"""MLX-Whisper-based transcription (Apple GPU) with optional pyannote diarization."""

from __future__ import annotations

import contextlib
import logging
import os
import warnings
from pathlib import Path

import click

from ownscribe.config import DiarizationConfig, TranscriptionConfig
from ownscribe.progress import (
    DownloadProgressEvent,
    DownloadProgressWriter,
    NullProgress,
    download_event_fraction,
    format_download_progress,
)
from ownscribe.transcription.base import Transcriber
from ownscribe.transcription.models import Segment, TranscriptResult, Word

_SAMPLE_RATE = 16000

# mlx-community publishes MLX-converted Whisper weights under this naming
# scheme for the standard (fp16) variant of each size. Anything not in this
# map is passed straight through as a Hugging Face repo id / local path, so
# users can point at their own MLX conversion or a quantized variant.
_MLX_MODEL_REPOS = {
    "tiny": "mlx-community/whisper-tiny-mlx",
    "base": "mlx-community/whisper-base-mlx",
    "small": "mlx-community/whisper-small-mlx",
    "medium": "mlx-community/whisper-medium-mlx",
    "large-v3": "mlx-community/whisper-large-v3-mlx",
}


class MLXWhisperTranscriber(Transcriber):
    """Transcribes audio using MLX Whisper (Apple GPU) with optional pyannote diarization."""

    def __init__(
        self,
        transcription_config: TranscriptionConfig,
        diarization_config: DiarizationConfig | None = None,
        progress: NullProgress | None = None,
        need_word_timestamps: bool = False,
    ) -> None:
        self._tx_config = transcription_config
        self._diar_config = diarization_config
        self._progress = progress or NullProgress()
        self._need_word_timestamps = need_word_timestamps
        self._model_repo = self._resolve_model_repo()
        self._model_loaded = False
        self._diarize_model = None

    def _resolve_model_repo(self) -> str:
        return _MLX_MODEL_REPOS.get(self._tx_config.model, self._tx_config.model)

    def _will_diarize(self) -> bool:
        return bool(
            self._diar_config
            and self._diar_config.enabled
            and self._diar_config.hf_token
        )

    def _wants_word_timestamps(self) -> bool:
        """Whether to pay for word-level timing during transcription.

        Nothing reads word timings unless the caller asked for JSON output or
        diarization needs them to assign speakers to words.
        """
        return self._need_word_timestamps or self._will_diarize()

    def _load_model(self) -> None:
        from mlx_whisper.load_models import load_model

        # Loading here (during "preparing_models"/warmup) just forces the
        # weights onto disk via huggingface_hub; mlx_whisper.transcribe()
        # reloads them itself when it actually runs, since it doesn't expose
        # a way to hand it a pre-loaded model instance.
        load_model(self._model_repo)
        self._model_loaded = True

    def _configure_runtime_env(self) -> None:
        os.environ.setdefault("TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD", "1")
        if self._diar_config is None or not self._diar_config.telemetry:
            os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
            os.environ.setdefault("PYANNOTE_METRICS_ENABLED", "0")

    def _set_detail(self, key: str, text: str | None) -> None:
        set_detail = getattr(self._progress, "set_detail", None)
        if callable(set_detail):
            set_detail(key, text)

    def _set_prepare_detail(self, text: str | None) -> None:
        self._set_detail("preparing_models", text)

    def _on_download_progress(self, step_key: str, stage_label: str, event: DownloadProgressEvent) -> None:
        fraction = download_event_fraction(event)
        if fraction is not None:
            self._progress.update(step_key, fraction)
        formatted = format_download_progress(event, include_percent=fraction is None)
        if formatted:
            self._set_detail(step_key, f"{stage_label}: {formatted}")
        elif fraction is None and event.percent is not None:
            self._set_detail(step_key, f"{stage_label}: {int(event.percent)}%")

    def _capture_download_output(self, step_key: str, stage_label: str, fn, *args, **kwargs):
        writer = DownloadProgressWriter(
            lambda event: self._on_download_progress(step_key, stage_label, event)
        )
        self._set_detail(step_key, stage_label)
        with contextlib.ExitStack() as stack:
            stack.enter_context(contextlib.redirect_stdout(writer))
            stack.enter_context(contextlib.redirect_stderr(writer))
            result = fn(*args, **kwargs)
        writer.flush()
        return result

    def _capture_prep_output(self, stage_label: str, fn, *args, **kwargs):
        return self._capture_download_output("preparing_models", stage_label, fn, *args, **kwargs)

    def _load_diarization_pipeline(self, *, step_key: str = "preparing_models"):
        from whisperx.diarize import DiarizationPipeline

        if self._diarize_model is not None:
            return self._diarize_model

        device = self._resolve_diarization_device(self._diar_config.device)
        self._diarize_model = self._capture_download_output(
            step_key,
            "Loading diarization pipeline",
            DiarizationPipeline,
            token=self._diar_config.hf_token,
            device=device,
        )
        return self._diarize_model

    def prepare_models(self, language: str | None = None) -> None:
        _ = language  # MLX needs no separate per-language alignment model.
        self._configure_runtime_env()
        progress = self._progress
        progress.begin("preparing_models")
        try:
            if self._model_loaded:
                self._set_prepare_detail(f"Whisper model ready ({self._tx_config.model})")
            else:
                self._capture_prep_output(
                    f"Loading Whisper model ({self._tx_config.model})",
                    self._load_model,
                )

            if self._will_diarize():
                self._load_diarization_pipeline()

            progress.complete("preparing_models")
        except Exception:
            progress.fail("preparing_models")
            raise

    def transcribe(self, audio_path: Path) -> TranscriptResult:
        import shutil

        if not shutil.which("ffmpeg"):
            click.echo(
                "Error: ffmpeg is not installed. ownscribe requires ffmpeg for audio decoding.\n"
                "Install with: brew install ffmpeg",
                err=True,
            )
            raise SystemExit(1)

        self._configure_runtime_env()

        hf_token_warning: str | None = None
        if (
            self._diar_config
            and self._diar_config.enabled
            and not self._diar_config.hf_token
        ):
            hf_token_warning = (
                "Diarization requested but no HF token configured. "
                "Set HF_TOKEN env var or hf_token in config. Skipping."
            )

        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            for name in ("whisperx", "lightning", "pytorch_lightning"):
                logging.getLogger(name).setLevel(logging.WARNING)
            result = self._transcribe_inner(audio_path)

        if hf_token_warning:
            click.echo(hf_token_warning, err=True)

        return result

    def _transcribe_inner(self, audio_path: Path) -> TranscriptResult:
        import mlx_whisper
        import whisperx  # audio decoding + diarization glue only; no ASR use

        progress = self._progress

        devnull = open(os.devnull, "w")  # noqa: SIM115
        try:
            with contextlib.redirect_stdout(devnull):
                progress.begin("transcribing")

                if not self._model_loaded:
                    self._capture_download_output(
                        "transcribing",
                        f"Loading Whisper model ({self._tx_config.model})",
                        self._load_model,
                    )
                self._set_detail("transcribing", None)

                audio = whisperx.load_audio(str(audio_path))

                initial_prompt = self._tx_config.initial_prompt or None
                if self._tx_config.hotwords:
                    # mlx-whisper has no dedicated hotwords mechanism (that's a
                    # faster-whisper/CTranslate2 feature); folding them into the
                    # prompt is the closest available substitute.
                    hint = f"Vocabulary: {self._tx_config.hotwords}."
                    initial_prompt = f"{hint} {initial_prompt}" if initial_prompt else hint

                # mlx_whisper prints its own tqdm progress to stderr; suppressed
                # in favour of the begin/complete spinner rather than parsed,
                # since tqdm's bar format isn't the whisperx "Progress: NN%"
                # text the rest of this pipeline's progress writers expect.
                with contextlib.redirect_stderr(devnull):
                    result = mlx_whisper.transcribe(
                        audio,
                        path_or_hf_repo=self._model_repo,
                        language=self._tx_config.language or None,
                        initial_prompt=initial_prompt,
                        word_timestamps=self._wants_word_timestamps(),
                        verbose=False,
                    )

                language = result.get("language", "")
                progress.complete("transcribing")

                # --- Optional diarization ---
                if self._will_diarize():
                    result = self._diarize(audio, result)
        finally:
            devnull.close()

        # --- Convert to our data models ---
        segments = []
        for seg in result.get("segments", []):
            words = []
            for w in seg.get("words", []):
                words.append(
                    Word(
                        text=w.get("word", ""),
                        start=w.get("start", 0.0),
                        end=w.get("end", 0.0),
                        speaker=w.get("speaker"),
                        score=w.get("probability", 0.0),
                    )
                )
            segments.append(
                Segment(
                    text=seg.get("text", ""),
                    start=seg.get("start", 0.0),
                    end=seg.get("end", 0.0),
                    speaker=seg.get("speaker"),
                    words=words,
                )
            )

        duration = audio.shape[0] / float(_SAMPLE_RATE)
        return TranscriptResult(segments=segments, language=language, duration=duration)

    def _diarize(self, audio, result):
        import pandas as pd
        import torch
        import whisperx

        progress = self._progress
        progress.begin("diarizing")
        diarize_model = self._load_diarization_pipeline(step_key="diarizing")

        # Build audio_data dict the same way whisperx does internally
        audio_data = {
            "waveform": torch.from_numpy(audio[None, :]),
            "sample_rate": _SAMPLE_RATE,
        }

        diarize_kwargs = {}
        if self._diar_config.min_speakers > 0:
            diarize_kwargs["min_speakers"] = self._diar_config.min_speakers
        if self._diar_config.max_speakers > 0:
            diarize_kwargs["max_speakers"] = self._diar_config.max_speakers

        # Call pyannote pipeline directly with progress hook
        diarization = diarize_model.model(
            audio_data, hook=progress.diarization_hook, **diarize_kwargs
        )

        progress.complete("diarizing")

        # Convert to DataFrame (replicating whisperx/diarize.py logic)
        diarize_df = pd.DataFrame(
            diarization.speaker_diarization.itertracks(yield_label=True),
            columns=["segment", "label", "speaker"],
        )
        diarize_df["start"] = diarize_df["segment"].apply(lambda x: x.start)
        diarize_df["end"] = diarize_df["segment"].apply(lambda x: x.end)

        return whisperx.assign_word_speakers(diarize_df, result)

    @staticmethod
    def _resolve_diarization_device(device_cfg: str) -> str:
        if device_cfg == "auto":
            import torch

            return "mps" if torch.backends.mps.is_available() else "cpu"
        return device_cfg
