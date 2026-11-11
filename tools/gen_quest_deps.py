#!/usr/bin/env python3
# CompletionRoute :: tools/gen_quest_deps.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Quest prerequisite index per client, for quest-level skipping (Core/Skip.lua, docs/ROUTING.md "Skipping quests").

    nice -n 10 venv/bin/python tools/gen_quest_deps.py [era tbc mop retail forever] [--no-crumbs] [--wiki-only]

    --wiki-only  the release build (tools/package_release.py, docs/RELEASE.md): read source 1 only. The default build
                 also reads the gaps guides (Questie-derived) and the retail storylines (Questie names), says so in
                 its header, and the packager's gate fails it.

Inputs : the generated quest guides the client loads (same files as its TOC), in priority order
           1. Guides/Imported_Wiki_<fl>.lua         Warcraft Wiki chains (CC BY-SA 4.0) - the source of truth
           2. Guides/Imported_Quests_<fl>_gaps.lua  quests the wiki lacks (older generated guides)
           3. Guides/Imported_Storylines_<fl>.lua   Blizzard quest-line order (retail only)
         A quest's prerequisites come from the FIRST source that has the quest at all, so a wiki quest with no
         `previous` link is not given one by a lower source.  WoW-Pro text is not read (its licence forbids
         derivatives); the addon falls back to the loaded guide's own PRE tags for quests this index lacks.
         tools/wiki/wiki.sqlite + tools/wiki/cache/wiki_raw.sqlite (read-only) to tell breadcrumbs apart.
Output : CompletionRoute/Data/QuestDeps_<fl>.lua (generated, gitignored; tools/install.sh ships each client its own)

Breadcrumbs.  The wiki's `previous` field (PRE in the guides) lists optional lead-in quests next to real prerequisites,
so a plain reverse index would warn that skipping a breadcrumb blocks the quest it leads to.  It does not: a breadcrumb
is never required.  The wiki has no breadcrumb field, but it says so in words, and only these forms are trusted:
  * quest-level, "breadcrumb" wording (no quest hard-requires that quest):
      - the quest's own page:  "'''Title''' is a/an (optional) [[breadcrumb]]...", "This (quest) is a/an/the (optional)
        breadcrumb...", "This (optional) breadcrumb (quest)..."
      - another quest's chain listing: "[[X]] (optional breadcrumb)", "[[X]] (breadcrumb to ...)",
        "Optional breadcrumb: [[X]]", "Breadcrumbs: [[X]] ..." (and the sub-bullets under it)
  * edge-level, "(optional)" after a link in the quest's own questbox `previous=` field: that one predecessor is
    optional for that one quest.
  A plain "(optional)" in a Progression list is NOT trusted (it also marks side quests whose own follow-ups need them).
Soft predecessors are dropped from the prerequisite set; what is left keeps the guide's semantics ("p1;p2" = any one of
them opens the quest, "p1&p2" = all of them).  A quest whose prerequisites were all soft gets no entry.

Format (lazy-parsed by Core/Skip.lua on first use, so loading the file costs one string per field):
  pre   = "q:p1;p2\\n..."  hard prerequisites of q (any one) / "q:p1&p2" (all)
  free  = "q:p1,p2\\n..."  predecessors of q the guides list but that were dropped as soft (breadcrumb / optional): a
                           guide step of q that waits on one of them stops waiting once the player skips it
  crumb = "p1,p2,..."      breadcrumb quests (no quest hard-requires them), for guides this index is not built from
  never = "q1,q2,..."      quests the hard prerequisites make unobtainable (a cycle with no way in, and what needs it);
                           a skip cannot lock what was never obtainable
  name  = "q=Title\\n..."  names for quests in any edge (the wiki's / guide's title; the client's own name wins in game)
"""
import datetime
import os
import re
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GUIDES = ROOT / "CompletionRoute" / "Guides"
OUT = ROOT / "CompletionRoute" / "Data"
WIKI = ROOT / "tools" / "wiki" / "wiki.sqlite"
RAW = ROOT / "tools" / "wiki" / "cache" / "wiki_raw.sqlite"
FLAVORS = ["era", "tbc", "mop", "retail", "forever"]

# tags G.ParseLine consumes without a value (Core/Guide.lua); every other tag takes the next field
BOOL_TAGS = {"O", "S", "US", "S!US", "NC", "NA", "NOAUTO", "CC", "CS", "CN", "ROUTE", "FIXED", "RUNE", "ELITE", "RARE",
             "DUNGEON", "CHAT", "H", "I", "V", "FAIL", "AP", "CT", "MS", "TOF", "EAB", "NOCACHE"}
TEXT_BLOCK = re.compile(r"text\s*=\s*\[(=*)\[(.*?)\]\1\]", re.S)
PLACEHOLDER = re.compile(r"^Quest \d+")


def intlist(v):
    """Core/Guide.lua intlist: every number, 'and' when the list has '&' (else any-one)."""
    nums = [int(n) for n in re.findall(r"\d+", v or "")]
    return nums, ("and" if "&" in (v or "") else "or")


def parse_line(line):
    """-> (action, title, qids, pre, andor) for one guide line, or None"""
    line = line.strip()
    if len(line) < 3 or line[1] != " " or line.startswith(";") or line.startswith("--"):
        return None
    parts = line.split("|")
    action, title = parts[0][0], parts[0][2:].strip()
    qids, pre, andor = [], [], "or"
    i = 1
    while i < len(parts):
        tag = parts[i].strip()
        val = parts[i + 1] if i + 1 < len(parts) else None
        if tag == "":
            i += 1
            continue
        if tag in BOOL_TAGS:
            i += 1
            continue
        if tag == "QID":
            qids = intlist(val)[0]
        elif tag == "PRE":
            pre, andor = intlist(val)
        i += 2
    return action, title, qids, pre, andor


def read_source(path):
    """-> (present: set of quest ids, pre: {q: (set, andor)}, names: {q: title})"""
    present, pre, names = set(), {}, {}
    if not path.exists():
        return present, pre, names
    text = path.read_text(encoding="utf-8", errors="replace")
    for m in TEXT_BLOCK.finditer(text):
        for line in m.group(2).splitlines():
            r = parse_line(line)
            if not r:
                continue
            action, title, qids, p, andor = r
            for q in qids:
                present.add(q)
                if action in ("A", "a") and title and not PLACEHOLDER.match(title) and q not in names:
                    names[q] = title
                if p:
                    s, ao = pre.get(q, (set(), "or"))
                    s.update(x for x in p if x != q)
                    pre[q] = (s, "and" if (ao == "and" or andor == "and") else "or")
    return present, pre, names


# ---------------------------------------------------------------------------
# Breadcrumbs (wiki wikitext, read-only)
# ---------------------------------------------------------------------------
SELF = [re.compile(p, re.I) for p in (
    r"'''[^'\n]+'''\s+is\s+(?:an?\s+)?(?:optional\s+|primary\s+)*(?:\[\[)?breadcrumb",
    r"\bthis\s+(?:quest\s+)?is\s+(?:an?|the)\s+(?:optional\s+|primary\s+)*(?:\[\[)?breadcrumb",
    r"\bthis\s+(?:optional\s+)?breadcrumb\b",
)]
LINK = r"\[\[([^\]|#\n]+)(?:\|[^\]\n]*)?\]\]"
MARK_CRUMB = re.compile(LINK + r"[^\n\[]{0,40}?\(\s*(?:optional\s+)?breadcrumb", re.I)
CRUMB_LIST = re.compile(r"(?:optional\s+)?breadcrumbs?\s*:", re.I)
PREV_FIELD = re.compile(r"\|\s*previous\s*=([^|}]*(?:\}\}[^|}]*)?)", re.I)
PREV_OPT = re.compile(LINK + r"\s*\(\s*optional", re.I)


def norm_title(t):
    t = (t or "").strip().replace("_", " ")
    return t[:1].upper() + t[1:] if t else t


def crumb_lists(text):
    """links named after a 'Breadcrumbs:' / 'Optional breadcrumb:' label, on its line and the deeper bullets under it"""
    out = []
    lines = text.splitlines()
    for i, ln in enumerate(lines):
        m = CRUMB_LIST.search(ln)
        if not m:
            continue
        out += re.findall(LINK, ln[m.end():])
        depth = len(re.match(r"^[#*:]*", ln).group(0))
        for nxt in lines[i + 1:]:
            d = len(re.match(r"^[#*:]*", nxt).group(0))
            if d <= depth or not nxt.strip():
                break
            out += re.findall(LINK, nxt)
    return out


def load_crumbs():
    """-> (crumb_titles: set of page titles that are breadcrumbs, soft_prev: {page_title: set of predecessor titles},
           evidence: {title: reason})"""
    crumbs, soft_prev, why = set(), {}, {}
    if not RAW.exists():
        return crumbs, soft_prev, why
    raw = sqlite3.connect(f"file:{RAW}?immutable=1", uri=True)
    for title, w in raw.execute("select title, wikitext from pages where ns=0 and template='Questbox'"):
        if not w:
            continue
        body = w.split("==Patch changes==")[0]
        if any(p.search(body) for p in SELF):
            crumbs.add(title)
            why.setdefault(title, "own page")
        for x in MARK_CRUMB.findall(body):
            crumbs.add(norm_title(x))
            why.setdefault(norm_title(x), f"marked on {title}")
        for x in crumb_lists(body):
            crumbs.add(norm_title(x))
            why.setdefault(norm_title(x), f"listed on {title}")
        for fld in PREV_FIELD.findall(body):
            for x in PREV_OPT.findall(fld):
                soft_prev.setdefault(title, set()).add(norm_title(x))
    raw.close()
    return crumbs, soft_prev, why


class Titles:
    """wiki page title -> quest ids (redirects followed)"""
    def __init__(self):
        self.ok = WIKI.exists()
        self.by_page, self.redir, self.page_of = {}, {}, {}
        if not self.ok:
            return
        db = sqlite3.connect(f"file:{WIKI}?mode=ro", uri=True)
        for qid, page in db.execute("select id, page_title from quests where id is not null"):
            self.by_page.setdefault(page, set()).add(int(qid))
        for a, b in db.execute("select from_title, to_title from redirects"):
            self.redir[a] = b
        for fl, qid, page in db.execute("select flavor, quest_id, page_title from flavor_quests"):
            self.page_of[(fl, int(qid))] = page
        db.close()

    def ids(self, title):
        t = norm_title(title)
        for _ in range(4):
            if t in self.by_page:
                return self.by_page[t]
            if t not in self.redir:
                break
            t = norm_title(self.redir[t])
        return set()


def lua_long(s):
    eq = "=="
    while ("]" + eq + "]") in s:
        eq += "="
    return "[" + eq + "[\n" + s + "]" + eq + "]"


def build(fl, crumbs, soft_prev, titles, use_crumbs, wiki_only=False):
    sources = [GUIDES / f"Imported_Wiki_{fl}.lua"]
    if not wiki_only:
        sources += [GUIDES / f"Imported_Quests_{fl}_gaps.lua", GUIDES / f"Imported_Storylines_{fl}.lua"]
    owner, pre, names = {}, {}, {}
    for rank, path in enumerate(sources):
        present, p, n = read_source(path)
        for q in present:
            if q not in owner:
                owner[q] = rank
                if q in p:
                    pre[q] = p[q]
        for q, t in n.items():
            names.setdefault(q, t)
    universe = set(owner)
    # breadcrumb flags as quest ids for this client
    crumb_ids, soft_edges = set(), set()
    if use_crumbs and titles.ok:
        for t in crumbs:
            crumb_ids |= titles.ids(t)
        for (f2, q), page in titles.page_of.items():
            if f2 == fl and page in soft_prev:
                for t in soft_prev[page]:
                    for p in titles.ids(t):
                        soft_edges.add((q, p))
    stats = {"quests": len(universe), "with_pre": 0, "edges": 0, "soft_crumb": 0, "soft_optional": 0, "freed": 0}
    rows, free_rows = [], []
    in_edges = set()
    hard_of = {}
    for q in sorted(pre):
        ps, andor = pre[q]
        hard, soft = set(), set()
        for p in ps:
            stats["edges"] += 1
            if p in crumb_ids:
                stats["soft_crumb"] += 1
                soft.add(p)
            elif (q, p) in soft_edges:
                stats["soft_optional"] += 1
                soft.add(p)
            else:
                hard.add(p)
        if soft:
            free_rows.append(f"{q}:" + ",".join(str(p) for p in sorted(soft)))
        if not hard:
            stats["freed"] += 1
            continue
        stats["with_pre"] += 1
        hard_of[q] = (hard, andor)
        rows.append(f"{q}:" + ("&" if andor == "and" else ";").join(str(p) for p in sorted(hard)))
        in_edges.add(q)
        in_edges |= hard
    never = unobtainable(hard_of)
    stats["never"] = len(never)
    name_rows = [f"{q}={names[q]}" for q in sorted(in_edges) if q in names]
    return rows, free_rows, sorted(never), name_rows, stats, crumb_ids & universe


def unobtainable(hard_of):
    """quests no order of play can reach: least fixpoint forward from the quests with no hard prerequisite.
    A quest opens when any one of its 'or' prerequisites (all of its 'and' ones) is open."""
    deps = {}
    for q, (ps, _) in hard_of.items():
        for p in ps:
            deps.setdefault(p, []).append(q)
    opened = set()
    work = [p for ps, _ in hard_of.values() for p in ps if p not in hard_of]
    seen = set()
    stack = []
    for p in work:
        if p not in seen:
            seen.add(p)
            stack.append(p)
    # quests outside hard_of have no hard prerequisite: open
    while stack:
        p = stack.pop()
        for q in deps.get(p, ()):
            if q in opened:
                continue
            ps, andor = hard_of[q]
            ok = all((x not in hard_of) or (x in opened) for x in ps) if andor == "and" else \
                any((x not in hard_of) or (x in opened) for x in ps)
            if ok:
                opened.add(q)
                stack.append(q)
    return set(hard_of) - opened


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    use_crumbs = "--no-crumbs" not in sys.argv
    wiki_only = "--wiki-only" in sys.argv
    fls = args or FLAVORS
    crumbs, soft_prev, why = load_crumbs() if use_crumbs else (set(), {}, {})
    titles = Titles()
    if use_crumbs and not RAW.exists():
        print("note: tools/wiki/cache/wiki_raw.sqlite missing - no breadcrumb detection (every PRE edge is hard)")
    print(f"breadcrumb pages: {len(crumbs)}, pages with an optional previous link: {len(soft_prev)}")
    today = datetime.date.today().isoformat()
    for fl in fls:
        if not (GUIDES / f"Imported_Wiki_{fl}.lua").exists():
            print(f"skip {fl}: Guides/Imported_Wiki_{fl}.lua missing")
            continue
        rows, free_rows, never, name_rows, st, crumb_q = build(fl, crumbs, soft_prev, titles, use_crumbs, wiki_only)
        out = OUT / f"QuestDeps_{fl}.lua"
        body = [
            f"-- Completionist's Guide :: QuestDeps_{fl}.lua - GENERATED {today} by tools/gen_quest_deps.py",
            "-- Quest prerequisites (hard ones only) for quest-level skipping, Core/Skip.lua. Chains and names come from the",
            f"-- generated guides this client loads: Imported_Wiki_{fl}.lua (Warcraft Wiki, https://warcraft.wiki.gg, CC BY-SA 4.0,",
            "-- see Guides/WIKI_DATA_LICENSE.md)" + (". Sources: Warcraft Wiki only (release build, --wiki-only)." if wiki_only else
            ", then the gaps guides (Questie-derived) and the retail storylines (Blizzard quest-line order, Questie names) for quests"
            "\n-- the wiki lacks. Local build: it never ships (tools/package_release.py needs the --wiki-only build)."),
            "-- Breadcrumbs (the wiki's own wording) are dropped from every prerequisite set. Generated, gitignored.",
            "-- pre: q:p1;p2 = any one of p1, p2 opens q; q:p1&p2 = all of them.  free: q:p1,p2 = soft predecessors of q the",
            "-- guides list.  crumb: breadcrumb quests.  never: quests the hard prerequisites make unobtainable.  name: q=title.",
            "local _, NS = ...",
            f'if (NS.dataFlavor or NS.flavor) ~= "{fl}" then return end',
            f'NS.QuestDeps = {{ flavor = "{fl}", n = {len(rows)}, soft = {st["soft_crumb"] + st["soft_optional"]},',
            "pre = " + lua_long("\n".join(rows) + "\n") + ",",
            "free = " + lua_long("\n".join(free_rows) + "\n") + ",",
            'crumb = "' + ",".join(str(q) for q in sorted(crumb_q)) + '",',
            'never = "' + ",".join(str(q) for q in never) + '",',
            "name = " + lua_long("\n".join(name_rows) + "\n") + " }",
            "",
        ]
        tmp = out.with_suffix(".lua.tmp")
        tmp.write_text("\n".join(body), encoding="utf-8")
        os.replace(tmp, out)
        print(f"{fl}: {st['quests']} quests, {st['with_pre']} with hard prerequisites, {st['edges']} PRE edges, "
              f"{st['soft_crumb']} breadcrumb edges and {st['soft_optional']} optional edges dropped "
              f"({st['freed']} quests left with none), {len(crumb_q)} breadcrumb quests on this client, "
              f"{len(free_rows)} quests with freed predecessors, {st['never']} unobtainable by the data, "
              f"{len(name_rows)} names -> {out.relative_to(ROOT)} ({out.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
