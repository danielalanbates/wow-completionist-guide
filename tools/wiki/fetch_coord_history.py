#!/usr/bin/env python3
# CompletionRoute :: tools/wiki/fetch_coord_history.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Which wiki coordinates were written on the Classic map: the page revision before patch 4.0.3.

    nice -n 10 python3 tools/wiki/fetch_coord_history.py [--zone "Blasted Lands" ...] [--changed-zones] [--max-requests N]

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
"""
import argparse
import datetime
import sqlite3
import sys
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zone", action="append", default=None, help="zone name (repeatable; default Blasted Lands)")
    ap.add_argument("--changed-zones", action="store_true", help="every zone whose Classic and retail maps differ")
    ap.add_argument("--max-requests", type=int, default=None)
    a = ap.parse_args()
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
