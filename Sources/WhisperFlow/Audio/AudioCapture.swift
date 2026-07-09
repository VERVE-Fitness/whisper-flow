import Foundation
import AVFoundation
import os

private let captureLog = Logger(subsystem: "com.niallwogan.whisperflow", category: "audio-capture")

enum AudioCaptureError: Error, LocalizedError {
    case converterCreationFailed
    case engineStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .converterCreationFailed: return "Could not create audio converter to 16 kHz mono"
        case .engineStartFailed(let why): return "Audio engine failed to start: \(why)"
        }
    }
}

/// Captures microphone audio via AVAudioEngine and delivers 16 kHz mono
/// Float32 sample chunks through an AsyncStream.
final class AudioCapture {
    static let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var continuation: AsyncStream<[Float]>.Continuation?
    private(set) var capturedSeconds: Double = 0
    /// Diagnostic only (see the tap callback): if the hardware tap ever
    /// stops delivering buffers mid-recording -- a driver/USB/Bluetooth
    /// dropout, or macOS throttling a backgrounded app's audio thread -- this
    /// is the one place that would notice, since everything downstream
    /// (feedTask, the STT backend) just sees "no more chunks arrived" and has
    /// no way to distinguish that from a legitimate key release.
    /// The tap callback runs on AVAudioEngine's real-time audio thread, while
    /// the stall-check timer reads this from the main thread -- genuinely
    /// concurrent access, so this needs real synchronization (unlike
    /// `capturedSeconds`, which the rest of this class gets away without
    /// locking only because it's read exclusively after `stop()`, once the
    /// tap thread has already gone quiet).
    private let lastBufferLock = NSLock()
    private var _lastBufferAt: Date?
    private var lastBufferAt: Date? {
        get { lastBufferLock.lock(); defer { lastBufferLock.unlock() }; return _lastBufferAt }
        set { lastBufferLock.lock(); defer { lastBufferLock.unlock() }; _lastBufferAt = newValue }
    }
    private var stallCheckTimer: Timer?
    /// How long without a new buffer counts as a stall worth logging. Real
    /// taps deliver every ~0.25s (4096 samples @ the input device's native
    /// rate); anything past a couple of seconds of silence from the tap
    /// itself (not the audio content -- silence still delivers buffers, it's
    /// buffer DELIVERY that would stop) means the hardware/driver stopped
    /// feeding us, not that the user paused speaking.
    private static let stallThreshold: TimeInterval = 2.0

    /// Start capturing. Returns a stream of 16 kHz mono Float32 chunks.
    func start() throws -> AsyncStream<[Float]> {
        capturedSeconds = 0
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: Self.targetSampleRate,
                                               channels: 1,
                                               interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioCaptureError.converterCreationFailed
        }
        self.converter = converter

        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self,
                                                            bufferingPolicy: .unbounded)
        self.continuation = continuation

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }
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
            self.lastBufferAt = Date()
            self.continuation?.yield(samples)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.continuation = nil
            throw AudioCaptureError.engineStartFailed(error.localizedDescription)
        }

        let startedAt = Date()
        lastBufferAt = startedAt
        stallCheckTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let gap = Date().timeIntervalSince(self.lastBufferAt ?? startedAt)
            if gap > Self.stallThreshold {
                let recordedFor = Date().timeIntervalSince(startedAt)
                captureLog.error("mic tap stalled: no buffer for \(String(format: "%.2f", gap))s (recording for \(String(format: "%.2f", recordedFor))s total) -- diagnostic for the '20 second cutoff' report")
            }
        }
        stallCheckTimer = timer
        RunLoop.main.add(timer, forMode: .common)

        return stream
    }

    func stop() {
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
