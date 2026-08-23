#!/usr/bin/env python3
"""Fold the offline guide-type / gold-circuit audits into docs/verification.sqlite.

  luajit tools/audit_guides.lua <flavor>     # writes docs/audit_guides_<flavor>.csv + audit_gold_<flavor>.csv
  python3 tools/collect_audit.py             # -> tables guide_type_audit, gold_circuits

Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
"""
import csv
import glob
import os
import sqlite3
import subprocess
import sys
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB = os.path.join(ROOT, "docs", "verification.sqlite")


def git_rev():
    try:
        return subprocess.check_output(["git", "-C", ROOT, "rev-parse", "--short", "HEAD"], text=True).strip()
    except Exception:
        return "?"


def main():
    at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    rev = git_rev()
    con = sqlite3.connect(DB)
    cur = con.cursor()
    cur.execute("""CREATE TABLE IF NOT EXISTS guide_type_audit (
        at TEXT, rev TEXT, flavor TEXT, type TEXT, guides INT, steps INT, located INT,
        unlocated INT, nocoord_guides INT, pct_located REAL)""")
    cur.execute("""CREATE TABLE IF NOT EXISTS gold_circuits (
        at TEXT, rev TEXT, flavor TEXT, metric TEXT, value REAL)""")

    types = golds = 0
    for path in sorted(glob.glob(os.path.join(ROOT, "docs", "audit_guides_*.csv"))):
        flavor = os.path.basename(path)[len("audit_guides_"):-len(".csv")]
        with open(path, newline="") as fh:
            for row in csv.DictReader(fh):
                cur.execute("INSERT INTO guide_type_audit VALUES (?,?,?,?,?,?,?,?,?,?)",
                            (at, rev, flavor, row["type"], int(row["guides"]), int(row["steps"]),
                             int(row["located"]), int(row["unlocated"]), int(row["nocoord_guides"]),
                             float(row["pct_located"])))
                types += 1
    for path in sorted(glob.glob(os.path.join(ROOT, "docs", "audit_gold_*.csv"))):
        flavor = os.path.basename(path)[len("audit_gold_"):-len(".csv")]
        with open(path, newline="") as fh:
            for row in csv.DictReader(fh):
                try:
                    value = float(row["value"])
                except ValueError:
                    continue
                cur.execute("INSERT INTO gold_circuits VALUES (?,?,?,?,?)",
                            (at, rev, flavor, row["metric"], value))
                golds += 1
    con.commit()
    print(f"guide_type_audit +{types} rows, gold_circuits +{golds} rows -> {DB}")

    for flavor, folded, total in cur.execute(
            """SELECT flavor,
                      MAX(CASE WHEN metric='folded_to_circuit' THEN value END),
                      MAX(CASE WHEN metric='imported_gold_guides' THEN value END)
               FROM gold_circuits WHERE at = ? GROUP BY flavor ORDER BY flavor""", (at,)):
        if total:
            print(f"  {flavor}: {int(folded)}/{int(total)} gold guides are circuits ({folded / total * 100:.0f}%)")
    con.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
