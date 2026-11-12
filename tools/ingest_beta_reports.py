#!/usr/bin/env python3
"""CompletionRoute :: tools/ingest_beta_reports.py - load /cr bug reports from SavedVariables into SQL.

Copyright (c) 2026 Daniel Bates / Bates LLC.  All rights reserved.
Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org

    python3 tools/ingest_beta_reports.py [--wow "/Volumes/x10/Video Games/Mac/World of Warcraft"]
                                         [--sv path/to/CompletionRoute.lua ...] [--db docs/verification.sqlite]
                                         [--luajit luajit] [--quiet]

Reads CompletionRouteDB.bugReports from every client folder's SavedVariables
(<wow>/*/WTF/Account/*/SavedVariables/CompletionRoute.lua), or from the files given with --sv, and upserts one row per
report into the table `beta_reports`, keyed by the report id (a report seen again is updated, never duplicated; the
triage columns `status` and `triage` are never overwritten).  The full report is kept as JSON in the `json` column;
`luajit tools/vplayer.lua --repro <id>` replays it from there.

SavedVariables are only read: each file is converted by tools/sv_to_json.lua (luajit, empty environment, instruction
budget), and its size and modification time are compared before and after so a file the game rewrote mid-read is
reported.  The account folder name is not stored; a short hash of it is (`account`), enough to tell accounts apart.
Character and realm names are never in a report (Core/BugReport.lua leaves them out and scrubs free text).

On the 8 GB Mac, start it the way every heavy job is started (one at a time); it runs luajit itself, one file at a
time.  See docs/BETA_REPORTS.md.
"""
import argparse
import datetime
import glob
import hashlib
import json
import os
import sqlite3
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_WOW = "/Volumes/x10/Video Games/Mac/World of Warcraft"
DEFAULT_DB = ROOT / "docs" / "verification.sqlite"

SCHEMA = """
CREATE TABLE IF NOT EXISTS beta_reports(
  id TEXT PRIMARY KEY,
  at TEXT, epoch INTEGER,
  client TEXT, account TEXT,
  flavor TEXT, data_flavor TEXT, build TEXT, interface INTEGER, addon_version TEXT,
  class TEXT, race TEXT, level REAL, faction TEXT,
  guide TEXT, guide_name TEXT, step INTEGER, action TEXT, qid TEXT, step_title TEXT, loc_source TEXT,
  map INTEGER, x REAL, y REAL,
  route TEXT, route_secs REAL, arrow_mode TEXT,
  note TEXT, error TEXT, sections_failed TEXT,
  status TEXT DEFAULT 'new', triage TEXT,
  first_seen TEXT, last_seen TEXT,
  json TEXT);
CREATE INDEX IF NOT EXISTS beta_reports_guide ON beta_reports(guide, step);
"""
# data columns (refreshed on every ingest); status, triage and first_seen belong to the person triaging
DATA_COLS = ["at", "epoch", "client", "account", "flavor", "data_flavor", "build", "interface", "addon_version",
             "class", "race", "level", "faction", "guide", "guide_name", "step", "action", "qid", "step_title",
             "loc_source", "map", "x", "y", "route", "route_secs", "arrow_mode", "note", "error", "sections_failed",
             "last_seen", "json"]


def d(v):
    """a JSON object, or {} (the Lua side writes an empty table as [])"""
    return v if isinstance(v, dict) else {}


def find_files(wow):
    return sorted(glob.glob(os.path.join(glob.escape(wow), "*", "WTF", "Account", "*", "SavedVariables", "CompletionRoute.lua")))


def where(path):
    """(client folder, hashed account folder) from .../<client>/WTF/Account/<account>/SavedVariables/CompletionRoute.lua"""
    parts = Path(path).parts
    client, account = "", ""
    if "WTF" in parts:
        i = parts.index("WTF")
        client = parts[i - 1] if i > 0 else ""
        if i + 2 < len(parts) and parts[i + 1] == "Account":
            account = hashlib.sha1(parts[i + 2].encode("utf-8")).hexdigest()[:10]
    return client, account


def read_reports(path, luajit):
    """-> (reports list, lastError or None, problem text or None).  Never writes the file.

    A file that is missing, unreadable or replaced while it is read is a problem for that file only: the run goes on."""
    try:
        st0 = os.stat(path)
    except OSError as e:
        return [], None, f"cannot read it: {e.strerror or e}"
    try:
        proc = subprocess.run([luajit, str(ROOT / "tools" / "sv_to_json.lua"), path], cwd=str(ROOT),
                              capture_output=True, timeout=300)
    except (OSError, subprocess.TimeoutExpired) as e:
        return [], None, f"converter failed: {e}"
    try:
        st1 = os.stat(path)
    except OSError as e:
        return [], None, f"file went away while it was read (is the game writing it?): {e.strerror or e}"
    if (st0.st_size, st0.st_mtime_ns) != (st1.st_size, st1.st_mtime_ns):
        return [], None, "file changed while it was read (is the game writing it?); run again"
    if proc.returncode != 0:
        return [], None, "converter: " + proc.stderr.decode("utf-8", "replace").strip()[:300]
    try:
        data = json.loads(proc.stdout.decode("utf-8", "replace"))
    except ValueError as e:
        return [], None, f"converter output is not JSON: {e}"
    data = d(data)
    reports = data.get("bugReports") or []
    if isinstance(reports, dict):          # a sparse table comes out as an object keyed "1", "2", ...
        reports = [reports[k] for k in sorted(reports, key=lambda k: int(k) if str(k).isdigit() else 0)]
    reports = [r for r in reports if isinstance(r, dict) and isinstance(r.get("id"), str) and r["id"]]
    return reports, data.get("lastError"), None


def row_for(r, client, account, now):
    c, ch, g, s, p = d(r.get("client")), d(r.get("char")), d(r.get("guide")), d(r.get("step")), d(r.get("player"))
    route, arrow, err = d(r.get("route")), d(r.get("arrow")), d(r.get("lastError"))
    failed = ",".join(sorted(d(r.get("errors")).keys())) or None
    return {
        "id": r["id"], "at": r.get("at"), "epoch": r.get("epoch"), "client": client, "account": account,
        "flavor": c.get("flavor"), "data_flavor": c.get("dataFlavor"), "build": c.get("build"),
        "interface": c.get("interface"), "addon_version": d(r.get("addon")).get("version"),
        "class": ch.get("class"), "race": ch.get("race"), "level": ch.get("levelFrac", ch.get("level")),
        "faction": ch.get("faction"),
        "guide": g.get("id"), "guide_name": g.get("name"), "step": s.get("index"), "action": s.get("action"),
        "qid": s.get("qid"), "step_title": s.get("title"), "loc_source": s.get("locSource"),
        "map": p.get("map"), "x": p.get("x"), "y": p.get("y"),
        "route": route.get("desc") if route.get("found") else ("no route" if route else None),
        "route_secs": route.get("secs"), "arrow_mode": arrow.get("mode"),
        "note": r.get("note"), "error": err.get("msg"), "sections_failed": failed,
        "first_seen": now, "last_seen": now,
        "json": json.dumps(r, sort_keys=True, ensure_ascii=False, separators=(",", ":")),
    }


def ingest(files, db_path, luajit, quiet=False, out=print):
    con = sqlite3.connect(str(db_path))
    con.executescript(SCHEMA)
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    known = {row[0] for row in con.execute("SELECT id FROM beta_reports")}
    seen, new_ids, problems, with_reports = {}, [], [], 0
    for path in files:
        client, account = where(path)
        reports, _last_error, problem = read_reports(path, luajit)
        if problem:
            problems.append((client or path, problem))
            continue
        if reports:
            with_reports += 1
        for r in reports:
            if r["id"] in seen:
                continue                      # the same report in two files: keep the first
            seen[r["id"]] = row_for(r, client, account, now)
    cols = ["id"] + DATA_COLS + ["first_seen"]
    sql = ("INSERT INTO beta_reports (" + ",".join(cols) + ") VALUES (" + ",".join("?" * len(cols)) + ") "
           "ON CONFLICT(id) DO UPDATE SET " + ",".join(f"{c}=excluded.{c}" for c in DATA_COLS))
    for rid, row in seen.items():
        con.execute(sql, [row[c] for c in cols])
        if rid not in known:
            new_ids.append(rid)
    con.commit()
    total = con.execute("SELECT COUNT(*) FROM beta_reports").fetchone()[0]
    out(f"ingest: {len(files)} SavedVariables file(s), {with_reports} with reports, {len(seen)} report(s) read: "
        f"{len(new_ids)} new, {len(seen) - len(new_ids)} already known; {total} in {db_path}")
    for who, problem in problems:
        out(f"  skipped {who}: {problem}")
    if not quiet:
        for rid in sorted(new_ids, key=lambda i: (seen[i]["epoch"] or 0), reverse=True)[:20]:
            r = seen[rid]
            note = f'  "{r["note"][:60]}"' if r["note"] else ""
            err = "  [lua error]" if r["error"] else ""
            out(f"  new {rid}  {r['flavor'] or '?'}  {r['guide'] or 'no guide'} step {r['step'] if r['step'] is not None else '-'}"
                f" [{r['action'] or '-'}]{note}{err}")
        if new_ids:
            out("  replay one: luajit tools/vplayer.lua --repro <id>" + ("" if Path(db_path) == DEFAULT_DB else f" --db {db_path}"))
    con.close()
    return {"files": len(files), "with_reports": with_reports, "read": len(seen), "new": len(new_ids),
            "problems": problems, "total": total}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--wow", default=DEFAULT_WOW, help="World of Warcraft folder holding the client folders")
    ap.add_argument("--sv", action="append", default=[], help="read this SavedVariables file instead (repeatable)")
    ap.add_argument("--db", default=str(DEFAULT_DB), help="SQLite database (default docs/verification.sqlite)")
    ap.add_argument("--luajit", default="luajit")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args(argv)
    files = a.sv or find_files(a.wow)
    if not files:
        print(f"ingest: no CompletionRoute SavedVariables under {a.wow}")
        return 1
    res = ingest(files, a.db, a.luajit, a.quiet)
    return 0 if not res["problems"] or res["read"] else 1


if __name__ == "__main__":
    sys.exit(main())
