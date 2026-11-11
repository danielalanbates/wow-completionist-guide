#!/usr/bin/env python3
"""CompletionRoute :: tools/test_ingest_beta_reports.py - offline test of tools/ingest_beta_reports.py.

Copyright (c) 2026 Daniel Bates / Bates LLC.  All rights reserved.
Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org

    python3 tools/test_ingest_beta_reports.py      (from repo root; needs luajit and sqlite3 on PATH)

Builds a fake World of Warcraft folder in a temp directory from tools/fixtures/beta_reports_SavedVariables.lua (written by
tools/test_bug_report.lua with CR_WRITE_FIXTURE), ingests it into a temp database twice, and checks: one row per report,
dedupe by id across runs and across two client folders, triage columns kept, no account, character or realm name
in the database, the SavedVariables bytes unchanged, a broken file skipped without stopping the run, and that
`vplayer.lua --repro <id> --show` finds a report by id in the database.
"""
import hashlib
import io
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import ingest_beta_reports as ing  # noqa: E402

FIXTURE = ROOT / "tools" / "fixtures" / "beta_reports_SavedVariables.lua"
ACCOUNT = "SECRETACCT"
CHAR, REALM = "Zorbulon", "Quelthar"   # the names the fixture's character store holds


def tmp_base():
    for base in (os.environ.get("CR_TEST_TMP"), "/private/tmp/claude-501"):
        if base and os.path.isdir(base):
            return base
    return None


class IngestTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="cr_ingest_", dir=tmp_base())
        self.wow = Path(self.dir) / "World of Warcraft"
        self.files = []
        for client in ("_classic_", "_retail_"):
            sv = self.wow / client / "WTF" / "Account" / ACCOUNT / "SavedVariables"
            sv.mkdir(parents=True)
            shutil.copy(FIXTURE, sv / "CompletionRoute.lua")
            shutil.copy(FIXTURE, sv / "CompletionRoute.lua.presync.bak")   # must be ignored
            self.files.append(sv / "CompletionRoute.lua")
        self.db = Path(self.dir) / "test.sqlite"

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def run_ingest(self, *extra):
        buf = io.StringIO()
        with redirect_stdout(buf):
            code = ing.main(["--wow", str(self.wow), "--db", str(self.db), *extra])
        return code, buf.getvalue()

    def test_ingest_dedupe_and_privacy(self):
        digests = [hashlib.sha256(f.read_bytes()).hexdigest() for f in self.files]
        self.assertEqual(len(ing.find_files(str(self.wow))), 2, "only CompletionRoute.lua, never the .bak copies")
        code, out = self.run_ingest()
        self.assertEqual(code, 0, out)
        self.assertIn("2 new", out)
        con = sqlite3.connect(self.db)
        rows = con.execute("SELECT id, flavor, guide, step, action, map, status, account, client, note, json, route, level "
                           "FROM beta_reports ORDER BY id").fetchall()
        self.assertEqual(len(rows), 2, "two reports, the same ids in two client folders count once")
        by_guide = {r[2]: r for r in rows}
        r = by_guide["t:elwynn"]
        self.assertEqual(r[1], "tbc")
        self.assertIsInstance(r[3], int)
        self.assertEqual(r[5], 1429)
        self.assertEqual(r[6], "new")
        self.assertEqual(r[8], "_classic_", "first file wins for a report present in two")
        self.assertEqual(len(r[7]), 10)
        self.assertNotIn(ACCOUNT, r[7])
        self.assertEqual(r[9], "later note about <char>")
        self.assertTrue(r[11] and ("Walk" in r[11] or "Follow" in r[11]), r[11])
        self.assertEqual(r[12], 5)
        self.assertIn('"route"', r[10])
        self.assertIn(None, by_guide, "the report made with no guide loaded is kept too")
        dump = "\n".join(str(x) for x in con.execute("SELECT * FROM beta_reports").fetchall())
        for secret in (ACCOUNT, CHAR, REALM):
            self.assertNotIn(secret, dump)
        # triage survives a second ingest; nothing is duplicated
        con.execute("UPDATE beta_reports SET status='fixed', triage='StepWorld picked the wrong map' WHERE guide='t:elwynn'")
        con.execute("UPDATE beta_reports SET first_seen='2000-01-01 00:00:00'")
        con.commit()
        code, out = self.run_ingest()
        self.assertEqual(code, 0, out)
        self.assertIn("0 new, 2 already known", out)
        self.assertEqual(con.execute("SELECT COUNT(*) FROM beta_reports").fetchone()[0], 2)
        st = con.execute("SELECT status, triage, first_seen FROM beta_reports WHERE guide='t:elwynn'").fetchone()
        self.assertEqual(st, ("fixed", "StepWorld picked the wrong map", "2000-01-01 00:00:00"))
        con.close()
        self.assertEqual(digests, [hashlib.sha256(f.read_bytes()).hexdigest() for f in self.files],
                         "SavedVariables must never be modified")

    def test_broken_and_empty_files(self):
        self.files[1].write_text("CompletionRouteDB = { [\"bugReports\"] = {\n")       # cut off mid-write
        empty = self.wow / "_anniversary_" / "WTF" / "Account" / ACCOUNT / "SavedVariables"
        empty.mkdir(parents=True)
        (empty / "CompletionRoute.lua").write_text('CompletionRouteDB = { ["profile"] = {} }\n')
        code, out = self.run_ingest()
        self.assertEqual(code, 0, out)
        self.assertIn("3 SavedVariables file(s), 1 with reports, 2 report(s) read", out)
        self.assertIn("skipped _retail_", out)

    def test_explicit_files_and_no_files(self):
        code, out = self.run_ingest("--sv", str(self.files[0]), "--quiet")
        self.assertEqual(code, 0, out)
        self.assertIn("1 SavedVariables file(s)", out)
        code, out = self.run_ingest("--wow", str(Path(self.dir) / "nowhere"))
        self.assertEqual(code, 1)

    def test_repro_finds_a_report_by_id(self):
        if not shutil.which("sqlite3") or not shutil.which("luajit"):
            self.skipTest("sqlite3 or luajit not on PATH")
        self.run_ingest("--quiet")
        con = sqlite3.connect(self.db)
        rid = con.execute("SELECT id FROM beta_reports WHERE guide='t:elwynn'").fetchone()[0]
        con.close()
        for spec in (rid, "latest"):
            p = subprocess.run(["luajit", "tools/vplayer.lua", "--repro", spec, "--db", str(self.db), "--show"], cwd=str(ROOT),
                               capture_output=True, text=True, timeout=120)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertIn("REPORT tbc-", p.stdout)
            if spec == rid:
                self.assertIn(rid, p.stdout)
                self.assertIn("t:elwynn", p.stdout)
        p = subprocess.run(["luajit", "tools/vplayer.lua", "--repro", "no-such-report", "--db", str(self.db), "--show"],
                           cwd=str(ROOT), capture_output=True, text=True, timeout=120)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("no report no-such-report", p.stdout + p.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
