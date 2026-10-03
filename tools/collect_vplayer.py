#!/usr/bin/env python3
"""Fold docs/vplayer_<flavor>[_<shard>].tsv (from tools/vplayer.lua) into docs/verification.sqlite.

    python3 tools/collect_vplayer.py

Tables
  vplayer_guides  one row per guide actually played by the virtual player
  vplayer_stalls  one row per step that SHOULD have auto-completed and did not (a real bug)
  vplayer_runs    one summary row per flavor per collection

A "stall" is a step whose action carried the data its check needs (an accept with a QID, a travel
step with coords...) and which still did not tick after the virtual player performed it.  Steps that
can never auto-tick (a note, a "Kill Kresh" with no QID) are counted as `manual` — in game those are
the ones you press the forward arrow for, exactly as in Zygor.
"""
import csv, glob, re, sqlite3, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DB = ROOT / "docs" / "verification.sqlite"
con = sqlite3.connect(DB)
con.executescript("""
CREATE TABLE IF NOT EXISTS vplayer_guides(
  flavor TEXT, at TEXT, guide TEXT, name TEXT, type TEXT, faction TEXT, zone TEXT, zone_name TEXT,
  steps INTEGER, simulated INTEGER, auto INTEGER, manual INTEGER, stalls INTEGER, forced INTEGER,
  laps INTEGER, yards REAL, seconds REAL, no_route INTEGER, finished INTEGER,
  manual_reason TEXT, error TEXT, PRIMARY KEY(flavor, guide));
CREATE TABLE IF NOT EXISTS vplayer_stalls(
  flavor TEXT, at TEXT, guide TEXT, step INTEGER, action TEXT, title TEXT, qid TEXT, zone TEXT, coords TEXT,
  PRIMARY KEY(flavor, guide, step));
CREATE TABLE IF NOT EXISTS vplayer_runs(
  flavor TEXT, at TEXT, guides INTEGER, finished INTEGER, steps INTEGER, simulated INTEGER,
  auto INTEGER, manual INTEGER, stalls INTEGER, stalled_guides INTEGER, errors INTEGER,
  no_route INTEGER, yards REAL, hours REAL, PRIMARY KEY(flavor, at));
""")
at = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")


def shards(pattern):
    """group docs/vplayer_<flavor>[_<n>].tsv by flavor"""
    out = {}
    for f in sorted(glob.glob(str(ROOT / "docs" / pattern))):
        m = re.search(r"vplayer_([a-z]+?)_?\d*(_stalls)?\.tsv$", f)
        if m:
            out.setdefault(m.group(1), []).append(f)
    return out


for flavor, files in sorted(shards("vplayer_*.tsv").items()):
    guide_files = [f for f in files if not f.endswith("_stalls.tsv")]
    stall_files = [f for f in files if f.endswith("_stalls.tsv")]
    rows, truncated = [], 0
    for f in guide_files:
        for r in csv.DictReader(open(f, encoding="utf-8"), delimiter="\t"):
            # a shard read while it is still running ends in a half-written line; drop it rather
            # than lose the whole file
            if any(r.get(k) is None for k in ("steps", "simulated", "auto", "manual", "stalls",
                                              "forced", "laps", "yards", "seconds", "no_route", "finished")):
                truncated += 1
                continue
            rows.append(r)
    if truncated:
        print(f"{flavor}: skipped {truncated} incomplete row(s) (shard still running?)")
    if not rows:
        continue
    con.execute("DELETE FROM vplayer_guides WHERE flavor=?", (flavor,))
    con.executemany(
        "INSERT OR REPLACE INTO vplayer_guides VALUES (" + ",".join("?" * 21) + ")",
        [(r["flavor"], at, r["guide"], r["name"], r["type"], r["faction"], r["zone"], r["zone_name"],
          int(r["steps"]), int(r["simulated"]), int(r["auto"]), int(r["manual"]), int(r["stalls"]),
          int(r["forced"]), int(r["laps"]), float(r["yards"]), float(r["seconds"]), int(r["no_route"]),
          int(r["finished"]), r.get("manual_reason", ""), r["error"]) for r in rows])

    srows = []
    for f in stall_files:
        srows += list(csv.DictReader(open(f, encoding="utf-8"), delimiter="\t"))
    con.execute("DELETE FROM vplayer_stalls WHERE flavor=?", (flavor,))
    con.executemany("INSERT OR REPLACE INTO vplayer_stalls VALUES (?,?,?,?,?,?,?,?,?)",
                    [(r["flavor"], at, r["guide"], int(r["step"]), r["action"], r["title"], r["qid"],
                      r["zone"], r["coords"]) for r in srows])

    n = len(rows)
    fin = sum(1 for r in rows if r["finished"] == "1")
    steps = sum(int(r["steps"]) for r in rows)
    sim = sum(int(r["simulated"]) for r in rows)
    auto = sum(int(r["auto"]) for r in rows)
    man = sum(int(r["manual"]) for r in rows)
    stalls = sum(int(r["stalls"]) for r in rows)
    sg = sum(1 for r in rows if int(r["stalls"]) > 0)
    err = sum(1 for r in rows if r["error"])
    nor = sum(int(r["no_route"]) for r in rows)
    yards = sum(float(r["yards"]) for r in rows)
    hours = sum(float(r["seconds"]) for r in rows) / 3600.0
    con.execute("INSERT OR REPLACE INTO vplayer_runs VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (flavor, at, n, fin, steps, sim, auto, man, stalls, sg, err, nor, yards, hours))
    pct = 100.0 * auto / max(1, auto + man)
    print(f"{flavor:7s} guides={n:5d} finished={fin:5d} steps={steps:7d} played={sim:7d} "
          f"auto={auto:7d} ({pct:4.1f}%) manual={man:6d} stalls={stalls:4d} in {sg} guides "
          f"errors={err} no-route-steps={nor} walked={yards/1000:.0f}k yd / {hours:.0f} sim-hours")
con.commit()
