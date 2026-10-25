import threading
import time
from pathlib import Path
from datetime import UTC, datetime, timedelta
from uuid import uuid4

from fastapi.testclient import TestClient

from rambu_api.app import create_app
from rambu_api.langflow_client import LangflowFailure
from rambu_api.models import ProtectionFailure, RiskAssessment
from rambu_api.pilot import PilotStore
from rambu_api.protection import ProtectionService

from .conftest import ImmediateExecutor, wav_bytes
from .test_api import StubDemoService


class TextTranscriber:
    def __init__(self, text: str = "Halo") -> None:
        self.text = text
        self.calls = 0
        self.languages: list[str] = []

    def transcribe(self, path: Path, language: str = "id") -> str:
        self.calls += 1
        self.languages.append(language)
        return self.text


class LowRiskAnalyzer:
    def __init__(self, error: Exception | None = None) -> None:
        self.error = error
        self.languages: list[str] = []

    def analyze(self, transcript: str, final: bool, language: str = "id") -> RiskAssessment:
        self.languages.append(language)
        if self.error is not None:
            raise self.error
        return RiskAssessment(
            risk_level="low",
            signals=[],
            evidence=[],
            explanation="Tidak ada tanda penipuan.",
            recommended_action="Tetap waspada.",
        )


class HighRiskAnalyzer:
    def analyze(
        self, transcript: str, final: bool, language: str = "id"
    ) -> RiskAssessment:
        return RiskAssessment(
            risk_level="high_risk",
            signals=["secret_code", "transfer"],
            evidence=[
                {"quote": "Halo", "signals": ["secret_code", "transfer"]},
            ],
            explanation="Penelepon meminta kode dan transfer.",
            recommended_action="Tutup telepon sekarang.",
        )


class SequenceAnalyzer:
    def __init__(self, values: list[RiskAssessment | Exception]) -> None:
        self.values = values

    def analyze(
        self, transcript: str, final: bool, language: str = "id"
    ) -> RiskAssessment:
        value = self.values.pop(0)
        if isinstance(value, Exception):
            raise value
        return value


class BlockingAnalyzer:
    def __init__(self) -> None:
        self.release = threading.Event()

    def analyze(
        self, transcript: str, final: bool, language: str = "id"
    ) -> RiskAssessment:
        self.release.wait(timeout=5)
        return danger_assessment()


class RecordingProtectionPushSender:
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


def auth(token: str) -> dict[str, str]:
    return {"authorization": f"Bearer {token}"}


def session_payload(call_id: str = "7f011753-8f09-4a45-8812-8a4591a96b3c") -> dict:
    return {
        "call_id": call_id,
        "started_at": "2026-10-01T10:00:00Z",
        "channel": None,
    }


def build_client(
    *, analyzer: LowRiskAnalyzer | HighRiskAnalyzer | SequenceAnalyzer | BlockingAnalyzer | None = None,
    push_sender: RecordingProtectionPushSender | None = None,
    threaded_analysis: bool = False,
) -> tuple[TestClient, PilotStore, TextTranscriber, ProtectionService]:
    store = PilotStore(":memory:")
    transcriber = TextTranscriber()
    protection = ProtectionService(
        store,
        transcriber,
        analyzer or LowRiskAnalyzer(),
        None if threaded_analysis else ImmediateExecutor(),
    )
    app = create_app(
        service=StubDemoService(),
        pilot_store=store,
        protection_service=protection,
        push_sender=push_sender,
    )
    return TestClient(app), store, transcriber, protection


def review_assessment() -> RiskAssessment:
    return RiskAssessment(
        risk_level="needs_review",
        signals=["impersonation"],
        evidence=[{"quote": "Halo", "signals": ["impersonation"]}],
        explanation="Penelepon mengaku dari bank.",
        recommended_action="Verifikasi melalui kanal resmi.",
    )


def danger_assessment() -> RiskAssessment:
    return RiskAssessment(
        risk_level="high_risk",
        signals=["secret_code", "transfer"],
        evidence=[{"quote": "Halo", "signals": ["secret_code", "transfer"]}],
        explanation="Penelepon meminta kode dan transfer.",
        recommended_action="Tutup telepon sekarang.",
    )


def upload_chunk(
    client: TestClient,
    puck_token: str,
    session_id: str,
    *,
    sequence: int,
    final: bool = False,
):
    return client.post(
        f"/api/pucks/sessions/{session_id}/chunks",
        headers={
            **auth(puck_token),
            "content-type": "audio/wav",
            "x-rambu-sequence": str(sequence),
            "x-rambu-final": str(final).lower(),
        },
        content=wav_bytes(),
    )


def finish_store_session(
    store: PilotStore,
    parent_token: str,
    puck_token: str,
    *,
    call_id: str,
    started_at: datetime,
    assessment: RiskAssessment,
    title: str,
) -> None:
    session = store.create_protection_session(
        parent_token,
        call_id,
        started_at,
        "cellular",
        title,
        "+62 812-••••-4417",
    )
    store.active_protection_session(puck_token)
    store.record_protection_chunk(
        puck_token,
        session.id,
        sequence=0,
        digest=f"digest-{call_id}",
        masked_transcript="Halo dari pihak bank.",
        assessment=assessment,
        final=True,
    )
    ended_at = started_at + timedelta(seconds=45)
    with store._connection:
        store._connection.execute(
            "UPDATE protection_sessions SET ended_at = ? WHERE id = ?",
            (ended_at.isoformat(), session.id),
        )


def test_high_risk_chunk_pushes_parent_once_when_risk_increases() -> None:
    pushes = RecordingProtectionPushSender()
    client, store, _, _ = build_client(
        analyzer=HighRiskAnalyzer(), push_sender=pushes
    )
    parent = store.create_family("Ibu Ratna")
    store.register_push_token(parent.access_token, "aa" * 32, "sandbox")
    puck = store.pair_puck(parent.invite_code or "", "Mac")
    session = store.create_protection_session(
        parent.access_token,
        session_payload()["call_id"],
        datetime.fromisoformat("2026-10-01T10:00:00+00:00"),
        None,
    )
    store.active_protection_session(puck.access_token)
    path = f"/api/pucks/sessions/{session.id}/chunks"

    first = client.post(
        path,
        headers={
            **auth(puck.access_token),
            "content-type": "audio/wav",
            "x-rambu-sequence": "0",
            "x-rambu-final": "false",
        },
        content=wav_bytes(),
    )
    second = client.post(
        path,
        headers={
            **auth(puck.access_token),
            "content-type": "audio/wav",
            "x-rambu-sequence": "1",
            "x-rambu-final": "false",
        },
        content=wav_bytes(),
    )

    assert first.status_code == 200
    assert second.status_code == 200
    assert pushes.sent == [
        (
            ["aa" * 32],
            "Bahaya: terindikasi penipuan",
            "Jangan berikan kode atau transfer. Tutup telepon sekarang.",
            session_payload()["call_id"],
            True,
        )
    ]


def test_risky_chunk_persists_alert_and_pushes_guardian_without_parent_publish() -> None:
    pushes = RecordingProtectionPushSender()
    client, store, _, _ = build_client(
        analyzer=HighRiskAnalyzer(), push_sender=pushes
    )
    parent = store.create_family("Ibu Ratna")
    guardian = store.join_family(parent.invite_code or "", "Richard", "Anak")
    store.register_push_token(parent.access_token, "aa" * 32, "sandbox")
    store.register_push_token(guardian.access_token, "bb" * 32, "sandbox")
    puck = store.pair_puck(parent.invite_code or "", "Mac")
    session = store.create_protection_session(
        parent.access_token,
        session_payload()["call_id"],
        datetime.fromisoformat("2026-10-01T10:00:00+00:00"),
        "cellular",
        "Panggilan terdeteksi",
        "+62 812-••••-4417",
    )
    store.active_protection_session(puck.access_token)

    response = upload_chunk(client, puck.access_token, session.id, sequence=0)
    alerts = client.get(
        "/api/pilot/alerts", headers=auth(guardian.access_token)
    ).json()

    assert response.status_code == 200
    assert len(alerts) == 1
    assert alerts[0]["id"] == session_payload()["call_id"]
    assert alerts[0]["level"] == "danger"
    assert alerts[0]["evidence"][0]["speaker"] == "unknown"
    assert [sent[0] for sent in pushes.sent].count(["aa" * 32]) == 1
    assert [sent[0] for sent in pushes.sent].count(["bb" * 32]) == 1
    assert all(sent[4] is True for sent in pushes.sent)


def test_all_risky_chunks_use_red_and_notify_guardian_once() -> None:
    pushes = RecordingProtectionPushSender()
    analyzer = SequenceAnalyzer(
        [review_assessment(), danger_assessment(), danger_assessment()]
    )
    client, store, _, _ = build_client(analyzer=analyzer, push_sender=pushes)
    parent = store.create_family("Ibu Ratna")
    guardian = store.join_family(parent.invite_code or "", "Richard", "Anak")
    store.register_push_token(parent.access_token, "aa" * 32, "sandbox")
    store.register_push_token(guardian.access_token, "bb" * 32, "sandbox")
    puck = store.pair_puck(parent.invite_code or "", "Mac")
    session = store.create_protection_session(
        parent.access_token,
        session_payload()["call_id"],
        datetime.fromisoformat("2026-10-01T10:00:00+00:00"),
        "cellular",
    )
    store.active_protection_session(puck.access_token)

    assert upload_chunk(client, puck.access_token, session.id, sequence=0).status_code == 200
    assert upload_chunk(client, puck.access_token, session.id, sequence=1).status_code == 200
    assert upload_chunk(client, puck.access_token, session.id, sequence=2).status_code == 200

    guardian_pushes = [sent for sent in pushes.sent if sent[0] == ["bb" * 32]]
    assert len(guardian_pushes) == 1
    assert "Danger" in guardian_pushes[0][1]
    assert guardian_pushes[0][4] is True
    alerts = client.get(
        "/api/pilot/alerts", headers=auth(guardian.access_token)
    ).json()
    assert alerts[0]["level"] == "danger"


def test_safe_chunk_creates_history_but_no_alert_or_guardian_push() -> None:
    pushes = RecordingProtectionPushSender()
    client, store, _, _ = build_client(push_sender=pushes)
    parent = store.create_family("Ibu Ratna")
    guardian = store.join_family(parent.invite_code or "", "Richard", "Anak")
    store.register_push_token(guardian.access_token, "bb" * 32, "sandbox")
    puck = store.pair_puck(parent.invite_code or "", "Mac")
    session = store.create_protection_session(
        parent.access_token,
        session_payload()["call_id"],
        datetime.fromisoformat("2026-10-01T10:00:00+00:00"),
        "cellular",
    )
    store.active_protection_session(puck.access_token)

    response = upload_chunk(
        client, puck.access_token, session.id, sequence=0, final=True
    )

    assert response.status_code == 200
    assert client.get(
        "/api/pilot/alerts", headers=auth(guardian.access_token)
    ).json() == []
    history = client.get(
        "/api/pilot/history", headers=auth(guardian.access_token)
    ).json()
    assert history[0]["presentation"] == "safe"
    assert pushes.sent == []


def test_terminal_chunk_and_analysis_failure_end_existing_alert() -> None:
    pushes = RecordingProtectionPushSender()
    client, store, _, _ = build_client(
        analyzer=SequenceAnalyzer([danger_assessment(), danger_assessment()]),
        push_sender=pushes,
    )
    parent = store.create_family("Ibu Ratna")
    guardian = store.join_family(parent.invite_code or "", "Richard", "Anak")
    puck = store.pair_puck(parent.invite_code or "", "Mac")
    session = store.create_protection_session(
        parent.access_token,
        session_payload()["call_id"],
        datetime.fromisoformat("2026-10-01T10:00:00+00:00"),
        "cellular",
    )
    store.active_protection_session(puck.access_token)
    assert upload_chunk(client, puck.access_token, session.id, sequence=0).status_code == 200
    assert upload_chunk(
        client, puck.access_token, session.id, sequence=1, final=True
    ).status_code == 200
    ended = client.get(
        "/api/pilot/alerts", headers=auth(guardian.access_token)
    ).json()[0]
    assert ended["call_ended"] is True

    failure_pushes = RecordingProtectionPushSender()
    failure = LangflowFailure("timeout", "Analisis gagal.", "provider timeout")
    failed_client, failed_store, _, _ = build_client(
        analyzer=SequenceAnalyzer([danger_assessment(), failure]),
        push_sender=failure_pushes,
    )
    failed_parent = failed_store.create_family("Ibu Ratna")
    failed_guardian = failed_store.join_family(
        failed_parent.invite_code or "", "Richard", "Anak"
    )
    failed_puck = failed_store.pair_puck(failed_parent.invite_code or "", "Mac")
    failed_session = failed_store.create_protection_session(
        failed_parent.access_token,
        "30000000-0000-0000-0000-000000000001",
        datetime.fromisoformat("2026-10-01T10:00:00+00:00"),
        "cellular",
    )
    failed_store.active_protection_session(failed_puck.access_token)
    assert upload_chunk(
        failed_client, failed_puck.access_token, failed_session.id, sequence=0
    ).status_code == 200
    assert upload_chunk(
        failed_client, failed_puck.access_token, failed_session.id, sequence=1
    ).status_code == 200
    failed_alert = failed_client.get(
        "/api/pilot/alerts", headers=auth(failed_guardian.access_token)
    ).json()[0]
    assert failed_alert["call_ended"] is True


def test_retried_risky_chunk_idempotently_repairs_alert_without_duplicate_push() -> None:
    pushes = RecordingProtectionPushSender()
    client, store, transcriber, protection = build_client(
        analyzer=HighRiskAnalyzer(), push_sender=pushes
    )
    parent = store.create_family("Ibu Ratna")
    guardian = store.join_family(parent.invite_code or "", "Richard", "Anak")
    store.register_push_token(guardian.access_token, "bb" * 32, "sandbox")
    puck = store.pair_puck(parent.invite_code or "", "Mac")
    session = store.create_protection_session(
        parent.access_token,
        session_payload()["call_id"],
        datetime.fromisoformat("2026-10-01T10:00:00+00:00"),
        "cellular",
    )
    store.active_protection_session(puck.access_token)
    audio = wav_bytes()
    protection.process_chunk(puck.access_token, session.id, 0, False, audio)

    response = client.post(
        f"/api/pucks/sessions/{session.id}/chunks",
        headers={
            **auth(puck.access_token),
            "content-type": "audio/wav",
            "x-rambu-sequence": "0",
            "x-rambu-final": "false",
        },
        content=audio,
    )

    assert response.status_code == 200
    assert transcriber.calls == 1
    alerts = client.get(
        "/api/pilot/alerts", headers=auth(guardian.access_token)
    ).json()
    assert len(alerts) == 1
    assert [sent[0] for sent in pushes.sent].count(["bb" * 32]) == 1


def test_parent_and_guardian_share_safe_review_danger_and_unassessed_history() -> None:
    client, store, _, _ = build_client()
    parent = store.create_family("Ibu Ratna")
    guardian = store.join_family(parent.invite_code or "", "Richard", "Anak")
    puck = store.pair_puck(parent.invite_code or "", "Mac")
    start = datetime(2026, 10, 3, 10, 0, tzinfo=UTC)

    finish_store_session(
        store,
        parent.access_token,
        puck.access_token,
        call_id="10000000-0000-0000-0000-000000000001",
        started_at=start,
        title="Telepon aman",
        assessment=RiskAssessment(
            risk_level="low",
            signals=[],
            evidence=[],
            explanation="Tidak ada tanda penipuan.",
            recommended_action="Tetap waspada.",
        ),
    )
    finish_store_session(
        store,
        parent.access_token,
        puck.access_token,
        call_id="10000000-0000-0000-0000-000000000002",
        started_at=start + timedelta(minutes=1),
        title="Telepon perlu ditinjau",
        assessment=RiskAssessment(
            risk_level="needs_review",
            signals=["impersonation"],
            evidence=[{"quote": "pihak bank", "signals": ["impersonation"]}],
            explanation="Penelepon mengaku dari bank.",
            recommended_action="Verifikasi melalui kanal resmi.",
        ),
    )
    finish_store_session(
        store,
        parent.access_token,
        puck.access_token,
        call_id="10000000-0000-0000-0000-000000000003",
        started_at=start + timedelta(minutes=2),
        title="Telepon bahaya",
        assessment=RiskAssessment(
            risk_level="high_risk",
            signals=["secret_code", "remote_app"],
            evidence=[
                {"quote": "Halo", "signals": ["secret_code"]},
                {"quote": "pihak bank", "signals": ["remote_app"]},
            ],
            explanation="Penelepon meminta akses sensitif.",
            recommended_action="Tutup telepon sekarang.",
        ),
    )
    no_speech = store.create_protection_session(
        parent.access_token,
        "10000000-0000-0000-0000-000000000004",
        start + timedelta(minutes=3),
        "cellular",
        "Tidak terdengar",
        "Nomor tidak tersedia",
    )
    store.request_protection_end(parent.access_token, no_speech.id)
    failed = store.create_protection_session(
        parent.access_token,
        "10000000-0000-0000-0000-000000000005",
        start + timedelta(minutes=4),
        "cellular",
        "Analisis gagal",
        "Nomor tidak tersedia",
    )
    store.active_protection_session(puck.access_token)
    store.fail_protection_session(
        puck.access_token,
        failed.id,
        ProtectionFailure(code="analysis_timeout", message="Analisis panggilan gagal."),
    )

    parent_response = client.get(
        "/api/pilot/history", headers=auth(parent.access_token)
    )
    guardian_response = client.get(
        "/api/pilot/history", headers=auth(guardian.access_token)
    )

    assert parent_response.status_code == 200
    assert guardian_response.status_code == 200
    assert guardian_response.json() == parent_response.json()
    records = {record["title"]: record for record in parent_response.json()}
    assert records["Telepon aman"]["presentation"] == "safe"
    assert records["Telepon perlu ditinjau"]["presentation"] == "danger"
    assert records["Telepon bahaya"]["presentation"] == "danger"
    assert records["Telepon bahaya"]["signals"] == ["secretCode", "remoteApp"]
    assert records["Telepon bahaya"]["evidence"] == [
        {
            "id": 0,
            "offset": None,
            "speaker": "unknown",
            "text": "Halo",
            "flagged": ["Halo"],
            "signals": ["secretCode"],
        },
        {
            "id": 1,
            "offset": None,
            "speaker": "unknown",
            "text": "pihak bank",
            "flagged": ["pihak bank"],
            "signals": ["remoteApp"],
        },
    ]
    assert records["Telepon bahaya"]["duration_seconds"] == 45.0
    assert records["Tidak terdengar"]["outcome"] == "no_speech"
    assert records["Tidak terdengar"]["presentation"] == "unassessed"
    assert records["Tidak terdengar"]["signals"] == []
    assert records["Tidak terdengar"]["evidence"] == []
    assert records["Analisis gagal"]["outcome"] == "error"
    assert records["Analisis gagal"]["presentation"] == "unassessed"
    assert records["Analisis gagal"]["failure"] == {
        "code": "analysis_timeout",
        "message": "Analisis panggilan gagal.",
    }
    assert records["Analisis gagal"]["signals"] == []
    assert records["Analisis gagal"]["evidence"] == []


def test_history_excludes_active_sessions_and_isolates_families() -> None:
    client, store, _, _ = build_client()
    first_parent = store.create_family("Ibu Ratna")
    first_guardian = store.join_family(first_parent.invite_code or "", "Richard", "Anak")
    first_puck = store.pair_puck(first_parent.invite_code or "", "Mac pertama")
    second_parent = store.create_family("Bapak Budi")
    start = datetime(2026, 10, 3, 10, 0, tzinfo=UTC)

    finish_store_session(
        store,
        first_parent.access_token,
        first_puck.access_token,
        call_id="20000000-0000-0000-0000-000000000001",
        started_at=start,
        title="Selesai keluarga pertama",
        assessment=RiskAssessment(
            risk_level="low",
            signals=[],
            evidence=[],
            explanation="Aman.",
            recommended_action="Tetap waspada.",
        ),
    )
    store.create_protection_session(
        first_parent.access_token,
        "20000000-0000-0000-0000-000000000002",
        start + timedelta(minutes=1),
        "cellular",
        "Masih aktif",
        "Nomor tidak tersedia",
    )
    other = store.create_protection_session(
        second_parent.access_token,
        "20000000-0000-0000-0000-000000000003",
        start + timedelta(minutes=2),
        "cellular",
        "Keluarga lain",
        "Nomor tidak tersedia",
    )
    store.request_protection_end(second_parent.access_token, other.id)

    response = client.get(
        "/api/pilot/history", headers=auth(first_guardian.access_token)
    )

    assert response.status_code == 200
    assert [record["title"] for record in response.json()] == [
        "Selesai keluarga pertama"
    ]


def test_history_is_newest_first_and_limited_to_one_hundred() -> None:
    client, store, _, _ = build_client()
    parent = store.create_family("Ibu Ratna")
    start = datetime(2026, 10, 1, 10, 0, tzinfo=UTC)
    call_ids: list[str] = []

    for index in range(101):
        call_id = str(uuid4())
        call_ids.append(call_id)
        session = store.create_protection_session(
            parent.access_token,
            call_id,
            start + timedelta(minutes=index),
            "cellular",
            f"Telepon {index}",
            "Nomor tidak tersedia",
        )
        store.request_protection_end(parent.access_token, session.id)

    response = client.get("/api/pilot/history", headers=auth(parent.access_token))

    assert response.status_code == 200
    assert len(response.json()) == 100
    assert response.json()[0]["id"] == call_ids[-1]
    assert response.json()[-1]["id"] == call_ids[1]


def test_protection_routes_complete_authenticated_parent_and_puck_flow() -> None:
    client, store, _, _ = build_client()
    parent = store.create_family("Ibu Ratna")

    paired_response = client.post(
        "/api/pucks/pair",
        json={"code": parent.invite_code, "display_name": "Mac ruang tamu"},
    )
    assert paired_response.status_code == 201
    puck_token = paired_response.json()["access_token"]

    created_response = client.post(
        "/api/protection/sessions",
        headers=auth(parent.access_token),
        json=session_payload(),
    )
    assert created_response.status_code == 201
    session_id = created_response.json()["id"]
    assert created_response.json()["status"] == "waiting_for_puck"

    repeated = client.post(
        "/api/protection/sessions",
        headers=auth(parent.access_token),
        json=session_payload(),
    )
    assert repeated.status_code == 201
    assert repeated.json()["id"] == session_id

    claimed = client.get("/api/pucks/sessions/active", headers=auth(puck_token))
    assert claimed.status_code == 200
    assert claimed.json()["status"] == "listening"

    chunk = client.post(
        f"/api/pucks/sessions/{session_id}/chunks",
        headers={
            **auth(puck_token),
            "content-type": "audio/wav",
            "x-rambu-sequence": "0",
            "x-rambu-final": "false",
        },
        content=wav_bytes(),
    )
    assert chunk.status_code == 200
    assert chunk.json()["masked_transcript"] == "Halo"

    status = client.get(
        f"/api/protection/sessions/{session_id}", headers=auth(parent.access_token)
    )
    assert status.status_code == 200
    assert status.json()["assessment"]["risk_level"] == "low"

    ending = client.post(
        f"/api/protection/sessions/{session_id}/end", headers=auth(parent.access_token)
    )
    assert ending.status_code == 200
    assert ending.json()["end_requested"] is True

    final = client.post(
        f"/api/pucks/sessions/{session_id}/chunks",
        headers={
            **auth(puck_token),
            "content-type": "audio/wav",
            "x-rambu-sequence": "1",
            "x-rambu-final": "true",
        },
        content=wav_bytes(seconds=0),
    )
    assert final.status_code == 200
    assert final.json()["status"] == "completed"

    deleted = client.delete(
        f"/api/protection/sessions/{session_id}", headers=auth(parent.access_token)
    )
    assert deleted.status_code == 204


def test_english_protection_session_persists_and_drives_detection_language() -> None:
    analyzer = LowRiskAnalyzer()
    client, store, transcriber, _ = build_client(analyzer=analyzer)
    parent = store.create_family("Mrs Taylor")
    puck = store.pair_puck(parent.invite_code or "", "Living room Mac")

    created = client.post(
        "/api/protection/sessions",
        headers=auth(parent.access_token),
        json={**session_payload(), "language": "en"},
    )
    assert created.status_code == 201
    assert created.json()["language"] == "en"
    claimed = client.get("/api/pucks/sessions/active", headers=auth(puck.access_token))
    assert claimed.json()["language"] == "en"

    uploaded = upload_chunk(client, puck.access_token, created.json()["id"], sequence=0)

    assert uploaded.status_code == 200
    assert transcriber.languages == ["en"]
    assert analyzer.languages == ["en"]


def test_puck_created_session_pushes_parent_once_and_not_guardian() -> None:
    pushes = RecordingProtectionPushSender()
    client, store, _, _ = build_client(push_sender=pushes)
    parent = store.create_family("Ibu Ratna")
    guardian = store.join_family(parent.invite_code or "", "Richard", "Anak")
    puck = store.pair_puck(parent.invite_code or "", "Mac")
    store.register_push_token(parent.access_token, "aa" * 32, "sandbox")
    store.register_push_token(guardian.access_token, "bb" * 32, "sandbox")
    payload = {
        **session_payload(),
        "channel": "whatsapp",
        "title": "Panggilan WhatsApp terdeteksi",
        "caller_detail": "Kontak WhatsApp",
    }

    created = client.post(
        "/api/pucks/sessions", headers=auth(puck.access_token), json=payload
    )
    repeated = client.post(
        "/api/pucks/sessions", headers=auth(puck.access_token), json=payload
    )

    assert created.status_code == 201
    assert created.json()["status"] == "listening"
    assert created.json()["puck_connected"] is True
    assert repeated.status_code == 201
    assert repeated.json()["id"] == created.json()["id"]
    assert pushes.sent == [
        (
            ["aa" * 32],
            "Panggilan WhatsApp terdeteksi",
            "Rambu Puck mulai mendengarkan dan melindungi panggilan ini.",
            session_payload()["call_id"],
            False,
        )
    ]


def test_parent_reuses_active_puck_session_instead_of_creating_a_conflict() -> None:
    client, store, _, _ = build_client()
    parent = store.create_family("Ibu Ratna")
    puck = store.pair_puck(parent.invite_code or "", "Mac")
    puck_call_id = "7f011753-8f09-4a45-8812-8a4591a96b3c"
    phone_call_id = "b2546d82-9466-4015-a663-ca10ccacffbf"

    puck_session = client.post(
        "/api/pucks/sessions",
        headers=auth(puck.access_token),
        json={
            **session_payload(puck_call_id),
            "channel": "whatsapp",
            "title": "Panggilan WhatsApp terdeteksi",
            "caller_detail": "Kontak WhatsApp",
        },
    )
    phone_session = client.post(
        "/api/protection/sessions",
        headers=auth(parent.access_token),
        json={**session_payload(phone_call_id), "channel": "cellular"},
    )

    session_count = store._connection.execute(
        "SELECT COUNT(*) FROM protection_sessions WHERE family_id = ?",
        (parent.family_id,),
    ).fetchone()[0]
    assert puck_session.status_code == 201
    assert phone_session.status_code == 201
    assert phone_session.json()["id"] == puck_session.json()["id"]
    assert phone_session.json()["call_id"] == puck_call_id
    assert phone_session.json()["status"] == "listening"
    assert session_count == 1


def test_puck_joining_parent_session_pushes_parent_once_and_not_guardian() -> None:
    pushes = RecordingProtectionPushSender()
    client, store, _, _ = build_client(push_sender=pushes)
    parent = store.create_family("Ibu Ratna")
    guardian = store.join_family(parent.invite_code or "", "Richard", "Anak")
    puck = store.pair_puck(parent.invite_code or "", "Mac")
    store.register_push_token(parent.access_token, "aa" * 32, "sandbox")
    store.register_push_token(guardian.access_token, "bb" * 32, "sandbox")

    created = client.post(
        "/api/protection/sessions",
        headers=auth(parent.access_token),
        json={**session_payload(), "channel": "whatsapp"},
    )
    first_claim = client.get(
        "/api/pucks/sessions/active", headers=auth(puck.access_token)
    )
    repeated_claim = client.get(
        "/api/pucks/sessions/active", headers=auth(puck.access_token)
    )

    assert created.status_code == 201
    assert first_claim.status_code == 200
    assert first_claim.json()["status"] == "listening"
    assert repeated_claim.status_code == 200
    assert repeated_claim.json()["id"] == first_claim.json()["id"]
    assert pushes.sent == [
        (
            ["aa" * 32],
            "Panggilan WhatsApp terdeteksi",
            "Rambu Puck mulai mendengarkan dan melindungi panggilan ini.",
            session_payload()["call_id"],
            False,
        )
    ]


def test_puck_session_route_rejects_member_credentials() -> None:
    client, store, _, _ = build_client()
    parent = store.create_family("Ibu Ratna")

    response = client.post(
        "/api/pucks/sessions",
        headers=auth(parent.access_token),
        json={**session_payload(), "channel": "whatsapp"},
    )

    assert response.status_code == 401


def test_parent_and_puck_credentials_cannot_cross_roles() -> None:
    client, store, _, _ = build_client()
    parent = store.create_family("Ibu Ratna")
    puck = store.pair_puck(parent.invite_code or "", "Mac")
    session = store.create_protection_session(
        parent.access_token,
        session_payload()["call_id"],
        datetime.fromisoformat("2026-10-01T10:00:00+00:00"),
        None,
    )

    assert client.post(
        "/api/protection/sessions", headers=auth(puck.access_token), json=session_payload()
    ).status_code == 401
    assert client.get(
        "/api/pucks/sessions/active", headers=auth(parent.access_token)
    ).status_code == 401
    assert client.post(
        f"/api/protection/sessions/{session.id}/end", headers=auth(puck.access_token)
    ).status_code == 401


def test_chunk_requires_wav_content_type_and_both_valid_headers() -> None:
    client, store, _, _ = build_client()
    parent = store.create_family("Ibu Ratna")
    puck = store.pair_puck(parent.invite_code or "", "Mac")
    session = store.create_protection_session(
        parent.access_token,
        session_payload()["call_id"],
        datetime.fromisoformat("2026-10-01T10:00:00+00:00"),
        None,
    )
    store.active_protection_session(puck.access_token)
    path = f"/api/pucks/sessions/{session.id}/chunks"

    assert client.post(path, headers=auth(puck.access_token), content=wav_bytes()).status_code == 422
    assert client.post(
        path,
        headers={**auth(puck.access_token), "content-type": "audio/wav"},
        content=wav_bytes(),
    ).status_code == 422
    assert client.post(
        path,
        headers={
            **auth(puck.access_token),
            "content-type": "audio/wav",
            "x-rambu-sequence": "zero",
            "x-rambu-final": "sometimes",
        },
        content=wav_bytes(),
    ).status_code == 422
    assert client.post(
        path,
        headers={
            **auth(puck.access_token),
            "content-type": "audio/wav",
            "x-rambu-sequence": "0",
            "x-rambu-final": "false",
        },
        content=b"0" * (1_048_576 + 1),
    ).status_code == 413


def test_chunk_retry_is_idempotent_and_sequence_conflict_is_409() -> None:
    client, store, transcriber, _ = build_client()
    parent = store.create_family("Ibu Ratna")
    puck = store.pair_puck(parent.invite_code or "", "Mac")
    session = store.create_protection_session(
        parent.access_token,
        session_payload()["call_id"],
        datetime.fromisoformat("2026-10-01T10:00:00+00:00"),
        None,
    )
    store.active_protection_session(puck.access_token)
    path = f"/api/pucks/sessions/{session.id}/chunks"
    headers = {
        **auth(puck.access_token),
        "content-type": "audio/wav",
        "x-rambu-sequence": "0",
        "x-rambu-final": "false",
    }

    assert client.post(path, headers=headers, content=wav_bytes()).status_code == 200
    assert client.post(path, headers=headers, content=wav_bytes()).status_code == 200
    assert transcriber.calls == 1
    assert client.post(path, headers=headers, content=wav_bytes(seconds=2)).status_code == 409


def test_langflow_failure_returns_sanitized_502_without_fallback() -> None:
    client, store, _, _ = build_client(
        analyzer=LowRiskAnalyzer(
            LangflowFailure(
                "timeout",
                "Langflow tidak merespons sebelum batas waktu.",
                "http://secret.internal/api/v1/run/key",
            )
        )
    )
    parent = store.create_family("Ibu Ratna")
    puck = store.pair_puck(parent.invite_code or "", "Mac")
    session = store.create_protection_session(
        parent.access_token,
        session_payload()["call_id"],
        datetime.fromisoformat("2026-10-01T10:00:00+00:00"),
        None,
    )
    store.active_protection_session(puck.access_token)

    response = client.post(
        f"/api/pucks/sessions/{session.id}/chunks",
        headers={
            **auth(puck.access_token),
            "content-type": "audio/wav",
            "x-rambu-sequence": "0",
            "x-rambu-final": "false",
        },
        content=wav_bytes(),
    )

    assert response.status_code == 200
    failed = client.get(
        f"/api/protection/sessions/{session.id}", headers=auth(parent.access_token)
    )
    assert failed.json()["status"] == "error"
    assert failed.json()["failure"] == {
        "code": "analysis_timeout",
        "message": "Langflow tidak merespons sebelum batas waktu.",
    }
    assert "secret.internal" not in failed.text


def test_untyped_analyzer_failure_uses_persisted_analysis_error_not_transcription_error() -> None:
    client, store, _, _ = build_client(
        analyzer=LowRiskAnalyzer(RuntimeError("provider implementation crashed"))
    )
    parent = store.create_family("Ibu Ratna")
    puck = store.pair_puck(parent.invite_code or "", "Mac")
    session = store.create_protection_session(
        parent.access_token,
        session_payload()["call_id"],
        datetime.fromisoformat("2026-10-01T10:00:00+00:00"),
        None,
    )
    store.active_protection_session(puck.access_token)

    response = client.post(
        f"/api/pucks/sessions/{session.id}/chunks",
        headers={
            **auth(puck.access_token),
            "content-type": "audio/wav",
            "x-rambu-sequence": "0",
            "x-rambu-final": "false",
        },
        content=wav_bytes(),
    )

    assert response.status_code == 200
    failed = client.get(
        f"/api/protection/sessions/{session.id}", headers=auth(parent.access_token)
    )
    assert failed.json()["status"] == "error"
    assert failed.json()["failure"] == {
        "code": "analysis_failed",
        "message": "Analisis panggilan gagal.",
    }
    assert "provider implementation crashed" not in failed.text


SCAM_TEXT = "Saya dari bank, sebutkan kode OTP dan transfer sekarang."


def timed_upload_chunk(client, puck_token, session_id, *, sequence, final=False):
    started = time.monotonic()
    response = upload_chunk(
        client, puck_token, session_id, sequence=sequence, final=final
    )
    return response, time.monotonic() - started


def poll_parent_session(client, parent_token, session_id, done):
    deadline = time.monotonic() + 5
    snapshot = client.get(
        f"/api/protection/sessions/{session_id}", headers=auth(parent_token)
    ).json()
    while not done(snapshot) and time.monotonic() < deadline:
        time.sleep(0.05)
        snapshot = client.get(
            f"/api/protection/sessions/{session_id}", headers=auth(parent_token)
        ).json()
    return snapshot


def blocking_analysis_setup():
    pushes = RecordingProtectionPushSender()
    analyzer = BlockingAnalyzer()
    client, store, transcriber, _ = build_client(
        analyzer=analyzer, push_sender=pushes, threaded_analysis=True
    )
    transcriber.text = SCAM_TEXT
    parent = store.create_family("Ibu Ratna")
    store.register_push_token(parent.access_token, "aa" * 32, "sandbox")
    puck = store.pair_puck(parent.invite_code or "", "Mac")
    session = store.create_protection_session(
        parent.access_token,
        session_payload()["call_id"],
        datetime.fromisoformat("2026-10-01T10:00:00+00:00"),
        "cellular",
    )
    store.active_protection_session(puck.access_token)
    return client, analyzer, pushes, parent, puck, session


def test_chunk_upload_responds_before_slow_analysis_and_analysis_completes_later() -> None:
    client, analyzer, pushes, parent, puck, session = blocking_analysis_setup()

    try:
        response, elapsed = timed_upload_chunk(
            client, puck.access_token, session.id, sequence=0
        )
    finally:
        analyzer.release.set()

    assert elapsed < 1, f"chunk upload blocked on analysis for {elapsed:.2f}s"
    assert response.status_code == 200
    assert "transfer sekarang" in response.json()["masked_transcript"]

    snapshot = poll_parent_session(
        client,
        parent.access_token,
        session.id,
        lambda value: (value["assessment"] or {}).get("risk_level") == "high_risk"
        and pushes.sent,
    )
    assert snapshot["assessment"]["risk_level"] == "high_risk"
    assert pushes.sent == [
        (
            ["aa" * 32],
            "Bahaya: terindikasi penipuan",
            "Jangan berikan kode atau transfer. Tutup telepon sekarang.",
            session_payload()["call_id"],
            True,
        )
    ]


def test_final_chunk_during_pending_analysis_ends_with_analyzed_assessment() -> None:
    client, analyzer, _, parent, puck, session = blocking_analysis_setup()

    try:
        first, first_elapsed = timed_upload_chunk(
            client, puck.access_token, session.id, sequence=0
        )
        assert first_elapsed < 1, (
            f"chunk upload blocked on analysis for {first_elapsed:.2f}s"
        )
        final, final_elapsed = timed_upload_chunk(
            client, puck.access_token, session.id, sequence=1, final=True
        )
        assert final_elapsed < 1, (
            f"final chunk upload blocked on analysis for {final_elapsed:.2f}s"
        )
    finally:
        analyzer.release.set()

    assert first.status_code == 200
    assert final.status_code == 200

    snapshot = poll_parent_session(
        client,
        parent.access_token,
        session.id,
        lambda value: value["outcome"] == "analyzed"
        and (value["assessment"] or {}).get("risk_level") == "high_risk",
    )
    assert snapshot["outcome"] == "analyzed"
    assert snapshot["assessment"]["risk_level"] == "high_risk"
