"""Core Audio Taps recorder — wraps the Swift ownscribe-audio helper."""

from __future__ import annotations

import functools
import platform
import queue
import shutil
import signal
import subprocess
import sys
import threading
import urllib.request
from pathlib import Path

import click

from ownscribe.audio.base import AudioRecorder

# Timeouts for graceful shutdown of the Swift helper.
# SIGINT triggers track merging (system + mic), which runs at roughly 9000x realtime, so
# even a long meeting merges in seconds. Killing the helper mid-merge loses the recording,
# and wait() returns as soon as it exits, so a generous value costs nothing.
_STOP_TIMEOUT = 120  # seconds to wait after SIGINT (allows track merging)
_KILL_TIMEOUT = 10  # seconds to wait after SIGTERM before SIGKILL

# Helper stderr lines that are routine progress, not worth showing.
_NOISE_PREFIXES = ("Recording ", "Saved ", "Merged audio saved")
_NOISE_LINES = ("[MIC_MUTED]", "[MIC_UNMUTED]", "[SILENCE_TIMEOUT]")
# Helper markers rewritten into something readable.
_MARKER_LABELS = {
    "[MIC_DEVICE] ": "Mic: ",
    "[MIC_NOTE] ": "Note: ",
    "[MIC_SILENT] ": "Warning: ",
    "[SILENCE_WARNING] ": "Warning: ",
}


def _display_line(line: str) -> str | None:
    """How a helper stderr line is shown to the user, or None to hide it."""
    if not line.strip() or line in _NOISE_LINES or line.startswith(_NOISE_PREFIXES):
        return None
    for marker, label in _MARKER_LABELS.items():
        if line.startswith(marker):
            return label + line.removeprefix(marker)
    return line


@functools.lru_cache(maxsize=8)
def _helper_supports(binary: str, option: str) -> bool:
    """Whether the helper binary knows a command-line option (from its usage text).

    A helper that wasn't built from this checkout (e.g. the prebuilt release binary that
    is downloaded when bin/ownscribe-audio is missing) would reject a newer option and
    fail to record at all.
    """
    try:
        result = subprocess.run([binary, "--help"], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return False
    return option in result.stdout + result.stderr

# Look for binary relative to package, then in PATH
_BINARY_CANDIDATES = [
    Path(__file__).resolve().parents[3] / "bin" / "ownscribe-audio",  # dev: repo root
    Path(sys.prefix) / "bin" / "ownscribe-audio",
]

_CACHE_DIR = Path.home() / ".local" / "share" / "ownscribe" / "bin"
_DOWNLOAD_URL = "https://github.com/paberr/ownscribe/releases/latest/download/ownscribe-audio-{arch}"

# Releases only ever publish ownscribe-audio-arm64.
_SUPPORTED_ARCH = "arm64"


def _download_binary() -> Path | None:
    """Download the prebuilt ownscribe-audio binary from GitHub Releases."""
    if sys.platform != "darwin":
        return None

    arch = platform.machine()
    if arch != _SUPPORTED_ARCH:
        # Say so rather than 404ing on a URL that cannot exist and degrading to
        # mic-only capture with no explanation.
        click.echo(
            f"System audio capture needs an Apple Silicon Mac; this one reports '{arch}'.\n"
            "No ownscribe-audio binary is published for it, so recording falls back to "
            "the microphone via sounddevice.\n"
            "To capture system audio anyway, build the helper from source: bash swift/build.sh",
            err=True,
        )
        return None

    url = _DOWNLOAD_URL.format(arch=arch)
    dest = _CACHE_DIR / "ownscribe-audio"

    try:
        _CACHE_DIR.mkdir(parents=True, exist_ok=True)
        click.echo(f"Downloading ownscribe-audio ({arch}) from GitHub Releases...")
        urllib.request.urlretrieve(url, dest)
        dest.chmod(0o755)
        click.echo(f"Saved to {dest}")
        return dest
    except Exception as e:
        click.echo(f"Download failed: {e}", err=True)
        # Clean up partial download
        dest.unlink(missing_ok=True)
        return None


def _find_binary() -> Path | None:
    for candidate in _BINARY_CANDIDATES:
        if candidate.exists() and candidate.is_file():
            return candidate

    # Check cache directory
    cached = _CACHE_DIR / "ownscribe-audio"
    if cached.exists() and cached.is_file():
        return cached

    # Fall back to PATH
    found = shutil.which("ownscribe-audio")
    if found:
        return Path(found)

    # Try downloading
    return _download_binary()


class CoreAudioRecorder(AudioRecorder):
    """Records system audio using the ownscribe-audio Swift helper."""

    def __init__(
        self, mic: bool = False, mic_device: str = "",
        capture_mode: str = "picker", silence_timeout: int = 0,
        avoid_bluetooth_mic: bool = False,
    ) -> None:
        self._mic = mic
        self._mic_device = mic_device
        self._capture_mode = capture_mode
        self._silence_timeout = silence_timeout
        self._avoid_bluetooth_mic = avoid_bluetooth_mic
        self._process: subprocess.Popen | None = None
        self._binary = _find_binary()
        self._silence_warning: bool = False
        self._silence_timed_out: bool = False
        self._muted: bool = False
        self._stderr_reader: threading.Thread | None = None
        self._messages: queue.SimpleQueue[str] = queue.SimpleQueue()

    def is_available(self) -> bool:
        return self._binary is not None

    def start(self, output_path: Path) -> None:
        if not self._binary:
            raise RuntimeError("ownscribe-audio binary not found. Run: bash swift/build.sh")

        cmd = [str(self._binary), "capture", "--output", str(output_path)]
        if self._capture_mode == "all":
            cmd.append("--capture-mode-all")
        # A configured mic_device must not re-enable a mic that was turned off,
        # e.g. via --no-mic or mic = false in config.toml.
        if self._mic:
            cmd.append("--mic")
            if self._mic_device:
                cmd.extend(["--mic-device", self._mic_device])
            elif self._avoid_bluetooth_mic:
                if _helper_supports(str(self._binary), "--avoid-bluetooth-mic"):
                    cmd.append("--avoid-bluetooth-mic")
                else:
                    click.echo(
                        f"Warning: {self._binary} is outdated (it predates the recording fixes and can't "
                        "avoid Bluetooth headset mics). Rebuild it with: bash swift/build.sh",
                        err=True,
                    )
        if self._silence_timeout > 0:
            cmd.extend(["--silence-timeout", str(self._silence_timeout)])

        self._process = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            process_group=0,
        )
        # Drain stderr continuously. Nothing used to read it until the helper exited, so
        # once the 64 KB pipe filled, every write in the helper (its audio threads
        # included) blocked; it hung, was SIGKILLed on stop, and nothing was saved.
        self._stderr_reader = threading.Thread(
            target=self._read_stderr, args=(self._process.stderr,), daemon=True
        )
        self._stderr_reader.start()

    def _read_stderr(self, stream) -> None:
        for raw in iter(stream.readline, b""):
            self._handle_stderr_line(raw.decode(errors="replace").rstrip("\r\n"))
        stream.close()

    def _handle_stderr_line(self, line: str) -> None:
        if line.startswith("[SILENCE_WARNING]"):
            self._silence_warning = True
        if line == "[SILENCE_TIMEOUT]":
            self._silence_timed_out = True
        shown = _display_line(line)
        if shown is not None:
            self._messages.put(shown)

    def pop_messages(self) -> list[str]:
        """Helper status/warnings received since the last call (shown live while recording)."""
        messages = []
        while True:
            try:
                messages.append(self._messages.get_nowait())
            except queue.Empty:
                return messages

    @property
    def silence_warning(self) -> bool:
        """True if the Swift helper reported a silence warning."""
        return self._silence_warning

    def toggle_mute(self) -> None:
        """Send SIGUSR1 to the Swift helper to toggle mic mute."""
        if self._mic and self._process and self._process.poll() is None:
            self._process.send_signal(signal.SIGUSR1)
            self._muted = not self._muted

    @property
    def is_muted(self) -> bool:
        return self._muted

    @property
    def is_recording(self) -> bool:
        return self._process is not None and self._process.poll() is None

    @property
    def silence_timed_out(self) -> bool:
        return self._silence_timed_out

    def stop(self) -> None:
        if self._process and self._process.poll() is None:
            self._process.send_signal(signal.SIGINT)
            try:
                self._process.wait(timeout=_STOP_TIMEOUT)
            except subprocess.TimeoutExpired:
                self._process.terminate()
                try:
                    self._process.wait(timeout=_KILL_TIMEOUT)
                except subprocess.TimeoutExpired:
                    self._process.kill()
                    self._process.wait()
        if self._stderr_reader is not None:
            # The helper has exited, so the pipe hits EOF promptly.
            self._stderr_reader.join(timeout=5)
            self._stderr_reader = None
        # Whatever the recording loop didn't get to show (e.g. lines from the merge).
        if remaining := self.pop_messages():
            click.echo("\n".join(remaining), err=True)

    def list_devices(self) -> str:
        """List available audio devices using the Swift helper."""
        if not self._binary:
            return "ownscribe-audio binary not found. Run: bash swift/build.sh"
        result = subprocess.run(
            [str(self._binary), "list-devices"],
            capture_output=True,
            text=True,
        )
        return result.stdout

    def list_apps(self) -> str:
        if not self._binary:
            return "ownscribe-audio binary not found. Run: bash swift/build.sh"
        result = subprocess.run(
            [str(self._binary), "list-apps"],
            capture_output=True,
            text=True,
        )
        return result.stdout
