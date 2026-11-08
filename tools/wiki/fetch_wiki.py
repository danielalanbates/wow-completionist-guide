#!/usr/bin/env python3
"""Download raw wikitext of Warcraft Wiki infobox pages into a local SQLite cache.

Source: https://warcraft.wiki.gg (content licensed CC BY-SA 4.0). This tool only
stores the raw wikitext; parsing happens elsewhere (tools/wiki/*). Anything built
from this cache must carry a CC BY-SA 4.0 attribution header.

Etiquette: MediaWiki API only, serial requests >= --min-interval seconds apart,
maxlag=5, honours Retry-After / 429 / 503, gzip, 50 pages per request,
descriptive User-Agent. Every response is committed together with its continue
token, so the job is resumable and never re-fetches a finished batch.

Usage:
  nice -n 10 python3 tools/wiki/fetch_wiki.py                 # all default templates
  python3 tools/wiki/fetch_wiki.py --templates Questbox        # one template
  python3 tools/wiki/fetch_wiki.py --status                    # counts only
  python3 tools/wiki/fetch_wiki.py --restart Npcbox            # forget state, refetch (idempotent upsert)

Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
Licensed under PolyForm Noncommercial 1.0.0 + 10% rider. batesai.org / help@batesai.org
"""
import argparse
import gzip
import json
import os
import signal
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://warcraft.wiki.gg/api.php"
UA = "CompletionistGuide/2.0 (+https://batesai.org)"
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DB = os.path.join(HERE, "cache", "wiki_raw.sqlite")

# Questbox = quests, Npcbox = NPCs (location {{Coords}}), Itembox = item infobox,
# Elinks-object = the wiki has no Objectbox; game-object pages are marked by this
# external-links template, Achievementtip = achievement infobox ({{#data:Achievementtip}}).
DEFAULT_TEMPLATES = ["Questbox", "Npcbox", "Itembox", "Elinks-object", "Achievementtip"]

SCHEMA = """
CREATE TABLE IF NOT EXISTS pages(
  pageid INTEGER PRIMARY KEY, ns INTEGER, title TEXT, template TEXT,
  revid INTEGER, timestamp TEXT, wikitext TEXT, fetched_at TEXT);
CREATE TABLE IF NOT EXISTS page_templates(
  pageid INTEGER, template TEXT, PRIMARY KEY(pageid, template));
CREATE TABLE IF NOT EXISTS state(
  template TEXT PRIMARY KEY, cont_json TEXT, done INTEGER DEFAULT 0,
  requests INTEGER DEFAULT 0, started_at TEXT, finished_at TEXT);
CREATE TABLE IF NOT EXISTS failures(
  id INTEGER PRIMARY KEY AUTOINCREMENT, template TEXT, cont_json TEXT,
  error TEXT, at TEXT);
CREATE INDEX IF NOT EXISTS idx_pages_title ON pages(title);
CREATE INDEX IF NOT EXISTS idx_pt_template ON page_templates(template);
"""

_stop = False


def _on_signal(signum, frame):
    global _stop
    _stop = True
    print(f"signal {signum}: finishing current request then stopping", flush=True)


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


class Client:
    def __init__(self, min_interval):
        self.min_interval = max(1.0, min_interval)
        self.last = 0.0
        self.count = 0

    def _wait(self):
        dt = time.monotonic() - self.last
        if dt < self.min_interval:
            time.sleep(self.min_interval - dt)

    def get(self, params, attempts=8):
        q = dict(params, format="json", formatversion="2", maxlag="5")
        url = API + "?" + urllib.parse.urlencode(q)
        backoff = 5.0
        last_err = None
        for _ in range(attempts):
            self._wait()
            self.last = time.monotonic()
            self.count += 1
            req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Encoding": "gzip"})
            try:
                with urllib.request.urlopen(req, timeout=120) as r:
                    body = r.read()
                    if r.headers.get("Content-Encoding") == "gzip":
                        body = gzip.decompress(body)
                    data = json.loads(body)
            except urllib.error.HTTPError as e:
                ra = e.headers.get("Retry-After") if e.headers else None
                last_err = f"HTTP {e.code}"
                if e.code in (429, 500, 502, 503, 504):
                    wait = float(ra) if ra and ra.isdigit() else backoff
                    print(f"  {last_err}, sleeping {wait:.0f}s", flush=True)
                    time.sleep(wait)
                    backoff = min(backoff * 2, 300)
                    continue
                raise
            except (urllib.error.URLError, TimeoutError, ConnectionError, json.JSONDecodeError, OSError) as e:
                last_err = repr(e)
                print(f"  network error {last_err}, sleeping {backoff:.0f}s", flush=True)
                time.sleep(backoff)
                backoff = min(backoff * 2, 300)
                continue
            err = data.get("error")
            if err:
                if err.get("code") == "maxlag":
                    wait = 5.0
                    print(f"  maxlag ({err.get('lag')}s), sleeping {wait:.0f}s", flush=True)
                    time.sleep(wait)
                    continue
                if err.get("code") in ("ratelimited", "internal_api_error_DBQueryError"):
                    print(f"  api error {err.get('code')}, sleeping {backoff:.0f}s", flush=True)
                    time.sleep(backoff)
                    backoff = min(backoff * 2, 300)
                    last_err = err.get("code")
                    continue
                raise RuntimeError(f"API error: {err}")
            return data
        raise RuntimeError(f"giving up after {attempts} attempts: {last_err}")


def open_db(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    db = sqlite3.connect(path)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=NORMAL")
    db.executescript(SCHEMA)
    return db


def fetch_template(db, cli, template, ns, max_requests):
    row = db.execute("SELECT cont_json, done FROM state WHERE template=?", (template,)).fetchone()
    if row and row[1]:
        print(f"[{template}] already done", flush=True)
        return True
    if not row:
        db.execute("INSERT INTO state(template, cont_json, done, requests, started_at) VALUES(?,?,0,0,?)",
                   (template, None, now()))
        db.commit()
        cont = {}
    else:
        cont = json.loads(row[0]) if row[0] else {}
    tl = "Template:" + template
    while not _stop:
        if max_requests is not None and cli.count >= max_requests:
            print(f"[{template}] request budget reached; resumable", flush=True)
            return False
        params = {
            "action": "query",
            "generator": "embeddedin",
            "geititle": tl,
            "geinamespace": str(ns),
            "geilimit": "50",
            "prop": "revisions",
            "rvprop": "content|ids|timestamp",
            "rvslots": "main",
        }
        params.update(cont)
        try:
            data = cli.get(params)
        except Exception as e:  # recorded, state untouched -> rerun resumes here
            db.execute("INSERT INTO failures(template, cont_json, error, at) VALUES(?,?,?,?)",
                       (template, json.dumps(cont), str(e), now()))
            db.commit()
            print(f"[{template}] FAILED: {e}", flush=True)
            return False
        stored = 0
        for p in (data.get("query") or {}).get("pages", []):
            revs = p.get("revisions")
            if not revs:
                continue  # content arrives in a later rvcontinue chunk
            rv = revs[0]
            text = rv.get("slots", {}).get("main", {}).get("content")
            if text is None:
                continue
            pid = p["pageid"]
            db.execute(
                "INSERT INTO pages(pageid, ns, title, template, revid, timestamp, wikitext, fetched_at) "
                "VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(pageid) DO UPDATE SET "
                "ns=excluded.ns, title=excluded.title, revid=excluded.revid, timestamp=excluded.timestamp, "
                "wikitext=excluded.wikitext, fetched_at=excluded.fetched_at "
                "WHERE excluded.revid IS NOT pages.revid",
                (pid, p.get("ns"), p.get("title"), template, rv.get("revid"), rv.get("timestamp"), text, now()))
            db.execute("INSERT OR IGNORE INTO page_templates(pageid, template) VALUES(?,?)", (pid, template))
            stored += 1
        cont = data.get("continue") or {}
        done = 0 if cont else 1
        db.execute("UPDATE state SET cont_json=?, done=?, requests=requests+1, finished_at=? WHERE template=?",
                   (json.dumps(cont) if cont else None, done, now() if done else None, template))
        db.commit()
        n = db.execute("SELECT COUNT(*) FROM page_templates WHERE template=?", (template,)).fetchone()[0]
        print(f"[{template}] +{stored} total={n} req={cli.count} next={cont.get('geicontinue', cont.get('rvcontinue', '-'))}",
              flush=True)
        if done:
            print(f"[{template}] DONE", flush=True)
            return True
    return False


def status(db, path):
    print(f"db: {path} ({os.path.getsize(path) / 1e6:.1f} MB)" if os.path.exists(path) else "db missing")
    for t, done, req, cont in db.execute("SELECT template, done, requests, cont_json FROM state ORDER BY rowid"):
        n = db.execute("SELECT COUNT(*) FROM page_templates WHERE template=?", (t,)).fetchone()[0]
        print(f"  {t:16s} pages={n:6d} requests={req:5d} {'DONE' if done else 'in progress'}")
    tot = db.execute("SELECT COUNT(*), COALESCE(SUM(LENGTH(wikitext)),0) FROM pages").fetchone()
    print(f"  unique pages={tot[0]} wikitext={tot[1] / 1e6:.1f} MB")
    nf = db.execute("SELECT COUNT(*) FROM failures").fetchone()[0]
    print(f"  failures logged={nf}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", default=DEFAULT_DB)
    ap.add_argument("--templates", default=",".join(DEFAULT_TEMPLATES))
    ap.add_argument("--ns", type=int, default=0, help="namespace to fetch (default 0 = main)")
    ap.add_argument("--min-interval", type=float, default=1.0, help="seconds between requests (>=1)")
    ap.add_argument("--max-requests", type=int, default=None, help="stop after N requests (resumable)")
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--restart", metavar="TEMPLATE", help="clear saved state for TEMPLATE and exit")
    a = ap.parse_args()

    db = open_db(a.db)
    if a.status:
        status(db, a.db)
        return 0
    if a.restart:
        db.execute("DELETE FROM state WHERE template=?", (a.restart,))
        db.commit()
        print(f"state cleared for {a.restart}")
        return 0
    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)
    cli = Client(a.min_interval)
    ok = True
    for t in [x.strip() for x in a.templates.split(",") if x.strip()]:
        if _stop:
            ok = False
            break
        ok = fetch_template(db, cli, t, a.ns, a.max_requests) and ok
        if a.max_requests is not None and cli.count >= a.max_requests:
            ok = False
            break
    status(db, a.db)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
