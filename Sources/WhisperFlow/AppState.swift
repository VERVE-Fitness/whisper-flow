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

    private let backend: TranscriptionBackend = ParakeetBackend()
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
    /// Keep the mic open this long after the key is released: people let go
    /// of the key on the last syllable, and the sliding-window decoder
    /// needs the trailing silence to commit the final word.
    private static let releaseTailNanoseconds: UInt64 = 250_000_000

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
        return "v\(version)" + (sha.map { " (\($0))" } ?? "")
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
    /// to be trusted on its own; re-decode the full retained clip through the
    /// batch path instead, which reports a real per-utterance confidence.
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

        accessibility.checkAndPromptIfNeeded()
        refreshInputDevices()
        startUpdateChecks()

        pill.onTapStop = { [weak self] in
            guard let self, self.currentMode != .window else { return }
            // The hands-free key tap is still armed; without this it would
            // swallow the user's next keypress as the "finish" key.
            self.hotkeys.reset()
            self.stopRecording()
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

                // Short clips give the sliding-window streaming pass too
                // little context to trust on its own; re-decode the full
                // retained buffer through the batch path, which scores a
                // real per-utterance confidence.
                if audioSeconds < Self.shortClipSecondsThreshold {
                    do {
                        let batch = try await backend.transcribeFileWithConfidence(samples: captured)
                        guard current() else { return }
                        sttConfidence = Double(batch.confidence)
                        if batch.confidence < Self.minimumBatchConfidence {
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
                        // The re-check exists to gate CONFIDENCE, not to
                        // replace the transcript. The batch pass sometimes
                        // drops out-of-vocabulary openings entirely (observed
                        // 2026-07-08: spoken "The VERVE Tori Functional
                        // Trainer", streaming heard the whole phrase, batch
                        // returned just "Functional trainer"). If the batch
                        // text lost a substantial share of the words the
                        // streaming pass heard, keep the streaming text — a
                        // mangled attempt at a product name downstream layers
                        // can correct beats a clean transcript missing it.
                        let streamWordCount = raw.split(whereSeparator: \.isWhitespace).count
                        let batchWordCount = batch.text.split(whereSeparator: \.isWhitespace).count
                        if Double(batchWordCount) >= Double(streamWordCount) * 0.7 {
                            raw = TextNormalizer.normalizeSentenceSpacing(batch.text)
                        } else {
                            FileHandle.standardError.write(Data("[stt] batch re-check dropped words (\(batchWordCount) vs streaming \(streamWordCount)); keeping streaming text\n".utf8))
                        }
                    } catch {
                        // Guard failure shouldn't break dictation — fall back
                        // to the streaming result.
                        FileHandle.standardError.write(Data("[stt] batch re-check failed, keeping streaming result: \(error)\n".utf8))
                    }
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
