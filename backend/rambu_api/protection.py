import hashlib
import json
import logging
import tempfile
from concurrent.futures import Executor, ThreadPoolExecutor
from pathlib import Path
from typing import Callable, Protocol

from .audio import validate_wav_bytes
from .langflow_client import LangflowFailure
from .models import (
    CreateProtectionSessionRequest,
    PairPuckResponse,
    ProtectionFailure,
    ProtectionSessionSnapshot,
    RiskAssessment,
)
from .pilot import PilotStore
from .redaction import mask_sensitive_text
from .transcription import Transcriber


MAXIMUM_CHUNK_BYTES = 1_048_576
TRANSCRIPTION_LOGGER = logging.getLogger("uvicorn.error.rambu.transcription")
ANALYSIS_LOGGER = logging.getLogger("uvicorn.error.rambu.analysis")
CONTRACT_FAILURE_CODES = frozenset({"invalid_json", "invalid_response"})


class Analyzer(Protocol):
    def analyze(self, transcript: str, final: bool, language: str = "id") -> RiskAssessment: ...


class ProtectionService:
    def __init__(
        self,
        store: PilotStore,
        transcriber: Transcriber,
        analyzer: Analyzer,
        analysis_executor: Executor | None = None,
    ) -> None:
        self.store = store
        self.transcriber = transcriber
        self.analyzer = analyzer
        self._analysis = analysis_executor or ThreadPoolExecutor(
            max_workers=1, thread_name_prefix="rambu-analysis"
        )
        self._analyzed: dict[str, tuple[str, bool]] = {}

    def pair_puck(self, invitation_code: str, display_name: str) -> PairPuckResponse:
        return self.store.pair_puck(invitation_code, display_name)

    def create_session(
        self, parent_token: str, request: CreateProtectionSessionRequest
    ) -> ProtectionSessionSnapshot:
        return self.store.create_protection_session(
            parent_token,
            str(request.call_id),
            request.started_at,
            request.channel,
            request.title,
            request.caller_detail,
            request.language,
        )

    def create_puck_session(
        self, puck_token: str, request: CreateProtectionSessionRequest
    ) -> tuple[ProtectionSessionSnapshot, bool]:
        language = request.language if "language" in request.model_fields_set else None
        return self.store.create_puck_protection_session(
            puck_token,
            str(request.call_id),
            request.started_at,
            request.channel,
            request.title,
            request.caller_detail,
            language,
        )

    def get_parent_session(
        self, parent_token: str, session_id: str
    ) -> ProtectionSessionSnapshot:
        return self.store.get_protection_session(parent_token, session_id)

    def get_active_puck_session(self, puck_token: str) -> ProtectionSessionSnapshot:
        return self.store.active_protection_session(puck_token)

    def claim_active_puck_session(
        self, puck_token: str
    ) -> tuple[ProtectionSessionSnapshot, bool]:
        return self.store.claim_active_protection_session(puck_token)

    def get_puck_session(
        self, puck_token: str, session_id: str
    ) -> ProtectionSessionSnapshot:
        return self.store.get_puck_protection_session(puck_token, session_id)

    def process_chunk(
        self,
        puck_token: str,
        session_id: str,
        sequence: int,
        final: bool,
        audio: bytes,
    ) -> ProtectionSessionSnapshot:
        if len(audio) > MAXIMUM_CHUNK_BYTES:
            raise ValueError("Potongan audio melebihi batas 1 MB.")
        validate_wav_bytes(audio)
        digest = hashlib.sha256(audio).hexdigest()
        current, duplicate = self.store.inspect_protection_chunk(
            puck_token,
            session_id,
            sequence=sequence,
            digest=digest,
        )
        if duplicate:
            return current

        try:
            text = self._transcribe_temporary_chunk(audio, current.language).strip()
        except Exception:
            self.store.fail_protection_session(
                puck_token,
                session_id,
                ProtectionFailure(
                    code="transcription_failed",
                    message="Transkripsi audio gagal.",
                ),
            )
            raise

        masked_chunk = mask_sensitive_text(text)
        logged_text = (
            json.dumps(masked_chunk, ensure_ascii=False) if masked_chunk else "<empty>"
        )
        TRANSCRIPTION_LOGGER.info(
            "transcription session=%s sequence=%d final=%s text=%s",
            session_id,
            sequence,
            final,
            logged_text,
        )

        combined = " ".join(
            part for part in (current.masked_transcript.strip(), text) if part
        )
        return self.store.record_protection_chunk(
            puck_token,
            session_id,
            sequence=sequence,
            digest=digest,
            masked_transcript=mask_sensitive_text(combined),
            assessment=current.assessment,
            final=final,
        )

    def analyze_latest(
        self,
        puck_token: str,
        session_id: str,
        on_assessed: Callable[[ProtectionSessionSnapshot, ProtectionSessionSnapshot], None],
    ) -> None:
        self._analysis.submit(self._analyze, puck_token, session_id, on_assessed)

    def _analyze(
        self,
        puck_token: str,
        session_id: str,
        on_assessed: Callable[[ProtectionSessionSnapshot, ProtectionSessionSnapshot], None],
    ) -> None:
        try:
            current = self.store.get_puck_protection_session(puck_token, session_id)
            transcript = current.masked_transcript
            final = current.status == "completed"
            if current.status == "error" or not transcript:
                return
            if self._analyzed.get(session_id) == (transcript, final):
                return
            assessment = self._assess(puck_token, session_id, current, transcript, final)
            self._analyzed[session_id] = (transcript, final)
            if assessment is None:
                return
            updated = self.store.update_protection_assessment(puck_token, session_id, assessment)
            on_assessed(current, updated)
        except Exception:
            ANALYSIS_LOGGER.exception("analysis failed session=%s", session_id)

    def _assess(
        self,
        puck_token: str,
        session_id: str,
        current: ProtectionSessionSnapshot,
        transcript: str,
        final: bool,
    ) -> RiskAssessment | None:
        try:
            for attempt in range(2):
                try:
                    assessment = self.analyzer.analyze(
                        transcript, final=final, language=current.language
                    )
                    if assessment.risk_level == "needs_review":
                        assessment = assessment.model_copy(update={"risk_level": "high_risk"})
                    return assessment
                except LangflowFailure as error:
                    if error.code not in CONTRACT_FAILURE_CODES or attempt == 1:
                        raise
                    ANALYSIS_LOGGER.warning(
                        "analysis contract retry session=%s reason=%s",
                        session_id,
                        error.reason or error.code,
                    )
        except LangflowFailure as error:
            if error.code in CONTRACT_FAILURE_CODES and (
                not final or current.assessment is not None
            ):
                ANALYSIS_LOGGER.warning(
                    "analysis contract fallback session=%s reason=%s previous_assessment=%s",
                    session_id,
                    error.reason or error.code,
                    current.assessment is not None,
                )
                return None
            self.store.fail_protection_session(
                puck_token,
                session_id,
                ProtectionFailure(code=f"analysis_{error.code}", message=error.safe_message),
            )
            raise
        except Exception:
            self.store.fail_protection_session(
                puck_token,
                session_id,
                ProtectionFailure(code="analysis_failed", message="Analisis panggilan gagal."),
            )
            raise
        return None

    def end_session(
        self, parent_token: str, session_id: str
    ) -> ProtectionSessionSnapshot:
        return self.store.request_protection_end(parent_token, session_id)

    def cancel_session(self, parent_token: str, session_id: str) -> None:
        self.store.delete_protection_session(parent_token, session_id)

    def _transcribe_temporary_chunk(self, audio: bytes, language: str = "id") -> str:
        temporary_path: Path | None = None
        try:
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as temporary:
                temporary.write(audio)
                temporary_path = Path(temporary.name)
            return self.transcriber.transcribe(temporary_path, language=language)
        finally:
            if temporary_path is not None:
                temporary_path.unlink(missing_ok=True)
