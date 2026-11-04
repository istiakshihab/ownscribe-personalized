"""Tests for the Core Audio helper command line."""

from __future__ import annotations

from pathlib import Path
from unittest import mock


def _make_recorder(**kwargs):
    from ownscribe.audio.coreaudio import CoreAudioRecorder

    binary = Path("/usr/local/bin/ownscribe-audio")
    with mock.patch("ownscribe.audio.coreaudio._find_binary", return_value=binary):
        return CoreAudioRecorder(**kwargs)


def _capture_cmd(recorder, tmp_path: Path) -> list[str]:
    with mock.patch("ownscribe.audio.coreaudio.subprocess.Popen") as mock_popen:
        recorder.start(tmp_path / "recording.wav")
    return mock_popen.call_args[0][0]


class TestDownloadBinaryArchitecture:
    """Releases only publish ownscribe-audio-arm64; anything else must say so."""

    @staticmethod
    def _download(platform_name: str, machine: str, capsys):
        from ownscribe.audio import coreaudio

        with (
            mock.patch.object(coreaudio.sys, "platform", platform_name),
            mock.patch.object(coreaudio.platform, "machine", return_value=machine),
            mock.patch.object(coreaudio.urllib.request, "urlretrieve") as urlretrieve,
        ):
            result = coreaudio._download_binary()
        return result, urlretrieve, capsys.readouterr()

    def test_intel_mac_explains_instead_of_downloading(self, capsys):
        result, urlretrieve, captured = self._download("darwin", "x86_64", capsys)

        assert result is None
        # A download would 404; the failure used to be swallowed silently.
        urlretrieve.assert_not_called()
        assert "Apple Silicon" in captured.err
        assert "x86_64" in captured.err

    def test_non_macos_stays_quiet(self, capsys):
        result, urlretrieve, captured = self._download("linux", "x86_64", capsys)

        assert result is None
        urlretrieve.assert_not_called()
        assert captured.err == ""

    def test_apple_silicon_still_downloads(self, tmp_path):
        from ownscribe.audio import coreaudio

        with (
            mock.patch.object(coreaudio.sys, "platform", "darwin"),
            mock.patch.object(coreaudio.platform, "machine", return_value="arm64"),
            mock.patch.object(coreaudio, "_CACHE_DIR", tmp_path),
            mock.patch.object(coreaudio.urllib.request, "urlretrieve") as urlretrieve,
            mock.patch.object(Path, "chmod"),
        ):
            result = coreaudio._download_binary()

        assert result == tmp_path / "ownscribe-audio"
        assert "ownscribe-audio-arm64" in urlretrieve.call_args[0][0]


class TestCoreAudioRecorderCommand:
    def test_mic_and_device_passed_when_mic_enabled(self, tmp_path):
        cmd = _capture_cmd(_make_recorder(mic=True, mic_device="USB Mic"), tmp_path)

        assert "--mic" in cmd
        assert cmd[cmd.index("--mic-device") + 1] == "USB Mic"

    def test_mic_device_ignored_when_mic_disabled(self, tmp_path):
        cmd = _capture_cmd(_make_recorder(mic=False, mic_device="USB Mic"), tmp_path)

        assert "--mic" not in cmd
        assert "--mic-device" not in cmd

    def test_capture_mode_all(self, tmp_path):
        cmd = _capture_cmd(_make_recorder(capture_mode="all"), tmp_path)

        assert "--capture-mode-all" in cmd

    def test_capture_mode_picker(self, tmp_path):
        cmd = _capture_cmd(_make_recorder(capture_mode="picker"), tmp_path)

        assert "--capture-mode-all" not in cmd

    def test_silence_timeout_passed(self, tmp_path):
        cmd = _capture_cmd(_make_recorder(silence_timeout=120), tmp_path)

        assert cmd[cmd.index("--silence-timeout") + 1] == "120"

    def test_silence_timeout_omitted_when_disabled(self, tmp_path):
        cmd = _capture_cmd(_make_recorder(silence_timeout=0), tmp_path)

        assert "--silence-timeout" not in cmd


class TestAvoidBluetoothMicFlag:
    def _cmd(self, tmp_path, supported=True, **kwargs):
        with mock.patch("ownscribe.audio.coreaudio._helper_supports", return_value=supported):
            return _capture_cmd(_make_recorder(**kwargs), tmp_path)

    def test_passed_with_default_mic(self, tmp_path):
        cmd = self._cmd(tmp_path, mic=True, avoid_bluetooth_mic=True)

        assert "--avoid-bluetooth-mic" in cmd

    def test_named_mic_device_wins(self, tmp_path):
        cmd = self._cmd(tmp_path, mic=True, mic_device="USB Mic", avoid_bluetooth_mic=True)

        assert "--avoid-bluetooth-mic" not in cmd

    def test_omitted_without_mic(self, tmp_path):
        cmd = self._cmd(tmp_path, mic=False, avoid_bluetooth_mic=True)

        assert "--avoid-bluetooth-mic" not in cmd

    def test_outdated_helper_warns_instead_of_failing(self, tmp_path, capsys):
        # An old helper exits on unknown options, which would kill the whole recording.
        cmd = self._cmd(tmp_path, supported=False, mic=True, avoid_bluetooth_mic=True)

        assert "--avoid-bluetooth-mic" not in cmd
        assert "swift/build.sh" in capsys.readouterr().err


class TestHelperStderr:
    def test_markers_are_relabelled_and_noise_dropped(self):
        from ownscribe.audio.coreaudio import _display_line

        assert _display_line("[MIC_DEVICE] MacBook Pro Microphone (built-in, 48000 Hz)") == (
            "Mic: MacBook Pro Microphone (built-in, 48000 Hz)"
        )
        assert _display_line("[MIC_SILENT] 'X' has delivered only digital silence").startswith("Warning: ")
        assert _display_line("[MIC_NOTE] Skipped the default input").startswith("Note: ")
        assert _display_line("Mic reconfigure: audio route changed") == "Mic reconfigure: audio route changed"
        for noise in ("[MIC_MUTED]", "[SILENCE_TIMEOUT]", "Recording system audio to x", "Saved x", ""):
            assert _display_line(noise) is None

    def test_reader_sets_flags_and_queues_messages(self):
        import io

        recorder = _make_recorder(mic=True)
        stream = io.BytesIO(b"[MIC_DEVICE] Mic (built-in, 48000 Hz)\n[SILENCE_WARNING] quiet\n[SILENCE_TIMEOUT]\n")
        recorder._read_stderr(stream)

        assert recorder.silence_warning
        assert recorder.silence_timed_out
        assert recorder.pop_messages() == ["Mic: Mic (built-in, 48000 Hz)", "Warning: quiet"]
        assert recorder.pop_messages() == []

    def test_chatty_helper_does_not_block_stop(self, tmp_path):
        """A helper writing more than a pipe buffer to stderr must still stop promptly.

        stderr used to be read only after the helper exited: once the pipe filled, the helper
        blocked in its writes, ignored SIGINT and SIGTERM, and was killed with nothing saved.
        """
        import sys
        import time

        from ownscribe.audio import coreaudio

        script = tmp_path / "fake-helper"
        script.write_text(
            f"#!{sys.executable}\n"
            "import signal, sys, time\n"
            "signal.signal(signal.SIGINT, lambda *a: sys.exit(0))\n"
            "for i in range(4000):\n"
            "    print(f'Mic reconfigure: line {i} ' + 'x' * 80, file=sys.stderr)\n"
            "print('[MIC_DEVICE] Fake Mic (built-in, 48000 Hz)', file=sys.stderr, flush=True)\n"
            "time.sleep(30)\n"
        )
        script.chmod(0o755)

        with mock.patch("ownscribe.audio.coreaudio._find_binary", return_value=script):
            recorder = coreaudio.CoreAudioRecorder()
        recorder.start(tmp_path / "recording.wav")
        deadline = time.monotonic() + 10
        messages: list[str] = []
        while not any(m.startswith("Mic: ") for m in messages) and time.monotonic() < deadline:
            messages += recorder.pop_messages()
            time.sleep(0.05)

        started = time.monotonic()
        with mock.patch.object(coreaudio, "_STOP_TIMEOUT", 5):
            recorder.stop()

        assert "Mic: Fake Mic (built-in, 48000 Hz)" in messages
        assert len(messages) > 4000  # all of it drained, more than a 64 KB pipe holds
        assert time.monotonic() - started < 4
