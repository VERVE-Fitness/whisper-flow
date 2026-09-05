import Foundation

/// One phrase the team says often, with the renderings the speech model is
/// known to produce for it. Team phrases apply to everyone; a person's own
/// phrases only reach their Mac. Both arrive through
/// `GET /api/public/whisper/me` and are cached on disk, so a Mac with no
/// connection still corrects what it corrected yesterday.
struct FlowPhrase: Codable, Equatable, Sendable {
    /// The right rendering, with the casing it should be typed in
    /// ("VERVE Pulse", "Tori").
    let phrase: String
    /// The wrong renderings to replace, lower case by convention but matched
    /// case-insensitively either way.
    let heardAs: [String]

    enum CodingKeys: String, CodingKey {
        case phrase
        case heardAs = "heard_as"
    }

    init(phrase: String, heardAs: [String] = []) {
        self.phrase = phrase
        self.heardAs = heardAs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phrase = try c.decode(String.self, forKey: .phrase)
        heardAs = try c.decodeIfPresent([String].self, forKey: .heardAs) ?? []
    }
}

/// The phrase list on disk, at
/// ~/Library/Application Support/WhisperFlow/phrases.json.
///
/// Written whenever `me()` answers (connect, every Stop, and the
/// `whisperflow://refresh` link the settings page opens after an edit), read
/// on every dictation. Kept in memory behind a lock so the cleanup path never
/// touches the disk mid-dictation, and re-read from disk when the file
/// changes underneath us.
final class PhraseStore: @unchecked Sendable {
    static let shared = PhraseStore()

    /// Tests point this at a temp file.
    nonisolated(unsafe) static var urlOverride: URL?

    static var url: URL {
        urlOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperFlow", isDirectory: true)
            .appendingPathComponent("phrases.json")
    }

    private let lock = NSLock()
    private var cached: [FlowPhrase]?

    init() {}

    /// The list as it stands. Loads from disk once per process, then serves
    /// memory until something replaces or reloads it.
    var phrases: [FlowPhrase] {
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

    /// Server said these are the phrases: keep them in memory and on disk.
    func replace(_ phrases: [FlowPhrase]) {
        lock.lock()
        cached = phrases
        lock.unlock()
        Self.save(phrases)
    }

    /// Drop the memory copy so the next read comes off disk.
    func reload() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    // MARK: - Disk

    static func load() -> [FlowPhrase] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([FlowPhrase].self, from: data)) ?? []
    }

    static func save(_ phrases: [FlowPhrase]) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(phrases)
            // Atomic, like the lexicon: a crash mid-write must never leave a
            // half-written list that decodes to nothing.
            try data.write(to: url, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("[phrase] could not cache the phrase list: \(error.localizedDescription)\n".utf8))
        }
    }
}
