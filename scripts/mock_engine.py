#!/usr/bin/env python3
"""Stand-in for ownscribe's backend that speaks docs/engine-protocol.md with synthetic data.

Lets a GUI client be built and tested without real capture, permissions or models.

    mock_engine.py helper [--session DIR]               # like: ownscribe-audio capture --control stdio
    mock_engine.py process SESSION [--events-fd 3]      # like: ownscribe process SESSION --events-fd 3
        [--template meeting|lecture|brief] [--no-diarize] [--no-summarize] [--speed 1.0]

It also accepts the real tools' command lines, so a client can point both its `ownscribe` command and
its capture helper at this script (`mock_engine.py [--speed N] <command> ...`):

    capture --session DIR --control stdio [--mic|--no-mic] [--mic-device UID] [--app ID]...  (= helper)
    list-apps --json · list-devices --json
    session new [--output-dir DIR] --json        # default parent: $TMPDIR/ownscribe-mock
    speakers SESSION --set SPEAKER_00=Name ... --events-fd 3
    resummarize SESSION --template T --events-fd 3
    doctor --json · templates --json

Jobs touch the session folder only if it exists: `process` writes session.json and summary.raw.md and
renames the folder after the title, like the real job. Standard library only.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import random
import sys
import threading
import time
from pathlib import Path

PROTOCOL = 1

# ---------------------------------------------------------------- helper (capture) side

APPS = {
    "us.zoom.xos": "Zoom",
    "com.google.Chrome": "Google Chrome",
    "com.apple.Music": "Music",
}
MICS = {
    "auto": ("BuiltInMicrophoneDevice", "MacBook Pro Microphone", "built-in", 48000, "auto"),
    "default": ("WH-1000XM6-hfp", "WH-1000XM6", "Bluetooth", 16000, "default"),
}
DEVICES = [
    {"uid": "WH-1000XM6-hfp", "name": "WH-1000XM6", "transport": "Bluetooth", "sample_rate": 16000, "channels": 1,
     "default": True},
    {"uid": "BuiltInMicrophoneDevice", "name": "MacBook Pro Microphone", "transport": "built-in",
     "sample_rate": 48000, "channels": 1, "default": False},
    {"uid": "zoom.us.zoomaudiodevice.001", "name": "ZoomAudioDevice", "transport": "virtual", "sample_rate": 48000,
     "channels": 2, "default": False},
]


class MockHelper:
    def __init__(self, session: str | None, mic: bool = True, mic_device: str | None = None,
                 apps: tuple = ()) -> None:
        self.session = session
        self.t0 = time.monotonic()
        self.lock = threading.Lock()
        self.out_lock = threading.Lock()
        self.stop_reason: str | None = None
        self.sources: dict[str, dict] = {
            "sys": {"id": "sys", "kind": "system", "name": "System audio", "gain_db": 0.0, "muted": False, "state": "active"},
        }
        if mic:
            self.sources["mic"] = {"id": "mic", "kind": "mic", "name": "MacBook Pro Microphone", "gain_db": 0.0,
                                   "muted": False, "state": "active"}
        self.mic_device = mic_device
        self.initial_apps = [a for a in apps if a in APPS]
        self.mic_mode = "auto"
        self.seq = 0

    def t(self) -> float:
        return round(time.monotonic() - self.t0, 3)

    def emit(self, ev: str, **fields) -> None:
        line = json.dumps({"ev": ev, "t": self.t(), **fields}, separators=(",", ":"))
        with self.out_lock:
            sys.stdout.write(line + "\n")
            sys.stdout.flush()

    def emit_sources(self) -> None:
        with self.lock:
            snapshot = [dict(s) for s in self.sources.values()]
        self.emit("sources", list=snapshot)

    def emit_mic(self, uid: str | None = None) -> None:
        if uid:
            dev = next((d for d in DEVICES if d["uid"] == uid), None)
            name = dev["name"] if dev else uid
            self.emit("mic", uid=uid, name=name, transport=dev["transport"] if dev else "USB",
                      rate=dev["sample_rate"] if dev else 48000, reason="device")
            with self.lock:
                if "mic" in self.sources:
                    self.sources["mic"]["name"] = name
            self.emit_sources()
            return
        uid_, name, transport, rate, reason = MICS[self.mic_mode]
        self.emit("mic", uid=uid_, name=name, transport=transport, rate=rate, reason=reason)
        if self.mic_mode == "auto":
            self.emit("notice", level="info", code="mic_bluetooth",
                      message="Skipped the default input 'WH-1000XM6': Bluetooth headset mics record in hands-free mode.")

    def level(self, sid: str, t: float) -> tuple[float | None, float | None]:
        # Speech-like bursts per source; seeded so each source has its own rhythm.
        phase = (hash(sid) % 1000) / 100.0
        talking = math.sin(t * 0.7 + phase) > -0.1
        if sid == "app:com.apple.Music":
            rms = -24 + 2 * math.sin(t * 2.1)
        elif talking:
            rms = -26 + 8 * abs(math.sin(t * 9 + phase)) + random.uniform(-1, 1)
        elif sid == "mic":
            rms = -56 + random.uniform(-1, 1)
        else:
            return None, None
        return round(rms + 6, 1), round(rms, 1)

    def levels_loop(self) -> None:
        while self.stop_reason is None:
            t = self.t()
            with self.lock:
                ids = [s["id"] for s in self.sources.values() if s["state"] == "active"]
            levels = {}
            for sid in ids:
                peak, rms = self.level(sid, t)
                levels[sid] = {"peak": peak, "rms": rms}
            self.seq += 1
            self.emit("levels", seq=self.seq, sources=levels)
            time.sleep(0.05)

    def handle(self, msg: dict) -> None:
        cmd, cid = msg.get("cmd"), msg.get("id")

        def ack() -> None:
            if cid is not None:
                self.emit("ack", id=cid)

        def error(code: str, message: str) -> None:
            self.emit("error", id=cid, code=code, message=message)

        if cmd in ("set_gain", "set_mute"):
            sid = msg.get("source")
            with self.lock:
                src = self.sources.get(sid)
                if src is None:
                    return error("unknown_source", f"No source {sid!r}")
                if cmd == "set_gain":
                    src["gain_db"] = float(msg.get("db", 0.0))
                else:
                    src["muted"] = bool(msg.get("muted"))
            ack()
            self.emit_sources()
        elif cmd == "set_mic":
            mic = msg.get("mic") or {}
            mode = mic.get("mode")
            if mode in MICS:
                self.mic_mode = mode
                ack()
                self.emit_mic()
            elif mode == "device" and mic.get("uid"):
                ack()
                self.emit_mic(mic["uid"])
            else:
                error("bad_mic", "mic.mode must be auto, default or device (with uid)")
        elif cmd == "add_app":
            bid = msg.get("bundle_id")
            if bid not in APPS:
                return error("app_not_running", f"{bid!r} is not running")
            with self.lock:
                self.sources[f"app:{bid}"] = {"id": f"app:{bid}", "kind": "app", "name": APPS[bid], "bundle_id": bid,
                                              "gain_db": 0.0, "muted": False, "state": "active"}
                self.sources["sys"]["name"] = "Other apps"
            ack()
            self.emit_sources()
        elif cmd == "remove_app":
            sid = f"app:{msg.get('bundle_id')}"
            with self.lock:
                if sid not in self.sources:
                    return error("unknown_source", f"No source {sid!r}")
                self.sources[sid]["state"] = "removed"
                if not any(s["kind"] == "app" and s["state"] == "active" for s in self.sources.values()):
                    self.sources["sys"]["name"] = "System audio"
            ack()
            self.emit_sources()
        elif cmd == "ping":
            ack()
        elif cmd == "stop":
            ack()
            self.stop_reason = "command"
        else:
            error("unknown_command", f"Unknown cmd {cmd!r}")

    def stdin_loop(self) -> None:
        for raw in sys.stdin:
            raw = raw.strip()
            if not raw:
                continue
            try:
                self.handle(json.loads(raw))
            except json.JSONDecodeError:
                self.emit("error", id=None, code="bad_json", message="Each command must be one JSON object per line")
            if self.stop_reason:
                return
        self.stop_reason = self.stop_reason or "stdin_closed"

    def run(self) -> int:
        self.emit("ready", version="mock", protocol=PROTOCOL)
        for bid in self.initial_apps:
            self.sources[f"app:{bid}"] = {"id": f"app:{bid}", "kind": "app", "name": APPS[bid], "bundle_id": bid,
                                          "gain_db": 0.0, "muted": False, "state": "active"}
            self.sources["sys"]["name"] = "Other apps"
        self.emit_sources()
        if "mic" in self.sources:
            self.emit_mic(self.mic_device)
        threading.Thread(target=self.stdin_loop, daemon=True).start()
        self.levels_loop()
        self.emit("stopping", reason=self.stop_reason)
        recording = str(Path(self.session) / "recording.wav") if self.session else None
        with self.lock:
            tracks = [f"tracks/{s['id'].replace(':', '-')}.wav" for s in self.sources.values()]
        self.emit("saved", status="ok", recording=recording, tracks=tracks, duration=self.t())
        return 0


# ---------------------------------------------------------------- job (processing) side

SEGMENTS = [
    (0.0, 4.8, 0, "Okay, it's recording. Let's go through the recorder layout first."),
    (5.0, 11.6, 1, "The signal chart on the left reads well, and I'd keep the mixer on the right."),
    (12.0, 16.5, 0, "Should the mixer get a master fader, like OBS has?"),
    (17.0, 24.4, 2, "I'd skip it. The total signal already shows the mix, and fewer controls is the point."),
    (25.0, 29.6, 1, "Agreed. What happens when someone joins wearing a Bluetooth headset?"),
    (30.0, 35.4, 0, "It records the built-in mic instead and says so under the picker."),
    (36.0, 41.5, 2, "Good. And the transcript and summary show up in this window when we stop."),
    (42.0, 46.5, 0, "Then let's share the mockup with the team by Friday."),
    (47.0, 51.0, 1, "I'll write the copy for the microphone picker."),
]
SUMMARIES = {
    "meeting": "The group reviewed the recorder mockup. Decisions: keep the chart left and the mixer right; "
               "no master fader. Action items: SPEAKER_00 shares the mockup by Friday; "
               "SPEAKER_01 writes the microphone picker copy.",
    "lecture": "Main points: fewer controls; headset mics record in hands-free mode, so the built-in mic is preferred.",
    "brief": "- Chart left, mixer right, no master fader.\n- SPEAKER_00 shares the mockup by Friday.",
}


def _emitter(events_fd: int | None):
    out = os.fdopen(events_fd, "w", buffering=1) if events_fd is not None else None

    def emit(ev: str, **fields) -> None:
        if out is not None:
            out.write(json.dumps({"ev": ev, "ts": round(time.time(), 3), **fields}, separators=(",", ":")) + "\n")

    def close() -> None:
        if out is not None:
            out.close()

    return emit, close


def _load_state(session: str) -> dict:
    try:
        return json.loads((Path(session) / "session.json").read_text())
    except (OSError, json.JSONDecodeError):
        return {"speakers": {"labels": [], "names": {}, "roles": {}}, "summary": None}


def _save_state(session: str, state: dict) -> None:
    if Path(session).is_dir():
        (Path(session) / "session.json").write_text(json.dumps(state, indent=2) + "\n")


def _render(text: str, names: dict) -> str:
    for label, name in names.items():
        if name:
            text = text.replace(label, name)
    return text


def _segments(labels: list, names: dict) -> list:
    return [{"start": s, "end": e, "text": t,
             **({"speaker": labels[k], "name": names.get(labels[k], labels[k])} if labels else {})}
            for s, e, k, t in SEGMENTS]


def _summarize(emit, pause, session: str, template: str, names: dict) -> None:
    emit("stage", stage="summarizing", status="running")
    pause(2.5)
    emit("stage", stage="summarizing", status="done")
    raw = SUMMARIES.get(template, SUMMARIES["meeting"])
    if Path(session).is_dir():
        (Path(session) / "summary.raw.md").write_text(raw + "\n")
    emit("summary", template=template, title="Recorder layout review", text=_render(raw, names),
         path=f"{session}/summary.md")


def run_process(args: argparse.Namespace) -> int:
    emit, close = _emitter(args.events_fd)
    speed = max(0.05, args.speed)

    def pause(seconds: float) -> None:
        time.sleep(seconds / speed)

    session = args.session.rstrip("/")
    emit("job", command="process", session=session, status="started")

    emit("stage", stage="transcribing", status="running", fraction=0.0)
    duration = SEGMENTS[-1][1] + 2
    for start, end, _spk, text in SEGMENTS:
        pause(0.5)
        emit("segment", start=start, end=end, text=text)
        emit("stage", stage="transcribing", status="running", fraction=round(end / duration, 3))
    emit("stage", stage="transcribing", status="done", fraction=1.0)

    labels: list[str] = []
    roles: dict = {}
    if not args.no_diarize:
        emit("stage", stage="diarizing", status="running")
        for sub in ("segmentation", "speaker_counting", "embeddings", "clustering"):
            emit("stage", stage=sub, parent="diarizing", status="running")
            pause(0.8)
            emit("stage", stage=sub, parent="diarizing", status="done")
        emit("stage", stage="diarizing", status="done")
        labels = ["SPEAKER_00", "SPEAKER_01", "SPEAKER_02"]
        roles = {"SPEAKER_00": "runs the meeting", "SPEAKER_01": "designer", "SPEAKER_02": "engineer"}
        emit("speakers", labels=labels, names={}, roles=roles)
    else:
        emit("stage", stage="diarizing", status="skipped")

    emit("transcript", path=f"{session}/transcript.md", segments=_segments(labels, {}), speakers=labels)
    state = {"speakers": {"labels": labels, "names": {}, "roles": roles}, "summary": None,
             "options": {"template": args.template}}
    _save_state(session, state)

    moved_to = session
    if not args.no_summarize:
        _summarize(emit, pause, session, args.template, {})
        state["summary"] = {"template": args.template}
        state["title"] = "Recorder layout review"
        _save_state(session, state)
        moved_to = f"{session}_recorder-layout-review"
        if Path(session).is_dir() and not Path(moved_to).exists():
            os.rename(session, moved_to)
        emit("session_moved", **{"from": session, "to": moved_to})
    else:
        emit("stage", stage="summarizing", status="skipped")

    emit("job", command="process", session=moved_to, status="done")
    close()
    return 0


def run_speakers(args: argparse.Namespace) -> int:
    emit, close = _emitter(args.events_fd)
    session = args.session.rstrip("/")
    emit("job", command="speakers", session=session, status="started")
    state = _load_state(session)
    labels = state["speakers"].get("labels") or ["SPEAKER_00", "SPEAKER_01", "SPEAKER_02"]
    names = dict(state["speakers"].get("names") or {})
    for item in args.set or []:
        label, sep, name = item.partition("=")
        if not sep or label not in labels:
            emit("error", code="unknown_speaker", message=f"No such speaker label: {label}")
            emit("job", command="speakers", session=session, status="failed")
            close()
            return 1
        names[label] = name.strip()
    names = {k: v for k, v in names.items() if v}
    state["speakers"] = {**state["speakers"], "labels": labels, "names": names}
    _save_state(session, state)
    emit("transcript", path=f"{session}/transcript.md", segments=_segments(labels, names), speakers=labels)
    emit("speakers", labels=labels, names=names, roles=state["speakers"].get("roles", {}))
    template = (state.get("summary") or {}).get("template")
    if template:
        raw = SUMMARIES.get(template, SUMMARIES["meeting"])
        emit("summary", template=template, title=state.get("title"), text=_render(raw, names),
             path=f"{session}/summary.md")
    emit("job", command="speakers", session=session, status="done")
    close()
    return 0


def run_resummarize(args: argparse.Namespace) -> int:
    emit, close = _emitter(args.events_fd)
    speed = max(0.05, args.speed)
    session = args.session.rstrip("/")
    emit("job", command="resummarize", session=session, status="started")
    state = _load_state(session)
    _summarize(emit, lambda s: time.sleep(s / speed), session, args.template, state["speakers"].get("names", {}))
    state["summary"] = {"template": args.template}
    _save_state(session, state)
    emit("job", command="resummarize", session=session, status="done")
    close()
    return 0


def run_session_new(args: argparse.Namespace) -> int:
    import tempfile
    from datetime import datetime

    base = Path(args.output_dir).expanduser() if args.output_dir else Path(tempfile.gettempdir()) / "ownscribe-mock"
    base.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y-%m-%d_%H%M%S")
    path, n = base / stamp, 2
    while path.exists():
        path, n = base / f"{stamp}-{n}", n + 1
    path.mkdir()
    _save_state(str(path), {"id": path.name, "speakers": {"labels": [], "names": {}, "roles": {}}, "summary": None})
    print(json.dumps({"id": path.name, "path": str(path)}))
    return 0


def run_doctor(_args: argparse.Namespace) -> int:
    import tempfile

    checks = {
        "ffmpeg": {"ok": True, "path": "/opt/homebrew/bin/ffmpeg"},
        "hf_token": {"ok": True, "set": True, "needed": True},
        "claude": {"ok": True, "path": "/usr/local/bin/claude"},
        "capture_helper": {"ok": True, "path": __file__, "session_mode": True},
        "disk": {"ok": True, "free_bytes": 50 * 1024**3, "path": str(Path(tempfile.gettempdir()) / "ownscribe-mock")},
        "whisper_model": {"ok": True, "cached": False, "model": "mock-whisper", "required": False},
    }
    print(json.dumps({"ok": True, "checks": checks}, indent=2))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--speed", type=float, default=None, help="time scale for jobs; 10 runs ten times faster")
    sub = parser.add_subparsers(dest="mode", required=True)

    helper = sub.add_parser("helper", aliases=["capture"], help="act like ownscribe-audio capture --control stdio")
    helper.add_argument("--session")
    helper.add_argument("--control", default="stdio")
    helper.add_argument("--mic", dest="mic", action="store_true", default=True)
    helper.add_argument("--no-mic", dest="mic", action="store_false")
    helper.add_argument("--mic-auto", action="store_true")
    helper.add_argument("--mic-default", action="store_true")
    helper.add_argument("--mic-device")
    helper.add_argument("--app", action="append", default=[])
    helper.add_argument("--exclude-bundle", action="append", default=[])
    helper.add_argument("--silence-timeout", type=float, default=0)
    helper.add_argument("--source")
    for name in ("list-apps", "list-devices", "doctor", "templates"):
        sub.add_parser(name).add_argument("--json", action="store_true")

    session = sub.add_parser("session").add_subparsers(dest="session_cmd", required=True)
    new = session.add_parser("new")
    new.add_argument("--output-dir")
    new.add_argument("--json", action="store_true")

    def job(name: str, help_text: str) -> argparse.ArgumentParser:
        p = sub.add_parser(name, help=help_text)
        p.add_argument("session")
        p.add_argument("--events-fd", type=int)
        p.add_argument("--json", action="store_true")
        p.add_argument("--speed", type=float, default=1.0, help="time scale; 10 runs ten times faster")
        return p

    proc = job("process", "act like ownscribe process SESSION --events-fd N")
    proc.add_argument("--template", choices=sorted(SUMMARIES), default="meeting")
    proc.add_argument("--diarize", dest="no_diarize", action="store_false")
    proc.add_argument("--no-diarize", dest="no_diarize", action="store_true")
    proc.add_argument("--summarize", dest="no_summarize", action="store_false")
    proc.add_argument("--no-summarize", dest="no_summarize", action="store_true")
    proc.add_argument("--language")
    proc.add_argument("--min-speakers", type=int)
    proc.add_argument("--max-speakers", type=int)
    proc.set_defaults(no_diarize=False, no_summarize=False)
    spk = job("speakers", "act like ownscribe speakers SESSION --set LABEL=NAME")
    spk.add_argument("--set", action="append", default=[])
    spk.add_argument("--resummarize", action="store_true")
    spk.add_argument("--suggest", action="store_true")
    res = job("resummarize", "act like ownscribe resummarize SESSION --template T")
    res.add_argument("--template", required=True)

    # The global --speed comes before the command; a job's own --speed wins when given.
    global_speed = None
    argv = sys.argv[1:]
    if argv[:1] == ["--speed"] and len(argv) > 1:
        global_speed, argv = float(argv[1]), argv[2:]
    args = parser.parse_args(argv)
    if global_speed is not None and getattr(args, "speed", 1.0) == 1.0:
        args.speed = global_speed

    if args.mode in ("helper", "capture"):
        return MockHelper(args.session, mic=args.mic, mic_device=args.mic_device, apps=tuple(args.app)).run()
    if args.mode == "list-apps":
        apps = [{"bundle_id": b, "name": n, "pid": 1000 + i, "playing": b != "com.apple.Music"}
                for i, (b, n) in enumerate(APPS.items())]
        print(json.dumps({"apps": apps}, indent=2))
        return 0
    if args.mode == "list-devices":
        print(json.dumps({"devices": DEVICES}, indent=2))
        return 0
    if args.mode == "session":
        return run_session_new(args)
    if args.mode == "doctor":
        return run_doctor(args)
    if args.mode == "templates":
        print(json.dumps({"templates": [{"name": n, "kind": "built-in"} for n in ("meeting", "lecture", "brief")]}))
        return 0
    if args.mode == "speakers":
        return run_speakers(args)
    if args.mode == "resummarize":
        return run_resummarize(args)
    return run_process(args)


if __name__ == "__main__":
    sys.exit(main())
