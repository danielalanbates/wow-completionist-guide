#!/usr/bin/env python3
# CompletionRoute :: tools/coverage.py
# Copyright (c) 2026 Daniel Bates / BatesAI. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Measure guide coverage per flavor against the client's own lists and chart it in SQL.

    python3 tools/coverage.py [--label before|after] [--guides DIR]

Universe (the "total" column), per flavor, from wago.tools DB2 exports cached in tools/db2/<flavor>/:
  quest        QuestV2.csv                       every quest id the client knows (incl. hidden trackers)
  achievement  Achievement.csv minus statistics  (Flags & 0x1 = counter/statistic, not an achievement)
  storyline    QuestLine x QuestLineXQuest       retail only; covered = every quest of the line is in a guide
  mission      GarrMission.csv                   retail only; covered = a guide step carries |MISSION|id|
  item-quest   tools/db2/<fl>/item_quests.tsv    quests Questie says are started by an item
                                                 (written by tools/gen_quest_guides.lua; retail uses the MoP
                                                 list intersected with retail QuestV2)
"covered" = the id appears in a guide the flavor's client loads.  "located" = at least one of those steps
has map coordinates, i.e. the router can actually take you there.  Both are reported because an id in a
guide with no location is a checklist line, not a route.

Writes tables `coverage` (flavor, category, label, total, covered, missing, located) and `coverage_missing`
(flavor, category, id) into docs/verification.sqlite; `coverage_missing` holds the latest run only.
"""
import csv, re, sqlite3, sys, collections
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DB2 = ROOT / "tools" / "db2"
FLAVORS = ["era", "tbc", "mop", "retail"]

# what each client loads (TOC order; Imported_Quests_<tier> files gate themselves on NS.flavor)
def guide_files(gdir, fl):
    names = [f"Imported_Zygor_{fl}.lua", f"Imported_WoWPro_{fl}.lua", f"Imported_Quests_{fl}.lua",
             f"Imported_Achievements_{fl}.lua", f"Imported_Storylines_{fl}.lua", f"Imported_Missions_{fl}.lua"]
    out = [gdir / n for n in names if (gdir / n).exists()]
    out += sorted((gdir / "Leveling").glob("*.lua"))
    return out

RE_QID = re.compile(r"\|QID\|([\d.^;&]+)")
RE_ACH = re.compile(r"\|ACH\|(\d+)")
RE_MIS = re.compile(r"\|MISSION\|(\d+)")
RE_ZY_Q = re.compile(r"(?:accept|turnin)\s[^\n|]*?##(\d+)|(?:^|\|)\s*q\s+(\d+)", re.M)
RE_ZY_A = re.compile(r"\bachieve\s+(\d+)")
RE_ZY_GOTO = re.compile(r"\bgoto\b|\|M\|")


def scan(path):
    """-> dict kind -> {id: located_bool}"""
    found = {"quest": {}, "achievement": {}, "mission": {}}
    txt = path.read_text(encoding="utf-8", errors="replace")
    zy = "Imported_Zygor_" in path.name
    if zy:
        # Zygor raw text: split into steps; a step is located when it has a goto
        for step in txt.split("step\\"):
            loc = "goto" in step
            for a, b in RE_ZY_Q.findall(step):
                q = int(a or b)
                found["quest"][q] = found["quest"].get(q, False) or loc
            for a in RE_ZY_A.findall(step):
                found["achievement"][int(a)] = found["achievement"].get(int(a), False) or loc
        return found
    for line in txt.splitlines():
        if "|" not in line:
            continue
        loc = "|M|" in line
        for m in RE_QID.findall(line):
            for part in re.split(r"[\^;&]", m):
                part = part.split(".")[0]
                if part.isdigit():
                    q = int(part)
                    found["quest"][q] = found["quest"].get(q, False) or loc
        for a in RE_ACH.findall(line):
            found["achievement"][int(a)] = found["achievement"].get(int(a), False) or loc
        for a in RE_MIS.findall(line):
            found["mission"][int(a)] = found["mission"].get(int(a), False) or loc
    return found


def read_csv(fl, table):
    p = DB2 / fl / f"{table}.csv"
    if not p.exists():
        return None
    return list(csv.DictReader(p.open(encoding="utf-8")))


def universes(fl):
    u = {}
    q = read_csv(fl, "QuestV2")
    if q is not None:
        u["quest"] = {int(r["ID"]) for r in q}
    a = read_csv(fl, "Achievement")
    if a is not None:
        u["achievement"] = {int(r["ID"]) for r in a if not (int(r["Flags"] or 0) & 0x1)}
    if fl == "retail":
        m = read_csv(fl, "GarrMission")
        if m is not None:
            u["mission"] = {int(r["ID"]) for r in m}
        qlx = read_csv(fl, "QuestLineXQuest")
        if qlx is not None:
            lines = collections.defaultdict(set)
            for r in qlx:
                lines[int(r["QuestLineID"])].add(int(r["QuestID"]))
            u["storyline"] = dict(lines)
    src = "mop" if fl == "retail" else fl
    it = DB2 / src / "item_quests.tsv"
    if it.exists():
        ids = {int(r["qid"]) for r in csv.DictReader(it.open(encoding="utf-8"), delimiter="\t") if r["qid"]}
        if fl == "retail" and "quest" in u:
            ids &= u["quest"]
        u["item-quest"] = ids
    return u


def main():
    label = "current"
    gdir = ROOT / "CompletionRoute" / "Guides"
    args = sys.argv[1:]
    if "--label" in args:
        label = args[args.index("--label") + 1]
    if "--guides" in args:
        gdir = Path(args[args.index("--guides") + 1])
    con = sqlite3.connect(ROOT / "docs" / "verification.sqlite")
    con.execute("""create table if not exists coverage (flavor text, category text, label text, total int,
                   covered int, missing int, located int, measured text, primary key (flavor, category, label))""")
    con.execute("create table if not exists coverage_missing (flavor text, category text, id int)")
    con.execute("delete from coverage_missing")
    for fl in FLAVORS:
        have = {"quest": {}, "achievement": {}, "mission": {}}
        for f in guide_files(gdir, fl):
            for k, d in scan(f).items():
                for i, loc in d.items():
                    have[k][i] = have[k].get(i, False) or loc
        for cat, uni in universes(fl).items():
            if cat == "storyline":
                total = len(uni)
                cov = [l for l, qs in uni.items() if qs and all(q in have["quest"] for q in qs)]
                loc = [l for l in cov if all(have["quest"][q] for q in uni[l])]
                miss = sorted(set(uni) - set(cov))
            else:
                key = "quest" if cat == "item-quest" else cat
                total = len(uni)
                cov = [i for i in uni if i in have[key]]
                loc = [i for i in cov if have[key][i]]
                miss = sorted(uni - set(cov))
            con.execute("insert or replace into coverage values (?,?,?,?,?,?,?,datetime('now'))",
                        (fl, cat, label, total, len(cov), total - len(cov), len(loc)))
            con.executemany("insert into coverage_missing values (?,?,?)", [(fl, cat, i) for i in miss])
            print(f"{label:7} {fl:6} {cat:11} total {total:6}  covered {len(cov):6} ({100*len(cov)/max(total,1):5.1f}%)"
                  f"  located {len(loc):6}")
    con.commit()


if __name__ == "__main__":
    main()
