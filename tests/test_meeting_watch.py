"""The Swift helper's `watch-meetings` mode, driven over stdio with a fake process table.

`--debug-commands` replaces Core Audio with a table that `debug_process` commands fill in, so this runs
anywhere the helper is built (bash swift/build.sh). Skipped when it isn't, or when it predates
watch-meetings. Timings are compared on the helper's own clock (event `t`), not the test's.
"""

from __future__ import annotations

import json
import subprocess
import threading
import time
from pathlib import Path

import pytest

HELPER = Path(__file__).resolve().parents[1] / "bin" / "ownscribe-audio"
START_AFTER = 0.2
END_AFTER = 0.5
INTERVAL = 0.05

ZOOM = {"app": "zoom", "name": "Zoom", "bundle_id": "us.zoom.xos"}
TEAMS = {"app": "teams", "name": "Microsoft Teams", "bundle_id": "com.microsoft.teams2"}


def _helper_supports_watch() -> bool:
    if not HELPER.exists():
        return False
    out = subprocess.run([str(HELPER), "--help"], capture_output=True, text=True, timeout=10)
    return "watch-meetings" in out.stdout + out.stderr


pytestmark = [
    pytest.mark.macos,
    pytest.mark.skipif(not _helper_supports_watch(), reason="ownscribe-audio with watch-meetings not built"),
]


class Watcher:
    def __init__(self, *, debug: bool = True) -> None:
        self.events: list[dict] = []
        self._next_id = 0
        args = ["--start-after", str(START_AFTER), "--end-after", str(END_AFTER), "--interval", str(INTERVAL)]
        self.proc = subprocess.Popen(
            [str(HELPER), "watch-meetings", "--control", "stdio", *(["--debug-commands"] if debug else []), *args],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1,
        )
        self._reader = threading.Thread(target=self._read, daemon=True)
        self._reader.start()
        self.ready = self.wait_for("watch_ready")

    def _read(self) -> None:
        for line in self.proc.stdout:
            self.events.append(json.loads(line))

    def send(self, **command) -> dict:
        """Send a command and return its ack, whose `t` is when the helper handled it."""
        self._next_id += 1
        self.proc.stdin.write(json.dumps({**command, "id": self._next_id}) + "\n")
        self.proc.stdin.flush()
        return self.wait_for("ack", id=self._next_id)

    def process(self, bundle_id: str, pid: int, *, input: bool = False, output: bool = False) -> dict:
        return self.send(cmd="debug_process", bundle_id=bundle_id, pid=pid, input=input, output=output)

    def gone(self, bundle_id: str, pid: int) -> dict:
        return self.send(cmd="debug_process", bundle_id=bundle_id, pid=pid, gone=True)

    def wait_for(self, ev: str, timeout: float = 5, after: float = -1, **fields) -> dict:
        """The first `ev` event with these fields at or after helper time `after`."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for e in list(self.events):
                if e["ev"] == ev and e["t"] >= after and all(e.get(k) == v for k, v in fields.items()):
                    return e
            time.sleep(0.01)
        raise AssertionError(f"no {ev} {fields} within {timeout} s; got {self.events}")

    def meetings(self) -> list[dict]:
        return [e for e in self.events if e["ev"].startswith("meeting_")]

    def finish(self, timeout: float = 10) -> int:
        code = self.proc.wait(timeout=timeout)
        self._reader.join(timeout=5)
        return code

    def stop(self) -> int:
        self.send(cmd="stop")
        return self.finish()


@pytest.fixture
def watcher():
    w = Watcher()
    yield w
    if w.proc.poll() is None:
        w.proc.kill()
        w.finish()


def _strip_t(event: dict) -> dict:
    return {k: v for k, v in event.items() if k != "t"}


def test_watch_ready_lists_the_apps(watcher):
    assert _strip_t(watcher.ready) == {"ev": "watch_ready", "v": "2.3.0", "apps": [ZOOM, TEAMS]}
    assert watcher.stop() == 0


def test_input_starts_a_meeting_after_the_debounce(watcher):
    watcher.process("us.zoom.xos", 123)  # Zoom open but idle
    time.sleep(0.4)
    assert watcher.meetings() == []

    on = watcher.process("us.zoom.xos", 123, input=True, output=True)
    started = watcher.wait_for("meeting_started")
    assert _strip_t(started) == {"ev": "meeting_started", **ZOOM, "pid": 123}
    assert START_AFTER - 0.002 <= started["t"] - on["t"] < START_AFTER + 0.3
    assert watcher.stop() == 0


def test_input_blips_shorter_than_the_debounce_are_ignored(watcher):
    for _ in range(3):  # together longer than the debounce, but each one restarts it
        watcher.process("us.zoom.xos", 123, input=True)
        time.sleep(0.08)
        watcher.process("us.zoom.xos", 123, input=False)
        time.sleep(0.03)
    time.sleep(0.5)
    assert watcher.meetings() == []
    assert watcher.stop() == 0


def test_output_alone_keeps_a_meeting_active_and_silence_ends_it(watcher):
    watcher.process("us.zoom.xos", 123, input=True, output=True)
    started = watcher.wait_for("meeting_started")

    watcher.process("us.zoom.xos", 123, input=False, output=True)  # muted, others talking
    time.sleep(END_AFTER * 2)
    assert [e["ev"] for e in watcher.meetings()] == ["meeting_started"]

    off = watcher.process("us.zoom.xos", 123, input=False, output=False)
    ended = watcher.wait_for("meeting_ended")
    assert _strip_t(ended) == {"ev": "meeting_ended", **ZOOM, "reason": "audio_stopped",
                               "duration": ended["duration"]}
    assert END_AFTER - INTERVAL - 0.01 <= ended["t"] - off["t"] < END_AFTER + 0.4
    assert abs(ended["duration"] - (ended["t"] - started["t"])) < 0.01

    again = watcher.process("us.zoom.xos", 123, input=True)  # the next call is reported too
    watcher.wait_for("meeting_started", after=again["t"])
    assert watcher.stop() == 0


def test_process_gone_ends_the_meeting_at_once(watcher):
    watcher.process("us.zoom.xos", 123, input=True, output=True)
    watcher.wait_for("meeting_started")
    gone = watcher.gone("us.zoom.xos", 123)
    ended = watcher.wait_for("meeting_ended")
    assert ended["reason"] == "app_quit" and ended["app"] == "zoom"
    assert ended["t"] - gone["t"] < 0.1  # no end-after wait
    assert watcher.stop() == 0


def test_a_helper_quitting_while_the_main_process_stays_is_not_app_quit(watcher):
    watcher.process("com.microsoft.teams2", 50)  # main process, idle
    watcher.process("com.microsoft.teams2.modulehost", 55, input=True, output=True)
    watcher.wait_for("meeting_started", app="teams")
    watcher.gone("com.microsoft.teams2.modulehost", 55)
    ended = watcher.wait_for("meeting_ended", app="teams")
    assert ended["reason"] == "audio_stopped"
    assert watcher.stop() == 0


@pytest.mark.parametrize(
    ("bundle_id", "app"),
    [
        ("com.microsoft.teams2.modulehost", TEAMS),
        ("com.microsoft.teams2.helper", TEAMS),
        ("com.microsoft.teams2", TEAMS),
        ("com.microsoft.teams", TEAMS),
        ("com.microsoft.teams.helper", TEAMS),
        ("us.zoom.xos", ZOOM),
        ("us.zoom.CptHost", ZOOM),
    ],
)
def test_helper_processes_map_to_the_app_and_its_main_bundle(watcher, bundle_id, app):
    watcher.process(bundle_id, 77, input=True)
    started = watcher.wait_for("meeting_started")
    assert _strip_t(started) == {"ev": "meeting_started", **app, "pid": 77}
    assert watcher.stop() == 0


def test_unrelated_bundles_are_ignored(watcher):
    for pid, bundle_id in enumerate(
        ["com.apple.FaceTime", "us.zoomer.app", "com.microsoft.teams2x", "com.microsoft.teamsapp", "zoom"], start=1
    ):
        watcher.process(bundle_id, pid, input=True, output=True)
    time.sleep(START_AFTER * 3)
    assert watcher.meetings() == []
    assert watcher.stop() == 0


def test_a_call_already_running_at_the_first_report_is_detected(watcher):
    first = watcher.process("com.microsoft.teams2.modulehost", 91, input=True, output=True)
    started = watcher.wait_for("meeting_started")
    assert _strip_t(started) == {"ev": "meeting_started", **TEAMS, "pid": 91}
    assert started["t"] - first["t"] >= START_AFTER - 0.002
    assert watcher.stop() == 0


def test_two_apps_are_tracked_independently(watcher):
    watcher.process("us.zoom.xos", 1, input=True)
    watcher.wait_for("meeting_started", app="zoom")
    watcher.process("com.microsoft.teams2", 2, input=True)
    watcher.wait_for("meeting_started", app="teams")
    watcher.gone("us.zoom.xos", 1)
    watcher.wait_for("meeting_ended", app="zoom", reason="app_quit")
    time.sleep(END_AFTER * 1.5)
    assert [(e["ev"], e["app"]) for e in watcher.meetings()] == [
        ("meeting_started", "zoom"), ("meeting_started", "teams"), ("meeting_ended", "zoom"),
    ]
    assert watcher.stop() == 0


def test_stdin_eof_exits_cleanly(watcher):
    watcher.process("us.zoom.xos", 123, input=True)
    watcher.wait_for("meeting_started")
    watcher.proc.stdin.close()  # the app quit or crashed
    assert watcher.finish() == 0


def test_debug_commands_need_the_flag():
    # Without --debug-commands the watcher reads Core Audio; reading process flags needs no permission.
    w = Watcher(debug=False)
    w.proc.stdin.write(json.dumps({"cmd": "debug_process", "bundle_id": "us.zoom.xos", "pid": 1, "id": 1}) + "\n")
    w.proc.stdin.flush()
    error = w.wait_for("error", id=1)
    assert error["code"] == "unknown_command"
    assert w.stop() == 0
