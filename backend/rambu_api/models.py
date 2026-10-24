from datetime import datetime
import re
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator


RiskLevel = Literal["low", "needs_review", "high_risk"]
Signal = Literal["impersonation", "urgency", "secret_code", "transfer", "remote_app"]


class Evidence(BaseModel):
    model_config = ConfigDict(extra="forbid")

    quote: str = Field(min_length=1)
    signals: list[Signal] = Field(min_length=1)


class RiskAssessment(BaseModel):
    model_config = ConfigDict(extra="forbid")

    risk_level: RiskLevel
    signals: list[Signal]
    evidence: list[Evidence]
    explanation: str = Field(min_length=1)
    recommended_action: str = Field(min_length=1)


def validate_assessment(assessment: RiskAssessment, transcript: str) -> RiskAssessment:
    if assessment.risk_level == "low":
        if assessment.signals or assessment.evidence:
            raise ValueError("Low risk cannot contain signals or evidence.")
        return assessment

    if not assessment.signals or not assessment.evidence:
        raise ValueError("Risky assessments require signals and evidence.")

    top_level = set(assessment.signals)
    canonical_evidence: list[Evidence] = []
    evidenced_signals: set[Signal] = set()
    for item in assessment.evidence:
        match = re.search(re.escape(item.quote), transcript, flags=re.IGNORECASE)
        if match is None:
            raise ValueError("Evidence must be an exact transcript substring.")
        if not set(item.signals).issubset(top_level):
            raise ValueError("Evidence signals must appear at the top level.")
        evidenced_signals.update(item.signals)
        canonical_evidence.append(
            item.model_copy(update={"quote": transcript[match.start() : match.end()]})
        )
    canonical_signals = list(
        dict.fromkeys(
            signal for signal in assessment.signals if signal in evidenced_signals
        )
    )
    return assessment.model_copy(
        update={
            "risk_level": "high_risk",
            "signals": canonical_signals,
            "evidence": canonical_evidence,
        }
    )


class DemoFailure(BaseModel):
    model_config = ConfigDict(extra="forbid")

    code: str
    message: str


class DemoSnapshot(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    scenario: str
    title: str
    status: Literal["running", "completed", "error"]
    progress: int
    transcript: str
    assessment: RiskAssessment | None
    error: DemoFailure | None


class ChunkAnalysisResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    transcript: str
    assessment: RiskAssessment | None


class PairPuckRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    code: str
    display_name: str


class PairPuckResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    puck_id: str
    family_id: str
    display_name: str
    access_token: str


class CreateProtectionSessionRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    call_id: UUID
    started_at: datetime
    channel: Literal["cellular", "whatsapp"] | None = None
    title: str | None = None
    caller_detail: str | None = None


class ProtectionFailure(BaseModel):
    model_config = ConfigDict(extra="forbid")

    code: str
    message: str


class ProtectionSessionSnapshot(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    call_id: UUID
    title: str
    caller_detail: str
    channel: Literal["cellular", "whatsapp"] | None
    status: Literal["waiting_for_puck", "listening", "completed", "error"]
    puck_connected: bool
    masked_transcript: str
    assessment: RiskAssessment | None
    outcome: Literal["analyzed", "no_speech"] | None
    end_requested: bool
    revision: int
    next_sequence: int
    started_at: datetime
    end_requested_at: datetime | None
    ended_at: datetime | None
    failure: ProtectionFailure | None


PilotRole = Literal["parent", "guardian"]
PilotRiskLevel = Literal["review", "danger"]
PilotSignal = Literal["impersonation", "urgency", "secretCode", "transfer", "remoteApp"]
PilotHistoryPresentation = Literal["safe", "review", "danger", "unassessed"]
PilotHistoryOutcome = Literal["analyzed", "no_speech", "error"]


class CreateFamilyRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    parent_name: str


class JoinFamilyRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    code: str
    name: str
    relation: str


class PilotPerson(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    name: str
    relation: str
    role: PilotRole


class PilotSession(BaseModel):
    model_config = ConfigDict(extra="forbid")

    family_id: str
    member: PilotPerson
    access_token: str
    invite_code: str | None = None
    invite_expires_at: datetime | None = None


class PilotProfile(BaseModel):
    model_config = ConfigDict(extra="forbid")

    family_id: str
    member: PilotPerson
    parent: PilotPerson
    guardians: list[PilotPerson]
    session_status: Literal["idle", "waiting_for_puck", "listening", "finishing"] = "idle"


class PilotInvite(BaseModel):
    model_config = ConfigDict(extra="forbid")

    code: str
    expires_at: datetime


class PilotTranscriptLine(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: int
    offset: float | None = None
    speaker: Literal["caller", "parent", "unknown"]
    text: str
    flagged: list[str]
    signals: list[PilotSignal]


class PilotAlertInput(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: UUID
    caller_detail: str
    channel: Literal["cellular", "whatsapp"]
    started_at: datetime
    raised_at: datetime
    level: PilotRiskLevel
    signals: list[PilotSignal]
    evidence: list[PilotTranscriptLine]


class PilotDecisionInput(BaseModel):
    model_config = ConfigDict(extra="forbid")

    verdict: Literal["scam", "safe"]


class PilotDecision(BaseModel):
    model_config = ConfigDict(extra="forbid")

    by: PilotPerson
    verdict: Literal["scam", "safe"]
    at: datetime


class PilotAlert(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: UUID
    parent: PilotPerson
    caller_detail: str
    channel: Literal["cellular", "whatsapp"]
    started_at: datetime
    raised_at: datetime
    level: PilotRiskLevel
    signals: list[PilotSignal]
    evidence: list[PilotTranscriptLine]
    recipients: list[PilotPerson]
    decision: PilotDecision | None
    call_ended: bool


class PilotHistoryRecord(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: UUID
    parent: PilotPerson
    title: str
    caller_detail: str
    channel: Literal["cellular", "whatsapp"] | None
    started_at: datetime
    ended_at: datetime
    duration_seconds: float
    outcome: PilotHistoryOutcome
    presentation: PilotHistoryPresentation
    signals: list[PilotSignal]
    evidence: list[PilotTranscriptLine]
    decision: PilotDecision | None
    failure: ProtectionFailure | None


class PilotDecisionResult(BaseModel):
    model_config = ConfigDict(extra="forbid")

    accepted: bool
    decision: PilotDecision


class PushTokenRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    token: str
    environment: Literal["sandbox", "production"] = "sandbox"
