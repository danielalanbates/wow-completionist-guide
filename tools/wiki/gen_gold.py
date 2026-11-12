#!/usr/bin/env python3
# CompletionRoute :: tools/wiki/gen_gold.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Gold guides from community data: gathering circuits, mob farming circuits, fishing, daily hubs, methods, instance runs.

    python3 tools/wiki/gen_gold.py [era tbc mop retail forever]        (use the heavy lock on the 8 GB Mac)

Writes CompletionRoute/Guides/Imported_Gold_<fl>.lua (gitignored, CC BY-SA 4.0 header) and the gold_guides table in
docs/verification.sqlite.  See docs/GOLD_ROUTES.md.

Sources.  Warcraft Wiki pages (fetched through wiki_fetch.py) and tools/wiki/wiki.sqlite + cache/wiki_raw.sqlite;
Guides/Imported_Wiki_<fl>.lua steps, but never a step whose location came from another project's data (their note
says "(location: Questie data"): those points are dropped, and counted.  Nothing here reads a paid guide.
No auction price, vendor price total or gold-per-hour figure is ever written into a guide: "Generic" means realm-independent,
so the addon measures what a lap is worth in game instead (Core/Farm.lua).
"""
import collections
import datetime
import json
import math
import re
import sqlite3
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import wiki_fetch as W  # noqa: E402
import wikimaps  # noqa: E402
from wikitext import links as wiki_links, plain  # noqa: E402
from gen_spine import ZoneLevels, CACHE, RAW  # noqa: E402

GUIDES = ROOT / "CompletionRoute" / "Guides"
VERIF = ROOT / "docs" / "verification.sqlite"
WIKIDB = HERE / "wiki.sqlite"
TODAY = datetime.date.today().isoformat()

FLAVORS = ["era", "tbc", "mop", "retail", "forever"]
CAP = {"era": 60, "tbc": 70, "mop": 90, "retail": 90, "forever": 60}
EXPANSION = {"era": 1, "forever": 1, "tbc": 2, "mop": 5, "retail": 12}   # highest expansion's data a client carries
CLASSIC_LIKE = ("era", "tbc", "forever")
FACTIONS = ("Alliance", "Horde")
MIN_WAYPOINTS = 6
MAX_WAYPOINTS = 20
CAPITAL_NAMES = wikimaps.CAPITALS

ATTRIB = """-- Data derived from Warcraft Wiki, https://warcraft.wiki.gg, by its contributors, licensed under CC BY-SA 4.0
-- (https://creativecommons.org/licenses/by-sa/4.0/). This data file is shared under the same licence;
-- see Guides/WIKI_DATA_LICENSE.md. Written into steps by CompletionRoute; advice text is original wording."""


def log(*a):
    print(*a, flush=True)


# ---------------------------------------------------------------------------------------------------------------
# Npcbox facts (creature type, level) for the mobs we route to.  One pass over wiki_raw, cached as JSON.
# ---------------------------------------------------------------------------------------------------------------
RX_FIELD = {k: re.compile(r"^[ \t]*\|[ \t]*%s[ \t]*=[ \t]*(.*?)[ \t]*$" % k, re.M | re.I)
            for k in ("level", "classiclvl", "creature", "faction", "status", "type", "gender")}
RE_ADDED = re.compile(r"\{\{\s*Patch\s+(\d+)\.[^|}]*\|\s*note\s*=\s*Added", re.I)
RE_NAMED_LEAD = re.compile(r"'''[^']+?'''\s+is\b")
CLIENT_MAJOR = {"era": 1, "forever": 1, "tbc": 2, "mop": 5, "retail": 99}
# Skill at which each expansion's nodes started before the skill reset; wiki pages 'Mining' / 'Skinning', "Former Skill Range"
EXP_FLOOR = {1: 1, 2: 275, 3: 350, 4: 425, 5: 525}


def npcbox_facts():
    cache = CACHE / "gold_npcbox.json"
    if cache.exists():
        return json.loads(cache.read_text(encoding="utf-8"))
    log("parsing Npcbox fields from wiki_raw ...")
    raw = sqlite3.connect(f"file:{RAW}?mode=ro", uri=True)
    out = {}
    for title, w in raw.execute("select title, wikitext from pages p join page_templates t using(pageid)"
                                " where t.template='Npcbox'"):
        i = w.lower().find("{{npcbox")
        if i < 0:
            continue
        box = w[i:i + 2500]
        d = {k: (m.group(1)) for k, r in RX_FIELD.items() for m in [r.search(box)] if m}
        m = RE_ADDED.search(w)
        if m:
            d["added"] = int(m.group(1))
        if re.search(r"\{\{\s*classic only\b", w[:400], re.I):
            d["classic_only"] = 1
        d["named"] = 1 if (d.get("gender", "").lower() in ("male", "female") and RE_NAMED_LEAD.search(w[i:i + 4000])) else 0
        out[title] = d
    cache.write_text(json.dumps(out), encoding="utf-8")
    return out


TEMPLATE_KEYS = re.compile(r"\{\{\s*level\s*\|\s*([^}|]+?)\s*\}\}", re.I)


def level_info(facts, flavor, zone_lo, zone_hi, levels):
    """(lo, hi, how) or None: 'num' = a number on the page (or classiclvl), 'zone' = the wiki says the mob has the
    zone's level.  Numbers more than 3 levels outside the zone's band are treated as another game version's number."""
    raw = (facts.get("classiclvl") if flavor in CLASSIC_LIKE and facts.get("classiclvl") else facts.get("level")) or ""
    raw = raw.strip()
    if not raw or raw in ("??", "?"):
        return None
    if re.search(r"elite|boss|rare", raw, re.I):
        return None
    m = re.fullmatch(r"(\d+)(?:\s*-\s*(\d+))?", raw)
    if m:
        lo, hi = int(m.group(1)), int(m.group(2) or m.group(1))
        if zone_lo is not None and (hi < zone_lo - 3 or lo > zone_hi + 3):
            return None
        return lo, hi, "num"
    # {{Level|Westfall}}, or the bare template key the box usually carries
    key = TEMPLATE_KEYS.sub(lambda mm: mm.group(1), raw).strip()
    key = re.sub(r"\s*\(.*\)$", "", key)
    r = levels.get(flavor, key)[0] if key and not re.search(r"[^\w '\-:,]", key) else None
    if r:
        return r[0], r[1], "zone"
    return None


def on_client(facts, flavor):
    """the page says the creature exists on this client (Classic-only pages are not on mop/retail; pages Added later are not on older clients)"""
    if facts.get("added") and facts["added"] > CLIENT_MAJOR[flavor]:
        return False
    if facts.get("classic_only") and flavor in ("mop", "retail"):
        return False
    return True


def is_killable(facts):
    """an ordinary hostile population: not a friendly NPC, not a named or elite single creature"""
    if (facts.get("faction") or "").lower() not in ("combat", "hostile"):
        return False
    st = (facts.get("status") or "").lower()
    if st and "killable" not in st:
        return False
    if facts.get("named"):
        return False
    return not re.search(r"elite|boss|rare", facts.get("type") or "", re.I)


def creature_kind(facts):
    c = (facts.get("creature") or "").lower()
    if "critter" in c or "battle pet" in c or "non-combat" in c:
        return None
    if "beast" in c:
        return "Beast"
    if "humanoid" in c:
        return "Humanoid"
    return None


# ---------------------------------------------------------------------------------------------------------------
# Tables on wiki pages
# ---------------------------------------------------------------------------------------------------------------
def wikitable_rows(text):
    """every row of every wikitable in `text`: a list of raw cell strings (cells may continue over several lines)"""
    rows = []
    for tbl in re.findall(r"\{\|(.*?)\n\|\}", text, re.S):
        for chunk in re.split(r"\n\|-[^\n]*", tbl):
            cells, cur = [], None
            for line in chunk.split("\n"):
                if line.startswith("|+"):
                    continue
                if line.startswith(("|", "!")):
                    if cur is not None:
                        cells.append(cur)
                    cur = line[1:]
                elif cur is not None:
                    cur += " " + line
            if cur is not None:
                cells.append(cur)
            if cells:
                rows.append(cells)
    return rows


ZONE_SPELL = {"Ashenvale Forest": "Ashenvale", "Tanaris Desert": "Tanaris", "The Blasted Lands": "Blasted Lands",
              "Blasted Lands": "Blasted Lands", "Gun'Drak": "Gundrak", "Ahn'kahet: The Old Kingdom": "Ahn'kahet"}


def clean_zone(cell):
    ls = wiki_links(cell)
    if ls:
        name = ls[0][0]
    else:
        name = plain(cell).strip()
    name = re.sub(r"\s*\((burning crusade|classic|zone|alternate universe|outland|shattrath)\)\s*$", "", name, flags=re.I)
    return ZONE_SPELL.get(name, name)


def herb_data():
    """{zone name: [herb names]} from 'Herbs by Area', {herb: (min skill or None, expansion)} from 'Herb'"""
    table = W.page("Herb")
    skill, exp, section = {}, {}, 1
    sect_rx = re.compile(r"^==+\s*(.*?)\s*==+\s*$")
    for block in re.split(r"(?m)^(?=={2,3}[^=])", table):
        head = sect_rx.match(block.split("\n", 1)[0] + "\n" if "\n" in block else block + "\n")
        t = (head.group(1).lower() if head else "")
        section = {"wotlk": 3, "northrend": 3, "outland": 2, "bc-inline": 2, "cata": 4, "pandaria": 5, "mop": 5, "draenor": 6,
                   "legion": 7, "battle for azeroth": 8, "bfa": 8, "shadowlands": 9, "dragon isles": 10,
                   "khaz algar": 11, "midnight": 12}.get(next((k for k in ("wotlk", "northrend", "outland", "bc-inline", "cata",
                   "pandaria", "mop", "draenor", "legion", "battle for azeroth", "bfa", "shadowlands", "dragon isles", "khaz algar",
                   "midnight") if k in t), ""), section if t else 1)
        for cells in wikitable_rows(block):
            if len(cells) < 2:
                continue
            ls = wiki_links(cells[0])
            m = re.search(r"Difficulty\|(\d+)", cells[1])
            if ls and m:
                exp.setdefault(ls[0][0], section)
    # newer expansions are not on 'Herbs by Area': the Herb table's own zone column names them
    PANDARIA = ["Jade Forest", "Valley of the Four Winds", "Krasarang Wilds", "Kun-Lai Summit", "Townlong Steppes", "Dread Wastes",
                "Vale of Eternal Blossoms"]
    extra = collections.defaultdict(list)
    for block in re.split(r"(?m)^(?=={2,3}[^=])", table):
        for cells in wikitable_rows(block):
            ls = wiki_links(cells[0])
            if not ls or len(cells) < 4:
                continue
            herb = ls[0][0]
            if exp.get(herb, 1) < 4:
                continue
            txt = plain(cells[-1])
            if "throughout Pandaria" in txt:
                names = PANDARIA
            else:
                txt = re.sub(r"^(Near water in|Inside caves, near water in|Snowy areas of|Sha-touched areas in|Grassy areas throughout)\s+", "", txt)
                txt = re.sub(r"\([^)]*\)", "", txt).replace(" and ", ",").replace("Towlong", "Townlong")
                names = [t.strip() for t in re.split(r"[,;]", txt) if t.strip()]
            for z in names:
                if herb not in extra[z]:
                    extra[z].append(herb)
    zones = collections.defaultdict(list)
    for z, herbs in extra.items():
        zones[z] += herbs
    for cells in wikitable_rows(W.page("Herbs by Area")):
        if len(cells) < 5:
            continue
        zone = clean_zone(cells[0])
        herbs = [t for t, _ in wiki_links(cells[4])]
        if zone and herbs and "Herb" not in zone:
            zones[zone] += [h for h in herbs if h not in zones[zone]]
    # the skill that opens a herb, from the herb's own page ("[[Herbalism]] (125)"); retail-era pages that only say
    # (1) carry no information for the older clients, so a page without a number leaves the herb unknown
    for herb in sorted({h for hs in zones.values() for h in hs} | set(exp)):
        if exp.get(herb, 1) > 5:
            continue                # retail gathers everything from skill 1: no number needed, no page fetched
        page = W.page(herb)
        m = re.search(r"\[\[Herbalism\]\]\s*\((\d+)\)", page) or re.search(r"Herbalism\s*\((\d+)\)", page)
        if m and int(m.group(1)) > 1:
            skill[herb] = int(m.group(1))
        elif m and exp.get(herb, 1) == 1:
            skill[herb] = 1
    return zones, skill, exp


# Lower bound of each expansion's profession range (wiki 'Mining' table, Former Skill Range), for a node whose page gives
# no number.  Only used on clients that still have the old skill bands; retail gathers everything from skill 1.
SKILL_FLOOR = EXP_FLOOR


MINING_SECTIONS = [("Classic proficiency", 1), ("Outland proficiency", 2), ("Northrend proficiency", 3),
                   ("Cataclysm proficiency", 4), ("Pandaria proficiency", 5), ("Draenor proficiency", 6),
                   ("Legion proficiency", 7), ("Battle for Azeroth proficiency", 8), ("Shadowlands proficiency", 9),
                   ("Dragon Isles proficiency", 10), ("Khaz Algar proficiency", 11)]
SKIP_NODE = re.compile(r"Hakkari|Ooze Covered|Incendicite|Indurium|Bloodstone|Cold Iron|Fool's Gold|Greater Moonstone|"
                       r"Starsilver|Primal|Infurious|Molten|Titan-Touched|Living |Hardened|Luminous|Rough |Coarse|Dense |Gleaming|"
                       r"Burnished|Ductile|Smooth |Ancient|Bright|Brilliant|Charged|Crude|Dark |Exquisite|Fiery|Fine |Glowing|"
                       r"Hard |Raw |Stormy|Striking|Superior|Warm|Wild |Burning|Darkened|Heavy |Malevolent|Odious|Shattered|"
                       r"Seam|Spike|Boulder|Core|Chunk|Crystallized|Camouflaged|EZ-Mine|Weeping|Webbed|Sivstone|Loose")


def mining_data():
    """{zone: [node names]}, {node: (classic min skill or None, expansion)} from 'Mining node' and each node page"""
    text = W.page("Mining node")
    nodes = {}
    parts = re.split(r"(?m)^==([^=].*?)==\s*$", text)
    for i in range(1, len(parts) - 1, 2):
        head = parts[i].strip()
        exp = next((e for n, e in MINING_SECTIONS if n.lower() == head.lower()), None)
        if exp is None:
            continue
        body = parts[i + 1]
        # the "Standard" list only; quest-only and removed nodes are not worth a route
        body = re.split(r"(?mi)^;\s*(location-specific|quest-related|world quest|treasure|season)", body)[0]
        for t, _ in wiki_links(body):
            t = t.lstrip(":")
            if SKIP_NODE.search(t) or t.lower().startswith(("template", "category")):
                continue
            nodes.setdefault(t, exp)
    zones = collections.defaultdict(list)
    skill = {}
    for node, exp in nodes.items():
        page = W.page(node)
        if not page:
            continue
        sk = None
        m = re.search(r"Mining \((\d+)\)\s*in\s*''(?:\[\[[^\]|]*\|)?(?:World of Warcraft: )?Classic", page) or \
            re.search(r"With \[\[Mining\]\] \((\d+)\)", page) or re.search(r"mining skill (\d+)", page, re.I)
        if m:
            sk = int(m.group(1))
        skill[node] = sk if sk and sk > 1 else EXP_FLOOR.get(exp, 1)
        sec = re.split(r"(?m)^==\s*Locations\s*==\s*$", page, maxsplit=1)
        if len(sec) < 2:
            continue
        body = re.split(r"(?m)^==[^=]", sec[1])[0]
        for line in body.split("\n"):
            if not line.startswith("*") or "Classic only" in line and exp > 1:
                continue
            for t, _ in wiki_links(line):
                z = clean_zone(f"[[{t}]]")
                if node not in zones[z]:
                    zones[z].append(node)
    return zones, skill, nodes


def fishing_data():
    """[(zone, location text, skill or None, [fish names])] from 'Fishing locations'"""
    out = []
    for cells in wikitable_rows(W.page("Fishing locations")):
        if len(cells) < 4:
            continue
        zone = clean_zone(cells[0])
        loc = plain(cells[1]).strip()
        sk = re.search(r"\d+", plain(cells[2]) or "")
        fish = [t for t, _ in wiki_links(cells[3]) if "(quest)" not in t]
        fish = [f for f in fish if "Objective" not in f]
        if zone and fish:
            out.append((zone, loc, int(sk.group(0)) if sk else None, fish))
    return out


def ah_locations():
    """[{faction, city, area, auctioneers: [title...], exp}] from 'Auction House' ==Locations=="""
    text = W.page("Auction House")
    sec = text.split("==Locations==", 1)[1]
    sec = re.split(r"(?m)^==[^=]", sec)[0]
    out = []
    faction, city, city_exp = None, None, 1
    EXP = {"bc-inline": 2, "wotlk-inline": 3, "cata-inline": 4, "mop-inline": 5, "wod-inline": 6, "legion-inline": 7,
           "bfa-inline": 8, "sl-inline": 9, "df-inline": 10, "tww-inline": 11, "mn-inline": 12}
    for line in sec.split("\n"):
        m = re.match(r"===\{\{(Horde|Alliance|Neutral)\}\}", line)
        if m:
            faction = m.group(1)
            continue
        m = re.match(r"\*(?!\*)\s*(\{\{\S+?\}\})?\s*(.*)", line)
        if m and not line.startswith("**"):
            tag = (m.group(1) or "").strip("{}").lower()
            ls = wiki_links(m.group(2))
            if ls:
                city, city_exp = ls[0][0], EXP.get(tag, 1)
                city = re.sub(r"\s*\(.*\)$", "", city)
                out.append({"faction": faction, "city": city, "area": "", "aucs": [], "exp": city_exp, "cityline": True})
            continue
        if line.startswith("**") and city:
            sub = line[2:].strip()
            sm = re.match(r"\{\{(\S+?)\}\}", sub)
            exp = EXP.get(sm.group(1).lower(), city_exp) if sm else city_exp
            aucs = [t for t, _ in wiki_links(sub) if t.lower().startswith(("auctioneer", "reginald", "brassbolt", "d.e.n.t", "h.a.r.v.e.y",
                                                                              "regla", "devin", "shei", "kong", "edierre"))]
            area = plain(sub.split("&ndash;")[0]).strip()
            out.append({"faction": faction, "city": city, "area": area, "aucs": aucs, "exp": exp, "cityline": False})
    return [o for o in out if not o["cityline"]]


# ---------------------------------------------------------------------------------------------------------------
# Per-flavor world data
# ---------------------------------------------------------------------------------------------------------------
RE_REG = re.compile(r'R\(\{ id="([^"]+)", name="((?:[^"\\]|\\.)*)", type="([^"]+)", zone=(\d+), (?:faction="(\w+)", )?minlevel=(\d+), maxlevel=(\d+)')


def parse_step_line(line):
    parts = line.rstrip("\n").split("|")
    head = parts[0]
    if len(head) < 3 or head[1] != " " or head[0] not in "ACT":
        return None
    tags = {}
    i = 1
    while i < len(parts) - 1:
        if parts[i] in ("O", "S", "US", "FIXED", "ROUTE"):
            i += 1
            continue
        tags[parts[i]] = parts[i + 1]
        i += 2
    return head[0], head[2:], tags


class World:
    """everything one flavor needs: zones, walkable points, mob points"""

    def __init__(self, fl, atlas, levels, npcbox):
        self.fl, self.atlas, self.levels, self.box = fl, atlas, levels, npcbox
        self.ms = atlas.sets[fl]
        self.cap = CAP[fl]
        self.points = collections.defaultdict(list)     # uiMapID -> [(x, y)]
        self.mob_pts = collections.defaultdict(lambda: collections.defaultdict(list))  # mid -> mob -> [(x,y)]
        self.zone_q = collections.Counter()             # mapID -> quest steps by faction
        self.zone_fac = collections.defaultdict(collections.Counter)
        self.qlines = collections.defaultdict(dict)     # qid -> {'A': (tags), 'T': (tags), 'name': }
        self.skipped_questie = 0
        self.guide_band = {}                            # mapID -> (lo, hi) from the wiki quest guides
        self._read_wiki_guides()
        self._read_npc_points()

    # ------------------------------------------------------------------
    def _read_wiki_guides(self):
        path = GUIDES / f"Imported_Wiki_{self.fl}.lua"
        if not path.exists():
            log(f"  {self.fl}: no Imported_Wiki file, no walkable points from quests")
            return
        with path.open(encoding="utf-8") as f:
            for line in f:
                m = RE_REG.search(line)
                if m:
                    zone, lo, hi = int(m.group(4)), int(m.group(6)), int(m.group(7))
                    a, b = self.guide_band.get(zone, (lo, hi))
                    self.guide_band[zone] = (min(a, lo), max(b, hi))
                    continue
                st = parse_step_line(line)
                if not st:
                    continue
                act, title, tags = st
                note = tags.get("N", "")
                qsource = "location: Questie" in note
                if qsource:
                    self.skipped_questie += 1
                mz = re.match(r"(\d+)", tags.get("Z", ""))
                mid = int(mz.group(1)) if mz else None
                if act == "A" and mid:
                    self.zone_fac[mid][tags.get("FACTION") or "Both"] += 1
                # keep the first line per (quest, action) for the daily guides, with its origin
                if "QID" in tags and act in "AT":
                    q = tags["QID"].split("^")[0].split("&")[0]
                    if q.isdigit():
                        self.qlines[int(q)].setdefault(act, (title, tags, qsource))
                if qsource or not mid or "M" not in tags or mid not in self.ms.maps:
                    continue
                pts = []
                for pair in tags["M"].split(";"):
                    p = pair.split(",")
                    if len(p) == 2:
                        try:
                            pts.append((float(p[0]), float(p[1])))
                        except ValueError:
                            pass
                pts = [p for p in pts if 0 < p[0] < 100 and 0 < p[1] < 100]
                self.points[mid] += pts
                if act == "C" and tags.get("T"):
                    mob = tags["T"]
                    self.mob_pts[mid][mob] += pts

    # ------------------------------------------------------------------
    def _read_npc_points(self):
        """every wiki NPC coordinate that places on this client: walkable points, and mob points for hostile pages"""
        db = sqlite3.connect(f"file:{WIKIDB}?mode=ro", uri=True)
        rows = db.execute("select c.title, c.zone, c.x, c.y, c.classic, coalesce(n.page_classic,0), n.kind "
                          "from npc_coords c left join npcs n on n.title=c.title where c.x is not null")
        for title, zone, x, y, classic, page_classic, kind in rows:
            if classic and self.fl not in CLASSIC_LIKE:
                continue
            if kind == "object":
                continue
            if title in self.box and not on_client(self.box[title], self.fl):
                continue
            placed = self.atlas.place(zone, x, y, self.fl, bool(classic or page_classic))
            if not placed:
                continue
            mid, px, py = placed
            if mid not in self.ms.maps or not (0 < px < 100 and 0 < py < 100):
                continue
            self.points[mid].append((round(px, 2), round(py, 2)))
            if title in self.box:
                self.mob_pts[mid][title].append((round(px, 2), round(py, 2)))

    # ------------------------------------------------------------------
    def zone_band(self, name, mid):
        band = None
        lv = self.levels.get(self.fl, name)[0]
        if lv:
            band = lv
        else:
            # a zone Midnight reworked (Eversong Woods) keeps its old range on its "(Burning Crusade)" page, not on Template:Level
            m = re.search(r"previous zone level:\s*(\d+)\s*-\s*(\d+)", self.levels.page(f"{name} (Burning Crusade)") or "", re.I) if self.fl != "retail" else None
            if m:
                band = (int(m.group(1)), int(m.group(2)))
            elif mid in self.guide_band:
                band = self.guide_band[mid]
        if band is None:
            return None
        lo, hi = band
        hi = min(hi, self.cap)
        return (lo, hi) if lo <= hi else None

    def zone_faction(self, mid):
        c = self.zone_fac.get(mid)
        if not c:
            return None
        a, h = c.get("Alliance", 0), c.get("Horde", 0)
        both = c.get("Both", 0)
        if a >= 8 and a >= 4 * max(h, 1) and a >= both:
            return "Alliance"
        if h >= 8 and h >= 4 * max(a, 1) and h >= both:
            return "Horde"
        return None

    def zone_of(self, name):
        """the zone-type uiMapID a wiki zone name is on this client, or None"""
        mid = self.ms.resolve(name)
        if mid is None:
            return None
        m = self.ms.maps.get(mid)
        if not m or m["type"] != 3 or m["name"] in CAPITAL_NAMES:
            return None
        return mid

    def yards(self, mid, a, b):
        return self.atlas.yards(self.fl, mid, a, b)


# ---------------------------------------------------------------------------------------------------------------
# Tour building: cluster the real points, keep the well-connected ones, shortest closed tour in yards
# ---------------------------------------------------------------------------------------------------------------
def build_tour(world, mid, pts, cell_frac=0.08, want=18, min_nodes=MIN_WAYPOINTS, max_nodes=MAX_WAYPOINTS, link_yards=None):
    """-> [(x, y)] closed-tour waypoints in map percent, or None if the zone has too few spread real points"""
    if not pts:
        return None
    m = world.ms.maps.get(mid)
    if not m or not m["w"] or not m["h"]:
        return None
    W_yd, H_yd = m["w"], m["h"]
    cell_x, cell_y = max(1.2, 100 * cell_frac), max(1.2, 100 * cell_frac)
    grid = collections.defaultdict(list)
    for x, y in pts:
        grid[(int(x // cell_x), int(y // cell_y))].append((x, y))
    nodes = []
    for cellpts in grid.values():
        n = len(cellpts)
        nodes.append({"x": sum(p[0] for p in cellpts) / n, "y": sum(p[1] for p in cellpts) / n, "w": n})
    if len(nodes) < min_nodes:
        return None

    def dist(a, b):
        return math.hypot((a["x"] - b["x"]) / 100 * W_yd, (a["y"] - b["y"]) / 100 * H_yd)

    # drop lonely clusters: an isolated quest point across a mountain would pull the tour over bad ground
    nd = [min((dist(a, b) for b in nodes if b is not a), default=0) for a in nodes]
    nd_sorted = sorted(nd)
    med = nd_sorted[len(nd_sorted) // 2] or 1
    nodes = [n for n, d in zip(nodes, nd) if d <= max(med * 3, 250)]
    if len(nodes) < min_nodes:
        return None
    if link_yards:
        # the biggest group of clusters joined by short hops: a real hunting ground, not a dash across the zone
        parent = list(range(len(nodes)))

        def find(i):
            while parent[i] != i:
                parent[i] = parent[parent[i]]
                i = parent[i]
            return i
        for i in range(len(nodes)):
            for j in range(i + 1, len(nodes)):
                if dist(nodes[i], nodes[j]) <= link_yards:
                    parent[find(i)] = find(j)
        groups = collections.defaultdict(list)
        for i, n in enumerate(nodes):
            groups[find(i)].append(n)
        nodes = max(groups.values(), key=lambda g: (len(g), sum(n["w"] for n in g)))
        if len(nodes) < min_nodes:
            return None
    # thin to at most max_nodes: keep heavy clusters, spread out (farthest point insertion seeded by the heaviest)
    if len(nodes) > max_nodes:
        chosen = [max(nodes, key=lambda n: n["w"])]
        rest = [n for n in nodes if n is not chosen[0]]
        while len(chosen) < want and rest:
            best = max(rest, key=lambda n: min(dist(n, c) for c in chosen) * (1 + 0.15 * math.log(n["w"] + 1)))
            chosen.append(best)
            rest.remove(best)
        nodes = chosen
    tour = two_opt(nearest_neighbour(nodes, dist), dist)
    # a ring has no start: cut it at its shortest edge, so the last waypoint is right next to the first
    cut = min(range(len(tour)), key=lambda i: dist(tour[i], tour[(i + 1) % len(tour)]))
    tour = tour[cut + 1:] + tour[:cut + 1]
    return [(round(n["x"], 2), round(n["y"], 2)) for n in tour]


def nearest_neighbour(nodes, dist):
    # start at the node closest to the centroid so the entry into the ring is not at a far corner
    cx = sum(n["x"] for n in nodes) / len(nodes)
    cy = sum(n["y"] for n in nodes) / len(nodes)
    start = min(nodes, key=lambda n: (n["x"] - cx) ** 2 + (n["y"] - cy) ** 2)
    left = [n for n in nodes if n is not start]
    tour = [start]
    while left:
        cur = tour[-1]
        nxt = min(left, key=lambda n: dist(cur, n))
        left.remove(nxt)
        tour.append(nxt)
    return tour


def two_opt(tour, dist):
    n = len(tour)
    if n < 4:
        return tour
    improved, passes = True, 0
    while improved and passes < 40:
        improved, passes = False, passes + 1
        for i in range(n - 1):
            for j in range(i + 2, n):
                a, b = tour[i], tour[i + 1]
                c, d = tour[j], tour[(j + 1) % n]
                if b is c or a is d:
                    continue
                if dist(a, c) + dist(b, d) < dist(a, b) + dist(c, d) - 1e-6:
                    tour[i + 1:j + 1] = reversed(tour[i + 1:j + 1])
                    improved = True
    return tour


# ---------------------------------------------------------------------------------------------------------------
# Guide assembly
# ---------------------------------------------------------------------------------------------------------------
class Guide:
    __slots__ = ("id", "name", "kind", "zone", "faction", "lo", "hi", "req", "lines", "loop", "farm", "source", "band")

    def __init__(self, gid, name, kind, zone, faction, lo, hi, req, lines, loop, farm, source):
        self.id, self.name, self.kind, self.zone, self.faction, self.lo, self.hi = gid, name, kind, zone, faction, lo, hi
        self.req, self.lines, self.loop, self.farm, self.source = req, lines, loop, farm, source
        self.band = f"{lo}-{hi}"


def q(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


def lua_guide(g, attrib_author="Warcraft Wiki contributors (CC BY-SA 4.0)"):
    fac = f'faction="{g.faction}", ' if g.faction else ""
    req = f'requires="{g.req}", ' if g.req else ""
    zone = f'zone={g.zone}, ' if g.zone else ""
    loop = "loop=true, " if g.loop else "noCircuit=true, "
    farm = ""
    if g.farm:
        def lv(v):
            return "true" if v is True else "false" if v is False else f'"{q(v)}"' if isinstance(v, str) else str(v)
        farm = "farm={ " + ", ".join(f"{k}={lv(v)}" for k, v in g.farm.items()) + " }, "
    head = f'R({{ id="{g.id}", name="{q(g.name)}", type="Gold", folder="{g.kind}", goldKind="{g.kind}", {zone}{fac}minlevel={g.lo}, maxlevel={g.hi}, {req}{loop}{farm}author="{attrib_author}", source="CompletionRoute", text=[==[\n'
    return head + "\n".join(g.lines) + "\n]==] })\n"


def zone_name(world, mid):
    return world.ms.maps[mid]["name"]


def ztag(world, mid):
    return f"{mid}; {zone_name(world, mid)}"


def gather_guides(world, fl, kind, node_zones, node_skill, node_exp, beast_zones, stats):
    """one circuit per zone per gathering profession, where the wiki says that node or beast type occurs"""
    out = []
    items = {}
    if kind == "Skinning":
        items = beast_zones
    else:
        for zname, nodes in node_zones.items():
            nodes = [n for n in nodes if node_exp.get(n, 1) <= EXPANSION[fl]]
            if nodes:
                items[zname] = nodes
    for zname, nodes in sorted(items.items()):
        mid = world.zone_of(zname)
        if mid is None:
            stats["gather_zone_not_on_client"] += 1
            continue
        band = world.zone_band(zone_name(world, mid), mid)
        if not band:
            stats["gather_no_zone_level"] += 1
            continue
        lo, hi = band
        pts = list(world.points.get(mid, []))
        if kind == "Skinning":
            beast_pts = [p for mob in nodes for p in world.mob_pts[mid].get(mob, [])]
            tour = build_tour(world, mid, beast_pts) or build_tour(world, mid, pts)
        else:
            tour = build_tour(world, mid, pts)
        if not tour:
            stats["gather_too_few_points"] += 1
            continue
        low = 1
        unknown = []
        if kind == "Skinning":
            what = ", ".join(n for n in nodes[:5])
            skill_note = "Tougher beasts need more Skinning; the corpse tooltip shows whether you can skin it."
            req = "Skinning;1"
        else:
            if fl == "retail":
                low, high = 1, None    # wiki: since patch 6.0.2 nodes are gatherable from skill 1 (low skill gets a lesser yield)
            else:
                # the lowest node a character can use here; a node with no number on its page takes its expansion's
                # lower bound, and the guide says so
                known = [node_skill.get(n) for n in nodes if node_skill.get(n) is not None]
                unknown = [n for n in nodes if node_skill.get(n) is None]
                floors = [SKILL_FLOOR.get(node_exp.get(n, 1), 1) for n in unknown]
                vals = known + floors
                low = min(vals) if vals else 1
                high = max(vals) if len(vals) > 1 else None
                if unknown:
                    # the wiki gives no number for these on this client: an expansion floor is a lower bound, not a fact to state
                    high = None
            # ties (nodes with the same or no skill number) go by name: a set's own order changes from run to run, and
            # with it the step's words (a quest-less step's saved mark is keyed by them)
            what = ", ".join(sorted(set(nodes), key=lambda n: (node_skill.get(n) or 0, n))[:6])
            if fl != "retail" and unknown:
                skill_note = f"The wiki gives no skill for some of these, so check each node's tooltip for what your {kind} can gather."
            else:
                skill_note = f"Needs {kind} {low}" + (f"; the higher-skill nodes here want {high}" if high and high != low else "") + "."
            req = f"{kind};{low}"
        fac = world.zone_faction(mid)
        name = f"{zone_name(world, mid)} {kind}{f' {low}+' if low > 1 else ''} circuit (coarse)"
        lines = []
        for i, (x, y) in enumerate(tour, 1):
            if i == 1:
                verb = "Kill and skin" if kind == "Skinning" else "Gather"
                note = (f"{verb} {what}. {skill_note} This ring walks the zone's real quest and NPC ground; "
                        f"it is coarse until you have farmed here (/cr farm build sharpens it from your own harvests).")
            elif i == 2:
                note = "Keep moving around the ring and take every node you pass; it repeats for as long as you want."
            else:
                note = ""
            lines.append(f"G {zone_name(world, mid)} {kind} {i}|M|{x:.2f},{y:.2f}|Z|{ztag(world, mid)}|RAD|60|"
                         + (f"N|{note}|" if note else ""))
        gid = f"gold:{fl}:gather:{mid}:{kind}"
        farm = {"map": mid, "kind": kind, "nodes": len(tour), "coarse": True}
        out.append(Guide(gid, name, "Gathering", mid, fac, lo, hi, req, lines, True, farm, "wiki:node-locations"))
        stats["gather_guides"] += 1
    return out


MOB_YIELD = {"Beast": "Skin them if you can and sell the leather; the meat and other trade goods go to the auction house or a vendor.",
             "Humanoid": "They drop cloth and coin; check every corpse, and keep the cloth for the auction house."}


RE_PROPER_NAME = re.compile(r"[A-Z][\w'-]+ the [A-Z][\w'-]+")  # "Vorsha the Lasher": one named creature, usually a quest spawn, not a farmable population


def mob_guides(world, fl, stats):
    """clusters of real mob locations, one circuit per zone and creature type, for the zone's level band"""
    per = collections.defaultdict(list)
    levels = world.levels
    for mid, mobs in world.mob_pts.items():
        m = world.ms.maps.get(mid)
        if not m or m["type"] != 3 or m["name"] in CAPITAL_NAMES:
            continue
        band = world.zone_band(m["name"], mid)
        if not band:
            continue
        zlo, zhi = band
        for mob, pts in mobs.items():
            facts = world.box.get(mob)
            if not facts or not is_killable(facts) or not on_client(facts, fl) or RE_PROPER_NAME.fullmatch(mob):
                continue
            kind = creature_kind(facts)
            if not kind:
                continue
            lv = level_info(facts, fl, zlo, zhi, levels)
            if not lv:
                stats["mob_no_level"] += 1
                continue
            per[(mid, kind, band)].append((mob, pts))
    out = []
    for (mid, kind, (lo, hi)), mobs in sorted(per.items()):
        zname = zone_name(world, mid)
        pts = []
        names = collections.Counter()
        for mob, ps in mobs:
            pts += ps
            names[mob] += len(ps)
        tour = build_tour(world, mid, pts, cell_frac=0.04, want=14, link_yards=800)
        if not tour:
            stats["mob_too_few_points"] += 1
            continue
        label = "Humanoids" if kind == "Humanoid" else "Beasts"
        top = [re.sub(r"\s*\(.*\)$", "", n) for n, _ in names.most_common(5)]
        fac = world.zone_faction(mid)
        name = f"Mob Farming {lo}-{hi}: {label} in {zname}"
        lines = []
        for i, (x, y) in enumerate(tour, 1):
            note = ""
            if i == 1:
                note = f"Kill {', '.join(top)} and anything else your level on the way round. {MOB_YIELD[kind]}"
            elif i == 2:
                note = "This is a loop: keep walking and pull what respawned behind you."
            lines.append(f"G {zname} {label} {i}|M|{x:.2f},{y:.2f}|Z|{ztag(world, mid)}|RAD|50|" + (f"N|{note}|" if note else ""))
        gid = f"gold:{fl}:mob:{mid}:{kind}"
        farm = {"map": mid, "kind": kind, "nodes": len(tour)}
        out.append(Guide(gid, name, "Mob Farming", mid, fac, lo, hi, None, lines, True, farm, "wiki:mob-locations"))
        stats["mob_guides"] += 1
    return out


FISH_SKILL_CAP = {"era": 300, "forever": 300, "tbc": 375, "mop": 600}   # the client's Fishing rank cap; wiki 'Fishing', rank table


def fishing_guides(world, fl, rows, stats):
    out = []
    seen = set()
    for zone, loc, skill, fish in rows:
        mid = world.zone_of(zone)
        if mid is None:
            stats["fish_zone_not_on_client"] += 1
            continue
        band = world.zone_band(zone_name(world, mid), mid)
        if not band:
            stats["fish_no_zone_level"] += 1
            continue
        lo, hi = band
        req_skill = None if fl == "retail" or not skill else skill
        # the wiki's 100% catch skill can sit above what this client's skill can reach: never list a guide as needing the impossible
        skill_cap = FISH_SKILL_CAP.get(fl)
        over_cap = bool(req_skill and skill_cap and req_skill > skill_cap)
        if over_cap:
            req_skill = skill_cap
        fishes = list(dict.fromkeys(fish))[:8]
        zname = zone_name(world, mid)
        name = f"Fishing: {zname}" + (f", {loc}" if loc and len(loc) <= 32 else "")
        if name in seen:
            continue
        seen.add(name)
        fac = world.zone_faction(mid)
        where = f"Fish at {loc}" if loc else "Fish any open water or pool in the zone"
        skill_text = (f"The wiki's 100% catch skill here is {skill}, above this client's cap of {skill_cap}: cast with a lure and expect some junk." if over_cap else
                      f"Skill {req_skill} or better keeps the catch from being mostly junk here." if req_skill else "Any fishing skill works; pools are the best casts.")
        lines = [
            f"R Travel to {zname}|Z|{ztag(world, mid)}|N|{'Bring a fishing pole. ' if lo < 30 else ''}{skill_text}|",
            f"N {where}|Z|{ztag(world, mid)}|N|Likely catches: {', '.join(fishes)}. Fish pools when you see them; they rarely give junk.|",
            f"N Sell or cook the catch|N|Fish that sells goes to the auction house; the rest is cooking practice or vendor money.|",
        ]
        gid = f"gold:{fl}:fish:{mid}:{len(out)}"
        out.append(Guide(gid, name, "Fishing", mid, fac, lo, hi, f"Fishing;{req_skill}" if req_skill else None, lines, False, None, "wiki:Fishing locations"))
        stats["fish_guides"] += 1
    return out


# ---------------------------------------------------------------------------------------------------------------
# Daily gold hubs
# ---------------------------------------------------------------------------------------------------------------
RE_MONEY = re.compile(r"\|\s*money\s*=\s*\{\{\s*(?:cost|coppercost)\s*\|([^}]*)\}\}", re.I)


def money_copper(args):
    parts = [p.strip() for p in args.split("|") if "=" not in p]
    nums = []
    for p in parts:
        p = p.replace(",", "")
        nums.append(int(p) if p.isdigit() else 0)
    nums += [0] * (3 - len(nums))
    return nums[0] * 10000 + nums[1] * 100 + nums[2]


RE_EVENT_PAGE = re.compile(r"\{\{\s*WorldEvent/\s*(?!Quel'Danas)|\{\{\s*level\s*\|\s*holiday", re.I)    # every WorldEvent page but the Shattered Sun dailies
RE_EVENT_CATEGORY = re.compile(r"love is in the air|lunar festival|noblegarden|children's week|midsummer|brewfest|hallow's end|"
                               r"pilgrim's bounty|feast of winter veil|winter veil|harvest festival|day of the dead|pirates' day|darkmoon", re.I)


def daily_guides(world, fl, stats):
    db = sqlite3.connect(f"file:{WIKIDB}?mode=ro", uri=True)
    raw = sqlite3.connect(f"file:{RAW}?mode=ro", uri=True)
    rows = db.execute("select q.id, q.name, q.level, q.levelreq, q.zone, q.faction, q.qtype, q.category, q.page_title "
                      "from quests q join flavor_quests f on f.quest_id=q.id and f.page_title=q.page_title "
                      "where f.flavor=? and q.qtype like 'Daily%'", (fl,)).fetchall()
    stats["daily_quests_on_client"] = len(rows)
    hubs = collections.defaultdict(list)
    for qid, name, level, req, zone, faction, qtype, category, page in rows:
        if re.search(r"meta|group|dungeon|raid|heroic|celestial|pvp", qtype or "", re.I) or re.search(r"remix|profession|cooking|fishing|archaeology", category or "", re.I):
            stats["daily_skip_type"] += 1
            continue
        if faction not in ("Alliance", "Horde", "Both", "Neutral", "", None):     # covenant or Aldor/Scryers choice: not generic
            stats["daily_skip_side_choice"] += 1
            continue
        r = raw.execute("select wikitext from pages where title=? limit 1", (page,)).fetchone()
        w = r[0] if r and r[0] else ""
        if RE_EVENT_PAGE.search(w) or RE_EVENT_CATEGORY.search(category or ""):     # a seasonal quest is not a daily you can run all year
            stats["daily_skip_event"] += 1
            continue
        m = RE_MONEY.search(w)
        if not m:
            stats["daily_no_money"] += 1
            continue
        copper = money_copper(m.group(1))
        if copper <= 0:
            stats["daily_no_money"] += 1
            continue
        lines = world.qlines.get(qid)
        if not lines or "A" not in lines:
            stats["daily_no_step"] += 1
            continue
        lv = req or level
        if not lv:
            stats["daily_no_level"] += 1
            continue
        lo = int(lv)
        if lo > world.cap:
            continue
        # wiki hub: the zone the giver's step uses
        a_title, a_tags, a_q = lines["A"]
        mz = re.match(r"(\d+)", a_tags.get("Z", ""))
        amid = int(mz.group(1)) if mz else None
        hubzone = amid
        mi = world.ms.maps.get(amid) if amid else None
        if mi and mi.get("type") == 4 and zone:
            # the point is an instance map: the page's boss/encounter location, not where the quest is given (Sun Tenderheart)
            qz = world.ms.resolve(zone)
            if qz and qz != amid and qz in world.ms.maps and world.ms.maps[qz].get("type") != 4:
                hubzone = qz
                a_tags = {k: v for k, v in a_tags.items() if k != "M"}
                a_tags["Z"] = ztag(world, qz)
                stats["daily_instance_point_dropped"] += 1
        if a_q:
            # the point came from another project's data; only the wiki's own zone name is usable
            hubzone = world.ms.resolve(zone) if zone else None
            stats["daily_giver_point_dropped"] += 1
        if hubzone is None or hubzone not in world.ms.maps:
            stats["daily_no_zone"] += 1
            continue
        fac = faction if faction in FACTIONS else None
        lband = (lo // 10) * 10
        hubs[(hubzone, lband, fac)].append((copper, qid, name, lo, a_title, a_tags, a_q, lines.get("T")))
    out = []
    for (mid, lband, fac), qs in sorted(hubs.items(), key=lambda kv: -sum(x[0] for x in kv[1])):
        if len(qs) < 2:
            stats["daily_lone_quest_hubs"] += 1
            continue
        qs.sort(key=lambda x: -x[0])
        if len(qs) > 25:
            stats["daily_cut_over_25"] += len(qs) - 25
            qs = qs[:25]
        zname = zone_name(world, mid)
        lo = min(x[3] for x in qs)
        hi = world.cap
        faction_label = f" ({fac})" if fac else ""
        name = f"Daily Gold: {zname} {lo}+{faction_label} ({len(qs)} dailies)"
        lines = []
        def dline(act, title, tags, qsource, qid, lvl, cls):
            keep = [f"QID|{qid}"]
            for t in ("PRE", "FACTION", "R", "C"):
                if tags.get(t):
                    keep.append(f"{t}|{tags[t]}")
            keep.append(f"LVL|{lvl}")
            if not qsource and tags.get("M"):
                keep.append(f"M|{tags['M']}")
            z = tags.get("Z", "")
            if qsource:
                z = ztag(world, mid)
            if z:
                keep.append(f"Z|{z}")
            n = re.sub(r"\s*\(location:[^)]*\)", "", tags.get("N", "")).strip()
            if n:
                keep.append(f"N|{n}")
            return f"{act} {title}|" + "|".join(keep) + "|"
        for copper, qid, qname, qlo, a_title, a_tags, a_q, t in qs:
            lines.append(dline("A", a_title, a_tags, a_q, qid, qlo, "A"))
            if t:
                t_title, t_tags, t_q = t
                lines.append(dline("T", t_title, t_tags, t_q, qid, qlo, "T"))
            else:
                stats["daily_no_turnin"] += 1
        gid = f"gold:{fl}:daily:{mid}:{lband}:{fac or 'Both'}"
        total = sum(x[0] for x in qs)
        out.append(Guide(gid, name, "Daily Gold", mid, fac, lo, hi, None, lines, False, None, f"wiki:Daily quests, money sum {total}c"))
        stats["daily_guides"] += 1
    return out


# ---------------------------------------------------------------------------------------------------------------
# Methods: short, original step-by-step guides per level band
# ---------------------------------------------------------------------------------------------------------------
CAP_CITIES = {  # wiki faction of the capitals that hold an Auction House, on every client that has the city
    "Alliance": ["Stormwind City", "Ironforge", "Darnassus", "The Exodar", "Shattrath City", "Shrine of Seven Stars"],
    "Horde": ["Orgrimmar", "Thunder Bluff", "Undercity", "Silvermoon City", "Shattrath City", "Shrine of Two Moons"],
}
PRE_CATA_SKIP_AREAS = ("Valley of Honor", "Goblin Slums", "Valley of Spirits", "Valley of Wisdom", "Dwarven District")


def npc_point(world, title):
    """first wiki coordinate of an NPC page placed on this client: (mid, x, y) or None"""
    db = world._db if hasattr(world, "_db") else sqlite3.connect(f"file:{WIKIDB}?mode=ro", uri=True)
    world._db = db
    rows = db.execute("select zone,x,y,classic from npc_coords where title=? and x is not null", (title,)).fetchall()
    rows += [(r[0], r[1], r[2], 0) for r in db.execute("select zone,x,y from npcs where title=? and x is not null", (title,)).fetchall()]
    if title in world.box and not on_client(world.box[title], world.fl):
        return None
    for zone, x, y, classic in rows:
        if classic and world.fl not in CLASSIC_LIKE:
            continue
        p = world.atlas.place(zone, x, y, world.fl, bool(classic))
        if p and 0 < p[1] < 100 and 0 < p[2] < 100:
            return p
    return None


def alt_str(points):
    out = []
    for mid, x, y, name in points:
        n = name.replace(";", " ").replace("|", "/").replace(",", " ")
        out.append(f"{mid},{x:.1f},{y:.1f},{n}")
    return ";".join(out)


def auction_houses(world, fl, locations, stats):
    """(alliance_alts, horde_alts, neutral_alts) as (mid, x, y, label)"""
    res = {"Alliance": [], "Horde": [], "Neutral": []}
    seen = set()
    for loc in locations:
        if loc["exp"] > EXPANSION[fl]:
            continue
        if fl in CLASSIC_LIKE and any(s in loc["area"] for s in PRE_CATA_SKIP_AREAS):
            continue
        # Shattrath and Dalaran auctioneers were added with Cataclysm: era/tbc clients skip those lines by exp above
        city = loc["city"]
        if not loc["aucs"]:
            continue
        pt = None
        for a in loc["aucs"]:
            pt = npc_point(world, a)
            if pt:
                break
        if not pt:
            stats["ah_no_coords"] += 1
            continue
        mid, x, y = pt
        if mid not in world.ms.maps:
            continue
        key = (loc["faction"], mid, round(x), round(y))
        if key in seen:
            continue
        seen.add(key)
        label = f"{city} Auction House"
        res[loc["faction"]].append((mid, x, y, label))
    return res


def banks(world, fl, stats):
    """(mid, x, y, label) per faction from the wiki's banker pages in capitals"""
    db = world._db if hasattr(world, "_db") else sqlite3.connect(f"file:{WIKIDB}?mode=ro", uri=True)
    world._db = db
    try:
        bankers = W.category("Category:Bankers")
    except Exception:
        bankers = []
    out = collections.defaultdict(list)
    seen = set()
    for t in bankers:
        p = npc_point(world, t)
        if not p:
            continue
        mid, x, y = p
        m = world.ms.maps.get(mid)
        if not m or m["name"] not in CAPITAL_NAMES:
            continue
        # era/tbc: the Dwarven District bank is post-Cataclysm; keep the Trade District and Commons branches
        if fl in CLASSIC_LIKE and m["name"] == "Stormwind City" and t in ("Ann Wainwright", "Jamie Crester", "Lee Crester", "Curtis Crester"):
            continue
        key = (mid, round(x / 3), round(y / 3))
        if key in seen:
            continue
        seen.add(key)
        fac = "Alliance" if m["name"] in CAP_CITIES["Alliance"] else "Horde" if m["name"] in CAP_CITIES["Horde"] else None
        if not fac:
            continue
        out[fac].append((mid, x, y, f"{m['name']} bank"))
    return out


def vendor_points(world, fl, faction, stats):
    """general-goods vendors and innkeepers placed on this client: (mid, x, y, label), spread over the world"""
    pts = []
    try:
        titles = list(dict.fromkeys(W.category("Category:General goods vendors") + W.category("Category:Innkeepers")))
    except Exception:
        titles = []
    db = world._db if hasattr(world, "_db") else sqlite3.connect(f"file:{WIKIDB}?mode=ro", uri=True)
    world._db = db
    for t in titles:
        p = npc_point(world, t)
        if not p:
            continue
        mid, x, y = p
        m = world.ms.maps.get(mid)
        if not m or m["type"] != 3:
            continue
        zf = world.zone_faction(mid)
        if zf and zf != faction:
            continue
        enemy = "Horde" if faction == "Alliance" else "Alliance"
        if m["name"] in CAP_CITIES[enemy]:
            continue
        pts.append((mid, x, y, f"{t} ({m['name']})"))
    # one per map, capped so the ALT list stays short and the engine prices few points
    best = {}
    for p in sorted(pts, key=lambda p: (p[0], p[3])):
        best.setdefault(p[0], p)
    out = list(best.values())
    out.sort(key=lambda p: (world.ms.maps[p[0]]["name"] not in CAPITAL_NAMES, p[0]))
    return out[:24]


def method_bands(cap):
    bands = [(1, 9)]
    lo = 10
    while lo <= cap:
        hi = min(lo + 9, cap)
        bands.append((lo, hi))
        lo = hi + 1
    return bands


def ah_listing_note(fl, short=False):
    """wiki 'Auction House': a realm's Houses are connected today; earlier versions had separate Alliance, Horde and Neutral Houses."""
    if fl == "retail":
        return "Pick the closest one; all of a realm's Auction Houses share listings." if short else \
            "Any auctioneer works; all the Auction Houses on a realm share the same listings."
    return "Pick the closest one in your faction's cities; those share listings, but the neutral Auction Houses are a separate market." if short else \
        "Any auctioneer in your faction's cities works; those Auction Houses share listings, but the neutral ones (Booty Bay, Gadgetzan, Everlook) are a separate market."


def step_ah(altstr, fl, title="Go to the Auction House", note=""):
    return f"R {title}|ALT|{altstr}|N|{note or ah_listing_note(fl)}|"


def step_bank(altstr, note):
    return f"R Visit the bank|ALT|{altstr}|N|{note}|"


def step_vendor(altstr, note):
    return f"R Sell your junk|ALT|{altstr}|N|{note}|"


def methods(world, fl, faction, ah, bank, vendor, stats):
    out = []
    neutrals = ah.get("Neutral", [])
    fah = ah.get(faction, [])
    ahs = fah + [p for p in neutrals]
    ah_alt = alt_str(ahs) if ahs else ""
    bank_alt = alt_str(bank.get(faction, [])) if bank.get(faction) else ""
    v_alt = alt_str(vendor) if vendor else ""

    def add(lo, hi, title, steps, band_label=None):
        name = f"Gold Methods {lo}-{hi}: {title} ({faction})"
        gid = f"gold:{fl}:methods:{faction}:{lo}-{hi}:{re.sub(r'[^a-z]', '', title.lower())[:24]}"
        out.append(Guide(gid, name, "Methods", None, faction, lo, hi, None, [s for s in steps if s], False, None, "original text; wiki:Guide to making money"))
        stats["methods_guides"] += 1

    def n(title, note):
        return f"N {title}|N|{note}|"

    bands = method_bands(world.cap)
    AH = step_ah(ah_alt, fl) if ah_alt else None
    VENDOR = step_vendor(v_alt, "Grey items have no other use; dump them on any vendor before your bags overflow.") if v_alt else None
    BANK = step_bank(bank_alt, "Stow profession materials you are saving and anything you want to sell later. Keep your bags empty for loot.") if bank_alt else None

    for lo, hi in bands:
        if hi <= 9:
            add(lo, hi, "Early habits", [
                n("Loot everything", "Open every corpse and chest on your path. Early on, grey junk and small coin drops are your whole income."),
                n("Do not buy upgrades yet", "Almost everything you could buy now gets replaced within a level or two. Save your coin for training."),
                VENDOR,
                n("Sell, do not destroy", "Before you throw anything away, right-click it on a vendor. Even cheap items pay for your next training."),
                n("Plan a gathering pair", "When a trainer offers them, take two gathering professions (see the Gathering guides). They pay as you go and cost little to start."),
            ])
        elif hi <= 19:
            add(lo, hi, "Reward choices and the vendor", [
                n("Pick quest rewards by value", "If no reward is an upgrade, take the one with the highest vendor price in its tooltip. Plate and big weapons often sell for the most."),
                VENDOR,
                n("Keep cloth and leather", "Do not vendor linen, wool or light leather: crafters buy them at the Auction House when they level their skills."),
                AH,
                n("Post in small stacks", "Materials move faster in modest stacks. Set a buyout on every auction; listings without one get ignored."),
                n("Stay in your gathering lane", "Take the lowest-level Gathering guide you qualify for and let your skill climb as you level."),
            ])
        elif hi <= 29:
            add(lo, hi, "Cloth, leather, and small profits", [
                n("Watch what the market buys", "Before you vendor anything green or a reagent, search it at the Auction House. Prices differ per realm, so look, do not assume."),
                AH,
                n("Skinning on the side", "If you skin, skin every beast you kill. It costs no extra travel, and leather is steady demand at this level."),
                n("Sort your bags by destination", "Keep three piles in your head: vendor, Auction House, keep for crafting. Decide once per loot pass and stop re-reading tooltips."),
                n("Save for riding", "A mount is your largest early cost. Skip optional gear so the money is there when you reach the level."),
            ])
        elif hi <= 39:
            add(lo, hi, "Enchanting materials and the Auction House", [
                n("Uncommon gear: sell or shard", "Green weapons and armor either go on the Auction House or, if you have Enchanting, get disenchanted. Compare the listings first."),
                AH,
                n("Learn undercutting", "A price just under the lowest listing sells faster than a price you hoped for, but do not undercut so far you lose money."),
                n("Use your cooldowns", "Profession cooldowns (a daily or weekly craft) cost little to run and are easy income if the product sells on your realm. Check what yours makes."),
                n("Travel light", "Bank what you are not selling this trip. A full bag ends a farming run early."),
                BANK,
            ])
        elif hi <= 49:
            add(lo, hi, "Reselling and cooldowns", [
                n("Convert materials when it pays", "Sometimes bars sell better than ore, or dust better than the item. Compare both prices at the Auction House before you convert or sell."),
                AH,
                n("Buy low, resell in patience", "If you spot an item listed far under its usual price, it may be worth buying and reposting. Only do this with items you already understand."),
                n("Cooldown crafts", "If you have a cooldown craft, run it every time it is ready and sell or use the result; it adds up over many days."),
                BANK,
            ])
        elif hi <= 59 or (fl in ("era", "forever") and hi == 60 and lo == 60):
            add(lo, hi, "Bank alt and steady farming" if not (fl in ("era", "forever") and lo == 60) else "At the cap", [
                n("Set up a bank alt", "Roll a character in a city and mail it what you sell. It keeps your main's bags clear and lets you run the Auction House from one place."),
                BANK,
                n("Sell in bulk runs", "Farm until your bags are full, then one trip to the Auction House. Short trips with half bags waste travel."),
                AH,
                n("Stop vendoring reagents", "At this level many drops are reagents that crafters pay well for. Search before you click sell."),
                n("Look at your gathering guides", "A high-level Gathering circuit for your skill is usually the steadiest income once you can hold the zone."),
            ])
        else:
            add(lo, hi, "Late game money", [
                n("Use your whole bank", "Materials you hoard do not pay. Sell what you are not crafting with this week."),
                BANK,
                n("Check prices on a schedule", "Prices drop and rise with patches and holidays. Check the same items at the same time of day so you can tell a real dip."),
                AH,
                n("Daily and weekly habits", "If this client has daily quests, the Daily Gold guides are a steady baseline that needs no market knowledge."),
                n("Mind what you buy", "Epic gear and consumables cost a lot. Buy only what changes what you can do, then get back to farming."),
            ])
    # any-level guides
    if ah_alt:
        add(1, world.cap, "Auction House Basics", [
            step_ah(ah_alt, fl, "Find an auctioneer", ah_listing_note(fl, short=True)),
            n("Search before you post", "Look up what you are selling and note the lowest buyouts. Price just under the cheapest listing, or match it if it is already fair."),
            n("Always set a buyout", "Many buyers only look at buyout prices. An auction without one is easy to skip."),
            n("Mind the deposit", "A listing costs a small deposit, lost if the auction fails. Do not spam items that will not sell."),
            n("Never gamble your rent", "Do not spend your training or repair money on speculation. Keep a reserve."),
        ])
        add(1, world.cap, "Flipping and patience", [
            step_ah(ah_alt, fl, "Check the market"),
            n("Learn a small niche", "Pick one kind of item (a herb, a cloth type, a recipe) and watch it for a few days before you buy anything to resell."),
            n("Buy under the usual price", "Only buy when you are confident it will resell higher after the fee. Your realm's normal price is the only one that matters."),
            n("Cut your losses", "If something does not sell after a few tries, vendor or use it. Do not relist forever."),
        ])
    if bank_alt:
        add(1, world.cap, "Set up a bank alt", [
            n("Create the alt", "Make a low-level character in a capital city. It only needs to stand next to a mailbox and the Auction House."),
            step_bank(bank_alt, "Stash the items the alt will sell. Mail moves goods between your characters for a small postage fee."),
            AH,
            n("Keep the main's bags clear", "Mail your main's sellable loot to the alt after each session, and list everything from one character."),
        ])
    return out


# ---------------------------------------------------------------------------------------------------------------
# Instance runs at or near the cap, retail and mists only (the wiki states the general fact; see docs/GOLD_ROUTES.md)
# ---------------------------------------------------------------------------------------------------------------
INSTANCE_SECTIONS = {"WORLD OF WARCRAFT": 1, "CLASSIC": 1, "THE BURNING CRUSADE": 2, "BURNING CRUSADE": 2, "WRATH OF THE LICH KING": 3, "CATACLYSM": 4,
                     "MISTS OF PANDARIA": 5, "WARLORDS OF DRAENOR": 6, "LEGION": 7, "BATTLE FOR AZEROTH": 8, "SHADOWLANDS": 9,
                     "DRAGONFLIGHT": 10, "WAR WITHIN": 11, "THE WAR WITHIN": 11, "MIDNIGHT": 12,
                     # Template:Level merges the oldest expansions into these two, and its levels are retail-scaled, so nothing in it splits them further
                     "PRE-CATACLYSM": 13, "CATACLYSM & PANDARIA": 14}
INSTANCE_LABEL = {1: "Classic", 2: "Burning Crusade", 3: "Wrath of the Lich King", 4: "Cataclysm", 5: "Mists of Pandaria", 6: "Warlords of Draenor",
                  7: "Legion", 8: "Battle for Azeroth", 9: "Shadowlands", 13: "Pre-Cataclysm", 14: "Cataclysm and Pandaria"}
# which expansions' instances count as "old content" on a client whose cap is well above them.  13 is not old on tbc: it holds that client's own dungeons too.
OLD_SECTIONS = {"tbc": (1,), "mop": (1, 2, 3, 13), "retail": (1, 2, 3, 4, 5, 6, 7, 8, 9, 13, 14)}
RE_INST_CO = re.compile(r"\{\{\s*co(?:ords)?\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*([^}|]+?)\s*(?:\|[^}]*)?\}\}", re.I)


def instance_table():
    """{instance key: expansion} from Template:Level's DUNGEONS block (section headers name the expansion)"""
    d = json.loads((CACHE / "template_level.json").read_text(encoding="utf-8"))
    t = d["query"]["pages"][0]["revisions"][0]["slots"]["main"]["content"]
    i = t.find("\nDUNGEONS\n")
    out, exp = {}, None
    for ln in t[i:].split("\n"):
        head = ln.strip()
        if head in INSTANCE_SECTIONS:
            exp = INSTANCE_SECTIONS[head]
            continue
        if head and head == head.upper() and "-->" not in head:     # an unknown section must not inherit the one above it
            exp = None
            continue
        if "+" in ln.split("=")[0]:
            continue
        m = re.search(r"-->\|([^=<]+)=(\d+)(?:-(\d+))?<!--", ln)
        if not m or exp is None:
            continue
        for k in m.group(1).split("|"):
            k = k.strip()
            if k and not k.endswith(" min"):
                out.setdefault(k, exp)
    return out


def entrance_from_wiki(world, name):
    """the instance page's own {{coords}} on an outdoor map of this client: (mid, x, y) or None"""
    for title in (name, f"{name} (instance)", f"The {name}"):
        page = W.page(title)
        if not page:
            continue
        for m in RE_INST_CO.finditer(page[:9000]):
            p = world.atlas.place(m.group(3), float(m.group(1)), float(m.group(2)), world.fl, world.fl in CLASSIC_LIKE)
            if p and world.ms.maps[p[0]]["type"] == 3 and 0 < p[1] < 100 and 0 < p[2] < 100:
                return p
    return None


def instance_guides(world, fl, table, stats):
    """Old instances at or near the cap.  The wiki's general statement: "with appropriate gear and experience" older instances can be soloed.
    It names no per-instance list, so these are the old-expansion instances this client has, skipping any whose page gives no entrance."""
    if fl not in OLD_SECTIONS:
        stats["instances_skipped_no_older_content"] = 1
        return []
    per = collections.defaultdict(list)
    for key, exp in table.items():
        if exp not in OLD_SECTIONS[fl]:
            continue
        mid = world.ms.resolve(key)
        if mid is None or world.ms.maps[mid]["type"] not in (4, 5):
            continue
        per[exp].append((world.ms.maps[mid]["name"], mid))
    cap = world.cap
    out = []
    for exp, items in sorted(per.items()):
        lines = ["N Check your character|N|This route assumes a character at or near the level cap. With enough gear older instances can be cleared alone; if a boss needs a group, skip it.|"]
        used = 0
        for name, mid in sorted(set(items)):
            if used >= 12:
                break
            door = entrance_from_wiki(world, name)
            if not door:
                stats["instance_no_entrance_on_wiki"] += 1
                continue
            dm, x, y = door
            lines.append(f"R {name} entrance|M|{x:.1f},{y:.1f}|Z|{ztag(world, dm)}|")
            lines.append(f"D {name}|Z|{mid}; {name}|N|Clear it and loot everything. Vendor the junk, post or disenchant the gear, and take recipes and reagents to the Auction House.|")
            used += 1
        if used < 2:
            stats["instance_groups_too_small"] += 1
            continue
        lines.append("N Sell the haul|N|Vendor the junk and post the rest. When an instance stops resetting for you, go on to the next one.|")
        minl = max(cap - 10, 1)
        label = INSTANCE_LABEL[exp]
        gid = f"gold:{fl}:inst:{exp}"
        out.append(Guide(gid, f"Instance Runs: old {label} content ({minl}-{cap})", "Instances", None, None, minl, cap, None, lines, False, None,
                         "wiki:Guide to making money + instance pages"))
        stats["instance_guides"] += 1
    return out


# ---------------------------------------------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------------------------------------------
def write_guides(fl, guides):
    GUIDES.mkdir(parents=True, exist_ok=True)
    head = (f"-- Completionist's Guide :: Imported_Gold_{fl}.lua - GENERATED {TODAY} by tools/wiki/gen_gold.py\n"
            + ATTRIB + "\nlocal _, NS = ...\n"
            + ('if not NS.isForever then return end\n' if fl == "forever" else f'if NS.flavor ~= "{fl}" or NS.isForever then return end\n')
            + "local R = NS.Guide.Register\n\n")
    with (GUIDES / f"Imported_Gold_{fl}.lua").open("w", encoding="utf-8") as f:
        f.write(head)
        for g in guides:
            f.write(lua_guide(g))


def write_sql(rows):
    VERIF.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(VERIF)
    db.execute("create table if not exists gold_guides(flavor text, id text primary key, name text, kind text, band text, "
               "zone text, faction text, steps int, loop int, requires text, source text)")
    db.execute("delete from gold_guides where flavor in (%s)" % ",".join("?" * len({r[0] for r in rows})), tuple({r[0] for r in rows}))
    db.executemany("insert or replace into gold_guides values (?,?,?,?,?,?,?,?,?,?,?)", rows)
    db.commit()
    db.close()


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    flavors = args or FLAVORS
    atlas = wikimaps.Atlas()
    levels = ZoneLevels()
    box = npcbox_facts()
    log(f"npc facts: {len(box)}")
    herb_zones, herb_skill, herb_exp = herb_data()
    log(f"herbs: {len(herb_skill)} node skills, {len(herb_zones)} zones")
    ore_zones, ore_skill, ore_exp = mining_data()
    log(f"mining: {len(ore_skill)} nodes, {len(ore_zones)} zones")
    fishing = fishing_data()
    log(f"fishing rows: {len(fishing)}")
    ah_locs = ah_locations()
    log(f"auction house lines: {len(ah_locs)}")
    inst_tab = instance_table()
    log(f"instance level rows: {len(inst_tab)}")
    sql_rows = []
    for fl in flavors:
        log(f"--- {fl} ---")
        world = World(fl, atlas, levels, box)
        stats = collections.Counter()
        stats["_seen"] = set()
        # beast zones: wiki Npcbox creature=Beast with a location on this client
        beast_zones = collections.defaultdict(list)
        for mid, mobs in world.mob_pts.items():
            m = world.ms.maps.get(mid)
            if not m or m["type"] != 3 or m["name"] in CAPITAL_NAMES:
                continue
            for mob, pts in mobs.items():
                facts = box.get(mob)
                if facts and is_killable(facts) and creature_kind(facts) == "Beast":
                    beast_zones[m["name"]].append(mob)
        beast_zones = {z: sorted(set(v)) for z, v in beast_zones.items() if len(set(v)) >= 3}
        guides = []
        guides += gather_guides(world, fl, "Herbalism", herb_zones, herb_skill, herb_exp, None, stats)
        guides += gather_guides(world, fl, "Mining", ore_zones, ore_skill, ore_exp, None, stats)
        guides += gather_guides(world, fl, "Skinning", None, None, None, beast_zones, stats)
        guides += mob_guides(world, fl, stats)
        guides += fishing_guides(world, fl, fishing, stats)
        guides += daily_guides(world, fl, stats)
        ahs = auction_houses(world, fl, ah_locs, stats)
        bks = banks(world, fl, stats)
        log(f"  AH alts: { {k: [p[3] for p in v] for k, v in ahs.items()} } banks: { {k: len(v) for k, v in bks.items()} }")
        for fac in FACTIONS:
            vendor = vendor_points(world, fl, fac, stats)
            stats[f"vendor_alts_{fac}"] = len(vendor)
            guides += methods(world, fl, fac, ahs, bks, vendor, stats)
        guides += instance_guides(world, fl, inst_tab, stats)
        seen = set()
        uniq = []
        for g in guides:
            if g.name in seen:
                g.name = f"{g.name} [{g.zone or g.id.rsplit(':', 1)[-1]}]"
            seen.add(g.name)
            uniq.append(g)
        write_guides(fl, uniq)
        for g in uniq:
            zone = zone_name(world, g.zone) if g.zone else ""
            sql_rows.append((fl, g.id, g.name, g.kind, g.band, zone, g.faction or "", len(g.lines), 1 if g.loop else 0, g.req or "", g.source))
        s = {k: v for k, v in stats.items() if k != "_seen"}
        by_kind = collections.Counter(g.kind for g in uniq)
        log(f"{fl}: {len(uniq)} guides {dict(by_kind)} stats {s} questie-tagged points skipped: {world.skipped_questie}")
    write_sql(sql_rows)
    log("done")


if __name__ == "__main__":
    main()
