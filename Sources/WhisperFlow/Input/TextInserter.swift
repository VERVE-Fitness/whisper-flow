import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

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

        let toInsert = withLeadingSpaceIfNeeded(text)

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        let previousChangeCount = pasteboard.changeCount

        copyToPasteboard(toInsert)
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

    /// Prepends a space when it looks like this insertion is landing right
    /// after existing text with nothing separating them. Each dictation is
    /// cleaned and pasted independently — `TextNormalizer` fixes spacing
    /// *within* one utterance, but has no way to see what's already in the
    /// document. Two push-to-talk recordings in a row (release, pause,
    /// press again) each paste a complete, period-terminated block, and
    /// without this check they land glued together with zero space between
    /// them: "First sentence.Second sentence."
    ///
    /// Best-effort: if the frontmost app doesn't expose caret position via
    /// Accessibility (some Electron/web views don't), this silently no-ops
    /// and behaviour is unchanged from before.
    static func withLeadingSpaceIfNeeded(_ text: String) -> String {
        guard let first = text.first, !first.isWhitespace else { return text }
        // Punctuation that should never be preceded by a space anyway.
        let noSpaceBefore: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "\u{2019}", "\u{201D}"]
        guard !noSpaceBefore.contains(first) else { return text }

        guard let priorChar = characterBeforeCaret()?.first else { return text }
        if priorChar.isWhitespace || priorChar.isNewline { return text }
        // Don't add a space right after an opening bracket/quote.
        let noSpaceAfter: Set<Character> = ["(", "[", "{", "\u{201C}", "\u{2018}", "'", "\""]
        if noSpaceAfter.contains(priorChar) { return text }

        return " " + text
    }

    /// Reads the single character immediately before the text caret in the
    /// frontmost focused element, via the Accessibility API. Returns nil if
    /// there's no focused element, no caret, we're at the very start of the
    /// field, or the app doesn't support the parameterized string-for-range
    /// query (common in some web/Electron text fields) — any of which means
    /// "can't tell, don't guess."
    private static func characterBeforeCaret() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return nil }
        let element = focusedRef as! AXUIElement

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef else { return nil }

        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), range.location > 0 else { return nil }

        var priorRange = CFRange(location: range.location - 1, length: 1)
        guard let priorRangeValue = AXValueCreate(.cfRange, &priorRange) else { return nil }

        var stringRef: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, priorRangeValue, &stringRef
        )
        guard err == .success, let string = stringRef as? String, !string.isEmpty else { return nil }
        return string
    }
}
