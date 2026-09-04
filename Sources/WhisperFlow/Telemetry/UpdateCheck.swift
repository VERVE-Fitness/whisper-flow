import Foundation

/// Once-a-launch (and every 6 h thereafter) check of the GitHub release feed
/// so the menu bar can say "Update available" -- without this, a colleague
/// who installed once never finds out a fix shipped. Sends nothing but the
/// request itself (no identifiers, no usage data); the only network traffic
/// this app otherwise makes is the one-time model downloads.
///
/// Release tags are `v<date>-<short sha>`; the running build carries its
/// short sha in Info.plist (`WFGitCommit`, stamped by make-app.sh). "Newer"
/// is therefore "the latest release's tag does not end in our sha", which
/// stays correct even if the version string were ever left un-bumped.
enum UpdateCheck {
    struct Result: Equatable {
        let tag: String
        let downloadPage: URL
    }

    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/VERVE-Fitness/whisper-flow/releases/latest")!
    static let downloadPage = URL(string: "https://flow.vervefitness.ai/whisper")!
    static let interval: TimeInterval = 6 * 60 * 60

    /// Returns a Result when a different build is published, nil when this
    /// build is current or the check couldn't be made (offline, rate limit).
    static func check(currentCommit: String?) async -> Result? {
        var request = URLRequest(url: latestReleaseAPI)
        request.timeoutInterval = 8
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { return nil }
        guard let currentCommit, !currentCommit.isEmpty, currentCommit != "unknown" else {
            // Dev build with no stamped commit: never nag.
            return nil
        }
        if tag.hasSuffix("-" + currentCommit) { return nil }
        return Result(tag: tag, downloadPage: downloadPage)
    }
}
