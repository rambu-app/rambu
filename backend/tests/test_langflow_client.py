import json
from urllib.error import HTTPError, URLError

import pytest

from rambu_api.langflow_client import LangflowClient, LangflowFailure


def assessment(
    *,
    risk_level: str = "high_risk",
    signals: list[str] | None = None,
    evidence: list[dict[str, object]] | None = None,
) -> dict[str, object]:
    return {
        "risk_level": risk_level,
        "signals": ["secret_code"] if signals is None else signals,
        "evidence": (
            [{"quote": "berikan OTP [KODE]", "signals": ["secret_code"]}]
            if evidence is None
            else evidence
        ),
        "explanation": "Penelepon meminta kode rahasia.",
        "recommended_action": "Akhiri panggilan dan hubungi kanal resmi.",
    }


def envelope(value: object) -> dict[str, object]:
    text = value if isinstance(value, str) else json.dumps(value)
    return {
        "outputs": [
            {"outputs": [{"results": {"message": {"text": text}}}]}
        ]
    }


def test_validated_yellow_warning_is_delivered_as_red_without_changing_evidence() -> None:
    transcript = "Saya dari bank."
    client = LangflowClient(
        "http://localhost:7861", "rambu", "secret",
        transport=lambda *_: envelope(assessment(
            risk_level="needs_review", signals=["impersonation"],
            evidence=[{"quote": transcript, "signals": ["impersonation"]}],
        )),
    )
    result = client.analyze(transcript, final=False)
    assert result.risk_level == "high_risk"
    assert result.evidence[0].quote == transcript
    assert result.signals == ["impersonation"]


def failure_from(call) -> Exception:
    with pytest.raises(Exception) as captured:
        call()
    assert type(captured.value).__name__ == "LangflowFailure"
    return captured.value


def test_parses_only_the_exact_langflow_envelope_and_sends_authentication() -> None:
    calls: list[tuple[str, dict[str, str], dict[str, object]]] = []

    def transport(url, headers, payload):
        calls.append((url, headers, payload))
        return envelope(assessment())

    client = LangflowClient(
        base_url="http://localhost:7861",
        flow_id="rambu",
        api_key="secret",
        transport=transport,
    )

    result = client.analyze("Tolong berikan OTP [KODE] sekarang.", final=False)

    assert result.risk_level == "high_risk"
    assert result.signals == ["secret_code"]
    assert result.evidence[0].quote == "berikan OTP [KODE]"
    assert calls[0][0] == "http://localhost:7861/api/v1/run/rambu"
    assert calls[0][1]["x-api-key"] == "secret"
    assert "Tolong berikan OTP [KODE] sekarang." in calls[0][2]["input_value"]


def test_canonicalizes_case_only_evidence_to_the_exact_transcript_text() -> None:
    transcript = "Saya perlu 4 juta sekarang untuk menebus mobil."
    response = assessment(
        signals=["transfer", "urgency"],
        evidence=[
            {
                "quote": "saya perlu 4 juta sekarang untuk menebus mobil.",
                "signals": ["transfer", "urgency"],
            }
        ],
    )
    client = LangflowClient(
        "http://localhost:7861",
        "rambu",
        "secret",
        transport=lambda *_: envelope(response),
    )

    result = client.analyze(transcript, final=True)

    assert result.evidence[0].quote == transcript


def test_prunes_top_level_signals_that_have_no_supporting_evidence() -> None:
    response = assessment(
        signals=["secret_code", "transfer"],
        evidence=[
            {"quote": "berikan OTP [KODE]", "signals": ["secret_code"]}
        ],
    )
    client = LangflowClient(
        "http://localhost:7861",
        "rambu",
        "secret",
        transport=lambda *_: envelope(response),
    )

    result = client.analyze("Tolong berikan OTP [KODE] sekarang.", final=True)

    assert result.signals == ["secret_code"]


@pytest.mark.parametrize(
    "transcript",
    [
        "Tolong sebutkan kode OTP yang baru masuk.",
        "Bacakan PIN itu sekarang.",
        "Kode OTP-nya berikan kepada saya.",
        "Jangan khawatir. Berikan kode OTP kepada saya.",
    ],
)
def test_explicit_secret_code_requests_are_always_high_risk(transcript: str) -> None:
    response = assessment(
        risk_level="needs_review",
        signals=["secret_code"],
        evidence=[{"quote": transcript, "signals": ["secret_code"]}],
    )
    client = LangflowClient(
        "http://localhost:7861",
        "rambu",
        "secret",
        transport=lambda *_: envelope(response),
    )

    result = client.analyze(transcript, final=False)

    assert result.risk_level == "high_risk"
    assert result.signals == ["secret_code"]
    assert result.evidence[0].quote in transcript
    assert "akhiri" in result.recommended_action.lower()


@pytest.mark.parametrize(
    "transcript",
    [
        "Kode OTP akan masuk melalui SMS.",
        "Jangan berikan kode OTP kepada siapa pun.",
        "Saya menolak menyebutkan PIN saya.",
    ],
)
def test_existing_warnings_use_red_without_adding_secret_code_requests(
    transcript: str,
) -> None:
    response = assessment(
        risk_level="needs_review",
        signals=["secret_code"],
        evidence=[{"quote": transcript, "signals": ["secret_code"]}],
    )
    client = LangflowClient(
        "http://localhost:7861",
        "rambu",
        "secret",
        transport=lambda *_: envelope(response),
    )

    result = client.analyze(transcript, final=False)

    assert result.risk_level == "high_risk"
    assert result.evidence[0].quote == transcript


@pytest.mark.parametrize(
    ("final", "expected_mode"),
    [(False, "live"), (True, "final")],
)
def test_analysis_mode_matches_final_flag(final, expected_mode) -> None:
    calls: list[dict[str, object]] = []

    def transport(_url, _headers, payload):
        calls.append(payload)
        return envelope(assessment(risk_level="low", signals=[], evidence=[]))

    client = LangflowClient(
        "http://localhost:7861",
        "rambu",
        "secret",
        transport=transport,
    )

    client.analyze("Halo.", final=final)

    assert json.loads(calls[0]["input_value"]) == {
        "masked_transcript": "Halo.",
        "analysis_mode": expected_mode,
        "language": "id",
    }


def test_english_language_is_sent_and_explicit_secret_request_is_upgraded() -> None:
    calls: list[dict[str, object]] = []

    def transport(_url, _headers, payload):
        calls.append(payload)
        return envelope(assessment(risk_level="low", signals=[], evidence=[]))

    client = LangflowClient("http://localhost:7861", "rambu", "secret", transport=transport)

    result = client.analyze("Please read me the OTP now.", final=False, language="en")

    assert json.loads(calls[0]["input_value"])["language"] == "en"
    assert result.risk_level == "high_risk"
    assert result.signals == ["secret_code"]
    assert result.evidence[0].quote.lower() == "read me the otp"
    assert "hang up" in result.recommended_action.lower()


@pytest.mark.parametrize(
    "invalid",
    [
        {**assessment(), "invented_caller": "Bank palsu"},
        assessment(risk_level="critical"),
        assessment(signals=["cryptocurrency"]),
        assessment(
            risk_level="low",
            signals=[],
            evidence=[{"quote": "halo", "signals": []}],
        ),
        assessment(risk_level="needs_review", signals=["urgency"], evidence=[]),
        assessment(
            signals=["secret_code"],
            evidence=[{"quote": "berikan OTP [KODE]", "signals": ["urgency"]}],
        ),
        assessment(
            signals=["secret_code"],
            evidence=[{"quote": "kutipan yang tidak ada", "signals": ["secret_code"]}],
        ),
    ],
)
def test_rejects_schema_and_semantic_contract_violations(invalid) -> None:
    client = LangflowClient(
        "http://localhost:7861",
        "rambu",
        "secret",
        transport=lambda *_: envelope(invalid),
    )

    error = failure_from(
        lambda: client.analyze("Tolong berikan OTP [KODE] sekarang.", final=True)
    )

    assert getattr(error, "code") == "invalid_response"


def test_reports_a_sanitized_semantic_validation_reason() -> None:
    client = LangflowClient(
        "http://localhost:7861",
        "rambu",
        "secret",
        transport=lambda *_: envelope(
            assessment(
                signals=["secret_code"],
                evidence=[
                    {
                        "quote": "kutipan yang tidak ada",
                        "signals": ["secret_code"],
                    }
                ],
            )
        ),
    )

    error = failure_from(
        lambda: client.analyze("Tolong berikan OTP [KODE] sekarang.", final=True)
    )

    assert getattr(error, "reason") == "evidence_not_in_transcript"
    assert "kutipan yang tidak ada" not in str(error)


def test_discards_an_unrecognized_failure_reason() -> None:
    error = LangflowFailure(
        "invalid_response",
        "Pesan aman.",
        "http://langflow/api/v1/run/rambu",
        reason="raw transcript sk-or-provider-secret provider-body",
    )

    assert error.reason is None


def test_rejects_assessment_outside_the_documented_envelope() -> None:
    client = LangflowClient(
        "http://localhost:7861",
        "rambu",
        "secret",
        transport=lambda *_: {"unexpected": assessment()},
    )

    error = failure_from(lambda: client.analyze("contoh", final=True))

    assert getattr(error, "code") == "invalid_response"


def test_reports_malformed_message_json_distinctly() -> None:
    client = LangflowClient(
        "http://localhost:7861",
        "rambu",
        "secret",
        transport=lambda *_: envelope("not-json"),
    )

    error = failure_from(lambda: client.analyze("contoh", final=True))

    assert getattr(error, "code") == "invalid_json"


@pytest.mark.parametrize(
    ("raised", "code", "status"),
    [
        (TimeoutError("slow"), "timeout", None),
        (URLError("offline"), "connection", None),
        (HTTPError("http://localhost", 401, "secret-key provider-body", None, None), "http", 401),
        (HTTPError("http://localhost", 404, "missing", None, None), "http", 404),
        (HTTPError("http://localhost", 503, "provider-body", None, None), "http", 503),
    ],
)
def test_reports_transport_failures_with_safe_context(raised, code, status) -> None:
    def transport(*_):
        raise raised

    client = LangflowClient("http://localhost:7861", "rambu", "secret-key", transport=transport)

    error = failure_from(lambda: client.analyze("contoh", final=True))

    assert getattr(error, "code") == code
    assert getattr(error, "endpoint").endswith("/api/v1/run/rambu")
    assert getattr(error, "http_status") == status
    assert "secret-key" not in str(error)
    assert "provider-body" not in str(error)


def test_probe_requires_a_valid_low_risk_result() -> None:
    received: list[str] = []

    def transport(_url, _headers, payload):
        received.append(payload["input_value"])
        return envelope(assessment())

    client = LangflowClient("http://localhost:7861", "rambu", "secret", transport=transport)

    error = failure_from(lambda: client.probe())

    assert getattr(error, "code") == "invalid_response"
    assert "analysis_mode" in received[0]
