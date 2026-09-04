import XCTest
@testable import WhisperFlow

final class TrackWriterTests: XCTestCase {
    func testWritesChunksReadableAs16kMono() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trackwriter-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try TrackWriter(url: url)
        // 1.5 s of a 440 Hz sine in three 0.5 s chunks
        let chunk = (0..<8_000).map { i in Float(sin(2 * .pi * 440 * Double(i) / 16_000)) * 0.5 }
        try writer.append(chunk)
        try writer.append(chunk)
        try writer.append(chunk)
        XCTAssertEqual(writer.framesWritten, 24_000)
        XCTAssertEqual(writer.seconds, 1.5, accuracy: 0.001)
        writer.close()

        let samples = try loadAudioFileAs16kMonoFloats(path: url.path)
        XCTAssertEqual(samples.count, 24_000)
        XCTAssertEqual(samples[100], chunk[100], accuracy: 1e-4)
    }

    func testCloseIsIdempotentAndAppendAfterCloseThrows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trackwriter-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try TrackWriter(url: url)
        try writer.append([0, 0, 0, 0])
        writer.close()
        writer.close()
        XCTAssertThrowsError(try writer.append([0]))
    }
}

final class MeetingStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MeetingStore.rootOverride = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetings-test-\(UUID().uuidString)")
    }
    override func tearDown() {
        if let root = MeetingStore.rootOverride { try? FileManager.default.removeItem(at: root) }
        MeetingStore.rootOverride = nil
        super.tearDown()
    }

    func testIDIsDateStampedAndUnique() {
        let date = ISO8601DateFormatter().date(from: "2026-09-05T14:32:00+10:00")!
        let a = MeetingStore.newMeetingID(at: date)
        let b = MeetingStore.newMeetingID(at: date)
        XCTAssertTrue(a.hasPrefix("2026-09-05-1432-"), a)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, "2026-09-05-1432-".count + 8)
    }

    func testSaveLoadRoundTripAndListNewestFirst() throws {
        let consent = MeetingConsent(confirmedAt: Date(timeIntervalSince1970: 1_800_000_000), wordingVersion: "consent-v1")
        var r1 = MeetingRecord(id: "2026-09-05-0900-aaaaaaaa", startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                               endedAt: nil, title: "Clayton lease", attendees: ["Nathan Hall"], consent: consent,
                               status: .recording, failureReason: nil, trackASeconds: 0, trackBSeconds: 0, speakerNames: [:])
        try MeetingStore.save(r1)
        r1.status = .recorded; r1.trackASeconds = 61.5
        try MeetingStore.save(r1)
        let r2 = MeetingRecord(id: "2026-09-05-1000-bbbbbbbb", startedAt: Date(timeIntervalSince1970: 1_800_003_600),
                               endedAt: nil, title: "", attendees: [], consent: consent,
                               status: .recording, failureReason: nil, trackASeconds: 0, trackBSeconds: 0, speakerNames: [:])
        try MeetingStore.save(r2)

        let loaded = try MeetingStore.load(id: r1.id)
        XCTAssertEqual(loaded, r1)
        XCTAssertEqual(MeetingStore.listIDs(), [r2.id, r1.id])
        XCTAssertEqual(MeetingStore.trackAURL(r1.id).lastPathComponent, "track-a.wav")
        XCTAssertEqual(MeetingStore.summaryURL(r1.id).lastPathComponent, "summary.md")
    }
}

final class ConsentGateTests: XCTestCase {
    func testWordingCarriesTheFourPromises() {
        let w = ConsentGate.wording(managerName: "Nathan Hall")
        XCTAssertEqual(ConsentGate.wordingVersion, "consent-v1")
        XCTAssertTrue(w.body.contains("Tell everyone on the call first"))
        XCTAssertTrue(w.body.contains("your manager, Nathan Hall, can play it back"))
        XCTAssertTrue(w.body.contains("deleted after 90 days"))
        XCTAssertTrue(w.body.contains("delete either at any time"))
        XCTAssertEqual(w.confirm, "I've told everyone and they're OK with it")
    }

    func testWordingWithoutManagerNameStillMentionsManager() {
        XCTAssertTrue(ConsentGate.wording(managerName: nil).body.contains("your manager can play it back"))
    }
}

final class TranscriptBuilderTests: XCTestCase {
    // Parakeet emits SentencePiece tokens: "▁" marks the start of a word.
    func testWordsGroupSentencePieceTokens() {
        let tokens: [(token: String, start: Double, end: Double)] = [
            ("▁The", 0.10, 0.20), ("▁Tor", 0.25, 0.35), ("i", 0.35, 0.40), ("▁trainer", 0.45, 0.80),
            (",", 0.80, 0.82), ("▁ships", 0.90, 1.10),
        ]
        let words = TranscriptBuilder.words(fromTokens: tokens)
        XCTAssertEqual(words.map(\.text), ["The", "Tori", "trainer,", "ships"])
        XCTAssertEqual(words[1].start, 0.25); XCTAssertEqual(words[1].end, 0.40)
    }

    func testSegmentsSplitOnSilenceGap() {
        let words = [TimedWord(text: "Hi", start: 0, end: 0.3), TimedWord(text: "Nathan", start: 0.35, end: 0.7),
                     TimedWord(text: "Next", start: 2.0, end: 2.3), TimedWord(text: "item", start: 2.35, end: 2.6)]
        let segs = TranscriptBuilder.segments(words: words, speakerId: "owner")
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].text, "Hi Nathan"); XCTAssertEqual(segs[0].start, 0); XCTAssertEqual(segs[0].end, 0.7)
        XCTAssertEqual(segs[1].text, "Next item"); XCTAssertEqual(segs[1].speakerId, "owner")
    }

    func testAssignWordsToSpeakerSpansByMidpointAndGroupTurns() {
        let words = [TimedWord(text: "Yes", start: 0.0, end: 0.3), TimedWord(text: "agreed", start: 0.4, end: 0.9),
                     TimedWord(text: "But", start: 3.0, end: 3.2), TimedWord(text: "when", start: 3.3, end: 3.6),
                     TimedWord(text: "Wednesday", start: 5.0, end: 5.6)]
        let spans = [SpeakerSpan(speakerId: "speaker_0", start: 0, end: 1.0),
                     SpeakerSpan(speakerId: "speaker_1", start: 2.8, end: 3.7),
                     SpeakerSpan(speakerId: "speaker_0", start: 4.9, end: 6.0)]
        let segs = TranscriptBuilder.assign(words: words, to: spans)
        XCTAssertEqual(segs.map(\.speakerId), ["speaker_0", "speaker_1", "speaker_0"])
        XCTAssertEqual(segs.map(\.text), ["Yes agreed", "But when", "Wednesday"])
    }

    func testAssignWordOutsideAnySpanGoesToNearestSpanWithinOneSecondElseUnknown() {
        let words = [TimedWord(text: "late", start: 1.2, end: 1.4), TimedWord(text: "lost", start: 9.0, end: 9.2)]
        let spans = [SpeakerSpan(speakerId: "speaker_0", start: 0, end: 1.0)]
        let segs = TranscriptBuilder.assign(words: words, to: spans)
        XCTAssertEqual(segs.map(\.speakerId), ["speaker_0", "speaker_unknown"])
    }

    func testMergeInterleavesByStartTime() {
        let a = [TranscriptSegment(speakerId: "owner", start: 0, end: 1, text: "Morning"),
                 TranscriptSegment(speakerId: "owner", start: 4, end: 5, text: "Wednesday works")]
        let b = [TranscriptSegment(speakerId: "speaker_0", start: 1.5, end: 3.5, text: "Can we do Wednesday")]
        let merged = TranscriptBuilder.merge(a, b)
        XCTAssertEqual(merged.map(\.text), ["Morning", "Can we do Wednesday", "Wednesday works"])
    }

    func testMarkdownUsesNamesAndTimestamps() {
        let t = Transcript(meetingID: "m", segments: [
            TranscriptSegment(speakerId: "owner", start: 0, end: 1, text: "Morning"),
            TranscriptSegment(speakerId: "speaker_0", start: 65.2, end: 67, text: "Can we do Wednesday"),
        ], speakerNames: ["owner": "Niall Wogan", "speaker_0": "Nathan Hall"])
        let md = TranscriptBuilder.markdown(t, title: "Clayton lease", startedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(md.hasPrefix("# Clayton lease"))
        XCTAssertTrue(md.contains("**[00:00] Niall Wogan:** Morning"))
        XCTAssertTrue(md.contains("**[01:05] Nathan Hall:** Can we do Wednesday"))
    }
}
