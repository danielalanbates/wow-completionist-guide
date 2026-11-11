#!/usr/bin/env python3
"""Completionist's Guide :: tools/bake_resume.py - resumable offline route bake.

Copyright (c) 2026 Daniel Bates. All rights reserved. PolyForm Noncommercial 1.0.0 + commercial rider (see LICENSE).
https://batesai.org - help@batesai.org

Bakes every quest guide whose result row is missing or stale, one heavy process at a time, and is safe to kill and
re-run: the to-do set is recomputed from `luajit tools/cost_matrix.lua <flavor> --list` (id, step count, checksum)
against the optimizer's result rows on every start, so finished guides are never redone.

A guide is "stale" when its step count or checksum changed. The checksum only covers each step's action and first
quest id, so a guide whose COORDINATES moved looks fresh: name those guides with --force-file, or use --force-mapfix
for the 2026-11-09 Classic map fix (wiki points in Badlands, Arathi Highlands, Swamp of Sorrows, Felwood and
Teldrassil on era/tbc/forever). docs/IDEAS.md "Bake gate and stale-bake check" proposes a coordinate-aware checksum.

Per batch: tools/cost_matrix.lua (travel matrices) -> tools/optimize_routes.py --merge --no-write. At the end the
RouteOrder_<flavor>.lua files of every flavor touched are rewritten from the merged rows.

Guards (8 GB Mac): waits while memory is genuinely short (kernel level critical or < 10% free; level 2 "warn" is
sticky with a game open and is NOT a gate), stops when free disk < 11 GB. Runs at nice 15.

Usage:
  python3 tools/bake_resume.py [--flavors mop,retail] [--dry-run] [--force-mapfix] [--force-file tbc=ids.txt]
                               [--batch 20] [--limit-s S] [--dp-time S]
Default solver limits are optimize_routes.py's own (full quality). Results: <TMP>/routeopt/<flavor>.jsonl, where TMP is
the optimizer's job directory (env CR_TMP, default the path hardcoded in tools/optimize_routes.py).
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "tools"))
FLAVORS = ("tbc", "forever", "era", "mop", "retail")
MAPFIX_ZONES = {"1418", "1417", "1435", "1448", "1438"}   # Badlands, Arathi Highlands, Swamp of Sorrows, Felwood, Teldrassil


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def opt_tmp():
    if os.environ.get("CR_TMP"):
        return os.environ["CR_TMP"]
    src = open(os.path.join(REPO, "tools", "optimize_routes.py"), encoding="utf-8").read()
    return re.search(r'^TMP = "([^"]+)"', src, re.M).group(1)


def python_bin():
    venv = os.path.join(os.path.dirname(REPO), "venv", "bin", "python")
    return venv if os.path.exists(venv) else sys.executable


def tight():
    try:
        lvl = int(subprocess.run(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"],
                                 capture_output=True, text=True).stdout.strip())
        out = subprocess.run(["memory_pressure"], capture_output=True, text=True, timeout=20).stdout
        free = int(out.rsplit("free percentage:", 1)[1].strip().rstrip("%"))
        return lvl >= 4 or free < 10
    except Exception:
        return False


def free_gb():
    st = os.statvfs("/")
    return st.f_bavail * st.f_frsize / 1e9


def current(fl, work):
    lp = os.path.join(work, f"list_{fl}.jsonl")
    subprocess.run(["luajit", "tools/cost_matrix.lua", fl, "--list", "--out", lp], capture_output=True, check=True)
    cur = {}
    for line in open(lp):
        r = json.loads(line)
        cur[r["id"]] = (r["n"], r["sum"])
    return cur


def rows(fl, tmp):
    p = os.path.join(tmp, "routeopt", fl + ".jsonl")
    out = {}
    if os.path.exists(p):
        for line in open(p):
            r = json.loads(line)
            out[r["id"]] = (r.get("n"), r.get("sum"))
    return out


def mapfix_ids(fl, quest_ids):
    if fl not in ("era", "tbc", "forever"):
        return []
    hit = set()
    for name in (f"Imported_Wiki_{fl}.lua", f"Imported_Quests_{fl}_gaps.lua"):
        p = os.path.join(REPO, "CompletionRoute", "Guides", name)
        if not os.path.exists(p):
            continue
        s = open(p, encoding="utf-8").read()
        for m in re.finditer(r'R\(\{ id="([^"]+)".*?text=\[==\[(.*?)\]==\]', s, re.S):
            gid, body = m.group(1), m.group(2)
            if gid in quest_ids and any(f"|Z|{z};" in body or f"|Z|{z}|" in body for z in MAPFIX_ZONES):
                hit.add(gid)
    return sorted(hit)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--flavors", default=",".join(FLAVORS))
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force-mapfix", action="store_true")
    ap.add_argument("--force-file", action="append", default=[], help="FLAVOR=PATH, one guide id per line")
    ap.add_argument("--batch", type=int, default=20)
    ap.add_argument("--limit-s", type=float)
    ap.add_argument("--dp-time", type=float)
    a = ap.parse_args()
    os.chdir(REPO)
    tmp, py = opt_tmp(), python_bin()
    work = tempfile.mkdtemp(prefix="bake_resume_")
    forced = {}
    for spec in a.force_file:
        fl, path = spec.split("=", 1)
        forced.setdefault(fl, set()).update(l.strip() for l in open(path) if l.strip())
    todo = {}
    for fl in a.flavors.split(","):
        cur, done = current(fl, work), rows(fl, tmp)
        ids = [i for i in cur if done.get(i) != cur[i]]
        extra = set(forced.get(fl, set()))
        if a.force_mapfix:
            extra.update(mapfix_ids(fl, set(cur)))
        ids += sorted(i for i in extra if i in cur and i not in ids)
        todo[fl] = ids
        log(f"{fl}: quest guides {len(cur)}, current rows {sum(1 for i in cur if done.get(i) == cur[i])}, to do {len(ids)}"
            + (f" (incl. {len(extra)} forced)" if extra else ""))
    if a.dry_run:
        return
    queue = []
    for fl in ("tbc", "forever", "era"):
        ids = todo.get(fl, [])
        queue += [(fl, ids[i:i + a.batch]) for i in range(0, len(ids), a.batch)]
    m, r = list(todo.get("mop", [])), list(todo.get("retail", []))
    while m or r:
        if m:
            queue.append(("mop", m[:a.batch])); m = m[a.batch:]
        if r:
            queue.append(("retail", r[:a.batch])); r = r[a.batch:]
    total = sum(len(b) for _, b in queue)
    done = failed = 0
    touched, t0 = set(), time.time()
    extra_args = (["--limit-s", str(a.limit_s)] if a.limit_s else []) + (["--dp-time", str(a.dp_time)] if a.dp_time else [])
    for fl, ids in queue:
        if free_gb() < 11:
            log("STOP: free disk", round(free_gb(), 1), "GB"); break
        waited = 0
        while tight() and waited < 1800:
            if waited == 0:
                log("memory tight - waiting")
            time.sleep(30); waited += 30
        gf, cj = os.path.join(work, f"batch_{fl}.txt"), os.path.join(work, f"batch_{fl}.jsonl")
        open(gf, "w").write("\n".join(ids) + "\n")
        p = subprocess.run(["nice", "-n", "15", "luajit", "tools/cost_matrix.lua", fl, "--guides-file", gf, "--out", cj,
                            "--verify", "20"], capture_output=True, text=True)
        if p.returncode != 0:
            log("cost_matrix FAILED", fl, p.stderr[-400:]); failed += len(ids); continue
        p = subprocess.run(["nice", "-n", "15", py, "tools/optimize_routes.py", fl, "--in", cj, "--merge", "--no-write"]
                           + extra_args, capture_output=True, text=True)
        if p.returncode != 0:
            log("optimize FAILED", fl, p.stderr[-400:]); failed += len(ids); continue
        touched.add(fl); done += len(ids)
        el = time.time() - t0
        log(f"{fl} batch ok  {done}/{total}  eta {(total - done) * el / max(done, 1) / 60:.0f} min |",
            (p.stderr.strip().splitlines() or [""])[-1][:110])
    empty = os.path.join(work, "empty.jsonl")
    open(empty, "w").close()
    for fl in sorted(touched):
        p = subprocess.run([py, "tools/optimize_routes.py", fl, "--in", empty, "--merge"], capture_output=True, text=True)
        log("write", fl, p.returncode, " | ".join((p.stderr or "").strip().splitlines()[-2:])[:200])
    log("ALL DONE done", done, "failed", failed, "minutes", round((time.time() - t0) / 60))


if __name__ == "__main__":
    main()
