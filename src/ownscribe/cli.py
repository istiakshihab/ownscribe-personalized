"""CLI entry point for ownscribe."""

from __future__ import annotations

import os
import shutil
import subprocess

import click

from ownscribe.config import CONFIG_DIR, Config, ensure_config_file

# Canonical paths for cleanup
_CACHE_DIR = os.path.expanduser("~/.local/share/ownscribe")
_CONFIG_DIR = str(CONFIG_DIR)


def _dir_size(path: str) -> str:
    """Human-readable size of a directory tree, or '(not found)' if missing."""
    from pathlib import Path

    p = Path(path)
    if not p.exists():
        return "(not found)"
    total = sum(f.stat().st_size for f in p.rglob("*") if f.is_file())
    for unit in ("B", "KB", "MB", "GB"):
        if total < 1024:
            return f"{total:.1f} {unit}"
        total /= 1024
    return f"{total:.1f} TB"


@click.group(invoke_without_command=True)
@click.option("--device", default=None, help="Audio input device name or index.")
@click.option("--no-summarize", is_flag=True, help="Skip LLM summarization.")
@click.option("--diarize", is_flag=True, help="Enable speaker diarization (needs HF token).")
@click.option("--format", "output_format", type=click.Choice(["markdown", "json"]), default=None, help="Output format.")
@click.option("--model", default=None, help="Whisper model size (tiny, base, small, medium, large-v3).")
@click.option("--language", default=None, help="Language code for transcription (e.g. en, de, fr).")
@click.option("--initial-prompt", default=None, help="Context text to prime Whisper (vocab, speaker names, etc.)")
@click.option("--hotwords", default=None, help="Comma-separated words to boost Whisper recognition.")
@click.option(
    "--mic/--no-mic",
    default=None,
    help="Also capture microphone input (mixed with system audio); on by default.",
)
@click.option("--mic-device", default=None, help="Specific mic device name (implies --mic).")
@click.option(
    "--keep-recording/--no-keep-recording",
    default=None,
    help="Keep or delete WAV recordings after transcription.",
)
@click.option("--template", default=None, help="Summarization template (meeting, lecture, brief, or custom).")
@click.option(
    "--silence-timeout", default=None, type=click.IntRange(min=0),
    help="Seconds of silence before auto-stopping recording (0 to disable).",
)
@click.pass_context
def cli(
    ctx: click.Context,
    device: str | None,
    no_summarize: bool,
    diarize: bool,
    output_format: str | None,
    model: str | None,
    language: str | None,
    initial_prompt: str | None,
    hotwords: str | None,
    mic: bool | None,
    mic_device: str | None,
    keep_recording: bool | None,
    template: str | None,
    silence_timeout: int | None,
) -> None:
    """Fully local meeting transcription and summarization.

    Run without a subcommand to record, transcribe, and summarize a meeting.
    """
    ctx.ensure_object(dict)
    config = Config.load()

    # Apply CLI overrides
    if device is not None:
        config.audio.device = device
        if config.audio.backend == "coreaudio" and device:
            config.audio.backend = "sounddevice"
    if no_summarize:
        config.summarization.enabled = False
    if diarize:
        config.diarization.enabled = True
    if output_format:
        config.output.format = output_format
    if model:
        config.transcription.model = model
    if language:
        config.transcription.language = language
    if initial_prompt:
        config.transcription.initial_prompt = initial_prompt
    if hotwords:
        config.transcription.hotwords = hotwords
    if mic is False and mic_device:
        raise click.UsageError("--no-mic and --mic-device cannot be used together.")
    if mic is not None:
        config.audio.mic = mic
    if mic_device:
        config.audio.mic = True
        config.audio.mic_device = mic_device
    if keep_recording is not None:
        config.output.keep_recording = keep_recording
    if template:
        config.summarization.template = template
    if silence_timeout is not None:
        config.audio.silence_timeout = silence_timeout

    ctx.obj["config"] = config

    if ctx.invoked_subcommand is None:
        from ownscribe.pipeline import run_pipeline
        run_pipeline(config)


@cli.command()
@click.argument("question")
@click.option("--since", default=None, help="Only search meetings after this date (YYYY-MM-DD).")
@click.option("--limit", default=None, type=int, help="Max number of recent meetings to search.")
@click.pass_context
def ask(ctx: click.Context, question: str, since: str | None, limit: int | None) -> None:
    """Ask a question across your meeting notes."""
    config = ctx.obj["config"]
    from ownscribe.search import ask as run_ask

    run_ask(config, question, since=since, limit=limit)


@cli.command()
def devices() -> None:
    """List available audio input devices."""
    from ownscribe.audio.coreaudio import CoreAudioRecorder
    recorder = CoreAudioRecorder()
    if recorder.is_available():
        click.echo(recorder.list_devices())
    else:
        import sounddevice as sd
        click.echo("Available audio devices:\n")
        click.echo(sd.query_devices())


@cli.command()
@click.argument("file", type=click.Path(exists=True))
@click.option("--diarize", is_flag=True, help="Enable speaker diarization.")
@click.option("--model", default=None, help="Whisper model size.")
@click.option("--language", default=None, help="Language code for transcription (e.g. en, de, fr).")
@click.option("--format", "output_format", type=click.Choice(["markdown", "json"]), default=None)
@click.pass_context
def transcribe(
    ctx: click.Context, file: str, diarize: bool,
    model: str | None, language: str | None, output_format: str | None,
) -> None:
    """Transcribe an audio file."""
    config = ctx.obj["config"]
    if diarize:
        config.diarization.enabled = True
    if model:
        config.transcription.model = model
    if language:
        config.transcription.language = language
    if output_format:
        config.output.format = output_format

    from ownscribe.pipeline import run_transcribe
    run_transcribe(config, file)


@cli.command()
@click.option("--model", default=None, help="Whisper model size.")
@click.option("--language", default=None, help="Language code to prefetch alignment model for (e.g. en, de, fr).")
@click.option(
    "--with-diarization/--no-diarization",
    "with_diarization",
    default=None,
    help="Override diarization warmup (defaults to config setting).",
)
@click.option("--events-fd", type=int, default=None, help="Write JSON progress events to this file descriptor.")
@click.pass_context
def warmup(
    ctx: click.Context,
    model: str | None,
    language: str | None,
    with_diarization: bool | None,
    events_fd: int | None,
) -> None:
    """Prefetch MLX Whisper/pyannote models to avoid first-run stalls."""
    config = ctx.obj["config"]
    if model:
        config.transcription.model = model
    if language:
        config.transcription.language = language
    if with_diarization is not None:
        config.diarization.enabled = with_diarization

    from ownscribe.pipeline import run_warmup

    factory = None
    if events_fd is not None:
        from ownscribe.events import EventSink
        from ownscribe.progress import EventProgress

        sink = EventSink(events_fd)

        def factory(**kwargs):
            return EventProgress(sink, **kwargs)

    run_warmup(config, progress_factory=factory)


@cli.command()
@click.argument("file", type=click.Path(exists=True))
@click.option("--template", default=None, help="Summarization template (meeting, lecture, brief, or custom).")
@click.pass_context
def summarize(ctx: click.Context, file: str, template: str | None) -> None:
    """Summarize a transcript file."""
    config = ctx.obj["config"]
    if template:
        config.summarization.template = template

    from ownscribe.pipeline import run_summarize
    run_summarize(config, file)


@cli.command()
@click.argument("directory", type=click.Path(exists=True, file_okay=False))
@click.option("--model", default=None, help="Whisper model size (tiny, base, small, medium, large-v3).")
@click.option("--language", default=None, help="Language code for transcription (e.g. en, de, fr).")
@click.option("--template", default=None, help="Summarization template (meeting, lecture, brief, or custom).")
@click.pass_context
def resume(
    ctx: click.Context, directory: str,
    model: str | None, language: str | None, template: str | None,
) -> None:
    """Resume a partially-completed pipeline in a meeting directory."""
    config = ctx.obj["config"]
    if model:
        config.transcription.model = model
    if language:
        config.transcription.language = language
    if template:
        config.summarization.template = template

    from ownscribe.pipeline import run_resume
    run_resume(config, directory)


@cli.command()
def apps() -> None:
    """List running apps with PIDs."""
    from ownscribe.audio.coreaudio import CoreAudioRecorder
    recorder = CoreAudioRecorder()
    click.echo(recorder.list_apps())


@cli.command("config")
def config_cmd() -> None:
    """Open the configuration file in your editor."""
    path = ensure_config_file()
    editor = os.environ.get("EDITOR", "nano")
    click.echo(f"Opening {path} with {editor}...")
    subprocess.run([editor, str(path)])


@cli.command()
@click.option("--yes", "-y", is_flag=True, help="Skip confirmation prompts.")
@click.option("--all", "all_", is_flag=True, help="Remove everything (config + cache + output).")
@click.option("--config", "config_", is_flag=True, help="Remove config directory (~/.config/ownscribe/).")
@click.option("--cache", is_flag=True, help="Remove cached binary (~/.local/share/ownscribe/).")
@click.option("--output", is_flag=True, help="Remove output directory with recordings/transcripts.")
@click.pass_context
def cleanup(
    ctx: click.Context,
    yes: bool,
    all_: bool,
    config_: bool,
    cache: bool,
    output: bool,
) -> None:
    """Remove ownscribe data from disk (config, cache, recordings)."""
    cfg = ctx.obj["config"]
    output_dir = str(cfg.output.resolved_dir)
    audio_dir = str(cfg.output.resolved_audio_dir)

    targets: list[tuple[str, str]] = []

    if all_:
        targets = [
            ("Config", _CONFIG_DIR),
            ("Cache", _CACHE_DIR),
            ("Output", output_dir),
        ]
        if audio_dir != output_dir:
            targets.append(("Audio", audio_dir))
    elif config_ or cache or output:
        if config_:
            targets.append(("Config", _CONFIG_DIR))
        if cache:
            targets.append(("Cache", _CACHE_DIR))
        if output:
            targets.append(("Output", output_dir))
            if audio_dir != output_dir:
                targets.append(("Audio", audio_dir))
    else:
        candidates = [
            ("Config", _CONFIG_DIR),
            ("Cache", _CACHE_DIR),
            ("Output", output_dir),
        ]
        if audio_dir != output_dir:
            candidates.append(("Audio", audio_dir))
        # Interactive: prompt for each directory
        for label, path in candidates:
            size = _dir_size(path)
            if size == "(not found)":
                click.echo(f"  {label}: {path} — {size}, skipping")
                continue
            if yes or click.confirm(f"  Remove {label}: {path} ({size})?"):
                targets.append((label, path))
        if not targets:
            click.echo("Nothing to remove.")
        return _remove_targets(targets)

    if not yes:
        click.echo("The following directories will be removed:")
        for label, path in targets:
            click.echo(f"  {label}: {path} ({_dir_size(path)})")
        if not click.confirm("Proceed?"):
            click.echo("Aborted.")
            return

    _remove_targets(targets)


def _remove_targets(targets: list[tuple[str, str]]) -> None:
    """Delete the listed directories."""
    from pathlib import Path

    for label, path in targets:
        p = Path(path)
        if p.exists():
            shutil.rmtree(p)
            click.echo(f"  Removed {label}: {path}")
        else:
            click.echo(f"  {label}: {path} — not found, skipping")


# ----------------------------------------------------------------- GUI jobs (docs/engine-protocol.md)

_events_fd = click.option(
    "--events-fd", type=int, default=None, help="Write JSON progress events to this file descriptor."
)
_as_json = click.option("--json", "as_json", is_flag=True, help="Print the result as JSON on stdout.")
_session_arg = click.argument("session", type=click.Path(exists=True, file_okay=False))


def _run_job(command: str, session: str | None, events_fd: int | None, as_json: bool, fn) -> None:
    """Run a job with events and a JSON result; exit 0 ok, 1 failed, 2 partial, 130 cancelled."""
    import signal
    import sys

    from ownscribe.events import EventSink
    from ownscribe.jobs import JobError, dumps

    sink = EventSink(events_fd)

    def _cancel(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, _cancel)
    sink.emit("job", command=command, session=session, status="started")
    try:
        result = fn(sink)
    except JobError as exc:
        sink.emit("error", code=exc.code, message=exc.message, **({"stage": exc.stage} if exc.stage else {}))
        sink.emit("job", command=command, session=session, status="failed")
        sink.close()
        click.echo(f"Error: {exc.message}", err=True)
        if as_json:
            click.echo(dumps({"ok": False, "code": exc.code, "message": exc.message}))
        sys.exit(1)
    except KeyboardInterrupt:
        sink.emit("job", command=command, session=session, status="cancelled")
        sink.close()
        sys.exit(130)
    exit_code = result.pop("exit_code", 0) if isinstance(result, dict) else 0
    final_session = result.get("session", session) if isinstance(result, dict) else session
    sink.emit("job", command=command, session=final_session, status="done")
    sink.close()
    if as_json:
        click.echo(dumps(result))
    sys.exit(exit_code)


def _job_config(ctx: click.Context) -> Config:
    from ownscribe.jobs import prepare_environment

    config = ctx.obj["config"]
    prepare_environment(config)
    return config


@cli.group("session")
def session_group() -> None:
    """Create session folders for a GUI recording."""


@session_group.command("new")
@click.option("--output-dir", default=None, help="Parent folder (default: [output] dir).")
@_as_json
@click.pass_context
def session_new(ctx: click.Context, output_dir: str | None, as_json: bool) -> None:
    """Create a session folder; pass its path to `ownscribe-audio capture --session`."""
    from pathlib import Path

    from ownscribe import session as sessions
    from ownscribe.jobs import dumps

    config = ctx.obj["config"]
    base = Path(output_dir).expanduser() if output_dir else config.output.resolved_dir
    path = sessions.new_session(base)
    click.echo(dumps({"id": path.name, "path": str(path)}) if as_json else str(path))


@cli.command("process")
@_session_arg
@click.option("--template", default=None, help="Summary template (meeting, lecture, brief, or custom).")
@click.option("--diarize/--no-diarize", default=None, help="Override [diarization] enabled.")
@click.option("--summarize/--no-summarize", default=None, help="Override [summarization] enabled.")
@click.option("--language", default=None, help="Transcription language code.")
@click.option("--min-speakers", type=int, default=None)
@click.option("--max-speakers", type=int, default=None)
@_events_fd
@_as_json
@click.pass_context
def process_cmd(ctx, session, template, diarize, summarize, language, min_speakers, max_speakers, events_fd, as_json):
    """Transcribe, diarize and summarize a session's recording.wav."""
    from pathlib import Path

    from ownscribe import jobs

    config = _job_config(ctx)
    _run_job("process", session, events_fd, as_json, lambda sink: jobs.process(
        config, Path(session), sink=sink, template=template, diarize=diarize, summarize=summarize,
        language=language, min_speakers=min_speakers, max_speakers=max_speakers))


@cli.command("speakers")
@_session_arg
@click.option(
    "--set", "assignments", multiple=True, metavar="LABEL=NAME", help="Name a speaker, e.g. SPEAKER_00=Alice."
)
@click.option("--suggest", is_flag=True, help="Ask Claude to suggest each speaker's role.")
@click.option("--resummarize", is_flag=True, help="Summarize again with the names instead of substituting them.")
@_events_fd
@_as_json
@click.pass_context
def speakers_cmd(ctx, session, assignments, suggest, resummarize, events_fd, as_json):
    """Name speakers and re-render the transcript and summary."""
    from pathlib import Path

    from ownscribe import jobs

    names = {}
    for item in assignments:
        label, sep, name = item.partition("=")
        if not sep:
            raise click.BadParameter(f"{item!r} is not LABEL=NAME", param_hint="--set")
        names[label.strip()] = name
    config = _job_config(ctx)

    def run(sink):
        result: dict = {"session": session}
        if suggest:
            result["roles"] = jobs.suggest_roles(config, Path(session), sink=sink)
        if names or resummarize:
            result.update(jobs.set_speaker_names(config, Path(session), names, sink=sink, resummarize=resummarize))
        return result

    _run_job("speakers", session, events_fd, as_json, run)


@cli.command("resummarize")
@_session_arg
@click.option("--template", required=True, help="Summary template (meeting, lecture, brief, or custom).")
@_events_fd
@_as_json
@click.pass_context
def resummarize_cmd(ctx, session, template, events_fd, as_json):
    """Summarize a session again with another template."""
    from pathlib import Path

    from ownscribe import jobs

    config = _job_config(ctx)
    _run_job("resummarize", session, events_fd, as_json,
             lambda sink: jobs.resummarize(config, Path(session), template, sink=sink))


@cli.command("file")
@_session_arg
@click.option("--preview", "mode", flag_value="preview", help="Draft the vault note and show it.")
@click.option("--write", "mode", flag_value="write", help="Write the previewed note into the vault.")
@click.option("--edits", type=click.Path(exists=True, dir_okay=False), default=None,
              help="JSON file with title/category/tags/body_markdown overrides for --write.")
@_events_fd
@_as_json
@click.pass_context
def file_cmd(ctx, session, mode, edits, events_fd, as_json):
    """File a session into the Obsidian vault: --preview first, then --write."""
    import json as _json
    from pathlib import Path

    from ownscribe import jobs

    if mode is None:
        raise click.UsageError("Pass --preview or --write.")
    config = _job_config(ctx)
    overrides = _json.loads(Path(edits).read_text()) if edits else None
    if mode == "preview":
        _run_job("file", session, events_fd, as_json,
                 lambda sink: jobs.vault_preview(config, Path(session), sink=sink))
    else:
        _run_job("file", session, events_fd, as_json,
                 lambda sink: jobs.vault_write(config, Path(session), edits=overrides, sink=sink))


@cli.command("sessions")
@click.option("--output-dir", default=None, help="Folder to list (default: [output] dir).")
@_as_json
@click.pass_context
def sessions_cmd(ctx, output_dir, as_json):
    """List recordings and their processing status."""
    from pathlib import Path

    from ownscribe import session as sessions
    from ownscribe.jobs import dumps

    config = ctx.obj["config"]
    found = sessions.list_sessions(Path(output_dir).expanduser() if output_dir else config.output.resolved_dir)
    if as_json:
        click.echo(dumps({"sessions": found}))
        return
    for s in found:
        stages = " ".join(f"{k}={v}" for k, v in s["stages"].items())
        click.echo(f"{s['id']}  {s.get('title') or '(untitled)'}  {stages}")


@cli.command("templates")
@_as_json
@click.pass_context
def templates_cmd(ctx, as_json):
    """List summary templates (built-in and custom)."""
    from ownscribe import jobs

    found = jobs.list_templates(ctx.obj["config"])
    click.echo(jobs.dumps({"templates": found}) if as_json else "\n".join(f"{t['name']} ({t['kind']})" for t in found))


@cli.command("doctor")
@_as_json
@click.pass_context
def doctor_cmd(ctx, as_json):
    """Check tools, tokens, models and disk space a recording needs."""
    import sys

    from ownscribe import jobs

    report = jobs.doctor(_job_config(ctx))
    if as_json:
        click.echo(jobs.dumps(report))
    else:
        for name, check in report["checks"].items():
            details = ", ".join(f"{k}={v}" for k, v in check.items() if k != "ok")
            click.echo(f"{'ok ' if check['ok'] else 'NO '} {name}: {details}")
    sys.exit(0 if report["ok"] else 1)
