import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Cleanup via Apple's on-device Foundation Models (Apple Intelligence).
/// On Macs where Apple Intelligence is disabled this reports unavailable,
/// which is expected — the router then falls through to Ollama/Passthrough.
struct FoundationModelsCleanup: CleanupBackend {
    let name = "foundation-models"

    func isAvailable() async -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    func clean(_ raw: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard SystemLanguageModel.default.availability == .available else {
                throw CleanupError.unavailable(name)
            }
            let session = LanguageModelSession(instructions: cleanupSystemPrompt)
            let response = try await session.respond(to: raw)
            let cleaned = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { throw CleanupError.emptyOutput }
            return cleaned
        }
        #endif
        throw CleanupError.unavailable(name)
    }
}
