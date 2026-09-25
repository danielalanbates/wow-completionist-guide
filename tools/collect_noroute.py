#!/usr/bin/env python3
# CompletionRoute :: tools/collect_noroute.py
# Copyright (c) 2026 Daniel Bates / BatesAI. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Fold a vplayer re-run of the no_route guides into docs/verification.sqlite.

    luajit tools/vplayer.lua <fl> --guides-file <ids> --out DIR/vp_<fl>[_n].tsv   (writes *_noroute.tsv too)
    python3 tools/collect_noroute.py DIR [label]

Tables: noroute_rerun (label, flavor, guide, steps, no_route_before, no_route_after, finished, stalls)
and noroute_steps (label, flavor, guide, step, action, from_map, to_map, to_name).
"""
import csv, sqlite3, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
d = Path(sys.argv[1])
label = sys.argv[2] if len(sys.argv) > 2 else "rerun"
con = sqlite3.connect(ROOT / "docs" / "verification.sqlite")
con.execute("create table if not exists noroute_rerun (label text, flavor text, guide text, steps int, "
            "no_route_before int, no_route_after int, finished int, stalls int)")
con.execute("create table if not exists noroute_steps (label text, flavor text, guide text, step int, action text, "
            "from_map text, to_map text, to_name text)")
con.execute("delete from noroute_rerun where label=?", (label,))
con.execute("delete from noroute_steps where label=?", (label,))
before = {(f, g): n for f, g, n in con.execute("select flavor, guide, no_route from vplayer_guides")}
for p in sorted(d.glob("vp_*.tsv")):
    if p.name.endswith(("_stalls.tsv", "_noroute.tsv")):
        continue
    for r in csv.DictReader(p.open(encoding="utf-8"), delimiter="\t"):
        con.execute("insert into noroute_rerun values (?,?,?,?,?,?,?,?)",
                    (label, r["flavor"], r["guide"], int(r["steps"]), before.get((r["flavor"], r["guide"])),
                     int(r["no_route"]), int(r["finished"]), int(r["stalls"])))
    nr = p.with_name(p.stem + "_noroute.tsv")
    if nr.exists():
        for r in csv.DictReader(nr.open(encoding="utf-8"), delimiter="\t"):
            con.execute("insert into noroute_steps values (?,?,?,?,?,?,?,?)",
                        (label, r["flavor"], r["guide"], int(r["step"]), r["action"], r["from_map"], r["to_map"], r["to_name"]))
con.commit()
for row in con.execute("select flavor, count(*), sum(no_route_before), sum(no_route_after), sum(finished), sum(stalls) "
                       "from noroute_rerun where label=? group by flavor", (label,)):
    print("flavor %s: %d guides, no_route %s -> %s, finished %s, stalls %s" % row)
