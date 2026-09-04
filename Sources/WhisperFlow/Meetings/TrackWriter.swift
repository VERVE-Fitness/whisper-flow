import Foundation

enum TrackWriterError: Error, LocalizedError {
    case closed
    case createFailed(String)
    case writeFailed(String)
    var errorDescription: String? {
        switch self {
        case .closed: return "Track writer is closed"
        case .createFailed(let why): return "Could not create the track WAV: \(why)"
        case .writeFailed(let why): return "Could not write to the track WAV: \(why)"
        }
    }
}

/// Appends 16 kHz mono Float32 chunks to a WAV file as they arrive from a
/// capture stream, so a crash mid-meeting loses at most the last chunk.
/// Not thread-safe by design: one writer is driven by one consumer task.
///
/// The RIFF header is written by hand over a `FileHandle` rather than through
/// `AVAudioFile` or AudioToolbox's `AudioFile`. `AVAudioFile` only finalises
/// its header when the object is deallocated, which is not the moment it is
/// released, so a read straight after `close()` came up short by the tail of
/// the recording. `AudioFileCreateWithURL` writes an `FLLR` padding chunk
/// before the data, and `AVAudioFile.read(into:)` then stops part way through
/// the first read (23552 of 24000 frames in the Task 2 test), which
/// `loadAudioFileAs16kMonoFloats` reports as a short file. A canonical
/// RIFF/WAVE header with the sizes patched on every append has neither
/// problem and leaves a playable file even if the app dies mid-meeting.
final class TrackWriter {
    /// RIFF(12) + fmt (26) + fact(12) + data(8). Audio starts at byte 58.
    private static let headerBytes = 58

    private var handle: FileHandle?
    private(set) var framesWritten = 0

    var seconds: Double { Double(framesWritten) / AudioCapture.targetSampleRate }

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path,
                                             contents: TrackWriter.header(frames: 0)) else {
            throw TrackWriterError.createFailed(url.path)
        }
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw TrackWriterError.createFailed(error.localizedDescription)
        }
    }

    func append(_ samples: [Float]) throws {
        guard let handle else { throw TrackWriterError.closed }
        guard !samples.isEmpty else { return }
        let bytes = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        do {
            try handle.seek(toOffset: UInt64(TrackWriter.headerBytes + framesWritten * 4))
            try handle.write(contentsOf: bytes)
            framesWritten += samples.count
            // Keep the sizes in the header current, so a crash mid-meeting
            // leaves a WAV that plays and transcribes rather than an empty one.
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: TrackWriter.header(frames: framesWritten))
        } catch {
            throw TrackWriterError.writeFailed(error.localizedDescription)
        }
    }

    /// Finalises the WAV header. Safe to call twice.
    func close() {
        guard let handle else { return }
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: TrackWriter.header(frames: framesWritten))
        } catch {
            FileHandle.standardError.write(Data("[meeting] could not finalise the track WAV header: \(error.localizedDescription)\n".utf8))
        }
        try? handle.close()
        self.handle = nil
    }

    /// Canonical little-endian RIFF/WAVE header for 16 kHz mono Float32.
    /// A `fact` chunk is required for non-PCM WAVs and carries the frame count.
    private static func header(frames: Int) -> Data {
        let rate = UInt32(AudioCapture.targetSampleRate)
        let dataBytes = UInt32(frames * 4)
        var d = Data(capacity: headerBytes)
        func tag(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

        tag("RIFF"); u32(UInt32(headerBytes - 8) + dataBytes); tag("WAVE")
        tag("fmt "); u32(18)
        u16(3)              // WAVE_FORMAT_IEEE_FLOAT
        u16(1)              // mono
        u32(rate)
        u32(rate * 4)       // byte rate
        u16(4)              // block align
        u16(32)             // bits per sample
        u16(0)              // no format extension
        tag("fact"); u32(4); u32(UInt32(frames))
        tag("data"); u32(dataBytes)
        return d
    }
}
