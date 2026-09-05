import Foundation
import SwiftUI
import AppKit
import Combine
import ServiceManagement
import os

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        /// Speech model download / compile / load in progress. The payload is
        /// a human-readable status ("Downloading speech model 37%") so a
        /// first launch on a slow M1 doesn't sit on an opaque "Loading…" for
        /// two minutes.
        case loadingModels(String)
        case idle
        case recording
        case cleaning
        case done
        case error(String)

        var label: String {
            switch self {
            case .loadingModels(let status): return status
            case .idle: return "Ready"
            case .recording: return "Recording…"
            case .cleaning: return "Cleaning up…"
            case .done: return "Done"
            case .error(let msg): return "Error: \(msg)"
            }
        }
    }

    /// How the current/last dictation was triggered. Window dictations show
    /// text in the transcript window (M1 behaviour); hotkey dictations insert
    /// at the cursor and show the floating pill instead.
    enum DictationMode: String {
        case hotkey = "hotkey"
        case window = "window"
    }

    @Published var phase: Phase = .loadingModels("Loading speech model…")
    @Published var rawTranscript: String = ""
    @Published var cleanedTranscript: String = ""
    @Published var cleanupBackendName: String = "…"
    @Published var llmStatus: EmbeddedOllama.Status = .notStarted
    @Published var lastSttMs: Int?
    @Published var lastCleanupMs: Int?
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    /// Which microphone to record from (see InputDeviceSelection for why the
    /// default is the built-in mic, not the system default).
    @Published var inputSelection: InputDeviceSelection = InputDeviceSelection.saved
    @Published var inputDevices: [AudioInputDevice] = []
    /// Non-nil when GitHub has a newer build than this one (see UpdateCheck).
    @Published var updateAvailable: UpdateCheck.Result?

    let accessibility = AccessibilityPermission()

    // MARK: - Meetings

    /// The meeting recorder owns its OWN AudioCapture, so a meeting running in
    /// the background does not touch the dictation capture and Right Option
    /// keeps working mid-meeting.
    let meetings = MeetingRecorder()
    /// Plain-English line for the menu ("Recording", "Separating speakers… 40%",
    /// "Saved", "Failed: …"). Nil when no meeting has run this launch.
    @Published var meetingStatus: String?
    /// The meeting the review window and "Open last meeting folder" act on.
    @Published var lastMeetingID: String?
    private var meetingTicker: AnyCancellable?

    // MARK: - Flow connection

    /// Who this Mac is connected to Flow as, once `me()` has answered. Nil
    /// means either no token or a token Flow has not confirmed this launch.
    @Published var flowMe: FlowMe?
    /// Last thing the connection did, for the menu ("Connecting…", an error).
    @Published var flowStatus: String?
    let flow = FlowClient.shared

    // MARK: - Calendar prompts

    /// Asks about a meeting a minute before it starts. Menu toggle, on by
    /// default, kept in UserDefaults so it survives a relaunch.
    @Published var meetingPromptsEnabled: Bool = CalendarPrompter.promptsEnabled()
    let meetingPrompts = MeetingPromptNotifier()
    private var promptPoller: Task<Void, Never>?
    /// The poll stops while the Mac is asleep: a machine that wakes at 4pm
    /// must not fire a stack of prompts for meetings that already happened.
    private var isSystemAsleep = false
    private var sleepObservers: [NSObjectProtocol] = []

    /// Remembered across launches so the menu can say "connected" before the
    /// first `me()` of the session comes back.
    static let recogniseMeDefaultsKey = "flowRecogniseMe"
    var flowRecogniseMe: Bool { UserDefaults.standard.bool(forKey: Self.recogniseMeDefaultsKey) }

    /// One line for the menu. Never shows the token.
    var flowMenuLine: String {
        if let flowMe {
            let who = flowMe.name.isEmpty ? flowMe.email : flowMe.name
            return "Flow: connected as \(who)"
        }
        return flow.isConnected ? "Flow: connected" : "Flow: not connected"
    }

    var flowSettingsURL: URL {
        URL(string: flow.serverBase + "/whisper-settings") ?? URL(string: "https://flow.vervefitness.ai/whisper-settings")!
    }

    /// Concrete, not the `TranscriptionBackend` protocol: MeetingTranscriber
    /// needs `transcribeLong(url:)`, which only Parakeet has (it is the
    /// disk-backed long-form path, and there is no second backend shipping).
    private let backend = ParakeetBackend()
    private let router = CleanupRouter()
    private let capture = AudioCapture()
    private let hotkeys = HotkeyManager()
    private let pill = StatusPillController()

    /// Engine bring-up for the current dictation. Awaited by stopRecording
    /// before it tears the capture down, so a stop that lands while a
    /// Bluetooth mic is still negotiating (1-3 s) waits for the engine to
    /// exist instead of leaving it to start AFTER we've "stopped" it --
    /// which is one way to get a pill stuck on "Listening…" forever.
    private var captureStartTask: Task<AsyncStream<[Float]>, Error>?
    /// Streaming-session bring-up (SlidingWindowAsrManager load + start).
    /// Also awaited by stopRecording: on a slow machine, releasing the key
    /// before this finished used to make finishStream() throw "backend not
    /// prepared" and lose the dictation, while the late-arriving session
    /// leaked with its model references.
    private var streamStartTask: Task<Void, Error>?
    /// Drains the capture stream, feeding each chunk to the streaming backend
    /// while also accumulating the raw samples so stopRecording can run the
    /// silence/short-clip guards and the batch re-check against the
    /// untouched, unclipped audio.
    private var feedTask: Task<[Float], Never>?
    private var recordStart: Date?
    private var currentMode: DictationMode = .window
    private var accessibilityCancellable: AnyCancellable?
    /// Text before the caret in the target document, captured once at
    /// recording start (feature: context-aware spelling) -- by stop time our
    /// own pill/window may have shifted focus, so capturing later would read
    /// the wrong element.
    private var capturedFocusContext: String?
    /// Defense-in-depth against stopRecording() being entered twice for one
    /// dictation: the actual observed cause was duplicate flagsChanged
    /// delivery (see HotkeyManager.lastHandledFlagsTimestamp), now deduped at
    /// the source, but this guard doesn't depend on that diagnosis being
    /// complete -- it makes the stop path itself non-reentrant regardless of
    /// what triggers a second call (a second monitor, a race between the
    /// pill's tap-to-stop and the hotkey release, a future regression).
    /// `phase = .cleaning` alone isn't sufficient: it's read-then-written
    /// synchronously, but if two calls somehow interleave before either
    /// write lands, both can pass. This flag is set unconditionally as the
    /// very first statement, before any other work, closing that window.
    private var isStopping = false
    /// The stop pipeline in flight, so the watchdog can cancel it. Every
    /// await inside it is followed by a generation check, so an abandoned
    /// stop can never insert text into whatever app is frontmost later.
    private var stopTask: Task<Void, Never>?
    /// Identifies the stop in flight so the watchdog below only fires for
    /// the dictation it was armed for.
    private var stopGeneration: UUID?
    /// Hard cap on how long the app may sit in "Cleaning…". finishStream,
    /// the batch re-check and the LLM all have their own timeouts, but a
    /// hang anywhere in that chain used to leave the pill up and the state
    /// machine wedged until the app was force-quit. After this long the UI
    /// is reset so the next dictation works; the wedged task, if it ever
    /// completes, is ignored.
    private static let cleaningWatchdogSeconds: UInt64 = 45
    /// Budget for the background list refresh at every Stop. Short on
    /// purpose: it runs alongside cleanup and must never be the reason a
    /// dictation feels slow.
    static let backgroundRefreshTimeout: TimeInterval = 2
    /// Keep the mic open this long after the key is released: people let go
    /// of the key on the last syllable, and the sliding-window decoder needs
    /// the trailing silence to commit the final word. 400 ms since week 3,
    /// alongside the silence pad and the batch re-check in TranscriptChoice.
    private static var releaseTailNanoseconds: UInt64 { TranscriptChoice.releaseTailNanoseconds }

    var isRecording: Bool { phase == .recording }
    /// `.error` is deliberately recordable: an error is a message about the
    /// LAST dictation, not a reason to refuse the next one. (It used to be
    /// terminal -- one failed capture wedged the hotkeys until relaunch.)
    /// `isStopping` blocks a new start while the previous stop/cancel is
    /// still tearing down, so its teardown can't hit the new session.
    var canRecord: Bool {
        guard !isStopping else { return false }
        switch phase {
        case .idle, .done, .error: return true
        case .loadingModels, .recording, .cleaning: return false
        }
    }

    private var didLaunch = false

    /// "v2026.9.4 (a1b2c3d)" -- what the menu bar shows so a colleague can
    /// tell you which build they're running.
    static var currentCommit: String? {
        Bundle.main.infoDictionary?["WFGitCommit"] as? String
    }

    static var versionLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        let sha = info["WFGitCommit"] as? String
        let built = (info["WFBuildDate"] as? String).flatMap { Self.buildDateLabel($0) }
        let detail = [sha, built].compactMap { $0 }.joined(separator: ", ")
        return "v\(version)" + (detail.isEmpty ? "" : " (\(detail))")
    }

    /// "built 5 Sep 2026, 3:19 pm" from the UTC stamp make-app.sh writes,
    /// shown in the Mac's local time zone so the time matches the clock the
    /// person is looking at. A stamp that does not parse is left out.
    nonisolated static func buildDateLabel(_ iso: String, timeZone: TimeZone = .current) -> String? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: iso) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_AU")
        f.timeZone = timeZone
        f.dateFormat = "d MMM yyyy, h:mm a"
        return "built " + f.string(from: date).replacingOccurrences(of: "AM", with: "am").replacingOccurrences(of: "PM", with: "pm")
    }

    /// Name of the microphone the current selection resolves to right now.
    var activeMicrophoneName: String {
        let (device, follows) = AudioDevices.resolve(inputSelection)
        guard let device else { return "no microphone found" }
        if follows, inputSelection == .builtIn, AudioDevices.isLidClosed() {
            return "\(device.name) (lid closed, using system default)"
        }
        return follows ? "\(device.name) (system default)" : device.name
    }

    // MARK: - Silence / short-clip / confidence gates
    //
    // A 1.68s clip once produced a fluent, entirely wrong sentence: with too
    // little acoustic signal, the ASR decoder's language prior dominates and
    // invents plausible-sounding text instead of transcribing nothing. These
    // guards stop that text from ever reaching cleanup or insertion.

    /// RMS below this is treated as near-silence (room tone / mic noise
    /// floor). Chosen well below any real speech energy at 16-bit-equivalent
    /// Float32 samples (typical speech RMS is in the 0.02-0.2+ range).
    private static let silenceRmsThreshold: Float = 1e-3
    /// 0.3s at 16 kHz mono — below this there isn't enough audio to contain a
    /// word, regardless of energy.
    private static let minimumSamplesForTranscription = 4_800
    /// Below this, the sliding-window streaming pass has too little context
    /// to be trusted on its own, and the batch pass's confidence score is
    /// used to discard the clip outright. Longer clips still run through the
    /// batch decoder (see TranscriptChoice.batchRecheckMaxSeconds), but only
    /// to recover a lost tail, never to discard.
    private static let shortClipSecondsThreshold: Double = 3.0
    /// FluidAudio's batch confidence ranges ~0.1 (empty/near-silent) to 1.0
    /// (fully confident); below this the re-check is treated the same as a
    /// silence discard.
    private static let minimumBatchConfidence: Float = 0.5

    private static func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumSquares / Float(samples.count)).squareRoot()
    }

    /// Idempotent: the menu bar content and the (optional) transcript window
    /// both call this on appear, but only the first call should do anything.
    func onLaunch() {
        guard !didLaunch else { return }
        didLaunch = true

        UsageLog.migrateLegacyLogIfNeeded()

        // Default to starting at login on first run; the menu toggle can turn
        // it off, and we never re-force it after that.
        let loginDefaultKey = "didApplyLoginItemDefault"
        if !UserDefaults.standard.bool(forKey: loginDefaultKey) {
            UserDefaults.standard.set(true, forKey: loginDefaultKey)
            setLaunchAtLogin(true)
        }

        // Install hotkeys as soon as Accessibility is trusted, whether that's
        // true already at launch or the user grants it later from the menu
        // (no relaunch required).
        accessibilityCancellable = accessibility.$isTrusted
            .sink { [weak self] trusted in
                os_log("accessibility trusted: %{public}@", String(trusted))
                if trusted { self?.installHotkeys() }
            }

        // An update replaces the signed binary and macOS drops the
        // Accessibility grant with it, which reads as "the app stopped
        // typing". Ask again, once per new version, and say why.
        if accessibility.handleVersionChange() {
            pill.show(.accessibilityAfterUpdate)
        } else {
            accessibility.checkAndPromptIfNeeded()
        }
        refreshInputDevices()
        startUpdateChecks()
        refreshFlowIdentity()
        resumePendingUploads()
        startCalendarPrompts()

        pill.onTapStop = { [weak self] in
            guard let self else { return }
            // A meeting owns the pill while it records, so a tap means "stop
            // the meeting" and must not fall through to the dictation stop.
            if self.meetings.isRecording {
                self.stopMeeting()
                return
            }
            guard self.currentMode != .window else { return }
            // The hands-free key tap is still armed; without this it would
            // swallow the user's next keypress as the "finish" key.
            self.hotkeys.reset()
            self.stopRecording()
        }

        // Redraw the elapsed time on the pill twice a second while a meeting
        // records. Guarded on isRecording so a late tick cannot put the pill
        // back up after the meeting stopped.
        meetingTicker = meetings.$elapsedSeconds
            .receive(on: RunLoop.main)
            .sink { [weak self] elapsed in
                guard let self, self.meetings.isRecording else { return }
                self.pill.update(.meeting(elapsed: elapsed))
            }

        hotkeys.onStart = { [weak self] in
            guard let self, self.accessibility.isTrusted, self.canRecord else { return }
            self.beginDictation(mode: .hotkey)
        }
        hotkeys.onFinish = { [weak self] in
            guard let self else { return }
            guard self.isRecording, self.currentMode == .hotkey else { return }
            self.stopRecording()
        }
        hotkeys.onCancel = { [weak self] in
            guard let self else { return }
            guard self.isRecording, self.currentMode == .hotkey else { return }
            self.cancelDictation()
        }

        Task {
            // Resolve cleanup backend for the status line.
            let cleanup = await router.resolveBackend()
            self.cleanupBackendName = cleanup.name
            do {
                try await backend.prepare { [weak self] status in
                    Task { @MainActor in
                        guard let self, case .loadingModels = self.phase else { return }
                        self.phase = .loadingModels(status)
                    }
                }
                self.phase = .idle
            } catch {
                self.phase = .error("model load failed: \(error.localizedDescription)")
            }
        }
    }

    private func startUpdateChecks() {
        Task { [weak self] in
            while !Task.isCancelled {
                let result = await UpdateCheck.check(currentCommit: Self.currentCommit)
                await MainActor.run { self?.updateAvailable = result }
                try? await Task.sleep(nanoseconds: UInt64(UpdateCheck.interval) * 1_000_000_000)
            }
        }
    }

    func copyDiagnostics() {
        Diagnostics.copyToClipboard(state: self)
    }

    /// Called by EmbeddedOllama as the local LLM comes up / pulls its model.
    func llmStatusChanged(_ status: EmbeddedOllama.Status) {
        llmStatus = status
        if status == .ready {
            Task {
                let cleanup = await router.resolveBackend()
                self.cleanupBackendName = cleanup.name
            }
        }
    }

    private func installHotkeys() {
        hotkeys.install()
    }

    // MARK: - Microphone selection

    func refreshInputDevices() {
        inputDevices = AudioDevices.allInputDevices().sorted { a, b in
            if a.isBuiltIn != b.isBuiltIn { return a.isBuiltIn }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    func setInputSelection(_ selection: InputDeviceSelection) {
        inputSelection = selection
        InputDeviceSelection.saved = selection
        os_log("input device selection changed: %{public}@", String(describing: selection))
    }

    // MARK: - Window button entry point (M1 behaviour: unchanged)

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            beginDictation(mode: .window)
        }
    }

    // MARK: - Shared start/stop path

    private func beginDictation(mode: DictationMode) {
        guard canRecord else { return }
        currentMode = mode
        rawTranscript = ""
        cleanedTranscript = ""
        lastSttMs = nil
        lastCleanupMs = nil
        recordStart = Date()
        capturedFocusContext = accessibility.isTrusted ? FocusContext.captureBeforeCaret() : nil

        if mode != .window {
            pill.show(.listening(partial: ""))
        }

        // Recording from this instant, BEFORE the engine is up: a key release
        // that lands during Bluetooth negotiation must be honoured as a stop
        // (stopRecording awaits the bring-up chain), not ignored because
        // `isRecording` was still false.
        phase = .recording
        let selection = inputSelection
        let startTask = Task { [capture] in
            try await capture.start(selection: selection)
        }
        captureStartTask = startTask

        // One task covers engine bring-up AND streaming-session bring-up, and
        // it is assigned synchronously here, so stopRecording can always
        // snapshot it: a stop that lands 100 ms in awaits the whole chain
        // instead of finding a nil it can't wait on. The capture stream is
        // unbounded-buffered, so audio arriving while startStream is still
        // loading accumulates and is drained once feedTask starts.
        let streamTask = Task { [backend] in
            let stream = try await startTask.value
            try await backend.startStream { [weak self] partial in
                Task { @MainActor in
                    guard let self else { return }
                    self.rawTranscript = partial.displayText
                    if self.currentMode != .window {
                        self.pill.update(.listening(partial: partial.displayText))
                    }
                }
            }
            await MainActor.run {
                self.feedTask = Task { [backend] in
                    var captured: [Float] = []
                    for await chunk in stream {
                        captured.append(contentsOf: chunk)
                        try? await backend.feed(samples: chunk)
                    }
                    return captured
                }
            }
        }
        streamStartTask = streamTask

        Task {
            do {
                try await streamTask.value
            } catch {
                // Only report if nobody has already moved us on (a stop that
                // raced the failure surfaces its own outcome).
                guard phase == .recording, streamStartTask == streamTask else { return }
                phase = .error(error.localizedDescription)
                capture.stop()
                captureStartTask = nil
                streamStartTask = nil
                if mode != .window {
                    pill.show(.failed(error.localizedDescription))
                    hotkeys.reset()
                }
            }
        }
    }

    /// Escape pressed during a hands-free hotkey dictation: throw the audio
    /// away, insert nothing.
    private func cancelDictation() {
        guard isRecording, !isStopping else { return }
        isStopping = true
        phase = .idle
        pill.hide()
        // Snapshot and clear the handles synchronously: a re-chord that lands
        // during teardown starts a fresh session with fresh handles, and this
        // teardown must only ever touch the old ones.
        let streamTask = streamStartTask
        captureStartTask = nil
        streamStartTask = nil
        Task {
            defer { isStopping = false }
            _ = try? await streamTask?.value
            capture.stop()
            let feed = feedTask
            feedTask = nil
            _ = await feed?.value
            _ = try? await backend.finishStream()
            rawTranscript = ""
            cleanedTranscript = ""
        }
    }

    private func stopRecording() {
        // isStopping is set here, unconditionally, before isRecording is even
        // read -- if two calls somehow land back to back (see isStopping's
        // doc comment), the second sees isStopping already true and bails,
        // regardless of what phase happens to read as at that instant.
        guard !isStopping else {
            FileHandle.standardError.write(Data("[stop] stopRecording re-entered while already stopping; ignoring\n".utf8))
            return
        }
        guard isRecording else { return }
        isStopping = true
        phase = .cleaning
        // Fire and forget, alongside the cleanup: the phrase list and the
        // voice profiles are refreshed at every Stop so an edit made on the
        // settings page this morning is live this afternoon, with no relaunch
        // and no waiting.
        refreshFromFlow(reason: "stop")
        let mode = currentMode
        let sttStart = recordStart ?? Date()
        // Snapshot the handles now; the watchdog or a later dictation may
        // replace the fields while this pipeline is still awaiting.
        let streamTask = streamStartTask
        captureStartTask = nil
        streamStartTask = nil

        if mode != .window {
            pill.update(.cleaning)
        }

        let generation = UUID()
        stopGeneration = generation
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.cleaningWatchdogSeconds * 1_000_000_000)
            guard let self, self.stopGeneration == generation, self.phase == .cleaning else { return }
            FileHandle.standardError.write(Data("[stop] watchdog: still cleaning after \(Self.cleaningWatchdogSeconds)s; abandoning this dictation so the next one works\n".utf8))
            // Abandon the work, not just the UI: cancel the pipeline, close
            // the mic, and let the generation guards below drop anything the
            // wedged task still produces.
            self.stopTask?.cancel()
            self.stopTask = nil
            self.capture.stop()
            self.feedTask = nil
            self.phase = .error("Cleanup took too long; please try again")
            self.isStopping = false
            if mode != .window {
                self.pill.show(.failed("took too long, try again"))
                self.hotkeys.reset()
            }
        }

        stopTask = Task {
            defer {
                if stopGeneration == generation {
                    isStopping = false
                    stopTask = nil
                }
            }
            /// False once the watchdog has abandoned this stop or a newer
            /// stop has superseded it: nothing after that point may touch
            /// state or, above all, insert text.
            @MainActor func current() -> Bool { stopGeneration == generation && !Task.isCancelled }

            // Let the engine and the streaming session finish coming up (or
            // fail) before tearing them down; see streamStartTask's comment.
            do {
                if let streamTask { try await streamTask.value }
            } catch {
                guard current() else { return }
                capture.stop()
                phase = .error(error.localizedDescription)
                if mode != .window {
                    pill.show(.failed(error.localizedDescription))
                    hotkeys.reset()
                }
                return
            }
            guard current() else { return }
            try? await Task.sleep(nanoseconds: Self.releaseTailNanoseconds)
            guard current() else { return }
            let audioSeconds = capture.capturedSeconds
            let deviceName = capture.activeDevice?.name ?? "?"
            capture.stop()
            let feed = feedTask
            feedTask = nil
            guard let feed else {
                // No streaming session was ever started, so there is nothing
                // to finish and finishStream() would only throw.
                phase = .done
                if mode != .window {
                    pill.show(.discarded)
                    hotkeys.reset()
                }
                return
            }
            let captured = await feed.value
            guard current() else { return }
            do {
                let sttT0 = Date()
                // The capture stream has drained, so every real sample is in
                // before this: 600 ms of silence on the end is what makes the
                // sliding window commit the last words instead of leaving
                // them volatile forever. A failure here is not worth
                // abandoning the dictation for; finishStream still runs.
                try? await backend.feed(samples: TranscriptChoice.silencePad())
                var raw = TextNormalizer.normalizeSentenceSpacing(try await backend.finishStream())
                guard current() else { return }
                // stt_ms: time from stop-press to final text (streaming absorbed the rest).
                let sttMs = Int(Date().timeIntervalSince(sttT0) * 1000)
                _ = sttStart

                let rms = Self.rms(of: captured)
                if rms < Self.silenceRmsThreshold || captured.count < Self.minimumSamplesForTranscription {
                    FileHandle.standardError.write(Data("[stt] discarding near-silent/too-short capture (rms=\(rms), samples=\(captured.count), device=\(deviceName))\n".utf8))
                    rawTranscript = ""
                    cleanedTranscript = ""
                    phase = .done
                    if mode != .window {
                        pill.show(.discarded)
                        hotkeys.reset()
                    }
                    UsageLog.append(mode: mode.rawValue, audioSeconds: audioSeconds,
                                    rawChars: raw.count, cleanedChars: 0,
                                    sttMs: sttMs, cleanupMs: 0, cleanupBackend: "-",
                                    rawText: raw, cleanedText: "",
                                    rms: Double(rms), inputDevice: deviceName, outcome: "discard_silence")
                    return
                }

                var sttConfidence: Double?

                // One batch pass, for two jobs. The full retained buffer goes
                // through the batch decoder for any dictation of two minutes
                // or less: it never had a sliding window, so it cannot have
                // lost the tail the way streaming can. For a short clip the
                // same pass also scores the confidence that decides whether
                // to discard the clip entirely. One decode, never two.
                if audioSeconds <= TranscriptChoice.batchRecheckMaxSeconds {
                    var batchText: String?
                    do {
                        let batch = try await withTimeout(seconds: TranscriptChoice.batchTimeoutSeconds) {
                            [backend, captured] in
                            try await backend.transcribeFileWithConfidence(samples: captured)
                        }
                        guard current() else { return }
                        sttConfidence = Double(batch.confidence)
                        if audioSeconds < Self.shortClipSecondsThreshold,
                           batch.confidence < Self.minimumBatchConfidence {
                            FileHandle.standardError.write(Data("[stt] discarding low-confidence short clip (confidence=\(batch.confidence), text=\"\(batch.text)\")\n".utf8))
                            rawTranscript = ""
                            cleanedTranscript = ""
                            phase = .done
                            if mode != .window {
                                pill.show(.discarded)
                                hotkeys.reset()
                            }
                            UsageLog.append(mode: mode.rawValue, audioSeconds: audioSeconds,
                                            rawChars: batch.text.count, cleanedChars: 0,
                                            sttMs: sttMs, cleanupMs: 0, cleanupBackend: "-",
                                            rawText: batch.text, cleanedText: "",
                                            sttConfidence: sttConfidence, rms: Double(rms),
                                            inputDevice: deviceName, outcome: "discard_low_confidence")
                            return
                        }
                        batchText = TextNormalizer.normalizeSentenceSpacing(batch.text)
                    } catch {
                        // A failed or timed-out batch pass must never break a
                        // dictation: the streaming text stands.
                        FileHandle.standardError.write(Data("[stt] batch pass failed, keeping the streaming result: \(error)\n".utf8))
                    }
                    let choice = TranscriptChoice.choose(streaming: raw, batch: batchText)
                    FileHandle.standardError.write(Data((TranscriptChoice.logLine(choice) + "\n").utf8))
                    raw = choice.text
                }

                rawTranscript = raw

                // Snippets: a deterministic, pre-cleanup shortcut. If the raw
                // transcript IS a snippet cue (optionally prefixed "insert"/
                // "paste"), skip the LLM entirely and insert the stored text
                // verbatim -- snippets are exact strings the user chose
                // (URLs, signatures, etc.), and running them through cleanup
                // risks the LLM "helpfully" rewording them.
                if let snippetText = Self.matchSnippet(raw) {
                    cleanedTranscript = snippetText
                    cleanupBackendName = "snippet"
                    lastSttMs = sttMs
                    lastCleanupMs = 0
                    phase = .done

                    if mode != .window {
                        let outcome = TextInserter.insert(snippetText, accessibilityTrusted: accessibility.isTrusted)
                        switch outcome {
                        case .inserted:
                            pill.show(.inserted)
                            CorrectionLearner.observe(insertedText: snippetText)
                        case .copiedOnly:
                            pill.show(.copiedOnly)
                        }
                    }

                    UsageLog.append(mode: mode.rawValue, audioSeconds: audioSeconds,
                                    rawChars: raw.count, cleanedChars: snippetText.count,
                                    sttMs: sttMs, cleanupMs: 0, cleanupBackend: "snippet",
                                    rawText: raw, cleanedText: snippetText,
                                    sttConfidence: sttConfidence, rms: Double(rms),
                                    inputDevice: deviceName, outcome: "snippet")
                    return
                }

                let cleanResult = await router.clean(raw, context: capturedFocusContext)
                guard current() else { return }
                let cleanedText = TextNormalizer.normalizeSentenceSpacing(cleanResult.text)
                cleanedTranscript = cleanedText
                cleanupBackendName = cleanResult.backendName
                lastSttMs = sttMs
                lastCleanupMs = cleanResult.durationMs
                phase = .done

                let backendLogName = cleanResult.backendName + (cleanResult.fellBackToRaw ? " (fallback-to-raw)" : "")

                // Tracked explicitly rather than left at UsageLog's "inserted"
                // default -- window-mode dictations never attempt insertion at
                // all, and copiedOnly (accessibility not trusted) is a
                // meaningfully different outcome from a real insert; both used
                // to be silently mislabeled "inserted" in the log.
                var loggedOutcome = "window"
                if mode != .window {
                    let outcome = TextInserter.insert(cleanedText, accessibilityTrusted: accessibility.isTrusted)
                    switch outcome {
                    case .inserted:
                        pill.show(.inserted)
                        CorrectionLearner.observe(insertedText: cleanedText)
                        loggedOutcome = "inserted"
                    case .copiedOnly:
                        pill.show(.copiedOnly)
                        loggedOutcome = "copied_only"
                    }
                }

                UsageLog.append(mode: mode.rawValue,
                                audioSeconds: audioSeconds,
                                rawChars: raw.count,
                                cleanedChars: cleanedText.count,
                                sttMs: sttMs,
                                cleanupMs: cleanResult.durationMs,
                                cleanupBackend: backendLogName,
                                rawText: raw,
                                cleanedText: cleanedText,
                                sttConfidence: sttConfidence,
                                rms: Double(rms),
                                inputDevice: deviceName,
                                outcome: loggedOutcome)
            } catch {
                guard current() else { return }
                phase = .error(error.localizedDescription)
                if mode != .window {
                    pill.show(.failed(error.localizedDescription))
                    hotkeys.reset()
                }
            }
        }
    }

    // MARK: - Meetings

    /// Consent gate first, always. `ConsentGate.present` returning nil is a
    /// cancel and nothing is recorded -- there is no path to a recording that
    /// skips this, and the CLI harnesses stamp their own wording version so a
    /// test run can never be mistaken for a real consent.
    func startMeeting(title: String = "", attendees: [String] = [], calendarEventId: String? = nil) {
        guard !meetings.isRecording else { return }
        Task {
            // The consent wording promises the recording reaches VERVE's
            // system. On a Mac with no token it would not, so there is no
            // path from here to a recording that cannot be uploaded.
            guard flow.isConnected else {
                meetingStatus = "Not recorded: connect this Mac to Flow first"
                ConsentGate.presentNotConnected(settingsURL: flowSettingsURL)
                return
            }
            // Ask Flow whether one of its bots already has this meeting. Any
            // failure here is silent and the recording goes ahead: the bot
            // check is a courtesy, never a gate.
            if case .botHasIt(let botTitle) = await activeBotDecision() {
                guard await ConsentGate.presentBotAlreadyRecording(title: botTitle) else {
                    meetingStatus = "Left to VERVE Notes, nothing recorded here"
                    return
                }
            }
            guard let consent = await ConsentGate.present() else {
                meetingStatus = "Cancelled, nothing recorded"
                return
            }
            do {
                _ = try await meetings.start(title: title, attendees: attendees, consent: consent,
                                             calendarEventId: calendarEventId)
                pill.show(.meeting(elapsed: 0))
                meetingStatus = "Recording"
            } catch {
                meetingStatus = "Could not start: \(error.localizedDescription)"
                pill.show(.failed(error.localizedDescription))
            }
        }
    }

    /// What Flow's bots are doing, on a two second budget. A slow or broken
    /// answer reads as `.clear`, so the person still gets the consent gate.
    private func activeBotDecision() async -> BotAwareness.Decision {
        do {
            let bots = try await flow.activeBots()
            let decision = BotAwareness.decide(bots: bots, now: Date())
            BotAwareness.logDecision(decision, bots: bots)
            return decision
        } catch {
            BotAwareness.logUnavailable(error)
            return .clear
        }
    }

    /// Stop, then the whole offline pass: both tracks through Parakeet, the far
    /// side through the diariser, names proposed from the attendee list, and a
    /// summary when a key is on the machine. Every stage reports into the pill
    /// because the first run downloads the diariser model and silence would
    /// read as a hang.
    func stopMeeting() {
        guard meetings.isRecording else { return }
        Task {
            guard let rec = await meetings.stop() else { return }
            lastMeetingID = rec.id
            pill.update(.meetingProcessing("Transcribing…"))
            meetingStatus = "Transcribing…"
            do {
                let transcriber = MeetingTranscriber(backend: backend) { [weak self] status in
                    Task { @MainActor in
                        guard let self else { return }
                        self.meetingStatus = status
                        self.pill.update(.meetingProcessing(status))
                    }
                }
                var transcript = try await transcriber.transcribe(meetingID: rec.id)
                transcript.speakerNames = SpeakerNaming.proposeNames(for: transcript,
                                                                    ownerName: NSFullUserName(),
                                                                    attendees: rec.attendees)
                var updated = try MeetingStore.load(id: rec.id)
                updated.speakerNames = transcript.speakerNames
                try MeetingStore.save(updated)
                try transcriber.write(transcript, record: updated)

                // Week 2: the summary is written by Flow, not on this Mac.
                // Everything from here is match, encode, upload, wait.
                try await uploadMeeting(id: rec.id, transcript: transcript, chunks: transcriber.lastChunks)
            } catch {
                meetingStatus = "Failed: \(error.localizedDescription)"
                pill.show(.failed(error.localizedDescription))
            }
        }
    }

    /// The Flow half of Stop: refresh the voice profiles, match, encode,
    /// upload, wait for the summary. A failure here leaves the meeting on
    /// disk with a pending `upload-state.json`, which the next launch or the
    /// next connect picks up.
    private func uploadMeeting(id: String, transcript: Transcript, chunks: [SpeakerChunk]) async throws {
        guard flow.isConnected else {
            meetingStatus = "Saved on this Mac. Connect to Flow to upload it."
            pill.show(.failed("not connected to Flow"))
            return
        }
        // Fresh profiles at every Stop, so a colleague confirmed this morning
        // is recognised this afternoon without a relaunch.
        var profiles = VoiceProfileCache.load()
        var owner = flowMe
        if let me = try? await flow.me() {
            applyFlowIdentity(me)
            owner = me
            profiles = me.profiles
            VoiceProfileCache.save(me.profiles)
        }
        // The transcript has already been written by the time the upload
        // starts, so a phrase list that arrives here lands on the NEXT
        // recording, not this one. That is the same deal the voice profiles
        // get, and it is why the list is also refreshed at every dictation.

        let uploader = MeetingUploader(flow: flow) { [weak self] progress in
            Task { @MainActor in
                guard let self else { return }
                self.meetingStatus = progress.text
                if progress == .done {
                    self.pill.show(.inserted)
                } else {
                    self.pill.update(.meetingProcessing(progress.text))
                }
            }
        }
        pill.update(.meetingProcessing("Preparing the audio…"))
        meetingStatus = "Preparing the audio…"
        try uploader.prepare(meetingID: id, transcript: transcript, chunks: chunks,
                             profiles: profiles, owner: owner)
        _ = try await uploader.ship(meetingID: id)
    }

    /// Anything that did not finish uploading: run at launch and every time
    /// this Mac connects. Quiet, because a Mac that was offline all weekend
    /// should catch up without a stack of alerts.
    func resumePendingUploads() {
        guard flow.isConnected else { return }
        Task {
            let uploader = MeetingUploader(flow: flow) { [weak self] progress in
                Task { @MainActor in self?.meetingStatus = progress.text }
            }
            await uploader.resumePending()
        }
    }

    /// The recording's page in Flow.
    func flowRecordingURL(_ id: String) -> URL {
        URL(string: flow.serverBase + "/meetings/recording/" + id) ?? flowSettingsURL
    }

    func openInFlow(_ id: String) {
        NSWorkspace.shared.open(flowRecordingURL(id))
    }

    // MARK: - Flow connection

    /// Handles `whisperflow://connect?token=…&server=…`: stores the token in
    /// the keychain, asks Flow who it belongs to, and says so on the pill.
    func handleFlowURL(_ url: URL) {
        switch FlowConnectURL.action(url) {
        case .refresh:
            // The settings page opens this after a phrase edit. Quiet on
            // purpose: nobody clicked anything on this Mac.
            refreshFromFlow(reason: "refresh link")
            return
        case .connect(let connect):
            connectToFlow(connect)
        case nil:
            flowStatus = "That link was not a Whisper Flow connection link"
            pill.show(.failed("that link did not carry a connection"))
        }
    }

    private func connectToFlow(_ connect: FlowConnectURL.Connect) {
        flowStatus = "Connecting to Flow…"
        Task {
            do {
                let me = try await flow.connect(token: connect.token, server: connect.server)
                applyFlowIdentity(me)
                let who = me.name.isEmpty ? me.email : me.name
                flowStatus = "Connected as \(who)"
                pill.show(.flowConnected(name: who))
                VoiceProfileCache.save(me.profiles)
                PhraseStore.shared.replace(me.phrases)
                resumePendingUploads()
                FileHandle.standardError.write(Data("[flow] connected as \(me.email) to \(flow.serverBase), recognise_me=\(me.recogniseMe), \(me.profiles.count) voice profiles, \(me.phrases.count) phrases\n".utf8))
            } catch {
                flowMe = nil
                flowStatus = "Could not connect: \(error.localizedDescription)"
                pill.show(.failed(error.localizedDescription))
                FileHandle.standardError.write(Data("[flow] connect failed: \(error.localizedDescription)\n".utf8))
            }
        }
    }

    /// Confirms the stored token at launch, quietly. A failure here is not
    /// worth a pill: the menu line says "not connected" and that is enough.
    func refreshFlowIdentity() {
        guard flow.isConnected else { return }
        Task {
            do {
                applyFlowIdentity(try await flow.me())
            } catch {
                FileHandle.standardError.write(Data("[flow] could not confirm the stored token: \(error.localizedDescription)\n".utf8))
                if let flowError = error as? FlowError, flowError == .unauthorised {
                    flowMe = nil
                    flowStatus = "This Mac was disconnected in Flow; connect it again"
                }
            }
        }
    }

    /// Re-reads the lists from Flow in the background. Two seconds and one
    /// attempt: this runs after every dictation, and a slow or unreachable
    /// server must cost nothing. Yesterday's cached list is still the right
    /// list.
    func refreshFromFlow(reason: String) {
        guard flow.isConnected else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let me = try await self.flow.me(timeout: Self.backgroundRefreshTimeout, attempts: 1)
                self.applyFlowIdentity(me)
                FileHandle.standardError.write(Data("[phrase] refreshed from Flow (\(reason)): \(me.phrases.count) phrases\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("[phrase] could not refresh from Flow (\(reason)): \(error.localizedDescription)\n".utf8))
            }
        }
    }

    private func applyFlowIdentity(_ me: FlowMe) {
        flowMe = me
        UserDefaults.standard.set(me.recogniseMe, forKey: Self.recogniseMeDefaultsKey)
        VoiceProfileCache.save(me.profiles)
        PhraseStore.shared.replace(me.phrases)
        // First connect of this launch is where the notification permission
        // is asked for. Nothing is asked on a Mac that never connects.
        Task { await meetingPrompts.requestAuthorisationOnce() }
    }

    // MARK: - Calendar prompts

    /// Reads the calendar every minute while this Mac is connected, is not
    /// recording, and is awake. Started once at launch; the guards inside the
    /// tick are what turn it on and off, so there is one timer for the life
    /// of the app rather than one per connect.
    func startCalendarPrompts() {
        guard promptPoller == nil else { return }
        observeSleep()
        promptPoller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(CalendarPrompter.pollSeconds * 1_000_000_000))
                guard let self else { return }
                await self.pollCalendarOnce()
            }
        }
    }

    private func observeSleep() {
        let centre = NSWorkspace.shared.notificationCenter
        sleepObservers.append(centre.addObserver(forName: NSWorkspace.willSleepNotification,
                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.isSystemAsleep = true
                CalendarPrompter.log("the Mac is going to sleep, pausing the calendar poll")
            }
        })
        sleepObservers.append(centre.addObserver(forName: NSWorkspace.didWakeNotification,
                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.isSystemAsleep = false
                CalendarPrompter.log("the Mac is awake, resuming the calendar poll")
            }
        })
    }

    /// One tick. Every reason to do nothing is checked here rather than in
    /// the timer, so turning prompts off or starting a recording takes effect
    /// at the next tick without restarting anything.
    private func pollCalendarOnce() async {
        guard !isSystemAsleep, flow.isConnected, !meetings.isRecording,
              CalendarPrompter.promptsEnabled() else { return }
        let upcoming: FlowUpcoming
        do {
            upcoming = try await flow.upcoming()
        } catch {
            CalendarPrompter.logPollFailed(error)
            return
        }
        let now = Date()
        let alreadyPrompted = PromptedEventStore.prompted(on: now)
        let due = CalendarPrompter.eventsToPrompt(events: upcoming.events, now: now,
                                                  alreadyPrompted: alreadyPrompted,
                                                  promptsEnabled: true)
        CalendarPrompter.logPoll(events: upcoming.events, due: due, now: now,
                                 alreadyPrompted: alreadyPrompted)
        for event in due {
            // Remembered before it is shown, so a notification that fails to
            // post is still not asked again a minute later.
            PromptedEventStore.remember(event.id, on: now)
            let outcome = await meetingPrompts.prompt(event: event)
            if outcome == .record {
                startMeetingFromPrompt(eventId: event.id,
                                       subject: CalendarPrompter.subject(of: event),
                                       attendees: event.attendees)
            }
            // Only one meeting can be recorded at a time, so stop after the
            // first one the person said yes to.
            if outcome == .record || meetings.isRecording { break }
        }
    }

    /// The normal consent gate, with the meeting's own title and attendees
    /// already filled in and the calendar event id attached so Flow can link
    /// the recording to the event.
    func startMeetingFromPrompt(eventId: String, subject: String, attendees: [String]) {
        CalendarPrompter.log("recording \(subject) from the prompt")
        startMeeting(title: subject, attendees: attendees, calendarEventId: eventId)
    }

    /// What the person tapped on the notification. Called by the app
    /// delegate, which is where UNUserNotificationCenter delivers it.
    func handleMeetingPromptResponse(actionIdentifier: String, userInfo: [AnyHashable: Any]) {
        let subject = userInfo[MeetingPromptNotifier.subjectKey] as? String ?? "this meeting"
        guard actionIdentifier == MeetingPromptNotifier.recordAction else {
            CalendarPrompter.log("left \(subject) unrecorded (\(actionIdentifier))")
            return
        }
        guard let eventId = userInfo[MeetingPromptNotifier.eventIdKey] as? String else {
            CalendarPrompter.log("a prompt answer arrived without an event id, ignoring it")
            return
        }
        let attendees = userInfo[MeetingPromptNotifier.attendeesKey] as? [String] ?? []
        startMeetingFromPrompt(eventId: eventId, subject: subject, attendees: attendees)
    }

    func setMeetingPrompts(_ on: Bool) {
        CalendarPrompter.setPromptsEnabled(on)
        meetingPromptsEnabled = on
        CalendarPrompter.log(on ? "meeting prompts on" : "meeting prompts off")
    }

    func openFlowSettings() {
        NSWorkspace.shared.open(flowSettingsURL)
    }

    func openMeetingFolder(_ id: String) {
        NSWorkspace.shared.open(MeetingStore.directory(for: id))
    }

    /// Rename one speaker on a saved meeting: rewrites transcript.json,
    /// transcript.md and the name map in meeting.json so the folder on disk and
    /// the review window never disagree.
    func applySpeakerName(meetingID: String, speakerId: String, name: String) {
        do {
            var record = try MeetingStore.load(id: meetingID)
            let data = try Data(contentsOf: MeetingStore.transcriptJSONURL(meetingID))
            let transcript = SpeakerNaming.renamed(try JSONDecoder().decode(Transcript.self, from: data),
                                                   speakerId: speakerId, to: name)
            record.speakerNames = transcript.speakerNames
            try MeetingStore.save(record)
            try MeetingTranscriber(backend: backend).write(transcript, record: record)
        } catch {
            meetingStatus = "Could not rename: \(error.localizedDescription)"
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Fall through to re-reading actual status below.
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Normalizes the raw transcript (lowercase, strip punctuation/common
    /// fillers, trim, optionally strip a leading "insert"/"paste") and looks
    /// it up against the stored snippet cues. Exact match only -- a fuzzy
    /// match risks firing on an unrelated sentence that happens to contain
    /// the cue words.
    static func matchSnippet(_ raw: String) -> String? {
        let snippets = UserLexicon.shared.snippets
        guard !snippets.isEmpty else { return nil }
        // Normalize the stored cues the same way as the transcript: cues are
        // saved as the user typed them ("calendar link!"), but the transcript
        // side has punctuation stripped — without normalizing both sides a
        // cue containing any punctuation could never match.
        var normalizedSnippets: [String: String] = [:]
        for (cue, text) in snippets {
            normalizedSnippets[normalizeForSnippetMatch(cue)] = text
        }
        let normalized = normalizeForSnippetMatch(raw)
        if let hit = normalizedSnippets[normalized] { return hit }
        for prefix in ["insert ", "paste "] {
            if normalized.hasPrefix(prefix) {
                let cue = String(normalized.dropFirst(prefix.count))
                if let hit = normalizedSnippets[cue] { return hit }
            }
        }
        return nil
    }

    private static let snippetFillerWords: Set<String> = ["um", "uh", "uhm", "erm", "er"]

    private static func normalizeForSnippetMatch(_ raw: String) -> String {
        let stripped = raw.lowercased().replacingOccurrences(
            of: "[^a-z0-9 ]", with: "", options: .regularExpression
        )
        let words = stripped.split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty && !snippetFillerWords.contains($0) }
        return words.joined(separator: " ")
    }

    func copyCleaned() {
        let text = cleanedTranscript.isEmpty ? rawTranscript : cleanedTranscript
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
