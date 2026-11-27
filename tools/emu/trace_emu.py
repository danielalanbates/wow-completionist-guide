#!/usr/bin/env python3
# CompletionRoute :: tools/emu/trace_emu.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Review only: trace N random emulator-placed steps per guide file back to the source row.

    python3 tools/emu/trace_emu.py [--n 25] [--seed 1127] FLAVOR:GUIDEFILE.lua ...

Per step: (1) the npc/object is a starter (A), ender (T) or objective target (C) of the quest in the source named by
the note; (2) one of its spawns converts (the map's own rectangle) to the step's |M| within 0.15 map units; (3) the
point's map is the step's |Z| zone or a map inside it; (4) where the wiki has coordinates for the same npc id in the
same zone, the distance is reported (spot check, not a pass/fail rule: the wiki may give another spawn).
"""
import math
import random
import re
import sqlite3
import sys
from pathlib import Path

sys.path[:0] = [str(Path(__file__).resolve().parents[1] / "wiki"), str(Path(__file__).resolve().parent)]
import wikimaps  # noqa: E402
import emu_points as EP  # noqa: E402

TAG = re.compile(r"\(location: (\S+) spawn of (npc|object) (\d+)\)")
M = re.compile(r"\|M\|([\d.]+),([\d.]+)")
REPO_SRC = {}


def main(argv):
    n, seed, jobs = 25, 1127, []
    it = iter(argv)
    for a in it:
        if a == "--n":
            n = int(next(it))
        elif a == "--seed":
            seed = int(next(it))
        else:
            jobs.append(a.split(":", 1))
    atlas = wikimaps.Atlas()
    wiki = sqlite3.connect(Path(EP.ROOT) / "tools" / "wiki" / "wiki.sqlite")
    bad = 0
    for fl, path in jobs:
        maps = atlas.sets[fl]
        srcs = {s.repo: s for s in (EP.Source(nm) for nm in EP.SOURCES[fl])}
        lines = [ln for ln in Path(path).read_text(encoding="utf-8").splitlines() if TAG.search(ln) and EP.STEP.match(ln)]
        rnd = random.Random(seed)
        sample = rnd.sample(lines, min(n, len(lines)))
        ok = wk = 0
        dists = []
        for ln in sample:
            act, qid = EP.STEP.match(ln).group(1), int(EP.STEP.match(ln).group(2))
            repo, what, entry = TAG.search(ln).groups()
            kind, entry = ("c" if what == "npc" else "g"), int(entry)
            mx, my = map(float, M.search(ln).groups())
            z = EP.ZONE.search(ln)
            zmid, zname = int(z.group(1)), z.group(2)
            src = srcs[repo]
            if act in "AT":
                rel = src.db.execute("select 1 from rel where quest=? and role=? and kind=? and entry=?",
                                     (qid, "start" if act == "A" else "end", kind, entry)).fetchone()
            else:
                rel = src.db.execute("select 1 from obj where quest=? and kind=? and entry=?", (qid, kind, entry)).fetchone()
            hit = None
            for inst, wx, wy in src.spawns(kind, entry):
                for mid in {zmid} | {i for i in maps.by_inst.get(inst, []) if maps.home(i) == zmid}:
                    m = maps.maps.get(mid)
                    if not m or m["inst"] != inst or not m["w"]:
                        continue
                    x, y = (m["leftY"] - wy) / m["w"] * 100, (m["topX"] - wx) / m["h"] * 100
                    if abs(x - mx) <= 0.15 and abs(y - my) <= 0.15:
                        hit = mid
            zone_ok = hit is not None and (hit == zmid or maps.home(hit) == zmid)
            good = bool(rel) and hit is not None and zone_ok
            ok += good
            if not good:
                bad += 1
                print(f"  FAIL {fl} {act} q{qid} {what} {entry} rel={bool(rel)} spawn={hit} zone_ok={zone_ok} :: {ln[:160]}")
            if what == "npc":
                r = wiki.execute("select x, y, zone from npcs where npc_id=? and x is not null", (str(entry),)).fetchone()
                if r and r[2] and r[2].lower() == zname.lower():
                    wk += 1
                    dists.append(math.hypot(r[0] - mx, r[1] - my))
        dists.sort()
        med = f"{dists[len(dists) // 2]:.1f}" if dists else "-"
        print(f"{fl:7} {Path(path).name}: {ok}/{len(sample)} traced ok (of {len(lines)} emu steps); wiki same-npc same-zone "
              f"{wk}: median {med}, within 3 units {sum(d <= 3 for d in dists)}, max {dists[-1] if dists else 0:.1f}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
