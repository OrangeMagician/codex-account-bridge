import datetime as dt
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from token_reader import read_report


def usage(day, total, cached=0):
    return {"timestamp": day + "T12:00:00Z", "type": "event_msg", "payload": {
        "type": "token_count", "info": {
            "total_token_usage": {"input_tokens": total - 10, "cached_input_tokens": cached,
                                  "output_tokens": 10, "reasoning_output_tokens": 5, "total_tokens": total},
            "last_token_usage": {"input_tokens": total - 10, "cached_input_tokens": cached,
                                 "output_tokens": 10, "total_tokens": total}}}}


class TokenReaderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def home(self, name, rows):
        home = self.root / name
        (home / 'sessions').mkdir(parents=True)
        db = sqlite3.connect(home / 'state_5.sqlite')
        db.execute('create table threads(id text, rollout_path text, tokens_used integer, updated_at integer)')
        for thread_id, events in rows:
            path = home / 'sessions' / ('rollout-' + thread_id + '.jsonl')
            records = [{"type": "session_meta", "payload": {"id": thread_id}}] + events
            path.write_text(''.join(json.dumps(e) + '\n' for e in records))
            # Deliberately wrong cumulative/index date, as happens on import.
            db.execute('insert into threads values(?,?,99999999,9999999999)', (thread_id, str(path)))
        db.commit()
        db.close()
        return home / 'state_5.sqlite'

    def test_actual_days_cached_subset_and_shared_copies(self):
        events = [usage('2026-08-01', 100, 60), usage('2026-08-01', 100, 60), usage('2026-08-02', 150, 90)]
        first = self.home('one', [('same', events)])
        second = self.home('two', [('same', events), ('fork', events + [usage('2026-08-03', 180, 100)])])
        report = read_report([str(first), str(second)])
        self.assertEqual(report['total_tokens'], 180)
        self.assertEqual(report['input_tokens'], 170)
        self.assertEqual(report['cached_input_tokens'], 100)
        self.assertEqual(report['output_tokens'], 10)  # reasoning isn't added twice
        self.assertEqual([d['tokens'] for d in report['daily']], [100, 50, 30])
        self.assertEqual(report['max_daily_tokens'], 100)
        self.assertEqual(report['active_days'], 3)
        self.assertEqual(report['unavailable_threads'], 0)

    def test_reset_partial_append_and_missing_history(self):
        reset = usage('2026-08-02', 50)
        reset['payload']['info']['last_token_usage'] = {"input_tokens": 15, "output_tokens": 5, "total_tokens": 20}
        db = self.home('one', [('reset', [usage('2026-08-01', 100), reset]), ('empty', [])])
        with (db.parent / 'sessions/rollout-reset.jsonl').open('ab') as f:
            f.write(b'{"type":"event_msg","payload":{"type":"token_count"')
        report = read_report([str(db)])
        self.assertEqual(report['total_tokens'], 120)
        self.assertEqual(report['unavailable_threads'], 1)
        self.assertEqual(report['incomplete_files'], 1)

    def test_imported_lifetime_baseline_is_not_charged_to_first_day(self):
        initial = usage('2026-08-01', 1_000_000)
        initial['payload']['info']['last_token_usage'] = {"input_tokens": 15, "output_tokens": 5, "total_tokens": 20}
        db = self.home('one', [('partial', [initial, usage('2026-08-02', 1_000_050)])])
        report = read_report([str(db)])
        self.assertEqual(report['total_tokens'], 70)
        self.assertEqual([d['tokens'] for d in report['daily']], [20, 50])
        self.assertEqual(report['incomplete_files'], 1)

    def test_reject_arbitrary_paths_symlinks_and_wrong_identity(self):
        db = self.home('one', [('bad', [usage('2026-08-01', 100)])])
        path = db.parent / 'sessions/rollout-bad.jsonl'
        path.rename(self.root / 'outside.jsonl')
        path.symlink_to(self.root / 'outside.jsonl')
        self.assertEqual(read_report([str(db)])['total_tokens'], 0)
        with sqlite3.connect(db) as conn:
            conn.execute('update threads set rollout_path=?', (str(db.parent / 'auth.json'),))
        # A directory makes accidental opening fail; it is never a data source.
        (db.parent / 'auth.json').mkdir()
        self.assertEqual(read_report([str(db)])['unavailable_threads'], 1)

    def test_yesterday_streak_and_utc_day(self):
        yesterday = (dt.datetime.now(dt.timezone.utc).date() - dt.timedelta(days=1)).isoformat()
        event = usage(yesterday, 100)
        db = self.home('one', [('day', [event])])
        self.assertEqual(read_report([str(db)])['current_streak'], 1)
        event['timestamp'] = '2026-08-02T01:00:00+08:00'
        other = self.home('two', [('tz', [event])])
        self.assertEqual(read_report([str(other)])['daily'][0]['date'], '2026-08-01')

    def test_corrupt_index_is_an_error_not_zero(self):
        db = self.root / 'state_5.sqlite'
        db.write_bytes(b'invalid sqlite')
        with self.assertRaises(sqlite3.Error):
            read_report([str(db)])
