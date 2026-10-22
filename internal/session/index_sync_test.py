import importlib.util
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("index_sync", Path(__file__).with_name("index_sync.py"))
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


class IndexRepairTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.shared = self.root / "shared" / "sessions"
        self.shared.mkdir(parents=True)
        self.homes = [self.root / "one", self.root / "two"]
        self.old = self.rollout("old", "2026-09-04T07:00:00Z")
        self.new = self.rollout("new", "2026-09-19T14:43:39Z")
        self.request = {"shared": str(self.shared), "data": str(self.root), "homes": [str(p) for p in self.homes]}
        for index, home in enumerate(self.homes):
            home.mkdir()
            (home / "sessions").symlink_to(self.shared)
            with sqlite3.connect(home / "state_5.sqlite") as db:
                db.executescript("""
                    PRAGMA journal_mode=WAL;
                    CREATE TABLE threads (
                        id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL,
                        updated_at INTEGER NOT NULL, updated_at_ms INTEGER,
                        name TEXT, sandbox_policy TEXT NOT NULL,
                        approval_mode TEXT NOT NULL, archived INTEGER DEFAULT 0
                    );
                    CREATE TABLE unrelated (value TEXT);
                    INSERT INTO unrelated VALUES ('keep me');
                """)
                db.execute("INSERT INTO threads VALUES (?,?,?,?,?,?,?,?)",
                           ("thread-id", str(self.new if index == 0 else self.old),
                            9999999999 if index == 1 else 1, None,
                            "My task" if index else None, "policy-" + str(index), "approval-" + str(index), index))

    def rollout(self, label, date, thread_id="thread-id"):
        path = self.shared / ("rollout-" + label + "-" + thread_id + ".jsonl")
        records = [
            {"timestamp": "2026-08-30T08:34:11Z", "type": "session_meta", "payload": {"id": thread_id}},
            {"timestamp": date, "type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "preserve this"}]}},
        ]
        path.write_text("".join(json.dumps(r) + "\n" for r in records))
        return path

    def row(self, home):
        with sqlite3.connect(home / "state_5.sqlite") as db:
            db.row_factory = sqlite3.Row
            return dict(db.execute("SELECT * FROM threads").fetchone())

    def test_newest_persisted_history_wins_without_replacing_policies(self):
        originals = [p.read_bytes() for p in (self.old, self.new)]
        report = sync.repair(self.request)
        self.assertEqual(report["updated"], 2)
        self.assertEqual(len(report["backups"]), 2)
        for index, home in enumerate(self.homes):
            row = self.row(home)
            self.assertEqual(row["rollout_path"], str(self.new))
            self.assertEqual(row["name"], "My task")
            self.assertEqual(row["sandbox_policy"], "policy-" + str(index))
            self.assertEqual(row["approval_mode"], "approval-" + str(index))
            self.assertEqual(row["archived"], index)
            with sqlite3.connect(home / "state_5.sqlite") as db:
                self.assertEqual(db.execute("SELECT value FROM unrelated").fetchone()[0], "keep me")
        self.assertEqual(self.row(self.homes[1])["updated_at"], 9999999999)
        self.assertEqual([p.read_bytes() for p in (self.old, self.new)], originals)
        self.assertEqual(sync.repair(self.request), {"updated": 0, "backups": []})

    def test_variable_timestamp_precision_on_older_system_python(self):
        base = "2026-09-20T00:00:00"
        whole = sync.timestamp(base + "Z")
        for digits in ("1", "12", "123", "1234", "12345", "123456", "123456789"):
            self.assertEqual(sync.timestamp(base + "." + digits + "Z"), whole + int((digits + "000")[:3]))

    def add_metadata(self):
        for home in self.homes:
            with sqlite3.connect(home / "state_5.sqlite") as db:
                for definition in ("title TEXT", "cwd TEXT", "is_pinned INTEGER DEFAULT 0", "project_id TEXT", "thread_section_id TEXT", "section_position INTEGER", "section_entered_at_ms INTEGER"):
                    db.execute("ALTER TABLE threads ADD COLUMN " + definition)
                db.execute("UPDATE threads SET cwd='/home/ubuntu/project', title='/home/ubuntu/project'")

    def test_projectless_pinned_thread_missing_in_other_account_is_imported(self):
        self.add_metadata()
        with sqlite3.connect(self.homes[0] / "state_5.sqlite") as db:
            db.execute("UPDATE threads SET name='Keep this task', title='Useful title', is_pinned=1")
        with sqlite3.connect(self.homes[1] / "state_5.sqlite") as db:
            db.execute("DELETE FROM threads")
        report = sync.repair(self.request)
        row = self.row(self.homes[1])
        self.assertEqual(row["name"], "Keep this task")
        self.assertEqual(row["title"], "Useful title")
        self.assertEqual(row["is_pinned"], 1)
        self.assertIsNone(row["project_id"])
        self.assertEqual(row["rollout_path"], str(self.new))
        self.assertTrue(report["backups"])
        self.assertEqual(sync.repair(self.request)["updated"], 0)

    def test_path_titles_and_existing_pins_are_repaired_without_policy_changes(self):
        self.add_metadata()
        with sqlite3.connect(self.homes[0] / "state_5.sqlite") as db:
            db.execute("UPDATE threads SET name='Restored name', title='Restored title', is_pinned=1")
        with sqlite3.connect(self.homes[1] / "state_5.sqlite") as db:
            db.execute("UPDATE threads SET name='/home/ubuntu/project/'")
        sync.repair(self.request)
        row = self.row(self.homes[1])
        self.assertEqual((row["name"], row["title"], row["is_pinned"]), ("Restored name", "Restored title", 1))
        self.assertEqual(row["sandbox_policy"], "policy-1")
        self.assertEqual(row["approval_mode"], "approval-1")
        self.assertEqual(row["archived"], 1)

    def test_outgoing_account_preserves_explicit_unpin_and_projectless_membership(self):
        self.add_metadata()
        self.request["source_home"] = str(self.homes[0])
        with sqlite3.connect(self.homes[1] / "state_5.sqlite") as db:
            db.execute("UPDATE threads SET is_pinned=1, project_id='stale-project'")
        sync.repair(self.request)
        self.assertEqual(self.row(self.homes[1])["is_pinned"], 0)
        self.assertIsNone(self.row(self.homes[1])["project_id"])
        # After switching back the explicit edit must remain stable.
        self.request["source_home"] = str(self.homes[1])
        self.assertEqual(sync.repair(self.request)["updated"], 0)

    def test_saved_session_name_recovers_when_all_account_names_are_paths(self):
        self.add_metadata()
        for home in self.homes:
            with sqlite3.connect(home / "state_5.sqlite") as db:
                db.execute("UPDATE threads SET name=cwd")
        (self.homes[0] / "session_index.jsonl").write_text(json.dumps({"id": "thread-id", "thread_name": "Original saved name", "updated_at": "2026-09-20T00:00:00.729974891Z"}) + "\n")
        sync.repair(self.request)
        for home in self.homes:
            self.assertEqual(self.row(home)["name"], "Original saved name")
        self.assertEqual(sync.repair(self.request)["updated"], 0)

    def test_missing_thread_without_shared_rollout_is_not_imported(self):
        with sqlite3.connect(self.homes[0] / "state_5.sqlite") as db:
            db.execute("INSERT INTO threads VALUES (?,?,?,?,?,?,?,?)", ("not-shared", "/outside", 1, None, "Private", "policy", "approval", 0))
        sync.repair(self.request)
        with sqlite3.connect(self.homes[1] / "state_5.sqlite") as db:
            self.assertEqual(db.execute("SELECT count(*) FROM threads WHERE id='not-shared'").fetchone()[0], 0)

    def test_online_backup_includes_live_wal_and_can_restore_prior_pointer(self):
        dbpath = self.homes[1] / "state_5.sqlite"
        writer = sqlite3.connect(dbpath)
        self.addCleanup(writer.close)
        writer.execute("PRAGMA wal_autocheckpoint=0")
        writer.execute("INSERT INTO unrelated VALUES ('live WAL')")
        writer.commit()
        report = sync.repair(self.request)
        backup = next(p for p in report["backups"] if Path(p).name == "two-state_5.sqlite")
        with sqlite3.connect(backup) as db:
            self.assertEqual(db.execute("SELECT rollout_path FROM threads").fetchone()[0], str(self.old))
            self.assertEqual(db.execute("SELECT count(*) FROM unrelated").fetchone()[0], 2)

    def test_partial_final_append_does_not_discard_complete_events(self):
        with self.new.open("a") as f:
            f.write('{"timestamp":"2026-09-20T00:00:00Z"')
        self.assertEqual(sync.rollout_info(self.new)[1], sync.timestamp("2026-09-19T14:43:39Z"))
        sync.repair(self.request)
        self.assertEqual(self.row(self.homes[1])["rollout_path"], str(self.new))

    def test_new_append_on_previous_branch_is_selected_on_next_launch(self):
        sync.repair(self.request)
        with self.old.open("a") as f:
            f.write(json.dumps({"timestamp": "2026-09-20T00:00:00Z", "type": "event_msg", "payload": {"type": "task_complete"}}) + "\n")
        sync.repair(self.request)
        for home in self.homes:
            self.assertEqual(self.row(home)["rollout_path"], str(self.old))

    def test_unindexed_rollout_variant_is_considered_for_existing_thread(self):
        newest = self.rollout("not-in-either-database", "2026-09-20T00:00:00Z")
        sync.repair(self.request)
        self.assertEqual(self.row(self.homes[0])["rollout_path"], str(newest))

    def test_symlink_rollout_is_rejected(self):
        self.new.unlink()
        self.new.symlink_to(self.old)
        with self.assertRaises(OSError):
            sync.repair(self.request)
        self.assertEqual(self.row(self.homes[1])["rollout_path"], str(self.old))

    def test_outside_pointer_is_not_read_or_replaced(self):
        with sqlite3.connect(self.homes[1] / "state_5.sqlite") as db:
            db.execute("UPDATE threads SET rollout_path=?", (str(self.root / "outside.jsonl"),))
        with self.assertRaisesRegex(ValueError, "outside shared history"):
            sync.repair(self.request)

    def test_non_rollout_files_are_never_opened(self):
        with self.assertRaisesRegex(ValueError, "non-rollout"):
            sync.rollout_info(self.shared / "auth.json")

    def test_symlink_database_rejected(self):
        path = self.homes[1] / "state_5.sqlite"
        path.unlink()
        path.symlink_to(self.homes[0] / "state_5.sqlite")
        with self.assertRaisesRegex(ValueError, "not a regular file"):
            sync.repair(self.request)

    def test_incompatible_schema_fails_before_writing(self):
        with sqlite3.connect(self.homes[1] / "state_5.sqlite") as db:
            db.execute("ALTER TABLE threads RENAME TO old_threads")
        with self.assertRaisesRegex(ValueError, "unsupported"):
            sync.repair(self.request)
        self.assertIsNone(self.row(self.homes[0])["name"])

    def test_non_shared_home_is_rejected(self):
        p = self.homes[1] / "sessions"
        p.unlink()
        p.mkdir()
        with self.assertRaisesRegex(ValueError, "does not use"):
            sync.repair(self.request)


if __name__ == "__main__":
    unittest.main()
