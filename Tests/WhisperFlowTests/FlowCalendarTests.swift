import XCTest
@testable import WhisperFlow

/// Answers canned HTTP for the two week 3 endpoints, so the client is tested
/// against the contract in the plan while the Flow functions are still being
/// written. Nothing here reaches the network.
final class StubURLProtocol: URLProtocol {
    struct Reply {
        var status: Int
        var body: Data
        var error: Error?
    }

    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private(set) static var seenRequests: [URLRequest] = []
    /// URLSession moves a request's httpBody into httpBodyStream by the time
    /// a URLProtocol sees it, so the body of the last request is read off the
    /// stream here rather than left for the test to dig out.
    nonisolated(unsafe) private(set) static var lastBody: Data?
    private static let lock = NSLock()

    /// `pathAndQuery` is matched exactly, e.g. "/api/public/whisper/bots?active=1".
    static func stub(_ pathAndQuery: String, status: Int = 200, json: String) {
        lock.lock(); defer { lock.unlock() }
        replies[pathAndQuery] = Reply(status: status, body: Data(json.utf8), error: nil)
    }

    static func stub(_ pathAndQuery: String, error: Error) {
        lock.lock(); defer { lock.unlock() }
        replies[pathAndQuery] = Reply(status: 0, body: Data(), error: error)
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        replies = [:]
        seenRequests = []
        lastBody = nil
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static func key(for request: URLRequest) -> String {
        guard let url = request.url else { return "" }
        let query = url.query.map { "?" + $0 } ?? ""
        return url.path + query
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? Self.readStream(request.httpBodyStream)
        Self.lock.lock()
        Self.seenRequests.append(request)
        if let body { Self.lastBody = body }
        let reply = Self.replies[Self.key(for: request)]
        Self.lock.unlock()

        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(contentsOf: buffer[0..<read])
        }
        return data.isEmpty ? nil : data
    }
}

/// The client half of the week 3 contract: the two GETs, their headers, and
/// the snake_case shapes the plan spells out.
final class FlowUpcomingAndBotsTests: XCTestCase {
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

    func testUpcomingDecodesTheContractShape() async throws {
        StubURLProtocol.stub("/api/public/whisper/upcoming", json: """
        {"bot_mode":"declined","events":[
          {"id":"AAMkAD","subject":"Nathan 1:1","start":"2026-09-05T04:32:10Z","end":"2026-09-05T05:00:00Z",
           "is_online":true,"join_url":"https://teams.microsoft.com/l/meetup-join/x",
           "attendees":["Nathan Hall","Giuseppe Tappi"],"organizer":"Niall Wogan","response":"organizer",
           "bot":{"id":"bot-1","status":"scheduled"}},
          {"id":"AAMkAE","subject":"Showroom walkthrough","start":"2026-09-05T06:00:00.500Z",
           "is_online":false,"join_url":null,"attendees":["Ella Xie"],"organizer":"Ella Xie",
           "response":"accepted","bot":null}]}
        """)
        let upcoming = try await client().upcoming()
        XCTAssertEqual(upcoming.botMode, "declined")
        XCTAssertEqual(upcoming.events.count, 2)

        let first = upcoming.events[0]
        XCTAssertEqual(first.id, "AAMkAD")
        XCTAssertEqual(first.subject, "Nathan 1:1")
        XCTAssertEqual(first.start, ISO8601DateFormatter().date(from: "2026-09-05T04:32:10Z"))
        XCTAssertTrue(first.isOnline)
        XCTAssertEqual(first.joinURL, "https://teams.microsoft.com/l/meetup-join/x")
        XCTAssertEqual(first.attendees, ["Nathan Hall", "Giuseppe Tappi"])
        XCTAssertEqual(first.bot?.status, "scheduled")

        // Fractional seconds, a null join url and a null bot all have to read.
        let second = upcoming.events[1]
        XCTAssertNil(second.bot)
        XCTAssertNil(second.joinURL)
        XCTAssertFalse(second.isOnline)
        XCTAssertEqual(second.start.timeIntervalSince1970,
                       ISO8601DateFormatter().date(from: "2026-09-05T06:00:00Z")!.timeIntervalSince1970 + 0.5,
                       accuracy: 0.01)
    }

    func testUpcomingSendsTheDeviceHeaders() async throws {
        StubURLProtocol.stub("/api/public/whisper/upcoming", json: #"{"bot_mode":"off","events":[]}"#)
        _ = try await client().upcoming()
        let request = try XCTUnwrap(StubURLProtocol.seenRequests.last)
        XCTAssertEqual(request.url?.absoluteString, "https://flow.test/api/public/whisper/upcoming")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-WhisperFlow-Version"))
    }

    func testActiveBotsDecodesAndKeepsTheQueryString() async throws {
        StubURLProtocol.stub("/api/public/whisper/bots?active=1", json: """
        {"bots":[{"id":"bot-1","title":"Nathan 1:1","meeting_url":"https://teams.microsoft.com/l/meetup-join/x",
                  "starts_at":"2026-09-05T04:30:00Z","status":"in_call","calendar_event_id":"AAMkAD"}]}
        """)
        let bots = try await client().activeBots()
        XCTAssertEqual(bots.count, 1)
        XCTAssertEqual(bots[0].id, "bot-1")
        XCTAssertEqual(bots[0].title, "Nathan 1:1")
        XCTAssertEqual(bots[0].status, "in_call")
        XCTAssertEqual(bots[0].calendarEventId, "AAMkAD")
        XCTAssertEqual(bots[0].startsAt, ISO8601DateFormatter().date(from: "2026-09-05T04:30:00Z"))
        XCTAssertEqual(StubURLProtocol.seenRequests.last?.url?.query, "active=1")
    }

    func testEmptyBotListReads() async throws {
        StubURLProtocol.stub("/api/public/whisper/bots?active=1", json: #"{"bots":[]}"#)
        let bots = try await client().activeBots()
        XCTAssertTrue(bots.isEmpty)
    }

    /// A 401 on either poll is an error the caller swallows, not a retry
    /// storm: the record path proceeds as it did before bots existed.
    func testUnauthorisedIsNotRetried() async {
        StubURLProtocol.stub("/api/public/whisper/bots?active=1", status: 401, json: #"{"error":"unauthorised"}"#)
        do {
            _ = try await client().activeBots()
            XCTFail("expected the call to throw")
        } catch {
            XCTAssertEqual(error as? FlowError, .unauthorised)
        }
        XCTAssertEqual(StubURLProtocol.seenRequests.count, 1)
    }

    /// A 500 would normally be retried three times. These two polls take one
    /// attempt each, because both sit in front of something the person is
    /// waiting on.
    func testServerErrorIsNotRetriedOnThesePolls() async {
        StubURLProtocol.stub("/api/public/whisper/upcoming", status: 500, json: "")
        do {
            _ = try await client().upcoming()
            XCTFail("expected the call to throw")
        } catch {
            XCTAssertFalse(StubURLProtocol.seenRequests.isEmpty)
        }
        XCTAssertEqual(StubURLProtocol.seenRequests.count, 1)
    }

    func testISO8601ParsingAcceptsBothShapes() {
        XCTAssertNotNil(FlowClient.parseISO8601("2026-09-05T04:32:10Z"))
        XCTAssertNotNil(FlowClient.parseISO8601("2026-09-05T04:32:10.250Z"))
        XCTAssertNotNil(FlowClient.parseISO8601("2026-09-05T04:32:10+00:00"))
        XCTAssertNil(FlowClient.parseISO8601("not a date"))
    }
}
