#!/usr/bin/env python3
"""Repair a session whose system or app audio was recorded at the wrong sample rate.

Until ownscribe-audio 2.2, a process tap's buffers were read as 48 kHz whatever the output device ran
at. A Bluetooth headset in a call runs at 16 kHz, so the other side of the call came out 3x fast and
chopped into 20 ms bursts with 40 ms of silence between; a 44.1 kHz device came out 9% fast with a gap
every ~0.4 s. No audio was lost. The track writer placed each run of back-to-back buffers at its true
start time and filled the rest with silence, so each run is squeezed by the ratio of the two rates, and
the distance to the next run says exactly by how much.

This stretches every run back to its real length, writes the repaired tracks into a new session folder
next to the original (which is left untouched), and rebuilds recording.wav with the helper's own merge,
so faders and the limiter apply as they did. Microphone tracks were never affected and are copied.
The repaired audio only reaches up to 12 kHz divided by the squeeze (4 kHz for a 16 kHz call): it
sounds like a phone call, which transcription handles fine.

    uv run python scripts/repair_tap_rate.py ~/ownscribe/2026-11-05_150135_some-title [--out DIR]

Then process the new folder as usual (`ownscribe process NEW_FOLDER`, or open it from Earshot).
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from collections import Counter
from fractions import Fraction
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

REPO = Path(__file__).resolve().parents[1]
HELPER = REPO / "bin" / "ownscribe-audio"
sys.path.insert(0, str(REPO / "src"))
from ownscribe import session as sessions  # noqa: E402

# The writer pads only once a run falls more than 30 ms (720 samples at 24 kHz) behind, so its padding
# is always longer than PAD; shorter stretches of zeros belong to the audio itself. And it pads as soon as
# that happens, so its padding never reaches MAX_PAD: a longer silence is a real pause (nothing playing),
# which says nothing about the squeeze of the run before it.
PAD = 600
MAX_PAD = 4800  # 200 ms
STANDARD_RATES = (8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000)
SQUEEZES = sorted({48000 / r for r in STANDARD_RATES})  # 1.0 (unaffected) ... 6.0 (8 kHz)


def snap(ratio: float) -> float | None:
    """The squeeze a run's ratio corresponds to, or None if it matches none."""
    best = min(SQUEEZES, key=lambda s: abs(s - ratio))
    return best if abs(best - ratio) / best < 0.015 else None


def runs_between_pads(x: np.ndarray) -> list[tuple[int, int, int]]:
    """(start, end, next_start) for each stretch of audio the writer wrote back to back."""
    z = (x == 0).astype(np.int8)
    edges = np.diff(np.concatenate([[0], z, [0]]))
    zs, ze = np.where(edges == 1)[0], np.where(edges == -1)[0]
    pads = [(s, e) for s, e in zip(zs, ze, strict=True) if e - s >= PAD]
    runs, prev = [], 0
    for s, e in pads:
        if s > prev:
            runs.append((prev, s))
        prev = e
    if prev < len(x):
        runs.append((prev, len(x)))
    return [(s, e, runs[i + 1][0] if i + 1 < len(runs) else len(x)) for i, (s, e) in enumerate(runs)]


def repair_track(x: np.ndarray) -> tuple[np.ndarray, Counter]:
    runs = runs_between_pads(x)
    # Each run's squeeze from the padding after it; none from a real pause or the end of the track.
    squeezes = [snap((nxt - s) / (e - s)) if 0 < nxt - e <= MAX_PAD else None for s, e, nxt in runs]
    seen = Counter(q for q in squeezes if q is not None)
    if not seen or set(seen) == {1.0}:
        return x, seen  # nothing squeezed
    squeezes = [q or 0.0 for q in squeezes]  # 0.0 = no evidence; never agrees with a neighbour
    fallback = seen.most_common(1)[0][0]
    y = np.zeros_like(x)
    used: Counter = Counter()
    last = fallback
    for i, ((s, e, nxt), q) in enumerate(zip(runs, squeezes, strict=True)):
        # The device's rate changes rarely: take a new squeeze only when the next run agrees. A run
        # without evidence, or one that disagrees with both neighbours, keeps the previous squeeze.
        if q != last and not (i + 1 < len(runs) and squeezes[i + 1] == q):
            q = last
        last = q
        if q == 1.0:
            y[s:e] = x[s:e]
            used[q] += 1
            continue
        f = Fraction(q).limit_denominator(1000)
        stretched = resample_poly(x[s:e], f.numerator, f.denominator).astype(np.float32)
        end = min(s + len(stretched), nxt, len(y))
        y[s:end] = stretched[: end - s]
        used[q] += 1
    return y, used


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("session", type=Path)
    parser.add_argument("--out", type=Path, help="new session folder (default: <id>-repaired next to it)")
    args = parser.parse_args()
    src = args.session.expanduser().resolve()
    manifest = json.loads((src / "capture.json").read_text())
    state = sessions.load(src)
    new_id = f"{state.get('id') or src.name[:17]}-repaired"
    out = (args.out or src.parent / new_id).expanduser().resolve()
    if out.exists():
        print(f"{out} already exists; pass --out or move it away.", file=sys.stderr)
        return 1
    (out / "tracks").mkdir(parents=True)

    for track in manifest["tracks"]:
        path, dest = src / track["file"], out / track["file"]
        if track["kind"] not in ("system", "app"):
            # A clone on APFS: no extra space for the untouched mic track.
            if subprocess.run(["cp", "-c", str(path), str(dest)], capture_output=True).returncode != 0:
                shutil.copy2(path, dest)
            print(f"{track['file']}: copied ({track['kind']} tracks were recorded correctly)")
            continue
        x, sr = sf.read(path, dtype="float32")
        y, seen = repair_track(x)
        sf.write(dest, y, sr, subtype="FLOAT")
        rates = ", ".join(f"{48000 / q / 1000:g} kHz x{n}" for q, n in seen.most_common())
        silent = f"{np.mean(x == 0):.0%} -> {np.mean(y == 0):.0%}"
        print(f"{track['file']}: runs by device rate: {rates or 'none'}; silent {silent}")

    manifest["recording"] = None
    (out / "capture.json").write_text(json.dumps(manifest, indent=2))
    new_state = sessions.initial_state(new_id)
    new_state.update(created=state.get("created"), options=state.get("options", {}), repaired_from=str(src))
    sessions.save(out, new_state)

    merge = subprocess.run([str(HELPER), "merge", "--session", str(out)], capture_output=True, text=True)
    if merge.returncode != 0:
        print(f"Merging failed: {merge.stderr.strip()}", file=sys.stderr)
        return 1
    print(f"Repaired session: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
