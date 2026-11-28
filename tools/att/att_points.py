# CompletionRoute :: tools/att/att_points.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Rung after the community quest database (tools/questie/questie_points.py): steps still without a point take the
giver's or objective's position from the MIT community collection database (credited in CREDITS.md and
docs/EMU_DATA.md; tools/att/fetch_att.sh -> extract_att.lua -> build_att.py -> tools/db2/att/<source>.sqlite).

Quest steps use the same rules as the quest-database rung (same tables): A = the quest's giver npc/object spawns, else
the quest's own start coordinates; C = the objective's npcs/objects, else its own coordinates.  It has no quest
enders, so T steps are left alone.
Achievement steps (ach_point): the achievement's and its criteria's coordinates (and the spawns of criterion npcs /
objects without coordinates) are used only when they all lie on one zone (the step zone, when it has one) within
SPREAD map units of their median: the point nearest the median.
The add-on UI never names the database; the note says "(location: community database ...)", and every value is
charted with repo + commit in docs/verification.sqlite att_points.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "questie"))
import questie_points as QP  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
ADB = ROOT / "tools" / "db2" / "att"
SOURCES = {"era": ["vanilla"], "forever": ["camelot", "vanilla"], "tbc": ["tbc"], "mop": ["mists"],
           "retail": ["standard"]}
LABEL = "community database"
SPREAD = 10.0


class ATTPoints(QP.QuestiePoints):
    LABEL, TABLE, DIR, SOURCES = LABEL, "att_points", ADB, SOURCES
    WHAT = {"c": "npc", "g": "object", "q": "quest start", "a": "objective area"}

    def fill_line(self, line):
        if isinstance(line, str) and line.startswith("T "):
            return None         # no quest enders in this database
        out = super().fill_line(line)
        if out:
            out = re.sub(r"spawn of quest start (\d+)\)", r"start of quest \1)", out)
            out = re.sub(r"spawn of objective area (\d+)\)",
                         lambda m: f"objective {int(m.group(1)) % 100 + 1} of quest {int(m.group(1)) // 100})", out)
        return out

    def ach_point(self, aid, zmid=None):
        """-> (mid, x, y, source) or None"""
        for src in self.sources:
            raw = src.db.execute("select map, x, y from ach where ach=?", (aid,)).fetchall()
            for kind, entry in src.db.execute("select kind, entry from achvia where ach=?", (aid,)).fetchall():
                raw += src.points(kind, entry)
            pts = []
            for mid, x, y in raw:
                if mid not in self.maps.maps:
                    continue
                if zmid is not None and mid != zmid:
                    w = self.maps.home(mid) == zmid and self.maps.to_world(mid, x, y)
                    r = w and self.on_map(zmid, *w)
                    if not r:
                        continue
                    mid, x, y = r
                pts.append((mid, x, y))
            if not pts or len({p[0] for p in pts}) != 1:
                continue
            xs, ys = sorted(p[1] for p in pts), sorted(p[2] for p in pts)
            mx, my = xs[len(xs) // 2], ys[len(ys) // 2]
            if max(((p[1] - mx) ** 2 + (p[2] - my) ** 2) ** 0.5 for p in pts) > SPREAD:
                continue
            pick = min(pts, key=lambda p: ((p[1] - mx) ** 2 + (p[2] - my) ** 2, p))
            self.placed.append((aid, "ACH", pick[0], round(pick[1], 1), round(pick[2], 1), "ach", aid, 0,
                                src.repo, src.commit))
            return pick[0], pick[1], pick[2], src
        return None

    def header(self):
        used = sorted({r[9] for r in self.placed})
        if not used:
            return []
        return ["-- Steps whose note says \"(location: " + LABEL + " ...)\" take their map point from an MIT-licensed "
                "community collection database (only ids and coordinates, which are facts, are used; source and commit "
                "per value: CREDITS.md and docs/verification.sqlite): commit " + ", ".join(c[:12] for c in used) + "."]

    def chart(self, con, file):
        con.execute("create table if not exists att_points(flavor text, file text, quest int, act text, map int, x real, "
                    "y real, kind text, entry int, via_item int, source text, commit_sha text)")
        con.execute("delete from att_points where flavor=? and file=?", (self.fl, file))
        con.executemany("insert into att_points values (?,?,?,?,?,?,?,?,?,?,?,?)", [(self.fl, file) + r for r in self.placed])
        con.commit()
