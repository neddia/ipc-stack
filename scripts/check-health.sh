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
- Telegraf     a cpu-total point written within the last 2 minutes
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

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

log() { echo "[ipc-health] $*"; }

health_host() {
  local bind_host="$1"
  if [ -z "$bind_host" ] || [ "$bind_host" = "0.0.0.0" ]; then
    echo "127.0.0.1"
  else
    echo "$bind_host"
  fi
}

INFLUX_HEALTH_HOST="$(health_host "${INFLUX_BIND_HOST:-127.0.0.1}")"
GATEWAYD_HEALTH_HOST="$(health_host "${GATEWAYD_BIND_HOST:-127.0.0.1}")"
SITE_AGENT_HEALTH_HOST="$(health_host "${SITE_AGENT_BIND_HOST:-127.0.0.1}")"
INFLUX_HEALTH_URL="${INFLUX_HEALTH_URL:-http://${INFLUX_HEALTH_HOST}:${INFLUX_HOST_PORT:-8086}/health}"
INFLUX_API_URL="${INFLUX_API_URL:-${INFLUX_HEALTH_URL%/health}}"
GATEWAYD_HEALTH_URL="${GATEWAYD_HEALTH_URL:-http://${GATEWAYD_HEALTH_HOST}:${GATEWAYD_HOST_PORT:-8080}/healthz}"
GATEWAYD_READY_URL="${GATEWAYD_READY_URL:-http://${GATEWAYD_HEALTH_HOST}:${GATEWAYD_HOST_PORT:-8080}/readyz}"
SITE_AGENT_HEALTH_URL="${SITE_AGENT_HEALTH_URL:-http://${SITE_AGENT_HEALTH_HOST}:${SITE_AGENT_HOST_PORT:-8000}/ui/settings/status}"
SECRETS_DIR="${IPC_SECRETS_DIR:-$STACK_DIR/.secrets}"
INFLUX_ADMIN_TOKEN_FILE="$SECRETS_DIR/influx.admin.token"
INFLUX_ORG="${INFLUX_ORG:-edge-org}"
TELEGRAF_BUCKET="${TELEGRAF_BUCKET:-telegraf}"

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

check_telegraf_freshness() {
  local token csv flux
  if [ ! -s "$INFLUX_ADMIN_TOKEN_FILE" ]; then
    echo "telegraf_check_missing_admin_token"
    return 1
  fi
  token="$(tr -d '\r\n' < "$INFLUX_ADMIN_TOKEN_FILE")"
  flux="from(bucket: \"${TELEGRAF_BUCKET}\") |> range(start: -2m) |> filter(fn: (r) => r._measurement == \"cpu\" and r.cpu == \"cpu-total\") |> last() |> keep(columns: [\"_time\"])"
  csv="$(curl --connect-timeout 2 --max-time 8 -fsS \
    -H "Authorization: Token $token" \
    -H "Accept: application/csv" \
    -H "Content-Type: application/vnd.flux" \
    --data-binary "$flux" \
    "$INFLUX_API_URL/api/v2/query?org=$INFLUX_ORG" 2>/dev/null || true)"
  if ! awk 'BEGIN { rows=0 } !/^#/ && NF { rows++ } END { exit(rows >= 2 ? 0 : 1) }' <<<"$csv"; then
    echo "telegraf_metrics_stale"
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
  if ! last_err="$(check_endpoint influx "$INFLUX_HEALTH_URL" '"status":"pass"')"; then
    sleep 2
    continue
  fi
  if ! last_err="$(check_telegraf_freshness)"; then
    sleep 2
    continue
  fi
  if ! last_err="$(check_endpoint gatewayd_health "$GATEWAYD_HEALTH_URL" '"ok"[[:space:]]*:[[:space:]]*true')"; then
    sleep 2
    continue
  fi
  if ! last_err="$(check_endpoint gatewayd_ready "$GATEWAYD_READY_URL" '"ok"[[:space:]]*:[[:space:]]*true')"; then
    sleep 2
    continue
  fi
  if ! last_err="$(check_endpoint site_agent "$SITE_AGENT_HEALTH_URL" '"ok"[[:space:]]*:[[:space:]]*true')"; then
    sleep 2
    continue
  fi
  log "stack healthy"
  exit 0
done

echo "[ipc-health] failed: ${last_err}" >&2
docker compose -f "$STACK_DIR/compose.yml" --env-file "$ENV_FILE" ps || true
exit 1
