from dataclasses import dataclass
from typing import Mapping
from urllib.parse import urlsplit


class ConfigurationError(RuntimeError):
    pass


@dataclass(frozen=True)
class LangflowSettings:
    url: str
    flow_id: str
    api_key: str

    @classmethod
    def from_environment(cls, environment: Mapping[str, str]) -> "LangflowSettings":
        values: dict[str, str] = {}
        for name in ("LANGFLOW_URL", "LANGFLOW_FLOW_ID", "LANGFLOW_API_KEY"):
            value = environment.get(name, "").strip()
            if not value:
                raise ConfigurationError(f"{name} is required")
            values[name] = value
        return cls(
            url=values["LANGFLOW_URL"],
            flow_id=values["LANGFLOW_FLOW_ID"],
            api_key=values["LANGFLOW_API_KEY"],
        )


@dataclass(frozen=True)
class WhisperSettings:
    model_name: str
    device: str
    compute_type: str
    device_index: int

    @classmethod
    def from_environment(cls, environment: Mapping[str, str]) -> "WhisperSettings":
        model_name = environment.get("RAMBU_WHISPER_MODEL", "small").strip() or "small"
        device = environment.get("RAMBU_WHISPER_DEVICE", "cpu").strip().lower()
        if device not in {"cpu", "cuda"}:
            raise ConfigurationError("RAMBU_WHISPER_DEVICE must be cpu or cuda")

        compute_type = environment.get("RAMBU_WHISPER_COMPUTE_TYPE", "int8").strip()
        if not compute_type:
            raise ConfigurationError("RAMBU_WHISPER_COMPUTE_TYPE is required")

        raw_device_index = environment.get("RAMBU_WHISPER_DEVICE_INDEX", "0").strip()
        try:
            device_index = int(raw_device_index)
        except ValueError as error:
            raise ConfigurationError("RAMBU_WHISPER_DEVICE_INDEX must be an integer") from error
        if device_index < 0:
            raise ConfigurationError("RAMBU_WHISPER_DEVICE_INDEX must be zero or greater")

        return cls(
            model_name=model_name,
            device=device,
            compute_type=compute_type,
            device_index=device_index,
        )


@dataclass(frozen=True)
class TranscriptionSettings:
    provider: str
    bridge_url: str | None
    timeout_seconds: float
    whisper: WhisperSettings

    @classmethod
    def from_environment(cls, environment: Mapping[str, str]) -> "TranscriptionSettings":
        provider = environment.get("RAMBU_TRANSCRIPTION_PROVIDER", "bridge").strip().lower()
        if provider not in {"bridge", "whisper"}:
            raise ConfigurationError(
                "RAMBU_TRANSCRIPTION_PROVIDER must be bridge or whisper"
            )

        raw_timeout = environment.get("RAMBU_TRANSCRIPTION_TIMEOUT_SECONDS", "30").strip()
        try:
            timeout_seconds = float(raw_timeout)
        except ValueError as error:
            raise ConfigurationError(
                "RAMBU_TRANSCRIPTION_TIMEOUT_SECONDS must be a positive number"
            ) from error
        if timeout_seconds <= 0:
            raise ConfigurationError(
                "RAMBU_TRANSCRIPTION_TIMEOUT_SECONDS must be a positive number"
            )

        bridge_url = environment.get("RAMBU_TRANSCRIPTION_BRIDGE_URL", "").strip()
        if provider == "bridge" and not bridge_url:
            raise ConfigurationError(
                "RAMBU_TRANSCRIPTION_BRIDGE_URL is required for bridge provider"
            )
        if bridge_url:
            parsed = urlsplit(bridge_url)
            if parsed.scheme not in {"http", "https"} or not parsed.netloc:
                raise ConfigurationError(
                    "RAMBU_TRANSCRIPTION_BRIDGE_URL must be an http or https URL"
                )
            bridge_url = bridge_url.rstrip("/")

        return cls(
            provider=provider,
            bridge_url=bridge_url or None,
            timeout_seconds=timeout_seconds,
            whisper=WhisperSettings.from_environment(environment),
        )
