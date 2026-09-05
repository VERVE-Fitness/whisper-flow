import XCTest
@testable import WhisperFlow

private func voices(_ speakers: [MeetingVoices.Speaker]) -> MeetingVoices { MeetingVoices(speakers: speakers) }

private func speaker(_ id: String, seconds: Double = 10, matched: Bool = false,
                     email: String? = nil, name: String? = nil, sampleFile: String? = nil) -> MeetingVoices.Speaker {
    MeetingVoices.Speaker(speakerId: id, seconds: seconds, embedding: [1, 0],
                          email: email, name: name, matched: matched, sampleFile: sampleFile)
}

private func meetingRecord(trackA: Double = 100, trackB: Double = 98, names: [String: String] = [:]) -> MeetingRecord {
    MeetingRecord(id: "2026-09-05-1432-3fa9c2d1",
                  startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                  endedAt: Date(timeIntervalSince1970: 1_800_001_770),
                  title: "Nathan 1:1", attendees: ["Nathan Hall"],
                  consent: MeetingConsent(confirmedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                          wordingVersion: "consent-v2"),
                  status: .transcribed, failureReason: nil,
                  trackASeconds: trackA, trackBSeconds: trackB, trackBOffsetSeconds: 1.05,
                  speakerNames: names)
}

final class UploadPlanTests: XCTestCase {
    func testPlannedFilesAreAudioThenClipsThenJSON() {
        let plan = MeetingUploader.plannedFiles(
            record: meetingRecord(),
            voices: voices([speaker("owner", matched: true),
                            speaker("S1", matched: true),
                            speaker("S2", sampleFile: "speaker-S2.m4a"),
                            speaker("S3", sampleFile: "speaker-S3.m4a")]))
        XCTAssertEqual(plan, ["track-a.m4a", "track-b.m4a", "speaker-S2.m4a", "speaker-S3.m4a",
                              "transcript.json", "meeting.json"])
    }

    /// A meeting recorded on a Mac with no system tap has no track B, and
    /// nothing must try to upload an empty file.
    func testMissingTrackBIsNotPlanned() {
        let plan = MeetingUploader.plannedFiles(record: meetingRecord(trackB: 0), voices: voices([speaker("owner", matched: true)]))
        XCTAssertEqual(plan, ["track-a.m4a", "transcript.json", "meeting.json"])
    }

    func testEveryPlannedNameIsOnTheServerAllowList() {
        let plan = MeetingUploader.plannedFiles(
            record: meetingRecord(), voices: voices([speaker("S2", sampleFile: "speaker-S2.m4a")]))
        let allowed = try! NSRegularExpression(pattern: "^(track-a\\.m4a|track-b\\.m4a|speaker-S[0-9]+\\.m4a|transcript\\.json|meeting\\.json)$")
        for name in plan {
            let range = NSRange(name.startIndex..., in: name)
            XCTAssertNotNil(allowed.firstMatch(in: name, range: range), "\(name) is not an accepted upload name")
        }
    }
}

final class UploadResumeTests: XCTestCase {
    private let plan = ["track-a.m4a", "track-b.m4a", "speaker-S2.m4a", "transcript.json", "meeting.json"]

    func testNoStateMeansSendEverything() {
        XCTAssertEqual(MeetingUploader.remainingFiles(planned: plan, state: nil), plan)
    }

    func testResumeSkipsWhatIsAlreadyUpAndKeepsTheOrder() {
        let state = UploadState(phase: .pending, files: ["track-a.m4a", "speaker-S2.m4a"])
        XCTAssertEqual(MeetingUploader.remainingFiles(planned: plan, state: state),
                       ["track-b.m4a", "transcript.json", "meeting.json"])
    }

    func testAFailedUploadStillResumesFromWhereItStopped() {
        let state = UploadState(phase: .failed, files: ["track-a.m4a"], error: "offline")
        XCTAssertEqual(MeetingUploader.remainingFiles(planned: plan, state: state),
                       ["track-b.m4a", "speaker-S2.m4a", "transcript.json", "meeting.json"])
        XCTAssertTrue(MeetingUploader.shouldResume(state))
    }

    func testACompletedUploadSendsNothingAndIsNotResumed() {
        let state = UploadState(phase: .complete, files: plan)
        XCTAssertEqual(MeetingUploader.remainingFiles(planned: plan, state: state), [])
        XCTAssertFalse(MeetingUploader.shouldResume(state))
        XCTAssertFalse(MeetingUploader.shouldResume(nil))
    }

    /// A file that was uploaded and then dropped from the plan (the clip was
    /// re-cut, say) must not reappear as work to do.
    func testUnknownFilesInTheStateAreIgnored() {
        let state = UploadState(phase: .pending, files: ["speaker-S9.m4a"])
        XCTAssertEqual(MeetingUploader.remainingFiles(planned: plan, state: state), plan)
    }
}

final class UploadStateFileTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MeetingStore.rootOverride = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-state-\(UUID().uuidString)")
    }
    override func tearDown() {
        if let root = MeetingStore.rootOverride { try? FileManager.default.removeItem(at: root) }
        MeetingStore.rootOverride = nil
        super.tearDown()
    }

    func testStateRoundTripsAndPendingMeetingsAreFound() throws {
        let rec = meetingRecord()
        try MeetingStore.save(rec)
        XCTAssertNil(MeetingUploader.readState(meetingID: rec.id))
        XCTAssertEqual(MeetingUploader.pendingMeetingIDs(), [])

        MeetingUploader.writeState(UploadState(phase: .pending, files: ["track-a.m4a"]), meetingID: rec.id)
        let back = try XCTUnwrap(MeetingUploader.readState(meetingID: rec.id))
        XCTAssertEqual(back.phase, .pending)
        XCTAssertEqual(back.files, ["track-a.m4a"])
        XCTAssertEqual(MeetingUploader.pendingMeetingIDs(), [rec.id])

        MeetingUploader.writeState(UploadState(phase: .complete, files: ["track-a.m4a"]), meetingID: rec.id)
        XCTAssertEqual(MeetingUploader.pendingMeetingIDs(), [])
        XCTAssertEqual(MeetingStore.uploadStateURL(rec.id).lastPathComponent, "upload-state.json")
    }
}

final class ManifestBuildingTests: XCTestCase {
    private let transcript = Transcript(meetingID: "2026-09-05-1432-3fa9c2d1", segments: [
        TranscriptSegment(speakerId: "owner", start: 0.4, end: 3.9, text: "Morning Nathan."),
        TranscriptSegment(speakerId: "S1", start: 4.2, end: 6.0, text: "Morning."),
    ], speakerNames: ["owner": "Niall Wogan", "S1": "Nathan Hall"])

    /// The owner is "owner" in the folder and "A" on the wire.
    func testOwnerBecomesSpeakerAOnTheWire() {
        XCTAssertEqual(MeetingUploader.wireSpeakerId("owner"), "A")
        XCTAssertEqual(MeetingUploader.wireSpeakerId("S1"), "S1")
        XCTAssertEqual(MeetingUploader.wireSpeakerId("speaker_unknown"), "speaker_unknown")

        let manifest = MeetingUploader.buildManifest(
            record: meetingRecord(), transcript: transcript,
            voices: voices([speaker("owner", matched: true, email: "niall.wogan@vervefitness.com.au", name: "Niall Wogan"),
                            speaker("S1", matched: true, email: "nathan.hall@vervefitness.com.au", name: "Nathan Hall")]))
        XCTAssertEqual(manifest.speakers.map(\.speakerId), ["A", "S1"])
        XCTAssertEqual(manifest.segments.map(\.speakerId), ["A", "S1"])
        XCTAssertEqual(manifest.consent.wordingVersion, "consent-v2")
        XCTAssertEqual(manifest.trackBOffsetSeconds, 1.05, accuracy: 1e-9)
        XCTAssertEqual(manifest.attendees, ["Nathan Hall"])
    }

    /// "Speaker 2" is a placeholder this app invented. The server numbers
    /// unnamed speakers itself, in first speech order, and two numbering
    /// schemes would disagree.
    func testPlaceholderNamesAreNotSent() {
        XCTAssertTrue(MeetingUploader.isPlaceholderName("Speaker 2"))
        XCTAssertTrue(MeetingUploader.isPlaceholderName(""))
        XCTAssertTrue(MeetingUploader.isPlaceholderName(nil))
        XCTAssertFalse(MeetingUploader.isPlaceholderName("Nathan Hall"))
        XCTAssertFalse(MeetingUploader.isPlaceholderName("Speaker Systems"))

        let manifest = MeetingUploader.buildManifest(
            record: meetingRecord(), transcript: transcript,
            voices: voices([speaker("S1", name: "Speaker 2"), speaker("S2", name: "Damian")]))
        XCTAssertNil(manifest.speakers[0].name)
        XCTAssertEqual(manifest.speakers[1].name, "Damian")
    }

    /// A word the diariser could not place carries "speaker_unknown". The
    /// server keeps only segments whose speaker is in the speakers list, so an
    /// unplaced segment is handed to the speaker who spoke just before it, and
    /// to the first known speaker when it comes before anyone known.
    func testUnplacedWordsGoToTheNeighbouringSpeaker() {
        let interrupted = Transcript(meetingID: "2026-09-05-1432-3fa9c2d1", segments: [
            TranscriptSegment(speakerId: "owner", start: 0.4, end: 3.9, text: "Morning Nathan."),
            TranscriptSegment(speakerId: "speaker_unknown", start: 4.0, end: 4.1, text: "yeah"),
            TranscriptSegment(speakerId: "S1", start: 4.2, end: 6.0, text: "Morning."),
        ], speakerNames: ["owner": "Niall Wogan", "S1": "Nathan Hall"])
        let known = voices([speaker("owner", matched: true, email: "niall.wogan@vervefitness.com.au", name: "Niall Wogan"),
                            speaker("S1", matched: true, email: "nathan.hall@vervefitness.com.au", name: "Nathan Hall")])

        let manifest = MeetingUploader.buildManifest(record: meetingRecord(), transcript: interrupted, voices: known)
        XCTAssertEqual(manifest.segments.count, 3)
        XCTAssertEqual(manifest.segments.map(\.speakerId), ["A", "A", "S1"])
        XCTAssertEqual(manifest.segments.map(\.text), ["Morning Nathan.", "yeah", "Morning."])
        let onTheWire = Set(manifest.speakers.map(\.speakerId))
        XCTAssertTrue(manifest.segments.allSatisfy { onTheWire.contains($0.speakerId) })

        // Nobody has spoken yet, so the first known speaker takes it.
        let opensUnknown = Transcript(meetingID: "2026-09-05-1432-3fa9c2d1", segments: [
            TranscriptSegment(speakerId: "speaker_unknown", start: 0.1, end: 0.3, text: "so"),
            TranscriptSegment(speakerId: "S1", start: 0.4, end: 2.0, text: "Morning."),
        ], speakerNames: ["S1": "Nathan Hall"])
        let opening = MeetingUploader.buildManifest(record: meetingRecord(), transcript: opensUnknown, voices: known)
        XCTAssertEqual(opening.segments.map(\.speakerId), ["S1", "S1"])
        XCTAssertEqual(opening.segments.map(\.text), ["so", "Morning."])
    }

    func testManifestRoundTripsThroughTheFileTheResumeReads() throws {
        let manifest = MeetingUploader.buildManifest(
            record: meetingRecord(), transcript: transcript,
            voices: voices([speaker("owner", matched: true, email: "niall.wogan@vervefitness.com.au", name: "Niall Wogan"),
                            speaker("S2", sampleFile: "speaker-S2.m4a")]))
        let data = try FlowClient.encodeManifest(manifest)
        let back = try MeetingUploader.decodeManifest(data)
        XCTAssertEqual(back, manifest)
        XCTAssertEqual(back.speakers[1].sampleFile, "speaker-S2.m4a")
        XCTAssertFalse(back.speakers[1].matched)
    }
}

final class SpeakerMatchingTests: XCTestCase {
    private func unit(_ v: [Float]) -> [Float] {
        let m = v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return v.map { $0 / m }
    }

    func testMatchedSpeakersCarryTheProfileEmailAndUnmatchedCarryNothing() {
        let nathan = unit([0, 1, 0, 0])
        let stranger = unit([0, 0, 1, 0])
        let profiles = [FlowVoiceProfile(email: "nathan.hall@vervefitness.com.au", name: "Nathan Hall", embedding: nathan)]
        let chunks = [
            SpeakerChunk(speakerId: "owner", start: 0, end: 30, embedding: unit([1, 0, 0, 0])),
            SpeakerChunk(speakerId: "S1", start: 5, end: 25, embedding: nathan),
            SpeakerChunk(speakerId: "S2", start: 26, end: 40, embedding: stranger),
        ]
        let me = FlowMe(email: "niall.wogan@vervefitness.com.au", name: "Niall Wogan",
                        recogniseMe: true, profiles: profiles, staff: [])
        let result = MeetingUploader.matchSpeakers(chunks: chunks, profiles: profiles, owner: me, typedNames: [:])

        let owner = result.speakers.first { $0.speakerId == "owner" }
        XCTAssertEqual(owner?.email, "niall.wogan@vervefitness.com.au")
        XCTAssertEqual(owner?.name, "Niall Wogan")
        XCTAssertTrue(owner?.matched == true)
        XCTAssertEqual(owner?.seconds, 30)

        let s1 = result.speakers.first { $0.speakerId == "S1" }
        XCTAssertTrue(s1?.matched == true)
        XCTAssertEqual(s1?.email, "nathan.hall@vervefitness.com.au")

        // Nobody the app cannot place is guessed at, and a stranger never
        // gets an email attached to them.
        let s2 = result.speakers.first { $0.speakerId == "S2" }
        XCTAssertTrue(s2?.matched == false)
        XCTAssertNil(s2?.email)
        XCTAssertNil(s2?.name)
    }

    func testATypedNameSurvivesAFailedMatchButAPlaceholderDoesNot() {
        let chunks = [SpeakerChunk(speakerId: "S1", start: 0, end: 10, embedding: unit([1, 0, 0, 0])),
                      SpeakerChunk(speakerId: "S2", start: 10, end: 20, embedding: unit([0, 1, 0, 0]))]
        let result = MeetingUploader.matchSpeakers(chunks: chunks, profiles: [], owner: nil,
                                                   typedNames: ["S1": "Damian", "S2": "Speaker 3"])
        XCTAssertEqual(result.speakers.first { $0.speakerId == "S1" }?.name, "Damian")
        XCTAssertNil(result.speakers.first { $0.speakerId == "S2" }?.name)
        XCTAssertTrue(result.speakers.allSatisfy { !$0.matched })
    }
}

final class UploadProgressCopyTests: XCTestCase {
    /// The words on the pill. Changing them is a product decision, so they
    /// are pinned here.
    func testPillCopy() {
        XCTAssertEqual(MeetingUploader.Progress.uploading(index: 2, total: 5).text, "Uploading 2 of 5")
        XCTAssertEqual(MeetingUploader.Progress.summarising.text, "Summarising in Flow")
        XCTAssertEqual(MeetingUploader.Progress.done.text, "Done, open in Flow")
        XCTAssertEqual(MeetingUploader.Progress.failedWillRetry.text, "Upload failed, will retry")
    }
}
