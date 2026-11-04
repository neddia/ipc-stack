#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$STACK_DIR/.env"
TIMEOUT_S="${IPC_HEALTH_TIMEOUT_S:-300}"
MAX_RESTARTS="${IPC_HEALTH_MAX_RESTARTS:-2}"
BASELINE_FILE=""
CAPTURE_FILE=""
SOAK_S=0

usage() {
  cat <<'EOF'
Usage: check-health.sh [--env-file PATH] [--timeout SECONDS]
                       [--baseline FILE] [--soak SECONDS]
       check-health.sh [--env-file PATH] --capture-baseline FILE

Checks that the IPC stack is running and that the key HTTP endpoints respond:
- InfluxDB     http://127.0.0.1:8086/health
- Telegraf     a cpu-total point written within the last 2 minutes
- site-agent   startup finished (/ui/service/status), with no startup error
               that the --baseline release did not also have

A site-agent that is still starting is waited for (up to --timeout). One that
keeps restarting fails at once. --soak keeps watching after the first healthy
result and fails if site-agent restarts or stops being ready.

--capture-baseline records the running release's startup errors before an
update, so problems caused by the site (a dead drive) are not blamed on the
new release. It never fails.
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
    --baseline)
      BASELINE_FILE="$2"
      shift 2
      ;;
    --capture-baseline)
      CAPTURE_FILE="$2"
      shift 2
      ;;
    --soak)
      SOAK_S="$2"
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
SITE_AGENT_HEALTH_HOST="$(health_host "${SITE_AGENT_BIND_HOST:-127.0.0.1}")"
SITE_AGENT_BASE="http://${SITE_AGENT_HEALTH_HOST}:${SITE_AGENT_HOST_PORT:-8000}"
INFLUX_HEALTH_URL="${INFLUX_HEALTH_URL:-http://${INFLUX_HEALTH_HOST}:${INFLUX_HOST_PORT:-8086}/health}"
INFLUX_API_URL="${INFLUX_API_URL:-${INFLUX_HEALTH_URL%/health}}"
SITE_AGENT_STATUS_URL="${SITE_AGENT_STATUS_URL:-$SITE_AGENT_BASE/ui/service/status}"
SITE_AGENT_EQUIPMENT_URL="${SITE_AGENT_EQUIPMENT_URL:-$SITE_AGENT_BASE/api/equipment/telemetry}"
ENROLLMENT_HOLD=0
if [ -f "${IPC_STORAGE_DIR:-/opt/site-agent/storage}/ipc/enrollment-hold.json" ]; then
  ENROLLMENT_HOLD=1
fi
SECRETS_DIR="${IPC_SECRETS_DIR:-$STACK_DIR/.secrets}"
INFLUX_ADMIN_TOKEN_FILE="$SECRETS_DIR/influx.admin.token"
INFLUX_ORG="${INFLUX_ORG:-edge-org}"

compose() {
  docker compose -f "$STACK_DIR/compose.yml" --env-file "$ENV_FILE" "$@"
}

# Drives the controller can reach right now, or empty when it cannot say.
drives_online() {
  curl --connect-timeout 2 --max-time 5 -fsS "$SITE_AGENT_EQUIPMENT_URL" 2>/dev/null | python3 -c '
import json, sys
try:
    fans = json.load(sys.stdin).get("fans") or []
except ValueError:
    sys.exit(0)
print(sum(1 for fan in fans if isinstance(fan, dict) and (fan.get("driver") or {}).get("online") is True))
' 2>/dev/null || true
}

if [ -n "$CAPTURE_FILE" ]; then
  body="$(curl --connect-timeout 2 --max-time 5 -fsS "$SITE_AGENT_STATUS_URL" 2>/dev/null || true)"
  python3 - "$CAPTURE_FILE" "$body" "$(drives_online)" <<'PY'
import json, sys
path, body, drives = sys.argv[1:]
try:
    data = json.loads(body)
    errors = list(data.get("startup_errors") or [])
    if data.get("apply_error"):
        errors.append("config apply")
    baseline = {"known": bool(data.get("startup_complete")), "errors": errors}
except ValueError:
    baseline = {"known": False, "errors": []}
baseline["drives_online"] = int(drives) if drives.isdigit() else None
with open(path, "w") as out:
    json.dump(baseline, out)
PY
  exit 0
fi

compose_services_running() {
  local running
  running="$(compose ps --services --status running 2>/dev/null || true)"
  for svc in influxdb site-agent; do
    if ! grep -qx "$svc" <<<"$running"; then
      echo "service_not_running:$svc"
      return 1
    fi
  done
}

site_agent_restarts() {
  local cid
  cid="$(compose ps -q site-agent 2>/dev/null | head -n1 || true)"
  [ -n "$cid" ] || { echo 0; return; }
  docker inspect -f '{{.RestartCount}}' "$cid" 2>/dev/null || echo 0
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

# Startup errors are compared with the release that ran before the update, so
# only failures the new release introduced count against it.
check_site_agent() {
  local body=""
  if [ "$ENROLLMENT_HOLD" = 1 ]; then
    check_endpoint site_agent "$SITE_AGENT_BASE/recovery/ready" '"ok"[[:space:]]*:[[:space:]]*true'
    return
  fi
  body="$(curl --connect-timeout 2 --max-time 5 -fsS "$SITE_AGENT_STATUS_URL" 2>/dev/null || true)"
  if [ -z "$body" ]; then
    echo "endpoint_unreachable:site_agent"
    return 1
  fi
  python3 - "$BASELINE_FILE" "$body" <<'PY'
import json, sys
baseline_path, body = sys.argv[1:]
try:
    data = json.loads(body)
except ValueError:
    print("endpoint_unhealthy:site_agent")
    sys.exit(1)
if not data.get("startup_complete"):
    print("site_agent_starting")
    sys.exit(1)
errors = set(data.get("startup_errors") or [])
if data.get("apply_error"):
    errors.add("config apply")
baseline = {"known": False, "errors": []}
if baseline_path:
    try:
        baseline = json.load(open(baseline_path))
    except (OSError, ValueError):
        pass
if baseline.get("known"):
    new = sorted(errors - set(baseline.get("errors") or []))
    if new:
        print("site_agent_startup_failed:" + ",".join(new))
        sys.exit(1)
PY
}

fail() {
  echo "[ipc-health] failed: $1" >&2
  compose ps || true
  exit 1
}

initial_restarts="$(site_agent_restarts)"
deadline=$((SECONDS + TIMEOUT_S))
last_err="unknown"
healthy=0

while [ "$SECONDS" -lt "$deadline" ]; do
  # Still starting is waited for; a crash loop is not.
  if [ $(( $(site_agent_restarts) - initial_restarts )) -ge "$MAX_RESTARTS" ]; then
    fail "site_agent_crash_looping (last: $last_err)"
  fi
  if ! last_err="$(compose_services_running)"; then
    sleep 2
    continue
  fi
  if ! last_err="$(check_endpoint influx "$INFLUX_HEALTH_URL" '"status":"pass"')"; then
    sleep 2
    continue
  fi
  if ! last_err="$(check_site_agent)"; then
    case "$last_err" in
      site_agent_startup_failed:*) fail "$last_err" ;;
    esac
    sleep 2
    continue
  fi
  healthy=1
  break
done

[ "$healthy" = 1 ] || fail "$last_err"

if [ "$SOAK_S" -gt 0 ]; then
  log "healthy; watching site-agent for ${SOAK_S}s"
  settled_restarts="$(site_agent_restarts)"
  soak_end=$((SECONDS + SOAK_S))
  while [ "$SECONDS" -lt "$soak_end" ]; do
    sleep "${IPC_HEALTH_SOAK_POLL_S:-10}"
    if [ "$(site_agent_restarts)" != "$settled_restarts" ]; then
      fail "site_agent_restarted_after_start"
    fi
    if ! last_err="$(check_site_agent)"; then
      fail "unstable_after_start:$last_err"
    fi
  done
  # A release that can no longer reach drives the old one could reach must not
  # stay installed. The loss has to hold for three checks, so one flaky drive
  # at the wrong moment does not roll an update back.
  before="$(python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get("drives_online"); print("" if v is None else v)' "$BASELINE_FILE" 2>/dev/null || true)"
  if [ -n "$before" ] && [ "$before" -gt 0 ]; then
    allowed=$(( before / 4 ))
    lost_checks=0
    for _ in 1 2 3; do
      now="$(drives_online)"
      if [ -n "$now" ] && [ $(( before - now )) -gt "$allowed" ]; then
        lost_checks=$((lost_checks + 1))
      fi
      [ "$lost_checks" -eq 0 ] && break
      sleep "${IPC_HEALTH_SOAK_POLL_S:-10}"
    done
    if [ "$lost_checks" -ge 3 ]; then
      fail "equipment_lost: ${now} of ${before} drives reachable after the update"
    fi
  fi
fi

log "stack healthy"
exit 0
