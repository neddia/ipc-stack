#!/usr/bin/env bash
set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Run as root (sudo $0)" >&2
  exit 1
fi

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$STACK_DIR/.env"

log() { echo "[ipc-install] $*"; }

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
  if [ -z "${GHCR_TOKEN:-}" ]; then
    return
  fi
  if [ -z "${GHCR_USER:-}" ]; then
    echo "GHCR_TOKEN provided but GHCR_USER is empty" >&2
    exit 1
  fi
  echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
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

STORAGE_DIR="${IPC_STORAGE_DIR:-/opt/site-agent/storage}"
mkdir -p "$STORAGE_DIR"
if [ ! -f "$STORAGE_DIR/site-config.yml" ]; then
  cp "$STACK_DIR/storage/seed/site-config.yml" "$STORAGE_DIR/site-config.yml"
  log "seeded $STORAGE_DIR/site-config.yml"
fi

if [ "${SKIP_HARDENING:-0}" != "1" ]; then
  "$STACK_DIR/scripts/bootstrap-host.sh" || true
fi

install_docker_stack
if [ "${SKIP_TAILSCALE:-0}" != "1" ]; then
  install_tailscale
  tailscale_up
fi

"$STACK_DIR/scripts/gen-ipc-secrets.sh"

docker_login_ghcr

log "starting IPC stack"
cd "$STACK_DIR"
docker compose pull

docker compose up -d

if [ "${TAILSCALE_SSH_ONLY:-0}" = "1" ]; then
  "$STACK_DIR/scripts/lockdown-ssh.sh" || true
fi

log "install complete"
if [ -z "${TS_AUTHKEY:-}" ] && [ "${SKIP_TAILSCALE:-0}" != "1" ]; then
  log "next: run 'tailscale up --ssh' and tag the node as ipc"
fi
