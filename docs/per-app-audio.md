# Per-app audio: Core Audio process taps (decision)

The mixer can give an app (Zoom, Chrome, Music, …) its own source, with "Other apps" holding the
rest. Two macOS APIs can do this; `swift/tools/AppAudioProbe.swift` compares them.

## Result (2026-11-03, macOS 27, Zen browser playing audio)

| | Core Audio process tap | ScreenCaptureKit app filter |
|---|---|---|
| App alone | correct | correct |
| "Everything else" | silent, correct | silent, correct |
| First audio after start | immediate | ~1.5 s |
| Buffers / s | 87, steady | 50 |
| Helper processes (Teams, Discord, Chrome) | visible as separate process objects (`com.microsoft.teams2.helper`, `com.hnc.DiscordPTB.helper.Renderer`); grouped by bundle-ID prefix | not tested yet |
| App quits and relaunches | handled by `processRestoreEnabled` + `bundleIDs` (macOS 26+) | filters must be rebuilt by hand |
| Permission | System Audio Recording | Screen Recording |
| Safari | audio comes from `com.apple.WebKit.GPU`, shared with other WebKit apps, so it can't be split out | untested |

## Decision

Use process taps for app sources **and** for "Other apps" (one global tap that excludes exactly the
split-out apps). Include and exclude taps built from the same process list partition the audio:
nothing doubles when an app is split out and nothing is lost when it rejoins. ScreenCaptureKit stays
only for the legacy `capture_mode = "picker"`.

A tap's device runs only while a process it covers is playing. Tapping a running but silent app
(Spotify, paused) or an app with no process at all creates the tap and the aggregate without error, but
the IO callback is never called and `kAudioDevicePropertyDeviceIsRunning` stays 0; as soon as a covered
process plays, buffers arrive at ~87/s. So "no buffers" cannot mean "dead tap" by itself: the session
treats a tap as lost only when a covered process is playing and nothing arrives (see "Lost sources" in
`engine-protocol.md`).

An app is matched by bundle-ID prefix, so `com.microsoft.teams2` also covers
`com.microsoft.teams2.helper` and `.modulehost`. Safari and other WebKit apps play through the shared
`com.apple.WebKit.GPU` process and stay in "Other apps".

## Still to confirm on a real call

```bash
bin/app-audio-probe list                    # while a Teams / Zoom / Chrome call is running
bin/app-audio-probe tap com.microsoft.teams2 8
bin/app-audio-probe tap com.google.Chrome 8
bin/app-audio-probe tap us.zoom.xos 8
```

Each should show the call's audio in the first column and only other apps in the second.
