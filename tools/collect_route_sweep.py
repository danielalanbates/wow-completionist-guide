#!/usr/bin/env python3
"""Fold docs/route_sweep_<flavor>.tsv (from tools/route_sweep.lua) into docs/verification.sqlite, table route_sweep.

    python3 tools/collect_route_sweep.py
Prints a per-flavor summary: guides, located %, precedence violations, optimizer-slower, no-route.
"""
import csv, glob, sqlite3, datetime
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
DB = ROOT / "docs" / "verification.sqlite"
con = sqlite3.connect(DB)
con.executescript("""
CREATE TABLE IF NOT EXISTS route_sweep(
  flavor TEXT, at TEXT, guide TEXT, name TEXT, type TEXT, faction TEXT, zone TEXT, zone_name TEXT,
  steps INTEGER, located INTEGER, unknown_zone INTEGER, window INTEGER, order_ok INTEGER, order_reason TEXT,
  opt_cost REAL, author_cost REAL, route_ok TEXT, route TEXT, error TEXT, PRIMARY KEY(flavor, guide));
""")
at = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
for f in sorted(f for f in glob.glob(str(ROOT / "docs" / "route_sweep_*.tsv")) if not f.endswith("_unknown.tsv")):
    rows = list(csv.DictReader(open(f, encoding="utf-8"), delimiter="\t"))
    if not rows: continue
    fl = rows[0]["flavor"]
    con.execute("DELETE FROM route_sweep WHERE flavor=?", (fl,))
    con.executemany("INSERT OR REPLACE INTO route_sweep VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        [(r["flavor"], at, r["guide"], r["name"], r["type"], r["faction"], r["zone"], r["zone_name"], int(r["steps"]), int(r["located"]),
          int(r["unknown_zone"]), int(r["window"]), int(r["order_ok"]), r["order_reason"], float(r["opt_cost"]), float(r["author_cost"]),
          r["route_ok"], r["route"], r["error"]) for r in rows])
    n = len(rows); steps = sum(int(r["steps"]) for r in rows); loc = sum(int(r["located"]) for r in rows)
    prec = sum(1 for r in rows if r["order_ok"] != "1"); slow = sum(1 for r in rows if float(r["opt_cost"]) > float(r["author_cost"]) + 1)
    nor = sum(1 for r in rows if r["route_ok"] == "no"); err = sum(1 for r in rows if r["error"])
    faster = sum(1 for r in rows if float(r["opt_cost"]) < float(r["author_cost"]) - 1)
    print(f"{fl:7s} guides={n:5d} steps={steps:6d} located={100*loc/max(1,steps):5.1f}% precedence-violations={prec} optimizer-slower={slow} optimizer-faster={faster} no-route={nor} load-errors={err}")
con.commit()
