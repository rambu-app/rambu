import logging
from collections.abc import Iterator
from pathlib import Path

import pytest

from rambu_api.langflow_client import LangflowFailure
from rambu_api.models import CreateProtectionSessionRequest, RiskAssessment
from rambu_api.pilot import PilotError, PilotStore
from rambu_api.protection import ProtectionService

from .conftest import ImmediateExecutor, wav_bytes


class QueueTranscriber:
    def __init__(self, values: list[str | Exception]) -> None:
        self.values: Iterator[str | Exception] = iter(values)
        self.seen_paths: list[Path] = []

    def transcribe(self, path: Path, language: str = "id") -> str:
        assert path.exists()
        self.seen_paths.append(path)
        value = next(self.values)
        if isinstance(value, Exception):
            raise value
        return value


class RecordingAnalyzer:
    def __init__(self, error: Exception | None = None) -> None:
        self.calls: list[tuple[str, bool]] = []
        self.error = error

    def analyze(
        self, transcript: str, final: bool, language: str = "id"
    ) -> RiskAssessment:
        self.calls.append((transcript, final))
        if self.error is not None:
            raise self.error
        return RiskAssessment(
            risk_level="low",
            signals=[],
            evidence=[],
            explanation="Tidak ada tanda penipuan pada teks yang tersedia.",
            recommended_action="Tetap waspada.",
        )


class SequenceAnalyzer:
    def __init__(self, values: list[RiskAssessment | Exception]) -> None:
        self.values: Iterator[RiskAssessment | Exception] = iter(values)
        self.calls: list[tuple[str, bool]] = []

    def analyze(
        self, transcript: str, final: bool, language: str = "id"
    ) -> RiskAssessment:
        self.calls.append((transcript, final))
        value = next(self.values)
        if isinstance(value, Exception):
            raise value
        return value


class DeferredExecutor:
    def __init__(self) -> None:
        self.pending: list[tuple[object, tuple[object, ...]]] = []

    def submit(self, function, *args):
        self.pending.append((function, args))

    def run_all(self) -> None:
        while self.pending:
            function, args = self.pending.pop(0)
            function(*args)


def assessment(level: str) -> RiskAssessment:
    if level == "low":
        return RiskAssessment(
            risk_level="low",
            signals=[],
            evidence=[],
            explanation="Tidak ada tanda penipuan.",
            recommended_action="Tetap waspada.",
        )
    return RiskAssessment(
        risk_level=level,
        signals=["secret_code"],
        evidence=[{"quote": "informasi SMS", "signals": ["secret_code"]}],
        explanation="Penelepon meminta informasi rahasia dari SMS.",
        recommended_action="Akhiri panggilan dan jangan berikan informasi tersebut.",
    )


def contract_failure() -> LangflowFailure:
    return LangflowFailure(
        "invalid_response",
        "Respons Langflow tidak sesuai kontrak Rambu.",
        "http://langflow",
        reason="schema_validation",
    )


def configured_service(
    texts: list[str | Exception],
    analyzer: RecordingAnalyzer | SequenceAnalyzer | None = None,
) -> tuple[ProtectionService, PilotStore, str, str, str]:
    store = PilotStore(":memory:")
    parent = store.create_family("Ibu Ratna")
    puck = store.pair_puck(parent.invite_code or "", "Mac")
    service = ProtectionService(
        store, QueueTranscriber(texts), analyzer or RecordingAnalyzer(), ImmediateExecutor()
    )
    session = service.create_session(
        parent.access_token,
        CreateProtectionSessionRequest(
            call_id="7F011753-8F09-4A45-8812-8A4591A96B3C",
            started_at="2026-10-01T10:00:00Z",
        ),
    )
    service.get_active_puck_session(puck.access_token)
    return service, store, parent.access_token, puck.access_token, session.id


def process(service, puck_token, session_id, sequence, final, audio):
    service.process_chunk(puck_token, session_id, sequence, final, audio)
    service.analyze_latest(puck_token, session_id, lambda previous, current: None)
    return service.get_puck_session(puck_token, session_id)


def test_stream_segments_are_masked_before_persistence_and_logging(caplog) -> None:
    service, store, parent_token, puck_token, session_id = configured_service([])

    with caplog.at_level(logging.INFO, logger="uvicorn.error.rambu.transcription"):
        snapshot = service.process_stream_segment(
            puck_token,
            session_id,
            sequence=0,
            text="Nomor 081234567890 dan OTP 123456",
            final=False,
        )

    assert snapshot.masked_transcript == "Nomor [NOMOR_TELEPON] dan OTP [KODE]"
    assert "081234567890" not in caplog.text
    assert "123456" not in caplog.text
    assert "[KODE]" in caplog.text
    persisted = store.get_protection_session(parent_token, session_id)
    assert persisted.masked_transcript == snapshot.masked_transcript


def test_stream_segment_final_completion_and_duplicate_retry() -> None:
    service, _, _, puck_token, session_id = configured_service([])

    completed = service.process_stream_segment(
        puck_token,
        session_id,
        sequence=0,
        text="Selesai",
        final=True,
    )
    duplicate = service.process_stream_segment(
        puck_token,
        session_id,
        sequence=0,
        text="Selesai",
        final=True,
    )

    assert completed.status == "completed"
    assert duplicate == completed


def test_empty_non_final_stream_segment_does_not_mutate_state() -> None:
    service, store, _, puck_token, session_id = configured_service([])
    before = service.get_puck_session(puck_token, session_id)

    unchanged = service.process_stream_segment(
        puck_token,
        session_id,
        sequence=0,
        text="   ",
        final=False,
    )

    assert unchanged == before
    count = store._connection.execute(
        "SELECT COUNT(*) FROM protection_stream_segments WHERE session_id = ?",
        (session_id,),
    ).fetchone()[0]
    assert count == 0


def test_chunks_are_masked_persisted_and_analyzed_cumulatively() -> None:
    analyzer = RecordingAnalyzer()
    service, store, parent_token, puck_token, session_id = configured_service(
        ["Nomor saya 081234567890.", "Kode OTP 123456."], analyzer
    )

    first = process(service, puck_token, session_id, 0, False, wav_bytes())
    second = process(service, puck_token, session_id, 1, False, wav_bytes())

    assert analyzer.calls == [
        ("Nomor saya [NOMOR_TELEPON].", False),
        ("Nomor saya [NOMOR_TELEPON]. Kode OTP [KODE].", False),
    ]
    assert first.masked_transcript == "Nomor saya [NOMOR_TELEPON]."
    assert second.masked_transcript == "Nomor saya [NOMOR_TELEPON]. Kode OTP [KODE]."
    persisted = store.get_protection_session(parent_token, session_id)
    assert "081234567890" not in persisted.masked_transcript
    assert "123456" not in persisted.masked_transcript


def test_repeated_analysis_requests_share_one_queued_worker() -> None:
    store = PilotStore(":memory:")
    parent = store.create_family("Ibu Ratna")
    puck = store.pair_puck(parent.invite_code or "", "Rambu Puck")
    analyzer = RecordingAnalyzer()
    executor = DeferredExecutor()
    service = ProtectionService(
        store,
        QueueTranscriber(["Halo", "minta kode", "sekarang"]),
        analyzer,
        executor,
    )
    session = service.create_session(
        parent.access_token,
        CreateProtectionSessionRequest(
            call_id="7F011753-8F09-4A45-8812-8A4591A96B3C",
            started_at="2026-10-01T10:00:00Z",
        ),
    )
    service.get_active_puck_session(puck.access_token)

    for sequence in range(3):
        service.process_chunk(
            puck.access_token, session.id, sequence, False, wav_bytes()
        )
        service.analyze_latest(
            puck.access_token, session.id, lambda previous, current: None
        )

    assert len(executor.pending) == 1
    executor.run_all()
    assert analyzer.calls == [("Halo minta kode sekarang", False)]


def test_preview_analysis_masks_without_persisting_and_deduplicates() -> None:
    analyzer = RecordingAnalyzer()
    service, store, parent_token, puck_token, session_id = configured_service(
        [], analyzer
    )
    assessed = []

    for _ in range(2):
        service.analyze_latest(
            puck_token,
            session_id,
            lambda _previous, current: assessed.append(current),
            preview_text="Kirim OTP 123456",
        )

    assert analyzer.calls == [("Kirim OTP [KODE]", False)]
    assert len(assessed) == 1
    assert assessed[0].assessment is not None
    persisted = store.get_protection_session(parent_token, session_id)
    assert persisted.masked_transcript == ""
    assert "123456" not in persisted.model_dump_json()


def test_preview_analysis_coalesces_to_the_latest_changed_text() -> None:
    store = PilotStore(":memory:")
    parent = store.create_family("Ibu Ratna")
    puck = store.pair_puck(parent.invite_code or "", "Rambu Puck")
    analyzer = RecordingAnalyzer()
    executor = DeferredExecutor()
    service = ProtectionService(store, QueueTranscriber([]), analyzer, executor)
    session = service.create_session(
        parent.access_token,
        CreateProtectionSessionRequest(
            call_id="7F011753-8F09-4A45-8812-8A4591A96B3C",
            started_at="2026-10-01T10:00:00Z",
        ),
    )
    service.get_active_puck_session(puck.access_token)

    service.analyze_latest(
        puck.access_token,
        session.id,
        lambda _previous, _current: None,
        preview_text="Halo",
    )
    service.analyze_latest(
        puck.access_token,
        session.id,
        lambda _previous, _current: None,
        preview_text="Halo minta OTP 123456",
    )

    assert len(executor.pending) == 1
    executor.run_all()
    assert analyzer.calls == [("Halo minta OTP [KODE]", False)]
    assert store.get_puck_protection_session(
        puck.access_token, session.id
    ).masked_transcript == ""


def test_successful_transcription_logs_masked_chunk(caplog: pytest.LogCaptureFixture) -> None:
    service, _, _, puck_token, session_id = configured_service(
        ["Nomor saya 081234567890."]
    )
    caplog.set_level(logging.INFO, logger="uvicorn.error.rambu.transcription")

    service.process_chunk(puck_token, session_id, 0, False, wav_bytes())

    messages = [record.getMessage() for record in caplog.records]
    assert messages == [
        f'transcription session={session_id} sequence=0 final=False '
        'text="Nomor saya [NOMOR_TELEPON]."'
    ]
    assert "081234567890" not in caplog.text


def test_empty_interim_chunk_advances_without_fabricating_assessment() -> None:
    analyzer = RecordingAnalyzer()
    service, _, _, puck_token, session_id = configured_service(["   "], analyzer)

    snapshot = service.process_chunk(puck_token, session_id, 0, False, wav_bytes())

    assert snapshot.next_sequence == 1
    assert snapshot.assessment is None
    assert snapshot.status == "listening"
    assert analyzer.calls == []


def test_empty_final_chunk_completes_with_explicit_no_speech() -> None:
    analyzer = RecordingAnalyzer()
    service, _, _, puck_token, session_id = configured_service([""], analyzer)

    snapshot = service.process_chunk(puck_token, session_id, 0, True, wav_bytes(seconds=0))

    assert snapshot.status == "completed"
    assert snapshot.outcome == "no_speech"
    assert snapshot.assessment is None
    assert analyzer.calls == []


def test_end_request_waits_for_claimed_puck_final_chunk() -> None:
    service, _, parent_token, puck_token, session_id = configured_service([""])

    ending = service.end_session(parent_token, session_id)
    completed = service.process_chunk(puck_token, session_id, 0, True, wav_bytes(seconds=0))

    assert ending.status == "listening"
    assert ending.end_requested is True
    assert completed.status == "completed"
    assert completed.outcome == "no_speech"


def test_contract_failure_retries_once_and_records_the_valid_result(
    caplog: pytest.LogCaptureFixture,
) -> None:
    analyzer = SequenceAnalyzer([contract_failure(), assessment("high_risk")])
    service, _, _, puck_token, session_id = configured_service(
        ["Tolong berikan informasi SMS"], analyzer
    )
    caplog.set_level(logging.WARNING, logger="uvicorn.error.rambu.analysis")

    snapshot = process(service, puck_token, session_id, 0, False, wav_bytes())

    assert len(analyzer.calls) == 2
    assert snapshot.status == "listening"
    assert snapshot.assessment is not None
    assert snapshot.assessment.risk_level == "high_risk"
    assert "reason=schema_validation" in caplog.text
    assert "informasi SMS" not in caplog.text


def test_repeated_contract_failure_preserves_previous_risk_and_completes() -> None:
    analyzer = SequenceAnalyzer(
        [assessment("high_risk"), contract_failure(), contract_failure()]
    )
    service, _, _, puck_token, session_id = configured_service(
        ["informasi SMS", "ucapan tidak jelas"], analyzer
    )
    first = process(service, puck_token, session_id, 0, False, wav_bytes())

    completed = process(service, puck_token, session_id, 1, True, wav_bytes(seconds=2))

    assert first.assessment is not None
    assert first.assessment.risk_level == "high_risk"
    assert completed.status == "completed"
    assert completed.outcome == "analyzed"
    assert completed.assessment is not None
    assert completed.assessment.risk_level == "high_risk"
    assert completed.masked_transcript == "informasi SMS ucapan tidak jelas"


def test_risk_never_downgrades_after_a_valid_higher_assessment() -> None:
    analyzer = SequenceAnalyzer([assessment("high_risk"), assessment("low")])
    service, _, _, puck_token, session_id = configured_service(
        ["informasi SMS", "percakapan selesai"], analyzer
    )
    process(service, puck_token, session_id, 0, False, wav_bytes())

    completed = process(service, puck_token, session_id, 1, True, wav_bytes(seconds=2))

    assert completed.status == "completed"
    assert completed.assessment is not None
    assert completed.assessment.risk_level == "high_risk"


@pytest.mark.parametrize(
    ("dependency_error", "expected_code"),
    [
        (RuntimeError("whisper crashed"), "transcription_failed"),
        (
            LangflowFailure("timeout", "Langflow tidak merespons.", "http://langflow"),
            "analysis_timeout",
        ),
    ],
)
def test_dependency_failure_is_persisted_and_propagated(
    dependency_error: Exception, expected_code: str
) -> None:
    if isinstance(dependency_error, LangflowFailure):
        analyzer = RecordingAnalyzer(dependency_error)
        service, store, parent_token, puck_token, session_id = configured_service(["Halo"], analyzer)
    else:
        service, store, parent_token, puck_token, session_id = configured_service(
            [dependency_error]
        )

    if isinstance(dependency_error, LangflowFailure):
        process(service, puck_token, session_id, 0, False, wav_bytes())
    else:
        with pytest.raises(type(dependency_error), match=str(dependency_error)):
            service.process_chunk(puck_token, session_id, 0, False, wav_bytes())

    failed = store.get_protection_session(parent_token, session_id)
    assert failed.status == "error"
    assert failed.failure is not None
    assert failed.failure.code == expected_code
    assert failed.assessment is None


@pytest.mark.parametrize(
    "audio",
    [b"not-wave", wav_bytes(seconds=6.6), b"0" * (1_048_576 + 1)],
)
def test_invalid_audio_fails_without_advancing_sequence(audio: bytes) -> None:
    service, store, parent_token, puck_token, session_id = configured_service(["unused"])

    with pytest.raises(ValueError):
        service.process_chunk(puck_token, session_id, 0, False, audio)

    assert store.get_protection_session(parent_token, session_id).next_sequence == 0


def test_skipped_and_conflicting_chunks_fail_explicitly() -> None:
    service, _, _, puck_token, session_id = configured_service(["Halo"])

    with pytest.raises(PilotError, match="urutan"):
        service.process_chunk(puck_token, session_id, 1, False, wav_bytes())

    service.process_chunk(puck_token, session_id, 0, False, wav_bytes())
    with pytest.raises(PilotError, match="berbeda"):
        service.process_chunk(puck_token, session_id, 0, False, wav_bytes(seconds=2))
