#!/usr/bin/env bash
# Build an unattended Ubuntu installer for a disposable e2e helper VM (test
# Cloud). Reuses the IPC builder's ISO tooling; development only.
#   e2e/build-vm-media.sh <hostname>
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRIVATE_DIR="${IPC_E2E_PRIVATE_DIR:-$HOME/.config/toops-e2e}"
CACHE_DIR="${IPC_E2E_CACHE_DIR:-$HOME/.cache/toops-e2e}"
BASE_ISO="${UBUNTU_ISO:-$CACHE_DIR/ubuntu-24.04.4-live-server-amd64.iso}"
HOST="${1:?hostname required}"
OUT="$CACHE_DIR/media/$HOST"
ISO_TOOLS_IMAGE="toops/ipc-e2e-iso-tools:bookworm"
PASSWORD_FILE="$PRIVATE_DIR/console-passwords/$HOST"

mkdir -p "$OUT" "$(dirname "$PASSWORD_FILE")"
chmod 0700 "$OUT" "$(dirname "$PASSWORD_FILE")"
[ -s "$PASSWORD_FILE" ] || (umask 077 && openssl rand -base64 24 >"$PASSWORD_FILE")
stage="$(mktemp -d "$CACHE_DIR/media-stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

HASH="$(openssl passwd -6 "$(cat "$PASSWORD_FILE")")" KEY="$(cat "$PRIVATE_DIR/id_ed25519.pub")" \
  HOST="$HOST" SRC="$STACK_DIR/e2e/cloud-vm/user-data" DST="$stage/user-data" python3 - <<'PY'
import os
text = open(os.environ["SRC"]).read()
text = text.replace("HOSTNAME_CHANGEME", os.environ["HOST"])
text = text.replace("CHANGEME_SHA512_CRYPT", os.environ["HASH"])
text = text.replace("OPERATOR_KEY_CHANGEME", os.environ["KEY"].strip())
open(os.environ["DST"], "w").write(text)
PY
: >"$stage/meta-data"

docker build -q -t "$ISO_TOOLS_IMAGE" -f "$STACK_DIR/provision/hyperv/iso-tools.Dockerfile" \
  "$STACK_DIR/provision/hyperv" >/dev/null
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$BASE_ISO:/work/base.iso:ro" -v "$stage:/work/stage" "$ISO_TOOLS_IMAGE" sh -ec '
    xorriso -osirrox on -indev /work/base.iso -extract /boot/grub/grub.cfg /work/stage/grub.cfg >/dev/null 2>&1
    chmod u+w /work/stage/grub.cfg'
sed -i -E '/\/casper\/vmlinuz/ s# ---# autoinstall ds=nocloud\\;s=/cdrom/nocloud/ ---#' "$stage/grub.cfg"
# GRUB needs the escaped semicolon, or it ends the kernel line at "ds=nocloud".
grep -qF 'ds=nocloud\;s=' "$stage/grub.cfg"
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$BASE_ISO:/work/base.iso:ro" -v "$stage:/work/stage:ro" -v "$OUT:/out" "$ISO_TOOLS_IMAGE" sh -ec '
    rm -f /out/installer.iso
    xorriso -indev /work/base.iso -outdev /out/installer.iso -boot_image any replay \
      -map /work/stage/grub.cfg /boot/grub/grub.cfg \
      -map /work/stage/user-data /nocloud/user-data \
      -map /work/stage/meta-data /nocloud/meta-data >/dev/null 2>&1'
chmod 0600 "$OUT/installer.iso"
echo "$OUT/installer.iso"
