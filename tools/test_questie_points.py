#!/usr/bin/env python3
# CompletionRoute :: tools/test_questie_points.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""tools/questie: row import (build_questie) and the quest-database rung (questie_points) on a tiny fixture."""
import sqlite3
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "questie"))
import build_questie as B  # noqa: E402
import questie_points as QP  # noqa: E402

ROWS = """rel\t7\tstart\tc\t100\t0
rel\t7\tend\tc\t200\t0
rel\t8\tstart\tc\t300\t0
obj\t7\t0\tc\t200\t0
obj\t7\t1\tc\t400\t55
obj\t7\t1\tc\t401\t55
obj\t7\t2\tt\t7\t0
spawn\tc\t100\t10\t40.00\t40.00
spawn\tc\t100\t10\t42.00\t44.00
spawn\tc\t100\t10\t90.00\t90.00
spawn\tc\t200\t10\t10.00\t10.00
spawn\tc\t300\t10\t5.00\t5.00
spawn\tc\t300\t20\t5.00\t5.00
spawn\tc\t400\t10\t70.00\t70.00
spawn\tc\t401\t10\t30.00\t30.00
spawn\tc\t401\t10\t31.00\t31.00
spawn\tc\t401\t10\t60.00\t60.00
spawn\tc\t401\t11\t50.00\t50.00
spawn\tt\t7\t10\t25.00\t75.00
spawn\tc\t100\t99\t1.00\t1.00
"""


class Maps:
    """zone 10 (100x100 yd at world 0,0, instance 0), its subzone 11 (the 50x50 yd middle), zone 20 elsewhere"""
    maps = {10: {"name": "Testzone", "inst": 0, "topX": 0.0, "leftY": 0.0, "w": 100.0, "h": 100.0},
            11: {"name": "Subzone", "inst": 0, "topX": -25.0, "leftY": -25.0, "w": 50.0, "h": 50.0},
            20: {"name": "Otherzone", "inst": 1, "topX": 0.0, "leftY": 0.0, "w": 100.0, "h": 100.0}}

    def home(self, mid):
        return 10 if mid == 11 else mid

    def to_world(self, mid, x, y):
        m = self.maps[mid]
        return m["inst"], m["topX"] - y / 100 * m["h"], m["leftY"] - x / 100 * m["w"]


def main():
    fails = 0

    def check(name, got, want):
        nonlocal fails
        ok = got == want
        fails += not ok
        print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": got {got!r}, want {want!r}"))

    with tempfile.TemporaryDirectory() as td:
        rows = Path(td) / "r.tsv"
        rows.write_text(ROWS, encoding="utf-8")
        db = Path(td) / "fx.sqlite"
        check("import counts", B.build(rows, db, {"repo": "test/qdb", "commit": "c0ffee"}), (3, 4, 13))
        q = QP.QuestiePoints("era", Maps(), sources=["fx"], paths={"fx": db})
        L = "community quest database"
        check("giver: point nearest the median, unknown uiMap 99 ignored",
              q.fill_line("A Foo|QID|7|Z|10; Testzone|N|From Bar.|"),
              f"A Foo|QID|7|M|42.0,44.0|Z|10; Testzone|N|From Bar. (location: {L} spawn of npc 100)|")
        check("ender", q.fill_line("T Foo|QID|7|Z|10; Testzone|"),
              f"T Foo|QID|7|M|10.0,10.0|Z|10; Testzone|N|(location: {L} spawn of npc 200)|")
        check("item objective: the drop source with most in-zone points (subzone 50,50 -> zone 50,50 is the median)",
              q.fill_line("C Foo|QID|7|QO|2|Z|10; Testzone|N|Loot.|"),
              f"C Foo|QID|7|QO|2|M|50.0,50.0|Z|10; Testzone|N|Loot. (location: {L} spawn of npc 401, drops item 55)|")
        check("explore objective area", q.fill_line("C Foo|QID|7|QO|3|Z|10; Testzone|"),
              f"C Foo|QID|7|QO|3|M|25.0,75.0|Z|10; Testzone|N|(location: {L} spawn of quest area 7)|")
        check("wrong zone refused", q.fill_line("A Foo|QID|7|Z|20; Otherzone|"), None)
        check("no zone, two zones refused", q.fill_line("A Qux|QID|8|N|x|"), None)
        check("no zone, one zone adds |M| and |Z|", q.fill_line("T Foo|QID|7|LVL|3|"),
              f"T Foo|QID|7|M|10.0,10.0|Z|10; Testzone|LVL|3|N|(location: {L} spawn of npc 200)|")
        check("point kept", q.fill_line("A Foo|QID|7|M|1.0,1.0|Z|10; Testzone|"), None)
        check("counts", (q.n_zone, q.n_none, q.n_item, len(q.placed)), (4, 1, 1, 5))
        check("the database name never reaches a guide line", "questie" in " ".join(q.header()).lower(), False)
        con = sqlite3.connect(":memory:")
        q.chart(con, "f.lua")
        check("chart rows: source, commit, item", con.execute(
            "select count(*), min(source), min(commit_sha), max(via_item) from questie_points").fetchone(),
            (5, "test/qdb", "c0ffee", 55))
        q.sources[0].db.close()
    print("all questie tests passed" if not fails else f"{fails} questie test(s) FAILED")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
