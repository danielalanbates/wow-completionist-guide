#!/usr/bin/env python3
# CompletionRoute :: tools/wiki/fetch_titles.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Fetch the pages quests LINK to but the template crawl did not cover (items, objects, subzones, redirects).

    nice -n 10 python3 tools/wiki/parse_wiki.py              # needs tools/wiki/wiki.sqlite first
    nice -n 10 python3 tools/wiki/fetch_titles.py [--max-requests N]
    nice -n 10 python3 tools/wiki/parse_wiki.py              # re-parse with the new pages

Queue = quest start/end targets + objective targets + item drop sources (from wiki.sqlite) that are not in the
raw cache and were never tried before, plus the places named in the {{Npcbox}}/{{Objectbox}} location field of those
NPC and object pages that have no coordinate of their own (2026-11-11; the zone link at the end is left out), and the
places linked in such a page's "Before the Cataclysm ... was located at [[Kargath]]" sentence (gen_wiki_guides.py
Places.MOVED, read on the Classic clients).  Same etiquette and client as fetch_wiki.py (MediaWiki API only, serial,
>= 1 s apart, maxlag=5, Retry-After, gzip, 50 titles per request, descriptive UA).  redirects=1: the redirect
pairs are stored in `redirects`, so a later parse resolves [[Old name]] links.  Every attempted title goes into
`title_attempts`, so nothing is fetched twice and the job resumes where it stopped.
"""
import argparse
import os
import signal
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fetch_wiki as F  # noqa: E402
import re  # noqa: E402
import wikitext as W  # noqa: E402

T_BOX = re.compile(r"npcbox|objectbox", re.I)
# the "Before the Cataclysm ... was located at [[Place]]" sentence, exactly as gen_wiki_guides.py reads it
from gen_wiki_guides import Places  # noqa: E402
MOVED = Places.MOVED

HERE = os.path.dirname(os.path.abspath(__file__))
PARSED = os.path.join(HERE, "wiki.sqlite")
TAG = "linked"


def queue(raw, parsed):
    have = {r[0] for r in raw.execute("select title from pages")}
    have |= {r[0] for r in raw.execute("select title from title_attempts")}
    have |= {r[0] for r in raw.execute("select from_title from redirects")}
    want = []
    used = set()
    for sql in ("select start_npc from quests", "select end_npc from quests",
                "select target_title from quest_objectives",
                "select value from items, json_each(items.sources_json)",
                "select json_extract(e.value, '$.title') from quests, json_each(quests.start_json) e",
                "select json_extract(e.value, '$.title') from quests, json_each(quests.end_json) e"):
        for (t,) in parsed.execute(sql):
            if t:
                used.add(t)
            if t and t not in have and len(t) < 200 and ":" not in t[:12]:
                have.add(t)
                want.append(t)
    # the places named in the location field of the NPC/object pages quests use that carry no coordinate of their own
    # ("| location = [[Razor Hill]], [[Durotar]]"): gen_wiki_guides.py takes the place page's point for them
    located = {r[0] for r in parsed.execute("select distinct title from npc_coords")}
    titles = {r[0]: r[1] for r in parsed.execute("select title, page_title from titles")}
    pages = {titles.get(t, t) for t in used} - located
    for t in sorted(pages):
        r = raw.execute("select wikitext from pages where title = ?", (t,)).fetchone()
        box = next(W.find_templates(r[0] or "", T_BOX), None) if r else None
        if not box:
            continue
        links = W.links(W.split_params(box[3])[1].get("location", ""))[:-1] or W.links(W.split_params(box[3])[1].get("location", ""))
        moved = MOVED.search(r[0] or "")
        if moved and moved.group(1):
            links += W.links(moved.group(1))
        for ln, _ in links:
            if ln and ln not in have and ln not in titles and len(ln) < 200:
                have.add(ln)
                want.append(ln)
    return want


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default=F.DEFAULT_DB)
    ap.add_argument("--max-requests", type=int, default=None)
    ap.add_argument("--min-interval", type=float, default=1.0)
    a = ap.parse_args()
    signal.signal(signal.SIGINT, F._on_signal)
    signal.signal(signal.SIGTERM, F._on_signal)
    raw = F.open_db(a.db)
    raw.executescript("""
    CREATE TABLE IF NOT EXISTS title_attempts(title TEXT PRIMARY KEY, result TEXT, at TEXT);
    CREATE TABLE IF NOT EXISTS redirects(from_title TEXT PRIMARY KEY, to_title TEXT);
    """)
    parsed = sqlite3.connect(PARSED)
    want = queue(raw, parsed)
    print(f"{len(want)} linked titles not cached -> {(len(want) + 49) // 50} requests", flush=True)
    cli = F.Client(a.min_interval)
    stored = missing = 0
    for i in range(0, len(want), 50):
        if F._stop or (a.max_requests is not None and cli.count >= a.max_requests):
            print("stopping; rerun to resume", flush=True)
            break
        batch = want[i:i + 50]
        try:
            data = cli.get({"action": "query", "prop": "revisions", "rvprop": "content|ids|timestamp",
                            "rvslots": "main", "redirects": "1", "titles": "|".join(batch)})
        except Exception as e:
            raw.execute("INSERT INTO failures(template, cont_json, error, at) VALUES(?,?,?,?)",
                        (TAG, "|".join(batch)[:2000], str(e), F.now()))
            raw.commit()
            print(f"FAILED batch {i // 50}: {e}", flush=True)
            continue
        q = data.get("query") or {}
        for r in q.get("redirects", []) or []:
            raw.execute("INSERT OR REPLACE INTO redirects VALUES(?,?)", (r["from"], r["to"]))
        for r in q.get("normalized", []) or []:
            raw.execute("INSERT OR REPLACE INTO redirects VALUES(?,?)", (r["from"], r["to"]))
        got = set()
        for p in q.get("pages", []):
            if p.get("missing") or p.get("invalid"):
                missing += 1
                continue
            revs = p.get("revisions")
            if not revs:
                continue
            rv = revs[0]
            text = rv.get("slots", {}).get("main", {}).get("content")
            if text is None:
                continue
            raw.execute(
                "INSERT INTO pages(pageid, ns, title, template, revid, timestamp, wikitext, fetched_at) "
                "VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(pageid) DO UPDATE SET revid=excluded.revid, "
                "timestamp=excluded.timestamp, wikitext=excluded.wikitext, fetched_at=excluded.fetched_at "
                "WHERE excluded.revid IS NOT pages.revid",
                (p["pageid"], p.get("ns"), p.get("title"), TAG, rv.get("revid"), rv.get("timestamp"), text, F.now()))
            raw.execute("INSERT OR IGNORE INTO page_templates(pageid, template) VALUES(?,?)", (p["pageid"], TAG))
            got.add(p.get("title"))
            stored += 1
        raw.executemany("INSERT OR REPLACE INTO title_attempts VALUES(?,?,?)",
                        [(t, "ok" if t in got else "redirect-or-missing", F.now()) for t in batch])
        raw.commit()
        if (i // 50) % 20 == 0:
            print(f"req {cli.count}: stored {stored}, missing {missing}", flush=True)
    print(f"done: {cli.count} requests, {stored} pages stored, {missing} missing titles", flush=True)


if __name__ == "__main__":
    main()
