# Whisper Flow

Fully local macOS voice dictation (privacy-first Wispr Flow clone). Menu-bar accessory app: mic → streaming Parakeet transcription (Core ML on the Neural Engine, via [FluidAudio](https://github.com/FluidInference/FluidAudio)) → LLM cleanup on stop → text inserted at the cursor in whatever app has focus. No audio or text ever leaves the machine; the only network access is the one-time Parakeet model download from HuggingFace and calls to a local Ollama server on 127.0.0.1.

## Build

The repo lives on OneDrive, so SwiftPM's scratch dir must stay outside it:

```sh
swift build --scratch-path "$HOME/.cache/whisperflow-build"      # debug build
scripts/make-app.sh                                              # release build + signed WhisperFlow.app
```

First run downloads the Parakeet TDT 0.6B v3 Core ML models (~600 MB, cached in `~/.cache/fluidaudio` thereafter).

## Run

Whisper Flow is a menu-bar accessory app (`LSUIElement`) — it never shows a Dock icon or a window at launch. Look for the mic icon in the menu bar.

- **GUI:** `open WhisperFlow.app`. Use the menu to check status, open the transcript window, grant Accessibility, or quit.
- **Dictation, three ways:**
  - **Push-to-talk:** hold **Right Option**, speak, release to stop. (Left Option is untouched — still safe for special characters.)
  - **Hands-free toggle:** **⌃⌥Space** to start, press again to stop.
  - **Window button:** open the transcript window from the menu and use Record/Stop as in M1 — text stays in the window instead of being inserted.
- **CLI test mode (no mic needed):**

```sh
WhisperFlow.app/Contents/MacOS/WhisperFlow --transcribe-file /path/to/audio.wav [--raw-only]
```

Prints `RAW:`, `CLEANED (<backend>):`, and `TIMING: stt=<ms> cleanup=<ms>`, then exits.

## Permissions (first launch)

1. **Microphone** — standard TCC prompt on first dictation attempt.
2. **Accessibility** — required for global hotkeys and cursor insertion. Prompted once automatically at launch; if dismissed, grant later via the menu bar's "Grant Accessibility…" item (System Settings → Privacy & Security → Accessibility → enable Whisper Flow). Without it, hotkeys and insertion silently no-op — dictated text is left on the clipboard with a "copied — paste with ⌘V" note instead.

## Hotkeys and insertion

- **Push-to-talk (Right Option, keyCode 61):** watched via both a global and a local `NSEvent` flagsChanged monitor, so it also fires when Whisper Flow's own UI has focus. Holds shorter than 150 ms are treated as accidental taps and ignored.
- **Hands-free toggle (⌃⌥Space):** registered as a Carbon system hot key, so it works everywhere regardless of focus.
- **Insertion:** on stop, the cleaned text is placed on the general pasteboard, a synthetic ⌘V is posted to the system HID event tap, and the previous clipboard contents are restored ~0.3 s later. The app never activates itself, so the target app keeps focus throughout. A floating, non-activating status pill (bottom-center of the screen with the cursor) shows Listening → Cleaning → Inserted for hotkey/toggle dictations; window-button dictations don't show the pill and keep the M1 in-window behaviour.

## Cleanup backends

`CleanupRouter` picks the first available backend at each dictation:

1. **FoundationModels** — Apple Intelligence on-device model (macOS 26+, only when Apple Intelligence is enabled).
2. **Ollama** — `llama3.2:3b` at `http://127.0.0.1:11434`, temperature 0, `keep_alive 30m`.
3. **Passthrough** — returns the raw transcript unchanged.

Guard rails: empty output, output longer than 1.6× the raw text, errors, or a 10 s timeout all fall back to the raw transcript (logged to stderr and the usage log).

## Swapping the STT backend

`STT/TranscriptionBackend.swift` defines the streaming protocol (prepare → startStream → feed → finishStream, plus batch `transcribeFile`). `ParakeetBackend` is the live implementation; `WhisperBackend` is a stub showing where a whisper.cpp/WhisperKit buffer+commit wrapper would conform.

## Telemetry

Each dictation appends one JSONL line to `~/Library/Application Support/WhisperFlow/usage.jsonl`:
`{ts, mode: "ptt"|"toggle"|"window"|"file", audio_seconds, raw_chars, cleaned_chars, stt_ms, cleanup_ms, cleanup_backend}`. Local file only. If a legacy `~/Library/Application Support/Murmur/usage.jsonl` exists from before the app was renamed, its contents are migrated into the new location on first launch.

## Roadmap

- **M2 (done):** menu-bar-only mode, global hotkeys (push-to-talk + hands-free toggle), system-wide cursor insertion, floating status pill.
- **M3:** per-app dictionaries, custom vocabulary, richer error surfacing.
