#!/usr/bin/env python3
# CompletionRoute :: tools/test_tmp_default.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""The optimizer's job folder defaults to <work>/tmp beside the clone, never a folder under ~/.claude."""
import os, re, subprocess, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
want = os.path.join(os.path.dirname(ROOT), "tmp")
env = {k: v for k, v in os.environ.items() if k != "CR_TMP"}
fail = 0
for mod in ("optimize_routes", "collect_routes"):
    out = subprocess.run([sys.executable, "-c", f"import sys; sys.path.insert(0, 'tools'); import {mod} as m; print(m.TMP)"],
                         cwd=ROOT, env=env, capture_output=True, text=True).stdout.strip().splitlines()
    got = out[-1] if out else ""
    if os.path.normpath(got) != want:
        print(f"FAIL {mod}.TMP = {got!r}, want {want!r}"); fail = 1
src = open(os.path.join(ROOT, "tools", "cost_matrix.lua"), encoding="utf-8").read()
if ".claude/jobs" in src or not re.search(r'"/\.\./\.\./tmp"', src):
    print("FAIL cost_matrix.lua default is not <work>/tmp"); fail = 1
for f in ("optimize_routes.py", "collect_routes.py", "bake_resume.py"):
    if ".claude/jobs" in open(os.path.join(ROOT, "tools", f), encoding="utf-8").read():
        print(f"FAIL {f} still names ~/.claude/jobs"); fail = 1
print("test_tmp_default: ok" if not fail else "test_tmp_default: FAILED")
sys.exit(fail)
