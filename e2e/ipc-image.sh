#!/usr/bin/env bash
# Derive the e2e site-agent image: the given release image plus a trust bundle
# that includes the test Cloud's CA, exported where build-media.sh preloads it.
# Test-only; production images trust public roots only.
#   e2e/ipc-image.sh <source-tag> <e2e-tag>
set -euo pipefail
SRC_TAG="${1:?source tag}"; DST_TAG="${2:?e2e tag}"
IMAGE="${SITE_AGENT_IMAGE_REPO:-release-mirror:5000/neddia/site-agent}"
PRIVATE_DIR="${IPC_E2E_PRIVATE_DIR:-$HOME/.config/toops-e2e}"
OUT="${IPC_E2E_IMAGE_DIR:-$HOME/.cache/toops-e2e/images}"
ctx="$(mktemp -d)"; trap 'rm -rf "$ctx"' EXIT
cp "$PRIVATE_DIR/cloud-e2e/ca-root.pem" "$ctx/e2e-ca.pem"
cat >"$ctx/Dockerfile" <<DOCKER
FROM $IMAGE:$SRC_TAG
USER root
COPY e2e-ca.pem /tmp/e2e-ca.pem
# The Cloud clients pass trust_env=False, so SSL_CERT_FILE is not enough:
# extend certifi's bundle itself.
RUN cat /tmp/e2e-ca.pem >> "\$(python -c 'import certifi; print(certifi.where())')" && rm /tmp/e2e-ca.pem
USER siteagent
DOCKER
docker build -q -t "$IMAGE:$DST_TAG" "$ctx" >/dev/null
mkdir -p "$OUT"
docker save "$IMAGE:$DST_TAG" | gzip -1 >"$OUT/site-agent-$DST_TAG.tar.gz"
echo "$OUT/site-agent-$DST_TAG.tar.gz"
