import asyncio
import json
from typing import Any
from urllib.parse import urlencode, urlsplit, urlunsplit

from websockets.asyncio.client import connect


MAX_STREAM_FRAME_BYTES = 16_384


class StreamCapacity:
    def __init__(self, limit: int = 4) -> None:
        if limit < 1:
            raise ValueError("stream capacity must be at least one")
        self.limit = limit
        self._active = 0
        self._sessions: set[str] = set()
        self._lock = asyncio.Lock()

    async def acquire(self, session_id: str | None = None) -> bool:
        async with self._lock:
            if self._active >= self.limit or (
                session_id is not None and session_id in self._sessions
            ):
                return False
            self._active += 1
            if session_id is not None:
                self._sessions.add(session_id)
            return True

    async def release(self, session_id: str | None = None) -> None:
        async with self._lock:
            self._active = max(0, self._active - 1)
            if session_id is not None:
                self._sessions.discard(session_id)


class BridgeStream:
    def __init__(self, socket: Any) -> None:
        self._socket = socket

    async def send_audio(self, value: bytes) -> None:
        await self._socket.send(value)

    async def finish(self) -> None:
        await self._socket.send(json.dumps({"type": "finish"}))

    async def receive(self) -> dict[str, Any]:
        value = await self._socket.recv()
        if not isinstance(value, str):
            raise RuntimeError("bridge returned a binary control message")
        event = json.loads(value)
        if not isinstance(event, dict):
            raise RuntimeError("bridge returned an invalid event")
        return event

    async def close(self) -> None:
        await self._socket.close()


class BridgeStreamClient:
    def __init__(self, base_url: str, *, open_timeout_seconds: float = 10) -> None:
        parsed = urlsplit(base_url.rstrip("/"))
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise ValueError("bridge URL must use http or https")
        scheme = "wss" if parsed.scheme == "https" else "ws"
        self._stream_url = urlunsplit((scheme, parsed.netloc, "/v1/stream", "", ""))
        self._open_timeout_seconds = open_timeout_seconds

    async def start(self, language: str) -> BridgeStream:
        if language not in {"id", "en"}:
            raise ValueError("unsupported language")
        url = f"{self._stream_url}?{urlencode({'language': language})}"
        socket = await connect(
            url,
            max_size=64 * 1024,
            open_timeout=self._open_timeout_seconds,
            ping_interval=20,
            ping_timeout=20,
        )
        return BridgeStream(socket)
