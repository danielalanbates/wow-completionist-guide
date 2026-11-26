#!/usr/bin/env python3
# CompletionRoute :: tools/forever_unmapped.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Chart the WoW Forever quest ids the Era client does not have, and why each one is in no Forever guide.

    python3 tools/forever_unmapped.py            # prints counts, rewrites docs/verification.sqlite forever_unmapped
    python3 tools/forever_unmapped.py --dry-run

Inputs (all offline): tools/db2/{era,forever}/QuestV2.csv decide the Forever-only ids; tools/wiki/wiki.sqlite (quests,
flavor_skip) says which have a wiki page and why the generator skipped one; Guides/Imported_*_forever.lua say which
ids a Forever guide carries; the Forever client's own QuestPOIBlob, QuestLineXQuest/QuestLine and Criteria/CriteriaTree/
Achievement tables (tools/wiki/db2_fetch.py, build in tools/db2/forever/BUILD) give a map, a quest line name or an
achievement criterion where the client has one.  The client data carries no quest names (those come from the server),
so an id without a wiki page is never made into a guide step here; it is listed with what the client does say.

Table forever_unmapped(quest_id, reason, wiki_page, ui_map, quest_line, criterion, at): one row per Forever-only id
that no Forever guide carries.  Table forever_only_summary: counts per run.
"""
import csv, datetime, glob, re, sqlite3, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DB2 = ROOT / "tools" / "db2"
csv.field_size_limit(1 << 28)


def rows(fl, t):
    p = DB2 / fl / f"{t}.csv"
    return list(csv.DictReader(p.open(encoding="utf-8"))) if p.exists() else []


def main():
    dry = "--dry-run" in sys.argv
    fo = {int(r["ID"]) for r in rows("forever", "QuestV2")} - {int(r["ID"]) for r in rows("era", "QuestV2")}
    w = sqlite3.connect(ROOT / "tools" / "wiki" / "wiki.sqlite")
    page = {i: t for i, t in w.execute("SELECT id, page_title FROM quests")}
    skip = {q: why for q, why in w.execute("SELECT quest_id, reason FROM flavor_skip WHERE flavor='forever'")}
    guided = set()
    for f in glob.glob(str(ROOT / "CompletionRoute" / "Guides" / "Imported_*_forever.lua")):
        guided |= {int(x) for x in re.findall(r"QID\|(\d+)", Path(f).read_text(encoding="utf-8"))}
    poi = {}
    for r in rows("forever", "QuestPOIBlob"):
        poi.setdefault(int(r["QuestID"] or 0), r["UiMapID"])
    qln = {r["ID"]: r["Name_lang"] for r in rows("forever", "QuestLine")}
    qline = {int(r["QuestID"]): qln.get(r["QuestLineID"], r["QuestLineID"]) for r in rows("forever", "QuestLineXQuest")}
    ctdesc = {}
    for r in rows("forever", "CriteriaTree"):
        if r["CriteriaID"] != "0" and r["Description_lang"]:
            ctdesc[r["CriteriaID"]] = r["Description_lang"]
    crit = {int(r["Asset"]): ctdesc.get(r["ID"], f"criteria {r['ID']}") for r in rows("forever", "Criteria")
            if r["Type"] == "27"}
    out = []
    for q in sorted(fo - guided):
        if q in page:
            why = "wiki page skipped: " + skip.get(q, "no step written (see flavor_skip)")
        elif q in poi or q in qline or q in crit:
            why = "no wiki page; client data has no quest name (map/quest line/criterion only)"
        else:
            why = "no wiki page; no client data beyond the id"
        out.append((q, why, page.get(q), poi.get(q), qline.get(q), crit.get(q)))
    from collections import Counter
    c = Counter(r[1] for r in out)
    paged = fo & set(page)
    print(f"forever-only ids {len(fo)}; with wiki page {len(paged)}, in a guide {len(paged & guided)}; "
          f"no page {len(fo - set(page))}, in a guide {len((fo - set(page)) & guided)}; unmapped {len(out)}")
    for k, v in c.most_common():
        print(f"  {v:5d}  {k}")
    if dry:
        return 0
    at = datetime.datetime.now().isoformat(timespec="seconds")
    v = sqlite3.connect(ROOT / "docs" / "verification.sqlite")
    v.execute("DROP TABLE IF EXISTS forever_unmapped")
    v.execute("CREATE TABLE forever_unmapped(quest_id int PRIMARY KEY, reason text, wiki_page text, ui_map int, "
              "quest_line text, criterion text, at text)")
    v.executemany("INSERT INTO forever_unmapped VALUES(?,?,?,?,?,?,?)", [r + (at,) for r in out])
    v.execute("CREATE TABLE IF NOT EXISTS forever_only_summary(at text, forever_only int, with_page int, "
              "page_in_guide int, no_page int, unmapped int)")
    v.execute("INSERT INTO forever_only_summary VALUES(?,?,?,?,?,?)",
              (at, len(fo), len(paged), len(paged & guided), len(fo - set(page)), len(out)))
    v.commit()
    return 0


if __name__ == "__main__":
    sys.exit(main())
