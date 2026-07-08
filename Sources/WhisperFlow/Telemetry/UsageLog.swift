import Foundation

/// Append-only JSONL usage log at
/// ~/Library/Application Support/WhisperFlow/usage.jsonl
enum UsageLog {
    struct Entry: Codable {
        let ts: String
        let mode: String            // "ptt" | "toggle" | "window" | "file"
        let audio_seconds: Double
        let raw_chars: Int
        let cleaned_chars: Int
        let stt_ms: Int
        let cleanup_ms: Int
        let cleanup_backend: String
        /// Truncated to 200 chars each — kept local-only, same as everything
        /// else in this file, purely so a bad cleanup can actually be
        /// diagnosed after the fact instead of guessed at from char counts.
        let raw_text: String
        let cleaned_text: String
        /// Optional fields for the silence/short-clip/low-confidence guards.
        /// Swift's synthesized `Encodable` conformance calls
        /// `encodeIfPresent` for `Optional` stored properties, so these are
        /// simply omitted from the JSON line (not written as `null`) when nil
        /// — kept out of every existing log line until a guard fires.
        let stt_confidence: Double?
        let rms: Double?
        let outcome: String
    }

    static var logURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperFlow", isDirectory: true)
            .appendingPathComponent("usage.jsonl")
    }

    /// Old Murmur-era log location. If it exists and the new one doesn't yet,
    /// its contents are migrated on first launch.
    private static var legacyLogURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
            .appendingPathComponent("usage.jsonl")
    }

    /// One-time migration: move the old Murmur usage.jsonl contents into the
    /// new WhisperFlow location. Safe to call every launch (no-ops after the
    /// first successful migration since the legacy file is removed).
    static func migrateLegacyLogIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyLogURL.path) else { return }
        guard !fm.fileExists(atPath: logURL.path) else {
            // New log already exists; just drop the legacy file so we don't
            // keep re-checking every launch.
            try? fm.removeItem(at: legacyLogURL)
            return
        }
        do {
            let dir = logURL.deletingLastPathComponent()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.moveItem(at: legacyLogURL, to: logURL)
        } catch {
            FileHandle.standardError.write(Data("[usage-log] legacy migration failed: \(error)\n".utf8))
        }
    }

    static func append(mode: String, audioSeconds: Double, rawChars: Int, cleanedChars: Int,
                       sttMs: Int, cleanupMs: Int, cleanupBackend: String,
                       rawText: String = "", cleanedText: String = "",
                       sttConfidence: Double? = nil, rms: Double? = nil,
                       outcome: String = "inserted") {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entry = Entry(ts: iso.string(from: Date()), mode: mode, audio_seconds: audioSeconds,
                          raw_chars: rawChars, cleaned_chars: cleanedChars,
                          stt_ms: sttMs, cleanup_ms: cleanupMs, cleanup_backend: cleanupBackend,
                          raw_text: String(rawText.prefix(200)), cleaned_text: String(cleanedText.prefix(200)),
                          stt_confidence: sttConfidence, rms: rms, outcome: outcome)
        do {
            let dir = logURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            var line = try encoder.encode(entry)
            line.append(Data("\n".utf8))
            if FileManager.default.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: logURL)
            }
        } catch {
            FileHandle.standardError.write(Data("[usage-log] write failed: \(error)\n".utf8))
        }
    }
}
