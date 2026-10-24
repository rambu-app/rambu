import logging
import os
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Protocol

from fastapi import BackgroundTasks, Body, FastAPI, Header, HTTPException, Response
from fastapi.responses import JSONResponse

from .config import LangflowSettings, WhisperSettings
from .demo import DemoService, default_scenarios, delay_from_environment
from .langflow_client import LangflowClient, LangflowFailure
from .apns import PushSender, push_sender_from_environment
from .models import (
    CreateProtectionSessionRequest,
    CreateFamilyRequest,
    ChunkAnalysisResponse,
    DemoFailure,
    DemoSnapshot,
    JoinFamilyRequest,
    PilotAlert,
    PilotAlertInput,
    PilotDecisionInput,
    PilotDecisionResult,
    PilotHistoryRecord,
    PilotInvite,
    PilotProfile,
    PilotSession,
    PairPuckRequest,
    PairPuckResponse,
    ProtectionFailure,
    ProtectionSessionSnapshot,
    PushTokenRequest,
)
from .pilot import (
    ActiveProtectionSessionConflict,
    AuthenticationError,
    AuthorizationError,
    ChunkSequenceConflict,
    DecisionConflict,
    InviteError,
    MissingAlertError,
    MissingProtectionSessionError,
    PilotStore,
)
from .protection import MAXIMUM_CHUNK_BYTES, ProtectionService
from .transcription import FasterWhisperTranscriber


PUSH_LOGGER = logging.getLogger("uvicorn.error.rambu.push")
RISK_RANK = {"low": 0, "needs_review": 1, "high_risk": 2}


def _risk_increased(
    previous: ProtectionSessionSnapshot,
    current: ProtectionSessionSnapshot,
) -> bool:
    previous_level = previous.assessment.risk_level if previous.assessment else "low"
    current_level = current.assessment.risk_level if current.assessment else "low"
    return RISK_RANK[current_level] > max(0, RISK_RANK[previous_level])


def _protection_warning(snapshot: ProtectionSessionSnapshot) -> tuple[str, str]:
    if snapshot.assessment is None or snapshot.assessment.risk_level == "low":
        raise ValueError("Peringatan membutuhkan hasil analisis berisiko.")
    if snapshot.assessment.risk_level == "high_risk":
        return (
            "Bahaya: terindikasi penipuan",
            "Jangan berikan kode atau transfer. Tutup telepon sekarang.",
        )
    return (
        "Bahaya: telepon mencurigakan",
        "Jangan berikan data atau uang. Verifikasi penelepon sebelum melanjutkan.",
    )


class DemoServiceContract(Protocol):
    def start(self, scenario: str) -> DemoSnapshot: ...
    def get(self, session_id: str) -> DemoSnapshot: ...
    def delete(self, session_id: str) -> None: ...
    def close(self) -> None: ...
    def probe(self) -> None: ...
    def analyze_chunk(self, audio: bytes, final: bool) -> ChunkAnalysisResponse: ...


def _default_service(
    settings: LangflowSettings,
    whisper_settings: WhisperSettings,
) -> DemoService:
    return DemoService(
        scenarios=default_scenarios(),
        transcriber=FasterWhisperTranscriber(
            whisper_settings.model_name,
            device=whisper_settings.device,
            compute_type=whisper_settings.compute_type,
            device_index=whisper_settings.device_index,
        ),
        analyzer=LangflowClient(
            settings.url,
            settings.flow_id,
            settings.api_key,
        ),
        delay_seconds=delay_from_environment(),
    )


def _default_pilot_store() -> PilotStore:
    default_path = Path(__file__).resolve().parents[1] / "data" / "rambu.sqlite3"
    return PilotStore(os.getenv("RAMBU_DATABASE_PATH", str(default_path)))


def create_app(
    service: DemoServiceContract | None = None,
    pilot_store: PilotStore | None = None,
    protection_service: ProtectionService | None = None,
    push_sender: PushSender | None = None,
    settings: LangflowSettings | None = None,
) -> FastAPI:
    demo_service = service
    protection = protection_service
    pilots = pilot_store or (PilotStore(":memory:") if service is not None else _default_pilot_store())
    pushes = push_sender or push_sender_from_environment()
    push_environment = os.getenv("APNS_ENVIRONMENT", "sandbox")

    def send_protection_warning(
        tokens: list[str], title: str, body: str, call_id: str, session_id: str
    ) -> None:
        if not tokens:
            PUSH_LOGGER.error(
                "protection push not sent session=%s reason=no_registered_parent_token",
                session_id,
            )
            return
        try:
            pushes.send(tokens, title, body, call_id)
        except Exception:
            PUSH_LOGGER.exception("protection push failed session=%s", session_id)

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        nonlocal demo_service, protection
        try:
            if demo_service is None:
                configuration = settings or LangflowSettings.from_environment(os.environ)
                whisper_configuration = WhisperSettings.from_environment(os.environ)
                demo_service = _default_service(configuration, whisper_configuration)
                demo_service.probe()
                protection = ProtectionService(
                    pilots,
                    demo_service.transcriber,
                    demo_service.analyzer,
                )
            yield
        finally:
            if demo_service is not None:
                demo_service.close()
            pilots.close()
            pushes.close()

    app = FastAPI(
        title="Rambu Digital Prototype",
        version="0.2.0",
        lifespan=lifespan,
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )

    def demos() -> DemoServiceContract:
        if demo_service is None:
            raise RuntimeError("Demo service is unavailable before application startup.")
        return demo_service

    def protections() -> ProtectionService:
        if protection is None:
            raise RuntimeError("Protection service is unavailable before application startup.")
        return protection

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ready"}

    @app.post("/api/demo/{scenario}", response_model=DemoSnapshot, status_code=201)
    def start_demo(scenario: str) -> DemoSnapshot:
        try:
            return demos().start(scenario)
        except KeyError as error:
            raise HTTPException(status_code=404, detail="Skenario tidak ditemukan.") from error
        except FileNotFoundError as error:
            raise HTTPException(status_code=503, detail="Audio skenario belum tersedia.") from error

    @app.get("/api/demo/{session_id}", response_model=DemoSnapshot)
    def demo_status(session_id: str) -> DemoSnapshot:
        try:
            return demos().get(session_id)
        except KeyError as error:
            raise HTTPException(status_code=404, detail="Sesi demo tidak ditemukan.") from error

    @app.delete("/api/demo/{session_id}", status_code=204)
    def delete_demo(session_id: str) -> Response:
        try:
            demos().delete(session_id)
        except KeyError as error:
            raise HTTPException(status_code=404, detail="Sesi demo tidak ditemukan.") from error
        return Response(status_code=204)

    @app.post("/api/analyze-chunk", response_model=ChunkAnalysisResponse)
    def analyze_chunk(
        audio: bytes = Body(media_type="audio/wav"),
        x_rambu_consent: str | None = Header(default=None),
        x_rambu_final: str | None = Header(default=None),
    ) -> ChunkAnalysisResponse:
        if x_rambu_consent != "true":
            raise HTTPException(status_code=403, detail="Persetujuan pemrosesan audio belum dikonfirmasi.")
        if len(audio) > 1_000_000:
            raise HTTPException(status_code=413, detail="Potongan audio terlalu besar.")
        try:
            return demos().analyze_chunk(audio, final=x_rambu_final == "true")
        except ValueError as error:
            raise HTTPException(status_code=422, detail=str(error)) from error
        except LangflowFailure as error:
            failure = DemoFailure(
                code=f"analysis_{error.code}",
                message=error.safe_message,
            )
            raise HTTPException(status_code=503, detail=failure.model_dump()) from error
        except Exception as error:
            failure = DemoFailure(
                code="transcription_failed",
                message="Transkripsi audio gagal.",
            )
            raise HTTPException(status_code=503, detail=failure.model_dump()) from error

    def token_from(authorization: str | None) -> str:
        if not authorization or not authorization.startswith("Bearer "):
            raise HTTPException(status_code=401, detail="Token perangkat diperlukan.")
        return authorization.removeprefix("Bearer ").strip()

    def pilot_error(error: Exception) -> HTTPException:
        if isinstance(error, AuthenticationError):
            return HTTPException(status_code=401, detail=str(error))
        if isinstance(error, AuthorizationError):
            return HTTPException(status_code=403, detail=str(error))
        if isinstance(error, (InviteError, ValueError)):
            return HTTPException(status_code=422, detail=str(error))
        if isinstance(error, MissingAlertError):
            return HTTPException(status_code=404, detail=str(error))
        return HTTPException(status_code=500, detail="Layanan pilot gagal.")

    def protection_error(error: Exception) -> HTTPException:
        if isinstance(error, AuthenticationError):
            return HTTPException(status_code=401, detail=str(error))
        if isinstance(error, AuthorizationError):
            return HTTPException(status_code=403, detail=str(error))
        if isinstance(error, MissingProtectionSessionError):
            return HTTPException(status_code=404, detail=str(error))
        if isinstance(error, (ActiveProtectionSessionConflict, ChunkSequenceConflict)):
            return HTTPException(status_code=409, detail=str(error))
        if isinstance(error, (InviteError, ValueError)):
            return HTTPException(status_code=422, detail=str(error))
        return HTTPException(status_code=500, detail="Layanan perlindungan gagal.")

    @app.post("/api/pucks/pair", response_model=PairPuckResponse, status_code=201)
    def pair_puck(value: PairPuckRequest) -> PairPuckResponse:
        try:
            return protections().pair_puck(value.code, value.display_name)
        except Exception as error:
            raise protection_error(error) from error

    @app.post(
        "/api/protection/sessions",
        response_model=ProtectionSessionSnapshot,
        status_code=201,
    )
    def create_protection_session(
        value: CreateProtectionSessionRequest,
        authorization: str | None = Header(default=None),
    ) -> ProtectionSessionSnapshot:
        try:
            return protections().create_session(token_from(authorization), value)
        except HTTPException:
            raise
        except Exception as error:
            raise protection_error(error) from error

    @app.get(
        "/api/protection/sessions/{session_id}",
        response_model=ProtectionSessionSnapshot,
    )
    def protection_session_status(
        session_id: str,
        authorization: str | None = Header(default=None),
    ) -> ProtectionSessionSnapshot:
        try:
            return protections().get_parent_session(token_from(authorization), session_id)
        except HTTPException:
            raise
        except Exception as error:
            raise protection_error(error) from error

    @app.post(
        "/api/protection/sessions/{session_id}/end",
        response_model=ProtectionSessionSnapshot,
    )
    def end_protection_session(
        session_id: str,
        authorization: str | None = Header(default=None),
    ) -> ProtectionSessionSnapshot:
        try:
            return protections().end_session(token_from(authorization), session_id)
        except HTTPException:
            raise
        except Exception as error:
            raise protection_error(error) from error

    @app.delete("/api/protection/sessions/{session_id}", status_code=204)
    def delete_protection_session(
        session_id: str,
        authorization: str | None = Header(default=None),
    ) -> Response:
        try:
            protections().cancel_session(token_from(authorization), session_id)
            return Response(status_code=204)
        except HTTPException:
            raise
        except Exception as error:
            raise protection_error(error) from error

    @app.get(
        "/api/pucks/sessions/active",
        response_model=ProtectionSessionSnapshot,
    )
    def active_puck_session(
        background_tasks: BackgroundTasks,
        authorization: str | None = Header(default=None),
    ) -> ProtectionSessionSnapshot:
        try:
            token = token_from(authorization)
            snapshot, newly_claimed = protections().claim_active_puck_session(token)
            if newly_claimed:
                targets = pilots.protection_notification_tokens(
                    token, snapshot.id, "parent", push_environment
                )
                background_tasks.add_task(
                    send_protection_warning,
                    targets,
                    "Panggilan WhatsApp terdeteksi",
                    "Rambu Puck mulai mendengarkan dan melindungi panggilan ini.",
                    str(snapshot.call_id),
                    snapshot.id,
                )
            return snapshot
        except HTTPException:
            raise
        except Exception as error:
            raise protection_error(error) from error

    @app.post(
        "/api/pucks/sessions",
        response_model=ProtectionSessionSnapshot,
        status_code=201,
    )
    def create_puck_session(
        background_tasks: BackgroundTasks,
        value: CreateProtectionSessionRequest,
        authorization: str | None = Header(default=None),
    ) -> ProtectionSessionSnapshot:
        try:
            token = token_from(authorization)
            snapshot, created = protections().create_puck_session(token, value)
            if created:
                targets = pilots.protection_notification_tokens(
                    token, snapshot.id, "parent", push_environment
                )
                background_tasks.add_task(
                    send_protection_warning,
                    targets,
                    "Panggilan WhatsApp terdeteksi",
                    "Rambu Puck mulai mendengarkan dan melindungi panggilan ini.",
                    str(snapshot.call_id),
                    snapshot.id,
                )
            return snapshot
        except HTTPException:
            raise
        except Exception as error:
            raise protection_error(error) from error

    @app.post(
        "/api/pucks/sessions/{session_id}/chunks",
        response_model=ProtectionSessionSnapshot,
    )
    def upload_puck_chunk(
        session_id: str,
        background_tasks: BackgroundTasks,
        audio: bytes = Body(media_type="audio/wav"),
        authorization: str | None = Header(default=None),
        content_type: str | None = Header(default=None),
        x_rambu_sequence: str | None = Header(default=None),
        x_rambu_final: str | None = Header(default=None),
    ) -> ProtectionSessionSnapshot:
        if content_type is None or content_type.split(";", 1)[0].strip().lower() != "audio/wav":
            raise HTTPException(status_code=422, detail="Content-Type harus audio/wav.")
        if x_rambu_sequence is None or not x_rambu_sequence.isdigit():
            raise HTTPException(status_code=422, detail="X-Rambu-Sequence harus bilangan bulat.")
        if x_rambu_final not in {"true", "false"}:
            raise HTTPException(status_code=422, detail="X-Rambu-Final harus true atau false.")
        if len(audio) > MAXIMUM_CHUNK_BYTES:
            raise HTTPException(status_code=413, detail="Potongan audio melebihi batas 1 MB.")
        try:
            token = token_from(authorization)
            previous = protections().get_puck_session(token, session_id)
            snapshot = protections().process_chunk(
                token,
                session_id,
                int(x_rambu_sequence),
                x_rambu_final == "true",
                audio,
            )
            alert, should_notify_guardians = pilots.upsert_protection_alert(
                token, session_id
            )
            if alert is not None and should_notify_guardians:
                guardian_targets = pilots.protection_notification_tokens(
                    token, session_id, "guardian", push_environment
                )
                if guardian_targets:
                    background_tasks.add_task(
                        pushes.send,
                        guardian_targets,
                        f"{alert.level.title()}: {alert.parent.name} mungkin sedang ditipu",
                        "Ketuk untuk melihat kalimat pemicu dan memutuskan.",
                        str(alert.id),
                    )
            if _risk_increased(previous, snapshot):
                targets = pilots.protection_notification_tokens(
                    token, session_id, "parent", push_environment
                )
                title, body = _protection_warning(snapshot)
                background_tasks.add_task(
                    send_protection_warning,
                    targets,
                    title,
                    body,
                    str(snapshot.call_id),
                    snapshot.id,
                )
            return snapshot
        except HTTPException:
            raise
        except LangflowFailure as error:
            failure = ProtectionFailure(
                code=f"analysis_{error.code}",
                message=error.safe_message,
            )
            raise HTTPException(status_code=502, detail=failure.model_dump()) from error
        except (AuthenticationError, AuthorizationError, MissingProtectionSessionError,
                ActiveProtectionSessionConflict, ChunkSequenceConflict, ValueError) as error:
            raise protection_error(error) from error
        except Exception as error:
            try:
                failed = protections().get_puck_session(
                    token_from(authorization), session_id
                )
                failure = failed.failure
            except Exception:
                failure = None
            failure = failure or ProtectionFailure(
                code="processing_failed",
                message="Pemrosesan audio gagal.",
            )
            raise HTTPException(status_code=502, detail=failure.model_dump()) from error

    @app.post("/api/pilot/families", response_model=PilotSession, status_code=201)
    def create_family(value: CreateFamilyRequest) -> PilotSession:
        try:
            return pilots.create_family(value.parent_name)
        except Exception as error:
            raise pilot_error(error) from error

    @app.post("/api/pilot/families/join", response_model=PilotSession, status_code=201)
    def join_family(value: JoinFamilyRequest) -> PilotSession:
        try:
            return pilots.join_family(value.code, value.name, value.relation)
        except Exception as error:
            raise pilot_error(error) from error

    @app.get("/api/pilot/profile", response_model=PilotProfile)
    def pilot_profile(authorization: str | None = Header(default=None)) -> PilotProfile:
        try:
            return pilots.profile(token_from(authorization))
        except HTTPException:
            raise
        except Exception as error:
            raise pilot_error(error) from error

    @app.post("/api/pilot/invites", response_model=PilotInvite, status_code=201)
    def renew_invite(authorization: str | None = Header(default=None)) -> PilotInvite:
        try:
            code, expires = pilots.renew_invite(token_from(authorization))
            return PilotInvite(code=code, expires_at=expires)
        except HTTPException:
            raise
        except Exception as error:
            raise pilot_error(error) from error

    @app.put("/api/pilot/push-token", status_code=204)
    def register_push_token(
        value: PushTokenRequest,
        authorization: str | None = Header(default=None),
    ) -> Response:
        try:
            pilots.register_push_token(token_from(authorization), value.token, value.environment)
            return Response(status_code=204)
        except HTTPException:
            raise
        except Exception as error:
            raise pilot_error(error) from error

    @app.post("/api/pilot/alerts", response_model=PilotAlert, status_code=201)
    def publish_alert(
        value: PilotAlertInput,
        background_tasks: BackgroundTasks,
        authorization: str | None = Header(default=None),
    ) -> PilotAlert:
        try:
            token = token_from(authorization)
            alert, should_notify = pilots.publish_alert_result(token, value)
            if should_notify:
                targets = pilots.notification_tokens(token, "guardian", push_environment)
                background_tasks.add_task(
                    pushes.send, targets, f"{alert.level.title()}: {alert.parent.name} mungkin sedang ditipu",
                    "Ketuk untuk melihat kalimat pemicu dan memutuskan.", str(alert.id),
                )
            return alert
        except HTTPException:
            raise
        except Exception as error:
            raise pilot_error(error) from error

    @app.get("/api/pilot/alerts", response_model=list[PilotAlert])
    def list_alerts(authorization: str | None = Header(default=None)) -> list[PilotAlert]:
        try:
            return pilots.alerts(token_from(authorization))
        except HTTPException:
            raise
        except Exception as error:
            raise pilot_error(error) from error

    @app.get("/api/pilot/history", response_model=list[PilotHistoryRecord])
    def list_history(
        authorization: str | None = Header(default=None),
    ) -> list[PilotHistoryRecord]:
        try:
            return pilots.history(token_from(authorization))
        except HTTPException:
            raise
        except Exception as error:
            raise pilot_error(error) from error

    @app.post("/api/pilot/alerts/{alert_id}/decision", response_model=PilotDecisionResult)
    def decide_alert(
        alert_id: str,
        value: PilotDecisionInput,
        background_tasks: BackgroundTasks,
        authorization: str | None = Header(default=None),
    ) -> PilotDecisionResult | JSONResponse:
        try:
            token = token_from(authorization)
            decision = pilots.decide(token, alert_id, value.verdict)
            targets = pilots.notification_tokens(token, "parent", push_environment)
            title = f"{decision.by.name}: {'ini penipuan' if decision.verdict == 'scam' else 'telepon aman'}"
            body = "Tutup telepon sekarang." if decision.verdict == "scam" else "Tetap jangan beri kode atau transfer."
            background_tasks.add_task(pushes.send, targets, title, body, alert_id)
            return PilotDecisionResult(accepted=True, decision=decision)
        except DecisionConflict as error:
            body = PilotDecisionResult(accepted=False, decision=error.decision)
            return JSONResponse(status_code=409, content=body.model_dump(mode="json"))
        except HTTPException:
            raise
        except Exception as error:
            raise pilot_error(error) from error

    @app.post("/api/pilot/alerts/{alert_id}/end", response_model=PilotAlert)
    def end_alert(alert_id: str, authorization: str | None = Header(default=None)) -> PilotAlert:
        try:
            return pilots.end_alert(token_from(authorization), alert_id)
        except HTTPException:
            raise
        except Exception as error:
            raise pilot_error(error) from error

    return app


app = create_app()
