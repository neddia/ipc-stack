#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${1:-$STACK_DIR/.env}"

log() { echo "[ipc-prod] $*"; }

persist_env_var() {
  local file="$1"
  local key="$2"
  local value="$3"
  if grep -q "^${key}=" "$file"; then
    sed -ri "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '\n%s=%s\n' "$key" "$value" >>"$file"
  fi
}

if [ ! -f "$ENV_FILE" ]; then
  if [ -f "$STACK_DIR/.env.example" ]; then
    cp "$STACK_DIR/.env.example" "$ENV_FILE"
    log "created $ENV_FILE from .env.example"
  else
    echo "Missing env file: $ENV_FILE" >&2
    exit 1
  fi
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

export ENV_FILE

if [ -z "${TAILSCALE_IP:-}" ]; then
  if command -v tailscale >/dev/null 2>&1; then
    DETECTED_TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
    if [ -n "$DETECTED_TS_IP" ]; then
      persist_env_var "$ENV_FILE" "TAILSCALE_IP" "$DETECTED_TS_IP"
      export TAILSCALE_IP="$DETECTED_TS_IP"
      log "detected TAILSCALE_IP=$DETECTED_TS_IP"
    fi
  fi
fi

SECRETS_DIR="${IPC_SECRETS_DIR:-$STACK_DIR/.secrets}"
REPO_LICENSE_KEY="$STACK_DIR/cloud.license.ed25519.pub"
mkdir -p "$SECRETS_DIR"

IPC_SECRETS_DIR="$SECRETS_DIR" "$STACK_DIR/scripts/gen-ipc-secrets.sh"

if [ ! -s "$SECRETS_DIR/cloud.license.ed25519.pub" ] && [ -s "$REPO_LICENSE_KEY" ]; then
  cp "$REPO_LICENSE_KEY" "$SECRETS_DIR/cloud.license.ed25519.pub"
  chmod 0644 "$SECRETS_DIR/cloud.license.ed25519.pub" 2>/dev/null || true
  log "seeded cloud license verifier key to $SECRETS_DIR/cloud.license.ed25519.pub"
fi

if [ -z "${IPC_PUBLIC_KEY_FILE:-}" ] && [ -s "$SECRETS_DIR/ipc_ed25519.pub" ]; then
  IPC_PUBLIC_KEY_FILE="/run/secrets/ipc_ed25519.pub"
  persist_env_var "$ENV_FILE" "IPC_PUBLIC_KEY_FILE" "$IPC_PUBLIC_KEY_FILE"
  export IPC_PUBLIC_KEY_FILE
  log "set IPC_PUBLIC_KEY_FILE=$IPC_PUBLIC_KEY_FILE"
fi
if [ -z "${IPC_PRIVATE_KEY_FILE:-}" ] && [ -s "$SECRETS_DIR/ipc_ed25519" ]; then
  IPC_PRIVATE_KEY_FILE="/run/secrets/ipc_ed25519"
  persist_env_var "$ENV_FILE" "IPC_PRIVATE_KEY_FILE" "$IPC_PRIVATE_KEY_FILE"
  export IPC_PRIVATE_KEY_FILE
  log "set IPC_PRIVATE_KEY_FILE=$IPC_PRIVATE_KEY_FILE"
fi
if [ -z "${CLOUD_LICENSE_SIGNING_PUBLIC_KEY_FILE:-}" ] && [ -s "$SECRETS_DIR/cloud.license.ed25519.pub" ]; then
  CLOUD_LICENSE_SIGNING_PUBLIC_KEY_FILE="/run/secrets/cloud.license.ed25519.pub"
  persist_env_var "$ENV_FILE" "CLOUD_LICENSE_SIGNING_PUBLIC_KEY_FILE" "$CLOUD_LICENSE_SIGNING_PUBLIC_KEY_FILE"
  export CLOUD_LICENSE_SIGNING_PUBLIC_KEY_FILE
  log "set CLOUD_LICENSE_SIGNING_PUBLIC_KEY_FILE=$CLOUD_LICENSE_SIGNING_PUBLIC_KEY_FILE"
fi
if [ "${OPTIMIZER_LICENSE_POLICY:-required}" = "required" ] && [ -z "${CLOUD_LICENSE_SIGNING_PUBLIC_KEY:-}" ] && [ ! -s "$SECRETS_DIR/cloud.license.ed25519.pub" ]; then
  echo "Missing optimizer trust key. Place cloud.license.ed25519.pub in $SECRETS_DIR." >&2
  exit 1
fi

cd "$STACK_DIR"
docker compose -f compose.yml --env-file "$ENV_FILE" up -d

if [ ! -s "$SECRETS_DIR/influx.telegraf.token" ]; then
  log "bootstrapping influx token/buckets"
  IPC_SECRETS_DIR="$SECRETS_DIR" "$STACK_DIR/scripts/bootstrap-influx.sh" "$ENV_FILE"
fi

"$STACK_DIR/scripts/check-health.sh" --env-file "$ENV_FILE"
