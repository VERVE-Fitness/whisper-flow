import Foundation
import AudioToolbox
import AVFoundation

enum TrackWriterError: Error, LocalizedError {
    case closed
    case createFailed(OSStatus)
    case writeFailed(OSStatus)
    var errorDescription: String? {
        switch self {
        case .closed: return "Track writer is closed"
        case .createFailed(let status): return "Could not create the track WAV (AudioFileCreateWithURL \(status))"
        case .writeFailed(let status): return "Could not write to the track WAV (AudioFileWritePackets \(status))"
        }
    }
}

/// Appends 16 kHz mono Float32 chunks to a WAV file as they arrive from a
/// capture stream, so a crash mid-meeting loses at most the last chunk.
/// Not thread-safe by design: one writer is driven by one consumer task.
///
/// AudioToolbox's `AudioFile` API rather than `AVAudioFile`: `AVAudioFile`
/// only finalises the WAV header when the object is deallocated, it holds
/// extra internal references so releasing it does not deallocate it on the
/// spot, and it updates the header a 4096-byte block at a time. Reading a
/// track straight after `close()` therefore came up short by the tail of the
/// recording. `AudioFileClose` finalises the header there and then.
final class TrackWriter {
    private var file: AudioFileID?
    private(set) var framesWritten = 0

    var seconds: Double { Double(framesWritten) / AudioCapture.targetSampleRate }

    /// 16 kHz mono Float32, packed: exactly what both captures deliver and
    /// what the Parakeet and diariser loaders read back.
    private static var streamDescription: AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: AudioCapture.targetSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0)
    }

    init(url: URL) throws {
        var asbd = TrackWriter.streamDescription
        var fileID: AudioFileID?
        let status = AudioFileCreateWithURL(url as CFURL, kAudioFileWAVEType, &asbd,
                                            .eraseFile, &fileID)
        guard status == noErr, let fileID else { throw TrackWriterError.createFailed(status) }
        file = fileID
    }

    func append(_ samples: [Float]) throws {
        guard let file else { throw TrackWriterError.closed }
        guard !samples.isEmpty else { return }
        var packets = UInt32(samples.count)
        let bytes = UInt32(samples.count * MemoryLayout<Float>.size)
        let status = samples.withUnsafeBufferPointer { src in
            AudioFileWritePackets(file, false, bytes, nil,
                                  Int64(framesWritten), &packets, src.baseAddress!)
        }
        guard status == noErr else { throw TrackWriterError.writeFailed(status) }
        framesWritten += Int(packets)
    }

    /// Finalises the WAV header. Safe to call twice.
    func close() {
        guard let file else { return }
        AudioFileClose(file)
        self.file = nil
    }
}
