#!/usr/bin/env python3
# CompletionRoute :: tools/build_verification.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Chart the wiki guides against the client's own data in docs/verification.sqlite (community data only).

    rm -f docs/verification.sqlite
    nice -n 10 python3 tools/wiki/gen_wiki_guides.py     # writes wiki_db2_conflict
    nice -n 10 python3 tools/build_verification.py       # coverage, coverage_steps, wiki_gaps, wiki_vs_db2
    nice -n 10 luajit tools/vplayer.lua <fl> --guides-file F --out docs/vplayer_<fl>.tsv   # one flavor at a time
    python3 tools/collect_vplayer.py                      # vplayer_runs / vplayer_guides / vplayer_stalls
    sqlite3 docs/verification.sqlite .dump > docs/verification.sql

Tables (all rebuilt on every run)
  coverage       flavor, category='quest', label, total (QuestV2 ids), covered, missing, located,
                 wiki_located (a step of the quest carries a Warcraft Wiki point), fallback_located (located only
                 through a fallback point: Blizzard quest POI on retail, Questie on Classic), measured.
                 label before = Imported_Quests_<fl>.lua (pre-wiki generated guides),
                       after  = Imported_Wiki_<fl> + Imported_Quests_<fl>_gaps (what the TOC loads now),
                       wiki   = Imported_Wiki_<fl> alone (the --no-fallback content plus fallback points).
                 Native Guides/Leveling/*.lua are counted in before/after.  Imported_WoWPro_* is never shipped
                 and is not counted.
  coverage_steps flavor, file, steps, wiki_xy, fallback_blizzard, fallback_questie, none
  wiki_gaps      flavor, quest_id, in_old_guides: QuestV2 ids with no Warcraft Wiki quest page
  wiki_vs_db2    flavor, quest_id, field, wiki_value, ref_value, ref_source, yards, page_title
                 field level   - wiki levelreq vs the Blizzard |LVL| gate (retail only; Classic has no client level)
                 field faction - wiki faction vs the reference: retail = the step's explicit |FACTION| tag (untagged
                                 steps make no claim), Classic = the Questie guide's Alliance/Horde/Both split
                 field A_xy/C_xy/T_xy - a WIKI-located step more than 100 yd from the reference step
                 field A_zone/C_zone/T_zone - the two points are on different continents/instances
                 ref_source: blizzard (retail quest POI / DB2) or questie (Classic).  Classic clients ship no
                 quest coordinates or levels in DB2, so on Classic the reference is Questie's database.
Nothing here reads or stores commercial guide data.
"""
import re, sqlite3, sys, collections, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools" / "wiki"))
from wikimaps import MapSet, load_name_aliases  # noqa: E402

G = ROOT / "CompletionRoute" / "Guides"
VERIF = ROOT / "docs" / "verification.sqlite"
WIKI = ROOT / "tools" / "wiki" / "wiki.sqlite"
FLAVORS = ["era", "tbc", "mop", "retail"]
RE_QID = re.compile(r"\|QID\|([\d.^;&]+)")
RE_M = re.compile(r"\|M\|([\d.]+),([\d.]+)")
RE_Z = re.compile(r"\|Z\|(\d+)")
RE_FAC = re.compile(r"\|FACTION\|(\w+)")
RE_LVL = re.compile(r"\|LVL\|(\d+)")
RE_QO = re.compile(r"\|QO\|(\d+)")


def steps(path):
    """yield dict(act, qid, qids, xy, zone, faction, lvl, qo, src) for every step line of a guide file"""
    gfac = None
    with path.open(encoding="utf-8", errors="replace") as f:
        for line in f:
            if line.startswith("R({"):
                m = re.search(r'faction="(\w+)"', line)
                gfac = m.group(1) if m else "Both"
                continue
            if len(line) < 3 or line[1] != " " or "|" not in line:
                continue
            q = RE_QID.search(line)
            qids = []
            if q:
                for part in re.split(r"[\^;&]", q.group(1)):
                    part = part.split(".")[0]
                    if part.isdigit():
                        qids.append(int(part))
            m, z = RE_M.search(line), RE_Z.search(line)
            fac = RE_FAC.search(line)
            lv = RE_LVL.search(line)
            qo = RE_QO.search(line)
            src = "none"
            if m:
                src = ("fallback_blizzard" if "(location: Blizzard data" in line else
                       "fallback_questie" if "(location: Questie data" in line else "wiki")
            yield dict(act=line[0], qid=qids[0] if qids else None, qids=qids,
                       xy=(float(m.group(1)), float(m.group(2))) if m else None,
                       zone=int(z.group(1)) if z else None,
                       faction=fac.group(1) if fac else gfac, faction_tag=fac.group(1) if fac else None, lvl=int(lv.group(1)) if lv else None,
                       qo=int(qo.group(1)) if qo else None, src=src)


def norm_fac(s):
    s = (s or "").strip().lower()
    if s in ("alliance", "horde"):
        return s.capitalize()
    if s in ("both", "neutral", ""):
        return "Both"
    return None  # covenant / Aldor / Scryers: not a faction gate


def main():
    con = sqlite3.connect(VERIF)
    con.executescript("""
    DROP TABLE IF EXISTS coverage; DROP TABLE IF EXISTS coverage_missing; DROP TABLE IF EXISTS coverage_steps;
    DROP TABLE IF EXISTS wiki_gaps; DROP TABLE IF EXISTS wiki_vs_db2;
    CREATE TABLE coverage(flavor text, category text, label text, total int, covered int, missing int, located int,
        wiki_located int, fallback_located int, measured text, primary key(flavor, category, label));
    CREATE TABLE coverage_missing(flavor text, category text, id int);
    CREATE TABLE coverage_steps(flavor text, file text, steps int, wiki_xy int, fallback_blizzard int,
        fallback_questie int, none int, primary key(flavor, file));
    CREATE TABLE wiki_gaps(flavor text, quest_id int, in_old_guides int, primary key(flavor, quest_id));
    CREATE TABLE wiki_vs_db2(flavor text, quest_id int, field text, wiki_value text, ref_value text,
        ref_source text, yards real, page_title text);
    """)
    wk = sqlite3.connect(WIKI)
    al = load_name_aliases()
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    for fl in FLAVORS:
        universe = {int(l.split(",")[0]) for l in (ROOT / "tools" / "db2" / fl / "QuestV2.csv").read_text().splitlines()[1:] if l}
        native = sorted((G / "Leveling").glob("*.lua"))
        files = {"wiki": [G / f"Imported_Wiki_{fl}.lua"],
                 "after": [G / f"Imported_Wiki_{fl}.lua", G / f"Imported_Quests_{fl}_gaps.lua"] + native,
                 "before": [G / f"Imported_Quests_{fl}.lua"] + native}
        parsed = {}
        for p in set(sum(files.values(), [])):
            parsed[p] = list(steps(p)) if p.exists() else []
        # per-file step source split (generated files only)
        for p in (G / f"Imported_Wiki_{fl}.lua", G / f"Imported_Quests_{fl}_gaps.lua", G / f"Imported_Quests_{fl}.lua"):
            c = collections.Counter(s["src"] for s in parsed.get(p, []))
            if p.name.startswith("Imported_Quests") and p in parsed:
                ref = "fallback_blizzard" if fl == "retail" else "fallback_questie"
                c = collections.Counter({ref if k != "none" else k: v for k, v in c.items()})
            con.execute("insert into coverage_steps values (?,?,?,?,?,?,?)",
                        (fl, p.name, sum(c.values()), c["wiki"], c["fallback_blizzard"], c["fallback_questie"], c["none"]))
        for label, fs in files.items():
            have = {}
            for p in fs:
                old = p.name.startswith("Imported_Quests") or p.parent.name == "Leveling"
                for s in parsed[p]:
                    for q in s["qids"]:
                        h = have.setdefault(q, [False, False])
                        if s["xy"]:
                            if s["src"] == "wiki" and not old:
                                h[0] = True
                            else:
                                h[1] = True
            cov = [q for q in universe if q in have]
            loc = [q for q in cov if have[q][0] or have[q][1]]
            wl = [q for q in cov if have[q][0]]
            fb = [q for q in cov if not have[q][0] and have[q][1]]
            con.execute("insert into coverage values (?,?,?,?,?,?,?,?,?,?)",
                        (fl, "quest", label, len(universe), len(cov), len(universe) - len(cov), len(loc), len(wl), len(fb), now))
            if label == "after":
                con.executemany("insert into coverage_missing values (?,?,?)",
                                [(fl, "quest", q) for q in sorted(universe - set(cov))])
            print(f"{fl:6} {label:6} total {len(universe):6} covered {len(cov):6} located {len(loc):6} "
                  f"wiki {len(wl):6} fallback-only {len(fb):6}")
        # wiki gaps
        con.executemany("insert into wiki_gaps values (?,?,?)",
                        wk.execute("select flavor, quest_id, in_old_guides from flavor_gap where flavor=?", (fl,)).fetchall())
        # wiki vs client/reference data
        ms = MapSet(fl, al)
        ref_src = "blizzard" if fl == "retail" else "questie"
        old = collections.defaultdict(list)
        for s in parsed[G / f"Imported_Quests_{fl}.lua"]:
            if s["qid"] is not None:
                old[s["qid"]].append(s)
        pages = dict(wk.execute("select quest_id, page_title from flavor_quests where flavor=?", (fl,)).fetchall())
        rows = []
        allq = {(t, i): (f, l) for t, i, f, l in wk.execute("select page_title, id, faction, levelreq from quests")}
        qinfo = {qid: allq[(pt, qid)] for qid, pt in pages.items() if (pt, qid) in allq}
        for qid, (wfac, wlvl) in qinfo.items():
            o = old.get(qid)
            if not o:
                continue
            wf = norm_fac(wfac)
            # retail: only an explicit |FACTION| tag is a claim (an untagged Blizzard-POI step is "unknown", not
            # "both"); Classic: the Questie guide's own faction split (Alliance / Horde / Both) is the claim
            ofs = ({norm_fac(s["faction_tag"]) for s in o if s["faction_tag"]} if fl == "retail"
                   else {norm_fac(s["faction"]) for s in o})
            of = ofs.pop() if len(ofs) == 1 else None
            if wf and of and wf != of:
                rows.append((fl, qid, "faction", wf, of, ref_src, None, pages[qid]))
            if fl == "retail":
                ol = next((s["lvl"] for s in o if s["lvl"]), None)
                if wlvl and ol and int(wlvl) != ol:
                    rows.append((fl, qid, "level", str(wlvl), str(ol), "blizzard", None, pages[qid]))
        seen = set()
        for s in parsed[G / f"Imported_Wiki_{fl}.lua"]:
            if s["src"] != "wiki" or s["qid"] is None or s["act"] not in "ACT":
                continue
            key = (s["qid"], s["act"], s["qo"])
            if key in seen:
                continue
            seen.add(key)
            cands = [x for x in old.get(s["qid"], []) if x["act"] == s["act"] and x["xy"]]
            if s["act"] == "C" and s["qo"] is not None:
                cands = [x for x in cands if x["qo"] in (None, s["qo"])] or cands
            if not cands:
                continue
            a = ms.to_world(s["zone"], *s["xy"])
            best = None
            for x in cands:
                b = ms.to_world(x["zone"], *x["xy"])
                if a and b and a[0] == b[0]:
                    d = ((a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2) ** 0.5
                    best = d if best is None else min(best, d)
            wv = f"{s['zone']}:{s['xy'][0]},{s['xy'][1]}"
            rv = f"{cands[0]['zone']}:{cands[0]['xy'][0]},{cands[0]['xy'][1]}"
            if best is None:
                rows.append((fl, s["qid"], s["act"] + "_zone", wv, rv, ref_src, None, pages.get(s["qid"])))
            elif best > 100:
                rows.append((fl, s["qid"], s["act"] + "_xy", wv, rv, ref_src, round(best), pages.get(s["qid"])))
        con.executemany("insert into wiki_vs_db2 values (?,?,?,?,?,?,?,?)", rows)
        c = collections.Counter(r[2] for r in rows)
        print(f"{fl:6} wiki_vs_db2 {dict(sorted(c.items()))}")
    con.commit()


if __name__ == "__main__":
    main()
