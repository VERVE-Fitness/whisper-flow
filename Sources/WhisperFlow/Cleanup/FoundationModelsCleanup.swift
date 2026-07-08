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

    func clean(_ raw: String, dictionary: [String] = [], context: String? = nil) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard SystemLanguageModel.default.availability == .available else {
                throw CleanupError.unavailable(name)
            }
            let examples = cleanupFewShot
                .map { "Input: \($0.user)\nOutput: \($0.assistant)" }
                .joined(separator: "\n\n")
            let systemPrompt = cleanupSystemPrompt + dictionaryPromptAddendum(dictionary)
            let session = LanguageModelSession(instructions: systemPrompt + "\n\nExamples:\n" + examples)
            let response = try await session.respond(to: wrapTranscript(raw, context: context))
            let cleaned = response.content
                .replacingOccurrences(of: "<transcript>", with: "")
                .replacingOccurrences(of: "</transcript>", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { throw CleanupError.emptyOutput }
            return cleaned
        }
        #endif
        throw CleanupError.unavailable(name)
    }
}
