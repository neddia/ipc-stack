#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -n "${1:-}" ]; then
  ENV_FILE="$1"
elif [ -f "$STACK_DIR/.env.dev" ]; then
  ENV_FILE="$STACK_DIR/.env.dev"
else
  ENV_FILE="$STACK_DIR/.env"
fi

cd "$STACK_DIR"
docker compose -f compose.yml -f compose.dev.yml --env-file "$ENV_FILE" down
