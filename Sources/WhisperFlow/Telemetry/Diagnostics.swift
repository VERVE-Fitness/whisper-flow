import Foundation
import AppKit

/// "Copy diagnostics" in the menu bar: one plain-text block a colleague can
/// paste into a message when something isn't working, instead of "it
/// doesn't work". Everything here is already on their Mac; nothing is sent
/// anywhere by this app -- it only goes on the clipboard.
enum Diagnostics {
    @MainActor
    static func report(state: AppState) -> String {
        var lines: [String] = []
        lines.append("Whisper Flow \(AppState.versionLabel)")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(chip()) · \(memoryGB()) GB RAM")
        lines.append("status: \(state.phase.label)")
        lines.append("cleanup backend: \(state.cleanupBackendName) · language model: \(state.llmStatus.label)")
        lines.append("accessibility: \(state.accessibility.isTrusted ? "granted" : "NOT granted")")
        lines.append("microphone setting: \(describe(state.inputSelection)) → \(state.activeMicrophoneName)")
        let def = AudioDevices.defaultInputDevice()
        lines.append("system default input: \(def?.name ?? "none")")
        lines.append("input devices:")
        for d in AudioDevices.allInputDevices() {
            lines.append("  - \(d.name) [\(d.isBuiltIn ? "built-in" : d.isBluetooth ? "bluetooth" : "other")]")
        }
        lines.append("")
        lines.append("last dictations:")
        lines.append(contentsOf: recentUsage(limit: 8).map { "  " + $0 })
        lines.append("")
        lines.append("ollama.log tail:")
        lines.append(contentsOf: tail(of: ollamaLogURL, lines: 12).map { "  " + $0 })
        lines.append("")
        lines.append("app.log tail (\(appLogURL.path)):")
        lines.append(contentsOf: tail(of: appLogURL, lines: appLogTailLines).map { "  " + $0 })
        return lines.joined(separator: "\n")
    }

    @MainActor
    static func copyToClipboard(state: AppState) {
        let text = report(state: state)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Pieces

    private static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperFlow", isDirectory: true)
    }
    private static var usageLogURL: URL { appSupport.appendingPathComponent("usage.jsonl") }
    private static var ollamaLogURL: URL { appSupport.appendingPathComponent("ollama.log") }

    // MARK: - The app's own log file

    /// Everything this app has ever had to say went to stderr, and stderr is
    /// thrown away when an app is launched from Finder -- which is how it is
    /// always launched. Diagnosing the "Cleaning…" hang cost a morning for
    /// that reason alone. fd 2 is pointed at this file at launch, so every
    /// existing `FileHandle.standardError.write` lands in it with no call site
    /// changed.
    static var appLogURL: URL { appSupport.appendingPathComponent("app.log") }
    /// The one previous file kept after a rotation.
    static var rotatedAppLogURL: URL { appSupport.appendingPathComponent("app.log.1") }
    /// Keep the last 5 MB. At the volume this app writes (a few hundred bytes
    /// per dictation) that is months.
    static let maxAppLogBytes = 5 * 1024 * 1024
    /// How much of it goes on the clipboard with "Copy diagnostics".
    static let appLogTailLines = 200

    /// Whether the log has outgrown its budget and should be rotated.
    /// Separated out and tested because getting it wrong in either direction
    /// is bad: never rotating fills the disk, rotating too eagerly throws away
    /// the evidence the file exists to keep.
    static func shouldRotate(currentBytes: Int, limitBytes: Int = maxAppLogBytes) -> Bool {
        guard limitBytes > 0 else { return false }
        return currentBytes >= limitBytes
    }

    /// Point fd 2 at `app.log`, in append mode, rotating first if the file has
    /// outgrown its budget. Call ONCE, at launch, and never from the CLI
    /// harness modes -- their whole output is on stderr and belongs in the
    /// terminal the person is watching.
    static func redirectStandardErrorToLogFile() {
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        rotateAppLogIfNeeded(reopen: false)
        guard openAppLogOnStandardError() else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        let sha = info["WFGitCommit"] as? String ?? "unstamped"
        FileHandle.standardError.write(Data("\n[app] \(stamp) launched v\(version) (\(sha)), pid \(ProcessInfo.processInfo.processIdentifier)\n".utf8))
    }

    @discardableResult
    private static func openAppLogOnStandardError() -> Bool {
        let fd = open(appLogURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return false }
        if fd != STDERR_FILENO {
            dup2(fd, STDERR_FILENO)
            close(fd)
        }
        return true
    }

    /// Rotate `app.log` to `app.log.1` once it passes the size budget.
    /// `reopen` re-points fd 2 at the fresh file afterwards; without it every
    /// later write would follow the renamed inode into app.log.1, which is
    /// exactly the bug that makes naive log rotation useless.
    static func rotateAppLogIfNeeded(reopen: Bool = true) {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: appLogURL.path)[.size] as? UInt64) ?? nil
        guard let size, shouldRotate(currentBytes: Int(size)) else { return }
        try? fm.removeItem(at: rotatedAppLogURL)
        do {
            try fm.moveItem(at: appLogURL, to: rotatedAppLogURL)
        } catch {
            return
        }
        if reopen { openAppLogOnStandardError() }
    }

    /// One line per stage of a dictation's stop pipeline, so the next hang
    /// says where it happened instead of costing a morning. `ms` is measured
    /// from the moment the key was released.
    static func dictation(_ id: String, stage: String, ms: Int) {
        FileHandle.standardError.write(Data("[dictation] id=\(id) stage=\(stage) ms=\(ms)\n".utf8))
    }

    private static func describe(_ selection: InputDeviceSelection) -> String {
        switch selection {
        case .builtIn: return "built-in"
        case .systemDefault: return "system default"
        case .device(let uid): return "device \(uid)"
        }
    }

    /// Compact one-line-per-dictation summary; transcript text is
    /// deliberately left out so the block is safe to paste into a chat.
    private static func recentUsage(limit: Int) -> [String] {
        tail(of: usageLogURL, lines: limit).compactMap { line in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let ts = (obj["ts"] as? String ?? "?").prefix(19)
            let secs = obj["audio_seconds"] as? Double ?? 0
            let outcome = obj["outcome"] as? String ?? "?"
            let backend = obj["cleanup_backend"] as? String ?? "?"
            let stt = obj["stt_ms"] as? Int ?? 0
            let cleanup = obj["cleanup_ms"] as? Int ?? 0
            let device = obj["input_device"] as? String ?? "-"
            let rawChars = obj["raw_chars"] as? Int ?? 0
            return "\(ts)  \(String(format: "%5.1f", secs))s  \(rawChars) chars  \(outcome)  \(backend)  stt \(stt)ms  cleanup \(cleanup)ms  mic \(device)"
        }
    }

    private static func tail(of url: URL, lines n: Int) -> [String] {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
        let all = text.split(separator: "\n", omittingEmptySubsequences: true)
        return all.suffix(n).map { String($0.prefix(220)) }
    }

    private static func chip() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "unknown chip" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    private static func memoryGB() -> Int {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }
}
