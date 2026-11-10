#!/usr/bin/env python3
# CompletionRoute :: tools/wiki/db2_fetch.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Fetch one Blizzard client table per flavor, pinned to tools/wiki/fetch_db2.py BUILDS, serialised across processes.

    python3 tools/wiki/db2_fetch.py SkillLine SkillLineAbility -- era tbc mop retail forever
    import db2_fetch as D; rows = D.rows("mop", "SkillLine")   # list of dicts, or [] when the client has no such table
"""
import csv, fcntl, subprocess, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
DB2 = ROOT / "tools" / "db2"
sys.path.insert(0, str(HERE))
from fetch_db2 import BUILDS, UA  # noqa: E402

LOCK = HERE / "cache" / ".db2_request.lock"
csv.field_size_limit(1 << 28)


def path(flavor, table):
    return DB2 / flavor / f"{table}.csv"


def fetch(flavor, table):
    p = path(flavor, table)
    miss = p.with_suffix(".missing")
    if (p.exists() and p.stat().st_size > 100) or miss.exists():
        return p if p.exists() else None
    p.parent.mkdir(parents=True, exist_ok=True)
    LOCK.parent.mkdir(parents=True, exist_ok=True)
    with open(LOCK, "a+") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        if p.exists() and p.stat().st_size > 100:
            return p
        time.sleep(1.2)
        url = f"https://wago.tools/db2/{table}/csv?build={BUILDS[flavor][1]}"
        r = subprocess.run(["curl", "-sS", "-L", "--compressed", "-m", "300", "-A", UA, "-w", "%{http_code}", "-o", str(p) + ".part", url],
                           capture_output=True, text=True)
        code = r.stdout.strip()
        part = Path(str(p) + ".part")
        if r.returncode == 0 and code == "200" and part.stat().st_size > 100:
            part.replace(p)
            return p
        part.unlink(missing_ok=True)
        if code in ("400", "404"):
            miss.write_text(code)   # this client genuinely has no such table: do not ask again
            return None
        raise RuntimeError(f"{url}: curl={r.returncode} http={code} {r.stderr.strip()}")


def rows(flavor, table):
    p = fetch(flavor, table)
    if not p:
        return []
    with open(p, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


if __name__ == "__main__":
    args = sys.argv[1:]
    cut = args.index("--")
    for fl in args[cut + 1:]:
        for t in args[:cut]:
            print(fl, t, fetch(fl, t))
