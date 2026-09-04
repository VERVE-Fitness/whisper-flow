import Foundation
import AppKit

/// The gate every meeting recording passes through. The wording is the
/// artefact the lawyer reads (design O1) and is versioned so meeting.json
/// records exactly what the person saw. Bump `wordingVersion` whenever the
/// text changes.
enum ConsentGate {
    static let wordingVersion = "consent-v1"

    static func wording(managerName: String?) -> (title: String, body: String, confirm: String, cancel: String) {
        let manager = managerName.map { "your manager, \($0), can play it back" } ?? "your manager can play it back"
        let body = """
        Tell everyone on the call first. Say something like "I'm recording this for notes, is that OK with everyone?" and wait for them to answer.

        What happens: the audio and a transcript are saved to VERVE's system. You and \(manager). The audio is deleted after 90 days; the transcript and summary are kept. You can delete either at any time from Flow.
        """
        return ("Record this meeting?", body, "I've told everyone and they're OK with it", "Cancel")
    }

    /// Modal alert; the default button is Cancel so a stray Return cannot
    /// confirm. Returns the consent record on confirm, nil on cancel.
    @MainActor
    static func present(managerName: String?) async -> MeetingConsent? {
        let w = wording(managerName: managerName)
        let alert = NSAlert()
        alert.messageText = w.title
        alert.informativeText = w.body
        alert.alertStyle = .informational
        alert.addButton(withTitle: w.cancel)
        alert.addButton(withTitle: w.confirm)
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertSecondButtonReturn else { return nil }
        return MeetingConsent(confirmedAt: Date(), wordingVersion: wordingVersion)
    }
}
