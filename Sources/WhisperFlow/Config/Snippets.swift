import Foundation

/// One snippet as Flow holds it: a cue somebody says out loud and the text that gets typed
/// instead. A team snippet reaches every Mac; a person snippet only its owner's.
struct FlowSnippet: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let cue: String
    let text: String
    /// person | team
    let scope: String

    enum CodingKeys: String, CodingKey {
        case id, cue, text, scope
    }

    init(id: String = "", cue: String, text: String, scope: String = "person") {
        self.id = id
        self.cue = cue
        self.text = text
        self.scope = scope
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // An id comes off Postgres as a number and through some proxies as a string; the app
        // only ever sends it straight back, so both are kept as a string.
        if let s = try? c.decodeIfPresent(String.self, forKey: .id) {
            id = s
        } else if let i = try? c.decodeIfPresent(Int64.self, forKey: .id) {
            id = String(i)
        } else {
            id = ""
        }
        cue = try c.decodeIfPresent(String.self, forKey: .cue) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? "person"
    }
}

/// The rules for a snippet, in one place so the window, the merge and the tests agree.
enum SnippetRules {
    static let cueMaxLength = 60
    static let textMaxLength = 4000

    /// The key a cue is stored and matched under. Case and outside whitespace never matter.
    static func key(_ cue: String) -> String {
        cue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Nil when the pair is fine, otherwise the sentence to show the person.
    static func problem(cue: String, text: String) -> String? {
        let c = cue.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.isEmpty { return "Give the snippet something to say." }
        if c.count > cueMaxLength { return "A cue can be at most \(cueMaxLength) characters." }
        if t.isEmpty { return "Give the snippet some text to type." }
        if t.count > textMaxLength { return "The text can be at most \(textMaxLength) characters." }
        return nil
    }

    /// The map dictation actually matches against: team first, then this person's own rows
    /// from Flow, then whatever is on this Mac. Local wins a clash, so a snippet somebody
    /// edits here keeps working even while Flow says something else, and an offline Mac
    /// behaves exactly as it did before any of this existed.
    static func merged(remote: [FlowSnippet], local: [String: String]) -> [String: String] {
        var map: [String: String] = [:]
        for snippet in remote where snippet.scope == "team" {
            let k = key(snippet.cue)
            guard !k.isEmpty, !snippet.text.isEmpty else { continue }
            map[k] = snippet.text
        }
        for snippet in remote where snippet.scope != "team" {
            let k = key(snippet.cue)
            guard !k.isEmpty, !snippet.text.isEmpty else { continue }
            map[k] = snippet.text
        }
        for (cue, text) in local {
            let k = key(cue)
            guard !k.isEmpty, !text.isEmpty else { continue }
            map[k] = text
        }
        return map
    }
}

/// The team and person snippets from Flow, cached at
/// ~/Library/Application Support/WhisperFlow/snippets.json.
///
/// Written whenever `me()` answers (connect, launch, every Stop) and read on every
/// dictation, the same shape as PhraseStore next door.
final class SnippetStore: @unchecked Sendable {
    static let shared = SnippetStore()

    /// Tests point this at a temp file.
    nonisolated(unsafe) static var urlOverride: URL?

    static var url: URL {
        urlOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperFlow", isDirectory: true)
            .appendingPathComponent("snippets.json")
    }

    private let lock = NSLock()
    private var cached: [FlowSnippet]?

    init() {}

    var snippets: [FlowSnippet] {
        lock.lock()
        if let cached {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let loaded = Self.load()
        lock.lock()
        cached = loaded
        lock.unlock()
        return loaded
    }

    func replace(_ snippets: [FlowSnippet]) {
        lock.lock()
        cached = snippets
        lock.unlock()
        Self.save(snippets)
    }

    func reload() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    /// What dictation matches against right now.
    func runtimeMap(local: [String: String]) -> [String: String] {
        SnippetRules.merged(remote: snippets, local: local)
    }

    // MARK: - Disk

    static func load() -> [FlowSnippet] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([FlowSnippet].self, from: data)) ?? []
    }

    static func save(_ snippets: [FlowSnippet]) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(snippets).write(to: url, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("[snippet] could not cache the snippet list: \(error.localizedDescription)\n".utf8))
        }
    }
}
