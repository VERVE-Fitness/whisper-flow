import Foundation
import AVFoundation
import AudioToolbox
import os

private let captureLog = Logger(subsystem: "com.niallwogan.whisperflow", category: "audio-capture")

enum AudioCaptureError: Error, LocalizedError {
    case noInputDevice
    case invalidInputFormat(device: String, sampleRate: Double, channels: UInt32)
    case converterCreationFailed
    case engineStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No microphone found on this Mac"
        case .invalidInputFormat(let device, let rate, let ch):
            return "Microphone \"\(device)\" reported an unusable format (\(Int(rate)) Hz, \(ch) ch) -- try again in a second, or pick another microphone from the menu"
        case .converterCreationFailed:
            return "Could not create audio converter to 16 kHz mono"
        case .engineStartFailed(let why):
            return "Audio engine failed to start: \(why)"
        }
    }
}

/// Captures microphone audio via AVAudioEngine and delivers 16 kHz mono
/// Float32 sample chunks through an AsyncStream.
///
/// Two behaviours matter for AirPods / Bluetooth users (see
/// `InputDeviceSelection` for why):
///
/// 1. The engine's input is PINNED to the chosen device (built-in mic by
///    default) via `kAudioOutputUnitProperty_CurrentDevice`, instead of
///    following the system default input. AirPods connecting mid-dictation
///    therefore never yank the engine onto a Bluetooth mic.
/// 2. If the device configuration changes anyway (the pinned device changed
///    sample rate, or in "system default" mode macOS switched devices),
///    AVAudioEngine stops itself and posts
///    `AVAudioEngineConfigurationChange`. The previous version never observed
///    that notification, so the tap silently stopped delivering buffers and
///    the dictation appeared to hang ("Listening…" forever with no words).
///    This version rebuilds the tap and restarts the engine on that
///    notification, keeping the same output stream.
final class AudioCapture: @unchecked Sendable {
    static let targetSampleRate: Double = 16_000

    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var continuation: AsyncStream<[Float]>.Continuation?
    /// Format the tap is currently installed with; re-read on reconfigure.
    private var inputFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat?
    private(set) var capturedSeconds: Double = 0
    /// The device the current/last capture actually recorded from (for the
    /// menu status line and the usage log).
    private(set) var activeDevice: AudioInputDevice?
    private var followsSystemDefault = false
    private var isActive = false
    private var configObserver: NSObjectProtocol?
    private var reconfigureCount = 0

    /// Diagnostic only (see the tap callback): if the hardware tap ever
    /// stops delivering buffers mid-recording -- a driver/USB/Bluetooth
    /// dropout, or macOS throttling a backgrounded app's audio thread -- this
    /// is the one place that would notice, since everything downstream
    /// (feedTask, the STT backend) just sees "no more chunks arrived" and has
    /// no way to distinguish that from a legitimate key release.
    /// The tap callback runs on AVAudioEngine's real-time audio thread, while
    /// the stall-check timer reads this from the main thread -- genuinely
    /// concurrent access, so this needs real synchronization.
    private let lastBufferLock = NSLock()
    private var _lastBufferAt: Date?
    private var lastBufferAt: Date? {
        get { lastBufferLock.lock(); defer { lastBufferLock.unlock() }; return _lastBufferAt }
        set { lastBufferLock.lock(); defer { lastBufferLock.unlock() }; _lastBufferAt = newValue }
    }
    private var stallCheckTimer: Timer?
    private var stallLogged = false
    /// How long without a new buffer counts as a stall. Real taps deliver
    /// every ~0.25s (4096 samples @ the input device's native rate); anything
    /// past a couple of seconds of silence from the tap itself (not the audio
    /// content -- silence still delivers buffers, it's buffer DELIVERY that
    /// would stop) means the hardware/driver stopped feeding us, not that the
    /// user paused speaking. When that happens we now try one engine restart
    /// rather than only logging it.
    private static let stallThreshold: TimeInterval = 2.0
    /// Total buffers delivered across the current capture (diagnostics + the
    /// `--capture-test` CLI mode).
    private(set) var buffersDelivered = 0

    /// Start capturing from the device `selection` resolves to. Returns a
    /// stream of 16 kHz mono Float32 chunks.
    ///
    /// Async because `AVAudioEngine.start()` can block for 1-3 seconds while
    /// a Bluetooth headset negotiates its hands-free profile; the caller is
    /// on the main actor and blocking it there freezes the status pill and
    /// starves the hands-free key tap (which the system then disables for
    /// unresponsiveness, so the "any key finishes" press is lost).
    func start(selection: InputDeviceSelection = InputDeviceSelection.saved) async throws -> AsyncStream<[Float]> {
        capturedSeconds = 0
        buffersDelivered = 0
        reconfigureCount = 0
        stallLogged = false

        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self,
                                                            bufferingPolicy: .unbounded)
        self.continuation = continuation

        try await Task.detached(priority: .userInitiated) { [self] in
            try self.configureAndStart(selection: selection)
        }.value

        isActive = true
        installConfigurationChangeObserver()
        startStallCheck()
        return stream
    }

    /// Synchronous engine bring-up; runs off the main actor (see `start`).
    private func configureAndStart(selection: InputDeviceSelection) throws {
        let (device, followsDefault) = AudioDevices.resolve(selection)
        guard let device else { throw AudioCaptureError.noInputDevice }
        activeDevice = device
        followsSystemDefault = followsDefault

        // A fresh engine per capture: after a configuration change or an
        // error the old graph can be left in a state where re-installing a
        // tap traps inside AVFoundation. Engines are cheap.
        engine = AVAudioEngine()
        let input = engine.inputNode
        if !followsDefault {
            try Self.pin(device: device, to: input)
        }
        try installTap(on: input, deviceName: device.name)

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioCaptureError.engineStartFailed(error.localizedDescription)
        }
        captureLog.info("capture started on \"\(device.name, privacy: .public)\" (\(device.isBuiltIn ? "built-in" : device.isBluetooth ? "bluetooth" : "other", privacy: .public), pinned: \(!followsDefault)) at \(self.inputFormat?.sampleRate ?? 0, privacy: .public) Hz / \(self.inputFormat?.channelCount ?? 0, privacy: .public) ch")
    }

    /// Bind the engine's input AudioUnit to one specific device so it stops
    /// tracking the system default input.
    private static func pin(device: AudioInputDevice, to input: AVAudioInputNode) throws {
        guard let unit = input.audioUnit else {
            throw AudioCaptureError.engineStartFailed("input node has no audio unit to pin a device on")
        }
        var deviceID = device.id
        let status = AudioUnitSetProperty(unit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global,
                                          0,
                                          &deviceID,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw AudioCaptureError.engineStartFailed("could not select microphone \"\(device.name)\" (OSStatus \(status))")
        }
    }

    private func installTap(on input: AVAudioInputNode, deviceName: String) throws {
        let inputFormat = input.outputFormat(forBus: 0)
        // A device mid-transition (Bluetooth profile switch, just-plugged USB
        // mic) can report 0 Hz / 0 channels. Installing a tap with that
        // format is an ObjC exception, i.e. a crash, so refuse up front with
        // a message that says what to do.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.invalidInputFormat(device: deviceName,
                                                       sampleRate: inputFormat.sampleRate,
                                                       channels: inputFormat.channelCount)
        }
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: Self.targetSampleRate,
                                               channels: 1,
                                               interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioCaptureError.converterCreationFailed
        }
        self.inputFormat = inputFormat
        self.targetFormat = targetFormat
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.converter, let targetFormat = self.targetFormat else { return }
            let ratio = Self.targetSampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 32)
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
                return buffer
            }
            guard status != .error, error == nil, out.frameLength > 0,
                  let channel = out.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
            self.capturedSeconds += Double(samples.count) / Self.targetSampleRate
            self.buffersDelivered += 1
            self.lastBufferAt = Date()
            self.continuation?.yield(samples)
        }
    }

    // MARK: - Configuration changes (device switched / format changed)

    private func installConfigurationChangeObserver() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        // queue: nil -- handle on the posting thread. Routing through the
        // main queue would make recovery depend on the main run loop being
        // serviced, which is exactly what a blocked main thread (Bluetooth
        // negotiation, a modal, the CLI test harness) can't guarantee.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange(reason: "AVAudioEngineConfigurationChange")
        }
    }

    /// AVAudioEngine has stopped itself because the input device's
    /// configuration changed under it. Rebuild the tap against the current
    /// format and start again, feeding the same continuation. In "system
    /// default" mode the current device may now be a different one (AirPods
    /// just took over); in pinned mode it's the same device with a new
    /// format (or gone entirely, in which case we fall back to the default
    /// selection rules so the dictation survives).
    private func handleConfigurationChange(reason: String) {
        guard isActive else { return }
        reconfigureCount += 1
        let attempt = reconfigureCount
        captureLog.error("input configuration changed mid-recording (\(reason, privacy: .public)); rebuilding capture (attempt \(attempt))")
        guard attempt <= 3 else {
            captureLog.error("giving up after \(attempt) reconfigure attempts; stream will end at stop()")
            return
        }
        let previousUID = activeDevice?.uid
        Task.detached(priority: .userInitiated) { [self] in
            // Tear down the old graph fully; a tap left on a stopped engine
            // after a device change is the state that traps on reinstall.
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            // Re-resolve: pinned device may have vanished (AirPods removed
            // while pinned to them), default may have moved.
            let selection: InputDeviceSelection = followsSystemDefault
                ? .systemDefault
                : (previousUID.map { .device(uid: $0) } ?? .builtIn)
            do {
                try configureAndStart(selection: selection)
                installConfigurationChangeObserver()
                lastBufferAt = Date()
                stallLogged = false
                captureLog.info("capture resumed after configuration change on \"\(self.activeDevice?.name ?? "?", privacy: .public)\"")
            } catch {
                captureLog.error("could not resume capture after configuration change: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Stall watchdog

    private func startStallCheck() {
        let startedAt = Date()
        lastBufferAt = startedAt
        stallCheckTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.isActive else { return }
            let gap = Date().timeIntervalSince(self.lastBufferAt ?? startedAt)
            if gap > Self.stallThreshold {
                let recordedFor = Date().timeIntervalSince(startedAt)
                if !self.stallLogged {
                    self.stallLogged = true
                    captureLog.error("mic tap stalled: no buffer for \(String(format: "%.2f", gap), privacy: .public)s (recording for \(String(format: "%.2f", recordedFor), privacy: .public)s total, device \"\(self.activeDevice?.name ?? "?", privacy: .public)\", engine running: \(self.engine.isRunning)); attempting restart")
                    // A stall with no configuration-change notification
                    // still means the engine isn't feeding us. Treat it the
                    // same way rather than sitting on a dead tap.
                    self.handleConfigurationChange(reason: "tap stall \(String(format: "%.1f", gap))s")
                }
            }
        }
        stallCheckTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        isActive = false
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        converter = nil
        stallCheckTimer?.invalidate()
        stallCheckTimer = nil
    }
}

/// Load any audio file (WAV/AIFF/M4A/...) and convert it to 16 kHz mono Float32.
func loadAudioFileAs16kMonoFloats(path: String) throws -> [Float] {
    let url = URL(fileURLWithPath: path)
    let file: AVAudioFile
    do {
        file = try AVAudioFile(forReading: url)
    } catch {
        throw TranscriptionError.fileLoadFailed(error.localizedDescription)
    }
    let sourceFormat = file.processingFormat
    guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: AudioCapture.targetSampleRate,
                                           channels: 1,
                                           interleaved: false) else {
        throw TranscriptionError.fileLoadFailed("could not create target format")
    }

    guard let inBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                          frameCapacity: AVAudioFrameCount(file.length)) else {
        throw TranscriptionError.fileLoadFailed("could not allocate input buffer")
    }
    try file.read(into: inBuffer)

    if sourceFormat.sampleRate == targetFormat.sampleRate,
       sourceFormat.channelCount == 1,
       sourceFormat.commonFormat == .pcmFormatFloat32,
       let channel = inBuffer.floatChannelData?[0] {
        return Array(UnsafeBufferPointer(start: channel, count: Int(inBuffer.frameLength)))
    }

    guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
        throw TranscriptionError.fileLoadFailed("could not create converter")
    }
    let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
    let capacity = AVAudioFrameCount((Double(inBuffer.frameLength) * ratio).rounded(.up) + 64)
    guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
        throw TranscriptionError.fileLoadFailed("could not allocate output buffer")
    }

    var fed = false
    var error: NSError?
    let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
        if fed {
            outStatus.pointee = .endOfStream
            return nil
        }
        fed = true
        outStatus.pointee = .haveData
        return inBuffer
    }
    if status == .error {
        throw TranscriptionError.fileLoadFailed(error?.localizedDescription ?? "conversion failed")
    }
    guard let channel = outBuffer.floatChannelData?[0] else {
        throw TranscriptionError.fileLoadFailed("no channel data after conversion")
    }
    return Array(UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength)))
}
