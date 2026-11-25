#!/usr/bin/env python3
# CompletionRoute :: tools/wiki/gen_dungeons.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Dungeon and raid routes: the quests leading up to an instance, the quests inside it, the door, the turn-ins.

    nice -n 10 python3 tools/wiki/gen_dungeons.py [era tbc mop retail forever] [--out DIR]

Owner's request (2026-11-16): "We need a dungeons section that includes all the quests leading up to the dungeon".
One route per dungeon or raid that has quests on a client, per faction where the quests differ; docs/DUNGEONS.md.

Inputs (read only):
  CompletionRoute/Guides/Imported_Wiki_<fl>.lua   the wiki quest steps this client ships (tools/wiki/gen_wiki_guides.py):
                                                  every step line of a dungeon route is one of these lines, so the
                                                  client's quest filtering (faction, flavor, added/removed patch, Classic
                                                  only, Forever) is exactly the zone routes' own
  tools/wiki/wiki.sqlite                          flavor_quests (which wiki page each client took for a quest), quests,
                                                  quest_objectives, npcs, items
  tools/wiki/cache/wiki_raw.sqlite                the wiki's instance pages ({{Infobox instance}}: name, type, location,
                                                  key) and their client-version twins ("(Classic)", "(BC Classic)")
  tools/db2/<fl>/Map.csv, JournalInstance.csv     Blizzard instance maps per client (which instances a client has, raid
                                                  or dungeon, expansion); fetched by tools/wiki/db2_fetch.py when absent
  tools/db2/retail/JournalInstanceEntrance.csv    Retail only: the Encounter Journal's door pin of each instance, in world
                                                  coordinates (the door itself)
  tools/db2/retail/Map.csv                        the Corpse position of each instance map: where a ghost is sent back
                                                  to, the instance entrance, in world coordinates
  tools/maps_<fl>.lua                             uiMaps (tools/wiki/wikimaps.py): the entrance on the client's zone map,
                                                  and the instance's own map (where the client has one)
Outputs:
  CompletionRoute/Guides/Imported_Dungeons_<fl>.lua    the routes (CC BY-SA 4.0 data; gitignored like every Imported_*)
  docs/verification.sqlite table dungeon_routes        one row per (client, instance, faction): routed or why not
  --out DIR writes both into DIR instead (DIR/Imported_Dungeons_<fl>.lua, DIR/verification.sqlite).

Which quests belong to an instance (a quest belongs to at most one):
  1. its quest-log category (the wiki questbox zone/category) names the instance;
  2. else one of its objective steps lies on the instance's own map on this client (|Z| of that map);
  3. else every objective whose target the wiki places (the NPC page's zone, an item's drop source's zone) is in the
     instance, and at least one is.
  An instance page with no Blizzard map on the client (a wing page such as Capital Gardens) borrows the map of the
  instance its location names (Dire Maul).

A route, in order (docs/DUNGEONS.md 2):
  1. lead-up: every quest the instance quests need first (their |PRE| tags, followed back until nothing is missing; of
     "any one of" alternatives the one the route's faction can take, then the lowest level, then the lowest id), plus
     attunement and key quests (a quest named "Attunement to <instance>", "Entry Into <instance>", "The Key to
     <instance>", or the key item the instance infobox names), each with all its steps, prerequisites first;
  2. pick-ups: the accept steps of the instance quests whose giver stands outside;
  3. the door: "D Enter <instance>" at the entrance (the wiki infobox's {{Coords}}, else on Retail the Encounter
     Journal door pin, else the Blizzard Map Corpse position converted to the client's zone map; on a Classic client
     only when it lies in the zone the wiki infobox names), else the instance's own map (the add-on
     routes to a door it has learned, Core/Instances.lua), else the zone the infobox names, with the wiki's words;
  4. inside: the objective steps, and the accepts / turn-ins of quests whose giver or ender stands inside, in chain
     order.  A step with no point gets the instance's own map, or on a client without one the entrance point;
  5. turn-ins outside, then the follow-up quests the run unlocks (quests whose |PRE| names an instance quest).
  A quest that needs another instance quest turned in outside first goes in a second pass (a second "Enter"); a
  prerequisite that itself needs an instance quest is done between the two passes.  Where the wiki's chains loop, the
  quests nothing can unlock follow at the end as written (dungeon_routes.unordered_quests).
Every line keeps the zone route's tags, so progress keys, prefill, skip, quest counts and the route order work unchanged.
"""
import csv
import datetime
import json
import os
import re
import sqlite3
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import wikimaps  # noqa: E402
import wikitext as WT  # noqa: E402
import db2_fetch  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
WIKI = ROOT / "tools" / "wiki" / "wiki.sqlite"
RAW = ROOT / "tools" / "wiki" / "cache" / "wiki_raw.sqlite"
GUIDES = ROOT / "CompletionRoute" / "Guides"
VERIF = ROOT / "docs" / "verification.sqlite"
FLAVORS = ["era", "tbc", "mop", "retail", "forever"]
csv.field_size_limit(1 << 28)

EXPANSIONS = ["Classic", "Burning Crusade", "Wrath of the Lich King", "Cataclysm", "Mists of Pandaria",
              "Warlords of Draenor", "Legion", "Battle for Azeroth", "Shadowlands", "Dragonflight", "The War Within",
              "Midnight", "The Last Titan"]
# which wiki page twin a client reads first (the base page is always the last resort)
PAGE_PREF = {"era": ["(Classic)"], "forever": ["(Classic)"], "tbc": ["(BC Classic)", "(Burning Crusade)", "(Classic)"],
             "mop": ["(Burning Crusade)"], "retail": []}
SUFFIX = re.compile(r"\s*\((instance|raid|dungeon|Classic|BC Classic|Burning Crusade|Season of Discovery|pet battle|"
                    r"Timewalking|scenario|delve|alternate universe)\)\s*$", re.I)
NEVER_PAGES = re.compile(r"\((Season of Discovery|pet battle|Timewalking|scenario|delve)\)\s*$", re.I)
CLASSIC_POINT_CHECK = ("era", "tbc", "forever")      # Blizzard's Corpse positions are the current game's
STEP = re.compile(r"^([ACT]) .*?\|QID\|(\d+)\|")
TEXT_BLOCK = re.compile(r"text\s*=\s*\[(=*)\[(.*?)\]\1\]", re.S)
ATTUNE = re.compile(r"^(?:Attunement to|Entry Into|The Key to|Key to)\s+(?:the\s+)?(.+?)\s*$", re.I)
PASS_WORDS = ["", " again", " a third time", " a fourth time"]
NO_COORDS = re.compile(r"\s*No coordinates on the wiki(?:; the quest is in [^.|]*)?\.\s*$")


def norm(s):
    s = (s or "").lower().strip()
    s = re.sub(r"^the\s+", "", s)
    return re.sub(r"[^0-9a-z]", "", s)


def base_title(t):
    return SUFFIX.sub("", t or "").strip()


def plain(s):
    """wiki markup -> plain words (links to their labels, templates dropped)"""
    s = re.sub(r"\{\{[^{}]*\}\}", "", s or "")
    s = re.sub(r"\[\[(?:[^\]|]*\|)?([^\]]*)\]\]", r"\1", s)
    s = re.sub(r"<[^>]+>", " ", s)
    return re.sub(r"\s+", " ", s).replace("|", "/").strip(" ,.;")


def link_titles(s):
    return [WT.norm_title(m.group(1)) for m in re.finditer(r"\[\[([^\]|#]+)", s or "")]


# tags Core/Guide.lua G.ParseLine reads without a value (tools/gen_quest_deps.py BOOL_TAGS)
BOOL_TAGS = {"O", "S", "US", "S!US", "NC", "NA", "NOAUTO", "CC", "CS", "CN", "ROUTE", "FIXED", "RUNE", "ELITE", "RARE",
             "DUNGEON", "CHAT", "H", "I", "V", "FAIL", "AP", "CT", "MS", "TOF", "EAB", "NOCACHE"}


def split_line(line):
    """'A Title|QID|1|O|M|..|' -> (head, [(tag, value or None), ...]): the add-on's own reading of a step line"""
    parts = line.rstrip("|").split("|")
    head, pairs = parts[0], []
    i = 1
    while i < len(parts):
        if parts[i] in BOOL_TAGS:
            pairs.append((parts[i], None))
            i += 1
            continue
        pairs.append((parts[i], parts[i + 1] if i + 1 < len(parts) else ""))
        i += 2
    return head, pairs


def join_line(head, pairs):
    return head + "|" + "".join(f"{t}|" if v is None else f"{t}|{v}|" for t, v in pairs)


def tag(line, name):
    for t, v in split_line(line)[1]:
        if t == name:
            return v
    return None


def zone_of(line):
    z = tag(line, "Z")
    m = re.match(r"\s*(\d+)", z or "")
    return int(m.group(1)) if m else None


def lua_str(s):
    return (s or "").replace("\\", "\\\\").replace('"', '\\"')


class Instances:
    """the instance catalog of one client: wiki instance pages matched to the client's Blizzard instance maps"""

    def __init__(self, fl, maps, raw_pages, retail_map, atlas=None):
        self.fl, self.maps, self.atlas = fl, maps, atlas
        fmap = db2_fetch.rows(fl, "Map")
        self.map_rows = {int(r["ID"]): r for r in fmap if r.get("InstanceType") in ("1", "2")}
        self.by_name = defaultdict(set)              # normalised name -> map ids (this client's instance maps)
        for mid, r in self.map_rows.items():
            nm = r.get("MapName_lang") or ""
            self.by_name[norm(nm)].add(mid)
            if ":" in nm:
                self.by_name[norm(nm.split(":", 1)[1])].add(mid)
        self.ji = defaultdict(set)                     # Encounter Journal names -> map ids (any client's journal)
        self.ji_names = defaultdict(set)               # map id -> Encounter Journal names
        for src in (fl, "mop", "retail"):
            for r in db2_fetch.rows(src, "JournalInstance"):
                try:
                    self.ji[norm(r["Name_lang"])].add(int(r["MapID"]))
                    self.ji_names[int(r["MapID"])].add(r["Name_lang"])
                except (KeyError, ValueError):
                    pass
        self.retail_map = retail_map
        # Blizzard's own door pins (JournalInstanceEntrance: the Encounter Journal's entrance marker in world
        # coordinates, joined to the instance map through this client's JournalInstance). Only Retail has the table;
        # on the other clients both reads return nothing.
        ji_map = {}
        for r in db2_fetch.rows(fl, "JournalInstance"):
            try:
                ji_map[r["ID"]] = int(r["MapID"])
            except (KeyError, ValueError):
                pass
        self.journal_doors = defaultdict(list)         # instance map id -> [(world x, world y, continent), ...]
        for r in sorted(db2_fetch.rows(fl, "JournalInstanceEntrance"), key=lambda r: (r.get("Faction") != "-1", int(r["ID"]))):
            try:
                mid, wx, wy, cont = ji_map[r["JournalInstanceID"]], float(r["Position_0"]), float(r["Position_1"]), int(r["MapID"])
            except (KeyError, ValueError):
                continue
            if not (wx == 0 and wy == 0):
                self.journal_doors[mid].append((wx, wy, cont))
        self.ui_of = defaultdict(list)                 # instance map id -> this client's uiMaps of it
        for uid, m in maps.maps.items():
            if m["type"] in (4, 5, 6) and m["inst"] in self.map_rows:
                self.ui_of[m["inst"]].append(uid)
        self.pages = {}
        self.lfg = None
        self.load_pages(raw_pages)

    def load_pages(self, raw_pages):
        groups = defaultdict(dict)                     # base -> {page title: (named fields, text)}
        for title, named, text in raw_pages:
            groups[base_title(title)][title] = (named, text)
        pref = PAGE_PREF[self.fl]
        for base in sorted(groups):
            pages = groups[base]
            pick = None
            for suf in pref:
                pick = next((t for t in pages if t.endswith(suf)), None)
                if pick:
                    break
            if not pick:
                plain_pages = [t for t in pages if not re.search(r"\((Classic|BC Classic|Burning Crusade)\)$", t)]
                cands = plain_pages or list(pages)
                # prefer a dungeon/raid page over an umbrella hub page whose type is blank (Auchindoun on Draenor vs Outland)
                typed = [t for t in cands if (pages[t][0].get("type") or "").strip()]
                pick = sorted(typed or cands)[0]
            named, text = pages[pick]
            self.pages[base] = {"base": base, "page": pick, "f": named, "text": text,
                                "name": plain(named.get("name") or "") or base}

    def map_for(self, d):
        """the client's instance map id for a catalog entry, or None"""
        names = [d["base"], d["name"]]
        for nm in names:
            for mid in sorted(self.ji.get(norm(nm), ())):
                if mid in self.map_rows:
                    return mid
        for nm in names:
            ids = sorted(self.by_name.get(norm(nm), ()))
            if ids:
                return ids[0]
        # "Upper Blackrock Spire" on a client whose one map is "Blackrock Spire": the longest map name inside the name
        best = None
        for key, ids in self.by_name.items():
            if len(key) >= 6 and key in norm(d["name"]) and (best is None or len(key) > len(best[0])):
                best = (key, sorted(ids)[0])
        return best[1] if best else None

    def lfg_level(self, d):
        """(low, high) of the client's own Dungeon Finder entry for the instance (Blizzard LFGDungeons: the normal
        difficulty with the lowest minimum level), or None"""
        if self.lfg is None:
            self.lfg = [r for r in db2_fetch.rows(self.fl, "LFGDungeons")]
        names = {norm(d["base"]), norm(d["name"])}
        best = None
        for r in self.lfg:
            try:
                mid, lo, hi, diff = int(r.get("MapID") or 0), int(r.get("MinLevel") or 0), int(r.get("MaxLevel") or 0), \
                    int(r.get("DifficultyID") or 0)
            except ValueError:
                continue
            if lo <= 0 or diff not in (0, 1, 3, 4, 9, 14):
                continue
            if not (mid == d["map"] or (mid == 0 and norm(r.get("Name_lang")) in names)):
                continue
            if best is None or lo < best[0]:
                best = (lo, hi if hi >= lo else None)        # MaxLevel 0: no upper bound (scaled raids)
        return best

    def is_instance_name(self, name):
        """does a Blizzard instance map (dungeon or raid) of this client carry this name?"""
        n = norm(name)
        return bool(self.by_name.get(n)) or any(m in self.map_rows for m in self.ji.get(n, ()))

    def kind_of(self, d, mid):
        t = (d["f"].get("type") or "").lower()
        if "scenario" in t or "delve" in t:
            return None
        if "raid" in t:
            return "Raid"
        if "dungeon" in t:
            return "Dungeon"
        if mid and mid in self.map_rows:
            return "Raid" if self.map_rows[mid]["InstanceType"] == "2" else "Dungeon"
        m = re.match(r"\s*(\d+)", d["f"].get("players") or "")
        if m:
            return "Dungeon" if int(m.group(1)) <= 5 else "Raid"
        return None

    def build(self):
        """-> {key: entry} for every instance page that is a dungeon or raid this client has"""
        out = {}
        for base, d in self.pages.items():
            mid = self.map_for(d)
            d["map"] = mid
            d["loc"] = d["f"].get("loc") or ""
            out[base] = d
        # a wing page without a map of its own takes the map of the instance its location names (Dire Maul wings)
        for base, d in out.items():
            if d["map"] is None:
                for lt in link_titles(d["loc"]):
                    p = out.get(base_title(lt))
                    if p and p is not d and p["map"] is not None:
                        d["map"], d["wing_of"] = p["map"], p["base"]
                        break
        keep = {}
        self.excluded = {}
        for base, d in out.items():
            kind = self.kind_of(d, d["map"])
            if d["map"] is None or kind is None:
                why = ("no Blizzard instance map on this client matches the wiki page" if d["map"] is None else
                       f"the wiki infobox type is '{plain(d['f'].get('type') or '')}', not a dungeon or raid")
                for nm in (base, d["name"]):
                    self.excluded.setdefault(norm(nm), (base, why))
                continue
            d["kind"] = kind
            r = self.map_rows[d["map"]]
            try:
                d["expansion"] = int(r.get("ExpansionID") or 0)
            except ValueError:
                d["expansion"] = 0
            d["ui"] = sorted(self.ui_of.get(d["map"], []))
            keep[base] = d
        self.names = {}
        for base, d in sorted(keep.items()):
            for nm in (base, d["name"]):
                self.names.setdefault(norm(nm), base)
        # the client's own names for a map only one page has ("Old Hillsbrad Foothills" = Escape from Durnholde Keep)
        per_map = Counter(d["map"] for d in keep.values())
        for base, d in sorted(keep.items()):
            if per_map[d["map"]] == 1:
                nm = self.map_rows[d["map"]].get("MapName_lang") or ""
                for alias in sorted(self.ji_names.get(d["map"], set()) | {nm, nm.split(":", 1)[-1]}):
                    if alias and norm(alias) not in self.excluded:
                        self.names.setdefault(norm(alias), base)
        return keep

    def entrance(self, d):
        """(uiMap, x, y, source) of the door on the client's zone map, or None"""
        locs = [nm for nm in link_titles(d["loc"])]
        if any(norm(nm) == "blackrockmountain" for nm in locs):
            locs += ["Burning Steppes", "Searing Gorge"]
        prefer = None
        also_prefer = []
        loc_maps = set()
        for nm in locs:
            mid = self.maps.resolve(nm)
            if mid and self.maps.maps[mid]["type"] == 3 and self.maps.maps[mid]["name"] != "The Great Sea":
                loc_maps.add(mid)
                mname = self.maps.maps[mid]["name"]
                if not prefer:
                    prefer = mname
                elif mname not in also_prefer:
                    also_prefer.append(mname)
        page_classic = "(Classic)" in d["page"]
        # 1. explicit {{Coords}} / {{co}} in the wiki infobox's loc= field
        if self.atlas:
            for cx, cy, czone, _s, _e in WT.coords(d["loc"]):
                z = czone or (locs[-1] if locs else "")
                hit = self.atlas.place(z, cx, cy, self.fl, page_classic=page_classic) if z else None
                if hit:
                    uid, px, py = hit
                    m = self.maps.maps.get(uid)
                    if m and m["type"] == 3 and m["name"] != "The Great Sea":
                        if self.fl not in CLASSIC_POINT_CHECK or not loc_maps or uid in loc_maps:
                            return uid, px, py, "wiki"
        # 2. Blizzard's Encounter Journal door pin (JournalInstanceEntrance; Retail only): the door itself. With several
        #    doors, the first one that lands on a zone the infobox names. A pin that lands on another zone ranks after
        #    a Corpse position on a named zone (Ruins of Ahn'Qiraj: the pin converts onto Uldum, the Corpse onto
        #    Silithus, the infobox says Silithus), and before one anywhere else.
        fallback_door = None
        for wx, wy, cont in self.journal_doors.get(d["map"], ()):
            hit = self.maps.from_world(cont, wx, wy, prefer_name=prefer, also_prefer=also_prefer)
            if hit:
                uid, x, y = hit
                m = self.maps.maps.get(uid)
                if m and m["type"] == 3 and m["name"] != "The Great Sea":
                    if not loc_maps or uid in loc_maps:
                        return uid, x, y, "journal"
                    fallback_door = fallback_door or (uid, x, y, "journal")
        if self.fl in CLASSIC_POINT_CHECK:
            fallback_door = None
        # 3. Blizzard Map table Corpse position (where a ghost returns to the instance)
        r = self.retail_map.get(d["map"])
        if r:
            try:
                wx, wy, cont = float(r["Corpse_0"]), float(r["Corpse_1"]), int(r["CorpseMapID"])
            except (KeyError, ValueError):
                wx, wy, cont = 0.0, 0.0, -1
            if cont >= 0 and not (wx == 0 and wy == 0):
                hit = self.maps.from_world(cont, wx, wy, prefer_name=prefer, also_prefer=also_prefer)
                if hit:
                    uid, x, y = hit
                    m = self.maps.maps.get(uid)
                    if m and m["type"] == 3 and m["name"] != "The Great Sea":
                        if self.fl not in CLASSIC_POINT_CHECK or not loc_maps or uid in loc_maps:
                            if loc_maps and uid not in loc_maps and fallback_door:
                                return fallback_door        # both off the named zones: the door pin, not the ghost
                            return uid, x, y, "blizzard"
        # 4. {{Coords}} / {{co}} in the lead section of the wiki instance page matching one of the infobox's outdoor zones
        if self.atlas and loc_maps:
            lead_txt = WT.sections(d["text"]).get("", "")
            for cx, cy, czone, _s, _e in WT.coords(lead_txt):
                z = czone or (locs[-1] if locs else "")
                hit = self.atlas.place(z, cx, cy, self.fl, page_classic=page_classic) if z else None
                if hit:
                    uid, px, py = hit
                    m = self.maps.maps.get(uid)
                    if m and m["type"] == 3 and uid in loc_maps and m["name"] != "The Great Sea":
                        return uid, px, py, "wiki"
        if fallback_door:
            return fallback_door
        return None

    def loc_zone(self, d):
        """the zone map the infobox location names (last link that is a zone on this client), or None"""
        locs = list(link_titles(d["loc"]))
        if any(norm(nm) == "blackrockmountain" for nm in locs):
            locs.append("Burning Steppes")
        for nm in reversed(locs):
            mid = self.maps.resolve(nm)
            if mid and self.maps.maps[mid]["type"] == 3 and self.maps.maps[mid]["name"] != "The Great Sea":
                return mid
        return None


def read_wiki_lines(fl, folder):
    """qid -> [step lines] from Imported_Wiki_<fl>.lua, in file order; plus the guides' minimum ids order"""
    p = folder / f"Imported_Wiki_{fl}.lua"
    out = defaultdict(list)
    if not p.exists():
        return None
    text = p.read_text(encoding="utf-8")
    for m in TEXT_BLOCK.finditer(text):
        for line in m.group(2).splitlines():
            s = STEP.match(line)
            if s:
                out[int(s.group(2))].append(line)
    return out


def pre_of(lines):
    """the |PRE| ids of a quest's accept step (any one of them), [] when none"""
    for ln in lines:
        if ln.startswith("A "):
            v = tag(ln, "PRE")
            if v:
                return [int(x) for x in re.findall(r"\d+", v)], ("&" in v)
            return [], False
    return [], False


class Gen:
    def __init__(self, out=None):
        self.out_dir = Path(out) if out else None
        self.db = sqlite3.connect(f"file:{WIKI}?mode=ro", uri=True)
        self.db.row_factory = sqlite3.Row
        self.raw = sqlite3.connect(f"file:{RAW}?mode=ro", uri=True)
        self.raw_pages = []
        raw_rows = self.raw.execute(
            "select p.title, p.wikitext from pages p join page_templates pt using(pageid) "
            "where pt.template='Infobox instance' order by p.title"
        ).fetchall()
        if not raw_rows:
            raw_rows = self.raw.execute(
                "select title, wikitext from pages where wikitext like '%{{Infobox instance%' order by title"
            ).fetchall()
        ib_re = re.compile(r"infobox instance", re.I)
        for title, text in raw_rows:
            if NEVER_PAGES.search(title):
                continue
            for _s, _e, _nm, inner in WT.find_templates(text, ib_re):
                _pos, named = WT.split_params(inner)
                self.raw_pages.append((title, named, text))
                break
        self.atlas = wikimaps.Atlas()
        self.retail_map = {int(r["ID"]): r for r in db2_fetch.rows("retail", "Map")}
        self.npc_zone = {r["title"]: r["zone"] for r in self.db.execute("select title, zone from npcs") if r["zone"]}
        self.titles = {r["title"]: r["page_title"] for r in self.db.execute("select title, page_title from titles")}
        self.items = {}
        for r in self.db.execute("select title, sources_json from items"):
            try:
                self.items[r["title"]] = [s if isinstance(s, str) else (s[0] if s else "") for s in json.loads(r["sources_json"] or "[]")]
            except ValueError:
                self.items[r["title"]] = []
        self.objs = defaultdict(list)
        for r in self.db.execute("select quest_id, page_title, target_title, optional from quest_objectives "
                                 "order by quest_id, page_title, idx"):
            self.objs[(r["quest_id"], r["page_title"])].append((r["target_title"], r["optional"]))
        self.rows = {}
        for r in self.db.execute("select * from quests"):
            self.rows[(r["id"], r["page_title"])] = dict(r)
        self.report = []
        self.inst_names = None          # the running client's instance names (Gen.run sets it)
        self.tpl = None                 # Template:Level instance ranges (template_level), read on first use
        self._npc_inst_cache = {}

    def template_level(self, d):
        """(low, high) from the wiki's Template:Level instance entries (retail ranges), for the infobox's
        {{level|<key>}} or the instance's name; None when it has none"""
        if self.tpl is None:
            self.tpl = {}
            p = RAW.parent / "template_level.json"
            if p.exists():
                t = json.loads(p.read_text(encoding="utf-8"))["query"]["pages"][0]["revisions"][0]["slots"]["main"]["content"]
                t = t[t.find("DUNGEONS"):] if "DUNGEONS" in t else ""
                for m in re.finditer(r"-->\|([^=<]+)=(\d+)(?:-(\d+))?<!--", t):
                    lo, hi = int(m.group(2)), int(m.group(3) or m.group(2))
                    for k in m.group(1).split("|"):
                        k = k.strip().lower()
                        if k and "+" not in k and k not in self.tpl:
                            self.tpl[k] = (lo, hi)
        keys = re.findall(r"\{\{\s*level\s*\|\s*([^}|]+)", d["f"].get("level") or "", re.I)
        keys += [d["name"], d["base"], re.sub(r"^the\s+", "", d["name"], flags=re.I)]
        for k in keys:
            v = self.tpl.get(k.strip().lower())
            if v:
                return v
        return None

    def page(self, t):
        return self.titles.get(t, t) if t else t

    def target_zone(self, title):
        """the wiki zone of an objective target: its NPC (or object) page; for an item, the one zone every drop source
        names, when every source is such a page (an item page also lists zones and recipes as sources: then None)"""
        t = self.page(title)
        if not t:
            return None
        if t in self.npc_zone:
            return self.npc_zone[t]
        srcs = [self.page(s) for s in self.items.get(t, []) if s]
        # a source that is the instance's own page counts as that instance
        zones = {self.npc_zone.get(s) or (s if self.inst_names and norm(base_title(s)) in self.inst_names else None)
                 for s in srcs}
        if srcs and None not in zones and len(zones) == 1:
            return zones.pop()
        return None

    def run(self, fl):
        maps = self.atlas.sets[fl]
        folder = GUIDES
        wl = read_wiki_lines(fl, folder)
        if wl is None:
            print(f"skip {fl}: Guides/Imported_Wiki_{fl}.lua missing (run tools/wiki/gen_wiki_guides.py first)")
            return None
        inst = Instances(fl, maps, self.raw_pages, self.retail_map, self.atlas)
        cat = inst.build()
        self.inst_names = inst.names
        chosen = {}
        for r in self.db.execute("select quest_id, page_title from flavor_quests where flavor=? order by quest_id", (fl,)):
            row = self.rows.get((r["quest_id"], r["page_title"]))
            if row and r["quest_id"] in wl:
                chosen[r["quest_id"]] = row
        ui_inst = {}
        for base, d in cat.items():
            for u in d["ui"]:
                ui_inst.setdefault(u, base)
        # outdoor zone maps (type 3, on a continent map rather than an instance map) that share a name with an instance
        # (Retail: Zul'Aman in Midnight vs the Cataclysm dungeon; City of Threads subzone in Azj-Kahet; Eye of Azshara)
        outdoor_zone_names = {norm(m["name"]) for m in maps.maps.values()
                              if m["type"] == 3 and m["inst"] not in inst.map_rows}

        # ---- which quests belong to which instance -----------------------------------------------------------
        owner, how = {}, {}
        unmatched_cats = Counter()
        excluded_q = defaultdict(list)       # (page, why) -> quests whose category is an instance page left out
        for qid, r in sorted(chosen.items()):
            c = base_title(r["category"] or r["zone"] or "")
            b = inst.names.get(norm(c))
            ak = re.match(r"\s*(\d+)\.", r["added_patch"] or "")
            q_exp = int(ak.group(1)) - 1 if ak else None
            if b:
                if norm(c) in outdoor_zone_names:
                    # the category name is also an outdoor zone on this client: keep only quests of the instance's own
                    # expansion that do not place their objectives on the outdoor continent map
                    if q_exp is not None and q_exp != cat[b]["expansion"]:
                        b = None
                    else:
                        c_lines = [ln for ln in wl[qid] if ln.startswith("C ")]
                        on_inst = any(zone_of(ln) in ui_inst for ln in wl[qid])
                        on_out = any("|M|" in ln and zone_of(ln) not in ui_inst and
                                     maps.maps.get(zone_of(ln) or 0, {}).get("inst") not in inst.map_rows
                                     for ln in c_lines)
                        if on_out and not on_inst:
                            b = None
                if b:
                    owner[qid], how[qid] = b, "category"
                    continue
            if norm(c) in inst.excluded and norm(c) not in inst.names:
                excluded_q[inst.excluded[norm(c)]].append(qid)
            # rules 2 and 3 only for a quest of the instance's own expansion: a quest that goes back into an old instance
            # years later (a covenant memory of Stratholme) belongs to its own storyline, not to the instance's route
            for ln in wl[qid]:
                if ln.startswith("C "):
                    z = zone_of(ln)
                    if z in ui_inst and (q_exp is None or q_exp == cat[ui_inst[z]]["expansion"]):
                        owner[qid], how[qid] = ui_inst[z], "map"
                        break
            if qid in owner:
                continue
            zs = set()
            unknown = 0
            for tgt, opt in self.objs.get((qid, r["page_title"]), []):
                if opt:
                    continue
                z = self.target_zone(tgt)
                if z is None:
                    unknown += 1
                    continue
                zs.add(inst.names.get(norm(base_title(z)), "-"))
            if len(zs) == 1 and "-" not in zs and (q_exp is None or q_exp == cat[next(iter(zs))]["expansion"]):
                owner[qid], how[qid] = zs.pop(), "objectives"
            elif c and inst.is_instance_name(c) and norm(c) not in outdoor_zone_names:
                unmatched_cats[c] += 1
        by_inst = defaultdict(list)
        for qid, b in owner.items():
            by_inst[b].append(qid)
        # attunement / key quests (outside the instance; done before it)
        attune = defaultdict(set)
        key_items = {}
        for base, d in cat.items():
            k = d["f"].get("key") or ""
            for lt in link_titles(k):
                if "heroic" not in k.lower().split(lt.lower(), 1)[-1][:30]:
                    key_items[norm(lt)] = base
        for qid, r in chosen.items():
            nm = r["name"] or ""
            m = ATTUNE.match(nm)
            b = inst.names.get(norm(m.group(1))) if m else None
            b = b or key_items.get(norm(nm))
            if b and owner.get(qid) != b:
                attune[b].add(qid)

        # ---- routes -------------------------------------------------------------------------------------------
        # a quest the zone routes write once per faction (a FACTION|Alliance copy and a FACTION|Horde copy of its
        # steps) gets the copy of the route's faction; a quest written once serves both
        wlf = {"Alliance": {}, "Horde": {}}
        for q in chosen:
            for F in wlf:
                keep = [ln for ln in wl[q] if tag(ln, "FACTION") in (None, F)]
                if keep:
                    wlf[F][q] = keep

        def fac(q):
            f = chosen[q]["faction"]
            return f if f in ("Alliance", "Horde") else "Both"

        def level(q):
            r = chosen[q]
            return r["level"] if (r["level"] or 0) > 0 else (r["levelreq"] or 0)

        def ok_for(q, F):
            return fac(q) in ("Both", F) and q in wlf[F]

        def closure(seeds, F, inside):
            """prerequisites of `seeds` (not in `inside`), each with the one alternative a route takes"""
            need, stack, seen = set(), list(seeds), set()
            while stack:
                q = stack.pop()
                if q in seen:
                    continue
                seen.add(q)
                pre, all_of = pre_of(wlf[F][q])
                pre = [p for p in pre if p in chosen and p != q]
                if not pre:
                    continue
                if all_of:
                    picks = [p for p in pre if ok_for(p, F)]
                elif any(p in inside or p in need for p in pre):
                    picks = []
                else:
                    cand = sorted([p for p in pre if ok_for(p, F)], key=lambda p: (level(p), p))
                    picks = cand[:1]
                for p in picks:
                    if p not in inside:
                        need.add(p)
                    stack.append(p)
            return need

        def topo(qs, L):
            """quests in prerequisite order (their lines L; "any one of" is met by any one); ties by level, then id"""
            qs = set(qs)
            deps = {}
            for q in qs:
                pre, all_of = pre_of(L[q])
                deps[q] = ({p for p in pre if p in qs and p != q}, all_of)

            def ready_q(q, done):
                ps, all_of = deps[q]
                return not ps or (ps <= done if all_of else bool(ps & done))
            out, done = [], set()
            while len(out) < len(qs):
                ready = sorted((q for q in qs if q not in done and ready_q(q, done)), key=lambda q: (level(q), q))
                if not ready:      # a cycle: take the lowest one and go on
                    ready = sorted((q for q in qs if q not in done), key=lambda q: (level(q), q))[:1]
                q = ready[0]
                out.append(q)
                done.add(q)
            return out

        def is_inst_ui(z, d):
            if z is None:
                return False
            if z in d["ui"]:
                return True
            m = maps.maps.get(z)
            if not m:
                return False
            return m["inst"] == d["map"] or (m["type"] in (4, 5, 6) and norm(m["name"]) in (norm(d["name"]), norm(d["base"])))

        def npc_in_inst(t, base):
            if not t:
                return False
            z = self.npc_zone.get(t)
            if z is not None and inst.names.get(norm(base_title(z))) == base:
                return True
            key = (t, base)
            if key not in self._npc_inst_cache:
                row = self.raw.execute("select wikitext from pages where title=?", (t,)).fetchone()
                ok = False
                if row and row[0]:
                    wt = row[0]
                    if any(norm(base_title(lt)) == norm(base) for lt in link_titles(wt)):
                        for _s, _e, _nm, inner in WT.find_templates(wt, re.compile(r"npcbox", re.I)):
                            _pos, named = WT.split_params(inner)
                            loc = (named.get("location") or "").lower()
                            if "various" in loc or any(norm(base_title(lt)) == norm(base) for lt in link_titles(loc)):
                                ok = True
                            break
                self._npc_inst_cache[key] = ok
            return self._npc_inst_cache[key]

        def make_giver_inside(base, d, L, dq_set):
            inside_npcs = set()
            for q in dq_set:
                for which, col in (("A", "start_npc"), ("T", "end_npc")):
                    t = self.page(chosen[q][col])
                    if t and any("|M|" in ln and is_inst_ui(zone_of(ln), d)
                                 for ln in L.get(q, ()) if ln.startswith(which + " ")):
                        inside_npcs.add(t)
            # in-dungeon boss-by-boss chains (q1 in dq -> q2 in dq) handed off by a companion NPC whose Npcbox
            # location is "Various" and whose page links to the instance (e.g. Ivar Bloodfang in Shadowfang Keep,
            # Slinky Sharpshiv in Deadmines, Brann in Halls of Origination, Chen in Stormstout Brewery)
            chain_T, chain_A = set(), set()
            for q2 in dq_set:
                for q1 in pre_of(L.get(q2, ()))[0]:
                    if q1 in dq_set:
                        t1 = self.page(chosen[q1]["end_npc"])
                        t2 = self.page(chosen[q2]["start_npc"])
                        if t1 and (t1 in inside_npcs or npc_in_inst(t1, base)):
                            chain_T.add(q1)
                        if t2 and (t2 in inside_npcs or npc_in_inst(t2, base)):
                            chain_A.add(q2)

            def giver_inside(q, which):
                if (which == "T" and q in chain_T) or (which == "A" and q in chain_A):
                    return True
                alines = [ln for ln in L.get(q, ()) if ln.startswith(which + " ")]
                for ln in alines:
                    if "|M|" in ln:
                        return is_inst_ui(zone_of(ln), d)
                r = chosen[q]
                t = self.page(r["start_npc"] if which == "A" else r["end_npc"])
                if t:
                    if t in inside_npcs or npc_in_inst(t, base):
                        return True
                    if self.npc_zone.get(t) is not None:
                        return False
                # no NPC named (automatic in-dungeon turn-in or auto-accepted chain step), or an unplaced NPC
                has_inside_c = any(not ("|M|" in ln and not is_inst_ui(zone_of(ln), d))
                                   for ln in L.get(q, ()) if ln.startswith("C "))
                if not t and has_inside_c:
                    if which == "T":
                        return True
                    if which == "A" and any(p in dq_set for p in pre_of(L.get(q, ()))[0]):
                        return True
                return False
            return giver_inside

        routes, rows = [], []
        st = Counter()
        for base in sorted(cat):
            d = cat[base]
            qs = sorted(by_inst.get(base, []))
            if not qs:
                continue
            ent = inst.entrance(d)
            loc_zone = inst.loc_zone(d)
            ui = d["ui"][0] if d["ui"] else None
            per = {}
            for F in ("Alliance", "Horde"):
                L = wlf[F]
                dq = [q for q in qs if ok_for(q, F)]
                if not dq:
                    continue
                dq_set = set(dq)
                att = sorted((q for q in attune.get(base, ()) if ok_for(q, F)), key=lambda q: q)
                lead = closure(dq + att, F, dq_set) | set(att)
                lead -= dq_set
                # a prerequisite that itself needs an instance quest first (Uldaman: "Passing Word of a Threat" needs
                # "Prospect of Faith") is done between two runs, not before the first; an "any one of" prerequisite is
                # met as soon as one of its alternatives in lead is done
                bridge, grew = set(), True
                while grew:
                    grew = False
                    for q in lead - bridge:
                        pre, all_of = pre_of(L[q])
                        pre = [p for p in pre if p in lead or p in dq_set]
                        if not pre:
                            continue
                        if (any(p in dq_set or p in bridge for p in pre) if all_of else
                                all(p in dq_set or p in bridge for p in pre)):
                            bridge.add(q)
                            grew = True
                follow = sorted(q for q in chosen if q not in dq_set and q not in lead and ok_for(q, F)
                                and any(p in dq_set for p in pre_of(L[q])[0]))
                per[F] = (dq, sorted(lead - bridge), sorted(bridge), follow)
            if not per:
                continue
            if len(per) == 2 and per["Alliance"] == per["Horde"] and all(
                    wlf["Alliance"].get(q) == wlf["Horde"].get(q) for part in per["Alliance"] for q in part):
                per = {"Both": per["Alliance"]}
            for F, (dq, lead, bridge, follow) in per.items():
                L = wlf["Alliance" if F == "Both" else F]
                gi = make_giver_inside(base, d, L, set(dq))
                lines, info = self.route_lines(fl, base, d, dq, lead, bridge, follow, L, chosen, ent, loc_zone, ui, maps,
                                               gi, lambda qs: topo(qs, L), how)
                lvls = [level(q) for q in dq if level(q)]
                reqs = [chosen[q]["levelreq"] or level(q) for q in dq if (chosen[q]["levelreq"] or level(q))]
                mn = min(reqs) if reqs else None
                mx = max(lvls) if lvls else None
                tl = inst.lfg_level(d) or (self.template_level(d) if fl == "retail" else None)
                if tl:
                    # the instance's own range: the client's Dungeon Finder entry, else (retail, which scales old
                    # instances) the wiki's Template:Level entry; the quests' own levels only when neither has one
                    mn, mx = tl
                if mn is None:
                    # no quest names a level (Ahn'Qiraj's): the infobox's own range for this client's page
                    nums = [int(x) for x in re.findall(r"\d+", plain(d["f"].get("classiclevel") or d["f"].get("level") or ""))]
                    nums = [x for x in nums if 1 <= x <= 90]
                    if nums:
                        mn, mx = min(nums), max(nums)
                if mn and mx and mx < mn:
                    mx = mn
                routes.append(dict(base=base, d=d, F=F, lines=lines, info=info, minlevel=mn, maxlevel=mx,
                                   zone=(ent[0] if ent else loc_zone or ui), dq=dq, lead=lead + bridge, follow=follow,
                                   ent_src=(ent[3] if ent else ("instance-map" if d["ui"] else "zone")),
                                   how={q: how[q] for q in dq}))
        # quests with an instance category this client has no instance page or map for
        for c, n in sorted(unmatched_cats.items()):
            if norm(c) in inst.excluded:
                continue        # counted with its page below
            rows.append((fl, c, "", None, "", "", "", "no route", "the quest category names a Blizzard instance map of this "
                         "client (a dungeon or raid, or a scenario or phased zone stored as one) but no wiki instance page "
                         "(Infobox instance) in the cache matches it", n, 0, 0, 0, 0, "",
                         None, None, 0, "", 0))
        for (page, why), qs in sorted(excluded_q.items()):
            if not any(qid in owner for qid in qs):
                rows.append((fl, page, "", None, "", "", "", "no route", why, len(qs), 0, 0, 0, 0, "", None, None, 0, page, 0))
        return routes, rows, cat, by_inst, st

    def route_lines(self, fl, base, d, dq, lead, bridge, follow, wl, chosen, ent, loc_zone, ui, maps, inside_giver, topo,
                    how):
        name = d["name"]
        info = Counter()
        lines = []
        universe = set(dq) | set(lead) | set(bridge) | set(follow)

        def fix_inside(ln):
            """an inside step with no point: the instance's own map, else the entrance point"""
            head, pairs = split_line(ln)
            tags = dict(pairs)
            if "M" in tags:
                return ln
            if ui:
                nz = f"{ui}; {maps.maps[ui]['name']}"
                pairs = [(t, nz if t == "Z" else v) for t, v in pairs] if "Z" in tags else pairs[:2] + [("Z", nz)] + pairs[2:]
                pairs = [(t, (NO_COORDS.sub("", v).rstrip(". ") + f". Inside {name}.").lstrip(". ")[:300] if t == "N" and
                          NO_COORDS.search(v) else v) for t, v in pairs]
                info["inside_on_instance_map"] += 1
                return join_line(head, pairs)
            if ent:
                mz = maps.maps[ent[0]]["name"]
                new = []
                for t, v in pairs:
                    if t == "Z":
                        continue
                    if t == "N":
                        # "the quest is in <zone>" named the zone this step no longer points at
                        v = NO_COORDS.sub("", v).strip()
                        v = ((v.rstrip(". ") + ". ") if v else "") + f"Inside {name}; the point is the entrance."
                        v = v[:300]
                    new.append((t, v))
                at = 2 if len(new) >= 2 and new[0][0] == "QID" else 0
                new[at:at] = [("M", f"{ent[1]:.1f},{ent[2]:.1f}"), ("Z", f"{ent[0]}; {mz}")]
                if not any(t == "N" for t, _ in new):
                    new.append(("N", f"Inside {name}; the point is the entrance."))
                info["inside_on_entrance"] += 1
                return join_line(head, new)
            return ln

        def door(npass):
            word = (PASS_WORDS[npass] if npass < len(PASS_WORDS) else f" (run {npass + 1})") if npass else ""
            title = f"Enter {name}{word}"
            loc_words = plain(d["loc"])
            if ent:
                zname = maps.maps[ent[0]]["name"]
                where_src = (f"Warcraft Wiki, {d['page']}" if ent[3] == "wiki" else
                             "Blizzard Encounter Journal entrance" if ent[3] == "journal" else
                             "Blizzard Map table, where a ghost returns to the instance")
                return (f"D {title}|M|{ent[1]:.1f},{ent[2]:.1f}|Z|{ent[0]}; {zname}|N|The entrance to {name}"
                        f"{(' (' + loc_words + ')') if loc_words else ''}. (location: {where_src})|")
            if loc_zone:
                return (f"D {title}|Z|{loc_zone}; {maps.maps[loc_zone]['name']}|N|No exact spot for the entrance on the "
                        f"wiki.{(' The wiki lists it at ' + loc_words + '.') if loc_words else ''}|")
            if ui:
                return (f"D {title}|Z|{ui}; {maps.maps[ui]['name']}|N|No exact spot for the entrance on the wiki."
                        f"{(' The wiki lists it at ' + loc_words + '.') if loc_words else ''} The arrow shows the "
                        f"entrance once you have walked in once.|")
            return f"D {title}|N|No location for the entrance on the wiki.{(' The wiki lists it at ' + loc_words + '.') if loc_words else ''}|"

        def acts(q, a):
            return [ln for ln in wl[q] if ln.startswith(a + " ")]

        # 1. lead-up
        done = set()
        for q in topo(lead):
            lines.extend(wl[q])
            done.add(q)
            info["lead_steps"] += len(wl[q])

        def pre_ok(q, have):
            pre, all_of = pre_of(wl[q])
            pre = [p for p in pre if p in universe and p != q]
            if not pre:
                return True
            return all(p in have for p in pre) if all_of else any(p in have for p in pre)

        # 2-5. passes through the instance
        remaining = topo(dq)
        bridges = topo(bridge)
        npass = 0
        while remaining:
            accepted, outside_c = [], []
            for q in remaining:
                a = acts(q, "A")
                if (not a or not inside_giver(q, "A")) and pre_ok(q, done):
                    lines.extend(a)
                    accepted.append(q)
                    # a quest placed by its map (rule 2) may have objectives outside: those before the door
                    if how.get(q) == "map":
                        for ln in acts(q, "C"):
                            z = zone_of(ln)
                            if not (z and maps.maps.get(z, {}).get("inst") == d["map"]):
                                outside_c.append(ln)
            lines.extend(outside_c)
            inside_done, cdone, inside_buf = set(), set(), []
            progress = True
            while progress:
                progress = False
                for q in remaining:
                    if q not in accepted and inside_giver(q, "A") and pre_ok(q, done | inside_done):
                        inside_buf.extend(fix_inside(ln) for ln in acts(q, "A"))
                        accepted.append(q)
                        progress = True
                    if q in accepted and q not in cdone:
                        cdone.add(q)
                        for ln in acts(q, "C"):
                            if ln in outside_c:
                                continue
                            inside_buf.append(fix_inside(ln))
                        if inside_giver(q, "T"):
                            inside_buf.extend(fix_inside(ln) for ln in acts(q, "T"))
                            inside_done.add(q)
                        progress = True
            if npass == 0 or inside_buf:
                lines.append(door(npass))
                lines.extend(inside_buf)
                npass += 1
            for q in accepted:
                if q not in inside_done:
                    lines.extend(acts(q, "T"))
            done |= set(accepted)
            # prerequisites of the next run that needed this one
            took = True
            while took:
                took = False
                for q in bridges:
                    if q not in done and pre_ok(q, done):
                        lines.extend(wl[q])
                        done.add(q)
                        took = True
            if not accepted:
                # nothing can be picked up any more (a prerequisite this client lacks): the rest as written
                for q in remaining:
                    lines.extend(wl[q])
                info["stuck_quests"] += len(remaining)
                break
            remaining = [q for q in remaining if q not in done]
        info["passes"] = npass
        for q in bridges:
            if q not in done:           # a prerequisite whose own prerequisite never came: as written, at the end
                lines.extend(wl[q])
                done.add(q)
                info["stuck_quests"] += 1
        # follow-up quests the run unlocks
        for q in topo(follow):
            lines.extend(wl[q])
        info["steps"] = len(lines)
        info["no_point"] = sum(1 for ln in lines if "|M|" not in ln)
        return lines, info

    def write(self, fl, routes, rows, cat, by_inst):
        today = datetime.date.today().isoformat()
        out_dir = self.out_dir or GUIDES
        out_dir.mkdir(parents=True, exist_ok=True)
        out = out_dir / f"Imported_Dungeons_{fl}.lua"
        gate = ('if not NS.isForever then return end' if fl == "forever" else
                'if NS.flavor ~= "era" or NS.isForever then return end' if fl == "era" else
                f'if NS.flavor ~= "{fl}" then return end')
        hdr = [
            f"-- Completionist's Guide :: Imported_Dungeons_{fl}.lua - GENERATED {today} by tools/wiki/gen_dungeons.py",
            "-- Dungeon and raid routes: the quests leading up to an instance, its quests, its entrance, the turn-ins.",
            f"-- Every quest step is a line of Imported_Wiki_{fl}.lua: quest data derived from Warcraft Wiki,",
            "-- https://warcraft.wiki.gg, by its contributors, licensed under CC BY-SA 4.0",
            "-- (https://creativecommons.org/licenses/by-sa/4.0/). This data file is shared under the same licence;",
            "-- see Guides/WIKI_DATA_LICENSE.md. Instances and entrances from the wiki's instance pages; which instances a",
            "-- client has and entrances (Encounter Journal door pins, Map Corpse position) from Blizzard client tables Map / JournalInstance / JournalInstanceEntrance via wago.tools (facts).",
            "local _, NS = ...", gate, "local R = NS.Guide.Register", ""]
        if routes:
            # Imported_Wiki's provenance lines (Blizzard quest pins, player contributions) apply to the lines copied here
            src = (GUIDES / f"Imported_Wiki_{fl}.lua").read_text(encoding="utf-8").splitlines()[:20]
            extra = [ln for ln in src if ln.startswith("-- ") and ("QuestPOI" in ln or "(location: player contributions" in ln
                                                               or "wow-completionist-data" in ln)]
            hdr[7:7] = extra
        body = []

        def sort_key(rt):
            return (rt["d"]["expansion"], rt["d"]["kind"] == "Raid", rt["minlevel"] or 999, rt["maxlevel"] or 999,
                    rt["d"]["name"], rt["F"])
        multi_exp = len({rt["d"]["expansion"] for rt in routes}) > 1
        for rt in sorted(routes, key=sort_key):
            d, F = rt["d"], rt["F"]
            exp = EXPANSIONS[d["expansion"]] if d["expansion"] < len(EXPANSIONS) else f"Expansion {d['expansion']}"
            folder = (f"{exp} {d['kind']}s" if multi_exp else f"{d['kind']}s")
            forder = d["expansion"] * 2 + (1 if d["kind"] == "Raid" else 0)
            slug = re.sub(r"[^a-z0-9]+", "-", d["base"].lower()).strip("-")
            gid = f"dungeon:{fl}:{slug}" + (f":{F}" if F != "Both" else "")
            gname = d["name"] + (f" ({F})" if F != "Both" else "")
            facf = f'faction="{F}", ' if F != "Both" else ""
            lv = (f"minlevel={rt['minlevel']}, " if rt["minlevel"] else "") + (f"maxlevel={rt['maxlevel']}, " if rt["maxlevel"] else "")
            zf = f"zone={rt['zone']}, " if rt["zone"] else ""
            native = "forever=true, " if fl == "forever" else ""
            body.append(f'R({{ id="{gid}", name="{lua_str(gname)}", type="Dungeons", folder="{lua_str(folder)}", '
                        f'folderOrder={forder}, instance="{lua_str(d["kind"])}", {zf}{facf}{lv}{native}'
                        f'author="Warcraft Wiki contributors (CC BY-SA 4.0)", source="CompletionRoute", text=[==[')
            body.extend(rt["lines"])
            body.append("]==] })")
            info = rt["info"]
            rows.append((fl, d["name"], d["kind"], d["map"], exp, F, gid, "route", "", len(rt["dq"]), len(rt["lead"]),
                         len(rt["follow"]), info["steps"], info["no_point"],
                         rt.get("ent_src", "blizzard") if "|M|" in next((ln for ln in rt["lines"] if ln.startswith("D ")), "") else
                         ("instance-map" if d["ui"] else "zone"), rt["minlevel"], rt["maxlevel"], info["passes"],
                         d["page"], info["stuck_quests"]))
        # instances with quests a client cannot route: none of them can be picked up (no route was made)
        tmp = out.with_suffix(".lua.tmp")
        tmp.write_text("\n".join(hdr + body) + "\n", encoding="utf-8")
        os.replace(tmp, out)
        return out

    def chart(self, rows, flavors):
        db = sqlite3.connect(self.out_dir / "verification.sqlite" if self.out_dir else VERIF)
        cols = [r[1] for r in db.execute("pragma table_info(dungeon_routes)")]
        if cols and "unordered_quests" not in cols:
            db.execute("drop table dungeon_routes")            # an older layout of this table
        db.executescript("""
        create table if not exists dungeon_routes(flavor text, instance text, kind text, map_id int, expansion text,
            faction text, route_id text, status text, why text, quests int, lead_quests int, follow_quests int,
            steps int, steps_no_point int, entrance text, minlevel int, maxlevel int, passes int, wiki_page text,
            unordered_quests int);
        """)
        for fl in flavors:
            db.execute("delete from dungeon_routes where flavor=?", (fl,))
        db.executemany("insert into dungeon_routes values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", rows)
        db.commit()
        db.close()


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    out = None
    fls = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--out":
            out = argv[i + 1]
            i += 2
            continue
        if a not in FLAVORS:
            raise SystemExit(f"gen_dungeons: unknown argument {a}")
        fls.append(a)
        i += 1
    fls = fls or FLAVORS
    g = Gen(out)
    done = []
    for fl in fls:
        res = g.run(fl)
        if res is None:
            continue
        routes, rows, cat, by_inst, st = res
        path = g.write(fl, routes, rows, cat, by_inst)
        g.chart(rows, [fl])
        done.append(fl)
        rr = [r for r in rows if r[7] == "route"]
        print(f"{fl}: {len({r[1] for r in rr})} instances routed ({len(rr)} routes), "
              f"{sum(r[9] for r in rr)} instance quests, {sum(r[10] for r in rr)} lead-up, {sum(r[11] for r in rr)} "
              f"follow-up, {sum(r[12] for r in rr)} steps, {sum(r[13] for r in rr)} without a point, "
              f"{len(rows) - len(rr)} not routed -> {path} ({path.stat().st_size // 1024} KB)")
    return done


if __name__ == "__main__":
    main()
