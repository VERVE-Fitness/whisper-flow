import SwiftUI

/// Snippets: say a short cue and a longer piece of text is typed for you, word for word.
/// "my LinkedIn", "the warranty line", "our bank details".
///
/// Two lists. Mine follows you to every Mac you connect and is kept on this one as well, so
/// it still works with no connection. Team snippets are everyone's and live only in Flow.
struct SnippetsSettingsView: View {
    @ObservedObject var model: SettingsModel

    @State private var newCue: String = ""
    @State private var newText: String = ""
    @State private var newScope: String = "person"
    @State private var problem: String?
    @State private var local: [String: String] = UserLexicon.shared.snippets
    @State private var editing: String?
    @State private var editCue: String = ""
    @State private var editText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            adder
            mine
            team
        }
        .onAppear { local = UserLexicon.shared.snippets }
    }

    // MARK: Add

    @ViewBuilder
    private var adder: some View {
        SettingsBlock(title: "Add a snippet",
                      caption: "Say the cue on its own, or with “insert” in front of it, and the text is typed exactly as written here.") {
            HStack(spacing: 8) {
                TextField("Cue, e.g. my LinkedIn", text: $newCue)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                TextField("What gets typed", text: $newText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                Menu(newScope == "team" ? "Everyone" : "Just me") {
                    Button("Just me") { newScope = "person" }
                    Button("Everyone") { newScope = "team" }
                        .disabled(!model.isConnected)
                }
                .frame(maxWidth: 130)
                Button("Add", action: add)
                    .disabled(model.isWorking)
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red)
            }
            if !model.isConnected {
                Text("With no connection a snippet is saved on this Mac only. It reaches your other Macs the next time this one is connected and you add it again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func add() {
        if let why = SnippetRules.problem(cue: newCue, text: newText) {
            problem = why
            return
        }
        problem = nil
        let cue = newCue.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        // A personal snippet is written to this Mac first, so it works this second and keeps
        // working with no connection; Flow gets a copy so a second Mac gets it too.
        if newScope == "person" {
            UserLexicon.shared.setSnippet(cue: cue, text: text)
            local = UserLexicon.shared.snippets
        }
        if model.isConnected {
            model.act(["action": "snippet_add", "cue": cue, "text": text, "scope": newScope])
        }
        newCue = ""
        newText = ""
    }

    // MARK: Mine

    @ViewBuilder
    private var mine: some View {
        SettingsBlock(title: "Mine") {
            let rows = mineRows
            if rows.isEmpty {
                SettingsEmptyLine(text: "No snippets of your own yet.")
            } else {
                ForEach(rows, id: \.cue) { row in
                    if editing == row.id {
                        editRow(id: row.id, remote: row.remote)
                    } else {
                        HStack(spacing: 10) {
                            Text(row.cue).bold().frame(width: 200, alignment: .leading)
                            Text(row.text)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                editing = row.id
                                editCue = row.cue
                                editText = row.text
                            } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless)
                            Button(role: .destructive) { removeMine(row) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.isWorking)
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    /// One row per cue: what Flow holds for this person, plus anything only on this Mac.
    /// Local text wins the display, because local text is what dictation will type.
    private var mineRows: [SnippetRow] {
        var byKey: [String: SnippetRow] = [:]
        var order: [String] = []
        for snippet in (model.settings?.snippets ?? []) where snippet.scope != "team" {
            let key = SnippetRules.key(snippet.cue)
            guard !key.isEmpty else { continue }
            if byKey[key] == nil { order.append(key) }
            byKey[key] = SnippetRow(cue: snippet.cue, text: snippet.text, remote: snippet)
        }
        for (cue, text) in local.sorted(by: { $0.key < $1.key }) {
            let key = SnippetRules.key(cue)
            guard !key.isEmpty else { continue }
            if let existing = byKey[key] {
                byKey[key] = SnippetRow(cue: existing.cue, text: text, remote: existing.remote)
            } else {
                order.append(key)
                byKey[key] = SnippetRow(cue: cue, text: text, remote: nil)
            }
        }
        return order.compactMap { byKey[$0] }
    }

    private func removeMine(_ row: SnippetRow) {
        UserLexicon.shared.removeSnippet(cue: row.cue)
        local = UserLexicon.shared.snippets
        if let remote = row.remote, !remote.id.isEmpty, model.isConnected {
            model.act(["action": "snippet_remove", "id": remote.id])
        }
    }

    @ViewBuilder
    private func editRow(id: String, remote: FlowSnippet?) -> some View {
        HStack(spacing: 8) {
            TextField("Cue", text: $editCue)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            TextField("What gets typed", text: $editText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
            Button("Save") { saveEdit(id: id, remote: remote) }
                .disabled(model.isWorking)
            Button("Cancel") { editing = nil }
                .buttonStyle(.link)
        }
        .font(.callout)
    }

    private func saveEdit(id: String, remote: FlowSnippet?) {
        if let why = SnippetRules.problem(cue: editCue, text: editText) {
            problem = why
            return
        }
        problem = nil
        let cue = editCue.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let remote, !remote.id.isEmpty, model.isConnected {
            model.act(["action": "snippet_edit", "id": remote.id, "cue": cue, "text": text])
        }
        if remote == nil || remote?.scope != "team" {
            // A renamed cue would otherwise leave the old one behind on this Mac.
            if SnippetRules.key(id) != SnippetRules.key(cue) {
                UserLexicon.shared.removeSnippet(cue: id)
            }
            UserLexicon.shared.setSnippet(cue: cue, text: text)
            local = UserLexicon.shared.snippets
        }
        editing = nil
    }

    // MARK: Team

    @ViewBuilder
    private var team: some View {
        SettingsBlock(title: "Team",
                      caption: "Everyone's. Anyone can add one; edit and remove with care, because every Mac says these.") {
            if let settings = model.settings {
                let rows = settings.snippets.filter { $0.scope == "team" }
                if rows.isEmpty {
                    SettingsEmptyLine(text: "No team snippets yet.")
                } else {
                    ForEach(rows) { snippet in
                        if editing == snippet.id {
                            editRow(id: snippet.id, remote: snippet)
                        } else {
                            HStack(spacing: 10) {
                                Text(snippet.cue).bold().frame(width: 200, alignment: .leading)
                                Text(snippet.text)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    editing = snippet.id
                                    editCue = snippet.cue
                                    editText = snippet.text
                                } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless)
                                Button(role: .destructive) {
                                    model.act(["action": "snippet_remove", "id": snippet.id])
                                } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .disabled(model.isWorking)
                            }
                            .font(.callout)
                        }
                    }
                }
            } else if model.isConnected {
                SettingsEmptyLine(text: model.isLoading ? "Reading from Flow…" : "Nothing from Flow yet.")
            }
        }
    }
}

/// One line in the Mine list: the cue as it is written, the text dictation will actually
/// type, and the Flow row behind it when there is one.
private struct SnippetRow {
    let cue: String
    let text: String
    let remote: FlowSnippet?

    /// The cue is the identity here, because a snippet only on this Mac has no id.
    var id: String { cue }
}
