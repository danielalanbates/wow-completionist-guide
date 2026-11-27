# CompletionRoute :: tools/emu/emu_points.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Last rung for quest steps that still have only a zone or no point: the quest giver's, ender's or objective target's
spawn from an open emulator database (tools/emu/extract_emu.py -> tools/db2/emu/<source>.sqlite).

A step  -> its entities: A = quest starters, T = quest enders, C = objective targets (the QO slot first).
Spawns  -> uiMap % with the client's own map rectangles (wikimaps.MapSet.from_world, Blizzard UiMap/UiMapAssignment
           via wago.tools).  A step with |Z| keeps only spawns that land on that map; a step with no zone takes the
           map only when every spawn of the chosen entity lands on one zone.  Several spawns: the one nearest the
           median of the in-zone spawns (cluster centre).
Order   -> the client's sources in turn (SOURCES); the first that places the step wins.  The wiki always comes first:
           this only fills steps the wiki, quest pins and Blizzard subzones left without a point.
Every placed step's note says "(location: <repo> spawn of <npc|object> <id>)" and is recorded with its source repo and
commit (rows(), charted in docs/verification.sqlite emu_points).
"""
import re
import sqlite3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EMU = ROOT / "tools" / "db2" / "emu"
SOURCES = {"era": ["classic"], "forever": ["classic"], "tbc": ["tbc"], "mop": ["tc442", "tc1210"],
           "retail": ["tc1210", "tc442"]}
STEP = re.compile(r"^([ACT]) [^|]*\|QID\|(\d+)\|")
ZONE = re.compile(r"\|Z\|(\d+); ([^|]*)")
QO = re.compile(r"\|QO\|(\d+)")


class Source:
    def __init__(self, name):
        self.name = name
        self.db = sqlite3.connect(EMU / f"{name}.sqlite")
        meta = dict(self.db.execute("select key, value from meta"))
        self.repo, self.commit = meta.get("repo", name), meta.get("commit", "")

    def entities(self, act, qid, qo=None):
        if act in "AT":
            return self.db.execute("select kind, entry from rel where quest=? and role=? order by kind, entry",
                                   (qid, "start" if act == "A" else "end")).fetchall()
        rows = self.db.execute("select idx, kind, entry from obj where quest=? order by idx", (qid,)).fetchall()
        if qo is not None:
            rows.sort(key=lambda r: r[0] != qo - 1)
        return [(k, e) for _, k, e in rows]

    def spawns(self, kind, entry):
        return self.db.execute("select map, x, y from spawn where kind=? and entry=?", (kind, entry)).fetchall()


class EmuPoints:
    def __init__(self, fl, maps, sources=None):
        self.fl, self.maps = fl, maps
        names = SOURCES.get(fl, []) if sources is None else sources
        self.sources = [Source(n) for n in names if (EMU / f"{n}.sqlite").exists()]
        self.placed = []        # (qid, act, mid, x, y, kind, entry, source repo, commit)
        self.n_zone = self.n_none = 0     # placed steps that had a zone / had nothing

    def locate(self, src, act, qid, zmid, zname, qo):
        for kind, entry in src.entities(act, qid, qo):
            pts = []
            for inst, wx, wy in src.spawns(kind, entry):
                r = self.maps.from_world(inst, wx, wy, prefer_name=zname)
                if not r:
                    continue
                home = self.maps.home(r[0])
                if zmid is not None and r[0] != zmid and home != zmid:
                    continue
                if zmid is not None and r[0] != zmid:
                    r = self.on_map(zmid, inst, wx, wy) or r
                pts.append((r, home, wx, wy))
            if not pts:
                continue
            if zmid is None and len({p[1] for p in pts}) != 1:
                continue        # spawns in several zones (a holiday NPC in every capital): no single place
            xs, ys = sorted(p[2] for p in pts), sorted(p[3] for p in pts)
            mx, my = xs[len(xs) // 2], ys[len(ys) // 2]
            best = min(pts, key=lambda p: ((p[2] - mx) ** 2 + (p[3] - my) ** 2, p[0]))
            return best[0], kind, entry
        return None

    def on_map(self, mid, inst, wx, wy):
        m = self.maps.maps.get(mid)
        if not m or m["inst"] != inst or not m["w"] or not m["h"]:
            return None
        y01, x01 = (m["topX"] - wx) / m["h"], (m["leftY"] - wy) / m["w"]
        if -0.005 <= x01 <= 1.005 and -0.005 <= y01 <= 1.005:
            return mid, min(max(x01, 0), 1) * 100, min(max(y01, 0), 1) * 100
        return None

    def fill_line(self, line):
        """a step line with no |M| -> the line with a spawn point, or None when no source places it"""
        if not isinstance(line, str) or "|M|" in line:
            return None
        m = STEP.match(line)
        if not m:
            return None
        act, qid = m.group(1), int(m.group(2))
        z = ZONE.search(line)
        zmid, zname = (int(z.group(1)), z.group(2)) if z else (None, None)
        if zmid is not None and zmid not in self.maps.maps:
            return None
        qo = QO.search(line)
        qo = int(qo.group(1)) if qo else None
        for src in self.sources:
            hit = self.locate(src, act, qid, zmid, zname, qo)
            if not hit:
                continue
            (mid, x, y), kind, entry = hit
            pt = f"|M|{x:.1f},{y:.1f}"
            if z:
                line = line[:z.start()] + pt + line[z.start():]
            else:
                mz = f"{pt}|Z|{mid}; {self.maps.maps[mid]['name']}"
                cut = min([i for i in (line.find(k) for k in ("|FACTION|", "|RACE|", "|CLASS|", "|LVL|", "|N|")) if i > 0]
                          or [len(line.rstrip("|"))])
                line = line[:cut] + mz + line[cut:]
            what = "npc" if kind == "c" else "object"
            tag = f"(location: {src.repo} spawn of {what} {entry})"
            if "|N|" in line:
                line = line.rstrip("|") + " " + tag + "|"
            else:
                line = line.rstrip("|") + "|N|" + tag + "|"
            self.n_zone += z is not None
            self.n_none += z is None
            self.placed.append((qid, act, mid, round(x, 1), round(y, 1), kind, entry, src.repo, src.commit))
            return line
        return None

    def fill(self, lines):
        """fill a guide's step lines in place; returns how many were placed"""
        n = 0
        for i, ln in enumerate(lines):
            new = self.fill_line(ln)
            if new is not None:
                lines[i] = new
                n += 1
        return n

    def header(self):
        used = sorted({(r[7], r[8]) for r in self.placed})
        if not used:
            return []
        return ["-- Steps whose note says \"(location: <repo> spawn of ...)\" take their map point from an open emulator "
                "world database (GPL; only ids and coordinates, which are facts, are used; see CREDITS.md): " +
                ", ".join(f"{r}@{c[:12]}" for r, c in used) + "."]

    def chart(self, con, file):
        con.execute("create table if not exists emu_points(flavor text, file text, quest int, act text, map int, x real, "
                    "y real, kind text, entry int, source text, commit_sha text)")
        con.execute("delete from emu_points where flavor=? and file=?", (self.fl, file))
        con.executemany("insert into emu_points values (?,?,?,?,?,?,?,?,?,?,?)",
                        [(self.fl, file) + r for r in self.placed])
        con.commit()
