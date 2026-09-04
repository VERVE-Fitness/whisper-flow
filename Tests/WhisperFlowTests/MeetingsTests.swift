import XCTest
import AVFoundation
@testable import WhisperFlow

final class TrackWriterTests: XCTestCase {
    func testWritesChunksReadableAs16kMono() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trackwriter-\(UUID().uuidString).wav")
        print("WAVPATH \(url.path)")

        let writer = try TrackWriter(url: url)
        // 1.5 s of a 440 Hz sine in three 0.5 s chunks
        let chunk = (0..<8_000).map { i in Float(sin(2 * .pi * 440 * Double(i) / 16_000)) * 0.5 }
        try writer.append(chunk)
        try writer.append(chunk)
        try writer.append(chunk)
        XCTAssertEqual(writer.framesWritten, 24_000)
        XCTAssertEqual(writer.seconds, 1.5, accuracy: 0.001)
        writer.close()

        let probe = try AVAudioFile(forReading: url)
        print("PROBE length=\(probe.length) fmt=\(probe.processingFormat)")
        let pb = AVAudioPCMBuffer(pcmFormat: probe.processingFormat, frameCapacity: AVAudioFrameCount(probe.length))!
        try probe.read(into: pb)
        print("PROBE firstRead=\(pb.frameLength)")
        let pb2 = AVAudioPCMBuffer(pcmFormat: probe.processingFormat, frameCapacity: AVAudioFrameCount(probe.length))!
        try probe.read(into: pb2)
        print("PROBE secondRead=\(pb2.frameLength)")
        let samples = try loadAudioFileAs16kMonoFloats(path: url.path)
        XCTAssertEqual(samples.count, 24_000)
        XCTAssertEqual(samples[100], chunk[100], accuracy: 1e-4)
    }

    func testCloseIsIdempotentAndAppendAfterCloseThrows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trackwriter-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try TrackWriter(url: url)
        try writer.append([0, 0, 0, 0])
        writer.close()
        writer.close()
        XCTAssertThrowsError(try writer.append([0]))
    }
}
