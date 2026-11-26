#!/usr/bin/env python3
# CompletionRoute :: tools/wiki/refresh_changed.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Refresh the wiki cache incrementally: re-fetch only pages edited (or created) since the last fetch.

    nice -n 10 python3 tools/wiki/refresh_changed.py                  # Questbox + Npcbox, since each one's last fetch
    python3 tools/wiki/refresh_changed.py --since 2026-11-07T23:00:00Z --templates Questbox
    python3 tools/wiki/refresh_changed.py --dry-run                   # count changed titles only

Source: https://warcraft.wiki.gg (CC BY-SA 4.0). Step 1 lists main-namespace edits/creations with
list=recentchanges (the wiki keeps 90 days), plus the new title of each page moved in that window. Step 2 asks each changed title, 50 per request, for its current
revision and which of the templates it embeds. A cached page of a refreshed template is replaced when its revid
changed; a page that newly embeds the template is added; a page that no longer does keeps its row (the parser
decides). Polite: one request at a time, >= 1.2 s apart, maxlag=5, generic UA (fetch_wiki.Client).
State: table refresh_log in cache/wiki_raw.sqlite records each run (template, since, until, counts).
"""
import argparse, json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fetch_wiki import Client, open_db, DEFAULT_DB, now  # noqa: E402

LOG = """CREATE TABLE IF NOT EXISTS refresh_log(
  id INTEGER PRIMARY KEY AUTOINCREMENT, template TEXT, since TEXT, until TEXT,
  changed_titles INTEGER, updated INTEGER, added INTEGER, at TEXT)"""


def since_for(db, template):
    r = db.execute("SELECT MAX(until) FROM refresh_log WHERE template=?", (template,)).fetchone()
    if r and r[0]:
        return r[0]
    r = db.execute("SELECT started_at FROM state WHERE template=?", (template,)).fetchone()
    return r[0] if r else None


def changed_titles(cli, since, until):
    titles, cont = {}, {}
    while True:
        p = {"action": "query", "list": "recentchanges", "rcnamespace": "0", "rctype": "edit|new|log",
             "rcprop": "title|timestamp|loginfo", "rclimit": "500", "rcdir": "older", "rcstart": until, "rcend": since}
        p.update(cont)
        d = cli.get(p)
        for rc in d.get("query", {}).get("recentchanges", []):
            if rc.get("type") == "log":
                # a renamed page keeps its pageid under a new title and makes no edit entry: fetch the target title
                lp = rc.get("logparams") or {}
                tgt = lp.get("target_title")
                if rc.get("logtype") == "move" and tgt and lp.get("target_ns") == 0:
                    titles.setdefault(tgt, rc["timestamp"])
                continue
            titles.setdefault(rc["title"], rc["timestamp"])
        cont = d.get("continue") or {}
        if not cont:
            return titles
        print(f"  recentchanges: {len(titles)} titles so far", flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", default=DEFAULT_DB)
    ap.add_argument("--templates", default="Questbox,Npcbox")
    ap.add_argument("--since", help="ISO timestamp; default: each template's last fetch/refresh")
    ap.add_argument("--min-interval", type=float, default=1.2)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--titles-file", help="re-fetch these titles (one per line) instead of listing changes; "
                    "writes no refresh_log row, so the next normal run's window is unchanged")
    a = ap.parse_args()
    db = open_db(a.db)
    db.execute(LOG)
    temps = [t.strip() for t in a.templates.split(",") if t.strip()]
    sinces = {t: a.since or since_for(db, t) for t in temps}
    if not all(sinces.values()):
        sys.exit(f"no previous fetch for {[t for t, s in sinces.items() if not s]}: run fetch_wiki.py first")
    since = min(sinces.values())
    until = now()
    cli = Client(a.min_interval)
    print(f"changes {since} .. {until} ({', '.join(temps)})", flush=True)
    if a.titles_file:
        ch = {t.strip(): until for t in open(a.titles_file, encoding="utf-8") if t.strip()}
    else:
        ch = changed_titles(cli, since, until)
    print(f"changed main-namespace titles: {len(ch)}", flush=True)
    if a.dry_run:
        return 0
    want = {"Template:" + t: t for t in temps}
    titles = sorted(ch)
    upd = {t: 0 for t in temps}
    add = {t: 0 for t in temps}
    for i in range(0, len(titles), 50):
        chunk = titles[i:i + 50]
        cont = {}
        while True:
            p = {"action": "query", "titles": "|".join(chunk), "prop": "revisions|templates",
                 "rvprop": "content|ids|timestamp", "rvslots": "main", "tlnamespace": "10", "tllimit": "max",
                 "tltemplates": "|".join(want)}
            p.update(cont)
            d = cli.get(p)
            for pg in d.get("query", {}).get("pages", []):
                if pg.get("missing") or "pageid" not in pg:
                    continue
                tl = [want[x["title"]] for x in pg.get("templates", []) if x["title"] in want]
                revs = pg.get("revisions")
                pid = pg["pageid"]
                known = {r[0] for r in db.execute("SELECT template FROM page_templates WHERE pageid=?", (pid,))}
                hit = [t for t in temps if t in tl or t in known]
                if not hit or not revs:
                    continue
                rv = revs[0]
                text = rv.get("slots", {}).get("main", {}).get("content")
                if text is None:
                    continue
                old = db.execute("SELECT revid FROM pages WHERE pageid=?", (pid,)).fetchone()
                db.execute(
                    "INSERT INTO pages(pageid, ns, title, template, revid, timestamp, wikitext, fetched_at) "
                    "VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(pageid) DO UPDATE SET title=excluded.title, "
                    "revid=excluded.revid, timestamp=excluded.timestamp, wikitext=excluded.wikitext, "
                    "fetched_at=excluded.fetched_at WHERE excluded.revid IS NOT pages.revid",
                    (pid, pg.get("ns"), pg.get("title"), hit[0], rv.get("revid"), rv.get("timestamp"), text, now()))
                for t in tl:
                    db.execute("INSERT OR IGNORE INTO page_templates(pageid, template) VALUES(?,?)", (pid, t))
                for t in hit:
                    if old is None or t not in known:
                        add[t] += 1
                    elif old[0] != rv.get("revid"):
                        upd[t] += 1
            cont = d.get("continue") or {}
            if not cont:
                break
        db.commit()
        if (i // 50) % 20 == 0:
            print(f"  {i + len(chunk)}/{len(titles)} titles; updated {upd} added {add}", flush=True)
    for t in temps if not a.titles_file else []:
        db.execute("INSERT INTO refresh_log(template, since, until, changed_titles, updated, added, at) "
                   "VALUES(?,?,?,?,?,?,?)", (t, sinces[t], until, len(ch), upd[t], add[t], now()))
    db.commit()
    print(f"done: updated {upd} added {add} requests={cli.count}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
