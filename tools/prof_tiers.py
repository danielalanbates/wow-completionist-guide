#!/usr/bin/env python3
# CompletionRoute :: tools/prof_tiers.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Profession x expansion-tier table per client, from the prof_guides rows tools/wiki/gen_professions.py writes.

    python3 tools/prof_tiers.py [--label before|after] [--markdown] [--thin]

One row per (client, profession, tier).  "reached" is the highest skill a guide of that tier gets to for the weaker
faction (a tier is only as good as its worse side), "cap" the tier's top (wiki proficiency tables, gen_professions
TIER_CAP / RANK_COUNT), "trainers" the most trainer points any band lists, "missing" the facts the guides say they lack.
--label also stores the table in docs/verification.sqlite `prof_tier_runs` (label, flavor, profession, tier, ...).
--thin prints only the tiers that stop short of their cap or list no trainer.
"""
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools" / "wiki"))
import db2_fetch as D  # noqa: E402
import gen_professions as GP  # noqa: E402

VERIF = ROOT / "docs" / "verification.sqlite"


def tier_names():
    out = {}
    for r in D.rows("retail", "SkillLine"):
        if r["ParentSkillLineID"] in ("185", "356") and r["CategoryID"] == "9":
            out[int(r["ID"])] = r["DisplayName_lang"]
    return out


def expected(fl, prof, tid, names):
    """every tier a client should have a guide for: (tier id, name, cap)"""
    if fl == "retail" and prof in GP.TIER_CAP:
        for i, nm in sorted(names.items()):
            if nm.endswith(prof):
                for prefix, cap in GP.TIER_CAP[prof].items():
                    if nm.startswith(prefix):
                        yield i, nm, cap
        return
    if prof == "Archaeology":
        yield 0, "Archaeology", GP.ARCH_BANDS[fl][-1][1]
        return
    yield 0, prof, GP.RANK_COUNT.get(fl, 4) * 75


def table(con):
    names = tier_names()
    rows = {}
    for fl, gid, prof, tier, lo, hi, steps, trainers, recipes, missing in con.execute(
            "select flavor, id, profession, tier, skill_min, skill_max, steps, trainers, recipes, missing_facts from prof_guides"):
        fac = gid.rsplit(":", 1)[-1]
        k = (fl, prof, tier)
        r = rows.setdefault(k, {"reach": {}, "guides": 0, "trainers": 0, "missing": 0, "steps": 0})
        r["reach"][fac] = max(r["reach"].get(fac, 0), hi)
        r["guides"] += 1
        r["trainers"] = max(r["trainers"], trainers or 0)
        r["missing"] += missing or 0
        r["steps"] += steps or 0
    out = []
    for fl in GP.FLAVORS:
        for prof in GP.PROFS[fl]:
            for tid, nm, cap in expected(fl, prof, None, names):
                r = rows.get((fl, prof, tid))
                reach = min(r["reach"].get("Alliance", 0), r["reach"].get("Horde", 0)) if r else 0
                out.append(dict(flavor=fl, profession=prof, tier=tid, name=nm, cap=cap, reached=reach,
                                guides=r["guides"] if r else 0, steps=r["steps"] if r else 0,
                                trainers=r["trainers"] if r else 0, missing=r["missing"] if r else 0))
    return out


def main():
    con = sqlite3.connect(VERIF)
    t = table(con)
    if "--label" in sys.argv:
        label = sys.argv[sys.argv.index("--label") + 1]
        con.execute("create table if not exists prof_tier_runs (label text, flavor text, profession text, tier int, name text, "
                    "cap int, reached int, guides int, steps int, trainers int, missing int, measured text, "
                    "primary key (label, flavor, profession, tier))")
        con.execute("delete from prof_tier_runs where label = ?", (label,))
        con.executemany("insert into prof_tier_runs values (?,?,?,?,?,?,?,?,?,?,?,datetime('now'))",
                        [(label, r["flavor"], r["profession"], r["tier"], r["name"], r["cap"], r["reached"], r["guides"],
                          r["steps"], r["trainers"], r["missing"]) for r in t])
        con.commit()
    if "--thin" in sys.argv:
        t = [r for r in t if r["reached"] < r["cap"] or r["trainers"] == 0]
    heads = ["flavor", "profession", "name", "reached", "cap", "guides", "steps", "trainers", "missing"]
    if "--markdown" in sys.argv:
        print("| " + " | ".join(heads) + " |")
        print("|" + "---|" * len(heads))
        for r in t:
            print("| " + " | ".join(str(r[h]) for h in heads) + " |")
        return
    w = {h: max(len(h), *(len(str(r[h])) for r in t)) for h in heads} if t else {h: len(h) for h in heads}
    print("  ".join(h.ljust(w[h]) for h in heads))
    for r in t:
        print("  ".join(str(r[h]).ljust(w[h]) for h in heads))


if __name__ == "__main__":
    main()
