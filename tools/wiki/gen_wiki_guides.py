#!/usr/bin/env python3
# CompletionRoute :: tools/wiki/gen_wiki_guides.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Generate per-zone quest guides from the Warcraft Wiki (the source of truth), one file per client.

    nice -n 10 python3 tools/wiki/gen_wiki_guides.py [era tbc mop retail forever] [--no-fallback]

Inputs : tools/wiki/wiki.sqlite (tools/wiki/parse_wiki.py), tools/db2/<flavor>/QuestV2.csv (+ retail
         QuestObjective.csv; tools/wiki/fetch_db2.py), tools/maps_<flavor>.lua, and - only to fill a step the wiki has
         no coordinates for - the existing CompletionRoute/Guides/Imported_Quests_<flavor>.lua.
Outputs: CompletionRoute/Guides/Imported_Wiki_<flavor>.lua        the wiki guides (CC BY-SA 4.0 data)
         CompletionRoute/Guides/Imported_Quests_<flavor>_gaps.lua  the old generated guides MINUS every quest the
                                                                   wiki guide covers (no duplicate quests in game)
         tools/wiki/wiki.sqlite tables flavor_quests / flavor_gap / flavor_skip / gen_stats
         docs/verification.sqlite table wiki_db2_conflict
All outputs are gitignored like every other Imported_* file.

Flavor membership (docs/WIKI_DATA_SPEC.md 6): a wiki quest belongs to a client when its id is in that client's
QuestV2, it never shipped-and-was-pulled (RemovedFromBeta/Alpha/PTR), it is not Forever-only (except on forever) or Season of Discovery,
it was not removed at or before the client's game version ({{Classic only}}, {{Removed}}, ==Patch changes==), and
its added patch fits the client.  When a quest id has several pages ("(Classic)", "(BC Classic)" twins) the page made
for that client wins.

Step location priority (docs/WIKI_DATA_SPEC.md 3/4):
  1. {{co}} written in the questbox start/end or on the objective bullet itself
  2. the linked NPC / object / place page ({{Npcbox}} location, {{Npclocations}} row for the client's expansion,
     lead sentence); an item objective follows the item page's drop sources to a page with coordinates
  3. fallback, only when the wiki has nothing: the same step in Imported_Quests_<flavor>.lua.  Those steps say
     "(location: Blizzard data)" (retail quest POI) or "(location: Questie data)" (Classic, Questie-derived) in
     their note.  --no-fallback writes a pure-wiki file (the shippable variant).
  4. otherwise the step has no |M| and says so.
Item-started quests (Blizzard ItemSparse.StartQuestID, tools/db2/<flavor>/ItemSparse.csv): the accept step is where the
item is obtained.  Its point comes from the wiki item page (the {{Coords}} in its "found / fished / dropped" sentences,
else the drop source pages), found through the questbox start link or, when the wiki starts the quest elsewhere or not
at all, through the item id.  A source that is only a zone gives a zone-level accept (|Z| without |M|, "zone only" in the
note).  The accept carries |U|<item>| so the arrow offers "Use <item>" once the item is in the bags.
Chains: the questbox `previous` links become |PRE| (any one of them, ";"), and a `next` link adds the reverse edge.
Only quests that exist on the same client are kept in PRE, so a chain never waits for a quest that cannot exist.
World quests, callings and emissary quests are left out (time-limited, not completionist steps).
"""
import csv
import datetime
import json
import math
import re
import sqlite3
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import wikimaps  # noqa: E402
import gen_spine  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
WIKI = ROOT / "tools" / "wiki" / "wiki.sqlite"
GUIDES = ROOT / "CompletionRoute" / "Guides"
VERIF = ROOT / "docs" / "verification.sqlite"
FLAVORS = ["era", "tbc", "mop", "retail", "forever"]
# WoW Forever (product wowf, 1.60.x): Era content (1.12 base + the 1.13-1.15 Era line) plus its own 1.60 additions
# (Skyborne, Zephras Isle, Mount Hyjal, Riverglades, new class quests) on reshaped maps (tools/maps_forever.lua).
# The client runs the era code path (Core/Init.lua: NS.flavor "era", NS.isForever).
CLASSICISH = ("era", "tbc", "forever")
# flavor -> (expansion number, last original patch it is built on)
EXP = {"era": (1, (1, 12, 9)), "tbc": (2, (2, 4, 9)), "mop": (5, (5, 4, 9)), "retail": (99, (99, 0, 0)),
       "forever": (1, (1, 12, 9))}
CO_KEY = {"era": ("wow", "classic", "vanilla", "era"), "tbc": ("tbc", "bc"), "mop": ("mop",), "retail": (),
          "forever": ("wow", "classic", "vanilla", "era", "forever")}
# Forever has no Questie-derived Imported_Quests_forever.lua of its own: the fallback points and the _gaps guides
# come from the era file (Era maps; reshaped maps are converted, see Gen.era_to_forever / Core/Util.lua).
FALLBACK_OF = {"forever": "era"}
SKIP_TYPES = re.compile(r"world quest|calling|emissary", re.I)
DELIVERY = re.compile(r"^(speak|talk|report|return|bring|take|deliver|go|travel|meet|seek|find|visit|"
                      r"give|hand|show|tell|carry|ask)\b", re.I)


def pkey(p):
    m = re.match(r"^\s*(\d+)\.(\d+)(?:\.(\d+))?", p or "")
    return (int(m.group(1)), int(m.group(2)), int(m.group(3) or 0)) if m else None


def patch_line(k):
    """which release line a patch belongs to: orig / era / forever / tbc / wrath / cata / mop (Classic lines)"""
    if not k:
        return None
    a, b = k[0], k[1]
    if a == 1 and b >= 60:
        return "forever"
    if a == 1 and b >= 13:
        return "era"
    if (a, b) == (2, 5):
        return "tbc"
    if (a, b) == (3, 4):
        return "wrath"
    if (a, b) == (4, 4):
        return "cata"
    if (a, b) == (5, 5):
        return "mop"
    return "orig"


VARIANT_FOR = {
    "classic": {"era", "tbc", "forever"}, "bc classic": {"tbc"}, "anniversary classic": {"tbc"},
    "wrath classic": {"mop"}, "cata classic": {"mop"}, "mop classic": {"mop"},
    "season of discovery": set(), "beta": set(), "alpha": set(), "forever": {"forever"}, "hardcore": set(),
}
VARIANT_PREF = {
    "era": ["classic"], "tbc": ["bc classic", "anniversary classic", "classic"],
    "mop": ["mop classic", "cata classic", "wrath classic"], "retail": [], "forever": ["forever", "classic"],
}


def membership(r, fl, qv2):
    """-> (ok, reason)"""
    if r["id"] not in qv2[fl]:
        return False, "not in QuestV2"
    if r["beta"]:
        return False, "removed from beta/alpha/ptr"
    if r["forever"] and fl != "forever":
        return False, "Forever only"
    if r["sod"]:
        return False, "Season of Discovery"
    v = (r["variant"] or "").lower()
    if v in VARIANT_FOR and fl not in VARIANT_FOR[v]:
        return False, f"page variant ({r['variant']})"
    e, vmax = EXP[fl]
    rk = pkey(r["removed_patch"])
    if r["classic_only"]:
        if fl == "retail":
            return False, "Classic only"
        if rk:
            args = (r["classic_only_args"] or "").split(",")
            if rk[0] < e or (rk[0] == e and not any(a in CO_KEY[fl] for a in args)):
                return False, f"Classic only, removed {r['removed_patch']}"
    else:
        if rk:
            line = patch_line(rk)
            if line == "orig" and (fl == "retail" or rk <= vmax):
                return False, f"removed {r['removed_patch']}"
            if line not in ("orig", None) and line == fl:
                return False, f"removed {r['removed_patch']}"
            # Forever was built from the Era line: an Era-line removal (1.13-1.15) is assumed to carry over
            if fl == "forever" and line == "era":
                return False, f"removed {r['removed_patch']} (Era line)"
        elif r["removed_flag"] and fl == "retail":
            return False, "removed"
    ak = pkey(r["added_patch"])
    if ak:
        line = patch_line(ak)
        if line == "forever" and fl != "forever":
            return False, "added in Forever"
        if fl == "retail" and line != "orig":
            return False, f"added in Classic patch {r['added_patch']}"
        if fl == "era" and not ((line == "orig" and ak <= vmax) or line == "era"):
            return False, f"added {r['added_patch']}"
        if fl == "tbc" and not ((line == "orig" and ak <= vmax) or line == "tbc"):
            return False, f"added {r['added_patch']}"
        if fl == "mop" and not ((line == "orig" and ak <= vmax) or line in ("wrath", "cata", "mop")):
            return False, f"added {r['added_patch']}"
        if fl == "forever" and not ((line == "orig" and ak <= vmax) or line in ("era", "forever")):
            return False, f"added {r['added_patch']}"
    return True, ""


def flavor_gate(fl):
    """the flavor guard at the top of a generated file.  Forever runs NS.flavor "era", so the era files step aside
    for Forever's own (NS.isForever) and the Forever files load nowhere else."""
    if fl == "forever":
        return "if not NS.isForever then return end"
    if fl == "era":
        return 'if NS.flavor ~= "era" or NS.isForever then return end'
    return f'if NS.flavor ~= "{fl}" then return end'


def clean(s, n=180):
    s = re.sub(r"\s+", " ", (s or "").replace("|", "/").replace("]==]", "]=]")).strip()
    return s[:n]


def fmt_xy(x, y):
    return f"{x:.1f},{y:.1f}"


class Fallback:
    """steps of Imported_Quests_<flavor>.lua indexed by quest id (used only where the wiki has no coordinates)"""
    RE_LINE = re.compile(r"^([ACT]) .*?\|QID\|(\d+)\|")

    def __init__(self, fl, convert=None):
        self.fl = fl
        self.path = GUIDES / f"Imported_Quests_{FALLBACK_OF.get(fl, fl)}.lua"
        self.q = defaultdict(lambda: {"A": None, "T": None, "C": {}})
        if not self.path.exists():
            print(f"  note: {self.path.name} missing - no fallback locations for {fl}")
            return
        for ln in self.path.read_text(encoding="utf-8", errors="replace").splitlines():
            m = self.RE_LINE.match(ln)
            if not m:
                continue
            act, qid = m.group(1), int(m.group(2))
            mm = re.search(r"\|M\|([\d.,;]+)\|", ln)
            zz = re.search(r"\|Z\|([^|]+)\|", ln)
            if not (mm and zz):
                continue
            note = (re.search(r"\|N\|([^|]*)\|", ln) or [None, ""])[1]
            pts = mm.group(1)
            if convert:
                zid = re.match(r"\s*(\d+)", zz.group(1))
                pts = convert(int(zid.group(1)) if zid else None, pts)
            if fl == "retail":
                src = "Questie data" if "(Questie)" in note else "Blizzard data"
            else:
                src = "Questie data"
            rec = (pts, zz.group(1).strip(), src)
            if act == "C":
                qo = re.search(r"\|QO\|(\d+)\|", ln)
                self.q[qid]["C"].setdefault(int(qo.group(1)) if qo else 0, rec)
            elif self.q[qid][act] is None:
                self.q[qid][act] = rec

    def get(self, qid, act, qo=None):
        r = self.q.get(qid)
        if not r:
            return None
        if act != "C":
            return r[act]
        if qo is not None and qo in r["C"]:
            return r["C"][qo]
        if 0 in r["C"]:
            return r["C"][0]
        return r["C"][min(r["C"])] if r["C"] and qo is None else None


class Gen:
    def __init__(self, fallback=True):
        self.db = sqlite3.connect(WIKI)
        self.db.row_factory = sqlite3.Row
        self.atlas = wikimaps.Atlas()
        self.use_fallback = fallback
        self.titles = {r["title"]: (r["page_title"], r["kind"]) for r in self.db.execute("select * from titles")}
        self.npc_pts = defaultdict(list)
        for r in self.db.execute("select title, zone, x, y, source, badge, classic from npc_coords order by title, idx"):
            self.npc_pts[r["title"]].append((r["zone"], r["x"], r["y"], r["source"], r["badge"], r["classic"]))
        self.npc_classic = {r["title"]: r["page_classic"] for r in self.db.execute("select title, page_classic from npcs")}
        self.items = {r["title"]: (r["item_id"], json.loads(r["sources_json"] or "[]"))
                      for r in self.db.execute("select * from items")}
        cols = [c[1] for c in self.db.execute("pragma table_info(items)")]
        self.item_pts = {r["title"]: json.loads(r["coords_json"] or "[]")
                         for r in self.db.execute("select * from items")} if "coords_json" in cols else {}
        self.item_by_id = {}
        for t, (iid, _src) in self.items.items():
            if iid and (iid not in self.item_by_id or "(item)" in t):
                self.item_by_id[iid] = t
        self.objs = defaultdict(list)
        for r in self.db.execute("select * from quest_objectives order by quest_id, page_title, idx"):
            self.objs[(r["quest_id"], r["page_title"])].append(dict(r))
        self.rows = [dict(r) for r in self.db.execute("select * from quests")]
        self.qv2 = {}
        for fl in FLAVORS:
            p = ROOT / "tools" / "db2" / fl / "QuestV2.csv"
            if not p.exists():
                sys.exit(f"missing {p} - run tools/wiki/fetch_db2.py")
            self.qv2[fl] = {int(r["ID"]) for r in csv.DictReader(p.open(encoding="utf-8"))}
        # quest -> [(item id, item name)] that start it, per client (Blizzard ItemSparse.StartQuestID)
        self.starter = {}
        for fl in FLAVORS:
            p = ROOT / "tools" / "db2" / fl / "ItemSparse.csv"
            self.starter[fl] = defaultdict(list)
            if p.exists():
                for r in csv.DictReader(p.open(encoding="utf-8")):
                    q = int(r.get("StartQuestID") or 0)
                    if q:
                        self.starter[fl][q].append((int(r["ID"]), r.get("Display_lang") or ""))
        self.qobj = Counter()
        p = ROOT / "tools" / "db2" / "retail" / "QuestObjective.csv"
        if p.exists():
            for r in csv.DictReader(p.open(encoding="utf-8")):
                self.qobj[int(r["QuestID"])] += 1
        self.conflicts = []
        self.place_cache = {}
        self.clean_pts = {}
        self.subzone_dropped = []

    # ---- locations ---------------------------------------------------------------------------------
    def era_to_forever(self, mid, pts):
        """'x,y;x,y' (percent) on an Era map -> the same places on the Forever map (only reshaped maps change)"""
        a = self.atlas.sets["era"].maps.get(mid) if mid else None
        b = self.atlas.sets["forever"].maps.get(mid) if mid else None
        if not a or not b or not isinstance(a.get("w"), float) or not isinstance(b.get("w"), float):
            return pts
        if max(abs(a[k] - b[k]) for k in ("topX", "leftY", "w", "h")) < 0.5:
            return pts
        out = []
        for pr in pts.split(";"):
            try:
                x, y = (float(v) / 100.0 for v in pr.split(","))
            except ValueError:
                out.append(pr)
                continue
            wx, wy = a["topX"] - y * a["h"], a["leftY"] - x * a["w"]
            out.append(fmt_xy((b["leftY"] - wy) / b["w"] * 100.0, (b["topX"] - wx) / b["h"] * 100.0))
        return ";".join(out)

    def resolve_title(self, t):
        if not t:
            return None, None
        r = self.titles.get(t)
        return r if r else (t, None)

    def place(self, zone, x, y, fl, classic, added):
        k = (zone, x, y, fl, classic, added)
        if k not in self.place_cache:
            self.place_cache[k] = self.atlas.place(zone, x, y, fl, classic, added)
        return self.place_cache[k]

    def coords_list(self, pts, fl, classic, added, home_name=None):
        """[(zone, x, y)] wiki points -> (mapID, 'x,y;x,y') on the client, all points on one map"""
        placed = []
        for z, x, y in pts:
            r = self.place(z, x, y, fl, classic, added)
            if r:
                placed.append(r)
        if not placed:
            return None
        if home_name:
            hn = wikimaps.norm(home_name)
            inz = [p for p in placed if wikimaps.norm(self.atlas.sets[fl].maps[p[0]]["name"]) == hn]
            if inz:
                placed = inz
        mid = placed[0][0]
        same = [p for p in placed if p[0] == mid][:4]
        return mid, ";".join(fmt_xy(p[1], p[2]) for p in same)

    def page_rows(self, title):
        """the page's coordinate rows, with a subzone row that its own parent-zone row contradicts (same expansion badge,
        same page version; wikimaps.Atlas.subzone_conflict) moved onto the parent row's point.  The row stays, under the
        subzone's name, because the choice between rows prefers the guide's own zone: dropping it would let a later
        expansion's row win (Gornek in Spires of Arak for a Valley of Trials quest).  Off the subzone map, it goes."""
        if title in self.clean_pts:
            return self.clean_pts[title]
        pts = self.npc_pts.get(title) or []
        out = []
        for a in pts:
            row = a
            for b in pts:
                if a is not b and a[4] == b[4] and a[5] == b[5] and self.atlas.subzone_conflict(a[:3], b[:3], bool(a[5])):
                    moved = self.atlas.parent_point_on_sub(a[0], b[:3], bool(a[5]))
                    row = (a[0], moved[0], moved[1]) + a[3:] if moved else None
                    self.subzone_dropped.append((title,) + a[:3])
                    break
            if row:
                out.append(row)
        self.clean_pts[title] = out
        return out

    def page_points(self, title, fl, home_name):
        """best coordinates on an NPC/object/place page for this client"""
        pts = self.page_rows(title)
        if not pts:
            return [], False
        e = EXP[fl][0]

        def score(p):
            zone, x, y, src, badge, classic = p
            s = 0
            # A point on a map this client does not have (a retail subzone map such as Valley of Trials on Classic, or a
            # retail-only zone) ranks after a point on a map it does have.  A subzone point is only usable through
            # world-coordinate conversion, so an entry for the zone itself is better.
            if self.atlas.sets[fl].resolve(zone) is None:
                s += 1.5
            if fl in CLASSICISH:
                s += 0 if classic else 2
                if fl == "tbc" and "(burning crusade)" in zone.lower():
                    s -= 1
            else:
                s += 2 if classic else 0
            if badge:
                s += 0 if badge <= e else 3
                s += (e - badge) * 0.05 if badge <= e else 0
            s += {"location": 0, "npclocations": 0.2, "lead": 0.5}.get(src, 1.0)
            if home_name and wikimaps.norm(re.sub(r"\s*\([^()]*\)$", "", zone)) == wikimaps.norm(home_name):
                s -= 0.5
            return s
        ranked = sorted(pts, key=score)
        best = ranked[0]
        group = [p for p in ranked if p[0] == best[0] and p[5] == best[5]]
        return [(p[0], p[1], p[2]) for p in group], self.exact(fl, best[5], best[4])

    @staticmethod
    def exact(fl, classic, badge=0):
        """is a wiki point written for this client's version?  Retail: always.  Classic clients: a point on a
        Classic page / Classic zone, or an {{Npclocations}} row badged with an expansion the client has."""
        if fl == "retail":
            return True
        e = EXP[fl][0]
        if fl in CLASSICISH:
            return bool(classic) or (0 < (badge or 0) <= e)
        return (not classic) and 0 < (badge or 0) <= e

    def entity_coords(self, title, fl, added, home_name, depth=0):
        """(mapID, 'x,y', how) for a linked page; items follow their drop sources"""
        page, kind = self.resolve_title(title)
        if not page:
            return None
        if kind in ("npc", "object", "place") or page in self.npc_pts:
            pts, ex = self.page_points(page, fl, home_name)
            if pts:
                r = self.coords_list(pts, fl, bool(self.npc_classic.get(page)), added, home_name)
                if r:
                    return r[0], r[1], page, ex
        if depth == 0 and page in self.items:
            pts = [(z, x, y) for x, y, z in self.item_pts.get(page, []) if z]
            if pts:
                r = self.coords_list(pts, fl, False, added, home_name)
                if r:
                    return r[0], r[1], page, fl == "retail"
            for src in self.items[page][1]:
                r = self.entity_coords(src, fl, added, home_name, 1)
                if r:
                    return r
        return None

    def item_zone(self, page, fl, added):
        """a zone-only place for an item page whose sources name a zone but give no point: (mapID, zone name) or None"""
        maps = self.atlas.sets[fl]
        for src in self.items.get(page, (None, []))[1]:
            t, kind = self.resolve_title(src)
            for name in (t, src):
                mid = maps.resolve(name, added) if name else None
                if mid is not None and maps.maps[mid]["type"] in (3, 4, 5, 6):
                    return mid
        return None

    # ---- one client ---------------------------------------------------------------------------------
    def run(self, fl):
        maps = self.atlas.sets[fl]
        fb = Fallback(fl, self.era_to_forever if fl == "forever" else None) if self.use_fallback else None
        st = Counter()
        skip = []
        by_id = defaultdict(list)
        all_ids = set()
        for r in self.rows:
            all_ids.add(r["id"])
            ok, why = membership(r, fl, self.qv2)
            if ok:
                by_id[r["id"]].append(r)
            else:
                skip.append((fl, r["id"], r["page_title"], why))
                if why == "" or (why == "not in QuestV2" and fl == "era" and not r["beta"] and not r["forever"]
                                 and not r["sod"] and pkey(r["added_patch"]) and pkey(r["added_patch"]) <= (1, 12, 9)
                                 and not r["removed_patch"] and not (r["variant"] or "").lower() in VARIANT_FOR):
                    self.conflicts.append((fl, r["id"], "membership", "added <= 1.12, not removed", "not in QuestV2",
                                           r["page_title"], r["revid"], "wiki says vanilla quest; client lacks it"))
        st["wiki_quest_ids"] = len(all_ids)
        chosen = {}
        pref = VARIANT_PREF[fl]
        for qid, rs in by_id.items():
            def rank(r):
                v = (r["variant"] or "").lower()
                return (pref.index(v) if v in pref else len(pref), -(r["revid"] or 0))
            chosen[qid] = sorted(rs, key=rank)[0]
        for qid, r in list(chosen.items()):
            if SKIP_TYPES.search(r["qtype"] or ""):
                skip.append((fl, qid, r["page_title"], f"type {r['qtype']}"))
                del chosen[qid]
        st["assigned"] = len(chosen)
        gaps = sorted(self.qv2[fl] - all_ids)
        st["db2_only_gap"] = len(gaps)

        # chains: previous (any of) + reverse of next
        pre = defaultdict(set)
        for qid, r in chosen.items():
            for p in (r["prev_ids"] or "").split(","):
                if p and int(p) in chosen and int(p) != qid:
                    pre[qid].add(int(p))
        for qid, r in chosen.items():
            for n in (r["next_ids"] or "").split(","):
                if n and int(n) in chosen and int(n) != qid and not chosen[int(n)]["prev_ids"]:
                    pre[int(n)].add(qid)

        guides = defaultdict(list)
        steps_out = {}
        for qid, r in chosen.items():
            added = pkey(r["added_patch"])
            classic_q = bool(r["page_classic"])
            zone_name = r["zone"] or r["category"] or ""
            zmid = maps.resolve(zone_name, added) if zone_name else None
            home_name = maps.maps[zmid]["name"] if zmid else zone_name
            name = clean(r["name"] or r["page_title"], 120)
            gate = ""
            if r["faction"] in ("Alliance", "Horde"):
                gate += f"FACTION|{r['faction']}|"
            if r["races"]:
                gate += f"R|{clean(r['races'], 80).replace(' and ', ',')}|"
            if r["classes"]:
                gate += f"C|{clean(r['classes'], 60)}|"
            lvl = r["levelreq"]
            if lvl and lvl > 1:
                gate += f"LVL|{lvl}|"
            lines = []
            first_map = None

            page_exact = self.exact(fl, classic_q, 0) or (
                fl == "mop" and (r["variant"] or "").lower() in VARIANT_FOR and "mop" in VARIANT_FOR[(r["variant"] or "").lower()])

            def versioned(c, ex, act, qo=None):
                """a wiki point written for another version (the wiki is retail-first) is kept unless this client's
                fallback data puts the step more than 300 yd away; then the fallback wins and SQL records it"""
                if ex or not fb:
                    return (c, "", "wiki")
                f = fb.get(qid, act, qo)
                if not f:
                    return (c, "", "wiki")
                try:
                    fz = int(f[1].split(";")[0])
                    fx, fy = (float(v) for v in f[0].split(";")[0].split(","))
                    wx, wy = (float(v) for v in c[1].split(";")[0].split(","))
                except ValueError:
                    return (c, "", "wiki")
                a = maps.to_world(c[0], wx, wy)
                b = maps.to_world(fz, fx, fy)
                if a and b and a[0] == b[0]:
                    d = ((a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2) ** 0.5
                    if d <= 300:
                        return (c, "", "wiki")
                else:
                    d = -1
                self.conflicts.append((fl, qid, f"{act}_xy_version", f"{c[0]}:{c[1]}", f"{f[1]}:{f[0]}",
                                       r["page_title"], r["revid"],
                                       f"wiki point is for another game version; {d:.0f} yd from client data"
                                       if d >= 0 else "wiki point is for another game version; other continent"))
                return (("Z", f), f" (location: {f[2]}; the wiki lists another version's position)", "fallback")

            def loc_tag(kind, ent_list, act, qo=None):
                """-> (M/Z text, note suffix, source) for an A/T step"""
                nonlocal first_map
                for e in ent_list:
                    if e.get("coords"):
                        c = self.coords_list([(x[2], x[0], x[1]) for x in e["coords"]], fl, classic_q, added, home_name)
                        if c:
                            return versioned(c, page_exact, act, qo)
                for e in ent_list:
                    if e.get("title"):
                        c = self.entity_coords(e["title"], fl, added, home_name)
                        if c:
                            return versioned((c[0], c[1]), c[3], act, qo)
                if fb:
                    f = fb.get(qid, act, qo)
                    if f:
                        return ("Z", f), f" (location: {f[2]})", "fallback"
                return None, "", "none"

            def mz(c):
                if c[0] == "Z":
                    f = c[1]
                    return f"M|{f[0]}|Z|{f[1]}|"
                return f"M|{c[1]}|Z|{c[0]}; {maps.maps[c[0]]['name']}|"

            starts = json.loads(r["start_json"] or "[]")
            ends = json.loads(r["end_json"] or "[]") or starts
            if r["faction"] in ("Alliance", "Horde"):
                starts = [e for e in starts if e.get("faction") in ("", r["faction"])] or starts
                ends = [e for e in ends if e.get("faction") in ("", r["faction"])] or ends
            ptag = f"PRE|{';'.join(str(p) for p in sorted(pre[qid]))}|" if pre.get(qid) else ""
            # A
            auto = bool(starts) and all(e.get("auto") for e in starts)
            c, suf, src = loc_tag("start", starts, "A")
            who = next((clean(e.get("label") or e.get("title"), 60) for e in starts if e.get("title")), "")
            item = r["item_start"] if r["item_start"] and self.resolve_title(r["item_start"])[0] in self.items else None
            # Blizzard says an item starts this quest: the accept is where that item is obtained
            starters = self.starter.get(fl, {}).get(qid, [])
            utag, zone_only, also = "", None, None
            if starters:
                st["item_quests"] += 1
                utag = f"U|{starters[0][0]}|"
                page = item and self.resolve_title(item)[0]
                if not page:
                    page = next((self.item_by_id[i] for i, _ in starters if i in self.item_by_id), None)
                    if not who or not c:
                        item = page or starters[0][1] or None
                    else:
                        # the wiki names a giver and has its point: keep it, and say the item starts it too
                        also = re.sub(r"\s*\(item\)$", "", page or starters[0][1] or "") or None
                if page and (not c or src == "fallback"):
                    e = self.entity_coords(page, fl, added, home_name)
                    if e:
                        c, suf, src = versioned((e[0], e[1]), e[3], "A")
                        item, also = item or page, None
                    elif not c:
                        zone_only = self.item_zone(page, fl, added)
                st["item_quests_point"] += 1 if c else 0
                st["item_quests_zone"] += 1 if zone_only is not None and not c else 0
            if item:
                iname = re.sub(r"\s*\(item\)$", "", item)
                note = f"Starts from the item {clean(iname, 60)}."
            elif also and who:
                note = f"From {who}; the item {clean(also, 60)} starts it too."
            elif auto:
                note = "Accepted automatically when you reach the area."
            elif who:
                note = f"From {who}."
            else:
                note = "Quest giver not named on the wiki."
            if c:
                lines.append(f"A {name}|QID|{qid}|{ptag}{utag}{mz(c)}{gate}N|{note}{suf}|")
                if c[0] != "Z":
                    first_map = c[0]
            elif zone_only is not None:
                lines.append(f"A {name}|QID|{qid}|{ptag}{utag}Z|{zone_only}; {maps.maps[zone_only]['name']}|{gate}"
                             f"N|{note} (zone only: the wiki names where it drops but gives no point)|")
                src = "zone"
            else:
                lines.append(f"A {name}|QID|{qid}|{ptag}{utag}{gate}N|{note} No coordinates on the wiki.|")
            st[f"steps_{src}"] += 1
            st["steps"] += 1
            # C per objective bullet
            bullets = self.objs.get((qid, r["page_title"]), [])
            counted = [b for b in bullets if b["kind"] != "provided"]
            use_qo = True
            if fl == "retail" and self.qobj.get(qid) is not None and counted and self.qobj[qid] != len(counted):
                use_qo = False
                self.conflicts.append((fl, qid, "objective_count", str(len(counted)), str(self.qobj[qid]),
                                       r["page_title"], r["revid"], "QO tags dropped"))
            provided_ids = []
            for b in bullets:
                if b["kind"] == "provided":
                    it = self.items.get(self.resolve_title(b["target_title"])[0] or "")
                    if it and it[0]:
                        provided_ids.append(it[0])
            qo = 0
            for b in counted:
                qo += 1
                cc = None
                bc = json.loads(b["coords_json"] or "[]")
                if bc:
                    cc = self.coords_list([(x[2], x[0], x[1]) for x in bc], fl, classic_q, added, home_name)
                    cc = versioned(cc, page_exact, "C", qo) if cc else None
                if not cc and b["target_title"]:
                    e = self.entity_coords(b["target_title"], fl, added, home_name)
                    if e:
                        cc = versioned((e[0], e[1]), e[3], "C", qo)
                if not cc and fb:
                    f = fb.get(qid, "C", qo)
                    if f:
                        cc = (("Z", f), f" (location: {f[2]})", "fallback")
                tags = f"QO|{qo}|" if use_qo else ""
                if b["kind"] == "kill" and b["target_title"]:
                    tags += f"T|{clean(b['target_title'], 60)}|"
                if b["kind"] == "item" and b["target_title"]:
                    it = self.items.get(self.resolve_title(b["target_title"])[0] or "")
                    if it and it[0]:
                        tags += f"L|{it[0]} {b['count'] or 1}|"
                if provided_ids and qo == 1:
                    tags += f"U|{provided_ids[0]}|"
                if b["optional"]:
                    tags += "O|"
                text = clean(b["text"]) or "Complete the objective."
                if cc:
                    lines.append(f"C {name}|QID|{qid}|{tags}{mz(cc[0])}{gate}N|{text}{cc[1]}|")
                    st[f"steps_{cc[2]}"] += 1
                else:
                    lines.append(f"C {name}|QID|{qid}|{tags}{gate}N|{text} No coordinates on the wiki.|")
                    st["steps_none"] += 1
                st["steps"] += 1
            if not counted:
                f = fb.get(qid, "C") if fb else None
                prose = clean(r["objectives_text"]) or "Complete the objectives."
                if f:
                    lines.append(f"C {name}|QID|{qid}|M|{f[0]}|Z|{f[1]}|{gate}N|{prose} (location: {f[2]})|")
                    st["steps_fallback"] += 1
                    st["steps"] += 1
                elif r["objectives_text"] and not DELIVERY.match(r["objectives_text"]):
                    lines.append(f"C {name}|QID|{qid}|{gate}N|{prose}|")
                    st["steps_none"] += 1
                    st["steps"] += 1
            # T (skipped for bonus objectives: they complete on their own)
            if not re.search(r"bonus objective", r["qtype"] or "", re.I):
                c, suf, src = loc_tag("end", ends, "T")
                who = next((clean(e.get("label") or e.get("title"), 60) for e in ends if e.get("title")), "")
                note = f"To {who}." if who else "Turn in."
                if c:
                    lines.append(f"T {name}|QID|{qid}|{mz(c)}{gate}N|{note}{suf}|")
                    if fl == "retail" and src == "wiki" and c[0] != "Z" and fb:
                        f = fb.get(qid, "T")
                        if f and f[2] == "Blizzard data" and f[1].split(";")[0].strip() == str(c[0]):
                            a = [float(v) for v in c[1].split(";")[0].split(",")]
                            b2 = [float(v) for v in f[0].split(";")[0].split(",")]
                            yd = self.atlas.yards(fl, c[0], a, b2)
                            if yd and yd > 50:
                                self.conflicts.append((fl, qid, "turnin_xy", f"{c[0]}:{c[1]}", f"{f[1]}:{f[0]}",
                                                       r["page_title"], r["revid"], f"{yd:.0f} yd apart"))
                else:
                    lines.append(f"T {name}|QID|{qid}|{gate}N|{note} No coordinates on the wiki.|")
                st[f"steps_{src}"] += 1
                st["steps"] += 1
            # home zone: the quest-log category when it is a map, else where the steps are
            hm = zmid if zmid is not None else first_map
            if hm is None:
                for ln in lines:
                    m = re.search(r"\|Z\|(\d+)", ln)
                    if m and int(m.group(1)) in maps.maps:
                        hm = int(m.group(1))
                        break
            hm = maps.home(hm) if hm is not None else 0
            fac = r["faction"] if r["faction"] in ("Alliance", "Horde") else "Both"
            lv = r["level"] if (r["level"] or 0) > 0 else None
            guides[(hm, fac)].append((qid, lv, r["levelreq"], name, lines))
            steps_out[qid] = len(lines)

        # ---- write ------------------------------------------------------------------------------------
        today = datetime.date.today().isoformat()
        out = GUIDES / f"Imported_Wiki_{fl}.lua"
        hdr = [
            f"-- Completionist's Guide :: Imported_Wiki_{fl}.lua - GENERATED {today} by tools/wiki/gen_wiki_guides.py",
            "-- Quest data (names, ids, givers, enders, chains, objectives, coordinates) is derived from",
            "-- Warcraft Wiki, https://warcraft.wiki.gg, by its contributors, licensed under CC BY-SA 4.0",
            "-- (https://creativecommons.org/licenses/by-sa/4.0/). This data file is shared under the same licence;",
            "-- see Guides/WIKI_DATA_LICENSE.md. Page histories (authors) are on each quest's wiki page.",
            "-- Flavor membership: Blizzard client QuestV2 table via wago.tools (facts only).",
        ]
        if self.use_fallback:
            hdr.append("-- Steps whose note says \"(location: Blizzard data)\" / \"(location: Questie data)\" took their map "
                       "point from Imported_Quests_" + fl + ".lua because the wiki has none; those points are not "
                       "wiki data. Regenerate with --no-fallback for a wiki-only file.")
        hdr += ["local _, NS = ...", flavor_gate(fl), "local R = NS.Guide.Register", ""]
        body = []
        # zone order, split of huge zone guides and the step order inside each guide: tools/wiki/gen_spine.py
        parts, cycles = gen_spine.build_parts(fl, guides, pre, maps, chosen)
        for p in parts:
            gname = p["name"].replace('"', '\\"')
            zfield = str(p["zone"]) if p["zone"] is not None else '"Other"'
            facf = f'faction="{p["faction"]}", ' if p["faction"] != "Both" else ""
            levels = f"minlevel={p['minlevel']}, maxlevel={p['maxlevel']}, "
            # forever=true: the points are already on Forever's maps (Core/Guide.lua skips the Era->Forever remap)
            native = "forever=true, " if fl == "forever" else ""
            if p.get("oversize"):
                native += f'oversize="{p["oversize"]}", '
            body.append(f'R({{ id="{p["id"]}", name="{gname}", type="Quests", zone={zfield}, {facf}{levels}'
                        f'{native}author="Warcraft Wiki contributors (CC BY-SA 4.0)", source="CompletionRoute", text=[==[')
            body.extend(p["lines"])
            body.append("]==] })")
        nguides = len(parts)
        out.write_text("\n".join(hdr + body) + "\n", encoding="utf-8")
        gen_spine.write_sidecar(fl, parts, pre, cycles)
        st["guides"] = nguides
        st["zone_guides"] = len(guides)
        st["file_kb"] = out.stat().st_size // 1024

        # ---- gaps file: the old generated guides minus the quests the wiki now covers ------------------
        old = GUIDES / f"Imported_Quests_{FALLBACK_OF.get(fl, fl)}.lua"
        gap_out = GUIDES / f"Imported_Quests_{fl}_gaps.lua"
        kept_q, dropped_q = set(), set()
        if old.exists():
            res, block, keep_lines = [], None, 0
            for ln in old.read_text(encoding="utf-8", errors="replace").splitlines():
                if ln.startswith("R({"):
                    block, keep_lines = [ln], 0
                    continue
                if block is not None:
                    if ln.startswith("]==] })"):
                        block.append(ln)
                        if keep_lines:
                            res.extend(block)
                        block = None
                        continue
                    m = re.search(r"\|QID\|(\d+)", ln)
                    if m and int(m.group(1)) in chosen:
                        dropped_q.add(int(m.group(1)))
                        continue
                    if m:
                        kept_q.add(int(m.group(1)))
                    keep_lines += 1 if ln.strip() else 0
                    block.append(ln)
                    continue
                if ln.startswith("-- "):
                    continue
                if re.match(r'^if NS\.flavor ~= "\w+" then return end$', ln):
                    ln = flavor_gate(fl)
                res.append(ln)
            gap_hdr = [f"-- Imported_Quests_{fl}_gaps.lua - GENERATED {today} by tools/wiki/gen_wiki_guides.py from "
                       f"Imported_Quests_{FALLBACK_OF.get(fl, fl)}.lua:",
                       "-- the same guides with every quest that Imported_Wiki_" + fl + ".lua covers removed, so no quest is "
                       "listed twice. Local use only - gitignored (source data: "
                       + ("Blizzard quest POI + Questie" if fl == "retail" else "Questie, GPL") + ")."]
            gap_out.write_text("\n".join(gap_hdr + res) + "\n", encoding="utf-8")
        st["gap_quests_kept"] = len(kept_q - dropped_q)
        st["old_quests_now_wiki"] = len(dropped_q)

        # ---- SQL ---------------------------------------------------------------------------------------
        db = sqlite3.connect(WIKI)
        db.executescript("""
        create table if not exists flavor_quests(flavor text, quest_id int, page_title text, steps int,
            primary key(flavor, quest_id));
        create table if not exists flavor_gap(flavor text, quest_id int, in_old_guides int, primary key(flavor, quest_id));
        create table if not exists flavor_skip(flavor text, quest_id int, page_title text, reason text);
        create table if not exists gen_stats(flavor text, metric text, value int, primary key(flavor, metric));
        """)
        for t in ("flavor_quests", "flavor_gap", "flavor_skip", "gen_stats"):
            db.execute(f"delete from {t} where flavor=?", (fl,))
        db.executemany("insert into flavor_quests values (?,?,?,?)",
                       [(fl, q, chosen[q]["page_title"], steps_out.get(q, 0)) for q in chosen])
        db.executemany("insert into flavor_gap values (?,?,?)",
                       [(fl, q, 1 if q in kept_q else 0) for q in gaps])
        db.executemany("insert into flavor_skip values (?,?,?,?)", skip)
        db.executemany("insert into gen_stats values (?,?,?)", [(fl, k, v) for k, v in st.items()])
        db.commit()
        return st

    def write_conflicts(self, flavors):
        con = sqlite3.connect(VERIF)
        con.execute("""create table if not exists wiki_db2_conflict(flavor text, quest_id int, field text,
                       wiki_value text, db2_value text, page_title text, revid int, note text)""")
        con.executemany("delete from wiki_db2_conflict where flavor=?", [(f,) for f in flavors])
        con.executemany("insert into wiki_db2_conflict values (?,?,?,?,?,?,?,?)", self.conflicts)
        con.commit()
        return Counter((c[0], c[2]) for c in self.conflicts)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flavors = args or FLAVORS
    g = Gen(fallback="--no-fallback" not in sys.argv)
    print(f"{len(g.rows)} wiki quest rows, {len({r['id'] for r in g.rows})} ids")
    for fl in flavors:
        st = g.run(fl)
        s = st["steps"] or 1
        print(f"{fl:6} wiki ids {st['wiki_quest_ids']}, assigned {st['assigned']}, guides {st['guides']}, "
              f"steps {st['steps']}: wiki coords {st['steps_wiki']} ({100*st['steps_wiki']/s:.1f}%), fallback "
              f"{st['steps_fallback']} ({100*st['steps_fallback']/s:.1f}%), none {st['steps_none']} "
              f"({100*st['steps_none']/s:.1f}%); DB2-only gap {st['db2_only_gap']}; old guides: "
              f"{st['old_quests_now_wiki']} quests now from wiki, {st['gap_quests_kept']} kept in _gaps; {st['file_kb']} KB")
        print(f"       zone guides {st['zone_guides']} -> {st['guides']} guides after splitting (gen_spine.MAX_STEPS)")
        if "--no-spine" not in sys.argv:
            gen_spine.build_spine(fl, flavor_gate(fl))
    c = g.write_conflicts(flavors)
    print("conflicts logged (docs/verification.sqlite wiki_db2_conflict):", dict(c))
    print(f"subzone rows corrected (a parent-zone row on the same page disagrees): {len(g.subzone_dropped)}; first: {g.subzone_dropped[:8]}")


if __name__ == "__main__":
    main()
