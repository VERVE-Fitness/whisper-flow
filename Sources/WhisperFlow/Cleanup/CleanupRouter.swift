import Foundation

struct CleanupResult: Sendable {
    let text: String
    let backendName: String
    /// True when guard rails discarded the LLM output and fell back to raw.
    let fellBackToRaw: Bool
    let durationMs: Int
}

/// Picks the best available cleanup backend:
/// FoundationModels (Apple Intelligence) -> Ollama -> Passthrough.
/// Applies guard rails: empty output, output > 1.6x raw length, error, or
/// >10s timeout all fall back to the raw transcript.
struct CleanupRouter: Sendable {
    private let foundation = FoundationModelsCleanup()
    private let ollama = OllamaCleanup()
    private let passthrough = PassthroughCleanup()
    private let timeoutSeconds: UInt64 = 10

    /// Resolve which backend would be used right now (for UI status display).
    func resolveBackend() async -> any CleanupBackend {
        if await foundation.isAvailable() { return foundation }
        if await ollama.isAvailable() { return ollama }
        return passthrough
    }

    /// - Parameter context: recent document text before the caret, captured
    ///   once at recording start; passed through to the LLM backend for
    ///   spelling reference only (feature: context-aware spelling).
    func clean(_ raw: String, context: String? = nil) async -> CleanupResult {
        let start = Date()
        let backend = await resolveBackend()
        let dictionary = UserLexicon.shared.dictionary
        let corrections = UserLexicon.shared.corrections

        func elapsedMs() -> Int { Int(Date().timeIntervalSince(start) * 1000) }
        // Deterministic dictionary corrections, self-correction stripping,
        // and digit formatting all apply on EVERY path, including
        // passthrough/raw fallback -- unlike the correctionCues-aware guard
        // relaxation above, none of these three depend on an LLM backend
        // being reachable at all. This matters in practice: the dictation
        // that motivated stripStandaloneCorrections ("Maybe I should talk
        // for five minutes. No scratch that. Say ten minutes.") landed on
        // Passthrough because Ollama wasn't running, so the LLM-based
        // correction handling above never ran -- raw text went straight
        // through, cue and all.
        func finalize(_ text: String, backendName: String, fellBackToRaw: Bool) -> CleanupResult {
            let corrected = Self.applyCorrections(corrections, to: text)
            let selfCorrected = Self.stripStandaloneCorrections(corrected)
            let digitsFormatted = SpokenNumbers.convert(selfCorrected)
            return CleanupResult(text: digitsFormatted, backendName: backendName, fellBackToRaw: fellBackToRaw, durationMs: elapsedMs())
        }

        if backend is PassthroughCleanup {
            return finalize(raw, backendName: passthrough.name, fellBackToRaw: false)
        }

        do {
            let cleaned = try await withTimeout(seconds: timeoutSeconds) {
                try await backend.clean(raw, dictionary: dictionary, context: context)
            }
            // Guard rails: empty or runaway output -> raw.
            let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                FileHandle.standardError.write(Data("[cleanup] \(backend.name) returned empty output; using raw\n".utf8))
                return finalize(raw, backendName: backend.name, fellBackToRaw: true)
            }
            if Double(trimmed.count) > Double(raw.count) * 1.6 {
                FileHandle.standardError.write(Data("[cleanup] \(backend.name) output \(trimmed.count) chars > 1.6x raw \(raw.count); using raw\n".utf8))
                return finalize(raw, backendName: backend.name, fellBackToRaw: true)
            }
            // Content-retention guard: small local models sometimes delete whole
            // clauses they judge to be noise, not just fillers. If the cleaned text
            // keeps fewer than 60% of the raw's non-filler words, treat it as a
            // content change and use the raw transcript instead. Short utterances
            // (few content words) get a much stricter bar -- with only 1-3 words to
            // begin with, losing even one is a bigger deal, and this is exactly
            // where a small model is cheapest to hallucinate a one-word "answer"
            // like turning "What's next?" into "Absolutely."
            //
            // Backtrack allowance: when the raw transcript contains a
            // self-correction cue ("no wait", "scratch that", ...), the
            // speaker deliberately abandons preceding words, so a lower
            // retention bar is legitimate -- and the strict short-utterance
            // 0.99 bar (meant for accidental 1-3-word deletions) doesn't fit
            // an utterance that's deliberately discarding words.
            let contentWordCount = Self.contentWordCount(raw)
            let hasCorrectionCue = Self.containsCorrectionCue(raw)
            // Dictionary allowance: when the cleaned text contains a
            // dictionary term that the raw didn't, the LLM did exactly what
            // the dictionary prompt asked — swapped a mishearing for the real
            // term. The strict short-utterance 0.99 bar would reject that
            // swap as a hallucination ("Devertory" → "VERVE Tori" loses the
            // raw word), so dictionary-corrected utterances use the normal
            // 0.6 bar instead. An answered question can't exploit this: an
            // answer that happens to contain a dictionary word still has to
            // clear retention over the rest of the utterance plus the
            // additions and dropped-question guards.
            let hasDictionaryCorrection = Self.introducedDictionaryTerm(raw: raw, cleaned: trimmed, dictionary: dictionary)
            let retentionThreshold: Double = hasCorrectionCue
                ? 0.35
                : ((contentWordCount <= 4 && !hasDictionaryCorrection) ? 0.99 : 0.6)
            let retention = Self.contentWordRetention(raw: raw, cleaned: trimmed, dictionary: dictionary)
            if retention < retentionThreshold {
                FileHandle.standardError.write(Data("[cleanup] \(backend.name) kept only \(Int(retention * 100))% of content words; using raw\n".utf8))
                return finalize(raw, backendName: backend.name, fellBackToRaw: true)
            }
            // Additions guard: a faithful cleanup introduces almost no new words;
            // an answered request does (e.g. "Here is a list: 1. 2. ..." echoes
            // the request's words, passing retention, but adds its own framing).
            if Self.addsTooManyNewWords(raw: raw, cleaned: trimmed, dictionary: dictionary) {
                FileHandle.standardError.write(Data("[cleanup] \(backend.name) introduced too many new words (looks like an answer, not a cleanup); using raw\n".utf8))
                return finalize(raw, backendName: backend.name, fellBackToRaw: true)
            }
            // Dropped-question guard: the retention and additions guards are
            // ratios over the WHOLE utterance, so a question buried at the end
            // of an otherwise-long dictation can get answered without either
            // ratio moving enough to trip -- most of the paragraph survives,
            // and the answer's new words fit inside the 25% budget. A "?" in
            // the raw transcript that vanished from the cleaned output is a
            // much sharper, length-independent signal of exactly that.
            if Self.droppedQuestion(raw: raw, cleaned: trimmed) {
                FileHandle.standardError.write(Data("[cleanup] \(backend.name) dropped a question mark present in raw (looks like a question got answered instead of transcribing); using raw\n".utf8))
                return finalize(raw, backendName: backend.name, fellBackToRaw: true)
            }
            return finalize(trimmed, backendName: backend.name, fellBackToRaw: false)
        } catch {
            FileHandle.standardError.write(Data("[cleanup] \(backend.name) failed (\(error.localizedDescription)); using raw\n".utf8))
            return finalize(raw, backendName: backend.name, fellBackToRaw: true)
        }
    }

    /// Fraction of the raw transcript's distinct non-filler words that still
    /// appear in the cleaned text. Word-count ratios miss paraphrases and
    /// answered questions (similar length, different words) -- checking which
    /// words survived catches deletions AND rewrites: a faithful cleanup keeps
    /// nearly all original words, an answer or paraphrase keeps very few.
    private static let fillerWords: Set<String> = ["um", "uh", "uhm", "erm", "er", "ah", "hmm", "mmm", "like", "you", "know", "so"]

    /// Correction cues that signal the speaker deliberately abandoned
    /// preceding words (feature: backtrack/self-correction). Matched
    /// case-insensitively as whole phrases. Every entry must be a phrase that
    /// is near-unambiguous as a correction: lowering the retention bar weakens
    /// the answered-question guard for that utterance, so a cue that also
    /// occurs in ordinary prose ("rather", "correction", bare "actually")
    /// must NOT be listed — "I'd rather we ship Friday" is not a backtrack.
    private static let correctionCues = ["no wait", "scratch that", "strike that", "actually make that", "i meant to say"]

    /// Cues that are inherently replacement-flavoured -- saying them at all
    /// only makes sense if the speaker is substituting new content for old,
    /// unlike "scratch that" which also reads fine as ordinary language
    /// ("scratch that itch"). Because these cues carry their own unambiguous
    /// correction meaning, the cue-led-replacement matcher below
    /// (cueLedRemainder) lets them trigger with no prefix word and no comma
    /// required -- the two signals that stand in for that unambiguity
    /// everywhere else. Bare "make that" is deliberately NOT here: it's
    /// everyday English ("Talk to finance. Make that happen today." must
    /// never eat the finance sentence), so it only fires with a prefix
    /// ("no make that 240") or a trailing comma ("Make that, 240") like any
    /// other ambiguous cue -- and the paraphrase case that motivated this
    /// list ("Actually, make that 2 and 40") is covered by the
    /// "actually make that" entry. Deliberately overlaps correctionCues:
    /// both entries are in that list too, just reached from the LLM-parity
    /// list above as well as from here.
    private static let replacementCues = ["actually make that", "i meant to say"]

    static func containsCorrectionCue(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return correctionCues.contains { lower.contains($0) }
    }

    /// Deterministic, narrower sibling of the LLM-based correction handling
    /// above. Handles three shapes, tried in this order per sentence:
    ///
    /// 1. A correction cue that stands as its OWN whole sentence ("Talk for
    ///    five minutes. No, scratch that. Ten minutes." -> "Ten minutes."),
    ///    dropping that sentence and the one immediately before it.
    /// 2. A cue that leads a whole sentence with real content after it
    ///    ("Tune and forty five. No scratch that two and forty." -> "Two
    ///    and forty.") -- the LLM-paraphrase-proof net: even when the LLM
    ///    cleanup rewrote the cue in its own words upstream, this runs on
    ///    the ORIGINAL raw transcript (stripStandaloneCorrections is called
    ///    on raw, before the LLM ever sees it -- see CleanupRouter.finalize)
    ///    so a paraphrase downstream can't hide the cue from it.
    /// 3. The same two shapes again at COMMA-CLAUSE granularity within a
    ///    single sentence ("Two forty five, no scratch that, two forty." ->
    ///    "Two forty.") -- STT often punctuates a spoken correction as
    ///    clauses of one sentence rather than separate sentences, and the
    ///    correction reads identically either way.
    ///
    /// This is deliberately conservative -- it does NOT attempt the harder,
    /// genuinely-needs-language-understanding case the LLM path exists for
    /// ("on tuesday no wait wednesday" -> "on wednesday", a mid-sentence
    /// word-level swap without any comma or sentence boundary) -- because a
    /// mechanical rule can't reliably tell how far back a truly mid-clause
    /// correction refers, and a wrong guess there deletes real content. The
    /// sentence/clause-boundary patterns above have only one sane reading,
    /// so they're safe to handle without a model.
    static func stripStandaloneCorrections(_ text: String) -> String {
        let sentences = splitSentences(text)
        guard !sentences.isEmpty else { return text }

        var kept: [String] = []
        for sentence in sentences {
            if isStandaloneCorrectionMarker(sentence) {
                _ = kept.popLast()
                continue
            }
            let (body, terminator) = stripTerminator(sentence)
            // Cue-led whole-sentence replacement requires a previous
            // sentence to actually replace -- without that guard, a
            // sentence like "No scratch that plan entirely." spoken on its
            // own (nothing before it to correct) would misfire on the bare
            // prefix+cue signal alone. Exact markers above don't need this
            // guard: their tight shape (bare cue, or cue plus one prefix/
            // suffix word) is unambiguous regardless of context, but a cue
            // with arbitrary trailing content only reads as a correction
            // when there's something in scope for it to replace.
            if !kept.isEmpty, let remainder = cueLedRemainder(body) {
                _ = kept.popLast()
                kept.append(capitalizeFirstLetter(remainder) + terminator)
                continue
            }
            if let rebuilt = stripClauseLevelCorrection(body: body, terminator: terminator, kept: &kept) {
                if !rebuilt.isEmpty { kept.append(rebuilt) }
                continue
            }
            kept.append(sentence)
        }
        guard kept != sentences else { return text }
        return kept.joined(separator: " ")
    }

    /// Splits a sentence body (terminator already stripped by stripTerminator)
    /// into comma-delimited clauses and looks for a correction inside it,
    /// mirroring stripStandaloneCorrections' two shapes at clause
    /// granularity:
    ///
    /// - An exact marker clause ("no scratch that" as a whole clause) drops
    ///   that clause and the one before it -- or, if the marker is the
    ///   sentence's FIRST clause, drops the previous SENTENCE instead (via
    ///   `kept`), since there's no earlier clause in this sentence to reach
    ///   back into.
    /// - A cue-led clause with trailing content ("..., make that 2 and 40")
    ///   drops the clause before it and keeps only the remainder. Only
    ///   checked from the second clause onward: a cue-led match at clause
    ///   index 0 is exactly the whole-sentence cueLedRemainder check the
    ///   caller already tried (a clause starting at index 0 spans the same
    ///   tokens the sentence itself starts with), so re-checking it here
    ///   would be redundant, not additive.
    ///
    /// Returns nil when neither shape is found in a multi-clause sentence
    /// (caller falls back to keeping the sentence verbatim), or when the
    /// sentence has no commas at all. Returns "" in the degenerate case
    /// where removing the matched clauses empties the sentence entirely --
    /// the caller skips appending an empty result.
    private static func stripClauseLevelCorrection(body: String, terminator: String, kept: inout [String]) -> String? {
        let clauses = body.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard clauses.count > 1 else { return nil }

        if let k = clauses.firstIndex(where: { isStandaloneCorrectionMarker($0) }) {
            var remaining = clauses
            remaining.remove(at: k)
            if k > 0 {
                remaining.remove(at: k - 1)
            } else {
                _ = kept.popLast()
            }
            guard !remaining.isEmpty else { return "" }
            return capitalizeFirstLetter(remaining.joined(separator: ", ")) + terminator
        }

        for k in 1..<clauses.count {
            if let remainder = cueLedRemainder(clauses[k]) {
                var remaining = clauses
                remaining[k] = remainder
                remaining.remove(at: k - 1)
                guard !remaining.isEmpty else { return "" }
                return capitalizeFirstLetter(remaining.joined(separator: ", ")) + terminator
            }
        }
        return nil
    }

    /// Splits a sentence into (body, terminator): the trailing ".", "?", or
    /// "!" pulled off separately so clause-splitting and cue matching never
    /// have to special-case it, and callers can re-append the exact
    /// original terminator after rebuilding the sentence.
    private static func stripTerminator(_ sentence: String) -> (body: String, terminator: String) {
        var s = sentence.trimmingCharacters(in: .whitespaces)
        var terminator = ""
        if let last = s.last, ".?!".contains(last) {
            terminator = String(last)
            s.removeLast()
        }
        return (s.trimmingCharacters(in: .whitespaces), terminator)
    }

    /// Uppercases just the first character, leaving the rest untouched --
    /// used to re-capitalize a rebuilt sentence/clause after its original
    /// first word (which may have been the dropped correction cue or
    /// prefix) is gone. A no-op when the new first character isn't a
    /// letter (e.g. a rebuilt sentence that now starts with a digit, like
    /// "2 and 40.").
    private static func capitalizeFirstLetter(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + s.dropFirst()
    }

    /// Matches the "cue-led replacement" shape: `text` (a sentence body or a
    /// single already-comma-split clause, terminator already stripped)
    /// OPENS with [prefix]? + cue and still has real content after it --
    /// e.g. "No scratch that two and forty" (prefix "no" + cue "scratch
    /// that" + remainder "two and forty"), or "make that 2 and 40" (bare
    /// replacement cue + remainder). Returns the remainder in ORIGINAL
    /// casing/punctuation (never the lowercased matching form), so digits
    /// and proper nouns in the surviving correction come through untouched.
    ///
    /// This is deliberately a LOOSER shape than isStandaloneCorrectionMarker
    /// (which only tolerates a single trailing tag word) -- it exists
    /// specifically for the case that motivated it: an LLM cleanup backend
    /// that paraphrases the correction instead of applying it ("No scratch
    /// that ..." rewritten as "Actually, make that ..."). No prompt-level
    /// rule can stop that reliably, but the paraphrase the model reaches
    /// for is itself cue-shaped -- and since finalize() runs this pass on
    /// whichever text won (LLM output or raw fallback alike), the
    /// paraphrased form gets caught here on the way out. Because it's
    /// looser, it needs a real
    /// trigger signal to fire, not just "starts with a cue word" -- a bare
    /// cue with trailing content and none of the three signals below is
    /// exactly the false-positive class this has to avoid: "Scratch that
    /// plan entirely." and "Scratch that idea and move on." use "scratch
    /// that" in its ordinary sense, not as a correction, and must pass
    /// through unchanged.
    private static func cueLedRemainder(_ text: String) -> String? {
        // Commas are discarded for matching purposes (mirrors
        // isStandaloneCorrectionMarker) -- a prefix and cue spoken either
        // side of a comma ("Actually, make that ...") are still "prefix
        // then cue" for this purpose. The remainder is built from the same
        // comma-normalized token stream, so it never carries a stray comma
        // forward from a prefix/cue boundary.
        let rawTokens = text.replacingOccurrences(of: ",", with: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        guard !rawTokens.isEmpty else { return nil }
        let lowerTokens = rawTokens.map { $0.lowercased() }
        let prefixWords = Set(correctionPrefixes.map { $0.replacingOccurrences(of: ",", with: "") })
        // "make that" joins the candidate list here as an AMBIGUOUS cue: it
        // can fire via the prefix or trailing-comma signals below ("no make
        // that 240", "Make that, 240") but is kept out of replacementCues,
        // so bare "Make that happen today" never triggers.
        let allCues = correctionCues + (replacementCues + ["make that"]).filter { !correctionCues.contains($0) }

        for cue in allCues {
            let cueWords = cue.components(separatedBy: " ")
            let n = cueWords.count

            // Prefix + cue + real content: "No scratch that two and
            // forty." The prefix word alone is signal enough here -- no
            // comma or replacement-cue membership required.
            if lowerTokens.count > n + 1, prefixWords.contains(lowerTokens[0]), Array(lowerTokens[1..<(1 + n)]) == cueWords {
                return rawTokens[(1 + n)...].joined(separator: " ")
            }
            // Bare cue + real content, no prefix: "Scratch that, two
            // forty." / "Make that 2 and 40." Only a replacement-flavoured
            // cue (always correction-shaped) or a comma immediately after
            // the cue in the original text is a strong enough signal on
            // its own -- neither present is the ordinary-sentence
            // false-positive case documented above.
            if lowerTokens.count > n, Array(lowerTokens[0..<n]) == cueWords {
                if replacementCues.contains(cue) || commaImmediatelyFollows(cueWords, in: text) {
                    return rawTokens[n...].joined(separator: " ")
                }
            }
        }
        return nil
    }

    /// True when `text` starts with `cueWords` (words only, whitespace
    /// between) immediately followed by a comma -- the "Scratch that, two
    /// forty" shape, checked against the ORIGINAL text (comma intact),
    /// unlike the token matching above which normalizes commas away.
    private static func commaImmediatelyFollows(_ cueWords: [String], in text: String) -> Bool {
        let pattern = "(?i)^\\s*" + cueWords.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "\\s+") + "\\s*,"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    /// Short interjections that commonly precede a correction cue spoken as
    /// its own sentence ("No, scratch that.", "Okay scratch that.").
    private static let correctionPrefixes = [
        "no", "no,", "okay", "okay,", "ok", "ok,", "sorry", "sorry,", "actually", "actually,", "wait", "wait,",
    ]

    /// Short tags that commonly follow a correction cue spoken as its own
    /// sentence ("No scratch that, right?", "Scratch that yeah."). STT
    /// tends to punctuate these as a "?", which is exactly what motivates
    /// the droppedQuestion fix below -- the tag reads like a question mark
    /// but isn't a real one. Kept to a small, near-unambiguous set for the
    /// same reason correctionCues is narrow: a suffix that also shows up in
    /// ordinary prose would let real content slip through as "just a tag".
    private static let correctionSuffixes: Set<String> = ["right", "yeah", "okay", "ok", "sorry"]

    private static func isStandaloneCorrectionMarker(_ sentence: String) -> Bool {
        var s = sentence.lowercased().trimmingCharacters(in: .whitespaces)
        while let last = s.last, ".?!".contains(last) { s.removeLast() }
        s = s.trimmingCharacters(in: .whitespaces)

        // Commas inside the marker are tag punctuation ("No, scratch that,
        // right?"), not sentence structure -- normalize them out so the
        // token-sequence check below only has to reason about word shape,
        // not comma placement.
        let tokens = s.replacingOccurrences(of: ",", with: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return false }
        let prefixWords = Set(correctionPrefixes.map { $0.replacingOccurrences(of: ",", with: "") })

        for cue in correctionCues {
            let cueWords = cue.components(separatedBy: " ")
            let n = cueWords.count

            // Bare cue: "scratch that".
            if tokens == cueWords { return true }
            // Prefix + cue: "no scratch that".
            if tokens.count == n + 1, prefixWords.contains(tokens[0]), Array(tokens[1...]) == cueWords {
                return true
            }
            // Cue + trailing tail: "scratch that yeah". Tight on purpose --
            // only ONE suffix word is ever tolerated, so a sentence with
            // real extra words ("no scratch that plan entirely") can't
            // sneak through as "cue + tag".
            if tokens.count == n + 1, Array(tokens[0..<n]) == cueWords, correctionSuffixes.contains(tokens[n]) {
                return true
            }
            // Prefix + cue + trailing tail: "no scratch that, right".
            if tokens.count == n + 2, prefixWords.contains(tokens[0]),
               Array(tokens[1..<(1 + n)]) == cueWords, correctionSuffixes.contains(tokens[n + 1]) {
                return true
            }
        }
        return false
    }

    /// Splits on '.', '?', '!' while keeping the terminator attached to each
    /// sentence; a trailing fragment without a terminator is kept as-is.
    private static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "?" || ch == "!" {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            }
        }
        let remainder = current.trimmingCharacters(in: .whitespaces)
        if !remainder.isEmpty { sentences.append(remainder) }
        return sentences
    }

    /// Applies the deterministic misheard->corrected map, case-insensitive,
    /// whole-word only (so "rob" doesn't match inside "robot"). Runs after
    /// cleanup on every path, including passthrough, so it works even
    /// without an LLM available.
    static func applyCorrections(_ corrections: [String: String], to text: String) -> String {
        guard !corrections.isEmpty, !text.isEmpty else { return text }
        var result = text
        for (misheard, corrected) in corrections {
            let pattern = "(?i)\\b" + NSRegularExpression.escapedPattern(for: misheard) + "\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: corrected))
        }
        return result
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Count of distinct non-filler words in the raw transcript -- used to
    /// decide how strict the retention bar should be (short utterances get a
    /// much stricter one; see contentWordRetention's caller).
    static func contentWordCount(_ raw: String) -> Int {
        Set(words(raw)).subtracting(fillerWords).count
    }

    static func contentWordRetention(raw: String, cleaned: String, dictionary: [String] = []) -> Double {
        let rawContent = Set(words(raw)).subtracting(fillerWords)
        let cleanedSet = Set(words(cleaned))
        guard !rawContent.isEmpty else {
            // Raw was pure filler/trivial. Only bypass the guard if the
            // cleaned output is equally trivial (near-empty) -- anything
            // substantial here is unearned content, not a legitimate cleanup.
            return cleanedSet.count <= 1 ? 1.0 : 0.0
        }
        // Dictionary credit: a raw word that vanished because it was corrected
        // TO a dictionary term isn't lost content — it's the correction the
        // dictionary prompt asked for. Count it as kept when it's an acoustic
        // near-miss (edit distance) of a dictionary word that actually appears
        // in the cleaned text. Only dictionary words present in cleaned earn
        // credit, so the model can't launder arbitrary deletions through a
        // large dictionary.
        let dictInCleaned = dictionaryWordSet(dictionary).intersection(cleanedSet)
        let kept = rawContent.filter { rawWord in
            if cleanedSet.contains(rawWord) { return true }
            return dictInCleaned.contains { dictWord in
                levenshtein(rawWord, dictWord) <= max(1, max(rawWord.count, dictWord.count) * 2 / 5)
            }
        }.count
        return Double(kept) / Double(rawContent.count)
    }

    /// True when the cleaned text contains a dictionary word the raw lacked —
    /// the signature of a mishearing corrected to a known term (used to relax
    /// the strict short-utterance retention bar; see the call site).
    static func introducedDictionaryTerm(raw: String, cleaned: String, dictionary: [String]) -> Bool {
        guard !dictionary.isEmpty else { return false }
        let rawSet = Set(words(raw))
        let cleanedSet = Set(words(cleaned))
        return !dictionaryWordSet(dictionary).intersection(cleanedSet).subtracting(rawSet).isEmpty
    }

    /// Dictionary entries can be multi-word terms ("Functional Trainer");
    /// split them so word-level comparisons see each component.
    private static func dictionaryWordSet(_ dictionary: [String]) -> Set<String> {
        Set(dictionary.flatMap { words($0) })
    }

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

    /// True when the cleaned text contains a suspicious number of words that
    /// were never spoken. Legitimate cleanup only adds words when correcting a
    /// mis-hearing (a handful at most); an LLM answering the dictation adds its
    /// own framing ("Here is...", list numbers, new content). Small dictations
    /// get an absolute allowance of 2 new words so corrections never trip it.
    ///
    /// Two allowances beyond that baseline, both conditional (never a blanket
    /// relaxation):
    /// - Personal-dictionary words never count as "added" -- they're expected
    ///   corrections the speaker asked for (feature: personal dictionary).
    /// - Pure-digit tokens never count as "added" -- the list-formatting rule
    ///   introduces list numbers ("1.", "2.") that are not spoken words but
    ///   are legitimate formatting, not model-invented content.
    static func addsTooManyNewWords(raw: String, cleaned: String, dictionary: [String] = []) -> Bool {
        let rawSet = Set(words(raw))
        let cleanedSet = Set(words(cleaned))
        guard !cleanedSet.isEmpty else { return false }
        let dictionaryWords = dictionaryWordSet(dictionary)
        let added = cleanedSet.subtracting(rawSet)
            .filter { !dictionaryWords.contains($0) && !$0.allSatisfy(\.isNumber) }
            .count
        return Double(added) > max(2.0, 0.25 * Double(cleanedSet.count))
    }

    /// True when the raw transcript asked a question that the cleaned text no
    /// longer poses. Punctuation-only, so it's cheap and independent of
    /// utterance length -- see the call site for why that matters.
    ///
    /// Checked against stripStandaloneCorrections(raw), not raw itself:
    /// STT punctuates a correction marker like "No scratch that, right?"
    /// with a "?" that isn't a real question. Without this, a legitimate
    /// cleanup that removes the correction (as it should) makes the "?"
    /// disappear and trips this guard, forcing the un-corrected raw text
    /// through instead -- exactly the "two hundred and forty. No scratch
    /// that, right? two hundred and forty five." case that motivated it.
    static func droppedQuestion(raw: String, cleaned: String) -> Bool {
        let strippedRaw = stripStandaloneCorrections(raw)
        return strippedRaw.contains("?") && !cleaned.contains("?")
    }
}

/// Run an async operation with a hard timeout.
func withTimeout<T: Sendable>(seconds: UInt64, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            throw CleanupError.timedOut
        }
        guard let result = try await group.next() else { throw CleanupError.timedOut }
        group.cancelAll()
        return result
    }
}
