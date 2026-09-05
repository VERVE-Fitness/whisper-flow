import Foundation
import Security

// MARK: - Keychain

/// Where the device token lives. It is a bearer credential for
/// /api/public/whisper/*, so it goes in the login keychain rather than
/// UserDefaults: a plist lifted out of a Time Machine backup must not carry
/// it. `kSecAttrAccessibleAfterFirstUnlock` so a meeting that finishes
/// uploading while the screen is locked still finds it.
enum FlowKeychain {
    static let service = "com.niallwogan.whisperflow"
    static let account = "flow-device-token"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }

    @discardableResult
    static func write(_ token: String) -> Bool {
        // Delete first: SecItemUpdate on a missing item fails, and an add on
        // an existing one returns errSecDuplicateItem. One path for both.
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            FileHandle.standardError.write(Data("[flow] could not store the device token in the keychain (OSStatus \(status))\n".utf8))
        }
        return status == errSecSuccess
    }

    @discardableResult
    static func delete() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

// MARK: - Errors

enum FlowError: Error, LocalizedError, Equatable {
    case notConnected
    case unauthorised
    case tooLarge(String, Int)
    case http(Int, String)
    case transport(String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "This Mac is not connected to Flow"
        case .unauthorised:
            return "Flow rejected the device token; connect this Mac again"
        case .tooLarge(let name, let bytes):
            return "\(name) is \(bytes / 1_048_576) MB, over the 300 MB limit"
        case .http(let code, let detail):
            return detail.isEmpty ? "Flow returned HTTP \(code)" : "Flow returned HTTP \(code): \(detail)"
        case .transport(let why):
            return "Could not reach Flow: \(why)"
        case .badResponse(let why):
            return "Flow sent something unexpected: \(why)"
        }
    }

    /// A 401 or an oversize file will fail again the same way; everything else
    /// is worth another go.
    var isRetryable: Bool {
        switch self {
        case .unauthorised, .tooLarge, .notConnected: return false
        case .badResponse: return false
        case .transport: return true
        case .http(let code, _): return code >= 500 || code == 408 || code == 429
        }
    }
}

// MARK: - Wire types

struct FlowVoiceProfile: Codable, Equatable {
    let email: String
    let name: String?
    let embedding: [Float]
}

struct FlowStaffMember: Codable, Equatable {
    let email: String
    let name: String?
}

struct FlowMe: Codable, Equatable {
    let email: String
    let name: String
    let recogniseMe: Bool
    let profiles: [FlowVoiceProfile]
    let staff: [FlowStaffMember]

    enum CodingKeys: String, CodingKey {
        case email, name, profiles, staff
        case recogniseMe = "recognise_me"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        email = try c.decode(String.self, forKey: .email)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        recogniseMe = try c.decodeIfPresent(Bool.self, forKey: .recogniseMe) ?? false
        profiles = try c.decodeIfPresent([FlowVoiceProfile].self, forKey: .profiles) ?? []
        staff = try c.decodeIfPresent([FlowStaffMember].self, forKey: .staff) ?? []
    }

    init(email: String, name: String, recogniseMe: Bool, profiles: [FlowVoiceProfile], staff: [FlowStaffMember]) {
        self.email = email
        self.name = name
        self.recogniseMe = recogniseMe
        self.profiles = profiles
        self.staff = staff
    }
}

/// A meeting bot that Flow has on the way, or already in the room. The
/// statuses are the server's: scheduled, joining, in_call, ingesting, done,
/// failed.
struct FlowActiveBot: Codable, Equatable {
    let id: String
    let title: String?
    let meetingURL: String?
    let startsAt: Date?
    let status: String
    let calendarEventId: String?

    enum CodingKeys: String, CodingKey {
        case id, title, status
        case meetingURL = "meeting_url"
        case startsAt = "starts_at"
        case calendarEventId = "calendar_event_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        meetingURL = try c.decodeIfPresent(String.self, forKey: .meetingURL)
        startsAt = try c.decodeIfPresent(Date.self, forKey: .startsAt)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        calendarEventId = try c.decodeIfPresent(String.self, forKey: .calendarEventId)
    }

    init(id: String, title: String? = nil, meetingURL: String? = nil, startsAt: Date? = nil,
         status: String, calendarEventId: String? = nil) {
        self.id = id
        self.title = title
        self.meetingURL = meetingURL
        self.startsAt = startsAt
        self.status = status
        self.calendarEventId = calendarEventId
    }
}

struct FlowActiveBots: Codable, Equatable {
    let bots: [FlowActiveBot]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bots = try c.decodeIfPresent([FlowActiveBot].self, forKey: .bots) ?? []
    }

    init(bots: [FlowActiveBot]) { self.bots = bots }
}

/// The bot Flow has attached to one calendar event, if any.
struct FlowEventBot: Codable, Equatable {
    let id: String
    let status: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
    }

    init(id: String, status: String) {
        self.id = id
        self.status = status
    }
}

/// One row of the caller's Outlook calendar as Flow hands it over.
/// `attendees` already excludes the caller, so "at least one other person on
/// this call" is simply a non-empty list.
struct FlowCalendarEvent: Codable, Equatable {
    let id: String
    let subject: String
    let start: Date
    let end: Date?
    let isOnline: Bool
    let joinURL: String?
    let attendees: [String]
    let organizer: String?
    let response: String?
    let bot: FlowEventBot?

    enum CodingKeys: String, CodingKey {
        case id, subject, start, end, attendees, organizer, response, bot
        case isOnline = "is_online"
        case joinURL = "join_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        subject = try c.decodeIfPresent(String.self, forKey: .subject) ?? ""
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decodeIfPresent(Date.self, forKey: .end)
        isOnline = try c.decodeIfPresent(Bool.self, forKey: .isOnline) ?? false
        joinURL = try c.decodeIfPresent(String.self, forKey: .joinURL)
        attendees = try c.decodeIfPresent([String].self, forKey: .attendees) ?? []
        organizer = try c.decodeIfPresent(String.self, forKey: .organizer)
        response = try c.decodeIfPresent(String.self, forKey: .response)
        bot = try c.decodeIfPresent(FlowEventBot.self, forKey: .bot)
    }

    init(id: String, subject: String, start: Date, end: Date? = nil, isOnline: Bool = false,
         joinURL: String? = nil, attendees: [String] = [], organizer: String? = nil,
         response: String? = nil, bot: FlowEventBot? = nil) {
        self.id = id
        self.subject = subject
        self.start = start
        self.end = end
        self.isOnline = isOnline
        self.joinURL = joinURL
        self.attendees = attendees
        self.organizer = organizer
        self.response = response
        self.bot = bot
    }
}

struct FlowUpcoming: Codable, Equatable {
    /// off | declined | all. The app never sets it; it decides whether an
    /// event is the bot's job or this Mac's.
    let botMode: String
    let events: [FlowCalendarEvent]

    enum CodingKeys: String, CodingKey {
        case events
        case botMode = "bot_mode"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        botMode = try c.decodeIfPresent(String.self, forKey: .botMode) ?? "off"
        events = try c.decodeIfPresent([FlowCalendarEvent].self, forKey: .events) ?? []
    }

    init(botMode: String, events: [FlowCalendarEvent]) {
        self.botMode = botMode
        self.events = events
    }
}

/// The manifest POSTed to /api/public/whisper/recordings/{id}/complete.
/// The key names and types here are the contract with the Flow function, so
/// they are spelled out rather than derived: `startedAt` and `endedAt` are ISO
/// 8601 in UTC with a Z, every duration is a JSON number, and `embedding` is
/// 256 floats or absent.
struct MeetingManifest: Codable, Equatable {
    struct Consent: Codable, Equatable {
        let confirmedAt: Date
        let wordingVersion: String
    }

    struct Speaker: Codable, Equatable {
        let speakerId: String
        var email: String?
        var name: String?
        var matched: Bool
        var seconds: Double
        var embedding: [Float]?
        var sampleFile: String?

        enum CodingKeys: String, CodingKey {
            case speakerId, email, name, matched, seconds, embedding, sampleFile
        }

        /// `email` and `name` always appear, as null when unknown, so the
        /// server never has to tell "absent" from "not identified". The two
        /// optional payloads are omitted when there is nothing to send.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(speakerId, forKey: .speakerId)
            try c.encode(email, forKey: .email)
            try c.encode(name, forKey: .name)
            try c.encode(matched, forKey: .matched)
            try c.encode(seconds, forKey: .seconds)
            try c.encodeIfPresent(embedding, forKey: .embedding)
            try c.encodeIfPresent(sampleFile, forKey: .sampleFile)
        }

        init(speakerId: String, email: String? = nil, name: String? = nil, matched: Bool,
             seconds: Double, embedding: [Float]? = nil, sampleFile: String? = nil) {
            self.speakerId = speakerId
            self.email = email
            self.name = name
            self.matched = matched
            self.seconds = seconds
            self.embedding = embedding
            self.sampleFile = sampleFile
        }
    }

    struct Segment: Codable, Equatable {
        let speakerId: String
        let start: Double
        let end: Double
        let text: String
    }

    var title: String
    var startedAt: Date
    var endedAt: Date?
    var trackASeconds: Double
    var trackBSeconds: Double
    var trackBOffsetSeconds: Double
    var attendees: [String]
    var consent: Consent
    /// Set only when the recording was started from a calendar prompt.
    /// Omitted from the JSON when nil, so a hand-started recording sends the
    /// same manifest it always did.
    var calendarEventId: String?
    var speakers: [Speaker]
    var segments: [Segment]

    init(title: String, startedAt: Date, endedAt: Date?, trackASeconds: Double, trackBSeconds: Double,
         trackBOffsetSeconds: Double, attendees: [String], consent: Consent,
         calendarEventId: String? = nil, speakers: [Speaker], segments: [Segment]) {
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.trackASeconds = trackASeconds
        self.trackBSeconds = trackBSeconds
        self.trackBOffsetSeconds = trackBOffsetSeconds
        self.attendees = attendees
        self.consent = consent
        self.calendarEventId = calendarEventId
        self.speakers = speakers
        self.segments = segments
    }
}

struct FlowCompleteResponse: Codable, Equatable {
    let ok: Bool
    let status: String
    let summary: MeetingSummary?
    let speakerNames: [String: String]

    enum CodingKeys: String, CodingKey {
        case ok, status, summary
        case speakerNames = "speaker_names"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "uploaded"
        summary = try c.decodeIfPresent(MeetingSummary.self, forKey: .summary)
        speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
    }

    init(ok: Bool, status: String, summary: MeetingSummary?, speakerNames: [String: String]) {
        self.ok = ok
        self.status = status
        self.summary = summary
        self.speakerNames = speakerNames
    }
}

struct FlowRecordingStatus: Codable, Equatable {
    let status: String
    let speakerNames: [String: String]
    let summary: MeetingSummary?

    enum CodingKeys: String, CodingKey {
        case status, summary
        case speakerNames = "speaker_names"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "uploaded"
        speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        summary = try c.decodeIfPresent(MeetingSummary.self, forKey: .summary)
    }

    init(status: String, speakerNames: [String: String], summary: MeetingSummary?) {
        self.status = status
        self.speakerNames = speakerNames
        self.summary = summary
    }
}

// MARK: - Client

/// Everything that leaves this Mac for Flow goes through here. One bearer
/// token, four endpoints, no Supabase SDK and no Cloudflare Access dance: the
/// endpoints under /api/public/whisper sit behind the existing Access bypass
/// and authorise on sha256 of this token.
final class FlowClient: @unchecked Sendable {
    static let shared = FlowClient()

    /// Dev override, so a laptop can point at a preview deployment without a
    /// rebuild: `defaults write com.niallwogan.whisperflow flowServer http://127.0.0.1:8788`.
    static let serverDefaultsKey = "flowServer"
    static let productionServer = "https://flow.vervefitness.ai"

    /// One file may not exceed this; the storage bucket rejects more.
    static let maxUploadBytes = 300 * 1_048_576

    /// Three attempts per request. The delay after a failed attempt is taken
    /// from this table in order, so at three attempts the waits are 2 s and
    /// 4 s; the 8 s entry is what a fourth attempt would wait if the budget is
    /// ever raised.
    static let retryDelaysSeconds: [Double] = [2, 4, 8]
    static let maxAttempts = 3

    private let session: URLSession
    /// Tests hand a token straight in. An unsigned test binary has no
    /// keychain of its own, so a real SecItemAdd from a test run either
    /// blocks on a prompt or leaves a credential on the machine; neither is
    /// something a test should do. Nil everywhere else, which is the
    /// keychain path.
    private let tokenOverride: String?

    init(session: URLSession = .shared, token: String? = nil) {
        self.session = session
        self.tokenOverride = token
    }

    // MARK: Connection

    var serverBase: String {
        let raw = (UserDefaults.standard.string(forKey: Self.serverDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = raw.isEmpty ? Self.productionServer : raw
        return base.hasSuffix("/") ? String(base.dropLast()) : base
    }

    var token: String? { tokenOverride ?? FlowKeychain.read() }

    var isConnected: Bool { token != nil }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// Stores a token and, when a server was supplied with it, remembers that
    /// server. Returns the identity the token belongs to, so the caller can
    /// say who this Mac is connected as instead of just "connected".
    @discardableResult
    func connect(token: String, server: String?) async throws -> FlowMe {
        if let server, !server.isEmpty, server != Self.productionServer {
            UserDefaults.standard.set(server, forKey: Self.serverDefaultsKey)
        } else if server == Self.productionServer {
            UserDefaults.standard.removeObject(forKey: Self.serverDefaultsKey)
        }
        FlowKeychain.write(token)
        do {
            return try await me()
        } catch {
            // A token Flow will not accept is worse than no token: it makes
            // "Record meeting" look available when nothing can be uploaded.
            if let flow = error as? FlowError, flow == .unauthorised { FlowKeychain.delete() }
            throw error
        }
    }

    func disconnect() {
        FlowKeychain.delete()
    }

    // MARK: Endpoints

    func me() async throws -> FlowMe {
        let data = try await send(path: "/api/public/whisper/me", method: "GET", body: nil, label: "me")
        return try decode(FlowMe.self, from: data, label: "me")
    }

    /// Streams one file straight off disk. `uploadTask(with:fromFile:)` rather
    /// than a Data body, so a 30 MB track never sits in memory twice.
    @discardableResult
    func putFile(recordingID: String, name: String, url: URL, contentType: String? = nil) async throws -> Int {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= Self.maxUploadBytes else { throw FlowError.tooLarge(name, size) }
        let type = contentType ?? Self.contentType(forFileName: name)
        let path = "/api/public/whisper/recordings/\(recordingID)/files/\(name)"
        _ = try await withRetries(label: "PUT \(name)") { [weak self] in
            guard let self else { throw FlowError.notConnected }
            var request = try self.request(path: path, method: "PUT")
            request.setValue(type, forHTTPHeaderField: "Content-Type")
            return try await self.upload(request: request, fromFile: url)
        }
        return size
    }

    func complete(recordingID: String, manifest: MeetingManifest) async throws -> FlowCompleteResponse {
        let body = try Self.encodeManifest(manifest)
        let data = try await send(path: "/api/public/whisper/recordings/\(recordingID)/complete",
                                  method: "POST", body: body, label: "complete \(recordingID)")
        return try decode(FlowCompleteResponse.self, from: data, label: "complete")
    }

    func recording(id: String) async throws -> FlowRecordingStatus {
        let data = try await send(path: "/api/public/whisper/recordings/\(id)", method: "GET",
                                  body: nil, label: "recording \(id)")
        return try decode(FlowRecordingStatus.self, from: data, label: "recording")
    }

    /// The caller's calendar for the next two hours. One attempt: this runs
    /// on a sixty second timer, so a poll that fails is simply the next
    /// poll's problem and three retries would only stack up behind it.
    func upcoming(timeout: TimeInterval = 15) async throws -> FlowUpcoming {
        let data = try await send(path: "/api/public/whisper/upcoming", method: "GET", body: nil,
                                  label: "upcoming", attempts: 1, timeout: timeout)
        return try decode(FlowUpcoming.self, from: data, label: "upcoming")
    }

    /// The bots Flow has on the way or in a call right now. Called between
    /// the Record click and the consent gate, so the budget is two seconds
    /// and there is no retry: a slow or broken answer must never be the
    /// reason a meeting was not recorded.
    func activeBots(timeout: TimeInterval = 2) async throws -> [FlowActiveBot] {
        let data = try await send(path: "/api/public/whisper/bots?active=1", method: "GET", body: nil,
                                  label: "bots", attempts: 1, timeout: timeout)
        return try decode(FlowActiveBots.self, from: data, label: "bots").bots
    }

    // MARK: Encoding

    /// One encoder for the manifest so the shape cannot drift between the
    /// uploader and the tests: ISO 8601 in UTC with a Z, keys as written.
    static func manifestEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(f.string(from: date))
        }
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static func encodeManifest(_ manifest: MeetingManifest) throws -> Data {
        try manifestEncoder().encode(manifest)
    }

    /// Every date Flow sends is ISO 8601. Graph hands over "2026-09-05T04:32:10Z";
    /// a timestamptz through PostgREST can arrive with fractional seconds or a
    /// +00:00 offset instead of a Z. All three are read here rather than in
    /// each wire type.
    static func responseDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let raw = try c.decode(String.self)
            guard let date = parseISO8601(raw) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an ISO 8601 date: \(raw)")
            }
            return date
        }
        return d
    }

    static func parseISO8601(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    static func contentType(forFileName name: String) -> String {
        name.hasSuffix(".m4a") ? "audio/mp4" : "application/json"
    }

    // MARK: Plumbing

    private func request(path: String, method: String, timeout: TimeInterval = 120) throws -> URLRequest {
        guard let token else { throw FlowError.notConnected }
        guard let url = URL(string: serverBase + path) else { throw FlowError.transport("bad server address") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(Self.appVersion, forHTTPHeaderField: "X-WhisperFlow-Version")
        return request
    }

    private func send(path: String, method: String, body: Data?, label: String,
                      attempts: Int = FlowClient.maxAttempts,
                      timeout: TimeInterval = 120) async throws -> Data {
        try await withRetries(label: label, attempts: attempts) { [weak self] in
            guard let self else { throw FlowError.notConnected }
            var request = try self.request(path: path, method: method, timeout: timeout)
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            return try await self.data(for: request)
        }
    }

    private func data(for request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            return try Self.check(data: data, response: response)
        } catch let error as FlowError {
            throw error
        } catch {
            throw FlowError.transport(error.localizedDescription)
        }
    }

    /// `uploadTask(with:fromFile:)` has no async twin that also streams from
    /// disk on every macOS this app supports, so it is wrapped by hand.
    private func upload(request: URLRequest, fromFile url: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.uploadTask(with: request, fromFile: url) { data, response, error in
                if let error {
                    continuation.resume(throwing: FlowError.transport(error.localizedDescription))
                    return
                }
                guard let response else {
                    continuation.resume(throwing: FlowError.badResponse("no response"))
                    return
                }
                do {
                    continuation.resume(returning: try Self.check(data: data ?? Data(), response: response))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            task.resume()
        }
    }

    private static func check(data: Data, response: URLResponse) throws -> Data {
        guard let http = response as? HTTPURLResponse else { throw FlowError.badResponse("not an HTTP response") }
        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw FlowError.unauthorised
        default:
            let detail = String(data: data.prefix(400), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw FlowError.http(http.statusCode, detail)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, label: String) throws -> T {
        do {
            return try Self.responseDecoder().decode(type, from: data)
        } catch {
            throw FlowError.badResponse("\(label): \(error.localizedDescription)")
        }
    }

    private func withRetries<T>(label: String,
                                attempts: Int = FlowClient.maxAttempts,
                                _ body: @Sendable @escaping () async throws -> T) async throws -> T {
        var lastError: Error = FlowError.transport("no attempt was made")
        let budget = max(1, attempts)
        for attempt in 1...budget {
            do {
                return try await body()
            } catch {
                lastError = error
                let retryable = (error as? FlowError)?.isRetryable ?? true
                guard retryable, attempt < budget else {
                    FileHandle.standardError.write(Data("[flow] \(label) failed: \(error.localizedDescription)\n".utf8))
                    throw error
                }
                let delay = Self.retryDelaysSeconds[min(attempt - 1, Self.retryDelaysSeconds.count - 1)]
                FileHandle.standardError.write(Data("[flow] \(label) attempt \(attempt) failed (\(error.localizedDescription)), retrying in \(Int(delay))s\n".utf8))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw lastError
    }
}
