import Foundation
import AVFoundation

enum AudioEncoderError: Error, LocalizedError {
    case openFailed(String)
    case writeFailed(String)
    case emptyRange

    var errorDescription: String? {
        switch self {
        case .openFailed(let why): return "Could not open the audio file: \(why)"
        case .writeFailed(let why): return "Could not write the .m4a: \(why)"
        case .emptyRange: return "Nothing to encode in that range"
        }
    }
}

/// Turns the meeting's WAV tracks (16 kHz mono Float32, about 115 MB an hour)
/// into AAC in .m4a at 32 kbps mono, about 14 MB an hour. That is what goes
/// up to Flow: every browser plays it, Safari included, and an hour of a
/// meeting is a quick download rather than a coffee break.
///
/// `AVAudioFile(forWriting:settings:)` does the encoding: its
/// `processingFormat` stays float PCM, so the read loop hands it the same
/// buffers it took out of the WAV and AVFoundation converts on write. No
/// `AVAssetExportSession`, which cannot be told a bit rate.
enum AudioEncoder {
    static let bitRate = 32_000
    static let sampleRate = 16_000.0
    static let channels: AVAudioChannelCount = 1

    static var settings: [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC,
         AVSampleRateKey: sampleRate,
         AVNumberOfChannelsKey: Int(channels),
         AVEncoderBitRateKey: bitRate]
    }

    /// Encodes all of `wav`, or the `seconds` slice of it, to `output`.
    /// Returns the number of source frames encoded.
    @discardableResult
    static func encodeM4A(wav: URL, to output: URL, seconds range: ClosedRange<Double>? = nil) throws -> AVAudioFramePosition {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: wav)
        } catch {
            throw AudioEncoderError.openFailed("\(wav.lastPathComponent): \(error.localizedDescription)")
        }
        let format = input.processingFormat
        let rate = format.sampleRate

        var first: AVAudioFramePosition = 0
        var wanted = input.length
        if let range {
            first = max(0, AVAudioFramePosition((range.lowerBound * rate).rounded()))
            let last = min(input.length, AVAudioFramePosition((range.upperBound * rate).rounded()))
            wanted = last - first
        }
        guard wanted > 0, first < input.length else { throw AudioEncoderError.emptyRange }

        try? FileManager.default.removeItem(at: output)
        let out: AVAudioFile
        do {
            out = try AVAudioFile(forWriting: output, settings: settings)
        } catch {
            throw AudioEncoderError.writeFailed("\(output.lastPathComponent): \(error.localizedDescription)")
        }

        input.framePosition = first
        // 1 s at a time: small enough that an hour-long track never sits in
        // memory, large enough that the encoder is not called 40,000 times.
        let chunkFrames = AVAudioFrameCount(rate)
        var remaining = wanted
        do {
            while remaining > 0 {
                let take = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), remaining))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: take) else {
                    throw AudioEncoderError.writeFailed("could not allocate a buffer")
                }
                try input.read(into: buffer, frameCount: take)
                guard buffer.frameLength > 0 else { break }
                try out.write(from: buffer)
                remaining -= AVAudioFramePosition(buffer.frameLength)
            }
        } catch let error as AudioEncoderError {
            throw error
        } catch {
            throw AudioEncoderError.writeFailed(error.localizedDescription)
        }
        return wanted - max(0, remaining)
    }

    /// Seconds of audio in a file, read from its header rather than its size.
    static func duration(of url: URL) throws -> Double {
        do {
            let file = try AVAudioFile(forReading: url)
            return Double(file.length) / file.processingFormat.sampleRate
        } catch {
            throw AudioEncoderError.openFailed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
