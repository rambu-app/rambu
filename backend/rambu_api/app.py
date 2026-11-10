import asyncio
import json
import logging
import os
import threading
import time
from collections import deque
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, Awaitable, Callable, Protocol

from fastapi import BackgroundTasks, Body, FastAPI, Header, HTTPException, Request, Response, WebSocket
from fastapi.responses import JSONResponse
from starlette.websockets import WebSocketDisconnect

from .audio import adpcm_to_wav
from .config import LangflowSettings, TranscriptionSettings
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
    PairFamilyPuckRequest,
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
from .redaction import mask_sensitive_text
from .streaming import BridgeStreamClient, MAX_STREAM_FRAME_BYTES, StreamCapacity
from .transcription import BridgeTranscriber, FasterWhisperTranscriber


PUSH_LOGGER = logging.getLogger("uvicorn.error.rambu.push")
RISK_RANK = {"low": 0, "needs_review": 1, "high_risk": 2}
SCAM_HANG_UP_BODY = {
    "id": "Matikan teleponnya sekarang. Jangan transfer apa pun.",
    "en": "Hang up now. Do not send any money.",
}
# After a scam verdict the parent's phone keeps ringing until the call ends.
SCAM_ALARM_REPEATS = int(os.getenv("RAMBU_SCAM_ALARM_REPEATS", "4"))
SCAM_ALARM_INTERVAL = float(os.getenv("RAMBU_SCAM_ALARM_INTERVAL", "6"))
CODE_FAILURE_WINDOW_SECONDS = 600
CODE_FAILURES_PER_CLIENT = 5
CODE_FAILURES_TOTAL = 30


def _risk_increased(
    previous: ProtectionSessionSnapshot,
    current: ProtectionSessionSnapshot,
) -> bool:
    previous_level = previous.assessment.risk_level if previous.assessment else "low"
    current_level = current.assessment.risk_level if current.assessment else "low"
    return RISK_RANK[current_level] > max(0, RISK_RANK[previous_level])


def _protection_warning(
    snapshot: ProtectionSessionSnapshot, language: str = "id"
) -> tuple[str, str]:
    if snapshot.assessment is None or snapshot.assessment.risk_level == "low":
        raise ValueError("Peringatan membutuhkan hasil analisis berisiko.")
    if snapshot.assessment.risk_level == "high_risk":
        if language == "en":
            return (
                "Warning: this is a scam!",
                "Hang up now. Do not share any code. Do not send money.",
            )
        return (
            "Awas, ini penipu!",
            "Matikan teleponnya sekarang. Jangan sebut kode apa pun. Jangan transfer.",
        )
    if language == "en":
        return (
            "Warning: this could be a scam",
            "Do not give any code or money. Hang up first, then call your family.",
        )
    return (
        "Awas, bisa jadi penipu",
        "Jangan kasih kode atau uang. Tutup dulu, lalu telepon keluarga.",
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
    transcription_settings: TranscriptionSettings,
) -> DemoService:
    if transcription_settings.provider == "bridge":
        assert transcription_settings.bridge_url is not None
        transcriber = BridgeTranscriber(
            transcription_settings.bridge_url,
            timeout_seconds=transcription_settings.timeout_seconds,
        )
    else:
        whisper_settings = transcription_settings.whisper
        transcriber = FasterWhisperTranscriber(
            whisper_settings.model_name,
            device=whisper_settings.device,
            compute_type=whisper_settings.compute_type,
            device_index=whisper_settings.device_index,
        )
    return DemoService(
        scenarios=default_scenarios(),
        transcriber=transcriber,
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
    demo_api: bool | None = None,
    scam_alarm_repeats: int | None = None,
    scam_alarm_interval: float | None = None,
    sleep=time.sleep,
    stream_factory: Callable[[str], Awaitable[Any]] | None = None,
    stream_capacity: StreamCapacity | None = None,
    stream_idle_seconds: float | None = None,
    stream_max_seconds: float | None = None,
    stream_analysis_seconds: float | None = None,
) -> FastAPI:
    # The demo routes run Whisper and Langflow without a login, so they stay off on a public server.
    if demo_api is None:
        demo_api = service is not None or os.getenv("RAMBU_DEMO_API") == "1"
    demo_service = service
    protection = protection_service
    pilots = pilot_store or (PilotStore(":memory:") if service is not None else _default_pilot_store())
    pushes = push_sender or push_sender_from_environment()
    push_environment = os.getenv("APNS_ENVIRONMENT", "sandbox")
    alarm_repeats = SCAM_ALARM_REPEATS if scam_alarm_repeats is None else scam_alarm_repeats
    alarm_interval = SCAM_ALARM_INTERVAL if scam_alarm_interval is None else scam_alarm_interval
    capacity = stream_capacity or StreamCapacity(int(os.getenv("RAMBU_MAX_STREAMS", "4")))
    idle_seconds = (
        stream_idle_seconds
        if stream_idle_seconds is not None
        else float(os.getenv("RAMBU_STREAM_IDLE_SECONDS", "45"))
    )
    if idle_seconds <= 0:
        raise ValueError("stream idle timeout must be positive")
    max_stream_seconds = (
        stream_max_seconds
        if stream_max_seconds is not None
        else float(os.getenv("RAMBU_MAX_STREAM_SECONDS", "900"))
    )
    if max_stream_seconds <= 0:
        raise ValueError("stream maximum duration must be positive")
    analysis_seconds = (
        stream_analysis_seconds
        if stream_analysis_seconds is not None
        else float(os.getenv("RAMBU_STREAM_ANALYSIS_SECONDS", "4"))
    )
    if analysis_seconds <= 0:
        raise ValueError("stream analysis interval must be positive")

    async def open_stream(language: str) -> Any:
        if stream_factory is not None:
            return await stream_factory(language)
        bridge_url = os.getenv("RAMBU_TRANSCRIPTION_BRIDGE_URL", "").strip()
        if not bridge_url:
            raise RuntimeError("transcription bridge is not configured")
        return await BridgeStreamClient(bridge_url).start(language)

    def send_localized_push(
        targets: dict[str, list[str]],
        copy: dict[str, tuple[str, str]],
        notification_id: str,
        session_id: str,
        urgent: bool,
    ) -> None:
        if not targets:
            PUSH_LOGGER.error(
                "push not sent session=%s reason=no_registered_token",
                session_id,
            )
            return
        for language, tokens in targets.items():
            title, body = copy.get(language, copy["id"])
            try:
                pushes.send(tokens, title, body, notification_id, urgent=urgent)
            except Exception:
                PUSH_LOGGER.exception("push failed session=%s language=%s", session_id, language)

    def guardian_copy(level: str, parent_name: str) -> dict[str, tuple[str, str]]:
        return {
            "id": (
                f"{level.title()}: {parent_name} mungkin sedang ditipu",
                "Ketuk untuk melihat kalimat pemicu dan memutuskan.",
            ),
            "en": (
                f"{level.title()}: {parent_name} may be getting scammed",
                "Tap to review the warning signs and decide.",
            ),
        }

    def call_detected_copy() -> dict[str, tuple[str, str]]:
        return {
            "id": (
                "Panggilan WhatsApp terdeteksi",
                "Rambu Puck mulai mendengarkan dan melindungi panggilan ini.",
            ),
            "en": (
                "WhatsApp call detected",
                "Rambu Puck is now listening and protecting this call.",
            ),
        }

    def notify_assessment(
        token: str,
        session_id: str,
        previous: ProtectionSessionSnapshot,
        snapshot: ProtectionSessionSnapshot,
    ) -> None:
        alert, should_notify_guardians = pilots.upsert_protection_alert(token, session_id)
        if alert is not None and should_notify_guardians:
            guardian_targets = pilots.protection_notification_targets(
                token, session_id, "guardian", push_environment
            )
            if guardian_targets:
                send_localized_push(
                    guardian_targets,
                    guardian_copy(alert.level, alert.parent.name),
                    str(alert.id),
                    session_id,
                    urgent=alert.level in {"review", "danger"},
                )
        if _risk_increased(previous, snapshot):
            targets = pilots.protection_notification_targets(
                token, session_id, "parent", push_environment
            )
            send_localized_push(
                targets,
                {
                    language: _protection_warning(snapshot, language)
                    for language in ("id", "en")
                },
                str(snapshot.call_id),
                snapshot.id,
                urgent=True,
            )

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        nonlocal demo_service, protection
        try:
            if demo_service is None:
                configuration = settings or LangflowSettings.from_environment(os.environ)
                transcription_configuration = TranscriptionSettings.from_environment(
                    os.environ
                )
                demo_service = _default_service(configuration, transcription_configuration)
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

    def repeat_scam_alarm(
        targets: dict[str, list[str]],
        copy: dict[str, tuple[str, str]],
        alert_id: str,
    ) -> None:
        """Re-send the hang-up push until the parent's call ends or the repeats run out."""
        for attempt in range(alarm_repeats):
            sleep(alarm_interval)
            try:
                if not pilots.alert_call_active(alert_id):
                    return
            except Exception:
                PUSH_LOGGER.exception("scam alarm stopped alert=%s", alert_id)
                return
            send_localized_push(targets, copy, f"{alert_id}-alarm-{attempt + 1}", alert_id, True)

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ready"}

    if demo_api:
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

    failed_codes: dict[str, deque[float]] = {}
    failed_codes_lock = threading.Lock()

    def attempt_keys(request: Request) -> tuple[str, str]:
        client = request.headers.get("cf-connecting-ip") or (request.client.host if request.client else "unknown")
        return client, "*"

    def check_attempt_keys(request: Request) -> None:
        now = time.monotonic()
        with failed_codes_lock:
            for key, limit in zip(attempt_keys(request), (CODE_FAILURES_PER_CLIENT, CODE_FAILURES_TOTAL)):
                failures = failed_codes.setdefault(key, deque())
                while failures and now - failures[0] > CODE_FAILURE_WINDOW_SECONDS:
                    failures.popleft()
                if len(failures) >= limit:
                    raise HTTPException(status_code=429, detail="Terlalu banyak percobaan kode. Coba lagi beberapa menit lagi.")

    def record_code_failure(request: Request) -> None:
        now = time.monotonic()
        with failed_codes_lock:
            for key in attempt_keys(request):
                failed_codes.setdefault(key, deque()).append(now)

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
    def pair_puck(value: PairPuckRequest, request: Request) -> PairPuckResponse:
        check_attempt_keys(request)
        try:
            return protections().pair_puck(value.code, value.display_name)
        except Exception as error:
            if isinstance(error, InviteError):
                record_code_failure(request)
            raise protection_error(error) from error

    @app.post("/api/pilot/pucks", response_model=PairPuckResponse, status_code=201)
    def pair_family_puck(
        value: PairFamilyPuckRequest, authorization: str | None = Header(default=None)
    ) -> PairPuckResponse:
        try:
            return pilots.pair_puck_for_parent(token_from(authorization), value.display_name)
        except HTTPException:
            raise
        except Exception as error:
            raise pilot_error(error) from error

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
                targets = pilots.protection_notification_targets(
                    token, snapshot.id, "parent", push_environment
                )
                background_tasks.add_task(
                    send_localized_push,
                    targets,
                    call_detected_copy(),
                    str(snapshot.call_id),
                    snapshot.id,
                    False,
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
                targets = pilots.protection_notification_targets(
                    token, snapshot.id, "parent", push_environment
                )
                background_tasks.add_task(
                    send_localized_push,
                    targets,
                    call_detected_copy(),
                    str(snapshot.call_id),
                    snapshot.id,
                    False,
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
        media_type = (content_type or "").split(";", 1)[0].strip().lower()
        if media_type not in {"audio/wav", "audio/x-rambu-adpcm"}:
            raise HTTPException(status_code=422, detail="Content-Type harus audio/wav atau audio/x-rambu-adpcm.")
        if x_rambu_sequence is None or not x_rambu_sequence.isdigit():
            raise HTTPException(status_code=422, detail="X-Rambu-Sequence harus bilangan bulat.")
        if x_rambu_final not in {"true", "false"}:
            raise HTTPException(status_code=422, detail="X-Rambu-Final harus true atau false.")
        if len(audio) > MAXIMUM_CHUNK_BYTES:
            raise HTTPException(status_code=413, detail="Potongan audio melebihi batas 1 MB.")
        try:
            token = token_from(authorization)
            snapshot = protections().process_chunk(
                token,
                session_id,
                int(x_rambu_sequence),
                x_rambu_final == "true",
                adpcm_to_wav(audio) if media_type == "audio/x-rambu-adpcm" else audio,
            )
            protections().analyze_latest(
                token,
                session_id,
                lambda previous, current: notify_assessment(token, session_id, previous, current),
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

    @app.websocket("/api/pucks/sessions/{session_id}/stream")
    async def stream_puck_audio(websocket: WebSocket, session_id: str) -> None:
        authorization = websocket.headers.get("authorization")
        if not authorization or not authorization.startswith("Bearer "):
            await websocket.close(code=4401)
            return
        token = authorization.removeprefix("Bearer ").strip()
        if not token:
            await websocket.close(code=4401)
            return
        try:
            session = protections().get_puck_session(token, session_id)
            if session.status != "listening":
                raise ActiveProtectionSessionConflict(
                    "Sesi perlindungan tidak sedang mendengar."
                )
        except AuthenticationError:
            await websocket.close(code=4401)
            return
        except AuthorizationError:
            await websocket.close(code=4403)
            return
        except MissingProtectionSessionError:
            await websocket.close(code=4404)
            return
        except ActiveProtectionSessionConflict:
            await websocket.close(code=4409)
            return

        if not await capacity.acquire(session_id):
            await websocket.close(code=4429)
            return

        bridge = None
        public_task: asyncio.Task | None = None
        provider_task: asyncio.Task | None = None
        checkpoint_task: asyncio.Task | None = None
        assessment_task: asyncio.Task | None = None
        ready = False
        finishing = False
        completed = False
        next_sequence = 0
        loop = asyncio.get_running_loop()
        started_at = loop.time()
        last_stream_activity = started_at
        last_lease_touch = started_at - 15
        latest_partial = ""
        checkpointed_partial = ""
        assessment_events: asyncio.Queue[ProtectionSessionSnapshot] = asyncio.Queue()
        accept_assessments = True

        def on_assessed(
            previous: ProtectionSessionSnapshot,
            current: ProtectionSessionSnapshot,
        ) -> None:
            if accept_assessments and _risk_increased(previous, current):
                try:
                    loop.call_soon_threadsafe(assessment_events.put_nowait, current)
                except RuntimeError:
                    pass
            notify_assessment(token, session_id, previous, current)

        try:
            await websocket.accept()
            try:
                bridge = await open_stream(session.language)
            except Exception:
                await websocket.send_json(
                    {
                        "type": "error",
                        "code": "transcription_unavailable",
                        "retryable": True,
                    }
                )
                await websocket.close(code=1011)
                return

            public_task = asyncio.create_task(websocket.receive())
            provider_task = asyncio.create_task(bridge.receive())
            assessment_task = asyncio.create_task(assessment_events.get())
            while True:
                pending = {
                    task
                    for task in (
                        public_task,
                        provider_task,
                        checkpoint_task,
                        assessment_task,
                    )
                    if task is not None
                }
                remaining = max_stream_seconds - (loop.time() - started_at)
                idle_remaining = idle_seconds - (loop.time() - last_stream_activity)
                if remaining <= 0 or idle_remaining <= 0:
                    duration_exceeded = remaining <= 0
                    await websocket.send_json(
                        {
                            "type": "error",
                            "code": (
                                "stream_duration_exceeded"
                                if duration_exceeded
                                else "idle_timeout"
                            ),
                            "retryable": False,
                        }
                    )
                    await websocket.close(code=1001)
                    return
                done, _ = await asyncio.wait(
                    pending,
                    timeout=min(idle_remaining, remaining),
                    return_when=asyncio.FIRST_COMPLETED,
                )
                if not done:
                    duration_exceeded = loop.time() - started_at >= max_stream_seconds
                    await websocket.send_json(
                        {
                            "type": "error",
                            "code": (
                                "stream_duration_exceeded"
                                if duration_exceeded
                                else "idle_timeout"
                            ),
                            "retryable": False,
                        }
                    )
                    await websocket.close(code=1001)
                    return

                if provider_task in done:
                    last_stream_activity = loop.time()
                    try:
                        event = provider_task.result()
                    except Exception:
                        await websocket.send_json(
                            {
                                "type": "error",
                                "code": "transcription_unavailable",
                                "retryable": not ready,
                            }
                        )
                        await websocket.close(code=1011)
                        return
                    event_type = event.get("type")
                    if event_type == "ready":
                        ready = True
                        await websocket.send_json({"type": "ready"})
                        checkpoint_task = asyncio.create_task(
                            asyncio.sleep(analysis_seconds)
                        )
                    elif event_type == "partial":
                        text = mask_sensitive_text(str(event.get("text", "")))
                        latest_partial = text.strip()
                        await websocket.send_json({"type": "partial", "text": text})
                    elif event_type == "final":
                        sequence = event.get("sequence")
                        if not isinstance(sequence, int) or sequence != next_sequence:
                            raise ChunkSequenceConflict("Nomor urutan segmen tidak sesuai.")
                        snapshot = protections().process_stream_segment(
                            token,
                            session_id,
                            sequence=sequence,
                            text=str(event.get("text", "")),
                            final=False,
                        )
                        next_sequence += 1
                        latest_partial = ""
                        checkpointed_partial = ""
                        await websocket.send_json(
                            {
                                "type": "snapshot",
                                "snapshot": snapshot.model_dump(mode="json"),
                            }
                        )
                        protections().analyze_latest(
                            token,
                            session_id,
                            on_assessed,
                        )
                    elif event_type == "complete":
                        snapshot = protections().process_stream_segment(
                            token,
                            session_id,
                            sequence=next_sequence,
                            text="",
                            final=True,
                        )
                        completed = True
                        await websocket.send_json(
                            {
                                "type": "snapshot",
                                "snapshot": snapshot.model_dump(mode="json"),
                            }
                        )
                        protections().analyze_latest(
                            token,
                            session_id,
                            on_assessed,
                        )
                        await websocket.send_json({"type": "complete"})
                        await websocket.close(code=1000)
                        return
                    elif event_type == "error":
                        await websocket.send_json(
                            {
                                "type": "error",
                                "code": "transcription_unavailable",
                                "retryable": not ready,
                            }
                        )
                        await websocket.close(code=1011)
                        return
                    else:
                        raise ValueError("invalid bridge event")
                    provider_task = asyncio.create_task(bridge.receive())

                if checkpoint_task in done:
                    if latest_partial and latest_partial != checkpointed_partial:
                        checkpointed_partial = latest_partial
                        protections().analyze_latest(
                            token,
                            session_id,
                            on_assessed,
                            preview_text=latest_partial,
                        )
                    checkpoint_task = asyncio.create_task(
                        asyncio.sleep(analysis_seconds)
                    )

                if assessment_task in done:
                    assessed = assessment_task.result()
                    await websocket.send_json(
                        {
                            "type": "snapshot",
                            "snapshot": assessed.model_dump(mode="json"),
                        }
                    )
                    assessment_task = asyncio.create_task(assessment_events.get())

                if public_task in done:
                    last_stream_activity = loop.time()
                    message = public_task.result()
                    if message["type"] == "websocket.disconnect":
                        return
                    audio = message.get("bytes")
                    text = message.get("text")
                    if audio is not None:
                        if (
                            not ready
                            or finishing
                            or len(audio) == 0
                            or len(audio) > MAX_STREAM_FRAME_BYTES
                            or len(audio) % 2 != 0
                        ):
                            await websocket.send_json(
                                {
                                    "type": "error",
                                    "code": "invalid_audio",
                                    "retryable": False,
                                }
                            )
                            await websocket.close(code=1009)
                            return
                        if loop.time() - last_lease_touch >= 15:
                            protections().touch_stream_session(token, session_id)
                            last_lease_touch = loop.time()
                        await bridge.send_audio(audio)
                    elif text is not None:
                        try:
                            control = json.loads(text)
                        except json.JSONDecodeError:
                            control = None
                        if not ready or finishing or control != {"type": "finish"}:
                            await websocket.send_json(
                                {
                                    "type": "error",
                                    "code": "invalid_message",
                                    "retryable": False,
                                }
                            )
                            await websocket.close(code=1008)
                            return
                        finishing = True
                        await bridge.finish()
                    if finishing:
                        public_task = None
                    else:
                        public_task = asyncio.create_task(websocket.receive())
        except WebSocketDisconnect:
            return
        except (ChunkSequenceConflict, ActiveProtectionSessionConflict, ValueError):
            try:
                await websocket.send_json(
                    {
                        "type": "error",
                        "code": "stream_conflict",
                        "retryable": False,
                    }
                )
                await websocket.close(code=1008)
            except Exception:
                pass
        finally:
            accept_assessments = False
            cancelled_tasks = []
            for task in (
                public_task,
                provider_task,
                checkpoint_task,
                assessment_task,
            ):
                if task is not None and not task.done():
                    task.cancel()
                    cancelled_tasks.append(task)
            if cancelled_tasks:
                await asyncio.gather(*cancelled_tasks, return_exceptions=True)
            if bridge is not None:
                try:
                    await bridge.close()
                except Exception:
                    pass
            if ready and not completed:
                try:
                    protections().fail_stream_session(token, session_id)
                except Exception:
                    pass
            await capacity.release(session_id)

    @app.post("/api/pilot/families", response_model=PilotSession, status_code=201)
    def create_family(value: CreateFamilyRequest) -> PilotSession:
        try:
            return pilots.create_family(value.parent_name)
        except Exception as error:
            raise pilot_error(error) from error

    @app.post("/api/pilot/families/join", response_model=PilotSession, status_code=201)
    def join_family(value: JoinFamilyRequest, request: Request) -> PilotSession:
        check_attempt_keys(request)
        try:
            return pilots.join_family(value.code, value.name, value.relation)
        except Exception as error:
            if isinstance(error, InviteError):
                record_code_failure(request)
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
            pilots.register_push_token(
                token_from(authorization), value.token, value.environment, value.language
            )
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
                targets = pilots.notification_targets(token, "guardian", push_environment)
                background_tasks.add_task(
                    send_localized_push,
                    targets,
                    guardian_copy(alert.level, alert.parent.name),
                    str(alert.id),
                    str(alert.id),
                    alert.level in {"review", "danger"},
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
            targets = pilots.notification_targets(token, "parent", push_environment)
            copies = {
                "id": (
                    f"{decision.by.name}: {'ini penipu!' if decision.verdict == 'scam' else 'telepon aman'}",
                    SCAM_HANG_UP_BODY["id"]
                    if decision.verdict == "scam"
                    else "Tetap jangan sebut kode atau transfer.",
                ),
                "en": (
                    f"{decision.by.name}: {'this is a scam!' if decision.verdict == 'scam' else 'call is safe'}",
                    SCAM_HANG_UP_BODY["en"]
                    if decision.verdict == "scam"
                    else "Still do not share codes or transfer money.",
                ),
            }
            background_tasks.add_task(
                send_localized_push,
                targets,
                copies,
                alert_id,
                alert_id,
                decision.verdict == "scam",
            )
            if decision.verdict == "scam" and alarm_repeats > 0:
                background_tasks.add_task(repeat_scam_alarm, targets, copies, alert_id)
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
