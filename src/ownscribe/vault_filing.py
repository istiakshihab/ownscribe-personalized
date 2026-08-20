"""File a finished transcript into the Obsidian vault as a categorized note.

Runs synchronously right after transcription (see pipeline.py), in-process —
no watcher, no state file. Summarization/categorization is delegated to a
headless `claude -p` call (text-only, no tool access): it can only return
text, never touch the filesystem itself. This module owns every write and
validates the model's suggested category against a fixed allow-list before
ever constructing a path.
"""

from __future__ import annotations

import contextlib
import json
import re
import shutil
import subprocess
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from ownscribe.config import CONFIG_DIR, Config
from ownscribe.transcription.models import TranscriptResult

PROMPT_TEMPLATE_PATH = CONFIG_DIR / "vault_prompt_template.txt"
_DEFAULT_TEMPLATE_PATH = Path(__file__).parent / "data" / "vault_prompt_template.default.txt"

# Fixed allow-list: only these exact category strings map to a real vault
# folder. Anything else (including "Unknown") falls back to Meetings Inbox.
CATEGORY_TO_FOLDER = {
    "Portrait": "Portrait/Meetings",
    "Research": "Research",
    "Oregon State University": "Oregon State University",
    "Job Search": "Job Search",
    "Monolog": "Monolog",
    "Personal": "Personal",
    "Podcast": "Podcast",
}
FALLBACK_FOLDER = "Meetings Inbox"


class VaultFilingError(Exception):
    """Raised for any failure in the vault-filing step; always non-fatal to the caller."""


@dataclass
class FiledNote:
    path: Path
    needs_review: bool


@dataclass
class PreparedNote:
    """A vault note ready to write, pending user confirmation."""

    parsed: dict
    folder_name: str
    date: str


def _ensure_prompt_template() -> Path:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    if not PROMPT_TEMPLATE_PATH.exists():
        PROMPT_TEMPLATE_PATH.write_text(_DEFAULT_TEMPLATE_PATH.read_text(encoding="utf-8"))
    return PROMPT_TEMPLATE_PATH


def _diarization_note(has_speakers: bool) -> str:
    if has_speakers:
        return (
            "This transcript includes speaker diarization: turns are labeled with "
            "speaker tags like SPEAKER_00, SPEAKER_01. These are consistent per-speaker "
            "within this transcript, but are anonymous IDs, not names — map a tag to a "
            "real name only where that person is explicitly named or self-identifies in "
            "the text."
        )
    return (
        "This transcript has no speaker diarization — it is a single undifferentiated "
        "stream of text with no speaker boundaries. Only attribute a statement to a "
        "specific person if they are named or self-identify in the text; otherwise "
        "write the summary neutrally without inventing who said what."
    )


def _resolve_claude_bin(configured: str) -> str:
    if configured:
        return configured
    found = shutil.which("claude")
    if not found:
        raise VaultFilingError(
            "claude CLI not found on PATH. Set obsidian.claude_bin in config.toml, "
            "or install it so `claude` resolves on PATH."
        )
    return found


def build_prompt(folder_name: str, meeting_name: str, transcript_text: str, has_speakers: bool) -> str:
    template_path = _ensure_prompt_template()
    template = template_path.read_text(encoding="utf-8")
    return template.format(
        folder_name=folder_name,
        meeting_name=meeting_name,
        diarization_note=_diarization_note(has_speakers),
        transcript_text=transcript_text,
    )


def call_claude(prompt: str, claude_bin: str) -> dict:
    result = subprocess.run(
        [claude_bin, "-p", prompt, "--output-format", "json", "--allowedTools", "", "--model", "sonnet"],
        capture_output=True,
        text=True,
        timeout=600,
        # Isolated cwd (no CLAUDE.md/.claude project config here) so this
        # narrow text-only call doesn't auto-discover unrelated project
        # instructions/agents/skills as extra context.
        cwd=str(CONFIG_DIR),
    )
    envelope = None
    # strict=False: tolerates raw control characters (e.g. literal newlines)
    # inside JSON string values, which models sometimes emit instead of
    # properly escaped \n.
    with contextlib.suppress(json.JSONDecodeError, ValueError):
        envelope = json.loads(result.stdout, strict=False)

    if result.returncode != 0 or (envelope and envelope.get("is_error")):
        detail = envelope.get("result") if envelope else None
        raise VaultFilingError(
            f"claude exited {result.returncode}: "
            f"{detail or result.stderr[:2000] or result.stdout[:2000]}"
        )
    if envelope is None:
        raise VaultFilingError(f"claude returned non-JSON stdout: {result.stdout[:2000]}")
    text = envelope.get("result", "")
    return parse_delimited_response(text)


def parse_delimited_response(text: str) -> dict:
    """Parse the <<<TITLE>>>/<<<CATEGORY>>>/<<<TAGS>>>/<<<BODY>>> plain-text
    format. Deliberately not JSON: the body is long free-form markdown, and
    asking a model to JSON-escape long prose reliably is exactly what kept
    breaking (unescaped quotes/newlines) during testing."""
    markers = ["<<<TITLE>>>", "<<<CATEGORY>>>", "<<<TAGS>>>", "<<<BODY>>>"]
    positions = []
    for m in markers:
        idx = text.find(m)
        if idx == -1:
            raise VaultFilingError(f"claude response missing {m} marker: {text[:500]}")
        positions.append((m, idx))
    positions.sort(key=lambda p: p[1])

    sections = {}
    for i, (marker, idx) in enumerate(positions):
        start = idx + len(marker)
        end = positions[i + 1][1] if i + 1 < len(positions) else len(text)
        sections[marker] = text[start:end].strip()

    tags = [t.strip() for t in sections["<<<TAGS>>>"].split(",") if t.strip()]
    return {
        "title": sections["<<<TITLE>>>"],
        "category": sections["<<<CATEGORY>>>"],
        "tags": tags,
        "body_markdown": sections["<<<BODY>>>"],
    }


def slugify_tag(s: str) -> str:
    return re.sub(r"[^a-z0-9-]+", "-", s.lower()).strip("-")


def yaml_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def write_note(parsed: dict, folder_name: str, date: str, vault_dir: Path) -> FiledNote:
    category = parsed.get("category", "")
    subfolder = CATEGORY_TO_FOLDER.get(category)
    needs_review = subfolder is None
    if needs_review:
        subfolder = FALLBACK_FOLDER

    title = parsed.get("title", "Untitled Meeting").strip()
    tags = [slugify_tag(t) for t in parsed.get("tags", []) if t]
    if not tags:
        tags = [slugify_tag(category) if category else "meeting"]

    dest_dir = vault_dir / subfolder
    dest_dir.mkdir(parents=True, exist_ok=True)

    base_filename = f"{date} {title}"
    filename = base_filename + ".md"
    n = 2
    while (dest_dir / filename).exists():
        filename = f"{base_filename} ({n}).md"
        n += 1

    fm_lines = [
        "---",
        f"title: {yaml_str(title)}",
        f"category: {yaml_str(category if not needs_review else 'Needs Review')}",
        "tags:",
    ]
    for t in tags:
        fm_lines.append(f"  - {t}")
    if needs_review:
        fm_lines.append('status: "needs-review"')
    fm_lines.append(f"created: {date}")
    fm_lines.append("source: transcript-pipeline")
    fm_lines.append("recorder: ownscribe")
    fm_lines.append(f"transcript_folder: {yaml_str(folder_name)}")
    fm_lines.append("---")
    frontmatter = "\n".join(fm_lines)

    body = parsed.get("body_markdown", "")
    full_text = frontmatter + "\n" + body + "\n"

    dest_path = dest_dir / filename
    dest_path.write_text(full_text, encoding="utf-8")
    return FiledNote(path=dest_path, needs_review=needs_review)


def prepare_note(config: Config, result: TranscriptResult, out_dir: Path) -> PreparedNote:
    """Summarize/categorize a just-finished transcript, but don't write it yet —
    callers that want a confirm-before-write step can inspect `.parsed` first,
    then pass this to write_note(). Raises VaultFilingError on any failure;
    callers should treat that as non-fatal to the transcript already in hand."""
    folder_name = out_dir.name
    date = folder_name[:10] if re.match(r"^\d{4}-\d{2}-\d{2}", folder_name) else datetime.now().strftime("%Y-%m-%d")

    transcript_text = result.speaker_text
    if not transcript_text.strip():
        raise VaultFilingError("transcript is empty, nothing to file")

    claude_bin = _resolve_claude_bin(config.obsidian.claude_bin)
    prompt = build_prompt(folder_name, folder_name, transcript_text, result.has_speakers)
    parsed = call_claude(prompt, claude_bin)
    return PreparedNote(parsed=parsed, folder_name=folder_name, date=date)


def file_to_vault(config: Config, result: TranscriptResult, out_dir: Path) -> FiledNote:
    """Prepare and immediately write a note, with no confirmation step."""
    prepared = prepare_note(config, result, out_dir)
    return write_note(prepared.parsed, prepared.folder_name, prepared.date, config.obsidian.resolved_vault_dir)
