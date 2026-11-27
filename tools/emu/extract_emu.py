#!/usr/bin/env python3
# CompletionRoute :: tools/emu/extract_emu.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Extract the facts the guides need from an open emulator world-database dump into a compact sqlite.

    python3 tools/emu/extract_emu.py SOURCE REPO COMMIT DUMP [--out tools/db2/emu/SOURCE.sqlite]

DUMP is a mysqldump (.sql, .sql.gz, or a TrinityCore TDB .7z whose *world*.sql is read with `7zz e -so`); nothing is unpacked to disk.
Kept (facts only: ids and world coordinates):
  spawn(kind, entry, map, x, y)     creature (kind 'c') and gameobject ('g') spawn positions
  rel(kind, entry, quest, role)     quest starters ('start') and enders ('end'): cmangos *_questrelation /
                                    *_involvedrelation, TrinityCore *_queststarter / *_questender
  obj(quest, idx, kind, entry)      kill/interact targets (idx: objective slot, 0-based): cmangos quest_template ReqCreatureOrGOId1-4 (negative =
                                    gameobject), TrinityCore quest_objectives Type 0 (creature) / 2 (gameobject)
  meta(key, value)                  repo, commit, dump file name
Sources are GPL emulator databases (cmangos classic-db / tbc-db, TrinityCore TDB); only coordinates and ids, which are
facts, are taken; attribution is in CREDITS.md and docs/EMU_DATA.md.
"""
import argparse
import gzip
import re
import sqlite3
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TABLES = {"creature", "gameobject", "creature_questrelation", "creature_involvedrelation", "gameobject_questrelation",
          "gameobject_involvedrelation", "creature_queststarter", "creature_questender", "gameobject_queststarter",
          "gameobject_questender", "quest_template", "quest_objectives"}
RELS = {"creature_questrelation": ("c", "start"), "creature_involvedrelation": ("c", "end"),
        "gameobject_questrelation": ("g", "start"), "gameobject_involvedrelation": ("g", "end"),
        "creature_queststarter": ("c", "start"), "creature_questender": ("c", "end"),
        "gameobject_queststarter": ("g", "start"), "gameobject_questender": ("g", "end")}
TUPLE = re.compile(r"\((?:'(?:[^'\\]|\\.)*'|[^'()])*\)")
FIELD = re.compile(r"'(?:[^'\\]|\\.)*'|[^,]+")
INSERT = re.compile(r"INSERT INTO `(\w+)`(?: \(([^)]*)\))? VALUES ")


def lines(dump):
    p = str(dump)
    if p.endswith(".7z"):
        proc = subprocess.Popen(["7zz", "e", "-so", p, "*world*.sql"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        for b in proc.stdout:
            yield b.decode("utf-8", "replace")
        proc.wait()
    elif p.endswith(".gz"):
        with gzip.open(p, "rt", encoding="utf-8", errors="replace") as f:
            yield from f
    else:
        with open(p, encoding="utf-8", errors="replace") as f:
            yield from f


def fields(tup):
    return [v.strip() for v in FIELD.findall(tup[1:-1])]


def num(v):
    try:
        return float(v)
    except ValueError:
        return None


def extract(dump):
    cols, cur, out = {}, None, {"spawn": [], "rel": [], "obj": []}
    for ln in lines(dump):
        if ln.startswith("CREATE TABLE `"):
            cur = ln.split("`")[1]
            cols[cur] = []
            continue
        if cur and ln.startswith("  `"):
            cols[cur].append(ln.split("`")[1])
            continue
        if ln.startswith(")"):
            cur = None
            continue
        if not ln.startswith("INSERT INTO `"):
            continue
        m = INSERT.match(ln)
        if not m or m.group(1) not in TABLES:
            continue
        t = m.group(1)
        names = [c.strip(" `") for c in m.group(2).split(",")] if m.group(2) else cols.get(t, [])
        ix = {c: i for i, c in enumerate(names)}
        for tup in TUPLE.finditer(ln, m.end()):
            f = fields(tup.group(0))
            if len(f) != len(names):
                continue
            if t in ("creature", "gameobject"):
                e, mp, x, y = (num(f[ix[k]]) for k in ("id", "map", "position_x", "position_y"))
                if e and mp is not None and x is not None:
                    out["spawn"].append((t[0], int(e), int(mp), round(x, 1), round(y, 1)))
            elif t in RELS:
                k, role = RELS[t]
                out["rel"].append((k, int(num(f[ix["id"]])), int(num(f[ix["quest"]])), role))
            elif t == "quest_template" and "ReqCreatureOrGOId1" in ix:
                q = int(num(f[ix["entry"]]))
                for i in range(1, 5):
                    v = int(num(f[ix[f"ReqCreatureOrGOId{i}"]]) or 0)
                    if v:
                        out["obj"].append((q, i - 1, "c" if v > 0 else "g", abs(v)))
            elif t == "quest_objectives":
                ty = int(num(f[ix["Type"]]))
                if ty in (0, 2):
                    v = int(num(f[ix["ObjectID"]]) or 0)
                    if v:
                        out["obj"].append((int(num(f[ix["QuestID"]])), int(num(f[ix["StorageIndex"]])), "c" if ty == 0 else "g", v))
    return out


def write(path, data, meta):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.unlink(missing_ok=True)
    db = sqlite3.connect(tmp)
    db.executescript("""create table spawn(kind text, entry int, map int, x real, y real);
        create table rel(kind text, entry int, quest int, role text);
        create table obj(quest int, idx int, kind text, entry int);
        create table meta(key text primary key, value text);""")
    db.executemany("insert into spawn values (?,?,?,?,?)", data["spawn"])
    db.executemany("insert into rel values (?,?,?,?)", sorted(set(data["rel"])))
    db.executemany("insert into obj values (?,?,?,?)", sorted(set(data["obj"])))
    db.executemany("insert into meta values (?,?)", meta.items())
    db.executescript("create index s_e on spawn(kind, entry); create index r_q on rel(quest, role); "
                     "create index o_q on obj(quest);")
    db.commit()
    db.execute("vacuum")
    db.close()
    tmp.replace(path)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("repo")
    ap.add_argument("commit")
    ap.add_argument("dump")
    ap.add_argument("--out")
    a = ap.parse_args(argv)
    data = extract(a.dump)
    out = Path(a.out) if a.out else ROOT / "tools" / "db2" / "emu" / f"{a.source}.sqlite"
    write(out, data, {"repo": a.repo, "commit": a.commit, "file": Path(a.dump).name})
    print(f"{a.source}: spawns {len(data['spawn'])}, relations {len(set(data['rel']))}, objectives "
          f"{len(set(data['obj']))} -> {out}")


if __name__ == "__main__":
    sys.exit(main())
