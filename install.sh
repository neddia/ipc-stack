#!/usr/bin/env bash
set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Run as root (sudo $0)" >&2
  exit 1
fi

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$STACK_DIR/.env"

log() { echo "[ipc-install] $*"; }

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

install_docker_stack() {
  if docker compose version >/dev/null 2>&1; then
    return
  fi
  log "installing docker + compose plugin (official repo)"
  apt-get update -y >/dev/null 2>&1 || apt-get update -y || true
  apt-get install -y ca-certificates curl gnupg

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y >/dev/null 2>&1 || apt-get update -y || true
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker || true
}

install_tailscale() {
  if command -v tailscaled >/dev/null 2>&1; then
    return
  fi
  log "installing tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh
}

tailscale_up() {
  if ! command -v tailscale >/dev/null 2>&1; then
    return
  fi
  if tailscale status >/dev/null 2>&1; then
    return
  fi
  if [ -z "${TS_AUTHKEY:-}" ]; then
    log "tailscale up skipped (set TS_AUTHKEY to auto-enroll)"
    return
  fi
  local tags="${TS_TAGS:-tag:ipc}"
  local hostname="${TS_HOSTNAME:-}"
  local args=(--authkey "$TS_AUTHKEY" --ssh --advertise-tags "$tags")
  if [ -n "$hostname" ]; then
    args+=(--hostname "$hostname")
  fi
  log "running tailscale up --ssh"
  tailscale up "${args[@]}"
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

if [ ! -f "$ENV_FILE" ]; then
  cp "$STACK_DIR/.env.example" "$ENV_FILE"
  log "created $ENV_FILE from example"
fi

# Load env for storage path and image config
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if [ -z "${SITE_AGENT_UID:-}" ] || [ -z "${SITE_AGENT_GID:-}" ]; then
  if [ -n "${SUDO_USER:-}" ] && id -u "$SUDO_USER" >/dev/null 2>&1; then
    SITE_AGENT_UID="$(id -u "$SUDO_USER")"
    SITE_AGENT_GID="$(id -g "$SUDO_USER")"
    log "using SITE_AGENT_UID/GID from $SUDO_USER: $SITE_AGENT_UID:$SITE_AGENT_GID"
    persist_env_var "$ENV_FILE" "SITE_AGENT_UID" "$SITE_AGENT_UID"
    persist_env_var "$ENV_FILE" "SITE_AGENT_GID" "$SITE_AGENT_GID"
  else
    SITE_AGENT_UID="${SITE_AGENT_UID:-1000}"
    SITE_AGENT_GID="${SITE_AGENT_GID:-1000}"
  fi
fi

STORAGE_DIR="${IPC_STORAGE_DIR:-/opt/site-agent/storage}"
mkdir -p "$STORAGE_DIR"
if [ ! -f "$STORAGE_DIR/site-config.yml" ]; then
  cp "$STACK_DIR/storage/seed/site-config.yml" "$STORAGE_DIR/site-config.yml"
  log "seeded $STORAGE_DIR/site-config.yml"
fi
if [[ "$SITE_AGENT_UID" =~ ^[0-9]+$ ]] && [[ "$SITE_AGENT_GID" =~ ^[0-9]+$ ]]; then
  chown -R "$SITE_AGENT_UID:$SITE_AGENT_GID" "$STORAGE_DIR"
  log "ensured $STORAGE_DIR owned by $SITE_AGENT_UID:$SITE_AGENT_GID"
else
  log "skipping storage ownership change (invalid SITE_AGENT_UID/GID)"
fi

if [ "${SKIP_HARDENING:-0}" != "1" ]; then
  "$STACK_DIR/scripts/bootstrap-host.sh" || true
fi

install_docker_stack
if [ "${SKIP_TAILSCALE:-0}" != "1" ]; then
  install_tailscale
  tailscale_up
  if [ -z "${TAILSCALE_IP:-}" ] && command -v tailscale >/dev/null 2>&1; then
    DETECTED_TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
    if [ -n "$DETECTED_TS_IP" ]; then
      persist_env_var "$ENV_FILE" "TAILSCALE_IP" "$DETECTED_TS_IP"
      export TAILSCALE_IP="$DETECTED_TS_IP"
      log "detected TAILSCALE_IP=$DETECTED_TS_IP"
    fi
  fi
fi

"$STACK_DIR/scripts/gen-ipc-secrets.sh"

docker_login_ghcr

log "starting IPC stack"
cd "$STACK_DIR"
docker compose pull

docker compose up -d

log "bootstrapping influx buckets/tokens"
"$STACK_DIR/scripts/bootstrap-influx.sh" || true

if [ "${TAILSCALE_SSH_ONLY:-0}" = "1" ]; then
  "$STACK_DIR/scripts/lockdown-ssh.sh" || true
fi

log "install complete"
if [ -z "${TS_AUTHKEY:-}" ] && [ "${SKIP_TAILSCALE:-0}" != "1" ]; then
  log "next: run 'tailscale up --ssh' and tag the node as ipc"
fi
