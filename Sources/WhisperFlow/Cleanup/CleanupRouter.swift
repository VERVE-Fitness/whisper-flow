import Foundation

struct CleanupResult: Sendable {
    let text: String
    let backendName: String
    /// True when guard rails discarded the LLM output and fell back to raw.
    let fellBackToRaw: Bool
    let durationMs: Int
}

/// Picks the best available cleanup backend:
/// FoundationModels (Apple Intelligence) -> Ollama -> Passthrough.
/// Applies guard rails: empty output, output > 1.6x raw length, error, or
/// >10s timeout all fall back to the raw transcript.
struct CleanupRouter: Sendable {
    private let foundation = FoundationModelsCleanup()
    private let ollama = OllamaCleanup()
    private let passthrough = PassthroughCleanup()
    private let timeoutSeconds: UInt64 = 10

    /// Resolve which backend would be used right now (for UI status display).
    func resolveBackend() async -> any CleanupBackend {
        if await foundation.isAvailable() { return foundation }
        if await ollama.isAvailable() { return ollama }
        return passthrough
    }

    func clean(_ raw: String) async -> CleanupResult {
        let start = Date()
        let backend = await resolveBackend()

        func elapsedMs() -> Int { Int(Date().timeIntervalSince(start) * 1000) }

        if backend is PassthroughCleanup {
            return CleanupResult(text: raw, backendName: passthrough.name, fellBackToRaw: false, durationMs: elapsedMs())
        }

        do {
            let cleaned = try await withTimeout(seconds: timeoutSeconds) {
                try await backend.clean(raw)
            }
            // Guard rails: empty or runaway output -> raw.
            let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                FileHandle.standardError.write(Data("[cleanup] \(backend.name) returned empty output; using raw\n".utf8))
                return CleanupResult(text: raw, backendName: backend.name, fellBackToRaw: true, durationMs: elapsedMs())
            }
            if Double(trimmed.count) > Double(raw.count) * 1.6 {
                FileHandle.standardError.write(Data("[cleanup] \(backend.name) output \(trimmed.count) chars > 1.6x raw \(raw.count); using raw\n".utf8))
                return CleanupResult(text: raw, backendName: backend.name, fellBackToRaw: true, durationMs: elapsedMs())
            }
            // Content-retention guard: small local models sometimes delete whole
            // clauses they judge to be noise, not just fillers. If the cleaned text
            // keeps fewer than 60% of the raw's non-filler words, treat it as a
            // content change and use the raw transcript instead.
            let retention = Self.contentWordRetention(raw: raw, cleaned: trimmed)
            if retention < 0.6 {
                FileHandle.standardError.write(Data("[cleanup] \(backend.name) kept only \(Int(retention * 100))% of content words; using raw\n".utf8))
                return CleanupResult(text: raw, backendName: backend.name, fellBackToRaw: true, durationMs: elapsedMs())
            }
            return CleanupResult(text: trimmed, backendName: backend.name, fellBackToRaw: false, durationMs: elapsedMs())
        } catch {
            FileHandle.standardError.write(Data("[cleanup] \(backend.name) failed (\(error.localizedDescription)); using raw\n".utf8))
            return CleanupResult(text: raw, backendName: backend.name, fellBackToRaw: true, durationMs: elapsedMs())
        }
    }

    /// Fraction of the raw transcript's non-filler word count still present in
    /// the cleaned text (by simple ratio of counts). Fillers are excluded from
    /// the raw count so legitimate filler removal doesn't depress the score.
    static func contentWordRetention(raw: String, cleaned: String) -> Double {
        let fillers: Set<String> = ["um", "uh", "uhm", "erm", "er", "ah", "hmm", "mmm", "like", "you", "know", "so"]
        func words(_ s: String) -> [String] {
            s.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }
        let rawContent = words(raw).filter { !fillers.contains($0) }
        guard !rawContent.isEmpty else { return 1.0 }
        let cleanedCount = words(cleaned).count
        return min(1.0, Double(cleanedCount) / Double(rawContent.count))
    }
}

/// Run an async operation with a hard timeout.
func withTimeout<T: Sendable>(seconds: UInt64, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            throw CleanupError.timedOut
        }
        guard let result = try await group.next() else { throw CleanupError.timedOut }
        group.cancelAll()
        return result
    }
}
