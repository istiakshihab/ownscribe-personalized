"""Tests for the claude-CLI summarization backend."""

from __future__ import annotations

from unittest import mock

import pytest

from ownscribe.config import Config, SummarizationConfig
from ownscribe.summarization import create_summarizer
from ownscribe.summarization.claude_summarizer import CLAUDE_CONTEXT_SIZE, ClaudeSummarizer


def _summarizer(**kwargs) -> ClaudeSummarizer:
    return ClaudeSummarizer(SummarizationConfig(backend="claude", **kwargs), claude_bin="/bin/claude")


class TestCreateSummarizer:
    def test_claude_backend(self):
        config = Config()
        config.summarization.backend = "claude"
        config.paths.claude = "/opt/claude"
        summarizer = create_summarizer(config)
        assert isinstance(summarizer, ClaudeSummarizer)
        assert summarizer._claude_bin == "/opt/claude"

    def test_obsidian_claude_bin_wins(self):
        config = Config()
        config.summarization.backend = "claude"
        config.obsidian.claude_bin = "/custom/claude"
        config.paths.claude = "/opt/claude"
        assert create_summarizer(config)._claude_bin == "/custom/claude"


class TestClaudeSummarizer:
    def test_summarize_sends_template_and_transcript(self):
        with mock.patch("ownscribe.summarization.claude_summarizer.run_claude", return_value="## Summary\nok") as run:
            result = _summarizer().summarize("[00:00] SPEAKER_00: hello", template="meeting")
        assert result == "## Summary\nok"
        prompt = run.call_args.args[0]
        assert "SPEAKER_00: hello" in prompt
        assert run.call_args.args[1] == "/bin/claude"

    def test_strips_think_tags(self):
        with mock.patch("ownscribe.summarization.claude_summarizer.run_claude", return_value="<think>x</think>\nDone"):
            assert _summarizer().summarize("text") == "Done"

    def test_generate_title(self):
        title = '"Recorder Layout Review"\n'
        with mock.patch("ownscribe.summarization.claude_summarizer.run_claude", return_value=title):
            assert _summarizer().generate_title("summary") == "Recorder Layout Review"

    def test_chat_json_mode_unwraps_code_fence(self):
        fenced = '```json\n{"a": 1}\n```'
        with mock.patch("ownscribe.summarization.claude_summarizer.run_claude", return_value=fenced) as run:
            assert _summarizer().chat("system", "user", json_mode=True) == '{"a": 1}'
        assert "JSON" in run.call_args.args[0]

    def test_errors_propagate(self):
        from ownscribe.claude_cli import ClaudeCliError

        with (
            mock.patch("ownscribe.summarization.claude_summarizer.run_claude", side_effect=ClaudeCliError("boom")),
            pytest.raises(ClaudeCliError),
        ):
            _summarizer().summarize("text")

    def test_context_size(self):
        assert _summarizer().context_size == CLAUDE_CONTEXT_SIZE
        assert _summarizer(context_size=4096).context_size == 4096

    def test_is_available(self):
        from ownscribe.claude_cli import ClaudeCliError

        s = ClaudeSummarizer(SummarizationConfig(backend="claude"))
        with mock.patch("ownscribe.summarization.claude_summarizer.resolve_claude_bin", return_value="/bin/claude"):
            assert s.is_available()
        with mock.patch(
            "ownscribe.summarization.claude_summarizer.resolve_claude_bin", side_effect=ClaudeCliError("missing")
        ):
            assert not s.is_available()
