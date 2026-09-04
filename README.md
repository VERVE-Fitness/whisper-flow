# Whisper Flow

Fully local macOS voice dictation (privacy-first Wispr Flow clone). Menu-bar accessory app: mic → streaming Parakeet transcription (Core ML on the Neural Engine, via [FluidAudio](https://github.com/FluidInference/FluidAudio)) → LLM cleanup on stop → text inserted at the cursor in whatever app has focus. No audio or text ever leaves the machine. Network access: the one-time Parakeet model download from HuggingFace, the one-time `llama3.2:3b` pull through the embedded Ollama, calls to that Ollama on 127.0.0.1, and a request to the GitHub releases API every 6 h to show "Update available" in the menu.

Requires Apple silicon and macOS 14 (Sonoma) or newer.

## Build

The repo lives on OneDrive, so SwiftPM's scratch dir must stay outside it:

```sh
swift build --scratch-path "$HOME/.cache/whisperflow-build"      # debug build
swift test  --scratch-path "$HOME/.cache/whisperflow-build"      # unit tests
scripts/make-app.sh                                              # release build + signed WhisperFlow.app + zip
```

`make-app.sh` embeds the Homebrew Ollama runtime (`brew install ollama` first), prunes the dangling MLX symlinks Homebrew ships, signs every nested binary then the bundle, stamps the git commit into `Info.plist` (`WFGitCommit`, shown in the menu bar), verifies the signature, and writes the release archive to `~/.cache/whisperflow-build/WhisperFlow.zip`. It never writes the zip into the repo.

First run downloads the Parakeet TDT 0.6B v3 Core ML models (~600 MB, cached in `~/.cache/fluidaudio` thereafter) and, if `llama3.2:3b` is not already in `~/.ollama/models`, pulls it (~2 GB) through the embedded Ollama. Both show progress in the menu bar; nothing needs Terminal.

## Release

Every release gets its own tag carrying the short commit sha, and the same zip under BOTH asset names (old shared links use `WhisperFlow-release.zip`):

```sh
SHA=$(git rev-parse --short HEAD); TAG="v$(date +%Y.%m.%d)-$SHA"
gh release create "$TAG" --title "Whisper Flow $TAG" --notes-file notes.md \
  "$HOME/.cache/whisperflow-build/WhisperFlow.zip" \
  "$HOME/.cache/whisperflow-build/WhisperFlow.zip#WhisperFlow-release.zip"
```

The download page (`flow.vervefitness.ai/whisper`) links to `releases/latest/download/WhisperFlow.zip`, so it never needs editing for a new build. The in-app update check compares the latest tag's sha suffix with `WFGitCommit`, so tags must keep the `-<sha>` suffix and assets must not be rebuilt in place under an old tag.

## Run

Whisper Flow is a menu-bar accessory app (`LSUIElement`) — it never shows a Dock icon or a window at launch. Look for the mic icon in the menu bar.

- **GUI:** `open WhisperFlow.app`. Use the menu to check status, pick a microphone, open the transcript window, grant Accessibility, copy diagnostics, or quit.
- **Dictation, three ways:**
  - **Push-to-talk:** hold **Right Option**, speak, release to stop. (Left Option is untouched — still safe for special characters.)
  - **Hands-free:** **⌘ + Right Option** to start; any key finishes, esc cancels.
  - **Window button:** open the transcript window from the menu and use Record/Stop — text stays in the window instead of being inserted.
- **CLI modes (no GUI):**

```sh
WhisperFlow.app/Contents/MacOS/WhisperFlow --transcribe-file /path/to/audio.wav [--raw-only]
WhisperFlow.app/Contents/MacOS/WhisperFlow --simulate-streaming /path/to/audio.wav
WhisperFlow.app/Contents/MacOS/WhisperFlow --list-input-devices
WhisperFlow.app/Contents/MacOS/WhisperFlow --capture-test 6 [--input builtin|default|<device uid>] [--no-stt]
```

`--capture-test` records through the same `AudioCapture` path a live dictation uses and prints buffer counts once a second, so you can switch the system input device mid-run (`SwitchAudioSource -t input -s "BlackHole 2ch"`) and watch it keep going.

## Microphone

Whisper Flow records from the **Mac's built-in microphone by default, even when AirPods or another Bluetooth headset are connected**. Opening a Bluetooth mic forces the headset from A2DP down to the Hands-Free Profile: a 1–3 s switch during which the input delivers silence or changes format, narrowband audio that Parakeet transcribes worse, and phone-quality playback for the duration. The engine input is pinned via `kAudioOutputUnitProperty_CurrentDevice` so a headset connecting mid-dictation cannot yank it. The menu's **Microphone** submenu offers "System default (follows AirPods / headsets)" and every input device by name; the choice is stored in `UserDefaults` (`inputDeviceSelection`) by device UID.

**Lid closed:** macOS switches the built-in mic off in clamshell mode (it still enumerates and still delivers buffers, all exactly zero). `AudioDevices.resolve(.builtIn)` reads `AppleClamshellState` from IOPMrootDomain and falls back to the system default while the lid is shut; the menu says "lid closed, using system default".

If the engine actually stops under a running capture (`AVAudioEngineConfigurationChange` with `isRunning == false`, or no buffer for 2 s), `AudioCapture` tears it down and rebuilds it on the same output stream, at most three times per 5 s window. A pinned engine also receives that notification when the *system default* changes, without stopping; those are ignored (rebuilding on them caused a rebuild storm and a dead capture). Events are logged to the `audio-capture` category of `com.niallwogan.whisperflow` and mirrored to stderr as `[capture] …`.

## Permissions (first launch)

1. **Microphone** — standard TCC prompt on first dictation attempt.
2. **Accessibility** — required for global hotkeys and cursor insertion. Prompted once automatically at launch; if dismissed, grant later via the menu bar's "Grant Accessibility…" item. Without it, hotkeys and insertion silently no-op — dictated text is left on the clipboard with a "copied — paste with ⌘V" note instead.

The app is signed with an Apple Development certificate, not Developer ID, and is not notarised: on macOS 15+ the first launch is blocked and must be allowed from System Settings → Privacy & Security → "Open Anyway" (Control-click → Open no longer works there). The download page walks through it.

## Hotkeys and insertion

- **Push-to-talk (Right Option, keyCode 61):** watched via both a global and a local `NSEvent` flagsChanged monitor, so it also fires when Whisper Flow's own UI has focus. Holds shorter than 150 ms are treated as accidental taps and ignored. The mic stays open 250 ms after release so the last word isn't clipped.
- **Hands-free (⌘ + Right Option):** a CGEvent tap swallows the finishing key press.
- **Insertion:** on stop, the cleaned text is placed on the general pasteboard, a synthetic ⌘V is posted to the system HID event tap, and the previous clipboard contents are restored ~0.3 s later. The app never activates itself, so the target app keeps focus throughout. A floating, non-activating status pill shows Listening → Cleaning → Inserted (or "Didn't catch that" / "Didn't work: …").
- **Watchdog:** if a stop is still in "Cleaning…" after 45 s, the state machine is reset so the next dictation works, and the pill says so.

## Cleanup backends

`CleanupRouter` picks the first available backend at each dictation:

1. **FoundationModels** — Apple Intelligence on-device model (macOS 26+, only when Apple Intelligence is enabled).
2. **Ollama** — `llama3.2:3b` on the app-owned server at `http://127.0.0.1:11535`, temperature 0, `keep_alive 30m`. The model is warmed as soon as the server reports ready, and the router waits 25 s instead of 10 s when the model is not resident (`/api/ps`), so a cold first dictation on an 8 GB M1 no longer falls back to raw.
3. **Passthrough** — returns the raw transcript unchanged.

Guard rails: empty output, output longer than 1.6× the raw text, too few content words kept, too many new words, a dropped question mark, errors, or the timeout all fall back to the raw transcript (logged to stderr and the usage log). Deterministic passes (dictionary corrections, self-correction stripping, digit formatting) run on every path. Whole-sentence cue-led replacement ("… by Tuesday. Actually make that Wednesday.") only deletes the previous sentence when the replacement is at least half its length; shorter remainders are word-level swaps left for the LLM.

## Swapping the STT backend

`STT/TranscriptionBackend.swift` defines the streaming protocol (prepare → startStream → feed → finishStream, plus batch `transcribeFile`). `ParakeetBackend` is the live implementation; `WhisperBackend` is a stub showing where a whisper.cpp/WhisperKit buffer+commit wrapper would conform.

## Telemetry and diagnostics

Each dictation appends one JSONL line to `~/Library/Application Support/WhisperFlow/usage.jsonl`:
`{ts, mode, audio_seconds, raw_chars, cleaned_chars, stt_ms, cleanup_ms, cleanup_backend, raw_text, cleaned_text, input_device, stt_confidence, rms, outcome}`. Local file only. The embedded Ollama logs to `ollama.log` in the same folder. **Copy diagnostics** in the menu puts version, macOS, chip, RAM, permissions, microphone setup, the last eight dictations (no transcript text) and the Ollama log tail on the clipboard.

## Roadmap

- **Developer ID signing + notarisation** so first launch is one click (needs the Account Holder to create the certificate).
- **Sparkle-style in-app update** instead of "download again from the page".
