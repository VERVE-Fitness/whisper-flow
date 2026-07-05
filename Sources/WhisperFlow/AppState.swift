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

    private var feedTask: Task<Void, Never>?
    private var recordStart: Date?
    private var currentMode: DictationMode = .window
    private var accessibilityCancellable: AnyCancellable?

    var isRecording: Bool { phase == .recording }
    var canRecord: Bool { phase == .idle || phase == .done }

    private var didLaunch = false

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

        if mode != .window {
            pill.show(.listening(partial: ""))
        }

        Task {
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
                let stream = try capture.start()
                phase = .recording
                feedTask = Task { [backend] in
                    for await chunk in stream {
                        try? await backend.feed(samples: chunk)
                    }
                }
            } catch {
                phase = .error(error.localizedDescription)
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
            await feedTask?.value
            feedTask = nil
            _ = try? await backend.finishStream()
            rawTranscript = ""
            cleanedTranscript = ""
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        phase = .cleaning
        let mode = currentMode
        let sttStart = recordStart ?? Date()
        let audioSeconds = capture.capturedSeconds
        capture.stop()

        if mode != .window {
            pill.update(.cleaning)
        }

        Task {
            await feedTask?.value
            feedTask = nil
            do {
                let sttT0 = Date()
                let raw = TextNormalizer.normalizeSentenceSpacing(try await backend.finishStream())
                // stt_ms: time from stop-press to final text (streaming absorbed the rest).
                let sttMs = Int(Date().timeIntervalSince(sttT0) * 1000)
                _ = sttStart
                rawTranscript = raw

                let cleanResult = await router.clean(raw)
                let cleanedText = TextNormalizer.normalizeSentenceSpacing(cleanResult.text)
                cleanedTranscript = cleanedText
                cleanupBackendName = cleanResult.backendName
                lastSttMs = sttMs
                lastCleanupMs = cleanResult.durationMs
                phase = .done

                let backendLogName = cleanResult.backendName + (cleanResult.fellBackToRaw ? " (fallback-to-raw)" : "")

                if mode != .window {
                    let outcome = TextInserter.insert(cleanedText, accessibilityTrusted: accessibility.isTrusted)
                    switch outcome {
                    case .inserted:
                        pill.show(.inserted)
                    case .copiedOnly:
                        pill.show(.copiedOnly)
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
                                cleanedText: cleanedText)
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

    func copyCleaned() {
        let text = cleanedTranscript.isEmpty ? rawTranscript : cleanedTranscript
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
