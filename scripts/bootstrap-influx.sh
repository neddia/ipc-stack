#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -n "${1:-}" ]; then
  ENV_FILE="$1"
elif [ -f "$STACK_DIR/.env.dev" ]; then
  ENV_FILE="$STACK_DIR/.env.dev"
else
  ENV_FILE="$STACK_DIR/.env"
fi
SECRETS_DIR="${IPC_SECRETS_DIR:-$STACK_DIR/.secrets}"

if [ ! -f "$ENV_FILE" ]; then
  echo "[ipc] missing $ENV_FILE (run install.sh first)" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

INFLUX_URL="${INFLUX_URL:-http://127.0.0.1:8086}"
if [ -n "${INFLUX_BOOTSTRAP_URL:-}" ]; then
  INFLUX_URL="$INFLUX_BOOTSTRAP_URL"
elif echo "$INFLUX_URL" | grep -q "://influxdb:"; then
  INFLUX_URL="http://127.0.0.1:8086"
fi
INFLUX_ORG="${INFLUX_ORG:-edge-org}"
EDGE_BUCKET="${INFLUX_BUCKET:-edge-site}"
TELEGRAF_BUCKET="${TELEGRAF_BUCKET:-telegraf}"
TELEGRAF_RETENTION="${TELEGRAF_RETENTION:-14d}"

ADMIN_TOKEN_FILE="$SECRETS_DIR/influx.admin.token"
TELEGRAF_TOKEN_FILE="$SECRETS_DIR/influx.telegraf.token"

if [ ! -s "$ADMIN_TOKEN_FILE" ]; then
  echo "[ipc] missing admin token at $ADMIN_TOKEN_FILE" >&2
  exit 1
fi
ADMIN_TOKEN="$(cat "$ADMIN_TOKEN_FILE")"

log() { echo "[ipc-influx] $*"; }

wait_influx() {
  local tries=60
  while [ $tries -gt 0 ]; do
    if curl -fsS "$INFLUX_URL/health" >/dev/null 2>&1; then
      return 0
    fi
    tries=$((tries - 1))
    sleep 2
  done
  return 1
}

if ! wait_influx; then
  echo "[ipc] influx not ready at $INFLUX_URL" >&2
  exit 1
fi

org_json="$(curl -fsS -H "Authorization: Token $ADMIN_TOKEN" "$INFLUX_URL/api/v2/orgs?org=$INFLUX_ORG")"
ORG_ID="$(python3 - <<'PY'
import json, sys
data = json.load(sys.stdin)
orgs = data.get("orgs") or []
if not orgs:
    raise SystemExit(1)
print(orgs[0]["id"])
PY
<<<"$org_json")" || {
  echo "[ipc] org not found: $INFLUX_ORG" >&2
  exit 1
}

bucket_json="$(curl -fsS -H "Authorization: Token $ADMIN_TOKEN" "$INFLUX_URL/api/v2/buckets?org=$INFLUX_ORG")"

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
  curl -fsS -H "Authorization: Token $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -X POST "$INFLUX_URL/api/v2/buckets" \
    -d "$(python3 - <<PY
import json
print(json.dumps({"orgID": "$ORG_ID", "name": "$EDGE_BUCKET"}))
PY
)" >/dev/null
  bucket_json="$(curl -fsS -H "Authorization: Token $ADMIN_TOKEN" "$INFLUX_URL/api/v2/buckets?org=$INFLUX_ORG")"
  EDGE_BUCKET_ID="$(bucket_id "$EDGE_BUCKET" <<<"$bucket_json")"
fi

TELEGRAF_BUCKET_ID="$(bucket_id "$TELEGRAF_BUCKET" <<<"$bucket_json" || true)"
if [ -z "$TELEGRAF_BUCKET_ID" ]; then
  log "creating bucket $TELEGRAF_BUCKET (retention $TELEGRAF_RETENTION)"
  curl -fsS -H "Authorization: Token $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -X POST "$INFLUX_URL/api/v2/buckets" \
    -d "$(python3 - <<PY
import json, re
ret = "$TELEGRAF_RETENTION".strip()
rules = []
if ret and ret not in ("0", "0s", "infinite", "none"):
    m = re.match(r"^(\d+)([smhdw])$", ret)
    if not m:
        raise SystemExit("invalid TELEGRAF_RETENTION")
    n = int(m.group(1))
    unit = m.group(2)
    mult = {"s":1,"m":60,"h":3600,"d":86400,"w":604800}[unit]
    rules = [{"type":"expire","everySeconds": n*mult}]
payload = {"orgID": "$ORG_ID", "name": "$TELEGRAF_BUCKET"}
if rules:
    payload["retentionRules"] = rules
print(json.dumps(payload))
PY
)" >/dev/null
  bucket_json="$(curl -fsS -H "Authorization: Token $ADMIN_TOKEN" "$INFLUX_URL/api/v2/buckets?org=$INFLUX_ORG")"
  TELEGRAF_BUCKET_ID="$(bucket_id "$TELEGRAF_BUCKET" <<<"$bucket_json")"
fi

if [ -s "$TELEGRAF_TOKEN_FILE" ]; then
  log "telegraf token already exists"
  chmod 644 "$TELEGRAF_TOKEN_FILE" || true
else
  log "creating telegraf token (write to $EDGE_BUCKET + $TELEGRAF_BUCKET)"
  token_json="$(curl -fsS -H "Authorization: Token $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -X POST "$INFLUX_URL/api/v2/authorizations" \
    -d "$(python3 - <<PY
import json
payload = {
  "orgID": "$ORG_ID",
  "description": "ipc-telegraf-writer",
  "permissions": [
    {"action": "write", "resource": {"type": "buckets", "id": "$EDGE_BUCKET_ID"}},
    {"action": "write", "resource": {"type": "buckets", "id": "$TELEGRAF_BUCKET_ID"}},
  ],
}
print(json.dumps(payload))
PY
)" )"
  token="$(python3 - <<'PY'
import json, sys
data = json.load(sys.stdin)
print(data.get("token") or "")
PY
<<<"$token_json")"
  if [ -z "$token" ]; then
    echo "[ipc] failed to create telegraf token" >&2
    exit 1
  fi
  printf '%s' "$token" > "$TELEGRAF_TOKEN_FILE"
  chmod 644 "$TELEGRAF_TOKEN_FILE" || true
fi

log "influx bootstrap done"
