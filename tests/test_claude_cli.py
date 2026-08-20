"""Tests for the shared headless-claude subprocess helper."""

from __future__ import annotations

import json
from unittest import mock

import pytest


class TestResolveClaudeBin:
    def test_uses_configured_path_without_lookup(self):
        from ownscribe.claude_cli import resolve_claude_bin

        with mock.patch("shutil.which") as mock_which:
            result = resolve_claude_bin("/custom/claude")
        mock_which.assert_not_called()
        assert result == "/custom/claude"

    def test_falls_back_to_path_lookup(self):
        from ownscribe.claude_cli import resolve_claude_bin

        with mock.patch("shutil.which", return_value="/usr/local/bin/claude"):
            assert resolve_claude_bin("") == "/usr/local/bin/claude"

    def test_raises_when_not_found(self):
        from ownscribe.claude_cli import ClaudeCliError, resolve_claude_bin

        with mock.patch("shutil.which", return_value=None), pytest.raises(ClaudeCliError):
            resolve_claude_bin("")


class TestRunClaude:
    def test_returns_result_text_on_success(self, tmp_path):
        from ownscribe.claude_cli import run_claude

        fake_result = mock.MagicMock(returncode=0, stdout=json.dumps({"result": "hello"}), stderr="")
        with mock.patch("subprocess.run", return_value=fake_result) as mock_run:
            text = run_claude("prompt", "/bin/claude", cwd=tmp_path)

        assert text == "hello"
        args = mock_run.call_args[0][0]
        assert args[:2] == ["/bin/claude", "-p"]
        assert "--allowedTools" in args

    def test_raises_on_nonzero_exit(self, tmp_path):
        from ownscribe.claude_cli import ClaudeCliError, run_claude

        fake_result = mock.MagicMock(returncode=1, stdout="", stderr="not logged in")
        with (
            mock.patch("subprocess.run", return_value=fake_result),
            pytest.raises(ClaudeCliError, match="not logged in"),
        ):
            run_claude("prompt", "/bin/claude", cwd=tmp_path)

    def test_raises_on_is_error_envelope(self, tmp_path):
        from ownscribe.claude_cli import ClaudeCliError, run_claude

        fake_result = mock.MagicMock(
            returncode=0, stdout=json.dumps({"is_error": True, "result": "boom"}), stderr=""
        )
        with mock.patch("subprocess.run", return_value=fake_result), pytest.raises(ClaudeCliError, match="boom"):
            run_claude("prompt", "/bin/claude", cwd=tmp_path)

    def test_raises_on_non_json_stdout(self, tmp_path):
        from ownscribe.claude_cli import ClaudeCliError, run_claude

        fake_result = mock.MagicMock(returncode=0, stdout="not json at all", stderr="")
        with mock.patch("subprocess.run", return_value=fake_result), pytest.raises(ClaudeCliError, match="non-JSON"):
            run_claude("prompt", "/bin/claude", cwd=tmp_path)

    def test_tolerates_raw_control_characters_in_json(self, tmp_path):
        from ownscribe.claude_cli import run_claude

        raw_stdout = '{"result": "line one\nline two"}'
        fake_result = mock.MagicMock(returncode=0, stdout=raw_stdout, stderr="")
        with mock.patch("subprocess.run", return_value=fake_result):
            text = run_claude("prompt", "/bin/claude", cwd=tmp_path)
        assert text == "line one\nline two"
