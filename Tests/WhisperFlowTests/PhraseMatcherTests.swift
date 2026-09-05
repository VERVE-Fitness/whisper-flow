import XCTest
@testable import WhisperFlow

private func phrase(_ text: String, _ heardAs: [String] = []) -> FlowPhrase {
    FlowPhrase(phrase: text, heardAs: heardAs)
}

/// The list Niall's Mac would actually carry.
private let vervePhrases: [FlowPhrase] = [
    phrase("Tori", ["tory", "torrey", "tori's"]),
    phrase("VERVE Pulse", ["verve pulse", "verve pulls"]),
    phrase("functional trainer"),
]

final class PhraseMatcherExactTests: XCTestCase {
    func testAHeardVariantBecomesThePhraseWithThePhrasesOwnCasing() {
        let applied = PhraseMatcher.apply("We sold three tory racks", phrases: vervePhrases)
        XCTAssertEqual(applied.text, "We sold three Tori racks")
        XCTAssertEqual(applied.replacements, [PhraseMatcher.Replacement(heard: "tory", phrase: "Tori", kind: .exact)])
        XCTAssertEqual(applied.logLines, ["[phrase] \"tory\" -> \"Tori\" (exact)"])
    }

    /// The whole point of the feature: a two word product name the model
    /// renders in lower case comes out the way the team writes it.
    func testAMultiWordVariantIsReplacedAsAWhole() {
        let applied = PhraseMatcher.apply("Put it in verve pulse today", phrases: vervePhrases)
        XCTAssertEqual(applied.text, "Put it in VERVE Pulse today")
        XCTAssertEqual(applied.replacements.count, 1)
        XCTAssertEqual(applied.replacements.first?.phrase, "VERVE Pulse")
    }

    /// A full stop or a comma right after the word must not stop the match,
    /// and must not be eaten by it.
    func testPunctuationRightAfterTheWordIsLeftAlone() {
        XCTAssertEqual(PhraseMatcher.apply("I asked about tory.", phrases: vervePhrases).text,
                       "I asked about Tori.")
        XCTAssertEqual(PhraseMatcher.apply("tory, then the rack", phrases: vervePhrases).text,
                       "Tori, then the rack")
        XCTAssertEqual(PhraseMatcher.apply("(tory)", phrases: vervePhrases).text, "(Tori)")
    }

    func testMatchingIsCaseInsensitiveOnTheHeardSide() {
        XCTAssertEqual(PhraseMatcher.apply("TORY and Tory", phrases: vervePhrases).text, "Tori and Tori")
    }

    /// "tory" inside "territory" is not the product.
    func testAVariantInsideALongerWordIsNotTouched() {
        XCTAssertEqual(PhraseMatcher.apply("in that territory", phrases: vervePhrases).text, "in that territory")
    }

    /// Longest first: with both "verve pulse" and "verve pulse pro" on the
    /// list, the longer one wins where it applies.
    func testTheLongestVariantWins() {
        let list = [phrase("VERVE Pulse", ["verve pulse"]), phrase("VERVE Pulse Pro", ["verve pulse pro"])]
        XCTAssertEqual(PhraseMatcher.apply("we run verve pulse pro here", phrases: list).text,
                       "we run VERVE Pulse Pro here")
    }

    func testTextThatIsAlreadyRightIsUntouchedAndLogsNothing() {
        let applied = PhraseMatcher.apply("The functional trainer is on the floor", phrases: vervePhrases)
        XCTAssertEqual(applied.text, "The functional trainer is on the floor")
        XCTAssertTrue(applied.replacements.isEmpty)
        let already = PhraseMatcher.apply("Tori sits next to VERVE Pulse", phrases: vervePhrases)
        XCTAssertEqual(already.text, "Tori sits next to VERVE Pulse")
        XCTAssertTrue(already.replacements.isEmpty)
    }

    func testAnEmptyListOrEmptyTextChangesNothing() {
        XCTAssertEqual(PhraseMatcher.apply("tory", phrases: []).text, "tory")
        XCTAssertEqual(PhraseMatcher.apply("", phrases: vervePhrases).text, "")
    }
}

final class PhraseMatcherFuzzyTests: XCTestCase {
    /// A near miss of a two word phrase, well inside the distance bar: one
    /// edit over eleven characters is 0.09.
    func testANearMissOfAMultiWordPhraseIsCorrected() {
        let list = [phrase("VERVE Pulse")]
        let applied = PhraseMatcher.apply("we sell verve pulze to gyms", phrases: list)
        XCTAssertEqual(applied.text, "we sell VERVE Pulse to gyms")
        guard case .fuzzy(let d)? = applied.replacements.first?.kind else {
            return XCTFail("expected a fuzzy replacement, got \(applied.replacements)")
        }
        XCTAssertEqual(d, 1.0 / 11.0, accuracy: 0.001)
        XCTAssertEqual(applied.logLines, ["[phrase] \"verve pulze\" -> \"VERVE Pulse\" (fuzzy 0.09)"])
    }

    /// The case the design calls out by name. "story" is five letters and two
    /// edits from "tori", which is 2/5 = 0.4, well over the 0.25 bar, so an
    /// ordinary English word survives a list that contains Tori.
    func testStoryIsNotRewrittenToTori() {
        let list = [phrase("Tori", ["tory"])]
        let applied = PhraseMatcher.apply("that is the story of the quarter", phrases: list)
        XCTAssertEqual(applied.text, "that is the story of the quarter")
        XCTAssertTrue(applied.replacements.isEmpty)
        // The arithmetic the guard rests on, pinned so a change to the
        // distance function shows up here rather than in someone's dictation.
        XCTAssertEqual(PhraseMatcher.levenshtein("story", "tori"), 2)
        XCTAssertGreaterThan(2.0 / 5.0, PhraseMatcher.maximumFuzzyDistance)
    }

    /// Under five characters there is not enough word for an edit distance to
    /// mean anything: "sori" is one edit from "tori" but 0.25 of nothing.
    func testShortWordsAreNeverFuzzyMatched() {
        let list = [phrase("Tori")]
        XCTAssertEqual(PhraseMatcher.apply("sori", phrases: list).text, "sori")
        XCTAssertEqual(PhraseMatcher.apply("tori", phrases: list).text, "tori",
                       "an exact lower-case hit is the exact pass's job, through heard_as, not fuzzy's")
    }

    /// A five character window against the four character phrase clears the
    /// character floor, and one edit over five is 0.2.
    func testAFiveCharacterNearMissIsCorrected() {
        let list = [phrase("Tori")]
        let applied = PhraseMatcher.apply("the torie rack", phrases: list)
        XCTAssertEqual(applied.text, "the Tori rack")
        XCTAssertEqual(applied.logLines, ["[phrase] \"torie\" -> \"Tori\" (fuzzy 0.2)"])
    }

    /// A phrase that is itself a common English word must never be a fuzzy
    /// target, or every dictation gets rewritten.
    func testACommonEnglishWordIsNeverAFuzzyTarget() {
        XCTAssertFalse(PhraseMatcher.isFuzzyEligible("meeting"))
        XCTAssertFalse(PhraseMatcher.isFuzzyEligible("story"))
        let list = [phrase("meeting")]
        XCTAssertEqual(PhraseMatcher.apply("the meting ran long", phrases: list).text, "the meting ran long")
    }

    /// The shape heuristic behind the word list: a single lower-case word
    /// reads as ordinary English, whatever it is.
    func testASingleLowerCaseWordIsNotAFuzzyTarget() {
        XCTAssertFalse(PhraseMatcher.isFuzzyEligible("kettlebell"))
        XCTAssertTrue(PhraseMatcher.isFuzzyEligible("Kettlebell"))
        XCTAssertTrue(PhraseMatcher.isFuzzyEligible("VERVE"))
        // Two words are specific enough to stand on their own.
        XCTAssertTrue(PhraseMatcher.isFuzzyEligible("functional trainer"))
    }

    /// A single word phrase must not swallow a run of words, and a longer
    /// phrase must not swallow the word next to it.
    func testWindowsAndPhrasesMustBeTheSameNumberOfWords() {
        let single = [phrase("Kettlebell")]
        XCTAssertEqual(PhraseMatcher.apply("kettle bells", phrases: single).text, "kettle bells")
        let pair = [phrase("functional trainer")]
        XCTAssertEqual(PhraseMatcher.apply("the functional trainer", phrases: pair).text,
                       "the functional trainer",
                       "a three word window must not collapse into a two word phrase")
    }

    func testNothingWiderThanFourWordsIsEverConsidered() {
        XCTAssertEqual(PhraseMatcher.maximumWindowWords, 4)
        let long = [phrase("One Two Three Four Five")]
        XCTAssertEqual(PhraseMatcher.apply("one two three four five", phrases: long).text,
                       "one two three four five")
    }

    /// Both passes in one string, in the right order.
    func testExactAndFuzzyTogether() {
        let applied = PhraseMatcher.apply("tory sits next to verve pulze", phrases: vervePhrases)
        XCTAssertEqual(applied.text, "Tori sits next to VERVE Pulse")
        XCTAssertEqual(applied.replacements.map(\.phrase), ["Tori", "VERVE Pulse"])
        XCTAssertEqual(applied.replacements.first?.kind, .exact)
    }

    func testTheDistanceInTheLogLineIsReadable() {
        XCTAssertEqual(PhraseMatcher.format(0.2), "0.2")
        XCTAssertEqual(PhraseMatcher.format(0.25), "0.25")
        XCTAssertEqual(PhraseMatcher.format(0.0), "0")
        XCTAssertEqual(PhraseMatcher.logLine(PhraseMatcher.Replacement(heard: "tory", phrase: "Tori", kind: .fuzzy(0.2))),
                       "[phrase] \"tory\" -> \"Tori\" (fuzzy 0.2)")
    }
}

final class PhraseCacheTests: XCTestCase {
    private var temp: URL!

    override func setUp() {
        super.setUp()
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperflow-phrases-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        PhraseStore.urlOverride = temp.appendingPathComponent("phrases.json")
    }

    override func tearDown() {
        PhraseStore.urlOverride = nil
        try? FileManager.default.removeItem(at: temp)
        super.tearDown()
    }

    func testWhatIsSavedIsWhatComesBack() {
        let store = PhraseStore()
        store.replace(vervePhrases)
        XCTAssertEqual(PhraseStore.load(), vervePhrases)
        XCTAssertEqual(PhraseStore().phrases, vervePhrases, "a fresh process reads the cache off disk")
    }

    /// No connection, no file, no crash: an empty list simply corrects nothing.
    func testAMissingCacheReadsAsAnEmptyList() {
        XCTAssertEqual(PhraseStore.load(), [])
        XCTAssertEqual(PhraseStore().phrases, [])
    }

    func testACorruptCacheReadsAsAnEmptyListRatherThanThrowing() throws {
        try Data("not json".utf8).write(to: PhraseStore.urlOverride!)
        XCTAssertEqual(PhraseStore.load(), [])
    }

    func testReloadPicksUpAFileWrittenUnderneathUs() throws {
        let store = PhraseStore()
        XCTAssertEqual(store.phrases, [])
        PhraseStore.save(vervePhrases)
        XCTAssertEqual(store.phrases, [], "the in-memory copy stands until something reloads it")
        store.reload()
        XCTAssertEqual(store.phrases, vervePhrases)
    }

    /// The server shape, decoded exactly as `me()` will hand it over.
    func testThePhraseWireShapeIsSnakeCaseAndToleratesAMissingList() throws {
        let json = #"[{"phrase":"Tori","heard_as":["tory","torrey"]},{"phrase":"VERVE Pulse"}]"#
        let decoded = try JSONDecoder().decode([FlowPhrase].self, from: Data(json.utf8))
        XCTAssertEqual(decoded, [FlowPhrase(phrase: "Tori", heardAs: ["tory", "torrey"]),
                                 FlowPhrase(phrase: "VERVE Pulse", heardAs: [])])
    }
}

final class PhraseWiringTests: XCTestCase {
    /// Phrases must reach the LLM's dictionary hints as well as the
    /// deterministic pass, and must not be listed twice.
    func testThePhraseListJoinsTheDictionaryHints() {
        let merged = CleanupRouter.dictionaryWithPhrases(["VERVE", "Tori"], phrases: vervePhrases)
        XCTAssertEqual(merged, ["VERVE", "Tori", "VERVE Pulse", "functional trainer"])
    }

    /// Every meeting segment goes through the same matcher before the
    /// transcript is written, so what Flow stores says "Tori" too.
    func testMeetingSegmentsAreRewrittenBeforeTheTranscriptIsWritten() {
        let segments = [
            TranscriptSegment(speakerId: "owner", start: 0, end: 2, text: "The tory rack ships Monday."),
            TranscriptSegment(speakerId: "S1", start: 2, end: 4, text: "And verve pulse is live."),
            TranscriptSegment(speakerId: "S1", start: 4, end: 5, text: "Nothing to fix here."),
        ]
        let out = MeetingTranscriber.applyPhrases(to: segments, phrases: vervePhrases)
        XCTAssertEqual(out.map(\.text), ["The Tori rack ships Monday.",
                                         "And VERVE Pulse is live.",
                                         "Nothing to fix here."])
        XCTAssertEqual(out.map(\.speakerId), ["owner", "S1", "S1"])
        XCTAssertEqual(out[0].start, 0)
        XCTAssertEqual(out[1].end, 4)
    }

    func testAnEmptyPhraseListLeavesTheSegmentsExactlyAsTheyWere() {
        let segments = [TranscriptSegment(speakerId: "owner", start: 0, end: 1, text: "tory")]
        XCTAssertEqual(MeetingTranscriber.applyPhrases(to: segments, phrases: []), segments)
    }
}
