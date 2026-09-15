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
/// The model itself is NOT bundled (multi-GB, and this repo syncs through
/// OneDrive). Instead, on every launch this checks whether the cleanup model
/// is present in `~/.ollama/models` and, if not, pulls it through the
/// embedded server's own API, reporting progress to the menu bar. The
/// previous version refused to even start the server when that directory
/// didn't exist -- which is the state of every colleague's Mac on first
/// install -- so the documented Terminal `ollama pull` step failed with
/// "could not connect" and cleanup silently ran as passthrough forever.
enum EmbeddedOllama {
    static let port = 11535
    static var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    /// Kept in one place: OllamaCleanup checks for this same name.
    static let model = "llama3.2:3b"

    /// How long Ollama keeps the model resident after a request.
    ///
    /// The first dictation after half an hour idle took 3.3 to 3.7 seconds,
    /// every time, against a warm p50 of 857 ms -- ollama.log shows the model
    /// being unloaded and reloaded five to eight times a day, and the reload
    /// is the whole difference. "-1" means never unload. llama3.2:3b at a
    /// 4096-token context is about 2.5 GB resident, which is a sensible thing
    /// to hold on a 16 GB Mac and not on an 8 GB one, so small-memory Macs
    /// keep the old 30-minute policy and lean on the idle re-warm below
    /// instead.
    /// Returns the value to put in the request body, which is deliberately
    /// NOT always a string: Ollama parses a keep_alive STRING as a Go
    /// duration, so "-1" comes back as
    /// `time: missing unit in duration "-1"` and the request fails outright.
    /// The never-unload form has to be the JSON NUMBER -1. Verified against
    /// the running server on 127.0.0.1:11535.
    static func keepAlive(physicalMemory: UInt64) -> Any {
        physicalMemory >= 16 * 1024 * 1024 * 1024 ? -1 : "30m"
    }

    /// This Mac's policy. Used by the warm-up AND by every chat request --
    /// they must agree, or each one resets the other's timer.
    static var keepAlive: Any { keepAlive(physicalMemory: ProcessInfo.processInfo.physicalMemory) }

    /// True when this Mac holds the model resident and the idle re-warm below
    /// has nothing to do.
    static var neverUnloads: Bool { keepAlive as? Int == -1 }

    /// Context window for every request, warm-up included.
    ///
    /// The default 32k context made llama-server allocate 3.5 GB of KV cache
    /// ("context 3584 MiB" in ollama.log) and dominated the cold-load time.
    /// Our prompt is about 1,100 tokens including the few-shot examples, so
    /// 4096 is roomy. It MUST be identical everywhere: Ollama keys a loaded
    /// model on its options, so a warm-up at one context and a request at
    /// another reloads the model on every single dictation.
    static let numCtx = 4096

    /// Options block every request sends. Same object, same values, one place.
    static var requestOptions: [String: Any] { ["temperature": 0, "num_ctx": numCtx] }

    /// How often a small-memory Mac re-warms the model so the 30-minute
    /// keep_alive never actually expires while the app is running.
    static let rewarmInterval: TimeInterval = 20 * 60

    /// Human-readable state of the local LLM for the menu bar status line.
    enum Status: Equatable {
        case notStarted
        case starting
        case checkingModel
        case downloadingModel(fraction: Double)
        case ready
        case unavailable(String)

        var label: String {
            switch self {
            case .notStarted: return "not started"
            case .starting: return "starting…"
            case .checkingModel: return "checking language model…"
            case .downloadingModel(let f): return "downloading language model \(Int((f * 100).rounded()))%"
            case .ready: return "ready"
            case .unavailable(let why): return "unavailable (\(why))"
            }
        }
    }

    private static var process: Process?
    private static var rewarmTask: Task<Void, Never>?
    private static let readinessCheckTimeout: TimeInterval = 1.0
    private static let startupWait: TimeInterval = 20.0
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

    /// Model store, shared with any Homebrew/desktop Ollama on the machine so
    /// a model that's already there is reused instead of downloaded twice.
    private static var modelsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ollama/models")
    }

    private static var logURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperFlow", isDirectory: true)
            .appendingPathComponent("ollama.log")
    }

    /// Call once at app launch. Starts the server (or reuses one already on
    /// the port), then makes sure the cleanup model is present, pulling it if
    /// not. `onStatus` is called on the main actor as things progress;
    /// CleanupRouter already degrades gracefully to Foundation Models or
    /// Passthrough while this is still in flight, so none of it is ever
    /// fatal to dictation itself.
    static func start(onStatus: @escaping @MainActor (Status) -> Void) {
        guard process == nil else { return }

        Task.detached(priority: .utility) {
            await MainActor.run { onStatus(.starting) }
            if await isAlreadyListening() {
                FileHandle.standardError.write(Data("[ollama] something is already serving on 127.0.0.1:\(port); reusing it instead of spawning a duplicate\n".utf8))
            } else {
                let spawned = await MainActor.run { spawn() }
                if let failure = spawned {
                    await MainActor.run { onStatus(.unavailable(failure)) }
                    return
                }
                // Give the server time to bind. Bluetooth-poor M1s under
                // memory pressure at login can take several seconds here.
                let deadline = Date().addingTimeInterval(startupWait)
                while Date() < deadline, !(await isAlreadyListening()) {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                guard await isAlreadyListening() else {
                    await MainActor.run { onStatus(.unavailable("server did not start")) }
                    return
                }
            }

            await MainActor.run { onStatus(.checkingModel) }
            if await hasModel() {
                await MainActor.run { onStatus(.ready) }
                await warmUp()
                startIdleRewarm()
                return
            }
            FileHandle.standardError.write(Data("[ollama] model \(model) not present; pulling\n".utf8))
            do {
                try await pullModel { fraction in
                    Task { @MainActor in onStatus(.downloadingModel(fraction: fraction)) }
                }
                let present = await hasModel()
                await MainActor.run { onStatus(present ? .ready : .unavailable("model pull finished but model still missing")) }
                if present {
                    await warmUp()
                    startIdleRewarm()
                }
            } catch {
                FileHandle.standardError.write(Data("[ollama] model pull failed: \(error)\n".utf8))
                await MainActor.run { onStatus(.unavailable("model download failed")) }
            }
        }
    }

    /// Returns nil on success, or a short reason on failure.
    @MainActor
    private static func spawn() -> String? {
        guard process == nil else { return nil }
        guard let binary = binaryURL else {
            FileHandle.standardError.write(Data("[ollama] no bundled or Homebrew binary found; cleanup will use Foundation Models or passthrough\n".utf8))
            return "no ollama binary in app"
        }
        // First launch on a fresh Mac: the store doesn't exist yet. Create
        // it -- `ollama serve` would too, but being explicit means the
        // failure mode (no permission to write in the home dir) surfaces
        // here with a message instead of as a mystery exit code below.
        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("[ollama] could not create model store at \(modelsDirectory.path): \(error)\n".utf8))
            return "cannot create ~/.ollama/models"
        }

        let task = Process()
        task.executableURL = binary
        task.arguments = ["serve"]
        task.environment = ProcessInfo.processInfo.environment.merging([
            "OLLAMA_HOST": "127.0.0.1:\(port)",
            "OLLAMA_MODELS": modelsDirectory.path,
            // Cleanup is a single short request at a time; one loaded model
            // and one parallel slot keeps the footprint sane on 8GB M1s.
            "OLLAMA_MAX_LOADED_MODELS": "1",
            "OLLAMA_NUM_PARALLEL": "1",
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
            return nil
        } catch {
            FileHandle.standardError.write(Data("[ollama] failed to launch embedded server: \(error)\n".utf8))
            return "could not launch server"
        }
    }

    /// Call once at app termination. Sends SIGTERM and gives the process a
    /// moment to shut down cleanly (it's a real server closing sockets, not
    /// just a leaf process) before force-killing -- this is what keeps quit
    /// from ever leaving an orphaned ollama process behind.
    static func stop() {
        rewarmTask?.cancel()
        rewarmTask = nil
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

    /// Load the model into memory now (an empty generate with keep_alive)
    /// so the FIRST dictation of the session isn't the one that pays the
    /// several-second weights-from-disk cost and trips the cleanup timeout.
    private static func warmUp() async {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "keep_alive": keepAlive,
            "options": requestOptions,
        ])
        let t0 = Date()
        if let (_, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200 {
            FileHandle.standardError.write(Data("[ollama] model warmed in \(Int(Date().timeIntervalSince(t0) * 1000)) ms\n".utf8))
        } else {
            FileHandle.standardError.write(Data("[ollama] warm-up request failed (non-fatal)\n".utf8))
        }
    }

    /// On a Mac too small to pin the model in memory, touch it every twenty
    /// minutes so the thirty-minute keep_alive never actually expires while
    /// the app is running. Cheap (an empty generate against an already-loaded
    /// model returns in milliseconds) and it is the whole 3.5-second
    /// first-dictation-of-the-afternoon penalty.
    private static func startIdleRewarm() {
        guard !neverUnloads, rewarmTask == nil else { return }
        rewarmTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(rewarmInterval) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await warmUp()
            }
        }
    }

    private static func isAlreadyListening() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = readinessCheckTimeout
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    static func hasModel() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else { return false }
        let names = models.compactMap { $0["name"] as? String }
        return names.contains { $0 == model || $0.hasPrefix(model) }
    }

    /// `POST /api/pull` with streaming NDJSON progress. Each line carries
    /// `status` and, during the blob download, `total`/`completed` bytes.
    private static func pullModel(onProgress: @escaping @Sendable (Double) -> Void) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A 2GB download on a slow connection can take a long time; the
        // per-line reads below keep the connection alive, this is just the
        // idle cap.
        request.timeoutInterval = 600
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": model, "stream": true])

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CleanupError.badResponse("pull HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        // Progress arrives per blob (one ~2 GB weights file plus a handful of
        // KB-sized manifests). Reporting each blob's own fraction made the
        // menu run 98% -> 4% -> 100% at the end; aggregate across blobs.
        var perBlob: [String: (completed: Double, total: Double)] = [:]
        var lastReported = -1
        for try await line in bytes.lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let err = obj["error"] as? String {
                throw CleanupError.badResponse("pull error: \(err)")
            }
            if let total = obj["total"] as? Double, total > 0 {
                let digest = obj["digest"] as? String ?? "?"
                perBlob[digest] = (obj["completed"] as? Double ?? 0, total)
                let sumTotal = perBlob.values.reduce(0) { $0 + $1.total }
                let sumDone = perBlob.values.reduce(0) { $0 + $1.completed }
                let fraction = min(1, max(0, sumDone / max(sumTotal, 1)))
                let pct = Int(fraction * 100)
                if pct != lastReported {
                    lastReported = pct
                    onProgress(fraction)
                }
            }
            if let status = obj["status"] as? String, status == "success" {
                onProgress(1)
            }
        }
    }
}
