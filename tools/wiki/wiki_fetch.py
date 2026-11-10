#!/usr/bin/env python3
# CompletionRoute :: tools/wiki/wiki_fetch.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Polite shared Warcraft Wiki client for the profession and gold generators.

    import wiki_fetch as W
    W.page("Cooking trainers")          # wikitext, "" if the page does not exist
    W.category("Category:Herbs")        # member titles
    W.api(action="query", list="search", srsearch="x", srlimit=5)   # raw JSON

MediaWiki API only.  A cross-process lock keeps every request from every running generator at least 1.2 s apart.
Responses are cached forever under tools/wiki/cache/extra_pages/ (gitignored); delete a file to refetch.
"""
import fcntl, gzip, hashlib, json, time, urllib.error, urllib.parse, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CACHE = ROOT / "cache" / "extra_pages"
LOCK = ROOT / "cache" / ".wiki_request.lock"
UA = "CompletionistGuide/2.0 (+https://batesai.org)"
API = "https://warcraft.wiki.gg/api.php"
GAP = 1.2


def _get(params):
    url = API + "?" + urllib.parse.urlencode(params)
    LOCK.parent.mkdir(parents=True, exist_ok=True)
    for attempt in range(8):
        with open(LOCK, "a+") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            lk.seek(0)
            try:
                last = float(lk.read().strip() or 0)
            except ValueError:
                last = 0.0
            wait = GAP - (time.time() - last)
            if wait > 0:
                time.sleep(wait)
            req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Encoding": "gzip"})
            body, retry = None, 0
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    body = r.read()
                    if r.headers.get("Content-Encoding") == "gzip":
                        body = gzip.decompress(body)
            except urllib.error.HTTPError as e:
                if e.code not in (429, 500, 502, 503, 504):
                    raise
                retry = int(e.headers.get("Retry-After") or (5 * (attempt + 1)))
            except (urllib.error.URLError, TimeoutError):
                retry = 5 * (attempt + 1)
            lk.seek(0)
            lk.truncate()
            lk.write(str(time.time()))
            lk.flush()
        if body is not None:
            d = json.loads(body)
            if isinstance(d, dict) and d.get("error", {}).get("code") == "maxlag":
                time.sleep(6)
                continue
            return d
        time.sleep(retry)
    raise RuntimeError("wiki request failed after retries: " + url)


def api(**params):
    params = dict(params, format="json", formatversion=2, maxlag=5)
    key = hashlib.sha1(json.dumps(params, sort_keys=True).encode()).hexdigest()
    p = CACHE / (key + ".json")
    if p.exists():
        return json.loads(p.read_text())
    d = _get(params)
    CACHE.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".part")
    tmp.write_text(json.dumps(d))
    tmp.replace(p)
    return d


def page(title):
    d = api(action="query", prop="revisions", rvprop="content", rvslots="main", redirects=1, titles=title)
    pages = d.get("query", {}).get("pages", [])
    if not pages or pages[0].get("missing"):
        return ""
    return pages[0]["revisions"][0]["slots"]["main"]["content"]


def category(title):
    out, cont = [], {}
    while True:
        d = api(action="query", list="categorymembers", cmtitle=title, cmlimit=500, **cont)
        out += [m["title"] for m in d.get("query", {}).get("categorymembers", [])]
        if "continue" not in d:
            return out
        cont = {"cmcontinue": d["continue"]["cmcontinue"]}
