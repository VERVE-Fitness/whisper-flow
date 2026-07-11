import Foundation

/// LLM cleanup via a local Ollama server (fully local, no cloud). Talks to
/// the app-owned instance EmbeddedOllama spawns/kills as part of
/// WhisperFlow's own lifecycle -- not a separately-registered background
/// service -- on EmbeddedOllama's dedicated port.
struct OllamaCleanup: CleanupBackend {
    let name = "ollama"
    let model = "llama3.2:3b"
    private let baseURL = EmbeddedOllama.baseURL
    private let requestTimeout: TimeInterval = 10

    func isAvailable() async -> Bool {
        // Server up AND the model present.
        var req = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        req.timeoutInterval = 3
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return false }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = obj["models"] as? [[String: Any]] else { return false }
            let names = models.compactMap { $0["name"] as? String }
            return names.contains { $0 == model || $0.hasPrefix(model) || $0.hasPrefix("llama3.2") }
        } catch {
            return false
        }
    }

    func clean(_ raw: String, dictionary: [String] = [], context: String? = nil) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = requestTimeout

        let systemPrompt = cleanupSystemPrompt + dictionaryPromptAddendum(dictionary)
        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for shot in cleanupFewShot {
            messages.append(["role": "user", "content": shot.user])
            messages.append(["role": "assistant", "content": shot.assistant])
        }
        messages.append(["role": "user", "content": wrapTranscript(raw, context: context)])

        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "keep_alive": "30m",
            "options": ["temperature": 0],
            "messages": messages
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch let e as URLError where e.code == .timedOut {
            throw CleanupError.timedOut
        }
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw CleanupError.badResponse("HTTP \(code): \(String(data: data, encoding: .utf8) ?? "")")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = obj["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw CleanupError.badResponse("unexpected JSON shape")
        }
        let cleaned = content
            .replacingOccurrences(of: "<transcript>", with: "")
            .replacingOccurrences(of: "</transcript>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw CleanupError.emptyOutput }
        return cleaned
    }
}
