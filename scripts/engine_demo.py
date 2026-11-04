#!/usr/bin/env python3
"""Drive the backend from a terminal the way the SwiftUI app will (docs/engine-protocol.md).

    uv run python scripts/engine_demo.py [--seconds 20] [--app us.zoom.xos] [--no-process]

1. `ownscribe session new --json` creates a session folder.
2. bin/ownscribe-audio records it in session mode while this prints a live meter per source.
   Type a bundle ID and Enter to split that app out, `-BUNDLE` to fold it back, `m` to mute the mic.
3. `ownscribe process SESSION --events-fd 3` transcribes, diarizes and summarizes, printing events.
"""

from __future__ import annotations

import argparse
import json
import os
import select
import subprocess
import sys
import threading
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
HELPER = REPO / "bin" / "ownscribe-audio"
# The `ownscribe` entry point, run with this interpreter (cli.py has no __main__ block).
OWNSCRIBE = [sys.executable, "-c", "from ownscribe.cli import cli; cli()"]


def bar(db: float | None, width: int = 24) -> str:
    filled = 0 if db is None else max(0, min(width, int((db + 60) / 60 * width)))
    return "█" * filled + "·" * (width - filled)


def record(session: Path, seconds: float, apps: list[str]) -> None:
    cmd = [str(HELPER), "capture", "--session", str(session), "--control", "stdio", "--mic", "--mic-auto"]
    for app in apps:
        cmd += ["--app", app]
    helper = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              text=True, bufsize=1)
    state = {"levels": {}, "names": {}, "notices": [], "done": None}

    def read() -> None:
        for line in helper.stdout:
            event = json.loads(line)
            ev = event["ev"]
            if ev == "levels":
                state["levels"] = event["sources"]
            elif ev == "sources":
                state["names"] = {s["id"]: s["name"] + (" (muted)" if s["muted"] else "")
                                  for s in event["list"] if s["state"] == "active"}
            elif ev in ("notice", "mic", "error"):
                state["notices"].append(event.get("message") or event.get("name") or event.get("code"))
            elif ev == "saved":
                state["done"] = event

    threading.Thread(target=read, daemon=True).start()

    def send(**command) -> None:
        helper.stdin.write(json.dumps(command) + "\n")
        helper.stdin.flush()

    muted = False
    end = time.time() + seconds
    print(f"Recording {seconds:.0f} s into {session}. Type a bundle ID + Enter to split an app, -ID to rejoin, m to mute.")
    while time.time() < end and helper.poll() is None:
        while state["notices"]:
            print(f"\r\033[K  · {state['notices'].pop(0)}")
        rows = [f"{state['names'].get(sid, sid)[:22]:22} {bar(v.get('peak'))}" for sid, v in state["levels"].items()]
        print("\r\033[K" + "   ".join(rows), end="", flush=True)
        if select.select([sys.stdin], [], [], 0.1)[0]:
            text = sys.stdin.readline().strip()
            if text == "m":
                muted = not muted
                send(cmd="set_mute", source="mic", muted=muted)
            elif text.startswith("-"):
                send(cmd="remove_app", bundle_id=text[1:])
            elif text:
                send(cmd="add_app", bundle_id=text)
    send(cmd="stop")
    helper.wait(timeout=60)
    time.sleep(0.2)
    print(f"\n\nSaved: {state['done']}")


def process(session: Path) -> None:
    r, w = os.pipe()
    job = subprocess.Popen([*OWNSCRIBE, "process", str(session), "--events-fd", "3"],
                           pass_fds=(w,), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
                           preexec_fn=lambda: os.dup2(w, 3))
    os.close(w)
    with os.fdopen(r) as events:
        for line in events:
            e = json.loads(line)
            if e["ev"] == "stage":
                frac = f" {e['fraction'] * 100:3.0f}%" if "fraction" in e else ""
                print(f"  [{e['status']:7}] {('  ' if e.get('parent') else '') + e['stage']}{frac} {e.get('detail') or ''}")
            elif e["ev"] == "segment":
                print(f"    {e['start']:6.1f}s  {e['text']}")
            elif e["ev"] in ("summary", "session_moved", "error", "job", "speakers"):
                print(f"  {e['ev']}: { {k: v for k, v in e.items() if k not in ('ev', 'ts')} }")
    job.wait()
    if job.returncode not in (0, 2):
        print(job.stderr.read())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seconds", type=float, default=20)
    parser.add_argument("--app", action="append", default=[], help="bundle ID to give its own source from the start")
    parser.add_argument("--no-process", action="store_true", help="record only")
    parser.add_argument("--output-dir", default=str(Path("~/ownscribe").expanduser()))
    args = parser.parse_args()
    created = subprocess.run([*OWNSCRIBE, "session", "new", "--json", "--output-dir", args.output_dir],
                             capture_output=True, text=True, check=True)
    session = Path(json.loads(created.stdout)["path"])
    record(session, args.seconds, args.app)
    if not args.no_process:
        print("\nProcessing…")
        process(session)
    return 0


if __name__ == "__main__":
    sys.exit(main())
