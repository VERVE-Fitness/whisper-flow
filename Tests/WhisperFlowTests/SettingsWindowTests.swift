import XCTest
@testable import WhisperFlow

/// The settings window's half of the week 3 part 4 contract: the payload the window reads,
/// the bodies it posts, and the pure rules behind snippets and insights.
///
/// The server endpoints are being written alongside this, so the HTTP here goes through the
/// same StubURLProtocol the calendar tests use and never touches the network or the login
/// keychain.
final class FlowSettingsClientTests: XCTestCase {
    private var savedServer: String?

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        savedServer = UserDefaults.standard.string(forKey: FlowClient.serverDefaultsKey)
        UserDefaults.standard.set("https://flow.test", forKey: FlowClient.serverDefaultsKey)
    }

    override func tearDown() {
        if let savedServer { UserDefaults.standard.set(savedServer, forKey: FlowClient.serverDefaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: FlowClient.serverDefaultsKey) }
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func client() -> FlowClient {
        FlowClient(session: StubURLProtocol.session(), token: "test-token")
    }

    /// The keys here are the ones public/functions/api/whisper-settings.js returns, because
    /// the public route serves the same payload.
    func testSettingsDecodesTheWebPagePayload() async throws {
        StubURLProtocol.stub("/api/public/whisper/settings", json: """
        {"me":{"email":"niall.wogan@vervefitness.com.au","name":"Niall Wogan"},
         "leader":true,"recognise_me":true,"bot_mode":"declined","bot_name":"VERVE Notes (Niall)",
         "bots_this_month":{"count":3,"finished":2,"hours":1.4},
         "profile":{"sample_count":6,"updated_at":"2026-09-01T04:00:00Z"},
         "phrases":[{"id":12,"phrase":"Tori","heard_as":["tory","torrie"],"scope":"team",
                     "source":"manual","hits":4,"mine":true,"editable":true}],
         "suggestions":[{"id":"31","email":"niall.wogan@vervefitness.com.au","heard":"verve pals",
                         "typed":"VERVE Pulse","count":2,"mine":true}],
         "queue":[{"recording_id":"rec_123","title":"Nathan 1:1","started_at":"2026-09-04T23:30:00Z",
                   "speaker_id":"S2","seconds":18.5,"clip_url":"https://clips.test/a.m4a",
                   "suggestions":[{"email":"nathan.hall@vervefitness.com.au","name":"Nathan Hall"}]}],
         "people":[{"email":"jacqueline@vervefitness.com.au","name":"Jacqueline"}],
         "snippets":[{"id":7,"cue":"my linkedin","text":"https://linkedin.com/in/niallwogan","scope":"person"},
                     {"id":8,"cue":"warranty line","text":"Every VERVE rig is covered.","scope":"team"}]}
        """)
        let settings = try await client().settings()

        XCTAssertEqual(settings.me.name, "Niall Wogan")
        XCTAssertTrue(settings.leader)
        XCTAssertTrue(settings.recogniseMe)
        XCTAssertEqual(settings.botMode, "declined")
        XCTAssertEqual(settings.botName, "VERVE Notes (Niall)")
        XCTAssertEqual(settings.botsThisMonth.count, 3)
        XCTAssertEqual(settings.botsThisMonth.hours, 1.4)
        XCTAssertEqual(settings.profile?.sampleCount, 6)

        // A numeric id and a string id both arrive as a string, because that is all the app
        // does with one: send it back.
        XCTAssertEqual(settings.phrases.first?.id, "12")
        XCTAssertEqual(settings.phrases.first?.heardAs, ["tory", "torrie"])
        XCTAssertTrue(settings.phrases.first?.editable ?? false)
        XCTAssertEqual(settings.suggestions.first?.id, "31")
        XCTAssertEqual(settings.suggestions.first?.typed, "VERVE Pulse")

        let queued = try XCTUnwrap(settings.queue.first)
        XCTAssertEqual(queued.recordingID, "rec_123")
        XCTAssertEqual(queued.speakerID, "S2")
        XCTAssertEqual(queued.seconds, 18.5)
        XCTAssertEqual(queued.clipURL, "https://clips.test/a.m4a")
        XCTAssertEqual(queued.suggestions.first?.name, "Nathan Hall")
        XCTAssertEqual(queued.id, "rec_123/S2")

        XCTAssertEqual(settings.people.first?.name, "Jacqueline")
        XCTAssertEqual(settings.snippets.count, 2)
        XCTAssertEqual(settings.snippets.first?.id, "7")
        XCTAssertEqual(settings.snippets.last?.scope, "team")
    }

    /// A server that has not shipped part of this yet must leave the window usable, not
    /// blank it with a decode failure.
    func testSettingsToleratesAThinPayload() async throws {
        StubURLProtocol.stub("/api/public/whisper/settings", json: #"{"me":{"email":"a@b.c"}}"#)
        let settings = try await client().settings()
        XCTAssertEqual(settings.me.email, "a@b.c")
        XCTAssertEqual(settings.me.name, "")
        XCTAssertEqual(settings.botMode, "off")
        XCTAssertTrue(settings.phrases.isEmpty)
        XCTAssertTrue(settings.snippets.isEmpty)
        XCTAssertTrue(settings.queue.isEmpty)
        XCTAssertNil(settings.profile)
        XCTAssertEqual(settings.botsThisMonth.count, 0)
        XCTAssertNil(settings.botsThisMonth.hours)
    }

    func testSettingsCarriesTheBearerTokenAndDoesNotRetry() async throws {
        StubURLProtocol.stub("/api/public/whisper/settings", status: 401, json: #"{"error":"unauthorised"}"#)
        do {
            _ = try await client().settings()
            XCTFail("a 401 should throw")
        } catch {
            XCTAssertEqual(error as? FlowError, .unauthorised)
        }
        XCTAssertEqual(StubURLProtocol.seenRequests.count, 1)
        XCTAssertEqual(StubURLProtocol.seenRequests.last?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer test-token")
    }

    /// The action names and keys are the web page's, so one server implementation answers
    /// both routes.
    func testSettingsActionPostsTheActionBody() async throws {
        StubURLProtocol.stub("/api/public/whisper/settings", json: #"{"ok":true}"#)
        let result = try await client().settingsAction([
            "action": "snippet_add", "cue": "my linkedin",
            "text": "https://linkedin.com/in/niallwogan", "scope": "person",
        ])
        XCTAssertTrue(result.ok)

        let request = try XCTUnwrap(StubURLProtocol.seenRequests.last)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/public/whisper/settings")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(StubURLProtocol.lastBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["action"] as? String, "snippet_add")
        XCTAssertEqual(object["cue"] as? String, "my linkedin")
        XCTAssertEqual(object["scope"] as? String, "person")
    }

    func testSettingsActionSendsTheServerReasonBack() async throws {
        StubURLProtocol.stub("/api/public/whisper/settings", status: 400,
                             json: #"{"error":"That phrase is already on the list."}"#)
        do {
            _ = try await client().settingsAction(["action": "phrase_add", "phrase": "Tori"])
            XCTFail("a 400 should throw")
        } catch {
            let flow = try XCTUnwrap(error as? FlowError)
            XCTAssertTrue(flow.errorDescription?.contains("already on the list") ?? false)
        }
    }

    /// The window sends ids and lists straight from the payload, so a body that cannot be
    /// turned into JSON must fail here rather than halfway through a request.
    func testSettingsActionRefusesABodyThatIsNotJSON() {
        XCTAssertThrowsError(try FlowClient.encodeAction(["action": "phrase_add", "when": Date()]))
    }

    /// /me is what every Mac reads at connect and after each Stop, so the snippets have to
    /// arrive there as well as in the settings payload.
    func testMeCarriesSnippetsAndStillDecodesWithoutThem() async throws {
        StubURLProtocol.stub("/api/public/whisper/me", json: """
        {"email":"a@b.c","name":"A","recognise_me":false,"profiles":[],"staff":[],
         "phrases":[{"phrase":"Tori","heard_as":["tory"]}],
         "snippets":[{"id":9,"cue":"my linkedin","text":"https://linkedin.com/in/x","scope":"person"}]}
        """)
        let me = try await client().me(timeout: 5, attempts: 1)
        XCTAssertEqual(me.snippets.count, 1)
        XCTAssertEqual(me.snippets.first?.cue, "my linkedin")

        StubURLProtocol.reset()
        StubURLProtocol.stub("/api/public/whisper/me", json: #"{"email":"a@b.c","name":"A"}"#)
        let older = try await client().me(timeout: 5, attempts: 1)
        XCTAssertTrue(older.snippets.isEmpty)
    }
}

/// The snippet rules the window, the merge and dictation all lean on.
final class SnippetRulesTests: XCTestCase {
    func testLocalWinsACueClashSoAnOfflineMacKeepsWorking() {
        let remote = [
            FlowSnippet(id: "1", cue: "my linkedin", text: "team version", scope: "team"),
            FlowSnippet(id: "2", cue: "My LinkedIn", text: "person version", scope: "person"),
        ]
        let merged = SnippetRules.merged(remote: remote, local: ["MY LINKEDIN": "local version"])
        XCTAssertEqual(merged["my linkedin"], "local version")
        XCTAssertEqual(merged.count, 1)
    }

    func testAPersonSnippetBeatsATeamOneOnTheSameCue() {
        let remote = [
            FlowSnippet(id: "1", cue: "sign off", text: "team", scope: "team"),
            FlowSnippet(id: "2", cue: "sign off", text: "mine", scope: "person"),
        ]
        XCTAssertEqual(SnippetRules.merged(remote: remote, local: [:])["sign off"], "mine")
    }

    func testTeamSnippetsReachAMacWithNoLocalOnes() {
        let remote = [FlowSnippet(id: "1", cue: "Warranty line", text: "Covered.", scope: "team")]
        XCTAssertEqual(SnippetRules.merged(remote: remote, local: [:])["warranty line"], "Covered.")
    }

    func testEmptyCuesAndTextsAreDropped() {
        let remote = [
            FlowSnippet(id: "1", cue: "   ", text: "nothing", scope: "team"),
            FlowSnippet(id: "2", cue: "empty", text: "", scope: "team"),
        ]
        XCTAssertTrue(SnippetRules.merged(remote: remote, local: ["  ": "x", "ok": ""]).isEmpty)
    }

    func testCueValidation() {
        XCTAssertNil(SnippetRules.problem(cue: "my linkedin", text: "https://x"))
        XCTAssertNotNil(SnippetRules.problem(cue: "   ", text: "https://x"))
        XCTAssertNotNil(SnippetRules.problem(cue: "ok", text: "  "))
        XCTAssertNotNil(SnippetRules.problem(cue: String(repeating: "a", count: 61), text: "x"))
        XCTAssertNil(SnippetRules.problem(cue: String(repeating: "a", count: 60), text: "x"))
        XCTAssertNotNil(SnippetRules.problem(cue: "ok", text: String(repeating: "a", count: 4001)))
    }

    /// The cache is what an offline Mac reads at launch.
    func testTheCacheRoundTripsThroughDisk() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("snippets-\(UUID().uuidString).json")
        SnippetStore.urlOverride = tmp
        defer {
            SnippetStore.urlOverride = nil
            try? FileManager.default.removeItem(at: tmp)
        }
        let store = SnippetStore()
        store.replace([FlowSnippet(id: "1", cue: "my linkedin", text: "https://x", scope: "person")])
        XCTAssertEqual(SnippetStore.load().first?.text, "https://x")
        XCTAssertEqual(store.runtimeMap(local: [:])["my linkedin"], "https://x")
    }

    /// A comma separated "it comes out as" box has to become a clean list.
    func testHeardAsListSplitsTrimsAndDropsRepeats() {
        XCTAssertEqual(DictionarySettingsView.heardAsList(" tory , Torrie ,, tory "),
                       ["tory", "Torrie"])
        XCTAssertEqual(DictionarySettingsView.heardAsList("   "), [])
    }
}

/// The Insights numbers, which are read off a log that has grown fields over a year.
final class InsightsTests: XCTestCase {
    private func iso(_ raw: String) -> Date {
        FlowClient.parseISO8601(raw)!
    }

    func testWordsAreCharactersOverFive() {
        XCTAssertEqual(Insights.words(cleanedChars: 100, rawChars: 90), 20)
        // Nothing cleaned falls back to the raw count rather than counting as zero.
        XCTAssertEqual(Insights.words(cleanedChars: 0, rawChars: 50), 10)
        XCTAssertEqual(Insights.words(cleanedChars: 0, rawChars: 0), 0)
    }

    func testALineWithNoTextIsNotADictation() {
        XCTAssertNil(Insights.sample(fromLine: ""))
        XCTAssertNil(Insights.sample(fromLine: "not json"))
        XCTAssertNil(Insights.sample(fromLine: #"{"mode":"ptt","cleaned_chars":100}"#))
        XCTAssertNil(Insights.sample(fromLine: #"{"ts":"2026-09-05T01:00:00.000Z","cleaned_chars":0,"raw_chars":0}"#))
    }

    /// An old line from before `outcome` and `input_device` existed still counts.
    func testAnOldLogLineStillCounts() throws {
        let sample = try XCTUnwrap(Insights.sample(
            fromLine: #"{"ts":"2026-08-20T03:15:00.000Z","mode":"ptt","audio_seconds":12.5,"raw_chars":300,"cleaned_chars":250,"stt_ms":400,"cleanup_ms":90,"cleanup_backend":"ollama"}"#))
        XCTAssertEqual(sample.words, 50)
        XCTAssertEqual(sample.audioSeconds, 12.5)
    }

    func testSummaryBucketsByDayAndKeepsTheEmptyDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = iso("2026-09-05T09:00:00Z")
        let samples = [
            Insights.Sample(date: iso("2026-09-05T01:00:00Z"), words: 100, audioSeconds: 60),
            Insights.Sample(date: iso("2026-09-05T02:00:00Z"), words: 60, audioSeconds: 30),
            Insights.Sample(date: iso("2026-09-03T02:00:00Z"), words: 40, audioSeconds: 30),
            // Outside the window: a year ago, and tomorrow.
            Insights.Sample(date: iso("2025-09-05T02:00:00Z"), words: 999, audioSeconds: 999),
            Insights.Sample(date: iso("2026-09-06T02:00:00Z"), words: 999, audioSeconds: 999),
        ]
        let summary = Insights.summarise(samples, now: now, calendar: calendar)

        XCTAssertEqual(summary.days.count, 30)
        XCTAssertEqual(summary.dictations, 3)
        XCTAssertEqual(summary.words, 200)
        XCTAssertEqual(summary.audioSeconds, 120)
        XCTAssertEqual(summary.minutesOfAudio, 2)
        XCTAssertEqual(summary.averageWordsPerDictation, 67)
        // 200 words at 40 a minute.
        XCTAssertEqual(summary.minutesSaved, 5)

        let today = try XCTUnwrap(summary.days.last)
        XCTAssertEqual(today.dictations, 2)
        XCTAssertEqual(today.words, 160)
        XCTAssertEqual(summary.days.first?.dictations, 0)
    }

    func testAMacThatHasNeverDictatedGetsAnEmptySummary() {
        XCTAssertTrue(Insights.summarise([], now: Date()).isEmpty)
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("no-usage-\(UUID().uuidString).jsonl")
        XCTAssertTrue(Insights.read(url: missing).isEmpty)
    }

    func testReadingALogFileOffDisk() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("usage-\(UUID().uuidString).jsonl")
        let lines = """
        {"ts":"2026-09-05T01:00:00.000Z","cleaned_chars":250,"raw_chars":260,"audio_seconds":10}
        not a line at all
        {"ts":"2026-09-04T01:00:00.000Z","cleaned_chars":100,"raw_chars":110,"audio_seconds":5}

        """
        try lines.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = Insights.read(url: url, now: iso("2026-09-05T09:00:00Z"), calendar: calendar)
        XCTAssertEqual(summary.dictations, 2)
        XCTAssertEqual(summary.words, 70)
    }
}
