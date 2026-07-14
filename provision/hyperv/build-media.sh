#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PRIVATE_DIR="${IPC_E2E_PRIVATE_DIR:-$HOME/.config/toops-e2e}"
CACHE_DIR="${IPC_E2E_CACHE_DIR:-$HOME/.cache/toops-e2e}"
BASE_ISO="${UBUNTU_ISO:-$CACHE_DIR/ubuntu-24.04.4-live-server-amd64.iso}"
BASE_ISO_SHA256="${UBUNTU_ISO_SHA256:-e907d92eeec9df64163a7e454cbc8d7755e8ddc7ed42f99dbc80c40f1a138433}"
OUTPUT_DIR="${IPC_E2E_MEDIA_DIR:-$CACHE_DIR/media}"
HOSTNAME="${IPC_E2E_HOSTNAME:-ipc-e2e-x86-01}"
SEED_FILE="$PRIVATE_DIR/seed.env"
SSH_KEY="$PRIVATE_DIR/id_ed25519"
CONSOLE_PASSWORD_FILE="$PRIVATE_DIR/console-password"
ISO_TOOLS_IMAGE="toops/ipc-e2e-iso-tools:bookworm"
IMAGE_DIR="${IPC_E2E_IMAGE_DIR:-}"
IMAGE_TAG="${IPC_E2E_IMAGE_TAG:-}"
USE_LOCAL_STACK="${IPC_E2E_LOCAL_STACK:-1}"

die() { echo "[ipc-e2e] ERROR: $*" >&2; exit 1; }
log() { echo "[ipc-e2e] $*"; }

[ -s "$BASE_ISO" ] || die "missing Ubuntu ISO: $BASE_ISO"
[ -s "$SEED_FILE" ] || die "missing private seed: $SEED_FILE"
[ "$(stat -c '%a' "$SEED_FILE")" = "600" ] || die "$SEED_FILE must have mode 600"
echo "$BASE_ISO_SHA256  $BASE_ISO" | sha256sum --check --status \
  || die "Ubuntu ISO checksum mismatch: $BASE_ISO"
mkdir -p "$PRIVATE_DIR" "$CACHE_DIR" "$OUTPUT_DIR"
chmod 0700 "$PRIVATE_DIR"

if [ ! -s "$SSH_KEY" ]; then
  ssh-keygen -q -t ed25519 -N "" -C "ipc-e2e" -f "$SSH_KEY"
  chmod 0600 "$SSH_KEY"
fi
if [ ! -s "$CONSOLE_PASSWORD_FILE" ]; then
  openssl rand -base64 24 > "$CONSOLE_PASSWORD_FILE"
  chmod 0600 "$CONSOLE_PASSWORD_FILE"
fi

stage="$(mktemp -d "$CACHE_DIR/media-stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
cp "$STACK_DIR/provision/autoinstall/user-data" "$stage/user-data"
cp "$STACK_DIR/provision/autoinstall/meta-data" "$stage/meta-data"
cp "$SEED_FILE" "$stage/seed.env"

set_seed_values() {
  SEED_STAGE="$stage/seed.env" SEED_VALUES="$1" python3 - <<'PY'
import json, os
from pathlib import Path

path = Path(os.environ["SEED_STAGE"])
values = json.loads(os.environ["SEED_VALUES"])
lines = path.read_text().splitlines()
seen = set()
out = []
for line in lines:
    key = line.split("=", 1)[0].strip() if "=" in line else ""
    if key in values:
        out.append(f"{key}={values[key]}")
        seen.add(key)
    else:
        out.append(line)
for key, value in values.items():
    if key not in seen:
        out.append(f"{key}={value}")
path.write_text("\n".join(out) + "\n")
PY
}

set_seed_values "$(HOSTNAME="$HOSTNAME" python3 -c 'import json,os; print(json.dumps({"TS_HOSTNAME": os.environ["HOSTNAME"]}))')"

if [ -n "${IPC_E2E_CLOUD_BASE_URL:-}" ]; then
  set_seed_values "$(python3 -c 'import json,os; print(json.dumps({"CLOUD_BASE_URL": os.environ["IPC_E2E_CLOUD_BASE_URL"], "CLOUD_PUBLIC_BASE_URL": os.environ["IPC_E2E_CLOUD_BASE_URL"]}))')"
fi

mkdir -p "$stage/images"
if [ -n "$IMAGE_TAG" ]; then
  set_seed_values "$(IMAGE_TAG="$IMAGE_TAG" python3 -c 'import json,os; print(json.dumps({"SITE_AGENT_VERSION": os.environ["IMAGE_TAG"], "GATEWAYD_VERSION": os.environ["IMAGE_TAG"]}))')"
fi
if [ -n "$IMAGE_DIR" ]; then
  [ -n "$IMAGE_TAG" ] || die "IPC_E2E_IMAGE_TAG is required with IPC_E2E_IMAGE_DIR"
  site_archive="$IMAGE_DIR/site-agent-$IMAGE_TAG.tar.gz"
  gateway_archive="$IMAGE_DIR/gatewayd-$IMAGE_TAG.tar.gz"
  [ -s "$site_archive" ] || die "missing $site_archive"
  [ -s "$gateway_archive" ] || die "missing $gateway_archive"
  cp "$site_archive" "$gateway_archive" "$stage/images/"
  set_seed_values "$(python3 -c 'import json; print(json.dumps({"IPC_PRELOAD_IMAGE_DIR": "/opt/ipc-stack/.e2e-images", "SKIP_IMAGE_PULL": "1"}))')"
fi

console_hash="$(openssl passwd -6 "$(cat "$CONSOLE_PASSWORD_FILE")")"
operator_key="$(cat "$SSH_KEY.pub")"
USER_DATA="$stage/user-data" HOSTNAME="$HOSTNAME" CONSOLE_HASH="$console_hash" \
  USE_LOCAL_STACK="$USE_LOCAL_STACK" \
  OPERATOR_KEY="$operator_key" python3 - <<'PY'
import os
from pathlib import Path

path = Path(os.environ["USER_DATA"])
text = path.read_text()
text = text.replace("hostname: ipc-CHANGEME", f"hostname: {os.environ['HOSTNAME']}")
text = text.replace('password: "CHANGEME_SHA512_CRYPT"', f'password: "{os.environ["CONSOLE_HASH"]}"')
text = text.replace(
    '"ssh-ed25519 AAAA_CHANGEME_OPERATOR_KEY toops-ops"',
    f'"{os.environ["OPERATOR_KEY"]}"',
)
text = text.replace("  timezone: Etc/UTC\n", "  timezone: Etc/UTC\n  shutdown: poweroff\n")
clone = "    - curtin in-target -- git clone https://github.com/neddia/ipc-stack /opt/ipc-stack"
local_stack = """    - |
      dev=\"$(blkid -L CIDATA 2>/dev/null || true)\"
      [ -n \"$dev\" ] || exit 1
      mkdir -p /mnt/cidata /target/opt/ipc-stack
      mount -o ro \"$dev\" /mnt/cidata
      tar -xzf /mnt/cidata/ipc-stack.tar.gz -C /target/opt/ipc-stack
      if [ -d /mnt/cidata/images ]; then
        mkdir -p /target/opt/ipc-stack/.e2e-images
        cp /mnt/cidata/images/*.tar.gz /target/opt/ipc-stack/.e2e-images/
      fi
      umount /mnt/cidata
""".rstrip()
if os.environ["USE_LOCAL_STACK"] == "1":
    if clone not in text:
        raise SystemExit("expected ipc-stack clone command was not found")
    text = text.replace(clone, local_stack)
path.write_text(text)
PY

if [ "$USE_LOCAL_STACK" = "1" ]; then
  log "packing the exact local ipc-stack working tree"
  tar -C "$STACK_DIR" -czf "$stage/ipc-stack.tar.gz" \
    --exclude=.git --exclude=.env --exclude=.env.dev --exclude=.watch-sim-deps.pid \
    --exclude='*.pid' --exclude='__pycache__' --exclude='*.pyc' .
else
  # Keep the CIDATA layout stable; stock user-data ignores this empty archive.
  tar -czf "$stage/ipc-stack.tar.gz" --files-from /dev/null
fi

log "preparing ISO tools"
docker build -q -t "$ISO_TOOLS_IMAGE" -f "$STACK_DIR/provision/hyperv/iso-tools.Dockerfile" \
  "$STACK_DIR/provision/hyperv" >/dev/null

log "building CIDATA seed ISO"
docker run --rm \
  --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$stage:/src:ro" -v "$OUTPUT_DIR:/out" \
  "$ISO_TOOLS_IMAGE" sh -ec '
    xorriso -as mkisofs -quiet -volid CIDATA -joliet -rock -graft-points \
      -output /out/cidata.iso \
      user-data=/src/user-data \
      meta-data=/src/meta-data \
      seed.env=/src/seed.env \
      ipc-stack.tar.gz=/src/ipc-stack.tar.gz \
      images=/src/images
  '

log "extracting and updating Ubuntu GRUB configuration"
docker run --rm \
  --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$BASE_ISO:/work/base.iso:ro" -v "$stage:/work/stage" \
  "$ISO_TOOLS_IMAGE" sh -ec '
    xorriso -osirrox on -indev /work/base.iso \
      -extract /boot/grub/grub.cfg /work/stage/grub.cfg >/dev/null 2>&1
    chmod u+w /work/stage/grub.cfg
  '
GRUB_CFG="$stage/grub.cfg" python3 - <<'PY'
import os
from pathlib import Path

path = Path(os.environ["GRUB_CFG"])
lines = []
changed = 0
for line in path.read_text().splitlines():
    if "linux" in line and "/casper/vmlinuz" in line and "autoinstall" not in line:
        line = line.replace(" ---", " autoinstall ---")
        changed += 1
    lines.append(line)
if not changed:
    raise SystemExit("no Ubuntu installer kernel lines were updated")
path.write_text("\n".join(lines) + "\n")
PY

log "building unattended Ubuntu installer ISO"
docker run --rm \
  --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$BASE_ISO:/work/base.iso:ro" -v "$stage:/work/stage:ro" -v "$OUTPUT_DIR:/out" \
  "$ISO_TOOLS_IMAGE" sh -ec '
    rm -f /out/ubuntu-ipc-autoinstall.iso
    xorriso -indev /work/base.iso -outdev /out/ubuntu-ipc-autoinstall.iso \
      -boot_image any replay \
      -map /work/stage/grub.cfg /boot/grub/grub.cfg >/dev/null 2>&1
  '

chmod 0600 "$OUTPUT_DIR/cidata.iso"
log "media ready: $OUTPUT_DIR/ubuntu-ipc-autoinstall.iso"
log "media ready: $OUTPUT_DIR/cidata.iso"
log "operator SSH key: $SSH_KEY"
