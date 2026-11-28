#!/usr/bin/env python3
# CompletionRoute :: tools/test_att_points.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""tools/att: the extractor (extract_att.lua, on a tiny folder in the compiled db/ format), the import (build_att) and
the community collection database rung (att_points) for quest and achievement steps."""
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "att"))
sys.path.insert(0, str(HERE))
import att_points as AP  # noqa: E402
import build_att as B  # noqa: E402
from test_questie_points import Maps  # noqa: E402

ZONES = """﻿if not (not C_Seasons or C_Seasons.GetActiveSeason() ~= 2) then return end
local appName, _ = ...
_.AddEventHandler("OnBuildDataCache", function(categories)
local ach,crit,h,n,o,q,qo=_.CreateAchievement,_.CreateAchievementCriteria,_.CreateHeader,_.CreateNPC,_.CreateObject,_.CreateQuest,_.CreateQuestObjective;
local hook = _.OnTooltipDB.Something
categories.Zones=
h(-1,{mapID=10,g={
h(-2,{
n(100,{coords={[10]={{40,40},{42,44},{90,90}},[99]={{1,1}}}}),
q(7,{coords={[10]={{12,12}}},qgs={100},g={
qo(1,{coords={[10]={{25,75}}}}),
qo(2,{crs={100}})}}),
q(8,{coords={[10]={{33,33}}}}),
q(9,{coords={[10]={{5,5}}},g={}})}),
n(300,{coords={[20]={{5,5}}},g={q(11,{})}}),
q(12,_.ResolveQuestData({aqd={coords={[10]={{1,1}}},qgs={100}},hqd={coords={[10]={{2,2}}}}})),
ach(50,{g={crit(1,{achID=50,coords={[10]={{60,60}}}}),crit(2,{achID=50,coords={[10]={{64,62}}}})}}),
ach(51,{coords={[10]={{10,10}}},g={crit(1,{achID=51,coords={[10]={{90,90}}}})}}),
ach(52,{g={crit(1,{achID=52,providers={{"n",300}}})}}),
ach(53,{g={crit(1,{achID=53,coords={[10]={{50,50}},[20]={{50,50}}}})}})}});
end);
"""
NEVER = """local appName, _ = ...
_.AddEventHandler("OnBuildDataCache", function(categories)
categories.NeverImplemented=_.CreateQuest(7,{coords={[20]={{9,9}}}});
end);
"""


def main():
    fails = 0

    def check(name, got, want):
        nonlocal fails
        ok = got == want
        fails += not ok
        print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": got {got!r}, want {want!r}"))

    lua = shutil.which("lua")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td) / "Vanilla"
        (d / "Categories").mkdir(parents=True)
        (d / "Database.xml").write_text('<Ui><Script file="LocalizationDB.lua"/><Script file="Categories/NeverImplemented.lua"/>'
                                        '<Script file="Categories/Zones.lua"/></Ui>', encoding="utf-8")
        (d / "Categories" / "Zones.lua").write_text(ZONES, encoding="utf-8")
        (d / "Categories" / "NeverImplemented.lua").write_text(NEVER, encoding="utf-8")
        rows = Path(td) / "r.tsv"
        if not lua:
            print("lua (5.4+) not installed: extractor test skipped")
            return 0
        r = subprocess.run([lua, str(HERE / "att" / "extract_att.lua"), str(d), str(rows)], capture_output=True, text=True)
        check("extractor runs", (r.returncode, r.stderr if r.returncode else ""), (0, ""))
        got = set(rows.read_text(encoding="utf-8").splitlines())
        check("giver from qgs", "rel\t7\tstart\tc\t100\t0" in got, True)
        check("quest start coords", {"rel\t8\tstart\tq\t8\t0", "spawn\tq\t8\t10\t33.00\t33.00"} <= got, True)
        check("giver = the npc the quest sits under", "rel\t11\tstart\tc\t300\t0" in got, True)
        check("objective coords and objective npc", {"obj\t7\t0\ta\t700\t0", "obj\t7\t1\tc\t100\t0"} <= got, True)
        check("per-faction data not read", any("\t12\t" in g for g in got), False)
        check("never-implemented category skipped", any(g.startswith("spawn\tq\t7\t20\t") for g in got), False)
        db = Path(td) / "fx.sqlite"
        n = B.build(rows, db, {"repo": "test/att", "commit": "c0ffee"})
        check("import has achievements", (n[3] > 0, n[4]), (True, 1))
        a = AP.ATTPoints("era", Maps(), sources=["fx"], paths={"fx": db})
        L = "community database"
        check("giver npc: point nearest the median, unknown uiMap ignored", a.fill_line("A Foo|QID|7|Z|10; Testzone|N|x|"),
              f"A Foo|QID|7|M|42.0,44.0|Z|10; Testzone|N|x (location: {L} spawn of npc 100)|")
        check("quest start coords when no giver", a.fill_line("A Bar|QID|8|Z|10; Testzone|"),
              f"A Bar|QID|8|M|33.0,33.0|Z|10; Testzone|N|(location: {L} start of quest 8)|")
        check("objective coords", a.fill_line("C Foo|QID|7|QO|1|Z|10; Testzone|"),
              f"C Foo|QID|7|QO|1|M|25.0,75.0|Z|10; Testzone|N|(location: {L} objective 1 of quest 7)|")
        check("no enders: T untouched", a.fill_line("T Foo|QID|7|Z|10; Testzone|"), None)
        check("wrong zone refused", a.fill_line("A Baz|QID|11|Z|10; Testzone|"), None)
        check("achievement: close criteria -> nearest the median", a.ach_point(50)[:3], (10, 64, 62))
        check("achievement: spread too wide refused", a.ach_point(51), None)
        check("achievement: criterion npc spawns", a.ach_point(52)[:3], (20, 5, 5))
        check("achievement: two zones refused", a.ach_point(53), None)
        check("achievement: kept inside the step zone", a.ach_point(53, 20)[:3], (20, 50, 50))
        check("the database name never reaches a guide line",
              any(w in " ".join(a.header()).lower() for w in ("allthethings", "all the things", "att ")), False)
        con = sqlite3.connect(":memory:")
        a.chart(con, "f.lua")
        check("chart rows: source, commit", con.execute(
            "select count(*), min(source), min(commit_sha) from att_points").fetchone(), (len(a.placed), "test/att", "c0ffee"))
        a.sources[0].db.close()
    print("all att tests passed" if not fails else f"{fails} att test(s) FAILED")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
