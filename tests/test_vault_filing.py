"""Tests for the Obsidian vault-filing step."""

from __future__ import annotations

from unittest import mock

import pytest


class TestParseDelimitedResponse:
    def test_parses_all_sections(self):
        from ownscribe.vault_filing import parse_delimited_response

        text = (
            "<<<TITLE>>>\nCOLM Paper Confidence Control\n"
            "<<<CATEGORY>>>\nResearch\n"
            "<<<TAGS>>>\nresearch, meeting, colm\n"
            "<<<BODY>>>\n### 1. Topic\nSome notes.\n\n## Action Items\n- [ ] do thing"
        )
        parsed = parse_delimited_response(text)

        assert parsed["title"] == "COLM Paper Confidence Control"
        assert parsed["category"] == "Research"
        assert parsed["tags"] == ["research", "meeting", "colm"]
        assert parsed["body_markdown"].startswith("### 1. Topic")

    def test_missing_marker_raises(self):
        from ownscribe.vault_filing import VaultFilingError, parse_delimited_response

        with pytest.raises(VaultFilingError):
            parse_delimited_response("<<<TITLE>>>\nOnly a title\n")

    def test_body_is_verbatim_to_end_of_response(self):
        from ownscribe.vault_filing import parse_delimited_response

        text = (
            "<<<TITLE>>>\nT\n<<<CATEGORY>>>\nPersonal\n<<<TAGS>>>\npersonal\n"
            '<<<BODY>>>\nLine with "quotes" and\nnewlines, verbatim.\n'
        )
        parsed = parse_delimited_response(text)
        assert 'Line with "quotes" and\nnewlines, verbatim.' in parsed["body_markdown"]


class TestDiarizationNote:
    def test_notes_diarization_present(self):
        from ownscribe.vault_filing import _diarization_note

        note = _diarization_note(True)
        assert "SPEAKER_00" in note

    def test_notes_speakers_already_named(self):
        from ownscribe.vault_filing import _diarization_note

        note = _diarization_note(True, speakers_named=True)
        assert "SPEAKER_00" not in note
        assert "real names" in note

    def test_speakers_named_ignored_without_diarization(self):
        from ownscribe.vault_filing import _diarization_note

        # speakers_named is meaningless without has_speakers=True
        assert _diarization_note(False, speakers_named=True) == _diarization_note(False)

    def test_notes_diarization_absent(self):
        from ownscribe.vault_filing import _diarization_note

        note = _diarization_note(False)
        assert "no speaker diarization" in note
        assert "inventing" in note


class TestWriteNote:
    def test_known_category_maps_to_folder(self, tmp_path):
        from ownscribe.vault_filing import write_note

        parsed = {
            "title": "Weekly Sync",
            "category": "Research",
            "tags": ["research", "meeting"],
            "body_markdown": "## Action Items\n- [ ] follow up",
        }
        note = write_note(parsed, "2026-08-19_0952", "2026-08-19", tmp_path)

        assert note.needs_review is False
        assert note.path == tmp_path / "Research" / "2026-08-19 Weekly Sync.md"
        text = note.path.read_text()
        assert 'category: "Research"' in text
        assert "source: transcript-pipeline" in text
        assert "recorder: ownscribe" in text
        assert "transcript_folder:" in text

    def test_unknown_category_falls_back_to_inbox(self, tmp_path):
        from ownscribe.vault_filing import write_note

        parsed = {"title": "Random Chat", "category": "Unknown", "tags": [], "body_markdown": "body"}
        note = write_note(parsed, "folder", "2026-08-19", tmp_path)

        assert note.needs_review is True
        assert note.path.parent.name == "Meetings Inbox"
        text = note.path.read_text()
        assert 'status: "needs-review"' in text
        assert 'category: "Needs Review"' in text

    def test_filename_collision_appends_counter(self, tmp_path):
        from ownscribe.vault_filing import write_note

        parsed = {"title": "Standup", "category": "Personal", "tags": ["personal"], "body_markdown": "b"}
        first = write_note(parsed, "f1", "2026-08-19", tmp_path)
        second = write_note(parsed, "f2", "2026-08-19", tmp_path)

        assert first.path != second.path
        assert second.path.name == "2026-08-19 Standup (2).md"

    def test_empty_tags_default_to_category_slug(self, tmp_path):
        from ownscribe.vault_filing import write_note

        parsed = {"title": "T", "category": "Podcast", "tags": [], "body_markdown": "b"}
        note = write_note(parsed, "f", "2026-08-19", tmp_path)
        assert "  - podcast" in note.path.read_text()


class TestBuildPrompt:
    def test_fills_all_placeholders(self, tmp_path, monkeypatch):
        import ownscribe.vault_filing as vf

        template_path = tmp_path / "template.txt"
        template_path.write_text("{folder_name}|{meeting_name}|{diarization_note}|{transcript_text}")
        monkeypatch.setattr(vf, "PROMPT_TEMPLATE_PATH", template_path)
        monkeypatch.setattr(vf, "CONFIG_DIR", tmp_path)

        prompt = vf.build_prompt("folder-1", "folder-1", "hello world", True)

        assert prompt.startswith("folder-1|folder-1|")
        assert "SPEAKER_00" in prompt
        assert prompt.endswith("hello world")

    def test_seeds_default_template_when_missing(self, tmp_path, monkeypatch):
        import ownscribe.vault_filing as vf

        template_path = tmp_path / "config" / "vault_prompt_template.txt"
        monkeypatch.setattr(vf, "PROMPT_TEMPLATE_PATH", template_path)
        monkeypatch.setattr(vf, "CONFIG_DIR", tmp_path / "config")

        vf.build_prompt("f", "f", "text", False)

        assert template_path.exists()
        assert "{transcript_text}" in vf._DEFAULT_TEMPLATE_PATH.read_text()


class TestResolveClaudeBin:
    def test_uses_configured_path_without_lookup(self):
        from ownscribe.vault_filing import _resolve_claude_bin

        with mock.patch("shutil.which") as mock_which:
            result = _resolve_claude_bin("/custom/claude")
        mock_which.assert_not_called()
        assert result == "/custom/claude"

    def test_falls_back_to_path_lookup(self):
        from ownscribe.vault_filing import _resolve_claude_bin

        with mock.patch("shutil.which", return_value="/usr/local/bin/claude"):
            assert _resolve_claude_bin("") == "/usr/local/bin/claude"

    def test_raises_when_not_found(self):
        from ownscribe.vault_filing import VaultFilingError, _resolve_claude_bin

        with mock.patch("shutil.which", return_value=None), pytest.raises(VaultFilingError):
            _resolve_claude_bin("")


class TestFileToVault:
    def test_raises_on_empty_transcript(self, tmp_path):
        from ownscribe.config import Config
        from ownscribe.transcription.models import TranscriptResult
        from ownscribe.vault_filing import VaultFilingError, file_to_vault

        result = TranscriptResult(segments=[])
        with pytest.raises(VaultFilingError):
            file_to_vault(Config(), result, tmp_path / "2026-08-19_0952")

    def test_derives_date_from_folder_prefix(self, tmp_path, monkeypatch):
        import ownscribe.vault_filing as vf
        from ownscribe.config import Config
        from ownscribe.transcription.models import Segment, TranscriptResult

        result = TranscriptResult(segments=[Segment(text="hello", start=0.0, end=1.0)])
        out_dir = tmp_path / "2026-08-19_0952_some-title"

        captured = {}

        def fake_write_note(parsed, folder_name, date, vault_dir):
            captured["date"] = date
            captured["folder_name"] = folder_name
            return vf.FiledNote(path=vault_dir / "note.md", needs_review=False)

        with (
            mock.patch.object(vf, "_resolve_claude_bin", return_value="/bin/claude"),
            mock.patch.object(vf, "build_prompt", return_value="prompt"),
            mock.patch.object(vf, "call_claude", return_value={"title": "T", "category": "Personal", "tags": []}),
            mock.patch.object(vf, "write_note", side_effect=fake_write_note),
        ):
            vf.file_to_vault(Config(), result, out_dir)

        assert captured["date"] == "2026-08-19"
        assert captured["folder_name"] == "2026-08-19_0952_some-title"
