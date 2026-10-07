# shellcheck shell=bash
# Sourced by install.sh and update.sh; expects log() and SITE_AGENT_IMAGE.
#
# Production images come from the Toops release mirror, which is reachable only
# over the tailnet and holds the upstream registry credential itself. Devices
# pull from it anonymously and keep no registry login, so removing a device
# from the tailnet is what revokes its access to new releases.
#
# The mirror is plain HTTP inside WireGuard, so Docker must be told to trust it.
# An image still pointing at ghcr.io keeps the legacy login path until the box
# is moved to the mirror.

release_registry_host() {
  # Print the registry host of an image reference, or nothing for references
  # without one (Docker Hub, or local names such as local/site-agent).
  local image="$1" first
  first="${image%%/*}"
  if [ "$first" != "$image" ] && { [[ "$first" == *.* ]] || [[ "$first" == *:* ]] || [ "$first" = localhost ]; }; then
    echo "$first"
  fi
}

trust_release_mirror() {
  local registry="$1"
  local daemon_json="${DOCKER_DAEMON_JSON:-/etc/docker/daemon.json}"
  local changed
  mkdir -p "$(dirname "$daemon_json")"
  changed="$(python3 - "$daemon_json" "$registry" <<'PY'
import json
import sys
from pathlib import Path

path, registry = Path(sys.argv[1]), sys.argv[2]
text = path.read_text() if path.exists() else ""
config = json.loads(text) if text.strip() else {}
registries = config.setdefault("insecure-registries", [])
if registry in registries:
    print("unchanged")
else:
    registries.append(registry)
    path.write_text(json.dumps(config, indent=2) + "\n")
    print("changed")
PY
)"
  if [ "$changed" = "changed" ]; then
    log "trusting release mirror $registry (tailnet only)"
    # insecure-registries is reloadable; running containers are untouched.
    systemctl reload docker
  fi
}

forget_ghcr_login() {
  local docker_cfg="${DOCKER_CONFIG:-/root/.docker}/config.json"
  if [ -f "$docker_cfg" ] && grep -q '"ghcr.io"' "$docker_cfg"; then
    log "removing the stored ghcr.io login; releases now come from the mirror"
    docker logout ghcr.io >/dev/null
  fi
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

prepare_release_registry() {
  # $1=pull when images will be pulled now; trust is configured either way so
  # later updates from a preloaded install still reach the mirror.
  local registry
  registry="$(release_registry_host "${SITE_AGENT_IMAGE:-}")"
  if [ "$registry" = "ghcr.io" ]; then
    if [ "${1:-}" = "pull" ]; then
      docker_login_ghcr
    fi
    return
  fi
  if [ -n "$registry" ]; then
    trust_release_mirror "$registry"
  fi
  forget_ghcr_login
}
