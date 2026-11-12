#!/usr/bin/env python3
# CompletionRoute :: tools/test_gen_determinism.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""The guide generator writes the same bytes on every run.

    python3 tools/test_gen_determinism.py [mop retail]        (default: mop retail; about 3 minutes)

Runs tools/wiki/gen_wiki_guides.py twice with different PYTHONHASHSEED values into two temp folders (--out: nothing in
the checkout is written) and compares the guide files, the spine files and the spine sidecars.

Why it matters: a baked route order is tied to its guide by a checksum over the steps in order
(Core/Guide.lua G.RouteChecksum).  Until 2026-11-12 tools/wiki/gen_spine.py broke rank ties by object address and
walked a set of guide ids, so every regeneration moved a few sibling quests on MoP and Retail and made those guides'
baked orders stale for no reason.

Needs the local wiki tables (tools/wiki/wiki.sqlite, gitignored); without them the test says so and passes.
Temp folders: CR_TEST_TMP, else /private/tmp/claude-501 when it exists, else the system default.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEEDS = ("1", "20261112")


def main():
    flavors = [a for a in sys.argv[1:] if not a.startswith("-")] or ["mop", "retail"]
    if not os.path.exists(os.path.join(ROOT, "tools", "wiki", "wiki.sqlite")):
        print("skip: tools/wiki/wiki.sqlite is not here (generated data is not committed)")
        return 0
    base = os.environ.get("CR_TEST_TMP") or ("/private/tmp/claude-501" if os.path.isdir("/private/tmp/claude-501") else None)
    work = tempfile.mkdtemp(prefix="cr_test_gen_determinism_", dir=base)
    bad = 0
    try:
        outs = []
        for seed in SEEDS:
            out = os.path.join(work, "seed" + seed)
            p = subprocess.run([sys.executable, "tools/wiki/gen_wiki_guides.py"] + flavors + ["--out", out], cwd=ROOT,
                               env=dict(os.environ, PYTHONHASHSEED=seed), capture_output=True, text=True)
            if p.returncode != 0:
                print("FAIL generator exit %d with PYTHONHASHSEED=%s: %s" % (p.returncode, seed, (p.stderr or p.stdout)[-600:]))
                return 1
            outs.append(out)
        for fl in flavors:
            for name in ("Imported_Wiki_%s.lua" % fl, "Imported_Spine_%s.lua" % fl, "parts_%s.json" % fl):
                a, b = (open(os.path.join(o, name), "rb").read() for o in outs)
                if name.endswith(".json"):          # the sidecar carries the day it was written
                    a, b = (json.dumps({k: v for k, v in json.loads(x).items() if k != "generated"}, sort_keys=False)
                            for x in (a, b))
                same = a == b
                bad += 0 if same else 1
                print(("ok   " if same else "FAIL ") + name + ("" if same else ": differs between two hash seeds"))
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print("ALL GENERATOR DETERMINISM TESTS PASSED" if not bad else "%d file(s) differ" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
