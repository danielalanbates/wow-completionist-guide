#!/usr/bin/env python3
# CompletionRoute :: tools/wiki/parse_wiki.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Parse the raw Warcraft Wiki cache into structured tables.

    nice -n 10 python3 tools/wiki/parse_wiki.py          # tools/wiki/cache/wiki_raw.sqlite -> tools/wiki/wiki.sqlite

Input : tools/wiki/cache/wiki_raw.sqlite (tools/wiki/fetch_wiki.py; CC BY-SA 4.0 wikitext, gitignored)
Output: tools/wiki/wiki.sqlite (gitignored; derived from CC BY-SA 4.0 content, keep the attribution)

Tables (one run rebuilds them all):
  quests(id, name, faction, races, classes, level, levelreq, zone, start_npc, end_npc, prev_ids, next_ids,
         item_start, objectives_text, removed_patch, added_patch, page_title, revid, + flavor markers,
         start_json / end_json = every start/end entity with its own {{co}} coords)
  quest_objectives(quest_id, page_title, idx, kind, target_title, count, optional, text, coords_json)
  npcs(title, npc_id, zone, x, y, flavor_hint, raw)       best single point per page (npc or object)
  npc_coords(title, idx, zone, x, y, source, badge, classic)  every coordinate on the page
  items(title, item_id, sources_json)                    item pages we have (Itembox): who drops it
  achievements(id, name, category, points, faction, account, description, criteria_json, page_title, revid)
  achievement_criteria(ach_id, idx, text, link_title, quest_id)
  titles(title, page_title, kind)                         resolution table: every fetched page by title
  parse_stats(metric, value)                              the parse rates printed at the end

The rules come from docs/WIKI_DATA_SPEC.md.  Nothing here reads any third-party addon data.
"""
import json
import re
import sqlite3
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import wikitext as W  # noqa: E402

HERE = Path(__file__).resolve().parent
RAW = HERE / "cache" / "wiki_raw.sqlite"
OUT = HERE / "wiki.sqlite"

T_QUESTBOX = re.compile(r"questbox", re.I)
T_NPCBOX = re.compile(r"npcbox", re.I)
T_NPCLOC = re.compile(r"npclocations", re.I)
T_PATCH = re.compile(r"patch \d[\w.]*", re.I)
T_CLASSIC_ONLY = re.compile(r"classic only", re.I)
T_REMOVED = re.compile(r"removed", re.I)
T_BETA = re.compile(r"removedfrom(?:beta|alpha|ptr)", re.I)
T_FOREVER = re.compile(r"forever only", re.I)
T_SEASON = re.compile(r"classic season", re.I)
T_ACHTIP = re.compile(r"#data:\s*achievementtip", re.I)
T_ITEMTIP = re.compile(r"#data:\s*itemtip", re.I)
T_PLAINLIST = re.compile(r"plainlist|ubl|unbulleted list|flatlist", re.I)
RE_ELINK = {
    "quest": re.compile(r"\{\{\s*elinks-quest\s*\|\s*(\d+)", re.I),
    "npc": re.compile(r"\{\{\s*elinks-npc\d?\s*\|([^{}]*)\}\}", re.I),
    "object": re.compile(r"\{\{\s*elinks-object\d?\s*\|\s*(\d+)", re.I),
    "item": re.compile(r"\{\{\s*elinks-item\d?\s*\|\s*(\d+)", re.I),
    "ach": re.compile(r"\{\{\s*elinks-achievement\s*\|\s*(\d+)", re.I),
}
BADGE = [("wow", 1), ("classic", 1), ("vanilla", 1), ("tbc", 2), ("bc", 2), ("wotlk", 3), ("wrath", 3), ("cata", 4),
         ("mop", 5), ("wod", 6), ("legion", 7), ("bfa", 8), ("sl", 9), ("df", 10), ("tww", 11), ("mn", 12), ("midnight", 12)]
CLASSIC_SUFFIX = {"classic", "bc classic", "wrath classic", "cata classic", "mop classic", "season of discovery",
                  "hardcore", "anniversary classic"}


def first_number(s):
    m = re.search(r"-?\d+", s or "")
    return int(m.group(0)) if m else None


def patch_key(p):
    """'4.0.3a' -> (4, 0, 3); None when not a patch number"""
    m = re.match(r"^\s*(\d+)\.(\d+)(?:\.(\d+))?", p or "")
    if not m:
        return None
    return int(m.group(1)), int(m.group(2)), int(m.group(3) or 0)


def title_variant(title):
    m = re.search(r"\(([^()]*)\)\s*$", title)
    return m.group(1).strip() if m else ""


def simple_templates_to_links(text):
    """{{NPC||Name}}, {{Au|Name}}, {{npc|...|Name}} -> [[Name]]; faction icons kept as markers"""
    def rep(m):
        vals = [p.strip() for p in m.group(2).split("|") if p.strip() and "=" not in p]
        return f"[[{vals[-1]}]]" if vals else ""
    return re.sub(r"\{\{\s*(npc|au|object|questitem|item)\s*\|([^{}]*)\}\}", rep, text, flags=re.I)


def entities(field):
    """start/end field -> [{title, label, coords:[[x,y,zone]], faction, auto}]"""
    if not field:
        return []
    f = field
    for _s, _e, _n, inner in list(W.find_templates(f, T_PLAINLIST)):
        pos, _ = W.split_params(inner)
        f = f.replace("{{" + inner + "}}", "\n".join(pos))
    f = simple_templates_to_links(f)
    f = re.sub(r"<!--.*?-->", "", f, flags=re.S)
    segs = re.split(r"<br\s*/?>|\n|\s/\s|\s+or\s+|;\s", f, flags=re.I)
    out = []
    for seg in segs:
        s = seg.strip().lstrip("*").strip()
        if not s:
            continue
        fac = "Alliance" if re.search(r"\{\{\s*alliance", s, re.I) else ("Horde" if re.search(r"\{\{\s*horde", s, re.I) else "")
        cs = [[c[0], c[1], c[2]] for c in W.coords(s)]
        lk = W.links(s)
        if not lk and re.search(r"\bauto(?:matic|-accept|matically|[- ]?accept(?:ed)?)?\b", s, re.I) and not cs:
            out.append({"title": None, "label": W.plain(s), "coords": [], "faction": fac, "auto": True})
            continue
        if lk:
            out.append({"title": lk[0][0], "label": lk[0][1], "coords": cs, "faction": fac, "auto": False,
                        "context": [l[0] for l in lk[1:]]})
        elif cs:
            out.append({"title": None, "label": W.plain(s), "coords": cs, "faction": fac, "auto": False})
    return out


KILL = re.compile(r"\b(slain|killed|defeated|destroyed|slaughtered|vanquished|dead)\b", re.I)
TALK = re.compile(r"\b(speak|talk|follow|meet|report|escort|find|locate|visit|ask|consult|listen)\b", re.I)
USE = re.compile(r"\b(use|used|place|placed|plant|planted|cleanse|cleansed|burn|burned|investigat|inspect|"
                 r"rescued?|freed|saved|helped|repaired|activated|collected|gathered)\b", re.I)


def objectives(body):
    """==Objectives== body -> (prose, [bullet dicts])"""
    if body is None:
        return "", []
    lines = body.splitlines()
    prose, bullets = [], []
    for ln in lines:
        s = ln.strip()
        if not s:
            continue
        if s.startswith("*"):
            b = s.lstrip("*").strip()
            low = b.lower()
            lk = W.links(simple_templates_to_links(b))
            cs = [[c[0], c[1], c[2]] for c in W.coords(b)]
            m = re.search(r"\((\d+)\)\s*(?:\(optional\))?\s*$", b, re.I) or re.search(r"\((\d+)\)", b)
            count = int(m.group(1)) if m else None
            if "(provided)" in low:
                kind = "provided"
            elif KILL.search(b):
                kind = "kill"
            elif re.search(r"\(\d+\s*/\s*100\s*%?\)|\d+%", b):
                kind = "progress"
            elif TALK.search(b) and not count:
                kind = "talk"
            elif count is not None and lk and not USE.search(b):
                kind = "item"
            elif USE.search(b):
                kind = "use"
            else:
                kind = "other"
            bullets.append({"kind": kind, "target": lk[0][0] if lk else None, "count": count,
                            "optional": "(optional)" in low, "text": W.plain(b)[:200], "coords": cs})
        elif not s.startswith(("{{", "[[File", "[[Image", ";", ":")) or s.startswith(":"):
            prose.append(W.plain(s))
    return " ".join(p for p in prose if p)[:400], bullets


def markers(text, sec):
    """flavor / patch markers above the box and in ==Patch changes=="""
    head = text[:3000]
    m = {"classic_only": None, "classic_only_args": "", "removed_patch": None, "removed_flag": False,
         "beta": False, "forever": False, "sod": False, "added_patch": None}
    for _s, _e, _n, inner in W.find_templates(head, T_CLASSIC_ONLY):
        pos, named = W.split_params(inner)
        m["classic_only"] = named.get("patch", "") or "?"
        m["classic_only_args"] = ",".join(p.lower() for p in pos if p)
    for _s, _e, nm, inner in W.find_templates(head, re.compile(r"removed\w*", re.I)):
        if T_BETA.fullmatch(nm):
            m["beta"] = True
            continue
        if nm.lower() == "removed":
            pos, named = W.split_params(inner)
            m["removed_flag"] = True
            if named.get("patch"):
                m["removed_patch"] = named["patch"]
    if list(W.find_templates(head, T_FOREVER)):
        m["forever"] = True
    for _s, _e, _n, inner in W.find_templates(head, T_SEASON):
        if "discovery" in inner.lower():
            m["sod"] = True
    pc = sec.get("patch changes") or ""
    adds, rems = [], []
    for _s, _e, nm, inner in W.find_templates(pc, T_PATCH):
        ver = nm.split(" ", 1)[1].strip()
        pos, named = W.split_params(inner)
        note = (named.get("note") or (pos[0] if pos else "")).strip().lower()
        note = re.sub(r"^[\[\]'\s]+", "", note)
        if "added" in named or note.startswith(("added", "introduced", "first appeared")):
            adds.append(ver)
        if "removed" in named or note.startswith(("removed", "quest removed", "this quest was removed")):
            rems.append(ver)
    keyed = [a for a in adds if patch_key(a)]
    if keyed:
        m["added_patch"] = min(keyed, key=patch_key)
    rk = [r for r in rems if patch_key(r)]
    if rk and not m["removed_patch"]:
        m["removed_patch"] = max(rk, key=patch_key)
    if m["classic_only"] and m["classic_only"] not in ("?", "") and not m["removed_patch"]:
        m["removed_patch"] = m["classic_only"]
    return m


def npc_points(title, text, sec, page_classic):
    """every {{Coords}} on an NPC/object page with where it came from"""
    pts = []
    box = next(W.find_templates(text, T_NPCBOX), None)
    loc_field = ""
    if box:
        _pos, named = W.split_params(box[3])
        loc_field = named.get("location", "")
        for x, y, z, *_ in W.coords(loc_field):
            pts.append((z, x, y, "location", 0))
    for _s, _e, _n, inner in W.find_templates(text, T_NPCLOC):
        _pos, named = W.split_params(inner)
        badge = 0
        ex = (named.get("extracol") or "").lower()
        bm = re.search(r"\{\{\s*([a-z]+)-inline", ex)
        if bm:
            for k, v in BADGE:
                if bm.group(1) == k:
                    badge = v
        for x, y, z, *_ in W.coords(named.get("loc", "")):
            pts.append((z, x, y, "npclocations", badge))
    lead = sec.get("", "")
    if box:
        lead = lead.replace("{{" + box[3] + "}}", "")
    for x, y, z, *_ in W.coords(lead):
        pts.append((z, x, y, "lead", 0))
    seen = {(p[0], p[1], p[2]) for p in pts}
    for k, body in sec.items():
        if k == "":
            continue
        for x, y, z, *_ in W.coords(body):
            if (z, x, y) not in seen:
                seen.add((z, x, y))
                pts.append((z, x, y, "body:" + k[:20], 0))
    out = []
    for z, x, y, src, badge in pts:
        zl = z.lower()
        classic = 1 if ("(classic)" in zl or "(forever)" in zl or "(burning crusade)" in zl or page_classic) else 0
        out.append((z, x, y, src, badge, classic))
    zone = ""
    lk = W.links(loc_field)
    if lk:
        zone = lk[-1][0]
    return out, zone


def main():
    t0 = time.time()
    raw = sqlite3.connect(RAW)
    tmpl = defaultdict(set)
    for pid, t in raw.execute("select pageid, template from page_templates"):
        tmpl[pid].add(t)
    if OUT.exists():
        OUT.unlink()
    db = sqlite3.connect(OUT)
    db.executescript("""
    create table quests(id int, name text, faction text, races text, classes text, level int, levelreq int, zone text,
        category text, start_npc text, end_npc text, prev_ids text, next_ids text, prev_titles text, next_titles text,
        item_start text, objectives_text text, removed_patch text, added_patch text, classic_only text,
        classic_only_args text, removed_flag int, beta int, forever int, sod int, variant text, qtype text,
        profession text, start_json text, end_json text, page_title text, revid int, page_classic int);
    create table quest_objectives(quest_id int, page_title text, idx int, kind text, target_title text, count int,
        optional int, text text, coords_json text);
    create table npcs(title text primary key, npc_id text, zone text, x real, y real, flavor_hint text, raw text,
        kind text, page_classic int);
    create table npc_coords(title text, idx int, zone text, x real, y real, source text, badge int, classic int);
    create table items(title text primary key, item_id int, sources_json text, starts_quest int);
    create table achievements(id int, name text, category text, points int, faction text, account int,
        description text, criteria_json text, page_title text, revid int);
    create table achievement_criteria(ach_id int, idx int, text text, link_title text, quest_id int);
    create table titles(title text primary key, page_title text, kind text);
    create table parse_stats(metric text primary key, value real);
    """)
    st = Counter()
    quests_rows, obj_rows = [], []
    title_kind = {}
    q_pages = []
    for pid, title, revid, text in raw.execute("select pageid, title, revid, wikitext from pages"):
        text = text or ""
        kinds = tmpl[pid]
        sec = W.sections(text)
        variant = title_variant(title)
        page_classic = 1 if (variant.lower() in CLASSIC_SUFFIX or
                              list(W.find_templates(text[:2000], T_CLASSIC_ONLY)) or
                              list(W.find_templates(text[:2000], T_SEASON))) else 0
        if "Questbox" in kinds:
            title_kind[title] = "quest"
            q_pages.append(pid)
            st["questbox_pages"] += 1
            box = next(W.find_templates(text, T_QUESTBOX), None)
            if not box:
                st["questbox_missing_box"] += 1
                continue
            _pos, f = W.split_params(box[3])
            ids = [int(x) for x in re.findall(r"\d+", re.sub(r"\{\{.*?\}\}", "", f.get("id", "")))]
            if not ids:
                m = RE_ELINK["quest"].search(text)
                if m:
                    ids = [int(m.group(1))]
                    st["id_from_elinks"] += 1
            if not ids:
                st["no_id"] += 1
                continue
            mk = markers(text, sec)
            starts = entities(f.get("start", ""))
            ends = entities(f.get("end", "")) if f.get("end", "").strip() else []
            if not ends:
                st["end_defaults_to_start"] += 1
            prose, bullets = objectives(sec.get("objectives"))
            if not bullets:
                st["objectives_no_bullets"] += 1
            st["bullets"] += len(bullets)
            prev_t = [l[0] for l in W.links(re.sub(r"\[\[[^\]]*\]\]\s*\(optional\)", "", f.get("previous", ""), flags=re.I))]
            next_t = [l[0] for l in W.links(f.get("next", ""))]
            level = f.get("level", "").strip()
            levelreq = f.get("levelreq", "").strip()
            fac = W.plain(f.get("faction", "")).strip()
            fac = fac if fac in ("Alliance", "Horde") else ("Both" if fac in ("", "Neutral", "Both") else fac)
            cls = W.plain(f.get("class", "")).strip()
            cat = W.plain(f.get("category", "")).strip()
            if not cls and cat.lower() in ("warrior", "paladin", "hunter", "rogue", "priest", "shaman", "mage", "warlock",
                                           "druid", "death knight", "monk", "demon hunter", "evoker"):
                cls = cat
            item_start = None
            if starts and starts[0]["title"] and re.search(r"\b(dropped|drops|loot|item|book|letter|note)\b",
                                                          f.get("start", ""), re.I):
                item_start = starts[0]["title"]
            for qid in ids:
                quests_rows.append((
                    qid, W.plain(f.get("name", "")) or re.sub(r"\s*\([^()]*\)$", "", title), fac,
                    W.plain(f.get("race", "")), cls,
                    int(level) if re.fullmatch(r"-?\d+", level) else None,
                    int(levelreq) if re.fullmatch(r"\d+", levelreq) else None,
                    W.plain(f.get("zone", "")) or cat, cat,
                    starts[0]["title"] if starts else None, (ends or starts)[0]["title"] if (ends or starts) else None,
                    None, None, json.dumps(prev_t), json.dumps(next_t), item_start, prose,
                    mk["removed_patch"], mk["added_patch"], mk["classic_only"], mk["classic_only_args"],
                    int(mk["removed_flag"]), int(mk["beta"]), int(mk["forever"]), int(mk["sod"]), variant,
                    W.plain(f.get("type", "")), W.plain(f.get("profession", "")),
                    json.dumps(starts), json.dumps(ends), title, revid, page_classic))
                for i, b in enumerate(bullets, 1):
                    obj_rows.append((qid, title, i, b["kind"], b["target"], b["count"], int(b["optional"]), b["text"],
                                     json.dumps(b["coords"])))
            if len(ids) > 1:
                st["multi_id_pages"] += 1
            if starts and any(e["coords"] for e in starts):
                st["start_has_coords"] += 1
            if starts and starts[0]["title"]:
                st["start_has_link"] += 1
            if starts and starts[0].get("auto"):
                st["start_auto"] += 1
        has_npcbox = "Npcbox" in kinds or re.search(r"\{\{\s*npcbox", text[:6000], re.I)
        has_obj = "Elinks-object" in kinds or RE_ELINK["object"].search(text)
        has_item = "Itembox" in kinds or next(W.find_templates(text[:4000], T_ITEMTIP), None)
        if "Questbox" not in kinds and (has_npcbox or has_obj or (not has_item and "linked" in kinds and
                                                                  W.RE_COORD.search(text))):
            kind = "npc" if has_npcbox else ("object" if has_obj else "place")
            title_kind.setdefault(title, kind)
            pts, zone = npc_points(title, text, sec, page_classic)
            nid = None
            if kind == "npc":
                m = RE_ELINK["npc"].search(text)
                if m:
                    nid = ",".join(re.findall(r"(?<![=\w])\d+(?![\w])", m.group(1).split("loc")[0])) or None
            else:
                m = RE_ELINK["object"].search(text)
                nid = m.group(1) if m else None
            best = pts[0] if pts else None
            db.execute("insert or replace into npcs values (?,?,?,?,?,?,?,?,?)",
                       (title, nid, (best[0] if best else zone), best[1] if best else None, best[2] if best else None,
                        "classic" if (best and best[5]) else ("retail" if best else None),
                        json.dumps(pts), kind, page_classic))
            db.executemany("insert into npc_coords values (?,?,?,?,?,?,?,?)",
                           [(title, i, p[0], p[1], p[2], p[3], p[4], p[5]) for i, p in enumerate(pts)])
            st[f"{kind}_pages"] += 1
            if pts:
                st[f"{kind}_with_coords"] += 1
        if "Itembox" in kinds or next(W.find_templates(text[:200], T_ITEMTIP), None):
            itip = next(W.find_templates(text[:4000], T_ITEMTIP), None)
            if itip or "Itembox" in kinds:
                title_kind.setdefault(title, "item")
                iid = None
                if itip:
                    _p, named = W.split_params(itip[3])
                    iid = first_number(named.get("itemid"))
                    qb = 1 if named.get("qbegin") else 0
                else:
                    qb = 0
                if not iid:
                    m = RE_ELINK["item"].search(text)
                    iid = int(m.group(1)) if m else None
                src = sec.get("source") or sec.get("sources") or ""
                lead = sec.get("", "")
                srcs = [l[0] for l in W.links(src)]
                for mm in re.finditer(r"(?:drop(?:s|ped)? (?:by|from)|looted from|found (?:in|on)|obtained from)([^.]*)",
                                      lead, re.I):
                    srcs += [l[0] for l in W.links(mm.group(1))]
                db.execute("insert or replace into items values (?,?,?,?)", (title, iid, json.dumps(srcs[:20]), qb))
                st["item_pages"] += 1
        if "Achievementtip" in kinds:
            title_kind.setdefault(title, "achievement")
            st["achievement_pages"] += 1
            tip = next(W.find_templates(text, T_ACHTIP), None)
            m = RE_ELINK["ach"].search(text)
            if not tip:
                st["achievement_no_tip"] += 1
                continue
            _p, named = W.split_params(tip[3])
            crit_txt = (named.get("criteria", "") + "\n" + named.get("criteria2", "")).strip()
            crits = []
            for ln in crit_txt.splitlines():
                s = ln.strip()
                if not s.startswith("*"):
                    continue
                lk = W.links(s)
                crits.append({"text": W.plain(s.lstrip("*")), "link": lk[0][0] if lk else None})
            aid = int(m.group(1)) if m else None
            if aid:
                st["achievement_with_id"] += 1
            db.execute("insert into achievements values (?,?,?,?,?,?,?,?,?,?)",
                       (aid, W.plain(named.get("name", "")) or title, W.plain(named.get("category", "")),
                        first_number(named.get("points")), W.plain(named.get("faction", "")),
                        1 if named.get("account", "").strip() else 0, W.plain(named.get("description", "")),
                        json.dumps(crits), title, revid))
            for i, c in enumerate(crits, 1):
                db.execute("insert into achievement_criteria values (?,?,?,?,?)", (aid, i, c["text"], c["link"], None))
            st["achievement_criteria"] += len(crits)
    db.executemany("insert into quests values (" + ",".join("?" * 33) + ")", quests_rows)
    db.executemany("insert into quest_objectives values (?,?,?,?,?,?,?,?,?)", obj_rows)
    # redirects seen by tools/wiki/fetch_titles.py: [[Old name]] -> page
    redir = {}
    try:
        redir = dict(raw.execute("select from_title, to_title from redirects"))
    except sqlite3.OperationalError:
        pass
    for frm, to in list(redir.items()):
        seen = set()
        while to in redir and to not in seen:
            seen.add(to)
            to = redir[to]
        if to in title_kind and frm not in title_kind:
            db.execute("insert or replace into titles values (?,?,?)", (frm, to, title_kind[to]))
    db.execute("create table redirects(from_title text primary key, to_title text)")
    db.executemany("insert into redirects values (?,?)", redir.items())
    db.executemany("insert or replace into titles values (?,?,?)",
                   [(t, t, k) for t, k in title_kind.items()] +
                   [(t[:1].lower() + t[1:], t, k) for t, k in title_kind.items() if t[:1].isupper()])

    # ---- resolution: previous/next titles -> quest ids; achievement criteria -> quest ids ----------------
    ids_by_title = defaultdict(set)
    for qid, pt in db.execute("select id, page_title from quests"):
        ids_by_title[pt].add(qid)
    for frm, to in db.execute("select title, page_title from titles where title != page_title").fetchall():
        if to in ids_by_title and frm not in ids_by_title:
            ids_by_title[frm] = ids_by_title[to]
    unresolved = Counter()
    upd = []
    for rowid, pt, nt in db.execute("select rowid, prev_titles, next_titles from quests").fetchall():
        res = []
        for lst in (json.loads(pt), json.loads(nt)):
            ids = []
            for t in lst:
                if t in ids_by_title:
                    ids += sorted(ids_by_title[t])
                else:
                    unresolved["chain_title_unresolved"] += 1
            res.append(",".join(str(i) for i in dict.fromkeys(ids)) or None)
        upd.append((res[0], res[1], rowid))
    db.executemany("update quests set prev_ids=?, next_ids=? where rowid=?", upd)
    for aid, idx, link in db.execute("select ach_id, idx, link_title from achievement_criteria where link_title is not null").fetchall():
        if link in ids_by_title:
            db.execute("update achievement_criteria set quest_id=? where ach_id is ? and idx=?",
                       (min(ids_by_title[link]), aid, idx))
            st["achievement_criteria_quest"] += 1

    # ---- rates --------------------------------------------------------------------------------------
    nq = db.execute("select count(*) from quests").fetchone()[0]
    nqid = db.execute("select count(distinct id) from quests").fetchone()[0]
    start_target_ok = db.execute("select count(*) from quests where start_npc in (select title from titles)").fetchone()[0]
    start_target_coords = db.execute(
        "select count(*) from quests where start_npc in (select title from npcs where x is not null)").fetchone()[0]
    start_any_coords = db.execute(
        "select count(*) from quests where start_json like '%\"coords\": [[%' "
        "or start_npc in (select title from npcs where x is not null)").fetchone()[0]
    obj_target_known = db.execute(
        "select count(*) from quest_objectives where target_title in (select title from titles)").fetchone()[0]
    nobj = db.execute("select count(*) from quest_objectives").fetchone()[0]
    obj_coords = db.execute(
        "select count(*) from quest_objectives where coords_json != '[]' or "
        "target_title in (select title from npcs where x is not null)").fetchone()[0]
    chain_rows = db.execute("select count(*) from quests where prev_titles != '[]'").fetchone()[0]
    chain_ok = db.execute("select count(*) from quests where prev_ids is not null").fetchone()[0]
    stats = dict(st)
    stats.update(quest_rows=nq, distinct_quest_ids=nqid, start_target_page_fetched=start_target_ok,
                 start_target_page_has_coords=start_target_coords, start_any_coords=start_any_coords,
                 objective_bullets=nobj, objective_target_page_fetched=obj_target_known,
                 objective_with_coords=obj_coords, rows_with_previous=chain_rows, previous_resolved=chain_ok,
                 **unresolved)
    db.executemany("insert or replace into parse_stats values (?,?)", stats.items())
    db.commit()
    pct = lambda a, b: f"{100.0 * a / max(b, 1):.1f}%"
    print(f"parsed in {time.time() - t0:.0f}s -> {OUT}")
    print(f"questbox pages {st['questbox_pages']}: rows {nq} ({nqid} distinct ids), no id {st['no_id']}, "
          f"id from Elinks {st['id_from_elinks']}, multi-id pages {st['multi_id_pages']}")
    print(f"  start: linked {pct(st['start_has_link'], st['questbox_pages'])}, own coords "
          f"{pct(st['start_has_coords'], st['questbox_pages'])}, auto {st['start_auto']}; target page fetched "
          f"{pct(start_target_ok, nq)}, target page has coords {pct(start_target_coords, nq)}, any start coords "
          f"{pct(start_any_coords, nq)}")
    print(f"  end defaults to start {pct(st['end_defaults_to_start'], st['questbox_pages'])}; previous resolved "
          f"{chain_ok}/{chain_rows} ({unresolved['chain_title_unresolved']} titles not in cache)")
    print(f"  objectives: {nobj} bullets, no bullets on {st['objectives_no_bullets']} pages; target page fetched "
          f"{pct(obj_target_known, nobj)}; with coords {pct(obj_coords, nobj)}")
    print(f"npc pages {st['npc_pages']} (coords {pct(st['npc_with_coords'], st['npc_pages'])}), object pages "
          f"{st['object_pages']} (coords {pct(st['object_with_coords'], st['object_pages'])}), place pages "
          f"{st['place_pages']} (coords {pct(st['place_with_coords'], st['place_pages'])}), item pages {st['item_pages']}")
    print(f"achievements {st['achievement_pages']} pages, with id {st['achievement_with_id']}, criteria "
          f"{st['achievement_criteria']} ({st['achievement_criteria_quest']} resolve to a quest)")


if __name__ == "__main__":
    main()
