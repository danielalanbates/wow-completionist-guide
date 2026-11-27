#!/usr/bin/env python3
# CompletionRoute :: tools/questie/build_questie.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""tools/questie/extract_questie.lua rows (TSV) -> compact tools/db2/questie/<source>.sqlite.

    python3 tools/questie/build_questie.py SOURCE REPO COMMIT ROWS.tsv [--out PATH]

Tables (facts only: ids and zone coordinates):
  rel(quest, role, kind, entry, via)      role start|end; kind c (npc) / g (object); via = item id (item-started quest) or 0
  obj(quest, idx, kind, entry, via)       objective targets (idx 0-based, Blizzard order); kind t = explore area (entry = quest);
                                          via = the objective item an npc/object drops
  spawn(kind, entry, map, x, y)           uiMap id + 0-100 zone %
  meta(key, value)                        repo, commit
"""
import argparse
import sqlite3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def build(rows, out, meta):
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        out.unlink()
    db = sqlite3.connect(out)
    db.executescript("""
    create table rel(quest int, role text, kind text, entry int, via int);
    create table obj(quest int, idx int, kind text, entry int, via int);
    create table spawn(kind text, entry int, map int, x real, y real);
    create table meta(key text primary key, value text);
    """)
    rel, obj, spawn = set(), set(), set()
    with open(rows, encoding="utf-8") as f:
        for ln in f:
            p = ln.rstrip("\n").split("\t")
            if p[0] == "rel":
                rel.add((int(p[1]), p[2], p[3], int(p[4]), int(p[5])))
            elif p[0] == "obj":
                obj.add((int(p[1]), int(p[2]), p[3], int(p[4]), int(p[5])))
            elif p[0] == "spawn":
                spawn.add((p[1], int(p[2]), int(p[3]), float(p[4]), float(p[5])))
    db.executemany("insert into rel values (?,?,?,?,?)", sorted(rel))
    db.executemany("insert into obj values (?,?,?,?,?)", sorted(obj))
    db.executemany("insert into spawn values (?,?,?,?,?)", sorted(spawn))
    db.executemany("insert into meta values (?,?)", sorted(meta.items()))
    db.executescript("create index rel_q on rel(quest, role); create index obj_q on obj(quest);"
                     "create index spawn_e on spawn(kind, entry);")
    db.commit()
    db.execute("vacuum")
    db.close()
    return len(rel), len(obj), len(spawn)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("repo")
    ap.add_argument("commit")
    ap.add_argument("rows")
    ap.add_argument("--out")
    a = ap.parse_args()
    out = Path(a.out) if a.out else ROOT / "tools" / "db2" / "questie" / f"{a.source}.sqlite"
    n = build(a.rows, out, {"repo": a.repo, "commit": a.commit, "source": a.source})
    print(f"{out.name}: rel {n[0]}, obj {n[1]}, spawn {n[2]}, {out.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
