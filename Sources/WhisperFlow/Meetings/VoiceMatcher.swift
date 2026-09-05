import Foundation
import FluidAudio

/// One diariser chunk: a stretch of audio the offline diariser assigned to a
/// cluster, with the 256-dim embedding it extracted for it. This is the app's
/// own shape rather than FluidAudio's, so the matching below can be tested
/// with hand-written numbers and no models.
struct SpeakerChunk: Equatable {
    let speakerId: String
    let start: Double
    let end: Double
    let embedding: [Float]

    var seconds: Double { max(0, end - start) }

    init(speakerId: String, start: Double, end: Double, embedding: [Float]) {
        self.speakerId = speakerId
        self.start = start
        self.end = end
        self.embedding = embedding
    }

    /// From FluidAudio's `ChunkEmbedding` (only present when the offline
    /// diariser config has `exposeChunkEmbeddings = true`).
    init(_ chunk: ChunkEmbedding) {
        self.init(speakerId: chunk.speakerId,
                  start: chunk.startTimeSeconds,
                  end: chunk.endTimeSeconds,
                  embedding: chunk.embedding256)
    }
}

/// Matches a meeting's speakers against the voice profiles Flow holds, so a
/// colleague who has been confirmed once is never asked about again.
///
/// A profile only exists for a VERVE staff member who switched on "recognise
/// my voice" on their own settings page, or for the person doing the
/// confirming. Customers and outsiders get a name on the one recording and no
/// stored voiceprint.
enum VoiceMatcher {
    // The two numbers that decide every match, in one place.
    //
    // FluidAudio's `SpeakerUtilities.cosineDistance` (declared in
    // Diarizer/Clustering/SpeakerOperations.swift) runs 0 (identical) to 2 (opposite). 0.45 is the
    // furthest a voice may be from a stored profile and still be called the
    // same person; below that, same-speaker pairs sit comfortably and
    // different-speaker pairs do not. `minMargin` is the gap the best profile
    // must have over the second best: two colleagues who sound alike produce
    // two close distances, and a coin toss between them is worse than asking.
    static let maxDistance: Float = 0.45
    static let minMargin: Float = 0.10

    struct Match: Equatable {
        let email: String
        let name: String?
        let distance: Float
        /// Distance to the next closest profile, nil when there was only one.
        let runnerUp: Float?
    }

    /// Duration-weighted mean of a speaker's chunk embeddings, re-normalised
    /// to unit length. Weighted because a 40 second chunk describes the voice
    /// far better than a 1 second one, and an unweighted mean lets short
    /// noisy chunks drag the profile around.
    static func meanEmbedding(for speakerId: String, chunks: [SpeakerChunk]) -> [Float]? {
        let mine = chunks.filter { $0.speakerId == speakerId && !$0.embedding.isEmpty }
        guard let width = mine.first?.embedding.count, width > 0 else { return nil }
        var sum = [Float](repeating: 0, count: width)
        var totalWeight: Double = 0
        for chunk in mine where chunk.embedding.count == width {
            // A zero-length chunk still carries a real embedding; give it a
            // small floor rather than dropping it.
            let weight = max(chunk.seconds, 0.01)
            totalWeight += weight
            for i in 0..<width { sum[i] += Float(weight) * chunk.embedding[i] }
        }
        guard totalWeight > 0 else { return nil }
        for i in 0..<width { sum[i] /= Float(totalWeight) }
        return normalised(sum)
    }

    /// Unit length, so a stored profile and a fresh mean are on the same
    /// scale and the server's running mean stays comparable over time.
    static func normalised(_ v: [Float]) -> [Float]? {
        let magnitude = v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard magnitude > 0, magnitude.isFinite else { return nil }
        return v.map { $0 / magnitude }
    }

    /// Total speech seconds the diariser gave this speaker.
    static func seconds(for speakerId: String, chunks: [SpeakerChunk]) -> Double {
        chunks.filter { $0.speakerId == speakerId }.reduce(0) { $0 + $1.seconds }
    }

    /// Speaker ids in the order they first spoke, which is the order unnamed
    /// speakers are numbered in.
    static func speakerIds(in chunks: [SpeakerChunk]) -> [String] {
        var seen: [String] = []
        for chunk in chunks.sorted(by: { $0.start < $1.start }) where !seen.contains(chunk.speakerId) {
            seen.append(chunk.speakerId)
        }
        return seen
    }

    /// The cluster with the most speech. Track A is one person, but the
    /// diariser does not know that and will happily split a cough or a
    /// bleed-through into a second cluster, so the owner's embedding is taken
    /// from whichever cluster did most of the talking.
    static func dominantSpeaker(in chunks: [SpeakerChunk]) -> String? {
        let totals = Dictionary(grouping: chunks, by: \.speakerId).mapValues { group in
            group.reduce(0.0) { $0 + $1.seconds }
        }
        // Ties break on the id so the answer never depends on dictionary order.
        return totals.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    /// Nearest profile, if it is near enough and clearly nearer than the next
    /// one. Returns nil when nothing is close, when two profiles are too
    /// close to each other to choose, or when there are no profiles at all.
    static func match(embedding: [Float], profiles: [FlowVoiceProfile]) -> Match? {
        let ranked = ranking(embedding: embedding, profiles: profiles)
        guard let best = ranked.first else { return nil }
        guard best.distance < maxDistance else { return nil }
        let runnerUp = ranked.dropFirst().first?.distance
        if let runnerUp, runnerUp - best.distance < minMargin { return nil }
        return Match(email: best.profile.email, name: best.profile.name,
                     distance: best.distance, runnerUp: runnerUp)
    }

    /// Every profile with its distance, nearest first. Exposed so a failed
    /// match can still report how close it got.
    static func ranking(embedding: [Float], profiles: [FlowVoiceProfile]) -> [(profile: FlowVoiceProfile, distance: Float)] {
        guard !embedding.isEmpty else { return [] }
        return profiles
            .filter { $0.embedding.count == embedding.count && !$0.embedding.isEmpty }
            .map { (profile: $0, distance: SpeakerUtilities.cosineDistance(embedding, $0.embedding)) }
            .filter { $0.distance.isFinite }
            .sorted { ($0.distance, $0.profile.email) < ($1.distance, $1.profile.email) }
    }

    /// Every match decision reaches stderr, matched or not, so a wrong name
    /// can be explained after the fact instead of guessed at.
    static func logDecision(speakerId: String, match: Match?, ranking: [(profile: FlowVoiceProfile, distance: Float)]) {
        let line: String
        if let match {
            let next = match.runnerUp.map { String(format: "%.2f", $0) } ?? "none"
            line = "[meeting] speaker \(speakerId) -> \(shortEmail(match.email)) (\(String(format: "%.2f", match.distance)), next \(next))"
        } else if let best = ranking.first {
            line = "[meeting] speaker \(speakerId) unmatched (best \(String(format: "%.2f", best.distance)))"
        } else {
            line = "[meeting] speaker \(speakerId) unmatched (no voice profiles to compare against)"
        }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Enough of the address to know who, not enough to be a mailing list.
    static func shortEmail(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@") else { return email }
        return String(email[email.startIndex..<at]) + "@\u{2026}"
    }
}

/// The profiles Flow holds, kept on disk so a Stop that happens offline can
/// still match speakers. Refreshed at every connect and every Stop.
enum VoiceProfileCache {
    /// Tests point this at a temp file.
    nonisolated(unsafe) static var urlOverride: URL?

    static var url: URL {
        urlOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperFlow", isDirectory: true)
            .appendingPathComponent("voice-profiles.json")
    }

    static func load() -> [FlowVoiceProfile] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([FlowVoiceProfile].self, from: data)) ?? []
    }

    static func save(_ profiles: [FlowVoiceProfile]) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(profiles).write(to: url, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("[flow] could not cache the voice profiles: \(error.localizedDescription)\n".utf8))
        }
    }
}
