import Foundation
import AVFoundation
import AudioToolbox
import os

private let captureLog = Logger(subsystem: "com.niallwogan.whisperflow", category: "audio-capture")

/// Mirror of the important capture events to stderr, so the `--capture-test`
/// CLI and a Terminal launch show them without needing Console.app.
private func captureNote(_ message: String) {
    FileHandle.standardError.write(Data("[capture] \(message)\n".utf8))
}

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
///
/// Threading: the tap closure runs on the real-time audio thread, the
/// configuration-change notification arrives on a CoreAudio thread, the
/// stall timer on the main run loop, and start()/stop() on the main actor.
///
/// Two separate mechanisms keep that safe, and they do different jobs:
///
/// * `engineQueue` is a serial queue, and EVERY sequence that mutates the
///   engine graph runs on it: `configureAndStart` (build engine, pin device,
///   install tap, start) and the `removeTap` + `stop` teardown. Before this,
///   a stop on the main actor could run `removeTap`/`stop` at the same
///   instant as a detached reconfigure task was building and starting a new
///   engine on the same field -- a torn read of `engine` there leaves either
///   a live mic nobody is consuming or a half-built graph, and it is one of
///   the two ways the stop pipeline was observed to wedge.
/// * `stateLock` guards the plain fields (flags, counters, the engine
///   REFERENCE, the continuation). Reading the reference under the lock and
///   then reading `isRunning` off it without the lock is deliberate: the
///   stall timer runs on the main run loop and must never block behind an
///   `AVAudioEngine.start()` that is taking 1-3 s on the engine queue.
///
/// `generation` ties each engine to the start() that created it, so a
/// reconfigure that finishes after stop() tears its engine straight back
/// down instead of leaving a live mic nobody is consuming.
final class AudioCapture: @unchecked Sendable {
    static let targetSampleRate: Double = 16_000

    /// Serialises every engine graph mutation. See the class doc comment.
    private let engineQueue = DispatchQueue(label: "com.niallwogan.whisperflow.engine")

    private let stateLock = NSLock()
    // -- everything below is guarded by stateLock --
    /// The engine reference. Mutated only from inside `engineQueue`; read
    /// from anywhere (under the lock) for diagnostics.
    private var _engine = AVAudioEngine()
    private var _continuation: AsyncStream<[Float]>.Continuation?
    /// Format the tap is currently installed with (diagnostics only).
    private var _inputFormat: AVAudioFormat?
    private var _followsSystemDefault = false
    private var _configObserver: NSObjectProtocol?
    private var _stallCheckTimer: Timer?
    /// Engine teardowns enqueued on `engineQueue` but not finished yet.
    /// `stopAndWait` waits on this reaching zero.
    private var _teardownsPending = 0
    private var _isActive = false
    private var _generation = 0
    private var _isReconfiguring = false
    private var _reconfigureCount = 0
    private var _lastReconfigureAt: Date?
    private var _stallLogged = false
    private var _capturedSeconds: Double = 0
    private var _buffersDelivered = 0
    private var _lastBufferAt: Date?
    private var _activeDevice: AudioInputDevice?

    private func locked<T>(_ body: () -> T) -> T {
        stateLock.lock(); defer { stateLock.unlock() }
        return body()
    }

    /// Seconds of 16 kHz audio delivered so far in the current capture.
    var capturedSeconds: Double { locked { _capturedSeconds } }
    /// Total buffers delivered across the current capture (diagnostics + the
    /// `--capture-test` CLI mode).
    var buffersDelivered: Int { locked { _buffersDelivered } }
    /// The device the current/last capture actually recorded from (for the
    /// menu status line and the usage log).
    var activeDevice: AudioInputDevice? { locked { _activeDevice } }
    /// Diagnostics only: whether the engine believes it is running. Reads the
    /// reference under the lock and the property outside it, on purpose --
    /// see the class doc comment.
    private var engineIsRunning: Bool { locked { _engine }.isRunning }

    /// How long without a new buffer counts as a stall. Real taps deliver
    /// every ~0.25s (4096 samples @ the input device's native rate); anything
    /// past a couple of seconds of silence from the tap itself (not the audio
    /// content -- silence still delivers buffers, it's buffer DELIVERY that
    /// would stop) means the hardware/driver stopped feeding us, not that the
    /// user paused speaking. When that happens we try an engine restart
    /// rather than only logging it.
    private static let stallThreshold: TimeInterval = 2.0
    /// Rebuild budget: at most this many rebuilds per `reconfigureCooldown`
    /// window. A closed-lid MacBook whose default input changes fires a
    /// BURST of configuration changes (observed: four in under a second);
    /// a hard lifetime cap of three was exhausted by the burst and the
    /// capture stayed dead. With a cooldown, the 1 s stall timer gets to
    /// try again once the storm has passed.
    private static let maxReconfigures = 3
    private static let reconfigureCooldown: TimeInterval = 5.0

    /// Start capturing from the device `selection` resolves to. Returns a
    /// stream of 16 kHz mono Float32 chunks.
    ///
    /// Async because `AVAudioEngine.start()` can block for 1-3 seconds while
    /// a Bluetooth headset negotiates its hands-free profile; the caller is
    /// on the main actor and blocking it there freezes the status pill and
    /// starves the hands-free key tap (which the system then disables for
    /// unresponsiveness, so the "any key finishes" press is lost).
    func start(selection: InputDeviceSelection = InputDeviceSelection.saved) async throws -> AsyncStream<[Float]> {
        // Defensive: a previous capture that was never stopped (or a
        // reconfigure that raced a stop) must not survive into this one. The
        // teardown it enqueues is serialised ahead of our own bring-up by
        // engineQueue, so there is no need to wait for it here.
        stop()

        let generation: Int = locked {
            _generation += 1
            _capturedSeconds = 0
            _buffersDelivered = 0
            _reconfigureCount = 0
            _isReconfiguring = false
            _stallLogged = false
            return _generation
        }

        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self,
                                                            bufferingPolicy: .unbounded)
        locked { _continuation = continuation }

        let engine: AVAudioEngine = try await Task.detached(priority: .userInitiated) { [self] in
            try engineQueue.sync { try configureAndStart(selection: selection) }
        }.value

        locked {
            _isActive = true
            _lastBufferAt = Date()
        }
        installConfigurationChangeObserver(generation: generation, on: engine)
        startStallCheck(generation: generation)
        return stream
    }

    private func isCurrent(_ generation: Int) -> Bool {
        locked { _isActive && _generation == generation }
    }

    /// Synchronous engine bring-up. MUST run on `engineQueue` (see the class
    /// doc comment) and off the main actor (see `start`). Returns the engine
    /// it built so the caller can observe that exact object.
    @discardableResult
    private func configureAndStart(selection: InputDeviceSelection) throws -> AVAudioEngine {
        dispatchPrecondition(condition: .onQueue(engineQueue))
        let (device, followsDefault) = AudioDevices.resolve(selection)
        guard let device else { throw AudioCaptureError.noInputDevice }
        locked {
            _activeDevice = device
            _followsSystemDefault = followsDefault
        }

        // A fresh engine per capture: after a configuration change or an
        // error the old graph can be left in a state where re-installing a
        // tap traps inside AVFoundation. Engines are cheap.
        let newEngine = AVAudioEngine()
        let input = newEngine.inputNode
        if !followsDefault {
            try Self.pin(device: device, to: input)
        }
        let format = try installTap(on: input, deviceName: device.name)

        newEngine.prepare()
        do {
            try newEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioCaptureError.engineStartFailed(error.localizedDescription)
        }
        locked {
            _engine = newEngine
            _inputFormat = format
        }
        captureNote("started on \"\(device.name)\" pinned=\(!followsDefault) \(Int(format.sampleRate)) Hz \(format.channelCount) ch")
        captureLog.info("capture started on \"\(device.name, privacy: .public)\" (\(device.isBuiltIn ? "built-in" : device.isBluetooth ? "bluetooth" : "other", privacy: .public), pinned: \(!followsDefault)) at \(format.sampleRate, privacy: .public) Hz / \(format.channelCount, privacy: .public) ch")
        return newEngine
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

    /// Installs the tap and returns the input format it was installed with.
    /// The converter and target format are captured by the tap closure as
    /// constants -- the real-time thread never reads a field that
    /// stop()/reconfigure could be replacing.
    private func installTap(on input: AVAudioInputNode, deviceName: String) throws -> AVAudioFormat {
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
        let continuation = locked { _continuation }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
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
            self.locked {
                self._capturedSeconds += Double(samples.count) / Self.targetSampleRate
                self._buffersDelivered += 1
                self._lastBufferAt = Date()
            }
            // Yielding to a finished continuation is a documented no-op, so
            // a tap that outlives stop() by a callback is harmless.
            continuation?.yield(samples)
        }
        return inputFormat
    }

    // MARK: - Configuration changes (device switched / format changed)

    private func installConfigurationChangeObserver(generation: Int, on engine: AVAudioEngine) {
        let previous: NSObjectProtocol? = locked {
            let old = _configObserver
            _configObserver = nil
            return old
        }
        if let previous { NotificationCenter.default.removeObserver(previous) }
        // queue: nil -- handle on the posting thread. Routing through the
        // main queue would make recovery depend on the main run loop being
        // serviced, which is exactly what a blocked main thread (Bluetooth
        // negotiation, a modal, the CLI test harness) can't guarantee.
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange(reason: "AVAudioEngineConfigurationChange", generation: generation)
        }
        locked { _configObserver = observer }
    }

    private func removeConfigurationChangeObserver() {
        let observer: NSObjectProtocol? = locked {
            let old = _configObserver
            _configObserver = nil
            return old
        }
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// AVAudioEngine has stopped itself because the input device's
    /// configuration changed under it (or the stall watchdog saw no buffers).
    /// Rebuild the tap against the current format and start again, feeding
    /// the same continuation. In "system default" mode the current device may
    /// now be a different one (AirPods just took over); in pinned mode it's
    /// the same device with a new format (or gone entirely, in which case we
    /// fall back to the default selection rules so the dictation survives).
    ///
    /// Re-entrancy: the notification and the stall timer can both fire for
    /// one event, from different threads. `_isReconfiguring` makes the
    /// second caller a no-op; the generation check makes a rebuild that
    /// finishes after stop() undo itself. The rebuild itself is dispatched
    /// to `engineQueue`, so it can never overlap a stop()'s teardown.
    private func handleConfigurationChange(reason: String, generation: Int) {
        // A PINNED engine receives AVAudioEngineConfigurationChange when the
        // system default input changes even though its own device did not,
        // and it keeps running. Rebuilding on that is worse than useless:
        // each rebuild loses ~0.3 s of audio and the replacement engine gets
        // the same notification again (observed: 3 rebuilds per device
        // switch, then a dead capture). Only a stopped engine needs a
        // rebuild; a running one is left alone, with the stall watchdog as
        // the safety net if it turns out to be running but silent.
        if reason == "AVAudioEngineConfigurationChange", engineIsRunning, isCurrent(generation) {
            captureNote("configuration change while engine still running; keeping current capture")
            return
        }
        let attempt: Int? = locked {
            guard _isActive, _generation == generation, !_isReconfiguring else { return nil }
            if _reconfigureCount >= Self.maxReconfigures {
                guard let last = _lastReconfigureAt,
                      Date().timeIntervalSince(last) > Self.reconfigureCooldown else { return nil }
                _reconfigureCount = 0
            }
            _isReconfiguring = true
            _reconfigureCount += 1
            _lastReconfigureAt = Date()
            return _reconfigureCount
        }
        guard let attempt else {
            captureNote("configuration change (\(reason)) ignored: inactive, superseded, already rebuilding, or \(Self.maxReconfigures) attempts used in the last \(Int(Self.reconfigureCooldown))s")
            captureLog.error("input configuration change (\(reason, privacy: .public)) ignored: inactive, superseded, already rebuilding, or \(Self.maxReconfigures) attempts used")
            return
        }
        captureLog.error("input configuration changed mid-recording (\(reason, privacy: .public)); rebuilding capture (attempt \(attempt))")
        captureNote("configuration changed (\(reason)); rebuilding, attempt \(attempt)")
        let previousUID = activeDevice?.uid
        let selection: InputDeviceSelection = locked { _followsSystemDefault }
            ? .systemDefault
            : (previousUID.map { .device(uid: $0) } ?? .builtIn)

        engineQueue.async { [self] in
            defer { locked { _isReconfiguring = false } }
            // Tear down the old graph fully; a tap left on a stopped engine
            // after a device change is the state that traps on reinstall.
            let old = locked { _engine }
            old.inputNode.removeTap(onBus: 0)
            old.stop()
            guard isCurrent(generation) else { return }
            do {
                let rebuilt = try configureAndStart(selection: selection)
                // stop() may have run while the engine was coming up. The
                // new engine is then a zombie with a live mic: kill it.
                guard isCurrent(generation) else {
                    rebuilt.inputNode.removeTap(onBus: 0)
                    rebuilt.stop()
                    captureLog.info("reconfigure finished after stop(); torn down again")
                    return
                }
                installConfigurationChangeObserver(generation: generation, on: rebuilt)
                locked {
                    _lastBufferAt = Date()
                    _stallLogged = false
                }
                captureLog.info("capture resumed after configuration change on \"\(self.activeDevice?.name ?? "?", privacy: .public)\"")
            } catch {
                // Let the stall timer try again on its next tick (bounded by
                // maxReconfigures), instead of latching the watchdog shut.
                locked { _stallLogged = false }
                captureNote("could not resume: \(error.localizedDescription)")
                captureLog.error("could not resume capture after configuration change: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Stall watchdog

    private func startStallCheck(generation: Int) {
        let startedAt = Date()
        invalidateStallTimer()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let (gap, shouldAct): (TimeInterval, Bool) = self.locked {
                guard self._isActive, self._generation == generation else { return (0, false) }
                let gap = Date().timeIntervalSince(self._lastBufferAt ?? startedAt)
                guard gap > Self.stallThreshold, !self._stallLogged else { return (gap, false) }
                self._stallLogged = true
                return (gap, true)
            }
            guard shouldAct else { return }
            let recordedFor = Date().timeIntervalSince(startedAt)
            captureLog.error("mic tap stalled: no buffer for \(String(format: "%.2f", gap), privacy: .public)s (recording for \(String(format: "%.2f", recordedFor), privacy: .public)s total, device \"\(self.activeDevice?.name ?? "?", privacy: .public)\", engine running: \(self.engineIsRunning)); attempting restart")
            // A stall with no configuration-change notification still means
            // the engine isn't feeding us. Treat it the same way rather than
            // sitting on a dead tap.
            self.handleConfigurationChange(reason: "tap stall \(String(format: "%.1f", gap))s", generation: generation)
        }
        locked { _stallCheckTimer = timer }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// `Timer.invalidate()` is only safe on the thread whose run loop the
    /// timer was scheduled on, and `stop()` is now callable from anywhere, so
    /// the invalidation hops to main when it isn't already there.
    private func invalidateStallTimer() {
        let timer: Timer? = locked {
            let t = _stallCheckTimer
            _stallCheckTimer = nil
            return t
        }
        guard let timer else { return }
        if Thread.isMainThread {
            timer.invalidate()
        } else {
            DispatchQueue.main.async { timer.invalidate() }
        }
    }

    // MARK: - Stop

    /// Stop capturing. Returns immediately -- nothing here blocks the caller,
    /// and in particular nothing blocks the main actor.
    ///
    /// The parts a caller depends on happen synchronously: the capture is
    /// marked inactive, the generation is bumped (so an in-flight reconfigure
    /// undoes itself), and the stream continuation is finished, which is what
    /// ends the feed task draining it. The engine teardown itself
    /// (`removeTap` + `stop`, which can sit inside CoreAudio for a second or
    /// more on a Bluetooth device) is handed to `engineQueue`. Use
    /// `stopAndWait(timeout:)` when the caller genuinely needs to know the
    /// hardware is released.
    func stop() {
        locked {
            _isActive = false
            _generation += 1   // invalidates any in-flight reconfigure
            _teardownsPending += 1
        }
        removeConfigurationChangeObserver()
        // Finish, don't nil: the tap thread may still be inside one last
        // callback holding this continuation, and yielding to a finished
        // continuation is a no-op. start() replaces it.
        locked { _continuation }?.finish()
        invalidateStallTimer()

        engineQueue.async { [self] in
            let engine = locked { _engine }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            locked { _teardownsPending -= 1 }
        }
    }

    /// `stop()` plus a bounded wait for the engine teardown to actually
    /// finish, for callers that want the mic released before they move on.
    ///
    /// Returns as soon as the teardown completes, or after `timeout`,
    /// whichever comes first. On timeout it returns anyway and says so in the
    /// log: a wedged CoreAudio teardown should cost a leaked engine, not a
    /// wedged UI. Never blocks a thread -- it suspends between polls.
    func stopAndWait(timeout: TimeInterval) async {
        stop()
        let deadline = Date().addingTimeInterval(timeout)
        while !Task.isCancelled {
            if locked({ _teardownsPending == 0 }) { return }
            if Date() >= deadline { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard locked({ _teardownsPending > 0 }) else { return }
        captureNote("engine teardown still running after \(String(format: "%.1f", timeout))s; leaving it to finish on its own rather than holding up the stop")
        captureLog.error("engine teardown exceeded \(timeout, privacy: .public)s; abandoned (engine leaked, UI released)")
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
