import Foundation

/// A partial (in-progress) transcription update emitted during streaming.
struct TranscriptionPartial: Sendable {
    /// Text confirmed so far (stable, will not change).
    let confirmedText: String
    /// Volatile tail that may still be revised by the decoder.
    let volatileText: String

    var displayText: String {
        volatileText.isEmpty ? confirmedText : (confirmedText.isEmpty ? volatileText : confirmedText + " " + volatileText)
    }
}

enum TranscriptionError: Error, LocalizedError {
    case notImplemented(String)
    case notPrepared
    case fileLoadFailed(String)

    var errorDescription: String? {
        switch self {
        case .notImplemented(let name): return "\(name) backend is not implemented yet"
        case .notPrepared: return "Transcription backend not prepared (models not loaded)"
        case .fileLoadFailed(let why): return "Could not load audio file: \(why)"
        }
    }
}

/// Streaming speech-to-text backend.
///
/// Lifecycle: `prepare()` once (downloads/loads models), then per dictation:
/// `startStream(onPartial:)` -> repeated `feed(samples:)` of 16 kHz mono Float32
/// -> `finishStream()` returns the final transcript.
///
/// Batch: `transcribeFile(samples:)` for offline/CLI use.
///
/// Designed so a Whisper wrapper (which has no native streaming) can conform by
/// buffering fed samples and committing chunks on an internal timer.
protocol TranscriptionBackend: AnyObject {
    var name: String { get }
    var isPrepared: Bool { get }

    /// Load (and if needed download) models. Idempotent.
    func prepare() async throws

    /// Begin a streaming session. `onPartial` is called as hypotheses update.
    func startStream(onPartial: @escaping @Sendable (TranscriptionPartial) -> Void) async throws

    /// Feed a chunk of 16 kHz mono Float32 samples into the live stream.
    func feed(samples: [Float]) async throws

    /// End the stream and return the final transcript.
    func finishStream() async throws -> String

    /// Batch-transcribe a complete buffer of 16 kHz mono Float32 samples.
    func transcribeFile(samples: [Float]) async throws -> String

    /// Batch-transcribe a complete buffer, also returning the backend's own
    /// per-utterance confidence score so callers can gate on it (used to
    /// re-check short/clipped streaming dictations against the more accurate
    /// full-clip batch path). Confidence scale is backend-defined; FluidAudio's
    /// Parakeet ranges ~0.1 (empty/near-silent) to 1.0 (fully confident).
    func transcribeFileWithConfidence(samples: [Float]) async throws -> (text: String, confidence: Float)
}
