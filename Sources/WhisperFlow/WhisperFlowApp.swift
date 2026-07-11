import Foundation
import SwiftUI

@main
enum WhisperFlowMain {
    static func main() {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--transcribe-file") {
            guard idx + 1 < args.count else {
                FileHandle.standardError.write(Data("error: --transcribe-file requires a path argument\n".utf8))
                exit(2)
            }
            let path = args[idx + 1]
            let rawOnly = args.contains("--raw-only")
            let exitCode = runCLITranscription(path: path, rawOnly: rawOnly)
            exit(exitCode)
        }
        if let idx = args.firstIndex(of: "--simulate-streaming") {
            guard idx + 1 < args.count else {
                FileHandle.standardError.write(Data("error: --simulate-streaming requires a path argument\n".utf8))
                exit(2)
            }
            let exitCode = runCLIStreamingSimulation(path: args[idx + 1])
            exit(exitCode)
        }
        WhisperFlowApp.main()
    }
}

/// Drives launch-time setup. An accessory (LSUIElement) app has no window to
/// hang `.onAppear` off reliably, so `applicationDidFinishLaunching` is the
/// dependable hook for `AppState.onLaunch()`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Own the local LLM cleanup backend end-to-end: start it here,
        // stop it in applicationWillTerminate below, so WhisperFlow never
        // depends on some separately-registered background service for
        // dictation cleanup.
        EmbeddedOllama.start()
        state?.onLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        EmbeddedOllama.stop()
    }
}

struct WhisperFlowApp: App {
    @StateObject private var state = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    static let transcriptWindowID = "transcript"

    var body: some Scene {
        // `body` is evaluated while SwiftUI builds the scene graph, which
        // happens before AppKit fires applicationDidFinishLaunching — so the
        // delegate is guaranteed to have its state reference by the time
        // that callback runs. (`let _ =` keeps this a plain statement rather
        // than a SceneBuilder expression, since bindDelegate() returns Void.)
        let _ = bindDelegate()

        // Menu-bar accessory: this is the only UI that appears at launch.
        // LSUIElement (Info.plist) keeps us out of the Dock; no window opens
        // automatically.
        MenuBarExtra {
            MenuBarContent(accessibility: state.accessibility) {
                openWindow(id: Self.transcriptWindowID)
            }
            .environmentObject(state)
        } label: {
            Image(systemName: "mic.circle")
        }
        .menuBarExtraStyle(.menu)

        // Transcript window: hidden at launch, opened only via the menu.
        Window("Whisper Flow", id: Self.transcriptWindowID) {
            MainView()
                .environmentObject(state)
        }
        .windowResizability(.contentSize)
    }

    private func bindDelegate() {
        appDelegate.state = state
    }
}

// MARK: - Headless CLI test mode

private func runCLITranscription(path: String, rawOnly: Bool) -> Int32 {
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0

    Task {
        do {
            let samples = try loadAudioFileAs16kMonoFloats(path: path)
            let audioSeconds = Double(samples.count) / AudioCapture.targetSampleRate

            let backend = ParakeetBackend()
            try await backend.prepare()

            let sttT0 = Date()
            let raw = TextNormalizer.normalizeSentenceSpacing(try await backend.transcribeFile(samples: samples))
            let sttMs = Int(Date().timeIntervalSince(sttT0) * 1000)

            print("RAW: \(raw)")

            var cleanupMs = 0
            var backendName = "raw-only"
            var cleanedChars = raw.count
            var cleanedText = raw
            if !rawOnly {
                let router = CleanupRouter()
                let result = await router.clean(raw)
                cleanupMs = result.durationMs
                backendName = result.backendName + (result.fellBackToRaw ? " (fallback-to-raw)" : "")
                cleanedText = TextNormalizer.normalizeSentenceSpacing(result.text)
                cleanedChars = cleanedText.count
                print("CLEANED (\(backendName)): \(cleanedText)")
            }
            print("TIMING: stt=\(sttMs) cleanup=\(cleanupMs)")

            UsageLog.append(mode: "file",
                            audioSeconds: audioSeconds,
                            rawChars: raw.count,
                            cleanedChars: cleanedChars,
                            sttMs: sttMs,
                            cleanupMs: cleanupMs,
                            cleanupBackend: backendName,
                            rawText: raw,
                            cleanedText: cleanedText)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exitCode = 1
        }
        semaphore.signal()
    }

    semaphore.wait()
    return exitCode
}

/// Diagnostic-only: feeds a file through the SAME streaming path a live
/// push-to-talk dictation uses (startStream/feed/finishStream in
/// AudioCapture-sized chunks, paced at real-time), instead of the one-shot
/// batch decode --transcribe-file uses. Exists to reproduce streaming-only
/// bugs (e.g. long dictations appearing to stop being heard after ~20s)
/// without needing a live microphone.
private func runCLIStreamingSimulation(path: String) -> Int32 {
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0

    Task {
        do {
            let samples = try loadAudioFileAs16kMonoFloats(path: path)
            let audioSeconds = Double(samples.count) / AudioCapture.targetSampleRate
            print("audio: \(String(format: "%.2f", audioSeconds))s (\(samples.count) samples)")

            let backend = ParakeetBackend()
            try await backend.prepare()

            var lastLoggedLen = 0
            try await backend.startStream { partial in
                // Log only on growth so the trace shows exactly where (if
                // anywhere) confirmed text stops advancing.
                if partial.displayText.count != lastLoggedLen {
                    lastLoggedLen = partial.displayText.count
                    print("  [partial @ \(Date().timeIntervalSince1970)] len=\(partial.displayText.count) tail=…\(partial.displayText.suffix(60))")
                }
            }

            // Same chunk size AudioCapture's real tap uses, paced at
            // real-time so any wall-clock-dependent chunking logic in the
            // streaming manager sees the same cadence a live mic would.
            let chunkSize = 4096
            var i = 0
            let chunkSeconds = Double(chunkSize) / AudioCapture.targetSampleRate
            let feedT0 = Date()
            while i < samples.count {
                let end = min(i + chunkSize, samples.count)
                try await backend.feed(samples: Array(samples[i..<end]))
                i = end
                try await Task.sleep(nanoseconds: UInt64(chunkSeconds * 1_000_000_000))
            }
            print("fed all chunks in \(String(format: "%.2f", Date().timeIntervalSince(feedT0)))s")

            let final = try await backend.finishStream()
            print("FINAL STREAMING TRANSCRIPT (\(final.count) chars):")
            print(final)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exitCode = 1
        }
        semaphore.signal()
    }

    semaphore.wait()
    return exitCode
}
