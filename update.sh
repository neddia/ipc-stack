#!/usr/bin/env bash
set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Run as root (sudo $0)" >&2
  exit 1
fi

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$STACK_DIR/.env"

log() { echo "[ipc-update] $*"; }

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

ensure_user_owned() {
  local path="$1"
  if [ -z "$path" ] || [ ! -e "$path" ]; then
    return
  fi
  if [[ "${SITE_AGENT_UID:-}" =~ ^[0-9]+$ ]] && [[ "${SITE_AGENT_GID:-}" =~ ^[0-9]+$ ]]; then
    chown -R "$SITE_AGENT_UID:$SITE_AGENT_GID" "$path" || true
  fi
}

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

set_release() {
  # Pin both images to the same release and remember the outgoing pin
  # so a bad update can roll back (and prune knows what to keep).
  local version="$1"
  if [ -n "${SITE_AGENT_VERSION:-}" ] && [ "$SITE_AGENT_VERSION" != "$version" ]; then
    persist_env_var "$ENV_FILE" "SITE_AGENT_PREV_VERSION" "$SITE_AGENT_VERSION"
    SITE_AGENT_PREV_VERSION="$SITE_AGENT_VERSION"
  fi
  if [ -n "${GATEWAYD_VERSION:-}" ] && [ "$GATEWAYD_VERSION" != "$version" ]; then
    persist_env_var "$ENV_FILE" "GATEWAYD_PREV_VERSION" "$GATEWAYD_VERSION"
    GATEWAYD_PREV_VERSION="$GATEWAYD_VERSION"
  fi
  persist_env_var "$ENV_FILE" "SITE_AGENT_VERSION" "$version"
  persist_env_var "$ENV_FILE" "GATEWAYD_VERSION" "$version"
  export SITE_AGENT_VERSION="$version" GATEWAYD_VERSION="$version"
  export SITE_AGENT_PREV_VERSION="${SITE_AGENT_PREV_VERSION:-}" GATEWAYD_PREV_VERSION="${GATEWAYD_PREV_VERSION:-}"
  log "set SITE_AGENT_VERSION=$version GATEWAYD_VERSION=$version"
}

rollback_release() {
  local sa_prev="${SITE_AGENT_PREV_VERSION:-}"
  local gw_prev="${GATEWAYD_PREV_VERSION:-$sa_prev}"
  if [ -z "$sa_prev" ]; then
    return 1
  fi
  log "rolling back to site-agent=$sa_prev gatewayd=$gw_prev"
  persist_env_var "$ENV_FILE" "SITE_AGENT_VERSION" "$sa_prev"
  persist_env_var "$ENV_FILE" "GATEWAYD_VERSION" "$gw_prev"
  export SITE_AGENT_VERSION="$sa_prev" GATEWAYD_VERSION="$gw_prev"
  docker compose up -d
}

prune_image_tags() {
  # Remove tags of $repo other than the two we keep (current + previous).
  local repo="$1" keep_a="$2" keep_b="$3"
  if [ -z "$repo" ]; then
    return
  fi
  docker images --format '{{.Repository}}:{{.Tag}}' "$repo" 2>/dev/null | while read -r ref; do
    tag="${ref##*:}"
    if [ "$tag" = "<none>" ]; then
      continue  # dangling layers; docker image prune handles them
    fi
    if [ "$tag" != "$keep_a" ] && [ "$tag" != "$keep_b" ]; then
      log "pruning old image $ref"
      docker rmi "$ref" >/dev/null 2>&1 || true
    fi
  done
}

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE. Run ./install.sh first." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if [ $# -ge 1 ]; then
  set_release "$1"
fi

if [ -z "${SITE_AGENT_UID:-}" ] || [ -z "${SITE_AGENT_GID:-}" ]; then
  if [ -n "${SUDO_USER:-}" ] && id -u "$SUDO_USER" >/dev/null 2>&1; then
    SITE_AGENT_UID="$(id -u "$SUDO_USER")"
    SITE_AGENT_GID="$(id -g "$SUDO_USER")"
  fi
fi

ensure_user_owned "$ENV_FILE"

docker_login_ghcr

cd "$STACK_DIR"
docker compose pull
"$STACK_DIR/scripts/sync-defaults.sh" --env-file "$ENV_FILE"

log "validating influx buckets and telegraf token"
docker compose up -d influxdb
"$STACK_DIR/scripts/bootstrap-influx.sh"
docker compose up -d

ensure_user_owned "$STACK_DIR/.secrets"

if ! "$STACK_DIR/scripts/check-health.sh" --env-file "$ENV_FILE"; then
  log "health check FAILED on ${SITE_AGENT_VERSION:-?}"
  if rollback_release; then
    if "$STACK_DIR/scripts/check-health.sh" --env-file "$ENV_FILE"; then
      log "rollback to ${SITE_AGENT_VERSION} healthy; update aborted"
    else
      log "rollback did NOT become healthy; manual intervention required"
    fi
  else
    log "no previous version recorded; cannot auto-rollback"
  fi
  exit 1
fi

prune_image_tags "${SITE_AGENT_IMAGE:-}" "${SITE_AGENT_VERSION:-latest}" "${SITE_AGENT_PREV_VERSION:-}"
prune_image_tags "${GATEWAYD_IMAGE:-}" "${GATEWAYD_VERSION:-latest}" "${GATEWAYD_PREV_VERSION:-}"
docker image prune -f >/dev/null || true

log "update complete"
