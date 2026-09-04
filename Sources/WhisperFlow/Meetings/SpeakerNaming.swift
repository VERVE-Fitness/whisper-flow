import Foundation

/// Week 1 naming: the owner is the owner; the other diarised speakers get the
/// typed attendee names in the order they first spoke, then "Speaker N".
/// Wrong guesses are expected on a first meeting with a new group and are
/// fixed with rename/reassign. No voice memory across meetings (a biometric,
/// deliberately out of scope).
enum SpeakerNaming {
    static func proposeNames(for transcript: Transcript, ownerName: String, attendees: [String]) -> [String: String] {
        var names = transcript.speakerNames
        names[TranscriptBuilder.ownerSpeakerId] = names[TranscriptBuilder.ownerSpeakerId] ?? ownerName
        var firstSeen: [String] = []
        for s in transcript.segments.sorted(by: { $0.start < $1.start }) where s.speakerId != TranscriptBuilder.ownerSpeakerId {
            if !firstSeen.contains(s.speakerId) { firstSeen.append(s.speakerId) }
        }
        let taken = Set(names.values)
        var pool = attendees.filter { !taken.contains($0) }
        var n = 1
        for id in firstSeen where names[id] == nil {
            if !pool.isEmpty {
                names[id] = pool.removeFirst()
            } else {
                n += 1
                names[id] = "Speaker \(n)"
            }
        }
        return names
    }

    static func renamed(_ transcript: Transcript, speakerId: String, to name: String) -> Transcript {
        var t = transcript
        t.speakerNames[speakerId] = name
        return t
    }

    static func reassigned(_ transcript: Transcript, segmentIndex: Int, to speakerId: String) -> Transcript {
        var t = transcript
        guard t.segments.indices.contains(segmentIndex) else { return t }
        t.segments[segmentIndex].speakerId = speakerId
        return t
    }
}
