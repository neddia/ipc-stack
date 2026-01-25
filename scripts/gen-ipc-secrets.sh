#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR="$STACK_DIR/.secrets"

mkdir -p "$SECRETS_DIR"
if [ -n "${SITE_AGENT_UID:-}" ] && [ -n "${SITE_AGENT_GID:-}" ]; then
  if [[ "$SITE_AGENT_UID" =~ ^[0-9]+$ ]] && [[ "$SITE_AGENT_GID" =~ ^[0-9]+$ ]]; then
    chown "$SITE_AGENT_UID:$SITE_AGENT_GID" "$SECRETS_DIR" || true
  fi
fi

rand() {
  # 32 chars base64-ish
  python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(24))
PY
}

write_secret() {
  local path="$1"
  local value="$2"
  if [ -s "$path" ]; then
    return
  fi
  printf '%s' "$value" > "$path"
  chmod 600 "$path" || true
}

write_secret "$SECRETS_DIR/influx.admin.user" "ipc-admin"
write_secret "$SECRETS_DIR/influx.admin.pass" "$(rand)"
write_secret "$SECRETS_DIR/influx.admin.token" "$(rand)"

if [ -n "${SITE_AGENT_UID:-}" ] && [ -n "${SITE_AGENT_GID:-}" ]; then
  if [[ "$SITE_AGENT_UID" =~ ^[0-9]+$ ]] && [[ "$SITE_AGENT_GID" =~ ^[0-9]+$ ]]; then
    chown "$SITE_AGENT_UID:$SITE_AGENT_GID" "$SECRETS_DIR"/* || true
  fi
fi

echo "[ipc] secrets ready in $SECRETS_DIR"
