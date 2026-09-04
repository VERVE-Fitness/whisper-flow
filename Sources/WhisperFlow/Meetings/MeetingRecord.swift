import Foundation

struct MeetingConsent: Codable, Equatable {
    let confirmedAt: Date
    /// Which wording the person saw. Bump when ConsentGate.wording changes.
    let wordingVersion: String
}

enum MeetingStatus: String, Codable {
    case recording, recorded, transcribing, transcribed, summarised, failed
}

struct MeetingRecord: Codable, Equatable {
    var id: String
    var startedAt: Date
    var endedAt: Date?
    var title: String
    /// Display names typed by the owner (week 1). Calendar attendees replace
    /// this in week 3.
    var attendees: [String]
    var consent: MeetingConsent
    var status: MeetingStatus
    var failureReason: String?
    var trackASeconds: Double
    var trackBSeconds: Double
    /// Diariser speaker id ("speaker_0", …) -> display name after naming/rename.
    var speakerNames: [String: String]
}

/// One folder per meeting under Application Support. Everything week 1
/// produces lives in that folder and nowhere else.
enum MeetingStore {
    /// Tests point this at a temp dir.
    nonisolated(unsafe) static var rootOverride: URL?

    static var rootDirectory: URL {
        rootOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperFlow", isDirectory: true)
            .appendingPathComponent("meetings", isDirectory: true)
    }

    static func newMeetingID(at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_AU_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return "\(f.string(from: date))-\(suffix)"
    }

    static func directory(for id: String) -> URL { rootDirectory.appendingPathComponent(id, isDirectory: true) }
    static func trackAURL(_ id: String) -> URL { directory(for: id).appendingPathComponent("track-a.wav") }
    static func trackBURL(_ id: String) -> URL { directory(for: id).appendingPathComponent("track-b.wav") }
    static func transcriptJSONURL(_ id: String) -> URL { directory(for: id).appendingPathComponent("transcript.json") }
    static func transcriptMarkdownURL(_ id: String) -> URL { directory(for: id).appendingPathComponent("transcript.md") }
    static func summaryURL(_ id: String) -> URL { directory(for: id).appendingPathComponent("summary.md") }
    private static func recordURL(_ id: String) -> URL { directory(for: id).appendingPathComponent("meeting.json") }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func save(_ record: MeetingRecord) throws {
        try FileManager.default.createDirectory(at: directory(for: record.id), withIntermediateDirectories: true)
        try encoder.encode(record).write(to: recordURL(record.id), options: .atomic)
    }

    static func load(id: String) throws -> MeetingRecord {
        try decoder.decode(MeetingRecord.self, from: Data(contentsOf: recordURL(id)))
    }

    /// Meeting IDs sort lexically by date because of the yyyy-MM-dd-HHmm prefix.
    static func listIDs() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: rootDirectory.path)) ?? []
        return names.filter { FileManager.default.fileExists(atPath: recordURL($0).path) }.sorted(by: >)
    }
}
