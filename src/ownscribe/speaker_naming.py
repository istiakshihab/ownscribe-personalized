"""Interactively name diarized speakers (SPEAKER_00, SPEAKER_01, ...).

Asks Claude for a one-sentence role blurb per distinct speaker label (what
they did/said in the meeting), then interactively prompts for a real name
per speaker so transcripts and vault notes don't stay anonymous. Runs after
transcription/diarization, before the transcript is written to disk or
handed to vault_filing.py.
"""

from __future__ import annotations

import re

import click

from ownscribe.claude_cli import ClaudeCliError, resolve_claude_bin, run_claude
from ownscribe.config import CONFIG_DIR, Config
from ownscribe.transcription.models import TranscriptResult

_SPEAKER_LABEL_RE = re.compile(r"^(SPEAKER_\d+)\s*:\s*(.+)$")

ROLE_PROMPT_TEMPLATE = """\
You have no tools available — respond with plain text only.

Below is a meeting transcript where speaker turns are labeled with anonymous
tags (SPEAKER_00, SPEAKER_01, etc.). For each DISTINCT speaker label that
appears in the transcript, write exactly one line: the label, a colon, then
one concise sentence describing what that person did or said in the meeting
(their apparent role or main contribution) — enough for someone who attended
to recognize who it was. Do not invent names; refer to speakers only by
their label. List every distinct label that appears, in the order each
first speaks, one per line, and output nothing else.

Example output:
SPEAKER_00: Opened the meeting and walked through the Q3 budget numbers.
SPEAKER_01: Pushed back on the timeline and volunteered to own the migration.

## Transcript
{transcript_text}
"""


class SpeakerNamingError(Exception):
    """Raised for any failure identifying speaker roles; always non-fatal to the caller."""


def _distinct_speakers(result: TranscriptResult) -> list[str]:
    """Speaker labels in first-appearance order."""
    seen: list[str] = []
    for seg in result.segments:
        if seg.speaker and seg.speaker not in seen:
            seen.append(seg.speaker)
    return seen


def get_speaker_roles(config: Config, result: TranscriptResult) -> dict[str, str]:
    """One-sentence role blurb per distinct speaker label, via a headless claude call."""
    transcript_text = result.speaker_text
    if not transcript_text.strip():
        raise SpeakerNamingError("transcript is empty, nothing to identify speakers from")

    try:
        claude_bin = resolve_claude_bin(config.obsidian.claude_bin)
        prompt = ROLE_PROMPT_TEMPLATE.format(transcript_text=transcript_text)
        text = run_claude(prompt, claude_bin, cwd=CONFIG_DIR)
    except ClaudeCliError as exc:
        raise SpeakerNamingError(str(exc)) from exc

    roles: dict[str, str] = {}
    for line in text.splitlines():
        m = _SPEAKER_LABEL_RE.match(line.strip())
        if m:
            roles[m.group(1)] = m.group(2).strip()
    return roles


def prompt_for_names(result: TranscriptResult, roles: dict[str, str]) -> dict[str, str]:
    """Interactively ask for a name per distinct speaker label.

    Returns only the labels the user actually named — blank input keeps that
    label as-is, so a partially-answered prompt still renames what it can.
    """
    speakers = _distinct_speakers(result)
    mapping: dict[str, str] = {}
    if not speakers:
        return mapping

    click.echo("\n--- Speaker identification ---")
    for label in speakers:
        blurb = roles.get(label, "")
        click.echo(f"{label} — {blurb}" if blurb else label)
        name = click.prompt("  Name (blank to keep label)", default="", show_default=False).strip()
        if name:
            mapping[label] = name
    return mapping


def apply_speaker_names(result: TranscriptResult, mapping: dict[str, str]) -> None:
    """Rename speaker labels in place, across every segment and word."""
    if not mapping:
        return
    for seg in result.segments:
        if seg.speaker in mapping:
            seg.speaker = mapping[seg.speaker]
        for w in seg.words:
            if w.speaker in mapping:
                w.speaker = mapping[w.speaker]
