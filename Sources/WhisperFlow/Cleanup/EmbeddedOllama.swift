import Foundation

/// Owns a private, app-managed `ollama serve` child process so WhisperFlow
/// doesn't depend on a separately-registered background service (a Homebrew
/// launchd service, a manually-run `ollama serve`, etc.) to get local LLM
/// cleanup. The binary is bundled inside the app itself; WhisperFlow starts
/// and stops it as part of its own lifecycle, the same way it owns
/// AudioCapture's start/stop rather than depending on some other process
/// having the microphone open.
///
/// Listens on a dedicated port -- NOT Ollama's default 11434 -- so there's
/// never ambiguity about which server OllamaCleanup is actually talking to
/// if some other Ollama install happens to exist on the machine.
///
/// Deliberately does NOT bundle the model itself: models are multi-GB, and
/// this app's source lives in a OneDrive-synced folder -- shipping a 2GB
/// blob inside the built .app (which make-app.sh assembles inside that same
/// folder) would make every rebuild a multi-GB sync. Instead this points
/// OLLAMA_MODELS at whatever model store already exists on the machine
/// (Homebrew's `~/.ollama/models`), reusing it in place.
enum EmbeddedOllama {
    static let port = 11535
    static var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private static var process: Process?
    private static let readinessCheckTimeout: TimeInterval = 1.0
    private static let terminationGracePeriod: TimeInterval = 3.0

    /// Path to the ollama binary bundled inside the app. Falls back to a
    /// Homebrew install for dev builds run via `swift build`/`swift run`,
    /// which execute outside any .app bundle and so have no Resources dir.
    private static var binaryURL: URL? {
        if let bundled = Bundle.main.url(forResource: "ollama", withExtension: nil, subdirectory: "ollama-bin") {
            return bundled
        }
        let devFallback = "/opt/homebrew/bin/ollama"
        return FileManager.default.isExecutableFile(atPath: devFallback) ? URL(fileURLWithPath: devFallback) : nil
    }

    /// Existing Ollama model store, reused in place rather than duplicated
    /// (see type doc comment).
    private static var modelsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ollama/models")
    }

    private static var logURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperFlow", isDirectory: true)
            .appendingPathComponent("ollama.log")
    }

    /// Call once at app launch. No-ops (logs and returns) if no binary or no
    /// model store can be found, or if something is already answering on the
    /// port -- CleanupRouter already degrades gracefully to Foundation
    /// Models or Passthrough when Ollama is unavailable, so none of this is
    /// ever fatal to dictation itself.
    static func start() {
        guard process == nil else { return }

        Task.detached(priority: .utility) {
            if await isAlreadyListening() {
                FileHandle.standardError.write(Data("[ollama] something is already serving on 127.0.0.1:\(port); reusing it instead of spawning a duplicate\n".utf8))
                return
            }
            await MainActor.run { spawn() }
        }
    }

    @MainActor
    private static func spawn() {
        guard process == nil else { return }
        guard let binary = binaryURL else {
            FileHandle.standardError.write(Data("[ollama] no bundled or Homebrew binary found; cleanup will use Foundation Models or passthrough\n".utf8))
            return
        }
        guard FileManager.default.fileExists(atPath: modelsDirectory.path) else {
            FileHandle.standardError.write(Data("[ollama] no model store at \(modelsDirectory.path); cleanup will use Foundation Models or passthrough\n".utf8))
            return
        }

        let task = Process()
        task.executableURL = binary
        task.arguments = ["serve"]
        task.environment = ProcessInfo.processInfo.environment.merging([
            "OLLAMA_HOST": "127.0.0.1:\(port)",
            "OLLAMA_MODELS": modelsDirectory.path,
        ]) { _, new in new }

        let log = logURL
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        if let handle = FileHandle(forWritingAtPath: log.path) {
            handle.seekToEndOfFile()
            task.standardOutput = handle
            task.standardError = handle
        }

        task.terminationHandler = { proc in
            FileHandle.standardError.write(Data("[ollama] embedded server exited (status \(proc.terminationStatus))\n".utf8))
        }

        do {
            try task.run()
            process = task
            FileHandle.standardError.write(Data("[ollama] embedded server started, pid \(task.processIdentifier), port \(port), models \(modelsDirectory.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("[ollama] failed to launch embedded server: \(error)\n".utf8))
        }
    }

    /// Call once at app termination. Sends SIGTERM and gives the process a
    /// moment to shut down cleanly (it's a real server closing sockets, not
    /// just a leaf process) before force-killing -- this is what keeps quit
    /// from ever leaving an orphaned ollama process behind.
    static func stop() {
        guard let task = process, task.isRunning else { return }
        task.terminate()
        let deadline = Date().addingTimeInterval(terminationGracePeriod)
        while task.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if task.isRunning {
            kill(task.processIdentifier, SIGKILL)
        }
        process = nil
    }

    private static func isAlreadyListening() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = readinessCheckTimeout
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
