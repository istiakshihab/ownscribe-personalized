<img src="Resources/Logo.png" width="128" alt="Earshot icon">

# Earshot

The macOS recorder app for ownscribe.

A native SwiftUI front end for ownscribe (macOS 26+) with a standard macOS look: a frosted window
background (as in System Settings) behind solid grouped sections, and native menus, buttons and sliders.
The window opens sized to the screen and only the transcript and summary scroll. It drives the backend exactly as [docs/engine-protocol.md](../docs/engine-protocol.md) describes:

- **Recording:** `ownscribe session new --json` makes the session folder, then the app spawns
  `ownscribe-audio capture --session DIR --control stdio --mic --mic-auto|--mic-device UID --exclude-bundle com.ownscribe.earshot`,
  sends mixer commands on its stdin and reads events (levels, sources, mic, notices, saved) from its stdout.
  Helper stderr goes to `~/Library/Logs/Earshot/Earshot.log`.
- **Processing:** after `saved`, `ownscribe process DIR --events-fd 3` with the template and the
  Diarization/Summarization switches. Speaker names run `ownscribe speakers DIR --set SPEAKER_00=Name`;
  a template change after a summary runs `ownscribe resummarize DIR --template T`. Cancel sends SIGTERM.
- **Obsidian:** the fourth card files the recording into the vault, following `[obsidian]` in
  config.toml. With `confirm_before_filing = true` (the default) it waits for you: **File to Obsidian…**
  runs `ownscribe file DIR --preview` (Claude drafts the note with the speaker names entered so far) and
  opens a sheet to edit the title, category (which picks the vault folder), tags and text; **File Note**
  runs `ownscribe file DIR --write --edits DIR/vault-edits.json`. With `confirm_before_filing = false` it
  drafts and writes right after processing, like the terminal pipeline. **Open in Obsidian** opens the
  note. `enabled = false` or a missing `vault_dir` turns the card off.
- **History:** the sidebar lists every recording in the save folder by date (Today, Yesterday, Previous
  7 Days, Previous 30 Days, then by month), with search, read straight from the session folders (title from
  session.json, or the slug older recordings carry in their folder name). Opening one loads its stage results,
  transcript (transcript.json, or transcript.md for recordings from the terminal days), speakers, summary and
  vault note into the same panel as a fresh recording, so renaming speakers, re-summarizing and filing work
  on past recordings too; one that was never transcribed offers **Transcribe**. Rows show a spinner while a
  job runs, a warning when a step failed and a check once filed to Obsidian; the context menu has Show in
  Finder, Open Note in Obsidian, Open Recording and Move to Trash (asks first). The standard sidebar button in
  the toolbar folds it away, and the choice is remembered.
- **Setup check:** `ownscribe doctor --json` problems show as banners under the title bar.

## Meeting detection

Earshot notices when a call starts in the Zoom or Microsoft Teams desktop app and offers to record it.
It keeps `ownscribe-audio watch-meetings --control stdio` running, which only reads which apps are using
the mic and speakers ([Meeting watch](../docs/engine-protocol.md#meeting-watch)), so it needs no extra
permission.

- **When a call starts**, a small panel at the top right of the screen (over the call, without taking
  focus) and a banner in the window ask whether to record it: **Record** or **Not now**. **Start
  recording automatically** skips the question; it's off by default. A recording started this way has
  the meeting app as its own source, next to the mic and system audio.
- **When the call ends**, a recording Earshot started for it stops by itself (**Stop when the call ends**)
  and then runs the usual pipeline (transcript, speakers, summary, Obsidian). A recording you start
  yourself is never stopped by detection.
- **Closing the window** leaves Earshot running in the menu bar, so it still notices calls. (A utility
  that quits apps when their last window closes, such as Vorssaint's auto-quit, needs Earshot excluded.)
- **Notifications** ("Zoom call ended · transcribing") only appear in a signed build: macOS refuses them
  for the ad-hoc-signed app that `app/build.sh` makes, which is why the prompt is a panel.

Settings ▸ Meetings:

| setting | default |
|---|---|
| Detect Zoom and Teams calls | on |
| Start recording automatically | off |
| Stop when the call ends | on |
| Keep running in the menu bar | on |
| Open at login | off |

Only the desktop apps are detected: a call in a browser (Google Meet, or Zoom or Teams on the web) or in
another app (Slack huddles, FaceTime) isn't.

To try it without a call, switch to the mock engine (below), quit Earshot, and open it with a fake one
(`open` passes the variable only to a new launch):

```bash
open --env OWNSCRIBE_MOCK_MEETING=zoom:15:60 app/build/Earshot.app
```

The value is `APP:START[:END]`: `zoom` or `teams`, then seconds after the watch starts, divided by the
mock's `--speed 5` (so this call runs from 3 s to 12 s). Leave the end off, or use `inf`, for a call that
never ends.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/istiakshihab/ownscribe-personalized/main/install.sh | bash
```

[`install.sh`](../install.sh) sets up the tools, the backend and both builds below, and copies the app to
`/Applications`. `bash install.sh` from a checkout installs that checkout.

## Build and run

Needs only the Command Line Tools (no Xcode project):

```bash
bash swift/build.sh            # the capture helper, bin/ownscribe-audio
bash app/build.sh              # app/build/Earshot.app (release, ad-hoc signed)
open app/build/Earshot.app
```

`bash app/build.sh debug --open` builds a debug app and launches it.

The first recording asks for **Microphone** and **System Audio Recording** access for "Earshot"
(the app is responsible for the helper it spawns). The signature is ad-hoc, so a rebuild may ask again.

## Settings

Earshot ▸ Settings… has three tabs: Backend, Hugging Face and Meetings (see "Meeting detection" above).

**Backend** holds the two commands the app runs:

| setting | default |
|---|---|
| ownscribe command | `uv run --frozen --project <checkout> ownscribe` |
| Capture helper | `<checkout>/bin/ownscribe-audio` |

`<checkout>` is the ownscribe folder the app was built from (`app/build.sh` records it in the bundle's
Info.plist as `OwnscribeRoot`), so a copy in /Applications still finds its backend.

Bare names are looked up in `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin` and `~/.cargo/bin`
too, since a GUI app gets launchd's minimal PATH. Extra words are passed through, e.g.
`… ownscribe --model base` to try a small Whisper model.

**Use mock engine** points both at `scripts/mock_engine.py --speed 5`, which fakes capture and
processing with synthetic data (no permissions, models or audio needed). **Use defaults** switches back.

**Hugging Face** is where the diarization token goes. Paste it and press Save: it's written to
`[diarization] hf_token` in `~/.config/ownscribe/config.toml` (only that line changes; the file is set to
mode 600), so the terminal `ownscribe` uses it too. **Test token** checks it against huggingface.co the
same way diarization does: that it's valid, and that it can download the gated
`pyannote/speaker-diarization-community-1` (a 403 means the account hasn't accepted the model's terms).

The backend prefers an `HF_TOKEN` environment variable over config.toml, and an app opened from a
terminal inherits the shell's. So while a token is saved in config.toml, the app removes `HF_TOKEN` from
the jobs it starts: the saved token is what diarization uses, however the app was opened.

## Layout

- `Sources/Earshot/Engine/` — `ChildProcess` (posix_spawn with an extra fd 3 for job events),
  `HelperConnection`, `JobProcess`, one-shot `Tools` (listings, `session new`, `doctor`, `templates`),
  `HFConfig` (the token in config.toml, and the token test).
- `Model/` — `RecorderModel` (helper lifecycle, mixer, meters, mic, notices), `PipelineModel`
  (jobs, stages, transcript, speakers, summary), `LevelHistory` (the last 60 s, averaged into fixed
  0.25 s buckets so the past never reshapes), `AppModel` (wiring, doctor, banners).
- `Views/` — title bar (toolbar), signal chart with the mixer's rows (one line per source) under it,
  pickers, after-recording panel, Settings.

Notes:

- In the macOS 27 SDK `@State` is a compiler macro whose plugin ships only with Xcode; the views use
  the `ViewState` typealias (SwiftUI's `State` property wrapper) so the Command Line Tools can build it.
- `build.sh` uses `swift build --build-system native`: SwiftPM's newer default fails before compiling
  with only the Command Line Tools installed.
- Per-app capture can't split out Safari (it plays through the shared WebKit GPU process), so the
  Add source list shows it disabled.

## Icon

A red recording dot with three sound arcs reaching out from it, coloured like the app's sources
(orange mic, blue system audio, green apps). `Resources/make-icon.swift` draws it and writes
`Resources/AppIcon.icns` and `Resources/Logo.png`; rerun it after changing the drawing:

```bash
swift app/Resources/make-icon.swift
```

The artwork is full-bleed; macOS masks it to the app-icon shape.

