"""Live replication of the local desktop's persisted thread list and paginated history.

Embedded alongside index_sync.py, which supplies the shared-history lock, schema
allowlists and SQLite file checks. Each desktop keeps its own databases and WAL.
"""
from contextlib import contextmanager
import hashlib
import subprocess
import time
from itertools import permutations

# Keys and portable columns. Unknown columns are never copied from another account.
PAGE_TABLES = {
    "thread_turns": (
        ("thread_id", "turn_id"),
        ("rollout_ordinal", "status", "error_json", "started_at", "completed_at",
         "duration_ms", "first_user_item_id", "final_agent_item_id", "rollout_byte_offset",
         "rollout_end_ordinal", "rollout_end_byte_offset", "root_turn_id")),
    "thread_items": (
        ("thread_id", "turn_id", "item_id"),
        ("rollout_ordinal", "created_at_ms", "item_json", "item_type", "updated_at_ordinal",
         "started_at_ms", "completed_at_ms")),
    "thread_realtime_items": (
        ("thread_id", "item_id"), ("rollout_ordinal", "created_at_ms", "item_type", "item_json")),
}
CATALOG_COLUMNS = ("host_id", "thread_id", "display_title", "source_created_at", "source_updated_at",
                   "cwd", "source_kind", "source_detail", "model_provider", "git_branch", "observation_sequence",
                   "thread_source", "source_recency_at", "project_id", "conversation_origin")
DESKTOP_HISTORY = "thread_history_1.sqlite"
DESKTOP_CATALOG = "sqlite/codex-dev.db"


def rollout_location(row, roots):
    path = Path(row["rollout_path"])
    if not path.is_absolute() or path.is_symlink():
        return None
    resolved = path.resolve()
    if not any(resolved.is_relative_to(r) for r in roots):
        return None
    # Codex can append another UUID to a resumed rollout's filename.
    name = r"rollout-.+-" + re.escape(row["id"]) + r"(?:_[0-9a-fA-F-]{36})?\.jsonl(?:\.zst)?"
    if not re.fullmatch(name, resolved.name):
        return None
    return resolved


def shared_rollout(row, roots):
    path = rollout_location(row, roots)
    if path is None:
        return None
    # Codex compresses a completed file before updating every index.
    if not path.exists() and path.name.endswith(".jsonl"):
        path = Path(str(path) + ".zst")
    return path if not path.is_symlink() and path.is_file() else None


def divergent_rollout(row, path, roots):
    if row is None:
        return False
    location = rollout_location(row, roots)
    if location is None:
        return True
    other = shared_rollout(row, roots)
    return other is not None and other != path


def linked_successor(path, previous, tid, verified):
    if not path or not previous or not segment_id(path, tid):
        return False
    base, _ = verify_header(path, tid, verified)
    return base == (segment_id(previous, tid) or tid)


@contextmanager
def rollout_stream(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise ValueError("invalid shared rollout")
        if path.suffix != ".zst":
            yield stream
            return
        try:
            from compression import zstd
        except ImportError:
            decoder = next((x for x in ("/usr/bin/zstd", "/opt/homebrew/bin/zstd", "/usr/local/bin/zstd")
                            if os.access(x, os.X_OK)), None)
            if not decoder:
                raise ValueError("compressed Codex history requires zstd or Python 3.14+")
            with subprocess.Popen([decoder, "-dq", "-c"], stdin=stream, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL) as process:
                try:
                    yield process.stdout
                finally:
                    process.stdout.close()
                    if process.poll() is None:
                        process.kill()
        else:
            with zstd.open(stream, "rb") as reader:
                yield reader


def segment_id(path, thread_id):
    match = re.search("-" + re.escape(thread_id) + r"_([0-9a-fA-F-]{36})\.jsonl(?:\.zst)?$", path.name)
    return match[1] if match else None


def verify_header(path, thread_id, verified):
    st = path.stat()
    key = (path, st.st_ino, st.st_size, st.st_mtime_ns, thread_id)
    if key in verified:
        return verified[key]
    limit = 4 * 1024 * 1024
    with rollout_stream(path) as stream:
        line = stream.readline(limit)
        if not line.endswith(b"\n"):
            raise ValueError("incomplete shared rollout header")
        meta = json.loads(line)
        payload = meta.get("payload", {})
        if meta.get("type") != "session_meta" or payload.get("id") != thread_id:
            raise ValueError("shared rollout identity mismatch")
        base = (payload.get("history_base") or {}).get("thread_id")
        first_turn = None
        if segment_id(path, thread_id):
            # Match the first persisted turn before admitting an unindexed
            # segment. A filename alone does not establish message ownership.
            remaining = limit
            for _ in range(256):
                line = stream.readline(remaining)
                remaining -= len(line)
                if not line.endswith(b"\n") or remaining <= 0:
                    break
                event = json.loads(line)
                value = event.get("payload", {})
                if event.get("type") == "event_msg" and value.get("type") == "task_started":
                    first_turn = value.get("turn_id")
                    break
    verified[key] = (base, first_turn)
    return verified[key]


def segment_pages(db, tid, path, roots, pending, indexed, verified, report):
    result = []
    seen = set()
    while path is not None:
        sid = segment_id(path, tid)
        if not sid or sid in seen or sid in indexed:
            break
        seen.add(sid)
        base, first_turn = verify_header(path, tid, verified)
        if sid in pending:
            if first_turn and db.execute("SELECT 1 FROM src_pages.thread_turns WHERE thread_id=? AND turn_id=?",
                                         (sid, first_turn)).fetchone():
                result.append((sid, first_turn))
            else:
                report["conflicts"] += 1
        if not isinstance(base, str) or not re.fullmatch(r"[0-9a-fA-F-]{36}", base) or base in indexed:
            break
        basename = "rollout-*-" + tid + "_" + base + ".jsonl"
        candidates = {f for root in roots for ext in ("", ".zst") for f in root.rglob(basename + ext)
                      if shared_rollout({"id": tid, "rollout_path": str(f)}, roots) == f}
        if len(candidates) > 1:
            report["conflicts"] += 1
            break
        path = next(iter(candidates), None)
    return result


def attach_desktop_db(db, schema, home, relative, write=False):
    path = home / relative
    if path.resolve() != path or path.is_symlink():
        raise ValueError("unsafe desktop database path")
    if not path.exists():
        return False  # The official app creates its own schema on first launch.
    with closing(connect(path, "ro")):
        pass
    uri = path.as_uri() + ("?mode=rw" if write else "?mode=ro")
    db.execute("ATTACH DATABASE ? AS " + schema, (uri,))
    return True


def columns_in(db, schema, table):
    return {r["name"] for r in db.execute("PRAGMA " + schema + ".table_info(" + table + ")")}


def compatible_columns(db, source, target, table, allowed):
    common = columns_in(db, source, table) & columns_in(db, target, table)
    return tuple(c for c in allowed if c in common)


def backup_desktop_db(home, relative, data, report):
    # A baseline per database inode, not a half-gigabyte copy on every poll.
    path = home / relative
    st = path.stat()
    tag = hashlib.sha256((str(path) + ":" + str(st.st_dev) + ":" + str(st.st_ino)).encode()).hexdigest()[:24]
    directory = data / "desktop-sync-backups"
    directory.mkdir(mode=0o700, exist_ok=True)
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("unsafe desktop backup directory")
    target = directory / (tag + "-" + path.name)
    if target.exists() or target.is_symlink():
        regular(target)
        return
    fd, name = tempfile.mkstemp(dir=directory, prefix=".pending-")
    os.close(fd)
    try:
        with closing(connect(path, "ro")) as src, closing(sqlite3.connect(name)) as dest:
            src.backup(dest)
        os.replace(name, target)
        report["backups"].append(str(target))
    finally:
        Path(name).unlink(missing_ok=True)


def thread_updates(src, dest, canonical, archived_root):
    if dest is None:
        return {}
    result = {}
    for column in ("updated_at", "updated_at_ms", "recency_at", "recency_at_ms"):
        if column in dest and (src.get(column) or 0) > (dest[column] or 0):
            result[column] = src[column]
    newer = recency(src) > recency(dest)
    for key in ("name", "title"):
        if key in dest and useful_title(src.get(key), src) and (newer or not useful_title(dest[key], dest)):
            if src[key] != dest[key]:
                result[key] = src[key]
    if newer:
        for key in ("preview", "first_user_message", "has_user_event", "project_id", "thread_section_id",
                    "section_position", "section_entered_at_ms", "is_pinned"):
            if key in src and key in dest and src[key] != dest[key]:
                result[key] = src[key]
    if canonical and not Path(dest["rollout_path"]).is_file():
        result["rollout_path"] = str(canonical)
    if canonical and "archived" in dest and "archived" in src:
        archived = int(canonical.is_relative_to(archived_root))
        if src["archived"] == archived and dest["archived"] != archived:
            result["archived"] = archived
            if "archived_at" in dest:
                result["archived_at"] = src.get("archived_at")
    return result


def page_stats(db, schema):
    # Index-only counts also find histories missing pages despite equal cursors
    # (older releases could copy the cursor before copying all the turns).
    counts = ",".join("(SELECT COUNT(*) FROM " + schema + "." + t + " r WHERE r.thread_id=p.thread_id)"
                      for t in PAGE_TABLES)
    return {r[0]: tuple(r[1:]) for r in db.execute(
        "SELECT thread_id,next_rollout_ordinal,next_rollout_byte_offset," + counts +
        " FROM " + schema + ".thread_history_projection_state p")}


def changed_page_threads(db, layouts):
    # Equal counts and cursors can hide different missing items. Compare the
    # covering primary-key indexes without scanning the message bodies.
    threads = set()
    for table, (keys, _) in PAGE_TABLES.items():
        keys = ",".join(keys)
        threads.update(r[0] for r in db.execute(
            "SELECT DISTINCT thread_id FROM (SELECT " + keys + " FROM src_pages." + table +
            " EXCEPT SELECT " + keys + " FROM dst_pages." + table + ")"))
    for table in ("thread_items", "thread_turns"):
        join = ",".join(PAGE_TABLES[table][0])
        conditions = [page_advanced(table, "s.", "d.")]
        conditions.extend("s." + c + " IS NOT NULL AND d." + c + " IS NULL"
                          for c in enrichment_columns(layouts[table]))
        threads.update(r[0] for r in db.execute(
            "SELECT DISTINCT s.thread_id FROM src_pages." + table + " s JOIN dst_pages." + table +
            " d USING(" + join + ") WHERE " + " OR ".join(conditions)))
    return threads


def enrichment_columns(cols):
    return [c for c in ("root_turn_id", "started_at_ms", "completed_at_ms") if c in cols]


def page_advanced(table, src, dst):
    if table == "thread_items":
        return src + "updated_at_ordinal>" + dst + "updated_at_ordinal"
    return ("coalesce(" + src + "rollout_end_ordinal,-1)>coalesce(" + dst + "rollout_end_ordinal,-1)"
            " OR (" + dst + "status='inProgress' AND " + src + "status<>'inProgress')")


def merge_pages(db, layouts, tid):
    for table, cols in layouts.items():
        keys = PAGE_TABLES[table][0]
        cols_sql = ",".join(cols)
        action = "DO NOTHING"
        if table in ("thread_items", "thread_turns"):
            advanced = page_advanced(table, "excluded.", table + ".")
            enrich = enrichment_columns(cols)
            changed = [advanced] + [c + " IS NULL AND excluded." + c + " IS NOT NULL" for c in enrich]
            assignments = []
            for c in cols:
                if c in keys:
                    continue
                value = "excluded." + c
                if c in enrich:
                    value = "coalesce(" + value + "," + c + ")"
                fallback = "coalesce(" + c + ",excluded." + c + ")" if c in enrich else c
                assignments.append(c + "=CASE WHEN " + advanced + " THEN " + value + " ELSE " + fallback + " END")
            action = "DO UPDATE SET " + ",".join(assignments) + " WHERE " + " OR ".join(changed)
        db.execute("INSERT INTO dst_pages." + table + "(" + cols_sql + ") SELECT " + cols_sql +
                   " FROM src_pages." + table + " WHERE thread_id=? ON CONFLICT(" + ",".join(keys) + ") " + action, (tid,))
    db.execute("""INSERT INTO dst_pages.thread_history_projection_state
        (thread_id,next_rollout_byte_offset,next_rollout_ordinal)
        SELECT thread_id,next_rollout_byte_offset,next_rollout_ordinal FROM src_pages.thread_history_projection_state
        WHERE thread_id=? ON CONFLICT(thread_id) DO UPDATE SET
        next_rollout_ordinal=excluded.next_rollout_ordinal,next_rollout_byte_offset=excluded.next_rollout_byte_offset
        WHERE excluded.next_rollout_ordinal>=next_rollout_ordinal AND excluded.next_rollout_byte_offset>=next_rollout_byte_offset
        AND (excluded.next_rollout_ordinal>next_rollout_ordinal OR excluded.next_rollout_byte_offset>next_rollout_byte_offset)""", (tid,))


def local_catalog(db, schema):
    return {r["thread_id"]: dict(r) for r in db.execute(
        "SELECT c.* FROM " + schema + ".local_thread_catalog c JOIN " + schema +
        ".local_thread_catalog_hosts h USING(host_id) WHERE h.host_kind='local'")}


def newer_catalog(src, dest):
    return src is not None and (dest is None or src["source_updated_at"] > dest["source_updated_at"] or
            (useful_title(src["display_title"], src) and not useful_title(dest["display_title"], dest)))


def sync_pair(source, target, roots, data, verified, report):
    if not (source / "state_5.sqlite").exists() or not (target / "state_5.sqlite").exists():
        return
    with closing(connect(target / "state_5.sqlite", "rw")) as db:
        db.execute("PRAGMA trusted_schema=OFF")
        db.execute("PRAGMA foreign_keys=ON")
        attach_desktop_db(db, "src", source, "state_5.sqlite")
        pages = attach_desktop_db(db, "src_pages", source, DESKTOP_HISTORY) and attach_desktop_db(db, "dst_pages", target, DESKTOP_HISTORY, True)
        catalogs = attach_desktop_db(db, "src_cat", source, DESKTOP_CATALOG) and attach_desktop_db(db, "dst_cat", target, DESKTOP_CATALOG, True)
        fields = compatible_columns(db, "src", "main", "threads", THREAD_COLUMNS)
        if not {"id", "rollout_path", "updated_at"} <= set(fields):
            raise ValueError("unsupported desktop thread schema")

        def rows(schema):
            return {r["id"]: dict(r) for r in db.execute("SELECT " + ",".join(fields) + " FROM " + schema + ".threads")}

        src_rows, dst_rows = rows("src"), rows("main")
        a, b = (page_stats(db, "src_pages"), page_stats(db, "dst_pages")) if pages else ({}, {})
        ac, bc = (local_catalog(db, "src_cat"), local_catalog(db, "dst_cat")) if catalogs else ({}, {})
        layouts = {}
        if pages:
            for t, (keys, values) in PAGE_TABLES.items():
                cols = compatible_columns(db, "src_pages", "dst_pages", t, keys + values)
                optional = {"root_turn_id", "started_at_ms", "completed_at_ms"}
                if not (set(keys + values) - optional) <= set(cols):
                    raise ValueError("unsupported desktop message schema: " + t)
                layouts[t] = cols
        missing = changed_page_threads(db, layouts) if pages else set()
        pending = {key for key, stats in a.items()
                   if key not in b or key in missing or any(x > y for x, y in zip(stats, b[key]))}
        indexed = src_rows.keys() | dst_rows.keys()
        unindexed = pending - indexed
        parents = {t: cols for t, cols in PARENT_COLUMNS.items()
                   if compatible_columns(db, "src", "main", t, cols) == cols}
        catalog_cols = compatible_columns(db, "src_cat", "dst_cat", "local_thread_catalog", CATALOG_COLUMNS) if catalogs else ()
        for tid, src in src_rows.items():
            dest = dst_rows.get(tid)
            path = shared_rollout(src, roots)
            if path is None:
                continue
            other = shared_rollout(dest, roots) if dest else None
            advance = divergent_rollout(dest, path, roots) and linked_successor(path, other, tid, verified)
            if other != path and linked_successor(other, path, tid, verified):
                continue
            if divergent_rollout(dest, path, roots) and not advance:
                # Both copies still exist. Combining their ordinal spaces could
                # corrupt the paginated history. Leave the originals intact.
                report["conflicts"] += 1
                continue
            page_ids = [(tid, None)] if tid in pending else []
            if unindexed and re.fullmatch(r"[0-9a-fA-F-]{36}", tid) and segment_id(path, tid):
                page_ids.extend(segment_pages(db, tid, path, roots, unindexed, indexed, verified, report))
            if any((a[key][0] - b[key][0]) * (a[key][1] - b[key][1]) < 0
                   for key, _ in page_ids if key in b):
                report["conflicts"] += 1
                continue
            copy_catalog = newer_catalog(ac.get(tid), bc.get(tid))
            updates = thread_updates(src, dest, path, roots[1])
            if advance:
                updates["rollout_path"] = str(path)
            if dest and not (updates or page_ids or copy_catalog):
                continue
            verify_header(path, tid, verified)
            if dest is None or updates:
                backup_desktop_db(target, "state_5.sqlite", data, report)
            if page_ids:
                backup_desktop_db(target, DESKTOP_HISTORY, data, report)
            if copy_catalog:
                backup_desktop_db(target, DESKTOP_CATALOG, data, report)
            # Re-read both thread paths and the target fields under the write
            # lock. Each thread and its projection cursor commit together.
            with db:
                db.execute("BEGIN IMMEDIATE")
                fresh = db.execute("SELECT * FROM src.threads WHERE id=?", (tid,)).fetchone()
                live = db.execute("SELECT * FROM main.threads WHERE id=?", (tid,)).fetchone()
                if not fresh or shared_rollout(fresh, roots) != path:
                    continue
                src = dict(fresh)
                dest = dict(live) if live else None
                other = shared_rollout(dest, roots) if dest else None
                advance = divergent_rollout(dest, path, roots) and linked_successor(path, other, tid, verified)
                if divergent_rollout(dest, path, roots) and not advance:
                    report["conflicts"] += 1
                    continue
                if dest is None and pages and any(db.execute(
                    "SELECT 1 FROM dst_pages." + table + " WHERE thread_id=? LIMIT 1", (tid,)
                ).fetchone() for table in (*PAGE_TABLES, "thread_history_projection_state")):
                    # An orphan has no index entry proving which file its
                    # messages came from. Never publish it through a new row.
                    report["conflicts"] += 1
                    continue
                verify_header(path, tid, verified)
                before = db.total_changes
                updates = thread_updates(src, dest, path, roots[1])
                if advance:
                    updates["rollout_path"] = str(path)
                if not dest or updates:
                    for table, key, fk in (("projects","id","project_id"), ("project_roots","project_id","project_id"),
                                           ("thread_sections","id","thread_section_id")):
                        if table in parents and src.get(fk) is not None:
                            cols = ",".join(parents[table])
                            db.execute("INSERT OR IGNORE INTO main." + table + "(" + cols + ") SELECT " + cols +
                                       " FROM src." + table + " WHERE " + key + "=?", (src[fk],))
                    if not dest:
                        src["rollout_path"] = str(path)
                        db.execute("INSERT INTO main.threads(" + ",".join(fields) + ") VALUES(" +
                                   ",".join("?" for _ in fields) + ")", [src[c] for c in fields])
                    elif updates:
                        db.execute("UPDATE main.threads SET " + ",".join(c + "=?" for c in updates) + " WHERE id=?",
                                   [*updates.values(), tid])
                for key, first in page_ids:
                    if first:
                        occupied = db.execute("SELECT id FROM main.threads WHERE id=? UNION ALL SELECT id FROM src.threads WHERE id=?", (key, key)).fetchone()
                        source_matches = db.execute("SELECT 1 FROM src_pages.thread_turns WHERE thread_id=? AND turn_id=?", (key, first)).fetchone()
                        foreign_turns = db.execute("""SELECT EXISTS(SELECT 1 FROM dst_pages.thread_turns WHERE thread_id=?)
                            AND NOT EXISTS(SELECT 1 FROM dst_pages.thread_turns WHERE thread_id=? AND turn_id=?)""",
                            (key, key, first)).fetchone()[0]
                        if occupied or not source_matches or foreign_turns:
                            report["conflicts"] += 1
                            continue
                    merge_pages(db, layouts, key)
                if copy_catalog:
                    # Only the local host's thread belongs to this shared history.
                    c = ac[tid]
                    host = c["host_id"]
                    existing = db.execute("SELECT host_kind FROM dst_cat.local_thread_catalog_hosts WHERE host_id=?", (host,)).fetchone()
                    if existing is None or existing[0] == "local":
                        db.execute("INSERT OR IGNORE INTO dst_cat.local_thread_catalog_hosts(host_id,host_kind) VALUES(?,'local')", (host,))
                        cols = ",".join(catalog_cols)
                        updates_sql = ",".join(x + "=CASE WHEN excluded.source_updated_at>source_updated_at THEN excluded." + x + " ELSE " + x + " END" for x in catalog_cols
                                               if x not in ("host_id","thread_id","observation_sequence","display_title"))
                        db.execute("INSERT INTO dst_cat.local_thread_catalog(" + cols + ") SELECT " + cols +
                                   " FROM src_cat.local_thread_catalog WHERE host_id=? AND thread_id=? ON CONFLICT(host_id,thread_id)"
                                   " DO UPDATE SET " + updates_sql + ", display_title=CASE WHEN trim(excluded.display_title) NOT IN ('',"
                                   "trim(coalesce(excluded.cwd,''))) THEN excluded.display_title ELSE display_title END"
                                   " WHERE excluded.source_updated_at>source_updated_at OR (trim(display_title) IN ('',trim(coalesce(cwd,''))) AND "
                                   "trim(excluded.display_title) NOT IN ('',trim(coalesce(excluded.cwd,''))))", (host,tid))
                        if db.execute("SELECT changes()").fetchone()[0]:
                            db.execute("UPDATE dst_cat.local_thread_catalog_metadata SET catalog_revision=catalog_revision+1 WHERE id=1")
                report["updated"] += int(db.total_changes > before)


def sync_desktops(request):
    shared = Path(request["shared"])
    archived = shared.parent / "archived_sessions"
    roots = (shared.resolve(), archived.resolve())
    homes = [Path(h) for h in request["homes"]]
    if not shared.is_absolute() or not shared.is_dir() or shared.is_symlink() or archived.is_symlink():
        raise ValueError("unsafe shared history root")
    for home in homes:
        if home.resolve() != home or (home / "sessions").resolve() != roots[0]:
            raise ValueError("account is not using this shared history")
        if ((home / "archived_sessions").exists() or (home / "archived_sessions").is_symlink()) and (home / "archived_sessions").resolve() != roots[1]:
            raise ValueError("account is not using this shared archive")
    report = {"updated": 0, "conflicts": 0, "backups": []}
    verified = {}
    for source, target in permutations(homes, 2):
        for attempt in range(3):
            try:
                sync_pair(source, target, roots, Path(request["data"]), verified, report)
                break
            except sqlite3.OperationalError as error:
                if attempt == 2 or str(error) not in ("unable to open database file", "database is locked"):
                    raise
                # The official client can rotate WAL sidecars while attaching.
                # Transactions already committed are safe to repeat.
                time.sleep(0.25)
    return report
