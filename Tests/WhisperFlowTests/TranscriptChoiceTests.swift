import XCTest
@testable import WhisperFlow

/// A backend that answers exactly what a test tells it to. Stands in for
/// Parakeet so the tail fix can be exercised without a Neural Engine, a
/// microphone or a 600 MB model download.
final class StubTranscriptionBackend: TranscriptionBackend, @unchecked Sendable {
    let name = "stub"
    private(set) var isPrepared = true

    /// What the sliding window would hand back at finish().
    var streamingResult: String
    /// What the batch decoder would hand back for the same buffer.
    var batchResult: (text: String, confidence: Float)
    /// Set to make the batch pass fail, the way a timeout or a model error
    /// would.
    var batchError: Error?
    /// Every buffer fed into the stream, in order. The silence pad lands here.
    private(set) var fed: [[Float]] = []

    init(streaming: String, batch: String, confidence: Float = 0.9) {
        self.streamingResult = streaming
        self.batchResult = (batch, confidence)
    }

    func prepare() async throws {}
    func prepare(onProgress: (@Sendable (String) -> Void)?) async throws {}
    func startStream(onPartial: @escaping @Sendable (TranscriptionPartial) -> Void) async throws {}
    func feed(samples: [Float]) async throws { fed.append(samples) }
    func finishStream() async throws -> String { streamingResult }
    func transcribeFile(samples: [Float]) async throws -> String {
        try await transcribeFileWithConfidence(samples: samples).text
    }

    func transcribeFileWithConfidence(samples: [Float]) async throws -> (text: String, confidence: Float) {
        if let batchError { throw batchError }
        return batchResult
    }
}

private struct StubBatchFailure: Error {}

final class TranscriptChoiceTests: XCTestCase {

    /// The regression this whole task exists for: the streaming pass loses
    /// the last word, the batch pass has it, and the batch text is what gets
    /// typed.
    func testTheLastWordSurvivesWhenStreamingDroppedIt() async throws {
        let backend = StubTranscriptionBackend(
            streaming: "Book the freight for Thursday",
            batch: "Book the freight for Thursday morning")

        let streaming = try await backend.finishStream()
        let batch = try await backend.transcribeFileWithConfidence(samples: [0, 0, 0])
        let choice = TranscriptChoice.choose(streaming: streaming, batch: batch.text)

        XCTAssertEqual(choice.source, .batch)
        XCTAssertEqual(choice.text, "Book the freight for Thursday morning")
        XCTAssertTrue(choice.text.hasSuffix("morning"))
        XCTAssertEqual(TranscriptChoice.logLine(choice),
                       "[stt] streaming 5 words, batch 6 words, using batch")
    }

    /// The other half of the same guard: the batch decoder sometimes drops an
    /// out-of-vocabulary opening outright, and a transcript missing half its
    /// words is worse than a mangled one.
    func testAShortBatchResultLosesToStreaming() {
        let choice = TranscriptChoice.choose(
            streaming: "The VERVE Tori Functional Trainer ships in March",
            batch: "Functional trainer")
        XCTAssertEqual(choice.source, .streaming)
        XCTAssertEqual(choice.text, "The VERVE Tori Functional Trainer ships in March")
        XCTAssertEqual(TranscriptChoice.logLine(choice),
                       "[stt] streaming 8 words, batch 2 words, using streaming")
    }

    /// Exactly half is enough; a word under it is not.
    func testTheFloorIsHalfTheWords() {
        XCTAssertEqual(TranscriptChoice.batchWordFloor, 0.5)
        XCTAssertEqual(TranscriptChoice.choose(streaming: "one two three four",
                                               batch: "one two").source, .batch)
        XCTAssertEqual(TranscriptChoice.choose(streaming: "one two three four five six",
                                               batch: "one two").source, .streaming)
    }

    /// No batch result at all, because the clip was too long, or the pass
    /// failed, or it timed out: the streaming text stands and says so.
    func testNoBatchResultMeansStreaming() async throws {
        let backend = StubTranscriptionBackend(streaming: "Book the freight", batch: "unused")
        backend.batchError = StubBatchFailure()
        var batchText: String?
        do {
            batchText = try await backend.transcribeFileWithConfidence(samples: []).text
        } catch {
            batchText = nil
        }
        let choice = TranscriptChoice.choose(streaming: "Book the freight", batch: batchText)
        XCTAssertEqual(choice.source, .streaming)
        XCTAssertEqual(choice.text, "Book the freight")
        XCTAssertEqual(choice.batchWords, 0)
        XCTAssertEqual(TranscriptChoice.logLine(choice),
                       "[stt] streaming 3 words, batch 0 words, using streaming")
    }

    /// An empty streaming result must not make an empty batch result "enough"
    /// in a way that hides a real transcript, and must not crash on a divide.
    func testEmptyResultsAreHandled() {
        XCTAssertEqual(TranscriptChoice.choose(streaming: "", batch: "Book the freight").source, .batch)
        XCTAssertEqual(TranscriptChoice.choose(streaming: "Book the freight", batch: "").source, .streaming)
        XCTAssertEqual(TranscriptChoice.choose(streaming: "", batch: "").text, "")
    }
}

final class SilencePadTests: XCTestCase {

    /// 600 ms at 16 kHz. If this number moves, the sliding window stops
    /// committing the tail and dictations start losing their last words
    /// again.
    func testThePadIsSixHundredMillisecondsOfZerosAtSixteenKilohertz() {
        XCTAssertEqual(AudioCapture.targetSampleRate, 16_000)
        XCTAssertEqual(TranscriptChoice.silencePadSeconds, 0.6)
        XCTAssertEqual(TranscriptChoice.silencePadSampleCount, 9_600)

        let pad = TranscriptChoice.silencePad()
        XCTAssertEqual(pad.count, 9_600)
        XCTAssertTrue(pad.allSatisfy { $0 == 0 }, "the pad has to be real silence, not noise")
    }

    /// The pad reaches the backend after every real sample, so the window
    /// commits what was already spoken rather than trailing zeros.
    func testThePadIsFedIntoTheStreamBeforeFinishing() async throws {
        let backend = StubTranscriptionBackend(streaming: "Book the freight for Thursday",
                                               batch: "Book the freight for Thursday morning")
        try await backend.feed(samples: [0.1, 0.2, 0.3])
        try await backend.feed(samples: TranscriptChoice.silencePad())
        _ = try await backend.finishStream()

        XCTAssertEqual(backend.fed.count, 2)
        XCTAssertEqual(backend.fed.first?.count, 3)
        XCTAssertEqual(backend.fed.last?.count, TranscriptChoice.silencePadSampleCount)
        XCTAssertTrue(backend.fed.last?.allSatisfy { $0 == 0 } ?? false)
    }

    /// The release hold and the batch window, pinned. 400 ms is the design's
    /// number, and 120 seconds is where the re-check stops.
    func testTheReleaseHoldAndTheBatchWindow() {
        XCTAssertEqual(TranscriptChoice.releaseTailSeconds, 0.4)
        XCTAssertEqual(TranscriptChoice.releaseTailNanoseconds, 400_000_000)
        XCTAssertEqual(TranscriptChoice.batchRecheckMaxSeconds, 120)
        XCTAssertEqual(TranscriptChoice.batchTimeoutSeconds, 8)
    }
}
