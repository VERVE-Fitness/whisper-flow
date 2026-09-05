# Whisper Flow

Fully local macOS voice dictation (privacy-first Wispr Flow clone). Menu-bar accessory app: mic → streaming Parakeet transcription (Core ML on the Neural Engine, via [FluidAudio](https://github.com/FluidInference/FluidAudio)) → LLM cleanup on stop → text inserted at the cursor in whatever app has focus. No audio or text ever leaves the machine. Network access: the one-time Parakeet model download from HuggingFace, the one-time `llama3.2:3b` pull through the embedded Ollama, calls to that Ollama on 127.0.0.1, a request to the GitHub releases API every 6 h to show "Update available" in the menu, and the release zip itself when somebody clicks that menu item.

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

## Updating

**Nothing has to be uninstalled first.** When a release is published, the menu bar shows **Update available (v...)**. Clicking it does the whole thing (Niall, 5 Sep 2026: "do I have to uninstall the old version before installing new versions, or can you make a fix so it isn't necessary?"):

1. Downloads `releases/latest/download/WhisperFlow.zip`, with the pill showing "Downloading update 43%".
2. Unpacks it with `ditto -x -k`.
3. Checks the new copy with `spctl --assess --type exec`: it has to be accepted, and it has to be a Developer ID build.
4. Checks the new copy's `WFGitCommit` against the sha in the release tag (`vYYYY.MM.DD-<sha>`), so an old asset re-uploaded under a new tag is refused.
5. Moves the old copy to the Trash (not deleted: a bad build is one drag away from being undone) and moves the new one into place. A copy running from outside an Applications folder is installed to `/Applications` instead of being replaced where it stands.
6. Restarts, and the copy that comes back says "Updated to v...".

Every step writes one `[update] ...` line to stderr. Any failure leaves the running app untouched, puts "Update failed: `<reason>`, download from Flow" on the pill and opens the download page. Nothing happens without the click: there is no auto-install and no background download.

**Manual path, still there.** **Download update from Flow…** in the same menu opens `flow.vervefitness.ai/whisper` as before: quit Whisper Flow, unzip, drag `WhisperFlow.app` into Applications and click Replace. Use it when the one-click install cannot finish, for example on a Mac where `/Applications` is not writable.

**Two copies, and stale copies.** Only one Whisper Flow runs at a time. A launch that finds another copy of the same bundle identifier running from a different folder compares `WFBuildDate` (then `CFBundleVersion`): the newer build asks the older one to quit and forces it after 3 s, and an older build launching against a newer one quits itself. Decisions are logged as `[instance] ...`. A copy running from Downloads, the Desktop or a mounted disk image is offered a move on launch, once per place it is run from: "Move Whisper Flow to Applications?" with **Move** and **Not now**; the declined paths are remembered in `UserDefaults` under `declinedMoveToApplicationsPaths`.

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

**After an update:** macOS drops the Accessibility grant whenever the signed binary changes, which used to read as the app quietly refusing to type. On the first launch of a new `CFBundleShortVersionString`, if the grant is gone, the app opens the system prompt itself, once, and the pill says "Update installed: grant Accessibility again". The version it last checked is stored under `UserDefaults` `lastAccessibilityCheckVersion`. A first ever install is not treated as an update: it gets the ordinary first-run prompt.

The app is signed with an Apple Development certificate, not Developer ID, and is not notarised: on macOS 15+ the first launch is blocked and must be allowed from System Settings → Privacy & Security → "Open Anyway" (Control-click → Open no longer works there). The download page walks through it.

## Hotkeys and insertion

- **Push-to-talk (Right Option, keyCode 61):** watched via both a global and a local `NSEvent` flagsChanged monitor, so it also fires when Whisper Flow's own UI has focus. Holds shorter than 150 ms are treated as accidental taps and ignored. The mic stays open 400 ms after release so the last word isn't clipped (see **Phrases and the last two seconds** below).
- **Hands-free (⌘ + Right Option):** a CGEvent tap swallows the finishing key press.
- **Insertion:** on stop, the cleaned text is placed on the general pasteboard, a synthetic ⌘V is posted to the system HID event tap, and the previous clipboard contents are restored ~0.3 s later. The app never activates itself, so the target app keeps focus throughout. A floating, non-activating status pill shows Listening → Cleaning → Inserted (or "Didn't catch that" / "Didn't work: …").
- **Watchdog:** if a stop is still in "Cleaning…" after 45 s, the state machine is reset so the next dictation works, and the pill says so.

## Cleanup backends

`CleanupRouter` picks the first available backend at each dictation:

1. **FoundationModels** — Apple Intelligence on-device model (macOS 26+, only when Apple Intelligence is enabled).
2. **Ollama** — `llama3.2:3b` on the app-owned server at `http://127.0.0.1:11535`, temperature 0, `keep_alive 30m`. The model is warmed as soon as the server reports ready, and the router waits 25 s instead of 10 s when the model is not resident (`/api/ps`), so a cold first dictation on an 8 GB M1 no longer falls back to raw.
3. **Passthrough** — returns the raw transcript unchanged.

Guard rails: empty output, output longer than 1.6× the raw text, too few content words kept, too many new words, a dropped question mark, errors, or the timeout all fall back to the raw transcript (logged to stderr and the usage log). Deterministic passes (dictionary corrections, self-correction stripping, digit formatting) run on every path. Whole-sentence cue-led replacement ("… by Tuesday. Actually make that Wednesday.") only deletes the previous sentence when the replacement is at least half its length; shorter remainders are word-level swaps left for the LLM.

## Meetings (week 3: recorded here or by a bot, kept in Flow)

**Record meeting…** in the menu records both sides of a call. At Stop the Mac transcribes it, works out who spoke, and sends the audio, the transcript and the speakers to Flow, which writes the summary and the proposed actions. You end up with the meeting at flow.vervefitness.ai/meetings and a copy of everything in a folder on this Mac.

### Connect this Mac first

"Record meeting…" does nothing until this Mac is connected, because the consent wording promises the recording reaches VERVE's system and it has to be true.

1. Open **flow.vervefitness.ai/whisper-settings** (the menu has "Whisper Flow settings…").
2. Under **Connect this Mac**, name the Mac and click **Create connection**.
3. Click **Open in Whisper Flow**. That is a `whisperflow://connect?token=…&server=…` link; the app takes the token, puts it in the login keychain and says "Connected to Flow as <your name>" on the pill.

The token is shown once. It never appears in a log, a preference file or the transcript folder. The menu says "Flow: connected as …" or "Flow: not connected". Revoke a Mac from the same page.

For a preview deployment: `defaults write com.niallwogan.whisperflow flowServer https://your-preview-url` before clicking the link, or let the link carry its own `server=`.

### When VERVE Notes already has the meeting

Flow can send a bot (VERVE Notes) to a meeting for you. Recording the same
call here as well would give you two of everything: two summaries, two sets of
draft actions, two recordings to delete. So when you click "Record meeting…"
the app asks Flow what its bots are doing first.

If a bot is joining or in the call now, or is scheduled to join within ten
minutes, you get this instead of the consent gate:

> VERVE Notes is already recording <title> into Flow. Recording here as well
> would give you two copies.

with **Let the bot do it** (the default button) and **Record here anyway**,
which carries on to the normal consent gate. The check has a two second budget
and no retry: if Flow is slow or unreachable you get the consent gate exactly
as before. Every decision is on stderr as a `[bot]` line.

### The calendar prompt

While this Mac is connected, awake and not already recording, the app reads
your calendar every sixty seconds and offers to record the meeting you are
about to walk into. A meeting qualifies when it starts in the next one to two
minutes, has at least one other person on it, and has no bot on the way.

The notification reads *"Record Nathan 1:1?"* / *"With Nathan, Giuseppe and
Ella. Starts in a minute."* with **Record** and **Not this one**. Record opens
the normal consent gate with the title and the attendee names already filled
in, and the recording carries the calendar event id so Flow can hang it off
the event.

- An event with a bot scheduled, joining, in a call or ingesting is the bot's
  job and is never prompted for. A bot that failed recorded nothing, so that
  meeting is offered after all.
- An in-person meeting has no join link, so it never has a bot, and it always
  qualifies. That is the case the prompt exists for.
- Each event is asked about once a day, so a meeting sitting in the window for
  a full minute does not prompt twice.
- The poll pauses while the Mac is asleep, so a machine that wakes at 4pm does
  not fire prompts for meetings that already happened.
- **Meeting prompts** in the menu turns the whole thing off. On by default.
- macOS asks for notification permission once, the first time this Mac
  connects to Flow. If you say no, the same two buttons appear as an alert
  instead, one at a time.

Every decision, taken or skipped, is on stderr as a `[prompt]` line.

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

**Not yet:** the 90-day retention job is installed on the VPS by Fable, not by this app.

### Week-3 dogfood (the prompt and the bot)

```
1. Prompt timing: did the notification arrive about a minute before the meeting, once, and not again?
2. Prompt copy: did the subject and the attendee first names read correctly?
3. Record from the prompt: did the consent gate open with the title and attendees already filled in?
4. Bot overlap: send a bot to a meeting, then click "Record meeting…" in it. Did the alert name the right meeting?
5. Let the bot do it: nothing recorded here, and the bot's recording appears in Flow on its own.
6. In-person meeting with no join link: prompted for, as it should be.
7. Meeting with a bot on the way: NOT prompted for.
8. Turn "Meeting prompts" off: nothing arrives for the rest of the day.
9. Close the lid between two meetings: no stack of late prompts on waking.
```

### Week-3 part 3 dogfood (phrases and the tail)

```
1. Add "Tori" with "it comes out as: tory" on /whisper-settings, open the refresh link, dictate "the tory rack": comes out "Tori".
2. Dictate "that is the story of the quarter": still says "story".
3. Dictate something already right ("the functional trainer"): unchanged, and no [phrase] line on stderr.
4. Pull the network out and dictate: the cached list still corrects, no hang at Stop.
5. Hand-edit a dictation ("vervey pulls" to "VERVE Pulse"), wait ten seconds: it appears in the "Heard wrong" queue in Flow.
6. Dictate a long sentence and let go of the key ON the last syllable: the last word is there.
7. Check stderr for the [stt] streaming N words, batch M words line on every dictation under two minutes.
8. Dictate for three minutes: no batch pass, no eight second wait at Stop.
9. Install a new build without granting Accessibility: the pill says "Update installed: grant Accessibility again", once.
10. Click "Update available (v...)" on a Mac running an older release: the pill counts the download up, the app restarts by itself, and the copy that comes back says "Updated to v...".
11. Run a second copy from Downloads while the one in Applications is running: one of the two quits, the newer one lives, and stderr says which and why.
12. Launch a copy from Downloads: it offers to move to Applications; say "Not now" and it never asks about that copy again.
```

## Phrases and the last two seconds

Two things Niall asked for on 5 Sep 2026: "get better at phrases we use often but it doesn't catch properly", and "sometimes it misses the last 2 seconds of what I say even though I'm holding the key long enough".

### Phrases we say

The phrase list lives in Flow, not on the Mac, so one person's fix reaches everyone. `GET /api/public/whisper/me` returns `phrases: [{phrase, heard_as: [...]}]`, the team's phrases plus your own, and the app caches them at `~/Library/Application Support/WhisperFlow/phrases.json`. The cache is refreshed on connect, at every Stop (2 s, one attempt, fire and forget) and whenever the settings page opens `whisperflow://refresh` after an edit. With no connection the cached list is used exactly as it stands.

`Cleanup/PhraseMatcher.swift` is pure and applies two passes, in `CleanupRouter.finalize` alongside the dictionary corrections, so it runs on **every** path including passthrough and every guard-rail fallback:

1. **Exact.** Each `heard_as` variant is replaced by its phrase, on word boundaries, case-insensitively, longest variant first, in the phrase's own casing. "tory." becomes "Tori."; "verve pulse" becomes "VERVE Pulse".
2. **Fuzzy.** Windows of one to four words within a normalised edit distance of 0.25 of a phrase become that phrase. Three guards keep it off ordinary English: the comparison has to involve at least five characters, a phrase that is itself a common English word (or any single lower-case word) is never a fuzzy target, and a window has to be the same number of words as the phrase. That is why "story" stays "story": two edits over five characters is 0.4, well over the bar.

The phrase list also joins the dictionary hints the LLM sees. At Stop, every meeting transcript segment goes through the same matcher before the transcript is written, so what Flow stores and what the summariser reads say "Tori" too. Every replacement writes one line to stderr:

```
[phrase] "tory" -> "Tori" (exact)
[phrase] "verve pulze" -> "VERVE Pulse" (fuzzy 0.09)
```

**Learning them.** `CorrectionLearner` now learns runs of up to four words replaced by up to four words, not just single words, so "vervey pulls" becoming "VERVE Pulse" is one correction. It keeps them locally as before **and** POSTs each new one to `POST /api/public/whisper/phrases/suggest` with the device token. Nothing becomes a team phrase until a person accepts it in the "Heard wrong" queue on `/whisper-settings`. A Mac with no token never calls at all.

### The missing last two seconds

The sliding-window decoder commits words a window at a time, so the tail of a dictation can still be volatile when the key is released and never gets committed. Three changes together, with the judgement calls kept pure in `STT/TranscriptChoice.swift`:

1. The release hold is 400 ms, up from 250 ms.
2. 600 ms of silence (9,600 zero samples at 16 kHz) is fed into the streaming session **after** the capture stream has drained and before `finish()`, which is what makes the window commit its last words.
3. Any dictation of 120 s or less is re-decoded through the batch path, which never had a window to lose anything from, with an 8 s budget. Its text is used unless it came back with fewer than half the words the streaming pass heard. The batch decoder occasionally drops an out-of-vocabulary opening outright, and a mangled attempt at a product name beats a clean transcript missing it. A failure or a timeout keeps the streaming text.

The existing low-confidence short-clip discard runs off that same single decode, so nothing is ever transcribed twice. Every dictation logs the choice, which is what makes a future truncation visible instead of silent:

```
[stt] streaming 5 words, batch 6 words, using batch
[stt] streaming 8 words, batch 2 words, using streaming
```

## Settings

Menu bar, **Whisper Flow settings…**, or `Cmd+,`. A native window inside the app, so nothing routine needs a browser after this Mac is first connected. Six sections:

| Section | What is in it | With no connection |
|---|---|---|
| **Dictation** | Microphone, what the keys do, Accessibility, Auto-learn corrections, Start at login, which cleanup model is running | All of it works |
| **Meetings** | Connected as, Connect this Mac, Disconnect; Meeting prompts; Recognise my voice; Meeting bot mode and bot name; the Who is who queue with a play button on each clip | The connection block only |
| **Dictionary and phrases** | The dictionary this Mac keeps; the team phrase list with what each phrase comes out as; the Heard wrong queue | The dictionary only |
| **Snippets** | Mine and the team's: a cue, and the text it types | Local snippets only |
| **Insights** | Thirty days of dictations and words a day, minutes of talking, average words a dictation, and the typing time saved at 40 words a minute | All of it works |
| **About** | The build, the update button, links to the Whisper and meetings pages on Flow | The build line only |

Everything the window reads and writes goes through the device token, at `GET`/`POST /api/public/whisper/settings`, which is the same payload and the same action names the web page at `/whisper-settings` uses. The web page stays: it is where a Mac is connected in the first place, and it is the fallback. Device tokens can never mint or revoke device tokens; that stays on the web.

The window never blanks a list because Flow was unreachable. A block that needs the server says so in a sentence, and the local half carries on.

### Snippets

Say the cue on its own, or with "insert" in front of it, and the text is typed word for word, skipping cleanup. `GET /api/public/whisper/me` carries `snippets: [{cue, text, scope}]`, the team's plus your own, cached at `~/Library/Application Support/WhisperFlow/snippets.json` and refreshed at connect, at launch and at every Stop.

What dictation matches against is the three lists merged, in this order: team, then your own from Flow, then whatever is on this Mac. **Local wins a cue clash**, so a snippet edited here works this second and an offline Mac behaves exactly as it did before any of this existed. A personal snippet added in the window is saved on this Mac and sent to Flow as a person-scoped row, so a second Mac gets it too.

## Swapping the STT backend

`STT/TranscriptionBackend.swift` defines the streaming protocol (prepare → startStream → feed → finishStream, plus batch `transcribeFile`). `ParakeetBackend` is the live implementation; `WhisperBackend` is a stub showing where a whisper.cpp/WhisperKit buffer+commit wrapper would conform.

## Telemetry and diagnostics

Each dictation appends one JSONL line to `~/Library/Application Support/WhisperFlow/usage.jsonl`:
`{ts, mode, audio_seconds, raw_chars, cleaned_chars, stt_ms, cleanup_ms, cleanup_backend, raw_text, cleaned_text, input_device, stt_confidence, rms, outcome}`. Local file only. The embedded Ollama logs to `ollama.log` in the same folder. **Copy diagnostics** in the menu puts version, macOS, chip, RAM, permissions, microphone setup, the last eight dictations (no transcript text) and the Ollama log tail on the clipboard.

## Roadmap

- **Developer ID signing + notarisation** so first launch is one click (needs the Account Holder to create the certificate).
- ~~**Sparkle-style in-app update** instead of "download again from the page".~~ Done 5 Sep 2026: see **Updating**.
