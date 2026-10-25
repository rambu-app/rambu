import pytest

from rambu_api.apns import APNsPushSender, DisabledPushSender, push_sender_from_environment


APNS_VARIABLES = (
    "APNS_TEAM_ID",
    "APNS_KEY_ID",
    "APNS_PRIVATE_KEY_PATH",
    "APNS_BUNDLE_ID",
    "APNS_ENVIRONMENT",
)


class SuccessfulResponse:
    def raise_for_status(self) -> None:
        pass


class RecordingHTTPClient:
    def __init__(self) -> None:
        self.payloads: list[dict] = []

    def post(self, url: str, *, headers: dict, json: dict) -> SuccessfulResponse:
        self.payloads.append(json)
        return SuccessfulResponse()


def recording_sender() -> tuple[APNsPushSender, RecordingHTTPClient]:
    sender = APNsPushSender.__new__(APNsPushSender)
    client = RecordingHTTPClient()
    sender.bundle_id = "id.rambu.puck"
    sender.base_url = "https://api.sandbox.push.apple.com"
    sender.client = client
    sender._jwt = lambda: "jwt"  # type: ignore[method-assign]
    return sender, client


def clear_apns_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    for name in APNS_VARIABLES:
        monkeypatch.delenv(name, raising=False)


def test_urgent_push_uses_custom_sound() -> None:
    sender, client = recording_sender()

    sender.send(["device-token"], "Danger", "Stop", "alert-id", urgent=True)

    assert client.payloads[0]["aps"]["sound"] == "rambu-urgent.caf"


def test_nonurgent_push_uses_default_sound() -> None:
    sender, client = recording_sender()

    sender.send(["device-token"], "Connected", "Listening", "alert-id", urgent=False)

    assert client.payloads[0]["aps"]["sound"] == "default"


def test_push_is_explicitly_disabled_when_no_apns_credentials_exist(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    clear_apns_environment(monkeypatch)

    sender = push_sender_from_environment()

    assert isinstance(sender, DisabledPushSender)
    with pytest.raises(RuntimeError, match="APNs is not configured"):
        sender.send(["device-token"], "Title", "Body", "alert-id")


def test_partial_apns_configuration_fails_at_startup(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    clear_apns_environment(monkeypatch)
    monkeypatch.setenv("APNS_TEAM_ID", "TEAM123")

    with pytest.raises(RuntimeError, match="APNS_KEY_ID"):
        push_sender_from_environment()


def test_unknown_apns_environment_fails_at_startup(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    clear_apns_environment(monkeypatch)
    monkeypatch.setenv("APNS_TEAM_ID", "TEAM123")
    monkeypatch.setenv("APNS_KEY_ID", "KEY123")
    monkeypatch.setenv("APNS_PRIVATE_KEY_PATH", "/tmp/AuthKey.p8")
    monkeypatch.setenv("APNS_BUNDLE_ID", "id.rambu.puck")
    monkeypatch.setenv("APNS_ENVIRONMENT", "staging")

    with pytest.raises(RuntimeError, match="sandbox or production"):
        push_sender_from_environment()
