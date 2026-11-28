#!/usr/bin/env python3
# CompletionRoute :: tools/record_category.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
#
# Folds the CATEGORY lines of `luajit tools/vplayer.lua <flavor> --category <cat>` (category routing, Core/AutoRoute.lua)
# into docs/verification.sqlite table category_runs (one row per run label, flavor, category, faction).
# Usage: python3 tools/record_category.py <label> <file with CATEGORY lines>
import sqlite3, sys, os

def main():
    label, path = sys.argv[1], sys.argv[2]
    db = sqlite3.connect(os.path.join(os.path.dirname(__file__), "..", "docs", "verification.sqlite"))
    db.execute("""CREATE TABLE IF NOT EXISTS category_runs(label text, flavor text, category text, faction text,
        units int, steps int, stalls int, manual int, errors int, noroute int, level int, finished int, itemcap int,
        timecap int, pool int, available int, blocked int, secs int, laps int, err text,
        PRIMARY KEY(label, flavor, category, faction))""")
    n = 0
    for line in open(path):
        f = line.rstrip("\n").split("\t")
        if not f or f[0] != "CATEGORY":
            continue
        kv = dict(x.split("=", 1) for x in f[4:] if "=" in x)
        if kv.get("err", "").startswith("No such category here"):
            continue    # the category does not exist on this client (Achievements on Classic Era, Legacy off Forever)
        ints = [int(float(kv[k])) for k in ("units", "steps", "stalls", "manual", "errors", "noroute", "level", "finished",
                                             "itemcap", "timecap", "pool", "available", "blocked", "secs", "laps")]
        db.execute("INSERT OR REPLACE INTO category_runs VALUES(?,?,?,?," + ",".join("?" * 15) + ",?)",
                   [label, f[1], f[2], f[3]] + ints + [kv.get("err", "")])
        n += 1
    db.commit()
    print(f"{n} rows -> category_runs ({label})")

if __name__ == "__main__":
    main()
