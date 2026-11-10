#!/usr/bin/env python3
# CompletionRoute :: tools/wiki/gen_professions.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Secondary profession guides (Cooking, Fishing, First Aid, Archaeology) -> Guides/Imported_Professions_<fl>.lua

    /path/to/heavy.sh python3 tools/wiki/gen_professions.py [era tbc mop retail forever]

Sources and rules: docs/PROFESSIONS.md.  Warcraft Wiki is the source of truth; the client tables (db2_fetch) decide
which recipes exist on which client, their yellow/grey thresholds and their reagents.  Nothing is invented: a fact
that is missing is omitted and counted in docs/verification.sqlite table prof_guides.
"""
import csv, datetime, json, math, re, sqlite3, sys
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import db2_fetch as D  # noqa: E402
import wiki_fetch as W  # noqa: E402
import wikimaps  # noqa: E402
import wikitext as WT  # noqa: E402

GUIDES = ROOT / "CompletionRoute" / "Guides"
VERIFY = ROOT / "docs" / "verification.sqlite"
FLAVORS = ("era", "tbc", "mop", "retail", "forever")
CLASSICISH = ("era", "tbc", "forever")
EXPANSION = {"era": 1, "tbc": 2, "mop": 5, "retail": 99, "forever": 1}
# first patch line this client does NOT contain
PATCH_LIMIT = {"era": (2, 0, 0), "tbc": (3, 0, 0), "mop": (6, 0, 0), "retail": (99, 0, 0), "forever": (2, 0, 0)}
BADGES = {"wow": 1, "bc": 2, "tbc": 2, "wotlk": 3, "cata": 4, "mop": 5, "wod": 6, "legion": 7, "bfa": 8, "sl": 9, "df": 10,
          "tww": 11, "mn": 12}
PROFS = {"era": ("Cooking", "Fishing", "First Aid"), "tbc": ("Cooking", "Fishing", "First Aid"),
         "forever": ("Cooking", "Fishing", "First Aid"), "mop": ("Cooking", "Fishing", "First Aid", "Archaeology"),
         "retail": ("Cooking", "Fishing", "Archaeology")}
SKILL_LINE = {"Cooking": "185", "Fishing": "356", "First Aid": "129", "Archaeology": "794"}
TRAINER_PAGE = {p: p + " trainers" for p in SKILL_LINE}
RANK_NAMES = ["Apprentice", "Journeyman", "Expert", "Artisan", "Master", "Grand Master", "Illustrious Grand Master", "Zen Master"]
# Same ids as Core/Professions.lua RANKS (DB2 SpellName).
RANK_SPELLS = {"Cooking": [2550, 3102, 3413, 18260, 33359, 51296, 88053, 104381],
               "Fishing": [7620, 7731, 7732, 18248, 33095, 51294, 88868, 110410],
               "First Aid": [3273, 3274, 7924, 10846, 27028, 45542, 74559, 110406],
               "Archaeology": [78670, 88961, 89718, 89719, 89720, 89721, 89722, 110393]}
RANK_COUNT = {"era": 4, "tbc": 5, "mop": 8, "forever": 4}
# Warcraft Wiki 'Cooking' and 'Fishing' proficiency tables (skill range per expansion, read 2026-11-09).
# key: name prefix of the retail SkillLine child.  A band the recipes cannot reach is cut short and counted.
TIER_CAP = {"Cooking": {"Classic": 300, "Outland": 75, "Northrend": 75, "Cataclysm": 75, "Pandaria": 75, "Draenor": 100, "Legion": 100,
                        "Kul Tiran": 175, "Shadowlands": 175, "Dragon Isles": 100, "Khaz Algar": 100, "Midnight": 100},
            "Fishing": {"Classic": 300, "Outland": 75, "Northrend": 75, "Cataclysm": 75, "Pandaria": 75, "Draenor": 100, "Legion": 100,
                        "Kul Tiran": 175, "Shadowlands": 150, "Dragon Isles": 100, "Khaz Algar": 300, "Midnight": 300}}
# Wiki 'Fishing' skill table: where each expansion's skill is raised.  Trainer tables use the landmass headings.
TIER_LAND = {"Classic": ("Eastern Kingdoms", "Kalimdor"), "Outland": ("Outland",), "Northrend": ("Northrend",), "Cataclysm": (),
             "Pandaria": ("Pandaria",), "Draenor": ("Draenor",), "Legion": ("Broken Isles",), "Kul Tiran": ("Kul Tiras", "Zandalar"),
             "Shadowlands": ("Shadowlands",), "Dragon Isles": ("Dragon Isles",), "Khaz Algar": (), "Midnight": ()}
TIER_WATER = {"Outland": ["Outland"], "Northrend": ["Northrend"], "Cataclysm": ["Mount Hyjal", "Twilight Highlands", "Uldum", "Deepholm"],
              "Pandaria": ["Pandaria"], "Draenor": ["Draenor"], "Legion": ["Broken Isles"], "Kul Tiran": ["Kul Tiras", "Zandalar"],
              "Shadowlands": ["The Shadowlands", "Shadowlands"], "Dragon Isles": ["Dragon Isles"], "Khaz Algar": ["Khaz Algar"],
              "Midnight": ["Eversong Woods", "Zul'Aman", "Harandar", "Voidspire"]}
# Rank gates on clients older than patch 3.1.0 (wiki pages of each book; the quests are checked against QuestV2).
BOOKS = {("Cooking", 3): "Expert Cookbook", ("Cooking", 5): "Master Cookbook", ("Fishing", 3): "Expert Fishing - The Bass and You",
         ("Fishing", 5): "Master Fishing - The Art of Angling", ("First Aid", 3): "Expert First Aid - Under Wraps",
         ("First Aid", 5): "Master First Aid - Doctor in the House"}
QUESTS = {("Cooking", 4): {"Alliance": [6610], "Horde": [6610]}, ("Fishing", 4): {"Alliance": [6607], "Horde": [6607]},
          ("First Aid", 4): {"Alliance": [6625, 6624], "Horde": [6623, 6622]}}
# Zones a faction's new character would not be sent to for a fishing band (hostile home territory).
ALLIANCE_ZONES = {"Elwynn Forest", "Dun Morogh", "Teldrassil", "Azuremyst Isle", "Bloodmyst Isle", "Stormwind City", "Ironforge", "Darnassus",
                  "Westfall", "Redridge Mountains", "Loch Modan", "Darkshore", "Wetlands", "The Exodar"}
HORDE_ZONES = {"Durotar", "Mulgore", "Tirisfal Glades", "Eversong Woods", "Ghostlands", "Silverpine Forest", "Undercity", "Orgrimmar",
               "Thunder Bluff", "The Barrens", "Northern Barrens", "Silvermoon City"}
SEASONAL = re.compile(r"winter veil|hallow'?s end|brewfest|day of the dead|pilgrim|midsummer|lunar festival|love is in the air|noblegarden|"
                      r"darkmoon|children's week", re.I)
VENDOR = re.compile(r"sold by|vendors?\b|merchant|supplier|purchased|can be bought", re.I)
RANK_LIMIT = re.compile(r"teaches only up to\s*\{\{quality\|common\|journeyman", re.I)
SPECIAL_TRAINER = re.compile(r"available only to starting|only available during|appears at .{0,60}during|teaches the \[\[way|teaches \[\[|teaches 3 recipes", re.I)
LATER_PAGE = re.compile(r"no longer (offers|teaches|trains)", re.I)
MOVED = re.compile(r"before the \[*cataclysm|prior to .{0,40}cataclysm", re.I)
ADDED = re.compile(r"\{\{\s*patch (\d+)\.(\d+)(?:\.(\d+))?[a-z]?\s*\|\s*(?:added\s*=|note\s*=\s*added)", re.I)
TODAY = datetime.date.today().isoformat()


def clean(s):
    return re.sub(r"\s+", " ", (s or "").replace("|", "/").replace("]==]", "")).strip()


def fetch_pages(titles):
    """{title as asked: wikitext}.  50 titles per request, through the shared polite cached client."""
    titles = sorted({t for t in titles if t})
    out = {}
    for i in range(0, len(titles), 50):
        chunk = titles[i:i + 50]
        d = W.api(action="query", prop="revisions|categories", rvprop="content", rvslots="main", redirects=1, cllimit="max",
                  titles="|".join(chunk))
        q = d.get("query", {})
        back = defaultdict(list)
        for t in chunk:
            back[t].append(t)
        for key in ("normalized", "redirects"):
            for r in q.get(key, []):
                back[r["to"]] += back.get(r["from"], [])
        for p in q.get("pages", []):
            if p.get("missing") or not p.get("revisions"):
                continue
            body = p["revisions"][0]["slots"]["main"]["content"]
            cats = " ".join(c["title"] for c in p.get("categories", []))
            for t in back.get(p["title"], []):
                out[t] = (body, cats)
    return out


def num(s):
    m = re.search(r"\d+", s or "")
    return int(m.group(0)) if m else None


def patch_after(text, limit):
    for a, b, c, in [(m.group(1), m.group(2), m.group(3)) for m in ADDED.finditer(text or "")]:
        if (int(a), int(b), int(c or 0)) >= limit:
            return True
    return False


# ---------------------------------------------------------------------------
# Trainers
# ---------------------------------------------------------------------------
def parse_trainers(prof):
    text = W.page(TRAINER_PAGE[prof])
    m = re.search(r"<onlyinclude>(.*?)</onlyinclude>", text, re.S)
    out, land, land_exp = [], "", 1
    for row in re.split(r"\n\|-", m.group(1) if m else text):
        h = re.search(r"^\s*!\s*(?:rowspan=\"?\d+\"?\s*\|)?\s*(.*)$", row, re.M)
        if h and "rowspan" in row:
            head = h.group(1)
            ln = WT.links(head)
            au = re.search(r"\{\{\s*au\s*\|([^}|]+)", head, re.I)
            land = ln[0][0] if ln else (au.group(1).strip() if au else WT.plain(head))
            b = re.search(r"\{\{\s*(\w+)-inline", head, re.I)
            land_exp = BADGES.get(b.group(1).lower(), 1) if b else 1
        t = re.search(r"\{\{\s*npc\s*\|([^|{}]*)\|([^|{}]+)(?:\|\|([^|{}]+))?", row, re.I)
        if not t:
            continue
        badge = re.search(r"\{\{\s*npc[^{}]*\}\}\s*\{\{\s*(\w+)-inline", row, re.I)
        pts = [(x, y, z) for x, y, z, _, _ in WT.coords(row)]
        out.append(dict(prof=prof, land=land, faction=t.group(1).strip() or "Neutral", page=t.group(2).strip(),
                        name=(t.group(3) or t.group(2)).strip(), exp=max(land_exp, BADGES.get(badge.group(1).lower(), 1) if badge else 1),
                        pts=pts, row=row, limit=2 if RANK_LIMIT.search(row) else 99, special=bool(SPECIAL_TRAINER.search(row))))
    return out


class Gen:
    def __init__(self):
        self.atlas = wikimaps.Atlas()
        self.db = sqlite3.connect(str(HERE / "wiki.sqlite"))
        self.npc_pts = defaultdict(list)
        for r in self.db.execute("select title, zone, x, y, source, badge, classic from npc_coords order by title, idx"):
            self.npc_pts[r[0]].append(r[1:])
        self.quest = {}
        for r in self.db.execute("select id, name, faction, start_json, end_json, page_title from quests"):
            self.quest[r[0]] = r
        self.objectives = defaultdict(list)
        for r in self.db.execute("select quest_id, idx, kind, target_title, count, text from quest_objectives order by quest_id, idx"):
            self.objectives[r[0]].append(r[1:])
        self.trainers = {p: parse_trainers(p) for p in SKILL_LINE}
        names = {t["page"] for rows in self.trainers.values() for t in rows}
        self.npc_page = fetch_pages(names)

    # -- points ------------------------------------------------------------------------------------------------------
    def place(self, zone, x, y, fl):
        r = self.atlas.place(zone, x, y, fl, False, None)
        if not r:
            return None
        return r[0], round(r[1], 1), round(r[2], 1)

    def classic_point(self, name, fl):
        """a coordinate the wiki wrote for a Classic-era client, if it has one"""
        for zone, x, y, _src, badge, classic in self.npc_pts.get(name, []):
            if classic or badge == 1 or (fl == "tbc" and badge == 2):
                r = self.atlas.place(zone, x, y, fl, bool(classic), None)
                if r:
                    return r[0], round(r[1], 1), round(r[2], 1)
        return None

    def npc_point(self, name, fl):
        if fl in CLASSICISH:
            c = self.classic_point(name, fl)
            if c:
                return c
        for zone, x, y, *_ in self.npc_pts.get(name, []):
            r = self.place(zone, x, y, fl)
            if r:
                return r
        for rows in self.trainers.values():       # Dirge Quikcleave and others are only located in a trainer table
            for t in rows:
                if name in (t["page"], t["name"]):
                    for x, y, z in t["pts"]:
                        r = self.place(z, x, y, fl)
                        if r:
                            return r
        return None

    def usable_trainers(self, prof, fl, stats):
        out = []
        for t in self.trainers[prof]:
            if t["exp"] > EXPANSION[fl]:
                continue
            if t["special"]:
                stats["trainer_special"] += 1
                continue
            page = self.npc_page.get(t["page"], ("", ""))[0]
            if LATER_PAGE.search(page) or (page and patch_after(page, PATCH_LIMIT[fl])):
                stats["trainer_version"] += 1
                continue
            classic = self.classic_point(t["page"], fl) if fl in CLASSICISH else None
            if fl in CLASSICISH and MOVED.search(page) and not classic:
                stats["trainer_moved"] += 1
                continue
            placed = []
            for x, y, z in t["pts"]:
                r = self.place(z, x, y, fl)
                if r:
                    placed.append(r)
            if classic:
                far = [p for p in placed if p[0] == classic[0] and (self.atlas.yards(fl, p[0], p[1:], classic[1:]) or 0) > 300]
                if far or not placed:
                    stats["trainer_300yd"] += 1
                placed = [classic]
            if not placed:
                stats["trainer_no_point"] += 1
                continue
            out.append(dict(t, placed=placed))
        return out

    @staticmethod
    def alt(trainers, faction, rank=1):
        seen, parts = set(), []
        for t in trainers:
            if t["faction"] not in (faction, "Neutral") or rank > t["limit"]:
                continue
            for m, x, y in t["placed"]:
                k = (m, x, y)
                if k in seen:
                    continue
                seen.add(k)
                parts.append("%d,%.1f,%.1f,%s" % (m, x, y, clean(t["name"]).replace(";", ",")))
        return ";".join(parts), len(parts)


# ---------------------------------------------------------------------------
# Recipes
# ---------------------------------------------------------------------------
def spell_names(fl):
    return {r["ID"]: r.get("Name_lang", "") for r in D.rows(fl, "SpellName")}


RECIPE_PREFIX = ("Recipe: ", "Manual: ", "Formula: ")
RECIPE_ITEMS = {}       # [flavor][item name] = item id: the recipe items this client really has


def item_names(fl, ids):
    """{id: name} for `ids`, and fills RECIPE_ITEMS[fl].  Streams the table so only the rows wanted stay in memory."""
    want, out, recipes = set(str(i) for i in ids), {}, {}
    p = D.fetch(fl, "ItemSparse")
    if not p:
        return out
    with open(p, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            name = r.get("Display_lang", "")
            if r["ID"] in want:
                out[int(r["ID"])] = name
            if name.startswith(RECIPE_PREFIX):
                recipes[name] = int(r["ID"])
    RECIPE_ITEMS[fl] = recipes
    return out


def reagents_of(fl):
    out = defaultdict(list)
    for r in D.rows(fl, "SpellReagents"):
        for i in range(8):
            item, n = r.get("Reagent_%d" % i, "0"), r.get("ReagentCount_%d" % i, "0")
            if item not in ("0", "") and n not in ("0", ""):
                out[r["SpellID"]].append((int(item), int(n)))
    return out


def parse_box(body):
    for _s, _e, _nm, inner in WT.find_templates(body, re.compile(r"#data:(#\w+|ProfessionBox)", re.I)):
        pos, named = WT.split_params(inner)
        if any(k in named for k in ("orange", "learncost", "learnitem", "yellow")):
            return named
    return None


LEAD_TAUGHT = re.compile(r"(?:created|made|crafted)\s+(?:with|by|using)\b[^.\n]{0,120}?\((\d+)\)[^.\n]{0,10}?\b(?:taught by|learned from)\s+([^.\n]+)", re.I)
ANY_TAUGHT = re.compile(r"\b(?:taught by|learned from)\s+([^.\n]{1,160})", re.I)
RECIPE_LINK = re.compile(r"\[\[((?:Recipe|Manual|Formula)[^\]|]*)")


def lead_source(body):
    """(learn skill or None, kind, source) from the sentence most recipe pages open with:
    "X is created with [[Cooking]] (285); taught by [[Recipe: X]]." or "...taught by trainers."  None when no such sentence."""
    m = LEAD_TAUGHT.search(body)
    if m:
        learn, text = int(m.group(1)), m.group(2)
    else:
        m = ANY_TAUGHT.search(body)
        if not m:
            return None
        learn, text = None, m.group(1)
    item = RECIPE_LINK.search(text)
    if item:
        return learn, "item", item.group(1).strip()
    if re.search(r"\btrainers?\b", text, re.I):
        return learn, "trainer", ""
    return learn, "listed", clean(WT.plain(text))[:150]


def parse_lists():
    """the wiki's per-rank recipe lists: {recipe: (learn, source text)}"""
    out = {}
    for t in ("List of Apprentice Cooking Recipes", "List of Journeyman Cooking Recipes", "List of Expert Cooking Recipes",
              "List of Artisan Cooking Recipes"):
        for line in W.page(t).splitlines():
            m = re.match(r"\|(.*?)\|\|.*?\|\|.*?\|\|.*?\|\|\s*(?:\[\[File:[^\]]*\]\]\s*)?\[\[([^\]|]+)[^\]]*\]\]\s*\|\|(.*)$", line)
            if m:
                out.setdefault(m.group(2).strip(), (num(re.sub(r"<[^>]+>", "", m.group(1))) or 1, m.group(3)))
    return out


def parse_first_aid():
    """'First Aid recipes': {recipe: (learn, source text)}"""
    out = {}
    text = W.page("First Aid recipes")
    for row in re.split(r"\n\|-", text):
        cells = [c.strip() for c in re.split(r"\n\|", "\n" + row.strip()) if c.strip()]
        if len(cells) < 7:
            continue
        ln = WT.links(cells[0])
        learn = num(re.sub(r"style=\"[^\"]*\"\s*\|", "", cells[2]))
        if ln and learn is not None:
            out.setdefault(ln[0][0], (learn, cells[6]))
    return out


STALE_SENTENCE = re.compile(r"prior to|kosh'harg|during the|formerly|previously|no longer|used to|removed", re.I)
SOURCE_WORD = re.compile(r"\b(sold by|drops? from|dropped by|drops|reward|taught|contained|fished|found|gathered|sliced|looted|created|purchased|vendors?)\b", re.I)


def source_sentence(body):
    """the sentence that says where something comes from today.  Historic and festival-only sentences are skipped, and a
    money figure is dropped because the page's {{cost}} template does not survive as text."""
    if not body:
        return ""
    # {{NPC|faction|Name|Title}}: WT.plain keeps the last value, which is the title
    body = re.sub(r"\{\{\s*npc\s*\|[^|{}]*\|([^|{}]+)[^{}]*\}\}", r"\1", body, flags=re.I)
    sec = WT.sections(body)
    txt = (WT.plain(sec.get("source") or "") or WT.plain(sec.get("") or "")).replace("__NOTOC__", " ")
    sentences = [x.strip() for x in re.split(r"(?<=[.!?])\s+|\s\*", txt) if x.strip()]
    usable = [x for x in sentences if SOURCE_WORD.search(x) and not STALE_SENTENCE.search(x)]
    # a sentence introducing a list ("sold by the following vendors:") means little alone, and "also" is not the main source
    usable.sort(key=lambda x: (x.endswith(":"), bool(re.match(r"(it|they)\s+(is|are|can)?\s*also\b", x, re.I))))
    general = [x for x in usable if re.search(r"sold by|vendors|suppliers|merchants|drops from|dropped by", x, re.I)]
    pick = (general or usable or [""])[0].rstrip(":").strip()
    if not re.search(r"(sold by|vendors|suppliers|merchants|drops? from|dropped by)", (usable or [""])[0], re.I):
        pick = (usable or [""])[0].rstrip(":").strip() or pick
    pick = re.sub(r"\s+for\s+\d+(?=[\s.,:]|$)", "", pick)
    pick = re.sub(r"\s+(?:for|with)(?:\s+\d+)?\s+from\b", " from", pick)    # a stripped {{cost}}
    pick = re.sub(r"\s+(?:from|by)\s*\.?$", "", pick)                         # a stripped {{NPC}} at the end
    pick = re.sub(r"^(In|During)\s+(and\s+)?,\s*", "", pick)     # "In {{wow}} and {{bc}}, ..." after the templates are gone
    pick = pick[:1].upper() + pick[1:]
    return clean(pick)[:150]


MAX_ORANGE_BAND = 80     # the widest learn-to-yellow gap in the wiki's single-track recipe lists is about 65


class Recipe:
    __slots__ = ("spell", "name", "learn", "yellow", "grey", "auto", "kind", "source", "reagents", "item", "weight")


def build_recipes(fl, prof, tier, names, sla, reag, lists, fa, boxes, faction, stats):
    out = []
    for r in sla:
        grey, yellow = int(r["TrivialSkillLineRankHigh"]), int(r["TrivialSkillLineRankLow"])
        if r["SkillLine"] != SKILL_LINE[prof] or grey == 0:
            continue
        if tier and r.get("SkillupSkillLineID") != str(tier):
            continue
        name = names.get(r["Spell"]) or ""
        if re.search(r"campfire|cooking fire", name, re.I):     # the fire itself, not a dish
            continue
        body, cats = boxes.get(name, ("", ""))
        box = parse_box(body) if body else None
        learn, kind, source = None, None, ""
        if prof == "First Aid" and name in fa:
            learn, src = fa[name]
            kind = "trainer" if re.search(r"\btrainer\b", src, re.I) else "item"
            source = clean(WT.plain(src))
        elif box:
            learn = num(box.get("orange"))
            if box.get("learncost") is not None:
                kind = "trainer"
            elif box.get("learnitem"):
                kind, source = "item", box["learnitem"].strip()
        if kind is None and body:
            lead = lead_source(body)
            if lead:
                learn = learn if learn is not None else lead[0]
                kind, source = lead[1], lead[2]
        if kind is None and name in lists:
            lv, src = lists[name]
            learn = learn if learn is not None else lv
            kind = "trainer" if re.match(r"\s*(\{\{[^}]*\}\}\s*)?trainer", src, re.I) else "listed"
            source = clean(WT.plain(src))
        if fl in CLASSICISH and kind == "trainer":
            for prefix in RECIPE_PREFIX:
                if prefix + name in RECIPE_ITEMS.get(fl, {}):
                    kind, source = "item", prefix + name
                    stats["recipe_item_on_classic"] += 1
                    break
        auto = r["AcquireMethod"] == "1"
        if auto:
            kind = "auto"
        if kind is None:
            stats["recipe_no_source"] += 1
            continue
        if SEASONAL.search(source) or (body and SEASONAL.search(body[:400]) and kind != "trainer"):
            stats["recipe_seasonal"] += 1
            continue
        if ("Alliance-only" in cats and faction == "Horde") or ("Horde-only" in cats and faction == "Alliance"):
            stats["recipe_other_faction"] += 1
            continue
        db_min = int(r["MinSkillLineRank"])
        rc = Recipe()
        rc.spell, rc.name, rc.yellow, rc.grey, rc.auto, rc.kind, rc.source = int(r["Spell"]), name, yellow or grey, grey, auto, kind, source
        # both sources give a floor: the later of the two can never make the plan use a recipe too early.  With no learn
        # value from the wiki the yellow threshold is the safe floor: a recipe is always learned at or below its yellow.
        if learn is None:
            stats["recipe_learn_unknown"] += 1
            learn = rc.yellow
        elif learn > rc.yellow or (fl != "retail" and rc.yellow - learn > MAX_ORANGE_BAND):
            # The wiki writes expansion recipes on the retail per-expansion scale (Cataclysm 1-75), or on the old one on
            # retail pages (Pandaria 500).  Against this client's own thresholds that value is on another scale, so it is not used.
            stats["recipe_learn_other_scale"] += 1
            learn = rc.yellow
        rc.learn = max(learn, db_min if db_min > 1 else 1)
        rc.reagents = reag.get(r["Spell"], [])
        rc.item, rc.weight = None, 0
        if rc.grey > rc.learn:
            out.append(rc)
    return out


def chance(r, s):
    if s < r.yellow:
        return 1.0
    if r.grey <= r.yellow:
        return 0.0
    return max(0.0, (r.grey - s) / float(r.grey - r.yellow))


def plan_path(recipes, lo, hi):
    """list of runs (recipe, from, to, crafts).  Greedy on estimated cost per skill point, sticky to avoid a recipe change per point."""
    runs, s, cur = [], lo, None
    while s < hi:
        cands = [r for r in recipes if r.learn <= s < r.grey and chance(r, s) >= 0.2]
        if not cands:
            break
        best = min(cands, key=lambda r: (r.weight / chance(r, s), r.grey, r.spell))
        if cur in cands and chance(cur, s) >= 0.33 and cur.weight / chance(cur, s) <= 1.35 * best.weight / chance(best, s):
            best = cur
        if not runs or runs[-1][0] is not best:
            runs.append([best, s, s, 0.0])
        runs[-1][2] = s + 1
        runs[-1][3] += 1.0 / chance(best, s)
        cur, s = best, s + 1
    return runs


# ---------------------------------------------------------------------------
# Guides
# ---------------------------------------------------------------------------
class Out:
    def __init__(self, fl):
        self.fl = fl
        self.defs, self.rows = [], []

    def add(self, gid, name, prof, lo, hi, faction, minlevel, lines, tier, trainers, recipes, missing):
        if not any(not ln.startswith("N ") for ln in lines):
            return
        d = dict(id=gid, name=name, type="Professions", folder=prof, prof=prof, skillMin=lo, skillMax=hi, faction=faction, minlevel=minlevel,
                 author="Warcraft Wiki contributors (CC BY-SA 4.0)", source="Warcraft Wiki + Blizzard client tables")
        if tier:
            d["tier"] = tier
        if self.fl == "forever":
            d["forever"] = True
        self.defs.append((d, lines))
        self.rows.append((self.fl, gid, prof, tier or 0, lo, hi, len(lines), trainers, recipes, missing))


def lua_val(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    return '"' + str(v).replace("\\", "\\\\").replace('"', '\\"') + '"'


GUARD = {"era": 'if NS.flavor ~= "era" or NS.isForever then return end', "tbc": 'if NS.flavor ~= "tbc" then return end',
         "mop": 'if NS.flavor ~= "mop" then return end', "retail": 'if NS.flavor ~= "retail" then return end',
         "forever": "if not NS.isForever then return end"}


def write_file(fl, out, sites):
    p = GUIDES / ("Imported_Professions_%s.lua" % fl)
    keys = ("id", "name", "type", "folder", "prof", "skillMin", "skillMax", "tier", "faction", "minlevel", "forever", "author", "source")
    with open(p, "w", encoding="utf-8") as f:
        f.write("-- Completionist's Guide :: Imported_Professions_%s.lua - GENERATED %s by tools/wiki/gen_professions.py\n" % (fl, TODAY))
        f.write("-- Trainer locations, rank gates, recipe sources, reagent sources and fishing locations are derived from\n")
        f.write("-- Warcraft Wiki, https://warcraft.wiki.gg, by its contributors, licensed under CC BY-SA 4.0\n")
        f.write("-- (https://creativecommons.org/licenses/by-sa/4.0/). This data file is shared under the same licence;\n")
        f.write("-- see Guides/WIKI_DATA_LICENSE.md. Page histories (authors) are on each wiki page.\n")
        f.write("-- Recipe membership, skill thresholds, reagents and dig sites: Blizzard client tables via wago.tools (facts only).\n")
        f.write("local _, NS = ...\n%s\nlocal R = NS.Guide.Register\n\n" % GUARD[fl])
        for d, lines in out.defs:
            f.write("R({ " + ", ".join("%s=%s" % (k, lua_val(d[k])) for k in keys if k in d) + ", text=[==[\n")
            f.write("\n".join(lines))
            f.write("\n]==] })\n\n")
        if sites:
            f.write("NS.ArchaeologySites = {\n")
            for cont in sorted(sites):
                f.write("  [%d] = {\n" % cont)
                for s in sites[cont]:
                    f.write('    { %d, %s, %d, %.1f, %.1f },\n' % (s[0], lua_val(s[1]), s[2], s[3], s[4]))
                f.write("  },\n")
            f.write("}\n")
    return p


def fishing_rows():
    text = W.page("Fishing locations")
    out, section = [], ""
    for line_block in re.split(r"\n\|-\s*", text):
        h = re.findall(r"^==\s*([^=]+?)\s*==", line_block, re.M)
        if h:
            section = h[-1]
        # keep empty cells: an empty Locations column is the normal case and the columns are positional
        cells = [c.strip() for c in re.split(r"\n\|", "\n" + line_block.strip())[1:]]
        if len(cells) < 4:
            continue
        ln = WT.links(cells[0])
        if not ln:
            continue
        skill = num(cells[2]) if cells[2].strip().isdigit() else None
        if skill is None:
            continue
        fish = [t for t, _ in WT.links(cells[3])]
        out.append(dict(section=section, zone=ln[0][0], where=WT.plain(cells[1]), catch=skill, fish=fish))
    return out


def fish_zone(rows, atlas, fl, faction, lo, ceiling=None):
    S = atlas.sets[fl]
    hostile = HORDE_ZONES if faction == "Alliance" else ALLIANCE_ZONES
    best, seen = [], set()
    for r in rows:
        if r["catch"] > max(lo, 25):
            continue
        mid = S.resolve(r["zone"])
        if mid is None or S.maps[mid]["type"] != 3:
            continue
        nm = S.maps[mid]["name"]
        if nm in hostile or nm in seen or "Objective" in r["where"]:
            continue
        seen.add(nm)
        best.append((r["catch"], nm, mid, r))
    best.sort(key=lambda b: (-b[0], b[1]))
    return best


def book_info(title, pages):
    body = pages.get(title, ("", ""))[0]
    if not body:
        return None
    named = {}
    for _s, _e, _n, inner in WT.find_templates(body, re.compile(r"#data:itemtip", re.I)):
        named = WT.split_params(inner)[1]
        break
    sellers = []
    for m in re.finditer(r"\{\{\s*npc\s*\|([^|{}]*)\|([^|{}]+)[^{}]*\}\}([^\n]*)", body, re.I):
        where = re.split(r"(?<=[.])\s", WT.plain(m.group(3)))[0].strip(" .,")
        sellers.append((m.group(1).strip(), m.group(2).strip(), clean(where)))
    if not sellers:
        m = re.search(r"(?:purchased|sold|bought)\s+(?:from|by)\s+\[\[([^\]|]+)[^\]]*\]\]([^.\n]*)", body, re.I)
        if m:
            sellers.append(("", m.group(1).strip(), clean(WT.plain(m.group(2)))))
    return dict(item=num(named.get("itemid")), skill=num(named.get("profskill")), level=num(named.get("level")), sellers=sellers)


def quest_line(gen, qid, faction, fl, questv2):
    q = gen.quest.get(qid)
    if not q or str(qid) not in questv2:
        return []
    name = clean(q[1])
    out, st, en = [], json.loads(q[3] or "[]"), json.loads(q[4] or "[]")
    giver = st[0]["title"] if st else None
    ender = en[0]["title"] if en else giver

    def loc(npc):
        pt = gen.npc_point(npc, fl) if npc else None
        return "|M|%.1f,%.1f|Z|%d" % (pt[1], pt[2], pt[0]) if pt else ""
    out.append("A %s|QID|%d%s|FACTION|%s|N|From %s.|" % (name, qid, loc(giver), faction, clean(giver or "?")))
    for idx, kind, target, count, text in gen.objectives.get(qid, []):
        if kind == "provided":
            continue
        out.append("C %s|QID|%d|QO|%d|N|%s|" % (name, qid, idx, clean(text)))
    out.append("T %s|QID|%d%s|FACTION|%s|N|To %s.|" % (name, qid, loc(ender), faction, clean(ender or "?")))
    return out


def recipe_steps(gen, prof, fl, faction, runs, tier, trainer_alt, taught, item_name, reagent_src, skill_tail):
    """make/buy/train lines of a plan; `taught` carries the recipes already shown in earlier bands"""
    lines, recipes, missing = [], 0, 0
    for r, a, b, crafts in runs:
        recipes += 1
        if r.spell not in taught and not r.auto:
            taught.add(r.spell)
            if r.kind == "trainer" and trainer_alt:
                lines.append("= Train %s|RECIPE|%d|ALT|%s|" % (clean(r.name), r.spell, trainer_alt))
            elif r.kind == "trainer":
                missing += 1
                lines.append("N Learn %s from a trainer|RECIPE|%d|N|The wiki lists no %s trainer for this client and faction.|" % (clean(r.name), r.spell, prof))
            elif r.kind == "item":
                rname = r.source or ("Recipe: " + r.name)
                src = reagent_src.get(r.source) or r.source
                it = r.item
                lines.append(("B %s|L|%d 1|RECIPE|%d|N|%s|" % (clean(rname), it, r.spell, clean(src))) if it else
                             ("N Get %s|RECIPE|%d|N|%s|" % (clean(rname), r.spell, clean(src))))
            else:
                lines.append("N Get the %s recipe|RECIPE|%d|N|%s|" % (clean(r.name), r.spell, clean(r.source)))
        n = int(math.ceil(crafts))
        notes = []
        for item, qty in r.reagents:
            nm = item_name.get(item) or ("item %d" % item)
            src = reagent_src.get(nm, "")
            if not src:
                missing += 1
            notes.append("%d %s%s" % (qty * n, clean(nm), " (%s)" % src if src else ""))
            if src and VENDOR.search(src) and not re.search(r"\balso\b", src, re.I):
                lines.append("B %s|L|%d %d|COUNT|%d|N|%s|" % (clean(nm), item, qty * n, qty * n, src))
        if not r.reagents:
            missing += 1
            notes.append("The client tables list no fixed reagents for this recipe; open the recipe in game to see them.")
        est = "About %d crafts (estimated from the skill colours)." % n
        lines.append("M %s|SKILL|%s;%d%s|SPELL|%d|COUNT|%d|N|%s %s|" % (clean(r.name), prof, b, skill_tail, r.spell, n, est, "; ".join(notes)))
    return lines, recipes, missing


def gen_flavor(gen, fl):
    stats = defaultdict(int)
    out = Out(fl)
    names = spell_names(fl)
    sla = D.rows(fl, "SkillLineAbility")
    sla_by = defaultdict(set)
    for r in sla:
        sla_by[r["SkillLine"]].add(r["Spell"])
    reag = reagents_of(fl)
    questv2 = {r["ID"] for r in D.rows(fl, "QuestV2")}
    lists, fa = parse_lists(), parse_first_aid()
    want = {names.get(r["Spell"]) for r in sla if r["SkillLine"] in ("185", "129") and int(r["TrivialSkillLineRankHigh"]) > 0}
    boxes = fetch_pages(want)
    all_item_ids = {i for rs in reag.values() for i, _ in rs}
    item_name = {}
    recipe_ids = [r["Spell"] for r in sla if r["SkillLine"] in ("185", "129")]
    used = {i for sp in recipe_ids for i, _ in reag.get(sp, [])}
    item_name = item_names(fl, used)
    reagent_pages = fetch_pages(item_name.values())
    reagent_src = {n: source_sentence(reagent_pages.get(n, ("", ""))[0]) for n in item_name.values()}
    learnitems = set()
    for n, (body, _) in boxes.items():
        b = parse_box(body)
        if b and b.get("learnitem"):
            learnitems.add(b["learnitem"].strip())
        else:
            lead = lead_source(body) if body else None
            if lead and lead[1] == "item":
                learnitems.add(lead[2])
    if fl in CLASSICISH:
        for sp_name in want:
            for prefix in RECIPE_PREFIX:
                if prefix + (sp_name or "") in RECIPE_ITEMS.get(fl, {}):
                    learnitems.add(prefix + sp_name)
    recipe_pages = fetch_pages(learnitems)
    for t in learnitems:
        reagent_src[t] = source_sentence(recipe_pages.get(t, ("", ""))[0])
    book_pages = fetch_pages(BOOKS.values())

    def prepare(recipes, faction):
        """planning weight: reagent availability and how the recipe is learned.  Internal only, never shown."""
        for r in recipes:
            w = 0.0
            for item, qty in r.reagents:
                src = reagent_src.get(item_name.get(item, ""), "")
                w += qty * (1.0 if VENDOR.search(src) else (3.0 if src else 12.0))
            # auto and trainer recipes first; a recipe from one named NPC can be a whole expansion away from a new character
            r.weight = max(w, 1.0) * {"auto": 1.0, "trainer": 1.0, "item": 2.0, "listed": 6.0}.get(r.kind, 2.0)
            if r.kind == "item" and r.source:
                body = recipe_pages.get(r.source, ("", ""))[0]
                tip = {}
                for _s, _e, _n, inner in WT.find_templates(body, re.compile(r"#data:itemtip", re.I)):
                    tip = WT.split_params(inner)[1]
                    break
                r.item = num(tip.get("itemid")) or RECIPE_ITEMS.get(fl, {}).get(r.source)
                if not reagent_src.get(r.source):
                    r.weight *= 3
        return recipes

    water = fishing_rows()
    for prof in PROFS[fl]:
        trainers = gen.usable_trainers(prof, fl, stats)
        if prof == "Archaeology":
            gen_arch(gen, fl, out, trainers, sla_by, stats)
            continue
        if fl == "retail":
            gen_tiers(gen, fl, out, prof, trainers, sla, names, reag, lists, fa, boxes, prepare, item_name, reagent_src, water, stats)
            continue
        taught = {}
        for faction in ("Alliance", "Horde"):
            taught_set = taught.setdefault(faction, set())
            recipes = []
            if prof != "Fishing":
                recipes = prepare(build_recipes(fl, prof, None, names, sla, reag, lists, fa, boxes, faction, stats), faction)
            for idx in range(1, RANK_COUNT[fl] + 1):
                lo, hi = max(1, (idx - 1) * 75), idx * 75
                rank_name = RANK_NAMES[idx - 1]
                spell = RANK_SPELLS[prof][idx - 1]
                rank_tag = "|RECIPE|%d" % spell if str(spell) in sla_by[SKILL_LINE[prof]] else ""
                lines, tcount, missing, minlevel = [], 0, 0, 1
                gated = fl in CLASSICISH and (idx >= 3)
                if not gated:
                    alt, tcount = gen.alt(trainers, faction, idx)
                    if alt:
                        caveat = "|N|On Classic some small-town trainers stop at a lower rank; the wiki table no longer says which, so if this one cannot teach it, try a city trainer.|" if fl in CLASSICISH and idx > 1 else "|"
                        lines.append("= Train %s %s%s|ALT|%s%s" % (rank_name, prof, rank_tag, alt, caveat))
                    else:
                        missing += 1
                        lines.append("N Train %s %s%s|N|The wiki lists no usable trainer for this client and faction.|" % (rank_name, prof, rank_tag))
                elif (prof, idx) in BOOKS:
                    bi = book_info(BOOKS[(prof, idx)], book_pages)
                    if not bi or not bi["item"]:
                        missing += 1
                        lines.append("N %s %s|N|The wiki has no usable page for this rank's book.|" % (rank_name, prof))
                    else:
                        minlevel = bi["level"] or 1
                        pts, named = [], []
                        for fac, npc, where in bi["sellers"]:
                            page_fac = fac or (re.search(r"faction\s*=\s*(\w+)", (fetch_pages([npc]).get(npc, ("", ""))[0]) or "") or [None, ""])[1]
                            if page_fac and page_fac not in (faction, "Neutral"):
                                continue
                            named.append("%s %s" % (clean(npc), where))
                            pt = gen.npc_point(npc, fl)
                            if pt:
                                pts.append("%d,%.1f,%.1f,%s" % (pt[0], pt[1], pt[2], clean(npc)))
                        tcount = len(pts)
                        loc = "|ALT|" + ";".join(pts) if pts else ""
                        if not pts:
                            missing += 1
                        if not named:
                            missing += 1
                        lines.append("B %s|L|%d 1%s%s|N|Sold by: %s (wiki: %s). Needs %s skill %s.|" % (clean(BOOKS[(prof, idx)]), bi["item"], rank_tag, loc, "; ".join(named) or "the wiki names no seller for this faction", clean(BOOKS[(prof, idx)]), prof, bi["skill"] or "?"))
                        lines.append("U Read %s|U|%d%s|N|Teaches %s %s.|" % (clean(BOOKS[(prof, idx)]), bi["item"], rank_tag, rank_name, prof))
                else:
                    qlines = []
                    for q in QUESTS[(prof, idx)][faction]:
                        qlines += quest_line(gen, q, faction, fl, questv2)
                    if qlines:
                        lines += qlines
                        lines.append("N %s %s reward%s|N|The quest above teaches this rank on this client.|" % (rank_name, prof, rank_tag))
                    else:
                        missing += 1
                        lines.append("N %s %s%s|N|The wiki has no usable quest row for this rank.|" % (rank_name, prof, rank_tag))
                reached, recipe_count = lo, 0
                if prof == "Fishing":
                    z = fish_zone(water, gen.atlas, fl, faction, lo)
                    if not z:
                        missing += 1
                        continue
                    c, nm, mid, r = z[0]
                    fish = ", ".join(r["fish"][:5])
                    also = ", ".join(x[1] for x in z[1:3])
                    if idx == 1:
                        lines.append("N Get a Fishing Pole|N|Sold by general goods and fishing supply vendors; a pole is optional for the first casts (wiki: Fishing Poles).|")
                    lines.append("R %s|Z|%d; %s|N|Fishing locations: 100%% catch at skill %d.|" % (clean(nm), mid, clean(nm), c))
                    lines.append("M Fish in %s|SKILL|Fishing;%d|Z|%d; %s|N|Catches here: %s.%s|" % (clean(nm), hi, mid, clean(nm), clean(fish), " Also works: %s." % clean(also) if also else ""))
                    reached = hi
                else:
                    train_alt, _ = gen.alt(trainers, faction, 1)
                    runs = plan_path(recipes, lo, hi)
                    if runs:
                        ml, recipe_count, m2 = recipe_steps(gen, prof, fl, faction, runs, None, train_alt, taught_set, item_name, reagent_src, "")
                        lines += ml
                        missing += m2
                        reached = runs[-1][2]
                    if reached < hi:
                        missing += 1
                        stats["band_short"] += 1
                if reached <= lo and prof != "Fishing":
                    stats["band_empty"] += 1
                    continue
                gid = "prof:%s:%s:%d:%s" % (fl, prof.replace(" ", ""), idx, faction)
                out.add(gid, "%s %d-%d (%s)" % (prof, lo, reached, faction), prof, lo, reached, faction, minlevel, lines, None, tcount, recipe_count, missing)
    return out, stats


# Wiki 'Profession' table: minimum level per expansion proficiency.  The later ones are written as {{level|xx-min}}.
TIER_LEVEL_KEY = {"Shadowlands": "sl-min", "Dragon Isles": "df-min", "Khaz Algar": "tww-min", "Midnight": "mn-min"}


def tier_level(prefix):
    if prefix == "Classic":
        return 5
    key = TIER_LEVEL_KEY.get(prefix)
    if key:
        m = re.search(r"\b" + key + r"\s*=\s*(\d+)", W.page("Template:Level"))
        if m:
            return int(m.group(1))
    return 10


def gen_tiers(gen, fl, out, prof, trainers, sla, names, reag, lists, fa, boxes, prepare, item_name, reagent_src, water, stats):
    tiers = {}
    for r in D.rows(fl, "SkillLine"):
        if r["ParentSkillLineID"] == SKILL_LINE[prof] and r["CategoryID"] == "9":
            for prefix in TIER_CAP[prof]:
                if r["DisplayName_lang"].startswith(prefix):
                    tiers[prefix] = int(r["ID"])
    for prefix, tid in tiers.items():
        cap = TIER_CAP[prof][prefix]
        lands = TIER_LAND[prefix]
        for faction in ("Alliance", "Horde"):
            usable = [t for t in trainers if t["land"] in lands]
            alt, tcount = gen.alt(usable, faction)
            bands = [(1, 75), (75, 150), (150, 225), (225, 300)] if prefix == "Classic" else [(1, cap)]
            taught = set()
            recipes = []
            if prof == "Cooking":
                recipes = prepare(build_recipes(fl, prof, tid, names, sla, reag, lists, fa, boxes, faction, stats), faction)
            for band_i, (lo, hi) in enumerate(bands):
                lines, missing, recipe_count, reached = [], 0, 0, lo
                tail = ";%d" % tid
                if band_i == 0:
                    if alt:
                        lines.append("= Train %s %s|SKILL|%s;1%s|ALT|%s|" % (prefix, prof, prof, tail, alt))
                    else:
                        missing += 1
                        lines.append("N Learn %s %s|SKILL|%s;1%s|N|The wiki's trainer table lists no %s trainer for this expansion and faction.|" % (prefix, prof, prof, tail, prof))
                if prof == "Fishing":
                    if prefix == "Classic":
                        z = fish_zone(water, gen.atlas, fl, faction, lo)
                        if not z:
                            continue
                        _c, nm, mid, r = z[0]
                        lines.append("R %s|Z|%d; %s|N|Fishing locations: 100%% catch at skill %d (the wiki figure predates the split into expansion skills).|" % (clean(nm), mid, clean(nm), _c))
                        lines.append("M Fish in %s|SKILL|Fishing;%d%s|Z|%d; %s|N|Catches here: %s.|" % (clean(nm), hi, tail, mid, clean(nm), clean(", ".join(r["fish"][:5]))))
                    else:
                        S = gen.atlas.sets[fl]
                        z = [(n, S.resolve(n)) for n in TIER_WATER[prefix]]
                        z = [(n, m) for n, m in z if m is not None]
                        if not z:
                            missing += 1
                            lines.append("M Fish in the %s zones|SKILL|Fishing;%d%s|N|The wiki's Fishing table names no map this client knows.|" % (prefix, hi, tail))
                        else:
                            n, m = z[0]
                            nm = S.maps[m]["name"]
                            lines.append("R %s|Z|%d; %s|N|Wiki: Fishing skill table.|" % (clean(nm), m, clean(nm)))
                            lines.append("M Fish in %s|SKILL|Fishing;%d%s|Z|%d; %s|N|Any water here raises %s %s.|" % (clean(nm), hi, tail, m, clean(nm), prefix, prof))
                    reached = hi
                else:
                    runs = plan_path(recipes, lo, hi)
                    if runs:
                        ml, recipe_count, m2 = recipe_steps(gen, prof, fl, faction, runs, tid, alt, taught, item_name, reagent_src, tail)
                        lines += ml
                        missing += m2
                        reached = runs[-1][2]
                    if reached < hi:
                        missing += 1
                        stats["band_short"] += 1
                    if reached <= lo:
                        stats["band_empty"] += 1
                        continue
                gid = "prof:%s:%s:%d:%d:%s" % (fl, prof, tid, band_i + 1, faction)
                out.add(gid, "%s %s %d-%d (%s)" % (prefix, prof, lo, reached, faction), prof, lo, reached, faction, tier_level(prefix),
                        lines, tid, tcount, recipe_count, missing)


# Warcraft Wiki 'Archaeology trainers' (rank -> level) and 'Archaeology' (skill ranges): apprentice to Illustrious come
# from the trainer table; later ranks are not given a level there, so the last stated level is kept.
ARCH_LEVEL = [20, 20, 20, 35, 50, 65, 75]
ARCH_BANDS = {"mop": [(1, 75), (75, 150), (150, 225), (225, 300), (300, 375), (375, 450), (450, 525), (525, 600)],
              "retail": [(1, 75), (75, 150), (150, 225), (225, 300), (300, 375), (375, 450), (450, 525), (525, 600), (600, 700), (700, 800), (800, 950)]}


def gen_arch(gen, fl, out, trainers, sla_by, stats):
    for faction in ("Alliance", "Horde"):
        for idx, (lo, hi) in enumerate(ARCH_BANDS[fl]):
            alt, tcount = gen.alt(trainers, faction)
            lvl = ARCH_LEVEL[min(idx, len(ARCH_LEVEL) - 1)]
            spell = RANK_SPELLS["Archaeology"][idx] if idx < 8 else None
            tag = "|RECIPE|%d" % spell if spell and str(spell) in sla_by["794"] else ""
            nm = RANK_NAMES[idx] if idx < 8 else "next"
            lines = []
            if idx == 0 or fl == "mop":
                lines.append("= Train %s Archaeology%s|ALT|%s|N|Requires level %d (wiki: Archaeology trainers).|" % (nm, tag, alt, lvl))
            lines.append('M Survey dig sites|SKILL|Archaeology;%d|N|Load the guide "Archaeology: active dig sites" for the sites on your continent. One skill point per find, more for solving artifacts (wiki: Archaeology, Levels).|' % hi)
            out.add("prof:%s:Archaeology:%d:%s" % (fl, idx + 1, faction), "Archaeology %d-%d (%s)" % (lo, hi, faction), "Archaeology", lo, hi, faction, lvl, lines, None, tcount, 0, 0 if alt else 1)


def dig_sites(gen, fl):
    """static fallback: {continent uiMapID: [(researchSiteID, name, zone uiMapID, x, y)]}"""
    S = gen.atlas.sets[fl]
    rs = D.rows(fl, "ResearchSite")
    if not rs:
        return {}
    wanted = {r["QuestPOIBlobID"] for r in rs}
    blobs = {r["ID"]: r for r in D.rows(fl, "QuestPOIBlob") if r["ID"] in wanted}
    pts = defaultdict(list)
    for r in D.rows(fl, "QuestPOIPoint"):
        if r["QuestPOIBlobID"] in wanted:
            pts[r["QuestPOIBlobID"]].append((float(r["X"]), float(r["Y"])))
    out = defaultdict(list)
    for r in rs:
        b, p = blobs.get(r["QuestPOIBlobID"]), pts.get(r["QuestPOIBlobID"])
        if not b or not p:
            continue
        wx, wy = sum(a for a, _ in p) / len(p), sum(c for _, c in p) / len(p)
        placed = S.from_world(int(r["MapID"]), wx, wy)
        if not placed:
            continue
        mid, x, y = placed
        cont, seen = mid, 0
        while cont in S.maps and S.maps[cont]["type"] > 2 and seen < 6:
            cont, seen = S.maps[cont]["parent"], seen + 1
        if cont in S.maps and S.maps[cont]["type"] == 2:
            out[cont].append((int(r["ID"]), clean(r["Name_lang"]), mid, x, y))
    return out


def main():
    flavors = [a for a in sys.argv[1:] if a in FLAVORS] or list(FLAVORS)
    gen = Gen()
    rows, totals = [], {}
    for fl in flavors:
        out, stats = gen_flavor(gen, fl)
        sites = dig_sites(gen, fl) if "Archaeology" in PROFS[fl] else {}
        p = write_file(fl, out, sites)
        rows += out.rows
        totals[fl] = (len(out.defs), sum(len(l) for _, l in out.defs), dict(stats), sum(len(v) for v in sites.values()))
        print(fl, "guides", len(out.defs), "steps", totals[fl][1], "sites", totals[fl][3], dict(stats), p.name, flush=True)
    con = sqlite3.connect(str(VERIFY))
    con.execute("create table if not exists prof_guides(flavor text, id text primary key, profession text, tier int, skill_min int, skill_max int, "
                "steps int, trainers int, recipes int, missing_facts int)")
    for fl in flavors:
        con.execute("delete from prof_guides where flavor=?", (fl,))
    con.executemany("insert or replace into prof_guides values (?,?,?,?,?,?,?,?,?,?)", rows)
    con.commit()
    con.close()


if __name__ == "__main__":
    main()
