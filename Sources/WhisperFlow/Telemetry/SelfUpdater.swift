import Foundation
import AppKit

/// One-click update. Until this existed, "install the new version" meant
/// quit, download a zip, open Finder, drag it over the old copy and click
/// Replace -- which on 5 Sep 2026 produced both failure modes in one
/// morning: two copies running at once (one still in Downloads, one in
/// Applications) and a stale copy in Applications after a replace that never
/// happened. Clicking the menu item now does the whole thing: download,
/// check the copy is really ours, put it in place, restart.
///
/// Nothing here runs on its own. There is no auto-install and no background
/// download: the person clicks "Update available", and every step logs one
/// `[update] ...` line to stderr so a failure can be read back afterwards.
/// Any failure leaves the running app exactly as it was.
enum SelfUpdater {

    // MARK: - Exact wording
    //
    // Kept here, not inline in the views, so the tests can hold the copy to
    // the word and nobody re-words a message by accident.

    static let moveAlertTitle = "Move Whisper Flow to Applications?"
    static let moveButtonTitle = "Move"
    static let notNowButtonTitle = "Not now"

    static func moveAlertBody(folder: String) -> String {
        "It is running from \(folder). Moving it to Applications means updates and macOS permissions stick."
    }

    /// "Downloading update 43%". A server that does not say how big the file
    /// is leaves the percentage out rather than inventing one.
    static func downloadingText(percent: Int?) -> String {
        guard let percent else { return "Downloading update…" }
        return "Downloading update \(percent)%"
    }

    static func failedText(reason: String) -> String {
        "Update failed: \(reason), download from Flow"
    }

    /// The version is stored without a leading "v" in Info.plist; a stray one
    /// would read "vv2026.9.10".
    static func updatedText(version: String) -> String {
        var v = version
        if v.hasPrefix("v") { v.removeFirst() }
        return "Updated to v\(v)"
    }

    // MARK: - Launch arguments
    //
    // The replacement copy is started with one of these so it knows it is a
    // relaunch and not a second person double-clicking the app: SingleInstance
    // must let it live and shut the outgoing copy down, not the other way
    // round.

    static let relaunchedAfterUpdateArgument = "--relaunched-after-update"
    static let relaunchedAfterMoveArgument = "--relaunched-after-move"

    static func didSelfUpdate(arguments: [String]) -> Bool {
        arguments.contains(relaunchedAfterUpdateArgument)
    }

    static func isReplacementLaunch(arguments: [String]) -> Bool {
        arguments.contains(relaunchedAfterUpdateArgument) || arguments.contains(relaunchedAfterMoveArgument)
    }

    // MARK: - Pure decisions

    /// Percentage for the pill, or nil when the size is unknown (a server
    /// that streams without a Content-Length reports -1).
    static func downloadPercent(received: Int64, expected: Int64) -> Int? {
        guard expected > 0, received >= 0 else { return nil }
        let pct = Int((Double(received) / Double(expected) * 100).rounded(.down))
        return min(max(pct, 0), 100)
    }

    /// Release tags are `vYYYY.MM.DD-<short sha>`, so the sha is whatever
    /// follows the last dash. A tag with no dash, or nothing after it, is not
    /// a tag this app can check a build against.
    static func shortSHA(fromTag tag: String) -> String? {
        guard let dash = tag.lastIndex(of: "-") else { return nil }
        let sha = String(tag[tag.index(after: dash)...])
        return sha.isEmpty ? nil : sha
    }

    /// What `spctl --assess --type exec -vv` said. Its verdict is on stdout,
    /// the `source=`/`origin=` lines on stderr; both are read together.
    struct SpctlVerdict: Equatable {
        let accepted: Bool
        let source: String?

        /// A Developer ID build, notarised, is the only thing worth putting on
        /// top of a running app. "source=Notarized Developer ID" is what a
        /// released build says; an ad-hoc or Apple Development build says
        /// something else, and a tampered one is rejected outright.
        var isDeveloperID: Bool {
            (source ?? "").localizedCaseInsensitiveContains("Developer ID")
        }
    }

    static func parseSpctl(exitCode: Int32, output: String) -> SpctlVerdict {
        var source: String?
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("source=") {
                source = String(line.dropFirst("source=".count))
            }
        }
        return SpctlVerdict(accepted: exitCode == 0 && output.contains("accepted"), source: source)
    }

    /// Everything that can stop an update, each with the phrase the pill
    /// shows. Short, and it names the step that failed so a screenshot is
    /// enough to tell what happened.
    enum Failure: Error, Equatable {
        case download(String)
        case unpack
        case noBundle
        case gatekeeper
        case notDeveloperID
        case wrongBuild(expected: String, found: String?)
        case badTag(String)
        case replace(String)
        case relaunch
        case notPackagedBuild

        var reason: String {
            switch self {
            case .download: return "the download did not finish"
            case .notPackagedBuild: return "this copy was not built for release"
            case .unpack: return "the download could not be unpacked"
            case .noBundle: return "the download did not contain the app"
            case .gatekeeper: return "macOS did not accept the new copy"
            case .notDeveloperID: return "the new copy is not signed by VERVE"
            case .wrongBuild: return "the new copy is not the published build"
            case .badTag: return "the release could not be read"
            case .replace: return "the app could not be replaced"
            case .relaunch: return "the new copy would not start"
            }
        }
    }

    /// The gate between "a zip finished downloading" and "this is going on
    /// top of the app that is running". Both halves matter: Gatekeeper says
    /// the bundle is intact and signed by us, the commit says it is the build
    /// the release feed advertised rather than an older asset re-uploaded
    /// under a new tag.
    static func verify(spctl: SpctlVerdict, bundleCommit: String?, tag: String) -> Failure? {
        guard spctl.accepted else { return .gatekeeper }
        guard spctl.isDeveloperID else { return .notDeveloperID }
        guard let expected = shortSHA(fromTag: tag) else { return .badTag(tag) }
        guard let found = bundleCommit, !found.isEmpty, found != "unknown" else {
            return .wrongBuild(expected: expected, found: bundleCommit)
        }
        guard found == expected else { return .wrongBuild(expected: expected, found: found) }
        return nil
    }

    /// Where the running copy lives. `/Applications` and `~/Applications` are
    /// both real installs; everything else (Downloads, Desktop, a mounted
    /// disk image) is a copy someone is running where it landed.
    enum InstallLocation: Equatable {
        case applications
        case userApplications
        case elsewhere(folder: String)

        var isInstalled: Bool {
            switch self {
            case .applications, .userApplications: return true
            case .elsewhere: return false
            }
        }
    }

    static func classify(bundlePath: String, home: String) -> InstallLocation {
        let path = normalise(bundlePath)
        let userApps = normalise(home) + "/Applications/"
        if path.hasPrefix("/Applications/") { return .applications }
        if path.hasPrefix(userApps) { return .userApplications }
        return .elsewhere(folder: folderName(of: path))
    }

    /// Display name of the folder a bundle sits in, for the alert.
    static func folderName(of bundlePath: String) -> String {
        let path = normalise(bundlePath)
        let parent = (path as NSString).deletingLastPathComponent
        if parent.isEmpty || parent == "/" { return "the top level of this Mac" }
        return (parent as NSString).lastPathComponent
    }

    /// Updating in place keeps the app where it already is; updating a copy
    /// that was never installed puts it in `/Applications`, which is the
    /// whole point of the move.
    static func installTarget(for location: InstallLocation, runningBundlePath: String) -> String {
        location.isInstalled ? normalise(runningBundlePath) : "/Applications/WhisperFlow.app"
    }

    /// "Not now" is remembered per source path, so a copy in Downloads asks
    /// once and a different copy somewhere else still gets its own ask.
    static let declinedMoveDefaultsKey = "declinedMoveToApplicationsPaths"

    static func shouldOfferMove(location: InstallLocation, bundlePath: String, declinedPaths: [String]) -> Bool {
        guard !location.isInstalled else { return false }
        return !declinedPaths.contains(normalise(bundlePath))
    }

    private static func normalise(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    // MARK: - The one pill a launch shows

    /// After a self-update the pill says so; but if macOS dropped the
    /// Accessibility grant with the binary, that ask wins, because it is the
    /// one message that needs something done about it. Both are driven off
    /// the stored-version key, which the update path does not touch, so the
    /// re-ask still fires on the launch that follows an update.
    static func launchPill(didSelfUpdate: Bool, accessibilityReask: Bool, version: String) -> PillState? {
        if accessibilityReask { return .accessibilityAfterUpdate }
        if didSelfUpdate { return .updated(version: version) }
        return nil
    }

    // MARK: - Doing it

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[update] \(message)\n".utf8))
    }

    /// Download, check, and put the new copy in place. Returns where it was
    /// installed. Throws before touching anything on disk if any check fails,
    /// so the running app survives every failure path.
    static func installUpdate(tag: String,
                              from zipURL: URL,
                              runningBundlePath: String,
                              home: String = NSHomeDirectory(),
                              progress: @escaping @Sendable (Int?) -> Void) async throws -> URL {
        guard isPackagedBuild else {
            log("not a packaged build (no WFBuildDate); refusing to install an update over anything")
            throw Failure.notPackagedBuild
        }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperflow-update-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        log("downloading \(tag) from \(zipURL.absoluteString)")
        let zip = work.appendingPathComponent("WhisperFlow.zip")
        try await download(zipURL, to: zip, progress: progress)
        let size = (try? FileManager.default.attributesOfItem(atPath: zip.path))?[.size] as? Int64
        log("downloaded \(size ?? 0) bytes")

        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let (dittoCode, dittoOut) = run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        guard dittoCode == 0 else {
            log("ditto failed (\(dittoCode)): \(dittoOut)")
            throw Failure.unpack
        }
        let newBundle = unpacked.appendingPathComponent("WhisperFlow.app")
        guard FileManager.default.fileExists(atPath: newBundle.path) else {
            log("no WhisperFlow.app at the top level of the archive")
            throw Failure.noBundle
        }
        log("unpacked to \(newBundle.path)")

        let (spctlCode, spctlOut) = run("/usr/sbin/spctl", ["--assess", "--type", "exec", "-vv", newBundle.path])
        let verdict = parseSpctl(exitCode: spctlCode, output: spctlOut)
        let commit = (NSDictionary(contentsOf: newBundle.appendingPathComponent("Contents/Info.plist"))?["WFGitCommit"]) as? String
        log("spctl accepted=\(verdict.accepted) source=\(verdict.source ?? "none") commit=\(commit ?? "none")")
        if let failure = verify(spctl: verdict, bundleCommit: commit, tag: tag) {
            log("refusing to install: \(failure.reason)")
            throw failure
        }

        let location = classify(bundlePath: runningBundlePath, home: home)
        let target = URL(fileURLWithPath: installTarget(for: location, runningBundlePath: runningBundlePath))
        if !location.isInstalled {
            log("running from \(folderName(of: runningBundlePath)); installing to \(target.path) instead of replacing in place")
        }
        try put(newBundle, at: target)
        log("installed \(tag) at \(target.path)")
        return target
    }

    /// Move the new bundle over the old one. The old one goes to the Trash
    /// rather than being deleted, so a bad build is one drag away from being
    /// undone.
    static func put(_ newBundle: URL, at target: URL) throws {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: target.path) {
                var trashed: NSURL?
                try fm.trashItem(at: target, resultingItemURL: &trashed)
                log("moved the old copy to the Trash")
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try fm.moveItem(at: newBundle, to: target)
            } catch {
                // A read-only source (a mounted disk image) cannot be moved.
                try fm.copyItem(at: newBundle, to: target)
            }
        } catch {
            log("could not put the new copy in place: \(error.localizedDescription)")
            throw Failure.replace(error.localizedDescription)
        }
    }

    /// Start the copy at `target` as a separate instance and quit this one
    /// once it is up. The argument is how the new process knows it is the
    /// replacement (see SingleInstance).
    @MainActor
    static func relaunch(at target: URL, argument: String) async throws {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = [argument]
        config.activates = true
        do {
            let app = try await NSWorkspace.shared.openApplication(at: target, configuration: config)
            log("relaunched \(target.path) as pid \(app.processIdentifier); quitting this copy")
        } catch {
            log("could not relaunch \(target.path): \(error.localizedDescription)")
            throw Failure.relaunch
        }
        NSApp.terminate(nil)
    }

    // MARK: - Move to Applications

    /// Offered once per source path, at launch, when the app is running from
    /// somewhere that is not an Applications folder. "Move" installs it the
    /// same way an update does and restarts from the new place.
    /// Only a bundle that came out of scripts/make-app.sh carries WFBuildDate.
    /// A `swift build` debug binary, a test host, or a helper app somebody
    /// made to look at a window is not that, and must never move itself
    /// into Applications or replace what is there. On 5 Sep 2026 a debug
    /// copy did exactly that on Niall's Mac: it moved his real app to the
    /// Trash and installed itself in its place. Never again.
    static var isPackagedBuild: Bool {
        Bundle.main.infoDictionary?["WFBuildDate"] as? String != nil
            && Bundle.main.infoDictionary?["WFGitCommit"] as? String != nil
    }

    @MainActor
    static func offerMoveToApplications(bundlePath: String,
                                        home: String = NSHomeDirectory(),
                                        defaults: UserDefaults = .standard) async {
        guard isPackagedBuild else {
            log("not a packaged build (no WFBuildDate); never offering to move or install")
            return
        }
        let location = classify(bundlePath: bundlePath, home: home)
        let declined = defaults.stringArray(forKey: declinedMoveDefaultsKey) ?? []
        guard shouldOfferMove(location: location, bundlePath: bundlePath, declinedPaths: declined) else { return }
        guard case .elsewhere(let folder) = location else { return }

        log("running from \(folder); offering to move to Applications")
        let alert = NSAlert()
        alert.messageText = moveAlertTitle
        alert.informativeText = moveAlertBody(folder: folder)
        alert.addButton(withTitle: moveButtonTitle)
        alert.addButton(withTitle: notNowButtonTitle)
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            log("not now; this copy will not be asked about again")
            defaults.set(declined + [(bundlePath as NSString).standardizingPath], forKey: declinedMoveDefaultsKey)
            return
        }

        let source = URL(fileURLWithPath: bundlePath)
        let target = URL(fileURLWithPath: "/Applications/WhisperFlow.app")
        do {
            try put(source, at: target)
            log("moved to \(target.path)")
            try await relaunch(at: target, argument: relaunchedAfterMoveArgument)
        } catch {
            log("move failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Thin shells over the file system and processes

    private static func run(_ launchPath: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "could not run \(launchPath): \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func download(_ url: URL,
                                 to destination: URL,
                                 progress: @escaping @Sendable (Int?) -> Void) async throws {
        let delegate = DownloadReporter(destination: destination, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    /// URLSession's byte-by-byte async sequence is far too slow for a bundle
    /// this size, so the download is a plain download task with a delegate
    /// that reports progress and moves the finished file before the system
    /// deletes it.
    private final class DownloadReporter: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let destination: URL
        private let progress: @Sendable (Int?) -> Void
        private var lastPercent: Int?
        private var finished = false
        private let lock = NSLock()
        var continuation: CheckedContinuation<Void, Error>?

        init(destination: URL, progress: @escaping @Sendable (Int?) -> Void) {
            self.destination = destination
            self.progress = progress
        }

        private func finish(_ result: Result<Void, Error>) {
            lock.lock()
            let alreadyDone = finished
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            guard !alreadyDone else { return }
            continuation?.resume(with: result)
        }

        func urlSession(_ session: URLSession,
                        downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            let percent = SelfUpdater.downloadPercent(received: totalBytesWritten, expected: totalBytesExpectedToWrite)
            guard percent != lastPercent else { return }
            lastPercent = percent
            progress(percent)
        }

        func urlSession(_ session: URLSession,
                        downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                finish(.failure(Failure.download("HTTP \(http.statusCode)")))
                return
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                finish(.success(()))
            } catch {
                finish(.failure(Failure.download(error.localizedDescription)))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                finish(.failure(Failure.download(error.localizedDescription)))
            } else {
                finish(.success(()))
            }
        }
    }
}
