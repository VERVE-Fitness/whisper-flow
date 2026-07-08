import SwiftUI

struct MainView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            // Status line
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(state.phase.label)
                    .font(.headline)
                Spacer()
                Text("cleanup: \(state.cleanupBackendName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Record / Stop
            Button(action: { state.toggleRecording() }) {
                Label(state.isRecording ? "Stop" : "Record",
                      systemImage: state.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.title2)
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.space, modifiers: [])
            .controlSize(.large)
            .disabled(!(state.canRecord || state.isRecording))

            // Raw transcript (live partials)
            Text("Raw transcript")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(state.rawTranscript.isEmpty ? " " : state.rawTranscript)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(minHeight: 80, maxHeight: 140)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.1)))

            // Cleaned output
            HStack {
                Text("Cleaned")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { state.copyCleaned() }
                    .disabled(state.cleanedTranscript.isEmpty && state.rawTranscript.isEmpty)
            }
            ScrollView {
                Text(state.cleanedTranscript.isEmpty ? " " : state.cleanedTranscript)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(minHeight: 80, maxHeight: 140)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))

            // Latency readout
            if let stt = state.lastSttMs, let cleanup = state.lastCleanupMs {
                Text("stt finalize: \(stt) ms · cleanup: \(cleanup) ms")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Divider()
            DictionaryEditor()

            Divider()
            SnippetsEditor()
        }
        .padding(16)
        }
        .frame(minWidth: 480, minHeight: 460)
        .onAppear { state.onLaunch() }
    }

    private var statusColor: Color {
        switch state.phase {
        case .loadingModels: return .yellow
        case .idle, .done: return .green
        case .recording: return .red
        case .cleaning: return .orange
        case .error: return .gray
        }
    }
}

/// "Dictionary…" section: proper nouns/terms injected into the cleanup
/// prompt so near-misses get spell-corrected. Simple add/delete list --
/// deliberately no bulk import/export, this is meant to grow a handful of
/// entries at a time as the speaker notices mishearings.
private struct DictionaryEditor: View {
    @State private var words: [String] = UserLexicon.shared.dictionary.sorted()
    @State private var newWord: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dictionary").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Add a name or term…", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add).disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if words.isEmpty {
                Text("No words yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(words, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button(role: .destructive) { remove(word) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private func add() {
        let trimmed = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UserLexicon.shared.addDictionaryWord(trimmed)
        words = UserLexicon.shared.dictionary.sorted()
        newWord = ""
    }

    private func remove(_ word: String) {
        UserLexicon.shared.removeDictionaryWord(word)
        words = UserLexicon.shared.dictionary.sorted()
    }
}

/// "Snippets…" section: a spoken cue that expands to fixed text verbatim,
/// skipping cleanup entirely (see AppState.matchSnippet).
private struct SnippetsEditor: View {
    @State private var snippets: [(cue: String, text: String)] =
        UserLexicon.shared.snippets.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    @State private var newCue: String = ""
    @State private var newText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Snippets").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Cue (e.g. \"my calendar link\")…", text: $newCue)
                    .textFieldStyle(.roundedBorder)
                TextField("Expands to…", text: $newText)
                    .textFieldStyle(.roundedBorder)
                Button("Add", action: add)
                    .disabled(newCue.trimmingCharacters(in: .whitespaces).isEmpty || newText.isEmpty)
            }
            if snippets.isEmpty {
                Text("No snippets yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(snippets, id: \.cue) { snippet in
                    HStack {
                        Text(snippet.cue).bold()
                        Text("→ \(snippet.text)")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button(role: .destructive) { remove(snippet.cue) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private func add() {
        let cue = newCue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cue.isEmpty, !newText.isEmpty else { return }
        UserLexicon.shared.setSnippet(cue: cue, text: newText)
        reload()
        newCue = ""
        newText = ""
    }

    private func remove(_ cue: String) {
        UserLexicon.shared.removeSnippet(cue: cue)
        reload()
    }

    private func reload() {
        snippets = UserLexicon.shared.snippets.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}
