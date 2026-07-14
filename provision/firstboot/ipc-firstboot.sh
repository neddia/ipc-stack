#!/usr/bin/env bash
# One-time first-boot bring-up for IPC appliances.
# Installed and enabled by the autoinstall late-commands; disables itself on
# success by writing /var/lib/ipc-firstboot.done.
set -uo pipefail

STACK_DIR="/opt/ipc-stack"
SEED_FILE="$STACK_DIR/seed.env"
DONE_FILE="/var/lib/ipc-firstboot.done"

log() { echo "[ipc-firstboot] $*"; }

if [ -e "$DONE_FILE" ]; then
  log "already provisioned; nothing to do"
  exit 0
fi

if [ ! -d "$STACK_DIR" ]; then
  log "ERROR: $STACK_DIR missing (autoinstall clone failed?)"
  exit 1
fi

# Wait for a working uplink (DNS + HTTPS), up to ~10 minutes.
log "waiting for network"
for _ in $(seq 1 60); do
  if curl -fsS --connect-timeout 5 https://api.github.com >/dev/null 2>&1; then
    break
  fi
  sleep 10
done
if ! curl -fsS --connect-timeout 5 https://api.github.com >/dev/null 2>&1; then
  log "ERROR: no network after 10 minutes; will run again next boot"
  exit 1
fi

# Load the per-site seed (TS_AUTHKEY, GHCR creds, version pins, ...).
if [ -f "$SEED_FILE" ]; then
  log "loading seed"
  set -a
  # shellcheck disable=SC1090
  source "$SEED_FILE"
  set +a
else
  log "no seed.env found; proceeding with defaults (may require manual steps)"
fi

# Refresh the deploy repo (the clone in the installer may predate fixes).
if command -v git >/dev/null 2>&1; then
  git -C "$STACK_DIR" pull --ff-only || log "warning: git pull failed; using cloned revision"
fi

if [ -n "${TS_HOSTNAME:-}" ]; then
  hostnamectl set-hostname "$TS_HOSTNAME" || true
fi

# Apply version pins from the seed before install reads .env.
if [ ! -f "$STACK_DIR/.env" ] && [ -f "$STACK_DIR/.env.example" ]; then
  cp "$STACK_DIR/.env.example" "$STACK_DIR/.env"
fi
pin_env() {
  local key="$1" value="$2"
  [ -n "$value" ] || return 0
  if grep -q "^${key}=" "$STACK_DIR/.env"; then
    sed -ri "s|^${key}=.*|${key}=${value}|" "$STACK_DIR/.env"
  else
    printf '\n%s=%s\n' "$key" "$value" >>"$STACK_DIR/.env"
  fi
}
pin_env "SITE_AGENT_VERSION" "${SITE_AGENT_VERSION:-}"
pin_env "GATEWAYD_VERSION" "${GATEWAYD_VERSION:-}"
pin_env "CLOUD_BASE_URL" "${CLOUD_BASE_URL:-}"
pin_env "CLOUD_PUBLIC_BASE_URL" "${CLOUD_PUBLIC_BASE_URL:-}"
pin_env "HARDWARE_SERIAL" "${HARDWARE_SERIAL:-}"
chmod 0600 "$STACK_DIR/.env"

log "running install.sh"
if ! "$STACK_DIR/install.sh"; then
  log "ERROR: install.sh failed; will run again next boot"
  exit 1
fi

log "install healthy; finalizing"
if [ -f "$SEED_FILE" ]; then
  shred -u "$SEED_FILE" 2>/dev/null || rm -f "$SEED_FILE"
fi
touch "$DONE_FILE"
log "first-boot provisioning complete"
