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
