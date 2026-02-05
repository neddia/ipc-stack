#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

if [ -n "${1:-}" ]; then
  ENV_FILE="$1"
elif [ -f "$STACK_DIR/.env.dev" ]; then
  ENV_FILE="$STACK_DIR/.env.dev"
else
  ENV_FILE="$STACK_DIR/.env"
fi

if [ ! -f "$ENV_FILE" ]; then
  if [ -f "$STACK_DIR/.env.example" ]; then
    cp "$STACK_DIR/.env.example" "$STACK_DIR/.env.dev"
    ENV_FILE="$STACK_DIR/.env.dev"
    echo "[ipc-dev] created $ENV_FILE from .env.example"
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
      echo "[ipc-dev] detected TAILSCALE_IP=$DETECTED_TS_IP"
    fi
  fi
fi

SECRETS_DIR="${IPC_SECRETS_DIR:-$STACK_DIR/.secrets}"
mkdir -p "$SECRETS_DIR"

if [ ! -s "$SECRETS_DIR/influx.admin.token" ]; then
  IPC_SECRETS_DIR="$SECRETS_DIR" "$STACK_DIR/scripts/gen-ipc-secrets.sh"
fi

cd "$STACK_DIR"
docker compose -f compose.yml -f compose.dev.yml --env-file "$ENV_FILE" up -d --build
docker compose -f compose.dev.yml --env-file "$ENV_FILE" up -d --build tailwind

if [ ! -s "$SECRETS_DIR/influx.telegraf.token" ]; then
  IPC_SECRETS_DIR="$SECRETS_DIR" "$STACK_DIR/scripts/bootstrap-influx.sh" "$ENV_FILE" || true
fi
