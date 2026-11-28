#!/usr/bin/env python3
# CompletionRoute :: tools/test_legacy.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""tools/gen_legacy.py rules (selfcheck) + the generated Imported_Legacy_forever.lua when present: Forever-only guard,
listed only in the Forever and Camelot TOCs, every Legacy Challenge of the client covered once, no forbidden source."""
import re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
fails = 0


def check(ok, msg):
    global fails
    print(("ok   " if ok else "FAIL ") + msg)
    fails += 0 if ok else 1


r = subprocess.run([sys.executable, str(ROOT / "tools" / "gen_legacy.py"), "--selfcheck"], capture_output=True, text=True)
check(r.returncode == 0, "gen_legacy.py --selfcheck" + ("" if r.returncode == 0 else "\n" + r.stdout + r.stderr))
for toc in sorted((ROOT / "CompletionRoute").glob("*.toc")):
    listed = "Guides\\Imported_Legacy_forever.lua" in toc.read_text(encoding="utf-8")
    want = toc.name in ("CompletionRoute_Forever.toc", "CompletionRoute_Camelot.toc")
    check(listed == want, f"{toc.name} {'lists' if want else 'does not list'} Imported_Legacy_forever.lua")
out = ROOT / "CompletionRoute" / "Guides" / "Imported_Legacy_forever.lua"
if out.exists():
    s = out.read_text(encoding="utf-8")
    check("if not NS.isForever then return end" in s, "Forever-only guard")
    check(not re.search(r"questie|wow-?pro|zygor", s, re.I), "no forbidden source named")
    ach_csv = ROOT / "tools" / "db2" / "forever" / "Achievement.csv"
    if ach_csv.exists():
        sys.path.insert(0, str(ROOT / "tools"))
        import csv, gen_legacy as L
        cats = list(csv.DictReader((ach_csv.parent / "Achievement_Category.csv").open(encoding="utf-8")))
        chs = L.challenges(list(csv.DictReader(ach_csv.open(encoding="utf-8"))), cats)
        have = {int(x) for x in re.findall(r"\|ACH\|(\d+)\|FIXED\|", s)} | \
               {int(x) for x in re.findall(r"^C [^|]*\|ACH\|(\d+)\|", s, re.M)}
        miss = [c["title"] for c in chs if c["id"] not in have]
        check(not miss, f"every one of {len(chs)} challenges has a step" + (f" (missing {miss})" if miss else ""))
    for m in re.finditer(r"\|M\|([\d.]+),([\d.]+)\|Z\|", s):
        if not (0 <= float(m.group(1)) <= 100 and 0 <= float(m.group(2)) <= 100):
            check(False, f"point out of range {m.group(0)}")
            break
else:
    print("skip: Imported_Legacy_forever.lua not generated")
print("test_legacy:", "ok" if not fails else f"{fails} failed")
sys.exit(1 if fails else 0)
