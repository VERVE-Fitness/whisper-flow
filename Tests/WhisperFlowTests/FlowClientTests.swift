import XCTest
@testable import WhisperFlow

/// The manifest is the contract with the Flow function that writes
/// th_recordings, so these tests read the encoded JSON back as a dictionary
/// and check the key names, the date format and the number types. A rename on
/// either side fails here rather than in production.
final class MeetingManifestEncodingTests: XCTestCase {
    private func manifest() -> MeetingManifest {
        let started = ISO8601DateFormatter().date(from: "2026-09-05T04:32:10Z")!
        let ended = ISO8601DateFormatter().date(from: "2026-09-05T05:01:40Z")!
        let confirmed = ISO8601DateFormatter().date(from: "2026-09-05T04:32:08Z")!
        return MeetingManifest(
            title: "Nathan 1:1",
            startedAt: started,
            endedAt: ended,
            trackASeconds: 1770.2,
            trackBSeconds: 1769.1,
            trackBOffsetSeconds: 1.05,
            attendees: ["Nathan Hall"],
            consent: MeetingManifest.Consent(confirmedAt: confirmed, wordingVersion: "consent-v2"),
            speakers: [
                MeetingManifest.Speaker(speakerId: "A", email: "niall.wogan@vervefitness.com.au",
                                        name: "Niall Wogan", matched: true, seconds: 900.0,
                                        embedding: Array(repeating: 0.1, count: 256)),
                MeetingManifest.Speaker(speakerId: "S2", email: nil, name: nil, matched: false,
                                        seconds: 12.0, embedding: Array(repeating: 0.2, count: 256),
                                        sampleFile: "speaker-S2.m4a"),
            ],
            segments: [MeetingManifest.Segment(speakerId: "A", start: 0.4, end: 3.9, text: "Morning Nathan.")]
        )
    }

    private func encodedObject() throws -> [String: Any] {
        let data = try FlowClient.encodeManifest(manifest())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTopLevelKeysMatchTheContract() throws {
        let obj = try encodedObject()
        XCTAssertEqual(Set(obj.keys), ["title", "startedAt", "endedAt", "trackASeconds", "trackBSeconds",
                                       "trackBOffsetSeconds", "attendees", "consent", "speakers", "segments"])
        XCTAssertEqual(obj["title"] as? String, "Nathan 1:1")
        XCTAssertEqual(obj["attendees"] as? [String], ["Nathan Hall"])
    }

    func testDatesAreISO8601InUTCWithAZ() throws {
        let obj = try encodedObject()
        XCTAssertEqual(obj["startedAt"] as? String, "2026-09-05T04:32:10Z")
        XCTAssertEqual(obj["endedAt"] as? String, "2026-09-05T05:01:40Z")
        let consent = obj["consent"] as? [String: Any]
        XCTAssertEqual(consent?["confirmedAt"] as? String, "2026-09-05T04:32:08Z")
        XCTAssertEqual(consent?["wordingVersion"] as? String, "consent-v2")
    }

    /// A duration sent as "1770.2" instead of 1770.2 lands in Postgres as
    /// null, and the recording then reports no length at all.
    func testDurationsAreNumbersNotStrings() throws {
        let obj = try encodedObject()
        XCTAssertEqual(obj["trackASeconds"] as? Double, 1770.2)
        XCTAssertEqual(obj["trackBSeconds"] as? Double, 1769.1)
        XCTAssertEqual(obj["trackBOffsetSeconds"] as? Double, 1.05)
        XCTAssertNil(obj["trackASeconds"] as? String)
        let segment = (obj["segments"] as? [[String: Any]])?.first
        XCTAssertEqual(segment?["start"] as? Double, 0.4)
        XCTAssertEqual(segment?["end"] as? Double, 3.9)
        XCTAssertEqual(segment?["speakerId"] as? String, "A")
        XCTAssertEqual(segment?["text"] as? String, "Morning Nathan.")
    }

    func testSpeakerShapeCarriesEmbeddingsAndNullNames() throws {
        let obj = try encodedObject()
        let speakers = try XCTUnwrap(obj["speakers"] as? [[String: Any]])
        XCTAssertEqual(speakers.count, 2)

        let a = speakers[0]
        XCTAssertEqual(a["speakerId"] as? String, "A")
        XCTAssertEqual(a["email"] as? String, "niall.wogan@vervefitness.com.au")
        XCTAssertEqual(a["name"] as? String, "Niall Wogan")
        XCTAssertEqual(a["matched"] as? Bool, true)
        XCTAssertEqual(a["seconds"] as? Double, 900.0)
        XCTAssertEqual((a["embedding"] as? [Double])?.count, 256)
        XCTAssertNil(a["sampleFile"])

        let s2 = speakers[1]
        // Present and null, never missing: the server must be able to tell
        // "we did not identify this person" from "the app forgot the field".
        XCTAssertTrue(s2.keys.contains("name"))
        XCTAssertTrue(s2.keys.contains("email"))
        XCTAssertTrue(s2["name"] is NSNull)
        XCTAssertTrue(s2["email"] is NSNull)
        XCTAssertEqual(s2["matched"] as? Bool, false)
        XCTAssertEqual(s2["sampleFile"] as? String, "speaker-S2.m4a")
    }

    /// A recording started by hand carries no event, and the key must not
    /// appear at all: the server tells "not from a calendar" from "the app
    /// sent an empty string" by the key being absent.
    func testCalendarEventIdIsAbsentWhenTheRecordingWasStartedByHand() throws {
        let obj = try encodedObject()
        XCTAssertFalse(obj.keys.contains("calendarEventId"))
    }

    func testCalendarEventIdRidesTheManifestWhenTheRecordingCameFromAPrompt() throws {
        var m = manifest()
        m.calendarEventId = "AAMkADRlYzk="
        let data = try FlowClient.encodeManifest(m)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["calendarEventId"] as? String, "AAMkADRlYzk=")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(MeetingManifest.self, from: data).calendarEventId, "AAMkADRlYzk=")
    }

    func testManifestRoundTripsThroughItsOwnDecoder() throws {
        let data = try FlowClient.encodeManifest(manifest())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(MeetingManifest.self, from: data)
        XCTAssertEqual(back.title, "Nathan 1:1")
        XCTAssertEqual(back.speakers.count, 2)
        XCTAssertEqual(back.speakers[1].sampleFile, "speaker-S2.m4a")
        XCTAssertNil(back.speakers[1].name)
        XCTAssertEqual(back.trackBOffsetSeconds, 1.05, accuracy: 1e-9)
    }
}

final class FlowClientWiringTests: XCTestCase {
    func testServerBaseDefaultsToProductionAndStripsTrailingSlash() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: FlowClient.serverDefaultsKey)
        defer {
            if let saved { defaults.set(saved, forKey: FlowClient.serverDefaultsKey) }
            else { defaults.removeObject(forKey: FlowClient.serverDefaultsKey) }
        }
        defaults.removeObject(forKey: FlowClient.serverDefaultsKey)
        XCTAssertEqual(FlowClient().serverBase, "https://flow.vervefitness.ai")
        defaults.set("http://127.0.0.1:8788/", forKey: FlowClient.serverDefaultsKey)
        XCTAssertEqual(FlowClient().serverBase, "http://127.0.0.1:8788")
    }

    func testContentTypeByFileName() {
        XCTAssertEqual(FlowClient.contentType(forFileName: "track-a.m4a"), "audio/mp4")
        XCTAssertEqual(FlowClient.contentType(forFileName: "speaker-S2.m4a"), "audio/mp4")
        XCTAssertEqual(FlowClient.contentType(forFileName: "transcript.json"), "application/json")
        XCTAssertEqual(FlowClient.contentType(forFileName: "meeting.json"), "application/json")
    }

    /// A 401 must never be retried: three goes at a revoked token is three
    /// times the noise in the Flow logs and the same answer.
    func testOnlyTransientFailuresAreRetried() {
        XCTAssertFalse(FlowError.unauthorised.isRetryable)
        XCTAssertFalse(FlowError.notConnected.isRetryable)
        XCTAssertFalse(FlowError.tooLarge("track-a.m4a", 400_000_000).isRetryable)
        XCTAssertFalse(FlowError.http(400, "bad name").isRetryable)
        XCTAssertTrue(FlowError.http(500, "").isRetryable)
        XCTAssertTrue(FlowError.http(429, "").isRetryable)
        XCTAssertTrue(FlowError.transport("offline").isRetryable)
    }

    func testMeDecodesTheServerShape() throws {
        let json = """
        {"email":"niall.wogan@vervefitness.com.au","name":"Niall Wogan","recognise_me":true,
         "profiles":[{"email":"nathan.hall@vervefitness.com.au","name":"Nathan Hall","embedding":[0.1,0.2]}],
         "staff":[{"email":"giuseppe.tappi@vervefitness.com.au","name":"Giuseppe Tappi"}]}
        """
        let me = try JSONDecoder().decode(FlowMe.self, from: Data(json.utf8))
        XCTAssertTrue(me.recogniseMe)
        XCTAssertEqual(me.profiles.first?.name, "Nathan Hall")
        XCTAssertEqual(me.profiles.first?.embedding, [0.1, 0.2])
        XCTAssertEqual(me.staff.first?.email, "giuseppe.tappi@vervefitness.com.au")
    }

    func testCompleteAndStatusDecodeSnakeCaseSpeakerNames() throws {
        let complete = """
        {"ok":true,"status":"summarised","speaker_names":{"A":"Niall Wogan","S1":"Nathan Hall"},
         "summary":{"summary":"S","decisions":["D"],"actions":[{"text":"A1","owner":"Nathan Hall","due":"2026-09-09","action_id":42}],"catch_up":"C"}}
        """
        let r = try JSONDecoder().decode(FlowCompleteResponse.self, from: Data(complete.utf8))
        XCTAssertEqual(r.status, "summarised")
        XCTAssertEqual(r.speakerNames["S1"], "Nathan Hall")
        XCTAssertEqual(r.summary?.actions.first?.owner, "Nathan Hall")
        XCTAssertEqual(r.summary?.catchUp, "C")

        let pending = try JSONDecoder().decode(FlowRecordingStatus.self, from: Data(#"{"status":"uploaded","speaker_names":{}}"#.utf8))
        XCTAssertEqual(pending.status, "uploaded")
        XCTAssertNil(pending.summary)
    }
}

final class FlowConnectURLTests: XCTestCase {
    func testParsesTokenAndServer() throws {
        let url = URL(string: "whisperflow://connect?token=abc123&server=https%3A%2F%2Fflow.vervefitness.ai")!
        let connect = try XCTUnwrap(FlowConnectURL.parse(url))
        XCTAssertEqual(connect.token, "abc123")
        XCTAssertEqual(connect.server, "https://flow.vervefitness.ai")
    }

    func testMissingServerMeansProduction() throws {
        let connect = try XCTUnwrap(FlowConnectURL.parse(URL(string: "whisperflow://connect?token=abc123")!))
        XCTAssertNil(connect.server)
    }

    func testAcceptsTheSlashedFormAndTrimsATrailingSlash() throws {
        let url = URL(string: "whisperflow:///connect?token=abc&server=http://127.0.0.1:8788/")!
        let connect = try XCTUnwrap(FlowConnectURL.parse(url))
        XCTAssertEqual(connect.token, "abc")
        XCTAssertEqual(connect.server, "http://127.0.0.1:8788")
    }

    /// A link that names a server we would not talk to is treated as if it
    /// named none, rather than pointing the app at something odd.
    func testNonHTTPServerIsIgnored() throws {
        let url = URL(string: "whisperflow://connect?token=abc&server=file:///etc")!
        XCTAssertNil(try XCTUnwrap(FlowConnectURL.parse(url)).server)
    }

    func testRejectsWrongSchemeWrongActionAndEmptyToken() {
        XCTAssertNil(FlowConnectURL.parse(URL(string: "https://connect?token=abc")!))
        XCTAssertNil(FlowConnectURL.parse(URL(string: "whisperflow://something-else?token=abc")!))
        XCTAssertNil(FlowConnectURL.parse(URL(string: "whisperflow://connect?token=")!))
        XCTAssertNil(FlowConnectURL.parse(URL(string: "whisperflow://connect")!))
    }

    /// Nothing that reaches stderr may carry the token.
    func testRedactionHidesTheToken() {
        let url = URL(string: "whisperflow://connect?token=super-secret&server=https://flow.vervefitness.ai")!
        let line = FlowConnectURL.redacted(url)
        XCTAssertFalse(line.contains("super-secret"))
        XCTAssertTrue(line.contains("token=(hidden)"))
        XCTAssertTrue(line.contains("https://flow.vervefitness.ai"))
    }
}
