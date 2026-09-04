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
        if args.contains("--list-input-devices") {
            exit(runCLIListInputDevices())
        }
        if let idx = args.firstIndex(of: "--capture-test") {
            guard idx + 1 < args.count, let seconds = Double(args[idx + 1]) else {
                FileHandle.standardError.write(Data("error: --capture-test requires a duration in seconds\n".utf8))
                exit(2)
            }
            var selection = InputDeviceSelection.saved
            if let i = args.firstIndex(of: "--input"), i + 1 < args.count {
                switch args[i + 1] {
                case "builtin": selection = .builtIn
                case "default": selection = .systemDefault
                default: selection = .device(uid: args[i + 1])
                }
            }
            exit(runCLICaptureTest(seconds: seconds, selection: selection, transcribe: !args.contains("--no-stt")))
        }
        if let idx = args.firstIndex(of: "--tap-test") {
            guard idx + 1 < args.count, let seconds = Double(args[idx + 1]) else {
                FileHandle.standardError.write(Data("error: --tap-test requires a duration in seconds\n".utf8))
                exit(2)
            }
            exit(runCLISystemAudioTapTest(seconds: seconds, transcribe: !args.contains("--no-stt")))
        }
        if let idx = args.firstIndex(of: "--dual-test") {
            guard idx + 1 < args.count, let seconds = Double(args[idx + 1]) else {
                FileHandle.standardError.write(Data("error: --dual-test requires a duration in seconds\n".utf8))
                exit(2)
            }
            exit(runCLIDualCaptureTest(seconds: seconds))
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
        EmbeddedOllama.start { [weak self] status in
            self?.state?.llmStatusChanged(status)
        }
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
    var finished = false
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
        finished = true
    }

    while !finished {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
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

// MARK: - Microphone diagnostics (CLI)

private func runCLIListInputDevices() -> Int32 {
    let def = AudioDevices.defaultInputDevice()
    let builtIn = AudioDevices.builtInMicrophone()
    print("saved selection: \(InputDeviceSelection.saved)")
    print("lid closed:      \(AudioDevices.isLidClosed()) (raw: \(AudioDevices.rawClamshellDescription()))")
    print("system default:  \(def?.name ?? "none") [\(def?.uid ?? "-")]")
    print("built-in mic:    \(builtIn?.name ?? "none") [\(builtIn?.uid ?? "-")]")
    print("all input devices:")
    for d in AudioDevices.allInputDevices() {
        let kind = d.isBuiltIn ? "built-in" : d.isBluetooth ? "bluetooth" : "other"
        print("  - \(d.name)  [\(d.uid)]  \(kind)")
    }
    return 0
}

/// Records for `seconds` from the resolved device through the SAME
/// AudioCapture path a live dictation uses, prints how many buffers arrived
/// and the RMS, then (optionally) batch-transcribes what it heard. Exists to
/// verify device pinning and mid-recording device changes without a human
/// holding a key: switch the system default input while this runs and the
/// buffer count must keep climbing.
private func runCLICaptureTest(seconds: Double, selection: InputDeviceSelection, transcribe: Bool) -> Int32 {
    // Not a semaphore: AudioCapture's stall watchdog is a main-run-loop
    // Timer, and blocking the main thread here would silence it -- the CLI
    // must exercise the same recovery path the app does.
    var finished = false
    var exitCode: Int32 = 0

    Task {
        let capture = AudioCapture()
        do {
            let t0 = Date()
            let stream = try await capture.start(selection: selection)
            print("capture started in \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000)) ms on \"\(capture.activeDevice?.name ?? "?")\"")
            let collector = Task { () -> [Float] in
                var all: [Float] = []
                for await chunk in stream { all.append(contentsOf: chunk) }
                return all
            }
            let ticker = Task {
                var last = 0
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    let n = capture.buffersDelivered
                    print("  t+\(String(format: "%.0f", Date().timeIntervalSince(t0)))s  buffers=\(n) (+\(n - last))  audio=\(String(format: "%.2f", capture.capturedSeconds))s  device=\"\(capture.activeDevice?.name ?? "?")\"")
                    last = n
                }
            }
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            ticker.cancel()
            capture.stop()
            let samples = await collector.value
            let rms = samples.isEmpty ? 0 : (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
            print("captured \(samples.count) samples (\(String(format: "%.2f", Double(samples.count) / AudioCapture.targetSampleRate))s), \(capture.buffersDelivered) buffers, rms=\(rms)")
            if transcribe, samples.count > 4_800 {
                let backend = ParakeetBackend()
                try await backend.prepare()
                let (text, confidence) = try await backend.transcribeFileWithConfidence(samples: samples)
                print("TRANSCRIPT (confidence \(String(format: "%.2f", confidence))): \(text)")
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exitCode = 1
        }
        finished = true
    }

    while !finished {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    return exitCode
}

// MARK: - System audio tap diagnostics (CLI)

/// Records `seconds` of the Mac's OUTPUT audio through SystemAudioTap -- the
/// same path a meeting recording will use for the far side of a call -- prints
/// buffer counts and RMS, then (optionally) batch-transcribes what it heard.
/// Play something while it runs (`say -v Karen "..."`, a Teams call, a YouTube
/// tab): buffer counts climbing with rms ~0 means the tap exists but the
/// System Audio Recording permission is missing, and the tap says so on stderr.
private func runCLISystemAudioTapTest(seconds: Double, transcribe: Bool) -> Int32 {
    guard #available(macOS 14.2, *) else {
        FileHandle.standardError.write(Data("error: \(SystemAudioTapError.unsupportedOS.localizedDescription)\n".utf8))
        return 1
    }
    // Not a semaphore: keep the main run loop being serviced, exactly as
    // --capture-test does, so timers and CoreAudio notifications still fire.
    var finished = false
    var exitCode: Int32 = 0

    Task {
        let tap = SystemAudioTap()
        do {
            let t0 = Date()
            let stream = try tap.start()
            print("system audio tap started in \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000)) ms, native format \(tap.nativeFormatDescription)")
            let collector = Task { () -> [Float] in
                var all: [Float] = []
                for await chunk in stream { all.append(contentsOf: chunk) }
                return all
            }
            let ticker = Task {
                var last = 0
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    let n = tap.buffersDelivered
                    print("  t+\(String(format: "%.0f", Date().timeIntervalSince(t0)))s  buffers=\(n) (+\(n - last))  audio=\(String(format: "%.2f", tap.capturedSeconds))s")
                    last = n
                }
            }
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            ticker.cancel()
            tap.stop()
            let samples = await collector.value
            let rms = samples.isEmpty ? 0 : (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
            print("captured \(samples.count) samples (\(String(format: "%.2f", Double(samples.count) / SystemAudioTap.targetSampleRate))s), \(tap.buffersDelivered) buffers, rms=\(rms)")
            if transcribe, samples.count > 4_800 {
                let backend = ParakeetBackend()
                try await backend.prepare()
                let (text, confidence) = try await backend.transcribeFileWithConfidence(samples: samples)
                print("TRANSCRIPT (confidence \(String(format: "%.2f", confidence))): \(text)")
            }
        } catch {
            tap.stop()
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exitCode = 1
        }
        finished = true
    }

    while !finished {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    return exitCode
}

/// Runs the microphone (AudioCapture, built-in mic) and the system-audio tap
/// AT THE SAME TIME for `seconds`, which is the state every meeting recording
/// will be in: our voice from the mic, the far side from the output tap. Prints
/// both buffer counts each second and both final RMS values, so a regression
/// where one path starves the other is visible immediately.
private func runCLIDualCaptureTest(seconds: Double) -> Int32 {
    guard #available(macOS 14.2, *) else {
        FileHandle.standardError.write(Data("error: \(SystemAudioTapError.unsupportedOS.localizedDescription)\n".utf8))
        return 1
    }
    var finished = false
    var exitCode: Int32 = 0

    Task {
        let mic = AudioCapture()
        let tap = SystemAudioTap()
        do {
            let t0 = Date()
            let micStream = try await mic.start(selection: .builtIn)
            let tapStream = try tap.start()
            print("mic on \"\(mic.activeDevice?.name ?? "?")\", system audio tap native format \(tap.nativeFormatDescription)")
            let micCollector = Task { () -> [Float] in
                var all: [Float] = []
                for await chunk in micStream { all.append(contentsOf: chunk) }
                return all
            }
            let tapCollector = Task { () -> [Float] in
                var all: [Float] = []
                for await chunk in tapStream { all.append(contentsOf: chunk) }
                return all
            }
            let ticker = Task {
                var lastMic = 0
                var lastTap = 0
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    let m = mic.buffersDelivered
                    let s = tap.buffersDelivered
                    print("  t+\(String(format: "%.0f", Date().timeIntervalSince(t0)))s  mic=\(m) (+\(m - lastMic))  system=\(s) (+\(s - lastTap))")
                    lastMic = m
                    lastTap = s
                }
            }
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            ticker.cancel()
            mic.stop()
            tap.stop()
            let micSamples = await micCollector.value
            let tapSamples = await tapCollector.value
            func rms(_ s: [Float]) -> Float {
                s.isEmpty ? 0 : (s.reduce(Float(0)) { $0 + $1 * $1 } / Float(s.count)).squareRoot()
            }
            print("mic:    \(micSamples.count) samples (\(String(format: "%.2f", Double(micSamples.count) / AudioCapture.targetSampleRate))s), \(mic.buffersDelivered) buffers, rms=\(rms(micSamples))")
            print("system: \(tapSamples.count) samples (\(String(format: "%.2f", Double(tapSamples.count) / SystemAudioTap.targetSampleRate))s), \(tap.buffersDelivered) buffers, rms=\(rms(tapSamples))")
        } catch {
            mic.stop()
            tap.stop()
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exitCode = 1
        }
        finished = true
    }

    while !finished {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    return exitCode
}
