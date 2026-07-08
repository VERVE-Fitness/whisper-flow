import Foundation
import SwiftUI
import AppKit
import Combine
import ServiceManagement
import os

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case loadingModels
        case idle
        case recording
        case cleaning
        case done
        case error(String)

        var label: String {
            switch self {
            case .loadingModels: return "Loading Parakeet models…"
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

    @Published var phase: Phase = .loadingModels
    @Published var rawTranscript: String = ""
    @Published var cleanedTranscript: String = ""
    @Published var cleanupBackendName: String = "…"
    @Published var lastSttMs: Int?
    @Published var lastCleanupMs: Int?
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    let accessibility = AccessibilityPermission()

    private let backend: TranscriptionBackend = ParakeetBackend()
    private let router = CleanupRouter()
    private let capture = AudioCapture()
    private let hotkeys = HotkeyManager()
    private let pill = StatusPillController()

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

    var isRecording: Bool { phase == .recording }
    var canRecord: Bool { phase == .idle || phase == .done }

    private var didLaunch = false

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

        pill.onTapStop = { [weak self] in
            guard let self, self.currentMode != .window else { return }
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
                try await backend.prepare()
                self.phase = .idle
            } catch {
                self.phase = .error("model load failed: \(error.localizedDescription)")
            }
        }
    }

    private func installHotkeys() {
        hotkeys.install()
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

        Task {
            // Start capture BEFORE awaiting startStream: the capture
            // AsyncStream is unbounded-buffered, so any chunks produced while
            // startStream is still loading its streaming session accumulate
            // safely and get drained once feedTask starts — instead of being
            // lost, which used to clip the front of short utterances.
            let stream: AsyncStream<[Float]>
            do {
                stream = try capture.start()
            } catch {
                phase = .error(error.localizedDescription)
                if mode != .window {
                    pill.hide()
                    hotkeys.reset()
                }
                return
            }
            phase = .recording

            do {
                try await backend.startStream { [weak self] partial in
                    Task { @MainActor in
                        guard let self else { return }
                        self.rawTranscript = partial.displayText
                        if self.currentMode != .window {
                            self.pill.update(.listening(partial: partial.displayText))
                        }
                    }
                }
                feedTask = Task { [backend] in
                    var captured: [Float] = []
                    for await chunk in stream {
                        captured.append(contentsOf: chunk)
                        try? await backend.feed(samples: chunk)
                    }
                    return captured
                }
            } catch {
                phase = .error(error.localizedDescription)
                capture.stop()
                if mode != .window {
                    pill.hide()
                    hotkeys.reset()
                }
            }
        }
    }

    /// Escape pressed during a hands-free hotkey dictation: throw the audio
    /// away, insert nothing.
    private func cancelDictation() {
        guard isRecording else { return }
        phase = .idle
        capture.stop()
        pill.hide()
        Task {
            _ = await feedTask?.value
            feedTask = nil
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
        let audioSeconds = capture.capturedSeconds
        capture.stop()

        if mode != .window {
            pill.update(.cleaning)
        }

        Task {
            defer { isStopping = false }
            let captured = await feedTask?.value ?? []
            feedTask = nil
            do {
                let sttT0 = Date()
                var raw = TextNormalizer.normalizeSentenceSpacing(try await backend.finishStream())
                // stt_ms: time from stop-press to final text (streaming absorbed the rest).
                let sttMs = Int(Date().timeIntervalSince(sttT0) * 1000)
                _ = sttStart

                let rms = Self.rms(of: captured)
                if rms < Self.silenceRmsThreshold || captured.count < Self.minimumSamplesForTranscription {
                    FileHandle.standardError.write(Data("[stt] discarding near-silent/too-short capture (rms=\(rms), samples=\(captured.count))\n".utf8))
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
                                    rms: Double(rms), outcome: "discard_silence")
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
                                            outcome: "discard_low_confidence")
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
                                    outcome: "snippet")
                    return
                }

                let cleanResult = await router.clean(raw, context: capturedFocusContext)
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
                                outcome: loggedOutcome)
            } catch {
                phase = .error(error.localizedDescription)
                if mode != .window {
                    pill.hide()
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
