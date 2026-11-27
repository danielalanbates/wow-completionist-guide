#!/usr/bin/env python3
# CompletionRoute :: tools/questie/trace_questie.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Review only: trace N random quest-database steps per guide file back to the source rows.

    python3 tools/questie/trace_questie.py [--n 25] [--seed 1127] FLAVOR:GUIDEFILE.lua ...

Per step: the npc/object/area is linked to the quest in the role the step needs (A start, T end, C objective; an item
drop source for "drops item"), one of its points (or its subzone point converted) is the step's |M| within 0.15, and
the point's map is the step's zone.
"""
import random
import re
import sys
from pathlib import Path

sys.path[:0] = [str(Path(__file__).resolve().parents[1] / "wiki"), str(Path(__file__).resolve().parent)]
import wikimaps  # noqa: E402
import questie_points as QP  # noqa: E402
import emu_points as EP  # noqa: E402

TAG = re.compile(r"\(location: community quest database spawn of (npc|object|quest area) (\d+)(?:, drops item (\d+))?\)")
M = re.compile(r"\|M\|([\d.]+),([\d.]+)")


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
    bad = total = 0
    for fl, path in jobs:
        q = QP.QuestiePoints(fl, atlas.sets[fl])
        lines = [ln for ln in Path(path).read_text(encoding="utf-8").splitlines() if TAG.search(ln) and EP.STEP.match(ln)]
        sample = random.Random(seed).sample(lines, min(n, len(lines)))
        ok = 0
        for ln in sample:
            act, qid = EP.STEP.match(ln).group(1), int(EP.STEP.match(ln).group(2))
            what, entry, via = TAG.search(ln).groups()
            kind, entry, via = {"npc": "c", "object": "g", "quest area": "t"}[what], int(entry), int(via or 0)
            mx, my = map(float, M.search(ln).groups())
            zmid = int(EP.ZONE.search(ln).group(1))
            good = False
            for src in q.sources:
                if act in "AT":
                    linked = src.db.execute("select 1 from rel where quest=? and role=? and kind=? and entry=? and via=?",
                                            (qid, "start" if act == "A" else "end", kind, entry, via)).fetchone()
                else:
                    linked = src.db.execute("select 1 from obj where quest=? and kind=? and entry=? and via=?",
                                            (qid, kind, entry, via)).fetchone()
                if not linked:
                    continue
                for (mid, x, y), _ in q.in_zone(src, kind, entry, zmid):
                    if mid == zmid and abs(x - mx) <= .15 and abs(y - my) <= .15:
                        good = True
                if good:
                    break
            ok += good
            if not good:
                print(f"  BAD {fl} {ln[:160]}")
        print(f"{fl} {Path(path).name}: {ok}/{len(sample)} traced")
        total += len(sample)
        bad += len(sample) - ok
    print(f"traced {total - bad}/{total}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
