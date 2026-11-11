#!/usr/bin/env python3
# CompletionRoute :: tools/gen_completion_guides.py
# Copyright (c) 2026 Daniel Bates / BatesAI. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Generate the "completionist" guide sets from Blizzard client data (wago.tools DB2 exports):

    python3 tools/gen_completion_guides.py [retail] [mop] [--achievements-only]

  Guides/Imported_Achievements_<fl>.lua   one guide per achievement category (retail, mop).  Every
      achievement that is not a statistic becomes a block of steps: one per criterion (cap 60), then a
      FIXED "earn it" step.  Criteria carry |ACH|<achievement>;<criteria-tree id>| and tick from
      GetAchievementCriteriaInfoByID.  Locations come only from Warcraft Wiki data and Blizzard tables, never
      from WoW-Pro or Questie (Places below):
        point (|M|..|Z|..)  a criterion "complete quest N" (the quest's step in Imported_Wiki_<fl>, skipping rows
                            whose note says the position came from Questie) or "kill creature N" (wiki NPC point).
        zone  (|Z|.. only)  the same criterion when the wiki only names its zone, an achievement Blizzard ties to a
                            dungeon/raid/scenario (Achievement.Instance_ID -> Map), "Explore <zone>", "... quests in
                            <zone>".  The router heads for the zone (Routing/Router.lua); no coordinate is written.
        |NOGEO|<reason>|    on the FIXED step of an achievement with no location that has no place at all: battleground
                            or arena, PvP/reputation/feat/guild/general categories, purely counter criteria (level,
                            skill, reputation, currency).  Read by tools/coverage.py; the client keeps it as a raw tag.
  Guides/Imported_Storylines_retail.lua   one guide per QuestLine, quests in the client's OrderIndex
      order.  Each accept carries |PRE|<previous quest>| so the optimizer can interleave travel but can
      never break the story order.  Step lines (with locations) are reused from Imported_Quests_retail.
  Guides/Imported_Missions_retail.lua     one guide per mission table (WoD garrison + shipyard, Legion
      order hall, BfA war table, Shadowlands covenant table): a travel step to the table, then one
      note step per GarrMission row (|MISSION|id|) with followers, duration and cost.  Mission
      completion has no persistent client flag, so those steps are manual clicks.

Inputs: tools/db2/<fl>/{Achievement,Achievement_Category,Criteria,CriteriaTree,Map}.csv (fetched through
tools/wiki/db2_fetch.py when absent), tools/wiki/wiki.sqlite, Guides/Imported_Wiki_<fl>.lua,
tools/db2/retail/{QuestLine,QuestLineXQuest,GarrMission}.csv, tools/db2/questie_index.tsv (storyline names only).
Everything written is gitignored (Imported_*.lua); only this script ships.
"""
import csv, re, sqlite3, sys, collections
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
NOGEO_TYPES = {"5", "7", "9", "10", "12", "14", "40", "44", "45", "46", "47"}

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


def questie_names():
    p = DB2 / "questie_index.tsv"
    out = {}
    if p.exists():
        for r in csv.DictReader(p.open(encoding="utf-8"), delimiter="\t"):
            out[int(r["qid"])] = (r["name"], r["faction"])
    return out


def quest_lines(fl):
    """qid -> [step lines] from Imported_Quests_<fl>.lua (the per-zone community quest guides)"""
    p = GUIDES / f"Imported_Quests_{fl}.lua"
    out = collections.defaultdict(list)
    if not p.exists():
        return out
    for line in p.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^[ACT] .*?\|QID\|(\d+)\|", line)
        if m:
            out[int(m.group(1))].append(line)
    return out


def located(lines, action_pref=("T", "A", "C")):
    """(M, Z) of the best located step among a quest's lines"""
    for a in action_pref:
        for l in lines:
            if l.startswith(a + " "):
                m = re.search(r"\|M\|([^|]+)\|Z\|([^|]+)\|", l)
                if m:
                    return m.group(1), m.group(2)
    return None


def wiki_quest_lines(fl):
    """qid -> step lines from Imported_Wiki_<fl>.lua, leaving out rows whose position the note credits to Questie"""
    p = GUIDES / f"Imported_Wiki_{fl}.lua"
    out = collections.defaultdict(list)
    if not p.exists():
        return out
    for line in p.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^[ACT] .*?\|QID\|(\d+)\|", line)
        if m and "location: Questie" not in line:
            out[int(m.group(1))].append(line)
    return out


class Places:
    """where a criterion or achievement happens, on one client's maps: 'M|x,y|Z|id; name|' or 'Z|id; name|' or ''"""

    def __init__(self, fl):
        import wikimaps
        self.fl = fl
        self.atlas = wikimaps.Atlas()
        self.maps = self.atlas.sets[fl]
        self.qlines = wiki_quest_lines(fl)
        self.instance = {}
        for r in rows(fl, "Map"):
            self.instance[int(r["ID"])] = (clean(r["MapName_lang"]), r["InstanceType"])
        con = sqlite3.connect(WIKI_DB)
        self.quest = {int(i): (n, z) for i, n, z in con.execute("select id, name, zone from quests")}
        coords = collections.defaultdict(list)
        for t, z, x, y, c in con.execute("select title, zone, x, y, classic from npc_coords where x is not null order by title, idx"):
            coords[t].append((z, x, y, c))
        self.npc_by_id, self.npc_by_title = {}, {}
        for t, ids, z, x, y, pc in con.execute("select title, npc_id, zone, x, y, page_classic from npcs"):
            pts = coords.get(t) or ([(z, x, y, pc)] if x is not None and z else [])
            rec = (pts, z, bool(pc))
            self.npc_by_title[t] = rec
            for i in re.findall(r"\d+", ids or ""):
                self.npc_by_id.setdefault(int(i), rec)
        self.crit = collections.defaultdict(dict)
        for a, text, link, q in con.execute("select ach_id, text, link_title, quest_id from achievement_criteria"):
            self.crit[a][wikimaps.norm(text)] = (link, q)
        self.norm = wikimaps.norm
        con.close()

    def _zone(self, mid):
        return f"Z|{mid}; {self.maps.maps[mid]['name']}|"

    def _zone_tag(self, name):
        """a zone step only for a name that resolves to a zone or instance map (never a continent)"""
        if not name:
            return ""
        mid = self.maps.resolve(name)
        return self._zone(mid) if mid is not None and self.maps.maps[mid]["type"] in ZONE_TYPES else ""

    def named_zone(self, name):
        return self._zone_tag(name)

    def quest_place(self, q):
        loc = located(self.qlines.get(q, []))
        if loc:
            return f"M|{loc[0]}|Z|{loc[1]}|"
        return self._zone_tag(self.quest.get(q, (None, None))[1])

    def _npc_place(self, rec):
        pts, zone, classic = rec
        for z, x, y, c in pts:
            hit = self.atlas.place(z, x, y, self.fl, bool(c) or classic)
            if hit and self.maps.maps[hit[0]]["type"] in ZONE_TYPES:
                return f"M|{hit[1]:.1f},{hit[2]:.1f}|{self._zone(hit[0])}"
        return self._zone_tag(zone)

    def creature_place(self, npc):
        rec = self.npc_by_id.get(npc)
        return self._npc_place(rec) if rec else ""

    def wiki_criterion_place(self, aid, desc):
        """the wiki's own criterion list: a linked quest, or a linked NPC article"""
        hit = self.crit.get(aid, {}).get(self.norm(desc))
        if not hit:
            return ""
        link, q = hit
        if q:
            return self.quest_place(int(q))
        if link:
            rec = self.npc_by_title.get(link) or self.npc_by_title.get(re.sub(r"\s*\(.*\)$", "", link))
            return self._npc_place(rec) if rec else ""
        return ""

    def achievement_zone(self, a):
        """(zone tag, why) when the whole achievement plainly belongs to one place, else ('', None)"""
        inst = self.instance.get(int(a["Instance_ID"] or -1))
        if inst and inst[1] in PLACE_INSTANCES:
            z = self._zone_tag(inst[0])
            if z:
                return z, "instance"
        title, desc = clean(a["Title_lang"]), clean(a["Description_lang"])
        m = re.match(r"^Explore (.+?)$", title) or re.match(r"^Explore (.+?), revealing", desc)
        if m:
            z = self._zone_tag(m.group(1))
            if z:
                return z, "explore"
        m = re.search(r"\bquests? in (?:the )?([A-Z][^.,]+?)\.?$", desc) or re.match(r"^(.+?) Quests$", title)
        if m:
            z = self._zone_tag(m.group(1))
            if z:
                return z, "quests-in-zone"
        return "", None

    def contradicts(self, where, az):
        """a criterion's map that is neither the achievement's own place nor a parent/child of it (a wrong-page match)"""
        a, b = (int(re.search(r"Z\|(\d+);", t).group(1)) for t in (where, az))
        return a != b and not self.maps.is_ancestor(a, b) and not self.maps.is_ancestor(b, a)

    def queue_only(self, a):
        inst = self.instance.get(int(a["Instance_ID"] or -1))
        return bool(inst and inst[1] in QUEUE_INSTANCES)


# What each set may say about redistribution (tools/package_release.py fails a file that says "do not redistribute").
# Achievements and missions are shippable (docs/FINISH_PLAN.md W9: wiki/DB2-generated guides ship); storylines copy step
# lines from Imported_Quests_retail.lua, which carries Questie giver points, names and gates, so they stay local.
PROVENANCE = {
    # no interop names in shippable headers: the packager reads them as derived content
    "achievements": ["-- (wago.tools DB2 exports, facts only) and Warcraft Wiki points: quest steps from Imported_Wiki_<flavor>.lua",
                     "-- (only rows whose point is wiki or Blizzard data) and wiki NPC pages, https://warcraft.wiki.gg, by its contributors,",
                     "-- licensed under CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0/); this data file is shared",
                     "-- under the same licence, see Guides/WIKI_DATA_LICENSE.md."],
    "missions": ["-- (wago.tools DB2 export GarrMission, facts only)."],
    "storylines": ["-- (wago.tools DB2 exports).  Local use only - gitignored, do not redistribute: the step lines come from",
                   "-- Imported_Quests_retail.lua (Questie giver points, names and level gates)."],
}


def header(fl, what):
    return [f"-- AUTO-GENERATED by tools/gen_completion_guides.py ({what}) from Blizzard client data"] + PROVENANCE[what] + [
            "local _, NS = ...", f'if NS.flavor ~= "{fl}" then return end', "local R = NS.Guide.Register"]


def gen_achievements(fl):
    ach = [r for r in rows(fl, "Achievement") if not (int(r["Flags"] or 0) & 0x1)]
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
    achname = {int(r["ID"]): clean(r["Title_lang"]) for r in ach}
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

    guides = collections.defaultdict(list)
    nsteps = 0
    st = collections.Counter()   # step counts by how the location was found
    achs = collections.Counter()  # achievements by best outcome
    gained = collections.Counter()  # zone-level achievements by reason
    nogeo_why = collections.Counter()
    for a in sorted(ach, key=lambda r: (int(r["Category"] or 0), int(r["Ui_order"] or 0), int(r["ID"]))):
        aid = int(a["ID"])
        title = achname[aid] or f"Achievement {aid}"
        fac = {"0": "Horde", "1": "Alliance"}.get(a["Faction"], "")
        ftag = f"FACTION|{fac}|" if fac else ""
        body = []
        az, azwhy = place.achievement_zone(a)
        any_point = any_zone = False
        types = set()
        for leaf in leaves(int(a["Criteria_tree"] or 0)):
            c = crit.get(int(leaf["CriteriaID"]))
            ctid = int(leaf["ID"])
            desc = clean(leaf["Description_lang"])
            ctype = c["Type"] if c else ""
            types.add(ctype)
            asset = int(c["Asset"] or 0) if c else 0
            where, why = "", None
            if ctype == "27" and asset:
                where, why = place.quest_place(asset), "quest"
            elif ctype == "0" and asset:
                where, why = place.creature_place(asset), "creature"
            if not where and ctype != "8":
                where, why = place.wiki_criterion_place(aid, desc), "wiki-criterion"
            if not where and ctype != "8":
                where, why = az, azwhy or "achievement-zone"
            if where and az and place.contradicts(where, az):
                where, why = az, "criterion contradicted achievement place"
                st["contradicted"] += 1
            if ctype == "8" and asset:
                sub = asset
                body.append(f"C {achname.get(sub) or desc or 'Achievement %d' % sub}|ACH|{sub}|{ftag}N|Needed for {lua_str(title)}.|")
                continue
            if where:
                st[("point" if where.startswith("M|") else "zone") + " " + why] += 1
                any_point |= where.startswith("M|")
                any_zone |= not where.startswith("M|")
            if ctype == "27" and asset:
                name = place.quest.get(asset, (None, None))[0] or desc or f"Quest {asset}"
                body.append(f"C {clean(name)}|QID|{asset}|ACH|{aid};{ctid}|{where}{ftag}N|{lua_str(title)}: complete this quest.|")
            else:
                body.append(f"C {desc or title}|ACH|{aid};{ctid}|{where}{ftag}N|{lua_str(title)} criterion.|")
        if az:
            any_zone = True
        nogeo = ""
        if not (any_point or any_zone):
            reason = None
            root = rootcat(int(a["Category"] or 0))
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
            gained[azwhy or "criterion-zone"] += 1
        body.append(f"C {title}|ACH|{aid}|FIXED|{az}{nogeo}{ftag}N|{lua_str(clean(a['Description_lang']))} ({a['Points']} pts)|")
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
    print(f"{fl}: {len(ach)} achievements -> {len(guides)} category guides, {nsteps} steps -> {out.relative_to(ROOT)}")
    print(f"  achievements by best location: {dict(achs)}")
    print(f"  zone-only achievements by reason: {dict(gained)}")
    print(f"  non-geographic by reason: {dict(nogeo_why)}")
    print(f"  located steps: {dict(st)}")


def gen_storylines(qnames):
    ql = {int(r["ID"]): r for r in rows("retail", "QuestLine")}
    members = collections.defaultdict(list)
    for r in rows("retail", "QuestLineXQuest"):
        members[int(r["QuestLineID"])].append((int(r["OrderIndex"] or 0), int(r["QuestID"])))
    qlines = quest_lines("retail")
    lines = header("retail", "storylines")
    ng = nsteps = bare = 0
    for lid in sorted(members):
        qs = [q for _, q in sorted(members[lid])]
        name = clean(ql.get(lid, {}).get("Name_lang")) or f"Storyline {lid}"
        body, prev, zone = [], None, None
        for q in qs:
            src = qlines.get(q)
            nm = qnames.get(q, (None,))[0] or f"Quest {q}"
            if not src:
                bare += 1
                src = [f"A {nm}|QID|{q}|N|No map pin in client data - follow the story.|", f"T {nm}|QID|{q}|"]
            for l in src:
                if prev and l.startswith("A ") and "|PRE|" not in l:
                    l = l.replace(f"|QID|{q}|", f"|QID|{q}|PRE|{prev}|", 1)
                if zone is None:
                    m = re.search(r"\|Z\|(\d+);", l)
                    zone = m.group(1) if m else None
                body.append(l)
            prev = q
        ng += 1
        nsteps += len(body)
        z = f"zone={zone}, " if zone else ""
        lines.append(f'R({{ id="story:retail:{lid}", name="{lua_str(name)}", type="Storylines", {z}'
                     f'author="Blizzard quest-line data", source="CompletionRoute", text=[==[')
        lines.extend(body)
        lines.append("]==] })")
    out = GUIDES / "Imported_Storylines_retail.lua"
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"retail: {ng} storylines, {nsteps} steps ({bare} quests without a pin) -> {out.relative_to(ROOT)}")


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


def main():
    args = [a for a in sys.argv[1:] if a != "--achievements-only"]
    only_ach = len(args) != len(sys.argv) - 1
    fls = args or ["retail", "mop"]
    qn = questie_names() if not only_ach else {}
    for fl in fls:
        gen_achievements(fl)
        if fl == "retail" and not only_ach:
            gen_storylines(qn)
            gen_missions()


if __name__ == "__main__":
    main()
