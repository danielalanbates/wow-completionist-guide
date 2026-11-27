#!/usr/bin/env python3
# CompletionRoute :: tools/test_emu_points.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""tools/emu: dump parsing (extract_emu) and the spawn rung (emu_points) on a tiny fixture, no network or db2 needed."""
import gzip
import sqlite3
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "emu"))
import extract_emu as X  # noqa: E402
import emu_points as EP  # noqa: E402

DUMP = """CREATE TABLE `creature` (
  `guid` int unsigned NOT NULL,
  `id` mediumint unsigned NOT NULL,
  `map` smallint unsigned NOT NULL,
  `spawnDifficulties` varchar(100) NOT NULL,
  `position_x` float NOT NULL,
  `position_y` float NOT NULL,
  PRIMARY KEY (`guid`)
) ENGINE=MyISAM;
INSERT INTO `creature` VALUES (1,100,0,'0,1',-50,-50),(2,100,0,'0',-52,-48),(3,100,0,'0',-90,-90),(4,200,0,'',-10,-10),(5,300,0,'',-10,-10),(6,300,1,'',-10,-10);
CREATE TABLE `creature_questrelation` (
  `id` int NOT NULL,
  `quest` int NOT NULL
);
INSERT INTO `creature_questrelation` VALUES (100,7),(300,9);
CREATE TABLE `creature_involvedrelation` (
  `id` int NOT NULL,
  `quest` int NOT NULL
);
INSERT INTO `creature_involvedrelation` VALUES (200,7);
CREATE TABLE `quest_template` (
  `entry` int NOT NULL,
  `Title` text,
  `ReqCreatureOrGOId1` int NOT NULL,
  `ReqCreatureOrGOId2` int NOT NULL,
  `ReqCreatureOrGOId3` int NOT NULL,
  `ReqCreatureOrGOId4` int NOT NULL
);
INSERT INTO `quest_template` VALUES (7,'A (tricky), title',0,200,-55,0);
"""


class Maps:
    """two 100x100-yard zones: map 10 on instance 0 (world x,y in [-100,0]), map 20 on instance 1"""
    maps = {10: {"name": "Testzone", "inst": 0, "topX": 0.0, "leftY": 0.0, "w": 100.0, "h": 100.0},
            20: {"name": "Otherzone", "inst": 1, "topX": 0.0, "leftY": 0.0, "w": 100.0, "h": 100.0}}

    def from_world(self, inst, wx, wy, prefer_name=None):
        mid = 10 if inst == 0 else 20
        m = self.maps[mid]
        return mid, (m["leftY"] - wy) / m["w"] * 100, (m["topX"] - wx) / m["h"] * 100

    def home(self, mid):
        return mid


def main():
    fails = 0

    def check(name, got, want):
        nonlocal fails
        ok = got == want
        fails += not ok
        print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": got {got!r}, want {want!r}"))

    with tempfile.TemporaryDirectory() as td:
        dump = Path(td) / "t.sql.gz"
        with gzip.open(dump, "wt") as f:
            f.write(DUMP)
        data = X.extract(dump)
        check("spawns parsed (quoted commas)", len(data["spawn"]), 6)
        check("relations", sorted(set(data["rel"])), [("c", 100, 7, "start"), ("c", 200, 7, "end"), ("c", 300, 9, "start")])
        check("objectives (negative = object)", sorted(data["obj"]), [(7, 1, "c", 200), (7, 2, "g", 55)])
        X.write(Path(td) / "fx.sqlite", data, {"repo": "test/db", "commit": "abc123"})
        EP.EMU = Path(td)
        e = EP.EmuPoints("era", Maps(), sources=["fx"])
        ln = e.fill_line("A Foo|QID|7|Z|10; Testzone|LVL|5|N|From Bar.|")
        check("giver: spawn nearest the median (tie -> lower x), before |Z|", ln,
              "A Foo|QID|7|M|48.0,52.0|Z|10; Testzone|LVL|5|N|From Bar. (location: test/db spawn of npc 100)|")
        check("ender placed", e.fill_line("T Foo|QID|7|Z|10; Testzone|N|To Baz.|"),
              "T Foo|QID|7|M|10.0,10.0|Z|10; Testzone|N|To Baz. (location: test/db spawn of npc 200)|")
        check("wrong zone refused", e.fill_line("A Foo|QID|7|Z|20; Otherzone|N|x|"), None)
        check("no zone, spawns in two zones refused", e.fill_line("A Qux|QID|9|N|x|"), None)
        check("no zone, one zone: |M| and |Z| added", e.fill_line("T Foo|QID|7|LVL|5|"),
              "T Foo|QID|7|M|10.0,10.0|Z|10; Testzone|LVL|5|N|(location: test/db spawn of npc 200)|")
        check("objective target", e.fill_line("C Foo|QID|7|QO|1|Z|10; Testzone|N|Kill.|"),
              "C Foo|QID|7|QO|1|M|10.0,10.0|Z|10; Testzone|N|Kill. (location: test/db spawn of npc 200)|")
        check("line with a point untouched", e.fill_line("A Foo|QID|7|M|1.0,1.0|Z|10; Testzone|"), None)
        check("counts", (e.n_zone, e.n_none, len(e.placed)), (3, 1, 4))
        con = sqlite3.connect(":memory:")
        e.chart(con, "f.lua")
        check("chart rows carry source + commit", con.execute("select count(*), min(source), min(commit_sha) from emu_points")
              .fetchone(), (4, "test/db", "abc123"))
        e.sources[0].db.close()
    print("all emu tests passed" if not fails else f"{fails} emu test(s) FAILED")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
