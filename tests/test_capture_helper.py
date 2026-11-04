"""The Swift capture helper's session mode, driven over its stdio protocol with synthetic sources.

`--source test-tone` needs no Microphone or System Audio permission, so this runs anywhere the
helper is built (bash swift/build.sh). Skipped when it isn't, or when it predates session mode.
"""

from __future__ import annotations

import json
import subprocess
import threading
import time
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

HELPER = Path(__file__).resolve().parents[1] / "bin" / "ownscribe-audio"


def _helper_supports_sessions() -> bool:
    if not HELPER.exists():
        return False
    out = subprocess.run([str(HELPER), "--help"], capture_output=True, text=True, timeout=10)
    return "--session" in out.stdout + out.stderr


pytestmark = [
    pytest.mark.macos,
    pytest.mark.skipif(not _helper_supports_sessions(), reason="ownscribe-audio with session mode not built"),
]


class Session:
    def __init__(self, path: Path, *args: str) -> None:
        self.events: list[dict] = []
        self.proc = subprocess.Popen(
            [str(HELPER), "capture", "--session", str(path), "--control", "stdio", "--source", "test-tone", *args],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1,
        )
        self._reader = threading.Thread(target=self._read, daemon=True)
        self._reader.start()

    def _read(self) -> None:
        for line in self.proc.stdout:
            self.events.append(json.loads(line))

    def send(self, **command) -> None:
        self.proc.stdin.write(json.dumps(command) + "\n")
        self.proc.stdin.flush()

    def finish(self, timeout: float = 30) -> int:
        code = self.proc.wait(timeout=timeout)
        self._reader.join(timeout=5)
        return code

    def wait_for(self, ev: str, timeout: float = 15, **fields) -> dict:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for e in list(self.events):
                if e["ev"] == ev and all(e.get(k) == v for k, v in fields.items()):
                    return e
            time.sleep(0.1)
        raise AssertionError(f"no {ev} {fields} within {timeout} s")

    def states(self, source: str) -> list[str]:
        """The source's state in each `sources` snapshot, with repeats collapsed."""
        out: list[str] = []
        for e in self.events:
            if e["ev"] == "sources":
                state = next((x["state"] for x in e["list"] if x["id"] == source), None)
                if state and (not out or out[-1] != state):
                    out.append(state)
        return out


def test_protocol_round_trip_and_aligned_tracks(tmp_path):
    s = Session(tmp_path, "--mic")
    time.sleep(0.6)
    s.send(cmd="add_app", bundle_id="com.example.player", id=1)
    time.sleep(0.8)
    s.send(cmd="set_gain", source="mic", db=-12, id=2)
    s.send(cmd="set_mute", source="sys", muted=True, id=3)
    time.sleep(0.6)
    s.send(cmd="set_mute", source="sys", muted=False, id=4)
    s.send(cmd="remove_app", bundle_id="com.example.player", id=5)
    s.send(cmd="nope", id=6)
    time.sleep(0.4)
    s.send(cmd="stop", id=7)
    assert s.finish() == 0

    kinds = [e["ev"] for e in s.events]
    assert kinds[0] == "ready" and kinds[-1] == "saved"
    assert sorted(e["id"] for e in s.events if e["ev"] == "ack") == [1, 2, 3, 4, 5, 7]
    assert [e["code"] for e in s.events if e["ev"] == "error"] == ["unknown_command"]
    names = [{x["id"]: x["name"] for x in e["list"]}["sys"] for e in s.events if e["ev"] == "sources"]
    assert "Other apps" in names and names[-1] == "System audio"
    levels = [e for e in s.events if e["ev"] == "levels"]
    assert len(levels) / s.events[-1]["t"] > 10  # ~20 Hz

    manifest = json.loads((tmp_path / "capture.json").read_text())
    assert manifest["status"] == "saved"
    assert [g["db"] for g in manifest["gain_log"]] == [-12]
    lengths = {t["id"]: sf.info(str(tmp_path / t["file"])).frames for t in manifest["tracks"]}
    assert len(set(lengths.values())) == 1  # every track spans the whole session

    sys_track, sr = sf.read(str(tmp_path / "tracks/sys.wav"), dtype="float32")
    mute = next(m["t"] for m in manifest["mute_log"] if m["muted"])
    unmute = next(m["t"] for m in manifest["mute_log"] if not m["muted"])
    assert np.all(sys_track[int((mute + 0.05) * sr):int((unmute - 0.05) * sr)] == 0)  # muted audio never hit disk
    app_track, _ = sf.read(str(tmp_path / "tracks/app-com.example.player.wav"), dtype="float32")
    assert np.all(app_track[: int(0.3 * sr)] == 0)  # padded before the app was added


def test_stdin_eof_stops_and_saves(tmp_path):
    s = Session(tmp_path)
    time.sleep(0.8)
    s.proc.stdin.close()  # the GUI quit or crashed
    assert s.finish() == 0
    assert s.events[-2] == {**s.events[-2], "ev": "stopping", "reason": "stdin_closed"}
    assert (tmp_path / "recording.wav").exists()


def test_merge_recovers_a_killed_session(tmp_path):
    s = Session(tmp_path, "--mic")
    time.sleep(1.2)
    s.proc.kill()  # no chance to finalize anything
    s.finish()
    assert json.loads((tmp_path / "capture.json").read_text())["status"] == "recording"

    # Popen, not run(): conftest blocks subprocess.run to keep tests away from the real claude CLI.
    merge = subprocess.Popen([str(HELPER), "merge", "--session", str(tmp_path)],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    _, stderr = merge.communicate(timeout=30)

    assert merge.returncode == 0, stderr
    assert sf.info(str(tmp_path / "recording.wav")).duration > 0.5
    assert json.loads((tmp_path / "capture.json").read_text())["status"] == "saved"


def test_dead_source_is_detected_rebuilt_and_logged_as_a_gap(tmp_path):
    s = Session(tmp_path, "--mic", "--debug-commands")
    time.sleep(0.5)
    s.send(cmd="debug_fail_source", source="sys", fail_recoveries=1, id=1)  # first rebuild fails too
    lost = s.wait_for("notice", code="source_lost", source="sys")
    restored = s.wait_for("notice", code="source_restored", source="sys")
    s.send(cmd="stop")
    assert s.finish() == 0  # it came back, so the recording is complete apart from the gap

    assert lost["level"] == "error" and restored["t"] - lost["t"] >= 1.5  # the second rebuild worked
    assert s.states("sys") == ["active", "lost", "active"]
    assert s.states("mic") == ["active"]  # the other source never noticed
    manifest = json.loads((tmp_path / "capture.json").read_text())
    assert manifest["status"] == "saved"
    [gap] = manifest["gaps"]
    assert gap["source"] == "sys" and 0.4 < gap["from"] < 1.0 and gap["to"] > gap["from"] + 3
    assert abs(restored["gap"] - (gap["to"] - gap["from"])) < 0.2

    sys_track, sr = sf.read(str(tmp_path / "tracks/sys.wav"), dtype="float32")
    assert np.all(sys_track[int((gap["from"] + 0.1) * sr):int((gap["to"] - 0.1) * sr)] == 0)
    assert np.any(sys_track[int(gap["to"] * sr):] != 0)  # audio again after the gap


def test_source_still_lost_at_stop_makes_the_session_partial(tmp_path):
    s = Session(tmp_path, "--mic", "--debug-commands")
    time.sleep(0.5)
    s.send(cmd="debug_fail_source", source="mic", fail_recoveries=99, id=1)
    s.wait_for("notice", code="source_lost", source="mic")
    s.send(cmd="stop")
    assert s.finish() == 2
    assert s.events[-1]["status"] == "partial" and s.events[-1]["recording"]
    manifest = json.loads((tmp_path / "capture.json").read_text())
    assert manifest["status"] == "partial"
    assert [(g["source"], g["to"]) for g in manifest["gaps"]] == [("mic", None)]


def test_debug_commands_need_the_flag(tmp_path):
    s = Session(tmp_path)
    time.sleep(0.4)
    s.send(cmd="debug_fail_source", source="sys", id=1)
    s.send(cmd="stop")
    assert s.finish() == 0
    assert [e["code"] for e in s.events if e["ev"] == "error"] == ["unknown_command"]
    assert "gaps" not in json.loads((tmp_path / "capture.json").read_text())
