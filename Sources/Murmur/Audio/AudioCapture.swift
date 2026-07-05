import Foundation
import AVFoundation

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
        return stream
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        converter = nil
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
