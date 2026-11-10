import json
import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[2]
DEPLOYMENT = ROOT / "deploy" / "pilot"
COMPOSE = DEPLOYMENT / "compose.yaml"
BACKEND_DOCKERFILE = DEPLOYMENT / "backend.Dockerfile"
BRIDGE_DOCKERFILE = ROOT / "services" / "transcription-bridge" / "Dockerfile"
LANGFLOW_DOCKERFILE = DEPLOYMENT / "langflow.Dockerfile"
EXAMPLE_ENVIRONMENT = DEPLOYMENT / ".env.example"
GITIGNORE = ROOT / ".gitignore"


def _service_blocks(compose: str) -> dict[str, str]:
    lines = compose.splitlines()
    services_index = lines.index("services:")
    blocks: dict[str, list[str]] = {}
    current: str | None = None

    for line in lines[services_index + 1 :]:
        if line and not line.startswith(" "):
            break
        if line.startswith("  ") and not line.startswith("    ") and line.endswith(":"):
            current = line.strip()[:-1]
            blocks[current] = []
        elif current is not None:
            blocks[current].append(line)

    return {name: "\n".join(content) for name, content in blocks.items()}


def test_compose_exposes_only_the_backend_to_host_and_tunnel() -> None:
    blocks = _service_blocks(COMPOSE.read_text())

    assert set(blocks) == {"backend", "transcription-bridge", "langflow", "cloudflared"}
    assert '${RAMBU_BIND_ADDRESS:-127.0.0.1}:${RAMBU_BIND_PORT:-8000}:8000' in blocks["backend"]
    assert "ports:" not in blocks["langflow"]
    assert "ports:" not in blocks["cloudflared"]
    assert "ports:" not in blocks["transcription-bridge"]
    assert "- private" in blocks["backend"]
    assert "- edge" in blocks["backend"]
    assert "- private" in blocks["langflow"]
    assert "- edge" not in blocks["langflow"]
    assert "- edge" in blocks["cloudflared"]
    assert "- private" not in blocks["cloudflared"]
    assert "- private" in blocks["transcription-bridge"]
    assert "- edge" not in blocks["transcription-bridge"]


def test_compose_is_cpu_only_and_keeps_vercel_key_in_private_bridge() -> None:
    compose = COMPOSE.read_text()
    blocks = _service_blocks(compose)

    assert all("platform: linux/amd64" in blocks[name] for name in blocks)
    assert "restart: unless-stopped" in blocks["backend"]
    assert "restart: unless-stopped" in blocks["langflow"]
    assert "restart: unless-stopped" in blocks["cloudflared"]
    assert "nvidia" not in compose.lower()
    assert "cuda" not in compose.lower()
    assert "AI_GATEWAY_API_KEY" not in blocks["backend"]
    assert "AI_GATEWAY_API_KEY" not in blocks["langflow"]
    assert "AI_GATEWAY_API_KEY" not in blocks["cloudflared"]
    assert "AI_GATEWAY_API_KEY: ${AI_GATEWAY_API_KEY}" in blocks["transcription-bridge"]
    assert "RAMBU_ENV_FILE" not in blocks["langflow"]
    assert "RAMBU_LANGFLOW_ENV_FILE" in blocks["langflow"]
    assert "RAMBU_TRANSCRIPTION_PROVIDER: bridge" in blocks["backend"]
    assert "RAMBU_TRANSCRIPTION_BRIDGE_URL: http://transcription-bridge:8788" in blocks["backend"]
    assert "RAMBU_MAX_STREAMS: ${RAMBU_MAX_STREAMS:-4}" in blocks["backend"]
    assert "condition: service_healthy" in blocks["backend"]
    assert "image: cloudflare/cloudflared:2025.11.1" in blocks["cloudflared"]
    assert "--token-file" in blocks["cloudflared"]
    assert 'com.rambu.tunnel-origin: "http://backend:8000"' in blocks["cloudflared"]
    assert 'com.rambu.tunnel-health: "http://backend:8000/health"' in blocks["cloudflared"]
    assert all("logging: *default-logging" in blocks[name] for name in blocks)
    assert all("cpus:" in blocks[name] for name in blocks)
    assert all("mem_limit:" in blocks[name] for name in blocks)


def test_compose_persists_data_and_mounts_credentials_read_only() -> None:
    blocks = _service_blocks(COMPOSE.read_text())

    assert "${RAMBU_DATA_ROOT:?set RAMBU_DATA_ROOT}/data:/app/backend/data" in blocks["backend"]
    assert "RAMBU_DATABASE_PATH: /app/backend/data/rambu.sqlite3" in blocks["backend"]
    assert "${RAMBU_DATA_ROOT:?set RAMBU_DATA_ROOT}/secrets/AuthKey.p8:/run/secrets/AuthKey.p8:ro" in blocks["backend"]
    assert "APNS_PRIVATE_KEY_PATH: /run/secrets/AuthKey.p8" in blocks["backend"]
    assert "${RAMBU_DATA_ROOT:?set RAMBU_DATA_ROOT}/secrets/cloudflare-tunnel-token:/run/secrets/cloudflare-tunnel-token:ro" in blocks[
        "cloudflared"
    ]


def test_cloudflared_runs_as_the_private_token_owner() -> None:
    environment = os.environ.copy()
    environment.update({"RAMBU_UID": "4321", "RAMBU_GID": "8765"})
    result = subprocess.run(
        [
            "docker",
            "compose",
            "--env-file",
            str(EXAMPLE_ENVIRONMENT),
            "--file",
            str(COMPOSE),
            "config",
            "--format",
            "json",
        ],
        cwd=ROOT,
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    rendered = json.loads(result.stdout)
    assert rendered["services"]["cloudflared"]["user"] == "4321:8765"


def test_images_are_reproducible_and_copy_only_required_sources() -> None:
    backend = BACKEND_DOCKERFILE.read_text()
    bridge = BRIDGE_DOCKERFILE.read_text()
    langflow = LANGFLOW_DOCKERFILE.read_text()

    assert backend.startswith("FROM python:3.12-slim-bookworm")
    assert "nvidia" not in backend.lower()
    assert "cuda" not in backend.lower()
    assert "COPY backend/pyproject.toml backend/uv.lock" in backend
    assert "uv sync --frozen --no-dev" in backend
    assert "CMD [\"uvicorn\", \"rambu_api.app:app\", \"--host\", \"0.0.0.0\", \"--port\", \"8000\"]" in backend
    assert langflow.startswith("FROM langflowai/langflow:1.12.3")
    assert "COPY langflow/flows/Rambu.json" in langflow
    assert "COPY langflow/scripts/bootstrap_flow.py" in langflow
    assert "COPY ." not in backend
    assert "COPY ." not in langflow
    assert bridge.startswith("FROM node:22-bookworm-slim")
    assert "npm ci --omit=dev" in bridge
    assert "USER node" in bridge


def test_deployment_secrets_and_generated_state_are_ignored() -> None:
    ignored = GITIGNORE.read_text()

    for pattern in (
        "deploy/pilot/.env",
        "*tunnel-token*",
        "*.p8",
        "*.sqlite3",
        "*.sqlite3-*",
        "backups/",
        "model-cache/",
        "*.app",
    ):
        assert pattern in ignored


def test_example_environment_contains_placeholders_only() -> None:
    example = EXAMPLE_ENVIRONMENT.read_text()

    assert "LANGFLOW_URL=http://langflow:7860" in example
    assert "LANGFLOW_FLOW_ID=rambu" in example
    assert "RAMBU_PUBLIC_URL=https://rambu-api.sfatimah.com" in example
    assert "APNS_ENVIRONMENT=production" in example
    assert "AI_GATEWAY_API_KEY=replace-with-vercel-ai-gateway-key" in example
    assert "RAMBU_DATA_ROOT=/home/your-user/rambu-pilot" in example
    assert "replace-with-" in example
    assert "sk-or-" not in example
    assert "eyJ" not in example
