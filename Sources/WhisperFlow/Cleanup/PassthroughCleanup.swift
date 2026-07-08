import Foundation

/// No-op cleanup: returns the raw transcript unchanged. Always available.
struct PassthroughCleanup: CleanupBackend {
    let name = "passthrough"

    func isAvailable() async -> Bool { true }

    func clean(_ raw: String, dictionary: [String], context: String?) async throws -> String { raw }
}
