import XCTest
import AVFoundation
@testable import WhisperFlow

final class AudioEncoderTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("encoder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    /// A 440 Hz tone through TrackWriter, exactly as a real track is written.
    private func tone(seconds: Double, named name: String) throws -> URL {
        let url = temp.appendingPathComponent(name)
        let writer = try TrackWriter(url: url)
        let frames = Int(seconds * AudioCapture.targetSampleRate)
        var i = 0
        while i < frames {
            let take = min(8_000, frames - i)
            let chunk = (0..<take).map { j in
                Float(sin(2 * .pi * 440 * Double(i + j) / AudioCapture.targetSampleRate)) * 0.5
            }
            try writer.append(chunk)
            i += take
        }
        writer.close()
        return url
    }

    func testTenSecondToneRoundTripsWithTheRightDuration() throws {
        let wav = try tone(seconds: 10, named: "track-b.wav")
        XCTAssertEqual(try AudioEncoder.duration(of: wav), 10.0, accuracy: 0.01)

        let m4a = temp.appendingPathComponent("track-b.m4a")
        try AudioEncoder.encodeM4A(wav: wav, to: m4a)
        XCTAssertTrue(FileManager.default.fileExists(atPath: m4a.path))

        // AAC carries encoder priming, so the decoded length lands a little
        // over the source. Anything near ten seconds means the whole tone
        // went through; a truncated encode would come back well short.
        XCTAssertEqual(try AudioEncoder.duration(of: m4a), 10.0, accuracy: 0.2)

        let file = try AVAudioFile(forReading: m4a)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)

        // 32 kbps mono: ten seconds is about 40 KB, and must be far smaller
        // than the 640 KB of Float32 WAV it came from.
        let m4aBytes = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: m4a.path)[.size] as? Int)
        let wavBytes = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: wav.path)[.size] as? Int)
        XCTAssertLessThan(m4aBytes, wavBytes / 4)
        XCTAssertGreaterThan(m4aBytes, 5_000)
    }

    func testEncodesOnlyTheRequestedSlice() throws {
        let wav = try tone(seconds: 20, named: "long.wav")
        let clip = temp.appendingPathComponent("speaker-S2.m4a")
        try AudioEncoder.encodeM4A(wav: wav, to: clip, seconds: 4.0...12.0)
        XCTAssertEqual(try AudioEncoder.duration(of: clip), 8.0, accuracy: 0.2)
    }

    func testSliceBeyondTheEndIsClamped() throws {
        let wav = try tone(seconds: 5, named: "short.wav")
        let clip = temp.appendingPathComponent("clip.m4a")
        try AudioEncoder.encodeM4A(wav: wav, to: clip, seconds: 3.0...30.0)
        XCTAssertEqual(try AudioEncoder.duration(of: clip), 2.0, accuracy: 0.2)
    }

    func testEmptyRangeThrowsRatherThanWritingAZeroLengthFile() throws {
        let wav = try tone(seconds: 3, named: "tiny.wav")
        let clip = temp.appendingPathComponent("none.m4a")
        XCTAssertThrowsError(try AudioEncoder.encodeM4A(wav: wav, to: clip, seconds: 10.0...12.0))
    }

    func testEncodingOverwritesAnExistingFile() throws {
        let wav = try tone(seconds: 6, named: "again.wav")
        let m4a = temp.appendingPathComponent("again.m4a")
        try AudioEncoder.encodeM4A(wav: wav, to: m4a, seconds: 0...6)
        try AudioEncoder.encodeM4A(wav: wav, to: m4a, seconds: 0...3)
        XCTAssertEqual(try AudioEncoder.duration(of: m4a), 3.0, accuracy: 0.2)
    }
}
