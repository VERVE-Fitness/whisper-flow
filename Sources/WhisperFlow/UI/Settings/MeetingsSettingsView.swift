import SwiftUI
import AppKit

/// Meetings: whether this Mac is connected to Flow at all, what it does when a meeting is
/// about to start, whether colleagues' Macs may recognise your voice, whether a bot goes to
/// meetings you are not in, and the voices nobody has named yet.
///
/// The connection block is local. Everything under it is Flow's, and stays out of the way
/// until this Mac is connected.
struct MeetingsSettingsView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var model: SettingsModel
    @StateObject private var clips = ClipPlayer()

    @State private var botName: String = ""
    @State private var botNameLoadedFrom: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            connection
            if model.isConnected {
                prompts
                recogniseMe
                bot
                whoIsWho
            }
        }
        .onDisappear { clips.stop() }
    }

    // MARK: Connection

    @ViewBuilder
    private var connection: some View {
        SettingsBlock(title: "This Mac and Flow",
                      caption: "A meeting can only be recorded once this Mac has a token, because the consent wording promises the audio reaches VERVE's system and it only does once the token is here.") {
            Text(state.flowMenuLine)
                .font(.callout)
            if let status = state.flowStatus {
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if model.isConnected {
                    Button("Disconnect this Mac") { disconnect() }
                    Button("Open the page on Flow") { state.openFlowSettings() }
                        .buttonStyle(.link)
                } else {
                    Button("Connect this Mac…") { state.openFlowSettings() }
                }
            }
            Text(model.isConnected
                 ? "Disconnecting removes the token from this Mac's keychain. Nothing already in Flow is touched."
                 : "Connecting opens the Whisper page in your browser, where you sign in once and click Connect this Mac. It is the only time the browser is needed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func disconnect() {
        state.flow.disconnect()
        state.flowMe = nil
        state.flowStatus = "This Mac is no longer connected"
        model.load()
    }

    // MARK: Prompts

    @ViewBuilder
    private var prompts: some View {
        SettingsBlock(title: "Meeting prompts",
                      caption: "A minute before a meeting with other people on it, the Mac asks whether to record it. Meetings a bot is already going to never ask.") {
            Toggle("Ask me before a meeting starts", isOn: Binding(
                get: { state.meetingPromptsEnabled },
                set: { state.setMeetingPrompts($0) }
            ))
        }
    }

    // MARK: Recognise my voice

    @ViewBuilder
    private var recogniseMe: some View {
        SettingsBlock(title: "Recognise my voice",
                      caption: "With this on, a colleague's Mac can put your name on your voice in a meeting you were both in. With it off, nobody keeps a voiceprint of you and your name is only ever typed in by hand.") {
            if let settings = model.settings {
                Toggle("Let VERVE Macs recognise my voice", isOn: Binding(
                    get: { settings.recogniseMe },
                    set: { model.act(["action": "recognise_me", "value": $0]) }
                ))
                .disabled(model.isWorking)

                if let profile = settings.profile {
                    HStack(spacing: 12) {
                        Text("Your voiceprint is built from \(profile.sampleCount) sample\(profile.sampleCount == 1 ? "" : "s").")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Forget my voice") { model.act(["action": "forget_profile"]) }
                            .buttonStyle(.link)
                            .disabled(model.isWorking)
                    }
                } else {
                    Text("No voiceprint of you is stored.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                loadingLine
            }
        }
    }

    // MARK: Meeting bot

    @ViewBuilder
    private var bot: some View {
        SettingsBlock(title: "Meeting bot",
                      caption: "For meetings you are not in. VERVE Notes joins by the meeting link, sits in the participant list under its own name, records, and the meeting turns up in Flow like any other.") {
            if let settings = model.settings {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(FlowSettings.botModes, id: \.self) { mode in
                        Button {
                            model.act(["action": "bot_settings", "bot_mode": mode,
                                       "bot_name": botName.trimmingCharacters(in: .whitespacesAndNewlines)])
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: settings.botMode == mode ? "largecircle.fill.circle" : "circle")
                                Text(FlowSettings.botModeSentence(mode))
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isWorking)
                    }
                }

                HStack(spacing: 10) {
                    Text("What the room sees")
                        .font(.callout)
                    TextField("VERVE Notes", text: $botName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                        .onSubmit { saveBotName(settings) }
                    Button("Save") { saveBotName(settings) }
                        .disabled(model.isWorking)
                }
                .padding(.top, 4)

                Text(botsLine(settings))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                loadingLine
            }
        }
        .onChange(of: model.settings?.botName) { _ in syncBotName() }
        .onAppear { syncBotName() }
    }

    private func syncBotName() {
        guard let settings = model.settings else { return }
        // Only take the server's value the first time, or when it actually changes: it must
        // never overwrite a name somebody is halfway through typing.
        if botNameLoadedFrom != settings.botName {
            botNameLoadedFrom = settings.botName
            botName = settings.botName
        }
    }

    private func saveBotName(_ settings: FlowSettings) {
        model.act(["action": "bot_settings", "bot_mode": settings.botMode,
                   "bot_name": botName.trimmingCharacters(in: .whitespacesAndNewlines)])
    }

    private func botsLine(_ settings: FlowSettings) -> String {
        let bots = settings.botsThisMonth
        if bots.count == 0 { return "No bots sent this month." }
        let hours = bots.hours.map { ", about \(String(format: "%.1f", $0)) hours in rooms" } ?? ""
        return "\(bots.count) bot\(bots.count == 1 ? "" : "s") this month, \(bots.finished) finished\(hours)."
    }

    // MARK: Who is who

    @ViewBuilder
    private var whoIsWho: some View {
        SettingsBlock(title: "Who is who",
                      caption: "Voices from your own recent meetings that the Mac could not place. Listen, put a name to it, or say it was not a person at all.") {
            if let settings = model.settings {
                if settings.queue.isEmpty {
                    SettingsEmptyLine(text: "Nothing waiting. Every voice in your recent meetings has a name.")
                } else {
                    ForEach(settings.queue) { item in
                        SpeakerQueueRow(item: item, people: settings.people, model: model, clips: clips)
                        if item.id != settings.queue.last?.id { Divider() }
                    }
                }
            } else {
                loadingLine
            }
        }
    }

    @ViewBuilder
    private var loadingLine: some View {
        if model.isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading from Flow…").font(.callout).foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 10) {
                Text("Nothing from Flow yet.").font(.callout).foregroundStyle(.secondary)
                Button("Try again") { model.load() }.buttonStyle(.link)
            }
        }
    }
}

/// One unnamed voice: what meeting it was in, how long it spoke, a play button, and the
/// three ways to settle it.
private struct SpeakerQueueRow: View {
    let item: FlowSpeakerQueueItem
    let people: [FlowStaffPerson]
    @ObservedObject var model: SettingsModel
    @ObservedObject var clips: ClipPlayer

    @State private var chosen: FlowNameSuggestion?
    @State private var typedName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(item.title).font(.callout.bold())
                Text(SettingsFormat.day(item.startedAt))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("spoke for \(SettingsFormat.seconds(item.seconds))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if let clip = item.clipURL, let url = URL(string: clip) {
                    Button {
                        clips.play(id: item.id, url: url)
                    } label: {
                        Label(clips.playingID == item.id ? "Stop" : "Play",
                              systemImage: clips.playingID == item.id ? "stop.fill" : "play.fill")
                    }
                }
            }

            HStack(spacing: 10) {
                Menu(chosen.map { $0.name } ?? "Pick a name") {
                    ForEach(choices, id: \.self) { person in
                        Button(person.name) {
                            chosen = person
                            typedName = person.name
                        }
                    }
                }
                .frame(maxWidth: 260)

                TextField("Or type a name", text: $typedName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .onSubmit(confirm)

                Button("Confirm", action: confirm)
                    .disabled(model.isWorking || typedName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Not a person") {
                    model.act(["action": "not_a_person",
                               "recording_id": item.recordingID,
                               "speaker_id": item.speakerID])
                }
                .disabled(model.isWorking)
            }
        }
        .padding(.vertical, 4)
    }

    /// Whoever was on that meeting first, then the rest of the team, as Flow ordered them.
    private var choices: [FlowNameSuggestion] {
        var seen = Set<String>()
        var out: [FlowNameSuggestion] = []
        for person in item.suggestions where seen.insert(person.name.lowercased()).inserted {
            out.append(person)
        }
        for person in people where seen.insert(person.name.lowercased()).inserted {
            out.append(FlowNameSuggestion(email: person.email, name: person.name))
        }
        return out
    }

    private func confirm() {
        let name = typedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var body: [String: Any] = ["action": "confirm_speaker",
                                   "recording_id": item.recordingID,
                                   "speaker_id": item.speakerID,
                                   "name": name]
        // The email only goes with the name when it is the one Flow suggested for that name:
        // a voiceprint is only ever enrolled against a person the server already knows.
        if let chosen, chosen.name.caseInsensitiveCompare(name) == .orderedSame, !chosen.email.isEmpty {
            body["email"] = chosen.email
        }
        model.act(body)
    }
}
