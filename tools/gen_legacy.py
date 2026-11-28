#!/usr/bin/env python3
# CompletionRoute :: tools/gen_legacy.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""WoW Forever "Legacy Points" guides -> CompletionRoute/Guides/Imported_Legacy_forever.lua (Forever and Camelot TOCs only).

    python3 tools/gen_legacy.py --fetch     # once: the wiki pages below -> tools/wiki/cache/legacy/*.json (serial, 1.5 s apart)
    python3 tools/gen_legacy.py             # write the guide file from the cache + Blizzard tables + the other Forever guides
    python3 tools/gen_legacy.py --selfcheck # rules on synthetic rows (run by tools/test_legacy.py)

Sources (facts only, never another add-on's data):
  * Blizzard Forever client tables (tools/db2/forever, wago.tools): every Achievement row whose reward reads "Earn N Legacy
    Point(s)" is a Legacy Challenge; Achievement_Category gives its group, CriteriaTree/Criteria its parts.  The client
    holds two copies of each challenge (two id ranges, same title and category); the guide uses the lower id, the one
    the wiki's {{Elinks-achievement}} links name, and keeps the other in `alt`.
  * Warcraft Wiki (CC BY-SA 4.0): Legacy System (reward thresholds), Legacy Challenges (the challenge list the Blizzard
    rows are checked against), the Forever instance pages (entrance {{co}}), Innkeeper Wiley.
  * Points: dungeon and raid entrances from Imported_Dungeons_forever.lua ("D Enter" lines keep their source), else the
    instance's wiki page; exploration areas from Blizzard WorldMapOverlay hit rectangles (Forever art, else the Era art
    for the same overlay converted through world coordinates onto the Forever map); quest steps copied from
    Imported_Wiki_forever.lua with their notes.  Steps whose challenge has no place (level, skill, honor rank,
    reputation, weekly journey) carry |NOGEO|<reason>|.
Guides (type "Legacy Points", forever=true: Forever map percentages):
  Season Rewards (Innkeeper Wiley) - the reward thresholds, at Innkeeper Wiley in Ratchet (owner scope, 2026-11-27);
  Classes, Tradeskills, Player vs. Player - checklists; Lord Valthalak Laid to Rest - the quest line;
  Explorer: Eastern Kingdoms / Kalimdor - every exploration area; Novice / Experienced / Master Spelunker - the dungeons;
  Raids - the three raids.
"""
import collections, json, re, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(ROOT / "tools" / "wiki"))
GUIDES = ROOT / "CompletionRoute" / "Guides"
CACHE = ROOT / "tools" / "wiki" / "cache" / "legacy"
OUT = GUIDES / "Imported_Legacy_forever.lua"
FL = "forever"
UA = "CompletionistGuide/2.0 (+https://batesai.org)"
API = "https://warcraft.wiki.gg/api.php"
REWARD = re.compile(r"Earn (\d+) Legacy Points?")
# wiki page batches cached by --fetch: file name -> titles
PAGES = {
    "Legacy_System": ["Legacy_System"],
    "Legacy_Challenges": ["Legacy_Challenges"],
    "Innkeeper_Wiley": ["Innkeeper_Wiley"],
    "instances": ["Hyjal_Summit_(instance)", "Barrow_Deeps_(instance)", "Alcaz_Prison", "Drowned_City",
                  "Blackmaw_Hold_(instance)", "Shaper's_Terrace_(instance)", "Excavation_Site:_Wetlands",
                  "Ruins_of_Lordaeron_(instance)", "Hall_of_Thanes_(instance)", "City_of_Dalaran", "Krol'dok_Stronghold"],
}
# criterion (Blizzard CriteriaTree description) -> (entrance name in Imported_Dungeons_forever.lua, wiki instance page,
# faction).  "Ragefire Chasm or Hall of Thanes" is one criterion with a dungeon per faction.
INSTANCES = {
    "Ragefire Chasm": ("Ragefire Chasm", None, "Horde"),
    "Hall of Thanes": ("The Hall of Thanes", "Hall of Thanes (instance)", "Alliance"),
    "Ruins of Lordaeron": (None, "Ruins of Lordaeron (instance)", None),
    "Wailing Caverns": ("Wailing Caverns", None, None),
    "The Deadmines": ("The Deadmines", None, None),
    "Shadowfang Keep": ("Shadowfang Keep", None, None),
    "Excavation Site: Wetlands": (None, "Excavation Site: Wetlands", None),
    "City of Dalaran": ("The City of Dalaran", "City of Dalaran", None),
    "Blackfathom Deeps": ("Blackfathom Deeps", None, None),
    "Gnomeregan": ("Gnomeregan", None, None),
    "The Drowned City": (None, "Drowned City", None),
    "Scarlet Monastery: Graveyard": ("Scarlet Monastery", None, None),
    "Scarlet Monastery: Library": ("Scarlet Monastery", None, None),
    "Scarlet Monastery: Armory": ("Scarlet Monastery", None, None),
    "Scarlet Monastery: Cathedral": ("Scarlet Monastery", None, None),
    "Razorfen Kraul": ("Razorfen Kraul", None, None),
    "Krol'dok Stronghold": (None, "Krol'dok Stronghold", None),
    "Razorfen Downs": ("Razorfen Downs", None, None),
    "Uldaman": ("Uldaman", None, None),
    "Zul'Farrak": ("Zul'Farrak", None, None),
    "Maraudon": ("Maraudon", None, None),
    "Alcaz Prison": (None, "Alcaz Prison", None),
    "The Temple of Atal'Hakkar": ("Temple of Atal'Hakkar", None, None),
    "Blackrock Depths": ("The Blackrock Depths", None, None),
    "Blackmaw Hold": (None, "Blackmaw Hold (instance)", None),
    "Lower Blackrock Spire": ("Lower Blackrock Spire", None, None),
    "Upper Blackrock Spire": ("Upper Blackrock Spire", None, None),
    "Scholomance": ("Scholomance", None, None),
    "Stratholme: Live": ("Stratholme", None, None),
    "Stratholme: Dead": ("Stratholme", None, None),
    "Dire Maul: East": ("Dire Maul", None, None),
    "Dire Maul: North": ("Dire Maul", None, None),
    "Dire Maul: West": ("Dire Maul", None, None),
    "The Shaper's Terrace": (None, "Shaper's Terrace (instance)", None),
    "Complete Hyjal Summit": (None, "Hyjal Summit (instance)", None),
    "Complete The Barrow Deeps": (None, "Barrow Deeps (instance)", None),
    "Kill Onyxia": ("Onyxia's Lair", None, None),
}
# Achievement_Category root -> (guide key, guide name, NOGEO reason for a challenge with no place)
GROUPS = {"Classes": "counter", "Tradeskills": "counter", "Player vs. Player": "pvp", "Adventure": None,
          "Dungeons": None, "Raids": None}
CLASS_OF = re.compile(r"\b(Druid|Hunter|Mage|Paladin|Priest|Rogue|Shaman|Warlock|Warrior)\b")
PROF_OF = {"Alchemist": "Alchemy", "Blacksmith": "Blacksmithing", "Enchanter": "Enchanting", "Engineer": "Engineering",
           "Leatherworker": "Leatherworking", "Tailor": "Tailoring"}


# ---- wiki cache ----------------------------------------------------------------------------------------------------
def fetch():
    CACHE.mkdir(parents=True, exist_ok=True)
    for name, titles in PAGES.items():
        url = (f"{API}?action=query&prop=revisions&rvprop=content|ids&rvslots=main&format=json&formatversion=2"
               f"&redirects=1&maxlag=5&titles=" + "|".join(t.replace("'", "%27") for t in titles))
        part = CACHE / f"{name}.json.part"
        r = subprocess.run(["curl", "-sS", "-L", "--compressed", "-m", "120", "-A", UA, "-o", str(part), url])
        if r.returncode == 0 and part.stat().st_size > 100:
            part.replace(CACHE / f"{name}.json")
            print(f"fetched {name}")
        else:
            part.unlink(missing_ok=True)
            print(f"FAILED {name}", file=sys.stderr)
        time.sleep(1.5)


def pages():
    """wiki title -> wikitext, from the cache"""
    out = {}
    for name in PAGES:
        p = CACHE / f"{name}.json"
        if not p.exists():
            sys.exit(f"missing {p.relative_to(ROOT)}: run python3 tools/gen_legacy.py --fetch")
        for pg in json.loads(p.read_text(encoding="utf-8"))["query"]["pages"]:
            if "revisions" in pg:
                out[pg["title"]] = pg["revisions"][0]["slots"]["main"]["content"]
    return out


def wiki_rewards(text):
    """[(points, reward, type)] from the Legacy System page's reward table"""
    out = []
    for m in re.finditer(r"^!\s*(\d+)\s*\n\|\s*\[\[([^\]|]+)(?:\|[^\]]*)?\]\]\s*\|\|\s*([^\n]+)", text, re.M):
        out.append((int(m.group(1)), m.group(2).strip(), m.group(3).strip()))
    return out


def wiki_challenges(text):
    """challenge titles from the Legacy Challenges page: every list link outside the exploration lists (the zone
    explores are parts of Explore Azeroth, not challenges); "(Forever)" is the wiki's disambiguation, not the name"""
    out = []
    for sec in re.split(r"^==([^=]+)==\s*$", text, flags=re.M)[2::2]:
        for m in re.finditer(r"^\*\[\[([^\]|]+)", sec, re.M):
            t = re.sub(r"\s*\(Forever\)$", "", m.group(1).strip())
            if not t.startswith("Explore "):
                out.append(t)
    return out


def entrance_co(text):
    """(zone, x, y) of an instance page's entrance: the {{co}} on the infobox loc line, else on the first line that
    names the instance line / entrance / summoning stone"""
    lines = text.splitlines()
    pick = [l for l in lines if l.startswith("|loc=")] + \
           [l for l in lines if re.search(r"instance line|entrance to the dungeon|summoning stone|Take a left at", l)]
    for l in pick:
        m = re.search(r"\{\{co\|([\d.]+)\|([\d.]+)\|([^}|]+)\}\}", l)
        if m:
            return m.group(3).strip(), float(m.group(1)), float(m.group(2))
    return None


def loc_zone(text):
    """the zone the infobox loc names ([[Mount Hyjal (Forever)|Mount Hyjal]], {{c|Azshara}})"""
    m = re.search(r"^\|loc=\s*(?:\[\[([^\]|]+)|\{\{c\|([^}|]+))", text, re.M)
    return (m.group(1) or m.group(2)).strip() if m else None


# ---- Blizzard tables -----------------------------------------------------------------------------------------------
def challenges(rows_ach, rows_cat):
    """[challenge dict] in category / ui order: one per (category, title), lower id first, the other id in alt"""
    cats = {r["ID"]: r for r in rows_cat}

    def root(cid):
        seen = set()
        while cid in cats and cid not in seen:
            seen.add(cid)
            if cats[cid]["Parent"] in ("-1", "") or cats[cid]["Parent"] not in cats:
                return cats[cid]["Name_lang"]
            cid = cats[cid]["Parent"]
        return ""

    by = collections.OrderedDict()
    for r in sorted(rows_ach, key=lambda r: int(r["ID"])):
        m = REWARD.search(r.get("Reward_lang") or "")
        if not m:
            continue
        key = (r["Category"], r["Title_lang"])
        if key in by:
            by[key]["alt"].append(int(r["ID"]))
            continue
        by[key] = {"id": int(r["ID"]), "alt": [], "title": r["Title_lang"], "desc": r["Description_lang"],
                   "points": int(m.group(1)), "cat": cats.get(r["Category"], {}).get("Name_lang", ""),
                   "root": root(r["Category"]), "tree": int(r["Criteria_tree"] or 0), "order": int(r["Ui_order"] or 0),
                   "catid": int(r["Category"] or 0)}
    return sorted(by.values(), key=lambda c: (list(GROUPS).index(c["root"]) if c["root"] in GROUPS else 99,
                                              c["catid"], c["order"], c["id"]))


class Tree:
    def __init__(self, rows_tree, rows_crit):
        self.node = {int(r["ID"]): r for r in rows_tree}
        self.kids = collections.defaultdict(list)
        for r in rows_tree:
            self.kids[int(r["Parent"])].append(r)
        for k in self.kids:
            self.kids[k].sort(key=lambda r: (int(r["OrderIndex"] or 0), int(r["ID"])))
        self.crit = {int(r["ID"]): r for r in rows_crit}

    def leaves(self, root):
        """[(criteria-tree id, description, Criteria.Type, asset)] under `root`, in order"""
        out, stack = [], [root]
        while stack:
            n = stack.pop(0)
            r = self.node.get(n)
            if r and int(r["CriteriaID"] or 0):
                c = self.crit.get(int(r["CriteriaID"]), {})
                out.append((n, r["Description_lang"], c.get("Type", ""), int(c.get("Asset") or 0)))
            stack[0:0] = [int(k["ID"]) for k in self.kids.get(n, [])]
        return out


# ---- points --------------------------------------------------------------------------------------------------------
def era_to_forever(rect_era, rect_fv, x, y):
    """an Era map percentage -> the same world spot as a Forever map percentage (tools/gen_mapfix_forever.py rects:
    (name, continent, topX, leftY, width, height); wx = topX - y01*h, wy = leftY - x01*w)"""
    _, _, tx, ly, w, h = rect_era
    wx, wy = tx - y / 100 * h, ly - x / 100 * w
    _, _, tx2, ly2, w2, h2 = rect_fv
    return round((ly2 - wy) / w2 * 100, 1), round((tx2 - wx) / h2 * 100, 1)


def overlay_points(G, place):
    """WorldMapOverlay id -> (uiMap, x, y, source) on Forever maps.  Forever's own art first; an overlay drawn on an Era
    art Forever no longer maps (the zone explores keep their old overlay ids) takes the Era art's map and is converted
    through world coordinates when Forever reshaped that map."""
    import gen_mapfix_forever as MF
    fv = {k: v + ("Blizzard WorldMapOverlay %d" % k,) for k, v in G.overlay_points(FL, place.maps).items()}
    era = G.overlay_points("era", place.atlas.sets["era"])
    rects_era, _ = MF.load("era")
    rects_fv, _ = MF.load("forever")
    for oid, (mid, x, y) in era.items():
        if oid in fv or mid not in place.maps.maps:
            continue
        a, b = rects_era.get(mid), rects_fv.get(mid)
        if a and b and max(abs(p - q) for p, q in zip(a[2:], b[2:])) >= 0.5:
            x, y = era_to_forever(a, b, x, y)
            if not (0 <= x <= 100 and 0 <= y <= 100):
                continue
            fv[oid] = (mid, x, y, f"Blizzard WorldMapOverlay {oid} on the Era map, converted to the Forever map")
        else:
            fv[oid] = (mid, x, y, f"Blizzard WorldMapOverlay {oid}")
    return fv


def dungeon_entrances(text):
    """entrance name -> (tag 'M|..|Z|..|', source) from the first "D Enter <name>" line of each Imported_Dungeons_forever
    guide; "again" / "a third time" re-entries are the same door"""
    out = {}
    for m in re.finditer(r"^D Enter (.+?)\|(M\|[^|]+\|Z\|[^|]+\|)N\|([^|]*)\|?$", text, re.M):
        name = re.sub(r" (?:again|a third time)$", "", m.group(1))
        src = re.search(r"\(location: (.*)\)\s*$", m.group(3))
        out.setdefault(name, (m.group(2), f"entrance; {src.group(1)}" if src else "entrance; Imported_Dungeons_forever"))
    return out


def wiki_lines(text):
    """qid -> A/C/T lines of Imported_Wiki_forever.lua"""
    out = collections.defaultdict(list)
    for l in text.splitlines():
        m = re.match(r"^[ACT] .*?\|QID\|(\d+)\|", l)
        if m:
            out[int(m.group(1))].append(l)
    return out


def quest_chain(lines, start_titles, end_titles):
    """the quest line from the quests titled start_titles to those titled end_titles: forward along the wiki's previous
    links from the start, backward from the end; one quest per (title, faction) (the class versions are the same steps
    at the same NPCs), PRE rewritten onto the kept quests.  Returns ([qid in story order], {qid: [line]})."""
    def title(q):
        return lines[q][0][2:].split("|", 1)[0]

    def faction(q):
        m = re.search(r"\|FACTION\|(\w+)\|", lines[q][0])
        return m.group(1) if m else ""

    pre, nxt = {}, collections.defaultdict(set)
    for q, ls in lines.items():
        for l in ls:
            m = re.search(r"\|PRE\|([\d;,]+)\|", l)
            if m:
                pre[q] = [int(x) for x in re.split("[;,]", m.group(1)) if x]
                for p in pre[q]:
                    nxt[p].add(q)
                break
    keep = set()
    st = [q for q in lines if title(q) in end_titles]
    while st:
        q = st.pop()
        if q in keep or q not in lines:
            continue
        keep.add(q)
        st += pre.get(q, [])
    st = [q for q in lines if title(q) in start_titles]
    while st:
        q = st.pop()
        if q in keep or q not in lines:
            continue
        keep.add(q)
        st += nxt.get(q, ())
    rep = {}
    for q in sorted(keep):
        rep.setdefault((title(q), faction(q)), q)
    canon = {q: rep[(title(q), faction(q))] for q in keep}
    kept = sorted(set(canon.values()))
    depth = {}

    def d(q, seen=()):
        if q in depth:
            return depth[q]
        ps = [canon[p] for p in pre.get(q, []) if p in canon and canon[p] != q and canon[p] not in seen]
        depth[q] = 1 + max((d(p, seen + (q,)) for p in ps), default=-1)
        return depth[q]
    order = sorted(kept, key=lambda q: (d(q), faction(q), q))
    out = {}
    for q in order:
        ps = sorted({canon[p] for p in pre.get(q, []) if p in canon and canon[p] != q})
        new = []
        for l in lines[q]:
            l = re.sub(r"\|PRE\|[\d;,]+\|", f"|PRE|{';'.join(map(str, ps))}|" if ps else "|", l)
            new.append(l)
        out[q] = new
    return order, out


# ---- writing -------------------------------------------------------------------------------------------------------
def lua(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


def clean(s):
    return re.sub(r"\s+", " ", (s or "").replace("|", "/")).strip()


def step(text, *tags, note=""):
    body = "|".join(t.strip("|") for t in tags if t)
    return f"C {clean(text)}|{body}|N|{clean(note)}|" if body else f"C {clean(text)}|N|{clean(note)}|"


def generate(write=True):
    import gen_completion_guides as G
    W = pages()
    rows = G.rows
    chs = challenges(rows(FL, "Achievement"), rows(FL, "Achievement_Category"))
    tree = Tree(rows(FL, "CriteriaTree"), rows(FL, "Criteria"))
    place = G.Places(FL)
    ach_rows = {int(r["ID"]): r for r in rows(FL, "Achievement")}
    wiki_text = (GUIDES / f"Imported_Wiki_{FL}.lua").read_text(encoding="utf-8")
    dung_text = (GUIDES / f"Imported_Dungeons_{FL}.lua").read_text(encoding="utf-8")
    entr = dungeon_entrances(dung_text)
    ovl = overlay_points(G, place)
    qlines = wiki_lines(wiki_text)
    stats = collections.Counter()
    located = {}           # challenge id -> "point" | "zone" | "nogeo"

    def mark(cid, where):
        kind = "point" if where.startswith("M|") else "zone" if where else "nogeo"
        rank = {"point": 0, "zone": 1, "nogeo": 2}
        if rank[kind] < rank.get(located.get(cid, "nogeo"), 2) or cid not in located:
            located[cid] = kind

    def wiki_place(page):
        t = W.get(page)
        if not t:
            return "", None
        co = entrance_co(t)
        if co:
            hit = place.place_pt(co[0], co[1], co[2])
            if hit:
                mid, x, y = hit[0], hit[1], hit[2]
                return f"M|{x:.1f},{y:.1f}|{place._zone(mid)}", f"entrance; wiki: {page}"
        z = loc_zone(t)
        tag = place._zone_tag(re.sub(r"\s*\(Forever\)$", "", z)) if z else ""
        return tag, (f"zone only; wiki: {page}" if tag else None)

    def instance_place(name):
        dname, page, fac = INSTANCES.get(name, (None, None, None))
        if dname and dname in entr:
            return entr[dname][0], entr[dname][1], fac
        if page:
            w, s = wiki_place(page)
            if w:
                return w, s, fac
        return "", None, fac

    guides = collections.OrderedDict()

    def add(gid, name, lines, order):
        guides[gid] = (name, lines, order)

    # wiki cross-check
    wiki_names = wiki_challenges(W.get("Legacy Challenges", ""))
    db_names = [c["title"] for c in chs]
    stats["wiki challenges"] = len(wiki_names)
    missing_db = sorted(set(wiki_names) - set(db_names))
    missing_wiki = sorted(set(db_names) - set(wiki_names))

    # rewards summary
    wiley = place.creature_place(6791)
    wtag, wsrc = wiley if wiley and wiley[0] else ("", None)
    rew = wiki_rewards(W.get("Legacy System", ""))
    total = sum(c["points"] for c in chs)
    lines = []
    by_root = collections.Counter()
    for c in chs:
        by_root[c["root"]] += c["points"]
    lines.append(step("Legacy Points overview", wtag, note=f"{len(chs)} challenges, {total} Legacy Points: " +
                      ", ".join(f"{k} {v}" for k, v in by_root.items()) + ". Points are account-wide (Hardcore apart) and "
                      "each challenge counts once per account. Open the Legacy window (Y) to see yours. "
                      f"({wsrc or 'no point'})"))
    for pts, item, kind in rew:
        lines.append(step(f"{item} ({pts} Legacy Points)", wtag,
                          note=f"Season reward at {pts} Legacy Points ({kind}, account-wide; wiki: Legacy System). "
                               f"Collect it from Innkeeper Wiley in Ratchet. ({wsrc or 'no point'})"))
    stats["rewards"] = len(rew)
    add("rewards", "Season Rewards (Innkeeper Wiley)", lines, 0)

    # per group
    explore_ach = None
    groups = collections.defaultdict(list)
    for c in chs:
        groups[c["root"]].append(c)
    for root, cs in groups.items():
        if root in ("Classes", "Tradeskills", "Player vs. Player"):
            lines = []
            for c in cs:
                gate = ""
                if root == "Classes":
                    m = CLASS_OF.search(c["title"])
                    gate = f"C|{m.group(1)}" if m else ""
                    extra = " Counts the first time any character of this class reaches the level."
                elif root == "Tradeskills":
                    m = re.search(r"(\w+)$", c["title"])
                    prof = PROF_OF.get(m.group(1), "") if m else ""
                    extra = f" Use a {prof} guide from the Professions list." if prof else ""
                else:
                    extra = f" ({c['cat']})" if c["cat"] and c["cat"] != root else ""
                reason = GROUPS[root]
                lines.append(step(c["title"], f"ACH|{c['id']}", gate, f"NOGEO|{reason}",
                                  note=f"{c['desc']} {c['points']} Legacy Point.{extra}"))
                mark(c["id"], "")
            stats[f"steps {root}"] = len(lines)
            add(re.sub(r"[^a-z]+", "-", root.lower()).strip("-"), root, lines, {"Classes": 1, "Tradeskills": 2,
                                                                                "Player vs. Player": 3}[root])
            continue
        for c in cs:
            leaves = tree.leaves(c["tree"])
            if root == "Adventure" and any(t == "27" for _, _, t, _ in leaves):
                # the Dungeon Set 2 quest line (wiki: begins with An Earnest Proposition, ends with Saving the Best for Last)
                order, ql = quest_chain(qlines, {"An Earnest Proposition"}, {"Saving the Best for Last"})
                lines = []
                for q in order:
                    lines.extend(ql[q])
                end = [q for q in order if ql[q][0][2:].startswith("Saving the Best for Last|")]
                for q in end:
                    t = next((l for l in ql[q] if l.startswith("T ")), ql[q][-1])
                    m = re.search(r"\|(M\|[^|]+\|)?(Z\|[^|]+\|)", t)
                    fac = re.search(r"\|FACTION\|(\w+)\|", t)
                    where = (m.group(1) or "") + m.group(2) if m else ""
                    lines.append(step(c["title"], f"ACH|{c['id']}", "FIXED", where,
                                      f"FACTION|{fac.group(1)}" if fac else "",
                                      note=f"{c['desc']} {c['points']} Legacy Point. Turn in Saving the Best for Last "
                                           "(quest " + str(q) + "). The class versions of each quest are the same steps; "
                                           "your quest log shows yours."))
                    mark(c["id"], where)
                stats["valthalak quests"] = len(order)
                add("valthalak", c["title"], lines, 4)
            elif root == "Adventure":
                explore_ach = c
            else:
                lines = []
                for ct, desc, typ, asset in leaves:
                    names = [n.strip() for n in desc.split(" or ")] if " or " in desc else [desc]
                    for n in names:
                        where, src, fac = instance_place(n)
                        if not where and root == "Raids":
                            where, src, fac = instance_place(tree.node[c["tree"]]["Description_lang"])
                        lines.append(step(n if len(names) > 1 or root == "Dungeons" else desc,
                                          f"ACH|{c['id']};{ct}", where, f"FACTION|{fac}" if fac else "",
                                          note=f"{c['title']}: {'defeat' if root == 'Raids' else 'complete'} "
                                               f"{desc if root == 'Raids' else n}."
                                               + (f" ({src})" if src else " (no location)")))
                        stats["instance " + ("point" if where.startswith("M|") else "zone" if where else "none")] += 1
                        mark(c["id"], where)
                lines.append(step(c["title"], f"ACH|{c['id']}", "FIXED",
                                  note=f"{c['desc']} {c['points']} Legacy Point."))
                key = "raids" if root == "Raids" else re.sub(r"[^a-z]+", "-", c["title"].lower()).strip("-")
                if root == "Raids":
                    old = guides.get("raids", ("Raids", [], 9))[1]
                    add("raids", "Raids", old + lines, 9)
                else:
                    add(key, c["title"], lines, 5 + ["Novice Spelunker", "Experienced Spelunker",
                                                     "Master Spelunker"].index(c["title"])
                        if c["title"] in ("Novice Spelunker", "Experienced Spelunker", "Master Spelunker") else 8)
    # Explorer: Explore Azeroth -> continents -> zones -> areas
    if explore_ach:
        c = explore_ach
        top = [a for _, _, t, a in tree.leaves(c["tree"]) if t == "8"]
        for meta in top:
            for _, _, t, cont in tree.leaves(int(ach_rows[meta]["Criteria_tree"])):
                if t != "8" or cont not in ach_rows:
                    continue
                cont_title = ach_rows[cont]["Title_lang"]
                lines = []
                for _, _, t2, zone_ach in tree.leaves(int(ach_rows[cont]["Criteria_tree"])):
                    if t2 != "8" or zone_ach not in ach_rows:
                        continue
                    zr = ach_rows[zone_ach]
                    for ct, desc, t3, asset in tree.leaves(int(zr["Criteria_tree"])):
                        hit = ovl.get(asset) if t3 == "43" else None
                        where, src = "", None
                        if hit:
                            where, src = f"M|{hit[1]:.1f},{hit[2]:.1f}|{place._zone(hit[0])}", hit[3]
                        else:
                            zname = re.sub(r"^Explore ", "", zr["Title_lang"])
                            where = place._zone_tag(zname)
                            src = "zone only; Blizzard: the achievement names this zone" if where else None
                        stats["explore " + ("point" if where.startswith("M|") else "zone" if where else "none")] += 1
                        lines.append(step(desc or zr["Title_lang"], f"ACH|{zone_ach};{ct}", where,
                                          note=f"{zr['Title_lang']} (for {cont_title}, Explore Azeroth and the "
                                               f"Explorer challenge)." + (f" ({src})" if src else "")))
                        mark(c["id"], where)
                lines.append(step(cont_title, f"ACH|{cont}", "FIXED", "NOGEO|counter",
                                  note=f"{ach_rows[cont]['Description_lang']}"))
                lines.append(step(c["title"], f"ACH|{c['id']}", "FIXED", "NOGEO|counter",
                                  note=f"{c['desc']} {c['points']} Legacy Point. Needs both continents."))
                add("explore-" + re.sub(r"[^a-z]+", "-", cont_title.replace("Explore ", "").lower()).strip("-"),
                    f"Explorer: {cont_title.replace('Explore ', '')}", lines, 4.5)
    for c in chs:
        located.setdefault(c["id"], "nogeo")
    res = {"challenges": len(chs), "points": total, "located": collections.Counter(located.values()),
           "missing_in_db2": missing_db, "missing_on_wiki": missing_wiki, "stats": stats,
           "unlocated": [c["title"] for c in chs if located[c["id"]] == "nogeo" and c["root"] in ("Adventure", "Dungeons", "Raids")]}
    if write:
        write_file(guides, wiki_text)
    return res


def write_file(guides, wiki_text):
    build = (ROOT / "tools" / "db2" / FL / "BUILD").read_text().strip()
    prov = [l for l in wiki_text.splitlines()[:20] if l.startswith("-- Steps whose note says")]
    head = [
        "-- Completionist's Guide :: Imported_Legacy_forever.lua - GENERATED by tools/gen_legacy.py",
        "-- WoW Forever Legacy Points: every Legacy Challenge (Blizzard Achievement rows whose reward is Legacy Points,",
        f"-- with Achievement_Category / CriteriaTree / Criteria / WorldMapOverlay; client build {build} and Era art for",
        "-- old exploration overlays, via wago.tools, facts only), the reward thresholds and challenge list from Warcraft",
        "-- Wiki (Legacy System, Legacy Challenges, the Forever instance pages, Innkeeper Wiley), https://warcraft.wiki.gg,",
        "-- by its contributors, licensed under CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0/). This data",
        "-- file is shared under the same licence; see Guides/WIKI_DATA_LICENSE.md. Quest steps and dungeon entrances are",
        "-- lines of Imported_Wiki_forever.lua / Imported_Dungeons_forever.lua and keep their notes.",
    ] + prov + [
        "local _, NS = ...",
        "if not NS.isForever then return end",
        "local R = NS.Guide.Register",
        "",
    ]
    out = list(head)
    for gid, (name, lines, order) in guides.items():
        out.append(f'R({{ id="legacy:forever:{gid}", name="{lua(name)}", type="Legacy Points", folder="Legacy Points", '
                   f'folderOrder={order:g}, forever=true, author="Blizzard achievement data + Warcraft Wiki contributors '
                   f'(CC BY-SA 4.0)", source="CompletionRoute", text=[==[')
        out.extend(l.replace("]==]", "] ==]") for l in lines)
        out.append("]==] })")
        out.append("")
    OUT.write_text("\n".join(out), encoding="utf-8")


# ---- selfcheck -----------------------------------------------------------------------------------------------------
def selfcheck():
    fails = 0

    def check(ok, msg):
        nonlocal fails
        print(("ok   " if ok else "FAIL ") + msg)
        fails += 0 if ok else 1
    ach = [
        {"ID": "61499", "Title_lang": "Novice Warrior", "Description_lang": "d", "Reward_lang": "Earn 1 Legacy Point.",
         "Category": "15585", "Criteria_tree": "1", "Ui_order": "1"},
        {"ID": "63969", "Title_lang": "Novice Warrior", "Description_lang": "d", "Reward_lang": "Earn 1 Legacy Point.",
         "Category": "15585", "Criteria_tree": "2", "Ui_order": "1"},
        {"ID": "5", "Title_lang": "Not legacy", "Description_lang": "d", "Reward_lang": "Title: X",
         "Category": "15585", "Criteria_tree": "3", "Ui_order": "1"},
        {"ID": "684", "Title_lang": "Conqueror of the Lair", "Description_lang": "d", "Reward_lang": "Earn 2 Legacy Points.",
         "Category": "15594", "Criteria_tree": "4", "Ui_order": "6"},
    ]
    cat = [{"ID": "15568", "Name_lang": "Classes", "Parent": "-1"}, {"ID": "15585", "Name_lang": "Warrior", "Parent": "15568"},
           {"ID": "15594", "Name_lang": "Raids", "Parent": "-1"}]
    cs = challenges(ach, cat)
    check(len(cs) == 2, "two challenges: copies merged, non-legacy row left out")
    check(cs[0]["id"] == 61499 and cs[0]["alt"] == [63969], "lower id kept, other copy in alt")
    check(cs[0]["root"] == "Classes" and cs[1]["points"] == 2, "root category and point count")
    check(wiki_rewards("! 15\n| [[Toy A]] || Toy\n|-\n! 25\n| [[Pet B|b]] || Companion\n") ==
          [(15, "Toy A", "Toy"), (25, "Pet B", "Companion")], "reward table parsed")
    check(wiki_challenges("x\n==Classes==\n*[[Novice Warrior (Forever)]]\n==Adventure==\n*[[Explorer (Forever)]]\n"
                          "*[[Explore Azeroth]]\n*[[Explore Duskwood (Forever)]]\n") == ["Novice Warrior", "Explorer"],
          "wiki challenge list: (Forever) stripped, zone explores left out")
    check(entrance_co("|loc=[[Riverglades]] {{co|39|39|Riverglades}}\n") == ("Riverglades", 39.0, 39.0), "loc {{co}}")
    check(entrance_co("blah\nThe instance line is at {{co|53.4|65.3|Wetlands (Forever)}}, x\n") ==
          ("Wetlands (Forever)", 53.4, 65.3), "instance line {{co}}")
    check(loc_zone("|loc=[[Mount Hyjal (Forever)|Mount Hyjal]]\n") == "Mount Hyjal (Forever)", "loc zone link")
    check(loc_zone("|loc={{c|Azshara}}\n") == "Azshara", "loc zone template")
    r = ("X", 0, 1000.0, 500.0, 1000.0, 1000.0)
    check(era_to_forever(r, r, 40.0, 60.0) == (40.0, 60.0), "identity rect keeps the point")
    r2 = ("X", 0, 1000.0, 500.0, 2000.0, 2000.0)
    check(era_to_forever(r, r2, 50.0, 50.0) == (25.0, 25.0), "a map twice the size halves the percentage")
    d = dungeon_entrances("D Enter Foo|M|1.0,2.0|Z|10; Bar|N|The entrance. (location: Blizzard Map table, x)|\n"
                          "D Enter Foo again|M|9.0,9.0|Z|10; Bar|N|later|\n")
    check(d == {"Foo": ("M|1.0,2.0|Z|10; Bar|", "entrance; Blizzard Map table, x")}, "first entrance kept, source copied")
    lines = {
        1: ["A Start|QID|1|FACTION|Alliance|N|x|", "T Start|QID|1|FACTION|Alliance|N|x|"],
        2: ["A Start|QID|2|FACTION|Alliance|N|x|"],
        3: ["A Mid|QID|3|PRE|1;2|N|x|"],
        4: ["A End|QID|4|PRE|3|M|1.0,1.0|Z|5; Z|N|x|"],
        9: ["A Other|QID|9|PRE|7|N|x|"],
    }
    order, ql = quest_chain(lines, {"Start"}, {"End"})
    check(order == [1, 3, 4], "chain: class copy 2 folded into 1, unrelated quest left out, story order")
    check("|PRE|1|" in ql[3][0] and "|PRE|3|" in ql[4][0], "PRE rewritten onto kept quests")
    check(step("A|B", "ACH|5", "", "NOGEO|pvp", note="n|m") == "C A/B|ACH|5|NOGEO|pvp|N|n/m|", "step escaping")
    print("selfcheck:", "ok" if not fails else f"{fails} failed")
    return fails


def main():
    if "--selfcheck" in sys.argv:
        sys.exit(1 if selfcheck() else 0)
    if "--fetch" in sys.argv:
        fetch()
        return
    res = generate()
    loc = res["located"]
    print(f"{OUT.relative_to(ROOT)}: {res['challenges']} challenges, {res['points']} Legacy Points; "
          f"wiki lists {res['stats']['wiki challenges']}")
    print(f"  challenges by best location: point {loc['point']}, zone {loc['zone']}, non-geographic {loc['nogeo']}")
    print(f"  steps: {dict(sorted((k, v) for k, v in res['stats'].items() if k != 'wiki challenges'))}")
    if res["missing_in_db2"] or res["missing_on_wiki"]:
        print(f"  wiki-only: {res['missing_in_db2']}  db2-only: {res['missing_on_wiki']}")
    if res["unlocated"]:
        print(f"  geographic challenges without a place: {res['unlocated']}")


if __name__ == "__main__":
    main()
