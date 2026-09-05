import Foundation

/// What the app worked out about each speaker before the upload: how long
/// they spoke, their voice embedding, and who the voice matched. Written to
/// `voices.json` so a resumed upload never re-runs the diariser.
struct MeetingVoices: Codable, Equatable {
    struct Speaker: Codable, Equatable {
        /// The app's own id: "owner" for track A, "S1", "S2" … for track B.
        var speakerId: String
        var seconds: Double
        var embedding: [Float]?
        var email: String?
        var name: String?
        var matched: Bool
        var sampleFile: String?
    }
    var speakers: [Speaker]
}

/// Where an upload got to. A meeting that is interrupted (quit, sleep, no
/// network) leaves this behind and the app picks it up at the next launch or
/// the next connect.
struct UploadState: Codable, Equatable {
    enum Phase: String, Codable {
        case pending, complete, failed
    }
    var phase: Phase
    /// File names already accepted by Flow, so a resume skips them.
    var files: [String]
    var error: String?
    var updatedAt: Date

    init(phase: Phase = .pending, files: [String] = [], error: String? = nil, updatedAt: Date = Date()) {
        self.phase = phase
        self.files = files
        self.error = error
        self.updatedAt = updatedAt
    }
}

/// Everything that happens between "the transcript is written" and "it is in
/// Flow": match the voices, encode the audio, cut the sample clips, push the
/// files, post the manifest, wait for the summary, write `summary.md`.
///
/// The work is split in two on purpose. `prepare` is all local and runs once.
/// `ship` is all network and can run again and again from what `prepare` left
/// on disk, which is what makes the resume honest: a resumed upload sends
/// exactly what the first attempt would have sent.
struct MeetingUploader: Sendable {
    typealias ProgressHandler = @Sendable (Progress) -> Void

    enum Progress: Equatable {
        case uploading(index: Int, total: Int)
        case summarising
        case done
        case failedWillRetry

        var text: String {
            switch self {
            case .uploading(let index, let total): return "Uploading \(index) of \(total)"
            case .summarising: return "Summarising in Flow"
            case .done: return "Done, open in Flow"
            case .failedWillRetry: return "Upload failed, will retry"
            }
        }
    }

    /// The owner is speaker "A" on the wire; "owner" is the app's own label
    /// and predates the contract.
    static let ownerWireId = "A"
    /// How long to wait for the server's summary before leaving the meeting
    /// uploaded but unsummarised. It is written into Flow either way.
    static let summaryPollInterval: Double = 5
    static let summaryTimeout: Double = 180

    var flow: FlowClient = .shared
    var onProgress: ProgressHandler?

    // MARK: - Pure helpers

    static func wireSpeakerId(_ id: String) -> String {
        id == TranscriptBuilder.ownerSpeakerId ? ownerWireId : id
    }

    /// A placeholder the app invented ("Speaker 2") is not a name and must
    /// not be sent: the server numbers unnamed speakers itself, in first
    /// speech order, and two numbering schemes would disagree.
    static func isPlaceholderName(_ name: String?) -> Bool {
        guard let name else { return true }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        guard trimmed.hasPrefix("Speaker ") else { return false }
        return Int(trimmed.dropFirst("Speaker ".count)) != nil
    }

    /// The files this meeting will send, in the order they go up. Audio
    /// first: it is the part that fails, and failing early keeps the manifest
    /// from describing files that are not there.
    static func plannedFiles(record: MeetingRecord, voices: MeetingVoices) -> [String] {
        var names: [String] = []
        if record.trackASeconds > 0 { names.append("track-a.m4a") }
        if record.trackBSeconds > 0 { names.append("track-b.m4a") }
        names += voices.speakers.compactMap(\.sampleFile).sorted()
        names += ["transcript.json", "meeting.json"]
        return names
    }

    /// What a resume still has to send.
    static func remainingFiles(planned: [String], state: UploadState?) -> [String] {
        guard let state else { return planned }
        guard state.phase != .complete else { return [] }
        let done = Set(state.files)
        return planned.filter { !done.contains($0) }
    }

    /// A meeting worth picking up again: started and not finished.
    static func shouldResume(_ state: UploadState?) -> Bool {
        guard let state else { return false }
        return state.phase == .pending || state.phase == .failed
    }

    /// Matches every speaker against the profiles Flow holds and logs the
    /// decision. The owner is not matched: this Mac knows whose it is.
    static func matchSpeakers(chunks: [SpeakerChunk],
                              profiles: [FlowVoiceProfile],
                              owner: FlowMe?,
                              typedNames: [String: String]) -> MeetingVoices {
        var speakers: [MeetingVoices.Speaker] = []
        for speakerId in VoiceMatcher.speakerIds(in: chunks) {
            let embedding = VoiceMatcher.meanEmbedding(for: speakerId, chunks: chunks)
            let seconds = VoiceMatcher.seconds(for: speakerId, chunks: chunks)
            let typed = typedNames[speakerId]

            if speakerId == TranscriptBuilder.ownerSpeakerId {
                speakers.append(MeetingVoices.Speaker(speakerId: speakerId, seconds: seconds,
                                                      embedding: embedding, email: owner?.email,
                                                      name: owner?.name ?? typed, matched: owner != nil))
                continue
            }

            guard let embedding else {
                speakers.append(MeetingVoices.Speaker(speakerId: speakerId, seconds: seconds,
                                                      embedding: nil, email: nil,
                                                      name: isPlaceholderName(typed) ? nil : typed,
                                                      matched: false))
                continue
            }
            let ranking = VoiceMatcher.ranking(embedding: embedding, profiles: profiles)
            let match = VoiceMatcher.match(embedding: embedding, profiles: profiles)
            VoiceMatcher.logDecision(speakerId: speakerId, match: match, ranking: ranking)
            speakers.append(MeetingVoices.Speaker(
                speakerId: speakerId,
                seconds: seconds,
                embedding: embedding,
                email: match?.email,
                name: match?.name ?? (isPlaceholderName(typed) ? nil : typed),
                matched: match != nil))
        }
        return MeetingVoices(speakers: speakers)
    }

    /// The manifest exactly as it goes on the wire.
    static func buildManifest(record: MeetingRecord, transcript: Transcript, voices: MeetingVoices) -> MeetingManifest {
        let speakers = voices.speakers.map { speaker in
            MeetingManifest.Speaker(
                speakerId: wireSpeakerId(speaker.speakerId),
                email: speaker.email,
                name: isPlaceholderName(speaker.name) ? nil : speaker.name,
                matched: speaker.matched,
                seconds: speaker.seconds,
                embedding: speaker.embedding,
                sampleFile: speaker.sampleFile)
        }
        let segments = transcript.segments.map {
            MeetingManifest.Segment(speakerId: wireSpeakerId($0.speakerId),
                                    start: $0.start, end: $0.end, text: $0.text)
        }
        return MeetingManifest(
            title: record.title,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            trackASeconds: record.trackASeconds,
            trackBSeconds: record.trackBSeconds,
            trackBOffsetSeconds: record.trackBOffsetSeconds,
            attendees: record.attendees,
            consent: MeetingManifest.Consent(confirmedAt: record.consent.confirmedAt,
                                             wordingVersion: record.consent.wordingVersion),
            speakers: speakers,
            segments: segments)
    }

    // MARK: - State file

    static func readState(meetingID: String) -> UploadState? {
        guard let data = try? Data(contentsOf: MeetingStore.uploadStateURL(meetingID)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UploadState.self, from: data)
    }

    @discardableResult
    static func writeState(_ state: UploadState, meetingID: String) -> Bool {
        var state = state
        state.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(state).write(to: MeetingStore.uploadStateURL(meetingID), options: .atomic)
            return true
        } catch {
            FileHandle.standardError.write(Data("[flow] could not write upload-state.json: \(error.localizedDescription)\n".utf8))
            return false
        }
    }

    // MARK: - Prepare (local)

    /// Matches voices, encodes both tracks, cuts the sample clips and writes
    /// `voices.json`, `manifest.json` and a pending `upload-state.json`.
    /// Nothing here needs the network.
    @discardableResult
    func prepare(meetingID: String,
                 transcript: Transcript,
                 chunks: [SpeakerChunk],
                 profiles: [FlowVoiceProfile],
                 owner: FlowMe?) throws -> MeetingManifest {
        let record = try MeetingStore.load(id: meetingID)
        var voices = MeetingUploader.matchSpeakers(chunks: chunks, profiles: profiles,
                                                   owner: owner, typedNames: record.speakerNames)

        // A clip only for the people we could not name: a matched colleague
        // needs no question asked, and the owner is never in doubt.
        for index in voices.speakers.indices {
            let speaker = voices.speakers[index]
            guard speaker.speakerId != TranscriptBuilder.ownerSpeakerId, !speaker.matched else { continue }
            voices.speakers[index].sampleFile = SampleClipExporter.exportClip(
                meetingID: meetingID, speakerId: speaker.speakerId, chunks: chunks)
        }

        if record.trackASeconds > 0 {
            try AudioEncoder.encodeM4A(wav: MeetingStore.trackAURL(meetingID), to: MeetingStore.trackAM4AURL(meetingID))
        }
        if record.trackBSeconds > 0 {
            try AudioEncoder.encodeM4A(wav: MeetingStore.trackBURL(meetingID), to: MeetingStore.trackBM4AURL(meetingID))
        }

        let manifest = MeetingUploader.buildManifest(record: record, transcript: transcript, voices: voices)
        let voicesEncoder = JSONEncoder()
        voicesEncoder.outputFormatting = [.sortedKeys]
        try voicesEncoder.encode(voices).write(to: MeetingStore.voicesURL(meetingID), options: .atomic)
        try FlowClient.encodeManifest(manifest).write(to: MeetingStore.manifestURL(meetingID), options: .atomic)
        MeetingUploader.writeState(UploadState(phase: .pending, files: []), meetingID: meetingID)

        let matched = voices.speakers.filter(\.matched).count
        FileHandle.standardError.write(Data("[meeting] prepared \(meetingID): \(voices.speakers.count) speakers, \(matched) matched, \(voices.speakers.compactMap(\.sampleFile).count) sample clips\n".utf8))
        return manifest
    }

    // MARK: - Ship (network)

    /// Sends whatever `prepare` left on disk and is not up yet, posts the
    /// manifest, then waits for the summary. Safe to call again: `complete`
    /// is idempotent on the server and finished files are skipped.
    @discardableResult
    func ship(meetingID: String) async throws -> FlowRecordingStatus {
        guard flow.isConnected else { throw FlowError.notConnected }
        let record = try MeetingStore.load(id: meetingID)
        let manifestData = try Data(contentsOf: MeetingStore.manifestURL(meetingID))
        let voices = (try? JSONDecoder().decode(MeetingVoices.self, from: Data(contentsOf: MeetingStore.voicesURL(meetingID))))
            ?? MeetingVoices(speakers: [])

        var state = MeetingUploader.readState(meetingID: meetingID) ?? UploadState()
        let planned = MeetingUploader.plannedFiles(record: record, voices: voices)
        let remaining = MeetingUploader.remainingFiles(planned: planned, state: state)

        do {
            for name in remaining {
                // Position in the whole plan, not in what is left, so a
                // resumed upload says "Uploading 4 of 5" rather than "1 of 5".
                let index = (planned.firstIndex(of: name) ?? 0) + 1
                onProgress?(.uploading(index: index, total: planned.count))
                let url = MeetingStore.directory(for: meetingID).appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    FileHandle.standardError.write(Data("[flow] \(name) is not on disk, skipping it\n".utf8))
                    state.files.append(name)
                    MeetingUploader.writeState(state, meetingID: meetingID)
                    continue
                }
                _ = try await flow.putFile(recordingID: meetingID, name: name, url: url)
                state.files.append(name)
                MeetingUploader.writeState(state, meetingID: meetingID)
            }

            onProgress?(.summarising)
            let manifest = try MeetingUploader.decodeManifest(manifestData)
            let completed = try await flow.complete(recordingID: meetingID, manifest: manifest)
            state.phase = .complete
            state.error = nil
            MeetingUploader.writeState(state, meetingID: meetingID)
            FileHandle.standardError.write(Data("[flow] uploaded \(meetingID): \(planned.count) files, status \(completed.status)\n".utf8))

            var status = FlowRecordingStatus(status: completed.status,
                                             speakerNames: completed.speakerNames,
                                             summary: completed.summary)
            if status.summary == nil {
                status = try await waitForSummary(meetingID: meetingID, fallback: status)
            }
            try applyServerResult(meetingID: meetingID, status: status)
            onProgress?(.done)
            return status
        } catch {
            state.phase = .failed
            state.error = error.localizedDescription
            MeetingUploader.writeState(state, meetingID: meetingID)
            onProgress?(.failedWillRetry)
            FileHandle.standardError.write(Data("[flow] upload of \(meetingID) failed: \(error.localizedDescription)\n".utf8))
            throw error
        }
    }

    static func decodeManifest(_ data: Data) throws -> MeetingManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeetingManifest.self, from: data)
    }

    /// Flow summarises after `complete` returns, so the app asks again every
    /// five seconds for three minutes. A timeout is not a failure: the
    /// recording is in Flow and the summary appears there when it lands.
    private func waitForSummary(meetingID: String, fallback: FlowRecordingStatus) async throws -> FlowRecordingStatus {
        let deadline = Date().addingTimeInterval(MeetingUploader.summaryTimeout)
        var latest = fallback
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(MeetingUploader.summaryPollInterval * 1_000_000_000))
            if Task.isCancelled { return latest }
            do {
                latest = try await flow.recording(id: meetingID)
                if latest.summary != nil || latest.status == "failed" { return latest }
            } catch {
                FileHandle.standardError.write(Data("[flow] still waiting on the summary: \(error.localizedDescription)\n".utf8))
            }
        }
        FileHandle.standardError.write(Data("[flow] no summary after \(Int(MeetingUploader.summaryTimeout))s; it will appear in Flow when it lands\n".utf8))
        return latest
    }

    /// Writes the server's answer back into the meeting folder: the names it
    /// settled on, and `summary.md` from the summary it wrote.
    private func applyServerResult(meetingID: String, status: FlowRecordingStatus) throws {
        if let summary = status.summary {
            try MeetingSummariser.markdown(summary).write(to: MeetingStore.summaryURL(meetingID),
                                                          atomically: true, encoding: .utf8)
        }
        guard !status.speakerNames.isEmpty else { return }
        var record = try MeetingStore.load(id: meetingID)
        // The server speaks in wire ids ("A"); the folder speaks in the app's
        // own ("owner"). Translate on the way back in.
        for (wireId, name) in status.speakerNames {
            let localId = wireId == MeetingUploader.ownerWireId ? TranscriptBuilder.ownerSpeakerId : wireId
            record.speakerNames[localId] = name
        }
        if status.summary != nil { record.status = .summarised }
        try MeetingStore.save(record)

        if let data = try? Data(contentsOf: MeetingStore.transcriptJSONURL(meetingID)),
           var transcript = try? JSONDecoder().decode(Transcript.self, from: data) {
            transcript.speakerNames = record.speakerNames
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(transcript).write(to: MeetingStore.transcriptJSONURL(meetingID), options: .atomic)
            try? TranscriptBuilder.markdown(transcript, title: record.title, startedAt: record.startedAt)
                .write(to: MeetingStore.transcriptMarkdownURL(meetingID), atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Resume

    /// Meeting ids that started an upload and did not finish it.
    static func pendingMeetingIDs() -> [String] {
        MeetingStore.listIDs().filter { shouldResume(readState(meetingID: $0)) }
    }

    /// Called at launch and at every connect. Quiet by design: a Mac that has
    /// been offline all weekend should catch up without a stack of alerts.
    func resumePending() async {
        guard flow.isConnected else { return }
        let ids = MeetingUploader.pendingMeetingIDs()
        guard !ids.isEmpty else { return }
        FileHandle.standardError.write(Data("[flow] resuming \(ids.count) unfinished upload(s)\n".utf8))
        for id in ids {
            guard FileManager.default.fileExists(atPath: MeetingStore.manifestURL(id).path) else {
                FileHandle.standardError.write(Data("[flow] \(id) has no manifest to resume from, leaving it\n".utf8))
                continue
            }
            _ = try? await ship(meetingID: id)
        }
    }
}
