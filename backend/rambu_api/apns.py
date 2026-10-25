import os
import threading
import time
from pathlib import Path
from typing import Protocol


class PushSender(Protocol):
    def send(
        self,
        tokens: list[str],
        title: str,
        body: str,
        alert_id: str,
        urgent: bool = False,
    ) -> None: ...
    def close(self) -> None: ...


class DisabledPushSender:
    def send(
        self,
        tokens: list[str],
        title: str,
        body: str,
        alert_id: str,
        urgent: bool = False,
    ) -> None:
        raise RuntimeError("APNs is not configured.")

    def close(self) -> None:
        return


class APNsPushSender:
    def __init__(
        self,
        team_id: str,
        key_id: str,
        private_key_path: str,
        bundle_id: str,
        environment: str,
    ) -> None:
        import httpx

        self.team_id = team_id
        self.key_id = key_id
        self.private_key = Path(private_key_path).read_text(encoding="utf-8")
        self.bundle_id = bundle_id
        self.base_url = (
            "https://api.push.apple.com" if environment == "production"
            else "https://api.sandbox.push.apple.com"
        )
        self.client = httpx.Client(http2=True, timeout=10)
        self._authorization: tuple[str, float] | None = None
        self._lock = threading.Lock()

    def send(
        self,
        tokens: list[str],
        title: str,
        body: str,
        alert_id: str,
        urgent: bool = False,
    ) -> None:
        if not tokens:
            return
        headers = {
            "authorization": f"bearer {self._jwt()}",
            "apns-topic": self.bundle_id,
            "apns-push-type": "alert",
            "apns-priority": "10",
            "apns-collapse-id": alert_id,
        }
        payload = {
            "aps": {
                "alert": {"title": title, "body": body},
                "sound": "rambu-urgent.caf" if urgent else "default",
                "thread-id": alert_id,
            },
            "alertID": alert_id,
        }
        failures: list[str] = []
        for token in set(tokens):
            try:
                response = self.client.post(f"{self.base_url}/3/device/{token}", headers=headers, json=payload)
                response.raise_for_status()
            except Exception as error:
                failures.append(f"{token[-8:]}: {error}")
        if failures:
            raise RuntimeError("APNs delivery failed: " + "; ".join(failures))

    def close(self) -> None:
        self.client.close()

    def _jwt(self) -> str:
        import jwt

        with self._lock:
            now = time.time()
            if self._authorization is not None and now - self._authorization[1] < 50 * 60:
                return self._authorization[0]
            token = jwt.encode(
                {"iss": self.team_id, "iat": int(now)},
                self.private_key,
                algorithm="ES256",
                headers={"kid": self.key_id},
            )
            self._authorization = (token, now)
            return token


def push_sender_from_environment() -> PushSender:
    values = {
        "team_id": os.getenv("APNS_TEAM_ID", ""),
        "key_id": os.getenv("APNS_KEY_ID", ""),
        "private_key_path": os.getenv("APNS_PRIVATE_KEY_PATH", ""),
        "bundle_id": os.getenv("APNS_BUNDLE_ID", ""),
        "environment": os.getenv("APNS_ENVIRONMENT", "sandbox"),
    }
    required = ("team_id", "key_id", "private_key_path", "bundle_id")
    configured = [key for key in required if values[key]]
    if not configured:
        return DisabledPushSender()
    missing = [key for key in required if not values[key]]
    if missing:
        names = ", ".join(f"APNS_{key.upper()}" for key in missing)
        raise RuntimeError(f"Incomplete APNs configuration. Missing: {names}.")
    if values["environment"] not in {"sandbox", "production"}:
        raise RuntimeError("APNS_ENVIRONMENT must be sandbox or production.")
    return APNsPushSender(**values)
