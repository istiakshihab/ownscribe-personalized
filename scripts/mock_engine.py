#!/usr/bin/env python3
"""Stand-in for ownscribe's backend that speaks docs/engine-protocol.md with synthetic data.

Lets a GUI client be built and tested without real capture, permissions or models.

    mock_engine.py helper [--session DIR]               # like: ownscribe-audio capture --control stdio
    mock_engine.py process SESSION [--events-fd 3]      # like: ownscribe process SESSION --events-fd 3
        [--template meeting|lecture|brief] [--no-diarize] [--no-summarize] [--speed 1.0]

Standard library only.
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


class MockHelper:
    def __init__(self, session: str | None) -> None:
        self.session = session
        self.t0 = time.monotonic()
        self.lock = threading.Lock()
        self.out_lock = threading.Lock()
        self.stop_reason: str | None = None
        self.sources: dict[str, dict] = {
            "sys": {"id": "sys", "kind": "system", "name": "System audio", "gain_db": 0.0, "muted": False, "state": "active"},
            "mic": {"id": "mic", "kind": "mic", "name": "MacBook Pro Microphone", "gain_db": 0.0, "muted": False,
                    "state": "active"},
        }
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
            self.emit("mic", uid=uid, name=uid, transport="USB", rate=48000, reason="device")
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
        self.emit_sources()
        self.emit_mic()
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


def run_process(args: argparse.Namespace) -> int:
    out = os.fdopen(args.events_fd, "w", buffering=1) if args.events_fd is not None else None
    speed = max(0.05, args.speed)

    def emit(ev: str, **fields) -> None:
        if out is not None:
            out.write(json.dumps({"ev": ev, "ts": round(time.time(), 3), **fields}, separators=(",", ":")) + "\n")

    def pause(seconds: float) -> None:
        time.sleep(seconds / speed)

    session = args.session
    emit("job", command="process", session=session, status="started")

    emit("stage", stage="transcribing", status="running", fraction=0.0)
    duration = SEGMENTS[-1][1] + 2
    for start, end, _spk, text in SEGMENTS:
        pause(0.5)
        emit("segment", start=start, end=end, text=text)
        emit("stage", stage="transcribing", status="running", fraction=round(end / duration, 3))
    emit("stage", stage="transcribing", status="done", fraction=1.0)

    labels: list[str] = []
    if not args.no_diarize:
        emit("stage", stage="diarizing", status="running")
        for sub in ("segmentation", "speaker_counting", "embeddings", "clustering"):
            emit("stage", stage=sub, parent="diarizing", status="running")
            pause(0.8)
            emit("stage", stage=sub, parent="diarizing", status="done")
        emit("stage", stage="diarizing", status="done")
        labels = ["SPEAKER_00", "SPEAKER_01", "SPEAKER_02"]
        emit("speakers", labels=labels, names={}, roles={"SPEAKER_00": "runs the meeting",
                                                         "SPEAKER_01": "designer", "SPEAKER_02": "engineer"})
    else:
        emit("stage", stage="diarizing", status="skipped")

    segments = [{"start": s, "end": e, "text": t, **({"speaker": labels[k]} if labels else {})}
                for s, e, k, t in SEGMENTS]
    emit("transcript", path=f"{session}/transcript.md", segments=segments, speakers=labels)

    moved_to = session
    if not args.no_summarize:
        emit("stage", stage="summarizing", status="running")
        pause(2.5)
        emit("stage", stage="summarizing", status="done")
        emit("summary", template=args.template, title="Recorder layout review", text=SUMMARIES[args.template],
             path=f"{session}_recorder-layout-review/summary.md")
        moved_to = f"{session.rstrip('/')}_recorder-layout-review"
        emit("session_moved", **{"from": session, "to": moved_to})
    else:
        emit("stage", stage="summarizing", status="skipped")

    emit("job", command="process", session=moved_to, status="done")
    if out is not None:
        out.close()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="mode", required=True)
    helper = sub.add_parser("helper", help="act like ownscribe-audio capture --control stdio")
    helper.add_argument("--session")
    proc = sub.add_parser("process", help="act like ownscribe process SESSION --events-fd N")
    proc.add_argument("session")
    proc.add_argument("--events-fd", type=int)
    proc.add_argument("--template", choices=sorted(SUMMARIES), default="meeting")
    proc.add_argument("--no-diarize", action="store_true")
    proc.add_argument("--no-summarize", action="store_true")
    proc.add_argument("--speed", type=float, default=1.0, help="time scale; 10 runs ten times faster")
    args = parser.parse_args()
    if args.mode == "helper":
        return MockHelper(args.session).run()
    return run_process(args)


if __name__ == "__main__":
    sys.exit(main())
