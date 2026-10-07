#!/usr/bin/env bash
# toops-support: host switch for Toops remote access to this controller.
#
#   sudo toops-support off      block Toops access and end open SSH sessions
#   sudo toops-support on       allow Toops access again
#   sudo toops-support status   show the setting and recent Toops logins
#   sudo toops-support apply    enforce the setting chosen on the site dashboard
#
# The customer's dashboard toggle writes a one-field request file; a systemd
# path unit runs `apply` as root whenever it changes, at boot, and every few
# minutes. "Off" means:
#   - SSH: the Toops support user is denied and its sessions are ended;
#   - tailnet UI: port 8000 over Tailscale is dropped for everything except the
#     Toops Cloud gateway, so the customer's own Cloud remote access keeps
#     working while operator laptops on the tailnet cannot reach the UI;
#   - Cloud: the check-in reports the setting and the Cloud proxy refuses
#     platform-admin sessions to this site.
# Updates that need SSH wait until support is switched back on. Every change
# is journaled (tag: toops-support) and summarized in a status file the
# dashboard shows.
set -euo pipefail

SUPPORT_USER="${TOOPS_SUPPORT_USER:-toops}"
DROPIN="${TOOPS_SUPPORT_DROPIN:-/etc/ssh/sshd_config.d/50-toops-support-off.conf}"
STORAGE_IPC="${IPC_STORAGE_DIR:-/opt/site-agent/storage}/ipc"
REQUEST="${TOOPS_SUPPORT_REQUEST:-$STORAGE_IPC/support-access-request.json}"
STATUS="${TOOPS_SUPPORT_STATUS:-$STORAGE_IPC/support-access.json}"
TS_IF="${TS_IF:-tailscale0}"
UI_PORT="${SETPOINT_UI_PORT:-8000}"
GATEWAY_TAG="${TOOPS_GATEWAY_TAG:-tag:gateway}"
SITE_AGENT_UID="${SITE_AGENT_UID:-1000}"
SITE_AGENT_GID="${SITE_AGENT_GID:-1000}"
CHAIN=TOOPS-SUPPORT

die() { echo "toops-support: $*" >&2; exit 1; }

require_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || die "run with sudo"
}

usage() {
  cat <<'USAGE'
Usage:
  sudo toops-support off      block Toops access and end open SSH sessions
  sudo toops-support on       allow Toops access again
  sudo toops-support status   show the setting and recent Toops logins
  sudo toops-support apply    enforce the setting chosen on the site dashboard
USAGE
}

reload_sshd() {
  if ! sshd -t; then
    echo "toops-support: sshd rejected its configuration; no change applied" >&2
    return 1
  fi
  # Reload a running sshd; an idle socket-activated one reads the file on
  # its next start.
  systemctl try-reload-or-restart ssh.service 2>/dev/null \
    || systemctl try-reload-or-restart sshd.service
}

current_state() {
  if [ -f "$DROPIN" ]; then echo off; else echo on; fi
}

record() {
  logger -t toops-support "$1 by ${SUDO_USER:-root}"
}

# The dashboard request is untrusted input: only a JSON boolean is accepted.
requested_state() {
  [ -f "$REQUEST" ] || return 0
  python3 - "$REQUEST" <<'PY' 2>/dev/null || true
import json, sys
value = json.load(open(sys.argv[1])).get("enabled")
if isinstance(value, bool):
    print("on" if value else "off")
PY
}

write_request() {
  mkdir -p "$(dirname "$REQUEST")"
  python3 - "$REQUEST" "$1" "${SUDO_USER:-root}" <<'PY'
import json, os, sys
from datetime import datetime, timezone
path, state, actor = sys.argv[1:]
tmp = path + ".tmp"
with open(tmp, "w") as out:
    json.dump({"enabled": state == "on", "requested_at": datetime.now(timezone.utc).isoformat(),
               "source": "host console (" + actor + ")"}, out)
os.replace(tmp, path)
PY
  chown "$SITE_AGENT_UID:$SITE_AGENT_GID" "$REQUEST" 2>/dev/null || true
  chmod 0644 "$REQUEST"
}

gateway_ips() {
  tailscale status --json 2>/dev/null | python3 -c '
import ipaddress, json, sys
tag = sys.argv[1]
for peer in (json.load(sys.stdin).get("Peer") or {}).values():
    if tag in (peer.get("Tags") or []):
        for ip in peer.get("TailscaleIPs") or []:
            if ipaddress.ip_address(ip).version == 4:
                print(ip)
' "$GATEWAY_TAG" 2>/dev/null || true
}

# Docker-published ports bypass UFW, so the tailnet UI rule lives in DOCKER-USER.
apply_firewall() {
  local state="$1" ip
  iptables -nL DOCKER-USER >/dev/null 2>&1 || iptables -N DOCKER-USER
  iptables -nL "$CHAIN" >/dev/null 2>&1 || iptables -N "$CHAIN"
  iptables -C DOCKER-USER -j "$CHAIN" 2>/dev/null || iptables -I DOCKER-USER 1 -j "$CHAIN"
  iptables -F "$CHAIN"
  GATEWAYS=0
  if [ "$state" = off ]; then
    for ip in $(gateway_ips); do
      iptables -A "$CHAIN" -i "$TS_IF" -s "$ip" -p tcp -m conntrack --ctorigdstport "$UI_PORT" -j RETURN
      GATEWAYS=$((GATEWAYS + 1))
    done
    iptables -A "$CHAIN" -i "$TS_IF" -p tcp -m conntrack --ctorigdstport "$UI_PORT" -j DROP
  fi
  iptables -A "$CHAIN" -j RETURN
}

recent_logins() {
  journalctl -u ssh.service -u sshd.service --since "-30d" --no-pager -o short-iso \
    --grep "Accepted publickey for ${SUPPORT_USER} " 2>/dev/null | tail -n 10 || true
}

write_status() {
  local state="$1" error="${2:-}"
  mkdir -p "$(dirname "$STATUS")"
  recent_logins | python3 - "$STATUS" "$state" "${GATEWAYS:-0}" "$error" <<'PY'
import json, os, sys
from datetime import datetime, timezone
path, state, gateways, error = sys.argv[1:]
logins = []
for line in sys.stdin.read().splitlines():
    parts = line.split()
    if len(parts) > 1 and " from " in line:
        logins.append({"at": parts[0], "from": line.split(" from ", 1)[1].split()[0]})
payload = {
    "enabled": state == "on",
    "applied_at": datetime.now(timezone.utc).isoformat(),
    "ssh_blocked": state == "off",
    "tailnet_ui_blocked": state == "off",
    "cloud_gateways_allowed": int(gateways),
    "recent_logins": logins[-10:],
    "error": error or None,
}
tmp = path + ".tmp"
with open(tmp, "w") as out:
    json.dump(payload, out)
os.replace(tmp, path)
PY
  chown "$SITE_AGENT_UID:$SITE_AGENT_GID" "$STATUS" 2>/dev/null || true
  chmod 0644 "$STATUS"
}

set_ssh() {
  local state="$1"
  if [ "$state" = on ]; then
    [ -f "$DROPIN" ] || return 0
    rm -f "$DROPIN"
    reload_sshd
    return
  fi
  [ -f "$DROPIN" ] && return 0
  mkdir -p "$(dirname "$DROPIN")"
  printf '# Written by toops-support; remove with `sudo toops-support on`.\nDenyUsers %s\n' \
    "$SUPPORT_USER" >"$DROPIN"
  if ! reload_sshd; then
    rm -f "$DROPIN"
    return 1
  fi
}

# Enforce one state everywhere. Sets SWITCHED_OFF when access was just taken
# away, so the caller can end open sessions last.
enforce() {
  local state="$1" before
  SWITCHED_OFF=0
  before="$(current_state)"
  set_ssh "$state" || { write_status "$before" "sshd rejected its configuration"; return 1; }
  if ! apply_firewall "$state"; then
    write_status "$state" "firewall rules could not be applied"
    return 1
  fi
  write_status "$state"
  if [ "$before" != "$state" ]; then
    if [ "$state" = on ]; then record "Toops support access enabled"; else record "Toops support access disabled"; fi
  fi
  if [ "$state" = off ] && [ "$before" = on ]; then SWITCHED_OFF=1; fi
}

# Last, because it may end the caller's own session. It ends login sessions
# only: containers run outside logind sessions, so site-agent keeps running
# even though it may share the support UID.
end_sessions() {
  [ "${SWITCHED_OFF:-0}" = 1 ] || return 0
  loginctl terminate-user "$SUPPORT_USER" >/dev/null 2>&1 || true
}

case "${1:-status}" in
  on)
    require_root
    write_request on
    enforce on
    echo "Toops support access is ON. Toops can open a remote shell and reach this controller's UI."
    ;;
  off)
    require_root
    write_request off
    enforce off
    echo "Toops support access is OFF. Open Toops sessions are being closed."
    echo "Remote support will need it switched back on from the site dashboard or with: sudo toops-support on"
    end_sessions
    ;;
  apply)
    require_root
    state="$(requested_state)"
    enforce "${state:-$(current_state)}"
    end_sessions
    ;;
  status)
    require_root
    echo "Toops support access: $(current_state | tr '[:lower:]' '[:upper:]')"
    echo
    echo "Recent Toops logins (last 30 days):"
    recent_logins
    echo
    echo "Setting changes:"
    journalctl -t toops-support --since "-90d" --no-pager -o short-iso \
      --grep "support access (enabled|disabled) by" 2>/dev/null | tail -n 10 || true
    ;;
  *)
    usage
    exit 2
    ;;
esac
