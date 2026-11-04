"""Tests for the GUI job layer: events, sessions, the process/speakers/resummarize/file jobs."""

from __future__ import annotations

import contextlib
import io
import json
import os
from pathlib import Path
from unittest import mock

import numpy as np
import pytest
import soundfile as sf

from ownscribe import jobs
from ownscribe import session as sessions
from ownscribe.config import Config
from ownscribe.events import EventSink
from ownscribe.transcription.models import Segment, TranscriptResult

# ----------------------------------------------------------------- helpers


class EventPipe:
    """An EventSink on a real pipe, so tests read back exactly what a GUI would."""

    def __init__(self) -> None:
        self._r, w = os.pipe()
        self.sink = EventSink(w)
        os.close(w)  # the sink holds its own duplicate

    def events(self) -> list[dict]:
        self.sink.close()
        with os.fdopen(self._r) as f:
            return [json.loads(line) for line in f if line.strip()]


def _wav(path: Path, seconds: float = 2.0, silent: bool = False) -> None:
    t = np.arange(int(16000 * seconds)) / 16000
    data = np.zeros_like(t) if silent else 0.2 * np.sin(2 * np.pi * 440 * t)
    sf.write(str(path), data.astype("float32"), 16000, subtype="FLOAT")


SEGMENTS = [(0.0, 2.5, "We should ship on Friday."), (2.6, 5.0, "Agreed, I'll write the notes."), (5.1, 8.0, "Great.")]
SPEAKERS = ["SPEAKER_00", "SPEAKER_01", "SPEAKER_00"]


class FakeTranscriber:
    def __init__(self, tx_config, diar_config=None, progress=None, need_word_timestamps=False, on_segment=None):
        self.diarize = diar_config is not None
        self.progress = progress
        self.on_segment = on_segment

    def transcribe(self, audio_path):
        self.progress.begin("transcribing")
        for start, end, text in SEGMENTS:
            self.on_segment(start, end, text)
            self.progress.update("transcribing", end / 8.0)
        self.progress.complete("transcribing")
        if self.diarize:
            self.progress.begin("diarizing")
            for step in ("segmentation", "speaker_counting", "embeddings", "discrete_diarization"):
                self.progress.diarization_hook(step, None, completed=1, total=1)
            self.progress.complete("diarizing")
        return TranscriptResult(
            segments=[
                Segment(text=text, start=start, end=end, speaker=(SPEAKERS[i] if self.diarize else None))
                for i, (start, end, text) in enumerate(SEGMENTS)
            ],
            language="en",
            duration=8.0,
        )


class FakeSummarizer:
    def __init__(self) -> None:
        self.calls: list[tuple[str, str | None]] = []

    def is_available(self):
        return True

    def summarize(self, text, template=None):
        self.calls.append((text, template))
        return "SPEAKER_00 proposed shipping on Friday; SPEAKER_01 writes the notes."

    def generate_title(self, summary):
        return "Friday ship plan"

    def close(self):
        pass


@pytest.fixture
def config():
    cfg = Config()
    cfg.summarization.backend = "ollama"  # no model download in tests
    cfg.diarization.enabled = True
    cfg.diarization.hf_token = "hf_test"
    return cfg


@pytest.fixture
def session_dir(tmp_path):
    path = sessions.new_session(tmp_path / "out")
    _wav(path / "recording.wav")
    return path


@contextlib.contextmanager
def fakes(summarizer=None):
    summarizer = summarizer or FakeSummarizer()
    with (
        mock.patch("ownscribe.transcription.mlx_transcriber.MLXWhisperTranscriber", FakeTranscriber),
        mock.patch("ownscribe.jobs.create_summarizer", return_value=summarizer),
        mock.patch("ownscribe.jobs.shutil.which", return_value="/opt/homebrew/bin/ffmpeg"),
    ):
        yield summarizer


# ----------------------------------------------------------------- live segments


class TestSegmentParsing:
    def test_formats_mlx_whisper_prints(self):
        from ownscribe.transcription.mlx_transcriber import parse_segment_line

        # mlx_whisper/transcribe.py: f"[{ts(start)} --> {ts(end)}] {text}", HH: only past an hour
        assert parse_segment_line("[00:05.120 --> 00:09.000]  Hello there") == (5.12, 9.0, "Hello there")
        assert parse_segment_line("[01:02:03.004 --> 01:02:05.500] Long meeting") == (3723.004, 3725.5, "Long meeting")
        assert parse_segment_line("Detected language: English") is None
        assert parse_segment_line("") is None

    def test_writer_reports_segments_and_progress_across_chunks(self):
        from ownscribe.transcription.mlx_transcriber import SegmentLineWriter

        segments, fractions = [], []
        writer = SegmentLineWriter(lambda s, e, t: segments.append((s, e, t)), 10.0, fractions.append)
        for chunk in ["Detected language: English\n[00:00.000 --> 00:0", "4.000] First part\n[00:04.000 --> ",
                      "00:04.000] \n[00:04.000 --> 00:08.000] Second part"]:
            writer.write(chunk)
        writer.flush()

        assert segments == [(0.0, 4.0, "First part"), (4.0, 8.0, "Second part")]  # empty segment dropped
        assert fractions == [0.4, 0.4, 0.8]


# ----------------------------------------------------------------- events


class TestEventSink:
    def test_events_survive_stdout_redirects_and_fd_replacement(self):
        """The transcriber redirects stdout and the summarizer dup2's fds; events must still arrive."""
        r, w = os.pipe()
        sink = EventSink(w)
        devnull = os.open(os.devnull, os.O_WRONLY)
        os.dup2(devnull, w)  # what llama_cpp_summarizer does to fd 2
        os.close(devnull)
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            print("library noise")
            sink.emit("stage", stage="transcribing", status="running", fraction=float("nan"))
        sink.close()
        os.close(w)
        with os.fdopen(r) as f:
            events = [json.loads(line) for line in f]
        assert events[0]["ev"] == "stage" and events[0]["fraction"] is None  # NaN becomes null

    def test_closed_reader_turns_the_sink_off(self):
        r, w = os.pipe()
        sink = EventSink(w)
        os.close(w)
        os.close(r)
        sink.emit("job", status="started")  # EPIPE: no exception
        assert not sink.enabled


class TestEventProgress:
    def test_reports_stage_changes_with_parents(self):
        from ownscribe.progress import EventProgress

        pipe = EventPipe()
        with EventProgress(pipe.sink, diarize=True) as progress:
            progress.begin("transcribing")
            progress.update("transcribing", 0.5)
            progress._render_all()
            progress.complete("transcribing")
            progress.begin("diarizing")
            progress.diarization_hook("segmentation", None, completed=1, total=2)
            progress._render_all()
            progress.diarization_hook("embeddings", None)
            progress.fail("diarizing")
        events = pipe.events()
        compact = [(e["stage"], e["status"], e.get("parent"), e.get("fraction")) for e in events]

        assert ("transcribing", "running", None, 0.5) in compact
        assert ("transcribing", "done", None, None) in compact
        assert ("segmentation", "running", "diarizing", 0.5) in compact
        assert ("diarizing", "failed", None, None) in compact
        assert all(e["ev"] == "stage" for e in events)


# ----------------------------------------------------------------- sessions


class TestSessions:
    def test_new_session_never_reuses_a_folder(self, tmp_path):
        with mock.patch("ownscribe.session.datetime") as dt:
            dt.now.return_value.strftime.return_value = "2026-11-03_182804"
            dt.now.return_value.astimezone.return_value.isoformat.return_value = "2026-11-03T18:28:04-08:00"
            first = sessions.new_session(tmp_path)
            second = sessions.new_session(tmp_path)
        assert first.name == "2026-11-03_182804"
        assert second.name == "2026-11-03_182804-2"
        assert sessions.load(second)["stages"]["transcription"]["status"] == "pending"

    def test_list_includes_cli_recordings_and_skips_other_folders(self, tmp_path):
        gui = sessions.new_session(tmp_path)
        cli_dir = tmp_path / "2026-08-24_1130"
        cli_dir.mkdir()
        (cli_dir / "transcript.md").write_text("# Transcript")
        (tmp_path / "notes").mkdir()

        listed = {s["id"]: s for s in sessions.list_sessions(tmp_path)}

        assert set(listed) == {gui.name, "2026-08-24_1130"}
        assert listed["2026-08-24_1130"]["has_transcript"]


class TestCliOutputDir:
    def test_same_minute_recordings_get_their_own_folder(self, tmp_path):
        from ownscribe.pipeline import _get_output_dir

        config = Config()
        config.output.dir = str(tmp_path)
        first = _get_output_dir(config)
        (first / "recording.wav").write_bytes(b"x")
        second = _get_output_dir(config)

        assert second != first
        assert second.name == f"{first.name}-2"


# ----------------------------------------------------------------- process


class TestProcess:
    def test_full_run_streams_events_writes_files_and_renames(self, config, session_dir):
        pipe = EventPipe()
        with fakes() as summarizer:
            result = jobs.process(config, session_dir, sink=pipe.sink, template="brief")
        events = pipe.events()
        kinds = [e["ev"] for e in events]
        moved = Path(result["session"])

        assert kinds.count("segment") == 3
        assert {"transcript", "speakers", "summary", "session_moved"} <= set(kinds)
        assert kinds.index("segment") < kinds.index("transcript") < kinds.index("summary")
        assert summarizer.calls[0][1] == "brief"
        assert moved.name == f"{session_dir.name}_friday-ship-plan" and not session_dir.exists()
        for name in ("transcript.json", "transcript.md", "summary.raw.md", "summary.md", "session.json"):
            assert (moved / name).exists(), name
        state = json.loads((moved / "session.json").read_text())
        assert state["id"] == session_dir.name  # stable id across the rename
        assert state["title"] == "Friday ship plan"
        assert {k: v["status"] for k, v in state["stages"].items()} == {
            "transcription": "done", "diarization": "done", "summarization": "done", "vault": "pending"}
        assert state["speakers"]["labels"] == ["SPEAKER_00", "SPEAKER_01"]
        assert result["exit_code"] == 0

    def test_without_diarization_or_summary(self, config, session_dir):
        with fakes():
            result = jobs.process(config, session_dir, diarize=False, summarize=False)
        state = sessions.load(session_dir)

        assert result["session"] == str(session_dir)  # no title, no rename
        assert state["stages"]["diarization"]["status"] == "skipped"
        assert state["stages"]["summarization"]["status"] == "skipped"
        assert "SPEAKER" not in (session_dir / "transcript.md").read_text()

    def test_summarizer_failure_keeps_the_transcript_and_exits_partial(self, config, session_dir):
        broken = FakeSummarizer()
        broken.summarize = mock.Mock(side_effect=RuntimeError("model crashed"))
        pipe = EventPipe()
        with fakes(broken):
            result = jobs.process(config, session_dir, sink=pipe.sink)
        errors = [e for e in pipe.events() if e["ev"] == "error"]

        assert result["exit_code"] == 2
        assert (session_dir / "transcript.md").exists()
        assert errors[0]["code"] == "summarization_failed"
        assert sessions.load(session_dir)["stages"]["summarization"]["status"] == "failed"

    @pytest.mark.parametrize(("make_audio", "code"), [(None, "audio_missing"), ("silent", "audio_silent")])
    def test_bad_audio_is_a_coded_error(self, config, tmp_path, make_audio, code):
        path = sessions.new_session(tmp_path)
        if make_audio:
            _wav(path / "recording.wav", silent=True)
        with fakes(), pytest.raises(jobs.JobError) as err:
            jobs.process(config, path)
        assert err.value.code == code

    def test_missing_ffmpeg_is_reported_by_code(self, config, session_dir):
        with fakes(), mock.patch("ownscribe.jobs.shutil.which", return_value=None), pytest.raises(jobs.JobError) as err:
            jobs.process(config, session_dir)
        assert err.value.code == "ffmpeg_missing"


# ----------------------------------------------------------------- speakers, resummarize, vault


class TestSpeakersAndSummary:
    def _processed(self, config, session_dir):
        with fakes():
            return Path(jobs.process(config, session_dir, summarize=True)["session"])

    def test_rename_rerenders_transcript_and_summary(self, config, session_dir):
        path = self._processed(config, session_dir)
        pipe = EventPipe()
        jobs.set_speaker_names(config, path, {"SPEAKER_00": "Alice"}, sink=pipe.sink)
        summary_events = [e for e in pipe.events() if e["ev"] == "summary"]

        assert "Alice" in (path / "transcript.md").read_text()
        assert "SPEAKER_00" in json.loads((path / "transcript.json").read_text())["segments"][0]["speaker"]
        assert "Alice proposed" in (path / "summary.md").read_text()
        assert "SPEAKER_01 writes" in (path / "summary.md").read_text()  # unnamed labels stay
        assert summary_events[0]["text"].startswith("Alice proposed")
        assert sessions.load(path)["speakers"]["names"] == {"SPEAKER_00": "Alice"}

    def test_unknown_label_is_rejected(self, config, session_dir):
        path = self._processed(config, session_dir)
        with pytest.raises(jobs.JobError) as err:
            jobs.set_speaker_names(config, path, {"SPEAKER_09": "Nobody"})
        assert err.value.code == "unknown_speaker"

    def test_resummarize_with_names_sends_the_named_transcript(self, config, session_dir):
        path = self._processed(config, session_dir)
        summarizer = FakeSummarizer()
        with fakes(summarizer):
            jobs.set_speaker_names(config, path, {"SPEAKER_01": "Bob"}, resummarize=True)
        assert "Bob" in summarizer.calls[-1][0]

    def test_resummarize_uses_the_requested_template(self, config, session_dir):
        path = self._processed(config, session_dir)
        summarizer = FakeSummarizer()
        with fakes(summarizer):
            jobs.resummarize(config, path, "lecture")
        assert summarizer.calls[-1][1] == "lecture"
        assert sessions.load(path)["summary"]["template"] == "lecture"

    def test_vault_preview_then_write_with_edits(self, config, session_dir, tmp_path):
        from ownscribe.vault_filing import FiledNote, PreparedNote

        path = self._processed(config, session_dir)
        prepared = PreparedNote(parsed={"title": "Ship plan", "category": "Research", "tags": ["x"],
                                        "body_markdown": "Body"}, folder_name=path.name, date="2026-11-03")
        note = FiledNote(path=tmp_path / "vault" / "note.md", needs_review=False)
        with mock.patch("ownscribe.vault_filing.prepare_note", return_value=prepared) as prep, \
             mock.patch("ownscribe.vault_filing.write_note", return_value=note) as write:
            preview = jobs.vault_preview(config, path)
            filed = jobs.vault_write(config, path, edits={"title": "Edited title"})

        assert prep.call_args[0][2] == path  # the note links to the folder's final, renamed path
        assert preview["title"] == "Ship plan"
        assert write.call_args[0][0]["title"] == "Edited title"
        assert filed == {"path": str(note.path), "needs_review": False}
        assert sessions.load(path)["stages"]["vault"]["status"] == "done"

    def test_write_without_preview_is_refused(self, config, session_dir):
        path = self._processed(config, session_dir)
        with pytest.raises(jobs.JobError) as err:
            jobs.vault_write(config, path)
        assert err.value.code == "no_preview"


class TestSummarizerTemplate:
    def test_template_argument_overrides_config(self):
        from ownscribe.summarization.base import Summarizer
        from ownscribe.summarization.prompts import resolve_template

        seen = []

        class Recorder(Summarizer):
            def _complete(self, system_prompt, user_prompt):
                seen.append(system_prompt)
                return "ok"

            def generate_title(self, summary_text):
                return "t"

            def chat(self, system_prompt, user_prompt, json_mode=False, json_schema=None):
                return ""

            def is_available(self):
                return True

        config = Config()
        config.summarization.template = "meeting"
        Recorder(config.summarization).summarize("SPEAKER_00: hello", template="brief")
        assert seen[0] == resolve_template("brief")[0]


class TestLabels:
    def test_render_labels_only_touches_named_labels(self):
        text = "SPEAKER_00 and SPEAKER_01 met; NOTSPEAKER_00 stays."
        assert jobs.render_labels(text, {"SPEAKER_00": "Alice"}) == "Alice and SPEAKER_01 met; NOTSPEAKER_00 stays."


# ----------------------------------------------------------------- CLI


class TestJobCli:
    def test_failed_job_prints_coded_json_and_exits_1(self, tmp_path):
        from click.testing import CliRunner

        from ownscribe.cli import cli

        path = sessions.new_session(tmp_path)
        runner = CliRunner()
        result = runner.invoke(cli, ["process", str(path), "--json"])

        assert result.exit_code == 1
        assert '"code": "audio_missing"' in result.output

    def test_session_new_prints_its_path(self, tmp_path):
        from click.testing import CliRunner

        from ownscribe.cli import cli

        result = CliRunner().invoke(cli, ["session", "new", "--output-dir", str(tmp_path), "--json"])

        assert result.exit_code == 0
        created = Path(json.loads(result.output)["path"])
        assert (created / "session.json").exists()
