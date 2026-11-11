#!/usr/bin/env python3
# CompletionRoute :: tools/test_package.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Offline test of tools/package_release.py (docs/RELEASE.md).

    python3 tools/test_package.py [--keep]

Builds a fixture checkout in a temp folder (under /private/tmp/claude-501 when it exists): the real tracked add-on code
and LICENSE, plus small clean stand-ins for every generated file the TOCs load, committed to a throwaway git repo, and a
fake WoW folder with one account and one character. It proves a clean build passes (interop files left out, their TOC
lines stripped, version stamped, notices present, provenance for every zip entry, reproducible zips, dist/ archiving),
then plants one bad file per gate rule and proves the gate fails with that rule. It also covers a git worktree whose
generated files link into its main checkout (fails by default, passes with --allow-checkout-links), --data-root and the
--db tables. Nothing outside the temp folder is read or written, except reading the tracked files it copies.
"""
import io
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parent
sys.path.insert(0, str(TOOLS))
import package_release as pr  # noqa: E402

GIT = pr.GIT
TMPROOT = "/private/tmp/claude-501" if os.path.isdir("/private/tmp/claude-501") else None
fails = 0


def check(ok, msg):
    global fails
    if ok:
        print("  ok   " + msg)
    else:
        fails += 1
        print("  FAIL " + msg)


def git(repo, *args):
    env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    return subprocess.run([GIT, "-C", str(repo), "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid",
                           "-c", "commit.gpgsign=false", *args], check=True, capture_output=True, text=True, env=env).stdout


STAND_IN = {
    "interop-wowpro": "-- test stand-in: third-party guide text. DO NOT COMMIT OR REDISTRIBUTE.\nNS.ImportedWoWPro = {}\n",
    "interop-questie": "-- test stand-in (source data: Questie, GPL). Local use only.\nlocal _, NS = ...\n",
    "wiki-cc-by-sa": "-- test stand-in: Warcraft Wiki data, CC BY-SA 4.0\nlocal _, NS = ...\n",
    "blizzard-client-data": "-- test stand-in: Blizzard client data, facts only\nlocal _, NS = ...\n",
    "own-data": "-- test stand-in: baked route order (own data)\nlocal _, NS = ...\n",
}


def append(path, text):
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(text)


def make_base(tmp):
    """the fixture checkout: tracked code + LICENSE + .gitignore, stand-ins for generated data, one commit"""
    base = tmp / "base"
    files = subprocess.run([GIT, "-C", str(ROOT), "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--",
                            pr.ADDON, "LICENSE", ".gitignore"], check=True, capture_output=True, text=True).stdout
    for rel in sorted(set(files.split("\0")) - {""}):
        src = ROOT / rel
        if src.is_file() and not src.is_symlink():
            (base / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, base / rel)
    addon = base / pr.ADDON
    for tocs in pr.CLIENTS.values():
        for toc in tocs:
            for _, rel in pr.read_toc_refs((addon / toc).read_text(encoding="utf-8")):
                if not (addon / rel).exists():
                    r = pr.rule_for(rel)
                    assert r and r.origin == "generated", f"TOC lists {rel}, which is neither tracked nor generated"
                    (addon / rel).parent.mkdir(parents=True, exist_ok=True)
                    (addon / rel).write_text(STAND_IN[r.category], encoding="utf-8")
    (addon / "Guides" / "Imported_Quests_era.lua").write_text(STAND_IN["interop-questie"], encoding="utf-8")
    # one shipped wiki guide with its baked order row, and one Questie-derived _gaps guide (no row yet)
    append(addon / "Guides" / "Imported_Wiki_era.lua", 'R({ id="wiki:era:1429:Both", name="Test", type="Quests", text=[==[\n]==] })\n')
    append(addon / "Data" / "RouteOrder_era.lua", 'O["wiki:era:1429:Both"] = { n = 2, sum = 1, o = "2,1" }\n')
    append(addon / "Guides" / "Imported_Quests_era_gaps.lua", 'R({ id="qdb:era:1:Alliance", name="Gap", type="Quests", text=[==[\n]==] })\n')
    git(base, "init", "-q")
    git(base, "add", "-A")
    git(base, "commit", "-qm", "fixture")
    return base


class Env:
    def __init__(self, tmp, base):
        self.tmp, self.base, self.n = tmp, base, 0
        self.wow = tmp / "wow"
        (self.wow / "_retail_" / "WTF" / "Account" / "TESTACCT42" / "SavedVariables").mkdir(parents=True)
        (self.wow / "_retail_" / "WTF" / "Account" / "TESTACCT42" / "Some Realm" / "Zorblaxia" / "SavedVariables").mkdir(parents=True)
        (self.wow / "_retail_" / "WTF" / "Account" / "SavedVariables").mkdir(parents=True)

    def scenario(self):
        self.n += 1
        d = self.tmp / f"s{self.n:02d}"
        shutil.copytree(self.base, d, symlinks=True)
        return d

    def run(self, repo, *extra):
        out = io.StringIO()
        code, res, man = pr.run(["--repo", str(repo), "--tmp", str(self.tmp), "--wow-dir", str(self.wow),
                                 "--no-local-terms", "--no-measure", *extra], out=out)
        return code, res, man, out.getvalue()


def has(res, rule, path=None):
    return any(f.rule == rule and (path is None or f.path == path) for f in res.failures)


def expect_fail(env, title, rule, path, plant, *extra):
    d = env.scenario()
    plant(d, d / pr.ADDON)
    code, res, _, text = env.run(d, *extra)
    check(code == 1 and has(res, rule, path), pr.redact(f"{title}: gate fails with [{rule}] on {path}")
          + ("" if has(res, rule, path) else " (got: " + "; ".join(f.text() for f in res.failures)[:300] + ")"))
    return res, text


def main():
    keep = "--keep" in sys.argv
    tmp = Path(tempfile.mkdtemp(prefix="cr-test-package-", dir=TMPROOT))
    try:
        base = make_base(tmp)
        env = Env(tmp, base)
        term = pr.denylist()[0]

        print("clean build")
        d = env.scenario()
        code, res, man, text = env.run(d)
        check(code == 0 and res.ok, "clean fixture passes the gate" + ("" if res.ok else ": " + "; ".join(f.text() for f in res.failures)[:400]))
        check(not (tmp / "dist").exists() and not (d / "dist").exists(), "dry run writes no dist/ folder")
        check(all(r["category"] in pr.SHIPPABLE for r in man["files"]), "every packaged file has a shippable category")
        check(all(r["generator"] and r["source"] and r["licence"] for r in man["files"]), "every packaged file names licence, source and generator")
        names = {r["path"] for r in man["files"]}
        check(not any("Imported_WoWPro_" in n or "_gaps" in n or "Imported_Storylines" in n or "Imported_Entrances" in n
                      or n.endswith("Imported_Quests_era.lua") for n in names), "WoW-Pro and Questie-derived files are not packaged")
        check({e["path"] for e in man["excluded"]} >= {"Guides/Imported_WoWPro_era.lua", "Guides/Imported_Quests_era_gaps.lua",
                                                       "Guides/Imported_Storylines_retail.lua", "Data/Imported_Entrances.lua",
                                                       "Guides/Imported_Quests_era.lua"}, "excluded files are listed with a reason")
        check({"LICENSE.txt", "ATTRIBUTION.md", "README.md"} <= set(res.files), "LICENSE.txt, ATTRIBUTION.md and README.md are added")
        check(res.files["Data/RouteOrder_era.lua"].get("order_rows") == 1, "a baked order row for a shipped guide passes")
        check(any("WoW account name" in w and "1 character name" in w for w in res.warnings),
              "account and character names under WTF/Account are checked")

        print("write mode")
        dist = tmp / "dist"
        code, res, man, text = env.run(d, "--write", "--out", str(dist), "--version", "9.9.9-test1", "--layout", "both")
        v1 = dist / "9.9.9-test1"
        zips = sorted(p.name for p in v1.glob("*.zip"))
        check(code == 0 and len(zips) == 6, f"--write --layout both writes 6 zips ({len(zips)})")
        uni = v1 / f"{pr.ADDON}-9.9.9-test1.zip"
        with zipfile.ZipFile(uni) as z:
            znames = set(z.namelist())
            vanilla = z.read(f"{pr.ADDON}/CompletionRoute_Vanilla.toc").decode()
            attribution = z.read(f"{pr.ADDON}/ATTRIBUTION.md").decode()
            licence = z.read(f"{pr.ADDON}/LICENSE.txt").decode()
        src_vanilla = (d / pr.ADDON / "CompletionRoute_Vanilla.toc").read_text()
        check(all(n.startswith(pr.ADDON + "/") for n in znames), "every zip entry sits in the CompletionRoute/ folder")
        check("## Version: 9.9.9-test1" in vanilla and "## Version: 9.9.9-test1" not in src_vanilla,
              "version stamped into the packaged TOC only")
        check("Imported_WoWPro_era" not in vanilla and "Imported_Quests_era_gaps" not in vanilla and "Imported_WoWPro_era" in src_vanilla,
              "interop TOC lines stripped in the packaged copy only")
        with zipfile.ZipFile(uni) as z:
            forever = z.read(f"{pr.ADDON}/CompletionRoute_Forever.toc").decode()
        check("Imported_Quests_forever_gaps" not in forever and "Imported_Entrances" not in forever
              and "Imported_Wiki_forever" in forever, "Forever TOC loses its gaps and entrance lines, keeps its wiki guides")
        prov = json.loads((v1 / "provenance.json").read_text())
        recorded = {r["path"] for r in prov["files"]}
        check(prov["gate"]["result"] == "PASS" and znames <= recorded, "provenance.json covers every zip entry")
        check("Guides/Imported_Wiki_era.lua" in attribution and "CC BY-SA 4.0" in attribution and "ShareAlike" in attribution,
              "ATTRIBUTION.md lists the wiki files with licence and share-alike note")
        check("PolyForm Noncommercial" in licence and "help@batesai.org" in licence, "LICENSE.txt is the PolyForm licence with the rider")
        check(f"{pr.ADDON}/Libs/CallbackHandler-1.0/LICENSE.txt" in znames, "Ace3 licence text ships with CallbackHandler")
        with zipfile.ZipFile(v1 / f"{pr.ADDON}-9.9.9-test1-era.zip") as z:
            era = set(z.namelist())
        check(f"{pr.ADDON}/Guides/Imported_Wiki_retail.lua" not in era and f"{pr.ADDON}/CompletionRoute.toc" not in era
              and f"{pr.ADDON}/CompletionRoute_Vanilla.toc" in era, "per-client era zip holds only the era TOC and data")
        sha1 = {p["name"]: p["sha256"] for p in prov["packages"]}
        code, res, man, _ = env.run(d, "--version", "9.9.9-test1", "--layout", "both")
        check(code == 0 and {p["name"]: p["sha256"] for p in man["packages"]} == sha1, "zips are byte-for-byte reproducible")
        code, res, man, _ = env.run(d, "--write", "--out", str(dist), "--version", "9.9.9-test2")
        check(code == 0 and (dist / "archive" / "9.9.9-test1").is_dir() and not v1.exists() and (dist / "9.9.9-test2").is_dir(),
              "a new --write moves the previous build to dist/archive/")
        bad = env.scenario()
        append(bad / pr.ADDON / "Guides" / "Imported_Wiki_era.lua", "A x|QID|1|M|1,1|Z|1; X|N|To X. (location: Questie data)|\n")
        code, res, man, _ = env.run(bad, "--write", "--out", str(dist), "--version", "9.9.9-test3")
        v3 = dist / "9.9.9-test3"
        check(code == 1 and sorted(p.name for p in v3.iterdir()) == ["gate.txt", "provenance.json"]
              and (dist / "9.9.9-test2").is_dir(), "a failed --write writes only gate.txt + provenance.json and archives nothing")

        print("gate rules")
        def plant_mystery(d, a):
            (a / "Data" / "Mystery.lua").write_text("local _, NS = ...\n")
            append(a / "CompletionRoute_Vanilla.toc", "Data\\Mystery.lua\n")
            git(d, "add", "-A"); git(d, "commit", "-qm", "plant")
        expect_fail(env, "file with no rule", "no-provenance", "Data/Mystery.lua", plant_mystery)
        def plant_untracked(d, a):
            (a / "Core" / "Scratch.lua").write_text("local _, NS = ...\n")
            append(a / "CompletionRoute_TBC.toc", "Core\\Scratch.lua\n")
        expect_fail(env, "code file git does not track", "no-provenance", "Core/Scratch.lua", plant_untracked)
        def plant_texture(d, a):
            (a / "Textures" / "odd.blp").write_bytes(b"BLP2")
            git(d, "add", "-A"); git(d, "commit", "-qm", "plant")
        expect_fail(env, "texture type with no rule", "no-provenance", "Textures/odd.blp", plant_texture)

        expect_fail(env, "Questie fallback line in wiki data", "interop-derived", "Guides/Imported_Wiki_era.lua",
                    lambda d, a: append(a / "Guides" / "Imported_Wiki_era.lua",
                                        "T Foo|QID|5|M|1,1|Z|1; X|N|To Foo. (location: Questie data)|\n"))
        expect_fail(env, "WoW-Pro guide text in gold data", "interop-derived", "Guides/Imported_Gold_tbc.lua",
                    lambda d, a: append(a / "Guides" / "Imported_Gold_tbc.lua", 'R({ id="x", author="WoWPro Team", text=[[ ]] })\n'))
        def plant_xml(d, a):
            x = a / "Guides" / "Guides.xml"
            x.write_text(x.read_text().replace("</Ui>", '\t<Script file="Imported_WoWPro_era.lua"/>\n</Ui>'))
            git(d, "add", "-A"); git(d, "commit", "-qm", "plant")
        expect_fail(env, "WoW-Pro file pulled in through an XML include", "interop-derived", "Guides/Imported_WoWPro_era.lua", plant_xml)
        res, _ = expect_fail(env, "baked order row for a Questie-derived _gaps guide", "interop-derived", "Data/RouteOrder_era.lua",
                             lambda d, a: append(a / "Data" / "RouteOrder_era.lua", 'O["qdb:era:1:Alliance"] = { n = 2, sum = 1, o = "1,2" }\n'))
        check(any("qdb: 1" in f.detail for f in res.failures), "the finding counts the rows by guide-id prefix")
        d = env.scenario()
        append(d / pr.ADDON / "Data" / "RouteOrder_tbc.lua", 'O["wiki:tbc:9999:Both"] = { n = 2, sum = 1, o = "1,2" }\n')
        code, res, _, _ = env.run(d)
        check(code == 0 and any("RouteOrder_tbc.lua" in w and "stale" in w for w in res.warnings),
              "a baked row for a guide that exists nowhere is a warning (stale bake), not a failure")
        expect_fail(env, "data that says do not redistribute", "not-redistributable", "Guides/Imported_Missions_retail.lua",
                    lambda d, a: (a / "Guides" / "Imported_Missions_retail.lua").write_text(
                        "-- (wago.tools DB2 exports).  Local use only - gitignored, do not redistribute.\n"))

        expect_fail(env, "commercial guide product named in data", "commercial-reference", "Guides/Imported_Professions_mop.lua",
                    lambda d, a: append(a / "Guides" / "Imported_Professions_mop.lua", f"-- like {term.upper()}Guides\n"))
        def plant_name(d, a):
            (a / "Textures" / f"{term.capitalize()}_arrow.tga").write_bytes(b"\0" * 18)
            git(d, "add", "-A"); git(d, "commit", "-qm", "plant")
        res, text = expect_fail(env, "commercial guide product in a file name", "commercial-reference",
                                f"Textures/{term.capitalize()}_arrow.tga", plant_name)
        check(term not in text.lower() and term not in json.dumps(pr.manifest(res)).lower(),
              "the report and provenance.json do not spell out the product name")

        expect_fail(env, "e-mail address", "personal-data", "Guides/Imported_Spine_era.lua",
                    lambda d, a: append(a / "Guides" / "Imported_Spine_era.lua", "-- ask someone.else@example.com\n"))
        expect_fail(env, "home folder path", "personal-data", "Data/RouteOrder_tbc.lua",
                    lambda d, a: append(a / "Data" / "RouteOrder_tbc.lua", "-- built in /Users/someone/Code\n"))
        res, text = expect_fail(env, "WoW account name from WTF/Account", "personal-data", "Guides/Imported_Gold_era.lua",
                                lambda d, a: append(a / "Guides" / "Imported_Gold_era.lua", "-- testacct42 was here\n"))
        check("TESTACCT42" not in text.upper(), "the report does not print the account name")
        res, text = expect_fail(env, "WoW character name from WTF/Account/<account>/<realm>", "personal-data",
                                "Guides/Imported_Professions_era.lua",
                                lambda d, a: append(a / "Guides" / "Imported_Professions_era.lua", "-- ZORBLAXIA\n"))
        check("zorblaxia" not in text.lower(), "the report does not print the character name")
        expect_fail(env, "--personal-term", "personal-data", "Guides/Imported_Wiki_tbc.lua",
                    lambda d, a: append(a / "Guides" / "Imported_Wiki_tbc.lua", "-- Zebulon Quux\n"), "--personal-term", "Zebulon Quux")

        expect_fail(env, "access key", "secret", "Data/RouteOrder_era.lua",
                    lambda d, a: append(a / "Data" / "RouteOrder_era.lua", '-- key = "' + "AKIA" + "Z" * 16 + '"\n'))
        expect_fail(env, "private key block", "secret", "Guides/Imported_Achievements_mop.lua",
                    lambda d, a: append(a / "Guides" / "Imported_Achievements_mop.lua", "--[[ -----BEGIN RSA " + "PRIVATE KEY----- ]]\n"))

        def plant_code_link(d, a):
            outside = env.tmp / "outside.lua"
            outside.write_text("local _, NS = ...\n")
            os.symlink(outside, a / "Core" / "Linked.lua")
            append(a / "CompletionRoute_Mists.toc", "Core\\Linked.lua\n")
            git(d, "add", "-A"); git(d, "commit", "-qm", "plant")
        expect_fail(env, "code file that is a symlink", "symlink", "Core/Linked.lua", plant_code_link)
        def plant_dir_link(d, a):
            shutil.move(str(a / "Libs" / "HereBeDragons"), str(env.tmp / f"hbd{env.n}"))
            os.symlink(env.tmp / f"hbd{env.n}", a / "Libs" / "HereBeDragons")
        expect_fail(env, "library folder that is a symlink", "symlink", "Libs/HereBeDragons/HereBeDragons-2.0.lua", plant_dir_link)
        def plant_data_link(d, a):
            elsewhere = env.tmp / f"elsewhere{env.n}"
            elsewhere.mkdir()
            (elsewhere / "Imported_Wiki_mop.lua").write_text(STAND_IN["wiki-cc-by-sa"])
            (a / "Guides" / "Imported_Wiki_mop.lua").unlink()
            os.symlink(elsewhere / "Imported_Wiki_mop.lua", a / "Guides" / "Imported_Wiki_mop.lua")
        expect_fail(env, "generated file linked outside any checkout", "symlink", "Guides/Imported_Wiki_mop.lua", plant_data_link)

        # a git worktree whose generated files are links into the main checkout (how the agent worktrees share data)
        main_co = env.scenario()
        wt = tmp / "worktree"
        git(main_co, "worktree", "add", "-q", "-b", "wt", str(wt))
        linked = 0
        for p in sorted((main_co / pr.ADDON).rglob("Imported_*.lua")) + sorted((main_co / pr.ADDON).rglob("RouteOrder_*.lua")):
            rel = p.relative_to(main_co / pr.ADDON)
            if not (wt / pr.ADDON / rel).exists():
                os.symlink(p, wt / pr.ADDON / rel)
                linked += 1
        code, res, man, _ = env.run(wt)
        check(code == 1 and has(res, "symlink", "Guides/Imported_Wiki_era.lua") and has(res, "symlink", "Data/RouteOrder_era.lua"),
              f"worktree with {linked} generated-data links into its main checkout fails by default (every symlink fails)")
        code, res, man, _ = env.run(wt, "--allow-checkout-links")
        check(code == 0 and linked > 20 and sum(r["via"] == "symlink into a checkout" for r in man["files"]) > 20
              and any("--allow-checkout-links" in w for w in res.warnings),
              f"... and passes with --allow-checkout-links, each linked file marked in provenance.json")
        os.unlink(wt / pr.ADDON / "Guides" / "Imported_Wiki_tbc.lua")
        os.symlink(main_co / pr.ADDON / "Guides" / "Imported_Wiki_era.lua", wt / pr.ADDON / "Guides" / "Imported_Wiki_tbc.lua")
        code, res, man, _ = env.run(wt, "--allow-checkout-links")
        check(code == 1 and has(res, "symlink", "Guides/Imported_Wiki_tbc.lua"),
              "a generated link to a different file fails even with --allow-checkout-links")

        expect_fail(env, "TOC lists a file that does not exist", "toc-missing-file", "CompletionRoute_Mists.toc",
                    lambda d, a: append(a / "CompletionRoute_Mists.toc", "Data\\Missing.lua\n"))
        expect_fail(env, "generated file the TOC loads is missing", "toc-missing-file", "CompletionRoute_TBC.toc",
                    lambda d, a: (a / "Guides" / "Imported_Spine_tbc.lua").unlink())
        def plant_xml_missing(d, a):
            x = a / "Guides" / "Guides.xml"
            x.write_text(x.read_text().replace("</Ui>", '\t<Script file="Leveling\\Missing.lua"/>\n</Ui>'))
            git(d, "add", "-A"); git(d, "commit", "-qm", "plant")
        expect_fail(env, "XML include of a missing file", "toc-missing-file", "Guides/Guides.xml", plant_xml_missing)

        def plant_no_ace(d, a):
            (a / "Libs" / "CallbackHandler-1.0" / "LICENSE.txt").unlink()
            git(d, "add", "-A"); git(d, "commit", "-qm", "plant")
        expect_fail(env, "library licence text missing", "missing-notice", "Libs/CallbackHandler-1.0/LICENSE.txt", plant_no_ace)
        def plant_licence(d, a):
            lic = d / "LICENSE"
            lic.write_text(lic.read_text().replace("ten percent (10%)", "some"))
            git(d, "add", "-A"); git(d, "commit", "-qm", "plant")
        expect_fail(env, "LICENSE without the rider", "missing-notice", "LICENSE.txt", plant_licence)

        print("data root")
        d = env.scenario()
        append(d / pr.ADDON / "Guides" / "Imported_Wiki_era.lua", "T a|QID|9|N|x (location: Questie data)|\n")
        over = tmp / "release-data"
        (over / "Guides").mkdir(parents=True)
        (over / "Guides" / "Imported_Wiki_era.lua").write_text(STAND_IN["wiki-cc-by-sa"])
        code, res, man, _ = env.run(d, "--data-root", str(over))
        rec = next(r for r in man["files"] if r["path"].endswith("Guides/Imported_Wiki_era.lua"))
        check(code == 0 and rec["via"] == "--data-root", "--data-root wins over the checkout's generated file")
        (over / "Core").mkdir()
        (over / "Core" / "Init.lua").write_text("-- replaced\n")
        code, res, man, _ = env.run(d, "--data-root", str(over))
        check(code == 1 and has(res, "no-provenance", "Core/Init.lua"), "a --data-root holding tracked code fails the gate")
        print("provenance table")
        db = tmp / "prov.sqlite"
        code, res, man, _ = env.run(d, "--data-root", str(over), "--db", str(db), "--version", "9.9.9-db")
        code2, res2, man2, _ = env.run(env.scenario(), "--db", str(db), "--version", "9.9.9-db")
        con = sqlite3.connect(db)
        n = con.execute("select count(*) from data_provenance where version='9.9.9-db'").fetchone()[0]
        gate = con.execute("select result, rule from release_gate where version='9.9.9-db'").fetchall()
        cats = {r[0] for r in con.execute("select distinct category from data_provenance")}
        con.close()
        check(code == 1 and code2 == 0 and n == len(man2["files"]) and gate == [("PASS", "")] and cats <= set(pr.SHIPPABLE),
              f"--db writes one data_provenance row per packaged file ({n}) and replaces the rows of the same version")
        link = tmp / "linked.sqlite"
        os.symlink(db, link)
        try:
            env.run(d, "--db", str(link))
            refused = False
        except SystemExit as e:
            refused = isinstance(e.code, str) and "symlink" in e.code
        check(refused, "--db refuses a path that is a symlink (a worktree's docs/verification.sqlite)")
    finally:
        if keep:
            print("kept " + str(tmp))
        else:
            shutil.rmtree(tmp, ignore_errors=True)
    print("ALL PACKAGE TESTS PASSED" if fails == 0 else f"{fails} PACKAGE TESTS FAILED")
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
