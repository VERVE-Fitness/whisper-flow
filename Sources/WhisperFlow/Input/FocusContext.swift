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

    /// Per-call cap inside the accessibility API. An AX query is a synchronous
    /// round trip into ANOTHER process, and the default timeout is measured in
    /// several seconds; an app that is beachballing, paused in a debugger or
    /// mid-launch keeps the caller waiting for all of it. Nothing here is worth
    /// a third of a second, let alone six, so every element we query is told so
    /// explicitly. On expiry the query returns .cannotComplete, which reads
    /// exactly like "this app can't answer" -- the case this code already
    /// handled by returning nil.
    static let messagingTimeout: Float = 0.3
    /// Cap on the whole read, in case a target app answers each individual
    /// query just inside the per-call timeout.
    static let overallTimeout: TimeInterval = 0.5

    /// Captured ONCE at recording start (see AppState.beginDictation) rather
    /// than at stop time -- by the time recording stops, our own status pill
    /// or transcript window may have taken focus, and re-reading then would
    /// see the wrong element (or none).
    ///
    /// Runs off the main actor and returns nil rather than waiting forever:
    /// this used to be a synchronous main-actor call, so a target app that
    /// could not answer froze the pill, the hotkey tap and the start of the
    /// recording itself.
    static func captureBeforeCaret(timeout: TimeInterval = overallTimeout) async -> String? {
        do {
            return try await withHardTimeout(seconds: timeout) { blockingCaptureBeforeCaret() }
        } catch {
            FileHandle.standardError.write(Data("[ax] focus context read did not answer within \(timeout)s; dictating without spelling context\n".utf8))
            return nil
        }
    }

    /// The accessibility round trip itself. Synchronous by nature (the API has
    /// no async form); never call it on the main actor.
    static func blockingCaptureBeforeCaret() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        _ = AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return nil }
        let element = focusedRef as! AXUIElement
        _ = AXUIElementSetMessagingTimeout(element, messagingTimeout)

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
