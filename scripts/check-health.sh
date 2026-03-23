#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$STACK_DIR/.env"
TIMEOUT_S="${IPC_HEALTH_TIMEOUT_S:-90}"

usage() {
  cat <<'EOF'
Usage: check-health.sh [--env-file PATH] [--timeout SECONDS]

Checks that the IPC stack is running and that the key HTTP endpoints respond:
- InfluxDB     http://127.0.0.1:8086/health
- gatewayd     http://127.0.0.1:8080/healthz
- gatewayd     http://127.0.0.1:8080/readyz
- site-agent   http://127.0.0.1:8000/ui/settings/status
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file)
      ENV_FILE="$2"
      shift 2
      ;;
    --timeout)
      TIMEOUT_S="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[ipc-health] unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ ! -f "$ENV_FILE" ]; then
  echo "[ipc-health] missing env file: $ENV_FILE" >&2
  exit 1
fi

log() { echo "[ipc-health] $*"; }

compose_services_running() {
  local running
  running="$(docker compose -f "$STACK_DIR/compose.yml" --env-file "$ENV_FILE" ps --services --status running 2>/dev/null || true)"
  for svc in influxdb site-agent gatewayd telegraf; do
    if ! grep -qx "$svc" <<<"$running"; then
      echo "service_not_running:$svc"
      return 1
    fi
  done
}

check_endpoint() {
  local name="$1"
  local url="$2"
  local pattern="$3"
  local body=""
  body="$(curl --connect-timeout 2 --max-time 5 -fsS "$url" 2>/dev/null || true)"
  if [ -z "$body" ]; then
    echo "endpoint_unreachable:$name"
    return 1
  fi
  if ! grep -q "$pattern" <<<"$body"; then
    echo "endpoint_unhealthy:$name"
    return 1
  fi
}

deadline=$((SECONDS + TIMEOUT_S))
last_err="unknown"

while [ "$SECONDS" -lt "$deadline" ]; do
  if ! last_err="$(compose_services_running)"; then
    sleep 2
    continue
  fi
  if ! last_err="$(check_endpoint influx http://127.0.0.1:8086/health '"status":"pass"')"; then
    sleep 2
    continue
  fi
  if ! last_err="$(check_endpoint gatewayd_health http://127.0.0.1:8080/healthz '"ok"[[:space:]]*:[[:space:]]*true')"; then
    sleep 2
    continue
  fi
  if ! last_err="$(check_endpoint gatewayd_ready http://127.0.0.1:8080/readyz '"ok"[[:space:]]*:[[:space:]]*true')"; then
    sleep 2
    continue
  fi
  if ! last_err="$(check_endpoint site_agent http://127.0.0.1:8000/ui/settings/status '"ok"[[:space:]]*:[[:space:]]*true')"; then
    sleep 2
    continue
  fi
  log "stack healthy"
  exit 0
done

echo "[ipc-health] failed: ${last_err}" >&2
docker compose -f "$STACK_DIR/compose.yml" --env-file "$ENV_FILE" ps || true
exit 1
