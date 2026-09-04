import Foundation

struct MeetingAction: Codable, Equatable {
    var text: String
    var owner: String?
    var due: String?
}

struct MeetingSummary: Codable, Equatable {
    var summary: String
    var decisions: [String]
    var actions: [MeetingAction]
    var catchUp: String

    enum CodingKeys: String, CodingKey {
        case summary, decisions, actions
        case catchUp = "catch_up"
    }
}

enum SummariserError: Error, LocalizedError {
    case badResponse(String)
    case noJSON
    var errorDescription: String? {
        switch self {
        case .badResponse(let why): return "Summariser: \(why)"
        case .noJSON: return "Summariser returned no JSON"
        }
    }
}

/// Week-1 summariser: calls the Anthropic Messages API from the Mac with a
/// key the owner placed on the machine. Week 2 moves this into an Engine
/// function and the key leaves the Mac. Text only is sent, never audio.
enum MeetingSummariser {
    static let model = "claude-sonnet-5"

    static var apiKey: String? {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty { return env }
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperFlow/anthropic.key")
        return (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func prompt(for transcript: Transcript, title: String) -> String {
        let lines = transcript.segments.map { s in
            "[\(TranscriptBuilder.stamp(s.start))] \(transcript.speakerNames[s.speakerId] ?? s.speakerId): \(s.text)"
        }.joined(separator: "\n")
        return """
        You are writing meeting notes for VERVE Fitness, an Australian gym equipment company. Australian English, plain words, no corporate jargon, no em dashes.

        Meeting title: \(title.isEmpty ? "(untitled)" : title)

        Transcript:
        \(lines)

        Return only JSON with this shape and nothing else:
        {"summary": "3 to 6 sentences on what was discussed and where it landed",
         "decisions": ["each decision actually made, one line each; empty list if none"],
         "actions": [{"text": "what has to happen", "owner": "the person's name as spoken, or null", "due": "YYYY-MM-DD if a date was said, else null"}],
         "catch_up": "two sentences for someone who missed it"}
        Do not invent decisions or actions that were not said. If a name is unclear, use the speaker label as given.
        """
    }

    static func parse(_ modelText: String) throws -> MeetingSummary {
        guard let start = modelText.firstIndex(of: "{"), let end = modelText.lastIndex(of: "}") else {
            throw SummariserError.noJSON
        }
        let json = String(modelText[start...end])
        return try JSONDecoder().decode(MeetingSummary.self, from: Data(json.utf8))
    }

    static func markdown(_ s: MeetingSummary) -> String {
        var out = ["## Summary", "", s.summary, "", "## Decisions", ""]
        out += s.decisions.isEmpty ? ["- None recorded"] : s.decisions.map { "- \($0)" }
        out += ["", "## Actions", ""]
        out += s.actions.isEmpty ? ["- None recorded"] : s.actions.map { a in
            var line = "- \(a.text)"
            if let o = a.owner, !o.isEmpty { line += " (\(o)" + (a.due.map { ", due \($0)" } ?? "") + ")" }
            else if let d = a.due { line += " (due \(d))" }
            return line
        }
        out += ["", "## Catch-up", "", s.catchUp, ""]
        return out.joined(separator: "\n")
    }

    /// Returns nil (and leaves status at .transcribed) when no key is present.
    static func summarise(meetingID: String) async throws -> MeetingSummary? {
        guard let key = apiKey else {
            FileHandle.standardError.write(Data("[meeting] no Anthropic key (env ANTHROPIC_API_KEY or Application Support/WhisperFlow/anthropic.key); skipping summary\n".utf8))
            return nil
        }
        var record = try MeetingStore.load(id: meetingID)
        let transcript = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: MeetingStore.transcriptJSONURL(meetingID)))

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4000,
            "messages": [["role": "user", "content": prompt(for: transcript, title: record.title)]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw SummariserError.badResponse("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1): \(String(data: data, encoding: .utf8) ?? "")")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw SummariserError.badResponse("unexpected JSON shape")
        }
        let summary = try parse(text)
        try markdown(summary).write(to: MeetingStore.summaryURL(meetingID), atomically: true, encoding: .utf8)
        record.status = .summarised
        try MeetingStore.save(record)
        return summary
    }
}
