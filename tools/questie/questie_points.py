# CompletionRoute :: tools/questie/questie_points.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Rung after the emulator spawns (tools/emu/emu_points.py): steps still without a point take the giver's, ender's
or objective target's position from the GPLv3 community quest database (credited in CREDITS.md and docs/EMU_DATA.md;
tools/questie/extract_questie.lua -> build_questie.py -> tools/db2/questie/<source>.sqlite).

Its points are already zone % on a uiMap (its own areaId -> uiMap table), so no world conversion is needed:
  * the uiMap must exist on the client; a step with |Z| keeps points on that map, or on a map inside it (converted
    through world coordinates with the client's rectangles); a step with no zone is placed only when every point of the
    entity lies in one zone;
  * item objectives (C steps whose objective is an item) use the item's drop sources: the npc/object with the most
    points in the zone wins (where the item is farmed), then the point nearest the median of its in-zone points;
  * explore objectives use the quest's own objective area.
The add-on UI never names the database (licence: its name and logo are not ours to use); the step note says
"(location: community quest database spawn of ...)", and every value is charted with repo + commit in
docs/verification.sqlite questie_points.
"""
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "emu"))
import emu_points as EP  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
QDB = ROOT / "tools" / "db2" / "questie"
SOURCES = {"era": ["classic"], "forever": ["forever", "classic"], "tbc": ["tbc"], "mop": ["mop", "cata"],
           "retail": ["mop", "cata"]}
LABEL = "community quest database"


class Source:
    def __init__(self, name, path=None):
        self.name = name
        self.db = sqlite3.connect(path or QDB / f"{name}.sqlite")
        meta = dict(self.db.execute("select key, value from meta"))
        self.repo, self.commit = meta.get("repo", name), meta.get("commit", "")

    def entities(self, act, qid, qo=None):
        """[(kind, entry, via item)], grouped: a group is one objective (all drop sources of one item compete)"""
        if act in "AT":
            rows = self.db.execute("select kind, entry, via from rel where quest=? and role=? order by via != 0, kind, entry",
                                   (qid, "start" if act == "A" else "end")).fetchall()
            return [[r] for r in rows if not r[2]] + ([[r for r in rows if r[2]]] if any(r[2] for r in rows) else [])
        rows = self.db.execute("select idx, kind, entry, via from obj where quest=? order by idx, kind, entry", (qid,)).fetchall()
        groups = {}
        for idx, k, e, via in rows:
            groups.setdefault((idx, via), []).append((k, e, via))
        keys = sorted(groups, key=lambda g: (qo is not None and g[0] != qo - 1, g[0], g[1]))
        out = []
        for g in keys:
            if g[1]:
                out.append(groups[g])           # drop sources of one item: compete inside the group
            else:
                out.extend([r] for r in groups[g])
        return out

    def points(self, kind, entry):
        return self.db.execute("select map, x, y from spawn where kind=? and entry=?", (kind, entry)).fetchall()


class QuestiePoints(EP.EmuPoints):
    def __init__(self, fl, maps, sources=None, paths=None):
        self.fl, self.maps = fl, maps
        names = SOURCES.get(fl, []) if sources is None else sources
        paths = paths or {}
        self.sources = [Source(n, paths.get(n)) for n in names if paths.get(n) or (QDB / f"{n}.sqlite").exists()]
        self.placed = []        # (qid, act, mid, x, y, kind, entry, via, source repo, commit)
        self.n_zone = self.n_none = 0
        self.n_item = 0

    def in_zone(self, src, kind, entry, zmid):
        pts = []
        for mid, x, y in src.points(kind, entry):
            if mid not in self.maps.maps:
                continue
            home = self.maps.home(mid)
            if zmid is not None and mid != zmid and home != zmid:
                continue
            if zmid is not None and mid != zmid:
                w = self.maps.to_world(mid, x, y)
                r = w and self.on_map(zmid, *w)
                if not r:
                    continue
                pts.append((r, home))
            else:
                pts.append(((mid, x, y), home))
        return pts

    def locate(self, src, act, qid, zmid, zname, qo):
        for group in src.entities(act, qid, qo):
            best = None
            for kind, entry, via in group:
                pts = self.in_zone(src, kind, entry, zmid)
                if not pts:
                    continue
                if zmid is None and len({p[1] for p in pts}) != 1:
                    continue
                if best is None or len(pts) > len(best[0]) or (len(pts) == len(best[0]) and (kind, entry) < best[1][:2]):
                    best = (pts, (kind, entry, via))
            if not best:
                continue
            pts = [p[0] for p in best[0]]
            mid0 = pts[0][0]
            pts = [p for p in pts if p[0] == mid0] if zmid is None else pts
            xs, ys = sorted(p[1] for p in pts), sorted(p[2] for p in pts)
            mx, my = xs[len(xs) // 2], ys[len(ys) // 2]
            pick = min(pts, key=lambda p: ((p[1] - mx) ** 2 + (p[2] - my) ** 2, p))
            return pick, best[1]
        return None

    def fill_line(self, line):
        if not isinstance(line, str) or "|M|" in line:
            return None
        m = EP.STEP.match(line)
        if not m:
            return None
        act, qid = m.group(1), int(m.group(2))
        z = EP.ZONE.search(line)
        zmid, zname = (int(z.group(1)), z.group(2)) if z else (None, None)
        if zmid is not None and zmid not in self.maps.maps:
            return None
        qo = EP.QO.search(line)
        qo = int(qo.group(1)) if qo else None
        for src in self.sources:
            hit = self.locate(src, act, qid, zmid, zname, qo)
            if not hit:
                continue
            (mid, x, y), (kind, entry, via) = hit
            pt = f"|M|{x:.1f},{y:.1f}"
            if z:
                line = line[:z.start()] + pt + line[z.start():]
            else:
                mz = f"{pt}|Z|{mid}; {self.maps.maps[mid]['name']}"
                cut = min([i for i in (line.find(k) for k in ("|FACTION|", "|RACE|", "|CLASS|", "|LVL|", "|N|")) if i > 0]
                          or [len(line.rstrip("|"))])
                line = line[:cut] + mz + line[cut:]
            what = {"c": "npc", "g": "object", "t": "quest area"}[kind]
            tag = f"(location: {LABEL} spawn of {what} {entry}" + (f", drops item {via})" if via else ")")
            line = line.rstrip("|") + (" " if "|N|" in line else "|N|") + tag + "|"
            self.n_zone += z is not None
            self.n_none += z is None
            self.n_item += bool(via)
            self.placed.append((qid, act, mid, round(x, 1), round(y, 1), kind, entry, via, src.repo, src.commit))
            return line
        return None

    def header(self):
        used = sorted({r[9] for r in self.placed})
        if not used:
            return []
        return ["-- Steps whose note says \"(location: " + LABEL + " spawn of ...)\" take their map point from a GPLv3 "
                "community quest database (only ids and coordinates, which are facts, are used; source and commit per "
                "value: CREDITS.md and docs/verification.sqlite): commit " + ", ".join(c[:12] for c in used) + "."]

    def chart(self, con, file):
        con.execute("create table if not exists questie_points(flavor text, file text, quest int, act text, map int, x real, "
                    "y real, kind text, entry int, via_item int, source text, commit_sha text)")
        con.execute("delete from questie_points where flavor=? and file=?", (self.fl, file))
        con.executemany("insert into questie_points values (?,?,?,?,?,?,?,?,?,?,?,?)",
                        [(self.fl, file) + r for r in self.placed])
        con.commit()
