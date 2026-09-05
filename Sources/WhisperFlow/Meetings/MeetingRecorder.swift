import Foundation
import Combine

/// Runs the two captures for one meeting and writes them to the meeting's
/// folder. Track A = the owner's microphone (its own AudioCapture, so
/// dictation keeps working during a meeting). Track B = the Mac's system
/// audio (the other side of the call). Either capture may be missing: a Mac
/// on macOS 14.0/14.1 has no system tap, and tests have no hardware at all.
@MainActor
final class MeetingRecorder: ObservableObject {
    /// A capture is anything that yields 16 kHz mono chunks and can stop.
    struct CaptureHandle {
        let stream: AsyncStream<[Float]>
        let stop: () -> Void
    }
    struct Captures {
        let mic: CaptureHandle?
        let system: CaptureHandle?
        /// Seconds between the mic stream starting and the system tap
        /// starting. Measured, not assumed: the settle sleep is one second but
        /// `AudioCapture.start` and the HAL calls either side of it take their
        /// own time, and on a Bluetooth mic that can be seconds. Zero when
        /// there is no system capture.
        let systemStartOffset: Double

        init(mic: CaptureHandle?, system: CaptureHandle?, systemStartOffset: Double = 0) {
            self.mic = mic
            self.system = system
            self.systemStartOffset = system == nil ? 0 : systemStartOffset
        }
    }
    typealias CaptureFactory = @MainActor () async throws -> Captures

    @Published private(set) var record: MeetingRecord?
    @Published private(set) var elapsedSeconds: Double = 0
    @Published private(set) var lastError: String?

    var isRecording: Bool { record?.status == .recording }

    private let captureFactory: CaptureFactory
    private var captures: Captures?
    private var drainTasks: [Task<Double, Never>] = []
    private var ticker: Task<Void, Never>?
    private var startedAt: Date?

    init(captureFactory: CaptureFactory? = nil) {
        self.captureFactory = captureFactory ?? MeetingRecorder.liveCaptures
    }

    /// The real captures. Mic pinned per the saved microphone selection;
    /// system tap only where the OS has it.
    static let liveCaptures: CaptureFactory = {
        let mic = AudioCapture()
        let micStream = try await mic.start(selection: InputDeviceSelection.saved)
        // Track A's t=0. Measured here rather than assumed, because the tap is
        // deliberately started later and both WAVs begin at their own zero.
        let micStartedAt = DispatchTime.now()
        // Starting the tap posts AVAudioEngineConfigurationChange to the mic
        // engine; harmless once the mic is running, destructive while it is
        // still starting. Let it settle first (Task 1 report).
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        var system: CaptureHandle?
        var offset: Double = 0
        if #available(macOS 14.2, *) {
            let tap = SystemAudioTap()
            do {
                // SystemAudioTap.start() is synchronous: the HAL calls it
                // makes return immediately (unlike AVAudioEngine.start()).
                let s = try tap.start()
                // Track B's t=0: the tap zero-fills from this moment (Task 1b),
                // so the gap between the two starts is exactly what track B has
                // to be shifted by to sit on track A's timeline.
                offset = Double(DispatchTime.now().uptimeNanoseconds - micStartedAt.uptimeNanoseconds) / 1_000_000_000
                system = CaptureHandle(stream: s, stop: { tap.stop() })
            } catch {
                FileHandle.standardError.write(Data("[meeting] system audio unavailable, recording microphone only: \(error.localizedDescription)\n".utf8))
            }
        } else {
            FileHandle.standardError.write(Data("[meeting] system audio needs macOS 14.2; recording microphone only\n".utf8))
        }
        return Captures(mic: CaptureHandle(stream: micStream, stop: { mic.stop() }),
                        system: system,
                        systemStartOffset: offset)
    }

    func start(title: String, attendees: [String], consent: MeetingConsent) async throws -> MeetingRecord {
        guard !isRecording else { throw MeetingError.alreadyRecording }
        let now = Date()
        var rec = MeetingRecord(id: MeetingStore.newMeetingID(at: now), startedAt: now, endedAt: nil,
                                title: title, attendees: attendees, consent: consent, status: .recording,
                                failureReason: nil, trackASeconds: 0, trackBSeconds: 0,
                                trackBOffsetSeconds: 0, speakerNames: [:])
        try MeetingStore.save(rec)
        // Both WAVs always exist, even if a capture is missing, so the
        // transcriber never has to special-case an absent file.
        let writerA = try TrackWriter(url: MeetingStore.trackAURL(rec.id))
        let writerB = try TrackWriter(url: MeetingStore.trackBURL(rec.id))

        let caps = try await captureFactory()
        captures = caps
        rec.trackBOffsetSeconds = caps.systemStartOffset
        try MeetingStore.save(rec)
        drainTasks = [drain(caps.mic, into: writerA, label: "A"), drain(caps.system, into: writerB, label: "B")]
        startedAt = now
        record = rec
        elapsedSeconds = 0
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsedSeconds = Date().timeIntervalSince(startedAt)
            }
        }
        FileHandle.standardError.write(Data("[meeting] recording \(rec.id) (system audio: \(caps.system != nil), track B starts \(String(format: "%.2f", rec.trackBOffsetSeconds))s after track A)\n".utf8))
        return rec
    }

    /// Drains one capture into one writer off the main actor; returns the
    /// seconds written. A missing capture closes its (empty) writer at once.
    private func drain(_ handle: CaptureHandle?, into writer: TrackWriter, label: String) -> Task<Double, Never> {
        Task.detached(priority: .userInitiated) {
            guard let handle else { writer.close(); return 0 }
            for await chunk in handle.stream {
                do { try writer.append(chunk) } catch {
                    FileHandle.standardError.write(Data("[meeting] track \(label) write failed: \(error.localizedDescription)\n".utf8))
                    break
                }
            }
            writer.close()
            return writer.seconds
        }
    }

    func stop() async -> MeetingRecord? {
        guard var rec = record, rec.status == .recording else { return record }
        ticker?.cancel(); ticker = nil
        captures?.mic?.stop()
        captures?.system?.stop()
        captures = nil
        let seconds = await drainTasks.asyncMap { await $0.value }
        drainTasks = []
        rec.endedAt = Date()
        rec.trackASeconds = seconds.count > 0 ? seconds[0] : 0
        rec.trackBSeconds = seconds.count > 1 ? seconds[1] : 0
        rec.status = .recorded
        do { try MeetingStore.save(rec) } catch { lastError = error.localizedDescription }
        record = rec
        FileHandle.standardError.write(Data("[meeting] stopped \(rec.id): A \(String(format: "%.1f", rec.trackASeconds))s, B \(String(format: "%.1f", rec.trackBSeconds))s\n".utf8))
        return rec
    }
}

enum MeetingError: Error, LocalizedError {
    case alreadyRecording
    case noTranscript
    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "A meeting is already being recorded"
        case .noTranscript: return "No transcript was produced"
        }
    }
}

extension Array {
    /// Sequential async map (order preserved). Used to await the drain tasks.
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var out: [T] = []
        out.reserveCapacity(count)
        for e in self { out.append(await transform(e)) }
        return out
    }
}
