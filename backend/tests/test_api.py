import pytest
from fastapi.testclient import TestClient

import rambu_api.app as app_module
from rambu_api.app import create_app
from rambu_api.langflow_client import LangflowFailure
from rambu_api.models import ChunkAnalysisResponse, DemoSnapshot, RiskAssessment

from .conftest import wav_bytes


class StubDemoService:
    def __init__(self) -> None:
        self.deleted: list[str] = []
        self.probes = 0

    def start(self, scenario: str) -> DemoSnapshot:
        if scenario in {"missing", "normal", "unclear", "otp"}:
            raise KeyError(scenario)
        return DemoSnapshot(
            id="demo-1",
            scenario=scenario,
            title="Permintaan OTP",
            status="running",
            progress=0,
            transcript="",
            assessment=None,
            error=None,
        )

    def get(self, session_id: str) -> DemoSnapshot:
        if session_id != "demo-1":
            raise KeyError(session_id)
        return DemoSnapshot(
            id="demo-1",
            scenario="bank-otp",
            title="Permintaan OTP",
            status="completed",
            progress=100,
            transcript="Berikan OTP [KODE].",
            assessment=None,
            error=None,
        )

    def delete(self, session_id: str) -> None:
        if session_id != "demo-1":
            raise KeyError(session_id)
        self.deleted.append(session_id)

    def close(self) -> None:
        pass

    def probe(self) -> None:
        self.probes += 1

    def analyze_chunk(self, audio: bytes, final: bool) -> ChunkAnalysisResponse:
        return ChunkAnalysisResponse(
            transcript="Berikan OTP [KODE].",
            assessment=RiskAssessment(
                risk_level="high_risk",
                signals=["secret_code"],
                evidence=[{"quote": "OTP [KODE]", "signals": ["secret_code"]}],
                explanation="Meminta kode rahasia.",
                recommended_action="Tutup telepon.",
            ),
        )


@pytest.mark.parametrize(
    "path",
    [
        "/",
        "/static/app.js",
        "/samples/bank-otp.wav",
        "/docs",
        "/redoc",
        "/openapi.json",
    ],
)
def test_public_web_routes_are_not_exposed(path: str) -> None:
    client = TestClient(create_app(service=StubDemoService()))

    assert client.get(path).status_code == 404


def test_demo_api_contract_remains_available_for_ios() -> None:
    service = StubDemoService()
    client = TestClient(create_app(service=service))

    started = client.post("/api/demo/bank-otp")
    status = client.get("/api/demo/demo-1")
    deleted = client.delete("/api/demo/demo-1")

    assert started.status_code == 201
    assert started.json()["id"] == "demo-1"
    assert status.json()["progress"] == 100
    assert deleted.status_code == 204
    assert service.deleted == ["demo-1"]


def test_unknown_demo_returns_not_found() -> None:
    client = TestClient(create_app(service=StubDemoService()))

    assert client.post("/api/demo/missing").status_code == 404
    assert client.get("/api/demo/missing").status_code == 404
    assert client.delete("/api/demo/missing").status_code == 404


def test_removed_backend_scenario_aliases_return_not_found() -> None:
    client = TestClient(create_app(service=StubDemoService()))

    assert client.post("/api/demo/normal").status_code == 404
    assert client.post("/api/demo/unclear").status_code == 404
    assert client.post("/api/demo/otp").status_code == 404


def test_live_chunk_requires_consent_and_returns_masked_analysis() -> None:
    client = TestClient(create_app(service=StubDemoService()))

    denied = client.post("/api/analyze-chunk", content=wav_bytes(), headers={"content-type": "audio/wav"})
    accepted = client.post(
        "/api/analyze-chunk",
        content=wav_bytes(),
        headers={"content-type": "audio/wav", "x-rambu-consent": "true", "x-rambu-final": "false"},
    )

    assert denied.status_code == 403
    assert accepted.status_code == 200
    assert accepted.json()["transcript"] == "Berikan OTP [KODE]."
    assert accepted.json()["assessment"]["risk_level"] == "high_risk"


def test_live_chunk_returns_sanitized_typed_dependency_failure() -> None:
    class FailingService(StubDemoService):
        def analyze_chunk(self, audio: bytes, final: bool) -> ChunkAnalysisResponse:
            raise LangflowFailure(
                "timeout",
                "Langflow tidak merespons sebelum batas waktu.",
                "http://langflow/api/v1/run/rambu",
            )

    client = TestClient(create_app(service=FailingService()))

    response = client.post(
        "/api/analyze-chunk",
        content=wav_bytes(),
        headers={"content-type": "audio/wav", "x-rambu-consent": "true"},
    )

    assert response.status_code == 503
    assert response.json()["detail"] == {
        "code": "analysis_timeout",
        "message": "Langflow tidak merespons sebelum batas waktu.",
    }


def test_injected_service_bypasses_default_probe() -> None:
    service = StubDemoService()

    with TestClient(create_app(service=service)) as client:
        assert client.get("/health").status_code == 200

    assert service.probes == 0


def test_default_startup_probes_and_propagates_failure(monkeypatch) -> None:
    class FailingProbeService(StubDemoService):
        def probe(self) -> None:
            self.probes += 1
            raise LangflowFailure(
                "connection",
                "Langflow tidak dapat dihubungi.",
                "http://langflow/api/v1/run/rambu",
            )

    service = FailingProbeService()
    monkeypatch.setattr(
        app_module,
        "_default_service",
        lambda _settings, _whisper_settings: service,
    )
    monkeypatch.setenv("RAMBU_TRANSCRIPTION_BRIDGE_URL", "http://bridge.internal:8788")
    application = create_app(settings=object())

    with pytest.raises(LangflowFailure, match="Langflow tidak dapat dihubungi"):
        with TestClient(application):
            pass

    assert service.probes == 1


def test_default_startup_rejects_missing_configuration(monkeypatch) -> None:
    for name in ("LANGFLOW_URL", "LANGFLOW_FLOW_ID", "LANGFLOW_API_KEY"):
        monkeypatch.delenv(name, raising=False)
    application = create_app()

    with pytest.raises(Exception) as captured:
        with TestClient(application):
            pass

    assert type(captured.value).__name__ == "ConfigurationError"
    assert str(captured.value) == "LANGFLOW_URL is required"
