#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${1:-$STACK_DIR/.env.dev}"
PIDFILE="$STACK_DIR/.watch-sim-deps.pid"
LOCKFILE="$STACK_DIR/.watch-sim-deps.lock"

exec 9>"$LOCKFILE"
if ! flock -n 9; then
  exit 0
fi

cleanup() {
  rm -f "$PIDFILE"
}
trap cleanup EXIT

echo "$$" >"$PIDFILE"

COMPOSE_ARGS=(-f "$STACK_DIR/compose.yml" -f "$STACK_DIR/compose.dev.yml" --env-file "$ENV_FILE")

site_agent_cid="$(docker compose "${COMPOSE_ARGS[@]}" ps -q site-agent 2>/dev/null || true)"
if [ -z "$site_agent_cid" ]; then
  echo "watch-sim-deps: site-agent container not found" >&2
  exit 0
fi

project_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$site_agent_cid" 2>/dev/null || true)"
if [ -z "$project_name" ]; then
  echo "watch-sim-deps: compose project label not found" >&2
  exit 0
fi

docker events \
  --filter "label=com.docker.compose.project=$project_name" \
  --filter "label=com.docker.compose.service=site-agent" \
  --filter 'event=start' \
  --format '{{.Time}} {{.Action}} {{.Actor.Attributes.name}}' |
while IFS= read -r line; do
  [ -n "$line" ] || continue
  sleep 2
  if docker compose "${COMPOSE_ARGS[@]}" ps -q fake-miner-fleet >/dev/null 2>&1; then
    echo "watch-sim-deps: site-agent start detected, restarting fake-miner-fleet" >&2
    docker compose "${COMPOSE_ARGS[@]}" restart fake-miner-fleet >/dev/null 2>&1 || true
  fi
done
