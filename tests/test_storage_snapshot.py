"""Snapshot and restore real SQLite files and config in a temporary storage directory."""
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('storage_snapshot', Path(__file__).resolve().parents[1] / 'scripts/storage-snapshot.py')
snap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(snap)


class StorageSnapshotTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.storage = Path(temporary.name)
        (self.storage / 'site-config.yml').write_text('site: a\n')
        (self.storage / 'site-profiles').mkdir()
        (self.storage / 'site-profiles/p.yml').write_text('profile: a\n')
        (self.storage / 'ipc').mkdir()
        (self.storage / 'ipc/identity.json').write_text('{"ipc_id": "before"}')
        self.db = sqlite3.connect(self.storage / 'ledger.sqlite3')
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('CREATE TABLE t (v)')
        self.db.execute("INSERT INTO t VALUES ('before')")
        self.db.commit()
        self.addCleanup(self.db.close)

    def rows(self):
        with sqlite3.connect(self.storage / 'ledger.sqlite3') as db:
            return [r[0] for r in db.execute('SELECT v FROM t')]

    def test_restore_returns_config_profiles_and_database(self):
        # The live connection keeps writing while the snapshot is taken.
        target = snap.snapshot(self.storage, 'v1-to-v2', keep=2)
        self.db.execute("INSERT INTO t VALUES ('after')")
        self.db.execute('ALTER TABLE t ADD COLUMN migrated')
        self.db.commit()
        self.db.close()
        (self.storage / 'site-config.yml').write_text('site: migrated\n')
        (self.storage / 'site-profiles/p.yml').write_text('profile: migrated\n')
        snap.restore(self.storage, target)
        self.assertEqual(self.rows(), ['before'])
        self.assertEqual((self.storage / 'site-config.yml').read_text(), 'site: a\n')
        self.assertEqual((self.storage / 'site-profiles/p.yml').read_text(), 'profile: a\n')

    def test_device_identity_is_never_snapshotted_or_restored(self):
        target = snap.snapshot(self.storage, 'x', keep=2)
        self.assertFalse((target / 'ipc').exists())
        (self.storage / 'ipc/identity.json').write_text('{"ipc_id": "after"}')
        self.db.close()
        snap.restore(self.storage, target)
        self.assertEqual(json.loads((self.storage / 'ipc/identity.json').read_text())['ipc_id'], 'after')

    def test_keeps_only_the_newest_snapshots(self):
        for n in range(3):
            target = snap.snapshot(self.storage, f'u{n}', keep=2)
            # Distinct, ordered timestamps without sleeping between snapshots.
            target.rename(target.with_name(f'2000010{n}T000000Z-u{n}'))
        remaining = sorted(p.name for p in (self.storage / 'update-snapshots').iterdir())
        self.assertEqual(remaining, ['20000101T000000Z-u1', '20000102T000000Z-u2'])

    def test_refuses_snapshot_without_disk_headroom(self):
        original = snap.HEADROOM
        snap.HEADROOM = 1 << 62
        self.addCleanup(setattr, snap, 'HEADROOM', original)
        with self.assertRaises(SystemExit):
            snap.snapshot(self.storage, 'x', keep=2)
        self.assertFalse(any((self.storage / 'update-snapshots').iterdir()))

    def test_restore_rejects_path_escapes_in_manifest(self):
        target = snap.snapshot(self.storage, 'x', keep=2)
        (target / 'manifest.json').write_text(json.dumps({'databases': ['../../etc/passwd'], 'items': []}))
        with self.assertRaises(SystemExit):
            snap.restore(self.storage, target)

    def test_restored_ledger_reports_to_cloud_as_a_new_generation(self):
        # Rows synced after the snapshot would otherwise collide with reused sequence numbers.
        self.db.execute('CREATE TABLE sync_state (key TEXT PRIMARY KEY, value TEXT)')
        self.db.executemany('INSERT INTO sync_state VALUES (?, ?)', [
            ('ledger:generation', 'g1'), ('ledger:started_s', '1.0'),
            ('sync_cursor:comparison_statements', '7'), ('sync_projection:x', 'v2')])
        self.db.commit()
        target = snap.snapshot(self.storage, 'v1-to-v2', keep=2)
        self.db.close()
        snap.restore(self.storage, target)
        with sqlite3.connect(self.storage / 'ledger.sqlite3') as db:
            kept = dict(db.execute('SELECT key, value FROM sync_state'))
        self.assertEqual(kept, {'ledger:started_s': '1.0', 'sync_projection:x': 'v2'})


if __name__ == '__main__':
    unittest.main()
