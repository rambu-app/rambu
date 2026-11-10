import wave
from pathlib import Path
from typing import Any, Callable, Literal, Protocol

import httpx

AppLanguage = Literal["id", "en"]


class Transcriber(Protocol):
    def probe(self) -> None: ...
    def transcribe(self, path: Path, language: AppLanguage = "id") -> str: ...


class TranscriptionFailure(RuntimeError):
    pass


class BridgeTranscriber:
    def __init__(
        self,
        base_url: str,
        *,
        timeout_seconds: float = 30,
        client: httpx.Client | None = None,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self._client = client or httpx.Client(timeout=timeout_seconds)

    def probe(self) -> None:
        try:
            response = self._client.get(f"{self.base_url}/health")
            response.raise_for_status()
            payload = response.json()
            if payload.get("status") != "ok":
                raise ValueError("unexpected health response")
        except httpx.TimeoutException as error:
            raise TranscriptionFailure("transcription bridge timed out") from error
        except Exception as error:
            raise TranscriptionFailure("transcription bridge unavailable") from error

    def transcribe(self, path: Path, language: AppLanguage = "id") -> str:
        try:
            response = self._client.post(
                f"{self.base_url}/v1/transcriptions",
                headers={
                    "content-type": "audio/wav",
                    "x-rambu-language": language,
                },
                content=path.read_bytes(),
            )
            response.raise_for_status()
            text = response.json().get("text")
            if not isinstance(text, str):
                raise ValueError("missing transcript")
            return text.strip()
        except httpx.TimeoutException as error:
            raise TranscriptionFailure("transcription bridge timed out") from error
        except TranscriptionFailure:
            raise
        except Exception as error:
            raise TranscriptionFailure("transcription bridge unavailable") from error


class FasterWhisperTranscriber:
    def __init__(
        self,
        model_name: str = "small",
        *,
        device: str = "cpu",
        compute_type: str = "int8",
        device_index: int = 0,
        model_factory: Callable[..., Any] | None = None,
    ) -> None:
        self.model_name = model_name
        self.device = device
        self.compute_type = compute_type
        self.device_index = device_index
        self._model_factory = model_factory
        self._model = None

    def probe(self) -> None:
        self._load_model()

    def transcribe(self, path: Path, language: AppLanguage = "id") -> str:
        # Runtime puck chunks are WAV. Dataset evaluation also accepts formats
        # supported by faster-whisper/PyAV, including MP3.
        if path.suffix.lower() == ".wav":
            with wave.open(str(path), "rb") as source:
                duration = source.getnframes() / source.getframerate()
            if duration < 0.75:
                return ""

        model = self._load_model()

        segments, _ = model.transcribe(
            str(path),
            language=language,
            vad_filter=True,
            beam_size=5,
        )
        return " ".join(segment.text.strip() for segment in segments).strip()

    def _load_model(self) -> Any:
        if self._model is None:
            factory = self._model_factory
            if factory is None:
                from faster_whisper import WhisperModel

                factory = WhisperModel
            self._model = factory(
                self.model_name,
                device=self.device,
                compute_type=self.compute_type,
                device_index=self.device_index,
            )
        return self._model
