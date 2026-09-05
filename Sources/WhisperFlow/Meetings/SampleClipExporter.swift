import Foundation

/// Cuts a short clip of each speaker the app could not put a name to, so the
/// person confirming on the settings page hears the voice instead of guessing
/// from a transcript line. Eight seconds is enough to recognise a colleague
/// and short enough that nobody sits through a meeting to answer one question.
///
/// Only unmatched track-B speakers get a clip. A matched speaker needs no
/// question asked, and the owner is on track A and is never in doubt.
enum SampleClipExporter {
    /// Longest clip taken. Beyond this the confirmer is just listening.
    static let maxSeconds: Double = 8
    /// Below this there is not enough voice to recognise, so no clip is made
    /// and the speaker is confirmed from the transcript instead.
    static let minSeconds: Double = 2
    /// Two stretches of the same speaker closer than this are one turn: the
    /// diariser breaks a sentence at a breath, and a clip that stops at the
    /// breath is half a word.
    static let joinGapSeconds: Double = 0.6

    struct Span: Equatable {
        let start: Double
        let end: Double
        var seconds: Double { max(0, end - start) }
    }

    /// The stretch of `speakerId` to cut, or nil when they never spoke for
    /// long enough. Pure, so the selection is tested without any audio.
    static func bestSpan(for speakerId: String, chunks: [SpeakerChunk]) -> Span? {
        let mine = chunks
            .filter { $0.speakerId == speakerId && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        guard !mine.isEmpty else { return nil }

        var runs: [Span] = []
        for chunk in mine {
            if let last = runs.last, chunk.start - last.end <= joinGapSeconds {
                // Overlapping or touching: extend, never shorten.
                runs[runs.count - 1] = Span(start: last.start, end: max(last.end, chunk.end))
            } else {
                runs.append(Span(start: chunk.start, end: chunk.end))
            }
        }

        // Longest run wins; an exact tie takes the earliest, which is the
        // part of the meeting the confirmer is most likely to remember.
        guard let longest = runs.max(by: { ($0.seconds, $1.start) < ($1.seconds, $0.start) }) else { return nil }
        guard longest.seconds >= minSeconds else { return nil }
        return Span(start: longest.start, end: min(longest.end, longest.start + maxSeconds))
    }

    /// `speaker-S2.m4a`, the only clip name the upload endpoint accepts.
    static func fileName(for speakerId: String) -> String { "speaker-\(speakerId).m4a" }

    /// Writes one clip into the meeting folder and returns its file name, or
    /// nil when the speaker never spoke for long enough. A failed export is
    /// reported on stderr and treated as no clip: a missing sample makes the
    /// question harder, it does not make the recording unusable.
    static func exportClip(meetingID: String, speakerId: String, chunks: [SpeakerChunk]) -> String? {
        guard let span = bestSpan(for: speakerId, chunks: chunks) else {
            FileHandle.standardError.write(Data("[meeting] no sample clip for \(speakerId): under \(Int(minSeconds))s of continuous speech\n".utf8))
            return nil
        }
        let name = fileName(for: speakerId)
        let output = MeetingStore.directory(for: meetingID).appendingPathComponent(name)
        do {
            try AudioEncoder.encodeM4A(wav: MeetingStore.trackBURL(meetingID), to: output,
                                       seconds: span.start...span.end)
            FileHandle.standardError.write(Data("[meeting] sample clip \(name): \(String(format: "%.1f", span.start))s to \(String(format: "%.1f", span.end))s\n".utf8))
            return name
        } catch {
            FileHandle.standardError.write(Data("[meeting] could not export \(name): \(error.localizedDescription)\n".utf8))
            return nil
        }
    }
}
