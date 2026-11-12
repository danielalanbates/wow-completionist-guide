#!/usr/bin/env python3
"""Completionist's Guide :: tools/bake_resume.py - resumable offline route bake.

Copyright (c) 2026 Daniel Bates. All rights reserved. PolyForm Noncommercial 1.0.0 + commercial rider (see LICENSE).
https://batesai.org - help@batesai.org

Bakes every shipped quest guide (the wiki zone guides: tools/cost_matrix.lua lists ids with the prefix "wiki:" and loads
only files the TOCs load) whose result row is missing or stale, one heavy process at a time, and is safe to kill and
re-run: the to-do set is recomputed from `luajit tools/cost_matrix.lua <flavor> --list` (id, step count, checksum, cost
model version) against the optimizer's result rows on every start, so finished guides are never redone.

A guide is "stale" when its step count or checksum changed, or its row was solved under another cost model version
(Routing/CostModel.lua CM.VERSION).  The checksum (version 2, 2026-11-10) covers each step's action, first quest id, zone
and first point rounded to 0.5 map percent, so a guide whose coordinates moved is stale too.  --force-mapfix and
--force-file still force guides by hand.

Per batch: tools/cost_matrix.lua (travel matrices) -> tools/optimize_routes.py --merge --no-write --gate.  The gate
(docs/ROUTING.md "Bake gate") plays author + live window and baked + live window in tools/vplayer.lua with a real
character of the guide's planning character (a guide for both factions: as Alliance and as Horde) and keeps a baked
order only when it is not slower by more than max(1%, 30 s); --no-gate skips it.  The optimizer saves a batch's solved
rows before its gate starts, so a row solved without a verdict (an earlier --no-gate run, a run killed during the gate,
or a vplayer failure) is gated on the next start without solving it again (tools/test_bake_gate.py).  At the end
the RouteOrder_<flavor>.lua file of every flavor touched is rewritten from the merged rows, with
entries only for guides that still match the current list (tools/optimize_routes.py --current).

--jobs N runs N batches at a time (default 1).  A batch is one cost_matrix + optimizer + gate chain, single-threaded
and about 100 to 300 MB, so several fit this Mac; each has its own scratch files, and the optimizer puts its rows into
the shared rows file under a lock, re-reading it first (tools/optimize_routes.py save_rows own=), so no batch
overwrites another's rows.  The solver's time limits are wall-clock: with more jobs than fast cores a solve gets less
done in its time, and the gate still decides what is kept.

Guards (8 GB Mac): waits while memory is genuinely short (kernel level critical or < 10% free; level 2 "warn" is
sticky with a game open and is NOT a gate), stops when free disk < 11 GB. Runs at nice 15.

Usage:
  python3 tools/bake_resume.py [--flavors mop,retail] [--dry-run] [--force-mapfix] [--force-file tbc=ids.txt]
                               [--only-file tbc=ids.txt] [--batch 20] [--limit-s S] [--dp-time S] [--no-gate]
                               [--gate-cap S] [--lua-dir DIR] [--jobs N]
Default solver limits are optimize_routes.py's own (full quality). Results: <TMP>/routeopt/<flavor>.jsonl, where TMP is
the optimizer's job directory (env CR_TMP, default TMP_DEFAULT in tools/optimize_routes.py).  --lua-dir (default
CompletionRoute/Data) is where the RouteOrder files are written.
"""
import argparse
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
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
    return os.path.expanduser(re.search(r'^TMP_DEFAULT = (?:os\.path\.expanduser\()?"([^"]+)"', src, re.M).group(1))


def model_keeps(r):
    """tools/optimize_routes.py model_keeps: a row the optimizer would bake (and the gate has to check)"""
    return r.get("violations") == 0 and r.get("baked_s") is not None and r["baked_s"] < r["author_s"] - 1.0


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
    """{id: (n, sum, cost model version)} of the guides as they are now, and the list file (optimize_routes --current)"""
    lp = os.path.join(work, f"list_{fl}.jsonl")
    subprocess.run(["luajit", "tools/cost_matrix.lua", fl, "--list", "--out", lp], capture_output=True, check=True)
    cur = {}
    for line in open(lp):
        r = json.loads(line)
        cur[r["id"]] = (r["n"], r["sum"], r.get("cmv"))
    return cur, lp


def rows(fl, tmp):
    p = os.path.join(tmp, "routeopt", fl + ".jsonl")
    out = {}
    if os.path.exists(p):
        for line in open(p):
            r = json.loads(line)
            out[r["id"]] = r
    return out


def fresh(row, cur):
    """the row was solved for the guide as it is now, under the current cost model"""
    return row is not None and (row.get("n"), row.get("sum"), row.get("cmv")) == cur


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def stale_progress_files(tmp):
    """Leftovers next to the rows files that no running optimizer owns: <flavor>.jsonl.solving.<pid> and
    <flavor>.jsonl.part.<pid> of a process that is gone (a kill -9 leaves them), and a plain <flavor>.jsonl.part
    (written before 2026-11-12) untouched for 10 minutes.  None of them is ever read back: the rows file is the record."""
    d = os.path.join(tmp, "routeopt")
    out = []
    if not os.path.isdir(d):
        return out
    for name in os.listdir(d):
        m = re.match(r"^[a-z]+\.jsonl\.(?:solving|part)\.(\d+)$", name)
        path = os.path.join(d, name)
        if m and not pid_alive(int(m.group(1))):
            out.append(path)
        elif re.match(r"^[a-z]+\.jsonl\.part$", name) and time.time() - os.path.getmtime(path) > 600:
            out.append(path)
    return sorted(out)


def mapfix_ids(fl, quest_ids):
    if fl not in ("era", "tbc", "forever"):
        return []
    hit = set()
    for name in (f"Imported_Wiki_{fl}.lua",):
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
    ap.add_argument("--only-file", action="append", default=[],
                    help="FLAVOR=PATH: bake (and gate) only these guide ids of that flavor (a partial or test run)")
    ap.add_argument("--batch", type=int, default=20)
    ap.add_argument("--limit-s", type=float)
    ap.add_argument("--dp-time", type=float)
    ap.add_argument("--no-gate", action="store_true", help="skip the vplayer gate (rows stay without a verdict)")
    ap.add_argument("--gate-cap", type=float, help="vplayer seconds per guide in the gate (optimize_routes --gate-cap)")
    ap.add_argument("--min-free-gb", type=float, default=11.0,
                    help="stop before a batch when the disk has less free space than this (owner's floor is 8 GB)")
    ap.add_argument("--lua-dir", help="where RouteOrder_<flavor>.lua is written (default CompletionRoute/Data)")
    ap.add_argument("--jobs", type=int, default=1,
                    help="batches run at once (default 1). Each batch is single-threaded and small in memory (about "
                         "100 to 300 MB), so 3 or 4 fit an 8-core, 8 GB Mac; tools/optimize_routes.py merges its rows "
                         "into the shared file under a lock")
    a = ap.parse_args()
    os.chdir(REPO)
    tmp, py = opt_tmp(), python_bin()
    gating = not a.no_gate
    lua_dir = os.path.abspath(a.lua_dir) if a.lua_dir else os.path.join(REPO, "CompletionRoute", "Data")
    work = tempfile.mkdtemp(prefix="bake_resume_")
    forced, only = {}, {}
    for spec in a.force_file:
        fl, path = spec.split("=", 1)
        forced.setdefault(fl, set()).update(l.strip() for l in open(path) if l.strip())
    for spec in a.only_file:
        fl, path = spec.split("=", 1)
        only.setdefault(fl, set()).update(l.strip() for l in open(path) if l.strip())
    stale = stale_progress_files(tmp)
    if stale:
        log("removing %d leftover progress file(s) of optimizer runs that are gone: %s"
            % (len(stale), ", ".join(os.path.basename(p) for p in stale)[:300]))
        if not a.dry_run:
            for path in stale:
                try:
                    os.remove(path)
                except OSError:
                    pass
    todo, togate, lists = {}, {}, {}
    for fl in a.flavors.split(","):
        (cur, lists[fl]), done = current(fl, work), rows(fl, tmp)
        if fl in only:
            cur = {i: v for i, v in cur.items() if i in only[fl]}
        ids = [i for i in cur if not fresh(done.get(i), cur[i])]
        extra = set(forced.get(fl, set()))
        if a.force_mapfix:
            extra.update(mapfix_ids(fl, set(cur)))
        ids += sorted(i for i in extra if i in cur and i not in ids)
        todo[fl] = ids
        # solved for the guide as it is now, but never gated (a --no-gate run, or killed between the solve and the gate)
        togate[fl] = sorted(i for i in cur if i not in ids and gating and model_keeps(done[i]) and "gate" not in done[i])
        log(f"{fl}: quest guides {len(cur)}, current rows {sum(1 for i in cur if fresh(done.get(i), cur[i]))}, to do {len(ids)}"
            + (f" (incl. {len(extra)} forced)" if extra else "") + (f", to gate {len(togate[fl])}" if gating else ", gate off"))
    if a.dry_run:
        return
    queue = []
    for fl in ("tbc", "forever", "era"):
        ids = todo.get(fl, [])
        queue += [(fl, "solve", ids[i:i + a.batch]) for i in range(0, len(ids), a.batch)]
    m, r = list(todo.get("mop", [])), list(todo.get("retail", []))
    while m or r:
        if m:
            queue.append(("mop", "solve", m[:a.batch])); m = m[a.batch:]
        if r:
            queue.append(("retail", "solve", r[:a.batch])); r = r[a.batch:]
    for fl in FLAVORS:
        ids = togate.get(fl, [])
        queue += [(fl, "gate", ids[i:i + a.batch]) for i in range(0, len(ids), a.batch)]
    total = sum(len(b) for _, _, b in queue)
    jobs = max(1, a.jobs)
    state = {"done": 0, "failed": 0}
    touched, t0 = set(), time.time()
    mu, stop = threading.Lock(), threading.Event()
    extra_args = (["--limit-s", str(a.limit_s)] if a.limit_s else []) + (["--dp-time", str(a.dp_time)] if a.dp_time else [])

    def run_batch(k, fl, what, ids):
        """one batch; every file it writes has the batch number in its name, so batches never share a file except the
        rows file, which tools/optimize_routes.py updates under a lock (save_rows own=)"""
        if stop.is_set():
            return
        if free_gb() < a.min_free_gb:
            if not stop.is_set():
                stop.set()
                log("STOP: free disk", round(free_gb(), 1), "GB")
            return
        waited = 0
        while tight() and waited < 1800 and not stop.is_set():
            if waited == 0:
                log("memory tight - waiting")
            time.sleep(30); waited += 30
        gf, cj = os.path.join(work, f"batch_{k}_{fl}.txt"), os.path.join(work, f"batch_{k}_{fl}.jsonl")
        gdir = os.path.join(work, f"gate_{k}")
        gate_args = ["--gate-work", gdir] + (["--gate-cap", str(a.gate_cap)] if a.gate_cap else [])
        with open(gf, "w") as f:
            f.write("\n".join(ids) + "\n")
        if what == "gate":
            p = subprocess.run(["nice", "-n", "15", py, "tools/optimize_routes.py", fl, "--gate-only", "--gate-ids", gf,
                                "--no-write"] + gate_args, capture_output=True, text=True)
        else:
            p = subprocess.run(["nice", "-n", "15", "luajit", "tools/cost_matrix.lua", fl, "--guides-file", gf, "--out", cj,
                                "--verify", "20"], capture_output=True, text=True)
            if p.returncode != 0:
                with mu:
                    state["failed"] += len(ids)
                log("cost_matrix FAILED", fl, p.stderr[-400:]); return
            p = subprocess.run(["nice", "-n", "15", py, "tools/optimize_routes.py", fl, "--in", cj, "--merge", "--no-write"]
                               + (["--gate"] + gate_args if gating else []) + extra_args, capture_output=True, text=True)
        if p.returncode != 0:
            with mu:
                state["failed"] += len(ids)
            log(what, "FAILED", fl, p.stderr[-400:]); return
        # a finished batch's scratch files are not needed again (a failed one keeps them for a look)
        shutil.rmtree(gdir, ignore_errors=True)
        for path in (gf, cj):
            try:
                os.remove(path)
            except OSError:
                pass
        with mu:
            touched.add(fl); state["done"] += len(ids)
            d = state["done"]
        el = time.time() - t0
        info = [l for l in (p.stderr or "").strip().splitlines() if l.startswith(("gate ", "DONE"))]
        log(f"{fl} {what} batch ok  {d}/{total}  eta {(total - d) * el / max(d, 1) / 60:.0f} min |",
            " | ".join(info)[:220])

    if jobs > 1:
        log(f"{jobs} batches at a time")
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        futs = [pool.submit(run_batch, k, fl, what, ids) for k, (fl, what, ids) in enumerate(queue)]
        for f in futs:
            f.result()          # a programming error in run_batch stops the run here instead of passing silently
    done, failed = state["done"], state["failed"]
    empty = os.path.join(work, "empty.jsonl")
    open(empty, "w").close()
    for fl in sorted(touched):
        p = subprocess.run([py, "tools/optimize_routes.py", fl, "--in", empty, "--merge", "--current", lists[fl],
                            "--lua-out", os.path.join(lua_dir, f"RouteOrder_{fl}.lua")], capture_output=True, text=True)
        log("write", fl, p.returncode, " | ".join((p.stderr or "").strip().splitlines()[-2:])[:200])
    log("ALL DONE done", done, "failed", failed, "minutes", round((time.time() - t0) / 60))


if __name__ == "__main__":
    main()
