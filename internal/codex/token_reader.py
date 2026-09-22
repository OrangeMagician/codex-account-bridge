"""Read persisted usage events only; never emit conversation content.

The index's tokens_used is cumulative and updated_at can change on import or
pinning. Neither is a daily usage record. Dates below are explicitly UTC.
"""
import datetime as dt
import hashlib
from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import stat
import sys

UTC = dt.timezone.utc
FIELDS = ("input_tokens", "cached_input_tokens", "output_tokens", "total_tokens")
MAX_LINE = 8 * 1024 * 1024


def counters(value):
    if not isinstance(value, dict):
        return None
    result = tuple(value.get(key, 0) for key in FIELDS)
    if any(type(n) is not int or n < 0 for n in result):
        return None
    if "total_tokens" not in value:
        result = (*result[:3], result[0] + result[2])
    return result


def regular(path):
    if not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError("not a regular usage source")


class EventCache:
    """CAB-owned cache of counters only, never message text or credentials."""
    def __init__(self, path):
        self.db = None
        self.scanned_bytes = 0
        if not path:
            return
        try:
            path = Path(path)
            if path.name != "token-cache-v1.sqlite":
                return
            for parent in (path.parent, *path.parents):
                if parent.is_symlink():
                    return
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            if path.parent.stat().st_mode & 0o077:
                return
            for candidate in (path, Path(str(path) + "-wal"), Path(str(path) + "-shm")):
                if candidate.exists() or candidate.is_symlink():
                    regular(candidate)
            fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
            os.close(fd)
            self.db = sqlite3.connect(path, timeout=1)
            self.db.execute("CREATE TABLE IF NOT EXISTS events (path TEXT PRIMARY KEY, state TEXT NOT NULL)")
        except (OSError, ValueError, sqlite3.Error):
            self.close()

    def close(self):
        if self.db is not None:
            self.db.close()
            self.db = None

    def get(self, path):
        if self.db is None:
            return None
        try:
            row = self.db.execute("SELECT state FROM events WHERE path=?", (str(path),)).fetchone()
            state = json.loads(row[0]) if row else None
            if not isinstance(state, dict) or not isinstance(state.get("events"), list):
                return None
            for event in state["events"]:
                if not isinstance(event, list) or len(event) != 3 or not isinstance(event[0], str):
                    return None
                for values in event[1:]:
                    if values is not None and (not isinstance(values, (list, tuple)) or len(values) != 4 or any(type(n) is not int or n < 0 for n in values)):
                        return None
                if event[1] is None:
                    return None
            return state
        except (sqlite3.Error, ValueError):
            return None

    def put(self, path, state):
        if self.db is not None:
            try:
                with self.db:
                    self.db.execute("INSERT OR REPLACE INTO events VALUES (?,?)", (str(path), json.dumps(state, separators=(",", ":"))))
            except sqlite3.Error:
                pass  # An optional cache must never make statistics unavailable.

    def prune(self, paths):
        if self.db is not None:
            try:
                with self.db:
                    for (path,) in self.db.execute("SELECT path FROM events").fetchall():
                        if path not in paths:
                            self.db.execute("DELETE FROM events WHERE path=?", (path,))
            except sqlite3.Error:
                pass


def boundary(stream, offset):
    """Validate the prefix and append boundary before trusting saved offsets."""
    digest = hashlib.sha256()
    stream.seek(0)
    digest.update(stream.read(min(offset, 4096)))
    stream.seek(max(0, offset - 4096))
    digest.update(stream.read(min(offset, 4096)))
    return digest.hexdigest()


def usage_events(stream, thread_id, path, cache):
    info = os.fstat(stream.fileno())
    old = cache.get(path)
    offset, events, damaged = 0, [], False
    if isinstance(old, dict) and old.get("version") == 1 and old.get("thread") == thread_id:
        same_file = old.get("device") == info.st_dev and old.get("inode") == info.st_ino
        unchanged = old.get("size") == info.st_size and old.get("modified") == info.st_mtime_ns and old.get("changed") == info.st_ctime_ns
        appended = info.st_size > old.get("size", info.st_size)
        saved_offset = old.get("offset", -1)
        if same_file and (unchanged or appended) and 0 <= saved_offset <= info.st_size and boundary(stream, saved_offset) == old.get("boundary"):
            offset, events, damaged = saved_offset, old["events"], old["damaged"]
    stream.seek(offset)
    if offset == 0:
        line = stream.readline(MAX_LINE)
        cache.scanned_bytes += len(line)
        meta = json.loads(line)
        if meta.get("type") != "session_meta" or meta.get("payload", {}).get("id") != thread_id:
            raise ValueError("wrong session identity")
        offset = stream.tell()
    remaining = info.st_size - offset
    partial = False
    while remaining > 0:
        line = stream.readline(min(MAX_LINE, remaining))
        cache.scanned_bytes += len(line)
        remaining -= len(line)
        if not line:
            break
        if not line.endswith(b"\n"):
            if len(line) < MAX_LINE:
                partial = True
                break  # Re-read the unfinished event on the next refresh.
            while remaining > 0 and line and not line.endswith(b"\n"):
                line = stream.readline(min(MAX_LINE, remaining))
                cache.scanned_bytes += len(line)
                remaining -= len(line)
            damaged = True
            offset = stream.tell()
            continue
        offset = stream.tell()
        if b'"token_count"' not in line or b'"event_msg"' not in line:
            continue
        try:
            event = json.loads(line)
            payload = event.get("payload", {})
            if event.get("type") != "event_msg" or payload.get("type") != "token_count":
                continue
            details = payload.get("info")
            if not isinstance(details, dict):
                continue
            current = counters(details.get("total_token_usage"))
            if current is None:
                damaged = True
                continue
            timestamp = dt.datetime.fromisoformat(event["timestamp"].replace("Z", "+00:00"))
            if timestamp.tzinfo is None:
                raise ValueError("missing timezone")
            # Store only normalized time and numerical counters.
            events.append([timestamp.astimezone(UTC).isoformat(), current, counters(details.get("last_token_usage"))])
        except (ValueError, TypeError, KeyError, AttributeError):
            damaged = True
    cache.put(path, {"version": 1, "thread": thread_id, "device": info.st_dev, "inode": info.st_ino,
                     "size": info.st_size, "modified": info.st_mtime_ns, "changed": info.st_ctime_ns,
                     "offset": offset, "boundary": boundary(stream, offset), "events": events, "damaged": damaged})
    return events, damaged or partial


def read_report(paths, cache_path=None):
    cache = EventCache(cache_path)
    try:
        return _read_report(paths, cache)
    finally:
        cache.close()


def _read_report(paths, cache):
    threads = {}
    roots = set()
    for path in map(Path, paths):
        roots.update((path.parent / name).resolve() for name in ("sessions", "archived_sessions"))
        regular(path)
        for suffix in ("-wal", "-shm"):
            sidecar = Path(str(path) + suffix)
            if sidecar.exists() or sidecar.is_symlink():
                regular(sidecar)
        db = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=2)
        try:
            columns = {row[1] for row in db.execute("PRAGMA table_info(threads)")}
            if "id" not in columns:
                raise ValueError("unsupported thread index")
            query = "SELECT id, " + ("rollout_path" if "rollout_path" in columns else "NULL") + " FROM threads"
            for thread_id, rollout in db.execute(query):
                threads.setdefault(str(thread_id), set())
                if rollout:
                    threads[str(thread_id)].add(Path(rollout))
        finally:
            db.close()

    daily = {}
    totals = [0] * 4
    seen = set()
    read_paths = set()
    covered = set()
    incomplete = 0
    for thread_id, candidates in sorted(threads.items()):
        for path in sorted(candidates):
            # Never follow arbitrary index pointers, including auth.json.
            if not path.name.startswith("rollout-") or path.suffix != ".jsonl":
                continue
            resolved = path.resolve()
            if not any(root in resolved.parents for root in roots):
                continue
            if resolved in read_paths:
                continue
            previous = (0, 0, 0, 0)
            damaged = False
            try:
                fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                with os.fdopen(fd, "rb") as stream:
                    if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                        continue
                    events, damaged = usage_events(stream, thread_id, resolved, cache)
                    read_paths.add(resolved)
                    for timestamp_text, values, last_values in events:
                        try:
                            current = tuple(values)
                            timestamp = dt.datetime.fromisoformat(timestamp_text)
                            covered.add(thread_id)
                            if current == previous:
                                continue  # Codex repeats snapshots after responses.
                            last = tuple(last_values) if last_values is not None else None
                            if previous == (0, 0, 0, 0) and last is not None and last[3] < current[3]:
                                # Imported/truncated logs can begin with an inherited
                                # lifetime total. Only this request belongs to this day.
                                delta = last
                                damaged = True
                            elif current[3] < previous[3]:
                                # A resumed/reset counter must not re-charge its history.
                                delta = tuple(last_values) if last_values is not None else None
                                if delta is None:
                                    damaged = True
                                    previous = current
                                    continue
                            else:
                                delta = tuple(max(0, n - p) for n, p in zip(current, previous))
                            previous = current
                            # Copies and forked histories retain original event timestamps
                            # and counters. Count their shared prefix exactly once.
                            key = (timestamp.isoformat(), current, tuple(last_values) if last_values is not None else None)
                            if key in seen:
                                continue
                            seen.add(key)
                            if delta[3] <= 0:
                                continue
                            totals = [n + d for n, d in zip(totals, delta)]
                            day = timestamp.date().isoformat()
                            entry = daily.setdefault(day, [0, set()])
                            entry[0] += delta[3]
                            entry[1].add(thread_id)
                        except (ValueError, TypeError, KeyError, AttributeError):
                            damaged = True
            except (OSError, ValueError, TypeError, AttributeError):
                damaged = True
            incomplete += int(damaged)

    # Other account selections may share this cache; retain their entries.
    dates = sorted(daily)
    longest = run = 0
    previous_date = None
    for day in dates:
        current = dt.date.fromisoformat(day)
        run = run + 1 if previous_date == current - dt.timedelta(days=1) else 1
        longest = max(longest, run)
        previous_date = current
    today = dt.datetime.now(UTC).date()
    cursor = today if today.isoformat() in daily else today - dt.timedelta(days=1)
    streak = 0
    while cursor.isoformat() in daily:
        streak += 1
        cursor -= dt.timedelta(days=1)
    return {
        "source": "session_events", "scanned_bytes": cache.scanned_bytes,
        "fetched_at": dt.datetime.now(UTC).isoformat().replace("+00:00", "Z"),
        "total_tokens": totals[3], "input_tokens": totals[0],
        "cached_input_tokens": totals[1], "output_tokens": totals[2],
        "max_daily_tokens": max((value[0] for value in daily.values()), default=0),
        "active_days": len(dates), "current_streak": streak, "longest_streak": longest,
        "thread_count": len(threads), "unavailable_threads": len(threads.keys() - covered),
        "incomplete_files": incomplete,
        "daily": [{"date": day, "tokens": daily[day][0], "threads": len(daily[day][1])} for day in dates],
    }


if __name__ == "__main__":
    try:
        args = sys.argv[1:]
        cache_path = args[1] if len(args) >= 2 and args[0] == "--cache" else None
        print(json.dumps(read_report(args[2:] if cache_path else args, cache_path), separators=(",", ":")))
    except (OSError, ValueError, sqlite3.Error):
        sys.exit("Cannot read the Codex usage index; no statistics were fabricated.")
