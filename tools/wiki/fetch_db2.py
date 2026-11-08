#!/usr/bin/env python3
# CompletionRoute :: tools/wiki/fetch_db2.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Download the Blizzard client tables the wiki pipeline needs, pinned to one build per flavor.

    python3 tools/wiki/fetch_db2.py            # fetch what is missing
    python3 tools/wiki/fetch_db2.py --force    # re-download

Writes tools/db2/<flavor>/<Table>.csv (gitignored) plus tools/db2/<flavor>/BUILD (the pinned version).
QuestV2 decides flavor membership (it is cumulative, see docs/WIKI_DATA_SPEC.md 6); QuestObjective (retail
only, wago returns 400 for the classic products) is used to check the wiki's objective count.
Serial requests, >= 1 s apart, cached: nothing is fetched twice.
"""
import subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DB2 = ROOT / "tools" / "db2"
UA = "CompletionistGuide/2.0 (+https://batesai.org)"
# flavor -> (wago product, pinned build). Verified on https://wago.tools/api/builds 2026-11-07.
BUILDS = {
    "era": ("wow_classic_era", "1.15.9.70576"),
    "tbc": ("wow_anniversary", "2.5.6.70577"),
    "mop": ("wow_classic", "5.5.4.70631"),
    "retail": ("wow", "12.1.5.70783"),
}
TABLES = {"era": ["QuestV2"], "tbc": ["QuestV2"], "mop": ["QuestV2"], "retail": ["QuestV2", "QuestObjective"]}


def main():
    force = "--force" in sys.argv
    last = 0.0
    for fl, (product, build) in BUILDS.items():
        d = DB2 / fl
        d.mkdir(parents=True, exist_ok=True)
        (d / "BUILD").write_text(f"{product} {build}\n")
        for t in TABLES[fl]:
            p = d / f"{t}.csv"
            if p.exists() and p.stat().st_size > 100 and not force:
                print(f"cached {p.relative_to(ROOT)}")
                continue
            wait = 1.2 - (time.time() - last)
            if wait > 0:
                time.sleep(wait)
            url = f"https://wago.tools/db2/{t}/csv?build={build}"
            r = subprocess.run(["curl", "-sS", "-L", "--compressed", "-m", "300", "-A", UA, "-w", "%{http_code}",
                                "-o", str(p) + ".part", url], capture_output=True, text=True)
            last = time.time()
            code = r.stdout.strip()
            if r.returncode != 0 or code != "200":
                print(f"FAIL {url}: curl={r.returncode} http={code} {r.stderr.strip()}")
                Path(str(p) + ".part").unlink(missing_ok=True)
                continue
            Path(str(p) + ".part").rename(p)
            n = sum(1 for _ in p.open(encoding="utf-8")) - 1
            print(f"{fl:6} {t:15} {build}  {n} rows -> {p.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
