import Foundation

/// What the Insights section shows: how much this Mac has been dictating, read off the
/// usage log that is already written after every dictation. Nothing here leaves the Mac and
/// nothing new is recorded for it.
///
/// The log is append-only JSONL that has grown fields over a year, so the lines are read as
/// loose dictionaries rather than through `UsageLog.Entry`: an old line missing a field that
/// is not optional today must still count, not blow up the whole section.
enum Insights {
    /// One dictation, reduced to the three things this section needs.
    struct Sample: Equatable, Sendable {
        let date: Date
        let words: Int
        let audioSeconds: Double
    }

    struct Day: Equatable, Sendable, Identifiable {
        let day: Date
        let dictations: Int
        let words: Int

        var id: Date { day }
    }

    struct Summary: Equatable, Sendable {
        let days: [Day]
        let dictations: Int
        let words: Int
        let audioSeconds: Double

        var isEmpty: Bool { dictations == 0 }

        var minutesOfAudio: Int { Int((audioSeconds / 60).rounded()) }

        var averageWordsPerDictation: Int {
            dictations == 0 ? 0 : Int((Double(words) / Double(dictations)).rounded())
        }

        /// Forty words a minute is a fair typing speed for prose somebody is composing as
        /// they go, so it is the number the estimate is stated at, out loud, on the page.
        var minutesSaved: Int { Int((Double(words) / Self.typingWordsPerMinute).rounded()) }

        static let typingWordsPerMinute: Double = 40

        static let empty = Summary(days: [], dictations: 0, words: 0, audioSeconds: 0)
    }

    /// The window the section covers.
    static let windowDays = 30

    /// Five characters a word is the usual English average including the space after it, and
    /// the log stores a character count rather than a word count.
    static let charactersPerWord = 5

    static func words(cleanedChars: Int, rawChars: Int) -> Int {
        let chars = cleanedChars > 0 ? cleanedChars : rawChars
        guard chars > 0 else { return 0 }
        return Int((Double(chars) / Double(charactersPerWord)).rounded())
    }

    /// Reads one JSONL line. Returns nil for a blank line, a line that is not JSON, a line
    /// with no timestamp, and a dictation that produced no text (a silence guard firing, an
    /// empty transcript): none of those are dictations anybody did.
    static func sample(fromLine line: String) -> Sample? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let ts = object["ts"] as? String, let date = FlowClient.parseISO8601(ts) else { return nil }
        let cleaned = (object["cleaned_chars"] as? Int) ?? Int((object["cleaned_chars"] as? Double) ?? 0)
        let raw = (object["raw_chars"] as? Int) ?? Int((object["raw_chars"] as? Double) ?? 0)
        let count = words(cleanedChars: cleaned, rawChars: raw)
        guard count > 0 else { return nil }
        let seconds = (object["audio_seconds"] as? Double) ?? Double((object["audio_seconds"] as? Int) ?? 0)
        return Sample(date: date, words: count, audioSeconds: max(0, seconds))
    }

    /// Every day in the window, including the ones with nothing on them, so the chart shows
    /// the gaps instead of squeezing them out.
    static func summarise(_ samples: [Sample], now: Date = Date(),
                          calendar: Calendar = .current, days: Int = windowDays) -> Summary {
        let today = calendar.startOfDay(for: now)
        guard let first = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return .empty }

        var buckets: [Date: (dictations: Int, words: Int)] = [:]
        var dictations = 0
        var words = 0
        var audio: Double = 0
        for sample in samples {
            let day = calendar.startOfDay(for: sample.date)
            guard day >= first, day <= today else { continue }
            var bucket = buckets[day] ?? (0, 0)
            bucket.dictations += 1
            bucket.words += sample.words
            buckets[day] = bucket
            dictations += 1
            words += sample.words
            audio += sample.audioSeconds
        }

        var out: [Day] = []
        var cursor = first
        while cursor <= today {
            let bucket = buckets[cursor] ?? (0, 0)
            out.append(Day(day: cursor, dictations: bucket.dictations, words: bucket.words))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return Summary(days: out, dictations: dictations, words: words, audioSeconds: audio)
    }

    /// The log off disk. A missing or unreadable file is an empty summary, which is what a
    /// Mac that has never dictated should see.
    static func read(url: URL = UsageLog.logURL, now: Date = Date(),
                     calendar: Calendar = .current) -> Summary {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .empty }
        let samples = text.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { sample(fromLine: String($0)) }
        return summarise(samples, now: now, calendar: calendar)
    }
}
