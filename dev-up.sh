#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${1:-$STACK_DIR/.env}"

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing env file: $ENV_FILE" >&2
  echo "Copy $STACK_DIR/.env.example -> $STACK_DIR/.env first." >&2
  exit 1
fi

cd "$STACK_DIR"
docker compose -f compose.yml -f compose.dev.yml --env-file "$ENV_FILE" up -d
