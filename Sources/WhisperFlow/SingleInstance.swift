import Foundation
import AppKit

/// Only one Whisper Flow types into your Mac at a time.
///
/// On 5 Sep 2026 two copies ran at once: one still in Downloads, one in
/// Applications. Both held the Right Option hotkey, so a dictation went
/// through twice and the text arrived doubled. Nothing in macOS stops this:
/// two bundles at two paths are two apps as far as the launcher is
/// concerned, whatever their bundle identifier says.
///
/// So the first thing a launch does is look for another copy of the same
/// bundle identifier. The newer build wins and asks the older one to quit;
/// the older build, if it is the one launching, quits itself and says so on
/// stderr. Newer is by `WFBuildDate` (the stamp make-app.sh writes), falling
/// back to `CFBundleVersion` when a build has no stamp. On a tie the copy
/// that is already running keeps running: it is the one with the person's
/// permissions and their in-flight work.
enum SingleInstance {

    /// One copy of the app, as far as this decision cares.
    struct Copy: Equatable {
        let path: String
        let buildDate: String?
        let version: String?

        init(path: String, buildDate: String? = nil, version: String? = nil) {
            self.path = path
            self.buildDate = buildDate
            self.version = version
        }
    }

    enum Decision: Equatable {
        /// This launch is the one that should live; the other copy is asked
        /// to quit.
        case terminateOther
        /// This launch is the spare. It quits, with the reason on stderr.
        case quitSelf(reason: String)
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[instance] \(message)\n".utf8))
    }

    /// Pure. `isReplacementLaunch` is the copy a self-update or a move just
    /// started: it is by definition the one that should live, including when
    /// it was installed over the very path the outgoing copy is running from.
    static func decide(mine: Copy, other: Copy, isReplacementLaunch: Bool) -> Decision {
        if isReplacementLaunch {
            return .terminateOther
        }
        if standardise(mine.path) == standardise(other.path) {
            return .quitSelf(reason: "another copy is already running from the same place")
        }
        if let a = stamp(mine.buildDate), let b = stamp(other.buildDate), a != b {
            return a > b ? .terminateOther : .quitSelf(reason: "a newer copy is already running")
        }
        if let a = mine.version, let b = other.version, !a.isEmpty, !b.isEmpty, a != b {
            let order = a.compare(b, options: .numeric)
            return order == .orderedDescending
                ? .terminateOther
                : .quitSelf(reason: "a newer copy is already running")
        }
        return .quitSelf(reason: "another copy is already running")
    }

    static func stamp(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: iso)
    }

    private static func standardise(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    // MARK: - Doing it

    /// Called first thing at launch, before any window, hotkey or permission
    /// prompt exists. Skipped when there is no bundle (the CLI harnesses run
    /// the bare binary).
    @MainActor
    static func enforceAtLaunch(arguments: [String] = CommandLine.arguments) {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let isReplacement = SelfUpdater.isReplacementLaunch(arguments: arguments)
        let mine = Copy(path: Bundle.main.bundleURL.path,
                        buildDate: Bundle.main.infoDictionary?["WFBuildDate"] as? String,
                        version: Bundle.main.infoDictionary?["CFBundleVersion"] as? String)

        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
        guard !others.isEmpty else { return }

        for running in others {
            let other = describe(running)
            let decision = decide(mine: mine, other: other, isReplacementLaunch: isReplacement)
            log("this copy \(mine.path) (built \(mine.buildDate ?? "?"), \(mine.version ?? "?")) "
                + "vs pid \(running.processIdentifier) at \(other.path) (built \(other.buildDate ?? "?"), \(other.version ?? "?"))"
                + (isReplacement ? " [replacement launch]" : "")
                + " -> \(decision)")
            switch decision {
            case .quitSelf(let reason):
                log("quitting: \(reason)")
                exit(0)
            case .terminateOther:
                ask(running, toQuitFor: reason(for: mine, other: other, isReplacement: isReplacement))
            }
        }
    }

    private static func reason(for mine: Copy, other: Copy, isReplacement: Bool) -> String {
        isReplacement ? "this launch replaces it" : "this copy is newer"
    }

    /// Ask nicely, then insist. A menu bar app with no windows quits on the
    /// first ask; one stuck mid-dictation might not, and two copies holding
    /// the same hotkey is the thing being fixed.
    @MainActor
    private static func ask(_ running: NSRunningApplication, toQuitFor reason: String) {
        log("asking pid \(running.processIdentifier) to quit (\(reason))")
        running.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard !running.isTerminated else {
                log("pid \(running.processIdentifier) quit")
                return
            }
            log("pid \(running.processIdentifier) is still running after 3 s; forcing it")
            running.forceTerminate()
        }
    }

    private static func describe(_ running: NSRunningApplication) -> Copy {
        guard let url = running.bundleURL else {
            return Copy(path: running.executableURL?.path ?? "unknown")
        }
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        return Copy(path: url.path,
                    buildDate: info?["WFBuildDate"] as? String,
                    version: info?["CFBundleVersion"] as? String)
    }
}
