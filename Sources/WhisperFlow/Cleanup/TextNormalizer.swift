import Foundation

/// Deterministic text hygiene applied regardless of which path produced the
/// text (STT directly, LLM cleanup, or the raw fallback) — so spacing is
/// never dependent on an LLM getting it right.
enum TextNormalizer {
    /// Fixes two things Parakeet's sliding-window transcription is prone to:
    /// runs of whitespace at window-boundary joins, and — more visibly —
    /// sentence boundaries glued together with no space at all (e.g.
    /// "Is it worth it?Or should we focus on...").
    static func normalizeSentenceSpacing(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression
        )
        // A sentence terminator directly followed by an uppercase letter with
        // no space is always a missing sentence break, never legitimate
        // punctuation (decimals like "3.14" aren't touched: the next
        // character there is a digit, not an uppercase letter).
        result = result.replacingOccurrences(
            of: "([.?!])([A-Z])", with: "$1 $2", options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
