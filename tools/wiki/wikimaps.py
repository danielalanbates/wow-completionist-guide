# CompletionRoute :: tools/wiki/wikimaps.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Offline zone-name -> uiMapID resolution and cross-version coordinate conversion for the wiki pipeline.

Mirrors Core/Util.lua U.MapIDByName (normalised name, "The " retry, NS.ZoneNameAliases, prefer mapType 3 then the
lowest id) and the world-coordinate math of tools/gen_quest_guides_retail.py to_zone():
    y01 = (topX - worldX) / height        x01 = (leftY - worldY) / width
Warcraft Wiki coordinates are retail-map percentages unless the zone carries a version suffix:
"(Classic)" / "(Forever)" / "(Season of Discovery)" = the Classic Era map, "(Burning Crusade)" = the TBC map,
"(alternate universe)" = the Draenor copy.  A point is carried to another client's map set through world
coordinates (same continent instance), so a pre-Cataclysm Barrens point lands on the right post-Cata zone.
A subzone map (retail's Valley of Trials) that the target client does not have lands on its PARENT zone, never on
whichever neighbouring zone rectangle happens to contain the point.  A zone only one client has (Forever's Zephras
Isle) is read on that client's own maps.

    python3 tools/wiki/wikimaps.py     # regression checks, run by tools/test_wiki.lua
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SETS = ("era", "tbc", "mop", "retail", "forever")
RE_MAP = re.compile(r'\[(\d+)\] = \{ "((?:[^"\\]|\\.)*)", (-?\d+), (-?[\d.]+), (-?[\d.]+), (-?[\d.]+), (-?[\d.]+), '
                    r'(\d+), (\d+) \}')
CAPITALS = {"Stormwind City", "Orgrimmar", "Ironforge", "Undercity", "Thunder Bluff", "Darnassus", "The Exodar",
            "Silvermoon City", "Shattrath City", "Dalaran", "Boralus", "Dazar'alor", "Oribos", "Valdrakken", "Dornogal"}
# wiki article names that are not map names (docs/WIKI_DATA_SPEC.md 7) -> candidate map names, tried in order
EXTRA_ALIASES = {
    "Barrens": ["The Barrens", "Northern Barrens"],
    "Scarlet Enclave": ["Plaguelands: The Scarlet Enclave", "The Scarlet Enclave"],
    "Emerald Dream": ["Emerald Dream"],
    "Exodar": ["The Exodar"],
    "Stormwind": ["Stormwind City"],
    "Hinterlands": ["The Hinterlands"],
    "Shattrath": ["Shattrath City"],
    "Dalaran (Northrend)": ["Dalaran"],
    "Dalaran (Broken Isles)": ["Dalaran"],
    "Cape of Stranglethorn": ["The Cape of Stranglethorn"],
    "Storm Peaks": ["The Storm Peaks"],
    "Jade Forest": ["The Jade Forest"],
    "Veiled Stair": ["The Veiled Stair"],
    "Wandering Isle": ["The Wandering Isle"],
    "Lost Isles": ["The Lost Isles"],
    "Maelstrom": ["The Maelstrom"],
    "Deadmines": ["The Deadmines", "Deadmines"],
    "Stockade": ["The Stockade", "Stormwind Stockade"],
}


def norm(s):
    return re.sub(r"[^0-9a-z]", "", (s or "").lower())


def load_maps(flavor):
    txt = (ROOT / "tools" / f"maps_{flavor}.lua").read_text(encoding="utf-8")
    maps = {}
    for m in RE_MAP.finditer(txt):
        maps[int(m.group(1))] = dict(name=m.group(2).replace('\\"', '"').replace("\\\\", "\\"), inst=int(m.group(3)),
                                     topX=float(m.group(4)), leftY=float(m.group(5)), w=float(m.group(6)),
                                     h=float(m.group(7)), parent=int(m.group(8)), type=int(m.group(9)))
    return maps


def load_name_aliases():
    txt = (ROOT / "CompletionRoute" / "Data" / "ZoneAliases.lua").read_text(encoding="utf-8")
    out = {}
    block = txt.split("NS.ZoneNameAliases", 1)[-1]
    for m in re.finditer(r'\["([^"]+)"\]\s*=\s*\{([^}]*)\}', block):
        out[m.group(1)] = re.findall(r'"([^"]+)"', m.group(2))
    for k, v in EXTRA_ALIASES.items():
        out.setdefault(k, [])
        out[k] = out[k] + [x for x in v if x not in out[k]]
    return out


class MapSet:
    def __init__(self, flavor, aliases):
        self.flavor = flavor
        self.maps = load_maps(flavor)
        self.aliases = aliases
        self.by_norm = {}
        for mid, m in self.maps.items():
            self.by_norm.setdefault(norm(m["name"]), []).append(mid)
        self.cache = {}
        self.by_inst = {}
        for mid, m in self.maps.items():
            if m["w"] and m["h"] and m["type"] in (3, 4, 5, 6):
                self.by_inst.setdefault(m["inst"], []).append(mid)

    def _best(self, ids):
        return sorted(ids, key=lambda i: (self.maps[i]["type"] != 3, i))[0]

    def resolve(self, name, added_patch=None, draenor=False):
        """zone/article name -> uiMapID on this client, or None"""
        key = (name, added_patch is not None and added_patch >= (12, 0, 0), draenor)
        if key in self.cache:
            return self.cache[key]
        r = self._resolve(name, *key[1:])
        self.cache[key] = r
        return r

    def _resolve(self, name, midnight, draenor):
        if not name:
            return None
        n = re.sub(r"\s*\((classic|forever|burning crusade|season of discovery|zone|alternate universe|"
                   r"bc classic|wrath classic|cata classic|mop classic)\)\s*$", "", name.strip(), flags=re.I)
        cands = []
        for nm in [n, "The " + n] + self.aliases.get(n, []) + self.aliases.get("The " + n, []):
            ids = self.by_norm.get(norm(nm))
            if ids:
                cands = ids
                break
        if not cands:
            return None
        if draenor:
            dr = [i for i in cands if self.maps[i]["inst"] == 1116]
            if dr:
                return self._best(dr)
        if self.flavor == "retail" and midnight and norm(n) in ("eversongwoods", "silvermooncity"):
            return 2395 if norm(n) == "eversongwoods" else 2393
        if self.flavor == "retail" and not draenor:
            nd = [i for i in cands if self.maps[i]["inst"] != 1116]
            cands = nd or cands
        return self._best(cands)

    def to_world(self, mid, x, y):
        m = self.maps.get(mid)
        if not m or m["w"] == 0 or m["h"] == 0:
            return None
        return m["inst"], m["topX"] - (y / 100.0) * m["h"], m["leftY"] - (x / 100.0) * m["w"]

    def from_world(self, inst, wx, wy, prefer_name=None, also_prefer=()):
        """world point -> (uiMapID, x, y) on this client.  Zone rectangles overlap, so: a map with the source
        name (or one of its NS.ZoneNameAliases successors) that contains the point wins; then, for a subzone map
        the target client does not have, the maps of the zones it sits in on the source client (`also_prefer`,
        nearest ancestor first); otherwise the zone-type map in which the point sits most centrally (adjacent zones'
        rectangles reach into each other, which is how Valley of Trials used to land in The Barrens)."""
        pool = self.by_inst.get(inst, [])
        pset = set(pool)
        wanted = []
        if prefer_name:
            wanted.append(prefer_name)
        for extra in also_prefer:
            if extra not in wanted:
                wanted.append(extra)
        for name in wanted:
            names = [name] + self.aliases.get(name, [])
            if name.startswith("The "):
                names += self.aliases.get(name[4:], [])
            for nm in names:
                same = [i for i in self.by_norm.get(norm(nm), []) if i in pset]
                for mid in sorted(same, key=lambda i: (self.maps[i]["type"] != 3, i)):
                    m = self.maps[mid]
                    y01 = (m["topX"] - wx) / m["h"]
                    x01 = (m["leftY"] - wy) / m["w"]
                    if -0.005 <= x01 <= 1.005 and -0.005 <= y01 <= 1.005:
                        return mid, min(max(x01, 0), 1) * 100, min(max(y01, 0), 1) * 100
        # nothing named matched: the most central zone map, not a dungeon/micro map (those can sit inside anything)
        best = None
        for mid in pool:
            m = self.maps[mid]
            y01 = (m["topX"] - wx) / m["h"]
            x01 = (m["leftY"] - wy) / m["w"]
            if not (-0.005 <= x01 <= 1.005 and -0.005 <= y01 <= 1.005):
                continue
            central = max(abs(x01 - 0.5), abs(y01 - 0.5))
            score = (0 if m["type"] == 3 else 1, round(central, 3), mid)
            if best is None or score < best[0]:
                best = (score, mid, min(max(x01, 0), 1) * 100, min(max(y01, 0), 1) * 100)
        return (best[1], best[2], best[3]) if best else None

    def ancestors(self, mid):
        """names of the maps above `mid` on this client, nearest first (zone before continent; a subzone's zones)"""
        out, seen = [], 0
        m = self.maps.get(mid)
        while m and m["parent"] in self.maps and seen < 6:
            m = self.maps[m["parent"]]
            if m["type"] >= 3 and m["name"] not in out:
                out.append(m["name"])
            seen += 1
        return out

    def is_ancestor(self, parent, mid):
        """is `parent` on `mid`'s parent chain?"""
        seen = 0
        while mid in self.maps and seen < 6:
            mid, seen = self.maps[mid]["parent"], seen + 1
            if mid == parent:
                return True
        return False

    def home(self, mid):
        """the zone a map belongs to for guide grouping: subzone maps lift to their zone, capitals stay"""
        seen = 0
        while mid in self.maps and seen < 6:
            m = self.maps[mid]
            p = self.maps.get(m["parent"])
            if m["type"] == 3 and m["name"] in CAPITALS:
                return mid
            if m["type"] in (3, 4) and not (p and p["type"] == 3):
                return mid
            if not p or p["type"] < 3:
                return mid
            mid = m["parent"]
            seen += 1
        return mid


class Atlas:
    """all four clients' map sets + the conversion between them"""

    def __init__(self):
        al = load_name_aliases()
        self.sets = {f: MapSet(f, al) for f in SETS}

    def source_set(self, zone, page_classic):
        z = (zone or "").lower()
        if "(forever)" in z:
            return "forever"   # written on Forever's own (partly reshaped) maps
        if "(classic)" in z or "(season of discovery)" in z:
            return "era"
        if "(burning crusade)" in z or "(bc classic)" in z:
            return "tbc"
        if page_classic and self.sets["era"].resolve(zone) is not None:
            return "era"
        return "retail"

    def place(self, zone, x, y, target, page_classic=False, added=None):
        """wiki (zone, x, y) -> (uiMapID, x, y) on the target client's maps, or None"""
        src = self.source_set(zone, page_classic)
        draenor = "alternate universe" in (zone or "").lower()
        S = self.sets[src]
        smid = S.resolve(zone, added, draenor)
        if smid is None:
            # the map exists only on some other client's set (Forever's Zephras Isle is on no other client)
            for other in ("forever", "era", "tbc", "mop", "retail"):
                if other != src:
                    cand = self.sets[other].resolve(zone, added, draenor)
                    if cand is not None:
                        src, S, smid = other, self.sets[other], cand
                        break
        if smid is None:
            return None
        T = self.sets[target]
        if src == target:
            return smid, x, y
        w = S.to_world(smid, x, y)
        sname = S.maps[smid]["name"]
        if w is None:
            tmid = T.resolve(sname)
            return (tmid, x, y) if tmid is not None else None
        # A subzone map on the source client (Valley of Trials on retail) has no twin on the target: the point
        # belongs to the zone that map sits in, not to whichever zone rectangle happens to reach over it.
        r = T.from_world(w[0], w[1], w[2], prefer_name=sname, also_prefer=S.ancestors(smid))
        if r is None:
            # the target client has no map there (e.g. a retail-only zone on Classic)
            return None
        return r

    def yards(self, flavor, mid, a, b):
        m = self.sets[flavor].maps.get(mid)
        if not m:
            return None
        dx = (a[0] - b[0]) / 100.0 * m["w"]
        dy = (a[1] - b[1]) / 100.0 * m["h"]
        return (dx * dx + dy * dy) ** 0.5

    def subzone_conflict(self, sub, parent, page_classic=False, tolerance=60.0):
        """sub, parent = (zone, x, y) rows from one wiki page.  True when `sub` is on a subzone map of `parent`'s zone
        and the two rows are more than `tolerance` yards apart: the same NPC cannot be in both, and the subzone row is
        the one read off a floor or cave map (Gornek: 'Valley of Trials 63.4, 83.0' inside the Den against 'Durotar
        43.2, 68.2'; carried through world coordinates the first is 300 yd from the second)."""
        src = self.source_set(sub[0], page_classic)
        if src != self.source_set(parent[0], page_classic):
            return False
        S = self.sets[src]
        a, b = S.resolve(sub[0]), S.resolve(parent[0])
        if a is None or b is None or a == b or S.maps[b]["type"] < 3 or not S.is_ancestor(b, a):
            return False    # only a zone can overrule its subzone: a row on a continent map says too little
        wa, wb = S.to_world(a, sub[1], sub[2]), S.to_world(b, parent[1], parent[2])
        if not wa or not wb or wa[0] != wb[0]:
            return False
        return ((wa[1] - wb[1]) ** 2 + (wa[2] - wb[2]) ** 2) ** 0.5 > tolerance


def _selfcheck():
    A = Atlas()

    def check(ok, msg):
        if not ok:
            raise SystemExit("FAIL wikimaps: " + msg)
    # a subzone only some clients have lands on the parent zone, wherever in the subzone the point is
    for fl in ("era", "tbc", "forever"):
        for x, y in ((63.4, 83.0), (43.0, 62.6), (1.0, 1.0), (99.0, 99.0)):
            r = A.place("Valley of Trials", x, y, fl)
            check(r is not None and r[0] == 1411, f"Valley of Trials {x},{y} on {fl} -> {r}, want Durotar 1411")
    r = A.place("Valley of Trials", 43.0, 62.6, "era")   # Galgar: the same place as the wiki's own Durotar row
    check(abs(r[1] - 42.8) < 0.5 and abs(r[2] - 67.2) < 0.5, f"Galgar on era {r}")
    check(A.place("Valley of Trials", 43.0, 62.6, "retail") == (461, 43.0, 62.6), "retail keeps its own subzone map")
    # the other starting zones, near each subzone map's edge as well as its centre
    for name, parent in (("Northshire", "Elwynn Forest"), ("Deathknell", "Tirisfal Glades"), ("Camp Narache", "Mulgore"),
                         ("Coldridge Valley", "Dun Morogh"), ("Shadowglen", "Teldrassil")):
        for fl in ("era", "tbc"):
            want = A.sets[fl].resolve(parent)
            for x, y in ((50.0, 50.0), (5.0, 95.0), (95.0, 5.0)):
                r = A.place(name, x, y, fl)
                check(r is not None and r[0] == want, f"{name} {x},{y} on {fl} -> {r}, want {parent} {want}")
    # a zone only Forever has
    z = A.place("Zephras Isle", 40.0, 50.0, "forever")
    check(z is not None and A.sets["forever"].maps[z[0]]["name"] == "Zephras Isle" and z[1:] == (40.0, 50.0), f"Zephras Isle on forever {z}")
    check(A.place("Zephras Isle", 40.0, 50.0, "era") is None, "Zephras Isle must not exist on era")
    # one page's subzone row against its parent-zone row
    check(A.subzone_conflict(("Valley of Trials", 63.4, 83.0), ("Durotar", 43.2, 68.2)) is True, "Gornek conflict not seen")
    check(A.subzone_conflict(("Valley of Trials", 43.0, 62.6), ("Durotar", 42.8, 67.2)) is False, "Galgar is not a conflict")
    check(A.subzone_conflict(("Durotar", 43.2, 68.2), ("Valley of Trials", 63.4, 83.0)) is False, "a parent is never the conflict")
    print("wikimaps regression checks passed")


if __name__ == "__main__":
    _selfcheck()
