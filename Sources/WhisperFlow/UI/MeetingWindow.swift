import SwiftUI

/// Week-1 review window for the last meeting: read the transcript and summary,
/// fix the speaker names, open the folder. Flow replaces this in week 2, so it
/// is deliberately plain -- everything it shows is already on disk in the
/// meeting folder.
struct MeetingWindow: View {
    @EnvironmentObject var state: AppState
    @State private var transcript: Transcript?
    @State private var record: MeetingRecord?
    @State private var summary: String = ""
    /// Names being typed. Kept apart from `transcript` so the files are
    /// rewritten when the field is committed, not on every keystroke.
    @State private var editedNames: [String: String] = [:]
    /// Where the upload got to, read from `upload-state.json`.
    @State private var uploadState: UploadState?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            speakers
            transcriptSection
            summarySection
            Spacer(minLength: 0)
            HStack {
                if let id = record?.id {
                    Button("Open in Flow") { state.openInFlow(id) }
                        .disabled(uploadState?.phase != .complete)
                }
                Button("Open folder") { if let id = record?.id { state.openMeetingFolder(id) } }
                Button("Reload") { load() }
                Spacer()
                if let status = state.meetingStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 520)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private var header: some View {
        if let record {
            Text(record.title.isEmpty ? record.id : record.title)
                .font(.headline)
            Text("\(record.status.rawValue) · your side \(Int(record.trackASeconds))s · their side \(Int(record.trackBSeconds))s · their side shifted +\(String(format: "%.1f", record.trackBOffsetSeconds))s")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(uploadLine)
                .font(.caption)
                .foregroundStyle(.secondary)
            // The single most common cause of a bad meeting transcript: with
            // the far side coming out of the laptop speakers, the microphone
            // hears it too, so both tracks carry the same words and the
            // speaker labels are guesswork.
            Text("Wear headphones while you record, so your voice and theirs stay on separate tracks. Out loud through the speakers, the microphone picks up their side as well and the names get mixed up.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("No meeting recorded yet")
                .font(.headline)
            Text("Menu bar → Record meeting… Everything is saved into one folder per meeting.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Plain English for the upload, so nobody has to open a JSON file to
    /// find out whether their meeting reached Flow.
    private var uploadLine: String {
        guard let uploadState else {
            return state.flow.isConnected ? "Not uploaded yet" : "Not uploaded: this Mac is not connected to Flow"
        }
        switch uploadState.phase {
        case .complete:
            return "In Flow. Speaker names below are the ones Flow settled on."
        case .pending:
            return "Uploading: \(uploadState.files.count) file(s) sent so far. It will finish on its own."
        case .failed:
            return "Upload failed, will retry: \(uploadState.error ?? "no reason recorded")"
        }
    }

    @ViewBuilder
    private var speakers: some View {
        if let t = transcript, !t.speakerNames.isEmpty {
            Text("Speakers (press Return to save a name)")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(t.speakerNames.keys.sorted(), id: \.self) { id in
                HStack {
                    Text(id)
                        .font(.caption.monospaced())
                        .frame(width: 110, alignment: .leading)
                    TextField("Name", text: Binding(
                        get: { editedNames[id] ?? "" },
                        set: { editedNames[id] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitName(id) }
                }
            }
        }
    }

    @ViewBuilder
    private var transcriptSection: some View {
        if let t = transcript {
            Text("Transcript")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(TranscriptBuilder.markdown(t, title: record?.title ?? "", startedAt: record?.startedAt ?? Date()))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 180, maxHeight: 320)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.1)))
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        if !summary.isEmpty {
            Text("Summary")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(summary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 120, maxHeight: 260)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
        }
    }

    private func commitName(_ speakerId: String) {
        guard let id = record?.id, var t = transcript else { return }
        let name = (editedNames[speakerId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != t.speakerNames[speakerId] else { return }
        state.applySpeakerName(meetingID: id, speakerId: speakerId, name: name)
        t = SpeakerNaming.renamed(t, speakerId: speakerId, to: name)
        transcript = t
    }

    private func load() {
        guard let id = state.lastMeetingID ?? MeetingStore.listIDs().first else { return }
        record = try? MeetingStore.load(id: id)
        transcript = (try? Data(contentsOf: MeetingStore.transcriptJSONURL(id)))
            .flatMap { try? JSONDecoder().decode(Transcript.self, from: $0) }
        editedNames = transcript?.speakerNames ?? [:]
        summary = (try? String(contentsOf: MeetingStore.summaryURL(id), encoding: .utf8)) ?? ""
        uploadState = MeetingUploader.readState(meetingID: id)
    }
}
