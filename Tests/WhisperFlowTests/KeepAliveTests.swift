import XCTest
@testable import WhisperFlow

/// The first dictation after half an hour idle took 3.3 to 3.7 seconds against
/// a warm p50 of 857 ms, every time, because keep_alive was "30m" and the
/// model had been unloaded. Holding it resident is the fix on a Mac with the
/// memory to spare, and a bad idea on one without.
final class KeepAliveTests: XCTestCase {
    private let gib: UInt64 = 1024 * 1024 * 1024

    func testLargeMemoryMacsNeverUnloadTheModel() {
        // The JSON NUMBER -1, not the string "-1": Ollama parses a keep_alive
        // string as a Go duration and answers
        // `time: missing unit in duration "-1"`, i.e. the request fails.
        XCTAssertEqual(EmbeddedOllama.keepAlive(physicalMemory: 48 * gib) as? Int, -1)
        XCTAssertEqual(EmbeddedOllama.keepAlive(physicalMemory: 16 * gib) as? Int, -1)
        XCTAssertEqual(EmbeddedOllama.keepAlive(physicalMemory: 128 * gib) as? Int, -1)
        XCTAssertNil(EmbeddedOllama.keepAlive(physicalMemory: 48 * gib) as? String,
                     "a keep_alive string of \"-1\" is rejected by Ollama")
    }

    func testSmallMemoryMacsKeepTheThirtyMinutePolicy() {
        // An 8 GB M1 cannot afford 2.5 GB pinned for a menu bar app, so it
        // keeps the old policy and relies on the idle re-warm instead.
        XCTAssertEqual(EmbeddedOllama.keepAlive(physicalMemory: 8 * gib) as? String, "30m")
        XCTAssertEqual(EmbeddedOllama.keepAlive(physicalMemory: 0) as? String, "30m")
    }

    func testTheBoundaryIsSixteenGibExactly() {
        XCTAssertEqual(EmbeddedOllama.keepAlive(physicalMemory: 16 * gib - 1) as? String, "30m")
        XCTAssertEqual(EmbeddedOllama.keepAlive(physicalMemory: 16 * gib) as? Int, -1)
    }

    func testTheRequestBodyIsSerialisable() {
        // A keep_alive value JSONSerialization refuses would throw at the
        // call site and take cleanup down with it.
        for memory in [8 * gib, 48 * gib] {
            let body: [String: Any] = ["model": "llama3.2:3b",
                                       "keep_alive": EmbeddedOllama.keepAlive(physicalMemory: memory),
                                       "options": EmbeddedOllama.requestOptions]
            XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
            XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
        }
    }

    func testRewarmOnlyMattersWhereTheModelCanBeUnloaded() {
        // The re-warm loop exists for the "30m" case; on a never-unload Mac
        // there is nothing to re-warm and it must not run.
        XCTAssertEqual(EmbeddedOllama.keepAlive(physicalMemory: 8 * gib) as? String, "30m")
        XCTAssertLessThan(EmbeddedOllama.rewarmInterval, 30 * 60,
                          "the re-warm has to land before the 30 minute keep_alive expires")
    }

    /// The warm-up and every chat request must send the same context size, or
    /// Ollama treats them as different loads and reloads the model per
    /// dictation -- which is the exact cost this change exists to remove.
    func testContextIsRoomyForThePromptWithoutAllocatingThirtyTwoK() {
        XCTAssertEqual(EmbeddedOllama.numCtx, 4096)
        XCTAssertEqual(EmbeddedOllama.requestOptions["num_ctx"] as? Int, EmbeddedOllama.numCtx)
        XCTAssertEqual(EmbeddedOllama.requestOptions["temperature"] as? Int, 0)
    }
}
