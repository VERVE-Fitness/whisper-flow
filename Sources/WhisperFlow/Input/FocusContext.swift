import Foundation
import ApplicationServices

/// Reads the text immediately before the caret in the frontmost focused
/// element, via the Accessibility API, for use as spelling context by the
/// cleanup LLM (feature: context-aware spelling). Best-effort only -- returns
/// nil on any failure (no focused element, no caret, app doesn't support the
/// parameterized string-for-range query, etc.), same posture as
/// TextInserter.characterBeforeCaret.
enum FocusContext {
    /// How much text before the caret to capture. Large enough to give the
    /// LLM real spelling context (a sentence or two) without bloating the
    /// prompt.
    private static let maxContextChars = 400

    /// Captured ONCE at recording start (see AppState.beginDictation) rather
    /// than at stop time -- by the time recording stops, our own status pill
    /// or transcript window may have taken focus, and re-reading then would
    /// see the wrong element (or none).
    static func captureBeforeCaret() -> String? {
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

        let length = min(range.location, maxContextChars)
        let start = range.location - length
        var priorRange = CFRange(location: start, length: length)
        guard let priorRangeValue = AXValueCreate(.cfRange, &priorRange) else { return nil }

        var stringRef: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, priorRangeValue, &stringRef
        )
        guard err == .success, let string = stringRef as? String, !string.isEmpty else { return nil }
        return string
    }
}
