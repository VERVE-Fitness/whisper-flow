import XCTest
@testable import WhisperFlow

/// One-click update. Niall, 5 Sep 2026: "do I have to uninstall the old
/// version before installing new versions, or can you make a fix so it isn't
/// necessary?" The judgement calls that decide whether a downloaded copy is
/// safe to put on top of a running app are all here; the download, the unzip
/// and the file moves are thin shells around them.
final class SelfUpdaterTests: XCTestCase {

    // MARK: - Reading a release tag

    func testTheShaIsWhateverFollowsTheLastDashInTheTag() {
        XCTAssertEqual(SelfUpdater.shortSHA(fromTag: "v2026.09.05-9596fa8"), "9596fa8")
        XCTAssertEqual(SelfUpdater.shortSHA(fromTag: "v2026.9.10-abc1234"), "abc1234")
    }

    /// A tag with nothing to compare against is a reason to stop, not a
    /// reason to guess.
    func testATagWithNoShaCannotBeChecked() {
        XCTAssertNil(SelfUpdater.shortSHA(fromTag: "v2026.09.05"))
        XCTAssertNil(SelfUpdater.shortSHA(fromTag: "v2026.09.05-"))
        XCTAssertNil(SelfUpdater.shortSHA(fromTag: ""))
    }

    // MARK: - What spctl said

    func testANotarisedDeveloperIDBuildIsAccepted() {
        let out = """
        /tmp/WhisperFlow.app: accepted
        source=Notarized Developer ID
        origin=Developer ID Application: VERVE Fitness Equipment Pty Ltd (ABC123)
        """
        let verdict = SelfUpdater.parseSpctl(exitCode: 0, output: out)
        XCTAssertTrue(verdict.accepted)
        XCTAssertEqual(verdict.source, "Notarized Developer ID")
        XCTAssertTrue(verdict.isDeveloperID)
        XCTAssertNil(SelfUpdater.verify(spctl: verdict, bundleCommit: "9596fa8", tag: "v2026.09.05-9596fa8"))
    }

    /// Gatekeeper rejecting the bundle is the end of it: nothing is replaced.
    func testARejectedBundleIsNeverInstalled() {
        let verdict = SelfUpdater.parseSpctl(exitCode: 3, output: "/tmp/WhisperFlow.app: rejected\nsource=no usable signature")
        XCTAssertFalse(verdict.accepted)
        XCTAssertEqual(SelfUpdater.verify(spctl: verdict, bundleCommit: "9596fa8", tag: "v2026.09.05-9596fa8"),
                       .gatekeeper)
    }

    /// An ad-hoc or Apple Development build can still be "accepted" on the
    /// Mac that signed it. Only a Developer ID copy goes on top of a running
    /// app.
    func testAnAcceptedButNotDeveloperIDBuildIsRefused() {
        let verdict = SelfUpdater.parseSpctl(exitCode: 0, output: "/tmp/WhisperFlow.app: accepted\nsource=Unnotarized Developer ID\n")
        XCTAssertTrue(verdict.isDeveloperID)
        let adhoc = SelfUpdater.parseSpctl(exitCode: 0, output: "/tmp/WhisperFlow.app: accepted\nsource=Local Signing Authority\n")
        XCTAssertFalse(adhoc.isDeveloperID)
        XCTAssertEqual(SelfUpdater.verify(spctl: adhoc, bundleCommit: "9596fa8", tag: "v2026.09.05-9596fa8"),
                       .notDeveloperID)
    }

    // MARK: - Is this the build the release feed advertised

    func testACopyWhoseCommitDoesNotMatchTheTagIsRefused() {
        let ok = SelfUpdater.parseSpctl(exitCode: 0, output: "accepted\nsource=Notarized Developer ID")
        XCTAssertEqual(SelfUpdater.verify(spctl: ok, bundleCommit: "0000000", tag: "v2026.09.05-9596fa8"),
                       .wrongBuild(expected: "9596fa8", found: "0000000"))
        XCTAssertEqual(SelfUpdater.verify(spctl: ok, bundleCommit: nil, tag: "v2026.09.05-9596fa8"),
                       .wrongBuild(expected: "9596fa8", found: nil))
        XCTAssertEqual(SelfUpdater.verify(spctl: ok, bundleCommit: "unknown", tag: "v2026.09.05-9596fa8"),
                       .wrongBuild(expected: "9596fa8", found: "unknown"))
        XCTAssertEqual(SelfUpdater.verify(spctl: ok, bundleCommit: "9596fa8", tag: "2026.09.05"),
                       .badTag("2026.09.05"))
    }

    /// Every failure names the step that failed, in words a person can read
    /// off a pill, with no dashes.
    func testEveryFailureHasAPlainReason() {
        let failures: [SelfUpdater.Failure] = [
            .download("timed out"), .unpack, .noBundle, .gatekeeper, .notDeveloperID,
            .wrongBuild(expected: "a", found: "b"), .badTag("v1"), .replace("busy"), .relaunch
        ]
        for failure in failures {
            XCTAssertFalse(failure.reason.isEmpty)
            XCTAssertFalse(failure.reason.contains("\u{2014}"))
            XCTAssertFalse(failure.reason.contains("\u{2013}"))
        }
        XCTAssertEqual(SelfUpdater.Failure.gatekeeper.reason, "macOS did not accept the new copy")
        XCTAssertEqual(SelfUpdater.Failure.wrongBuild(expected: "a", found: "b").reason,
                       "the new copy is not the published build")
    }

    // MARK: - Where the running copy lives

    func testApplicationsAndUserApplicationsAreBothRealInstalls() {
        XCTAssertEqual(SelfUpdater.classify(bundlePath: "/Applications/WhisperFlow.app", home: "/Users/niall"),
                       .applications)
        XCTAssertEqual(SelfUpdater.classify(bundlePath: "/Applications/Utilities/WhisperFlow.app", home: "/Users/niall"),
                       .applications)
        XCTAssertEqual(SelfUpdater.classify(bundlePath: "/Users/niall/Applications/WhisperFlow.app", home: "/Users/niall"),
                       .userApplications)
        XCTAssertTrue(SelfUpdater.classify(bundlePath: "/Applications/WhisperFlow.app", home: "/Users/niall").isInstalled)
    }

    /// The two places today's copies were running from, plus a disk image.
    func testAnywhereElseIsNamedByItsFolder() {
        XCTAssertEqual(SelfUpdater.classify(bundlePath: "/Users/niall/Downloads/WhisperFlow.app", home: "/Users/niall"),
                       .elsewhere(folder: "Downloads"))
        XCTAssertEqual(SelfUpdater.classify(bundlePath: "/Users/niall/Desktop/WhisperFlow.app", home: "/Users/niall"),
                       .elsewhere(folder: "Desktop"))
        XCTAssertEqual(SelfUpdater.classify(bundlePath: "/Volumes/Whisper Flow/WhisperFlow.app", home: "/Users/niall"),
                       .elsewhere(folder: "Whisper Flow"))
        XCTAssertEqual(SelfUpdater.classify(bundlePath: "/WhisperFlow.app", home: "/Users/niall"),
                       .elsewhere(folder: "the top level of this Mac"))
        XCTAssertFalse(SelfUpdater.classify(bundlePath: "/Users/niall/Downloads/WhisperFlow.app", home: "/Users/niall").isInstalled)
    }

    /// A trailing slash is the same folder, and so is a path with a "..".
    func testPathsAreStandardisedBeforeTheyAreJudged() {
        XCTAssertEqual(SelfUpdater.classify(bundlePath: "/Applications/WhisperFlow.app/", home: "/Users/niall"),
                       .applications)
        XCTAssertEqual(SelfUpdater.classify(bundlePath: "/Users/niall/Downloads/../Downloads/WhisperFlow.app",
                                            home: "/Users/niall"),
                       .elsewhere(folder: "Downloads"))
    }

    /// An installed copy is updated where it stands; a copy running from
    /// Downloads is installed properly instead, which is the fix for the
    /// stale copy left behind in Applications.
    func testAnInstalledCopyIsReplacedInPlaceAndAnythingElseGoesToApplications() {
        XCTAssertEqual(SelfUpdater.installTarget(for: .applications,
                                                 runningBundlePath: "/Applications/WhisperFlow.app"),
                       "/Applications/WhisperFlow.app")
        XCTAssertEqual(SelfUpdater.installTarget(for: .userApplications,
                                                 runningBundlePath: "/Users/niall/Applications/WhisperFlow.app"),
                       "/Users/niall/Applications/WhisperFlow.app")
        XCTAssertEqual(SelfUpdater.installTarget(for: .elsewhere(folder: "Downloads"),
                                                 runningBundlePath: "/Users/niall/Downloads/WhisperFlow.app"),
                       "/Applications/WhisperFlow.app")
    }

    // MARK: - Progress

    func testThePercentageIsWhatTheServerSaidAndNothingWhenItSaidNothing() {
        XCTAssertEqual(SelfUpdater.downloadPercent(received: 43, expected: 100), 43)
        XCTAssertEqual(SelfUpdater.downloadPercent(received: 0, expected: 100), 0)
        XCTAssertEqual(SelfUpdater.downloadPercent(received: 100, expected: 100), 100)
        XCTAssertEqual(SelfUpdater.downloadPercent(received: 150, expected: 100), 100)
        XCTAssertNil(SelfUpdater.downloadPercent(received: 5_000, expected: -1))
        XCTAssertNil(SelfUpdater.downloadPercent(received: 5_000, expected: 0))
    }

    // MARK: - The exact copy

    func testTheWordingIsExactAndCarriesNoDashes() {
        XCTAssertEqual(SelfUpdater.downloadingText(percent: 43), "Downloading update 43%")
        XCTAssertEqual(SelfUpdater.downloadingText(percent: nil), "Downloading update…")
        XCTAssertEqual(SelfUpdater.failedText(reason: "macOS did not accept the new copy"),
                       "Update failed: macOS did not accept the new copy, download from Flow")
        XCTAssertEqual(SelfUpdater.updatedText(version: "2026.9.10"), "Updated to v2026.9.10")
        XCTAssertEqual(SelfUpdater.updatedText(version: "v2026.9.10"), "Updated to v2026.9.10")
        XCTAssertEqual(SelfUpdater.moveAlertTitle, "Move Whisper Flow to Applications?")
        XCTAssertEqual(SelfUpdater.moveAlertBody(folder: "Downloads"),
                       "It is running from Downloads. Moving it to Applications means updates and macOS permissions stick.")
        XCTAssertEqual(SelfUpdater.moveButtonTitle, "Move")
        XCTAssertEqual(SelfUpdater.notNowButtonTitle, "Not now")
        for copy in [SelfUpdater.downloadingText(percent: 43),
                     SelfUpdater.failedText(reason: "x"),
                     SelfUpdater.updatedText(version: "2026.9.10"),
                     SelfUpdater.moveAlertTitle,
                     SelfUpdater.moveAlertBody(folder: "Downloads")] {
            XCTAssertFalse(copy.contains("\u{2014}"))
            XCTAssertFalse(copy.contains("\u{2013}"))
        }
    }

    // MARK: - The pill

    func testTheDownloadPillStaysUpAndTheOthersHideThemselves() {
        XCTAssertFalse(PillState.updateDownloading(percent: 43).isTerminal)
        XCTAssertTrue(PillState.updateFailed("no").isTerminal)
        XCTAssertTrue(PillState.updated(version: "2026.9.10").isTerminal)
        XCTAssertEqual(PillState.updateFailed("no").autoHideSeconds, 8.0)
        XCTAssertEqual(PillState.updated(version: "2026.9.10").autoHideSeconds, 4.0)
    }
}
