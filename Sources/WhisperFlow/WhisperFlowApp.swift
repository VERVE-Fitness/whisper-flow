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
        if let idx = args.firstIndex(of: "--transcribe-meeting") {
            guard idx + 1 < args.count else {
                FileHandle.standardError.write(Data("error: --transcribe-meeting requires a meeting id\n".utf8))
                exit(2)
            }
            exit(runCLITranscribeMeeting(id: args[idx + 1]))
        }
        if let idx = args.firstIndex(of: "--summarise-meeting") {
            guard idx + 1 < args.count else {
                FileHandle.standardError.write(Data("error: --summarise-meeting requires a meeting id\n".utf8))
                exit(2)
            }
            exit(runCLISummariseMeeting(id: args[idx + 1]))
        }
        if let idx = args.firstIndex(of: "--meeting-test") {
            guard idx + 1 < args.count, let seconds = Double(args[idx + 1]) else {
                FileHandle.standardError.write(Data("error: --meeting-test requires a duration in seconds\n".utf8))
                exit(2)
            }
            var attendees: [String] = []
            if let i = args.firstIndex(of: "--attendees"), i + 1 < args.count {
                attendees = args[i + 1]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
            exit(runCLIMeetingTest(seconds: seconds, attendees: attendees))
        }
        if let idx = args.firstIndex(of: "--record-test") {
            guard idx + 1 < args.count, let seconds = Double(args[idx + 1]) else {
                FileHandle.standardError.write(Data("error: --record-test requires a duration in seconds\n".utf8))
                exit(2)
            }
            exit(runCLIRecordTest(seconds: seconds))
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

    /// The `whisperflow://connect?token=…` handler. SwiftUI's `onOpenURL`
    /// needs a window in the responder chain to fire reliably, and this is an
    /// LSUIElement app whose only UI at launch is a menu bar item, so the URL
    /// is taken straight off the Apple Event instead. Registered in
    /// `willFinishLaunching`, which is before the system delivers a GetURL
    /// event to an app it launched to open a link.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
    }

    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else {
            FileHandle.standardError.write(Data("[flow] a URL arrived that could not be read\n".utf8))
            return
        }
        // The token is never printed, here or anywhere else.
        FileHandle.standardError.write(Data("[flow] opened \(FlowConnectURL.redacted(url))\n".utf8))
        Task { @MainActor [weak self] in self?.state?.handleFlowURL(url) }
    }

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
    static let meetingWindowID = "meeting"

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
            MenuBarContent(accessibility: state.accessibility,
                           meetings: state.meetings,
                           openTranscriptWindow: { openWindow(id: Self.transcriptWindowID) },
                           openMeetingWindow: { openWindow(id: Self.meetingWindowID) })
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

        // Review window for the last meeting. Also hidden at launch; it opens
        // itself only via the menu, and it reads what is already on disk.
        Window("Last meeting", id: Self.meetingWindowID) {
            MeetingWindow()
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
            // capturedSeconds should now track wall clock, not speech time:
            // gapSecondsFilled is the synthesised silence that makes up the
            // difference (see SystemAudioTap.gapFill).
            print("capturedSeconds=\(String(format: "%.2f", tap.capturedSeconds))s  gapSecondsFilled=\(String(format: "%.2f", tap.gapSecondsFilled))s  wallClock=\(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
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

// MARK: - Meeting recorder harness (CLI)

/// Records a meeting for `seconds` through the real MeetingRecorder (mic +
/// system tap), then prints the folder and track lengths. Spins the main run
/// loop like --capture-test so the AudioCapture watchdog timer runs.
private func runCLIRecordTest(seconds: Double) -> Int32 {
    var finished = false
    var exitCode: Int32 = 0
    Task { @MainActor in
        let recorder = MeetingRecorder()
        do {
            // "-cli" so nothing downstream can mistake a harness run for a real
            // person having read the consent wording and agreed to it.
            let consent = MeetingConsent(confirmedAt: Date(), wordingVersion: ConsentGate.wordingVersion + "-cli")
            let rec = try await recorder.start(title: "CLI record test", attendees: [], consent: consent)
            print("recording \(rec.id) for \(seconds)s …")
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            let done = await recorder.stop()
            print("folder: \(MeetingStore.directory(for: rec.id).path)")
            print("track A: \(String(format: "%.2f", done?.trackASeconds ?? 0))s   track B: \(String(format: "%.2f", done?.trackBSeconds ?? 0))s")
            print("track B offset: \(String(format: "%.2f", done?.trackBOffsetSeconds ?? 0))s (added to every track B time before the merge)")
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exitCode = 1
        }
        finished = true
    }
    while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    return exitCode
}

/// Batch-transcribes an already-recorded meeting: Parakeet over both tracks,
/// the offline diariser over the far side, then prints the Markdown that was
/// written next to the audio.
private func runCLITranscribeMeeting(id: String) -> Int32 {
    var finished = false
    var exitCode: Int32 = 0
    Task {
        do {
            let transcriber = MeetingTranscriber(backend: ParakeetBackend()) { status in print("  \(status)") }
            let t0 = Date()
            let transcript = try await transcriber.transcribe(meetingID: id)
            print("transcribed in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s: \(transcript.segments.count) segments, speakers: \(Set(transcript.segments.map(\.speakerId)).sorted())")
            print(try String(contentsOf: MeetingStore.transcriptMarkdownURL(id), encoding: .utf8))
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exitCode = 1
        }
        finished = true
    }
    while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    return exitCode
}

/// Sends an already-transcribed meeting to the Anthropic Messages API and
/// prints the summary that was written next to the audio. Does nothing (exit 0)
/// when no key is on the machine: the key lives in the environment as
/// ANTHROPIC_API_KEY or in Application Support/WhisperFlow/anthropic.key, never
/// in the repo.
private func runCLISummariseMeeting(id: String) -> Int32 {
    var finished = false
    var exitCode: Int32 = 0
    Task {
        do {
            let t0 = Date()
            if let summary = try await MeetingSummariser.summarise(meetingID: id) {
                print("summarised in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s with \(MeetingSummariser.model): \(summary.decisions.count) decisions, \(summary.actions.count) actions")
                print(try String(contentsOf: MeetingStore.summaryURL(id), encoding: .utf8))
            } else {
                print("no Anthropic key on this Mac; nothing summarised")
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exitCode = 1
        }
        finished = true
    }
    while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    return exitCode
}

/// The whole week-1 meeting pipeline in one command: record for `seconds`,
/// transcribe both tracks, name the speakers from `--attendees`, summarise if a
/// key is present, then print the folder, the transcript and the summary. This
/// is the harness a human uses to check a change end to end without clicking
/// through the menu bar.
private func runCLIMeetingTest(seconds: Double, attendees: [String]) -> Int32 {
    var finished = false
    var exitCode: Int32 = 0
    Task { @MainActor in
        let recorder = MeetingRecorder()
        do {
            // "-cli": a harness run must never be mistaken for real consent.
            let consent = MeetingConsent(confirmedAt: Date(),
                                         wordingVersion: ConsentGate.wordingVersion + "-cli")
            let rec = try await recorder.start(title: "CLI meeting test",
                                               attendees: attendees,
                                               consent: consent)
            print("recording \(rec.id) for \(seconds)s …")
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            let stopped = await recorder.stop()
            print("track A: \(String(format: "%.2f", stopped?.trackASeconds ?? 0))s   track B: \(String(format: "%.2f", stopped?.trackBSeconds ?? 0))s   track B offset: \(String(format: "%.2f", stopped?.trackBOffsetSeconds ?? 0))s")

            let t0 = Date()
            let transcriber = MeetingTranscriber(backend: ParakeetBackend()) { status in print("  \(status)") }
            var transcript = try await transcriber.transcribe(meetingID: rec.id)
            transcript.speakerNames = SpeakerNaming.proposeNames(for: transcript,
                                                                ownerName: NSFullUserName(),
                                                                attendees: attendees)
            var record = try MeetingStore.load(id: rec.id)
            record.speakerNames = transcript.speakerNames
            try MeetingStore.save(record)
            try transcriber.write(transcript, record: record)
            print("transcribed in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s: \(transcript.segments.count) segments, speakers \(transcript.speakerNames.keys.sorted())")

            let summary = try await MeetingSummariser.summarise(meetingID: rec.id)
            print("folder: \(MeetingStore.directory(for: rec.id).path)")
            print("--- transcript.md ---")
            print(try String(contentsOf: MeetingStore.transcriptMarkdownURL(rec.id), encoding: .utf8))
            if summary != nil {
                print("--- summary.md ---")
                print(try String(contentsOf: MeetingStore.summaryURL(rec.id), encoding: .utf8))
            } else {
                print("--- summary.md --- (skipped: no Anthropic key on this Mac)")
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exitCode = 1
        }
        finished = true
    }
    while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    return exitCode
}
