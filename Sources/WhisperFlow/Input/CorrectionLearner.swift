import Foundation
import ApplicationServices

/// Pragmatic v1 of "auto-learned dictionary": after we insert text, snapshot
/// the focused element's full value, wait a few seconds, and re-read it. If a
/// run of up to four words of what we inserted was hand-edited into a
/// different run, treat that as a real-world correction and remember it for
/// next time (misheard -> corrected), the same map the deterministic
/// "corrections" path in CleanupRouter already applies. From week 3 the same
/// correction is also offered to Flow as a phrase suggestion, so one person's
/// fix can become the whole team's phrase once somebody accepts it on the
/// settings page.
///
/// Deliberately isolated in its own file behind a UserDefaults flag so this
/// heuristic-heavy module can be ripped out cleanly if it turns out to be too
/// noisy in practice. All AX access is best-effort: any failure or weirdness
/// (element gone, value not a string, etc.) just no-ops.
enum CorrectionLearner {
    static let enabledDefaultsKey = "autoLearnEnabled"
    private static let checkDelay: TimeInterval = 8.0
    private static let correctionsCap = 200
    /// A correction may cover at most this many words on each side. Beyond
    /// that it is a rewrite, not a mishearing.
    static let maximumRunWords = 4

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
            guard let correction = diffWordRunChange(before: before, after: after, inserted: insertedText) else { return }
            UserLexicon.shared.setCorrection(misheard: correction.from, corrected: correction.to)
            UserLexicon.shared.capCorrections(at: correctionsCap)
            FileHandle.standardError.write(Data("[auto-learn] recorded correction \"\(correction.from)\" -> \"\(correction.to)\"\n".utf8))
            suggest(heard: correction.from, typed: correction.to)
        }
    }

    /// Tells Flow what this Mac learned, so the person can turn it into a
    /// phrase for everyone on the settings page. Nothing here changes what
    /// this Mac does: the correction is already stored locally, and a
    /// suggestion stays a suggestion until a human accepts it.
    ///
    /// Fire and forget on purpose. A Mac with no connection, or a server that
    /// is down, simply keeps the correction to itself.
    static func suggest(heard: String, typed: String, client: FlowClient = .shared) {
        guard client.isConnected else { return }
        Task {
            do {
                try await client.suggestPhrase(heard: heard, typed: typed)
                FileHandle.standardError.write(Data("[auto-learn] suggested \"\(heard)\" -> \"\(typed)\" to Flow\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("[auto-learn] could not send the suggestion: \(error.localizedDescription)\n".utf8))
            }
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

    /// Finds the run of words from `inserted` that was hand-edited into a
    /// different run in `after`. Up to four words on each side, so "vervey
    /// pulse" becoming "VERVE Pulse" is learned as one correction rather than
    /// thrown away as two ambiguous changes.
    ///
    /// Deliberately conservative: bails (returns nil) on any ambiguity rather
    /// than risk learning garbage. The edit is located by trimming the words
    /// the two versions agree on at each end, so unrelated typing elsewhere in
    /// the document widens the run past four words and is dropped.
    static func diffWordRunChange(before: String, after: String, inserted: String) -> (from: String, to: String)? {
        guard before != after else { return nil }
        let beforeWords = tokenize(before)
        let afterWords = tokenize(after)
        guard !beforeWords.isEmpty, !afterWords.isEmpty else { return nil }

        var prefix = 0
        while prefix < beforeWords.count, prefix < afterWords.count,
              beforeWords[prefix].lowercased() == afterWords[prefix].lowercased() {
            prefix += 1
        }
        var suffix = 0
        while suffix < beforeWords.count - prefix, suffix < afterWords.count - prefix,
              beforeWords[beforeWords.count - 1 - suffix].lowercased() == afterWords[afterWords.count - 1 - suffix].lowercased() {
            suffix += 1
        }
        let fromWords = Array(beforeWords[prefix..<(beforeWords.count - suffix)])
        let toWords = Array(afterWords[prefix..<(afterWords.count - suffix)])
        // A pure insertion or a pure deletion is not a correction of something
        // we typed, and a run longer than four words is somebody rewriting the
        // sentence.
        guard !fromWords.isEmpty, !toWords.isEmpty else { return nil }
        guard fromWords.count <= maximumRunWords, toWords.count <= maximumRunWords else { return nil }

        let from = fromWords.joined(separator: " ")
        let to = toWords.joined(separator: " ")

        // Every word of the run has to be one we put there: an edit to text
        // the person typed themselves is none of our business.
        let insertedWords = Set(tokenize(inserted).map { $0.lowercased() })
        guard fromWords.allSatisfy({ insertedWords.contains($0.lowercased()) }) else { return nil }
        guard from.count >= 3, to.count >= 3 else { return nil }
        // At least one word of the run has to carry meaning; "the and" is not
        // a phrase anyone says on purpose.
        guard fromWords.contains(where: { !stopWords.contains($0.lowercased()) }) else { return nil }
        // Proper-noun constraint: a learned correction is applied globally to
        // every future dictation, so learning a common word ("there" to
        // "their") would silently rewrite it forever, and no stop-word list is
        // long enough to make that safe. Names and product terms are where
        // auto-learn earns its keep, and they arrive capitalised; ordinary
        // words do not.
        guard toWords[0].first?.isUppercase == true else { return nil }
        // The two runs have to be near neighbours. A person replacing one idea
        // with a different one is not correcting a mishearing.
        guard levenshtein(from.lowercased(), to.lowercased()) <= max(from.count, to.count) / 2 else { return nil }

        return (from: from, to: to)
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
