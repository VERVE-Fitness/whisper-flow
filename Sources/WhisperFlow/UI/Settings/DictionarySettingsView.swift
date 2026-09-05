import SwiftUI

/// Dictionary and phrases: the words this Mac should spell your way, the phrases the whole
/// team says that the recogniser keeps getting wrong, and the corrections your Mac learned
/// that nobody has decided on yet.
///
/// The dictionary is local to this Mac. The two lists under it are Flow's and are shared.
struct DictionarySettingsView: View {
    @ObservedObject var model: SettingsModel

    @State private var newWord: String = ""
    @State private var newPhrase: String = ""
    @State private var newHeardAs: String = ""
    @State private var newPhraseScope: String = "team"
    @State private var words: [String] = UserLexicon.shared.dictionary.sorted()
    @State private var editing: String?
    @State private var editPhrase: String = ""
    @State private var editHeardAs: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            dictionary
            phrases
            heardWrong
        }
        .onAppear { words = UserLexicon.shared.dictionary.sorted() }
    }

    // MARK: Personal dictionary

    @ViewBuilder
    private var dictionary: some View {
        SettingsBlock(title: "My dictionary",
                      caption: "Names and terms you use, so a near miss gets spelled your way. This list stays on this Mac and is only used to tidy up dictation.") {
            HStack {
                TextField("Add a name or a term…", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .onSubmit(addWord)
                Button("Add", action: addWord)
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if words.isEmpty {
                SettingsEmptyLine(text: "No words yet.")
            } else {
                ForEach(words, id: \.self) { word in
                    HStack {
                        Text(word)
                        if isBuiltin(word) {
                            Text("built in").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        // A built-in is compiled into the app, so a trash click on one would
                        // do nothing visible: it is not offered.
                        if !isBuiltin(word) {
                            Button(role: .destructive) { removeWord(word) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
    }

    private func addWord() {
        let trimmed = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UserLexicon.shared.addDictionaryWord(trimmed)
        words = UserLexicon.shared.dictionary.sorted()
        newWord = ""
    }

    private func removeWord(_ word: String) {
        UserLexicon.shared.removeDictionaryWord(word)
        words = UserLexicon.shared.dictionary.sorted()
    }

    private func isBuiltin(_ word: String) -> Bool {
        BuiltinLexicon.dictionary.contains { $0.caseInsensitiveCompare(word) == .orderedSame }
    }

    // MARK: Phrases we say

    @ViewBuilder
    private var phrases: some View {
        SettingsBlock(title: "Phrases we say",
                      caption: "Words the whole team uses that come out wrong. Add the right spelling, and what it usually comes out as, separated by commas. Team phrases reach everyone's Mac; your own reach only yours.") {
            HStack(spacing: 8) {
                TextField("The phrase, spelled right", text: $newPhrase)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                TextField("It comes out as… (comma separated)", text: $newHeardAs)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Menu(newPhraseScope == "team" ? "Everyone" : "Just me") {
                    Button("Everyone") { newPhraseScope = "team" }
                    Button("Just me") { newPhraseScope = "person" }
                }
                .frame(maxWidth: 130)
                Button("Add", action: addPhrase)
                    .disabled(model.isWorking || !model.isConnected
                              || newPhrase.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let settings = model.settings {
                if settings.phrases.isEmpty {
                    SettingsEmptyLine(text: "No phrases yet.")
                } else {
                    phraseHeader
                    ForEach(settings.phrases) { phrase in
                        if editing == phrase.id {
                            editRow(phrase)
                        } else {
                            phraseRow(phrase)
                        }
                    }
                }
            } else if model.isConnected {
                SettingsEmptyLine(text: model.isLoading ? "Reading from Flow…" : "Nothing from Flow yet.")
            }
        }
    }

    private var phraseHeader: some View {
        HStack {
            Text("Phrase").frame(width: 200, alignment: .leading)
            Text("Heard as").frame(maxWidth: .infinity, alignment: .leading)
            Text("Who").frame(width: 90, alignment: .leading)
            Text("").frame(width: 80)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func phraseRow(_ phrase: FlowSettingsPhrase) -> some View {
        HStack {
            Text(phrase.phrase).frame(width: 200, alignment: .leading)
            Text(phrase.heardAs.isEmpty ? "—" : phrase.heardAs.joined(separator: ", "))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(phrase.scope == "team" ? "Everyone" : "Just me")
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            HStack(spacing: 4) {
                if phrase.editable {
                    Button {
                        editing = phrase.id
                        editPhrase = phrase.phrase
                        editHeardAs = phrase.heardAs.joined(separator: ", ")
                    } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    Button(role: .destructive) {
                        model.act(["action": "phrase_remove", "id": phrase.id])
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .disabled(model.isWorking)
                }
            }
            .frame(width: 80, alignment: .trailing)
        }
        .font(.callout)
    }

    @ViewBuilder
    private func editRow(_ phrase: FlowSettingsPhrase) -> some View {
        HStack(spacing: 8) {
            TextField("Phrase", text: $editPhrase)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            TextField("Heard as", text: $editHeardAs)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
            Button("Save") {
                model.act(["action": "phrase_edit", "id": phrase.id,
                           "phrase": editPhrase.trimmingCharacters(in: .whitespacesAndNewlines),
                           "heard_as": Self.heardAsList(editHeardAs)])
                editing = nil
            }
            .disabled(model.isWorking || editPhrase.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel") { editing = nil }
                .buttonStyle(.link)
        }
        .font(.callout)
    }

    private func addPhrase() {
        model.act(["action": "phrase_add",
                   "phrase": newPhrase.trimmingCharacters(in: .whitespacesAndNewlines),
                   "heard_as": Self.heardAsList(newHeardAs),
                   "scope": newPhraseScope])
        newPhrase = ""
        newHeardAs = ""
    }

    /// "tory, torrie" becomes ["tory", "torrie"]. Blanks and repeats drop out here so the
    /// server never has to guess what an empty entry meant.
    static func heardAsList(_ raw: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for part in raw.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }

    // MARK: Heard wrong

    @ViewBuilder
    private var heardWrong: some View {
        SettingsBlock(title: "Heard wrong",
                      caption: "Fixes people made straight after dictating. Nothing here changes anything until you decide.") {
            if let settings = model.settings {
                if settings.suggestions.isEmpty {
                    SettingsEmptyLine(text: "Nothing waiting.")
                } else {
                    ForEach(settings.suggestions) { suggestion in
                        HStack(spacing: 10) {
                            Text("heard “\(suggestion.heard)”, you typed “\(suggestion.typed)”")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if suggestion.count > 1 {
                                Text("×\(suggestion.count)").foregroundStyle(.secondary)
                            }
                            Button("Add for everyone") { resolve(suggestion, "team") }
                                .disabled(model.isWorking)
                            Button("Just for me") { resolve(suggestion, "person") }
                                .disabled(model.isWorking)
                            Button("Ignore") { resolve(suggestion, "ignore") }
                                .buttonStyle(.link)
                                .disabled(model.isWorking)
                        }
                        .font(.callout)
                    }
                }
            } else if model.isConnected {
                SettingsEmptyLine(text: model.isLoading ? "Reading from Flow…" : "Nothing from Flow yet.")
            }
        }
    }

    private func resolve(_ suggestion: FlowPhraseSuggestion, _ decision: String) {
        model.act(["action": "suggestion_resolve", "id": suggestion.id, "decision": decision])
    }
}
