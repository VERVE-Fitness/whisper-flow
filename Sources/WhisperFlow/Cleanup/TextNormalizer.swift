import Foundation

/// Deterministic text hygiene applied regardless of which path produced the
/// text (STT directly, LLM cleanup, or the raw fallback) -- so spacing is
/// never dependent on an LLM getting it right.
enum TextNormalizer {
    /// Fixes two things Parakeet's sliding-window transcription is prone to:
    /// runs of whitespace at window-boundary joins, and -- more visibly --
    /// sentence boundaries glued together with no space at all (e.g.
    /// "Is it worth it?Or should we focus on...").
    ///
    /// Newlines are preserved (only collapsed within a line) so that the
    /// list-formatting cleanup rule ("1. X\n2. Y") survives this pass instead
    /// of being flattened back into one line -- this used to collapse ALL
    /// whitespace including "\n" via a single "\\s+" regex.
    static func normalizeSentenceSpacing(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        let lines = text.components(separatedBy: "\n")
        let normalizedLines = lines.map { line -> String in
            var result = line.replacingOccurrences(
                of: "[ \\t]+", with: " ", options: .regularExpression
            )
            // A sentence terminator directly followed by an uppercase letter with
            // no space is always a missing sentence break, never legitimate
            // punctuation (decimals like "3.14" aren't touched: the next
            // character there is a digit, not an uppercase letter). An optional
            // quote/quote-like character between the two is carried through, so
            // `he said "stop."Then he left.` also gets split correctly.
            result = result.replacingOccurrences(
                of: "([.?!])([\"'\u{201C}\u{2018}]?[A-Z])", with: "$1 $2", options: .regularExpression
            )
            return result.trimmingCharacters(in: .whitespaces)
        }

        return normalizedLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
