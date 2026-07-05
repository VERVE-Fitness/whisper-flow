import Foundation
import SwiftUI

@main
enum MurmurMain {
    static func main() {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--transcribe-file") {
            guard idx + 1 < args.count else {
                FileHandle.standardError.write(Data("error: --transcribe-file requires a path argument\n".utf8))
                exit(2)
            }
            let path = args[idx + 1]
            let rawOnly = args.contains("--raw-only")
            let exitCode = runCLITranscription(path: path, rawOnly: rawOnly)
            exit(exitCode)
        }
        MurmurApp.main()
    }
}

struct MurmurApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("Murmur") {
            MainView()
                .environmentObject(state)
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - Headless CLI test mode

private func runCLITranscription(path: String, rawOnly: Bool) -> Int32 {
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0

    Task {
        do {
            let samples = try loadAudioFileAs16kMonoFloats(path: path)
            let audioSeconds = Double(samples.count) / AudioCapture.targetSampleRate

            let backend = ParakeetBackend()
            try await backend.prepare()

            let sttT0 = Date()
            let raw = try await backend.transcribeFile(samples: samples)
            let sttMs = Int(Date().timeIntervalSince(sttT0) * 1000)

            print("RAW: \(raw)")

            var cleanupMs = 0
            var backendName = "raw-only"
            var cleanedChars = raw.count
            if !rawOnly {
                let router = CleanupRouter()
                let result = await router.clean(raw)
                cleanupMs = result.durationMs
                backendName = result.backendName + (result.fellBackToRaw ? " (fallback-to-raw)" : "")
                cleanedChars = result.text.count
                print("CLEANED (\(backendName)): \(result.text)")
            }
            print("TIMING: stt=\(sttMs) cleanup=\(cleanupMs)")

            UsageLog.append(mode: "file",
                            audioSeconds: audioSeconds,
                            rawChars: raw.count,
                            cleanedChars: cleanedChars,
                            sttMs: sttMs,
                            cleanupMs: cleanupMs,
                            cleanupBackend: backendName)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exitCode = 1
        }
        semaphore.signal()
    }

    semaphore.wait()
    return exitCode
}
