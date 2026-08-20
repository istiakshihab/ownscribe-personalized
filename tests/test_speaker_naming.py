"""Tests for interactive speaker naming."""

from __future__ import annotations

from unittest import mock

import pytest

from ownscribe.config import Config
from ownscribe.transcription.models import Segment, TranscriptResult, Word


def _diarized_result() -> TranscriptResult:
    return TranscriptResult(
        segments=[
            Segment(
                text="Let's start with the budget.",
                start=0.0,
                end=2.0,
                speaker="SPEAKER_00",
                words=[Word(text="Let's", start=0.0, end=0.3, speaker="SPEAKER_00")],
            ),
            Segment(text="Sounds good, I'll take notes.", start=2.0, end=4.0, speaker="SPEAKER_01"),
            Segment(text="One more thing from me.", start=4.0, end=5.0, speaker="SPEAKER_00"),
        ],
        language="en",
        duration=5.0,
    )


class TestDistinctSpeakers:
    def test_first_appearance_order_no_duplicates(self):
        from ownscribe.speaker_naming import _distinct_speakers

        assert _distinct_speakers(_diarized_result()) == ["SPEAKER_00", "SPEAKER_01"]

    def test_no_speakers_returns_empty(self):
        from ownscribe.speaker_naming import _distinct_speakers

        result = TranscriptResult(segments=[Segment(text="hi", start=0.0, end=1.0)])
        assert _distinct_speakers(result) == []


class TestGetSpeakerRoles:
    def test_parses_label_colon_blurb_lines(self):
        from ownscribe.speaker_naming import get_speaker_roles

        response_text = (
            "SPEAKER_00: Opened the meeting and covered the budget.\n"
            "SPEAKER_01: Took notes and asked about the timeline.\n"
        )
        config = Config()
        with (
            mock.patch("ownscribe.speaker_naming.resolve_claude_bin", return_value="/bin/claude"),
            mock.patch("ownscribe.speaker_naming.run_claude", return_value=response_text) as mock_run,
        ):
            roles = get_speaker_roles(config, _diarized_result())

        assert roles == {
            "SPEAKER_00": "Opened the meeting and covered the budget.",
            "SPEAKER_01": "Took notes and asked about the timeline.",
        }
        mock_run.assert_called_once()

    def test_ignores_malformed_lines(self):
        from ownscribe.speaker_naming import get_speaker_roles

        response_text = "not a speaker line\nSPEAKER_00: Valid one.\n\n"
        config = Config()
        with (
            mock.patch("ownscribe.speaker_naming.resolve_claude_bin", return_value="/bin/claude"),
            mock.patch("ownscribe.speaker_naming.run_claude", return_value=response_text),
        ):
            roles = get_speaker_roles(config, _diarized_result())

        assert roles == {"SPEAKER_00": "Valid one."}

    def test_raises_on_empty_transcript(self):
        from ownscribe.speaker_naming import SpeakerNamingError, get_speaker_roles

        empty = TranscriptResult(segments=[])
        with pytest.raises(SpeakerNamingError):
            get_speaker_roles(Config(), empty)

    def test_wraps_claude_cli_error(self):
        from ownscribe.claude_cli import ClaudeCliError
        from ownscribe.speaker_naming import SpeakerNamingError, get_speaker_roles

        with (
            mock.patch("ownscribe.speaker_naming.resolve_claude_bin", return_value="/bin/claude"),
            mock.patch("ownscribe.speaker_naming.run_claude", side_effect=ClaudeCliError("nope")),
            pytest.raises(SpeakerNamingError, match="nope"),
        ):
            get_speaker_roles(Config(), _diarized_result())


class TestPromptForNames:
    def test_collects_named_speakers_only(self):
        from ownscribe.speaker_naming import prompt_for_names

        roles = {"SPEAKER_00": "Led the meeting.", "SPEAKER_01": "Took notes."}
        with mock.patch("click.prompt", side_effect=["Alice", ""]):
            mapping = prompt_for_names(_diarized_result(), roles)

        assert mapping == {"SPEAKER_00": "Alice"}

    def test_no_speakers_skips_prompting(self):
        from ownscribe.speaker_naming import prompt_for_names

        result = TranscriptResult(segments=[Segment(text="hi", start=0.0, end=1.0)])
        with mock.patch("click.prompt") as mock_prompt:
            mapping = prompt_for_names(result, {})
        mock_prompt.assert_not_called()
        assert mapping == {}

    def test_strips_whitespace_from_names(self):
        from ownscribe.speaker_naming import prompt_for_names

        with mock.patch("click.prompt", side_effect=["  Bob  ", "  "]):
            mapping = prompt_for_names(_diarized_result(), {})

        assert mapping == {"SPEAKER_00": "Bob"}


class TestApplySpeakerNames:
    def test_renames_segments_and_words(self):
        from ownscribe.speaker_naming import apply_speaker_names

        result = _diarized_result()
        apply_speaker_names(result, {"SPEAKER_00": "Alice", "SPEAKER_01": "Bob"})

        speakers = [seg.speaker for seg in result.segments]
        assert speakers == ["Alice", "Bob", "Alice"]
        assert result.segments[0].words[0].speaker == "Alice"

    def test_partial_mapping_leaves_others_untouched(self):
        from ownscribe.speaker_naming import apply_speaker_names

        result = _diarized_result()
        apply_speaker_names(result, {"SPEAKER_00": "Alice"})

        speakers = [seg.speaker for seg in result.segments]
        assert speakers == ["Alice", "SPEAKER_01", "Alice"]

    def test_empty_mapping_is_a_noop(self):
        from ownscribe.speaker_naming import apply_speaker_names

        result = _diarized_result()
        original = [seg.speaker for seg in result.segments]
        apply_speaker_names(result, {})
        assert [seg.speaker for seg in result.segments] == original
