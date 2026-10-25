import json
import re
from collections.abc import Callable
from typing import Any, Literal
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from pydantic import ValidationError

from .models import Evidence, RiskAssessment, validate_assessment


AppLanguage = Literal["id", "en"]

_SECRET_TERM = (
    r"(?:kode\s+)?(?:otp|pin)(?:-?nya)?|kata\s+sandi|password|cvv|passcode|"
    r"security\s+code|verification\s+code"
)
_SECRET_REQUEST = (
    r"(?:tolong\s+)?(?:sebutkan|bacakan|berikan|kirimkan|bagikan|masukkan|"
    r"input(?:kan)?|kasih(?:kan)?|minta|read(?:\s+me)?|tell(?:\s+me)?|give(?:\s+me)?|"
    r"send(?:\s+me)?|share|enter|type|provide)"
)
_NEGATED_REQUEST = re.compile(
    r"\b(?:jangan|tidak\s+usah|tidak\s+boleh|dilarang|tolak|menolak|do\s+not|"
    r"don't|never|must\s+not|shouldn't|refuse|refused|won't)\b",
    flags=re.IGNORECASE,
)
_ACTIVE_SECRET_PATTERNS = (
    re.compile(
        rf"\b{_SECRET_REQUEST}\b.{{0,100}}?\b(?:{_SECRET_TERM})\b",
        flags=re.IGNORECASE | re.DOTALL,
    ),
    re.compile(
        rf"\b(?:{_SECRET_TERM})\b.{{0,100}}?\b{_SECRET_REQUEST}\b",
        flags=re.IGNORECASE | re.DOTALL,
    ),
)


SAFE_FAILURE_REASONS = frozenset(
    {
        "response_not_json",
        "probe_not_low",
        "response_envelope",
        "message_not_text",
        "message_not_json",
        "schema_validation",
        "low_risk_has_findings",
        "risky_assessment_missing_findings",
        "evidence_not_in_transcript",
        "evidence_signal_missing_from_summary",
        "semantic_validation",
    }
)


class LangflowFailure(RuntimeError):
    def __init__(
        self,
        code: str,
        safe_message: str,
        endpoint: str,
        http_status: int | None = None,
        reason: str | None = None,
    ) -> None:
        super().__init__(safe_message)
        self.code = code
        self.safe_message = safe_message
        self.endpoint = endpoint
        self.http_status = http_status
        self.reason = reason if reason in SAFE_FAILURE_REASONS else None


Transport = Callable[[str, dict[str, str], dict[str, Any]], dict[str, Any]]


class LangflowClient:
    def __init__(
        self,
        base_url: str,
        flow_id: str,
        api_key: str,
        transport: Transport | None = None,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.flow_id = flow_id
        self.api_key = api_key
        self.transport = transport or self._http_transport

    def analyze(
        self, transcript: str, final: bool, language: AppLanguage = "id"
    ) -> RiskAssessment:
        headers = {"Content-Type": "application/json"}
        headers["x-api-key"] = self.api_key
        payload = {
            "input_value": json.dumps(
                {
                    "masked_transcript": transcript,
                    "analysis_mode": "final" if final else "live",
                    "language": language,
                },
                ensure_ascii=False,
            ),
            "input_type": "chat",
            "output_type": "chat",
        }
        url = f"{self.base_url}/api/v1/run/{self.flow_id}"
        try:
            response = self.transport(url, headers, payload)
        except HTTPError as error:
            raise LangflowFailure(
                "http",
                f"Langflow menolak permintaan (HTTP {error.code}).",
                url,
                error.code,
            ) from error
        except TimeoutError as error:
            raise LangflowFailure(
                "timeout",
                "Langflow tidak merespons sebelum batas waktu.",
                url,
            ) from error
        except (URLError, OSError) as error:
            raise LangflowFailure(
                "connection",
                "Langflow tidak dapat dihubungi.",
                url,
            ) from error
        except json.JSONDecodeError as error:
            raise LangflowFailure(
                "invalid_json",
                "Langflow mengembalikan JSON yang tidak valid.",
                url,
                reason="response_not_json",
            ) from error
        return _extract_assessment(response, transcript, url, language)

    def probe(self) -> None:
        assessment = self.analyze(
            "Halo Bu, arisan dimulai pukul empat sore.",
            final=True,
        )
        if assessment.risk_level != "low":
            raise LangflowFailure(
                "invalid_response",
                "Probe Langflow tidak menghasilkan risiko rendah yang valid.",
                f"{self.base_url}/api/v1/run/{self.flow_id}",
                reason="probe_not_low",
            )

    @staticmethod
    def _http_transport(
        url: str,
        headers: dict[str, str],
        payload: dict[str, Any],
    ) -> dict[str, Any]:
        request = Request(
            url,
            data=json.dumps(payload).encode("utf-8"),
            headers=headers,
            method="POST",
        )
        with urlopen(request, timeout=45) as response:
            return json.loads(response.read().decode("utf-8"))


def _extract_assessment(
    value: Any, transcript: str, endpoint: str, language: AppLanguage = "id"
) -> RiskAssessment:
    try:
        text = value["outputs"][0]["outputs"][0]["results"]["message"]["text"]
    except (KeyError, IndexError, TypeError) as error:
        raise LangflowFailure(
            "invalid_response",
            "Respons Langflow tidak sesuai kontrak Rambu.",
            endpoint,
            reason="response_envelope",
        ) from error
    if not isinstance(text, str):
        raise LangflowFailure(
            "invalid_response",
            "Respons Langflow tidak sesuai kontrak Rambu.",
            endpoint,
            reason="message_not_text",
        )
    try:
        candidate = json.loads(text)
    except json.JSONDecodeError as error:
        raise LangflowFailure(
            "invalid_json",
            "Langflow mengembalikan JSON yang tidak valid.",
            endpoint,
            reason="message_not_json",
        ) from error
    try:
        assessment = RiskAssessment.model_validate(candidate)
        assessment = validate_assessment(assessment, transcript)
        return _enforce_explicit_secret_request(assessment, transcript, language)
    except ValidationError as error:
        raise LangflowFailure(
            "invalid_response",
            "Respons Langflow tidak sesuai kontrak Rambu.",
            endpoint,
            reason="schema_validation",
        ) from error
    except ValueError as error:
        reasons = {
            "Low risk cannot contain signals or evidence.": "low_risk_has_findings",
            "Risky assessments require signals and evidence.": "risky_assessment_missing_findings",
            "Evidence must be an exact transcript substring.": "evidence_not_in_transcript",
            "Evidence signals must appear at the top level.": "evidence_signal_missing_from_summary",
        }
        raise LangflowFailure(
            "invalid_response",
            "Respons Langflow tidak sesuai kontrak Rambu.",
            endpoint,
            reason=reasons.get(str(error), "semantic_validation"),
        ) from error


def _enforce_explicit_secret_request(
    assessment: RiskAssessment,
    transcript: str,
    language: AppLanguage = "id",
) -> RiskAssessment:
    if assessment.risk_level == "high_risk":
        return assessment
    quote: str | None = None
    for pattern in _ACTIVE_SECRET_PATTERNS:
        for match in pattern.finditer(transcript):
            candidate = match.group(0).strip()
            context_start = max(0, match.start() - 30)
            for boundary in ".!?\n":
                boundary_index = transcript.rfind(boundary, context_start, match.start())
                if boundary_index >= 0:
                    context_start = max(context_start, boundary_index + 1)
            context = transcript[context_start : match.end()]
            if not _NEGATED_REQUEST.search(context):
                quote = candidate
                break
        if quote is not None:
            break
    if quote is None:
        return assessment

    signals = list(dict.fromkeys([*assessment.signals, "secret_code"]))
    evidence = list(assessment.evidence)
    if not any(item.quote == quote and "secret_code" in item.signals for item in evidence):
        evidence.append(Evidence(quote=quote, signals=["secret_code"]))
    upgraded = assessment.model_copy(
        update={
            "risk_level": "high_risk",
            "signals": signals,
            "evidence": evidence,
            "explanation": (
                "The caller is asking for a secret code that must not be shared."
                if language == "en"
                else "Penelepon meminta kode rahasia yang tidak boleh dibagikan."
            ),
            "recommended_action": (
                "Hang up, do not share the code, and contact the organization through an official channel."
                if language == "en"
                else "Akhiri panggilan, jangan berikan kode, dan hubungi institusi lewat kanal resmi."
            ),
        }
    )
    return validate_assessment(upgraded, transcript)
