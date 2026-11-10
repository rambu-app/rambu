#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIRECTORY}/.." && pwd)"
COMPOSE_FILE="${REPOSITORY_ROOT}/deploy/pilot/compose.yaml"
PILOT_ROOT="${RAMBU_PILOT_ROOT:-${HOME}/rambu-pilot}"
MINIMUM_FREE_KB="${RAMBU_MIN_FREE_KB:-10485760}"
HEALTH_ATTEMPTS="${RAMBU_HEALTH_ATTEMPTS:-30}"
HEALTH_INTERVAL="${RAMBU_HEALTH_INTERVAL:-2}"
ENVIRONMENT_FILE=""

usage() {
  cat <<'EOF'
Usage: tools/deploy_pilot_server.sh COMMAND --env-file PATH

Commands:
  check    Validate secrets, disk, Docker Compose, and network isolation.
  deploy   Back up data, build and start the stack, bootstrap the flow, and verify health.
  status   Show the four Compose services and local backend health.
  logs     Follow service logs with configured secret values redacted.
  backup   Create a consistent timestamped SQLite backup.

The production pilot stores data under $HOME/rambu-pilot by default.
EOF
}

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

environment_value() {
  local name="$1"
  awk -F= -v key="${name}" '
    $1 == key {
      sub(/^[^=]*=/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      if (($0 ~ /^".*"$/) || ($0 ~ /^\047.*\047$/)) {
        $0 = substr($0, 2, length($0) - 2)
      }
      print
      exit
    }
  ' "${ENVIRONMENT_FILE}"
}

load_environment() {
  local name
  local value
  local required=(
    RAMBU_PUBLIC_URL
    LANGFLOW_FLOW_ID
    LANGFLOW_API_KEY
    LANGFLOW_SUPERUSER_PASSWORD
    LANGFLOW_SECRET_KEY
    OPENROUTER_API_KEY
    AI_GATEWAY_API_KEY
    APNS_TEAM_ID
    APNS_KEY_ID
    APNS_BUNDLE_ID
    APNS_ENVIRONMENT
  )

  [[ -f "${ENVIRONMENT_FILE}" ]] || fail "Environment file is missing: ${ENVIRONMENT_FILE}"
  for name in "${required[@]}"; do
    value="$(environment_value "${name}")"
    [[ -n "${value}" ]] || fail "${name} is missing or blank in the environment file."
    [[ "${value}" != replace-with-* ]] || fail "${name} still contains an example placeholder."
    printf -v "${name}" '%s' "${value}"
    export "${name}"
  done

  RAMBU_BIND_ADDRESS="$(environment_value RAMBU_BIND_ADDRESS)"
  RAMBU_BIND_ADDRESS="${RAMBU_BIND_ADDRESS:-127.0.0.1}"
  RAMBU_BIND_PORT="$(environment_value RAMBU_BIND_PORT)"
  RAMBU_BIND_PORT="${RAMBU_BIND_PORT:-8000}"
  [[ "${RAMBU_BIND_PORT}" =~ ^[0-9]+$ ]] && \
    (( RAMBU_BIND_PORT >= 1 && RAMBU_BIND_PORT <= 65535 )) || \
    fail "RAMBU_BIND_PORT must be an integer from 1 to 65535."
  export RAMBU_BIND_ADDRESS RAMBU_BIND_PORT
  RAMBU_DATA_ROOT="$(environment_value RAMBU_DATA_ROOT)"
  RAMBU_DATA_ROOT="${RAMBU_DATA_ROOT:-${PILOT_ROOT}}"
  PILOT_ROOT="${RAMBU_DATA_ROOT}"
  RAMBU_UID="$(environment_value RAMBU_UID)"
  RAMBU_UID="${RAMBU_UID:-$(id -u)}"
  RAMBU_GID="$(environment_value RAMBU_GID)"
  RAMBU_GID="${RAMBU_GID:-$(id -g)}"
  export RAMBU_DATA_ROOT RAMBU_UID RAMBU_GID
  RAMBU_LANGFLOW_ENV_FILE="$(environment_value RAMBU_LANGFLOW_ENV_FILE)"
  RAMBU_LANGFLOW_ENV_FILE="${RAMBU_LANGFLOW_ENV_FILE:-${PILOT_ROOT}/secrets/langflow.env}"
  export RAMBU_LANGFLOW_ENV_FILE

  [[ "${RAMBU_PUBLIC_URL}" == "https://rambu-api.sfatimah.com" ]] || \
    fail "RAMBU_PUBLIC_URL must be https://rambu-api.sfatimah.com."
  [[ "${RAMBU_BIND_ADDRESS}" == "127.0.0.1" ]] || \
    fail "RAMBU_BIND_ADDRESS must remain 127.0.0.1."
  [[ "${APNS_ENVIRONMENT}" == "production" ]] || \
    fail "APNS_ENVIRONMENT must be production for TestFlight."
  [[ "${APNS_BUNDLE_ID}" == "id.rambu.puck" ]] || \
    fail "APNS_BUNDLE_ID must be id.rambu.puck."
}

write_scoped_langflow_environment() {
  python3 - "${RAMBU_LANGFLOW_ENV_FILE}" <<'PY'
import os
from pathlib import Path
import sys
import tempfile

destination = Path(sys.argv[1])
destination.parent.mkdir(parents=True, exist_ok=True)
names = ("LANGFLOW_FLOW_ID", "LANGFLOW_API_KEY", "OPENROUTER_API_KEY")
values = {name: os.environ[name] for name in names}
if any("\n" in value or "\r" in value for value in values.values()):
    raise SystemExit("Langflow environment values must be single-line")
lines = ["LANGFLOW_URL=http://langflow:7860"]
lines.extend(f"{name}={values[name]}" for name in names)
handle, temporary = tempfile.mkstemp(prefix=".langflow-", dir=destination.parent)
try:
    os.fchmod(handle, 0o600)
    with os.fdopen(handle, "w") as output:
        output.write("\n".join(lines) + "\n")
    os.replace(temporary, destination)
except BaseException:
    try:
        os.close(handle)
    except OSError:
        pass
    Path(temporary).unlink(missing_ok=True)
    raise
PY
}

permission_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

require_private_file() {
  local mode
  local path="$1"
  mode="$(permission_mode "${path}")" || fail "Unable to inspect permissions for ${path}."
  [[ "${mode}" == "600" || "${mode}" == "400" ]] || \
    fail "${path} must use mode 600 or 400."
}

port_is_available() {
  python3 - "${RAMBU_BIND_ADDRESS}" "${RAMBU_BIND_PORT}" <<'PY'
import socket
import sys

address, raw_port = sys.argv[1:]
family = socket.AF_INET6 if ":" in address else socket.AF_INET
try:
    with socket.socket(family, socket.SOCK_STREAM) as candidate:
        candidate.bind((address, int(raw_port)))
except OSError:
    raise SystemExit(1)
PY
}

check_bind_port() {
  local existing_backend
  if port_is_available; then
    return 0
  fi
  existing_backend="$(compose ps --status running --quiet backend 2>/dev/null || true)"
  [[ -n "${existing_backend}" ]] || \
    fail "${RAMBU_BIND_ADDRESS}:${RAMBU_BIND_PORT} is already in use by another process."
}

compose() {
  docker compose \
    --project-name rambu-pilot \
    --env-file "${ENVIRONMENT_FILE}" \
    --file "${COMPOSE_FILE}" \
    "$@"
}

validate_compose_networks() {
  local rendered
  rendered="$(compose config --format json 2>/dev/null)" || \
    fail "Docker Compose configuration is invalid."

  if ! printf '%s' "${rendered}" | python3 -c '
import json
import sys

model = json.load(sys.stdin)
services = model.get("services", {})
if set(services) != {"backend", "transcription-bridge", "langflow", "cloudflared"}:
    raise SystemExit(1)
backend = services["backend"]
langflow = services["langflow"]
cloudflared = services["cloudflared"]
bridge = services["transcription-bridge"]
if langflow.get("ports") or bridge.get("ports") or cloudflared.get("ports"):
    raise SystemExit(1)
if any(port.get("host_ip") != "127.0.0.1" for port in backend.get("ports", [])):
    raise SystemExit(1)
if set(backend.get("networks", {})) != {"private", "edge"}:
    raise SystemExit(1)
if set(langflow.get("networks", {})) != {"private"}:
    raise SystemExit(1)
if set(bridge.get("networks", {})) != {"private"}:
    raise SystemExit(1)
if set(cloudflared.get("networks", {})) != {"edge"}:
    raise SystemExit(1)
if cloudflared.get("labels", {}).get("com.rambu.tunnel-origin") != "http://backend:8000":
    raise SystemExit(1)
'; then
    fail "Compose has an unsafe network configuration."
  fi
}

check_requirements() {
  local available_kb
  local command
  local secret_directory="${PILOT_ROOT}/secrets"

  [[ -f "${COMPOSE_FILE}" ]] || fail "Compose file is missing: ${COMPOSE_FILE}"
  load_environment

  for command in docker python3 curl df; do
    command -v "${command}" >/dev/null 2>&1 || fail "${command} is not installed or not on PATH."
  done
  docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is unavailable."

  [[ -r "${secret_directory}/AuthKey.p8" ]] || \
    fail "APNs key is missing or unreadable at ${secret_directory}/AuthKey.p8."
  [[ -r "${secret_directory}/cloudflare-tunnel-token" ]] || \
    fail "Cloudflare tunnel token is missing or unreadable."
  require_private_file "${ENVIRONMENT_FILE}"
  require_private_file "${secret_directory}/AuthKey.p8"
  require_private_file "${secret_directory}/cloudflare-tunnel-token"

  check_bind_port
  write_scoped_langflow_environment

  available_kb="$(df -Pk "${PILOT_ROOT}" | awk 'NR == 2 { print $4 }')"
  [[ "${available_kb}" =~ ^[0-9]+$ ]] || fail "Unable to determine free space for ${PILOT_ROOT}."
  (( available_kb >= MINIMUM_FREE_KB )) || \
    fail "Insufficient free space under ${PILOT_ROOT}; at least $((MINIMUM_FREE_KB / 1024 / 1024)) GiB is required."

  validate_compose_networks
  printf '✓ Pilot server checks passed.\n'
}

prepare_directories() {
  mkdir -p \
    "${PILOT_ROOT}/data/langflow" \
    "${PILOT_ROOT}/backups"
}

backup_database() {
  local backup_directory="${PILOT_ROOT}/backups"
  local database="${PILOT_ROOT}/data/rambu.sqlite3"
  local destination
  local temporary
  local timestamp

  mkdir -p "${backup_directory}"
  if [[ ! -f "${database}" ]]; then
    printf 'No Rambu database exists yet; backup skipped.\n'
    return 0
  fi

  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  destination="${backup_directory}/rambu-${timestamp}.sqlite3"
  temporary="${destination}.tmp"
  [[ ! -e "${destination}" && ! -e "${temporary}" ]] || \
    fail "Backup destination already exists for timestamp ${timestamp}."

  if ! python3 - "${database}" "${temporary}" <<'PY'
import sqlite3
import sys

source_path, destination_path = sys.argv[1:]
with sqlite3.connect(source_path) as source, sqlite3.connect(destination_path) as destination:
    source.backup(destination)
    result = destination.execute("PRAGMA integrity_check").fetchone()
    if result != ("ok",):
        raise RuntimeError(f"backup integrity check failed: {result!r}")
PY
  then
    rm -f "${temporary}"
    fail "SQLite backup failed."
  fi

  chmod 600 "${temporary}"
  mv "${temporary}" "${destination}"
  printf '✓ Backup created: %s\n' "${destination}"
}

wait_for_health() {
  local attempt
  local container_id
  local service="$1"
  local status

  for ((attempt = 1; attempt <= HEALTH_ATTEMPTS; attempt++)); do
    container_id="$(compose ps --status running --quiet "${service}" 2>/dev/null || true)"
    if [[ -n "${container_id}" ]]; then
      status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        "${container_id}" 2>/dev/null || true)"
      if [[ "${status}" == "healthy" ]]; then
        return 0
      fi
    fi
    sleep "${HEALTH_INTERVAL}"
  done

  fail "Timed out waiting for ${service} health."
}

wait_for_public_health() {
  local attempt
  local url="${RAMBU_PUBLIC_URL%/}/health"
  for ((attempt = 1; attempt <= HEALTH_ATTEMPTS; attempt++)); do
    if curl --fail --silent --show-error --max-time 10 "${url}" >/dev/null 2>&1; then
      return 0
    fi
    sleep "${HEALTH_INTERVAL}"
  done
  fail "Timed out waiting for the public Rambu health endpoint."
}

deploy_stack() {
  check_requirements
  prepare_directories
  backup_database

  printf 'Building pinned Rambu images...\n'
  compose build backend transcription-bridge langflow
  compose pull cloudflared

  printf 'Starting private Langflow...\n'
  compose up -d langflow
  wait_for_health langflow

  printf 'Loading the reviewed Rambu flow...\n'
  compose exec -T langflow python /opt/rambu/scripts/bootstrap_flow.py \
    --env-file /run/secrets/rambu.env \
    --flow-file /opt/rambu/flows/Rambu.json

  printf 'Starting the private transcription bridge...\n'
  compose up -d transcription-bridge
  wait_for_health transcription-bridge

  printf 'Starting the Rambu backend...\n'
  compose up -d backend
  wait_for_health backend

  printf 'Starting the Cloudflare tunnel...\n'
  compose up -d cloudflared
  wait_for_public_health
  printf '✓ Rambu pilot is ready at %s\n' "${RAMBU_PUBLIC_URL}"
}

load_redaction_values() {
  load_environment
  RAMBU_TUNNEL_TOKEN="$(<"${PILOT_ROOT}/secrets/cloudflare-tunnel-token")"
  RAMBU_APNS_PRIVATE_KEY="$(<"${PILOT_ROOT}/secrets/AuthKey.p8")"
  export RAMBU_TUNNEL_TOKEN RAMBU_APNS_PRIVATE_KEY
}

redact_stream() {
  python3 -c '
import os
import sys

text = sys.stdin.read()
for name in (
    "LANGFLOW_API_KEY",
    "LANGFLOW_SUPERUSER_PASSWORD",
    "LANGFLOW_SECRET_KEY",
    "OPENROUTER_API_KEY",
    "AI_GATEWAY_API_KEY",
    "APNS_TEAM_ID",
    "APNS_KEY_ID",
    "RAMBU_TUNNEL_TOKEN",
    "RAMBU_APNS_PRIVATE_KEY",
):
    value = os.environ.get(name, "")
    if value:
        text = text.replace(value, "[REDACTED]")
sys.stdout.write(text)
'
}

show_status() {
  load_environment
  compose ps
  if curl --fail --silent --show-error --max-time 5 \
    "http://127.0.0.1:${RAMBU_BIND_PORT:-8000}/health" >/dev/null 2>&1; then
    printf 'Backend health: ready\n'
  else
    printf 'Backend health: unavailable\n'
    return 1
  fi
}

follow_logs() {
  load_redaction_values
  compose logs --follow --tail 100 2>&1 | redact_stream
}

parse_arguments() {
  COMMAND="${1:-}"
  [[ -n "${COMMAND}" ]] || { usage >&2; exit 2; }
  shift || true

  while (($#)); do
    case "$1" in
      --env-file)
        (($# >= 2)) || fail "--env-file requires a path."
        ENVIRONMENT_FILE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
  done

  [[ -n "${ENVIRONMENT_FILE}" ]] || fail "--env-file is required."
  if [[ "${ENVIRONMENT_FILE}" != /* ]]; then
    ENVIRONMENT_FILE="$(cd "$(dirname "${ENVIRONMENT_FILE}")" && pwd)/$(basename "${ENVIRONMENT_FILE}")"
  fi
}

main() {
  parse_arguments "$@"
  case "${COMMAND}" in
    check) check_requirements ;;
    deploy) deploy_stack ;;
    status) show_status ;;
    logs) follow_logs ;;
    backup)
      load_environment
      command -v python3 >/dev/null 2>&1 || fail "python3 is not installed or not on PATH."
      backup_database
      ;;
    *)
      usage >&2
      fail "Unknown command: ${COMMAND}"
      ;;
  esac
}

main "$@"
