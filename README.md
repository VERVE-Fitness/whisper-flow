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

Notarisation credentials: export `NOTARY_KEY` (path to the App Store Connect API `.p8`), `NOTARY_KEY_ID` and `NOTARY_ISSUER` before `scripts/make-app.sh` (the AIOS `.env` carries them as `APP_STORE_CONNECT_*`). Without them the script falls back to a notarytool keychain profile named `whisperflow-notary`. The Developer ID Application certificate lives in the login keychain (created 4 Sep 2026 by Niall in Xcode); when it is present the build is signed with it, hardened runtime on, notarised and stapled, and Gatekeeper opens it with a double-click.


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

## Meetings (week 2: recorded here, kept in Flow)

**Record meeting…** in the menu records both sides of a call. At Stop the Mac transcribes it, works out who spoke, and sends the audio, the transcript and the speakers to Flow, which writes the summary and the proposed actions. You end up with the meeting at flow.vervefitness.ai/meetings and a copy of everything in a folder on this Mac.

### Connect this Mac first

"Record meeting…" does nothing until this Mac is connected, because the consent wording promises the recording reaches VERVE's system and it has to be true.

1. Open **flow.vervefitness.ai/whisper-settings** (the menu has "Whisper Flow settings…").
2. Under **Connect this Mac**, name the Mac and click **Create connection**.
3. Click **Open in Whisper Flow**. That is a `whisperflow://connect?token=…&server=…` link; the app takes the token, puts it in the login keychain and says "Connected to Flow as <your name>" on the pill.

The token is shown once. It never appears in a log, a preference file or the transcript folder. The menu says "Flow: connected as …" or "Flow: not connected". Revoke a Mac from the same page.

For a preview deployment: `defaults write com.niallwogan.whisperflow flowServer https://your-preview-url` before clicking the link, or let the link carry its own `server=`.

### Wear headphones

Two tracks are recorded: track A is your microphone, track B is whatever the Mac is playing (the other side of the call). Out loud through the speakers, your microphone hears their side as well, so both tracks carry the same words and the speaker names get mixed up. Headphones keep the two apart.

### Consent gate

Every recording passes through it, there is no auto-record, and the wording version you saw (`consent-v2`) plus the timestamp is written into `meeting.json` and sent with the recording. Cancel is the default button; a cancelled gate records nothing at all. CLI harness runs stamp `consent-v2-cli` so a test run can never be read as a real person agreeing.

### What Stop does

Each stage shows on the pill:

1. Transcribes track A (you) and track B (them) with Parakeet.
2. Separates track B into speakers with the offline diariser, and runs the diariser over track A as well to read your own voice.
3. **Matches each speaker against the voice profiles Flow holds.** A colleague who has been confirmed once, and who has switched on "recognise my voice", is named without anyone being asked again.
4. Cuts an eight second clip of each speaker it could not name, so the confirmer on the settings page hears the voice.
5. Encodes both tracks to AAC in .m4a, 32 kbps mono, about 14 MB an hour.
6. Uploads: `track-a.m4a`, `track-b.m4a`, the clips, `transcript.json`, `meeting.json`, then posts the manifest. The pill counts: "Uploading 2 of 5".
7. Waits up to three minutes for Flow's summary ("Summarising in Flow"), writes it into `summary.md`, and says "Done, open in Flow".

Nothing is lost if the network drops. The meeting stays on this Mac with an `upload-state.json`, and the next launch or the next connect picks it up where it stopped.

### What leaves this Mac

| Leaves | Stays here |
|---|---|
| Both tracks as .m4a, the sample clips, `transcript.json`, `meeting.json` | The two WAVs (about 115 MB an hour), which are never uploaded |
| The manifest: title, times, attendees, the consent record, the segments, and one 256-float voice embedding per speaker | `voices.json` and `manifest.json`, the staging files a resumed upload reads |

Flow deletes the audio after 90 days. The transcript and summary are kept. The owner can delete either at any time from Flow.

### Voice recognition

The diariser already produces a 256-dimension embedding for every chunk of speech. The app averages them per speaker, weighted by how long each chunk ran, and compares them with the profiles Flow holds using cosine distance. A match needs a distance under **0.45** and a margin of at least **0.10** over the second closest profile, so two colleagues who sound alike produce a question rather than a coin toss. Every decision is on stderr:

```
[meeting] speaker S1 -> nathan.hall@… (0.31, next 0.58)
[meeting] speaker S2 unmatched (best 0.62)
```

A profile only ever exists for a VERVE staff member who switched on "recognise my voice" on their own settings page, or for the person doing the confirming. Customers and outsiders get a name on that one recording and no stored voiceprint: a voiceprint is sensitive biometric information under the Privacy Act, a name is not. The profiles are cached at `~/Library/Application Support/WhisperFlow/voice-profiles.json` and refreshed at every connect and every Stop. "Forget my voice" on the settings page deletes the profile.

### The folder

`~/Library/Application Support/WhisperFlow/meetings/<id>/`, one per meeting, id shaped `2026-09-05-1432-<8 hex>`:

| File | What it is |
|---|---|
| `meeting.json` | Times, title, attendees, the consent record, status, track lengths, the measured track-B offset, the speaker name map |
| `track-a.wav` / `track-b.wav` | Your microphone and the Mac's output audio, 16 kHz mono Float32. Never uploaded |
| `track-a.m4a` / `track-b.m4a` | The same two tracks as AAC, which is what Flow gets |
| `speaker-S<n>.m4a` | The eight second sample clip for a speaker nobody has named yet |
| `transcript.json` / `transcript.md` | Segments with speaker ids and times; the readable version |
| `voices.json` | Per speaker: seconds, embedding, and who the voice matched |
| `manifest.json` | Exactly what was POSTed to `complete` |
| `upload-state.json` | `pending`, `complete` or `failed`, plus the files already sent |
| `summary.md` | The summary Flow wrote, pulled back down after it lands |

### Track alignment

The microphone is started first and the system tap a second later (starting the tap posts a configuration change that would kill a still-starting mic engine). Each WAV therefore begins at its own zero. The recorder measures the gap, stores it as `trackBOffsetSeconds`, and the transcriber adds it to every track-B time before merging, so the far side lands where it was actually said. Typical measured value on this M4 is 1.03 to 1.08 s.

### Permissions

Microphone (the usual prompt), plus **System Audio Recording**, granted in System Settings → Privacy & Security → Screen & System Audio Recording → "System Audio Recording Only". Without it the tap still runs and `track-b.wav` is silent; a `[capture] system-audio:` note on stderr says so. The system tap needs macOS 14.2; below that the meeting records your microphone only and says so.

### CLI harnesses

The debug binary, `$HOME/.cache/whisperflow-build-scratch/debug/WhisperFlow`:

| Command | What it does |
|---|---|
| `--tap-test <seconds>` | System audio tap only: buffer counts, RMS, gap-fill, transcript |
| `--dual-test <seconds>` | Microphone and tap at the same time, to prove neither starves the other |
| `--record-test <seconds>` | One real recording through `MeetingRecorder`; prints the folder, both track lengths and the measured offset |
| `--transcribe-meeting <id>` | Parakeet over both tracks plus the diariser, prints `transcript.md` |
| `--summarise-meeting <id>` | Summarises on this Mac with a local Anthropic key. Harness only: the GUI never does this, Flow does |
| `--meeting-test <seconds> [--attendees "A,B"] [--no-upload]` | The whole chain: record, transcribe, match, upload, print. `--no-upload` stops at the transcript |

### Week-2 dogfood (Niall, five real meetings)

```
1. Connect: the settings link connected this Mac first time, and the pill named you correctly.
2. Consent alert appeared every time; Cancel was the default; you actually announced the recording.
3. Pill counted up for the whole meeting; dictation with Right Option still worked mid-meeting.
4. Upload: the pill counted files, then said "Done, open in Flow". Time from Stop to Done (target: under 3 minutes for a 30-minute meeting).
5. Speakers: how many were named by voice with nobody asked? How many landed in the settings page queue? Note both counts.
6. Wrong names: any speaker matched to the WRONG colleague? Note it verbatim; that is the number that decides whether 0.45 and 0.10 are right.
7. Sample clips: play one from the settings page. Could you tell who it was in eight seconds?
8. Summary from Flow: are decisions and actions real, not invented? Note any invented item verbatim.
9. Actions: accept one in Flow and check it appears in your Flow actions with status open.
10. Resume: turn the wifi off, stop a meeting, turn it back on. Did it finish on its own?
```

**Not yet:** attendees are typed rather than read from the calendar, and the 90-day retention job is installed on the VPS by Fable, not by this app.

## Swapping the STT backend

`STT/TranscriptionBackend.swift` defines the streaming protocol (prepare → startStream → feed → finishStream, plus batch `transcribeFile`). `ParakeetBackend` is the live implementation; `WhisperBackend` is a stub showing where a whisper.cpp/WhisperKit buffer+commit wrapper would conform.

## Telemetry and diagnostics

Each dictation appends one JSONL line to `~/Library/Application Support/WhisperFlow/usage.jsonl`:
`{ts, mode, audio_seconds, raw_chars, cleaned_chars, stt_ms, cleanup_ms, cleanup_backend, raw_text, cleaned_text, input_device, stt_confidence, rms, outcome}`. Local file only. The embedded Ollama logs to `ollama.log` in the same folder. **Copy diagnostics** in the menu puts version, macOS, chip, RAM, permissions, microphone setup, the last eight dictations (no transcript text) and the Ollama log tail on the clipboard.

## Roadmap

- **Developer ID signing + notarisation** so first launch is one click (needs the Account Holder to create the certificate).
- **Sparkle-style in-app update** instead of "download again from the page".
