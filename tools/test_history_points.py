#!/usr/bin/env python3
# CompletionRoute :: tools/test_history_points.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Offline checks for points recovered from pre-4.0.3 wiki revisions (tools/wiki/fetch_coord_history.py --recover,
wikimaps.history_points, gen_wiki_guides.py).  No network: the parser runs on fixture text, the table on a temp file.
When the generated Classic guides are present it also checks their provenance notes.

    python3 tools/test_history_points.py
"""
import re
import sqlite3
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools" / "wiki"))
import fetch_coord_history as F  # noqa: E402
import wikimaps  # noqa: E402

fails = 0


def check(ok, what):
    global fails
    print(("  ok   " if ok else "  FAIL ") + what)
    fails += 0 if ok else 1


OLD = """{{Npcbox
| name = Example Giver
| location = [[Southshore]], [[Hillsbrad Foothills]] {{coords|49.2|58.6|Hillsbrad Foothills}}
}}
'''Example Giver''' stands by the inn {{co|50|57|Hillsbrad Foothills}}.
== Spawns ==
{{Zone Map|zone=Stranglethorn Vale|notes=
  {{Zone Map Note|29.6|80.8|Blip}}
  {{Zone Map Note|27,2|82.7|Blip|Example}}
  {{Zone Map Note|bad|1|Blip}}
}}
"""

pts = F.old_points("Example Giver", OLD)
check(("Hillsbrad Foothills", 49.2, 58.6, "location") in pts, "infobox {{coords}} on the old revision is kept as 'location'")
check(("Hillsbrad Foothills", 50.0, 57.0, "lead") in pts, "lead {{co}} is kept as 'lead'")
check(("Stranglethorn Vale", 29.6, 80.8, "zonemap") in pts and ("Stranglethorn Vale", 27.2, 82.7, "zonemap") in pts,
      "Zone Map Note blips take the Zone Map's zone (decimal comma read)")
check(sum(1 for p in pts if p[3] == "zonemap") == 2, "a blip without numbers is skipped")
many = "{{Zone Map|zone=Durotar|notes=" + "".join(f"{{{{Zone Map Note|{i}|{i}|Blip}}}}" for i in range(1, 40)) + "}}"
check(sum(1 for p in F.old_points("Mob", many) if p[3] == "zonemap") == F.MAX_BLIPS, f"at most {F.MAX_BLIPS} blips per page")
check(F.old_points("Empty", "no coordinates here") == [], "a revision with no coordinates gives nothing")

with tempfile.TemporaryDirectory() as td:
    p = Path(td) / "h.sqlite"
    db = sqlite3.connect(p)
    db.execute("create table history_points(title text, zone text, x real, y real, source text, revid int, rev_time text, "
               "checked text, primary key (title, zone, x, y))")
    db.execute("insert into history_points values ('A','Duskwood',33.4,76.3,'location',2539800,'2010-01-01','now')")
    db.commit()
    db.close()
    hp = wikimaps.history_points(p)
    check(hp == {"A": [("Duskwood", 33.4, 76.3, "location", 2539800)]}, "wikimaps.history_points reads the table")
    check(wikimaps.history_points(Path(td) / "missing.sqlite") == {}, "a missing table file reads as empty")

RE_REV = re.compile(r"\(location: wiki revision (\d+)\)")
for fl in ("era", "tbc", "forever", "mop", "retail"):
    f = ROOT / "CompletionRoute" / "Guides" / f"Imported_Wiki_{fl}.lua"
    if not f.exists():
        print(f"  skip {f.name} not generated")
        continue
    lines = [ln for ln in f.read_text(encoding="utf-8").splitlines() if RE_REV.search(ln)]
    if fl in ("mop", "retail"):
        check(not lines, f"{fl}: no step takes a pre-4.0.3 point (its maps are the Cataclysm ones)")
        continue
    if not wikimaps.history_points():
        print(f"  skip {fl}: tools/wiki/cache/coord_history.sqlite has no history_points")
        continue
    check(len(lines) >= 100, f"{fl}: at least 100 steps carry a pre-4.0.3 revision point ({len(lines)})")
    check(all("|M|" in ln for ln in lines), f"{fl}: every such step has a map point")
    revs = {int(m.group(1)) for ln in lines for m in RE_REV.finditer(ln)}
    known = {r for v in wikimaps.history_points().values() for *_x, r in v}
    check(revs <= known, f"{fl}: every revision id named is one the table recorded")

print("test_history_points: " + ("passed" if not fails else f"FAILED, {fails} check(s)"))
sys.exit(1 if fails else 0)
