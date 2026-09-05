import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import os

private let tapLog = Logger(subsystem: "com.niallwogan.whisperflow", category: "system-audio-tap")

/// Mirror of the important tap events to stderr, so `--tap-test` / `--dual-test`
/// and a Terminal launch show them without needing Console.app. Same `[capture]`
/// prefix family as `AudioCapture`, tagged so the two are separable when both
/// run at once (the meeting recorder's normal state).
private func tapNote(_ message: String) {
    FileHandle.standardError.write(Data("[capture] system-audio: \(message)\n".utf8))
}

/// Renders an OSStatus the way CoreAudio means it: most HAL errors are
/// four-char codes ('nope', '!obj', 'stop'), which are unreadable as the
/// signed integers Swift prints.
private func osStatusText(_ status: OSStatus) -> String {
    let bytes = [UInt8((status >> 24) & 0xff), UInt8((status >> 16) & 0xff),
                 UInt8((status >> 8) & 0xff), UInt8(status & 0xff)]
    let printable = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7f }
    guard printable, let code = String(bytes: bytes, encoding: .ascii) else { return "\(status)" }
    return "\(status) '\(code)'"
}

enum SystemAudioTapError: Error, LocalizedError {
    case unsupportedOS
    case tapCreationFailed(OSStatus)
    case tapFormatUnavailable(OSStatus)
    case unusableTapFormat(sampleRate: Double, channels: UInt32)
    case aggregateDeviceCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case converterCreationFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "System audio capture needs macOS 14.2 or later"
        case .tapCreationFailed(let status):
            return "AudioHardwareCreateProcessTap failed (OSStatus \(osStatusText(status))) -- macOS would not create a system-audio tap for this process"
        case .tapFormatUnavailable(let status):
            return "Could not read the tap's stream format, kAudioTapPropertyFormat failed (OSStatus \(osStatusText(status)))"
        case .unusableTapFormat(let rate, let channels):
            return "The system-audio tap reported an unusable format (\(Int(rate)) Hz, \(channels) ch)"
        case .aggregateDeviceCreationFailed(let status):
            return "AudioHardwareCreateAggregateDevice failed (OSStatus \(osStatusText(status)))"
        case .ioProcCreationFailed(let status):
            return "AudioDeviceCreateIOProcIDWithBlock failed (OSStatus \(osStatusText(status)))"
        case .deviceStartFailed(let status):
            return "AudioDeviceStart failed on the tap's aggregate device (OSStatus \(osStatusText(status)))"
        case .converterCreationFailed:
            return "Could not create audio converter from the system-audio tap format to 16 kHz mono"
        }
    }
}

/// Availability gate that callers can use without an `#available` block.
///
/// `SystemAudioTap` itself is `@available(macOS 14.2, *)` because CoreAudio's
/// process-tap API is, and the package's deployment target is macOS 14.0. A
/// caller on 14.0/14.1 therefore cannot even name the type, so the readable
/// "needs macOS 14.2 or later" error has to come from somewhere non-gated:
/// call `SystemAudioSupport.require()` in the `else` branch of your
/// `#available` check (or just read `isAvailable`).
enum SystemAudioSupport {
    static var isAvailable: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    static func require() throws {
        guard isAvailable else { throw SystemAudioTapError.unsupportedOS }
    }
}

/// Captures the Mac's SYSTEM OUTPUT audio (everything the Mac is playing: the
/// other side of a Teams/Zoom call, a YouTube tab, `say`) and delivers 16 kHz
/// mono Float32 chunks through an AsyncStream -- deliberately the same shape as
/// `AudioCapture.start()`, so the meeting recorder can consume the microphone
/// and the far side identically and mix or diarise them later.
///
/// Mechanism (CoreAudio process taps, macOS 14.2+, NOT ScreenCaptureKit):
///
/// 1. `CATapDescription(stereoGlobalTapButExcludeProcesses: [])` is a GLOBAL
///    tap: every process's output, with nothing excluded. `muteBehavior =
///    .unmuted` means the user keeps hearing the call while we record it.
/// 2. `AudioHardwareCreateProcessTap` turns that description into an
///    `AudioObjectID` we can read a stream format off.
/// 3. A PRIVATE aggregate device (visible only to this process, so we never
///    appear in the user's Sound settings) is created with the tap in its
///    `kAudioAggregateDeviceTapListKey`, `TapAutoStart` on. No sub-devices:
///    an output tap needs none, and adding one would make us an input device.
/// 4. `AudioDeviceCreateIOProcIDWithBlock` + `AudioDeviceStart` pull the
///    tapped audio; each callback is converted to 16 kHz mono and yielded.
///
/// Permission: this is a TCC-gated capability ("System Audio Recording Only",
/// System Settings > Privacy & Security > Screen & System Audio Recording),
/// declared by `NSAudioCaptureUsageDescription` in Info.plist. The failure
/// mode is nasty: a denied (or never-prompted, e.g. an unbundled CLI binary)
/// process still gets a tap, an aggregate device and a steady stream of
/// callbacks -- all of whose samples are exactly zero. `buffersDelivered`
/// climbing is therefore NOT proof of capture, so this class watches the first
/// `silenceWindow` seconds and says so on stderr when everything is digital
/// silence, instead of letting a caller ship a "successful" recording of
/// nothing.
///
/// Threading: the IOProc block runs on a CoreAudio-owned serial queue (see
/// `ioQueue`), start()/stop() run on the caller's thread/actor. Every field
/// touched by both goes through `stateLock`; the block captures its converter
/// and formats as constants so it never reads a field stop() may be clearing.
@available(macOS 14.2, *)
final class SystemAudioTap: @unchecked Sendable {
    static let targetSampleRate: Double = 16_000

    /// How long an all-zero start is tolerated before it is reported as a
    /// probable permission denial. Two seconds is long enough to survive the
    /// genuine silence at the top of a call ("...you there?") being brief, and
    /// short enough that `--tap-test 9` still shows the note in time to be
    /// useful.
    private static let silenceWindow: Double = 2.0

    private let tapName: String
    /// CoreAudio dispatches the IOProc on this queue rather than its own
    /// real-time IO thread, which keeps the AVAudioConverter allocation out of
    /// a real-time context. The buffer list stays valid for the duration of
    /// the block either way.
    private let ioQueue = DispatchQueue(label: "com.niallwogan.whisperflow.system-audio-tap")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<[Float]>.Continuation?

    private let stateLock = NSLock()
    // -- everything below is guarded by stateLock --
    private var _isRunning = false
    private var _capturedSeconds: Double = 0
    /// Seconds the tap actually delivered, EXCLUDING the zero-fill below.
    /// The missing-permission check has to use this: a call that opens with
    /// three seconds of real silence would otherwise be reported as a
    /// permission failure the moment the gap-fill crossed `silenceWindow`.
    private var _realAudioSeconds: Double = 0
    private var _gapSecondsFilled: Double = 0
    private var _buffersDelivered = 0
    private var _nonZeroSamples = 0
    private var _silenceReported = false
    private var _nativeSampleRate: Double = 0
    private var _nativeChannels: UInt32 = 0
    /// `mach_absolute_time()` at the moment `AudioDeviceStart` succeeded, so
    /// the first callback's `mHostTime` says how much silence preceded it.
    private var _startHostTime: UInt64 = 0
    /// Native-rate frame position the next callback is expected to begin at.
    /// Negative until the first callback arrives.
    private var _expectedNextSampleTime: Double = -1

    private func locked<T>(_ body: () -> T) -> T {
        stateLock.lock(); defer { stateLock.unlock() }
        return body()
    }

    /// Seconds of 16 kHz audio delivered so far in the current capture.
    var capturedSeconds: Double { locked { _capturedSeconds } }
    /// Total buffers delivered across the current capture (diagnostics, and
    /// the `--tap-test` / `--dual-test` CLI modes).
    var buffersDelivered: Int { locked { _buffersDelivered } }
    /// Seconds of digital silence this class synthesised to stand in for the
    /// stretches where the Mac played nothing and the HAL therefore called
    /// nobody. Diagnostics only: `capturedSeconds` already includes it.
    var gapSecondsFilled: Double { locked { _gapSecondsFilled } }
    /// True once at least one non-zero sample has arrived, i.e. the TCC
    /// permission is really granted and the Mac really is playing something.
    var hasRealAudio: Bool { locked { _nonZeroSamples > 0 } }
    /// The tap's own format before conversion, for diagnostics.
    var nativeSampleRate: Double { locked { _nativeSampleRate } }
    var nativeChannelCount: UInt32 { locked { _nativeChannels } }
    var nativeFormatDescription: String {
        let (rate, channels) = locked { (_nativeSampleRate, _nativeChannels) }
        guard rate > 0 else { return "unknown" }
        return "\(Int(rate)) Hz \(channels) ch"
    }
    var isRunning: Bool { locked { _isRunning } }

    init(name: String = "Whisper Flow meeting tap") {
        self.tapName = name
    }

    deinit {
        stop()
    }

    /// Start tapping system output. Returns a stream of 16 kHz mono Float32
    /// chunks; call `stop()` to tear the tap down and finish the stream.
    ///
    /// Not async: unlike `AVAudioEngine.start()` (which can block for seconds
    /// negotiating a Bluetooth profile), the HAL calls here are property
    /// reads and object creations that return immediately.
    func start() throws -> AsyncStream<[Float]> {
        // Defensive: a tap that was never stopped must not leak an aggregate
        // device into this one.
        if locked({ _isRunning }) { stop() }
        try SystemAudioSupport.require()

        locked {
            _capturedSeconds = 0
            _realAudioSeconds = 0
            _gapSecondsFilled = 0
            _buffersDelivered = 0
            _nonZeroSamples = 0
            _silenceReported = false
            _startHostTime = 0
            _expectedNextSampleTime = -1
        }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = tapName
        // .unmuted: record the call without muting it for the user. The other
        // behaviours (muted / mutedWhenTapped) silence the very audio the
        // meeting recorder exists to keep.
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapStatus == noErr, newTapID != AudioObjectID(kAudioObjectUnknown) else {
            throw SystemAudioTapError.tapCreationFailed(tapStatus)
        }
        tapID = newTapID

        let tapFormat: AVAudioFormat
        do {
            tapFormat = try Self.readFormat(of: newTapID)
        } catch {
            teardownCoreAudio()
            throw error
        }

        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: Self.targetSampleRate,
                                               channels: 1,
                                               interleaved: false),
              let converter = AVAudioConverter(from: tapFormat, to: targetFormat) else {
            teardownCoreAudio()
            throw SystemAudioTapError.converterCreationFailed
        }
        locked {
            _nativeSampleRate = tapFormat.sampleRate
            _nativeChannels = tapFormat.channelCount
        }

        // A private aggregate device never shows up in Sound settings or in
        // other apps' device lists, and dies with this process even if we
        // crash before stop().
        let aggregateUID = UUID().uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Whisper Flow System Audio",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString]
            ]
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary,
                                                                 &newAggregateID)
        guard aggregateStatus == noErr, newAggregateID != AudioObjectID(kAudioObjectUnknown) else {
            teardownCoreAudio()
            throw SystemAudioTapError.aggregateDeviceCreationFailed(aggregateStatus)
        }
        aggregateID = newAggregateID

        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self,
                                                            bufferingPolicy: .unbounded)
        self.continuation = continuation

        var newProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, newAggregateID, ioQueue) {
            [weak self] _, inInputData, inInputTime, _, _ in
            guard let self else { return }
            self.handle(inputData: inInputData,
                        inputTime: inInputTime,
                        tapFormat: tapFormat,
                        targetFormat: targetFormat,
                        converter: converter,
                        continuation: continuation)
        }
        guard procStatus == noErr, let newProcID else {
            continuation.finish()
            self.continuation = nil
            teardownCoreAudio()
            throw SystemAudioTapError.ioProcCreationFailed(procStatus)
        }
        ioProcID = newProcID

        // Anchor the gap-fill clock before the first callback can possibly
        // run: everything the first buffer's mHostTime is ahead of this is
        // silence the tap will never deliver.
        locked { _startHostTime = mach_absolute_time() }
        let startStatus = AudioDeviceStart(newAggregateID, newProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(newAggregateID, newProcID)
            ioProcID = nil
            continuation.finish()
            self.continuation = nil
            teardownCoreAudio()
            throw SystemAudioTapError.deviceStartFailed(startStatus)
        }

        locked { _isRunning = true }
        tapNote("tap started, native format \(Int(tapFormat.sampleRate)) Hz \(tapFormat.channelCount) ch, aggregate device \(newAggregateID) (private)")
        tapLog.info("system audio tap started at \(tapFormat.sampleRate, privacy: .public) Hz / \(tapFormat.channelCount, privacy: .public) ch, aggregate \(newAggregateID, privacy: .public)")
        return stream
    }

    /// Tear everything down, in the reverse order it was built, and finish the
    /// stream. Idempotent: safe to call twice, from `deinit`, or after a
    /// failed `start()`.
    func stop() {
        let wasRunning = locked {
            let was = _isRunning
            _isRunning = false
            return was
        }
        if let ioProcID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if wasRunning { AudioDeviceStop(aggregateID, ioProcID) }
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        teardownCoreAudio()
        // A meeting that ends in silence ends with no callbacks either, so
        // pad the tail out to the moment of stop() before closing the
        // stream. Without this the far-side WAV is short by however long
        // nobody spoke at the end, and the two tracks stop lining up.
        if wasRunning, let fill = tailFill() { continuation?.yield(fill) }
        // Finish, don't nil: the IO queue may still be inside one last
        // callback holding this continuation, and yielding to a finished
        // continuation is a documented no-op. start() replaces it.
        continuation?.finish()
        if wasRunning {
            let (seconds, buffers, filled) = locked { (_capturedSeconds, _buffersDelivered, _gapSecondsFilled) }
            tapNote("tap stopped after \(String(format: "%.2f", seconds))s / \(buffers) buffers (\(String(format: "%.2f", filled))s of that was silence gap-filled)")
        }
    }

    /// Destroy the aggregate device and the tap object if they exist. Split
    /// out of `stop()` so the failure paths in `start()` can unwind without
    /// leaving a private aggregate device behind.
    private func teardownCoreAudio() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            let status = AudioHardwareDestroyAggregateDevice(aggregateID)
            if status != noErr {
                tapLog.error("AudioHardwareDestroyAggregateDevice failed (OSStatus \(status, privacy: .public))")
            }
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            let status = AudioHardwareDestroyProcessTap(tapID)
            if status != noErr {
                tapLog.error("AudioHardwareDestroyProcessTap failed (OSStatus \(status, privacy: .public))")
            }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - IOProc

    /// One IOProc callback: stand in for whatever silence the HAL skipped,
    /// then wrap the tap's buffer list, convert to 16 kHz mono and yield.
    /// Runs on `ioQueue`.
    private func handle(inputData: UnsafePointer<AudioBufferList>,
                        inputTime: UnsafePointer<AudioTimeStamp>,
                        tapFormat: AVAudioFormat,
                        targetFormat: AVAudioFormat,
                        converter: AVAudioConverter,
                        continuation: AsyncStream<[Float]>.Continuation) {
        guard let input = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: inputData),
              input.frameLength > 0 else { return }

        // Timeline before audio: the zero-fill has to be yielded BEFORE this
        // buffer's samples, or the stream's ordering no longer matches the
        // clock it is being aligned to.
        if let fill = gapFill(before: inputTime.pointee,
                              frames: input.frameLength,
                              nativeRate: tapFormat.sampleRate) {
            continuation.yield(fill)
        }

        let ratio = Self.targetSampleRate / tapFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up) + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, out.frameLength > 0,
              let channel = out.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        let nonZero = samples.reduce(into: 0) { count, sample in if sample != 0 { count += 1 } }

        let reportSilence: Bool = locked {
            let seconds = Double(samples.count) / Self.targetSampleRate
            _capturedSeconds += seconds
            _realAudioSeconds += seconds
            _buffersDelivered += 1
            _nonZeroSamples += nonZero
            guard !_silenceReported, _nonZeroSamples == 0,
                  _realAudioSeconds >= Self.silenceWindow else { return false }
            _silenceReported = true
            return true
        }
        if reportSilence {
            tapNote("every sample in the first \(String(format: "%.0f", Self.silenceWindow))s is silence. Either the Mac is playing nothing, or this app does not have permission to record system audio -- grant it in System Settings > Privacy & Security > Screen & System Audio Recording (\"System Audio Recording Only\"), then start the recording again.")
            tapLog.error("system audio tap delivering pure silence for the first \(Self.silenceWindow, privacy: .public)s; likely missing System Audio Recording permission")
        }
        continuation.yield(samples)
    }

    // MARK: - Gap filling

    /// `mach_absolute_time()` ticks to seconds. The timebase is fixed for the
    /// life of the process, so read it once.
    private static let hostTickSeconds: Double = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0 else { return 0 }
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    private static func hostSeconds(_ ticks: UInt64) -> Double {
        Double(ticks) * hostTickSeconds
    }

    /// The digital silence that belongs in front of this buffer, if any.
    ///
    /// The tap delivers NOTHING while the Mac is playing nothing (Task 1:
    /// ten seconds of wall clock containing four seconds of speech produced
    /// four seconds of buffers), so simply concatenating the callbacks
    /// compresses the timeline and every timestamp downstream of it is
    /// wrong -- including the diariser's, and including the alignment
    /// between this track and the microphone track recorded alongside it.
    ///
    /// The IOProc's own input timestamp carries the true position:
    /// `mSampleTime` is a frame counter at the tap's native rate, so the
    /// frames between where the last buffer ended and where this one starts
    /// are exactly what was skipped. The first callback is anchored against
    /// the `mach_absolute_time()` recorded in `start()` instead, since there
    /// is no previous buffer to measure from.
    ///
    /// Two guards keep a bogus timestamp from allocating hundreds of MB of
    /// zeros: a gap of one buffer or less is ignored as ordinary jitter, and
    /// the fill can never take `capturedSeconds` past the wall-clock time
    /// that has really elapsed since `start()`.
    private func gapFill(before timestamp: AudioTimeStamp,
                         frames: AVAudioFrameCount,
                         nativeRate: Double) -> [Float]? {
        guard nativeRate > 0 else { return nil }
        let sampleTimeValid = timestamp.mFlags.contains(.sampleTimeValid)
        let hostTimeValid = timestamp.mFlags.contains(.hostTimeValid)

        let fillSamples: Int = locked {
            var gapSeconds: Double = 0
            if _expectedNextSampleTime < 0 {
                // First callback (or a device that reports no sample time at
                // all): measure from start() with the host clock.
                if hostTimeValid, _startHostTime > 0, timestamp.mHostTime > _startHostTime {
                    gapSeconds = Self.hostSeconds(timestamp.mHostTime - _startHostTime)
                }
            } else if sampleTimeValid {
                let skipped = timestamp.mSampleTime - _expectedNextSampleTime
                if skipped > Double(frames) { gapSeconds = skipped / nativeRate }
            }
            if sampleTimeValid {
                _expectedNextSampleTime = timestamp.mSampleTime + Double(frames)
            }
            if hostTimeValid, _startHostTime > 0, timestamp.mHostTime > _startHostTime {
                let elapsed = Self.hostSeconds(timestamp.mHostTime - _startHostTime)
                gapSeconds = min(gapSeconds, max(0, elapsed - _capturedSeconds))
            }
            guard gapSeconds > 0 else { return 0 }
            let count = Int((gapSeconds * Self.targetSampleRate).rounded())
            guard count > 0 else { return 0 }
            let filled = Double(count) / Self.targetSampleRate
            _capturedSeconds += filled
            _gapSecondsFilled += filled
            return count
        }
        guard fillSamples > 0 else { return nil }
        return [Float](repeating: 0, count: fillSamples)
    }

    /// The silence between the last buffer and `stop()`. Same reasoning as
    /// `gapFill`, at the other end of the recording.
    private func tailFill() -> [Float]? {
        let now = mach_absolute_time()
        let fillSamples: Int = locked {
            guard _startHostTime > 0, now > _startHostTime else { return 0 }
            let missing = Self.hostSeconds(now - _startHostTime) - _capturedSeconds
            // 10 ms: below that it is scheduling noise, not silence.
            guard missing > 0.01 else { return 0 }
            let count = Int((missing * Self.targetSampleRate).rounded())
            guard count > 0 else { return 0 }
            let filled = Double(count) / Self.targetSampleRate
            _capturedSeconds += filled
            _gapSecondsFilled += filled
            return count
        }
        guard fillSamples > 0 else { return nil }
        return [Float](repeating: 0, count: fillSamples)
    }

    // MARK: - Property helpers

    /// The tap's own stream format (`kAudioTapPropertyFormat` on the tap
    /// object), as an AVAudioFormat the converter can use. Typically the
    /// current output device's rate in stereo float32, e.g. 48 kHz 2 ch.
    private static func readFormat(of tapID: AudioObjectID) throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr else { throw SystemAudioTapError.tapFormatUnavailable(status) }
        guard asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0,
              let format = AVAudioFormat(streamDescription: &asbd) else {
            throw SystemAudioTapError.unusableTapFormat(sampleRate: asbd.mSampleRate,
                                                        channels: asbd.mChannelsPerFrame)
        }
        return format
    }
}
