import Foundation
import FluidAudio

/// Turns a recorded meeting's two WAV tracks into one speaker-labelled
/// transcript. Track A (the owner's mic) is always speaker "owner". Track B
/// (system audio) is diarised with FluidAudio's offline diariser and its
/// words are assigned to speakers by time. Runs fully on the Mac.
final class MeetingTranscriber {
    private let backend: ParakeetBackend
    private let onStatus: (@Sendable (String) -> Void)?
    private let diarizer = OfflineDiarizerManager(config: .default)
    private var diarizerReady = false

    init(backend: ParakeetBackend, onStatus: (@Sendable (String) -> Void)? = nil) {
        self.backend = backend
        self.onStatus = onStatus
    }

    func transcribe(meetingID: String) async throws -> Transcript {
        var record = try MeetingStore.load(id: meetingID)
        record.status = .transcribing
        try MeetingStore.save(record)
        do {
            onStatus?("Loading speech model…")
            try await backend.prepare()

            // Track A: the owner.
            onStatus?("Transcribing your side…")
            let a = try await backend.transcribeLong(url: MeetingStore.trackAURL(meetingID))
            let aSegments = segmentsForSingleSpeaker(a, speakerId: TranscriptBuilder.ownerSpeakerId)

            // Track B: everyone else. Skip an empty track (no system audio).
            var bSegments: [TranscriptSegment] = []
            if record.trackBSeconds > 1.0 {
                onStatus?("Transcribing the other side…")
                let b = try await backend.transcribeLong(url: MeetingStore.trackBURL(meetingID))
                if !b.text.isEmpty {
                    onStatus?("Separating speakers…")
                    let spans = try await diarise(url: MeetingStore.trackBURL(meetingID))
                    let words = TranscriptBuilder.words(fromTokens: b.tokens)
                    if words.isEmpty || spans.isEmpty {
                        // No timings or no speakers found: one block for "them",
                        // under the same id shape the diariser uses ("S1", "S2", …)
                        // so nothing downstream has to know two conventions.
                        bSegments = [TranscriptSegment(speakerId: "S1", start: 0, end: record.trackBSeconds, text: b.text)]
                    } else {
                        bSegments = TranscriptBuilder.assign(words: words, to: spans)
                    }
                    FileHandle.standardError.write(Data("[meeting] track B: \(words.count) words, \(spans.count) speaker spans \(Set(spans.map(\.speakerId)).sorted()) -> \(bSegments.count) segments\n".utf8))
                }
            }

            var names = record.speakerNames
            names[TranscriptBuilder.ownerSpeakerId] = names[TranscriptBuilder.ownerSpeakerId] ?? NSFullUserName()
            let transcript = Transcript(meetingID: meetingID,
                                        segments: TranscriptBuilder.merge(aSegments, bSegments),
                                        speakerNames: names)
            guard !transcript.segments.isEmpty else { throw MeetingError.noTranscript }
            try write(transcript, record: record)
            record.speakerNames = names
            record.status = .transcribed
            try MeetingStore.save(record)
            return transcript
        } catch {
            record.status = .failed
            record.failureReason = error.localizedDescription
            try? MeetingStore.save(record)
            throw error
        }
    }

    private func segmentsForSingleSpeaker(_ r: (text: String, tokens: [(token: String, start: Double, end: Double)]), speakerId: String) -> [TranscriptSegment] {
        let words = TranscriptBuilder.words(fromTokens: r.tokens)
        if words.isEmpty {
            return r.text.isEmpty ? [] : [TranscriptSegment(speakerId: speakerId, start: 0, end: 0, text: r.text)]
        }
        return TranscriptBuilder.segments(words: words, speakerId: speakerId)
    }

    private func diarise(url: URL) async throws -> [SpeakerSpan] {
        if !diarizerReady {
            // First run downloads the diariser models (~100 MB) into the
            // same cache the speech model uses.
            try await diarizer.prepareModels()
            diarizerReady = true
        }
        // Bind the callback to a local so the @Sendable progress closure does
        // not capture this (non-Sendable) transcriber.
        let onStatus = self.onStatus
        let result = try await diarizer.process(url) { done, total in
            onStatus?("Separating speakers… \(total > 0 ? Int(Double(done) / Double(total) * 100) : 0)%")
        }
        return result.segments.map {
            SpeakerSpan(speakerId: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
    }

    func write(_ transcript: Transcript, record: MeetingRecord) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(transcript).write(to: MeetingStore.transcriptJSONURL(record.id), options: .atomic)
        try TranscriptBuilder.markdown(transcript, title: record.title, startedAt: record.startedAt)
            .write(to: MeetingStore.transcriptMarkdownURL(record.id), atomically: true, encoding: .utf8)
    }
}
