#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIRECTORY}/.." && pwd)"
BACKEND_ENVIRONMENT_FILE="${REPOSITORY_ROOT}/backend/.env"
MENU_APP="${REPOSITORY_ROOT}/build/Rambu Puck.app"
PUBLIC_URL="${RAMBU_PUBLIC_URL:-https://rambu-api.sfatimah.com}"
BACKEND_URL="http://127.0.0.1:8001"
TUNNEL_TOKEN_FILE="${RAMBU_TUNNEL_TOKEN_FILE:-${HOME}/.config/rambu/cloudflare-tunnel-token}"
HEALTH_ATTEMPTS="${RAMBU_HEALTH_ATTEMPTS:-60}"
HEALTH_INTERVAL="${RAMBU_HEALTH_INTERVAL:-0.5}"

usage() {
  cat <<'EOF'
Usage: tools/run_stable_mac_server.sh [--check]

Start the persistent-address Rambu stack on this Mac:
  Langflow, backend, a named Cloudflare Tunnel, and the Rambu Puck menu app.

The Cloudflare tunnel must publish:
  https://rambu-api.sfatimah.com -> http://localhost:8001

Store its token outside the repository at:
  ~/.config/rambu/cloudflare-tunnel-token

Options:
  --check   Validate requirements without starting services.
  -h, --help
            Show this help.
EOF
}

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

environment_value() {
  awk -F= -v key="$1" '
    $1 == key {
      sub(/^[^=]*=/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      if (($0 ~ /^".*"$/) || ($0 ~ /^\047.*\047$/)) {
        $0 = substr($0, 2, length($0) - 2)
      }
      print
      exit
    }
  ' "${BACKEND_ENVIRONMENT_FILE}"
}

file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

check_requirements() {
  local command
  local mode
  local private_key_path
  local variable

  for command in uv cloudflared curl open; do
    command -v "${command}" >/dev/null 2>&1 || fail "${command} is not installed or not on PATH."
  done

  [[ "${PUBLIC_URL}" == "https://rambu-api.sfatimah.com" ]] || \
    fail "RAMBU_PUBLIC_URL must be https://rambu-api.sfatimah.com."
  [[ -f "${BACKEND_ENVIRONMENT_FILE}" ]] || \
    fail "backend/.env is missing. Copy backend/.env.example and configure it first."
  [[ -x "${REPOSITORY_ROOT}/langflow/.venv/bin/langflow" ]] || \
    fail "langflow/.venv is missing. Follow the Langflow setup in README.md first."
  [[ -d "${MENU_APP}" ]] || \
    fail "Rambu Puck.app is missing. Run ./tools/package_rambu_puck_controller.sh first."
  [[ -f "${TUNNEL_TOKEN_FILE}" ]] || \
    fail "Cloudflare tunnel token file is missing. Create ${TUNNEL_TOKEN_FILE} with mode 600."
  [[ -s "${TUNNEL_TOKEN_FILE}" ]] || fail "Cloudflare tunnel token file is empty."

  mode="$(file_mode "${TUNNEL_TOKEN_FILE}")" || \
    fail "Could not inspect Cloudflare tunnel token file permissions."
  case "${mode}" in
    400|600) ;;
    *) fail "Cloudflare tunnel token file must only be readable by its owner. Run: chmod 600 ${TUNNEL_TOKEN_FILE}" ;;
  esac

  for variable in \
    LANGFLOW_URL LANGFLOW_FLOW_ID LANGFLOW_API_KEY OPENROUTER_API_KEY \
    APNS_TEAM_ID APNS_KEY_ID APNS_PRIVATE_KEY_PATH APNS_BUNDLE_ID APNS_ENVIRONMENT; do
    [[ -n "$(environment_value "${variable}")" ]] || \
      fail "${variable} is missing from backend/.env."
  done

  [[ "$(environment_value APNS_ENVIRONMENT)" == "production" ]] || \
    fail "APNS_ENVIRONMENT must be production for TestFlight devices."
  [[ "$(environment_value APNS_BUNDLE_ID)" == "id.rambu.puck" ]] || \
    fail "APNS_BUNDLE_ID must be id.rambu.puck for this TestFlight build."

  private_key_path="$(environment_value APNS_PRIVATE_KEY_PATH)"
  if [[ "${private_key_path}" != /* ]]; then
    private_key_path="${REPOSITORY_ROOT}/${private_key_path}"
  fi
  [[ -f "${private_key_path}" ]] || \
    fail "APNS private key file does not exist at the configured path."
}

service_is_ready() {
  curl --fail --silent --show-error --max-time 3 "$1" >/dev/null 2>&1
}

rambu_backend_is_ready() {
  local response

  response="$(curl --fail --silent --show-error --max-time 3 "$1" 2>/dev/null)" || return 1
  [[ "${response}" == *'"status":"ready"'* ]]
}

OWNED_PIDS=""
LAST_STARTED_PID=""
LOG_DIRECTORY=""

start_background_process() {
  local log_file="$1"
  shift
  "$@" >"${log_file}" 2>&1 &
  LAST_STARTED_PID=$!
  OWNED_PIDS="${LAST_STARTED_PID} ${OWNED_PIDS}"
}

show_log_tail() {
  local log_file="$1"
  if [[ -f "${log_file}" ]]; then
    printf '\nLast output from %s:\n' "${log_file}" >&2
    tail -n 20 "${log_file}" >&2 || true
  fi
}

wait_for_service() {
  local label="$1"
  local url="$2"
  local pid="$3"
  local log_file="$4"
  local readiness_probe="${5:-service_is_ready}"
  local attempt

  for attempt in $(seq 1 "${HEALTH_ATTEMPTS}"); do
    if "${readiness_probe}" "${url}"; then
      return 0
    fi
    if [[ -n "${pid}" ]] && ! kill -0 "${pid}" 2>/dev/null; then
      show_log_tail "${log_file}"
      fail "${label} stopped before it became ready."
    fi
    sleep "${HEALTH_INTERVAL}"
  done

  show_log_tail "${log_file}"
  fail "Timed out waiting for ${label}."
}

cleanup() {
  local exit_status=$?
  local pid
  trap - EXIT INT TERM

  for pid in ${OWNED_PIDS}; do
    if kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
    fi
  done
  for pid in ${OWNED_PIDS}; do
    wait "${pid}" 2>/dev/null || true
  done
  if [[ -n "${LOG_DIRECTORY}" ]]; then
    printf '\nRambu stable server stopped. Logs: %s\n' "${LOG_DIRECTORY}"
  fi
  exit "${exit_status}"
}

run_server() {
  local backend_log
  local bootstrap_log
  local langflow_log
  local tunnel_log
  local tunnel_pid

  check_requirements
  cd "${REPOSITORY_ROOT}"

  if [[ -n "${RAMBU_STABLE_LOG_DIRECTORY:-}" ]]; then
    LOG_DIRECTORY="${RAMBU_STABLE_LOG_DIRECTORY}"
    mkdir -p "${LOG_DIRECTORY}"
  else
    LOG_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/rambu-stable.XXXXXX")"
  fi
  langflow_log="${LOG_DIRECTORY}/langflow.log"
  bootstrap_log="${LOG_DIRECTORY}/bootstrap.log"
  backend_log="${LOG_DIRECTORY}/backend.log"
  tunnel_log="${LOG_DIRECTORY}/cloudflared.log"
  trap cleanup EXIT
  trap 'exit 130' INT TERM

  printf 'Starting Rambu stable Mac server...\n'

  if service_is_ready "http://127.0.0.1:7861/health"; then
    printf '✓ Langflow is already running.\n'
  else
    start_background_process "${langflow_log}" \
      "${REPOSITORY_ROOT}/langflow/.venv/bin/langflow" run --host 127.0.0.1 --port 7861
    wait_for_service "Langflow" "http://127.0.0.1:7861/health" "${LAST_STARTED_PID}" "${langflow_log}"
    printf '✓ Langflow is ready.\n'
  fi

  printf 'Checking the Rambu Langflow flow...\n'
  if ! uv run --project backend --env-file backend/.env \
    python langflow/scripts/bootstrap_flow.py >"${bootstrap_log}" 2>&1; then
    show_log_tail "${bootstrap_log}"
    fail "Langflow flow bootstrap failed."
  fi
  printf '✓ Langflow flow is ready.\n'

  if rambu_backend_is_ready "${BACKEND_URL}/health"; then
    printf '✓ Backend is already running.\n'
  else
    start_background_process "${backend_log}" \
      uv run --project backend uvicorn rambu_api.app:app \
      --host 127.0.0.1 --port 8001 --env-file backend/.env
    wait_for_service "backend" "${BACKEND_URL}/health" \
      "${LAST_STARTED_PID}" "${backend_log}" rambu_backend_is_ready
    printf '✓ Backend is ready.\n'
  fi

  start_background_process "${tunnel_log}" \
    cloudflared tunnel --no-autoupdate run --token-file "${TUNNEL_TOKEN_FILE}"
  tunnel_pid="${LAST_STARTED_PID}"
  wait_for_service "public backend at ${PUBLIC_URL}" \
    "${PUBLIC_URL}/health" "${tunnel_pid}" "${tunnel_log}" rambu_backend_is_ready
  printf '✓ Named Cloudflare Tunnel is ready.\n'

  if ! open "${MENU_APP}"; then
    fail "Could not open Rambu Puck.app."
  fi

  printf '\nRambu is ready at %s\n' "${PUBLIC_URL}"
  printf 'The menu-bar app is the puck. Pair it there, then start listening for the demo.\n'
  printf 'Keep this terminal open. Press Ctrl+C to stop the server and tunnel.\n\n'

  if ! wait "${tunnel_pid}"; then
    show_log_tail "${tunnel_log}"
    fail "The named Cloudflare Tunnel stopped unexpectedly."
  fi
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  --check)
    check_requirements
    printf 'Rambu stable Mac server prerequisites are ready.\n'
    exit 0
    ;;
  "")
    run_server
    ;;
  *)
    usage >&2
    fail "Unknown option: $1"
    ;;
esac
