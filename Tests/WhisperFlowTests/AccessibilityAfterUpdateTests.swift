import XCTest
@testable import WhisperFlow

/// macOS drops the Accessibility grant when the signed binary changes, so
/// every update used to look like the app quietly stopped typing. The
/// decision to ask again is pure and lives here.
final class AccessibilityAfterUpdateTests: XCTestCase {

    func testANewVersionWithoutTheGrantAsksAgain() {
        XCTAssertTrue(AccessibilityPermission.shouldReaskAfterUpdate(
            currentVersion: "v2026.9.8", lastCheckedVersion: "v2026.9.7", isTrusted: false))
    }

    /// The grant survived the update: say nothing.
    func testANewVersionThatKeptTheGrantSaysNothing() {
        XCTAssertFalse(AccessibilityPermission.shouldReaskAfterUpdate(
            currentVersion: "v2026.9.8", lastCheckedVersion: "v2026.9.7", isTrusted: true))
    }

    /// The same version launching again is not an update, however many times
    /// it launches.
    func testTheSameVersionNeverAsksTwice() {
        XCTAssertFalse(AccessibilityPermission.shouldReaskAfterUpdate(
            currentVersion: "v2026.9.8", lastCheckedVersion: "v2026.9.8", isTrusted: false))
    }

    /// A first ever install has no stored version, and its missing grant is
    /// the ordinary first-run prompt. Saying "update installed" there would
    /// be a lie.
    func testAFirstEverLaunchIsNotAnUpdate() {
        XCTAssertFalse(AccessibilityPermission.shouldReaskAfterUpdate(
            currentVersion: "v2026.9.8", lastCheckedVersion: nil, isTrusted: false))
        XCTAssertFalse(AccessibilityPermission.shouldReaskAfterUpdate(
            currentVersion: "v2026.9.8", lastCheckedVersion: "", isTrusted: false))
    }

    /// A downgrade is still a binary change, so it still costs the grant.
    func testGoingBackAVersionAlsoAsksAgain() {
        XCTAssertTrue(AccessibilityPermission.shouldReaskAfterUpdate(
            currentVersion: "v2026.9.6", lastCheckedVersion: "v2026.9.7", isTrusted: false))
    }

    func testTheDefaultsKeyIsTheOneTheDesignNames() {
        XCTAssertEqual(AccessibilityPermission.lastVersionDefaultsKey, "lastAccessibilityCheckVersion")
    }

    /// The wording is the design's, word for word, and it is what the pill
    /// renders.
    func testThePillWordingIsExact() {
        XCTAssertEqual(AccessibilityPermission.updatePillText,
                       "Update installed: grant Accessibility again")
        XCTAssertFalse(AccessibilityPermission.updatePillText.contains("\u{2014}"))
        XCTAssertFalse(AccessibilityPermission.updatePillText.contains("\u{2013}"))
    }

    /// The pill hides itself, but not before it can be read.
    func testThePillIsTerminalAndStaysUpLongEnoughToRead() {
        XCTAssertTrue(PillState.accessibilityAfterUpdate.isTerminal)
        XCTAssertFalse(PillState.accessibilityAfterUpdate.isFailure)
        XCTAssertEqual(PillState.accessibilityAfterUpdate.autoHideSeconds, 8.0)
        XCTAssertEqual(PillState.failed("x").autoHideSeconds, 3.5)
        XCTAssertEqual(PillState.inserted.autoHideSeconds, 1.0)
    }
}
