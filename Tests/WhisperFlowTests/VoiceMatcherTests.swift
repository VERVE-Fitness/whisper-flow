import XCTest
@testable import WhisperFlow

/// Vectors are built by hand so the distances are known before the test runs.
/// Everything here is 8-dim; the real embeddings are 256, and nothing in
/// VoiceMatcher cares about the width beyond the two sides agreeing.
private func unit(_ values: [Float]) -> [Float] {
    let m = values.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
    return values.map { $0 / m }
}

private let niall = unit([1, 0, 0, 0, 0, 0, 0, 0])
private let nathan = unit([0, 1, 0, 0, 0, 0, 0, 0])
/// Close to Nathan (distance well under 0.45) but not identical.
private let nathanAgain = unit([0.18, 1, 0, 0, 0, 0, 0, 0])
/// A voice that sits between two profiles: near both, clearly neither.
private let ambiguous = unit([0.72, 0.72, 0, 0, 0, 0, 0, 0])

private let profiles = [
    FlowVoiceProfile(email: "niall.wogan@vervefitness.com.au", name: "Niall Wogan", embedding: niall),
    FlowVoiceProfile(email: "nathan.hall@vervefitness.com.au", name: "Nathan Hall", embedding: nathan),
]

final class VoiceMatcherTests: XCTestCase {
    func testConstantsAreTheAgreedOnes() {
        XCTAssertEqual(VoiceMatcher.maxDistance, 0.45)
        XCTAssertEqual(VoiceMatcher.minMargin, 0.10)
    }

    func testMeanIsDurationWeightedAndUnitLength() throws {
        // 9 s of one direction against 1 s of another: the mean must sit
        // nearly on top of the long chunk, not halfway between the two.
        let chunks = [
            SpeakerChunk(speakerId: "S1", start: 0, end: 9, embedding: niall),
            SpeakerChunk(speakerId: "S1", start: 9, end: 10, embedding: nathan),
        ]
        let mean = try XCTUnwrap(VoiceMatcher.meanEmbedding(for: "S1", chunks: chunks))
        XCTAssertEqual(mean.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot(), 1.0, accuracy: 1e-5)
        XCTAssertEqual(mean[0] / mean[1], 9.0, accuracy: 1e-4)
        let unweighted = VoiceMatcher.meanEmbedding(for: "S1", chunks: [
            SpeakerChunk(speakerId: "S1", start: 0, end: 5, embedding: niall),
            SpeakerChunk(speakerId: "S1", start: 5, end: 10, embedding: nathan),
        ])
        XCTAssertEqual(try XCTUnwrap(unweighted)[0], try XCTUnwrap(unweighted)[1], accuracy: 1e-5)
    }

    func testMeanIgnoresOtherSpeakersAndEmptyInput() {
        let chunks = [
            SpeakerChunk(speakerId: "S1", start: 0, end: 5, embedding: niall),
            SpeakerChunk(speakerId: "S2", start: 5, end: 9, embedding: nathan),
        ]
        let mean = VoiceMatcher.meanEmbedding(for: "S1", chunks: chunks)
        XCTAssertEqual(mean?[0], 1.0)
        XCTAssertEqual(mean?[1], 0.0)
        XCTAssertNil(VoiceMatcher.meanEmbedding(for: "S3", chunks: chunks))
        XCTAssertNil(VoiceMatcher.meanEmbedding(for: "S1", chunks: []))
    }

    func testMatchesTheNearProfile() throws {
        let match = try XCTUnwrap(VoiceMatcher.match(embedding: nathanAgain, profiles: profiles))
        XCTAssertEqual(match.email, "nathan.hall@vervefitness.com.au")
        XCTAssertEqual(match.name, "Nathan Hall")
        XCTAssertLessThan(match.distance, VoiceMatcher.maxDistance)
        XCTAssertGreaterThan(try XCTUnwrap(match.runnerUp) - match.distance, VoiceMatcher.minMargin)
    }

    /// Nobody in the room is in the profile list: nothing is guessed.
    func testNoMatchWhenEverythingIsTooFar() {
        let stranger = unit([0, 0, 1, 0, 0, 0, 0, 0])
        XCTAssertNil(VoiceMatcher.match(embedding: stranger, profiles: profiles))
    }

    /// Near two profiles at once is a question for a human, not a coin toss.
    func testNoMatchWhenTheMarginIsTooThin() {
        let ranking = VoiceMatcher.ranking(embedding: ambiguous, profiles: profiles)
        XCTAssertLessThan(ranking[0].distance, VoiceMatcher.maxDistance)
        XCTAssertLessThan(ranking[1].distance - ranking[0].distance, VoiceMatcher.minMargin)
        XCTAssertNil(VoiceMatcher.match(embedding: ambiguous, profiles: profiles))
    }

    func testSingleProfileNeedsNoMarginButStillNeedsToBeClose() throws {
        let one = [profiles[1]]
        let match = try XCTUnwrap(VoiceMatcher.match(embedding: nathanAgain, profiles: one))
        XCTAssertEqual(match.email, "nathan.hall@vervefitness.com.au")
        XCTAssertNil(match.runnerUp)
        XCTAssertNil(VoiceMatcher.match(embedding: unit([0, 0, 1, 0, 0, 0, 0, 0]), profiles: one))
    }

    func testNoProfilesAndMismatchedWidthsMatchNothing() {
        XCTAssertNil(VoiceMatcher.match(embedding: nathanAgain, profiles: []))
        let wrongWidth = [FlowVoiceProfile(email: "x@y", name: "X", embedding: [1, 0, 0])]
        XCTAssertNil(VoiceMatcher.match(embedding: nathanAgain, profiles: wrongWidth))
        XCTAssertNil(VoiceMatcher.match(embedding: [], profiles: profiles))
    }

    func testSecondsAndFirstSpeechOrder() {
        let chunks = [
            SpeakerChunk(speakerId: "S2", start: 4, end: 9, embedding: niall),
            SpeakerChunk(speakerId: "S1", start: 0, end: 3, embedding: nathan),
            SpeakerChunk(speakerId: "S1", start: 10, end: 12, embedding: nathan),
        ]
        XCTAssertEqual(VoiceMatcher.seconds(for: "S1", chunks: chunks), 5, accuracy: 1e-9)
        XCTAssertEqual(VoiceMatcher.seconds(for: "S2", chunks: chunks), 5, accuracy: 1e-9)
        XCTAssertEqual(VoiceMatcher.speakerIds(in: chunks), ["S1", "S2"])
    }

    /// Track A is one person; the dominant cluster is the owner's voice.
    func testDominantSpeakerIsTheOneWithTheMostSpeech() {
        let chunks = [
            SpeakerChunk(speakerId: "S1", start: 0, end: 40, embedding: niall),
            SpeakerChunk(speakerId: "S2", start: 40, end: 43, embedding: nathan),
        ]
        XCTAssertEqual(VoiceMatcher.dominantSpeaker(in: chunks), "S1")
        XCTAssertNil(VoiceMatcher.dominantSpeaker(in: []))
    }

    func testShortEmailKeepsTheNameAndDropsTheDomain() {
        XCTAssertEqual(VoiceMatcher.shortEmail("nathan.hall@vervefitness.com.au"), "nathan.hall@\u{2026}")
        XCTAssertEqual(VoiceMatcher.shortEmail("no-at-sign"), "no-at-sign")
    }
}

final class VoiceProfileCacheTests: XCTestCase {
    override func setUp() {
        super.setUp()
        VoiceProfileCache.urlOverride = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-profiles-\(UUID().uuidString).json")
    }
    override func tearDown() {
        if let url = VoiceProfileCache.urlOverride { try? FileManager.default.removeItem(at: url) }
        VoiceProfileCache.urlOverride = nil
        super.tearDown()
    }

    func testMissingFileIsAnEmptyListNotAFailure() {
        XCTAssertEqual(VoiceProfileCache.load(), [])
    }

    func testRoundTrip() {
        VoiceProfileCache.save(profiles)
        XCTAssertEqual(VoiceProfileCache.load(), profiles)
        VoiceProfileCache.save([])
        XCTAssertEqual(VoiceProfileCache.load(), [])
    }
}
