#!/usr/bin/env python3
# CompletionRoute :: tools/gen_completion_guides.py
# Copyright (c) 2026 Daniel Bates / BatesAI. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Generate the "completionist" guide sets from Blizzard client data (wago.tools DB2 exports) and Warcraft Wiki data:

    python3 tools/gen_completion_guides.py [retail] [mop] [--achievements-only]

  Guides/Imported_Achievements_<fl>.lua   one guide per achievement category (retail, mop).  Every
      achievement that is not a statistic and not internal (INTERNAL: DNT, <Hidden>, Hidden Tracking) becomes a block
      of steps: one per criterion (cap 60), then a FIXED "earn it" step.  Criteria carry
      |ACH|<achievement>;<criteria-tree id>| and tick from GetAchievementCriteriaInfoByID.  Locations come only from
      Warcraft Wiki data and Blizzard tables, never from WoW-Pro or Questie (Places below); every located step's note
      names its source ("wiki: <page>", "Blizzard WorldMapOverlay <id>", ...).  By Criteria.Type:
        point (|M|..|Z|..)  27 "complete quest N": the quest's step in Imported_Wiki_<fl> (rows whose note credits a
                              fallback point are skipped), else Blizzard QuestPOIBlob/QuestPOIPoint (the turn-in pin);
                            0 "kill creature N": the wiki NPC page with that id, else the page named like the criterion;
                            43 "explore area": the centre of the Blizzard WorldMapOverlay hit rectangle on its map
                              (UiMapXMapArt, UiMapArt, UiMapArtStyleLayer);
                            68 "use object N": the wiki object page with that id;
                            36/42 "own / loot item N": the item's wiki drop source with a point;
                            NPC-named types (28 spell target, 54 emote, 72 fishing pool, 73 event, 152 scenario, 157
                              pet, 158 pet tamer, 165 encounter): the wiki NPC / object / place page with the criterion's
                              name (the wiki's own criterion links first).
                            A page matched by name must fit the achievement: its point lies in the achievement's zone
                            (its instance, "Explore"/"quests in" zone, or the one zone its description or title names)
                            and not on a later expansion's map than its Blizzard category names; else the step is that
                            zone only.  A zone's own page gives only the zone (its {{co}} rows are neighbours), and a
                            topic page (every {{co}} in a body section: professions, holidays, expansions) gives nothing.
                            Names that exist twice resolve for the achievement's expansion (category words, else the
                            nearest achievement ids): Midnight's Eversong Woods, Legion's Dalaran, Draenor's Nagrand.
        zone  (|Z|.. only)  the same criterion when the source names only a zone; 165 "dungeon encounter" and 71
                            "complete instance": the instance map (DungeonEncounter.MapID / the Map id); a criterion
                            whose name is a map name; a "complete achievement N" criterion whose achievement sits in
                            one zone; and on the FIXED step, an achievement Blizzard ties to a dungeon/raid/scenario
                            (Achievement.Instance_ID), "Explore <zone>", "... quests in <zone>", a meta achievement
                            whose parts all sit in one zone, or a description naming exactly one zone (skyriding
                            races).  The router heads for the zone (Routing/Router.lua); no coordinate is written and
                            the note says "(zone only; <source>)".
        achievement level   when no criterion has a place, in order: a glyph's wiki point ("Dragon Glyph", "<zone>
                            Glyph Hunter" lists), the map or explorable area after "Name: " (never an instance for a
                            glyph; an area only through a Blizzard overlay that covers it alone), the wiki race lists,
                            the achievement's own wiki page (only links its title or description names), the one zone
                            its description, title or meta achievement names.
        |NOGEO|<reason>|    on the FIXED step of an achievement with no location that has no place at all: battleground
                            or arena, PvP/reputation/feat/guild/general categories, purely counter criteria (level,
                            skill, reputation, currency).  Read by tools/coverage.py; the client keeps it as a raw tag.
  Guides/Imported_QuestLines_retail.lua   one guide per Blizzard QuestLine, quests in the client's OrderIndex order
      (QuestLineXQuest; guide name from QuestLine).  Each accept carries |PRE|<previous quest>| so the optimizer can
      interleave travel but can never break the story order.  A quest's steps are its Imported_Wiki_retail lines
      (wiki text, gates and points; a fallback point is dropped); a step left without a point takes the Blizzard
      QuestPOI pin (turn-in pin for T, objective area for C), an accept without one names the quest's map as zone only.
      A quest the wiki lacks gets "Quest <id>" steps from QuestPOI alone (the client shows the live name).  Shippable
      (wiki CC BY-SA + Blizzard facts).  The older Imported_Storylines_retail.lua copied Imported_Quests_retail.lua lines
      (Questie-derived); this script no longer writes it and no TOC loads it.
  Both files depend on which build of Imported_Wiki_<fl>.lua they read: from the default (fallback) build their header
  says so and names the Questie-derived source, which makes tools/package_release.py refuse them.  A release build runs
  this script after tools/wiki/gen_wiki_guides.py --no-fallback.
  Guides/Imported_Missions_retail.lua     one guide per mission table (WoD garrison + shipyard, Legion
      order hall, BfA war table, Shadowlands covenant table): a travel step to the table, then one
      note step per GarrMission row (|MISSION|id|) with followers, duration and cost.  Mission
      completion has no persistent client flag, so those steps are manual clicks.

Inputs: tools/db2/<fl>/{Achievement,Achievement_Category,Criteria,CriteriaTree,Map,QuestPOIBlob,QuestPOIPoint,
WorldMapOverlay,UiMapXMapArt,UiMapArt,UiMapArtStyleLayer,DungeonEncounter,AreaTable}.csv (fetched through
tools/wiki/db2_fetch.py when absent), tools/wiki/wiki.sqlite, Guides/Imported_Wiki_<fl>.lua, tools/db2/retail/{QuestLine,
QuestLineXQuest,GarrMission}.csv.  Everything written is gitignored (Imported_*.lua); only this script ships.

    python3 tools/gen_completion_guides.py --selfcheck    # place rules on synthetic rows (run by tools/test_completion.lua)
"""
import bisect, csv, json, re, sqlite3, sys, collections
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DB2 = ROOT / "tools" / "db2"
GUIDES = ROOT / "CompletionRoute" / "Guides"
MAX_CRIT = 60
WIKI_DB = ROOT / "tools" / "wiki" / "wiki.sqlite"
sys.path.insert(0, str(ROOT / "tools" / "wiki"))
csv.field_size_limit(1 << 28)
ZONE_TYPES = (3, 4, 5, 6)   # uiMap types a step may head for: zone, dungeon, micro, orphan (never continent / world)
# Map.InstanceType: 1 party, 2 raid, 5 scenario are places; 3 battleground and 4 arena are a queue
PLACE_INSTANCES = ("1", "2", "5")
QUEUE_INSTANCES = ("3", "4")
# root category -> reason, applied only to an achievement that found no location at all
NOGEO_ROOTS = {"Player vs. Player": "pvp", "Reputation": "reputation", "Statistics": "statistic",
               "Feats of Strength": "feat", "Characters": "character", "Collections": "collection",
               "General": "general", "Guild": "guild"}
# Criteria.Type with no place: reach level, skill, total quests, dailies, currency, title rank, bank slots, reputation
NOGEO_TYPES = {"5", "7", "9", "10", "12", "14", "40", "44", "45", "46", "47",
               # archaeology finds (dig sites rotate), spells learned (mounts, pets, toys), arena and rated ratings,
               # recipes known, pets collected or levelled, missions completed: counters and collections, no place
               "3", "34", "39", "132", "112", "156", "160", "173"}
# Criteria.Type whose description is the name of an NPC, object or place (looked up as a wiki page title): spell target
# (bosses, NPCs), emote at, fishing pool, scripted event (delves), scenario, pet capture, pet tamer, dungeon encounter
NAMED_TYPES = {"0", "28", "54", "68", "72", "73", "152", "157", "158", "165"}
# Criteria.Type whose asset is an item id: own an item, loot an item
ITEM_TYPES = {"36", "42"}
# a criterion's description often wraps the name: "Defeat X", "X defeated", "X Defeated (Mythic)"
NAME_WRAP = re.compile(r"^(?:Defeat|Kill|Slay|Destroy|Rescue|Free|Find|Visit|Discover|Catch|Capture)\s+(?:the\s+)?"
                       r"|\s+(?:defeated|Defeated|slain|killed|destroyed|rescued|freed|found|visited|discovered)"
                       r"(?:\s*\((?:Normal|Heroic|Mythic|LFR)\))?$")
# Blizzard's internal rows (trackers, flags, unfinished content): marked in the title or description.  They are left out
# of the guides and of the coverage universe (tools/coverage.py), and counted apart.  Case matters: "Hidden Treasures"
# and "A Test of Valor" are real achievements.  "(char specific hidden copy)" rows are per-character copies of account
# achievements that the achievement window never shows.
INTERNAL = re.compile(r"\bDNT\b|<DND>|<Hidden>|\[Hidden\]|\([Hh]idden\)|^Hidden Tracking\b|^Hidden - |\bUNUSED\b|\bDEPRECATED\b"
                      r"|[Hh]idden [Cc]opy\)|\(Hidden Character Achievement\)")
# the storyline guides: built from wiki and Blizzard data since 2026-11-11.  The older file name holds the build whose
# step lines were copied from Imported_Quests_retail.lua; it never ships and no TOC loads it any more.
STORY_FILE = "Imported_QuestLines_{fl}.lua"
OLD_STORY_FILE = "Imported_Storylines_{fl}.lua"
# a point the --no-fallback wiki build does not have (tools/wiki/gen_wiki_guides.py Fallback): never reused here
FALLBACK_NOTE = re.compile(r" ?\(location: (?:Questie|Blizzard) data[^)]*\)")
RE_MZ = re.compile(r"M\|[^|]*\|Z\|[^|]*\|")
# outdoor collectibles named after the place they are at: never an instance map, a wiki glyph list gives the point
COLLECTIBLE = re.compile(r"^(?:Dragon|Skyriding) Glyphs?: ")


def internal_achievement(r):
    """an Achievement.csv row Blizzard marks as internal (never shown to players as an achievement to earn)"""
    return bool(INTERNAL.search(r.get("Title_lang") or "") or INTERNAL.search(r.get("Description_lang") or ""))


def rows(fl, table):
    p = DB2 / fl / f"{table}.csv"
    if not p.exists():
        import db2_fetch
        return db2_fetch.rows(fl, table)
    return list(csv.DictReader(p.open(encoding="utf-8")))


def clean(s):
    return re.sub(r"\s+", " ", (s or "").replace("|", "/")).strip()


def lua_str(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


def located(lines, action_pref=("T", "A", "C")):
    """(M, Z) of the best located step among a quest's lines"""
    for a in action_pref:
        for l in lines:
            if l.startswith(a + " "):
                m = re.search(r"\|M\|([^|]+)\|Z\|([^|]+)\|", l)
                if m:
                    return m.group(1), m.group(2)
    return None


def wiki_lines(fl):
    """qid -> every A/C/T step line of Imported_Wiki_<fl>.lua for that quest, in file order"""
    p = GUIDES / f"Imported_Wiki_{fl}.lua"
    out = collections.defaultdict(list)
    if not p.exists():
        return out
    for line in p.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^[ACT] .*?\|QID\|(\d+)\|", line)
        if m:
            out[int(m.group(1))].append(line)
    return out


def wiki_quest_lines(fl):
    """qid -> step lines from Imported_Wiki_<fl>.lua whose point is the wiki's own (a fallback-credited row is left out:
    the shippable --no-fallback build has no point there)"""
    return {q: [l for l in ls if not FALLBACK_NOTE.search(l)] for q, ls in wiki_lines(fl).items()}


def drop_fallback(line):
    """a wiki step line as the --no-fallback build writes it: a fallback point and its credit removed"""
    if not FALLBACK_NOTE.search(line):
        return line
    line = RE_MZ.sub("", line, count=1)
    return FALLBACK_NOTE.sub(" No coordinates on the wiki.", line, count=1)


def to_map(maps, uimap, pts):
    """Blizzard world points (centroid) -> (uiMapID, x, y percent) on that map, or None when off it"""
    m = maps.maps.get(uimap)
    if not m or not pts or not m["w"] or not m["h"] or m["type"] not in ZONE_TYPES:
        return None
    wx = sum(p[0] for p in pts) / len(pts)
    wy = sum(p[1] for p in pts) / len(pts)
    y01, x01 = (m["topX"] - wx) / m["h"], (m["leftY"] - wy) / m["w"]
    if not (-0.02 <= x01 <= 1.02 and -0.02 <= y01 <= 1.02):
        return None
    return uimap, round(min(max(x01, 0.0), 1.0) * 100, 1), round(min(max(y01, 0.0), 1.0) * 100, 1)


def quest_poi(fl, maps):
    """qid -> {"turnin": (map, x, y) | None, "obj": {objective index: (map, x, y)}} from Blizzard QuestPOIBlob +
    QuestPOIPoint (tools/gen_quest_guides_retail.py documents the indexes: -1 = turn-in pin, 32 = waypoint hint)"""
    blobs = rows(fl, "QuestPOIBlob")
    pts = collections.defaultdict(list)
    for p in rows(fl, "QuestPOIPoint"):
        pts[p["QuestPOIBlobID"]].append((float(p["X"]), float(p["Y"])))
    out = {}
    for b in blobs:
        oi = int(b["ObjectiveIndex"])
        if oi == 32:
            continue
        pos = to_map(maps, int(b["UiMapID"]), pts.get(b["ID"], []))
        if not pos:
            continue
        rec = out.setdefault(int(b["QuestID"]), {"turnin": None, "obj": {}})
        if oi == -1:
            rec["turnin"] = rec["turnin"] or pos
        else:
            rec["obj"].setdefault(oi, pos)
    return out


def overlay_points(fl, maps):
    """WorldMapOverlay id -> (uiMapID, x, y): the centre of the overlay's hit rectangle, in percent of its map.  The
    overlay is drawn on the map art (UiMapXMapArt -> UiMapArt -> UiMapArtStyleLayer gives the canvas size), whose
    canvas is the uiMap's 0..1 coordinate space."""
    size = {}
    for r in rows(fl, "UiMapArtStyleLayer"):
        if int(r["LayerIndex"] or 0) == 0:
            size[int(r["UiMapArtStyleID"])] = (float(r["LayerWidth"]), float(r["LayerHeight"]))
    art = {int(r["ID"]): size.get(int(r["UiMapArtStyleID"])) for r in rows(fl, "UiMapArt")}
    art_maps = collections.defaultdict(list)
    for r in rows(fl, "UiMapXMapArt"):
        art_maps[int(r["UiMapArtID"])].append(int(r["UiMapID"]))
    out = {}
    for r in rows(fl, "WorldMapOverlay"):
        a = int(r["UiMapArtID"] or 0)
        sz = art.get(a)
        cands = [m for m in art_maps.get(a, []) if m in maps.maps and maps.maps[m]["type"] in ZONE_TYPES]
        if not sz or not sz[0] or not sz[1] or not cands:
            continue
        left, right, top, bottom = (float(r[k] or 0) for k in ("HitRectLeft", "HitRectRight", "HitRectTop", "HitRectBottom"))
        if right <= left or bottom <= top:
            left, top = float(r["OffsetX"] or 0), float(r["OffsetY"] or 0)
            right, bottom = left + float(r["TextureWidth"] or 0), top + float(r["TextureHeight"] or 0)
        x, y = (left + right) / 2 / sz[0] * 100, (top + bottom) / 2 / sz[1] * 100
        if not (0 <= x <= 100 and 0 <= y <= 100):
            continue
        mid = sorted(cands, key=lambda m: (maps.maps[m]["type"] != 3, m))[0]
        out[int(r["ID"])] = (mid, round(x, 1), round(y, 1))
    return out


def named_areas(overlays, areas, overlay_pts):
    """AreaTable name -> [((uiMap, x, y), source)]: the centre of each exploration overlay that covers that area alone.
    An overlay that covers several areas (WorldMapOverlay.AreaID_0..3) stands for none of them."""
    area_pts = collections.defaultdict(list)
    for r in overlays:
        ids = [i for i in (int(r.get(k) or 0) for k in ("AreaID_0", "AreaID_1", "AreaID_2", "AreaID_3")) if i]
        if len(ids) == 1 and int(r["ID"]) in overlay_pts:
            area_pts[ids[0]].append((overlay_pts[int(r["ID"])], int(r["ID"])))
    out = collections.defaultdict(list)
    for r in areas:
        for pt, oid in area_pts.get(int(r["ID"]), []):
            name = clean(r["AreaName_lang"])
            if pt not in [p for p, _ in out[name]]:
                out[name].append((pt, f"Blizzard AreaTable {r['ID']}, WorldMapOverlay {oid}"))
    return out


class Places:
    """where a criterion or achievement happens, on one client's maps: 'M|x,y|Z|id; name|' or 'Z|id; name|' or ''.
    Every lookup returns (tag, source): the source names the wiki page or the Blizzard table the place came from, and
    the step's note carries it.  scope() is called for each achievement before its criteria are placed."""

    def __init__(self, fl, load=True):
        import wikimaps
        self.fl = fl
        self.atlas = wikimaps.Atlas()
        self.maps = self.atlas.sets[fl]
        self.norm = wikimaps.norm
        # a zone-type map with no parent map, named like a continent ("Dragon Isles" 2063), is the whole continent, not
        # a zone ("Zereth Mortis" 1970 sits under its continent and is a zone)
        names = {self.norm(m["name"]) for m in self.maps.maps.values() if m["type"] <= 2}
        self.continent_copies = {mid for mid, m in self.maps.maps.items()
                                 if m["type"] == 3 and m["parent"] not in self.maps.maps and self.norm(m["name"]) in names}
        self.qlines, self.instance, self.inst_maps, self.poi, self.overlay = {}, {}, collections.defaultdict(list), {}, {}
        self.encounter_map, self.area, self.quest, self.titles, self.item_src = {}, {}, {}, {}, {}
        self.npc_by_id, self.obj_by_id, self.npc_by_title, self.topic = {}, {}, {}, set()
        self.course_pt, self.course, self.glyph_pt = {}, collections.defaultdict(list), {}
        self.page_links, self.ach_page, self.quest_ids = collections.defaultdict(list), {}, collections.defaultdict(list)
        self.crit = collections.defaultdict(dict)
        # every zone-type map name a description may name (skyriding courses: "Complete Waking Shores ...")
        self.word_zone = {}
        self.scope()
        if load:
            self.load(fl)

    def load(self, fl):
        """Blizzard tables (tools/db2/<fl>), the wiki tables (tools/wiki/wiki.sqlite) and Imported_Wiki_<fl>.lua"""
        import wikimaps
        self.qlines = wiki_quest_lines(fl)
        for r in rows(fl, "Map"):
            self.instance[int(r["ID"])] = (clean(r["MapName_lang"]), r["InstanceType"], int(r.get("ExpansionID") or 0))
        for mid, m in self.maps.maps.items():
            if m["type"] in ZONE_TYPES:
                self.inst_maps[m["inst"]].append(mid)
        self.poi = quest_poi(fl, self.maps)
        self.overlay = overlay_points(fl, self.maps)
        self.encounter_map = {int(r["ID"]): int(r["MapID"]) for r in rows(fl, "DungeonEncounter")}
        self.area = named_areas(rows(fl, "WorldMapOverlay"), rows(fl, "AreaTable"), self.overlay)
        con = sqlite3.connect(WIKI_DB)
        self.quest = {int(i): (n, z, pt) for i, n, z, pt in con.execute("select id, name, zone, page_title from quests")}
        coords = collections.defaultdict(list)
        for t, z, x, y, c, src in con.execute("select title, zone, x, y, classic, source from npc_coords where x is not null "
                                              "order by title, idx"):
            coords[t].append((z, x, y, c, src or ""))
        for t, ids, z, x, y, pc, kind in con.execute("select title, npc_id, zone, x, y, page_classic, kind from npcs"):
            self.add_page(t, kind, ids, coords.get(t) or ([(z, x, y, pc, "lead")] if x is not None and z else []), z, pc)
        self.titles = {t: (p, k) for t, p, k in con.execute("select title, page_title, kind from titles")}
        for t, iid, src in con.execute("select title, item_id, sources_json from items"):
            s = json.loads(src or "[]")
            if iid and s:
                self.item_src.setdefault(int(iid), (t, s))
            self.item_src.setdefault(t, (t, s))
        # race courses: the wiki's race lists ("Skyriding races", "<Continent> Cup": a {{co}} start point per course),
        # else the wiki's race quests ("Skyrider Racing - Mereldar Meander") by course name
        if con.execute("select 1 from sqlite_master where name = 'race_courses'").fetchone():
            for c, z, x, y, pg in con.execute("select course, zone, x, y, page_title from race_courses"):
                self.course_pt.setdefault(wikimaps.norm(c), (z, x, y, pg))
        for i, n in con.execute("select id, name from quests where name like '%Racing - %' or name like '%Cup: %'"):
            self.course[wikimaps.norm(re.split(r" - |: ", n, maxsplit=1)[-1])].append(int(i))
        # glyphs: the wiki's glyph lists ("Dragon Glyph", "<zone> Glyph Hunter": a {{co}} per glyph)
        if con.execute("select 1 from sqlite_master where name = 'glyph_points'").fetchone():
            for n, z, x, y, pg in con.execute("select name, zone, x, y, page_title from glyph_points order by rowid"):
                self.glyph_pt.setdefault(wikimaps.norm(n), (z, x, y, pg))
        # the achievement's own wiki page: links and coords in its lead and location sections (tools/wiki/parse_wiki.py)
        if con.execute("select 1 from sqlite_master where name = 'achievement_links'").fetchone():
            for a, lk, cs in con.execute("select ach_id, link_title, coords_json from achievement_links order by ach_id, idx"):
                self.page_links[a].append((lk, json.loads(cs or "[]")))
        self.ach_page = {int(a): p for a, p in con.execute("select id, page_title from achievements where id is not null")}
        for i, pt in con.execute("select id, page_title from quests"):
            self.quest_ids[pt].append(int(i))
        for a, text, link, q in con.execute("select ach_id, text, link_title, quest_id from achievement_criteria"):
            self.crit[a][wikimaps.norm(text)] = (link, q)
        con.close()

    def add_page(self, t, kind, ids, pts, zone, pc):
        """one wiki NPC / object / place page; pts = [(zone, x, y, classic, source)] in page order.  Creature ids and
        object ids are separate id spaces: kept apart.  A place page about a zone, city or continent gives only that zone
        (its {{co}} rows are neighbours and landmarks: "Hellfire Peninsula" lists the Exodar portal); a place page whose
        every {{co}} stands in a body section is a topic page (a profession, class, holiday, expansion or system article
        listing other places: "Tailoring", "Noblegarden", "Pet tamer") and gives nothing."""
        if kind == "place":
            if self.zone_page(t):
                rec = ([], t, bool(pc))
            else:
                pts = [p for p in pts if not str(p[4]).startswith("body:")]
                if not pts:
                    self.topic.add(t)
                    return
                rec = ([tuple(p[:4]) for p in pts], pts[0][0], bool(pc))
        else:
            rec = ([tuple(p[:4]) for p in pts], zone, bool(pc))
        self.npc_by_title[t] = rec
        by = self.obj_by_id if kind == "object" else self.npc_by_id
        for i in re.findall(r"\d+", ids or ""):
            by.setdefault(int(i), (rec, t))

    # ---- the achievement being placed -----------------------------------------------------------------------------
    def scope(self, exp=None, named=False, zone=None, zone_src=None):
        """exp (Map.ExpansionID numbering, 0 Classic .. 11 Midnight): names a city or zone that exists twice resolve to
        that expansion's map (Dalaran, Eversong Woods, Shadowmoon Valley, Nagrand).  A point a name-matched wiki page
        gives must lie in `zone` (the achievement's zone, when it has one) and, when the Blizzard category names the
        expansion (named=True), not on a later expansion's map."""
        self.added = (exp + 1, 0, 0) if exp is not None else None
        self.draenor = exp == 5
        self.exp_known = exp if named else None
        self.zone_scope, self.zone_scope_src = zone, zone_src

    def resolve(self, name):
        return self.maps.resolve(name, self.added, self.draenor) if name else None

    def place_pt(self, z, x, y, classic=False):
        """a wiki point on this client's maps, read for the achievement's expansion"""
        if self.draenor and z and "(" not in z:
            hit = self.atlas.place(z + " (alternate universe)", x, y, self.fl, classic, self.added)
            if hit:
                return hit
        return self.atlas.place(z, x, y, self.fl, classic, self.added)

    def map_exp(self, mid):
        inst = self.instance.get(self.maps.maps[mid]["inst"]) if mid in self.maps.maps else None
        return inst[2] if inst else None

    def current_map(self, mid):
        """is `mid` the map its own name means for this achievement?  (Midnight's Eversong Woods, not the old one; Legion's
        Dalaran, not Northrend's; Draenor's Nagrand for a Draenor achievement)"""
        m = self.maps.maps.get(mid)
        r = self.resolve(m["name"]) if m else None
        return r is None or r == mid or self.maps.maps[r]["inst"] == m["inst"] or self.maps.maps[r]["type"] != m["type"]

    def in_zone(self, mid, z):
        """is map `mid` inside `z`: the same map, a subzone or parent of it, a map that belongs to zone `z`, or another
        floor of instance `z`.  An orphan or micro map (the Molten Front) does not take in its neighbours (Firelands)."""
        M = self.maps.maps
        if mid == z or self.maps.is_ancestor(z, mid) or self.maps.is_ancestor(mid, z):
            return True
        if M[z]["type"] == 3:
            return self.maps.home(mid) == self.maps.home(z)
        return M[z]["type"] == 4 and M[mid]["inst"] == M[z]["inst"]

    def in_scope(self, mid):
        """does a point on map `mid` fit the achievement being placed?"""
        if mid not in self.maps.maps or not self.current_map(mid):
            return False
        if self.zone_scope is not None and not self.in_zone(mid, self.zone_scope):
            return False
        e = self.map_exp(mid)
        return not (self.exp_known is not None and e is not None and e > self.exp_known)

    # ---- tags -----------------------------------------------------------------------------------------------------
    def _zone(self, mid):
        return f"Z|{mid}; {self.maps.maps[mid]['name']}|"

    def is_zone(self, mid, types=ZONE_TYPES):
        """a map a zone-level step may name: one of `types`, and not a zone-type copy of a continent map"""
        m = self.maps.maps.get(mid)
        return bool(m) and m["type"] in types and mid not in self.continent_copies

    def _zone_tag(self, name):
        """a zone step only for a name that resolves to a zone or instance map (never a continent)"""
        mid = self.resolve(name)
        return self._zone(mid) if mid is not None and self.is_zone(mid) else ""

    def zone_page(self, title):
        """is this the wiki page of a zone, city or continent (a map of type 3 or less on this client or on retail)?"""
        for S in (self.maps, self.atlas.sets["retail"]):
            mid = S.resolve(title)
            if mid is not None and S.maps[mid]["type"] <= 3:
                return True
        return False

    def placeable(self, mid):
        """a map the router can head for: not a battleground or arena (a queue, Map.InstanceType 3/4)"""
        inst = self.instance.get(self.maps.maps[mid]["inst"]) if mid in self.maps.maps else None
        return not (inst and inst[1] in QUEUE_INSTANCES)

    def map_tag(self, name, outdoor=False):
        """a zone step for a criterion or sentence that names a map, unless that map is a queue (or, for an outdoor
        collectible such as a skyriding glyph, an instance: "Brackenhide Hollow" is also a dungeon)"""
        z = self._zone_tag(name)
        if not z or not self.placeable(self.zone_of(z)):
            return ""
        if outdoor:
            mid = self.zone_of(z)
            inst = self.instance.get(self.maps.maps[mid]["inst"])
            if self.maps.maps[mid]["type"] == 4 or (inst and inst[1] in PLACE_INSTANCES):
                return ""
        return z

    def instance_tag(self, mapid):
        """the instance's own map (dungeon floor first), for a dungeon, raid or scenario Map id"""
        inst = self.instance.get(mapid)
        if not inst or inst[1] not in PLACE_INSTANCES:
            return ""
        cands = self.inst_maps.get(mapid)
        if cands:
            order = {4: 0, 6: 1, 5: 2, 3: 3}
            return self._zone(sorted(cands, key=lambda m: (order.get(self.maps.maps[m]["type"], 9), m))[0])
        return self._zone_tag(inst[0])

    # ---- sources --------------------------------------------------------------------------------------------------
    def quest_place(self, q):
        """(tag, why, source): the wiki's own point, else Blizzard's quest map pin, else the wiki's zone.  A wiki point on
        an old copy of a remade map (a Midnight quest's NPC row on the Burning Crusade Silvermoon) gives way to the pin."""
        page = self.quest.get(q, (None, None, None))[2]
        loc = located(self.qlines.get(q, []))
        if loc and self.current_map(self.zone_of(f"Z|{loc[1]}")):
            return f"M|{loc[0]}|Z|{loc[1]}|", "quest", f"wiki: {page or 'quest %d' % q}"
        p = self.poi.get(q)
        if p:
            pos = p["turnin"] or (p["obj"][min(p["obj"])] if p["obj"] else None)
            if pos:
                return f"M|{pos[1]:.1f},{pos[2]:.1f}|{self._zone(pos[0])}", "quest-poi", f"Blizzard QuestPOI, quest {q}"
        z = self._zone_tag(self.quest.get(q, (None, None, None))[1])
        return (z, "quest", f"wiki: {page}, the quest's zone") if z else ("", None, None)

    def _npc_place(self, rec, page):
        """(tag, source) for a wiki NPC / object / place page: its first point that fits the achievement, else, when
        every point lies elsewhere, the achievement's own zone (zone only) if it has one; a page with no point gives
        its zone when that fits"""
        pts, zone, classic = rec
        src = f"wiki: {page}"
        elsewhere = False
        for z, x, y, c in pts:
            hit = self.place_pt(z, x, y, bool(c) or classic)
            if hit and self.maps.maps[hit[0]]["type"] in ZONE_TYPES:
                if self.in_scope(hit[0]):
                    return f"M|{hit[1]:.1f},{hit[2]:.1f}|{self._zone(hit[0])}", src
                elsewhere = True
        if elsewhere:
            if self.zone_scope is not None:
                return self._zone(self.zone_scope), f"{self.zone_scope_src}; {page}'s wiki points lie elsewhere"
            return "", None
        z = self._zone_tag(zone)
        if z and self.in_scope(self.zone_of(z)):
            return z, src
        return "", None

    def _title_rec(self, name):
        """(rec, page) for the wiki NPC / object / place page with this title (redirects followed), or None"""
        if not name:
            return None
        t = self.titles.get(name) or self.titles.get(name[:1].upper() + name[1:])
        page = t[0] if t and t[1] in ("npc", "object", "place") else name
        rec = self.npc_by_title.get(page)
        return (rec, page) if rec else None

    def creature_place(self, npc):
        hit = self.npc_by_id.get(npc)
        return self._npc_place(*hit) if hit else ("", None)

    def object_place(self, obj):
        hit = self.obj_by_id.get(obj)
        return self._npc_place(*hit) if hit else ("", None)

    def item_place(self, item, desc):
        """where an item comes from: its wiki page's drop / source pages (by item id, else by the criterion's name)"""
        page, srcs = self.item_src.get(item) or self.item_src.get(desc) or (None, [])
        for src in srcs:
            hit = self._title_rec(src)
            if hit:
                where, s = self._npc_place(*hit)
            elif src in self.topic:
                continue
            else:
                where, s = self.map_tag(src), f"wiki: {src}"
            if where:
                return where, f"wiki: {page} -> {s[6:] if s.startswith('wiki: ') else s}"
        return "", None

    def area_place(self, name, az=""):
        """(tag, source): a named area that an exploration overlay covers alone -> the overlay's centre (the
        achievement's own zone breaks a tie), or ('', None)"""
        pts = [p for p in self.area.get(name) or [] if self.current_map(p[0][0])]
        if az and len(pts) > 1:
            near = [p for p in pts if self.in_zone(p[0][0], self.zone_of(az))]
            pts = near or pts
        if not pts or self.one_zone([p[0][0] for p in pts]) is None:
            return "", None
        (mid, x, y), src = pts[0]
        return f"M|{x:.1f},{y:.1f}|{self._zone(mid)}", f"{src}, the area's centre"

    def glyph_place(self, title):
        """(tag, source): a dragon / skyriding glyph achievement -> the wiki's {{co}} for that glyph"""
        m = COLLECTIBLE.match(title)
        pt = self.glyph_pt.get(self.norm(title[m.end():])) if m else None
        if pt:
            hit = self.place_pt(pt[0], pt[1], pt[2])
            if hit and self.maps.maps[hit[0]]["type"] in ZONE_TYPES:
                return f"M|{hit[1]:.1f},{hit[2]:.1f}|{self._zone(hit[0])}", f"wiki: {pt[3]}"
        return "", None

    def page_place(self, aid, text=""):
        """(tag, source) from the achievement's own wiki page: a {{Coords}} on a line whose link (if any) the title or
        description also names, else the first linked NPC / object / place page with a point, quest, or map that the
        title or description names (lead and location sections, page order).  A lead also links categories, rewards,
        professions, holidays and flavour-text NPCs: topic pages give nothing, a zone's page gives only the zone, and a
        point must fit the achievement (scope())."""
        said = self.norm(text)
        apage = self.ach_page.get(aid) or f"achievement {aid}"
        for lk, cs in self.page_links.get(aid, []):
            base = self.norm(re.sub(r"\s*\([^()]*\)$", "", lk or ""))
            named = bool(base) and base in said
            if cs and (lk is None or named):
                for x, y, z in cs:
                    hit = self.place_pt(z, x, y) if z else None
                    if hit and self.maps.maps[hit[0]]["type"] in ZONE_TYPES and self.in_scope(hit[0]):
                        return f"M|{hit[1]:.1f},{hit[2]:.1f}|{self._zone(hit[0])}", f"wiki: {apage}"
            if not named:
                continue
            t = self.titles.get(lk) or self.titles.get(lk[:1].upper() + lk[1:])
            page, kind = t if t else (lk, None)
            if page in self.topic:
                continue
            if kind in ("npc", "object", "place"):
                hit = self._title_rec(page)
                w, s = self._npc_place(*hit) if hit else ("", None)
                if w:
                    return w, f"wiki: {apage} -> {s[6:] if s.startswith('wiki: ') else s}"
            elif kind == "quest":
                for q in self.quest_ids.get(page, []):
                    w, _, s = self.quest_place(q)
                    if w:
                        return w, f"wiki: {apage} -> {s[6:] if s.startswith('wiki: ') else s}"
            z = self.map_tag(page) or self.map_tag(lk)
            if z and self.in_scope(self.zone_of(z)):
                return z, f"wiki: {apage} -> {page}"
        return "", None

    def course_place(self, title):
        """(tag, source): a race achievement ("Mereldar Meander Advanced: Gold") -> the wiki race list's start point,
        else the wiki race quest of that course"""
        c = re.sub(r":\s*(?:Bronze|Silver|Gold)$", "", title)
        c = re.sub(r"(?:\s+(?:Reverse|Advanced|Challenge))+$", "", c)
        pt = self.course_pt.get(self.norm(c))
        if pt:
            hit = self.place_pt(pt[0], pt[1], pt[2])
            if hit and self.maps.maps[hit[0]]["type"] in ZONE_TYPES:
                return f"M|{hit[1]:.1f},{hit[2]:.1f}|{self._zone(hit[0])}", f"wiki: {pt[3]}"
        for q in self.course.get(self.norm(c), []):
            where, _, s = self.quest_place(q)
            if where:
                return where, s
        return "", None

    def named_place(self, desc, npc_ok, az=""):
        """(tag, why, source) for a criterion named after a wiki NPC / object / place page, or after a map or area"""
        names = list(dict.fromkeys([desc, NAME_WRAP.sub("", desc).strip()]))
        for nm in names:
            if npc_ok:
                hit = self._title_rec(nm)
                if hit:
                    w, s = self._npc_place(*hit)
                    if w:
                        return w, "named-page", s
            z = self.map_tag(nm)
            if z:
                return z, "named-map", "Blizzard: the criterion names this map"
            a, s = self.area_place(nm, az)
            if a:
                return a, "named-area", s
        return "", None, None

    def wiki_criterion_place(self, aid, desc):
        """(tag, source): the wiki's own criterion list: a linked quest, or a linked NPC article"""
        hit = self.crit.get(aid, {}).get(self.norm(desc))
        if not hit:
            return "", None
        link, q = hit
        if q:
            w, _, s = self.quest_place(int(q))
            return w, s
        if link:
            t = self._title_rec(link) or self._title_rec(re.sub(r"\s*\(.*\)$", "", link))
            return self._npc_place(*t) if t else ("", None)
        return "", None

    def text_exp(self, text):
        """the latest expansion (Map.ExpansionID) of the zones a title or description names ("... in Eversong Woods,
        Zul'Aman, Harandar, and Voidstorm" -> Midnight), or None"""
        words = re.findall(r"[A-Za-z][A-Za-z'\-]*", text or "")
        best = None
        for n in range(1, min(4, len(words)) + 1):
            for i in range(len(words) - n + 1):
                run = " ".join(words[i:i + n])
                mid = self.maps.resolve(run) if len(run) >= 5 else None
                if mid is not None and self.is_zone(mid, (3,)):
                    e = self.map_exp(mid)
                    best = e if best is None or (e is not None and e > best) else best
        return best

    def text_zone(self, text):
        """the one zone a sentence names ("Complete Waking Shores Ruby Lifeshrine Loop.", "... the attack on the Molten
        Front"): the longest word run that is the name of a zone or standalone (orphan) map; two different zones at
        that length name no single place"""
        words = re.findall(r"[A-Za-z][A-Za-z'\-]*", text or "")
        for n in range(min(5, len(words)), 0, -1):
            found = set()
            for i in range(len(words) - n + 1):
                run = " ".join(words[i:i + n])
                if len(run) < 5:
                    continue
                key = (run, self.added, self.draenor)
                if key not in self.word_zone:
                    mid = self.resolve(run)
                    self.word_zone[key] = mid if (mid is not None and self.is_zone(mid, (3, 6))
                                                  and self.placeable(mid)) else None
                if self.word_zone[key] is not None:
                    found.add(self.word_zone[key])
            if found:
                return self._zone(found.pop()) if len(found) == 1 else ""
        return ""

    def achievement_zone(self, a):
        """(zone tag, why, source) when the whole achievement plainly belongs to one place, else ('', None, None)"""
        z = self.instance_tag(int(a["Instance_ID"] or -1))
        if z:
            return z, "instance", f"Blizzard Map {a['Instance_ID']}"
        title, desc = clean(a["Title_lang"]), clean(a["Description_lang"])
        m = re.match(r"^Explore (.+?)$", title) or re.match(r"^Explore (.+?), revealing", desc)
        if m:
            z = self._zone_tag(m.group(1))
            if z:
                return z, "explore", "Blizzard: the achievement names this zone"
        m = re.search(r"\bquests? in (?:the )?([A-Z][^.,]+?)\.?$", desc) or re.match(r"^(.+?) Quests$", title)
        if m:
            z = self._zone_tag(m.group(1))
            if z:
                return z, "quests-in-zone", "Blizzard: the achievement names this zone"
        return "", None, None

    def zone_of(self, where):
        m = re.search(r"Z\|(\d+);", where or "")
        return int(m.group(1)) if m else None

    def contradicts(self, where, az):
        """a criterion's map that is neither the achievement's own place nor a parent/child of it (a wrong-page match)"""
        a, b = (int(re.search(r"Z\|(\d+);", t).group(1)) for t in (where, az))
        return a != b and not self.maps.is_ancestor(a, b) and not self.maps.is_ancestor(b, a)

    def one_zone(self, mids):
        """the single zone a set of maps lies in (subzone and instance maps lift to their zone), or None"""
        homes = {self.maps.home(m) for m in mids if m is not None}
        return homes.pop() if len(homes) == 1 else None

    def queue_only(self, a):
        inst = self.instance.get(int(a["Instance_ID"] or -1))
        return bool(inst and inst[1] in QUEUE_INSTANCES)


# What each set may say about redistribution (tools/package_release.py fails a file that says "do not redistribute").
# Achievements, quest lines and missions are shippable (docs/FINISH_PLAN.md W9: wiki/DB2-generated guides ship).
PROVENANCE = {
    # no interop names in shippable headers: the packager reads them as derived content
    "achievements": ["-- (wago.tools DB2 exports, facts only: Achievement, Criteria, Map, QuestPOI, WorldMapOverlay, AreaTable,",
                     "-- DungeonEncounter) and Warcraft Wiki points: quest steps from Imported_Wiki_<flavor>.lua (only rows whose",
                     "-- point is the wiki's own) and wiki NPC, object, item, glyph, race and achievement pages,",
                     "-- https://warcraft.wiki.gg, by its contributors, licensed under CC BY-SA 4.0",
                     "-- (https://creativecommons.org/licenses/by-sa/4.0/); this data file is shared under the same licence,",
                     "-- see Guides/WIKI_DATA_LICENSE.md.  Each located step's note names the wiki page or Blizzard table."],
    "questlines": ["-- (wago.tools DB2 exports, facts only: QuestLine, QuestLineXQuest, QuestPOIBlob, QuestPOIPoint) and",
                   "-- Warcraft Wiki quest steps from Imported_Wiki_retail.lua (text, gates and the wiki's own points),",
                   "-- https://warcraft.wiki.gg, by its contributors, licensed under CC BY-SA 4.0",
                   "-- (https://creativecommons.org/licenses/by-sa/4.0/); this data file is shared under the same licence,",
                   "-- see Guides/WIKI_DATA_LICENSE.md.  Steps titled \"Quest <id>\" have no wiki page; the client shows",
                   "-- the live quest name."],
    "missions": ["-- (wago.tools DB2 export GarrMission, facts only)."],
}
# A header line for a file made from the default (fallback) build of Imported_Wiki_<flavor>.lua.  That build fills points
# the wiki lacks from the local Questie-derived file, so its steps (and which C steps exist) differ from the release
# build; the name in this line makes tools/package_release.py refuse the file (interop-derived), see test_package.py.
FALLBACK_BUILD = ("-- LOCAL BUILD: made from the default build of Imported_Wiki_{fl}.lua, whose fallback rows come from "
                  "Questie-derived data. It never ships: regenerate after tools/wiki/gen_wiki_guides.py --no-fallback.")


def wiki_build(fl):
    """which build of Imported_Wiki_<fl>.lua this run reads: 'no-fallback' (wiki only, the release build), 'fallback'
    (the default build; tools/wiki/gen_wiki_guides.py says so in its header) or None (no file)"""
    p = GUIDES / f"Imported_Wiki_{fl}.lua"
    if not p.exists():
        return None
    with p.open(encoding="utf-8") as fh:
        head = fh.read(6000)
    return "fallback" if "Regenerate with --no-fallback" in head else "no-fallback"


def header(fl, what):
    b = DB2 / fl / "BUILD"
    build = b.read_text().strip() if b.exists() else "unknown build"
    out = [f"-- AUTO-GENERATED by tools/gen_completion_guides.py ({what}) from Blizzard client data"] + PROVENANCE[what] + [
           f"-- Blizzard tables: client build {build} (tools/db2/{fl}/BUILD).  A point from Blizzard data says so in its step."]
    if what != "missions":
        wb = wiki_build(fl)
        out.append(FALLBACK_BUILD.format(fl=fl) if wb == "fallback" else
                   f"-- Wiki steps: the --no-fallback (wiki-only) build of Imported_Wiki_{fl}.lua." if wb else
                   f"-- Wiki steps: none (no Imported_Wiki_{fl}.lua when this was generated).")
    return out + ["local _, NS = ...", f'if NS.flavor ~= "{fl}" then return end', "local R = NS.Guide.Register"]


def zone_note(where, src=None):
    """a located step names where its place came from (wiki page or Blizzard table); a zone-level step says so (the
    router heads for the zone, the player finds the spot)"""
    if not where:
        return ""
    if not where.startswith("M|"):
        return f" (zone only; {src})" if src else " (zone only)"
    return f" ({src})" if src else ""


# Blizzard Map.ExpansionID numbering (0 Classic .. 11 Midnight): words in an achievement's category path that name it
EXPANSION_WORDS = ((11, ("Midnight",)), (10, ("War Within", "Khaz Algar")), (9, ("Dragonflight", "Dragon Isle")),
                   (8, ("Shadowlands", "Covenant", "Torghast")),
                   (7, ("Battle for Azeroth", "Island Expedition", "Heart of Azeroth", "Visions of N'Zoth", "War Effort")),
                   (6, ("Legion", "Broken Isles")), (5, ("Draenor", "Ashran")), (4, ("Pandaria",)),
                   (3, ("Cataclysm", "Tol Barad")), (2, ("Lich King", "Northrend", "Argent Tournament", "Wintergrasp")),
                   (1, ("Burning Crusade", "Outland")), (0, ("Classic",)))


def expansions(achs, catpath, k=7):
    """achievement id -> (expansion, named).  named: the Blizzard category path names it ("Exploration - Midnight",
    "Expansion Features - Draenor Garrison").  Otherwise (Professions, Skyriding, World Events) the expansion of the k
    nearest ids with a named category, each weighted by 1 / (1 + id distance): Blizzard hands ids out patch by patch."""
    named = {}
    for a in achs:
        p = catpath(int(a["Category"] or 0))
        e = next((e for e, words in EXPANSION_WORDS if any(w in p for w in words)), None)
        if e is not None:
            named[int(a["ID"])] = e
    ids = sorted(named)
    out = {i: (e, True) for i, e in named.items()}
    for a in achs:
        i = int(a["ID"])
        if i in out or not ids:
            continue
        j = bisect.bisect_left(ids, i)
        near = sorted(ids[max(0, j - k):j + k], key=lambda n: (abs(n - i), n))[:k]
        votes = collections.Counter()
        for n in near:
            votes[named[n]] += 1.0 / (1 + abs(n - i))
        out[i] = (votes.most_common(1)[0][0], False)
    return out


def gen_achievements(fl):
    every = [r for r in rows(fl, "Achievement") if not (int(r["Flags"] or 0) & 0x1)]
    ach = [r for r in every if not internal_achievement(r)]
    if not ach:
        print(f"{fl}: no Achievement.csv - skipped")
        return
    cats = {int(r["ID"]): r for r in rows(fl, "Achievement_Category")}
    crit = {int(r["ID"]): r for r in rows(fl, "Criteria")}
    kids = collections.defaultdict(list)
    tree = {}
    for r in rows(fl, "CriteriaTree"):
        tree[int(r["ID"])] = r
        kids[int(r["Parent"])].append(r)
    for k in kids:
        kids[k].sort(key=lambda r: (int(r["OrderIndex"] or 0), int(r["ID"])))
    achname = {int(r["ID"]): clean(r["Title_lang"]) for r in every}
    place = Places(fl)

    def rootcat(cid):
        seen = set()
        while cid in cats and cid not in seen:
            seen.add(cid)
            parent = int(cats[cid]["Parent"])
            if parent == -1 or parent not in cats:
                return clean(cats[cid]["Name_lang"])
            cid = parent
        return ""

    def catpath(cid):
        parts, seen = [], set()
        while cid in cats and cid not in seen and cid != -1:
            seen.add(cid)
            parts.append(clean(cats[cid]["Name_lang"]))
            cid = int(cats[cid]["Parent"])
        return " - ".join(reversed(parts)) or "Other"

    def leaves(root):
        out, stack, seen = [], [root], set()
        if not root:
            return out
        while stack and len(out) < MAX_CRIT:
            node = stack.pop(0)
            if node in seen:
                continue
            seen.add(node)
            r = tree.get(node)
            if r and int(r["CriteriaID"] or 0):
                out.append(r)
            stack[0:0] = [int(c["ID"]) for c in kids.get(node, [])]
        return out

    exp_of = expansions(ach, catpath)
    leaves_of = {int(a["ID"]): leaves(int(a["Criteria_tree"] or 0)) for a in ach}
    # part achievement -> the metas it counts for ("Dragon Glyphs: X" -> "<zone> Glyph Hunter")
    metas = collections.defaultdict(list)
    for a in ach:
        for leaf in leaves_of[int(a["ID"])]:
            c = crit.get(int(leaf["CriteriaID"]))
            if c and c["Type"] == "8" and int(c["Asset"] or 0):
                metas[int(c["Asset"])].append(a)

    def meta_zone(aid):
        """(zone tag, source): the one zone the metas this achievement counts for name ("Isle of Dorn Glyph Hunter")"""
        found = {}
        for m in metas.get(aid, []):
            z = place.text_zone(clean(m["Title_lang"])) or place.text_zone(clean(m["Description_lang"]))
            if z:
                found[z] = f"Blizzard: its meta achievement {clean(m['Title_lang'])} names this zone"
        return next(iter(found.items())) if len(found) == 1 else ("", None)

    # ---- pass 1: every criterion's place ------------------------------------------------------------------------
    st = collections.Counter()   # step counts by how the location was found
    plan = []                    # (achievement row, az, azwhy, azsrc, [criterion dicts], fallback, fwhy, fsrc)
    zones_of = {}                # achievement -> maps its located steps sit on (for meta achievements)
    for a in sorted(ach, key=lambda r: (int(r["Category"] or 0), int(r["Ui_order"] or 0), int(r["ID"]))):
        aid = int(a["ID"])
        title = achname[aid] or f"Achievement {aid}"
        desc_a = clean(a["Description_lang"])
        exp, named = exp_of.get(aid, (None, False))
        if not named:
            te = place.text_exp(title + " " + desc_a)
            exp = te if exp is None or (te is not None and te > exp) else exp
        place.scope(exp, named)
        az, azwhy, azsrc = place.achievement_zone(a)
        # the zone a name-matched wiki page's point must lie in: the achievement's own place, else the one zone its
        # description or title names ("... Fiona's travelling party in Eastern Plaguelands", "Opposing Orgrimmar")
        zs, zsrc = az, azsrc
        if not zs:
            zs, zsrc = place.text_zone(desc_a), "Blizzard: the description names this zone"
        if not zs:
            zs, zsrc = place.text_zone(title), "Blizzard: the title names this zone"
        place.scope(exp, named, place.zone_of(zs) if zs else None, zsrc if zs else None)
        crits = []
        for leaf in leaves_of[aid]:
            c = crit.get(int(leaf["CriteriaID"]))
            desc = clean(leaf["Description_lang"])
            ctype = c["Type"] if c else ""
            asset = int(c["Asset"] or 0) if c else 0
            cr = {"ct": int(leaf["ID"]), "desc": desc, "type": ctype, "asset": asset, "where": "", "why": None, "src": None}
            crits.append(cr)
            if ctype == "8":
                continue
            where, why, src = "", None, None
            if ctype == "27" and asset:
                where, why, src = place.quest_place(asset)
            elif ctype == "0" and asset:
                (where, src), why = place.creature_place(asset), "creature"
            elif ctype == "43" and asset in place.overlay:
                mid, x, y = place.overlay[asset]
                where, why, src = f"M|{x:.1f},{y:.1f}|{place._zone(mid)}", "explore-overlay", f"Blizzard WorldMapOverlay {asset}"
            elif ctype == "68" and asset:
                (where, src), why = place.object_place(asset), "object"
            elif ctype == "165" and asset in place.encounter_map:
                inst = place.instance_tag(place.encounter_map[asset])
                if inst:
                    # the boss's own wiki point when it lies in that instance, else the instance map
                    w, _, s = place.named_place(desc, True)
                    where, why, src = ((w, "encounter-page", s) if w.startswith("M|") and place.zone_of(w) in
                                       place.inst_maps.get(place.encounter_map[asset], []) else
                                       (inst, "encounter-instance", f"Blizzard DungeonEncounter {asset}"))
            elif ctype == "71" and asset:
                where, why, src = place.instance_tag(asset), "instance-run", f"Blizzard Map {asset}"
            elif ctype in ITEM_TYPES and asset:
                (where, src), why = place.item_place(asset, desc), "item-source"
            if not where and ctype not in NOGEO_TYPES:
                (where, src), why = place.wiki_criterion_place(aid, desc), "wiki-criterion"
            if not where and ctype not in NOGEO_TYPES and desc:
                where, why, src = place.named_place(desc, ctype in NAMED_TYPES, az)
            if not where:
                where, why, src = az, azwhy or "achievement-zone", azsrc
            if where and az and place.contradicts(where, az):
                where, why, src = az, "criterion contradicted achievement place", azsrc
                st["contradicted"] += 1
            cr["where"], cr["why"], cr["src"] = where, why, (src if where else None)
        # an achievement-level place when no criterion found one: a glyph's wiki point, "Hidden Treasures: <zone>" (the
        # part after the colon), an explorable area, a race course, the achievement's wiki page, a description or
        # title naming one zone, the one zone its metas name
        fallback, fwhy, fsrc = "", None, None
        types = {c["type"] for c in crits}
        if not az and not any(c["where"] for c in crits) and rootcat(int(a["Category"] or 0)) not in NOGEO_ROOTS \
                and not (types and types <= NOGEO_TYPES):
            part = title.split(": ", 1)[1] if ": " in title else ""
            outdoor = bool(COLLECTIBLE.match(title))
            for w, fn in (("glyph", lambda: place.glyph_place(title)),
                          ("named-zone", lambda: (place.map_tag(part, outdoor), "Blizzard: the title names this map")),
                          ("named-area", lambda: place.area_place(part)),
                          ("race-course", lambda: place.course_place(title)),
                          ("wiki-page", lambda: place.page_place(aid, title + " " + desc_a)),
                          ("named-zone", lambda: (place.text_zone(desc_a), "Blizzard: the description names this zone")),
                          ("named-zone", lambda: (place.text_zone(title), "Blizzard: the title names this zone")),
                          ("meta-zone", lambda: meta_zone(aid))):
                fz, fs = fn()
                if fz:
                    fallback, fwhy, fsrc = fz, w, fs
                    break
        zones_of[aid] = ({place.zone_of(c["where"]) for c in crits if c["where"]} | ({place.zone_of(az)} if az else set())
                         | ({place.zone_of(fallback)} if fallback else set()))
        plan.append((a, az, azwhy, azsrc, crits, fallback, fwhy, fsrc))

    # ---- pass 2: meta achievements ("complete achievement N") take the one zone their parts sit in ------------------
    for _ in range(4):
        changed = False
        for a, az, azwhy, azsrc, crits, *_ in plan:
            aid = int(a["ID"])
            for cr in crits:
                if cr["type"] == "8" and cr["asset"] and not cr["where"]:
                    z = place.one_zone(zones_of.get(cr["asset"], set()))
                    if z is not None:
                        cr["where"], cr["why"], cr["src"] = place._zone(z), "meta-part", "where the part achievement's steps are"
                        zones_of[aid].add(z)
                        changed = True
        if not changed:
            break

    # ---- pass 3: write ----------------------------------------------------------------------------------------------
    guides = collections.defaultdict(list)
    nsteps = 0
    achs = collections.Counter()  # achievements by best outcome
    gained = collections.Counter()  # zone-level achievements by reason
    nogeo_why = collections.Counter()
    for a, az, azwhy, azsrc, crits, fallback, fwhy, fsrc in plan:
        aid = int(a["ID"])
        title = achname[aid] or f"Achievement {aid}"
        fac = {"0": "Horde", "1": "Alliance"}.get(a["Faction"], "")
        ftag = f"FACTION|{fac}|" if fac else ""
        body = []
        any_point = any_zone = False
        types = set()
        root = rootcat(int(a["Category"] or 0))
        for cr in crits:
            types.add(cr["type"])
            where, why = cr["where"], cr["why"]
            if cr["type"] == "8" and cr["asset"]:
                sub = cr["asset"]
                body.append(f"C {achname.get(sub) or cr['desc'] or 'Achievement %d' % sub}|ACH|{sub}|{where}{ftag}"
                            f"N|Needed for {lua_str(title)}.{zone_note(where, cr['src'])}|")
                if where:
                    st["zone meta-part"] += 1
                    any_zone = True     # a step of this block names a zone (tools/coverage.py counts it for the meta)
                continue
            if where:
                st[("point" if where.startswith("M|") else "zone") + " " + why] += 1
                any_point |= where.startswith("M|")
                any_zone |= not where.startswith("M|")
            if cr["type"] == "27" and cr["asset"]:
                name = place.quest.get(cr["asset"], (None, None, None))[0] or cr["desc"] or f"Quest {cr['asset']}"
                body.append(f"C {clean(name)}|QID|{cr['asset']}|ACH|{aid};{cr['ct']}|{where}{ftag}"
                            f"N|{lua_str(title)}: complete this quest.{zone_note(where, cr['src'])}|")
            else:
                body.append(f"C {cr['desc'] or title}|ACH|{aid};{cr['ct']}|{where}{ftag}N|{lua_str(title)} criterion."
                            f"{zone_note(where, cr['src'])}|")
        fixed_zone, why, fixed_src = az, azwhy, azsrc
        if not (any_point or any_zone or az):
            # an achievement-level place (pass 1), else a meta whose parts sit in one zone
            zs = zones_of.get(aid, set()) - {None}
            z = place.one_zone(zs)
            if fallback:
                fixed_zone, why, fixed_src = fallback, fwhy, fsrc
                st[f"achievement-level {'point' if fallback.startswith('M|') else 'zone'} {fwhy}"] += 1
            elif z is not None:
                fixed_zone, why, fixed_src = place._zone(z), "meta", "where its part achievements' steps are"
        if fixed_zone:
            any_point |= fixed_zone.startswith("M|")
            any_zone |= not fixed_zone.startswith("M|")
        nogeo = ""
        if not (any_point or any_zone):
            reason = None
            if place.queue_only(a):
                reason = "battleground"
            elif root in NOGEO_ROOTS:
                reason = NOGEO_ROOTS[root]
            elif types and types <= NOGEO_TYPES:
                reason = "counter"
            if reason:
                nogeo = f"NOGEO|{reason}|"
                nogeo_why[reason] += 1
        achs["point" if any_point else "zone" if any_zone else "non-geographic" if nogeo else "unlocated"] += 1
        if any_zone and not any_point:
            gained[why or ("meta-part" if any(c["why"] == "meta-part" for c in crits) else "criterion-zone")] += 1
        body.append(f"C {title}|ACH|{aid}|FIXED|{fixed_zone}{nogeo}{ftag}N|{lua_str(clean(a['Description_lang']))} "
                    f"({a['Points']} pts){zone_note(fixed_zone, fixed_src)}|")
        guides[catpath(int(a["Category"] or 0))].extend(body)
        nsteps += len(body)
    lines = header(fl, "achievements")
    for name in sorted(guides):
        gid = re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")
        lines.append(f'R({{ id="ach:{fl}:{gid}", name="{lua_str(name)}", type="Achievements", '
                     f'author="Blizzard achievement data", source="CompletionRoute", text=[==[')
        lines.extend(l.replace("]==]", "] ==]") for l in guides[name])
        lines.append("]==] })")
    out = GUIDES / f"Imported_Achievements_{fl}.lua"
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"{fl}: {len(ach)} achievements ({len(every) - len(ach)} internal left out) -> {len(guides)} category guides, "
          f"{nsteps} steps -> {out.relative_to(ROOT)} (wiki build: {wiki_build(fl)})")
    print(f"  achievements by best location: {dict(achs)}")
    print(f"  zone-only achievements by reason: {dict(gained)}")
    print(f"  non-geographic by reason: {dict(nogeo_why)}")
    print(f"  located steps: {dict(sorted(st.items()))}")


def gen_questlines(fl="retail"):
    """storyline guides from Blizzard QuestLine order + wiki quest steps + Blizzard quest pins (no third-party data)"""
    import wikimaps
    maps = wikimaps.Atlas().sets[fl]
    ql = {int(r["ID"]): r for r in rows(fl, "QuestLine")}
    members = collections.defaultdict(list)
    for r in rows(fl, "QuestLineXQuest"):
        members[int(r["QuestLineID"])].append((int(r["OrderIndex"] or 0), int(r["QuestID"])))
    wl = wiki_lines(fl)
    poi = quest_poi(fl, maps)

    def mz(pos):
        return f"M|{pos[1]:.1f},{pos[2]:.1f}|Z|{pos[0]}; {maps.maps[pos[0]]['name']}|"

    def zonly(mid):
        return f"Z|{mid}; {maps.maps[mid]['name']}|"

    def with_point(line, tag, why):
        """put a Blizzard pin (or zone) on a wiki line that has none, right before its note; the client reads tags in
        any order (Core/Guide.lua ParseLine)"""
        if " No coordinates on the wiki.|" in line:
            line = line.replace(" No coordinates on the wiki.|", f" ({why})|", 1)
        else:
            line = re.sub(r"\|N\|([^|]*)\|$", lambda m: f"|N|{m.group(1)} ({why})|", line, count=1)
        i = line.rfind("|N|")
        return line[:i + 1] + tag + line[i + 1:] if i >= 0 else line + tag

    st = collections.Counter()
    lines = header(fl, "questlines")
    ng = nsteps = 0
    for lid in sorted(members):
        qs = [q for _, q in sorted(members[lid])]
        name = clean(ql.get(lid, {}).get("Name_lang")) or f"Storyline {lid}"
        body, prev, zone = [], None, None
        for q in qs:
            p = poi.get(q) or {"turnin": None, "obj": {}}
            src = [drop_fallback(l) for l in wl.get(q, [])]
            if src:
                st["wiki quests"] += 1
                out = []
                for l in src:
                    if "|M|" not in l:
                        act = l[0]
                        qo = re.search(r"\|QO\|(\d+)\|", l)
                        pos = None
                        if act == "T":
                            pos = p["turnin"]
                        elif act == "C":
                            pos = p["obj"].get(int(qo.group(1)) - 1) if qo else (p["obj"][min(p["obj"])] if p["obj"] else None)
                        if pos:
                            l = with_point(l, mz(pos), "point: Blizzard quest map pin")
                            st["steps given a Blizzard pin"] += 1
                        elif act == "A" and (p["turnin"] or p["obj"]):
                            any_pos = p["turnin"] or p["obj"][min(p["obj"])]
                            l = with_point(l, zonly(any_pos[0]), "zone only: the quest's map in Blizzard data")
                            st["accepts given the quest's map (zone only)"] += 1
                        else:
                            st["steps left without a location"] += 1
                    out.append(l)
            else:
                st["quests without a wiki page"] += 1
                nm = f"Quest {q}"
                anchor = p["turnin"] or (p["obj"][min(p["obj"])] if p["obj"] else None)
                if anchor:
                    out = [f"A {nm}|QID|{q}|{zonly(anchor[0])}N|No wiki page; the quest's map from Blizzard data (zone only).|"]
                    for oi in sorted(p["obj"]):
                        out.append(f"C {nm}|QID|{q}|QO|{oi + 1}|{mz(p['obj'][oi])}N|Objective area (Blizzard quest map pin).|")
                    out.append(f"T {nm}|QID|{q}|{mz(p['turnin'])}N|Turn-in pin (Blizzard data).|" if p["turnin"]
                               else f"T {nm}|QID|{q}|N|No turn-in pin in Blizzard data.|")
                    st["wiki-less quests with a Blizzard pin"] += 1
                else:
                    out = [f"A {nm}|QID|{q}|N|No wiki page and no map pin in Blizzard data - follow the story.|",
                           f"T {nm}|QID|{q}|"]
                    st["wiki-less quests with no location"] += 1
            for l in out:
                if prev and l.startswith("A ") and "|PRE|" not in l:
                    l = l.replace(f"|QID|{q}|", f"|QID|{q}|PRE|{prev}|", 1)
                if zone is None:
                    m = re.search(r"\|Z\|(\d+);", l)
                    zone = m.group(1) if m else None
                body.append(l.replace("]==]", "] ==]"))
            prev = q
        ng += 1
        nsteps += len(body)
        z = f"zone={zone}, " if zone else ""
        lines.append(f'R({{ id="story:{fl}:{lid}", name="{lua_str(name)}", type="Storylines", {z}'
                     f'author="Blizzard quest-line data, Warcraft Wiki contributors (CC BY-SA 4.0)", source="CompletionRoute", text=[==[')
        lines.extend(body)
        lines.append("]==] })")
    out_path = GUIDES / STORY_FILE.format(fl=fl)
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"{fl}: {ng} quest lines, {nsteps} steps -> {out_path.relative_to(ROOT)}")
    print(f"  {dict(st)}")


# mission tables: GarrTypeID -> [(title, faction, zone step)]
TABLES = {
    "2": [("Garrison Missions (Alliance)", "Alliance", "R Lunarfall garrison mission table|Z|582; Lunarfall|FACTION|Alliance|"),
          ("Garrison Missions (Horde)", "Horde", "R Frostwall garrison mission table|Z|590; Frostwall|FACTION|Horde|")],
    "3": [("Order Hall Missions", "", "R Your class order hall (portal in Dalaran)|Z|627; Dalaran|N|The mission table is in your class order hall.|")],
    "9": [("War Campaign Missions (Alliance)", "Alliance", "R Boralus war table|Z|1161; Boralus|FACTION|Alliance|"),
          ("War Campaign Missions (Horde)", "Horde", "R Dazar'alor war table|Z|1165; Dazar'alor|FACTION|Horde|")],
    "111": [("Covenant Adventures", "", "R Your covenant sanctum (from Oribos)|Z|1670; Oribos|N|The adventure table is in your covenant sanctum.|")],
}


def gen_missions():
    ms = rows("retail", "GarrMission")
    by = collections.defaultdict(list)
    for r in ms:
        by[r["GarrTypeID"]].append(r)
    lines = header("retail", "missions")
    n = 0
    for gt, tabs in TABLES.items():
        for title, fac, first in tabs:
            ftag = f"FACTION|{fac}|" if fac else ""
            body = [first]
            for r in sorted(by.get(gt, []), key=lambda r: (int(r["TargetLevel"] or 0), int(r["ID"]))):
                hrs = int(r["MissionDuration"] or 0) / 3600
                kind = "Shipyard" if r["GarrFollowerTypeID"] == "2" else "Mission"
                body.append(f"N {clean(r['Name_lang']) or 'Mission %s' % r['ID']}|MISSION|{r['ID']}|{ftag}"
                            f"N|{kind} lvl {r['TargetLevel']}, {r['MaxFollowers']} followers, {hrs:g} h, cost {r['MissionCost']}. "
                            f"{clean(r['Location_lang'])}|")
                n += 1
            lines.append(f'R({{ id="mission:retail:{gt}:{fac or "all"}", name="{lua_str(title)}", type="Missions", '
                         f'{("faction=%s, " % repr(fac).replace(chr(39), chr(34))) if fac else ""}'
                         f'author="Blizzard mission data", source="CompletionRoute", text=[==[')
            lines.extend(body)
            lines.append("]==] })")
    left = [gt for gt in by if gt not in TABLES]
    out = GUIDES / "Imported_Missions_retail.lua"
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"retail: {len(ms)} missions -> {n} mission steps (unmapped table types: {left}) -> {out.relative_to(ROOT)}")


def _selfcheck():
    """the place rules on synthetic wiki and Blizzard rows: no wiki.sqlite or DB2 export needed (a fresh clone has
    neither), only tools/maps_retail.lua.  Each check is a defect the 2026-11-11 review found in a generated file."""
    fails = []

    def check(ok, msg):
        if not ok:
            fails.append(msg)
    P = Places("retail", load=False)
    # instance -> (name, InstanceType, ExpansionID) for the maps used below
    P.instance = {0: ("Eastern Kingdoms", "0", 0), 1: ("Kalimdor", "0", 0), 530: ("Outland", "0", 1),
                  571: ("Northrend", "0", 2), 1116: ("Draenor", "0", 5), 1220: ("Broken Isles", "0", 6),
                  1643: ("Kul Tiras", "0", 7), 2444: ("Dragon Isles", "0", 9)}
    exodar = [("Exodar", 46.0, 61.0, 0, "body:geography")]
    # a zone's own page: the zone only, never its geography row in a neighbouring zone (Local Pet Mauler)
    P.add_page("Hellfire Peninsula", "place", None, exodar, "Exodar", 0)
    w, why, src = P.named_place("Hellfire Peninsula", True)
    check(w == "Z|100; Hellfire Peninsula|" and src == "wiki: Hellfire Peninsula", f"zone page -> {w!r} {src!r}")
    # a topic page (every {{co}} in a body section) gives nothing, as a criterion name or an achievement page link
    P.add_page("Tailoring", "place", None, [("Dalaran", 39.0, 26.0, 0, "body:tailoring in wrath o")], "Dalaran", 0)
    P.add_page("World of Warcraft: Cataclysm", "place", None,
               [("Abyssal Depths", 71.0, 29.0, 0, "body:dungeons and raids")], "Abyssal Depths", 0)
    P.titles["Cataclysm"] = ("World of Warcraft: Cataclysm", "place")
    check("Tailoring" in P.topic and P.named_place("Tailoring", True)[0] == "", "topic page Tailoring gave a place")
    P.page_links[17498] = [("Cataclysm", [])]
    check(P.page_place(17498, "Renowned Leatherworking Specialist prior to the Cataclysm") == ("", None),
          "an expansion article linked from an achievement page gave a place")
    # coordinates on the achievement page count only on a line whose link the title or description names (or no link)
    P.page_links[1295] = [("Blue Crashin' Thrashin' Racer Controller", [[44.0, 45.0, "Dalaran"]])]
    check(P.page_place(1295, "Crashin' & Thrashin' Win 25 races")[0] == "", "unnamed link's coordinates were used")
    P.page_links[40727] = [(None, [[65.2, 57.2, "City of Threads"]])]
    check(P.page_place(40727, "Skittershaw Spin")[0].startswith("M|65.2,57.2|Z|"), "a bare coordinate on the page was lost")
    # a name-matched NPC page whose points lie outside the achievement's zone: that zone only (Fiona of Full Caravan)
    P.add_page("Fiona", "npc", None, [("Boralus", 68.0, 41.2, 0, "location")], "Boralus", 0)
    P.scope(zone=23, zone_src="Blizzard: the description names this zone")
    w, why, src = P.named_place("Fiona", True)
    check(w == "Z|23; Eastern Plaguelands|" and "lie elsewhere" in (src or ""), f"Fiona -> {w!r} {src!r}")
    P.scope()
    check(P.named_place("Fiona", True)[0].startswith("M|68.0,41.2|Z|1161;"), "Fiona without a zone scope")
    # a category that names the expansion: no point on a later expansion's map
    P.scope(exp=3, named=True)
    check(P.named_place("Fiona", True)[0] == "", "a Cataclysm achievement took a Kul Tiras point")
    # names that exist twice resolve for the achievement's expansion; an old copy of a remade map is not in scope
    for exp, name, want in ((11, "Eversong Woods", 2395), (1, "Eversong Woods", 94), (11, "Silvermoon City", 2393),
                            (5, "Shadowmoon Valley", 539), (0, "Shadowmoon Valley", 104), (5, "Nagrand", 550),
                            (6, "Dalaran", 627), (2, "Dalaran", 125), (None, "Dalaran", 125)):
        P.scope(exp)
        check(P.zone_of(P._zone_tag(name)) == want, f"{name} for expansion {exp} -> {P._zone_tag(name)!r}, want {want}")
    P.scope(11)
    check(not P.in_scope(94) and P.in_scope(2395), "Midnight achievement: legacy Eversong Woods (94) in scope")
    P.scope(5)
    hit = P.place_pt("Shadowmoon Valley", 50.0, 50.0)
    check(hit is not None and hit[0] == 539, f"a Draenor achievement's Shadowmoon Valley point -> {hit}")
    P.scope()
    # glyphs: the wiki's {{co}} for the glyph, credited to its page; never an instance map for an outdoor collectible
    P.glyph_pt[P.norm("Windsong Rise")] = ("Ohn'ahran Plains", 61.5, 64.4, "Dragon Glyph")
    check(P.glyph_place("Dragon Glyphs: Windsong Rise") == ("M|61.5,64.4|Z|2023; Ohn'ahran Plains|", "wiki: Dragon Glyph"),
          f"glyph -> {P.glyph_place('Dragon Glyphs: Windsong Rise')}")
    bh = P.maps.resolve("Brackenhide Hollow")
    check(bh is not None and P.map_tag("Brackenhide Hollow") and P.map_tag("Brackenhide Hollow", outdoor=True) == "",
          f"Brackenhide Hollow outdoor -> {P.map_tag('Brackenhide Hollow', outdoor=True)!r}")
    # an exploration overlay that covers several areas stands for none of them
    areas = named_areas([{"ID": "1", "AreaID_0": "10", "AreaID_1": "11"}, {"ID": "2", "AreaID_0": "12"}],
                        [{"ID": "10", "AreaName_lang": "Burning Ascent"}, {"ID": "11", "AreaName_lang": "Dragonbane Keep"},
                         {"ID": "12", "AreaName_lang": "Windsong Rise"}], {1: (2022, 33.2, 60.4), 2: (2023, 54.8, 74.2)})
    check(set(areas) == {"Windsong Rise"} and areas["Windsong Rise"][0][1] == "Blizzard AreaTable 12, WorldMapOverlay 2",
          f"shared overlay -> {dict(areas)}")
    # a description may name a standalone (orphan) map; a zone-type copy of a continent map is no zone
    check(P.zone_of(P.text_zone("Speak with them during the attack on the Molten Front.")) == 338, "Molten Front")
    check(P.text_zone("Place a flag on 10 of the tallest peaks in the Dragon Isles.") == "" and
          P._zone_tag("Dragon Isles") == "", f"Dragon Isles -> {P._zone_tag('Dragon Isles')!r}")
    check(P.zone_of(P.text_zone("Use it on Progenitor Forges throughout Zereth Mortis.")) == 1970, "Zereth Mortis is a zone")
    # a standalone map's scope does not take in its neighbours: Malfurion's Firelands row is not the Molten Front
    P.add_page("Malfurion Stormrage", "npc", None, [("Firelands", 51.6, 24.6, 0, "npclocations")], "Firelands", 0)
    P.scope(exp=3, named=True, zone=338, zone_src="Blizzard: the description names this zone")
    check(P.named_place("Malfurion Stormrage", True)[0] == "Z|338; Molten Front|", "Fireside Chat: Firelands taken")
    P.scope()
    # every located step names its source; zone-level steps say so
    check(zone_note("M|1.0,2.0|Z|84; Stormwind City|", "wiki: Tailoring") == " (wiki: Tailoring)", "point note")
    check(zone_note("Z|84; Stormwind City|", "Blizzard Map 0") == " (zone only; Blizzard Map 0)", "zone note")
    # an achievement's expansion: its category's words, else the nearest ids that have them
    cats = {1: "Exploration - Midnight", 2: "Expansion Features - Skyriding", 3: "Quests - Legion"}
    achs = [{"ID": str(i), "Category": str(c)} for i, c in ((61500, 1), (61510, 1), (61520, 1), (61524, 2), (10700, 3),
                                                            (10710, 3), (10722, 2))]
    ex = expansions(achs, lambda c: cats.get(c, ""))
    check(ex[61524] == (11, False) and ex[10722] == (6, False) and ex[61500] == (11, True), f"expansions -> {ex}")
    # a file made from the default (fallback) wiki build names the Questie-derived source, so the packager refuses it
    check("Questie" in FALLBACK_BUILD, "FALLBACK_BUILD must name the Questie-derived source")
    for f in fails:
        print("FAIL gen_completion_guides:", f)
    if fails:
        raise SystemExit(1)
    print("gen_completion_guides place checks passed")


def main():
    if "--selfcheck" in sys.argv:
        return _selfcheck()
    args = [a for a in sys.argv[1:] if a != "--achievements-only"]
    only_ach = len(args) != len(sys.argv) - 1
    fls = args or ["retail", "mop"]
    for fl in fls:
        gen_achievements(fl)
        if fl == "retail" and not only_ach:
            gen_questlines(fl)
            gen_missions()


if __name__ == "__main__":
    main()
