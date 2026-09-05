import XCTest
@testable import WhisperFlow

private func chunk(_ id: String, _ start: Double, _ end: Double) -> SpeakerChunk {
    SpeakerChunk(speakerId: id, start: start, end: end, embedding: [1, 0])
}

final class SampleClipExporterSpanTests: XCTestCase {
    func testPicksTheLongestRunAndCapsItAtEightSeconds() throws {
        let chunks = [chunk("S2", 0, 3),          // 3 s
                      chunk("S2", 20, 40),        // 20 s, capped to 8
                      chunk("S1", 4, 19)]
        let span = try XCTUnwrap(SampleClipExporter.bestSpan(for: "S2", chunks: chunks))
        XCTAssertEqual(span.start, 20)
        XCTAssertEqual(span.end, 28)
        XCTAssertEqual(span.seconds, 8)
    }

    /// The diariser breaks a sentence at a breath; a clip that stops at the
    /// breath is half a word, so near-adjacent stretches are one run.
    func testJoinsStretchesSeparatedByLessThanTheJoinGap() throws {
        let chunks = [chunk("S2", 0, 2.4), chunk("S2", 2.8, 5.2), chunk("S2", 12, 13)]
        let span = try XCTUnwrap(SampleClipExporter.bestSpan(for: "S2", chunks: chunks))
        XCTAssertEqual(span.start, 0)
        XCTAssertEqual(span.end, 5.2, accuracy: 1e-9)
    }

    func testDoesNotJoinAcrossARealSilence() throws {
        let chunks = [chunk("S2", 0, 2.5), chunk("S2", 10, 15)]
        let span = try XCTUnwrap(SampleClipExporter.bestSpan(for: "S2", chunks: chunks))
        XCTAssertEqual(span.start, 10)
        XCTAssertEqual(span.end, 15)
    }

    /// Someone who said two words gets no clip; the confirmer reads the
    /// transcript line instead of listening to a cough.
    func testTooShortMeansNoClip() {
        XCTAssertNil(SampleClipExporter.bestSpan(for: "S3", chunks: [chunk("S3", 0, 1.2), chunk("S3", 30, 31.4)]))
        XCTAssertNil(SampleClipExporter.bestSpan(for: "S3", chunks: []))
        XCTAssertNil(SampleClipExporter.bestSpan(for: "S9", chunks: [chunk("S2", 0, 30)]))
    }

    func testExactlyTheMinimumIsKept() throws {
        let span = try XCTUnwrap(SampleClipExporter.bestSpan(for: "S2", chunks: [chunk("S2", 5, 7)]))
        XCTAssertEqual(span.seconds, 2)
    }

    func testOverlappingChunksExtendRatherThanShorten() throws {
        let chunks = [chunk("S2", 0, 6), chunk("S2", 2, 4), chunk("S2", 3, 9)]
        let span = try XCTUnwrap(SampleClipExporter.bestSpan(for: "S2", chunks: chunks))
        XCTAssertEqual(span.start, 0)
        XCTAssertEqual(span.end, 8)
    }

    func testFileNameMatchesTheUploadAllowList() {
        XCTAssertEqual(SampleClipExporter.fileName(for: "S2"), "speaker-S2.m4a")
        XCTAssertEqual(SampleClipExporter.fileName(for: "S11"), "speaker-S11.m4a")
    }
}

final class SampleClipExporterFileTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MeetingStore.rootOverride = FileManager.default.temporaryDirectory
            .appendingPathComponent("clips-\(UUID().uuidString)")
    }
    override func tearDown() {
        if let root = MeetingStore.rootOverride { try? FileManager.default.removeItem(at: root) }
        MeetingStore.rootOverride = nil
        super.tearDown()
    }

    func testExportsTheClipOutOfTrackB() throws {
        let id = "2026-09-05-1432-3fa9c2d1"
        try FileManager.default.createDirectory(at: MeetingStore.directory(for: id), withIntermediateDirectories: true)
        let writer = try TrackWriter(url: MeetingStore.trackBURL(id))
        let frames = Int(20 * AudioCapture.targetSampleRate)
        var i = 0
        while i < frames {
            let take = min(8_000, frames - i)
            try writer.append((0..<take).map { j in
                Float(sin(2 * .pi * 440 * Double(i + j) / AudioCapture.targetSampleRate)) * 0.5
            })
            i += take
        }
        writer.close()

        let name = try XCTUnwrap(SampleClipExporter.exportClip(meetingID: id, speakerId: "S2",
                                                              chunks: [chunk("S2", 4, 18)]))
        XCTAssertEqual(name, "speaker-S2.m4a")
        let clip = MeetingStore.directory(for: id).appendingPathComponent(name)
        XCTAssertEqual(try AudioEncoder.duration(of: clip), 8.0, accuracy: 0.2)
    }

    func testShortSpeakerGetsNoFile() throws {
        let id = "2026-09-05-1500-aaaabbbb"
        try FileManager.default.createDirectory(at: MeetingStore.directory(for: id), withIntermediateDirectories: true)
        XCTAssertNil(SampleClipExporter.exportClip(meetingID: id, speakerId: "S4", chunks: [chunk("S4", 0, 1)]))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: MeetingStore.directory(for: id).appendingPathComponent("speaker-S4.m4a").path))
    }
}
