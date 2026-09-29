#!/usr/bin/env bash
# Keep container and host logs on the appliance long enough to diagnose problems.
#
# Container logs go to journald, so they survive container recreation (every
# update and rollback recreates site-agent, and Docker deletes a json-file log
# with its container). journald keeps them persistent across reboots, capped
# at ~1G: about six weeks at site-agent's measured ~11 MB/day.
#
#   journalctl -t ipc-stack-site-agent-1 --since "2026-09-28 15:00" --until "15:30"
#
# Idempotent. Prints "recreate" when Docker's logging config changed: containers
# keep the driver they were created with until they are recreated.
set -euo pipefail

DAEMON_JSON="${DOCKER_DAEMON_JSON:-/etc/docker/daemon.json}"
JOURNALD_DROPIN="${JOURNALD_DROPIN:-/etc/systemd/journald.conf.d/size-limit.conf}"

log() { echo "[ipc-logging] $*" >&2; }

journald_conf='[Journal]
Storage=persistent
SystemMaxUse=1G
SystemMaxFileSize=100M
RuntimeMaxUse=100M'

mkdir -p "$(dirname "$JOURNALD_DROPIN")"
if [ "$(cat "$JOURNALD_DROPIN" 2>/dev/null || true)" != "$journald_conf" ]; then
  printf '%s\n' "$journald_conf" >"$JOURNALD_DROPIN"
  log "journald: persistent, capped at 1G"
  systemctl restart systemd-journald || true
fi

mkdir -p "$(dirname "$DAEMON_JSON")"
changed="$(python3 - "$DAEMON_JSON" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
try:
    config = json.loads(path.read_text()) if path.exists() and path.read_text().strip() else {}
except ValueError:
    sys.exit("daemon.json is not valid JSON; not changing it")
before = json.dumps(config, sort_keys=True)
config["log-driver"] = "journald"
# json-file options (max-size/max-file) are invalid under journald and would stop dockerd.
config["log-opts"] = {"tag": "{{.Name}}"}
config["live-restore"] = True
if json.dumps(config, sort_keys=True) != before:
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(config, indent=2) + "\n")
    tmp.replace(path)
    print("changed")
PY
)"
if [ "$changed" = changed ]; then
  # On a fresh install this runs before Docker exists; dockerd reads it at first start.
  if systemctl is-active --quiet docker 2>/dev/null; then
    log "docker: container logs now go to journald; restarting dockerd"
    systemctl restart docker
  fi
  echo recreate
fi
