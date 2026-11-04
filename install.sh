#!/usr/bin/env bash
set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Run as root (sudo $0)" >&2
  exit 1
fi

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$STACK_DIR/.env"

log() { echo "[ipc-install] $*"; }
# shellcheck source=scripts/release-registry.sh
source "$STACK_DIR/scripts/release-registry.sh"

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

tailscale_state() {
  tailscale status --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null || true
}

console_status() {
  # Shown above the console login prompt, where a customer installing on their
  # own hardware will look. An empty message clears it.
  local issue="${IPC_CONSOLE_ISSUE_FILE:-/etc/issue.d/toops-ipc.issue}"
  if [ -n "$1" ]; then
    mkdir -p "$(dirname "$issue")"
    printf '\n%s\n\n' "$1" >"$issue"
  else
    rm -f "$issue"
  fi
  agetty --reload >/dev/null 2>&1 || true
}

wait_for_tailnet_approval() {
  # With device approval enabled on the tailnet, a new node joins but stays
  # unusable until an operator approves it. Wait as long as that takes.
  local state notified=0 unsettled=0
  while :; do
    state="$(tailscale_state)"
    case "$state" in
      Running)
        [ "$notified" = "0" ] || log "tailnet approval received"
        console_status ""
        return 0
        ;;
      NeedsMachineAuth)
        if [ "$notified" = "0" ]; then
          notified=1
          log "waiting for an operator to approve this device in the Tailscale admin console"
          console_status "Toops controller setup: waiting for Toops to approve this device.
Leave it powered on and connected; setup continues automatically."
        fi
        ;;
      Starting|"")
        unsettled=$((unsettled + 1))
        if [ "$unsettled" -gt "${TAILSCALE_SETTLE_POLLS:-40}" ]; then
          echo "Tailscale did not settle (state: ${state:-unavailable})" >&2
          return 1
        fi
        ;;
      *)
        console_status ""
        echo "Tailscale did not log in (state: ${state}); check the provisioning auth key" >&2
        return 1
        ;;
    esac
    sleep "${TAILSCALE_APPROVAL_POLL_SECONDS:-15}"
  done
}

tailscale_up() {
  if ! command -v tailscale >/dev/null 2>&1; then
    return
  fi
  case "$(tailscale_state)" in
    Running|NeedsMachineAuth)
      wait_for_tailnet_approval
      return
      ;;
  esac
  local tags="${TS_TAGS:-tag:ipc}"
  local hostname="${TS_HOSTNAME:-}"
  # Tailscale supplies the private transport. The host's normal OpenSSH
  # daemon remains the deliberately separate, key-only login layer.
  local args=(--advertise-tags "$tags")
  if [ -n "$hostname" ]; then
    args+=(--hostname "$hostname")
  fi
  log "running tailscale up --advertise-tags=$tags"
  if [ -n "${TS_AUTHKEY:-}" ]; then
    # Do not block inside `tailscale up` while a device awaits approval; the
    # approval wait below reports progress on the console instead.
    tailscale up --authkey "$TS_AUTHKEY" "${args[@]}" --timeout=2m || true
    wait_for_tailnet_approval
  else
    tailscale up "${args[@]}"
  fi
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
  # Tailscale installs from its own package source, which the security-only
  # OS updates never touch; let it apply its own releases.
  if command -v tailscale >/dev/null 2>&1; then
    tailscale set --auto-update || log "could not enable Tailscale auto-update"
  fi
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
  prepare_release_registry pull
else
  prepare_release_registry
fi

log "starting IPC stack"
cd "$STACK_DIR"
if [ "${SKIP_IMAGE_PULL:-0}" != "1" ]; then
  docker compose pull
else
  log "using preloaded images; registry pull skipped"
fi
"$STACK_DIR/scripts/sync-defaults.sh" --env-file "$ENV_FILE"
python3 "$STACK_DIR/scripts/install-enrollment.py" --stack "$STACK_DIR" --secrets "${IPC_SECRETS_DIR:-$STACK_DIR/.secrets}" --storage "$STORAGE_DIR" --cloud "${CLOUD_BASE_URL:-}"

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
if [ "$STACK_DIR" = '/opt/ipc-stack' ]; then
  install -m 0644 "$STACK_DIR/provision/firstboot/ipc-replacement.service" /etc/systemd/system/ipc-replacement.service
  install -m 0644 "$STACK_DIR/provision/firstboot/ipc-replacement.timer" /etc/systemd/system/ipc-replacement.timer
  install -m 0755 "$STACK_DIR/scripts/toops-support.sh" /usr/local/sbin/toops-support
  for unit in ipc-support-access.service ipc-support-access.path ipc-support-access.timer; do
    install -m 0644 "$STACK_DIR/provision/firstboot/$unit" "/etc/systemd/system/$unit"
  done
  systemctl daemon-reload
  systemctl enable --now ipc-replacement.timer
  # The customer's support-access switch ships dark: only a device with
  # SUPPORT_ACCESS_TOGGLE=1 lets the dashboard drive the host lockout.
  if [ "${SUPPORT_ACCESS_TOGGLE:-0}" = "1" ]; then
    systemctl enable --now ipc-support-access.path ipc-support-access.timer
  else
    systemctl disable --now ipc-support-access.path ipc-support-access.timer >/dev/null 2>&1 || true
  fi
fi
if [ -z "${TS_AUTHKEY:-}" ] && [ "${SKIP_TAILSCALE:-0}" != "1" ]; then
  log "if Tailscale prompted above, complete the browser login to finish tailnet enrollment"
fi
