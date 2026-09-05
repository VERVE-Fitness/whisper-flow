import Foundation

/// Parses the `whisperflow://connect?token=…&server=…` link the Flow settings
/// page hands out. Pure and tested, because the alternative is discovering a
/// parsing bug while a colleague stands over a Mac that will not connect.
///
/// The link is the only way a token reaches this app: nothing is typed, and
/// the token is never written to stderr, a log or UserDefaults.
enum FlowConnectURL {
    static let scheme = "whisperflow"
    static let host = "connect"

    struct Connect: Equatable {
        let token: String
        /// Absent when the link did not name one, which means production.
        let server: String?
    }

    static func parse(_ url: URL) -> Connect? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        // A URL with no path ("whisperflow://connect?…") puts "connect" in the
        // host; one written with a slash ("whisperflow:///connect?…") puts it
        // in the path. Accept both rather than make the page get it exactly right.
        let action = (url.host?.lowercased()).flatMap { $0.isEmpty ? nil : $0 }
            ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard action == host else { return nil }
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let token = items.first { $0.name == "token" }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token, !token.isEmpty else { return nil }
        var server = items.first { $0.name == "server" }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let s = server, s.isEmpty { server = nil }
        if let s = server, !(s.hasPrefix("http://") || s.hasPrefix("https://")) { server = nil }
        return Connect(token: token, server: server.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 })
    }

    /// What is safe to print when a link arrives: the action and the server,
    /// never the token.
    static func redacted(_ url: URL) -> String {
        let action = url.host ?? url.path
        let server = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "server" }?.value
        return "\(url.scheme ?? "?")://\(action) server=\(server ?? "(default)") token=(hidden)"
    }
}
