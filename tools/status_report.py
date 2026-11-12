#!/usr/bin/env python3
# CompletionRoute :: tools/status_report.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""One headline table per flavor from docs/verification.sqlite and tools/wiki/wiki.sqlite.

    python3 tools/status_report.py [--markdown] [--label L]

Reads SQL only and writes nothing.  A number whose table or row does not exist yet prints as "-", never as 0.
--label L reads the coverage rows of one tools/coverage.py label; default: the newest.  There is one build, so every
number describes what the TOCs load, tools/install.sh installs and a release ships.

  guides        zone guides the generator wrote (wiki.sqlite gen_stats) and, in brackets, spine guides (guide_parts/spine_order)
  quests        quest ids in a loaded guide / quest ids the client has (coverage, newest label)
  located       share of those covered quests with a map point (coverage)
  zone only     share of the covered quests with no point but a step that names the zone (coverage quest-zone; "-" for a
                label measured before 2026-11-11 night, which has no such row)
  no location   the rest of the covered quests: no point and no zone
  ach located   achievements with a point or a zone-only step / achievements minus the non-geographic ones (the plan's
                80% target; coverage rows achievement, achievement-zone, achievement-nongeo of one label)
  item quests   item-started quests whose accept step (where the item is obtained) has a point or a zone (coverage
                item-quest, item-quest-zone), of all item-started quests the client has
  vplayer       finished / guides of the newest vplayer run, and its stalls
  route gain    vplayer travel time saved, baked + live against author + live (route_compare, guides in the sample)
  slower        guides more than 1% slower in that comparison
  violations    precedence violations from every checker (opt_violations, spine_violations pre_after)
  gold, prof    guides from the gold / profession generators, when their tables exist
"""
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERIF = ROOT / "docs" / "verification.sqlite"
WIKI = ROOT / "tools" / "wiki" / "wiki.sqlite"
FLAVORS = ["era", "tbc", "mop", "retail", "forever"]


def open_ro(path):
    if not path.exists():
        return None
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True)


def has_table(con, name):
    return con is not None and con.execute("select 1 from sqlite_master where name = ? and type in ('table', 'view')", (name,)).fetchone() is not None


def columns(con, name):
    return [r[1] for r in con.execute(f"pragma table_info({name})")]


def one(con, sql, args=()):
    """the first row, or None when the query has nothing to say (a missing column is a missing number, not a crash)"""
    try:
        return con.execute(sql, args).fetchone()
    except sqlite3.Error:
        return None


def pct(a, b):
    return f"{100.0 * a / b:.1f}%" if b else "-"


LABEL = None


def coverage(con, fl, category, label=None):
    if not has_table(con, "coverage"):
        return None
    label = label or LABEL
    if label:
        return one(con, "select total, covered, located, label from coverage where flavor = ? and category = ? and label = ?",
                   (fl, category, label))
    return one(con, "select total, covered, located, label from coverage where flavor = ? and category = ? "
                    "order by measured desc, label limit 1", (fl, category))


def ach_share(con, fl):
    """(point + zone-only) / (total - non-geographic), all from the same label as the achievement row"""
    a = coverage(con, fl, "achievement")
    if not a or not a[0]:
        return "-"
    z, n = coverage(con, fl, "achievement-zone", a[3]), coverage(con, fl, "achievement-nongeo", a[3])
    if not z or not n:
        return pct(a[2], a[1])
    return pct((a[2] or 0) + z[1], a[0] - n[1])


def quest_zone(con, fl, q):
    """(zone-only share, no-location share) of the covered quests, from the same label as the quest row"""
    z = coverage(con, fl, "quest-zone", q[3]) if q else None
    if not q or not q[1] or not z:
        return "-", "-"
    return pct(z[1], q[1]), pct(q[1] - (q[2] or 0) - z[1], q[1])


def item_share(con, fl):
    q = coverage(con, fl, "item-quest")
    if not q or not q[0]:
        return "-"
    z = coverage(con, fl, "item-quest-zone", q[3])
    return f"{(q[2] or 0) + (z[1] if z else 0)}/{q[0]}"


def wiki_guides(con, fl):
    if not has_table(con, "gen_stats"):
        return None
    r = one(con, "select value from gen_stats where flavor = ? and metric = 'guides'", (fl,))
    return r[0] if r else None


def spine_guides(con, fl):
    if not has_table(con, "spine_order"):
        return None
    r = one(con, "select count(*) from spine_order where flavor = ?", (fl,))
    return r[0] if r and r[0] else None


def route(con, fl):
    if not has_table(con, "route_compare"):
        return None
    r = one(con, "select sum(window_s), sum(baked_live_s), count(*), "
                 "sum(case when baked_live_s > window_s * 1.01 then 1 else 0 end) "
                 "from route_compare where flavor = ? and window_s is not null and baked_live_s is not null", (fl,))
    return r if r and r[0] else None


def violations(con, fl):
    total, seen = 0, False
    if has_table(con, "opt_violations"):
        r = one(con, "select sum(violations), count(*) from opt_violations where flavor = ?", (fl,))
        if r and r[1]:
            total, seen = total + (r[0] or 0), True
    if has_table(con, "spine_violations"):
        cols = columns(con, "spine_violations")
        if "reason" in cols:
            r = one(con, "select count(*) from spine_violations where flavor = ? and reason = 'pre_after'", (fl,))
            if r is not None:
                total, seen = total + r[0], True
    return total if seen else None


def vplayer(con, fl):
    if not has_table(con, "vplayer_runs"):
        return None
    return one(con, "select finished, guides, stalls, no_route, at from vplayer_runs where flavor = ? order by at desc limit 1", (fl,))


def count_guides(con, table, fl):
    """rows of a generator's table for this flavor, or None when that generator has not charted anything"""
    if not has_table(con, table):
        return None
    if "flavor" not in columns(con, table):
        return None
    r = one(con, f"select count(*) from {table} where flavor = ?", (fl,))
    return r[0] if r else None


def first_count(cons, tables, fl):
    for con in cons:
        for t in tables:
            n = count_guides(con, t, fl)
            if n is not None:
                return n
    return None


def show(v):
    return "-" if v is None else str(v)


def rows():
    verif, wiki = open_ro(VERIF), open_ro(WIKI)
    out = []
    for fl in FLAVORS:
        q = coverage(verif, fl, "quest")
        ach = coverage(verif, fl, "achievement")
        rc = route(verif, fl)
        vp = vplayer(verif, fl)
        zone, spine = wiki_guides(wiki, fl), spine_guides(verif, fl)
        qz, qn = quest_zone(verif, fl, q)
        out.append({
            "flavor": fl,
            "guides": f"{show(zone)} ({show(spine)})",
            "quests": f"{q[1]} / {q[0]}" if q else "-",
            "covered": pct(q[1], q[0]) if q else "-",
            "located": pct(q[2], q[1]) if q else "-",
            "zone only": qz,
            "no location": qn,
            "ach located": ach_share(verif, fl) if ach and ach[1] else "-",
            "item quests": item_share(verif, fl),
            "vplayer": f"{vp[0]}/{vp[1]} ({vp[2]} stalls)" if vp else "-",
            "route gain": pct(rc[0] - rc[1], rc[0]) if rc else "-",
            "slower": f"{rc[3]}/{rc[2]}" if rc else "-",
            "violations": show(violations(verif, fl)),
            "gold": show(first_count((verif, wiki), ("gold_guides", "gold_routes"), fl)),
            "prof": show(first_count((verif, wiki), ("profession_guides", "prof_guides"), fl)),
        })
    return out


def main():
    global LABEL
    if "--label" in sys.argv:
        LABEL = sys.argv[sys.argv.index("--label") + 1]
    table = rows()
    heads = list(table[0])
    if "--markdown" in sys.argv:
        print("| " + " | ".join(heads) + " |")
        print("|" + "---|" * len(heads))
        for r in table:
            print("| " + " | ".join(r[h] for h in heads) + " |")
        return
    widths = {h: max(len(h), *(len(r[h]) for r in table)) for h in heads}
    print("  ".join(h.ljust(widths[h]) for h in heads))
    print("  ".join("-" * widths[h] for h in heads))
    for r in table:
        print("  ".join(r[h].ljust(widths[h]) for h in heads))


if __name__ == "__main__":
    main()
