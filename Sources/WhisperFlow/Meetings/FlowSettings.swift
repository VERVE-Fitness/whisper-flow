import Foundation

// The payload behind the settings window. It is the same shape the web page at
// /whisper-settings already reads, served a second time under the device token at
// GET /api/public/whisper/settings so the window never needs a browser login.
//
// Every field is optional on the wire. A server that has not shipped a part of this yet
// (snippets, say) must read as an empty list, not as a decode failure that blanks the whole
// window.

/// Ids come off Postgres as numbers through PostgREST and as strings through some proxies.
/// Both are read as a string, because that is all the app ever does with them: send them back.
private func flowID<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> String {
    // `try?` flattens the optional decodeIfPresent returns, so one `if let` is enough.
    if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s }
    if let i = try? c.decodeIfPresent(Int64.self, forKey: key) { return String(i) }
    return ""
}

struct FlowIdentitySummary: Codable, Equatable, Sendable {
    let email: String
    let name: String

    init(email: String, name: String) {
        self.email = email
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    }
}

/// One phrase as the settings payload carries it: the row plus whether this person is
/// allowed to change it.
struct FlowSettingsPhrase: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let phrase: String
    let heardAs: [String]
    let scope: String
    let source: String
    let hits: Int
    let mine: Bool
    let editable: Bool

    enum CodingKeys: String, CodingKey {
        case id, phrase, scope, source, hits, mine, editable
        case heardAs = "heard_as"
    }

    init(id: String, phrase: String, heardAs: [String] = [], scope: String = "team",
         source: String = "manual", hits: Int = 0, mine: Bool = false, editable: Bool = false) {
        self.id = id
        self.phrase = phrase
        self.heardAs = heardAs
        self.scope = scope
        self.source = source
        self.hits = hits
        self.mine = mine
        self.editable = editable
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = flowID(c, .id)
        phrase = try c.decodeIfPresent(String.self, forKey: .phrase) ?? ""
        heardAs = try c.decodeIfPresent([String].self, forKey: .heardAs) ?? []
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? "team"
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "manual"
        hits = try c.decodeIfPresent(Int.self, forKey: .hits) ?? 0
        mine = try c.decodeIfPresent(Bool.self, forKey: .mine) ?? false
        editable = try c.decodeIfPresent(Bool.self, forKey: .editable) ?? false
    }
}

/// "Heard X, you typed Y" from somebody's Mac, waiting for a person to decide.
struct FlowPhraseSuggestion: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let email: String
    let heard: String
    let typed: String
    let count: Int
    let mine: Bool

    enum CodingKeys: String, CodingKey {
        case id, email, heard, typed, count, mine
    }

    init(id: String, email: String = "", heard: String, typed: String, count: Int = 1, mine: Bool = true) {
        self.id = id
        self.email = email
        self.heard = heard
        self.typed = typed
        self.count = count
        self.mine = mine
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = flowID(c, .id)
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        heard = try c.decodeIfPresent(String.self, forKey: .heard) ?? ""
        typed = try c.decodeIfPresent(String.self, forKey: .typed) ?? ""
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 1
        mine = try c.decodeIfPresent(Bool.self, forKey: .mine) ?? true
    }
}

/// A name Flow can suggest for an unknown voice: an attendee of that meeting first, then
/// everybody on staff.
struct FlowNameSuggestion: Codable, Equatable, Sendable, Hashable {
    let email: String
    let name: String

    init(email: String, name: String) {
        self.email = email
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    }
}

/// One voice nobody has put a name to yet, with a five minute signed link to the clip.
struct FlowSpeakerQueueItem: Codable, Equatable, Sendable, Identifiable {
    let recordingID: String
    let title: String
    let startedAt: Date?
    let speakerID: String
    let seconds: Double
    let clipURL: String?
    let suggestions: [FlowNameSuggestion]

    var id: String { recordingID + "/" + speakerID }

    enum CodingKeys: String, CodingKey {
        case title, seconds, suggestions
        case recordingID = "recording_id"
        case startedAt = "started_at"
        case speakerID = "speaker_id"
        case clipURL = "clip_url"
    }

    init(recordingID: String, title: String, startedAt: Date?, speakerID: String,
         seconds: Double, clipURL: String?, suggestions: [FlowNameSuggestion]) {
        self.recordingID = recordingID
        self.title = title
        self.startedAt = startedAt
        self.speakerID = speakerID
        self.seconds = seconds
        self.clipURL = clipURL
        self.suggestions = suggestions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recordingID = try c.decodeIfPresent(String.self, forKey: .recordingID) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled meeting"
        startedAt = try? c.decodeIfPresent(Date.self, forKey: .startedAt)
        speakerID = try c.decodeIfPresent(String.self, forKey: .speakerID) ?? ""
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
        clipURL = try c.decodeIfPresent(String.self, forKey: .clipURL)
        suggestions = try c.decodeIfPresent([FlowNameSuggestion].self, forKey: .suggestions) ?? []
    }
}

struct FlowStaffPerson: Codable, Equatable, Sendable, Hashable {
    let email: String
    let name: String

    init(email: String, name: String) {
        self.email = email
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    }
}

/// How many bots went out this calendar month, and how long they sat in rooms. `hours` is
/// null until a bot has brought a recording back, so it is shown only when it is real.
struct FlowBotsThisMonth: Codable, Equatable, Sendable {
    let count: Int
    let finished: Int
    let hours: Double?

    init(count: Int, finished: Int, hours: Double?) {
        self.count = count
        self.finished = finished
        self.hours = hours
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
        finished = try c.decodeIfPresent(Int.self, forKey: .finished) ?? 0
        hours = try? c.decodeIfPresent(Double.self, forKey: .hours)
    }
}

struct FlowVoiceProfileSummary: Codable, Equatable, Sendable {
    let sampleCount: Int
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case sampleCount = "sample_count"
        case updatedAt = "updated_at"
    }

    init(sampleCount: Int, updatedAt: Date?) {
        self.sampleCount = sampleCount
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sampleCount = try c.decodeIfPresent(Int.self, forKey: .sampleCount) ?? 0
        updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

/// Everything the settings window reads in one call.
struct FlowSettings: Codable, Equatable, Sendable {
    let me: FlowIdentitySummary
    let leader: Bool
    let recogniseMe: Bool
    let botMode: String
    let botName: String
    let botsThisMonth: FlowBotsThisMonth
    let profile: FlowVoiceProfileSummary?
    let phrases: [FlowSettingsPhrase]
    let suggestions: [FlowPhraseSuggestion]
    let queue: [FlowSpeakerQueueItem]
    let people: [FlowStaffPerson]
    let snippets: [FlowSnippet]

    enum CodingKeys: String, CodingKey {
        case me, leader, profile, phrases, suggestions, queue, people, snippets
        case recogniseMe = "recognise_me"
        case botMode = "bot_mode"
        case botName = "bot_name"
        case botsThisMonth = "bots_this_month"
    }

    init(me: FlowIdentitySummary, leader: Bool = false, recogniseMe: Bool = false,
         botMode: String = "off", botName: String = "",
         botsThisMonth: FlowBotsThisMonth = FlowBotsThisMonth(count: 0, finished: 0, hours: nil),
         profile: FlowVoiceProfileSummary? = nil, phrases: [FlowSettingsPhrase] = [],
         suggestions: [FlowPhraseSuggestion] = [], queue: [FlowSpeakerQueueItem] = [],
         people: [FlowStaffPerson] = [], snippets: [FlowSnippet] = []) {
        self.me = me
        self.leader = leader
        self.recogniseMe = recogniseMe
        self.botMode = botMode
        self.botName = botName
        self.botsThisMonth = botsThisMonth
        self.profile = profile
        self.phrases = phrases
        self.suggestions = suggestions
        self.queue = queue
        self.people = people
        self.snippets = snippets
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        me = try c.decodeIfPresent(FlowIdentitySummary.self, forKey: .me)
            ?? FlowIdentitySummary(email: "", name: "")
        leader = try c.decodeIfPresent(Bool.self, forKey: .leader) ?? false
        recogniseMe = try c.decodeIfPresent(Bool.self, forKey: .recogniseMe) ?? false
        botMode = try c.decodeIfPresent(String.self, forKey: .botMode) ?? "off"
        botName = try c.decodeIfPresent(String.self, forKey: .botName) ?? ""
        botsThisMonth = try c.decodeIfPresent(FlowBotsThisMonth.self, forKey: .botsThisMonth)
            ?? FlowBotsThisMonth(count: 0, finished: 0, hours: nil)
        profile = try? c.decodeIfPresent(FlowVoiceProfileSummary.self, forKey: .profile)
        phrases = try c.decodeIfPresent([FlowSettingsPhrase].self, forKey: .phrases) ?? []
        suggestions = try c.decodeIfPresent([FlowPhraseSuggestion].self, forKey: .suggestions) ?? []
        queue = try c.decodeIfPresent([FlowSpeakerQueueItem].self, forKey: .queue) ?? []
        people = try c.decodeIfPresent([FlowStaffPerson].self, forKey: .people) ?? []
        snippets = try c.decodeIfPresent([FlowSnippet].self, forKey: .snippets) ?? []
    }

    /// The three choices in the Meeting bot block, in the order they are shown.
    static let botModes = ["off", "declined", "all"]

    static func botModeSentence(_ mode: String) -> String {
        switch mode {
        case "declined": return "Only meetings I decline or mark as maybe"
        case "all": return "Every meeting with a join link"
        default: return "Never send a bot"
        }
    }
}

/// What a POST to the settings endpoint answers with. An action that fails comes back as an
/// HTTP error with the reason in it, so this is only the happy path.
struct FlowActionResult: Codable, Equatable, Sendable {
    let ok: Bool

    init(ok: Bool) { self.ok = ok }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? true
    }
}
