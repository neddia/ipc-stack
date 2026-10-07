#!/usr/bin/env bash
set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Run as root (sudo $0)" >&2
  exit 1
fi

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$STACK_DIR/.env"

log() { echo "[ipc-update] $*"; }
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

set_release() {
  # Pin the application image to a release (tag, optionally @sha256:digest)
  # and remember the outgoing pin so a bad update can roll back (and prune
  # knows what to keep).
  local ref="$1" version digest=""
  version="${ref%%@*}"
  [ "$version" = "$ref" ] || digest="${ref#*@}"
  if [ -n "$digest" ] && ! [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "Release digest must look like sha256:<64 hex>: $digest" >&2
    exit 2
  fi
  if [ -n "${SITE_AGENT_VERSION:-}" ] && [ "$SITE_AGENT_VERSION" != "$version" ]; then
    persist_env_var "$ENV_FILE" "SITE_AGENT_PREV_VERSION" "$SITE_AGENT_VERSION"
    persist_env_var "$ENV_FILE" "SITE_AGENT_PREV_DIGEST" "${SITE_AGENT_DIGEST:-}"
    SITE_AGENT_PREV_VERSION="$SITE_AGENT_VERSION"
    SITE_AGENT_PREV_DIGEST="${SITE_AGENT_DIGEST:-}"
  fi
  persist_env_var "$ENV_FILE" "SITE_AGENT_VERSION" "$version"
  persist_env_var "$ENV_FILE" "SITE_AGENT_DIGEST" "$digest"
  export SITE_AGENT_VERSION="$version" SITE_AGENT_DIGEST="$digest"
  export SITE_AGENT_PREV_VERSION="${SITE_AGENT_PREV_VERSION:-}" SITE_AGENT_PREV_DIGEST="${SITE_AGENT_PREV_DIGEST:-}"
  log "set SITE_AGENT_VERSION=$version${digest:+ (digest $digest)}"
}

revert_pin() {
  # Failure before any container was switched: leave the device exactly as it was.
  persist_env_var "$ENV_FILE" "SITE_AGENT_VERSION" "$FROM_VERSION"
  persist_env_var "$ENV_FILE" "SITE_AGENT_DIGEST" "$FROM_DIGEST"
  persist_env_var "$ENV_FILE" "SITE_AGENT_PREV_VERSION" "$FROM_PREV_VERSION"
  persist_env_var "$ENV_FILE" "SITE_AGENT_PREV_DIGEST" "$FROM_PREV_DIGEST"
}

verify_digest() {
  # Tags can move; the digest published by the release workflow cannot.
  [ -n "${SITE_AGENT_DIGEST:-}" ] || return 0
  docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' \
    "${SITE_AGENT_IMAGE}:${SITE_AGENT_VERSION}" 2>/dev/null | grep -q "@${SITE_AGENT_DIGEST}\$"
}

rollback_release() {
  local sa_prev="${SITE_AGENT_PREV_VERSION:-}"
  if [ -z "$sa_prev" ]; then
    return 1
  fi
  log "rolling back to site-agent=$sa_prev"
  persist_env_var "$ENV_FILE" "SITE_AGENT_VERSION" "$sa_prev"
  persist_env_var "$ENV_FILE" "SITE_AGENT_DIGEST" "${SITE_AGENT_PREV_DIGEST:-}"
  export SITE_AGENT_VERSION="$sa_prev" SITE_AGENT_DIGEST="${SITE_AGENT_PREV_DIGEST:-}"
  if [ -n "${SNAPSHOT:-}" ]; then
    # The failed release may have migrated config or databases the previous
    # one cannot read. Writes since the switch (minutes) are given up.
    docker compose stop site-agent
    log "restoring site state from $SNAPSHOT"
    if ! python3 "$STACK_DIR/scripts/storage-snapshot.py" restore --storage "$STORAGE_DIR" --snapshot "$SNAPSHOT"; then
      log "snapshot restore FAILED; starting the previous release on current state"
    fi
  fi
  docker compose up -d
}

prune_image_tags() {
  # Remove tags of $repo other than the two we keep (current + previous).
  local repo="$1" keep_a="$2" keep_b="$3"
  if [ -z "$repo" ]; then
    return
  fi
  docker images --format '{{.Repository}}:{{.Tag}}' "$repo" 2>/dev/null | while read -r ref; do
    tag="${ref##*:}"
    if [ "$tag" = "<none>" ]; then
      continue  # dangling layers; docker image prune handles them
    fi
    if [ "$tag" != "$keep_a" ] && [ "$tag" != "$keep_b" ]; then
      log "pruning old image $ref"
      docker rmi "$ref" >/dev/null 2>&1 || true
    fi
  done
}

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE. Run ./install.sh first." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# Never roll back to images without commissioning-hold support mid-swap.
python3 "$STACK_DIR/scripts/ensure-ipc-identity.py" --validate-only --secrets "${IPC_SECRETS_DIR:-$STACK_DIR/.secrets}" --storage "${IPC_STORAGE_DIR:-/opt/site-agent/storage}"
replacement_state="${IPC_STORAGE_DIR:-/opt/site-agent/storage}/ipc/replacement.json"
if [ -f "$replacement_state" ]; then
  python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("phase") == "active" else "Finish or resolve hardware replacement before updating images")' "$replacement_state"
fi

STORAGE_DIR="${IPC_STORAGE_DIR:-/opt/site-agent/storage}"
FROM_VERSION="${SITE_AGENT_VERSION:-}"
FROM_DIGEST="${SITE_AGENT_DIGEST:-}"
FROM_PREV_VERSION="${SITE_AGENT_PREV_VERSION:-}"
FROM_PREV_DIGEST="${SITE_AGENT_PREV_DIGEST:-}"
SNAPSHOT=""

if [ $# -ge 1 ]; then
  set_release "$1"
fi

if [ -z "${SITE_AGENT_UID:-}" ] || [ -z "${SITE_AGENT_GID:-}" ]; then
  if [ -n "${SUDO_USER:-}" ] && id -u "$SUDO_USER" >/dev/null 2>&1; then
    SITE_AGENT_UID="$(id -u "$SUDO_USER")"
    SITE_AGENT_GID="$(id -g "$SUDO_USER")"
  fi
fi

ensure_user_owned "$ENV_FILE"

prepare_release_registry pull

cd "$STACK_DIR"
# What the running release already reports as broken is the site's problem,
# not the new release's; the post-update check only fails on new errors.
BASELINE="$(mktemp)"
trap 'rm -f "$BASELINE"' EXIT
"$STACK_DIR/scripts/check-health.sh" --env-file "$ENV_FILE" --capture-baseline "$BASELINE"
if ! docker compose pull; then
  revert_pin
  log "image pull failed; nothing was changed"
  exit 1
fi
if ! verify_digest; then
  revert_pin
  log "pulled ${SITE_AGENT_IMAGE}:${SITE_AGENT_VERSION} does not match digest ${SITE_AGENT_DIGEST}; nothing was changed"
  exit 1
fi
if [ "$SITE_AGENT_VERSION" != "$FROM_VERSION" ] || [ "${SITE_AGENT_DIGEST:-}" != "$FROM_DIGEST" ]; then
  if ! SNAPSHOT="$(python3 "$STACK_DIR/scripts/storage-snapshot.py" snapshot --storage "$STORAGE_DIR" \
      --label "${FROM_VERSION:-none}-to-${SITE_AGENT_VERSION}")"; then
    revert_pin
    log "could not snapshot site state; nothing was changed"
    exit 1
  fi
  log "site state snapshot: $SNAPSHOT"
fi
"$STACK_DIR/scripts/sync-defaults.sh" --env-file "$ENV_FILE"

# Appliances keep container logs in journald so they outlive this update; a
# logging change only reaches containers when they are recreated.
RECREATE=()
if [ "$STACK_DIR" = '/opt/ipc-stack' ] && [ "$("$STACK_DIR/scripts/configure-logging.sh")" = recreate ]; then
  RECREATE=(--force-recreate)
fi

log "validating influx buckets and telegraf token"
docker compose up -d "${RECREATE[@]}" influxdb
"$STACK_DIR/scripts/bootstrap-influx.sh"
docker compose up -d "${RECREATE[@]}"

ensure_user_owned "$STACK_DIR/.secrets"

if ! "$STACK_DIR/scripts/check-health.sh" --env-file "$ENV_FILE" --baseline "$BASELINE" \
    --soak "${IPC_UPDATE_SOAK_S:-180}"; then
  log "health check FAILED on ${SITE_AGENT_VERSION:-?}"
  if rollback_release; then
    if "$STACK_DIR/scripts/check-health.sh" --env-file "$ENV_FILE" --baseline "$BASELINE"; then
      log "rollback to ${SITE_AGENT_VERSION} healthy; update aborted"
    else
      log "rollback did NOT become healthy; manual intervention required"
    fi
  else
    log "no previous version recorded; cannot auto-rollback"
  fi
  exit 1
fi

prune_image_tags "${SITE_AGENT_IMAGE:-}" "${SITE_AGENT_VERSION:-latest}" "${SITE_AGENT_PREV_VERSION:-}"
docker image prune -f >/dev/null || true

log "update complete"
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
