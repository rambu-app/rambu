import importlib

import pytest


def config_module():
    return importlib.import_module("rambu_api.config")


@pytest.mark.parametrize(
    ("name", "value"),
    [
        ("LANGFLOW_URL", None),
        ("LANGFLOW_URL", "   "),
        ("LANGFLOW_FLOW_ID", None),
        ("LANGFLOW_FLOW_ID", "\t"),
        ("LANGFLOW_API_KEY", None),
        ("LANGFLOW_API_KEY", "\n"),
    ],
)
def test_langflow_configuration_rejects_each_missing_or_blank_value(name, value) -> None:
    module = config_module()
    environment = {
        "LANGFLOW_URL": "http://localhost:7861",
        "LANGFLOW_FLOW_ID": "rambu",
        "LANGFLOW_API_KEY": "secret",
    }
    if value is None:
        environment.pop(name)
    else:
        environment[name] = value

    with pytest.raises(module.ConfigurationError, match=f"^{name} is required$"):
        module.LangflowSettings.from_environment(environment)


def test_langflow_configuration_trims_and_preserves_complete_values() -> None:
    module = config_module()

    result = module.LangflowSettings.from_environment(
        {
            "LANGFLOW_URL": "  https://langflow.example  ",
            "LANGFLOW_FLOW_ID": " rambu-production ",
            "LANGFLOW_API_KEY": " key-value ",
        }
    )

    assert result.url == "https://langflow.example"
    assert result.flow_id == "rambu-production"
    assert result.api_key == "key-value"


def test_whisper_configuration_uses_safe_cpu_defaults() -> None:
    module = config_module()

    result = module.WhisperSettings.from_environment({})

    assert result.model_name == "small"
    assert result.device == "cpu"
    assert result.compute_type == "int8"
    assert result.device_index == 0


def test_transcription_configuration_defaults_to_private_bridge() -> None:
    module = config_module()

    result = module.TranscriptionSettings.from_environment(
        {"RAMBU_TRANSCRIPTION_BRIDGE_URL": " http://transcription-bridge:8788/ "}
    )

    assert result.provider == "bridge"
    assert result.bridge_url == "http://transcription-bridge:8788"
    assert result.timeout_seconds == 30.0


def test_transcription_configuration_requires_bridge_url_by_default() -> None:
    module = config_module()

    with pytest.raises(
        module.ConfigurationError,
        match="^RAMBU_TRANSCRIPTION_BRIDGE_URL is required for bridge provider$",
    ):
        module.TranscriptionSettings.from_environment({})


def test_transcription_configuration_allows_explicit_local_whisper() -> None:
    module = config_module()

    result = module.TranscriptionSettings.from_environment(
        {"RAMBU_TRANSCRIPTION_PROVIDER": " whisper "}
    )

    assert result.provider == "whisper"
    assert result.bridge_url is None
    assert result.whisper.model_name == "small"


@pytest.mark.parametrize(
    ("environment", "message"),
    [
        (
            {
                "RAMBU_TRANSCRIPTION_BRIDGE_URL": "file:///tmp/socket",
            },
            "RAMBU_TRANSCRIPTION_BRIDGE_URL must be an http or https URL",
        ),
        (
            {
                "RAMBU_TRANSCRIPTION_PROVIDER": "gpu",
                "RAMBU_TRANSCRIPTION_BRIDGE_URL": "http://bridge:8788",
            },
            "RAMBU_TRANSCRIPTION_PROVIDER must be bridge or whisper",
        ),
        (
            {
                "RAMBU_TRANSCRIPTION_BRIDGE_URL": "http://bridge:8788",
                "RAMBU_TRANSCRIPTION_TIMEOUT_SECONDS": "zero",
            },
            "RAMBU_TRANSCRIPTION_TIMEOUT_SECONDS must be a positive number",
        ),
    ],
)
def test_transcription_configuration_rejects_invalid_values(environment, message) -> None:
    module = config_module()

    with pytest.raises(module.ConfigurationError, match=f"^{message}$"):
        module.TranscriptionSettings.from_environment(environment)


def test_whisper_configuration_trims_explicit_cuda_values() -> None:
    module = config_module()

    result = module.WhisperSettings.from_environment(
        {
            "RAMBU_WHISPER_MODEL": " small ",
            "RAMBU_WHISPER_DEVICE": " CUDA ",
            "RAMBU_WHISPER_COMPUTE_TYPE": " float16 ",
            "RAMBU_WHISPER_DEVICE_INDEX": " 0 ",
        }
    )

    assert result.model_name == "small"
    assert result.device == "cuda"
    assert result.compute_type == "float16"
    assert result.device_index == 0


@pytest.mark.parametrize(
    ("environment", "message"),
    [
        ({"RAMBU_WHISPER_DEVICE": "metal"}, "RAMBU_WHISPER_DEVICE must be cpu or cuda"),
        ({"RAMBU_WHISPER_COMPUTE_TYPE": "   "}, "RAMBU_WHISPER_COMPUTE_TYPE is required"),
        ({"RAMBU_WHISPER_DEVICE_INDEX": "-1"}, "RAMBU_WHISPER_DEVICE_INDEX must be zero or greater"),
        ({"RAMBU_WHISPER_DEVICE_INDEX": "first"}, "RAMBU_WHISPER_DEVICE_INDEX must be an integer"),
    ],
)
def test_whisper_configuration_rejects_invalid_values(environment, message) -> None:
    module = config_module()

    with pytest.raises(module.ConfigurationError, match=f"^{message}$"):
        module.WhisperSettings.from_environment(environment)
