import Foundation

struct TimedWord: Equatable {
    let text: String
    let start: Double
    let end: Double
}

struct SpeakerSpan: Equatable {
    let speakerId: String
    let start: Double
    let end: Double
}

struct TranscriptSegment: Codable, Equatable {
    var speakerId: String
    var start: Double
    var end: Double
    var text: String
}

struct Transcript: Codable, Equatable {
    var meetingID: String
    var segments: [TranscriptSegment]
    /// speaker id -> display name. "owner" is always the recording person.
    var speakerNames: [String: String]
}

/// Pure functions from token timings + speaker spans to a readable
/// transcript. No models, no I/O, fully unit-tested.
enum TranscriptBuilder {
    static let ownerSpeakerId = "owner"
    private static let wordStart: Character = "\u{2581}"   // SentencePiece "▁"

    /// Groups SentencePiece tokens into words: a token starting with "▁"
    /// begins a new word; everything else (including punctuation) attaches to
    /// the current word. Word timing spans its first to last token.
    static func words(fromTokens tokens: [(token: String, start: Double, end: Double)]) -> [TimedWord] {
        var out: [TimedWord] = []
        var text = ""; var start = 0.0; var end = 0.0
        func flush() {
            let t = text.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out.append(TimedWord(text: t, start: start, end: end)) }
            text = ""
        }
        for tok in tokens {
            if tok.token.first == wordStart {
                flush()
                text = String(tok.token.dropFirst()); start = tok.start; end = tok.end
            } else {
                if text.isEmpty { start = tok.start }
                text += tok.token; end = tok.end
            }
        }
        flush()
        return out
    }

    /// One speaker, split into segments wherever the silence between words
    /// exceeds `gap` seconds.
    static func segments(words: [TimedWord], speakerId: String, gap: Double = 0.8) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        for w in words {
            if var last = out.last, w.start - last.end <= gap {
                last.text += " " + w.text; last.end = w.end
                out[out.count - 1] = last
            } else {
                out.append(TranscriptSegment(speakerId: speakerId, start: w.start, end: w.end, text: w.text))
            }
        }
        return out
    }

    /// Each word goes to the span containing its midpoint; a word outside
    /// every span goes to the nearest span edge within one second, else to
    /// `unknownId`. Consecutive words with the same speaker form one segment.
    static func assign(words: [TimedWord], to spans: [SpeakerSpan], unknownId: String = "speaker_unknown") -> [TranscriptSegment] {
        let sorted = spans.sorted { $0.start < $1.start }
        var out: [TranscriptSegment] = []
        for w in words {
            let mid = (w.start + w.end) / 2
            var speaker = sorted.first { $0.start <= mid && mid <= $0.end }?.speakerId
            if speaker == nil {
                let nearest = sorted.min { distance(mid, $0) < distance(mid, $1) }
                if let nearest, distance(mid, nearest) <= 1.0 { speaker = nearest.speakerId }
            }
            let id = speaker ?? unknownId
            if var last = out.last, last.speakerId == id {
                last.text += " " + w.text; last.end = w.end
                out[out.count - 1] = last
            } else {
                out.append(TranscriptSegment(speakerId: id, start: w.start, end: w.end, text: w.text))
            }
        }
        return out
    }

    private static func distance(_ t: Double, _ span: SpeakerSpan) -> Double {
        if t < span.start { return span.start - t }
        if t > span.end { return t - span.end }
        return 0
    }

    static func merge(_ a: [TranscriptSegment], _ b: [TranscriptSegment]) -> [TranscriptSegment] {
        (a + b).sorted { $0.start < $1.start }
    }

    static func markdown(_ t: Transcript, title: String, startedAt: Date) -> String {
        let df = DateFormatter(); df.dateFormat = "d MMMM yyyy, h:mm a"; df.locale = Locale(identifier: "en_AU")
        var lines = ["# \(title.isEmpty ? "Meeting" : title)", "", "Recorded \(df.string(from: startedAt)) with Whisper Flow.", ""]
        for s in t.segments {
            let name = t.speakerNames[s.speakerId] ?? s.speakerId
            lines.append("**[\(stamp(s.start))] \(name):** \(s.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func stamp(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
