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

    // MARK: - Pair-style hundreds ("two forty five" -> 245)

    func testPairHundredTensAndUnits() {
        XCTAssertEqual(SpokenNumbers.convert("two forty five"), "245")
    }

    func testPairHundredBareTens() {
        XCTAssertEqual(SpokenNumbers.convert("two forty"), "240")
    }

    func testPairHundredWithLeadingWord() {
        XCTAssertEqual(SpokenNumbers.convert("room two forty"), "room 240")
    }

    func testPairHundredTeens() {
        XCTAssertEqual(SpokenNumbers.convert("two fifteen"), "215")
    }

    func testPairHundredTen() {
        XCTAssertEqual(SpokenNumbers.convert("two ten"), "210")
    }

    func testPairHundredRequiresTailAtLeastTen() {
        // Below 10 this is two separate digits (a room number, a score),
        // not a botched "twenty-five" -- unchanged per-word behaviour.
        XCTAssertEqual(SpokenNumbers.convert("two five"), "2 5")
    }

    func testPairHundredExcludesBareOne() {
        // "one" is disproportionately non-numeric ("the 1:20 meeting"), so
        // it's excluded from the pair-hundred leading unit -- only the
        // trailing tens value converts.
        XCTAssertEqual(SpokenNumbers.convert("one twenty"), "one 20")
    }

    func testPairHundredDigitLeading() {
        XCTAssertEqual(SpokenNumbers.convert("2 forty five"), "245")
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

    // MARK: - Cue-led whole-sentence replacement (LLM-paraphrase-proof net)

    func testCueLedReplacementWithPrefix() {
        // "No" precedes the cue and there's real trailing content -- this
        // is NOT a standalone marker (too many extra words), so it needs
        // the cue-led-replacement shape, not the exact-marker shape.
        let raw = "Tune and forty five. No scratch that two and forty."
        XCTAssertEqual(CleanupRouter.stripStandaloneCorrections(raw), "Two and forty.")
    }

    func testCueLedReplacementCatchesLLMParaphrase() {
        // "Actually, make that ..." -- documents the actual bug report:
        // Ollama paraphrased "No scratch that" into "Actually, make that"
        // instead of applying the correction. finalize() runs this pass on
        // whichever text won the guards (here, the LLM output), and the
        // paraphrase the model reached for is itself cue-shaped --
        // "actually make that" is a replacement cue -- so it gets caught
        // on the way out.
        let raw = "Tune and 45. Actually, make that 2 and 40."
        XCTAssertEqual(CleanupRouter.stripStandaloneCorrections(raw), "2 and 40.")
    }

    func testBareMakeThatIsNeverACorrection() {
        // "make that" is everyday English -- a sentence-initial bare "Make
        // that ..." must never eat the sentence before it. (This is why
        // "make that" is excluded from replacementCues and only fires with
        // a prefix or a trailing comma.)
        let raw = "Talk to finance. Make that happen today."
        XCTAssertEqual(CleanupRouter.stripStandaloneCorrections(raw), raw)
    }

    // MARK: - Clause-level correction (comma-delimited, one sentence)

    func testClauseLevelStandaloneMarker() {
        let raw = "Two forty five, no scratch that, two forty."
        XCTAssertEqual(CleanupRouter.stripStandaloneCorrections(raw), "Two forty.")
    }

    // MARK: - False-positive guards: bare cue with real trailing content and

    func testBareCueWithTrailingContentUnchangedNoSignal() {
        // No prefix, no comma after the cue, not a replacement-flavoured
        // cue, and nothing before it to correct against -- "scratch" is
        // being used in its ordinary sense, not as a correction.
        let raw = "Scratch that plan entirely."
        XCTAssertEqual(CleanupRouter.stripStandaloneCorrections(raw), raw)
    }

    func testBareCueWithTrailingContentUnchangedSecondExample() {
        let raw = "Scratch that idea and move on."
        XCTAssertEqual(CleanupRouter.stripStandaloneCorrections(raw), raw)
    }

    // MARK: - Idempotence

    func testStripStandaloneCorrectionsIsIdempotent() {
        let raw = "Two forty five, no scratch that, two forty."
        let once = CleanupRouter.stripStandaloneCorrections(raw)
        let twice = CleanupRouter.stripStandaloneCorrections(once)
        XCTAssertEqual(once, twice)
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

    /// The new motivating bug: "two forty five, no scratch that two forty"
    /// spoken as clause-level correction, with the pair-style hundreds
    /// grammar folding the surviving number into one value.
    func testEndToEndClauseCorrectionThenPairHundredFormatting() {
        let raw = "Two forty five, no scratch that, two forty."
        let stripped = CleanupRouter.stripStandaloneCorrections(raw)
        let result = SpokenNumbers.convert(stripped)
        XCTAssertEqual(result, "240.")
    }

    /// The exact real-world transcript from the bug report: raw STT "Tune
    /// and forty five. No scratch that two and forty." (the user actually
    /// said "two forty five, no scratch that, two forty"). "Tune" (for
    /// "two") and the stray "and" are STT mishearing damage that neither
    /// stripStandaloneCorrections nor SpokenNumbers can repair -- fixing
    /// mis-heard words is the LLM cleanup backend's job, not this
    /// deterministic layer's. This test documents that ceiling: it proves
    /// the correction cue IS stripped ("No scratch that" and the abandoned
    /// "Tune and forty five." are both gone), while "and" passes through
    /// untouched because it isn't part of either deterministic pattern.
    /// "Two" also converts to "2" here -- SpokenNumbers has no surrounding-
    /// context awareness and converts every standalone number word it
    /// recognises unconditionally (that's true of every other word in this
    /// file too, e.g. "twelve" in "twelve thousand"), so this isn't a gap
    /// specific to the correction-stripping feature under test.
    func testEndToEndRealBugTranscriptDocumentsSTTDamageCeiling() {
        let raw = "Tune and forty five. No scratch that two and forty."
        let stripped = CleanupRouter.stripStandaloneCorrections(raw)
        XCTAssertEqual(stripped, "Two and forty.")
        let result = SpokenNumbers.convert(stripped)
        XCTAssertEqual(result, "2 and 40.")
    }
}
