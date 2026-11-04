"""Summarization through the headless `claude` CLI (Claude Code).

Uses the same one-shot, tool-less `claude -p` helper as vault filing and speaker naming
(`ownscribe.claude_cli`), so no extra dependency or API key is needed: whatever account the
`claude` CLI is signed in to does the work.
"""

from __future__ import annotations

from ownscribe.claude_cli import ClaudeCliError, resolve_claude_bin, run_claude
from ownscribe.config import CONFIG_DIR, SummarizationConfig
from ownscribe.summarization.base import Summarizer
from ownscribe.summarization.prompts import TITLE_PROMPT, TITLE_SYSTEM, clean_response

#: Claude's window is far larger than any meeting transcript, so chunking only kicks in for
#: very long recordings. Kept below the real limit to leave room for the CLI's own context.
CLAUDE_CONTEXT_SIZE = 150_000


class ClaudeSummarizer(Summarizer):
    """Summarizes transcripts with `claude -p` (Sonnet, no tools)."""

    def __init__(self, config: SummarizationConfig, templates: dict | None = None, claude_bin: str = "") -> None:
        super().__init__(config, templates)
        self._claude_bin = claude_bin

    @property
    def context_size(self) -> int:
        if self._config.context_size > 0:
            return self._config.context_size
        return CLAUDE_CONTEXT_SIZE

    def _run(self, system_prompt: str, user_prompt: str) -> str:
        prompt = f"{system_prompt}\n\n{user_prompt}" if system_prompt else user_prompt
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        # CONFIG_DIR as cwd: no project CLAUDE.md or .claude config is picked up as context.
        text = run_claude(prompt, resolve_claude_bin(self._claude_bin), cwd=CONFIG_DIR)
        return clean_response(text)

    def _complete(self, system_prompt: str, user_prompt: str) -> str:
        return self._run(system_prompt, user_prompt)

    def chat(
        self,
        system_prompt: str,
        user_prompt: str,
        json_mode: bool = False,
        json_schema: dict | None = None,
    ) -> str:
        if json_mode:
            user_prompt += "\n\nRespond with a single JSON object and nothing else."
        text = self._run(system_prompt, user_prompt)
        if json_mode and text.startswith("```"):
            text = text.strip("`").removeprefix("json").strip()
        return text

    def generate_title(self, summary_text: str) -> str:
        return self._run(TITLE_SYSTEM, TITLE_PROMPT.format(summary=summary_text)).strip().strip('"')

    def is_available(self) -> bool:
        try:
            resolve_claude_bin(self._claude_bin)
        except ClaudeCliError:
            return False
        return True
