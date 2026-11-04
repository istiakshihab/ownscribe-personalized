# ownscribe engine protocol (v1)

This is the contract between a GUI client (Earshot, the SwiftUI app in `app/`) and ownscribe's backend.
Everything here is JSON over pipes; there is no network listener.

```
GUI ──stdin/stdout JSON lines──▶ ownscribe-audio capture --control stdio   (capture, meters, mixer, merge)
 │
 └──spawns one process per job──▶ ownscribe <command> SESSION --events-fd 3  (transcribe, diarize, summarize, file)

 shared state: the session folder (capture.json written by the helper, session.json by ownscribe)
```

- The GUI starts the capture helper itself, so meters stay in Swift and a recording survives a
  crash of any Python job.
- Each processing step is its own short-lived `ownscribe` process. Cancel a job with SIGTERM.
- `scripts/mock_engine.py` speaks both halves of this protocol with synthetic data, so a client can
  be built before (and tested without) real capture: `mock_engine.py helper` and
  `mock_engine.py process --events-fd 3`. It also accepts the real tools' command lines (`capture`,
  `list-apps`, `list-devices`, `session new`, `speakers`, `resummarize`, `doctor`, `templates`), so a
  client can point both its `ownscribe` command and its helper path at `mock_engine.py [--speed N]`.

Conventions for every stream: UTF-8 JSON, one object per line, `\n`-terminated. Unknown fields must be
ignored by readers; new fields are added without bumping the protocol version. Levels are dBFS;
"silence" is `null`, never `-inf`.

---

## 1. Session folder

A session is one recording and everything derived from it.

```
<output dir>/<YYYY-MM-DD_HHMMSS>[_<title-slug>]/
  capture.json        written only by the capture helper
  tracks/<source>.wav one file per source, mono float32 at 24 kHz, aligned to the session start
  recording.wav       the mixdown (faders and mutes applied); input to transcription
  session.json        written only by ownscribe jobs
  transcript.json     segments with SPEAKER_XX labels (source of truth for re-rendering)
  transcript.md       rendered with the current speaker names
  summary.raw.md      the summarizer's output, with SPEAKER_XX labels
  summary.md          rendered with the current speaker names
```

Create one with `ownscribe session new --json` (prints `{"id": ..., "path": ...}`), then start the
helper with `--session <path>`. After summarization the folder is renamed to append the title slug;
jobs report this with a `session_moved` event and update `session.json`.

### capture.json (helper)

```json
{
  "version": 1,
  "status": "recording",            // recording | saved | partial | failed
  "session_start": "2026-11-03T18:28:04-08:00",
  "sample_rate": 24000,
  "tracks": [
    {"id": "sys", "kind": "system", "name": "Other apps", "file": "tracks/sys.wav"},
    {"id": "mic", "kind": "mic", "name": "MacBook Pro Microphone", "file": "tracks/mic.wav"},
    {"id": "app:us.zoom.xos", "kind": "app", "name": "Zoom", "bundle_id": "us.zoom.xos",
     "file": "tracks/app-us.zoom.xos.wav"}
  ],
  "gain_log": [{"t": 12.5, "source": "mic", "db": -6.0}],
  "mute_log": [{"t": 30.0, "source": "sys", "muted": true}],
  "recording": "recording.wav"      // set once merged
}
```

Every track file starts at the session start and is padded with silence wherever its source was absent
(not yet added, removed, device switching), so tracks line up sample for sample. Mutes are applied
at capture (muted audio never reaches disk); gain is applied when mixing, from `gain_log`.
`ownscribe-audio merge --session <path>` rebuilds `recording.wav` from `capture.json` (crash recovery).

### session.json (ownscribe)

```json
{
  "version": 1,
  "id": "2026-11-03_182804",
  "title": "Recorder layout review",
  "created": "2026-11-03T18:28:04-08:00",
  "options": {"template": "meeting", "diarize": true, "summarize": true, "language": "en"},
  "stages": {
    "transcription": {"status": "done"},
    "diarization":   {"status": "done", "speakers": 3},
    "summarization": {"status": "failed", "error": {"code": "summarizer_unavailable", "message": "..."}},
    "vault":         {"status": "pending"}
  },
  "speakers": {"labels": ["SPEAKER_00", "SPEAKER_01"], "names": {"SPEAKER_00": "Alice"}, "roles": {}},
  "vault_note": null
}
```

Stage `status` is one of `pending`, `running`, `done`, `failed`, `skipped`.

---

## 2. Capture helper

```
ownscribe-audio capture --session DIR --control stdio
    [--mic | --no-mic] [--mic-auto | --mic-default | --mic-device UID_OR_NAME]
    [--app BUNDLE_ID]...          # apps with their own source from the start
    [--exclude-bundle BUNDLE_ID]  # never record this app (pass the GUI's own bundle ID)
    [--silence-timeout SECONDS]
    [--source test-tone]          # synthetic sources; needs no permissions (for tests)
```

System audio and app sources are Core Audio process taps (see `docs/per-app-audio.md`): an app source
taps the app and its helper processes (matched by bundle-ID prefix), and "Other apps" is one tap of
everything except the split-out apps, so the two never overlap. Session mode needs the Microphone and
System Audio Recording permissions, not Screen Recording.

The legacy CLI form (`capture --output FILE [--mic] ...`, stopped with SIGINT, mic mute with SIGUSR1)
keeps working unchanged; `--control stdio` is opt-in.

### Commands (GUI → helper stdin)

Every command may carry an `"id"`; the helper answers it with `ack` or `error`.

| `cmd` | fields | effect |
|---|---|---|
| `set_gain` | `source`, `db` (−60…+6; ≤ −60 = −∞) | fader; logged, applied at mixdown |
| `set_mute` | `source`, `muted` | mute; zeros are written while muted |
| `set_mic` | `mic`: `{"mode":"auto"}` · `{"mode":"default"}` · `{"mode":"device","uid":UID}` | switch mic live |
| `add_app` | `bundle_id` | give an app its own source; "System audio" becomes "Other apps" |
| `remove_app` | `bundle_id` | fold the app back into "Other apps" (its track pads with silence) |
| `stop` | — | stop, merge, emit `saved`, exit |
| `ping` | — | answered with `ack` |

Closing stdin (the GUI quit or crashed) is treated as `stop`.

### Events (helper stdout)

Every event has `"ev"` and `"t"` (seconds since session start).

| `ev` | fields |
|---|---|
| `ready` | `version` (helper build), `protocol` (= 1) |
| `sources` | `list`: `[{"id","kind","name","bundle_id"?,"gain_db","muted","state"}]` — full snapshot on any change; `state` is `active`, `lost` or `removed` |
| `levels` | `seq`, `sources`: `{id: {"peak": dBFS or null, "rms": dBFS or null}}` — 20 Hz, pre-fader |
| `mic` | `uid`, `name`, `transport` (`built-in`, `Bluetooth`, `USB`, `virtual`, …), `rate`, `reason` (`auto`, `default`, `device`, `fallback`) |
| `notice` | `level` (`info`, `warning`, `error`), `code`, `message`, `source`? |
| `ack` / `error` | `id`, and for `error`: `code`, `message` |
| `stopping` | `reason`: `command`, `signal`, `stdin_closed`, `silence_timeout`, `picker_cancelled` |
| `saved` | `status` (`ok`, `partial`, `failed`), `recording` (path or null), `tracks`, `duration` |

`saved` is always the last event. Exit code: 0 = ok, 2 = partial (some source failed), 1 = failed.

Notice codes:
- mic: `mic_bluetooth`, `mic_silent`, `mic_signal_back`, `mic_builtin_silent_fallback`, `mic_reconfigure`,
  `mic_permission_denied`, `mic_failed`
- system and apps: `system_audio_permission_denied`, `tap_failed`, `no_output_device`, `output_device_changed`
- session: `source_failed`, `no_sources`, `session_dir_failed`, `silence_timeout_soon` (with `seconds_left`),
  `write_error`, `merge_failed`

Messages are human-readable English; clients should key behavior off `code`. A source that fails to start
is reported with `level: "error"` and `state: "lost"` while the others keep recording; the final `saved`
then has `status: "partial"`. (Detecting a tap that dies mid-session is not implemented yet.)

### Listings

`ownscribe-audio list-devices --json`
```json
{"devices": [{"uid": "BuiltInMicrophoneDevice", "name": "MacBook Pro Microphone",
              "transport": "built-in", "sample_rate": 48000, "channels": 1, "default": false}]}
```
`ownscribe-audio list-apps --json`
```json
{"apps": [{"bundle_id": "us.zoom.xos", "name": "Zoom", "pid": 812, "playing": true}]}
```

---

## 3. Jobs (`ownscribe` subcommands)

Jobs print a final JSON result to stdout when given `--json`, write progress events to `--events-fd N`
when given one (the GUI passes an extra pipe as fd 3), and log human text to stderr. Exit codes:
0 = ok, 2 = finished with a failed optional stage (e.g. summarization), 1 = failed, 130 = cancelled.

| command | does |
|---|---|
| `ownscribe session new [--output-dir DIR] --json` | create a session folder and `session.json` |
| `ownscribe process SESSION [--template T] [--no-diarize] [--no-summarize] [--language L] [--min-speakers N] [--max-speakers N]` | transcription → diarization → summarization |
| `ownscribe speakers SESSION --set SPEAKER_00=Alice ... [--resummarize]` | rename speakers; re-render transcript and summary |
| `ownscribe resummarize SESSION --template T` | run summarization again |
| `ownscribe file SESSION --preview --json` / `--write [--edits FILE]` | Obsidian vault note: preview, then write |
| `ownscribe sessions [--output-dir DIR] --json` | list sessions with stage status |
| `ownscribe templates --json` | built-in and custom summary templates |
| `ownscribe doctor --json` | ffmpeg, Hugging Face token, claude CLI, summarizer (`backend`, `model`), cached models, disk space |
| `ownscribe warmup --events-fd N` | download and cache models, with progress |

### Job events (on `--events-fd`)

Every event has `"ev"` and `"ts"` (Unix time).

| `ev` | fields |
|---|---|
| `job` | `command`, `session`, `status` (`started`, `done`, `failed`, `cancelled`) |
| `stage` | `stage`, `parent`? (sub-steps), `status` (`running`, `done`, `failed`, `skipped`), `fraction`? (0–1), `detail`? |
| `segment` | `start`, `end`, `text` — live while transcribing; no speakers yet |
| `transcript` | `path`, `segments`: `[{"start","end","text","speaker"?}]`, `speakers`: labels |
| `speakers` | `labels`, `names`, `roles` (suggestions; may be empty) |
| `summary` | `template`, `title`, `text` (rendered with current names), `path` |
| `session_moved` | `from`, `to` |
| `vault_preview` | `title`, `category`, `tags`, `body_markdown` |
| `vault_note` | `path`, `needs_review` |
| `error` | `stage`?, `code`, `message` |

Stage names follow the terminal display: `preparing_models`, `transcribing`, `diarizing` with the
sub-steps `segmentation`, `speaker_counting`, `embeddings`, `clustering`, then `summarizing` and
`downloading_model`.

Error codes include `audio_missing`, `audio_silent`, `ffmpeg_missing`, `hf_token_missing`,
`transcription_failed`, `diarization_failed`, `summarizer_unavailable`, `summarization_failed`,
`claude_unavailable`, `vault_failed`.

---

## 4. Environment for GUI-launched processes

A process started by a GUI app gets launchd's minimal `PATH` and none of the shell's variables. Set
`[paths] ffmpeg` and `[paths] claude` in `~/.config/ownscribe/config.toml` (or put the binaries in
`/opt/homebrew/bin`, which jobs add to `PATH`), and keep the Hugging Face token in
`[diarization] hf_token` rather than only in `HF_TOKEN`. `ownscribe doctor --json` reports what is missing.

Permissions (Microphone and System Audio Recording) are granted to the GUI app, which macOS treats as
responsible for the helper it spawns.
