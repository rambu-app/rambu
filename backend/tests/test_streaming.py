import asyncio
import threading
import time
from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from rambu_api.app import create_app
from rambu_api.models import RiskAssessment
from rambu_api.pilot import PilotStore
from rambu_api.protection import ProtectionService
from rambu_api.streaming import StreamCapacity

from .conftest import ImmediateExecutor
from .test_api import StubDemoService


class UnusedTranscriber:
    def transcribe(self, *_args, **_kwargs) -> str:
        raise AssertionError("streaming must not invoke batch transcription")


class LowRiskAnalyzer:
    def analyze(self, transcript: str, final: bool, language: str = "id") -> RiskAssessment:
        return RiskAssessment(
            risk_level="low",
            signals=[],
            evidence=[],
            explanation="Tidak ada tanda penipuan.",
            recommended_action="Tetap waspada.",
        )


class CountingHighRiskAnalyzer:
    def __init__(self) -> None:
        self.calls: list[tuple[str, bool]] = []

    def analyze(
        self, transcript: str, final: bool, language: str = "id"
    ) -> RiskAssessment:
        self.calls.append((transcript, final))
        return RiskAssessment(
            risk_level="high_risk",
            signals=["secret_code"],
            evidence=[{"quote": "OTP", "signals": ["secret_code"]}],
            explanation="Penelepon meminta kode rahasia.",
            recommended_action="Tutup telepon sekarang.",
        )


class BlockingHighRiskAnalyzer(CountingHighRiskAnalyzer):
    def __init__(self) -> None:
        super().__init__()
        self.started = threading.Event()
        self.release = threading.Event()
        self.finished = threading.Event()

    def analyze(
        self, transcript: str, final: bool, language: str = "id"
    ) -> RiskAssessment:
        self.started.set()
        self.release.wait(timeout=2)
        result = super().analyze(transcript, final, language)
        self.finished.set()
        return result


class RecordingPushSender:
    def __init__(self) -> None:
        self.sent: list[tuple[list[str], str, str, str, bool]] = []

    def send(
        self,
        tokens: list[str],
        title: str,
        body: str,
        alert_id: str,
        urgent: bool = False,
    ) -> None:
        self.sent.append((tokens, title, body, alert_id, urgent))

    def close(self) -> None:
        pass


class FakeBridgeStream:
    def __init__(
        self,
        *,
        fail_before_ready: bool = False,
        fail_after_ready: bool = False,
    ) -> None:
        self.events: asyncio.Queue[dict] = asyncio.Queue()
        self.audio: list[bytes] = []
        self.closed = False
        self.language: str | None = None
        self.fail_before_ready = fail_before_ready
        self.fail_after_ready = fail_after_ready

    async def start(self, language: str):
        self.language = language
        if self.fail_before_ready:
            await self.events.put({"type": "error", "code": "provider_unavailable"})
        else:
            await self.events.put({"type": "ready"})
        return self

    async def send_audio(self, value: bytes) -> None:
        self.audio.append(value)
        if self.fail_after_ready:
            await self.events.put({"type": "error", "code": "provider_unavailable"})
            return
        if len(self.audio) == 1:
            await self.events.put({"type": "partial", "text": "OTP 123456"})
        else:
            await self.events.put(
                {"type": "final", "text": "OTP 123456", "sequence": 0}
            )

    async def finish(self) -> None:
        await self.events.put({"type": "complete"})

    async def receive(self) -> dict:
        return await self.events.get()

    async def close(self) -> None:
        self.closed = True


class PartialBridgeStream(FakeBridgeStream):
    def __init__(self, texts: list[str]) -> None:
        super().__init__()
        self.texts = texts

    async def send_audio(self, value: bytes) -> None:
        self.audio.append(value)
        index = min(len(self.audio) - 1, len(self.texts) - 1)
        await self.events.put({"type": "partial", "text": self.texts[index]})


def configured_client(
    fake: FakeBridgeStream,
    *,
    max_streams: int = 4,
    stream_idle_seconds: float = 45,
    stream_max_seconds: float = 900,
    stream_analysis_seconds: float | None = None,
    analyzer=None,
    analysis_executor=None,
    threaded_analysis: bool = False,
    push_sender=None,
):
    store = PilotStore(":memory:")
    parent = store.create_family("Ibu Ratna")
    puck = store.pair_puck(parent.invite_code or "", "Rambu Puck")
    store.register_push_token(parent.access_token, "aa" * 32, "sandbox", "en")
    session, _ = store.create_puck_protection_session(
        puck.access_token,
        "7F011753-8F09-4A45-8812-8A4591A96B3C",
        datetime(2026, 10, 1, 10, 0, tzinfo=UTC),
        "whatsapp",
    )
    protection = ProtectionService(
        store,
        UnusedTranscriber(),
        analyzer or LowRiskAnalyzer(),
        None if threaded_analysis else (analysis_executor or ImmediateExecutor()),
    )
    app = create_app(
        service=StubDemoService(),
        pilot_store=store,
        protection_service=protection,
        push_sender=push_sender,
        stream_factory=fake.start,
        stream_capacity=StreamCapacity(max_streams),
        stream_idle_seconds=stream_idle_seconds,
        stream_max_seconds=stream_max_seconds,
        stream_analysis_seconds=stream_analysis_seconds,
    )
    return TestClient(app), store, parent, puck, session


def test_continuous_partial_speech_emits_a_live_assessed_snapshot() -> None:
    fake = PartialBridgeStream(["Tolong kirim OTP 123456"])
    analyzer = CountingHighRiskAnalyzer()
    pushes = RecordingPushSender()
    client, store, _, puck, session = configured_client(
        fake,
        analyzer=analyzer,
        push_sender=pushes,
        stream_analysis_seconds=0.01,
    )

    with client.websocket_connect(
        f"/api/pucks/sessions/{session.id}/stream",
        headers={"authorization": f"Bearer {puck.access_token}"},
    ) as socket:
        assert socket.receive_json() == {"type": "ready"}
        socket.send_bytes(b"\x00\x00" * 1600)
        assert socket.receive_json() == {
            "type": "partial",
            "text": "Tolong kirim OTP [KODE]",
        }
        assessed = socket.receive_json()
        assert assessed["type"] == "snapshot"
        assert assessed["snapshot"]["assessment"]["risk_level"] == "high_risk"
        assert assessed["snapshot"]["masked_transcript"] == ""

        socket.send_bytes(b"\x01\x00" * 1600)
        assert socket.receive_json()["type"] == "partial"
        time.sleep(0.03)
        assert analyzer.calls == [("Tolong kirim OTP [KODE]", False)]

        socket.send_json({"type": "finish"})
        assert socket.receive_json()["type"] == "snapshot"
        assert socket.receive_json() == {"type": "complete"}

    persisted = store.get_puck_protection_session(puck.access_token, session.id)
    assert persisted.masked_transcript == ""
    assert len(pushes.sent) == 1


def test_provider_final_after_preview_is_persisted_once() -> None:
    fake = FakeBridgeStream()
    analyzer = CountingHighRiskAnalyzer()
    client, store, _, puck, session = configured_client(
        fake,
        analyzer=analyzer,
        push_sender=RecordingPushSender(),
        stream_analysis_seconds=0.01,
    )

    with client.websocket_connect(
        f"/api/pucks/sessions/{session.id}/stream",
        headers={"authorization": f"Bearer {puck.access_token}"},
    ) as socket:
        assert socket.receive_json() == {"type": "ready"}
        socket.send_bytes(b"\x00\x00" * 1600)
        assert socket.receive_json()["type"] == "partial"
        assert socket.receive_json()["snapshot"]["assessment"]["risk_level"] == "high_risk"

        socket.send_bytes(b"\x01\x00" * 1600)
        stable = socket.receive_json()
        assert stable["type"] == "snapshot"
        assert stable["snapshot"]["masked_transcript"] == "OTP [KODE]"

        socket.send_json({"type": "finish"})
        assert socket.receive_json()["snapshot"]["status"] == "completed"
        assert socket.receive_json() == {"type": "complete"}

    persisted = store.get_puck_protection_session(puck.access_token, session.id)
    assert persisted.masked_transcript == "OTP [KODE]"
    assert analyzer.calls == [("OTP [KODE]", False), ("OTP [KODE]", True)]


def test_late_assessment_after_completion_does_not_touch_closed_socket(caplog) -> None:
    fake = PartialBridgeStream(["Tolong kirim OTP 123456"])
    analyzer = BlockingHighRiskAnalyzer()
    client, _, _, puck, session = configured_client(
        fake,
        analyzer=analyzer,
        threaded_analysis=True,
        push_sender=RecordingPushSender(),
        stream_analysis_seconds=0.01,
    )

    with client.websocket_connect(
        f"/api/pucks/sessions/{session.id}/stream",
        headers={"authorization": f"Bearer {puck.access_token}"},
    ) as socket:
        assert socket.receive_json() == {"type": "ready"}
        socket.send_bytes(b"\x00\x00" * 1600)
        assert socket.receive_json()["type"] == "partial"
        assert analyzer.started.wait(timeout=1)
        socket.send_json({"type": "finish"})
        assert socket.receive_json()["snapshot"]["status"] == "completed"
        assert socket.receive_json() == {"type": "complete"}

    analyzer.release.set()
    assert analyzer.finished.wait(timeout=1)
    time.sleep(0.05)
    assert "analysis failed" not in caplog.text


@pytest.mark.parametrize("stream_analysis_seconds", [0, -1])
def test_stream_analysis_interval_must_be_positive(
    stream_analysis_seconds: float,
) -> None:
    with pytest.raises(ValueError, match="analysis interval must be positive"):
        configured_client(
            FakeBridgeStream(),
            stream_analysis_seconds=stream_analysis_seconds,
        )


def test_authenticated_stream_forwards_pcm_masks_partials_and_persists_finals() -> None:
    fake = FakeBridgeStream()
    client, store, _, puck, session = configured_client(fake)

    with client.websocket_connect(
        f"/api/pucks/sessions/{session.id}/stream",
        headers={"authorization": f"Bearer {puck.access_token}"},
    ) as socket:
        assert socket.receive_json() == {"type": "ready"}
        assert fake.language == "en"

        socket.send_bytes(b"\x00\x00" * 1600)
        assert socket.receive_json() == {"type": "partial", "text": "OTP [KODE]"}
        assert store.get_puck_protection_session(
            puck.access_token, session.id
        ).masked_transcript == ""

        socket.send_bytes(b"\x01\x00" * 1600)
        stable = socket.receive_json()
        assert stable["type"] == "snapshot"
        assert stable["snapshot"]["masked_transcript"] == "OTP [KODE]"

        socket.send_json({"type": "finish"})
        completed = socket.receive_json()
        assert completed["type"] == "snapshot"
        assert completed["snapshot"]["status"] == "completed"
        assert socket.receive_json() == {"type": "complete"}

    assert fake.audio == [b"\x00\x00" * 1600, b"\x01\x00" * 1600]
    assert fake.closed is True


def test_accepted_audio_refreshes_the_puck_session_lease() -> None:
    fake = FakeBridgeStream()
    client, store, _, puck, session = configured_client(fake)
    stale = datetime.now(UTC) - timedelta(minutes=5)
    store._connection.execute(
        "UPDATE protection_sessions SET last_activity_at = ? WHERE id = ?",
        (stale.isoformat(), session.id),
    )

    with client.websocket_connect(
        f"/api/pucks/sessions/{session.id}/stream",
        headers={"authorization": f"Bearer {puck.access_token}"},
    ) as socket:
        assert socket.receive_json() == {"type": "ready"}
        socket.send_bytes(b"\x00\x00" * 1600)
        assert socket.receive_json()["type"] == "partial"
        socket.send_json({"type": "finish"})
        assert socket.receive_json()["type"] == "snapshot"
        assert socket.receive_json() == {"type": "complete"}

    touched = store._connection.execute(
        "SELECT last_activity_at FROM protection_sessions WHERE id = ?",
        (session.id,),
    ).fetchone()[0]
    assert datetime.fromisoformat(touched) > stale


def test_missing_bearer_is_closed_without_opening_provider() -> None:
    fake = FakeBridgeStream()
    client, _, _, _, session = configured_client(fake)

    with pytest.raises(WebSocketDisconnect) as captured:
        with client.websocket_connect(f"/api/pucks/sessions/{session.id}/stream"):
            pass

    assert captured.value.code == 4401
    assert fake.language is None


def test_provider_failure_is_safe_and_marks_pre_ready_retryable() -> None:
    fake = FakeBridgeStream(fail_before_ready=True)
    client, _, _, puck, session = configured_client(fake)

    with client.websocket_connect(
        f"/api/pucks/sessions/{session.id}/stream",
        headers={"authorization": f"Bearer {puck.access_token}"},
    ) as socket:
        assert socket.receive_json() == {
            "type": "error",
            "code": "transcription_unavailable",
            "retryable": True,
        }
        with pytest.raises(WebSocketDisconnect):
            socket.receive_json()


def test_oversized_pcm_frame_closes_safely() -> None:
    fake = FakeBridgeStream()
    client, _, _, puck, session = configured_client(fake)

    with client.websocket_connect(
        f"/api/pucks/sessions/{session.id}/stream",
        headers={"authorization": f"Bearer {puck.access_token}"},
    ) as socket:
        assert socket.receive_json() == {"type": "ready"}
        socket.send_bytes(b"\x00" * 16_386)
        assert socket.receive_json() == {
            "type": "error",
            "code": "invalid_audio",
            "retryable": False,
        }


def test_stream_capacity_defaults_to_four_and_releases_slots() -> None:
    async def exercise() -> None:
        capacity = StreamCapacity(4)
        assert [await capacity.acquire() for _ in range(4)] == [True] * 4
        assert await capacity.acquire() is False
        await capacity.release()
        assert await capacity.acquire() is True

    asyncio.run(exercise())


def test_stream_capacity_rejects_a_second_stream_for_the_same_session() -> None:
    async def exercise() -> None:
        capacity = StreamCapacity(4)
        assert await capacity.acquire("session-1") is True
        assert await capacity.acquire("session-1") is False
        assert await capacity.acquire("session-2") is True
        await capacity.release("session-1")
        assert await capacity.acquire("session-1") is True

    asyncio.run(exercise())


def test_idle_stream_is_closed_and_releases_provider() -> None:
    fake = FakeBridgeStream()
    client, store, _, puck, session = configured_client(fake, stream_idle_seconds=0.01)

    with client.websocket_connect(
        f"/api/pucks/sessions/{session.id}/stream",
        headers={"authorization": f"Bearer {puck.access_token}"},
    ) as socket:
        assert socket.receive_json() == {"type": "ready"}
        assert socket.receive_json() == {
            "type": "error",
            "code": "idle_timeout",
            "retryable": False,
        }

    assert fake.closed is True
    failed = store.get_puck_protection_session(puck.access_token, session.id)
    assert failed.status == "error"
    assert failed.failure is not None
    assert failed.failure.code == "stream_interrupted"


def test_provider_failure_after_ready_marks_session_failed() -> None:
    fake = FakeBridgeStream(fail_after_ready=True)
    client, store, _, puck, session = configured_client(fake)

    with client.websocket_connect(
        f"/api/pucks/sessions/{session.id}/stream",
        headers={"authorization": f"Bearer {puck.access_token}"},
    ) as socket:
        assert socket.receive_json() == {"type": "ready"}
        socket.send_bytes(b"\x00\x00" * 1600)
        assert socket.receive_json() == {
            "type": "error",
            "code": "transcription_unavailable",
            "retryable": False,
        }

    failed = store.get_puck_protection_session(puck.access_token, session.id)
    assert failed.status == "error"
    assert failed.failure is not None
    assert failed.failure.code == "stream_interrupted"


def test_stream_has_a_hard_duration_limit() -> None:
    fake = FakeBridgeStream()
    client, store, _, puck, session = configured_client(
        fake,
        stream_idle_seconds=1,
        stream_max_seconds=0.01,
    )

    with client.websocket_connect(
        f"/api/pucks/sessions/{session.id}/stream",
        headers={"authorization": f"Bearer {puck.access_token}"},
    ) as socket:
        assert socket.receive_json() == {"type": "ready"}
        assert socket.receive_json() == {
            "type": "error",
            "code": "stream_duration_exceeded",
            "retryable": False,
        }

    assert store.get_puck_protection_session(puck.access_token, session.id).status == "error"
