#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$STACK_DIR/.env"
IMAGE_REF=""
REFRESH_RUNTIME_PROFILES=0
REFRESH_SITE_CONFIG=0

usage() {
  cat <<'EOF'
Usage: sync-defaults.sh [--env-file PATH] [--image IMAGE[:TAG]] [--refresh-runtime-profiles] [--refresh-site-config]

Copies bundled defaults out of the pinned site-agent image into host storage.
- Always refreshes storage/site-config.example.yml
- Always refreshes storage/profiles.defaults/
- Initializes storage/site-config.yml and storage/profiles/ when missing
- Never overwrites runtime storage unless an explicit refresh flag is passed
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file)
      ENV_FILE="$2"
      shift 2
      ;;
    --image)
      IMAGE_REF="$2"
      shift 2
      ;;
    --refresh-runtime-profiles)
      REFRESH_RUNTIME_PROFILES=1
      shift
      ;;
    --refresh-site-config)
      REFRESH_SITE_CONFIG=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[ipc-defaults] unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ ! -f "$ENV_FILE" ]; then
  echo "[ipc-defaults] missing env file: $ENV_FILE" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if [ -z "$IMAGE_REF" ]; then
  if [ -z "${SITE_AGENT_IMAGE:-}" ] || [ -z "${SITE_AGENT_VERSION:-}" ]; then
    echo "[ipc-defaults] SITE_AGENT_IMAGE/SITE_AGENT_VERSION must be set" >&2
    exit 1
  fi
  IMAGE_REF="${SITE_AGENT_IMAGE}:${SITE_AGENT_VERSION}"
fi

STORAGE_DIR="${IPC_STORAGE_DIR:-/opt/site-agent/storage}"
TMP_DIR="$(mktemp -d)"
CID=""
TOUCHED_PATHS=()

log() { echo "[ipc-defaults] $*"; }

cleanup() {
  if [ -n "$CID" ]; then
    docker rm -f "$CID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$STORAGE_DIR"

log "extracting defaults from $IMAGE_REF"
CID="$(docker create "$IMAGE_REF")"
docker cp "$CID:/app/defaults/." "$TMP_DIR/"

if [ ! -f "$TMP_DIR/site-config.example.yml" ]; then
  echo "[ipc-defaults] image is missing /app/defaults/site-config.example.yml" >&2
  exit 1
fi
if [ ! -d "$TMP_DIR/profiles" ]; then
  echo "[ipc-defaults] image is missing /app/defaults/profiles" >&2
  exit 1
fi

cp "$TMP_DIR/site-config.example.yml" "$STORAGE_DIR/site-config.example.yml"
TOUCHED_PATHS+=("$STORAGE_DIR/site-config.example.yml")
log "refreshed $STORAGE_DIR/site-config.example.yml"

if [ ! -f "$STORAGE_DIR/site-config.yml" ] || [ "$REFRESH_SITE_CONFIG" = "1" ]; then
  cp "$TMP_DIR/site-config.example.yml" "$STORAGE_DIR/site-config.yml"
  TOUCHED_PATHS+=("$STORAGE_DIR/site-config.yml")
  if [ "$REFRESH_SITE_CONFIG" = "1" ]; then
    log "refreshed $STORAGE_DIR/site-config.yml from bundled defaults"
  else
    log "initialized $STORAGE_DIR/site-config.yml from bundled defaults"
  fi
fi

rm -rf "$STORAGE_DIR/profiles.defaults.tmp"
cp -a "$TMP_DIR/profiles" "$STORAGE_DIR/profiles.defaults.tmp"
rm -rf "$STORAGE_DIR/profiles.defaults"
mv "$STORAGE_DIR/profiles.defaults.tmp" "$STORAGE_DIR/profiles.defaults"
TOUCHED_PATHS+=("$STORAGE_DIR/profiles.defaults")
log "refreshed $STORAGE_DIR/profiles.defaults"

if [ ! -d "$STORAGE_DIR/profiles" ]; then
  cp -a "$TMP_DIR/profiles" "$STORAGE_DIR/profiles"
  TOUCHED_PATHS+=("$STORAGE_DIR/profiles")
  log "initialized $STORAGE_DIR/profiles from bundled defaults"
else
  while IFS= read -r -d '' src; do
    rel="${src#"$TMP_DIR/profiles/"}"
    dest="$STORAGE_DIR/profiles/$rel"
    if [ "$REFRESH_RUNTIME_PROFILES" = "1" ] || [ ! -e "$dest" ]; then
      mkdir -p "$(dirname "$dest")"
      cp -a "$src" "$dest"
      TOUCHED_PATHS+=("$dest")
      if [ "$REFRESH_RUNTIME_PROFILES" = "1" ]; then
        log "refreshed runtime profile $rel"
      else
        log "initialized missing runtime profile $rel"
      fi
    fi
  done < <(find "$TMP_DIR/profiles" -type f -print0)
fi

if [[ "${SITE_AGENT_UID:-}" =~ ^[0-9]+$ ]] && [[ "${SITE_AGENT_GID:-}" =~ ^[0-9]+$ ]]; then
  for path in "${TOUCHED_PATHS[@]}"; do
    chown -R "${SITE_AGENT_UID}:${SITE_AGENT_GID}" "$path" || true
  done
fi
