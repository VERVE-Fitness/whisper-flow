# Murmur

Fully local macOS voice dictation (privacy-first Wispr Flow clone). Milestone 1: a windowed prototype — mic → streaming Parakeet transcription (Core ML on the Neural Engine, via [FluidAudio](https://github.com/FluidInference/FluidAudio)) → LLM cleanup on stop → text in the app window. No audio or text ever leaves the machine; the only network access is the one-time Parakeet model download from HuggingFace and calls to a local Ollama server on 127.0.0.1.

## Build

The repo lives on OneDrive, so SwiftPM's scratch dir must stay outside it:

```sh
swift build --scratch-path "$HOME/.cache/murmur-build"          # debug build
scripts/make-app.sh                                              # release build + signed Murmur.app
```

First run downloads the Parakeet TDT 0.6B v3 Core ML models (~600 MB, cached in `~/.cache/fluidaudio` thereafter).

## Run

- **GUI:** `open Murmur.app` — Record, speak, Stop. Raw partials stream live; the cleaned text appears after stop. Copy button puts it on the clipboard.
- **CLI test mode (no mic needed):**

```sh
Murmur.app/Contents/MacOS/Murmur --transcribe-file /path/to/audio.wav [--raw-only]
```

Prints `RAW:`, `CLEANED (<backend>):`, and `TIMING: stt=<ms> cleanup=<ms>`, then exits.

## Cleanup backends

`CleanupRouter` picks the first available backend at each dictation:

1. **FoundationModels** — Apple Intelligence on-device model (macOS 26+, only when Apple Intelligence is enabled).
2. **Ollama** — `llama3.2:3b` at `http://127.0.0.1:11434`, temperature 0, `keep_alive 30m`.
3. **Passthrough** — returns the raw transcript unchanged.

Guard rails: empty output, output longer than 1.6× the raw text, errors, or a 10 s timeout all fall back to the raw transcript (logged to stderr and the usage log).

## Swapping the STT backend

`STT/TranscriptionBackend.swift` defines the streaming protocol (prepare → startStream → feed → finishStream, plus batch `transcribeFile`). `ParakeetBackend` is the live implementation; `WhisperBackend` is a stub showing where a whisper.cpp/WhisperKit buffer+commit wrapper would conform.

## Telemetry

Each dictation appends one JSONL line to `~/Library/Application Support/Murmur/usage.jsonl`:
`{ts, mode: "mic"|"file", audio_seconds, raw_chars, cleaned_chars, stt_ms, cleanup_ms, cleanup_backend}`. Local file only.

## Roadmap

- **M2:** global hotkey (push-to-talk), insertion into the frontmost app.
- **M3:** menu-bar-only mode, per-app dictionaries.
