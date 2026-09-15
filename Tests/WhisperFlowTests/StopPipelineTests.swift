import XCTest
@testable import WhisperFlow

/// finishStream() had no timeout at all, and a stop that hung inside it left
/// the pill on "Cleaning…" until the app was force-quit. It is bounded now,
/// and this is the decision that makes the bound survivable: what to insert
/// when the final pass never came back.
final class StopPipelineTests: XCTestCase {
    func testFinishedTextWins() {
        XCTAssertEqual(StopPipeline.rawText(finished: "the install team arrives at nine",
                                            partial: "the install team"),
                       "the install team arrives at nine")
    }

    func testTimeoutFallsBackToThePartial() {
        XCTAssertEqual(StopPipeline.rawText(finished: nil, partial: "the install team arrives"),
                       "the install team arrives")
    }

    func testEmptyFinishedTextStillFallsBackToThePartial() {
        // finishStream() returning "" with a real partial on screen is the
        // same failure as a timeout as far as the person is concerned.
        XCTAssertEqual(StopPipeline.rawText(finished: "", partial: "hello there"), "hello there")
        XCTAssertEqual(StopPipeline.rawText(finished: "   \n ", partial: "hello there"), "hello there")
    }

    func testNothingAtAllIsADiscard() {
        XCTAssertNil(StopPipeline.rawText(finished: nil, partial: ""))
        XCTAssertNil(StopPipeline.rawText(finished: nil, partial: "   "))
        XCTAssertNil(StopPipeline.rawText(finished: "", partial: ""))
    }

    func testPartialIsReturnedVerbatim() {
        // Normalisation happens downstream; this function must not quietly
        // reshape the text it hands back.
        XCTAssertEqual(StopPipeline.rawText(finished: nil, partial: " hello  there "),
                       " hello  there ")
    }
}
