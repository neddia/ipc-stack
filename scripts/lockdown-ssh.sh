#!/usr/bin/env bash
# toops-ipc-lockdown.sh
#
# Lock down an Ubuntu IPC so OpenSSH is reachable ONLY over Tailscale:
#  - sshd listens only on the device's Tailscale IPv4 (100.x)
#  - disables password / interactive auth
#  - ensures ssh starts AFTER tailscaled (prevents boot bind failures)
#  - enables UFW and allows TCP/22 ONLY on tailscale0
#
# This keeps VS Code Remote-SSH working as long as you connect via MagicDNS
# or the 100.x Tailscale IP (NOT the public/LAN IP).
#
# Usage:
#   sudo ./toops-ipc-lockdown.sh
#
# Optional env:
#   TS_IF=tailscale0        # tailscale interface name
#   SSH_PORT=22             # ssh port
#   FORCE=0|1               # bypass tailscale status check (still requires TS IP)
#   ALLOW_LAN_SSH=0|1       # if 1, also allow SSH from LAN_CIDR (still not public)
#   LAN_CIDR=192.168.0.0/16

set -euo pipefail

TS_IF="${TS_IF:-tailscale0}"
SSH_PORT="${SSH_PORT:-22}"
FORCE="${FORCE:-0}"
ALLOW_LAN_SSH="${ALLOW_LAN_SSH:-0}"
LAN_CIDR="${LAN_CIDR:-192.168.0.0/16}"

log() { echo "[ipc-lockdown] $*"; }
die() { echo "[ipc-lockdown] ERROR: $*" >&2; exit 1; }

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root (sudo $0)"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

ensure_openssh() {
  if command -v sshd >/dev/null 2>&1; then
    return
  fi
  if command -v apt-get >/dev/null 2>&1; then
    log "installing openssh-server"
    apt-get update -y
    apt-get install -y openssh-server
    return
  fi
  die "openssh-server not found and apt-get is unavailable"
}

get_ts_ip4() {
  # Prefer tailscale CLI; fallback to interface addr if needed.
  local ip=""
  if command -v tailscale >/dev/null 2>&1; then
    ip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "$ip" ]] && ip link show "$TS_IF" >/dev/null 2>&1; then
    ip="$(ip -4 -o addr show dev "$TS_IF" | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
  fi
  echo "$ip"
}

ensure_tailscale_up() {
  require_cmd ip
  require_cmd systemctl

  if ! command -v tailscale >/dev/null 2>&1; then
    die "tailscale not installed. Install it first (or set up Tailscale SSH instead)."
  fi

  # If tailscaled isn't running, try to start it.
  systemctl enable --now tailscaled >/dev/null 2>&1 || true

  local ts_ip
  ts_ip="$(get_ts_ip4)"
  if [[ -z "$ts_ip" ]]; then
    if [[ "$FORCE" == "1" ]]; then
      die "FORCE=1 set, but no Tailscale IPv4 found. Refusing to lock down SSH without a Tailscale IP."
    else
      die "Tailscale does not appear up (no Tailscale IPv4). Run: sudo tailscale up"
    fi
  fi

  log "Detected Tailscale IPv4: $ts_ip"
}

write_sshd_dropin() {
  local ts_ip="$1"
  local conf_dir="/etc/ssh/sshd_config.d"
  local conf_file="${conf_dir}/99-toops-tailscale-only.conf"

  mkdir -p "$conf_dir"

  # Hardening + bind to Tailscale IP only
  cat >"$conf_file" <<EOF
# Managed by toops-ipc-lockdown.sh
# Only listen on Tailscale IPv4:
ListenAddress ${ts_ip}

# Auth hardening:
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin no

# Reasonable defaults (leave forwarding enabled for VS Code Remote-SSH):
PubkeyAuthentication yes
EOF

  log "Wrote sshd drop-in: $conf_file"
}

ensure_privsep_dir() {
  mkdir -p /run/sshd
  chmod 0755 /run/sshd
}

ensure_sshd_after_tailscale() {
  # On Ubuntu, OpenSSH is commonly "ssh.service". Some distros use sshd.service.
  local unit=""
  if systemctl list-unit-files | awk '{print $1}' | grep -qx "ssh.service"; then
    unit="ssh.service"
  elif systemctl list-unit-files | awk '{print $1}' | grep -qx "sshd.service"; then
    unit="sshd.service"
  else
    # still allow validation; user may be using socket activation or custom.
    log "Could not find ssh.service or sshd.service in unit files; skipping systemd ordering drop-in."
    return 0
  fi

  local dropin_dir="/etc/systemd/system/${unit}.d"
  local dropin_file="${dropin_dir}/10-toops-after-tailscale.conf"
  mkdir -p "$dropin_dir"

  cat >"$dropin_file" <<'EOF'
# Managed by toops-ipc-lockdown.sh
[Unit]
After=tailscaled.service network-online.target
Wants=network-online.target
EOF

  systemctl daemon-reload
  log "Added systemd ordering drop-in for ${unit}: ${dropin_file}"
}

validate_and_restart_sshd() {
  ensure_privsep_dir
  # Validate config first; fail hard if invalid.
  if ! sshd -t; then
    die "sshd config test failed (sshd -t). Fix before proceeding."
  fi

  # Restart whichever service exists.
  if systemctl list-unit-files | awk '{print $1}' | grep -qx "ssh.service"; then
    systemctl enable --now ssh >/dev/null 2>&1 || true
    systemctl restart ssh
    systemctl --no-pager --full status ssh || true
  elif systemctl list-unit-files | awk '{print $1}' | grep -qx "sshd.service"; then
    systemctl enable --now sshd >/dev/null 2>&1 || true
    systemctl restart sshd
    systemctl --no-pager --full status sshd || true
  else
    log "No ssh.service/sshd.service found; attempting to restart via 'service ssh restart' fallback."
    service ssh restart || service sshd restart || die "Could not restart ssh service"
  fi

  log "Restarted SSH successfully."

  # Show what it's listening on:
  if command -v ss >/dev/null 2>&1; then
    ss -lntp | awk -v p=":${SSH_PORT}" '$4 ~ p || NR==1'
  fi
}

install_ufw_if_missing() {
  if command -v ufw >/dev/null 2>&1; then
    return 0
  fi
  log "ufw not found; installing..."
  apt-get update -y
  apt-get install -y ufw
}

configure_ufw() {
  install_ufw_if_missing

  # Set defaults (does not wipe existing rules).
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null

  # Ensure the allow-on-tailscale rule is evaluated before any deny 22 rule.
  # "insert 1" places it at the top.
  ufw insert 1 allow in on "$TS_IF" to any port "$SSH_PORT" proto tcp >/dev/null 2>&1 || true

  if [[ "$ALLOW_LAN_SSH" == "1" ]]; then
    ufw allow from "$LAN_CIDR" to any port "$SSH_PORT" proto tcp >/dev/null 2>&1 || true
    log "ufw: also allowed SSH from LAN_CIDR=$LAN_CIDR"
  fi

  # Deny SSH on all other interfaces (public/LAN/etc).
  ufw deny in "$SSH_PORT"/tcp >/dev/null 2>&1 || true

  # Enable if not already active.
  ufw --force enable >/dev/null 2>&1 || true

  log "ufw configured. Status:"
  ufw status verbose || true
}

main() {
  require_root
  require_cmd systemctl
  ensure_openssh

  ensure_tailscale_up
  local ts_ip
  ts_ip="$(get_ts_ip4)"
  [[ -n "$ts_ip" ]] || die "No Tailscale IPv4 found; refusing to proceed."

  write_sshd_dropin "$ts_ip"
  ensure_sshd_after_tailscale
  validate_and_restart_sshd
  configure_ufw

  log "Done."
  log "Use VS Code Remote-SSH / ssh with the host's MagicDNS name or 100.x Tailscale IP."
  log "Example ~/.ssh/config:"
  log "  Host ipc1"
  log "    HostName <magicdns-name>"
  log "    User <user>"
}

main "$@"
