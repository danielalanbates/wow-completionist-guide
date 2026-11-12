#!/usr/bin/env python3
# CompletionRoute :: tools/test_package.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Offline test of tools/package_release.py (docs/RELEASE.md).

    python3 tools/test_package.py [--keep]

Builds a fixture checkout in a temp folder (CR_TEST_TMP, else /private/tmp/claude-501 when it exists): the real tracked
add-on code and LICENSE, plus small clean stand-ins for every generated file the TOCs load, committed to a throwaway
git repo, and a fake WoW folder with one account and one character. It proves a clean build passes (a packaged TOC is
the source TOC plus the version stamp, notices present, provenance for every zip entry, reproducible zips, dist/
archiving), then plants one bad file per gate rule and proves the gate fails with that rule: among them every kind of
file derived from another add-on's data, lying in CompletionRoute/ or listed by a TOC (there is one build, and such a
file is never part of it). It also covers a git worktree whose
generated files link into its main checkout (fails by default, passes with --allow-checkout-links), --data-root, the
--db tables, what --write may move (only its own builds; a failing build never displaces a passing one), the dirty
flag for packager edits, per-client ATTRIBUTION.md and usage errors. Nothing outside the temp folder is read or
written, except reading the tracked files it copies.
"""
import contextlib
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
TMPROOT = os.environ.get("CR_TEST_TMP") or ("/private/tmp/claude-501" if os.path.isdir("/private/tmp/claude-501") else None)
# the header a file made from the dev build retired on 2026-11-11 carries (a leftover must still fail the gate)
OLD_LOCAL_BUILD = ("-- LOCAL BUILD: made from the default build of Imported_Wiki_{fl}.lua, whose fallback rows come from "
                   "Questie-derived data. It never ships: regenerate after tools/wiki/gen_wiki_guides.py --no-fallback.")
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
                    assert r.category in pr.SHIPPABLE, f"TOC lists {rel}, which never ships ({r.category})"
                    text = STAND_IN[r.category]
                    if pr.match("Data/QuestDeps_*.lua", rel):     # the header tools/gen_quest_deps.py writes
                        text = "-- test stand-in: Sources: Warcraft Wiki only.\n" + text
                    (addon / rel).write_text(text, encoding="utf-8")
    # one shipped wiki guide with its baked order row
    append(addon / "Guides" / "Imported_Wiki_era.lua", 'R({ id="wiki:era:1429:Both", name="Test", type="Quests", text=[==[\n]==] })\n')
    append(addon / "Data" / "RouteOrder_era.lua", 'O["wiki:era:1429:Both"] = { n = 2, sum = 1, o = "2,1" }\n')
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


def usage_error(env, repo, *extra):
    """the SystemExit text of a usage error, or None when pr.run did not stop with one"""
    try:
        env.run(repo, *extra)
    except SystemExit as e:
        return e.code if isinstance(e.code, str) else None
    return None


def zip_sha(path):
    import hashlib
    return hashlib.sha256(path.read_bytes()).hexdigest()


def listed_files(attribution):
    """the file paths an ATTRIBUTION.md lists as bullets"""
    return [l[3:-1] for l in attribution.splitlines() if l.startswith("* `") and l.endswith("`")]


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
        check(not any("Imported_WoWPro_" in n or "Imported_Quests_" in n or "Imported_Storylines" in n or "/Data/Imported_" in n
                      for n in names), "no WoW-Pro- or Questie-derived file is packaged")
        check(man["excluded"] == [] and "toc_lines_stripped" not in man, "the clean checkout holds no never-shipped file and nothing is stripped")
        check({"LICENSE.txt", "ATTRIBUTION.md", "README.md"} <= set(res.files), "LICENSE.txt, ATTRIBUTION.md and README.md are added")
        ql = [r for r in man["files"] if r["path"].endswith("/Guides/Imported_QuestLines_retail.lua")]
        check(len(ql) == 1 and ql[0]["category"] == "wiki-cc-by-sa" and "QuestLine" in ql[0]["source"],
              "the quest-line storylines (wiki + Blizzard data) ship as wiki CC BY-SA data")
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
        with zipfile.ZipFile(uni) as z:
            forever = z.read(f"{pr.ADDON}/CompletionRoute_Forever.toc").decode()
            same = []
            for toc in sorted(t for tocs in pr.CLIENTS.values() for t in tocs):
                src_lines = (d / pr.ADDON / toc).read_text(encoding="utf-8").splitlines()
                pkg_lines = z.read(f"{pr.ADDON}/{toc}").decode().splitlines()
                diff = [(a, b) for a, b in zip(src_lines, pkg_lines) if a != b]
                same.append(len(src_lines) == len(pkg_lines) and len(diff) == 1 and diff[0][1] == "## Version: 9.9.9-test1")
        check(len(same) == 6 and all(same), "each of the six packaged TOCs differs from its source TOC only by the stamped version")
        check("_gaps" not in forever and "Imported_Entrances" not in forever and "Imported_Wiki_forever" in forever,
              "Forever TOC lists its wiki guides and no gaps or entrance file")
        prov = json.loads((v1 / "provenance.json").read_text())
        recorded = {r["path"] for r in prov["files"]}
        check(prov["gate"]["result"] == "PASS" and znames <= recorded, "provenance.json covers every zip entry")
        check("Guides/Imported_Wiki_era.lua" in attribution and "CC BY-SA 4.0" in attribution and "ShareAlike" in attribution,
              "ATTRIBUTION.md lists the wiki files with licence and share-alike note")
        check("PolyForm Noncommercial" in licence and "help@batesai.org" in licence, "LICENSE.txt is the PolyForm licence with the rider")
        check(f"{pr.ADDON}/Libs/CallbackHandler-1.0/LICENSE.txt" in znames, "Ace3 licence text ships with CallbackHandler")
        with zipfile.ZipFile(v1 / f"{pr.ADDON}-9.9.9-test1-era.zip") as z:
            era = set(z.namelist())
            era_attr = z.read(f"{pr.ADDON}/ATTRIBUTION.md")
        check(f"{pr.ADDON}/Guides/Imported_Wiki_retail.lua" not in era and f"{pr.ADDON}/CompletionRoute.toc" not in era
              and f"{pr.ADDON}/CompletionRoute_Vanilla.toc" in era, "per-client era zip holds only the era TOC and data")
        era_listed = listed_files(era_attr.decode())
        check("Guides/Imported_Wiki_era.lua" in era_listed and all(f"{pr.ADDON}/{f}" in era for f in era_listed)
              and "Guides/Imported_Wiki_retail.lua" in listed_files(attribution),
              f"per-client era ATTRIBUTION.md lists only files in the era zip ({len(era_listed)}); the universal one lists all")
        era_rec = next(r for r in json.loads((v1 / "provenance.json").read_text())["packages"] if r["client"] == "era")
        check([d["sha256"] for d in era_rec.get("differs", [])] == [__import__("hashlib").sha256(era_attr).hexdigest()],
              "provenance.json records the per-client ATTRIBUTION.md that differs from the files[] record")
        sha1 = {p["name"]: p["sha256"] for p in prov["packages"]}
        code, res, man, _ = env.run(d, "--version", "9.9.9-test1", "--layout", "both")
        check(code == 0 and {p["name"]: p["sha256"] for p in man["packages"]} == sha1, "zips are byte-for-byte reproducible")
        code, res, man, _ = env.run(d, "--write", "--out", str(dist), "--version", "9.9.9-test2")
        check(code == 0 and (dist / "archive" / "9.9.9-test1").is_dir() and not v1.exists() and (dist / "9.9.9-test2").is_dir(),
              "a new --write moves the previous build to dist/archive/")
        bad = env.scenario()
        append(bad / pr.ADDON / "Guides" / "Imported_Wiki_era.lua", "A x|QID|1|M|1,1|Z|1; X|N|To X. (location: Questie data)|\n")
        before = sorted(p.name for p in (dist / "archive").iterdir())
        code, res, man, _ = env.run(bad, "--write", "--out", str(dist), "--version", "9.9.9-test3")
        failed = sorted((dist / "failed").glob("9.9.9-test3-*"))
        check(code == 1 and len(failed) == 1 and sorted(p.name for p in failed[0].iterdir()) == ["gate.txt", "provenance.json"]
              and not (dist / "9.9.9-test3").exists() and (dist / "9.9.9-test2").is_dir()
              and sorted(p.name for p in (dist / "archive").iterdir()) == before,
              "a failed --write writes only gate.txt + provenance.json to dist/failed/ and moves nothing")

        print("write mode: what --write may move")
        test2 = dist / "9.9.9-test2" / f"{pr.ADDON}-9.9.9-test2.zip"
        sha2 = zip_sha(test2)
        code, res, man, _ = env.run(bad, "--write", "--out", str(dist), "--version", "9.9.9-test2")
        check(code == 1 and zip_sha(test2) == sha2 and len(list((dist / "failed").glob("9.9.9-test2-*"))) == 1
              and sorted(p.name for p in (dist / "archive").iterdir()) == before,
              "a failing rebuild of the same version leaves the passing build and its zip untouched")
        code, res, man, _ = env.run(d, "--write", "--out", str(dist), "--version", "9.9.9-test2")
        arch2 = sorted((dist / "archive").glob("9.9.9-test2*"))
        check(code == 0 and len(arch2) == 1 and zip_sha(arch2[0] / test2.name) == sha2 and (dist / "9.9.9-test2" / test2.name).is_file(),
              "a passing rebuild of the same version archives the earlier build instead of deleting it")
        code, res, man, _ = env.run(d, "--write", "--out", str(dist), "--version", "9.9.9-test2")
        check(code == 0 and len(list((dist / "archive").glob("9.9.9-test2*"))) == 2,
              "... and a third build of it gets its own archive name (nothing overwritten)")
        desk = tmp / "Desktop"
        for sub in ("Photos", "Taxes 2025", "3.0.0", "archive"):
            (desk / sub).mkdir(parents=True)
            (desk / sub / "keep.txt").write_text("mine\n")
        (desk / "notes.txt").write_text("mine\n")
        (desk / "4.0.0").mkdir()
        (desk / "4.0.0" / "provenance.json").write_text('{"product": "something else", "version": "4.0.0"}\n')
        mine = sorted(p.name for p in desk.iterdir())
        code, res, man, _ = env.run(d, "--write", "--out", str(desk), "--version", "9.9.9-desk1")
        code2, res, man, _ = env.run(d, "--write", "--out", str(desk), "--version", "9.9.9-desk2")
        check(code == 0 and code2 == 0 and sorted(p.name for p in desk.iterdir()) == sorted(mine + ["9.9.9-desk2"])
              and sorted(p.name for p in (desk / "archive").iterdir()) == ["9.9.9-desk1", "keep.txt"]
              and all((desk / s / "keep.txt").is_file() for s in ("Photos", "Taxes 2025", "3.0.0")),
              "--out on a folder with other folders moves only the packager's own earlier build to archive/")
        (desk / "9.9.9-mine").mkdir()
        (desk / "9.9.9-mine" / "keep.txt").write_text("mine\n")
        err = usage_error(env, d, "--write", "--out", str(desk), "--version", "9.9.9-mine")
        check(err is not None and "not written by this packager" in err and (desk / "9.9.9-mine" / "keep.txt").is_file()
              and (desk / "9.9.9-desk2").is_dir(), "a dist/<version> the packager did not write is a usage error, nothing moved")

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

        # ---- one build: nothing derived from another add-on's data may be in CompletionRoute/ or in a TOC -------------
        for rel, kind in (("Guides/Imported_Quests_era_gaps.lua", "a leftover _gaps guide file"),
                          ("Guides/Imported_Quests_era.lua", "a leftover Questie-derived guide file (measurement input)"),
                          ("Guides/Imported_Storylines_retail.lua", "the old Questie-derived storylines"),
                          ("Data/Imported_Entrances.lua", "the Questie-derived dungeon doors"),
                          ("Data/Imported_Anything.lua", "any generated file in Data/Imported_*"),
                          ("Guides/Imported_WoWPro_era.lua", "a leftover WoW-Pro export")):
            res, text = expect_fail(env, f"{kind} lying in the checkout (no TOC lists it)", "interop-derived", rel,
                                    lambda d, a, rel=rel: (a / rel).write_text(STAND_IN["interop-questie"], encoding="utf-8"))
            check(not any(r["path"].endswith("/" + rel) for r in pr.manifest(res)["files"]), "... and it is not packaged")
        def plant_gaps_line(d, a):      # the dev build's TOC line, with its file
            (a / "Guides" / "Imported_Quests_era_gaps.lua").write_text(STAND_IN["interop-questie"], encoding="utf-8")
            append(a / "CompletionRoute_Vanilla.toc", "Guides\\Imported_Quests_era_gaps.lua\n")
            git(d, "add", "-A"); git(d, "commit", "-qm", "plant")
        res, _ = expect_fail(env, "a TOC that lists a _gaps guide file", "interop-derived", "CompletionRoute_Vanilla.toc", plant_gaps_line)
        check(has(res, "interop-derived", "Guides/Imported_Quests_era_gaps.lua"), "... and the file itself fails too")
        def plant_entrance_line(d, a):  # the line alone: the file is gone, the TOC still names it
            append(a / "CompletionRoute_TBC.toc", "Data\\Imported_Entrances.lua\n")
            git(d, "add", "-A"); git(d, "commit", "-qm", "plant")
        expect_fail(env, "a TOC that lists Data/Imported_Entrances.lua (file absent)", "interop-derived", "CompletionRoute_TBC.toc",
                    plant_entrance_line)

        def plant_deps(d, addon):     # the quest prerequisite index of the retired dev build (gaps guides + storylines)
            (addon / "Data" / "QuestDeps_era.lua").write_text(
                "-- then the gaps guides (Questie-derived) and the retail storylines for quests the wiki lacks.\n"
                "local _, NS = ...\n", encoding="utf-8")
        expect_fail(env, "quest prerequisite index left over from the dev build", "interop-derived", "Data/QuestDeps_era.lua", plant_deps)
        expect_fail(env, "Questie fallback line in wiki data", "interop-derived", "Guides/Imported_Wiki_era.lua",
                    lambda d, a: append(a / "Guides" / "Imported_Wiki_era.lua",
                                        "T Foo|QID|5|M|1,1|Z|1; X|N|To Foo. (location: Questie data)|\n"))
        expect_fail(env, "Questie-credited point in the quest-line storylines", "interop-derived",
                    "Guides/Imported_QuestLines_retail.lua",
                    lambda d, a: append(a / "Guides" / "Imported_QuestLines_retail.lua",
                                        "T Foo|QID|5|M|1,1|Z|1; X|N|To Foo. (location: Questie data)|\n"))
        # achievements and quest lines made from the retired dev build's wiki file said so in their header: a leftover
        # still fails (tools/gen_completion_guides.py now refuses such a wiki file instead of writing from it)
        for rel, fl in (("Guides/Imported_QuestLines_retail.lua", "retail"), ("Guides/Imported_Achievements_mop.lua", "mop")):
            expect_fail(env, f"{rel} left over from the dev build", "interop-derived", rel,
                        lambda d, a, rel=rel, fl=fl: append(a / rel, OLD_LOCAL_BUILD.format(fl=fl) + "\n"))
        expect_fail(env, "the offline measurement file copied over the wiki guides", "interop-derived", "Guides/Imported_Wiki_tbc.lua",
                    lambda d, a: (a / "Guides" / "Imported_Wiki_tbc.lua").write_text(
                        "-- MEASUREMENT ONLY, never part of the add-on (tools/wiki/gen_wiki_guides.py --measure-fallback): steps whose\n"
                        "-- note says \"(location: Blizzard data)\" / \"(location: Questie data)\" took their map point from the\n"
                        'error("measurement file")\n', encoding="utf-8"))
        def plant_old_story(d, a):
            toc = a / "CompletionRoute.toc"
            toc.write_text(toc.read_text().replace("Guides\\Imported_QuestLines_retail.lua", "Guides\\Imported_Storylines_retail.lua"))
            (a / "Guides" / "Imported_Storylines_retail.lua").write_text(STAND_IN["interop-questie"], encoding="utf-8")
            git(d, "add", "-A"); git(d, "commit", "-qm", "plant")
        res, _ = expect_fail(env, "a TOC that still lists the old Questie-derived storylines", "interop-derived",
                             "CompletionRoute.toc", plant_old_story)
        check(not any(r["path"].endswith("/Guides/Imported_Storylines_retail.lua") for r in pr.manifest(res)["files"]),
              "... and the file is not packaged")
        # retail client quest pins (2026-11-11 review): a step whose point is a Blizzard quest pin ships only in a file
        # whose header names QuestPOIBlob + QuestPOIPoint and the client build
        poi_step = "T Foo|QID|5|M|50.0,50.0|Z|1; X|N|To Foo. (location: Blizzard quest POI, the turn-in area)|\n"
        expect_fail(env, "quest-pin step in a wiki file without the QuestPOI header", "no-provenance",
                    "Guides/Imported_Wiki_retail.lua", lambda d, a: append(a / "Guides" / "Imported_Wiki_retail.lua", poi_step))
        expect_fail(env, "quest-pin header with an unknown build", "no-provenance", "Guides/Imported_Wiki_retail.lua",
                    lambda d, a: (a / "Guides" / "Imported_Wiki_retail.lua").write_text(
                        "-- Steps ... Blizzard QuestPOIBlob + QuestPOIPoint tables via wago.tools, build unknown (client data).\n"
                        + STAND_IN["wiki-cc-by-sa"] + poi_step, encoding="utf-8"))
        d = env.scenario()
        (d / pr.ADDON / "Guides" / "Imported_Wiki_retail.lua").write_text(
            "-- Steps whose note says \"(location: Blizzard quest POI, ...)\" take their map point from the client's quest "
            "pins, not from the wiki: Blizzard QuestPOIBlob + QuestPOIPoint tables via wago.tools, build wow 12.1.5.70783 "
            "(client data, facts only).\n" + STAND_IN["wiki-cc-by-sa"] + poi_step, encoding="utf-8")
        code, res, _, _ = env.run(d)
        check(code == 0 and not has(res, "no-provenance", "Guides/Imported_Wiki_retail.lua"),
              "quest-pin steps pass when the header names the tables and the build")
        # player contributions (2026-11-12): a step that credits them ships only in a file whose header names the open
        # data repository, its licence and the commit the areas came from
        sha = "0123456789abcdef0123456789abcdef01234567"
        contrib_step = "A Foo|QID|5|M|50.0,50.0|Z|1429; Elwynn Forest|N|From Bar. (location: player contributions, 3 players)|\n"
        contrib_hdr = ('-- Steps whose note says "(location: player contributions, ...)" take their map point from where '
                       "players stood, not from the wiki: merged player contributions, wow-completionist-data "
                       "contributions/areas/tbc.json (https://github.com/danielalanbates/wow-completionist-data, "
                       "CC BY-SA 4.0), commit {commit} (see Guides/WIKI_DATA_LICENSE.md).\n")

        def plant_contrib(rel, commit, step=contrib_step):
            def plant(d, a):
                head = contrib_hdr.format(commit=commit) if commit else ""
                (a / rel).write_text(head + STAND_IN["wiki-cc-by-sa"] + step, encoding="utf-8")
            return plant
        wiki_tbc = "Guides/Imported_Wiki_tbc.lua"
        expect_fail(env, "contributed step in a wiki file without the contributions header", "no-provenance", wiki_tbc,
                    plant_contrib(wiki_tbc, None))
        expect_fail(env, "contributions header with an unknown commit", "no-provenance", wiki_tbc,
                    plant_contrib(wiki_tbc, "unknown"))
        expect_fail(env, "contributions header whose areas differ from the commit", "no-provenance", wiki_tbc,
                    plant_contrib(wiki_tbc, sha + "-dirty"))
        expect_fail(env, "contributions header with a shortened commit", "no-provenance", wiki_tbc,
                    plant_contrib(wiki_tbc, sha[:12]))
        ach_step = ("C Foo|ACH|7;8|M|50.0,50.0|Z|84; Stormwind City|N|Bar (location: player contributions, 2 players; "
                    "quest 5)|\n")
        expect_fail(env, "achievement criterion on a contributed quest point, no header", "no-provenance",
                    "Guides/Imported_Achievements_retail.lua",
                    plant_contrib("Guides/Imported_Achievements_retail.lua", None, ach_step))
        d = env.scenario()
        for rel, step in ((wiki_tbc, contrib_step), ("Guides/Imported_Achievements_retail.lua", ach_step),
                          ("Guides/Imported_QuestLines_retail.lua", contrib_step)):
            plant_contrib(rel, sha, step)(d, d / pr.ADDON)
        code, res, _, _ = env.run(d)
        check(code == 0 and not has(res, "no-provenance"),
              "contributed steps pass when the header names the data repository and a full commit"
              + ("" if code == 0 else " (got: " + "; ".join(f.text() for f in res.failures)[:300] + ")"))
        d = env.scenario()
        (d / pr.ADDON / wiki_tbc).write_text(contrib_hdr.format(commit=sha) + STAND_IN["wiki-cc-by-sa"], encoding="utf-8")
        code, res, _, _ = env.run(d)
        check(code == 0, "a file with the header and no contributed step passes")
        expect_fail(env, "WoW-Pro guide text in gold data", "interop-derived", "Guides/Imported_Gold_tbc.lua",
                    lambda d, a: append(a / "Guides" / "Imported_Gold_tbc.lua", 'R({ id="x", author="WoWPro Team", text=[[ ]] })\n'))
        def plant_xml(d, a):
            x = a / "Guides" / "Guides.xml"
            x.write_text(x.read_text().replace("</Ui>", '\t<Script file="Imported_WoWPro_era.lua"/>\n</Ui>'))
            # a leftover export in the checkout (no TOC lists it since the adapter was removed on 2026-11-11)
            (a / "Guides" / "Imported_WoWPro_era.lua").write_text(STAND_IN["interop-wowpro"], encoding="utf-8")
            git(d, "add", "-A"); git(d, "commit", "-qm", "plant")
        expect_fail(env, "WoW-Pro file pulled in through an XML include", "interop-derived", "Guides/Imported_WoWPro_era.lua", plant_xml)
        def plant_gap_row(d, a):        # a leftover _gaps guide file and the row an old bake made for its guide
            append(a / "Guides" / "Imported_Quests_era_gaps.lua", 'R({ id="qdb:era:1:Alliance", name="Gap", type="Quests", text=[==[\n]==] })\n')
            append(a / "Data" / "RouteOrder_era.lua", 'O["qdb:era:1:Alliance"] = { n = 2, sum = 1, o = "1,2" }\n')
        res, _ = expect_fail(env, "baked order row for a Questie-derived _gaps guide", "interop-derived", "Data/RouteOrder_era.lua",
                             plant_gap_row)
        check(any("qdb: 1" in f.detail for f in res.failures), "the finding counts the rows by guide-id prefix")
        d = env.scenario()
        append(d / pr.ADDON / "Data" / "RouteOrder_tbc.lua", 'O["wiki:tbc:9999:Both"] = { n = 2, sum = 1, o = "1,2" }\n'
               'O["qdb:tbc:1:Alliance"] = { n = 2, sum = 1, o = "1,2" }\n')
        code, res, _, _ = env.run(d)
        check(code == 0 and any("RouteOrder_tbc.lua" in w and "stale" in w and "2 baked order row" in w for w in res.warnings),
              "baked rows for guides that exist nowhere (a deleted wiki guide, a deleted _gaps guide) are a warning (stale "
              "bake), not a failure")
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
        def plant_char_file(d, a):
            (a / "Textures" / "Zorblaxia_arrow.tga").write_bytes(b"\0" * 18)
            git(d, "add", "-A"); git(d, "commit", "-qm", "plant")
        res, text = expect_fail(env, "WoW character name in a file name", "personal-data", "Textures/Zorblaxia_arrow.tga",
                                plant_char_file)
        man = pr.manifest(res)
        check("zorblaxia" not in text.lower() and "zorblaxia" not in json.dumps(man).lower()
              and any(f["path"] == "Textures/[personal term]_arrow.tga" for f in man["gate"]["failures"]),
              "the report and provenance.json mask a personal term in a file name")

        expect_fail(env, "access key", "secret", "Data/RouteOrder_era.lua",
                    lambda d, a: append(a / "Data" / "RouteOrder_era.lua", '-- key = "' + "AKIA" + "Z" * 16 + '"\n'))
        expect_fail(env, "private key block", "secret", "Guides/Imported_Achievements_mop.lua",
                    lambda d, a: append(a / "Guides" / "Imported_Achievements_mop.lua", "--[[ -----BEGIN RSA " + "PRIVATE KEY----- ]]\n"))
        # fake keys, built here so no key-shaped string sits in this file
        for label, value, said in (("Cerebras key", "csk" + "-" + "a1b2c3d4" * 6, "Cerebras API key"),
                                   ("Groq key", "gsk" + "_" + "A1b2C3d4" * 7, "Groq API key"),
                                   ("Hugging Face token", "hf" + "_" + "AbCdEfGhIj" * 4, "Hugging Face token"),
                                   ("xAI key", "xai" + "-" + "Ab1Cd2Ef3" * 9, "xAI API key"),
                                   ("npm token", "npm" + "_" + "Ab1Cd2Ef3" * 5, "npm token"),
                                   ("GitLab token", "glpat" + "-" + "Ab1Cd2Ef3" * 3, "GitLab token"),
                                   ("OpenRouter key", "sk" + "-or-v1-" + "ab12" * 16, "sk- API key"),
                                   ("unquoted api_key=", "api_key" + "=" + "Zq8" * 12, "credential assignment"),
                                   ("env line OPENAI_API_KEY=", "export OPENAI_API" + "_KEY=" + "Zq8x" * 10, "credential assignment"),
                                   ("quoted MY_PASSWORD", 'MY_PASSWORD = "' + "hunter2hunter2" + '"', "credential assignment")):
            res, _ = expect_fail(env, f"secret: {label}", "secret", "Guides/Imported_Gold_era.lua",
                                 lambda d, a, v=value: append(a / "Guides" / "Imported_Gold_era.lua", f"-- {v}\n"))
            check(any(f.rule == "secret" and f.detail.startswith(said + " pattern") for f in res.failures),
                  f"... reported as \"{said}\"")
        d = env.scenario()
        append(d / pr.ADDON / "Guides" / "Imported_Gold_era.lua", "-- api_key = NS.Config.apiKey; local token = GetToken()\n"
               "-- passwords = 3; hf_max_level = 60; task-csk-1; password: see the options panel\n")
        code, res, _, _ = env.run(d)
        check(code == 0 and not has(res, "secret"), "code that names a key without holding one does not fail the secret rule")

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
        for p in sorted((main_co / pr.ADDON).rglob("Imported_*.lua")) + sorted((main_co / pr.ADDON).rglob("RouteOrder_*.lua")) \
                + sorted((main_co / pr.ADDON).rglob("QuestDeps_*.lua")):
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

        print("dirty flag covers the packager and its templates")
        d = env.scenario()
        (d / "tools" / "release").mkdir(parents=True)
        shutil.copyfile(TOOLS / "package_release.py", d / "tools" / "package_release.py")
        for f in ("ATTRIBUTION.md", "README.md"):
            shutil.copyfile(TOOLS / "release" / f, d / "tools" / "release" / f)
        git(d, "add", "-A"); git(d, "commit", "-qm", "packager")

        def own_packager(stage):
            p = subprocess.run([sys.executable, "-B", str(d / "tools" / "package_release.py"), "--repo", str(d), "--tmp",
                                str(tmp), "--wow-dir", str(env.wow), "--no-local-terms", "--no-measure", "--stage-dir",
                                str(stage)], capture_output=True, text=True)
            return p.returncode, p.stdout + p.stderr
        code, text = own_packager(tmp / "own1")
        check(code == 0 and "-dirty" not in text and "uncommitted" not in text, "a committed packager builds a clean version")
        tpl = d / "tools" / "release" / "README.md"
        tpl.write_text(tpl.read_text().replace("**Beta.**", "**Beta. UNCOMMITTED EDIT.**"))
        code, text = own_packager(tmp / "own2")
        check(code == 0 and "-dirty" in text and "uncommitted" in text
              and "UNCOMMITTED EDIT" in (tmp / "own2" / pr.ADDON / "README.md").read_text(),
              "an uncommitted edit to a release template makes the build -dirty, with a note")

        print("usage errors exit 2, a crash exits 3")
        d = env.scenario()
        afile = tmp / "afile"
        afile.write_text("x\n")
        for flag, val in (("--stage-dir", afile), ("--out", afile), ("--tmp", tmp / "nowhere"), ("--db", tmp / "nowhere" / "p.sqlite")):
            extra = ["--write"] if flag == "--out" else []
            try:
                code = pr.run(["--repo", str(d), "--no-local-terms", "--no-measure", "--wow-dir", str(env.wow), flag, str(val),
                               *extra], out=io.StringIO())[0]
                err = None
            except SystemExit as e:
                err = e.code if isinstance(e.code, str) else None
            check(err is not None and flag in err, f"{flag} {val.name}: usage error before any work")
        argv, err = sys.argv, io.StringIO()
        sys.argv = ["package_release.py", "--stage-dir", str(afile)]
        try:
            with contextlib.redirect_stderr(err):
                code = pr.main()
        finally:
            sys.argv = argv
        check(code == 2, f"main() exits 2 on a usage error ({code})")
        real = pr.assemble
        pr.assemble = lambda opts: (_ for _ in ()).throw(OSError("planted crash"))
        sys.argv = ["package_release.py", "--repo", str(d), "--tmp", str(tmp)]
        try:
            with contextlib.redirect_stderr(err):
                code = pr.main()
        finally:
            sys.argv, pr.assemble = argv, real
        check(code == 3 and "planted crash" in err.getvalue(), f"main() exits 3, not 1 (gate failed), on a crash ({code})")
    finally:
        if keep:
            print("kept " + str(tmp))
        else:
            shutil.rmtree(tmp, ignore_errors=True)
    print("ALL PACKAGE TESTS PASSED" if fails == 0 else f"{fails} PACKAGE TESTS FAILED")
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
