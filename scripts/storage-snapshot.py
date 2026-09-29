#!/usr/bin/env python3
"""Snapshot site state before an image switch; restore it if the update rolls back.

Covers what a release may migrate: SQLite databases in the storage root (copied
with SQLite's online backup, so the copy is consistent while site-agent keeps
writing), site config, time zone, site profiles and alert policy. It never
touches storage/ipc: device identity, license and enrollment must not roll back.

  storage-snapshot.py snapshot --storage DIR --label FROM-to-TO   # prints the snapshot path
  storage-snapshot.py restore  --storage DIR --snapshot PATH      # site-agent must be stopped
"""
import argparse
import json
import os
import re
import shutil
import sqlite3
import sys
import time
from pathlib import Path

SNAPSHOTS = 'update-snapshots'
FILES = ('site-config.yml', 'site-timezone.json')
DIRS = ('site-profiles', 'alerts')
DB_SUFFIXES = ('.sqlite3', '.db')
SIDECARS = ('-wal', '-shm', '-journal')
HEADROOM = 512 * 1024 * 1024


def databases(storage):
    return sorted(p for p in storage.iterdir() if p.is_file() and p.suffix in DB_SUFFIXES)


def tree_size(path):
    if path.is_file():
        return path.stat().st_size
    return sum(p.stat().st_size for p in path.rglob('*') if p.is_file())


def match_owner(path, reference):
    if os.geteuid() == 0:
        info = reference.stat()
        os.chown(path, info.st_uid, info.st_gid)


def backup_database(source, target):
    before = {s for s in SIDECARS if Path(str(source) + s).exists()}
    src = sqlite3.connect(source)
    dst = sqlite3.connect(target)
    try:
        src.backup(dst)
    finally:
        dst.close()
        src.close()
    # Opening the source as root may create WAL/SHM files site-agent then cannot open.
    for sidecar in SIDECARS:
        path = Path(str(source) + sidecar)
        if sidecar not in before and path.exists():
            match_owner(path, source)


def snapshot(storage, label, keep):
    root = storage / SNAPSHOTS
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    dbs = databases(storage)
    items = [storage / n for n in FILES + DIRS if (storage / n).exists()]
    need = sum(tree_size(p) for p in dbs + items)
    free = shutil.disk_usage(storage).free
    if free < need + HEADROOM:
        raise SystemExit(f'not enough free disk for a pre-update snapshot: need {need + HEADROOM} bytes, have {free}')
    name = time.strftime('%Y%m%dT%H%M%SZ', time.gmtime()) + '-' + (re.sub(r'[^A-Za-z0-9._-]+', '_', label)[:80] or 'update')
    partial = root / (name + '.partial')
    shutil.rmtree(partial, ignore_errors=True)
    partial.mkdir()
    for db in dbs:
        backup_database(db, partial / db.name)
    for path in items:
        if path.is_dir():
            shutil.copytree(path, partial / path.name, symlinks=True)
        else:
            shutil.copy2(path, partial / path.name)
    manifest = {'created_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'label': label,
                'databases': [p.name for p in dbs], 'items': [p.name for p in items]}
    (partial / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    target = root / name
    partial.rename(target)
    finished = sorted(p for p in root.iterdir() if p.is_dir() and not p.name.endswith('.partial'))
    for old in finished[:-keep]:
        shutil.rmtree(old)
    return target


def restore(storage, snap):
    manifest = json.loads((snap / 'manifest.json').read_text())
    for name in manifest['databases'] + manifest['items']:
        if '/' in name or name.startswith('.') or name == SNAPSHOTS:
            raise SystemExit(f'refusing unexpected snapshot entry: {name}')
    for name in manifest['databases']:
        live = storage / name
        owner = live if live.exists() else storage
        # A leftover WAL would be replayed onto the restored copy.
        for sidecar in SIDECARS:
            Path(str(live) + sidecar).unlink(missing_ok=True)
        staged = storage / (name + '.restoring')
        shutil.copy2(snap / name, staged)
        match_owner(staged, owner)
        os.replace(staged, live)
    for name in manifest['items']:
        live, saved = storage / name, snap / name
        owner = live if live.exists() else storage
        if saved.is_dir():
            staged = storage / (name + '.restoring')
            shutil.rmtree(staged, ignore_errors=True)
            shutil.copytree(saved, staged, symlinks=True)
            if live.exists():
                shutil.rmtree(live)
            os.replace(staged, live)
            for path in [live, *live.rglob('*')]:
                if not path.is_symlink():
                    match_owner(path, owner)
        else:
            staged = storage / (name + '.restoring')
            shutil.copy2(saved, staged)
            match_owner(staged, owner)
            os.replace(staged, live)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=('snapshot', 'restore'))
    parser.add_argument('--storage', required=True)
    parser.add_argument('--label', default='update')
    parser.add_argument('--snapshot')
    parser.add_argument('--keep', type=int, default=2)
    args = parser.parse_args()
    storage = Path(args.storage).resolve()
    if args.action == 'snapshot':
        print(snapshot(storage, args.label, max(1, args.keep)))
        return
    if not args.snapshot:
        raise SystemExit('--snapshot is required for restore')
    snap = Path(args.snapshot).resolve()
    if snap.parent != storage / SNAPSHOTS:
        raise SystemExit('snapshot must be inside this storage directory')
    restore(storage, snap)


if __name__ == '__main__':
    try:
        main()
    except (OSError, sqlite3.Error, ValueError, KeyError) as exc:
        print(f'storage-snapshot: {type(exc).__name__}: {exc}', file=sys.stderr)
        sys.exit(1)
