"""JSON-lines job events for GUI clients (docs/engine-protocol.md, section 3)."""

from __future__ import annotations

import contextlib
import json
import math
import os
import threading
import time
from typing import Any


def _clean(value: Any) -> Any:
    """JSON has no NaN/infinity; send null instead."""
    if isinstance(value, float) and not math.isfinite(value):
        return None
    if isinstance(value, dict):
        return {k: _clean(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_clean(v) for v in value]
    return value


class EventSink:
    """Writes one JSON object per line to a file descriptor, from any thread.

    The descriptor is duplicated at construction, so the transcriber's process-wide
    ``redirect_stdout`` and the summarizer's ``dup2`` of fd 2 can't swallow or corrupt events.
    A client that goes away (EPIPE) just turns the sink off; the job keeps running.
    """

    def __init__(self, fd: int | None) -> None:
        self._lock = threading.Lock()
        self._stream = os.fdopen(os.dup(fd), "w", buffering=1, encoding="utf-8") if fd is not None else None

    @property
    def enabled(self) -> bool:
        return self._stream is not None

    def emit(self, ev: str, **fields: Any) -> None:
        if self._stream is None:
            return
        line = json.dumps(_clean({"ev": ev, "ts": round(time.time(), 3), **fields}), ensure_ascii=False)
        with self._lock:
            if self._stream is None:
                return
            try:
                self._stream.write(line + "\n")
                self._stream.flush()
            except (BrokenPipeError, OSError):
                self._stream = None

    def close(self) -> None:
        with self._lock:
            if self._stream is not None:
                with contextlib.suppress(OSError):
                    self._stream.close()
                self._stream = None


class NullSink(EventSink):
    def __init__(self) -> None:
        super().__init__(None)
