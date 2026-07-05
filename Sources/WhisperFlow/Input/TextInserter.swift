import Foundation
import AppKit
import CoreGraphics

/// Inserts text at the frontmost app's cursor by round-tripping the general
/// pasteboard and synthesizing Cmd+V, then restoring whatever was previously
/// on the pasteboard. Never activates our own app, so the target app keeps
/// focus throughout.
enum TextInserter {
    private static let restoreDelay: TimeInterval = 0.3

    enum Outcome {
        case inserted
        case copiedOnly   // Accessibility not granted; text left on the clipboard.
    }

    /// Insert `text` at the current cursor position if Accessibility is
    /// trusted; otherwise just place it on the clipboard so the user can
    /// paste manually.
    static func insert(_ text: String, accessibilityTrusted: Bool) -> Outcome {
        guard accessibilityTrusted else {
            copyToPasteboard(text)
            return .copiedOnly
        }

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        let previousChangeCount = pasteboard.changeCount

        copyToPasteboard(text)
        synthesizeCmdV()

        // Restore the previous clipboard contents shortly after, but only if
        // nothing else has touched the pasteboard in the meantime (avoid
        // clobbering something the user copied right after dictation).
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            guard pasteboard.changeCount == previousChangeCount + 1 else { return }
            if let previous {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            } else {
                pasteboard.clearContents()
            }
        }

        return .inserted
    }

    private static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Post a synthetic Cmd+V (key down then up) to the system HID event tap.
    private static func synthesizeCmdV() {
        let vKeyCode: CGKeyCode = 9 // kVK_ANSI_V
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
