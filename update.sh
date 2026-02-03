#!/usr/bin/env bash
set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Run as root (sudo $0)" >&2
  exit 1
fi

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$STACK_DIR/.env"

log() { echo "[ipc-update] $*"; }

docker_login_ghcr() {
  local docker_cfg="${DOCKER_CONFIG:-/root/.docker}/config.json"
  if [ -f "$docker_cfg" ] && grep -q '"ghcr.io"' "$docker_cfg"; then
    return
  fi

  local default_user="${GHCR_USER:-}"
  if [ -z "$default_user" ] && [ -n "${SITE_AGENT_IMAGE:-}" ]; then
    default_user="${SITE_AGENT_IMAGE#ghcr.io/}"
    default_user="${default_user%%/*}"
  fi
  if [ -z "$default_user" ]; then
    default_user="neddia"
  fi

  if [ -z "${GHCR_TOKEN:-}" ]; then
    if [ ! -t 0 ]; then
      echo "GHCR_TOKEN not set and no TTY available. Set GHCR_USER/GHCR_TOKEN or login first." >&2
      exit 1
    fi
    local input_user=""
    read -r -p "GHCR user [$default_user]: " input_user
    if [ -n "$input_user" ]; then
      default_user="$input_user"
    fi
    read -r -s -p "GHCR token (read:packages): " GHCR_TOKEN
    echo
  fi

  if [ -z "${GHCR_USER:-}" ]; then
    GHCR_USER="$default_user"
  fi
  if [ -z "${GHCR_TOKEN:-}" ]; then
    echo "GHCR token is empty; cannot login" >&2
    exit 1
  fi
  log "logging into ghcr.io as $GHCR_USER"
  echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
  unset GHCR_TOKEN
}

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE. Run ./install.sh first." >&2
  exit 1
fi

if [ $# -ge 1 ]; then
  VERSION="$1"
  if grep -q '^SITE_AGENT_VERSION=' "$ENV_FILE"; then
    sed -ri "s/^SITE_AGENT_VERSION=.*/SITE_AGENT_VERSION=${VERSION}/" "$ENV_FILE"
  else
    echo "SITE_AGENT_VERSION=${VERSION}" >> "$ENV_FILE"
  fi
  log "set SITE_AGENT_VERSION=$VERSION"
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

docker_login_ghcr

cd "$STACK_DIR"
docker compose pull

docker compose up -d

log "bootstrapping influx buckets/tokens"
"$STACK_DIR/scripts/bootstrap-influx.sh" || true

log "update complete"
