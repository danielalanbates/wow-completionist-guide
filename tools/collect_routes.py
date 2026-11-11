#!/usr/bin/env python3
"""CompletionRoute :: tools/collect_routes.py - fold the offline route optimizer results into docs/verification.sqlite.

  python3 tools/collect_routes.py sample <flavor> [N]     -> <job tmp>/routeopt/<flavor>_sample.txt (N guides, default 150,
                                                            evenly spread over the optimized guides, for vplayer)
  python3 tools/collect_routes.py collect [flavor ...]   -> tables route_compare, opt_violations

route_compare (one row per optimized quest guide):
  author_s, baked_s, lower_bound_s, opt_gap - travel seconds in the optimizer's model (tools/cost_matrix.lua matrices,
      Router.TravelSeconds between located steps, from the guide zone's centre); baked_s = author_s when the bake found
      no gain (then the guide is not written to Data/RouteOrder_<flavor>.lua)
  window_s      - vplayer seconds, author order + the live 12-step window (what the addon did before the bake)
  baked_live_s  - vplayer seconds, baked order + the live window (what the addon does now)
  vp_author_s, vp_baked_s - vplayer seconds with the live window OFF (cross-check of the model numbers)
  NULL vplayer columns = guide not in the vplayer sample.
opt_violations (one row per flavor and checker; violations must be 0):
  source 'optimizer' = the solver's own step-level check; 'test_route_order' = tools/test_route_order.lua on the parsed
  guides in the Lua harness.
"""
import csv
import json
import os
import re
import sqlite3
import subprocess
import sys

TMP = os.environ.get("CR_TMP") or os.path.expanduser("~/.claude/jobs/ff3c728a/tmp")   # as tools/optimize_routes.py
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB = os.path.join(REPO, "docs", "verification.sqlite")
FLAVORS = ["era", "tbc", "mop", "retail", "forever"]
VP = {"window": ("author", "on"), "baked_live": ("baked", "on"), "vp_author": ("author", "off"), "vp_baked": ("baked", "off")}


def rows_of(fl):
    p = os.path.join(TMP, "routeopt", fl + ".jsonl")
    if not os.path.exists(p):
        return []
    return [json.loads(l) for l in open(p)]


def vp_path(fl, key):
    o, live = VP[key]
    return os.path.join(TMP, "routeopt", "vp_%s_%s_%s.tsv" % (fl, o, live))


def read_vp(fl, key):
    p = vp_path(fl, key)
    out = {}
    if not os.path.exists(p):
        return out
    with open(p) as f:
        for r in csv.DictReader(f, delimiter="\t"):
            out[r["guide"]] = r
    return out


def sample(fl, n=150):
    rows = sorted(rows_of(fl), key=lambda r: r["id"])
    if not rows:
        sys.exit("no optimizer rows for " + fl)
    if len(rows) <= n:
        pick = rows
    else:
        step = len(rows) / n
        pick = [rows[int(i * step)] for i in range(n)]
    p = os.path.join(TMP, "routeopt", fl + "_sample.txt")
    with open(p, "w") as f:
        for r in pick:
            f.write(r["id"] + "\n")
    print("%s: %d of %d guides -> %s" % (fl, len(pick), len(rows), p))


def baked_ids(fl):
    p = os.path.join(REPO, "CompletionRoute", "Data", "RouteOrder_%s.lua" % fl)
    if not os.path.exists(p):
        return set()
    return set(re.findall(r'^O\["([^"]+)"\]', open(p).read(), re.M))


def collect(flavors):
    con = sqlite3.connect(DB)
    con.execute("""CREATE TABLE IF NOT EXISTS route_compare (flavor TEXT, guide_id TEXT, steps INTEGER, author_s REAL,
        window_s REAL, baked_s REAL, baked_live_s REAL, lower_bound_s REAL, opt_gap REAL, blocks INTEGER, segments INTEGER,
        method TEXT, lb_exact INTEGER, solve_s REAL, noroute_author INTEGER, noroute_baked INTEGER, in_route_order INTEGER,
        vp_author_s REAL, vp_baked_s REAL, vp_finished_author INTEGER, vp_finished_baked INTEGER, vp_stalls_baked INTEGER,
        PRIMARY KEY (flavor, guide_id))""")
    con.execute("""CREATE TABLE IF NOT EXISTS opt_violations (flavor TEXT, source TEXT, guides INTEGER, steps INTEGER,
        violations INTEGER, detail TEXT, PRIMARY KEY (flavor, source))""")
    # the Lua-side check, once for all flavors
    lua = {}
    try:
        outp = subprocess.run(["luajit", "tools/test_route_order.lua"], cwd=REPO, capture_output=True, text=True, timeout=1800).stdout
        for m in re.finditer(r"^(?:ok|BAD)\s+(\w+)\s+(\d+) entries, (\d+) guides baked \((\d+) spine\), (\d+) steps, (\d+) moved, (\d+) violations", outp, re.M):
            lua[m.group(1)] = (int(m.group(3)), int(m.group(5)), int(m.group(7)), "%s entries, %s spine, %s moved" % (m.group(2), m.group(4), m.group(6)))
        fails = [l for l in outp.splitlines() if l.startswith("FAIL")]
    except Exception as e:  # pragma: no cover
        fails = ["test_route_order did not run: %s" % e]
    for fl in flavors:
        rows = rows_of(fl)
        if not rows:
            continue
        written = baked_ids(fl)
        vps = {k: read_vp(fl, k) for k in VP}
        con.execute("DELETE FROM route_compare WHERE flavor = ?", (fl,))

        def sec(k, gid):
            r = vps[k].get(gid)
            return float(r["seconds"]) if r else None

        def fin(k, gid):
            r = vps[k].get(gid)
            return int(r["finished"]) if r else None
        for r in rows:
            gid = r["id"]
            inro = gid in written
            baked_s = r["baked_s"] if inro else r["author_s"]
            con.execute("INSERT INTO route_compare VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (
                fl, gid, r["steps"], r["author_s"], sec("window", gid), baked_s, sec("baked_live", gid),
                r["lower_bound_s"], (baked_s - r["lower_bound_s"]) / baked_s if baked_s > 0 else 0.0,
                r["blocks"], r["segments"], r["method"], r["lb_exact"], r["solve_s"], r["noroute_author"],
                r["noroute_baked"] if inro else r["noroute_author"], int(inro), sec("vp_author", gid), sec("vp_baked", gid),
                fin("window", gid), fin("baked_live", gid),
                int(vps["baked_live"][gid]["stalls"]) if gid in vps["baked_live"] else None))
        nviol = sum(r["violations"] for r in rows)
        con.execute("INSERT OR REPLACE INTO opt_violations VALUES (?,?,?,?,?,?)", (
            fl, "optimizer", len(rows), sum(r["steps"] for r in rows), nviol,
            "%d guides written to Data/RouteOrder_%s.lua; %d PRE/lifecycle edges the author order breaks were not enforced" % (
                len(written), fl, sum(r.get("dropped_edges", 0) for r in rows))))
        if fl in lua:
            g, st, v, d = lua[fl]
            det = d + ("; " + " | ".join(f for f in fails if fl in f)[:500] if any(fl in f for f in fails) else "")
            con.execute("INSERT OR REPLACE INTO opt_violations VALUES (?,?,?,?,?,?)", (fl, "test_route_order", g, st, v, det))
        print("%s: %d route_compare rows (%d in RouteOrder), vplayer rows %s, optimizer violations %d, lua %s" % (
            fl, len(rows), len(written), {k: len(v) for k, v in vps.items()}, nviol, lua.get(fl)))
    con.commit()
    con.close()


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "sample":
        sample(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 150)
    elif len(sys.argv) >= 2 and sys.argv[1] == "collect":
        collect(sys.argv[2:] or FLAVORS)
    else:
        sys.exit(__doc__)
