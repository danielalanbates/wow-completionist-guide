#!/usr/bin/env python3
# CompletionRoute :: tools/test_bake_gate.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Offline test of the bake gate's bookkeeping (tools/optimize_routes.py --gate / --gate-only, tools/bake_resume.py).

    venv/bin/python -m unittest tools/test_bake_gate.py      (or: venv/bin/python tools/test_bake_gate.py)

vplayer is replaced by a stand-in (no luajit, no guides): the test bakes two small synthetic guides (one Alliance, one
for both factions) and proves that
  * the solved rows are on disk before the gate starts, so a run killed during the gate (or a vplayer failure, exit 3)
    loses no solve, and tools/bake_resume.py's rule then gates them without solving them again;
  * --gate-only gives every row a verdict; a guide for both factions is played as Alliance AND as Horde and is rejected
    when either play is slower than the gate allows; the RouteOrder entry carries va / vb (and vah / vbh);
  * the gate limits come from the rows (the cost model's GATE_FRAC / GATE_ABS), never from a copy in the optimizer.
Every file goes to a temp folder (under /private/tmp/claude-501 when it exists); nothing in the repo is written.
"""
import json
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import optimize_routes as opt  # noqa: E402
import bake_resume  # noqa: E402

X = [0, 100, 1, 101]          # four points on a line: A1, T1, A2, T2 - the author order walks back and forth
CM = {"version": 2, "noroute": 1800, "hearth": 60, "taxi": "faction", "gate_frac": 0.01, "gate_abs": 30}


def row(gid, faction):
    steps = [["A", "A", 1, [], 0, 0, 0, 1, 1, 1, "o", 0], ["T", "T", 1, [], 0, 1, 0, 1, 1, 1, "o", 0],
             ["A", "A", 2, [], 0, 2, 0, 1, 1, 1, "o", 0], ["T", "T", 2, [], 0, 3, 0, 1, 1, 1, "o", 0]]
    return {"flavor": "era", "id": gid, "name": gid, "faction": faction, "minlevel": 1, "n": 4, "sum": opt.checksum(steps),
            "npts": 4, "cm": dict(CM), "who": {"faction": faction} if faction != "Both" else {}, "steps": steps,
            "start": list(X), "m": [[abs(a - b) for b in X] for a in X]}


def read_rows(path):
    with open(path) as f:
        return {r["id"]: r for r in (json.loads(l) for l in f if l.strip())}


class BakeGate(unittest.TestCase):
    def setUp(self):
        base = "/private/tmp/claude-501" if os.path.isdir("/private/tmp/claude-501") else None
        self.dir = tempfile.mkdtemp(prefix="cr_test_bake_gate_", dir=base)
        self.inp = os.path.join(self.dir, "cm.jsonl")
        self.out = os.path.join(self.dir, "routeopt", "era.jsonl")
        self.work = os.path.join(self.dir, "gate")
        with open(self.inp, "w") as f:
            for r in (row("t:gate:alliance", "Alliance"), row("t:gate:both", "Both")):
                f.write(json.dumps(r) + "\n")
        self.real = opt.run_vplayer
        self.calls = []

    def tearDown(self):
        opt.run_vplayer = self.real
        shutil.rmtree(self.dir, ignore_errors=True)

    def main(self, *args):
        argv = sys.argv
        sys.argv = ["optimize_routes.py", "era", "--out", self.out, "--gate-work", self.work, "--no-write", "--limit-s", "1",
                    "--dp-time", "0.5"] + list(args)
        try:
            opt.main()
            return 0
        except SystemExit as e:
            return e.code
        finally:
            sys.argv = argv

    def fake(self, slower=None):
        """a vplayer stand-in: author 1000 s, baked 900 s, except `slower` = {(id, faction): baked seconds}"""
        def run(flavor, ids_file, order, out_tsv, cap, route_order=None, taxi=None, both_as=None):
            with open(ids_file) as f:
                ids = [l.strip() for l in f if l.strip()]
            self.calls.append((order, both_as, tuple(ids)))
            out = {}
            for i in ids:
                sec = 1000.0 if order == "author" else (slower or {}).get((i, both_as), 900.0)
                out[i] = {"guide": i, "seconds": str(sec), "finished": "1", "error": ""}
            return out
        return run

    def test_kill_during_gate_keeps_the_solves(self):
        seen = {}

        def killed(*a, **k):
            # the gate's first vplayer run: the solves must already be on disk
            seen.update(read_rows(self.out))
            raise RuntimeError("vplayer killed")
        opt.run_vplayer = killed
        self.assertEqual(self.main("--in", self.inp, "--gate"), 3, "a vplayer failure exits 3")
        self.assertEqual(sorted(seen), ["t:gate:alliance", "t:gate:both"], "solved rows saved before the gate ran")
        rows = read_rows(self.out)
        self.assertEqual(sorted(rows), ["t:gate:alliance", "t:gate:both"], "solved rows kept after the failure")
        for r in rows.values():
            self.assertTrue(bake_resume.model_keeps(r), "the synthetic guides bake faster than the author order")
            self.assertNotIn("gate", r, "no verdict without a finished gate")
        # tools/bake_resume.py: a current row the model keeps and that has no verdict is gated, not solved again
        cur = {i: (r["n"], r["sum"], r["cmv"]) for i, r in rows.items()}
        self.assertTrue(all(bake_resume.fresh(rows[i], cur[i]) for i in rows), "rows count as solved for the guides as they are")
        togate = sorted(i for i in cur if bake_resume.model_keeps(rows[i]) and "gate" not in rows[i])
        self.assertEqual(togate, ["t:gate:alliance", "t:gate:both"])

        # the next run gates them without solving: both factions for the guide for both, Horde slower there -> reject
        opt.run_vplayer = self.fake(slower={("t:gate:both", "Horde"): 1100.0})
        self.assertEqual(self.main("--gate-only"), 0)
        rows = read_rows(self.out)
        a, b = rows["t:gate:alliance"], rows["t:gate:both"]
        self.assertEqual(a["gate"], "keep")
        self.assertEqual((a["gate_author_live_s"], a["gate_baked_live_s"]), (1000.0, 900.0))
        self.assertNotIn("gate_author_live_h_s", a, "a one-faction guide is played once")
        self.assertEqual(b["gate"], "reject", b.get("gate_why"))
        self.assertIn("Horde", b["gate_why"])
        self.assertEqual((b["gate_author_live_h_s"], b["gate_baked_live_h_s"]), (1000.0, 1100.0))
        horde = [c for c in self.calls if c[1] == "Horde"]
        self.assertEqual(sorted(c[0] for c in horde), ["author", "baked"])
        self.assertTrue(all(c[2] == ("t:gate:both",) for c in horde), "only guides for both factions are played as Horde")
        self.assertTrue(all(c[1] in ("Alliance", "Horde") for c in self.calls))
        # nothing left to gate
        self.assertEqual([i for i, r in rows.items() if bake_resume.model_keeps(r) and "gate" not in r], [])

    def test_kept_entry_carries_both_factions(self):
        opt.run_vplayer = self.fake()
        self.assertEqual(self.main("--in", self.inp, "--gate"), 0)
        rows = read_rows(self.out)
        self.assertEqual(rows["t:gate:both"]["gate"], "keep")
        lua = os.path.join(self.dir, "RouteOrder_era.lua")
        self.assertEqual(opt.write_lua("era", list(rows.values()), lua), 2)
        text = open(lua).read()
        self.assertIn('O["t:gate:both"] = { n = 4, sum = %d, o = "1,3,2,4", va = 1000, vb = 900, vah = 1000, vbh = 900 }'
                      % rows["t:gate:both"]["sum"], text)
        self.assertIn('O["t:gate:alliance"] = { n = 4, sum = %d, o = "1,3,2,4", va = 1000, vb = 900 }'
                      % rows["t:gate:alliance"]["sum"], text)

    def test_gate_limits_come_from_the_rows(self):
        self.assertEqual(opt.gate_limits([{"cm": {"gate_frac": 0.02, "gate_abs": 45}}]), (0.02, 45.0))
        self.assertFalse(hasattr(opt, "GATE_FRAC"), "no second copy of the gate limits in the optimizer")
        with self.assertRaises(SystemExit):
            opt.gate_limits([{"cm": {"noroute": 1800}}])
        lim = (0.01, 30.0)
        a = {"seconds": "1000", "finished": "1", "error": ""}
        self.assertEqual(opt.gate_verdict(a, {"seconds": "1030", "finished": "1", "error": ""}, lim)[0], "keep")
        self.assertEqual(opt.gate_verdict(a, {"seconds": "1031", "finished": "1", "error": ""}, lim)[0], "reject")
        big = {"seconds": "10000", "finished": "1", "error": ""}
        self.assertEqual(opt.gate_verdict(big, {"seconds": "10100", "finished": "1", "error": ""}, lim)[0], "keep")
        self.assertEqual(opt.gate_verdict(a, {"seconds": "900", "finished": "0", "error": ""}, lim)[0], "reject")


if __name__ == "__main__":
    unittest.main()
