#!/usr/bin/env bash
# Harden the host for IPC appliances. Run once per install as root.
# Focuses on OS-level hygiene (sleep, time, logs, security updates, tailscale, docker logs).
set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Run as root (sudo $0)" >&2
  exit 1
fi

log() { echo "[ipc-host] $*"; }

APT_UPDATED=0
apt_install() {
  if ! command -v apt-get >/dev/null 2>&1; then
    return 1
  fi
  if [ "$APT_UPDATED" -eq 0 ]; then
    log "apt-get update"
    apt-get update -y >/dev/null 2>&1 || apt-get update -y || true
    APT_UPDATED=1
  fi
  apt-get install -y "$@"
}

disable_sleep() {
  log "disabling sleep / hibernate targets"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target || true
  fi
  if [ -f /etc/systemd/logind.conf ]; then
    for key in HandleLidSwitch HandleLidSwitchDocked HandleLidSwitchExternalPower; do
      if grep -q "^${key}=" /etc/systemd/logind.conf; then
        sed -ri "s/^${key}=.*/${key}=ignore/" /etc/systemd/logind.conf
      else
        echo "${key}=ignore" >> /etc/systemd/logind.conf
      fi
    done
    systemctl restart systemd-logind || true
  fi
}

ensure_timesync() {
  log "ensuring systemd-timesyncd is enabled"
  apt_install systemd-timesyncd >/dev/null 2>&1 || true
  systemctl enable --now systemd-timesyncd || true
}

limit_journal() {
  log "setting journald size limits"
  mkdir -p /etc/systemd/journald.conf.d
  cat >/etc/systemd/journald.conf.d/size-limit.conf <<'CONF'
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
RuntimeMaxUse=100M
CONF
  systemctl restart systemd-journald || true
}

security_updates() {
  log "enabling unattended-upgrades (security only)"
  if apt_install unattended-upgrades; then
    cat >/etc/apt/apt.conf.d/51unattended-upgrades-security-only <<'CONF'
Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
CONF
    systemctl enable --now unattended-upgrades || true
  fi
}

enable_tailscale() {
  if command -v tailscaled >/dev/null 2>&1; then
    log "enabling tailscaled on boot"
    systemctl enable --now tailscaled || true
  else
    log "tailscaled not installed; skipping"
  fi
}

docker_log_limits() {
  log "ensuring docker log caps"
  mkdir -p /etc/docker
  if [ ! -f /etc/docker/daemon.json ]; then
    cat >/etc/docker/daemon.json <<'CONF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "20m",
    "max-file": "5"
  }
}
CONF
    systemctl restart docker || true
  else
    log "/etc/docker/daemon.json exists; leaving unchanged"
  fi
}

seed_profiles() {
  local root_dir seed_dir storage_dir dest_dir
  root_dir="$(cd "$(dirname "$0")/.." && pwd)"
  seed_dir="${root_dir}/seed/profiles"
  storage_dir="${IPC_STORAGE_DIR:-/opt/site-agent/storage}"
  dest_dir="${storage_dir}/profiles"

  if [ ! -d "${seed_dir}" ]; then
    log "no profile seed dir at ${seed_dir}; skipping"
    return
  fi

  mkdir -p "${dest_dir}"
  if [ -n "$(ls -A "${dest_dir}" 2>/dev/null)" ]; then
    log "profiles already present at ${dest_dir}; leaving unchanged"
    return
  fi

  log "seeding profiles to ${dest_dir}"
  cp -a "${seed_dir}/." "${dest_dir}/"
}

disable_sleep
ensure_timesync
limit_journal
security_updates
enable_tailscale
docker_log_limits
seed_profiles

if [ -x /opt/ipc-stack/scripts/enable-mdns.sh ]; then
  /opt/ipc-stack/scripts/enable-mdns.sh || true
elif [ -x "$(dirname "$0")/enable-mdns.sh" ]; then
  "$(dirname "$0")/enable-mdns.sh" || true
fi

log "host bootstrap complete"
