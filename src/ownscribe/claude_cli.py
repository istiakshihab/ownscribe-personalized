"""Shared helper for invoking the headless `claude` CLI as a text-only subprocess.

Used by both vault_filing.py and speaker_naming.py — anything that needs a
one-shot, no-tool-access text response from Claude.
"""

from __future__ import annotations

import contextlib
import json
import shutil
import subprocess
from pathlib import Path


class ClaudeCliError(Exception):
    """Raised for any failure resolving or invoking the claude CLI."""


def resolve_claude_bin(configured: str) -> str:
    if configured:
        return configured
    found = shutil.which("claude")
    if not found:
        raise ClaudeCliError(
            "claude CLI not found on PATH. Set obsidian.claude_bin in config.toml, "
            "or install it so `claude` resolves on PATH."
        )
    return found


def run_claude(prompt: str, claude_bin: str, *, cwd: Path, timeout: int = 600) -> str:
    """Run a single headless, tool-less `claude -p` call and return its text result."""
    result = subprocess.run(
        [claude_bin, "-p", prompt, "--output-format", "json", "--allowedTools", "", "--model", "sonnet"],
        capture_output=True,
        text=True,
        timeout=timeout,
        # Isolated cwd (no CLAUDE.md/.claude project config here) so this
        # narrow text-only call doesn't auto-discover unrelated project
        # instructions/agents/skills as extra context.
        cwd=str(cwd),
    )
    envelope = None
    # strict=False: tolerates raw control characters (e.g. literal newlines)
    # inside JSON string values, which models sometimes emit instead of
    # properly escaped \n.
    with contextlib.suppress(json.JSONDecodeError, ValueError):
        envelope = json.loads(result.stdout, strict=False)

    if result.returncode != 0 or (envelope and envelope.get("is_error")):
        detail = envelope.get("result") if envelope else None
        raise ClaudeCliError(
            f"claude exited {result.returncode}: "
            f"{detail or result.stderr[:2000] or result.stdout[:2000]}"
        )
    if envelope is None:
        raise ClaudeCliError(f"claude returned non-JSON stdout: {result.stdout[:2000]}")
    return envelope.get("result", "")
