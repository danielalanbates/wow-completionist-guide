#!/usr/bin/env python3
# CompletionRoute :: tools/att/build_att.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""tools/att/extract_att.lua rows (TSV) -> compact tools/db2/att/<source>.sqlite.

    python3 tools/att/build_att.py SOURCE REPO COMMIT ROWS.tsv [--out PATH]

Same tables as tools/questie/build_questie.py (rel, obj, spawn, meta; extra spawn kinds q = quest start coords,
a = objective coords), plus
  ach(ach, map, x, y)          achievement / criterion coordinates
  achvia(ach, kind, entry)     criterion npc/object providers without own coordinates (their spawns are in spawn)
"""
import argparse
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "questie"))
import build_questie as BQ  # noqa: E402


def build(rows, out, meta):
    n = BQ.build(rows, out, meta)
    ach, via = set(), set()
    with open(rows, encoding="utf-8") as f:
        for ln in f:
            p = ln.rstrip("\n").split("\t")
            if p[0] == "ach":
                ach.add((int(p[1]), int(p[2]), float(p[3]), float(p[4])))
            elif p[0] == "achvia":
                via.add((int(p[1]), p[2], int(p[3])))
    db = sqlite3.connect(out)
    db.executescript("create table ach(ach int, map int, x real, y real); create table achvia(ach int, kind text, entry int);")
    db.executemany("insert into ach values (?,?,?,?)", sorted(ach))
    db.executemany("insert into achvia values (?,?,?)", sorted(via))
    db.executescript("create index ach_a on ach(ach); create index achvia_a on achvia(ach);")
    db.commit()
    db.execute("vacuum")
    db.close()
    return n + (len(ach), len(via))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("repo")
    ap.add_argument("commit")
    ap.add_argument("rows")
    ap.add_argument("--out")
    a = ap.parse_args()
    out = Path(a.out) if a.out else ROOT / "tools" / "db2" / "att" / f"{a.source}.sqlite"
    n = build(a.rows, out, {"repo": a.repo, "commit": a.commit, "source": a.source})
    print(f"{out.name}: rel {n[0]}, obj {n[1]}, spawn {n[2]}, ach {n[3]}, achvia {n[4]}, {out.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
