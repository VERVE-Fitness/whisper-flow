import XCTest
@testable import WhisperFlow

final class SpokenNumbersTests: XCTestCase {
    // MARK: - Hundreds / thousands (new grammar)

    func testHundredsAndTensWords() {
        XCTAssertEqual(SpokenNumbers.convert("two hundred and forty five"), "245")
    }

    func testHundredsMixedDigitsAndWords() {
        XCTAssertEqual(SpokenNumbers.convert("2 hundred and 45."), "245.")
    }

    func testHundredsNoAnd() {
        XCTAssertEqual(SpokenNumbers.convert("three hundred twelve"), "312")
    }

    func testThousandsWithHundredsAndTens() {
        XCTAssertEqual(SpokenNumbers.convert("five thousand two hundred and thirty one"), "5231")
    }

    func testThousandsWithTensOnly() {
        XCTAssertEqual(SpokenNumbers.convert("two thousand and fifty"), "2050")
    }

    func testBareHundredUnambiguous() {
        // Unlike bare "one", "one hundred" is unambiguous and should convert.
        XCTAssertEqual(SpokenNumbers.convert("one hundred"), "100")
    }

    func testHundredAndNonNumberDoesNotConsumeAnd() {
        // "and" only binds to a valid continuation; when there isn't one it
        // must be left alone for pass-through, not swallowed or misattached.
        XCTAssertEqual(SpokenNumbers.convert("two hundred and I mean it"), "200 and I mean it")
    }

    func testThousandAlone() {
        XCTAssertEqual(SpokenNumbers.convert("twelve thousand"), "12000")
    }

    // MARK: - Existing 0-99 behaviour (regression)

    func testTensCompoundRegression() {
        XCTAssertEqual(SpokenNumbers.convert("twenty five dollars"), "25 dollars")
    }

    func testBareOneWithUnitFollowerRegression() {
        XCTAssertEqual(SpokenNumbers.convert("wait one minute"), "wait 1 minute")
    }

    func testBareOneWithoutUnitFollowerUnchanged() {
        XCTAssertEqual(SpokenNumbers.convert("one of them"), "one of them")
    }
}

final class CleanupRouterCorrectionTests: XCTestCase {
    // MARK: - stripStandaloneCorrections

    func testStripsCorrectionWithTrailingTail() {
        let raw = "Two hundred and forty. No scratch that, right? Two hundred and forty five."
        XCTAssertEqual(CleanupRouter.stripStandaloneCorrections(raw), "Two hundred and forty five.")
    }

    func testStripsPlainCorrectionRegression() {
        let raw = "Talk for five minutes. No, scratch that. Ten minutes."
        XCTAssertEqual(CleanupRouter.stripStandaloneCorrections(raw), "Ten minutes.")
    }

    func testDoesNotMatchSentenceWithExtraRealWords() {
        // "plan entirely" are two real extra words after the cue -- this
        // must NOT be treated as a standalone correction marker, so with
        // only one sentence present the text is returned unchanged.
        let raw = "No scratch that plan entirely."
        XCTAssertEqual(CleanupRouter.stripStandaloneCorrections(raw), raw)
    }

    // MARK: - droppedQuestion

    func testDroppedQuestionGuardIgnoresCorrectionMarkerQuestionMark() {
        let raw = "Two hundred and forty. No scratch that, right? Two hundred and forty five."
        let cleaned = "Two hundred and forty five."
        XCTAssertFalse(CleanupRouter.droppedQuestion(raw: raw, cleaned: cleaned))
    }

    func testDroppedQuestionGuardStillCatchesRealQuestion() {
        let raw = "What's the price?"
        let cleaned = "The price is high."
        XCTAssertTrue(CleanupRouter.droppedQuestion(raw: raw, cleaned: cleaned))
    }

    // MARK: - End-to-end (the motivating bug)

    /// The actual finalize() order is corrections -> strip -> digits (see
    /// CleanupRouter.finalize). Composing stripStandaloneCorrections and
    /// SpokenNumbers.convert directly reproduces that seam without needing
    /// a live LLM backend, and is the exact utterance from the bug report:
    /// "two hundred and forty. No scratch that, right? two hundred and
    /// forty five." used to type as "2 hundred and 40. No scratch that,
    /// right? 2 hundred and 45." -- the correction never got stripped (the
    /// dropped-question guard forced raw through) and hundreds never
    /// combined into one number.
    func testEndToEndCorrectionThenNumberFormatting() {
        let raw = "Two hundred and forty. No scratch that, right? Two hundred and forty five."
        let stripped = CleanupRouter.stripStandaloneCorrections(raw)
        let result = SpokenNumbers.convert(stripped)
        XCTAssertEqual(result, "245.")
    }
}
