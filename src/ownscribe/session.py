"""Session folders shared between the GUI, the capture helper and ownscribe jobs.

The helper owns ``capture.json``; ownscribe owns ``session.json``. See docs/engine-protocol.md.
"""

from __future__ import annotations

import contextlib
import json
import os
import re
from datetime import datetime
from pathlib import Path
from typing import Any

SESSION_FILE = "session.json"
STAGES = ("transcription", "diarization", "summarization", "vault")
# GUI sessions are YYYY-MM-DD_HHMMSS, CLI recordings YYYY-MM-DD_HHMM; both may carry a title suffix.
_ID_RE = re.compile(r"^\d{4}-\d{2}-\d{2}_\d{4}")


def _now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def new_session(output_dir: Path) -> Path:
    """Create ``<output_dir>/<YYYY-MM-DD_HHMMSS>`` (suffixed if taken) with a fresh session.json."""
    output_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y-%m-%d_%H%M%S")
    path = output_dir / stamp
    suffix = 2
    while path.exists():
        path = output_dir / f"{stamp}-{suffix}"
        suffix += 1
    path.mkdir()
    save(path, initial_state(path.name))
    return path


def initial_state(session_id: str) -> dict[str, Any]:
    return {
        "version": 1,
        "id": session_id,
        "title": None,
        "created": _now(),
        "options": {},
        "stages": {stage: {"status": "pending"} for stage in STAGES},
        "speakers": {"labels": [], "names": {}, "roles": {}},
        "summary": None,
        "vault_preview": None,
        "vault_note": None,
    }


def load(path: Path) -> dict[str, Any]:
    """session.json for a session folder; a folder without one (e.g. a CLI recording) gets a fresh state."""
    try:
        data = json.loads((path / SESSION_FILE).read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return initial_state(path.name)
    base = initial_state(data.get("id") or path.name)
    base.update(data)
    for stage in STAGES:
        base["stages"].setdefault(stage, {"status": "pending"})
    return base


def save(path: Path, state: dict[str, Any]) -> None:
    """Atomic write: a reader (the GUI) never sees a half-written file."""
    tmp = path / f".{SESSION_FILE}.tmp"
    tmp.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n")
    os.replace(tmp, path / SESSION_FILE)


def set_stage(path: Path, state: dict[str, Any], stage: str, status: str, **extra: Any) -> None:
    entry = {"status": status, "updated": _now(), **extra}
    if status != "failed":
        entry.pop("error", None)
    state["stages"][stage] = entry
    save(path, state)


def list_sessions(output_dir: Path) -> list[dict[str, Any]]:
    """Folders under ``output_dir`` that hold a recording or a session.json, newest first."""
    if not output_dir.is_dir():
        return []
    sessions = []
    for path in sorted(output_dir.iterdir(), reverse=True):
        if not path.is_dir() or not _ID_RE.match(path.name):
            continue
        has_state = (path / SESSION_FILE).exists()
        recording = path / "recording.wav"
        if not has_state and not recording.exists() and not (path / "transcript.md").exists():
            continue
        state = load(path)
        capture = {}
        with contextlib.suppress(FileNotFoundError, json.JSONDecodeError):
            capture = json.loads((path / "capture.json").read_text())
        sessions.append(
            {
                "id": state["id"],
                "path": str(path),
                "title": state.get("title"),
                "created": state.get("created"),
                "duration": capture.get("duration"),
                "capture_status": capture.get("status"),
                "has_recording": recording.exists(),
                "has_transcript": (path / "transcript.md").exists() or (path / "transcript.json").exists(),
                "has_summary": (path / "summary.md").exists(),
                "stages": {k: v.get("status") for k, v in state["stages"].items()},
            }
        )
    return sessions
