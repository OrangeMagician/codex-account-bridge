"""Repair opted-in shared history and portable thread metadata.

Never overwrite an existing thread's credentials, policies or runtime settings.

Executed by CAB with an isolated system Python. Input is CAB configuration, not
code. Only state_5.sqlite, session_index.jsonl and verified rollout-*.jsonl
within opted-in account/history directories are opened. Rollout message bodies are neither returned nor rewritten.
"""
import datetime
from contextlib import closing
import fcntl
import json
import os
import re
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
    # Older system Pythons require three or six fractional digits. Codex
    # writes variable precision, including nanoseconds; normalize to micros.
    value = re.sub(r"\.(\d+)", lambda match: "." + (match[1] + "000000")[:6], value)
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


# Explicit allowlist: no account identity, authentication, enrollments or trust.
THREAD_COLUMNS = (
    "id", "rollout_path", "created_at", "updated_at", "source", "model_provider",
    "cwd", "title", "sandbox_policy", "approval_mode", "tokens_used",
    "has_user_event", "archived", "archived_at", "git_sha", "git_branch",
    "git_origin_url", "cli_version", "first_user_message", "agent_nickname",
    "agent_role", "memory_mode", "model", "reasoning_effort", "agent_path",
    "created_at_ms", "updated_at_ms", "thread_source", "preview", "recency_at",
    "recency_at_ms", "history_mode", "name", "is_pinned", "thread_section_id",
    "section_position", "section_entered_at_ms", "project_id",
)
PARENT_COLUMNS = {
    "projects": ("id", "name", "metadata", "position", "created_at_ms", "updated_at_ms"),
    "project_roots": ("project_id", "position", "path"),
    "thread_sections": ("id", "name", "appearance"),
}


def recency(row):
    return row.get("updated_at_ms") or (row.get("updated_at") or 0) * 1000


def useful_title(value, row):
    return bool(value and value.strip() and value.strip().rstrip("/\\") != (row.get("cwd") or "").strip().rstrip("/\\"))


def metadata_changes(row, columns, versions, preferred=None):
    result = {}
    newest = max(versions, key=recency)
    for key in ("name", "title"):
        choices = [r for r in versions if useful_title(r.get(key), r)]
        if key not in columns or not choices:
            continue
        best = max(choices, key=recency)
        if not useful_title(row.get(key), row) or recency(best) > recency(row):
            if row.get(key) != best[key]:
                result[key] = best[key]
    if "is_pinned" in columns and not row.get("is_pinned") and any(r.get("is_pinned") for r in versions):
        result["is_pinned"] = 1
    if recency(newest) > recency(row):
        for key in ("project_id", "thread_section_id", "section_position", "section_entered_at_ms"):
            if key in columns and key in newest and newest[key] != row.get(key):
                result[key] = newest[key]
    if preferred:
        for key in ("is_pinned", "project_id", "thread_section_id", "section_position", "section_entered_at_ms"):
            if key in columns and key in preferred:
                if row.get(key) != preferred[key]:
                    result[key] = preferred[key]
                else:
                    result.pop(key, None)
        for key in ("name", "title"):
            if key in columns and useful_title(preferred.get(key), preferred) and recency(preferred) >= recency(row) and row.get(key) != preferred[key]:
                result[key] = preferred[key]
    return result


def saved_names(home):
    path = home / "session_index.jsonl"
    if not path.exists() and not path.is_symlink():
        return []
    regular(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode) or os.fstat(stream.fileno()).st_size > 64 * 1024 * 1024:
            raise ValueError("unsafe session name index")
        names = []
        for line in stream:
            # An official append may still be in progress.
            if not line.endswith(b"\n"):
                continue
            row = json.loads(line)
            if row.get("id") and isinstance(row.get("thread_name"), str):
                names.append(row)
        return names


def index_rows(path):
    with closing(connect(path, "ro")) as db:
        columns = {row["name"] for row in db.execute("PRAGMA table_info(threads)")}
        required = {"id", "rollout_path", "updated_at"}
        if not required <= columns:
            raise ValueError("unsupported Codex thread schema: " + str(path))
        names = [c for c in THREAD_COLUMNS if c in columns]
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
    versions = {}
    preferred_rows = {}
    parents = {table: [] for table in PARENT_COLUMNS}
    recovered_names = {}
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
        for saved in saved_names(home):
            previous = recovered_names.get(saved["id"])
            if previous is None or timestamp(saved["updated_at"]) > timestamp(previous["updated_at"]):
                recovered_names[saved["id"]] = saved
        databases.append((db, columns, rows))
        if str(home) == request.get("source_home"):
            preferred_rows = {row["id"]: row for row in rows}
        for row in rows:
            versions.setdefault(row["id"], []).append(row)
        with closing(connect(db, "ro")) as source:
            for table, allowed in PARENT_COLUMNS.items():
                available = {r["name"] for r in source.execute("PRAGMA table_info(" + table + ")")}
                if set(allowed) <= available:
                    parents[table].extend(dict(r) for r in source.execute("SELECT " + ",".join(allowed) + " FROM " + table))
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

    def changes(row, columns, current_home=None):
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
        preferred = row if str(current_home) == request.get("source_home") else preferred_rows.get(row["id"])
        result.update(metadata_changes(row, columns, versions[row["id"]], preferred))
        saved = recovered_names.get(row["id"])
        if "name" in columns and saved and not useful_title(result.get("name", row.get("name")), row) and useful_title(saved["thread_name"], row):
            result["name"] = saved["thread_name"]
        return result

    def missing_rows(rows, columns):
        present = {r["id"] for r in rows}
        missing = []
        for thread_id, copies in versions.items():
            if thread_id in present or thread_id not in histories:
                continue
            candidate = dict(max(copies, key=recency))
            # Import only an already indexed official thread with a verified
            # shared rollout. New rows retain that thread's original settings;
            # no defaults or existing security settings are changed.
            candidate.update(changes(candidate, columns))
            missing.append({k: v for k, v in candidate.items() if k in columns})
        return missing

    plans = [(path, columns, [row["id"] for row in rows if changes(row, columns, path.parent)], missing_rows(rows, columns))
             for path, columns, rows in databases]
    if request.get("dry_run"):
        return {"updated": sum(len(ids) + len(missing) for _, _, ids, missing in plans), "backups": []}
    report = {"updated": 0, "backups": []}
    for path, columns, planned, missing in plans:
        if not planned and not missing:
            continue
        # SQLite online backup includes the WAL and is safe with live writers.
        backup_dir = Path(tempfile.mkdtemp(prefix="index-backup-", dir=data))
        backup = backup_dir / (path.parent.name + "-state_5.sqlite")
        with closing(connect(path, "ro")) as source, closing(sqlite3.connect(backup)) as target:
            source.backup(target)
        backup.chmod(0o600)
        report["backups"].append(str(backup))
        with closing(connect(path, "rw")) as db, db:
            db.execute("PRAGMA foreign_keys=ON")
            db.execute("BEGIN IMMEDIATE")
            # Parent rows must precede project/section membership updates.
            for table, allowed in PARENT_COLUMNS.items():
                available = {r["name"] for r in db.execute("PRAGMA table_info(" + table + ")")}
                if set(allowed) <= available:
                    for parent in parents[table]:
                        db.execute("INSERT OR IGNORE INTO " + table + " (" + ",".join(allowed) + ") VALUES (" + ",".join("?" for _ in allowed) + ")", list(parent.values()))
            for candidate in missing:
                # A live writer may have created it since planning. Never
                # replace that row, including its policy and runtime fields.
                inserted = db.execute("INSERT INTO threads (" + ",".join(candidate) + ") VALUES (" + ",".join("?" for _ in candidate) + ") ON CONFLICT(id) DO NOTHING", list(candidate.values()))
                report["updated"] += inserted.rowcount
            for thread_id in planned:
                row = db.execute("SELECT * FROM threads WHERE id=?", (thread_id,)).fetchone()
                if row is None:
                    continue
                update = changes(dict(row), columns, path.parent)
                if not update:
                    continue
                db.execute("UPDATE threads SET " + ",".join(k + "=?" for k in update) + " WHERE id=?",
                           [*update.values(), thread_id])
                report["updated"] += 1
            # No DELETE/REPLACE, default changes or session content merging.
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
