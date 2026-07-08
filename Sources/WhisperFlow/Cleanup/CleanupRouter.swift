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
        // Deterministic dictionary corrections apply on EVERY path, including
        // passthrough/raw fallback, so they work even without an LLM.
        func finalize(_ text: String, backendName: String, fellBackToRaw: Bool) -> CleanupResult {
            let corrected = Self.applyCorrections(corrections, to: text)
            return CleanupResult(text: corrected, backendName: backendName, fellBackToRaw: fellBackToRaw, durationMs: elapsedMs())
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

    static func containsCorrectionCue(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return correctionCues.contains { lower.contains($0) }
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
    static func droppedQuestion(raw: String, cleaned: String) -> Bool {
        raw.contains("?") && !cleaned.contains("?")
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
