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
        WhisperFlowApp.main()
    }
}

/// Drives launch-time setup. An accessory (LSUIElement) app has no window to
/// hang `.onAppear` off reliably, so `applicationDidFinishLaunching` is the
/// dependable hook for `AppState.onLaunch()`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        state?.onLaunch()
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
            let raw = try await backend.transcribeFile(samples: samples)
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
                cleanedChars = result.text.count
                cleanedText = result.text
                print("CLEANED (\(backendName)): \(result.text)")
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
