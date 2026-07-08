import Foundation

/// Placeholder Whisper backend proving the `TranscriptionBackend` protocol is
/// swappable. A real implementation would wrap whisper.cpp / WhisperKit with a
/// buffer+commit strategy (accumulate fed samples, transcribe committed windows,
/// emit the moving tail as volatile text).
final class WhisperBackend: TranscriptionBackend {
    let name = "whisper"
    private(set) var isPrepared = false

    func prepare() async throws {
        throw TranscriptionError.notImplemented(name)
    }

    func startStream(onPartial: @escaping @Sendable (TranscriptionPartial) -> Void) async throws {
        throw TranscriptionError.notImplemented(name)
    }

    func feed(samples: [Float]) async throws {
        throw TranscriptionError.notImplemented(name)
    }

    func finishStream() async throws -> String {
        throw TranscriptionError.notImplemented(name)
    }

    func transcribeFile(samples: [Float]) async throws -> String {
        throw TranscriptionError.notImplemented(name)
    }

    func transcribeFileWithConfidence(samples: [Float]) async throws -> (text: String, confidence: Float) {
        throw TranscriptionError.notImplemented(name)
    }
}
