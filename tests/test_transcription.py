"""Tests for transcription helpers."""

from __future__ import annotations

import types
from unittest import mock

import pytest


class TestFfmpegCheck:
    def test_missing_ffmpeg_exits(self):
        from ownscribe.config import TranscriptionConfig
        from ownscribe.transcription.mlx_transcriber import MLXWhisperTranscriber

        transcriber = MLXWhisperTranscriber(TranscriptionConfig(), None)

        with mock.patch("shutil.which", return_value=None), pytest.raises(SystemExit):
            transcriber.transcribe(mock.MagicMock())


class TestModelRepoResolution:
    """Simple model names map to the mlx-community conversion; anything else passes through."""

    @staticmethod
    def _repo(model: str) -> str:
        from ownscribe.config import TranscriptionConfig
        from ownscribe.transcription.mlx_transcriber import MLXWhisperTranscriber

        return MLXWhisperTranscriber(TranscriptionConfig(model=model), None)._model_repo

    @pytest.mark.parametrize(
        ("model", "repo"),
        [
            ("tiny", "mlx-community/whisper-tiny-mlx"),
            ("base", "mlx-community/whisper-base-mlx"),
            ("small", "mlx-community/whisper-small-mlx"),
            ("medium", "mlx-community/whisper-medium-mlx"),
            ("large-v3", "mlx-community/whisper-large-v3-mlx"),
        ],
    )
    def test_known_sizes_map_to_mlx_community(self, model, repo):
        assert self._repo(model) == repo

    def test_custom_repo_passes_through_unchanged(self):
        custom = "mlx-community/whisper-large-v3-mlx-4bit"
        assert self._repo(custom) == custom


class TestWantsWordTimestamps:
    """Word timestamps cost extra compute; only pay for them when something reads them."""

    @staticmethod
    def _wants(need_word_timestamps: bool, diar=None) -> bool:
        from ownscribe.config import TranscriptionConfig
        from ownscribe.transcription.mlx_transcriber import MLXWhisperTranscriber

        transcriber = MLXWhisperTranscriber(
            TranscriptionConfig(), diar, need_word_timestamps=need_word_timestamps
        )
        return transcriber._wants_word_timestamps()

    def test_skipped_for_markdown_without_diarization(self):
        assert self._wants(need_word_timestamps=False) is False

    def test_wanted_for_json_output(self):
        assert self._wants(need_word_timestamps=True) is True

    def test_wanted_when_diarizing(self):
        from ownscribe.config import DiarizationConfig

        diar = DiarizationConfig(enabled=True, hf_token="hf_test_token")
        assert self._wants(need_word_timestamps=False, diar=diar) is True

    def test_skipped_when_diarization_has_no_token(self):
        from ownscribe.config import DiarizationConfig

        diar = DiarizationConfig(enabled=True, hf_token="")
        assert self._wants(need_word_timestamps=False, diar=diar) is False


class _FakeProgress:
    def __init__(self) -> None:
        self.calls: list[tuple[str, str]] = []
        self.details: dict[str, str] = {}
        self.updates: list[tuple[str, float]] = []

    def begin(self, key: str) -> None:
        self.calls.append(("begin", key))

    def complete(self, key: str) -> None:
        self.calls.append(("complete", key))

    def fail(self, key: str) -> None:
        self.calls.append(("fail", key))

    def update(self, key: str, fraction: float) -> None:
        self.updates.append((key, fraction))

    def set_detail(self, key: str, text: str | None) -> None:
        if text is None:
            self.details.pop(key, None)
        else:
            self.details[key] = text

    def diarization_hook(self, step_name: str, _artifact, **kwargs) -> None:
        _ = (step_name, _artifact, kwargs)


class TestPrepareModels:
    def test_prepare_models_emits_preparing_models_lifecycle(self):
        from ownscribe.config import TranscriptionConfig
        from ownscribe.transcription.mlx_transcriber import MLXWhisperTranscriber

        progress = _FakeProgress()
        transcriber = MLXWhisperTranscriber(TranscriptionConfig(language="en"), None, progress=progress)

        with mock.patch.object(
            transcriber, "_load_model", side_effect=lambda: setattr(transcriber, "_model_loaded", True)
        ):
            transcriber.prepare_models(language="en")

        assert ("begin", "preparing_models") in progress.calls
        assert ("complete", "preparing_models") in progress.calls
        assert ("fail", "preparing_models") not in progress.calls

    def test_prepare_models_skips_diarization_without_token(self):
        from ownscribe.config import DiarizationConfig, TranscriptionConfig
        from ownscribe.transcription.mlx_transcriber import MLXWhisperTranscriber

        progress = _FakeProgress()
        diar = DiarizationConfig(enabled=True, hf_token="")
        transcriber = MLXWhisperTranscriber(TranscriptionConfig(language="en"), diar, progress=progress)

        with (
            mock.patch.object(
                transcriber, "_load_model", side_effect=lambda: setattr(transcriber, "_model_loaded", True)
            ),
            mock.patch.object(transcriber, "_load_diarization_pipeline") as mock_diar_load,
        ):
            transcriber.prepare_models(language="en")

        mock_diar_load.assert_not_called()

    def test_prepare_models_reuses_loaded_whisper_model(self):
        from ownscribe.config import TranscriptionConfig
        from ownscribe.transcription.mlx_transcriber import MLXWhisperTranscriber

        progress = _FakeProgress()
        transcriber = MLXWhisperTranscriber(TranscriptionConfig(language="en"), None, progress=progress)

        with mock.patch.object(
            transcriber,
            "_load_model",
            side_effect=lambda: setattr(transcriber, "_model_loaded", True),
        ) as mock_load_model:
            transcriber.prepare_models(language="en")
            transcriber.prepare_models(language="en")

        assert mock_load_model.call_count == 1


class TestDownloadProgressHooks:
    def test_on_download_progress_updates_detail_and_bar(self):
        from ownscribe.config import TranscriptionConfig
        from ownscribe.progress import DownloadProgressEvent
        from ownscribe.transcription.mlx_transcriber import MLXWhisperTranscriber

        progress = _FakeProgress()
        transcriber = MLXWhisperTranscriber(TranscriptionConfig(), None, progress=progress)

        transcriber._on_download_progress(
            "preparing_models",
            "Loading Whisper model (base)",
            DownloadProgressEvent(filename="model.safetensors", percent=25.0),
        )

        assert ("preparing_models", 0.25) in progress.updates
        assert "Loading Whisper model (base)" in progress.details["preparing_models"]
        assert "model.safetensors" in progress.details["preparing_models"]
        assert "25%" not in progress.details["preparing_models"]

    def test_capture_download_output_resets_bar_to_zero(self):
        from ownscribe.config import TranscriptionConfig
        from ownscribe.transcription.mlx_transcriber import MLXWhisperTranscriber

        progress = _FakeProgress()
        transcriber = MLXWhisperTranscriber(TranscriptionConfig(), None, progress=progress)

        def fake_loader():
            print("model.safetensors: 12%|##| 12MB/100MB [00:01<00:08]")

        transcriber._capture_download_output("preparing_models", "Loading Whisper model (base)", fake_loader)

        assert progress.updates
        # Progress bar should only appear once download events fire, not eagerly at 0%
        assert all(frac > 0 for _, frac in progress.updates)


class TestTranscribeInner:
    def test_loads_model_lazily_and_skips_preparing_models_step(self):
        from ownscribe.config import TranscriptionConfig
        from ownscribe.transcription.mlx_transcriber import MLXWhisperTranscriber

        class _Audio:
            shape = (16000,)

        fake_whisperx = types.SimpleNamespace(load_audio=lambda _path: _Audio())
        fake_mlx_whisper = mock.MagicMock()
        fake_mlx_whisper.transcribe.return_value = {"segments": [], "language": "en"}

        progress = _FakeProgress()
        transcriber = MLXWhisperTranscriber(TranscriptionConfig(language="en"), None, progress=progress)

        with (
            mock.patch.dict("sys.modules", {"whisperx": fake_whisperx, "mlx_whisper": fake_mlx_whisper}),
            mock.patch.object(
                transcriber, "_load_model", side_effect=lambda: setattr(transcriber, "_model_loaded", True)
            ),
        ):
            result = transcriber._transcribe_inner(mock.MagicMock())

        assert transcriber._model_loaded is True
        fake_mlx_whisper.transcribe.assert_called_once()
        assert ("begin", "transcribing") in progress.calls
        assert ("begin", "preparing_models") not in progress.calls
        assert result.language == "en"

    def test_does_not_reload_model_when_already_loaded(self):
        from ownscribe.config import TranscriptionConfig
        from ownscribe.transcription.mlx_transcriber import MLXWhisperTranscriber

        class _Audio:
            shape = (16000,)

        fake_whisperx = types.SimpleNamespace(load_audio=lambda _path: _Audio())
        fake_mlx_whisper = mock.MagicMock()
        fake_mlx_whisper.transcribe.return_value = {"segments": [], "language": "en"}

        progress = _FakeProgress()
        transcriber = MLXWhisperTranscriber(TranscriptionConfig(language="en"), None, progress=progress)
        transcriber._model_loaded = True

        with (
            mock.patch.dict("sys.modules", {"whisperx": fake_whisperx, "mlx_whisper": fake_mlx_whisper}),
            mock.patch.object(transcriber, "_load_model") as mock_load_model,
        ):
            transcriber._transcribe_inner(mock.MagicMock())

        mock_load_model.assert_not_called()

    def test_folds_hotwords_into_initial_prompt(self):
        from ownscribe.config import TranscriptionConfig
        from ownscribe.transcription.mlx_transcriber import MLXWhisperTranscriber

        class _Audio:
            shape = (16000,)

        fake_whisperx = types.SimpleNamespace(load_audio=lambda _path: _Audio())
        fake_mlx_whisper = mock.MagicMock()
        fake_mlx_whisper.transcribe.return_value = {"segments": [], "language": "en"}

        config = TranscriptionConfig(language="en", initial_prompt="Quarterly sync.", hotwords="Kubernetes, gRPC")
        transcriber = MLXWhisperTranscriber(config, None)
        transcriber._model_loaded = True

        with mock.patch.dict("sys.modules", {"whisperx": fake_whisperx, "mlx_whisper": fake_mlx_whisper}):
            transcriber._transcribe_inner(mock.MagicMock())

        prompt = fake_mlx_whisper.transcribe.call_args.kwargs["initial_prompt"]
        assert "Kubernetes, gRPC" in prompt
        assert "Quarterly sync." in prompt

    def test_word_dicts_are_converted_with_probability_as_score(self):
        from ownscribe.config import TranscriptionConfig
        from ownscribe.transcription.mlx_transcriber import MLXWhisperTranscriber

        class _Audio:
            shape = (16000,)

        fake_whisperx = types.SimpleNamespace(load_audio=lambda _path: _Audio())
        fake_mlx_whisper = mock.MagicMock()
        fake_mlx_whisper.transcribe.return_value = {
            "segments": [
                {
                    "text": "hello world",
                    "start": 0.0,
                    "end": 1.0,
                    "words": [{"word": "hello", "start": 0.0, "end": 0.5, "probability": 0.9}],
                }
            ],
            "language": "en",
        }

        transcriber = MLXWhisperTranscriber(TranscriptionConfig(), None, need_word_timestamps=True)
        transcriber._model_loaded = True

        with mock.patch.dict("sys.modules", {"whisperx": fake_whisperx, "mlx_whisper": fake_mlx_whisper}):
            result = transcriber._transcribe_inner(mock.MagicMock())

        word = result.segments[0].words[0]
        assert word.text == "hello"
        assert word.score == 0.9


class TestDiarizationApiCompat:
    def test_load_diarization_pipeline_passes_token_kwarg(self):
        # pyannote.audio 4.0 renamed `use_auth_token` -> `token`.
        from ownscribe.config import DiarizationConfig, TranscriptionConfig
        from ownscribe.transcription.mlx_transcriber import MLXWhisperTranscriber

        diar = DiarizationConfig(enabled=True, hf_token="hf_test_token", device="cpu")
        transcriber = MLXWhisperTranscriber(TranscriptionConfig(), diar, progress=_FakeProgress())

        fake_pipeline = mock.MagicMock(return_value=mock.sentinel.diarize_model)
        fake_diarize_module = types.SimpleNamespace(DiarizationPipeline=fake_pipeline)

        def passthrough(_step_key, _label, fn, *args, **kwargs):
            return fn(*args, **kwargs)

        with (
            mock.patch.dict("sys.modules", {"whisperx.diarize": fake_diarize_module}),
            mock.patch.object(transcriber, "_capture_download_output", side_effect=passthrough),
        ):
            result = transcriber._load_diarization_pipeline()

        assert result is mock.sentinel.diarize_model
        fake_pipeline.assert_called_once()
        kwargs = fake_pipeline.call_args.kwargs
        assert kwargs.get("token") == "hf_test_token"
        assert "use_auth_token" not in kwargs

    def test_diarize_unwraps_speaker_diarization_from_diarize_output(self):
        # pyannote.audio 4.0 wraps the annotation in a DiarizeOutput container;
        # _diarize must read it as `.speaker_diarization.itertracks()`.
        import numpy as np

        from ownscribe.config import DiarizationConfig, TranscriptionConfig
        from ownscribe.transcription.mlx_transcriber import MLXWhisperTranscriber

        diar = DiarizationConfig(enabled=True, hf_token="hf_test_token", device="cpu")
        transcriber = MLXWhisperTranscriber(TranscriptionConfig(), diar, progress=_FakeProgress())

        fake_segment = types.SimpleNamespace(start=0.5, end=1.5)
        fake_annotation = mock.MagicMock()
        fake_annotation.itertracks.return_value = [(fake_segment, "track_0", "SPEAKER_00")]
        # DiarizeOutput stand-in: deliberately no top-level `itertracks` attribute.
        fake_diarize_output = types.SimpleNamespace(speaker_diarization=fake_annotation)

        fake_diarize_model = mock.MagicMock()
        fake_diarize_model.model.return_value = fake_diarize_output

        fake_whisperx = types.SimpleNamespace(assign_word_speakers=lambda df, res: ("assigned", df, res))

        audio = np.zeros(16000, dtype=np.float32)

        with (
            mock.patch.object(transcriber, "_load_diarization_pipeline", return_value=fake_diarize_model),
            mock.patch.dict("sys.modules", {"whisperx": fake_whisperx}),
        ):
            out = transcriber._diarize(audio, {"segments": []})

        fake_annotation.itertracks.assert_called_once_with(yield_label=True)
        assert out[0] == "assigned"
