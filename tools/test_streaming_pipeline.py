#!/usr/bin/env python3
"""Opt-in live smoke test for an authenticated Rambu transcription stream."""

from __future__ import annotations

import asyncio
import json
import os
import sys
import time
from pathlib import Path
from urllib.parse import quote, urlsplit, urlunsplit

import websockets


def required_environment(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"{name} is required")
    return value


def stream_url(server_url: str, session_id: str) -> str:
    parsed = urlsplit(server_url.rstrip("/"))
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise RuntimeError("RAMBU_SERVER_URL must be an http(s) URL")
    scheme = "wss" if parsed.scheme == "https" else "ws"
    path = f"{parsed.path}/api/pucks/sessions/{quote(session_id, safe='')}/stream"
    return urlunsplit((scheme, parsed.netloc, path, "", ""))


async def run() -> None:
    if os.environ.get("RAMBU_ALLOW_LIVE_STREAM") != "1":
        raise RuntimeError(
            "refusing live traffic; set RAMBU_ALLOW_LIVE_STREAM=1 explicitly"
        )

    url = stream_url(
        required_environment("RAMBU_SERVER_URL"),
        required_environment("RAMBU_SESSION_ID"),
    )
    token = required_environment("RAMBU_PUCK_TOKEN")
    pcm_path = Path(required_environment("RAMBU_PCM_FILE"))
    audio = pcm_path.read_bytes()
    if not audio or len(audio) % 2 != 0:
        raise RuntimeError("RAMBU_PCM_FILE must contain non-empty PCM16 audio")
    if len(audio) > 160_000:
        raise RuntimeError("RAMBU_PCM_FILE must be at most five seconds at 16 kHz mono PCM16")
    started_at = time.monotonic()

    async with websockets.connect(
        url,
        additional_headers={"Authorization": f"Bearer {token}"},
        open_timeout=10,
        close_timeout=5,
        max_size=1_048_576,
    ) as socket:
        first = json.loads(await asyncio.wait_for(socket.recv(), timeout=15))
        if first != {"type": "ready"}:
            raise RuntimeError(f"stream did not become ready: {first.get('type', 'unknown')}")
        ready_seconds = time.monotonic() - started_at

        for offset in range(0, len(audio), 8_000):
            await socket.send(audio[offset : offset + 8_000])
        await socket.send(json.dumps({"type": "finish"}))

        stable_snapshot = False
        while True:
            event = json.loads(await asyncio.wait_for(socket.recv(), timeout=30))
            event_type = event.get("type")
            if event_type == "snapshot":
                transcript = event.get("snapshot", {}).get("masked_transcript", "")
                stable_snapshot = stable_snapshot or bool(transcript.strip())
            if event_type == "complete":
                if not stable_snapshot:
                    raise RuntimeError("stream completed without a stable transcript snapshot")
                audio_seconds = len(audio) / 2 / 16_000
                total_seconds = time.monotonic() - started_at
                print(
                    "Streaming smoke test passed: "
                    f"audio={audio_seconds:.2f}s ready={ready_seconds:.2f}s "
                    f"total={total_seconds:.2f}s"
                )
                return
            if event_type == "error":
                raise RuntimeError(
                    f"stream failed safely with code {event.get('code', 'unknown')}"
                )


def main() -> int:
    try:
        asyncio.run(run())
    except Exception as error:
        print(f"Streaming smoke test failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
