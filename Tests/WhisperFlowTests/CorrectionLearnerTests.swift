import XCTest
@testable import WhisperFlow

/// The run diff is the only part of auto-learn that can be tested without an
/// accessibility API and a live document, and it is the part that decides
/// what gets written into the lexicon and sent to Flow. Every guard has a
/// test, because a false positive here rewrites every future dictation.
final class CorrectionRunDiffTests: XCTestCase {
    private func diff(before: String, after: String, inserted: String? = nil) -> (from: String, to: String)? {
        CorrectionLearner.diffWordRunChange(before: before, after: after, inserted: inserted ?? before)
    }

    func testASingleWordCorrectionIsStillLearned() {
        let d = diff(before: "The tory rack ships Monday",
                     after: "The Tori rack ships Monday")
        XCTAssertEqual(d?.from, "tory")
        XCTAssertEqual(d?.to, "Tori")
    }

    /// The reason this changed: two words replaced by two words used to be
    /// two ambiguous diffs and was thrown away.
    func testATwoWordRunIsLearnedAsOneCorrection() {
        let d = diff(before: "we sell vervey pulls to gyms",
                     after: "we sell VERVE Pulse to gyms")
        XCTAssertEqual(d?.from, "vervey pulls")
        XCTAssertEqual(d?.to, "VERVE Pulse")
    }

    /// The run is the minimal one: a word both versions agree on is trimmed
    /// off the end rather than carried into the correction, so "vervey pulse"
    /// becoming "VERVE Pulse" is learned as the one word that actually
    /// changed.
    func testWordsBothVersionsAgreeOnAreTrimmedOffTheRun() {
        let d = diff(before: "we sell vervey pulse to gyms",
                     after: "we sell VERVE Pulse to gyms")
        XCTAssertEqual(d?.from, "vervey")
        XCTAssertEqual(d?.to, "VERVE")
    }

    /// Runs of different lengths on each side are the common case for a
    /// mishearing: one heard word is really two.
    func testTwoWordsBecomingOneAndOneBecomingTwoAreBothLearned() {
        XCTAssertEqual(diff(before: "the verve pulse dashboard", after: "the VERVEPulse dashboard")?.from,
                       "verve pulse")
        let split = diff(before: "the vervepulse dashboard", after: "the VERVE Pulse dashboard")
        XCTAssertEqual(split?.from, "vervepulse")
        XCTAssertEqual(split?.to, "VERVE Pulse")
    }

    func testARunLongerThanFourWordsIsARewriteAndIsIgnored() {
        XCTAssertEqual(CorrectionLearner.maximumRunWords, 4)
        XCTAssertNil(diff(before: "one two three four five six",
                          after: "One Two Three Four Five six"))
    }

    func testNothingIsLearnedWhenTheTextDidNotChange() {
        XCTAssertNil(diff(before: "The Tori rack", after: "The Tori rack"))
    }

    /// Somebody typing more of their own document is not correcting us.
    func testAPureInsertionOrDeletionIsNotACorrection() {
        XCTAssertNil(diff(before: "The Tori rack", after: "The Tori rack ships Monday"))
        XCTAssertNil(diff(before: "The Tori rack ships Monday", after: "The Tori rack"))
    }

    /// An edit to words we never inserted belongs to the person, not to us.
    func testOnlyWordsWeInsertedCanBeLearned() {
        XCTAssertNil(diff(before: "their tory rack", after: "their Tori rack", inserted: "rack"))
    }

    /// The proper-noun guard: a learned correction applies to every future
    /// dictation, and rewriting ordinary English forever is unrecoverable.
    func testALowerCaseReplacementIsNeverLearned() {
        XCTAssertNil(diff(before: "we were there today", after: "we were their today"))
        XCTAssertNil(diff(before: "the functional trainor", after: "the functional trainer"))
    }

    func testAllStopWordsOnTheHeardSideAreIgnored() {
        XCTAssertNil(diff(before: "and the rack", after: "And The rack"))
    }

    /// Replacing one idea with a different one is not a mishearing.
    func testAFarAwayReplacementIsNotAMishearing() {
        XCTAssertNil(diff(before: "we shipped the treadmill", after: "we shipped the Kettlebell"))
    }

    func testVeryShortRunsAreIgnored() {
        XCTAssertNil(diff(before: "the ab rack", after: "the Ab rack"))
    }
}

/// The suggestion half of the contract: the path, the method and the body
/// that Flow's `phrases/suggest` endpoint will read. Built against the
/// contract while the endpoint is being written, with a stubbed client, so
/// nothing here reaches the network or the keychain.
final class PhraseSuggestionClientTests: XCTestCase {
    private var savedServer: String?

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        savedServer = UserDefaults.standard.string(forKey: FlowClient.serverDefaultsKey)
        UserDefaults.standard.set("https://flow.test", forKey: FlowClient.serverDefaultsKey)
    }

    override func tearDown() {
        if let savedServer { UserDefaults.standard.set(savedServer, forKey: FlowClient.serverDefaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: FlowClient.serverDefaultsKey) }
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func client() -> FlowClient {
        FlowClient(session: StubURLProtocol.session(), token: "test-token")
    }

    func testASuggestionPostsHeardAndTypedToTheContractPath() async throws {
        StubURLProtocol.stub("/api/public/whisper/phrases/suggest", json: #"{"ok":true}"#)
        try await client().suggestPhrase(heard: "vervey pulse", typed: "VERVE Pulse")

        let request = try XCTUnwrap(StubURLProtocol.seenRequests.last)
        XCTAssertEqual(request.url?.path, "/api/public/whisper/phrases/suggest")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-WhisperFlow-Version"))

        let body = try XCTUnwrap(StubURLProtocol.lastBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["heard", "typed"])
        XCTAssertEqual(json["heard"] as? String, "vervey pulse")
        XCTAssertEqual(json["typed"] as? String, "VERVE Pulse")
    }

    /// One attempt, no retry queue: a suggestion that does not arrive is not
    /// worth holding a dictation open for.
    func testAFailedSuggestionIsNotRetried() async {
        StubURLProtocol.stub("/api/public/whisper/phrases/suggest", status: 500, json: "")
        do {
            try await client().suggestPhrase(heard: "vervey pulse", typed: "VERVE Pulse")
            XCTFail("expected the 500 to throw")
        } catch {
            XCTAssertEqual(StubURLProtocol.seenRequests.count, 1)
        }
    }

}
