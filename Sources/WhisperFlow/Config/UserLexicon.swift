import Foundation

/// Persistent, user-editable dictation vocabulary: proper nouns/terms the
/// speaker uses often (injected into the cleanup prompt so near-misses get
/// corrected to the exact spelling), deterministic word-level corrections
/// (misheard -> corrected, applied after cleanup regardless of backend), and
/// voice snippets (a spoken cue that expands to fixed text, skipping cleanup
/// entirely). Stored at
/// ~/Library/Application Support/WhisperFlow/lexicon.json.
///
/// Loaded once at launch and cached in memory; `reload()` re-reads from disk
/// (e.g. after an external edit), and every mutating API writes back
/// atomically so a crash mid-write can never corrupt the file.
final class UserLexicon: @unchecked Sendable {
    static let shared = UserLexicon()

    struct Storage: Codable {
        var dictionary: [String]
        var corrections: [String: String]
        var snippets: [String: String]

        static let empty = Storage(dictionary: [], corrections: [:], snippets: [:])
    }

    private let lock = NSLock()
    private var storage: Storage = .empty

    private init() {
        reload()
    }

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperFlow", isDirectory: true)
            .appendingPathComponent("lexicon.json")
    }

    // MARK: - Load / save

    func reload() {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode(Storage.self, from: data) else {
            storage = .empty
            return
        }
        storage = decoded
    }

    /// Atomic write: encode to a temp file in the same directory, then
    /// replace — so a crash or concurrent read never sees a half-written file.
    private func save() {
        do {
            let dir = Self.fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(storage)
            let tmp = dir.appendingPathComponent(".lexicon.json.tmp-\(UUID().uuidString)")
            try data.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(Self.fileURL, withItemAt: tmp)
        } catch {
            FileHandle.standardError.write(Data("[lexicon] save failed: \(error)\n".utf8))
        }
    }

    // MARK: - Reads
    //
    // Reads merge BuiltinLexicon (compiled-in VERVE vocabulary) UNDER the
    // user's own entries: user entries win on collisions, and removing a
    // user entry can never remove a built-in. Only the user's entries are
    // ever persisted to lexicon.json.

    var dictionary: [String] {
        lock.lock(); defer { lock.unlock() }
        var merged = BuiltinLexicon.dictionary
        for word in storage.dictionary where !merged.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
            merged.append(word)
        }
        return merged
    }

    var corrections: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return BuiltinLexicon.corrections.merging(storage.corrections) { _, user in user }
    }

    var snippets: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return storage.snippets
    }

    // MARK: - Dictionary

    func addDictionaryWord(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        if !storage.dictionary.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            storage.dictionary.append(trimmed)
        }
        lock.unlock()
        save()
    }

    func removeDictionaryWord(_ word: String) {
        lock.lock()
        storage.dictionary.removeAll { $0 == word }
        lock.unlock()
        save()
    }

    // MARK: - Corrections

    func setCorrection(misheard: String, corrected: String) {
        let key = misheard.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !value.isEmpty else { return }
        lock.lock()
        storage.corrections[key.lowercased()] = value
        // Cap at 200 entries (used by the auto-learner too); drop nothing
        // deterministic here since manual entries should never be evicted by
        // insertion order alone — only the auto-learner enforces the cap.
        lock.unlock()
        save()
    }

    func removeCorrection(misheard: String) {
        lock.lock()
        storage.corrections.removeValue(forKey: misheard.lowercased())
        lock.unlock()
        save()
    }

    // MARK: - Snippets

    func setSnippet(cue: String, text: String) {
        let key = cue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        lock.lock()
        storage.snippets[key.lowercased()] = text
        lock.unlock()
        save()
    }

    func removeSnippet(cue: String) {
        lock.lock()
        storage.snippets.removeValue(forKey: cue.lowercased())
        lock.unlock()
        save()
    }

    /// Enforces the 200-entry cap used by CorrectionLearner, dropping the
    /// oldest entries (insertion order, per Swift dictionary's stable
    /// iteration within a process — approximate but adequate for a soft cap).
    func capCorrections(at max: Int) {
        lock.lock()
        if storage.corrections.count > max {
            let overflow = storage.corrections.count - max
            let keysToDrop = storage.corrections.keys.prefix(overflow)
            for k in keysToDrop { storage.corrections.removeValue(forKey: k) }
        }
        lock.unlock()
        save()
    }
}
