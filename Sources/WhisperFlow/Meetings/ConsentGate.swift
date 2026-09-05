import Foundation
import AppKit

/// The gate every meeting recording passes through. The wording is the
/// artefact the lawyer reads (design O1) and is versioned so meeting.json
/// records exactly what the person saw. Bump `wordingVersion` whenever the
/// text changes.
///
/// v2 (week 2) says out loud that the recording leaves this Mac, because from
/// this week it does: the audio, transcript and summary go to Flow, which is
/// why "Record meeting" refuses to start until the Mac is connected.
enum ConsentGate {
    static let wordingVersion = "consent-v2"

    static func wording() -> (title: String, body: String, confirm: String, cancel: String) {
        let body = """
        Tell everyone on the call first. Say something like "I'm recording this for notes, is that OK with everyone?" and wait for them to answer.

        What happens: the audio and a transcript are saved to VERVE's system (Flow). You and your manager can play it back. The audio is deleted after 90 days; the transcript and summary are kept. You can delete either at any time from Flow.
        """
        return ("Record this meeting?", body, "I've told everyone and they're OK with it", "Cancel")
    }

    /// Modal alert; Cancel is added first so it is the default button and a
    /// stray Return cannot start a recording. Returns the consent record on
    /// confirm, nil on cancel.
    @MainActor
    static func present() async -> MeetingConsent? {
        let w = wording()
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

    /// Shown before the consent gate when Flow already has a bot on this
    /// meeting (see BotAwareness). "Let the bot do it" is added first, so it
    /// is the default button and doing nothing is what a stray Return does.
    /// Returns true when the person chose to record here as well.
    @MainActor
    static func presentBotAlreadyRecording(title: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "VERVE Notes is already recording \(title) into Flow. Recording here as well would give you two copies."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Let the bot do it")
        alert.addButton(withTitle: "Record here anyway")
        NSApp.activate(ignoringOtherApps: true)
        let recordAnyway = alert.runModal() == .alertSecondButtonReturn
        FileHandle.standardError.write(Data("[bot] the person chose \(recordAnyway ? "record here anyway" : "let the bot do it")\n".utf8))
        return recordAnyway
    }

    /// Shown instead of the consent gate when this Mac has no Flow token. The
    /// consent wording promises the recording reaches VERVE's system, so it
    /// must not be shown on a Mac where that cannot happen.
    @MainActor
    static func presentNotConnected(settingsURL: URL) {
        let alert = NSAlert()
        alert.messageText = "Connect this Mac to Flow first"
        alert.informativeText = """
        Meeting recordings are saved to Flow, so this Mac has to be connected before it can record one.

        Open the Whisper Flow settings page, create a connection for this Mac, then click "Open in Whisper Flow".
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open the settings page")
        alert.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(settingsURL)
        }
    }
}
