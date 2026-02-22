#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${1:-$STACK_DIR/.env}"

cd "$STACK_DIR"
docker compose -f compose.yml --env-file "$ENV_FILE" down
