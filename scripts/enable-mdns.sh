#!/usr/bin/env bash
# Enable mDNS advertisement for the site-agent UI as _setpoint._tcp.
set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Run as root (sudo $0)" >&2
  exit 1
fi

log() { echo "[ipc-mdns] $*"; }

load_env_file() {
  local env_file="$1"
  [ -f "$env_file" ] || return 0
  # shellcheck disable=SC2046
  export $(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$env_file" | xargs -d '\n' || true)
}

apt_install() {
  if ! command -v apt-get >/dev/null 2>&1; then
    return 1
  fi
  apt-get update -y >/dev/null 2>&1 || apt-get update -y || true
  apt-get install -y "$@"
}

load_env_file "/opt/ipc-stack/.env"
load_env_file "$(dirname "$0")/../.env"

PORT="${SETPOINT_UI_PORT:-8000}"

log "installing avahi-daemon"
if ! command -v avahi-daemon >/dev/null 2>&1; then
  apt_install avahi-daemon avahi-utils >/dev/null 2>&1 || apt_install avahi-daemon avahi-utils
fi

log "writing avahi service file"
mkdir -p /etc/avahi/services
cat >/etc/avahi/services/setpoint.service <<EOF
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name>setpoint</name>
  <service>
    <type>_setpoint._tcp</type>
    <port>${PORT}</port>
  </service>
</service-group>
EOF

log "enabling avahi-daemon"
systemctl enable --now avahi-daemon || true
systemctl restart avahi-daemon || true

log "mDNS advertisement enabled on port ${PORT}"
