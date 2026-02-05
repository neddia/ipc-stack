#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR="${IPC_SECRETS_DIR:-$STACK_DIR/.secrets}"

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

KEY_PATH="$SECRETS_DIR/ipc_ed25519"
PUB_PATH="$SECRETS_DIR/ipc_ed25519.pub"
if [ ! -s "$KEY_PATH" ] || [ ! -s "$PUB_PATH" ]; then
  if command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -t ed25519 -N "" -C "ipc" -f "$KEY_PATH" >/dev/null 2>&1
    chmod 600 "$KEY_PATH" || true
    chmod 644 "$PUB_PATH" || true
  else
    echo "[ipc] warning: ssh-keygen not found; skipping IPC keypair" >&2
  fi
fi

if [ -n "${SITE_AGENT_UID:-}" ] && [ -n "${SITE_AGENT_GID:-}" ]; then
  if [[ "$SITE_AGENT_UID" =~ ^[0-9]+$ ]] && [[ "$SITE_AGENT_GID" =~ ^[0-9]+$ ]]; then
    chown "$SITE_AGENT_UID:$SITE_AGENT_GID" "$SECRETS_DIR"/* || true
  fi
fi

echo "[ipc] secrets ready in $SECRETS_DIR"
