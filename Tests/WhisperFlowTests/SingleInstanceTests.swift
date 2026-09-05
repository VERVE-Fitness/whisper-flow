import XCTest
@testable import WhisperFlow

/// Two copies ran at once on 5 Sep 2026, one from Downloads and one from
/// Applications, and every dictation arrived twice. Which copy lives is a
/// pure decision, and this is it.
final class SingleInstanceTests: XCTestCase {

    private func copy(_ path: String, built: String? = nil, version: String? = nil) -> SingleInstance.Copy {
        SingleInstance.Copy(path: path, buildDate: built, version: version)
    }

    // MARK: - Build stamps decide it

    func testTheNewerBuildTellsTheOlderOneToQuit() {
        let decision = SingleInstance.decide(
            mine: copy("/Applications/WhisperFlow.app", built: "2026-09-05T05:19:52Z"),
            other: copy("/Users/niall/Downloads/WhisperFlow.app", built: "2026-09-01T01:00:00Z"),
            isReplacementLaunch: false)
        XCTAssertEqual(decision, .terminateOther)
    }

    func testTheOlderBuildQuitsItself() {
        let decision = SingleInstance.decide(
            mine: copy("/Users/niall/Downloads/WhisperFlow.app", built: "2026-09-01T01:00:00Z"),
            other: copy("/Applications/WhisperFlow.app", built: "2026-09-05T05:19:52Z"),
            isReplacementLaunch: false)
        XCTAssertEqual(decision, .quitSelf(reason: "a newer copy is already running"))
    }

    // MARK: - No stamp to compare

    /// A build from before the stamp existed still has a bundle version.
    func testWithoutStampsTheBundleVersionDecides() {
        XCTAssertEqual(SingleInstance.decide(
            mine: copy("/Applications/WhisperFlow.app", version: "20260905.5"),
            other: copy("/Users/niall/Downloads/WhisperFlow.app", version: "20260905.4"),
            isReplacementLaunch: false), .terminateOther)
        XCTAssertEqual(SingleInstance.decide(
            mine: copy("/Users/niall/Downloads/WhisperFlow.app", version: "20260905.4"),
            other: copy("/Applications/WhisperFlow.app", version: "20260905.5"),
            isReplacementLaunch: false), .quitSelf(reason: "a newer copy is already running"))
    }

    /// Version 20260905.10 is newer than 20260905.9, which a plain string
    /// comparison gets backwards.
    func testVersionsAreComparedAsNumbersNotText() {
        XCTAssertEqual(SingleInstance.decide(
            mine: copy("/Applications/WhisperFlow.app", version: "20260905.10"),
            other: copy("/Users/niall/Downloads/WhisperFlow.app", version: "20260905.9"),
            isReplacementLaunch: false), .terminateOther)
    }

    /// A stamp beats a version: the stamp is the build time, the version is
    /// whatever somebody last typed into Info.plist.
    func testTheStampIsPreferredToTheVersion() {
        XCTAssertEqual(SingleInstance.decide(
            mine: copy("/Applications/WhisperFlow.app", built: "2026-09-05T05:19:52Z", version: "20260101.1"),
            other: copy("/Users/niall/Downloads/WhisperFlow.app", built: "2026-09-01T01:00:00Z", version: "20990101.9"),
            isReplacementLaunch: false), .terminateOther)
    }

    /// Nothing to tell them apart: the copy already running keeps running,
    /// because it has the permissions and any work in flight.
    func testOnATieTheCopyAlreadyRunningWins() {
        XCTAssertEqual(SingleInstance.decide(
            mine: copy("/Users/niall/Downloads/WhisperFlow.app"),
            other: copy("/Applications/WhisperFlow.app"),
            isReplacementLaunch: false), .quitSelf(reason: "another copy is already running"))
        XCTAssertEqual(SingleInstance.decide(
            mine: copy("/Users/niall/Downloads/WhisperFlow.app", built: "2026-09-05T05:19:52Z"),
            other: copy("/Applications/WhisperFlow.app", built: "2026-09-05T05:19:52Z"),
            isReplacementLaunch: false), .quitSelf(reason: "another copy is already running"))
        XCTAssertNil(SingleInstance.stamp("not a date"))
        XCTAssertNil(SingleInstance.stamp(nil))
    }

    // MARK: - The same app launched twice

    func testTheSamePathTwiceIsADoubleLaunchAndTheSecondQuits() {
        XCTAssertEqual(SingleInstance.decide(
            mine: copy("/Applications/WhisperFlow.app", built: "2026-09-05T05:19:52Z"),
            other: copy("/Applications/WhisperFlow.app", built: "2026-09-05T05:19:52Z"),
            isReplacementLaunch: false),
            .quitSelf(reason: "another copy is already running from the same place"))
        // Even when the newer stamp would otherwise win: same path, one app.
        XCTAssertEqual(SingleInstance.decide(
            mine: copy("/Applications/WhisperFlow.app/", built: "2026-09-06T00:00:00Z"),
            other: copy("/Applications/WhisperFlow.app", built: "2026-09-01T00:00:00Z"),
            isReplacementLaunch: false),
            .quitSelf(reason: "another copy is already running from the same place"))
    }

    // MARK: - The copy an update just started

    /// A self-update installs over the path the outgoing copy is running
    /// from, so the replacement launches from the same place. Without this it
    /// would read as a double launch and quit itself, leaving nothing
    /// running.
    func testTheReplacementLaunchAlwaysWins() {
        XCTAssertEqual(SingleInstance.decide(
            mine: copy("/Applications/WhisperFlow.app", built: "2026-09-06T00:00:00Z"),
            other: copy("/Applications/WhisperFlow.app", built: "2026-09-05T05:19:52Z"),
            isReplacementLaunch: true), .terminateOther)
        XCTAssertEqual(SingleInstance.decide(
            mine: copy("/Applications/WhisperFlow.app"),
            other: copy("/Users/niall/Downloads/WhisperFlow.app", built: "2099-01-01T00:00:00Z"),
            isReplacementLaunch: true), .terminateOther)
    }

    func testTheRelaunchArgumentsAreTheOnesTheUpdaterSends() {
        XCTAssertTrue(SelfUpdater.isReplacementLaunch(arguments: ["WhisperFlow", "--relaunched-after-update"]))
        XCTAssertTrue(SelfUpdater.isReplacementLaunch(arguments: ["WhisperFlow", "--relaunched-after-move"]))
        XCTAssertFalse(SelfUpdater.isReplacementLaunch(arguments: ["WhisperFlow"]))
        XCTAssertTrue(SelfUpdater.didSelfUpdate(arguments: ["WhisperFlow", "--relaunched-after-update"]))
        // A move is not an update: it does not claim a new version was installed.
        XCTAssertFalse(SelfUpdater.didSelfUpdate(arguments: ["WhisperFlow", "--relaunched-after-move"]))
    }
}
