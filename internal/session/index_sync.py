"""Repair shared rollout pointers only; never merge credentials or policies.

Executed by CAB with an isolated system Python. Input is CAB configuration, not
code. Only state_5.sqlite and rollout-*.jsonl within opted-in shared directories
are opened. Message bodies are neither returned nor rewritten.
"""
import datetime
from contextlib import closing
import fcntl
import json
import os
from pathlib import Path
import sqlite3
import stat
import sys
import tempfile


def regular(path):
    mode = path.lstat().st_mode
    if not stat.S_ISREG(mode):
        raise ValueError("not a regular file: " + str(path))
    return path


def open_rollout(path):
    if not path.name.startswith("rollout-") or not path.name.endswith(".jsonl"):
        raise ValueError("refusing non-rollout path")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise ValueError("not a regular rollout: " + str(path))
    return os.fdopen(fd, "rb")


def timestamp(value):
    return int(datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp() * 1000)


def rollout_info(path):
    with open_rollout(path) as stream:
        first = stream.readline(4 * 1024 * 1024)
        if not first.endswith(b"\n"):
            raise ValueError("incomplete session metadata: " + str(path))
        meta = json.loads(first)
        if meta.get("type") != "session_meta" or not meta.get("payload", {}).get("id"):
            raise ValueError("invalid session metadata: " + str(path))
        # Read only a bounded tail. Ignore an unfinished final append; never use
        # filesystem mtime (which can change during copying) to rank histories.
        size = stream.seek(0, os.SEEK_END)
        start = max(0, size - 4 * 1024 * 1024)
        stream.seek(start)
        tail = stream.read(size - start)
        lines = tail.split(b"\n")[:-1]
        if start:
            lines = lines[1:]
        times = []
        for line in reversed(lines):
            if not line.strip():
                continue
            record = json.loads(line)
            if record.get("timestamp"):
                times.append(timestamp(record["timestamp"]))
            if len(times) >= 32:
                break
        if not times:
            raise ValueError("cannot establish last persisted event: " + str(path))
        return meta["payload"]["id"], max(times)


def connect(path, mode):
    regular(path)
    for suffix in ("-wal", "-shm"):
        sidecar = Path(str(path) + suffix)
        if sidecar.exists() or sidecar.is_symlink():
            regular(sidecar)
    db = sqlite3.connect(path.as_uri() + "?mode=" + mode, uri=True, timeout=10)
    db.row_factory = sqlite3.Row
    return db


def index_rows(path):
    with closing(connect(path, "ro")) as db:
        columns = {row["name"] for row in db.execute("PRAGMA table_info(threads)")}
        required = {"id", "rollout_path", "updated_at"}
        if not required <= columns:
            raise ValueError("unsupported Codex thread schema: " + str(path))
        names = [c for c in ("id", "rollout_path", "updated_at", "updated_at_ms", "name") if c in columns]
        return columns, [dict(row) for row in db.execute("SELECT " + ",".join(names) + " FROM threads")]


def repair(request):
    shared = Path(request["shared"])
    data = Path(request["data"])
    if not shared.is_absolute() or shared.is_symlink() or not shared.is_dir():
        raise ValueError("unsafe shared session root")
    roots = [shared.resolve()]
    archived = shared.parent / "archived_sessions"
    if archived.is_symlink():
        raise ValueError("unsafe archived session root")
    if archived.is_dir():
        roots.append(archived.resolve())
    databases = []
    known_names = {}
    for home in request["homes"]:
        home = Path(home)
        if not home.is_absolute() or home.is_symlink():
            raise ValueError("unsafe account home")
        # Validate the opt-in is actually wired to this shared history.
        if (home / "sessions").resolve() != roots[0]:
            raise ValueError("account does not use the configured shared sessions: " + str(home))
        db = home / "state_5.sqlite"
        if not db.exists() and not db.is_symlink():
            continue
        columns, rows = index_rows(db)
        databases.append((db, columns, rows))
        for row in rows:
            if row.get("name"):
                known_names.setdefault(row["id"], row["name"])
    needed = {row["id"] for _, _, rows in databases for row in rows}
    histories = {}
    for root in roots:
        for folder, dirs, files in os.walk(root, followlinks=False):
            dirs[:] = [d for d in dirs if not (Path(folder) / d).is_symlink()]
            for name in files:
                if not name.startswith("rollout-") or not name.endswith(".jsonl"):
                    continue
                # Inspect only files belonging to indexed IDs. In particular,
                # no unrelated file in an account home is ever opened.
                if not any(thread_id in name for thread_id in needed):
                    continue
                path = Path(folder) / name
                thread_id, latest = rollout_info(path)
                if thread_id in needed:
                    histories.setdefault(thread_id, []).append((latest, path))

    def changes(row, columns):
        candidates = histories.get(row["id"], [])
        if not candidates:
            return {}
        current = Path(row["rollout_path"])
        # Reject pointers outside opted-in history rather than following them.
        resolved = current.resolve()
        if not any(resolved.is_relative_to(root) for root in roots):
            raise ValueError("thread points outside shared history: " + row["id"])
        newest = max(t for t, _ in candidates)
        winners = [p for t, p in candidates if t == newest]
        winner = resolved if resolved in winners else sorted(winners)[0]
        result = {}
        if winner != resolved:
            # Re-read the live files under the SQLite write lock. A running
            # writer may have appended since the initial scan.
            winner_id, winner_time = rollout_info(winner)
            if winner_id != row["id"]:
                raise ValueError("rollout identity changed")
            if current.exists():
                current_id, current_time = rollout_info(resolved)
                if current_id != row["id"]:
                    raise ValueError("current rollout identity does not match index")
                if current_time >= winner_time:
                    return {}
            result["rollout_path"] = str(winner)
            newest = winner_time
        if result:
            # Recency never regresses when the UI has newer metadata.
            result["updated_at"] = max(row["updated_at"], newest // 1000)
            if "updated_at_ms" in columns:
                result["updated_at_ms"] = max(row.get("updated_at_ms") or 0, newest)
        if "name" in columns and not row.get("name") and known_names.get(row["id"]):
            result["name"] = known_names[row["id"]]
        return result

    plans = [(path, columns, [row["id"] for row in rows if changes(row, columns)])
             for path, columns, rows in databases]
    if request.get("dry_run"):
        return {"updated": sum(len(ids) for _, _, ids in plans), "backups": []}
    report = {"updated": 0, "backups": []}
    for path, columns, planned in plans:
        if not planned:
            continue
        # SQLite online backup includes the WAL and is safe with live writers.
        backup_dir = Path(tempfile.mkdtemp(prefix="index-backup-", dir=data))
        backup = backup_dir / (path.parent.name + "-state_5.sqlite")
        with closing(connect(path, "ro")) as source, closing(sqlite3.connect(backup)) as target:
            source.backup(target)
        backup.chmod(0o600)
        report["backups"].append(str(backup))
        with closing(connect(path, "rw")) as db, db:
            db.execute("BEGIN IMMEDIATE")
            for thread_id in planned:
                row = db.execute("SELECT * FROM threads WHERE id=?", (thread_id,)).fetchone()
                if row is None:
                    continue
                update = changes(dict(row), columns)
                if not update:
                    continue
                db.execute("UPDATE threads SET " + ",".join(k + "=?" for k in update) + " WHERE id=?",
                           [*update.values(), thread_id])
                report["updated"] += 1
            # No new thread rows: only Codex may choose their policy defaults.
            # No DELETE/REPLACE and no session truncation or content merging.
    return report


if __name__ == "__main__":
    try:
        request = json.load(sys.stdin)
        lock_path = Path(request["data"]) / "session-index.lock"
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        with os.fdopen(fd, "w") as lock:
            if not stat.S_ISREG(os.fstat(lock.fileno()).st_mode):
                raise ValueError("unsafe index lock")
            fcntl.flock(lock, fcntl.LOCK_EX)
            print(json.dumps(repair(request)))
    except Exception as error:
        print("session index repair failed: " + str(error), file=sys.stderr)
        sys.exit(1)
