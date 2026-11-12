import base64
from contextlib import closing
import json
from pathlib import Path
import runpy
import sqlite3
import tempfile
import unittest

sync = runpy.run_path(str(Path(__file__).with_name("index_sync.py")))
exec(Path(__file__).with_name("desktop_sync.py").read_text(), sync)


class DesktopHistoryTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.shared = self.root / "shared" / "sessions"
        self.shared.mkdir(parents=True)
        self.archive = self.shared.parent / "archived_sessions"
        self.archive.mkdir()
        self.a, self.b = (self.root / name for name in ("a", "b"))
        self.request = dict(homes=list(map(str, (self.a, self.b))), shared=str(self.shared), data=str(self.root))
        for home in (self.a, self.b):
            home.mkdir()
            (home / "sessions").symlink_to(self.shared)
            (home / "archived_sessions").symlink_to(self.archive)
            with closing(sqlite3.connect(home / "state_5.sqlite")) as db:
                db.executescript("""
                    PRAGMA journal_mode=WAL;
                    CREATE TABLE threads(id TEXT PRIMARY KEY,rollout_path TEXT,updated_at INTEGER,
                                         title TEXT,approval_mode TEXT,archived INTEGER DEFAULT 0);
                """)
            with closing(sqlite3.connect(home / sync["DESKTOP_HISTORY"])) as db:
                db.executescript("""
                    PRAGMA journal_mode=WAL;
                    CREATE TABLE thread_turns(thread_id,turn_id,rollout_ordinal,status,error_json,
                        started_at,completed_at,duration_ms,first_user_item_id,final_agent_item_id,
                        rollout_byte_offset,rollout_end_ordinal,rollout_end_byte_offset,PRIMARY KEY(thread_id,turn_id));
                    CREATE TABLE thread_items(thread_id,turn_id,item_id,rollout_ordinal,created_at_ms,item_json,
                        item_type,updated_at_ordinal,PRIMARY KEY(thread_id,turn_id,item_id));
                    CREATE TABLE thread_realtime_items(thread_id,item_id,rollout_ordinal,created_at_ms,
                        item_type,item_json,PRIMARY KEY(thread_id,item_id));
                    CREATE TABLE thread_history_projection_state(thread_id PRIMARY KEY,next_rollout_byte_offset,next_rollout_ordinal);
                """)

    def replicate(self):
        return sync["sync_desktops"](self.request)

    def index(self, home, tid="thread", path=None):
        if path is None:
            path = self.shared / ("rollout-test-" + tid + ".jsonl")
            path.write_text(json.dumps({"type": "session_meta", "payload": {"id": tid}}) + "\n")
        with closing(sqlite3.connect(home / "state_5.sqlite")) as db, db:
            db.execute("INSERT INTO threads VALUES(?,?,?,?,?,0)", (tid, str(path), 1, "test", home.name))
        return path

    def page(self, home, value, cursor, tid="thread"):
        with closing(sqlite3.connect(home / sync["DESKTOP_HISTORY"])) as db, db:
            db.execute("INSERT OR IGNORE INTO thread_turns(thread_id,turn_id,rollout_ordinal,status) VALUES(?,?,0,'inProgress')", (tid,"turn"))
            db.execute("INSERT INTO thread_items VALUES(?,?,?,1,0,?,'userMessage',1)", (tid,"turn",value,value))
            db.execute("INSERT OR REPLACE INTO thread_history_projection_state VALUES(?,?,?)", (tid, cursor*10,cursor))

    def items(self, home, tid="thread"):
        with closing(sqlite3.connect(home / sync["DESKTOP_HISTORY"])) as db:
            return [r[0] for r in db.execute("SELECT item_json FROM thread_items WHERE thread_id=? ORDER BY item_id", (tid,))]

    def test_live_reciprocal_updates_and_equal_count_gaps(self):
        self.index(self.a)
        self.page(self.a, "first", 10)
        with closing(sqlite3.connect(self.b / sync["DESKTOP_HISTORY"])) as reader:
            reader.execute("BEGIN")
            self.assertEqual(reader.execute("SELECT count(*) FROM thread_items").fetchone()[0], 0)
            report = self.replicate()
            self.assertEqual(report["conflicts"], 0)
            self.assertEqual(len(report["backups"]), 2)
            self.assertEqual(reader.execute("SELECT count(*) FROM thread_items").fetchone()[0], 0)
            reader.commit()
            self.assertEqual(self.items(self.b), ["first"])
        self.page(self.b, "second", 12)
        self.page(self.a, "third", 12)
        self.page(self.a, "private", 15, tid="unindexed")
        with closing(sqlite3.connect(self.b / "state_5.sqlite")) as db, db:
            db.execute("UPDATE threads SET approval_mode='target-local'")
        self.replicate()
        for home in (self.a, self.b):
            self.assertEqual(self.items(home), ["first","second","third"])
        self.assertEqual(self.items(self.b, "unindexed"), [])
        with closing(sqlite3.connect(self.a / sync["DESKTOP_HISTORY"])) as db, db:
            db.execute("UPDATE thread_items SET updated_at_ordinal=3,item_json='first edit' WHERE item_id='first'")
        self.replicate()
        self.assertEqual(self.items(self.b)[0], "first edit")
        with closing(sqlite3.connect(self.b / "state_5.sqlite")) as db:
            self.assertEqual(db.execute("SELECT approval_mode FROM threads").fetchone()[0], "target-local")
        self.assertEqual(self.replicate(), {"updated":0, "conflicts":0, "backups":[]})

    def test_refuses_divergent_file_and_unowned_pages(self):
        self.index(self.a)
        other = self.shared / "rollout-second-thread.jsonl"
        other.write_text('{"type":"session_meta","payload":{"id":"thread"}}\n')
        self.index(self.b, path=other)
        self.page(self.a, "source", 10)
        self.page(self.b, "divergent", 10)
        self.assertGreater(self.replicate()["conflicts"], 0)
        self.assertEqual(self.items(self.a), ["source"])
        self.assertEqual(self.items(self.b), ["divergent"])
        self.index(self.a, "orphan")
        self.page(self.b, "unknown origin", 1, "orphan")
        self.assertGreater(self.replicate()["conflicts"], 0)
        self.assertEqual(self.items(self.a, "orphan"), [])

    def test_linked_segments_use_their_verified_turns(self):
        current = "33333333-3333-4333-8333-333333333333"
        previous = "22222222-2222-4222-8222-222222222222"
        root = "11111111-1111-4111-8111-111111111111"
        def segment(sid, parent):
            p = self.shared / ("rollout-test-" + root + "_" + sid + ".jsonl")
            records = [{"type": "session_meta", "payload": {"id": root, "history_base": {"thread_id": parent}}},
                       {"type": "event_msg", "payload": {"type": "task_started", "turn_id": "turn"}}]
            p.write_text("".join(json.dumps(r) + "\n" for r in records))
            return p
        p = segment(current, previous)
        segment(previous, root)
        self.index(self.a, root, p)
        self.page(self.a, "latest", 2, current)
        self.page(self.a, "earlier", 5, previous)
        self.page(self.a, "unrelated", 5, "other")
        self.assertEqual(self.replicate()["conflicts"], 0)
        self.assertEqual(self.items(self.b, previous), ["earlier"])
        self.assertEqual(self.items(self.b, current), ["latest"])
        self.assertEqual(self.items(self.b, "other"), [])
        # Appending an unrelated index key to a filename cannot publish a
        # segment unless its first persisted turn matches that projection.
        p.write_text(p.read_text().replace('"turn"', '"different"'))
        self.page(self.a, "another", 10, current)
        self.assertGreater(self.replicate()["conflicts"], 0)
        self.assertEqual(self.items(self.b, current), ["latest"])

    def test_existing_thread_advances_to_explicit_continuation(self):
        root = "11111111-1111-4111-8111-111111111111"
        sid = "22222222-2222-4222-8222-222222222222"
        old = self.index(self.b, root)
        new = self.shared / ("rollout-test-" + root + "_" + sid + ".jsonl")
        new.write_text(json.dumps({"type":"session_meta","payload":{"id":root,"history_base":{"thread_id":root}}}) + "\n" +
                       json.dumps({"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}) + "\n")
        self.index(self.a, root, new)
        self.page(self.a, "new segment", 2, sid)
        self.page(self.b, "base", 5, root)
        self.assertEqual(self.replicate()["conflicts"], 0)
        self.assertEqual(self.items(self.b, sid), ["new segment"])
        for home in (self.a, self.b):
            with closing(sqlite3.connect(home / "state_5.sqlite")) as db:
                self.assertEqual(db.execute("SELECT rollout_path FROM threads").fetchone()[0], str(new))
        self.assertTrue(old.exists())
        self.assertEqual(self.replicate()["updated"], 0)

    def test_missing_timing_metadata_at_identical_cursor(self):
        for home in (self.a, self.b):
            self.index(home)
            self.page(home, "item", 10)
            with closing(sqlite3.connect(home / sync["DESKTOP_HISTORY"])) as db, db:
                db.execute("ALTER TABLE thread_items ADD COLUMN started_at_ms INTEGER")
                db.execute("ALTER TABLE thread_turns ADD COLUMN root_turn_id TEXT")
        with closing(sqlite3.connect(self.a / sync["DESKTOP_HISTORY"])) as db, db:
            db.execute("UPDATE thread_items SET started_at_ms=123")
        with closing(sqlite3.connect(self.b / sync["DESKTOP_HISTORY"])) as db, db:
            db.execute("UPDATE thread_turns SET root_turn_id='root'")
        self.replicate()
        for home in (self.a, self.b):
            with closing(sqlite3.connect(home / sync["DESKTOP_HISTORY"])) as db:
                self.assertEqual(db.execute("SELECT started_at_ms FROM thread_items").fetchone()[0], 123)
                self.assertEqual(db.execute("SELECT root_turn_id FROM thread_turns").fetchone()[0], "root")
        self.assertEqual(self.replicate()["updated"], 0)

    def test_checks_identity_and_private_locations(self):
        path = self.index(self.a)
        path.write_text('{"type":"session_meta","payload":{"id":"different"}}\n')
        with self.assertRaisesRegex(ValueError, "identity mismatch"):
            self.replicate()
        path.unlink()
        private = self.root / path.name
        private.write_text('{"type":"session_meta","payload":{"id":"thread"}}\n')
        path.symlink_to(private)
        self.assertEqual(self.replicate()["updated"], 0)
        path.unlink()
        path.write_text(private.read_text())
        self.index(self.b, path=self.root / "missing" / path.name)
        self.assertGreater(self.replicate()["conflicts"], 0)

    def test_compressed_resumed_rollout_with_stale_filename(self):
        path = self.archive / "rollout-test-thread_01234567-89ab-cdef-0123-456789abcdef.jsonl"
        # One zstd frame containing only this fixture's session_meta line.
        Path(str(path)+".zst").write_bytes(base64.b64decode("KLUv/QRYkQEAeyJ0eXBlIjoic2Vzc2lvbl9tZXRhIiwicGF5bG9hZCI6eyJpZCI6InRocmVhZCJ9fQoQYJQz"))
        self.index(self.a, path=path)
        self.page(self.a, "archived", 10)
        try:
            report = self.replicate()
        except ValueError as error:
            if "requires zstd" in str(error):
                self.skipTest(str(error))
            raise
        self.assertEqual(report["conflicts"], 0)
        self.assertEqual(self.items(self.b), ["archived"])
        with closing(sqlite3.connect(self.b / "state_5.sqlite")) as db:
            self.assertEqual(db.execute("SELECT rollout_path FROM threads").fetchone()[0], str(path)+".zst")


if __name__ == "__main__":
    unittest.main()
