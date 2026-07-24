import Foundation

/// Deterministic conversion of spoken number words to digits ("five minutes"
/// -> "5 minutes", "twenty five dollars" -> "25 dollars"). Runs inside
/// CleanupRouter.finalize() -- on every path, including Passthrough -- for
/// the same reason self-correction stripping does (see
/// CleanupRouter.stripStandaloneCorrections): an LLM-prompt-based version
/// would silently stop working whenever Ollama isn't running, and even when
/// it is, having the LLM change "five" to "5" risks tripping the
/// content-retention guard, since "five" and "5" share no characters as
/// tokens. Running this deterministically, after the guard has already
/// decided which text to use, sidesteps that entirely.
///
/// Handles 0-99 (units, teens, tens, and simple tens+units compounds like
/// "twenty five"), plus "hundred"/"thousand" magnitude grammar: "two
/// hundred" -> "200", "two hundred and forty five" -> "245", "five thousand
/// two hundred and thirty one" -> "5231". This used to be out of scope
/// (the compounding and "and"-insertion rules add real complexity), but it
/// turned out to matter in practice: STT reliably renders "two hundred and
/// forty five" as digit-and-word soup ("2 hundred and 40"), and the digit
/// tokens have to be handled inline with the word tokens, not as a separate
/// pass -- see parseSmallNumber. If a case beyond hundreds/thousands turns
/// out to matter (e.g. "million"), extend the parse functions below rather
/// than reaching for an LLM to do it.
enum SpokenNumbers {
    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let tensWords: Set<String> = [
        "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
    ]

    /// "one" is disproportionately non-numeric in ordinary speech ("one of",
    /// "no one", "someone", "the one") -- only convert it when a unit noun
    /// immediately follows, which is specifically the pattern that motivated
    /// this ("wait one minute", "say ten minutes").
    private static let oneUnitFollowers: Set<String> = [
        "minute", "minutes", "hour", "hours", "second", "seconds",
        "day", "days", "week", "weeks", "month", "months", "year", "years",
        "dollar", "dollars", "buck", "bucks", "percent", "time", "times", "o'clock",
    ]

    static func convert(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let tokens = text.components(separatedBy: " ")
        var out: [String] = []
        var i = 0
        while i < tokens.count {
            let (word, punct) = split(tokens[i])
            let key = word.lowercased()

            // Magnitude phrases ("two hundred", "five thousand two hundred
            // and thirty one") must be tried before the plain 0-99 checks
            // below: "two" alone is also a valid unit, and without this
            // running first, "two hundred" would fall through as the plain
            // unit "2" followed by the un-converted word "hundred". This
            // never fires for a bare unit/tens word with no "hundred" or
            // "thousand" following -- it returns nil and the existing
            // checks below run exactly as before.
            if let magnitude = parseMagnitudeNumber(tokens, at: i) {
                out.append(String(magnitude.value) + magnitude.punct)
                i += magnitude.consumed
                continue
            }

            if key == "one" {
                if i + 1 < tokens.count, oneUnitFollowers.contains(split(tokens[i + 1]).word.lowercased()) {
                    out.append("1" + punct)
                } else {
                    out.append(tokens[i])
                }
                i += 1
                continue
            }

            // Compound "twenty five" -> "25": only when the two words are
            // adjacent with no intervening punctuation (a comma or period
            // between them means they're not one number).
            if tensWords.contains(key), i + 1 < tokens.count {
                let (nextWord, nextPunct) = split(tokens[i + 1])
                if let unitsValue = units[nextWord.lowercased()], punct.isEmpty, unitsValue > 0, unitsValue < 10 {
                    out.append(String(units[key]! + unitsValue) + nextPunct)
                    i += 2
                    continue
                }
            }

            if let value = units[key] {
                out.append(String(value) + punct)
                i += 1
                continue
            }

            out.append(tokens[i])
            i += 1
        }
        return out.joined(separator: " ")
    }

    /// Parses a 1-99 value starting at token index i: a single number word
    /// ("twelve"), a tens+units compound ("forty five" -> 45, same adjacency
    /// rule as the standalone compounding in convert()), or a pure-digit
    /// token that already spells a 1-99 value outright. The digit case
    /// matters because STT frequently mixes digits and number words in the
    /// same magnitude phrase ("2 hundred and 40") -- a digit token like "40"
    /// is taken whole here, not decomposed into "4" + "0".
    private static func parseSmallNumber(_ tokens: [String], at i: Int) -> (value: Int, consumed: Int, punct: String)? {
        guard i < tokens.count else { return nil }
        let (word, punct) = split(tokens[i])

        if let digitValue = Int(word), (1...99).contains(digitValue) {
            return (digitValue, 1, punct)
        }

        let key = word.lowercased()
        guard let value = units[key], value > 0 else { return nil }

        // Compound "twenty five" -> 25: only when adjacent with no
        // punctuation on the first word -- mirrors the standalone
        // tens-compounding rule in convert().
        if tensWords.contains(key), punct.isEmpty, i + 1 < tokens.count {
            let (nextWord, nextPunct) = split(tokens[i + 1])
            if let unitsValue = units[nextWord.lowercased()], unitsValue > 0, unitsValue < 10 {
                return (value + unitsValue, 2, nextPunct)
            }
            if let digitValue = Int(nextWord), (1...9).contains(digitValue) {
                return (value + digitValue, 2, nextPunct)
            }
        }
        return (value, 1, punct)
    }

    /// If the token at `index` is a bare "and" with no trailing punctuation,
    /// skips past it. "and" only ever binds a magnitude word to its
    /// continuation ("two hundred AND forty") -- it's never part of the
    /// number itself, so callers that fail to find a valid continuation
    /// after this must NOT treat "and" as consumed (see parseHundredPart
    /// and parseMagnitudeNumber for the rollback that relies on this).
    private static func optionalAndIndex(_ tokens: [String], after index: Int) -> Int {
        guard index < tokens.count else { return index }
        let (word, punct) = split(tokens[index])
        return (word.lowercased() == "and" && punct.isEmpty) ? index + 1 : index
    }

    /// Parses "<1-9> hundred [and <1-99>]" starting at token index i. Word
    /// or digit form for the leading unit, word or digit form for the
    /// trailing continuation (via parseSmallNumber). Returns nil when there's
    /// no "hundred" immediately after a 1-9 unit -- e.g. "twenty hundred"
    /// doesn't parse (20 isn't a valid hundreds-unit), nor does a unit
    /// followed by anything else.
    private static func parseHundredPart(_ tokens: [String], at i: Int) -> (value: Int, consumed: Int, punct: String)? {
        guard i < tokens.count else { return nil }
        let (word, punct) = split(tokens[i])
        let key = word.lowercased()

        var unitValue: Int?
        if let digitValue = Int(word), (1...9).contains(digitValue) {
            unitValue = digitValue
        } else if let value = units[key], (1...9).contains(value) {
            unitValue = value
        }
        guard let uValue = unitValue, punct.isEmpty, i + 1 < tokens.count else { return nil }

        let (hundredWord, hundredPunct) = split(tokens[i + 1])
        guard hundredWord.lowercased() == "hundred" else { return nil }

        let hundredsValue = uValue * 100
        // Punctuation right after "hundred" ends the phrase there -- a
        // period or comma between "hundred" and what follows means they
        // aren't one number.
        if !hundredPunct.isEmpty {
            return (hundredsValue, 2, hundredPunct)
        }

        let contIndex = optionalAndIndex(tokens, after: i + 2)
        if let tail = parseSmallNumber(tokens, at: contIndex) {
            return (hundredsValue + tail.value, (contIndex - i) + tail.consumed, tail.punct)
        }
        // No valid continuation ("hundred" followed by a non-number word, or
        // nothing at all) -- leave "and", if present, unconsumed so the main
        // loop re-emits it untouched ("two hundred and I mean it" -> "200
        // and I mean it", not "200 mean it").
        return (hundredsValue, 2, hundredPunct)
    }

    /// Parses a full magnitude expression starting at token index i:
    /// "<1-99> thousand [and] <1-9> hundred [and] <1-99>" and every valid
    /// truncation of that (thousand alone, thousand+hundred, thousand+tens,
    /// hundred alone, hundred+tens). Returns nil when no "hundred" or
    /// "thousand" is present, leaving the token to the plain 0-99 checks in
    /// convert().
    private static func parseMagnitudeNumber(_ tokens: [String], at i: Int) -> (value: Int, consumed: Int, punct: String)? {
        // "<1-99> thousand [...]"
        if let small = parseSmallNumber(tokens, at: i), small.punct.isEmpty, i + small.consumed < tokens.count {
            let thousandIndex = i + small.consumed
            let (thousandWord, thousandPunct) = split(tokens[thousandIndex])
            if thousandWord.lowercased() == "thousand" {
                let thousandsValue = small.value * 1000
                let afterThousand = thousandIndex + 1
                // Punctuation right after "thousand", or nothing left to
                // read, ends the phrase there.
                if !thousandPunct.isEmpty || afterThousand >= tokens.count {
                    return (thousandsValue, small.consumed + 1, thousandPunct)
                }
                let contIndex = optionalAndIndex(tokens, after: afterThousand)
                if let hundredPart = parseHundredPart(tokens, at: contIndex) {
                    return (thousandsValue + hundredPart.value, (contIndex - i) + hundredPart.consumed, hundredPart.punct)
                }
                if let tail = parseSmallNumber(tokens, at: contIndex) {
                    return (thousandsValue + tail.value, (contIndex - i) + tail.consumed, tail.punct)
                }
                // "and" (if any) didn't lead to a valid continuation -- same
                // rollback rule as parseHundredPart: don't consume it.
                return (thousandsValue, small.consumed + 1, thousandPunct)
            }
        }

        // No thousands part -- try a bare "<1-9> hundred [...]".
        return parseHundredPart(tokens, at: i)
    }

    private static func split(_ token: String) -> (word: String, punct: String) {
        var w = token
        var p = ""
        while let last = w.last, ".,!?;:".contains(last) {
            p = String(last) + p
            w.removeLast()
        }
        return (w, p)
    }
}
