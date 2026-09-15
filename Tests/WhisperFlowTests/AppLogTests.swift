import XCTest
@testable import WhisperFlow

/// The app wrote no log of its own: every [capture]/[stop]/[stt] note went to
/// stderr, which goes nowhere when the app is launched from Finder. fd 2 now
/// points at ~/Library/Application Support/WhisperFlow/app.log, which means
/// the file grows forever unless something bounds it. This is that something.
final class AppLogRotationTests: XCTestCase {
    func testAnEmptyOrSmallLogIsNotRotated() {
        XCTAssertFalse(Diagnostics.shouldRotate(currentBytes: 0))
        XCTAssertFalse(Diagnostics.shouldRotate(currentBytes: 1))
        XCTAssertFalse(Diagnostics.shouldRotate(currentBytes: Diagnostics.maxAppLogBytes - 1))
    }

    func testTheBudgetIsFiveMegabytes() {
        XCTAssertEqual(Diagnostics.maxAppLogBytes, 5 * 1024 * 1024)
    }

    func testRotatesAtAndAboveTheBudget() {
        XCTAssertTrue(Diagnostics.shouldRotate(currentBytes: Diagnostics.maxAppLogBytes))
        XCTAssertTrue(Diagnostics.shouldRotate(currentBytes: Diagnostics.maxAppLogBytes + 1))
        XCTAssertTrue(Diagnostics.shouldRotate(currentBytes: 100 * 1024 * 1024))
    }

    func testAnExplicitLimitIsHonoured() {
        XCTAssertTrue(Diagnostics.shouldRotate(currentBytes: 100, limitBytes: 100))
        XCTAssertFalse(Diagnostics.shouldRotate(currentBytes: 99, limitBytes: 100))
    }

    func testANonsenseLimitNeverRotates() {
        // Better to let the file grow than to throw the evidence away on
        // every single check because a limit came through as zero.
        XCTAssertFalse(Diagnostics.shouldRotate(currentBytes: 10_000_000, limitBytes: 0))
        XCTAssertFalse(Diagnostics.shouldRotate(currentBytes: 10_000_000, limitBytes: -1))
    }

    func testTheRotatedFileSitsBesideTheLiveOne() {
        XCTAssertEqual(Diagnostics.appLogURL.lastPathComponent, "app.log")
        XCTAssertEqual(Diagnostics.rotatedAppLogURL.lastPathComponent, "app.log.1")
        XCTAssertEqual(Diagnostics.appLogURL.deletingLastPathComponent(),
                       Diagnostics.rotatedAppLogURL.deletingLastPathComponent())
    }
}
