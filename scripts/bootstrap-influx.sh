#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -n "${1:-}" ]; then
  ENV_FILE="$1"
elif [ -n "${ENV_FILE:-}" ]; then
  ENV_FILE="$ENV_FILE"
else
  ENV_FILE="$STACK_DIR/.env"
fi

if [ ! -f "$ENV_FILE" ]; then
  echo "[ipc] missing $ENV_FILE (run install.sh first)" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

SECRETS_DIR="${IPC_SECRETS_DIR:-$STACK_DIR/.secrets}"

INFLUX_URL="${INFLUX_URL:-http://127.0.0.1:8086}"
if [ -n "${INFLUX_BOOTSTRAP_URL:-}" ]; then
  INFLUX_URL="$INFLUX_BOOTSTRAP_URL"
elif echo "$INFLUX_URL" | grep -q "://influxdb:"; then
  INFLUX_URL="http://127.0.0.1:8086"
fi
INFLUX_ORG="${INFLUX_ORG:-edge-org}"
EDGE_BUCKET="${INFLUX_BUCKET:-edge-site}"

ADMIN_TOKEN_FILE="$SECRETS_DIR/influx.admin.token"

if [ ! -s "$ADMIN_TOKEN_FILE" ]; then
  echo "[ipc] missing admin token at $ADMIN_TOKEN_FILE" >&2
  exit 1
fi
ADMIN_TOKEN="$(cat "$ADMIN_TOKEN_FILE")"

log() { echo "[ipc-influx] $*"; }

CURL_CONNECT_TIMEOUT_S="${INFLUX_CURL_CONNECT_TIMEOUT_S:-2}"
CURL_MAX_TIME_S="${INFLUX_CURL_MAX_TIME_S:-10}"
CURL_ARGS=(--connect-timeout "$CURL_CONNECT_TIMEOUT_S" --max-time "$CURL_MAX_TIME_S")

wait_influx() {
  local tries=60
  local total="$tries"
  while [ $tries -gt 0 ]; do
    if curl "${CURL_ARGS[@]}" -fsS "$INFLUX_URL/health" >/dev/null 2>&1; then
      return 0
    fi
    tries=$((tries - 1))
    if [ $((tries % 10)) -eq 0 ]; then
      log "waiting for influx at $INFLUX_URL ($((total - tries))/${total})"
    fi
    sleep 2
  done
  return 1
}

if ! wait_influx; then
  echo "[ipc] influx not ready at $INFLUX_URL" >&2
  exit 1
fi

log "querying org $INFLUX_ORG"
org_json="$(curl "${CURL_ARGS[@]}" -fsS -H "Authorization: Token $ADMIN_TOKEN" \
  "$INFLUX_URL/api/v2/orgs?org=$INFLUX_ORG")"

ORG_ID="$(python3 -c 'import json,sys
data=json.load(sys.stdin)
orgs=data.get("orgs") or []
print(orgs[0]["id"] if orgs else "")
' <<<"$org_json")"

if [ -z "$ORG_ID" ]; then
  echo "[ipc] org not found: $INFLUX_ORG" >&2
  exit 1
fi


log "querying buckets in org $INFLUX_ORG"
bucket_json="$(curl "${CURL_ARGS[@]}" -fsS -H "Authorization: Token $ADMIN_TOKEN" "$INFLUX_URL/api/v2/buckets?org=$INFLUX_ORG")"

bucket_id() {
  local name="$1"
  BUCKET_NAME="$name" BUCKET_JSON="$bucket_json" python3 - <<'PY'
import json, os
name = os.environ.get("BUCKET_NAME", "")
data = json.loads(os.environ.get("BUCKET_JSON", "{}"))
for b in data.get("buckets", []):
    if b.get("name") == name:
        print(b.get("id"))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

EDGE_BUCKET_ID="$(bucket_id "$EDGE_BUCKET" <<<"$bucket_json" || true)"
if [ -z "$EDGE_BUCKET_ID" ]; then
  log "creating bucket $EDGE_BUCKET"
  curl "${CURL_ARGS[@]}" -fsS -H "Authorization: Token $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -X POST "$INFLUX_URL/api/v2/buckets" \
    -d "$(python3 - <<PY
import json
print(json.dumps({"orgID": "$ORG_ID", "name": "$EDGE_BUCKET"}))
PY
)" >/dev/null
  bucket_json="$(curl "${CURL_ARGS[@]}" -fsS -H "Authorization: Token $ADMIN_TOKEN" "$INFLUX_URL/api/v2/buckets?org=$INFLUX_ORG")"
  EDGE_BUCKET_ID="$(bucket_id "$EDGE_BUCKET" <<<"$bucket_json")"
fi

log "influx bootstrap done"
