from pathlib import Path

import httpx
import pytest

from rambu_api.transcription import BridgeTranscriber, TranscriptionFailure


def test_probe_uses_health_without_posting_audio() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return httpx.Response(200, json={"status": "ok"})

    transcriber = BridgeTranscriber(
        "http://bridge.internal:8788",
        client=httpx.Client(transport=httpx.MockTransport(handler)),
    )

    transcriber.probe()

    assert [(request.method, request.url.path) for request in requests] == [
        ("GET", "/health")
    ]


@pytest.mark.parametrize("language", ["id", "en"])
def test_transcribe_forwards_audio_and_language(tmp_path: Path, language: str) -> None:
    audio = tmp_path / "chunk.wav"
    audio.write_bytes(b"wave-bytes")

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.method == "POST"
        assert request.url.path == "/v1/transcriptions"
        assert request.headers["x-rambu-language"] == language
        assert request.headers["content-type"] == "audio/wav"
        assert request.content == b"wave-bytes"
        return httpx.Response(200, json={"text": "  Halo aman  "})

    transcriber = BridgeTranscriber(
        "http://bridge.internal:8788/",
        client=httpx.Client(transport=httpx.MockTransport(handler)),
    )

    assert transcriber.transcribe(audio, language=language) == "Halo aman"


def test_timeout_is_mapped_without_exposing_upstream_details(tmp_path: Path) -> None:
    audio = tmp_path / "chunk.wav"
    audio.write_bytes(b"wave")

    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("upstream included secret", request=request)

    transcriber = BridgeTranscriber(
        "http://bridge.internal:8788",
        client=httpx.Client(transport=httpx.MockTransport(handler)),
    )

    with pytest.raises(TranscriptionFailure, match="^transcription bridge timed out$"):
        transcriber.transcribe(audio)


def test_error_response_is_sanitized(tmp_path: Path) -> None:
    audio = tmp_path / "chunk.wav"
    audio.write_bytes(b"wave")

    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(502, text="Bearer secret-key and provider body")

    transcriber = BridgeTranscriber(
        "http://bridge.internal:8788",
        client=httpx.Client(transport=httpx.MockTransport(handler)),
    )

    with pytest.raises(TranscriptionFailure) as captured:
        transcriber.transcribe(audio)

    assert str(captured.value) == "transcription bridge unavailable"
    assert "secret-key" not in str(captured.value)
