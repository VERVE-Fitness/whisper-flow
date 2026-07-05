import Foundation
import SwiftUI
import AppKit

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

    @Published var phase: Phase = .loadingModels
    @Published var rawTranscript: String = ""
    @Published var cleanedTranscript: String = ""
    @Published var cleanupBackendName: String = "…"
    @Published var lastSttMs: Int?
    @Published var lastCleanupMs: Int?

    private let backend: TranscriptionBackend = ParakeetBackend()
    private let router = CleanupRouter()
    private let capture = AudioCapture()
    private var feedTask: Task<Void, Never>?
    private var recordStart: Date?

    var isRecording: Bool { phase == .recording }
    var canRecord: Bool { phase == .idle || phase == .done }

    func onLaunch() {
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

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        guard canRecord else { return }
        rawTranscript = ""
        cleanedTranscript = ""
        lastSttMs = nil
        lastCleanupMs = nil
        recordStart = Date()

        Task {
            do {
                try await backend.startStream { [weak self] partial in
                    Task { @MainActor in
                        self?.rawTranscript = partial.displayText
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
            }
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        phase = .cleaning
        let sttStart = recordStart ?? Date()
        let audioSeconds = capture.capturedSeconds
        capture.stop()

        Task {
            await feedTask?.value
            feedTask = nil
            do {
                let sttT0 = Date()
                let raw = try await backend.finishStream()
                // stt_ms: time from stop-press to final text (streaming absorbed the rest).
                let sttMs = Int(Date().timeIntervalSince(sttT0) * 1000)
                _ = sttStart
                rawTranscript = raw

                let result = await router.clean(raw)
                cleanedTranscript = result.text
                cleanupBackendName = result.backendName
                lastSttMs = sttMs
                lastCleanupMs = result.durationMs
                phase = .done

                UsageLog.append(mode: "mic",
                                audioSeconds: audioSeconds,
                                rawChars: raw.count,
                                cleanedChars: result.text.count,
                                sttMs: sttMs,
                                cleanupMs: result.durationMs,
                                cleanupBackend: result.backendName + (result.fellBackToRaw ? " (fallback-to-raw)" : ""))
            } catch {
                phase = .error(error.localizedDescription)
            }
        }
    }

    func copyCleaned() {
        let text = cleanedTranscript.isEmpty ? rawTranscript : cleanedTranscript
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
