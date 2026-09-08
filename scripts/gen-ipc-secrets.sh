#!/usr/bin/env bash
set -euo pipefail
umask 077

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR="${IPC_SECRETS_DIR:-$STACK_DIR/.secrets}"

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR" || true
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

rand_cli_password() {
  # Influx's entrypoint passes this as `--password VALUE`.  Keep the value
  # from beginning with `-`, which its CLI can otherwise interpret as a flag.
  # token_hex(32) provides 256 bits of entropy using an unambiguous alphabet.
  python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
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
write_secret "$SECRETS_DIR/influx.admin.pass" "$(rand_cli_password)"
write_secret "$SECRETS_DIR/influx.admin.token" "$(rand)"
write_secret "$SECRETS_DIR/gatewayd.token" "$(rand)"

KEY_PATH="$SECRETS_DIR/ipc_ed25519"
PUB_PATH="$SECRETS_DIR/ipc_ed25519.pub"
python3 "$STACK_DIR/scripts/ensure-ipc-identity.py" --secrets "$SECRETS_DIR" --storage "${IPC_STORAGE_DIR:-/opt/site-agent/storage}"
if [ -s "$KEY_PATH" ] && [ -s "$PUB_PATH" ]; then
  chmod 600 "$KEY_PATH" || true
  chmod 644 "$PUB_PATH" || true
fi

if [ -n "${SITE_AGENT_UID:-}" ] && [ -n "${SITE_AGENT_GID:-}" ]; then
  if [[ "$SITE_AGENT_UID" =~ ^[0-9]+$ ]] && [[ "$SITE_AGENT_GID" =~ ^[0-9]+$ ]]; then
    chown "$SITE_AGENT_UID:$SITE_AGENT_GID" "$SECRETS_DIR"/* || true
  fi
fi

echo "[ipc] secrets ready in $SECRETS_DIR"
