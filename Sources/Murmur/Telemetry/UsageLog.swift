import Foundation

/// Append-only JSONL usage log at
/// ~/Library/Application Support/Murmur/usage.jsonl
enum UsageLog {
    struct Entry: Codable {
        let ts: String
        let mode: String            // "mic" | "file"
        let audio_seconds: Double
        let raw_chars: Int
        let cleaned_chars: Int
        let stt_ms: Int
        let cleanup_ms: Int
        let cleanup_backend: String
    }

    static var logURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
            .appendingPathComponent("usage.jsonl")
    }

    static func append(mode: String, audioSeconds: Double, rawChars: Int, cleanedChars: Int,
                       sttMs: Int, cleanupMs: Int, cleanupBackend: String) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entry = Entry(ts: iso.string(from: Date()), mode: mode, audio_seconds: audioSeconds,
                          raw_chars: rawChars, cleaned_chars: cleanedChars,
                          stt_ms: sttMs, cleanup_ms: cleanupMs, cleanup_backend: cleanupBackend)
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
