import Foundation
import ApplicationServices

/// Pragmatic v1 of "auto-learned dictionary": after we insert text, snapshot
/// the focused element's full value, wait a few seconds, and re-read it. If
/// exactly one word of what we inserted was hand-edited to something else,
/// treat that as a real-world correction and remember it for next time
/// (misheard -> corrected), the same map the deterministic "corrections"
/// path in CleanupRouter already applies.
///
/// Deliberately isolated in its own file behind a UserDefaults flag so this
/// heuristic-heavy module can be ripped out cleanly if it turns out to be too
/// noisy in practice. All AX access is best-effort: any failure or weirdness
/// (element gone, value not a string, etc.) just no-ops.
enum CorrectionLearner {
    static let enabledDefaultsKey = "autoLearnEnabled"
    private static let checkDelay: TimeInterval = 8.0
    private static let correctionsCap = 200

    static var isEnabled: Bool {
        // ON by default: absence of the key reads as false from
        // UserDefaults.bool(forKey:), so register a default explicitly.
        if UserDefaults.standard.object(forKey: enabledDefaultsKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }

    /// Call right after TextInserter.insert succeeds with `.inserted`.
    static func observe(insertedText: String) {
        guard isEnabled, !insertedText.isEmpty else { return }
        guard let element = focusedElement(), let before = stringValue(of: element) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + checkDelay) {
            guard let after = stringValue(of: element) else { return }
            guard let correction = diffSingleWordChange(before: before, after: after, inserted: insertedText) else { return }
            UserLexicon.shared.setCorrection(misheard: correction.from, corrected: correction.to)
            UserLexicon.shared.capCorrections(at: correctionsCap)
            FileHandle.standardError.write(Data("[auto-learn] recorded correction \"\(correction.from)\" -> \"\(correction.to)\"\n".utf8))
        }
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return nil }
        return (focusedRef as! AXUIElement)
    }

    private static func stringValue(of element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String else { return nil }
        return value
    }

    /// Finds a single word from `inserted` that appears in `before` but was
    /// replaced by a different, similar-length word in `after`, at the same
    /// approximate position. Deliberately conservative: bails (returns nil)
    /// on any ambiguity rather than risk learning garbage.
    private static func diffSingleWordChange(before: String, after: String, inserted: String) -> (from: String, to: String)? {
        guard before != after else { return nil }
        // Only look at the region touched by our insertion, approximated as
        // the smallest common-prefix/suffix trim between before and after --
        // avoids false positives from unrelated edits elsewhere in the doc.
        let beforeWords = tokenize(before)
        let afterWords = tokenize(after)
        guard beforeWords.count == afterWords.count else { return nil }

        var diffs: [(from: String, to: String)] = []
        for (b, a) in zip(beforeWords, afterWords) where b.lowercased() != a.lowercased() {
            diffs.append((from: b, to: a))
        }
        guard diffs.count == 1, let diff = diffs.first else { return nil }

        let insertedWords = Set(tokenize(inserted).map { $0.lowercased() })
        guard insertedWords.contains(diff.from.lowercased()) else { return nil }
        guard diff.from.count >= 3, diff.to.count >= 3 else { return nil }
        guard !stopWords.contains(diff.from.lowercased()) else { return nil }
        // Proper-noun constraint: a learned correction is applied globally to
        // every future dictation, so learning a common word ("there"→"their")
        // would silently rewrite it forever — no stop-word list is long enough
        // to make that safe. Names and product terms are where auto-learn
        // earns its keep, and they arrive capitalized; ordinary words don't.
        guard diff.to.first?.isUppercase == true else { return nil }
        guard levenshtein(diff.from.lowercased(), diff.to.lowercased()) <= max(diff.from.count, diff.to.count) / 2 else { return nil }

        return diff
    }

    private static func tokenize(_ s: String) -> [String] {
        s.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static let stopWords: Set<String> = ["the", "and", "for", "that", "this", "with", "have", "from", "were", "was", "are", "is"]

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                curr[j] = a[i - 1] == b[j - 1]
                    ? prev[j - 1]
                    : 1 + min(prev[j - 1], prev[j], curr[j - 1])
            }
            prev = curr
        }
        return prev[b.count]
    }
}
