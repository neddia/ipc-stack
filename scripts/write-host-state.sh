#!/usr/bin/env bash
set -euo pipefail

STORAGE_DIR="${IPC_STORAGE_DIR:-/opt/site-agent/storage}"
OUT_DIR="$STORAGE_DIR/ipc"
OUT_FILE="$OUT_DIR/host-status.json"

mkdir -p "$OUT_DIR"

python3 - "$STORAGE_DIR" "$OUT_FILE" <<'PY'
import json
import os
import shutil
import sys
from datetime import datetime, timezone

storage_dir = sys.argv[1]
out_file = sys.argv[2]


def usage(path: str, fs_id: str) -> dict:
    total, used, free = shutil.disk_usage(path)
    used_pct = (used / total * 100.0) if total > 0 else 0.0
    free_pct = (free / total * 100.0) if total > 0 else 0.0
    return {
        "id": fs_id,
        "path": path,
        "total_bytes": int(total),
        "used_bytes": int(used),
        "avail_bytes": int(free),
        "used_pct": round(used_pct, 2),
        "free_pct": round(free_pct, 2),
    }


payload = {
    "collected_at": datetime.now(timezone.utc).isoformat(),
    "reboot_required": os.path.exists("/var/run/reboot-required") or os.path.exists("/run/reboot-required"),
    "reboot_required_since": None,
    "filesystems": [],
}

for path, fs_id in [("/", "root"), (storage_dir, "storage")]:
    try:
        payload["filesystems"].append(usage(path, fs_id))
    except Exception:
        pass

stamp_candidates = ["/var/run/reboot-required.pkgs", "/run/reboot-required.pkgs"]
for candidate in stamp_candidates:
    if os.path.exists(candidate):
        try:
            st = os.stat(candidate)
            payload["reboot_required_since"] = datetime.fromtimestamp(st.st_mtime, tz=timezone.utc).isoformat()
            break
        except Exception:
            pass

tmp_file = out_file + ".tmp"
with open(tmp_file, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
    fh.write("\n")
os.replace(tmp_file, out_file)
PY
