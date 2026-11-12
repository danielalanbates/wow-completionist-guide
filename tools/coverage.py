#!/usr/bin/env python3
# CompletionRoute :: tools/coverage.py
# Copyright (c) 2026 Daniel Bates / BatesAI. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Measure guide coverage per flavor against the client's own lists and chart it in SQL.

    python3 tools/coverage.py [--label L] [--guides DIR] [--db PATH]

Universe (the "total" column), per flavor, from wago.tools DB2 exports cached in tools/db2/<flavor>/:
  quest        QuestV2.csv                       every quest id the client knows (incl. hidden trackers)
  quest-zone                                     of the covered quests without a point: those with a step that names
                                                 the zone (|Z| without |M|; the router goes to the zone).  Covered
                                                 quests = located (point) + quest-zone + no location at all
  achievement  Achievement.csv minus statistics  (Flags & 0x1 = counter/statistic, not an achievement) and minus
               internal rows (title marked DNT, <Hidden>, Hidden Tracking...: gen_completion_guides.internal_achievement)
  storyline    QuestLine x QuestLineXQuest       retail only; covered = every quest of the line is in a guide
  storyline-quest                                the quests of those lines, one row each (covered / located)
  mission      GarrMission.csv                   retail only; covered = a guide step carries |MISSION|id|
  item-quest   ItemSparse.csv StartQuestID       quests an item starts (Blizzard data), in the client's QuestV2.
               covered = the quest is in a guide; located = its accept step (where the item is obtained) has a point
"covered" = the id appears in a guide the flavor's client loads.  "located" = at least one of those steps
has map coordinates, i.e. the router can actually take you there.  Both are reported because an id in a
guide with no location is a checklist line, not a route.  Missions are started from a table, not a place, so their
located column is NULL (non-geographic), never a failure.  Statistics are not in the achievement universe at all.
Achievements also report extra categories, kept apart from located (point only, comparable across runs):
  achievement-zone      no point, but a step names the zone or instance (|Z| without |M|): routes to the zone, no coordinate
  achievement-nongeo    carries |NOGEO|<reason|> (battleground, PvP total, reputation count, level milestone...): no place at all
  achievement-internal  total = internal rows left out of the universe; covered = how many a guide still lists
  The located share the plan's 80% target means: (point + zone-only) / (total - non-geographic).
  item-quest-zone       the accept step names only a zone (|Z| without |M|)
Table `coverage_ach_types` breaks the achievement criteria down by Blizzard Criteria.Type (point / zone / none).
Table `item_quests` lists every item-started quest of the latest run: item, covered, how its accept step is located,
and the wiki's reason when a quest is in no guide (tools/wiki/wiki.sqlite flavor_skip).

There is one build: the guides measured are the ones the six TOCs load (Warcraft Wiki, Blizzard and own data), read
from CompletionRoute/Guides.  A file there that credits a point to another addon's data ("(location: Questie data)" /
"(location: Blizzard data)", the dev build retired on 2026-11-11) is not part of the build and stops the run.
--shippable (the old name of this mode) is accepted and ignored.  --guides DIR measures another folder as it is (for
example tools/measure/out, the offline comparison: pass --db too, so the project's chart keeps only the build).

Also folds docs/vplayer_<fl>_noroute.tsv into table `noroute_class`: a step the router could not reach is
"battleground" (a queue, no travel edge exists by design), "instance" (an instance map: the guide walks you in, or the
player has not learned its door yet), or "routable" (two open-world maps: a real gap in the travel graph).

Writes tables `coverage` (flavor, category, label, total, covered, missing, located) and `coverage_missing`
(flavor, category, id) into docs/verification.sqlite; `coverage_missing` holds the latest run only.
"""
import csv, re, sqlite3, sys, collections
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DB2 = ROOT / "tools" / "db2"
WIKI_DB = ROOT / "tools" / "wiki" / "wiki.sqlite"
FLAVORS = ["era", "tbc", "mop", "retail", "forever"]
sys.path.insert(0, str(ROOT / "tools"))
csv.field_size_limit(1 << 28)
from gen_completion_guides import internal_achievement, STORY_FILE  # noqa: E402


# what each client loads (its TOC; tools/package_release.py RULES): the wiki quest guides, gold, professions,
# achievements, quest lines, missions and the hand-written guides.  The spine reuses the wiki guides' text.
def guide_files(gdir, fl):
    names = [f"Imported_Wiki_{fl}.lua", f"Imported_Gold_{fl}.lua", f"Imported_Professions_{fl}.lua",
             f"Imported_Achievements_{fl}.lua", STORY_FILE.format(fl=fl), f"Imported_Missions_{fl}.lua"]
    out = [gdir / n for n in names if (gdir / n).exists()]
    return out + sorted((gdir / "Leveling").glob("*.lua"))

RE_QID = re.compile(r"\|QID\|([\d.^;&]+)")
RE_ACH = re.compile(r"\|ACH\|(\d+)")
RE_ACH_CRIT = re.compile(r"\|ACH\|(\d+);(\d+)\|")
# a meta achievement's part line ("C <part>|ACH|<part>|...|N|Needed for <meta>.|") ticks from the part's own id but is a
# step of the meta's block, which ends with the meta's FIXED "earn it" line (tools/gen_completion_guides.py)
RE_ACH_PART = re.compile(r"\|ACH\|\d+\|(?!FIXED\|)")
RE_ACH_FIXED = re.compile(r"\|ACH\|(\d+)\|FIXED\|")
RE_MIS = re.compile(r"\|MISSION\|(\d+)")
# a point taken from another addon's data: never in the build (the dev build retired on 2026-11-11, or the offline
# comparison file of tools/wiki/gen_wiki_guides.py --measure-fallback)
FALLBACK_NOTE = ("(location: Questie data", "(location: Blizzard data")
# a storyline accept that only names the quest's map (tools/gen_completion_guides.py gen_questlines) says nothing about
# where a starting item is obtained: it does not count as a located accept for item-quest
QUEST_MAP_NOTE = "the quest's map"
KINDS = ("quest", "quest-zone", "achievement", "mission", "achievement-zone", "achievement-nongeo", "accept", "ach-crit")
RANK = {"none": 0, "zone": 1, "point": 2}


def scan(path, build=False):
    """-> dict kind -> {id: located_bool}; "quest-zone" -> {qid: True} for a quest with a zone-only step; "accept" ->
    {qid: point|zone|none} of A steps, "ach-crit" -> {ct: (ach, how)}.  build=True: the file is part of the build, so
    a step that credits another addon's data stops the run"""
    found = {k: {} for k in KINDS}
    txt = path.read_text(encoding="utf-8", errors="replace")
    if build and any(n in txt for n in FALLBACK_NOTE):
        raise SystemExit(f"coverage: {path.name} credits points to another addon's data (the dev build retired on "
                         "2026-11-11): it is not part of the build. Regenerate it (tools/wiki/gen_wiki_guides.py, then "
                         "tools/gen_completion_guides.py), or pass --guides DIR to measure another folder as it is.")
    part_loc = part_zone = False   # meta part lines seen since the last FIXED line
    for line in txt.splitlines():
        if "|" not in line:
            continue
        if line.startswith("R({"):
            part_loc = part_zone = False
        loc = "|M|" in line
        zone = "|Z|" in line
        how = "point" if loc else ("zone" if zone else "none")
        for m in RE_QID.findall(line):
            for part in re.split(r"[\^;&]", m):
                part = part.split(".")[0]
                if part.isdigit():
                    q = int(part)
                    found["quest"][q] = found["quest"].get(q, False) or loc
                    if zone and not loc:
                        found["quest-zone"][q] = True
                    if line.startswith(("A ", "a ")):
                        prev = found["accept"].get(q, "none")
                        h = "none" if QUEST_MAP_NOTE in line and not loc else how
                        found["accept"][q] = h if RANK[h] > RANK[prev] else prev
        for a in RE_ACH.findall(line):
            found["achievement"][int(a)] = found["achievement"].get(int(a), False) or loc
            if zone and not loc:
                found["achievement-zone"][int(a)] = True
            if "|NOGEO|" in line:
                found["achievement-nongeo"][int(a)] = True
        if RE_ACH_PART.search(line) and "|QID|" not in line:
            part_loc, part_zone = part_loc or loc, part_zone or (zone and not loc)
        fx = RE_ACH_FIXED.search(line)
        if fx:
            a = int(fx.group(1))
            found["achievement"][a] = found["achievement"].get(a, False) or part_loc
            if part_zone and not part_loc:
                found["achievement-zone"][a] = True
            part_loc = part_zone = False
        for a, ct in RE_ACH_CRIT.findall(line):
            found["ach-crit"][int(ct)] = (int(a), how)
        for a in RE_MIS.findall(line):
            found["mission"][int(a)] = found["mission"].get(int(a), False) or loc
    return found


def read_csv(fl, table):
    p = DB2 / fl / f"{table}.csv"
    if not p.exists():
        return None
    return list(csv.DictReader(p.open(encoding="utf-8")))


def item_starters(fl, quests=None):
    """quest id -> [(item id, item name)] from Blizzard ItemSparse.StartQuestID, limited to the client's QuestV2"""
    rows = read_csv(fl, "ItemSparse")
    out = collections.defaultdict(list)
    for r in rows or []:
        q = int(r.get("StartQuestID") or 0)
        if q and (quests is None or q in quests):
            out[q].append((int(r["ID"]), r.get("Display_lang") or ""))
    return dict(out)


def universes(fl):
    u = {}
    q = read_csv(fl, "QuestV2")
    if q is not None:
        u["quest"] = {int(r["ID"]) for r in q}
    a = read_csv(fl, "Achievement")
    if a is not None:
        u["achievement"] = {int(r["ID"]) for r in a if not (int(r["Flags"] or 0) & 0x1) and not internal_achievement(r)}
        u["achievement-internal"] = {int(r["ID"]) for r in a if not (int(r["Flags"] or 0) & 0x1) and internal_achievement(r)}
    if fl == "retail":
        m = read_csv(fl, "GarrMission")
        if m is not None:
            u["mission"] = {int(r["ID"]) for r in m}
        qlx = read_csv(fl, "QuestLineXQuest")
        if qlx is not None:
            lines = collections.defaultdict(set)
            for r in qlx:
                lines[int(r["QuestLineID"])].add(int(r["QuestID"]))
            u["storyline"] = dict(lines)
            u["storyline-quest"] = set().union(*lines.values()) if lines else set()
    if "quest" in u:
        st = item_starters(fl, u["quest"])
        if st:
            u["item-quest"] = set(st)
    return u


def crit_types(fl):
    """criteria-tree id -> Blizzard Criteria.Type"""
    tree, crit = read_csv(fl, "CriteriaTree"), read_csv(fl, "Criteria")
    if not tree or not crit:
        return {}
    ty = {int(r["ID"]): r["Type"] for r in crit}
    return {int(r["ID"]): ty.get(int(r["CriteriaID"] or 0), "?") for r in tree}


def wiki_skip(fl):
    """quest id -> why the wiki pipeline left it out of this client (tools/wiki/wiki.sqlite flavor_skip)"""
    if not WIKI_DB.exists():
        return {}
    con = sqlite3.connect(f"file:{WIKI_DB}?mode=ro", uri=True)
    try:
        return {q: r for q, r in con.execute("select quest_id, reason from flavor_skip where flavor = ?", (fl,))}
    except sqlite3.Error:
        return {}
    finally:
        con.close()


NON_GEOGRAPHIC = {"mission"}
BATTLEGROUNDS = {"alteracvalley", "warsonggulch", "arathibasin", "eyeofthestorm", "strandoftheancients", "isleofconquest",
                 "twinpeaks", "thebattleforgilneas", "templeofkotmogu", "silvershardmines", "deepwindgorge"}


def classify_noroute(con, verbose=True):
    sys.path.insert(0, str(ROOT / "tools" / "wiki"))
    import wikimaps
    con.execute("create table if not exists noroute_class (flavor text, kind text, steps int, measured text, primary key (flavor, kind))")
    for fl in FLAVORS:
        p = ROOT / "docs" / f"vplayer_{fl}_noroute.tsv"
        if not p.exists():
            continue
        maps = wikimaps.load_maps(fl)
        counts = collections.Counter()
        for r in csv.DictReader(p.open(encoding="utf-8"), delimiter="\t"):
            ends = [maps.get(int(v)) for v in (r["from_map"], r["to_map"]) if v.isdigit()]
            if any(m and re.sub(r"[^0-9a-z]", "", m["name"].lower()) in BATTLEGROUNDS for m in ends):
                counts["battleground"] += 1
            elif any(m and m["type"] in (4, 5, 6) for m in ends):
                counts["instance"] += 1
            else:
                counts["routable"] += 1
        con.execute("delete from noroute_class where flavor = ?", (fl,))
        con.executemany("insert into noroute_class values (?,?,?,datetime('now'))", [(fl, k, v) for k, v in counts.items()])
        if verbose:
            print(f"no_route {fl:7} " + "  ".join(f"{k} {counts[k]}" for k in ("battleground", "instance", "routable")))


def put(con, fl, cat, label, total, covered, located):
    con.execute("insert or replace into coverage (flavor, category, label, total, covered, missing, located, measured) "
                "values (?,?,?,?,?,?,?,datetime('now'))", (fl, cat, label, total, covered, total - covered, located))


def main():
    label = "current"
    gdir = ROOT / "CompletionRoute" / "Guides"
    db = ROOT / "docs" / "verification.sqlite"
    args = sys.argv[1:]
    if "--label" in args:
        label = args[args.index("--label") + 1]
    if "--guides" in args:
        gdir = Path(args[args.index("--guides") + 1])
    if "--db" in args:
        db = Path(args[args.index("--db") + 1])
    build = "--guides" not in args      # the build's own folder: a file that is not part of the build stops the run
    print(f"guides {gdir} ({'the build: what the TOCs load' if build else 'another folder, measured as it is'})")
    con = sqlite3.connect(db)
    con.execute("""create table if not exists coverage (flavor text, category text, label text, total int,
                   covered int, missing int, located int, measured text, primary key (flavor, category, label))""")
    con.execute("create table if not exists coverage_missing (flavor text, category text, id int)")
    con.execute("""create table if not exists coverage_ach_types (flavor text, label text, ctype text, total int, point int,
                   zone int, none int, measured text, primary key (flavor, label, ctype))""")
    con.execute("""create table if not exists item_quests (flavor text, label text, quest_id int, item_id int, item_name text,
                   covered int, accept text, skip_reason text, primary key (flavor, label, quest_id))""")
    con.execute("delete from coverage_missing")
    for fl in FLAVORS:
        have = {k: {} for k in KINDS}
        for f in guide_files(gdir, fl):
            for k, d in scan(f, build).items():
                for i, loc in d.items():
                    if k == "accept":
                        prev = have[k].get(i, "none")
                        have[k][i] = loc if RANK[loc] > RANK[prev] else prev
                    elif k == "ach-crit":
                        have[k][i] = loc
                    else:
                        have[k][i] = have[k].get(i, False) or loc
        uni_all = universes(fl)
        for cat, uni in uni_all.items():
            if cat == "achievement-internal":
                put(con, fl, cat, label, len(uni), sum(1 for i in uni if i in have["achievement"]), None)
                continue
            if cat == "storyline":
                total = len(uni)
                cov = [l for l, qs in uni.items() if qs and all(q in have["quest"] for q in qs)]
                loc = [l for l in cov if all(have["quest"][q] for q in uni[l])]
                miss = sorted(set(uni) - set(cov))
            elif cat == "item-quest":
                total = len(uni)
                cov = [i for i in uni if i in have["quest"]]
                loc = [i for i in cov if have["accept"].get(i) == "point"]
                zone = [i for i in cov if have["accept"].get(i) == "zone"]
                miss = sorted(uni - set(cov))
            else:
                key = "quest" if cat in ("storyline-quest",) else cat
                total = len(uni)
                cov = [i for i in uni if i in have[key]]
                loc = [i for i in cov if have[key][i]]
                miss = sorted(uni - set(cov))
            geo = cat not in NON_GEOGRAPHIC
            put(con, fl, cat, label, total, len(cov), len(loc) if geo else None)
            con.executemany("insert into coverage_missing values (?,?,?)", [(fl, cat, i) for i in miss])
            if cat == "quest":
                qzone = sum(1 for i in cov if not have["quest"][i] and have["quest-zone"].get(i))
                put(con, fl, "quest-zone", label, total, qzone, None)
                print(f"{label:7} {fl:6} {'quest':11} covered {len(cov):6}: point {len(loc):6} ({100*len(loc)/max(len(cov),1):5.1f}%)"
                      f"  zone-only {qzone:6} ({100*qzone/max(len(cov),1):5.1f}%)  no location {len(cov) - len(loc) - qzone:6}"
                      f" ({100*(len(cov) - len(loc) - qzone)/max(len(cov),1):5.1f}%)")
            if cat == "achievement":
                zone_n = sum(1 for i in have["achievement-zone"] if i in uni and not have["achievement"].get(i))
                nongeo = sum(1 for i in have["achievement-nongeo"] if i in uni and not have["achievement"].get(i)
                             and i not in have["achievement-zone"])
                for extra, n in (("achievement-zone", zone_n), ("achievement-nongeo", nongeo)):
                    put(con, fl, extra, label, total, n, None)
                geo_total = total - nongeo
                print(f"{label:7} {fl:6} {'achievement':11} point {len(loc):6}  zone-only {zone_n:6}  non-geographic {nongeo:6}"
                      f"  neither {total - len(loc) - zone_n - nongeo:6}  (of {total}; internal left out "
                      f"{len(uni_all.get('achievement-internal', ()))})  located share (point+zone)/(total-nongeo) "
                      f"{100 * (len(loc) + zone_n) / max(geo_total, 1):5.1f}%")
                types = crit_types(fl)
                by = collections.defaultdict(collections.Counter)
                for ct, (a, how) in have["ach-crit"].items():
                    if a in uni:
                        by[types.get(ct, "?")][how] += 1
                con.execute("delete from coverage_ach_types where flavor = ? and label = ?", (fl, label))
                con.executemany("insert into coverage_ach_types values (?,?,?,?,?,?,?,datetime('now'))",
                                [(fl, label, t, sum(c.values()), c["point"], c["zone"], c["none"]) for t, c in by.items()])
            if cat == "item-quest":
                put(con, fl, "item-quest-zone", label, total, len(zone), None)
                starters = item_starters(fl, uni)
                skip = wiki_skip(fl)
                con.execute("delete from item_quests where flavor = ? and label = ?", (fl, label))
                con.executemany("insert into item_quests values (?,?,?,?,?,?,?,?)",
                                [(fl, label, q, starters[q][0][0], starters[q][0][1], int(q in have["quest"]),
                                  have["accept"].get(q, "none") if q in have["quest"] else None,
                                  None if q in have["quest"] else skip.get(q, "no wiki page")) for q in sorted(uni)])
                print(f"{label:7} {fl:6} {'item-quest':11} total {total:6}  covered {len(cov):6}  accept step: point {len(loc):6}"
                      f"  zone-only {len(zone):6}  none {len(cov) - len(loc) - len(zone):6}")
                continue
            print(f"{label:7} {fl:6} {cat:11} total {total:6}  covered {len(cov):6} ({100*len(cov)/max(total,1):5.1f}%)"
                  f"  located {len(loc) if geo else 'non-geographic':>6}")
    classify_noroute(con)
    con.commit()


if __name__ == "__main__":
    main()
