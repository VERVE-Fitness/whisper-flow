import Foundation

/// Picks between the streaming transcript and the batch one, and holds the
/// two constants that stop a dictation losing its last words.
///
/// The problem this exists for: the sliding-window streaming decoder commits
/// words a window at a time, so the tail of a dictation can still be sitting
/// in the volatile window when the key is released, and it never gets
/// committed. Three things fix it together, and only the third one is a
/// judgement call worth testing on its own:
///
/// 1. the mic stays open 400 ms after the key is released, because people let
///    go on the last syllable;
/// 2. 600 ms of silence is fed into the streaming session before `finish()`,
///    which is what makes the window commit its last words;
/// 3. for a dictation of two minutes or less the app re-decodes the complete
///    retained buffer through the batch path, which never had a window to
///    lose anything from, and uses that text unless it came back short.
enum TranscriptChoice {

    /// Feed this much silence into the streaming session before finishing it.
    static let silencePadSeconds: Double = 0.6
    /// Keep the mic open this long after the key is released.
    static let releaseTailSeconds: Double = 0.4
    /// Anything at or under this runs through the batch decoder as well. Two
    /// minutes of 16 kHz mono is about 7.7 MB and a second or two of Neural
    /// Engine time; a forty minute dictation is neither.
    static let batchRecheckMaxSeconds: Double = 120
    /// The batch pass gets 8 seconds. Past that the streaming text stands.
    static let batchTimeoutSeconds: UInt64 = 8
    /// The batch text is used unless it came back with fewer than half the
    /// words the streaming pass heard. The batch decoder occasionally drops
    /// an out-of-vocabulary opening outright (observed 2026-07-08: spoken
    /// "The VERVE Tori Functional Trainer", batch returned just "Functional
    /// trainer"), and a mangled attempt at a product name that the phrase and
    /// dictionary passes can still fix beats a clean transcript missing it.
    static let batchWordFloor = 0.5

    /// 9,600 samples at 16 kHz.
    static var silencePadSampleCount: Int {
        Int((AudioCapture.targetSampleRate * silencePadSeconds).rounded())
    }

    /// The silence to feed in before `finish()`. Real zeros, not noise: the
    /// decoder needs the window to look like the speaker stopped.
    static func silencePad() -> [Float] {
        [Float](repeating: 0, count: silencePadSampleCount)
    }

    static var releaseTailNanoseconds: UInt64 {
        UInt64(releaseTailSeconds * 1_000_000_000)
    }

    enum Source: String, Equatable {
        case streaming
        case batch
    }

    struct Choice: Equatable {
        let text: String
        let source: Source
        let streamingWords: Int
        let batchWords: Int
    }

    /// Pure. `batch` is nil when the clip was too long for the re-check, or
    /// the batch pass failed or timed out.
    static func choose(streaming: String, batch: String?) -> Choice {
        let streamingWords = wordCount(streaming)
        guard let batch else {
            return Choice(text: streaming, source: .streaming,
                          streamingWords: streamingWords, batchWords: 0)
        }
        let batchWords = wordCount(batch)
        let keepsEnough = Double(batchWords) >= Double(streamingWords) * batchWordFloor
        return Choice(text: keepsEnough ? batch : streaming,
                      source: keepsEnough ? .batch : .streaming,
                      streamingWords: streamingWords, batchWords: batchWords)
    }

    /// The line that makes a future truncation visible in the log.
    static func logLine(_ choice: Choice) -> String {
        "[stt] streaming \(choice.streamingWords) words, batch \(choice.batchWords) words, using \(choice.source.rawValue)"
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
