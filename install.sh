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

ensure_user_owned() {
  local path="$1"
  if [ -z "$path" ] || [ ! -e "$path" ]; then
    return
  fi
  if [[ "${SITE_AGENT_UID:-}" =~ ^[0-9]+$ ]] && [[ "${SITE_AGENT_GID:-}" =~ ^[0-9]+$ ]]; then
    chown -R "$SITE_AGENT_UID:$SITE_AGENT_GID" "$path" || true
  fi
}

install_docker_stack() {
  if docker compose version >/dev/null 2>&1; then
    return
  fi
  log "installing docker + compose plugin (official repo)"
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y
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
  local tags="${TS_TAGS:-tag:ipc}"
  local hostname="${TS_HOSTNAME:-}"
  # Tailscale supplies the private transport. The host's normal OpenSSH
  # daemon remains the deliberately separate, key-only login layer.
  local args=(--advertise-tags "$tags")
  if [ -n "${TS_AUTHKEY:-}" ]; then
    args=(--authkey "$TS_AUTHKEY" "${args[@]}")
  fi
  if [ -n "$hostname" ]; then
    args+=(--hostname "$hostname")
  fi
  log "running tailscale up --advertise-tags=$tags"
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

preload_images() {
  local image_dir="${IPC_PRELOAD_IMAGE_DIR:-}"
  [ -n "$image_dir" ] || return 0
  [ -d "$image_dir" ] || { echo "Missing IPC_PRELOAD_IMAGE_DIR: $image_dir" >&2; exit 1; }
  local archive loaded=0
  for archive in "$image_dir"/*.tar "$image_dir"/*.tar.gz; do
    [ -f "$archive" ] || continue
    log "loading prebuilt image archive $(basename "$archive")"
    if [[ "$archive" == *.gz ]]; then
      gzip -dc "$archive" | docker load >/dev/null
    else
      docker load -i "$archive" >/dev/null
    fi
    loaded=1
  done
  [ "$loaded" = "1" ] || { echo "No image archives found in $image_dir" >&2; exit 1; }
}

if [ ! -f "$ENV_FILE" ]; then
  cp "$STACK_DIR/.env.example" "$ENV_FILE"
  chmod 0600 "$ENV_FILE"
  log "created $ENV_FILE from example"
fi

# Load env for storage path and image config
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# The host identity must survive container recreation and be stable before the
# IPC pairs with cloud. Container /etc/machine-id and hostnames are not durable
# appliance identifiers.
if [ -z "${HARDWARE_SERIAL:-}" ]; then
  HARDWARE_SERIAL=""
  if [ -r /sys/class/dmi/id/product_uuid ]; then
    HARDWARE_SERIAL="$(tr -d '\r\n' </sys/class/dmi/id/product_uuid)"
  fi
  if [ -z "$HARDWARE_SERIAL" ]; then
    HARDWARE_SERIAL="$(tr -d '\r\n' </etc/machine-id 2>/dev/null || true)"
  fi
  if [ -z "$HARDWARE_SERIAL" ]; then
    echo "Unable to determine a stable HARDWARE_SERIAL" >&2
    exit 1
  fi
  persist_env_var "$ENV_FILE" "HARDWARE_SERIAL" "$HARDWARE_SERIAL"
  export HARDWARE_SERIAL
  log "persisted host hardware identity"
fi

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

ensure_user_owned "$ENV_FILE"
chmod 0600 "$ENV_FILE"

STORAGE_DIR="${IPC_STORAGE_DIR:-/opt/site-agent/storage}"
REPO_LICENSE_KEY="$STACK_DIR/cloud.license.ed25519.pub"
mkdir -p "$STORAGE_DIR"
if [[ "$SITE_AGENT_UID" =~ ^[0-9]+$ ]] && [[ "$SITE_AGENT_GID" =~ ^[0-9]+$ ]]; then
  chown -R "$SITE_AGENT_UID:$SITE_AGENT_GID" "$STORAGE_DIR"
  log "ensured $STORAGE_DIR owned by $SITE_AGENT_UID:$SITE_AGENT_GID"
else
  log "skipping storage ownership change (invalid SITE_AGENT_UID/GID)"
fi

if [ "${SKIP_HARDENING:-0}" != "1" ]; then
  "$STACK_DIR/scripts/bootstrap-host.sh"
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

preload_images

IPC_SECRETS_DIR="${IPC_SECRETS_DIR:-$STACK_DIR/.secrets}" "$STACK_DIR/scripts/gen-ipc-secrets.sh"
ensure_user_owned "${IPC_SECRETS_DIR:-$STACK_DIR/.secrets}"

# Use the per-site generated gatewayd token; never run with the old shared default.
if [ -z "${GATEWAYD_TOKEN:-}" ] || [ "${GATEWAYD_TOKEN:-}" = "devtoken" ]; then
  if [ -s "${IPC_SECRETS_DIR:-$STACK_DIR/.secrets}/gatewayd.token" ]; then
    GATEWAYD_TOKEN="$(cat "${IPC_SECRETS_DIR:-$STACK_DIR/.secrets}/gatewayd.token")"
    persist_env_var "$ENV_FILE" "GATEWAYD_TOKEN" "$GATEWAYD_TOKEN"
    export GATEWAYD_TOKEN
    log "set GATEWAYD_TOKEN from generated secret"
  fi
fi

if [ ! -s "${IPC_SECRETS_DIR:-$STACK_DIR/.secrets}/cloud.license.ed25519.pub" ] && [ -s "$REPO_LICENSE_KEY" ]; then
  cp "$REPO_LICENSE_KEY" "${IPC_SECRETS_DIR:-$STACK_DIR/.secrets}/cloud.license.ed25519.pub"
  chmod 0644 "${IPC_SECRETS_DIR:-$STACK_DIR/.secrets}/cloud.license.ed25519.pub" 2>/dev/null || true
  log "seeded cloud license verifier key to ${IPC_SECRETS_DIR:-$STACK_DIR/.secrets}/cloud.license.ed25519.pub"
fi
ensure_user_owned "${IPC_SECRETS_DIR:-$STACK_DIR/.secrets}"

if [ -z "${IPC_PUBLIC_KEY_FILE:-}" ] && [ -s "${IPC_SECRETS_DIR:-$STACK_DIR/.secrets}/ipc_ed25519.pub" ]; then
  IPC_PUBLIC_KEY_FILE="/run/secrets/ipc_ed25519.pub"
  persist_env_var "$ENV_FILE" "IPC_PUBLIC_KEY_FILE" "$IPC_PUBLIC_KEY_FILE"
  export IPC_PUBLIC_KEY_FILE
  log "set IPC_PUBLIC_KEY_FILE=$IPC_PUBLIC_KEY_FILE"
fi
if [ -z "${IPC_PRIVATE_KEY_FILE:-}" ] && [ -s "${IPC_SECRETS_DIR:-$STACK_DIR/.secrets}/ipc_ed25519" ]; then
  IPC_PRIVATE_KEY_FILE="/run/secrets/ipc_ed25519"
  persist_env_var "$ENV_FILE" "IPC_PRIVATE_KEY_FILE" "$IPC_PRIVATE_KEY_FILE"
  export IPC_PRIVATE_KEY_FILE
  log "set IPC_PRIVATE_KEY_FILE=$IPC_PRIVATE_KEY_FILE"
fi
if [ -z "${CLOUD_LICENSE_SIGNING_PUBLIC_KEY_FILE:-}" ] && [ -s "${IPC_SECRETS_DIR:-$STACK_DIR/.secrets}/cloud.license.ed25519.pub" ]; then
  CLOUD_LICENSE_SIGNING_PUBLIC_KEY_FILE="/run/secrets/cloud.license.ed25519.pub"
  persist_env_var "$ENV_FILE" "CLOUD_LICENSE_SIGNING_PUBLIC_KEY_FILE" "$CLOUD_LICENSE_SIGNING_PUBLIC_KEY_FILE"
  export CLOUD_LICENSE_SIGNING_PUBLIC_KEY_FILE
  log "set CLOUD_LICENSE_SIGNING_PUBLIC_KEY_FILE=$CLOUD_LICENSE_SIGNING_PUBLIC_KEY_FILE"
fi
if [ "${OPTIMIZER_LICENSE_POLICY:-required}" = "required" ] && [ -z "${CLOUD_LICENSE_SIGNING_PUBLIC_KEY:-}" ] && [ ! -s "${IPC_SECRETS_DIR:-$STACK_DIR/.secrets}/cloud.license.ed25519.pub" ]; then
  echo "Missing optimizer trust key. Place cloud.license.ed25519.pub in ${IPC_SECRETS_DIR:-$STACK_DIR/.secrets}." >&2
  exit 1
fi

if [ "${SKIP_IMAGE_PULL:-0}" != "1" ]; then
  docker_login_ghcr
fi

log "starting IPC stack"
cd "$STACK_DIR"
if [ "${SKIP_IMAGE_PULL:-0}" != "1" ]; then
  docker compose pull
else
  log "using preloaded images; registry pull skipped"
fi
"$STACK_DIR/scripts/sync-defaults.sh" --env-file "$ENV_FILE"

log "starting influx"
docker compose up -d influxdb
log "bootstrapping influx buckets/tokens"
IPC_SECRETS_DIR="${IPC_SECRETS_DIR:-$STACK_DIR/.secrets}" \
  "$STACK_DIR/scripts/bootstrap-influx.sh" "$ENV_FILE"
log "starting IPC services"
docker compose up -d
"$STACK_DIR/scripts/check-health.sh" --env-file "$ENV_FILE"

if [ "${TAILSCALE_SSH_ONLY:-0}" = "1" ]; then
  "$STACK_DIR/scripts/lockdown-ssh.sh"
fi

log "install complete"
if [ -z "${TS_AUTHKEY:-}" ] && [ "${SKIP_TAILSCALE:-0}" != "1" ]; then
  log "if Tailscale prompted above, complete the browser login to finish tailnet enrollment"
fi
