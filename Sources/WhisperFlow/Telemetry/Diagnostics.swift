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
