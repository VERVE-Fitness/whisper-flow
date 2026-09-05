import XCTest
@testable import WhisperFlow

/// The version line in the menu carries the build time next to the commit,
/// so "which build are you on?" has a date and a time in it (Niall, 5 Sep
/// 2026), shown in the Mac's own time zone.
final class VersionLabelTests: XCTestCase {
    func testBuildStampRendersInLocalTime() {
        let brisbane = TimeZone(identifier: "Australia/Brisbane")!
        XCTAssertEqual(AppState.buildDateLabel("2026-09-05T05:19:52Z", timeZone: brisbane),
                       "built 5 Sep 2026, 3:19 pm")
        XCTAssertEqual(AppState.buildDateLabel("2026-01-14T22:05:00Z", timeZone: brisbane),
                       "built 15 Jan 2026, 8:05 am")
    }

    func testAStampThatDoesNotParseIsLeftOut() {
        XCTAssertNil(AppState.buildDateLabel("yesterday-ish"))
        XCTAssertNil(AppState.buildDateLabel(""))
    }
}
