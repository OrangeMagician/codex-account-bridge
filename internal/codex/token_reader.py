"""Read persisted usage events only; never emit conversation content.

The index's tokens_used is cumulative and updated_at can change on import or
pinning. Neither is a daily usage record. Dates below are explicitly UTC.
"""
import datetime as dt
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


def read_report(paths):
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
                    # Bound the scan to the snapshot even if Codex is appending.
                    remaining = os.fstat(stream.fileno()).st_size
                    meta = stream.readline(min(MAX_LINE, remaining))
                    remaining -= len(meta)
                    record = json.loads(meta)
                    if record.get("type") != "session_meta" or record.get("payload", {}).get("id") != thread_id:
                        continue
                    read_paths.add(resolved)
                    while remaining > 0:
                        line = stream.readline(min(MAX_LINE, remaining))
                        remaining -= len(line)
                        if not line:
                            break
                        if not line.endswith(b"\n"):
                            # Discard oversized records and in-progress appends.
                            while remaining > 0 and line and not line.endswith(b"\n"):
                                line = stream.readline(min(MAX_LINE, remaining))
                                remaining -= len(line)
                            damaged = True
                            continue
                        if b'"token_count"' not in line or b'"event_msg"' not in line:
                            continue
                        try:
                            event = json.loads(line)
                            payload = event.get("payload", {})
                            if event.get("type") != "event_msg" or payload.get("type") != "token_count":
                                continue
                            info = payload.get("info")
                            if not isinstance(info, dict):
                                continue
                            current = counters(info.get("total_token_usage"))
                            if current is None:
                                damaged = True
                                continue
                            timestamp = dt.datetime.fromisoformat(event["timestamp"].replace("Z", "+00:00"))
                            if timestamp.tzinfo is None:
                                raise ValueError("usage timestamp has no timezone")
                            timestamp = timestamp.astimezone(UTC)
                            covered.add(thread_id)
                            if current == previous:
                                continue  # Codex repeats snapshots after responses.
                            last = counters(info.get("last_token_usage"))
                            if previous == (0, 0, 0, 0) and last is not None and last[3] < current[3]:
                                # Imported/truncated logs can begin with an inherited
                                # lifetime total. Only this request belongs to this day.
                                delta = last
                                damaged = True
                            elif current[3] < previous[3]:
                                # A resumed/reset counter must not re-charge its history.
                                delta = counters(info.get("last_token_usage"))
                                if delta is None:
                                    damaged = True
                                    previous = current
                                    continue
                            else:
                                delta = tuple(max(0, n - p) for n, p in zip(current, previous))
                            previous = current
                            # Copies and forked histories retain original event timestamps
                            # and counters. Count their shared prefix exactly once.
                            key = (timestamp.isoformat(), current, counters(info.get("last_token_usage")))
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
        "source": "session_events",
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
        print(json.dumps(read_report(sys.argv[1:]), separators=(",", ":")))
    except (OSError, ValueError, sqlite3.Error):
        sys.exit("Cannot read the Codex usage index; no statistics were fabricated.")
