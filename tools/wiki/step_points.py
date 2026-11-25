#!/usr/bin/env python3
# CompletionRoute :: tools/wiki/step_points.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Count the A / C / T quest steps of generated guide files by location kind (measurement only, writes nothing
unless --chart LABEL is given, then one row per file into docs/verification.sqlite table step_points).

    python3 tools/wiki/step_points.py [--chart LABEL] FILE.lua ...

point = the step has |M| (a map point); zone = |Z| only; none = neither; history = the note says
"(location: wiki revision <id>)" (a point recovered from the page's pre-4.0.3 revision, fetch_coord_history.py).
"""
import datetime
import re
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STEP = re.compile(r"^\s*([ACT]) [^|]*\|QID\|")


def count(path):
    n = {"steps": 0, "point": 0, "zone": 0, "none": 0, "history": 0}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if not STEP.match(line):
            continue
        n["steps"] += 1
        if "|M|" in line:
            n["point"] += 1
        elif "|Z|" in line:
            n["zone"] += 1
        else:
            n["none"] += 1
        n["history"] += "(location: wiki revision " in line
    return n


def main(argv):
    label = None
    if argv[:1] == ["--chart"]:
        label, argv = argv[1], argv[2:]
    rows = []
    for f in argv:
        n = count(f)
        rows.append((Path(f).name, n))
        s = n["steps"] or 1
        print(f"{Path(f).name:32} steps {n['steps']:6}  point {n['point']:6} ({100*n['point']/s:.1f}%)  "
              f"zone {n['zone']:6} ({100*n['zone']/s:.1f}%)  none {n['none']:5}  pre-4.0.3 revision {n['history']}")
    if label:
        db = sqlite3.connect(ROOT / "docs" / "verification.sqlite")
        db.execute("create table if not exists step_points(file text, label text, steps int, point int, zone int, "
                   "none int, history int, measured text, primary key (file, label))")
        now = datetime.datetime.now().isoformat(sep=" ", timespec="seconds")
        for name, n in rows:
            db.execute("insert or replace into step_points values (?,?,?,?,?,?,?,?)",
                       (name, label, n["steps"], n["point"], n["zone"], n["none"], n["history"], now))
        db.commit()


if __name__ == "__main__":
    main(sys.argv[1:])
