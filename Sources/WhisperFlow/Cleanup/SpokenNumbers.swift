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
/// Scoped to 0-99 (units, teens, tens, and simple tens+units compounds like
/// "twenty five"). Deliberately does NOT attempt "hundred"/"thousand"
/// grammar -- the compounding and "and"-insertion rules add real complexity
/// for a case that's rare in short dictation notes; if that turns out to
/// matter in practice, extend the tables below rather than reaching for an
/// LLM to do it.
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
