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
