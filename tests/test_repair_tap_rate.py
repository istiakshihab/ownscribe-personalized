"""scripts/repair_tap_rate.py undoes the squeeze of tap audio read at the wrong sample rate.

The damage is simulated the way ownscribe-audio < 2.2 made it: a 16 kHz device delivers 20 ms buffers,
each read as 48 kHz (so written as a third of its length), and the track writer places buffers by
time, padding with silence once a run falls more than 30 ms behind.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path

import numpy as np
from scipy.signal import resample_poly

SR = 24000
_spec = importlib.util.spec_from_file_location(
    "repair_tap_rate", Path(__file__).resolve().parents[1] / "scripts" / "repair_tap_rate.py")
repair = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(repair)


def _two_tones(seconds: float) -> np.ndarray:
    t = np.arange(int(seconds * SR)) / SR
    return (0.3 * np.sin(2 * np.pi * 200 * t) + 0.2 * np.sin(2 * np.pi * 1000 * t)).astype(np.float32)


def _squeeze_like_the_old_writer(signal: np.ndarray, squeeze: int, buffer_ms: int = 20) -> np.ndarray:
    per_buffer = SR * buffer_ms // 1000
    out, written = [], 0
    for k in range(len(signal) // per_buffer):
        squeezed = resample_poly(signal[k * per_buffer:(k + 1) * per_buffer], 1, squeeze).astype(np.float32)
        target = k * per_buffer
        if target > written + 720:  # TrackWriter.toleranceFrames
            out.append(np.zeros(target - written, np.float32))
            written = target
        out.append(squeezed)
        written += len(squeezed)
    return np.concatenate(out)


def _peaks(x: np.ndarray, n: int = 2) -> list[int]:
    spectrum = np.abs(np.fft.rfft(x * np.hanning(len(x))))
    hz = np.fft.rfftfreq(len(x), 1 / SR)
    peaks = []
    for i in np.argsort(spectrum)[::-1]:
        if all(abs(hz[i] - p) > 50 for p in peaks):
            peaks.append(round(hz[i] / 10) * 10)
        if len(peaks) == n:
            return sorted(peaks)
    return sorted(peaks)


def test_a_16_khz_call_read_as_48_khz_is_stretched_back():
    truth = _two_tones(6)
    broken = _squeeze_like_the_old_writer(truth, 3)
    assert 0.6 < np.mean(broken == 0) < 0.7  # 20 ms of audio, 40 ms of silence
    assert _peaks(broken[SR:5 * SR]) == [600, 3000]  # everything 3x too high

    fixed, used = repair.repair_track(broken)

    assert used == {3.0: used[3.0]} and used[3.0] > 50
    assert np.mean(fixed[: len(truth) - SR] == 0) < 0.01
    assert _peaks(fixed[SR:5 * SR]) == [200, 1000]


def test_an_unaffected_track_is_left_alone():
    track = _two_tones(3)
    track[SR:SR + SR // 2] = 0  # a real pause
    fixed, used = repair.repair_track(track)
    assert fixed is track and set(used) <= {1.0}
