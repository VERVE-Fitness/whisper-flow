import Foundation

/// Replaces the renderings the speech model gets wrong with the phrases the
/// team actually says. Two passes, in order:
///
/// 1. **Exact.** Every `heard_as` variant is replaced by its phrase, on word
///    boundaries, case-insensitively, longest variant first, keeping the
///    phrase's own casing ("tory." becomes "Tori.").
/// 2. **Fuzzy.** Any window of one to four words whose lower-case form is
///    within a normalised edit distance of 0.25 of a phrase becomes that
///    phrase. Guarded three ways, because a fuzzy rewrite of ordinary English
///    is far worse than a missed correction:
///    - the comparison must involve at least five characters, so two short
///      words are never one edit apart ("story" against "Tori" is 2 over 5 =
///      0.4, and stays "story");
///    - a phrase that is itself a common English word is never a fuzzy
///      target, nor is a single all-lower-case word, which reads as ordinary
///      English rather than a name or a product term;
///    - a single-word phrase only ever matches a single-word window.
///
/// Pure: no I/O, no globals, no clock. `applyLogging` is the one wrapper that
/// writes the `[phrase] "x" -> "Y" (exact)` lines to stderr.
enum PhraseMatcher {

    /// A window and a phrase must involve at least this many characters
    /// before fuzzy matching is allowed to look at them at all.
    static let minimumFuzzyCharacters = 5
    /// Levenshtein distance over the longer of the two strings. A quarter of
    /// the word is about one edit in a five letter word and two in a nine
    /// letter one.
    static let maximumFuzzyDistance = 0.25
    /// Fuzzy windows never run longer than this many words.
    static let maximumWindowWords = 4

    enum Kind: Equatable {
        case exact
        case fuzzy(Double)
    }

    struct Replacement: Equatable {
        let heard: String
        let phrase: String
        let kind: Kind
    }

    struct Applied: Equatable {
        let text: String
        let replacements: [Replacement]

        var logLines: [String] { replacements.map(PhraseMatcher.logLine) }
    }

    // MARK: - Entry points

    /// The whole pass, pure. Returns the rewritten text and what it changed.
    static func apply(_ text: String, phrases: [FlowPhrase]) -> Applied {
        guard !phrases.isEmpty, !text.isEmpty else { return Applied(text: text, replacements: []) }
        let exact = applyExact(text, phrases: phrases)
        let fuzzy = applyFuzzy(exact.text, phrases: phrases)
        return Applied(text: fuzzy.text, replacements: exact.replacements + fuzzy.replacements)
    }

    /// The pass as the app uses it: rewrite, and say on stderr what changed.
    static func applyLogging(_ text: String, phrases: [FlowPhrase]) -> String {
        let applied = apply(text, phrases: phrases)
        for line in applied.logLines {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        return applied.text
    }

    static func logLine(_ r: Replacement) -> String {
        switch r.kind {
        case .exact:
            return "[phrase] \"\(r.heard)\" -> \"\(r.phrase)\" (exact)"
        case .fuzzy(let distance):
            return "[phrase] \"\(r.heard)\" -> \"\(r.phrase)\" (fuzzy \(format(distance)))"
        }
    }

    // MARK: - Exact

    /// Longest variant first, so "verve pulse pro" wins over "verve pulse"
    /// when both are on the list.
    static func applyExact(_ text: String, phrases: [FlowPhrase]) -> Applied {
        var pairs: [(variant: String, phrase: String)] = []
        for phrase in phrases {
            for variant in phrase.heardAs {
                let trimmed = variant.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                pairs.append((trimmed, phrase.phrase))
            }
        }
        pairs.sort { lhs, rhs in
            let l = wordCount(lhs.variant), r = wordCount(rhs.variant)
            if l != r { return l > r }
            return lhs.variant.count > rhs.variant.count
        }

        var result = text
        var replacements: [Replacement] = []
        for pair in pairs {
            // Matches are taken one at a time rather than through
            // stringByReplacingMatches, because a variant can differ from its
            // phrase in casing alone ("verve pulse" against "VERVE Pulse").
            // That is a real correction, but text that already reads exactly
            // like the phrase is not, and must not produce a log line saying
            // nothing changed.
            let pattern = "(?i)" + boundary(before: pair.variant)
                + NSRegularExpression.escapedPattern(for: pair.variant)
                + boundary(after: pair.variant)
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            var hits: [(range: Range<String.Index>, heard: String)] = []
            for match in regex.matches(in: result, range: range) {
                guard let r = Range(match.range, in: result) else { continue }
                let heard = String(result[r])
                guard heard != pair.phrase else { continue }
                hits.append((r, heard))
            }
            guard let first = hits.first else { continue }
            // Right to left, so the ranges ahead of each edit stay valid.
            for hit in hits.reversed() {
                result.replaceSubrange(hit.range, with: pair.phrase)
            }
            replacements.append(Replacement(heard: first.heard, phrase: pair.phrase, kind: .exact))
        }
        return Applied(text: result, replacements: replacements)
    }

    /// `\b` only asserts a boundary next to a word character, so a variant
    /// that starts or ends with punctuation would never match with it. Use it
    /// only where the variant's own edge is a word character.
    private static func boundary(before variant: String) -> String {
        (variant.first?.isLetter == true || variant.first?.isNumber == true) ? "\\b" : ""
    }

    private static func boundary(after variant: String) -> String {
        (variant.last?.isLetter == true || variant.last?.isNumber == true) ? "\\b" : ""
    }

    // MARK: - Fuzzy

    /// Windows are taken longest first and never overlap: once four words
    /// have become one phrase, the words inside them are spent.
    static func applyFuzzy(_ text: String, phrases: [FlowPhrase]) -> Applied {
        let targets = phrases.filter { isFuzzyEligible($0.phrase) }
        guard !targets.isEmpty else { return Applied(text: text, replacements: []) }
        let tokens = wordTokens(text)
        guard !tokens.isEmpty else { return Applied(text: text, replacements: []) }

        var spent = [Bool](repeating: false, count: tokens.count)
        // (range in the original string, phrase, heard text, distance)
        var hits: [(range: Range<String.Index>, phrase: String, heard: String, distance: Double)] = []

        var size = min(maximumWindowWords, tokens.count)
        while size >= 1 {
            var start = 0
            while start + size <= tokens.count {
                defer { start += 1 }
                if spent[start..<(start + size)].contains(true) { continue }
                let window = Array(tokens[start..<(start + size)])
                let joined = window.map { $0.text.lowercased() }.joined(separator: " ")
                guard let best = bestMatch(for: joined, windowWords: size, among: targets) else { continue }
                let range = window[0].range.lowerBound..<window[size - 1].range.upperBound
                let heard = String(text[range])
                // Already right: no rewrite, no log line.
                guard heard.compare(best.phrase, options: .caseInsensitive) != .orderedSame else { continue }
                for i in start..<(start + size) { spent[i] = true }
                hits.append((range: range, phrase: best.phrase, heard: heard, distance: best.distance))
            }
            size -= 1
        }

        guard !hits.isEmpty else { return Applied(text: text, replacements: []) }
        // Rewrite right to left so earlier ranges stay valid.
        var result = text
        for hit in hits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(hit.range, with: hit.phrase)
        }
        let replacements = hits
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
            .map { Replacement(heard: $0.heard, phrase: $0.phrase, kind: .fuzzy($0.distance)) }
        return Applied(text: result, replacements: replacements)
    }

    private static func bestMatch(for window: String, windowWords: Int,
                                  among targets: [FlowPhrase]) -> (phrase: String, distance: Double)? {
        var best: (phrase: String, distance: Double)?
        for target in targets {
            // A window only ever matches a phrase of the same number of
            // words: a single-word phrase matches a single-word window, and
            // nothing wider. Allowing a word of slack looked tempting (it
            // would catch a merged word) but it also makes "the functional
            // trainer" sit 4 characters from "functional trainer", and
            // swallowing a real word is worse than missing a correction.
            guard windowWords == wordCount(target.phrase) else { continue }
            let candidate = target.phrase.lowercased()
            guard candidate != window else { continue }
            let longer = max(candidate.count, window.count)
            guard longer >= minimumFuzzyCharacters else { continue }
            let distance = Double(levenshtein(window, candidate)) / Double(longer)
            guard distance <= maximumFuzzyDistance else { continue }
            if best == nil || distance < best!.distance {
                best = (target.phrase, distance)
            }
        }
        return best
    }

    /// A phrase that is itself ordinary English never gets fuzzy matching: a
    /// fuzzy rewrite is applied to every future dictation, and no stop list
    /// is long enough to make rewriting common words safe. Two guards, both
    /// on single-word phrases only (a two word phrase is specific enough):
    /// the common word list below, and the shape of the word itself.
    static func isFuzzyEligible(_ phrase: String) -> Bool {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let words = wordsOf(trimmed)
        guard !words.isEmpty else { return false }
        guard words.count == 1 else { return true }
        if commonWords.contains(words[0]) { return false }
        // "Tori" and "VERVE" carry a capital; "kettlebell" does not, and a
        // lower-case single word is exactly the shape of ordinary English.
        return trimmed != trimmed.lowercased()
    }

    // MARK: - Text helpers

    struct WordToken: Equatable {
        let text: String
        let range: Range<String.Index>
    }

    /// Runs of letters, digits and apostrophes. Punctuation between words is
    /// left where it is, which is what keeps "tory." working.
    static func wordTokens(_ text: String) -> [WordToken] {
        var tokens: [WordToken] = []
        var index = text.startIndex
        while index < text.endIndex {
            if isWordCharacter(text[index]) {
                let start = index
                while index < text.endIndex, isWordCharacter(text[index]) {
                    index = text.index(after: index)
                }
                tokens.append(WordToken(text: String(text[start..<index]), range: start..<index))
            } else {
                index = text.index(after: index)
            }
        }
        return tokens
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "'" || c == "\u{2019}"
    }

    static func wordsOf(_ text: String) -> [String] {
        wordTokens(text).map { $0.text.lowercased() }
    }

    static func wordCount(_ text: String) -> Int { wordTokens(text).count }

    static func format(_ distance: Double) -> String {
        var s = String(format: "%.2f", distance)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
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

    /// A compact stand-in for the top few thousand English words: everything
    /// here is common enough that a phrase spelled the same way must never be
    /// fuzzy-matched. Kept short on purpose, because the lower-case guard in
    /// `isFuzzyEligible` already catches the long tail.
    static let commonWords: Set<String> = [
        "the", "be", "to", "of", "and", "a", "in", "that", "have", "i", "it", "for", "not", "on",
        "with", "he", "as", "you", "do", "at", "this", "but", "his", "by", "from", "they", "we",
        "say", "her", "she", "or", "an", "will", "my", "one", "all", "would", "there", "their",
        "what", "so", "up", "out", "if", "about", "who", "get", "which", "go", "me", "when",
        "make", "can", "like", "time", "no", "just", "him", "know", "take", "people", "into",
        "year", "your", "good", "some", "could", "them", "see", "other", "than", "then", "now",
        "look", "only", "come", "its", "over", "think", "also", "back", "after", "use", "two",
        "how", "our", "work", "first", "well", "way", "even", "new", "want", "because", "any",
        "these", "give", "day", "most", "us", "is", "are", "was", "were", "been", "has", "had",
        "did", "does", "said", "made", "went", "very", "much", "many", "such", "here", "where",
        "why", "again", "still", "every", "same", "few", "more", "less", "own", "off", "down",
        "under", "while", "before", "between", "through", "should", "must", "might", "shall",
        "may", "each", "both", "another", "around", "away", "never", "always", "often",
        "sometimes", "really", "right", "left", "next", "last", "long", "great", "little",
        "old", "big", "small", "high", "low", "sure", "thing", "things", "part", "place",
        "point", "case", "week", "month", "today", "tomorrow", "yesterday", "morning",
        "night", "team", "company", "business", "money", "number", "order", "call", "email",
        "meeting", "story", "start", "stop", "help", "need", "keep", "leave", "move", "talk",
        "tell", "ask", "put", "run", "send", "read", "write", "open", "close", "find", "show",
        "play", "hold", "bring", "build", "change", "check", "clear", "cover", "cut", "drop",
        "end", "fall", "feel", "fill", "follow", "hear", "learn", "let", "live", "lose", "love",
        "mean", "meet", "pay", "pick", "plan", "pull", "push", "reach", "remember", "return",
        "save", "seem", "set", "sit", "sound", "speak", "spend", "stand", "stay", "try",
        "turn", "wait", "walk", "watch", "win", "worry", "yes", "not", "nothing", "something",
        "anything", "everything", "someone", "anyone", "everyone", "nobody", "somebody",
    ]
}
