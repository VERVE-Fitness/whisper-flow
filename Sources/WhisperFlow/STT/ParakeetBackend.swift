import Foundation
import AVFoundation
import FluidAudio

/// Parakeet TDT 0.6B v3 (multilingual) via FluidAudio, running as Core ML models
/// on the Neural Engine. Batch transcription uses `AsrManager` directly; streaming
/// uses `SlidingWindowAsrManager`, which wraps the same v3 model with an
/// overlapping-window pseudo-streaming scheme and exposes confirmed/volatile
/// transcript updates.
final class ParakeetBackend: TranscriptionBackend, @unchecked Sendable {
    let name = "parakeet-v3"
    private(set) var isPrepared = false

    private var asrModels: AsrModels?
    private var batchManager: AsrManager?

    private var streamingManager: SlidingWindowAsrManager?
    private var streamUpdatesTask: Task<Void, Never>?
    private var onPartial: (@Sendable (TranscriptionPartial) -> Void)?

    func prepare() async throws {
        try await prepare(onProgress: nil)
    }

    /// `onProgress` receives a short human-readable status ("Downloading
    /// speech model 37%", "Compiling speech model…") so the menu bar can
    /// show what a first launch is actually doing during the ~600MB download
    /// and the Core ML compile that follows it -- on an M1 that's a couple of
    /// minutes of otherwise-silent "Loading…".
    func prepare(onProgress: (@Sendable (String) -> Void)?) async throws {
        guard !isPrepared else { return }
        // Downloads (~600MB, one-time, cached under ~/.cache/fluidaudio thereafter)
        // then loads the v3 multilingual Parakeet TDT models.
        let models = try await AsrModels.downloadAndLoad(version: .v3) { progress in
            guard let onProgress else { return }
            switch progress.phase {
            case .listing:
                onProgress("Preparing speech model download…")
            case .downloading(let done, let total):
                let pct = Int((progress.fractionCompleted * 100).rounded())
                onProgress("Downloading speech model \(pct)% (\(done)/\(total) files)")
            case .compiling(let name):
                onProgress("Compiling speech model (\(name))…")
            }
        }
        onProgress?("Loading speech model…")
        self.asrModels = models

        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.batchManager = manager

        isPrepared = true
    }

    // MARK: - Streaming

    func startStream(onPartial: @escaping @Sendable (TranscriptionPartial) -> Void) async throws {
        guard let models = asrModels else { throw TranscriptionError.notPrepared }
        self.onPartial = onPartial

        let manager = SlidingWindowAsrManager(config: .default)
        try await manager.loadModels(models)
        try await manager.startStreaming(source: .microphone)
        self.streamingManager = manager

        streamUpdatesTask = Task { [weak self] in
            guard let self else { return }
            // Each `update` marks whether the emitted text is confirmed or still
            // volatile; the manager's own confirmed/volatileTranscript properties
            // already accumulate that split, so we just re-read them per event.
            for await _ in await manager.transcriptionUpdates {
                let confirmed = await manager.confirmedTranscript
                let volatile = await manager.volatileTranscript
                self.onPartial?(TranscriptionPartial(confirmedText: confirmed, volatileText: volatile))
            }
        }
    }

    func feed(samples: [Float]) async throws {
        guard let manager = streamingManager else { throw TranscriptionError.notPrepared }
        guard let buffer = Self.makeBuffer(from: samples) else { return }
        await manager.streamAudio(buffer)
    }

    func finishStream() async throws -> String {
        guard let manager = streamingManager else { throw TranscriptionError.notPrepared }
        let updates = streamUpdatesTask
        let text = try await manager.finish()
        updates?.cancel()
        await manager.cleanup()
        // Only clear the session fields if they still refer to THIS session.
        // A finish that was abandoned by the caller (watchdog, cancel) can
        // complete after a newer startStream has installed its own manager;
        // nil-ing that one would silently break the live dictation.
        if streamingManager === manager {
            streamingManager = nil
            streamUpdatesTask = nil
            onPartial = nil
        }
        return text
    }

    // MARK: - Batch (CLI)

    func transcribeFile(samples: [Float]) async throws -> String {
        try await transcribeFileWithConfidence(samples: samples).text
    }

    /// FluidAudio's `ASRResult.confidence` is the average of token-level TDT
    /// softmax probabilities for the whole utterance: ~0.1 for an empty/
    /// near-silent transcription up to 1.0 for full confidence (see
    /// `AsrManager+TokenProcessing.swift: calculateConfidence` in the
    /// FluidAudio package). Decoding the complete retained buffer here (vs.
    /// the sliding-window streaming path) gives a real per-clip score to gate
    /// short/clipped dictations on.
    func transcribeFileWithConfidence(samples: [Float]) async throws -> (text: String, confidence: Float) {
        guard let manager = batchManager else { throw TranscriptionError.notPrepared }
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        return (result.text, result.confidence)
    }

    /// Long-form batch transcription straight from a WAV on disk (memory-
    /// mapped and chunked inside FluidAudio, so an hour-long track is fine).
    /// Returns the text plus per-token timings when the library provides
    /// them; the meeting transcriber needs the timings to place words against
    /// the diariser's speaker spans.
    func transcribeLong(url: URL) async throws -> (text: String, tokens: [(token: String, start: Double, end: Double)]) {
        guard let manager = batchManager else { throw TranscriptionError.notPrepared }
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribeDiskBacked(url, decoderState: &decoderState)
        let tokens = (result.tokenTimings ?? []).compactMap { t -> (token: String, start: Double, end: Double)? in
            guard !t.token.isEmpty, t.token != "<blank>", t.token != "<pad>" else { return nil }
            // FluidAudio 0.15.6 marks a word boundary with a LEADING SPACE
            // (" Hi", " N", "at", "han", ","), not the SentencePiece "▁"
            // that TranscriptBuilder groups on. Normalise here, at the
            // library boundary, so the transcript grouper keeps one
            // convention and stays independent of the ASR package.
            let token = t.token.hasPrefix(" ") ? "\u{2581}" + t.token.dropFirst() : t.token
            return (token: token, start: t.startTime, end: t.endTime)
        }
        return (result.text, tokens)
    }

    // MARK: - Helpers

    private static func makeBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: AudioCapture.targetSampleRate,
                                         channels: 1,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { src in
            channel.update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }
}
