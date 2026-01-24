#!/usr/bin/env bash
set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Run as root (sudo $0)" >&2
  exit 1
fi

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$STACK_DIR/.env"

log() { echo "[ipc-update] $*"; }

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

if [ -n "${GHCR_TOKEN:-}" ] && [ -n "${GHCR_USER:-}" ]; then
  echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
fi

cd "$STACK_DIR"
docker compose pull

docker compose up -d

log "update complete"
