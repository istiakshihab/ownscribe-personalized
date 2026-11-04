"""Non-interactive jobs a GUI runs as separate processes (docs/engine-protocol.md, section 3).

Each job works on one session folder, reports progress as JSON events through an EventSink and
raises JobError with a stable code on failure. The interactive CLI pipeline is untouched.
"""

from __future__ import annotations

import copy
import json
import os
import re
import shutil
from pathlib import Path
from typing import Any

from ownscribe import session as sessions
from ownscribe.config import Config
from ownscribe.events import EventSink, NullSink
from ownscribe.summarization import create_summarizer
from ownscribe.transcription.models import TranscriptResult

_LABEL_RE = re.compile(r"\bSPEAKER_\d{2}\b")


class JobError(Exception):
    """A job failed; ``code`` is one of the error codes in docs/engine-protocol.md."""

    def __init__(self, code: str, message: str, stage: str | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.stage = stage


# ----------------------------------------------------------------- environment


def prepare_environment(config: Config) -> None:
    """A GUI-launched process gets launchd's minimal PATH: add Homebrew's and any configured bins."""
    extra = ["/opt/homebrew/bin", "/usr/local/bin"]
    for configured in (config.paths.ffmpeg, config.paths.claude):
        if configured:
            extra.insert(0, str(Path(configured).expanduser().parent))
    current = os.environ.get("PATH", "").split(os.pathsep)
    os.environ["PATH"] = os.pathsep.join(dict.fromkeys([*extra, *current]))
    if config.paths.claude and not config.obsidian.claude_bin:
        config.obsidian.claude_bin = config.paths.claude


# ----------------------------------------------------------------- rendering helpers


def _names(state: dict[str, Any]) -> dict[str, str]:
    return {k: v for k, v in state["speakers"].get("names", {}).items() if v}


def render_labels(text: str, names: dict[str, str]) -> str:
    """Replace SPEAKER_XX labels with assigned names, leaving unnamed labels alone."""
    return _LABEL_RE.sub(lambda m: names.get(m.group(0), m.group(0)), text)


def _named(result: TranscriptResult, names: dict[str, str]) -> TranscriptResult:
    from ownscribe.speaker_naming import apply_speaker_names

    named = copy.deepcopy(result)
    if names:
        apply_speaker_names(named, names)
    return named


def _load_transcript(path: Path) -> TranscriptResult:
    from ownscribe.output.json_output import parse_transcript_json

    try:
        result = parse_transcript_json((path / "transcript.json").read_text())
    except FileNotFoundError:
        result = None
    if result is None:
        raise JobError("transcript_missing", f"No transcript.json in {path}; run `ownscribe process` first")
    return result


def _write_transcript(path: Path, result: TranscriptResult, names: dict[str, str]) -> Path:
    from ownscribe.output.json_output import format_transcript_json
    from ownscribe.output.markdown import format_transcript

    (path / "transcript.json").write_text(format_transcript_json(result))  # labels: source of truth
    out = path / "transcript.md"
    out.write_text(format_transcript(_named(result, names)))
    return out


def _transcript_event(sink: EventSink, path: Path, result: TranscriptResult, names: dict[str, str]) -> None:
    labels = _distinct_labels(result)
    sink.emit(
        "transcript",
        path=str(path / "transcript.md"),
        speakers=labels,
        segments=[
            {
                "start": round(s.start, 3),
                "end": round(s.end, 3),
                "text": s.text,
                **({"speaker": s.speaker, "name": names.get(s.speaker, s.speaker)} if s.speaker else {}),
            }
            for s in result.segments
        ],
    )


def _distinct_labels(result: TranscriptResult) -> list[str]:
    seen: list[str] = []
    for s in result.segments:
        if s.speaker and s.speaker not in seen:
            seen.append(s.speaker)
    return seen


def _write_summary(path: Path, raw: str, names: dict[str, str]) -> Path:
    from ownscribe.output.markdown import format_summary

    (path / "summary.raw.md").write_text(raw)
    out = path / "summary.md"
    out.write_text(format_summary(render_labels(raw, names)))
    return out


def audio_is_silent(audio_path: Path) -> bool:
    """True if the whole file is digital silence (stops at the first audible block)."""
    import numpy as np
    import soundfile as sf

    with sf.SoundFile(str(audio_path)) as f:
        block = max(1, f.samplerate * 10)
        while len(data := f.read(block, dtype="float32")):
            if float(np.max(np.abs(data))) >= 1e-6:
                return False
    return True


# ----------------------------------------------------------------- process


def process(
    config: Config,
    path: Path,
    *,
    sink: EventSink | None = None,
    template: str | None = None,
    diarize: bool | None = None,
    summarize: bool | None = None,
    language: str | None = None,
    min_speakers: int | None = None,
    max_speakers: int | None = None,
) -> dict[str, Any]:
    """Transcription → diarization → summarization for one session. Returns the result summary."""
    from ownscribe.pipeline import _download_summarization_model, _rename_output_dir, _slugify
    from ownscribe.progress import EventProgress
    from ownscribe.transcription.mlx_transcriber import MLXWhisperTranscriber

    sink = sink or NullSink()
    state = sessions.load(path)
    audio = path / "recording.wav"
    if not audio.exists():
        raise JobError("audio_missing", f"No recording.wav in {path}", "transcription")
    if audio_is_silent(audio):
        raise JobError("audio_silent", "The recording is digital silence from start to end", "transcription")

    if language is not None:
        config.transcription.language = language
    if diarize is not None:
        config.diarization.enabled = diarize
    if min_speakers is not None:
        config.diarization.min_speakers = min_speakers
    if max_speakers is not None:
        config.diarization.max_speakers = max_speakers
    do_diarize = config.diarization.enabled and bool(config.diarization.hf_token)
    if config.diarization.enabled and not config.diarization.hf_token:
        sink.emit(
            "error",
            stage="diarization",
            code="hf_token_missing",
            message="Diarization needs a Hugging Face token ([diarization] hf_token)",
        )
    do_summarize = config.summarization.enabled if summarize is None else summarize
    template = template or config.summarization.template or "meeting"
    local_sum = do_summarize and config.summarization.backend == "local"
    state["options"] = {
        "template": template,
        "diarize": do_diarize,
        "summarize": do_summarize,
        "language": config.transcription.language or None,
    }

    # ---- transcription (+ diarization inside the transcriber)
    sessions.set_stage(path, state, "transcription", "running")
    if do_diarize:
        sessions.set_stage(path, state, "diarization", "running")
    progress = EventProgress(sink, diarize=do_diarize, summarize=False)
    diar_config = config.diarization if do_diarize else None
    with progress:
        if shutil.which("ffmpeg") is None:
            raise JobError("ffmpeg_missing", "ffmpeg is not on PATH; install it or set [paths] ffmpeg", "transcription")
        transcriber = MLXWhisperTranscriber(
            config.transcription,
            diar_config,
            progress=progress,
            need_word_timestamps=False,
            on_segment=lambda start, end, text: sink.emit(
                "segment", start=round(start, 3), end=round(end, 3), text=text
            ),
        )
        try:
            result = transcriber.transcribe(audio)
        except JobError:
            raise
        except Exception as exc:
            sessions.set_stage(
                path, state, "transcription", "failed", error={"code": "transcription_failed", "message": str(exc)}
            )
            raise JobError("transcription_failed", str(exc), "transcription") from exc

    labels = _distinct_labels(result)
    state["speakers"] = {"labels": labels, "names": {}, "roles": {}}
    names: dict[str, str] = {}
    _write_transcript(path, result, names)
    sessions.set_stage(path, state, "transcription", "done", segments=len(result.segments))
    if do_diarize:
        sessions.set_stage(path, state, "diarization", "done", speakers=len(labels))
        sink.emit("speakers", labels=labels, names={}, roles={})
    else:
        sessions.set_stage(path, state, "diarization", "skipped")
    _transcript_event(sink, path, result, names)

    # ---- summarization
    exit_code = 0
    if do_summarize:
        exit_code = _summarize(
            config,
            path,
            state,
            result,
            template,
            sink,
            progress_cls=EventProgress,
            download=_download_summarization_model if local_sum else None,
        )
        slug = _slugify(state.get("title") or "")
        if slug:
            new_path = _rename_output_dir(path, slug)
            if new_path != path:
                sink.emit("session_moved", **{"from": str(path), "to": str(new_path)})
                path = new_path
    else:
        sessions.set_stage(path, state, "summarization", "skipped")

    return {
        "session": str(path),
        "status": "ok" if exit_code == 0 else "partial",
        "exit_code": exit_code,
        "title": state.get("title"),
        "speakers": labels,
    }


def _summarize(
    config: Config,
    path: Path,
    state: dict[str, Any],
    result: TranscriptResult,
    template: str,
    sink: EventSink,
    *,
    progress_cls=None,
    download=None,
    names: dict[str, str] | None = None,
) -> int:
    """Run summarization, write summary files and record the title. Returns 0, or 2 if it failed."""
    from ownscribe.progress import EventProgress

    names = names or {}
    sessions.set_stage(path, state, "summarization", "running", template=template)
    progress = (progress_cls or EventProgress)(
        sink, transcribe=False, summarize=True, download_summarizer=download is not None
    )
    try:
        summarizer = create_summarizer(config)
    except ImportError as exc:
        return _fail_summary(path, state, sink, "summarizer_unavailable", str(exc))
    try:
        with progress:
            progress.begin("summarizing")
            if download is not None:
                progress.begin("downloading_model")
                download(config.summarization.model, progress, "downloading_model")
                progress.complete("downloading_model")
            if not summarizer.is_available():
                progress.fail("summarizing")
                return _fail_summary(
                    path,
                    state,
                    sink,
                    "summarizer_unavailable",
                    f"The {config.summarization.backend} summarizer is not available",
                )
            text = _named(result, names).speaker_text
            raw = summarizer.summarize(text, template=template)
            try:
                title = summarizer.generate_title(raw).strip().strip('"')
            except Exception:
                title = None
            progress.complete("summarizing")
    except Exception as exc:
        return _fail_summary(path, state, sink, "summarization_failed", str(exc))
    finally:
        summarizer.close()

    out = _write_summary(path, raw, _names(state))
    state["summary"] = {"template": template, "raw_file": "summary.raw.md", "with_names": bool(names)}
    if title:
        state["title"] = title
    sessions.set_stage(path, state, "summarization", "done", template=template)
    sink.emit("summary", template=template, title=title, text=render_labels(raw, _names(state)), path=str(out))
    return 0


def _fail_summary(path: Path, state: dict[str, Any], sink: EventSink, code: str, message: str) -> int:
    sessions.set_stage(path, state, "summarization", "failed", error={"code": code, "message": message})
    sink.emit("error", stage="summarization", code=code, message=message)
    return 2


# ----------------------------------------------------------------- speakers, resummarize


def set_speaker_names(
    config: Config, path: Path, names: dict[str, str], *, sink: EventSink | None = None, resummarize: bool = False
) -> dict[str, Any]:
    """Store names for SPEAKER_XX labels and re-render transcript.md and summary.md with them.

    Renaming substitutes labels in the stored summary; ``resummarize`` instead runs the summarizer
    again on the named transcript, which reads better than substituted text.
    """
    sink = sink or NullSink()
    state = sessions.load(path)
    result = _load_transcript(path)
    labels = _distinct_labels(result)
    unknown = [label for label in names if label not in labels]
    if unknown:
        raise JobError("unknown_speaker", f"No such speaker label: {', '.join(unknown)}")
    merged = {**state["speakers"].get("names", {}), **names}
    merged = {k: v.strip() for k, v in merged.items() if v and v.strip()}
    state["speakers"] = {**state["speakers"], "labels": labels, "names": merged}
    sessions.save(path, state)
    _write_transcript(path, result, merged)
    _transcript_event(sink, path, result, merged)
    sink.emit("speakers", labels=labels, names=merged, roles=state["speakers"].get("roles", {}))

    exit_code = 0
    if resummarize:
        template = (state.get("summary") or {}).get("template") or config.summarization.template or "meeting"
        exit_code = _summarize(config, path, state, result, template, sink, names=merged)
    elif (path / "summary.raw.md").exists():
        raw = (path / "summary.raw.md").read_text()
        out = _write_summary(path, raw, merged)
        sink.emit(
            "summary",
            template=(state.get("summary") or {}).get("template"),
            title=state.get("title"),
            text=render_labels(raw, merged),
            path=str(out),
        )
    return {"session": str(path), "names": merged, "exit_code": exit_code}


def suggest_roles(config: Config, path: Path, *, sink: EventSink | None = None) -> dict[str, str]:
    """Ask Claude what each speaker's role seems to be (suggestions for naming)."""
    from ownscribe.speaker_naming import get_speaker_roles

    sink = sink or NullSink()
    state = sessions.load(path)
    result = _load_transcript(path)
    try:
        roles = get_speaker_roles(config, result)
    except Exception as exc:
        raise JobError("claude_unavailable", str(exc)) from exc
    state["speakers"] = {**state["speakers"], "roles": roles}
    sessions.save(path, state)
    sink.emit("speakers", labels=_distinct_labels(result), names=_names(state), roles=roles)
    return roles


def resummarize(config: Config, path: Path, template: str, *, sink: EventSink | None = None) -> dict[str, Any]:
    from ownscribe.pipeline import _download_summarization_model

    sink = sink or NullSink()
    state = sessions.load(path)
    result = _load_transcript(path)
    download = _download_summarization_model if config.summarization.backend == "local" else None
    exit_code = _summarize(
        config,
        path,
        state,
        result,
        template,
        sink,
        download=download,
        names=_names(state) if (state.get("summary") or {}).get("with_names") else None,
    )
    if exit_code:
        raise JobError(
            state["stages"]["summarization"].get("error", {}).get("code", "summarization_failed"),
            state["stages"]["summarization"].get("error", {}).get("message", "Summarization failed"),
            "summarization",
        )
    return {"session": str(path), "template": template, "title": state.get("title")}


# ----------------------------------------------------------------- vault


def vault_preview(config: Config, path: Path, *, sink: EventSink | None = None) -> dict[str, Any]:
    from ownscribe.vault_filing import prepare_note

    sink = sink or NullSink()
    state = sessions.load(path)
    names = _names(state)
    result = _named(_load_transcript(path), names)
    sessions.set_stage(path, state, "vault", "running")
    try:
        prepared = prepare_note(config, result, path, speakers_named=bool(names))
    except Exception as exc:
        sessions.set_stage(path, state, "vault", "failed", error={"code": "vault_failed", "message": str(exc)})
        raise JobError("vault_failed", str(exc), "vault") from exc
    preview = {**prepared.parsed, "folder": prepared.folder_name, "date": prepared.date}
    state["vault_preview"] = preview
    sessions.set_stage(path, state, "vault", "pending", previewed=True)
    sink.emit("vault_preview", **{k: preview.get(k) for k in ("title", "category", "tags", "body_markdown")})
    return preview


def vault_write(
    config: Config, path: Path, *, edits: dict[str, Any] | None = None, sink: EventSink | None = None
) -> dict[str, Any]:
    from ownscribe.vault_filing import write_note

    sink = sink or NullSink()
    state = sessions.load(path)
    preview = state.get("vault_preview")
    if not preview:
        raise JobError("no_preview", "Run `ownscribe file SESSION --preview` first", "vault")
    parsed = {**preview, **(edits or {})}
    try:
        note = write_note(parsed, preview["folder"], preview["date"], config.obsidian.resolved_vault_dir)
    except Exception as exc:
        sessions.set_stage(path, state, "vault", "failed", error={"code": "vault_failed", "message": str(exc)})
        raise JobError("vault_failed", str(exc), "vault") from exc
    state["vault_note"] = {"path": str(note.path), "needs_review": note.needs_review}
    sessions.set_stage(path, state, "vault", "done")
    sink.emit("vault_note", path=str(note.path), needs_review=note.needs_review)
    return state["vault_note"]


# ----------------------------------------------------------------- listings, doctor


def list_templates(config: Config) -> list[dict[str, str]]:
    from ownscribe.summarization.prompts import list_templates as builtin

    names = builtin()
    custom = [name for name in config.templates if name not in names]
    return [{"name": n, "kind": "built-in"} for n in names] + [{"name": n, "kind": "custom"} for n in custom]


def doctor(config: Config) -> dict[str, Any]:
    """What a GUI needs to know before it starts: missing tools, tokens, models, disk space."""
    from ownscribe.audio.coreaudio import _find_binary
    from ownscribe.claude_cli import resolve_claude_bin

    checks: dict[str, Any] = {}
    ffmpeg = shutil.which("ffmpeg")
    checks["ffmpeg"] = {"ok": ffmpeg is not None, "path": ffmpeg}
    token = bool(config.diarization.hf_token)
    checks["hf_token"] = {
        "ok": token or not config.diarization.enabled,
        "set": token,
        "needed": config.diarization.enabled,
    }
    try:
        claude = resolve_claude_bin(config.obsidian.claude_bin)
        checks["claude"] = {"ok": True, "path": claude}
    except Exception as exc:
        checks["claude"] = {"ok": not config.obsidian.enabled, "path": None, "message": str(exc)}
    helper = _find_binary()
    checks["capture_helper"] = {
        "ok": helper is not None,
        "path": str(helper) if helper else None,
        "session_mode": _helper_has_sessions(helper),
    }
    out = config.output.resolved_dir
    probe = out if out.exists() else Path.home()
    free = shutil.disk_usage(probe).free
    checks["disk"] = {"ok": free > 2 * 1024**3, "free_bytes": free, "path": str(out)}
    # Advisory: a missing model is downloaded on first use (or with `ownscribe warmup`).
    checks["whisper_model"] = {
        "ok": True,
        "cached": _whisper_cached(config.transcription.model),
        "model": config.transcription.model,
        "required": False,
    }
    return {"ok": all(c["ok"] for c in checks.values()), "checks": checks}


def _helper_has_sessions(helper: Path | None) -> bool:
    if helper is None:
        return False
    from ownscribe.audio.coreaudio import _helper_supports

    return _helper_supports(str(helper), "--session")


def _whisper_cached(model: str) -> bool:
    from ownscribe.transcription.mlx_transcriber import _MLX_MODEL_REPOS

    repo = _MLX_MODEL_REPOS.get(model, model)
    hub = Path(
        os.environ.get("HF_HUB_CACHE") or Path(os.environ.get("HF_HOME", "~/.cache/huggingface")).expanduser() / "hub"
    )
    return (hub / f"models--{repo.replace('/', '--')}").exists()


def dumps(obj: Any) -> str:
    return json.dumps(obj, indent=2, ensure_ascii=False)
