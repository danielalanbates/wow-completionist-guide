#!/usr/bin/env python3
# CompletionRoute :: tools/wiki/fetch_coord_history.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Which wiki coordinates were written on the Classic map: the page revision before patch 4.0.3.

    nice -n 10 python3 tools/wiki/fetch_coord_history.py [--zone "Blasted Lands" ...] [--changed-zones] [--max-requests N]
    nice -n 10 python3 tools/wiki/fetch_coord_history.py --recover [--max-requests N] [--recheck]

Patch 4.0.3 (2010-11-23) redrew the zone maps.  Warcraft Wiki is retail-first and its coordinates are read as retail-map
numbers, but a page whose coordinate already stood, number for number, in its last revision before that date was
measured on the Classic map and never re-measured.  Read as a retail number it lands several map units off on the
Classic clients (Blasted Lands: 5.5 units, docs/STATUS.md 2026-11-11).  Pages whose numbers changed after 4.0.3, or
that had no coordinate then, are retail numbers and keep the normal conversion.

For every NPC / object / place page with a coordinate in the chosen zones (default: Blasted Lands; --changed-zones =
every zone whose Classic and retail maps differ, tools/maps_era.lua against tools/maps_retail.lua) this asks the
MediaWiki API for the last revision before 4.0.3 (one request per page, through wiki_fetch: cached forever, >= 1.2 s
apart) and writes one row per current coordinate into tools/wiki/cache/coord_history.sqlite (gitignored, kept when
parse_wiki.py rebuilds wiki.sqlite):

    coord_history(title, zone, x, y, pre_cata, pre_revid, pre_time, checked)
        pre_cata = 1  the same zone and numbers (to 0.1) are on the page's pre-4.0.3 revision: Classic-map numbers
        pre_cata = 0  they are not (re-measured or added later): retail numbers

tools/wiki/gen_wiki_guides.py and gen_professions.py read the pre_cata = 1 rows as "(Classic)" points
(wikimaps.history_marks).  Source: Warcraft Wiki page histories (CC BY-SA 4.0); nothing else is read.

--recover (2026-11-25, branch classic-history-points): many pages were rewritten for Cataclysm or later and lost the
coordinate they had on the Classic map, so the Classic clients (Era, TBC Anniversary, WoW Forever) got only a
zone-level step.  This mode takes every NPC / object page that a Classic quest names (giver, ender, objective target;
tools/wiki/wiki.sqlite flavor_quests) and that has no Classic-usable point today (no coordinate at all, or only
retail-map ones), reads the same last revision before 4.0.3 and keeps the coordinates on it ({{Coords}}/{{co}} in the
infobox, {{Npclocations}}, lead or body, plus {{Zone Map Note}} spawn blips inside {{Zone Map|zone=...}}):

    history_points(title, zone, x, y, source, revid, rev_time, checked)   Classic-map numbers recovered from revid
    history_pages(title, revid, rev_time, points, checked)               every page asked (points may be 0)

The current coordinates on those pages are also checked as above (coord_history), so one request serves both.
gen_wiki_guides.py adds history_points as "(Classic)" rows (wikimaps.history_points) and notes the step
"(location: wiki revision <revid>)".  MoP Classic and Retail use the Cataclysm-and-later maps and ignore them.
"""
import argparse
import datetime
import re
import sqlite3
import sys
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import wiki_fetch as W  # noqa: E402
import wikimaps  # noqa: E402
import wikitext as WT  # noqa: E402

WIKI = HERE / "wiki.sqlite"
OUT = wikimaps.HISTORY_DB
REDRAW = "2010-11-23T00:00:00Z"     # patch 4.0.3a, the Cataclysm world: every zone map redrawn


def changed_zones():
    """zone names whose Classic (era) and retail map rectangles differ by more than 1 yard on any edge"""
    era, ret = wikimaps.load_maps("era"), wikimaps.load_maps("retail")
    by_name = {}
    for mid, m in ret.items():
        if m["type"] == 3 and isinstance(m["w"], float):
            by_name.setdefault(wikimaps.norm(m["name"]), m)
    out = []
    for mid, m in era.items():
        r = by_name.get(wikimaps.norm(m["name"]))
        if m["type"] == 3 and r and isinstance(m["w"], float) and r["inst"] == m["inst"]:
            if max(abs(m[k] - r[k]) for k in ("topX", "leftY", "w", "h")) > 1.0:
                out.append(m["name"])
    return sorted(set(out))


def pre_cata_points(title):
    """(revid, timestamp, {(zone norm, x, y)}) of the last revision before 4.0.3, or (None, None, set())"""
    d = W.api(action="query", prop="revisions", titles=title, rvlimit=1, rvstart=REDRAW, rvdir="older",
              rvprop="content|timestamp|ids", rvslots="main", redirects=1)
    pages = d.get("query", {}).get("pages", [])
    revs = pages[0].get("revisions") if pages else None
    if not revs:
        return None, None, set()
    txt = revs[0].get("slots", {}).get("main", {}).get("content", "") or ""
    pts = {(wikimaps.norm(wikimaps.base_zone(z)), round(x, 1), round(y, 1)) for x, y, z, *_ in WT.coords(txt)}
    return revs[0].get("revid"), revs[0].get("timestamp"), pts


RE_ZONEMAP = re.compile(r"zone ?map", re.I)
RE_ZMN = re.compile(r"zone ?map ?note", re.I)
MAX_BLIPS = 12          # spawn blips kept per page (a mob page lists dozens; the guide uses at most a few)


def old_points(title, text):
    """[(zone, x, y, source)] on one old revision: the parse_wiki.npc_points rows (zone as written) plus Zone Map
    Note blips, which carry no zone themselves and take their {{Zone Map|zone=...}}"""
    import parse_wiki as P
    out = [(z, x, y, src) for z, x, y, src, _b, _c in P.npc_points(title, text, WT.sections(text), 0)[0] if z]
    seen = {(wikimaps.norm(z), x, y) for z, x, y, _ in out}
    blips = 0
    for _s, _e, _n, inner in WT.find_templates(text, RE_ZONEMAP):
        _pos, named = WT.split_params(inner)
        zone = WT.plain(named.get("zone", "")).strip()
        if not zone:
            continue
        for _s2, _e2, _n2, note in WT.find_templates(inner, RE_ZMN):
            pos, _nm = WT.split_params(note)
            try:
                x, y = float(pos[0].replace(",", ".")), float(pos[1].replace(",", "."))
            except (IndexError, ValueError):
                continue
            k = (wikimaps.norm(zone), x, y)
            if 0 <= x <= 100 and 0 <= y <= 100 and k not in seen and blips < MAX_BLIPS:
                seen.add(k)
                blips += 1
                out.append((zone, x, y, "zonemap"))
    return out


def old_revision(title):
    """(revid, timestamp, text) of the last revision before 4.0.3, or (None, None, '')"""
    d = W.api(action="query", prop="revisions", titles=title, rvlimit=1, rvstart=REDRAW, rvdir="older",
              rvprop="content|timestamp|ids", rvslots="main", redirects=1)
    pages = d.get("query", {}).get("pages", [])
    revs = pages[0].get("revisions") if pages else None
    if not revs:
        return None, None, ""
    return revs[0].get("revid"), revs[0].get("timestamp"), revs[0].get("slots", {}).get("main", {}).get("content", "") or ""


def recover_candidates(src, flavors=("era", "tbc", "forever")):
    """NPC / object pages a Classic quest names that have no Classic-usable point today: {page: has_any_point}"""
    tit = {t: (p, k) for t, p, k in src.execute("select title, page_title, kind from titles")}
    kinds = {t: k for t, k in src.execute("select title, kind from npcs")}
    pts = {}
    for t, c in src.execute("select title, classic from npc_coords where x is not null"):
        pts[t] = pts.get(t, 0) or c
    marks = wikimaps.history_marks()
    marked = {m[0] for m in marks}
    ref = set()
    for fl in flavors:
        for s, e in src.execute("select q.start_npc, q.end_npc from flavor_quests f join quests q on q.id = f.quest_id "
                                "and q.page_title = f.page_title where f.flavor = ?", (fl,)):
            ref.update(n for n in (s, e) if n)
        ref.update(t for (t,) in src.execute("select o.target_title from flavor_quests f join quest_objectives o on "
                                             "o.quest_id = f.quest_id and o.page_title = f.page_title where f.flavor = ? "
                                             "and o.target_title <> ''", (fl,)))
    out = {}
    for n in ref:
        p, k = tit.get(n, (n, None))
        if (kinds.get(p) or k) in ("npc", "object") and not pts.get(p) and p not in marked:
            out[p] = p in pts
    return out


def recover(a):
    src = sqlite3.connect(f"file:{WIKI}?mode=ro", uri=True)
    cand = recover_candidates(src)
    cur = defaultdict(list)
    for t, z, x, y, c in src.execute("select title, zone, x, y, classic from npc_coords where x is not null"):
        if t in cand:
            cur[t].append((z, x, y))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(OUT)
    db.execute("create table if not exists coord_history(title text, zone text, x real, y real, pre_cata int, "
               "pre_revid int, pre_time text, checked text, primary key (title, zone, x, y))")
    db.execute("create table if not exists history_points(title text, zone text, x real, y real, source text, "
               "revid int, rev_time text, checked text, primary key (title, zone, x, y))")
    db.execute("create table if not exists history_pages(title text primary key, revid int, rev_time text, "
               "points int, checked text)")
    done = {t for (t,) in db.execute("select title from history_pages")} if not a.recheck else set()
    todo = sorted(t for t in cand if t not in done)
    print(f"{len(cand)} candidate pages ({sum(cand.values())} with retail-map points only), {len(todo)} to ask",
          flush=True)
    now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    n = got = 0
    for t in todo:
        if a.max_requests is not None and n >= a.max_requests:
            print("stopped at --max-requests; re-run to continue (answers are cached)")
            break
        revid, ts, text = old_revision(t)
        n += 1
        pts = old_points(t, text) if text else []
        have = {(wikimaps.norm(wikimaps.base_zone(z)), round(x, 1), round(y, 1)) for z, x, y, _ in pts}
        for z, x, y in cur.get(t, []):
            hit = (wikimaps.norm(wikimaps.base_zone(z)), round(x, 1), round(y, 1)) in have
            db.execute("insert or replace into coord_history values (?,?,?,?,?,?,?,?)",
                       (t, z, x, y, int(hit), revid, ts, now))
        db.execute("delete from history_points where title = ?", (t,))
        for z, x, y, s in pts:
            db.execute("insert or replace into history_points values (?,?,?,?,?,?,?,?)", (t, z, x, y, s, revid, ts, now))
        db.execute("insert or replace into history_pages values (?,?,?,?,?)", (t, revid, ts, len(pts), now))
        got += bool(pts)
        if n % 50 == 0:
            db.commit()
            print(f"  {n}/{len(todo)} pages, {got} with old points", flush=True)
    db.commit()
    tot = db.execute("select count(distinct title), count(*) from history_points").fetchone()
    print(f"{n} pages asked, {got} with points on the pre-4.0.3 revision; table holds {tot[0]} pages / {tot[1]} "
          f"points -> {OUT}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zone", action="append", default=None, help="zone name (repeatable; default Blasted Lands)")
    ap.add_argument("--changed-zones", action="store_true", help="every zone whose Classic and retail maps differ")
    ap.add_argument("--max-requests", type=int, default=None)
    ap.add_argument("--recover", action="store_true", help="recover pre-4.0.3 points for Classic quest pages that "
                    "have none today (history_points)")
    ap.add_argument("--recheck", action="store_true", help="--recover: ask pages already in history_pages again "
                    "(answers still come from the cache)")
    a = ap.parse_args()
    if a.recover:
        return recover(a)
    zones = changed_zones() if a.changed_zones else (a.zone or ["Blasted Lands"])
    want = {wikimaps.norm(z) for z in zones}
    src = sqlite3.connect(f"file:{WIKI}?mode=ro", uri=True)
    rows = [r for r in src.execute("select title, zone, x, y, classic from npc_coords where x is not null")
            if r[4] == 0 and wikimaps.norm(wikimaps.base_zone(r[1])) in want and r[1] == wikimaps.base_zone(r[1])]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(OUT)
    db.execute("create table if not exists coord_history(title text, zone text, x real, y real, pre_cata int, "
               "pre_revid int, pre_time text, checked text, primary key (title, zone, x, y))")
    titles = sorted({r[0] for r in rows})
    print(f"{len(zones)} zone(s), {len(titles)} pages, {len(rows)} coordinates", flush=True)
    now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    n, pre = 0, 0
    for t in titles:
        if a.max_requests is not None and n >= a.max_requests:
            print("stopped at --max-requests; re-run to continue (answers are cached)")
            break
        revid, ts, old = pre_cata_points(t)
        n += 1
        for title, zone, x, y, _c in rows:
            if title != t:
                continue
            hit = (wikimaps.norm(zone), round(x, 1), round(y, 1)) in old
            pre += hit
            db.execute("insert or replace into coord_history values (?,?,?,?,?,?,?,?)",
                       (title, zone, x, y, int(hit), revid, ts, now))
        if n % 50 == 0:
            db.commit()
            print(f"  {n}/{len(titles)} pages", flush=True)
    db.commit()
    print(f"{n} pages checked; {pre} coordinates were already on the page before 4.0.3 (Classic-map numbers) -> {OUT}")


if __name__ == "__main__":
    main()
