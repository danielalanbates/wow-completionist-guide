#!/usr/bin/env python3
# CompletionRoute :: tools/test_contrib_gen.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Offline test of the last step of player contributions (docs/CONTRIBUTE.md): merged areas from the open data
repository reach the shipped guides.

    python3 tools/test_contrib_gen.py [--unit] [--keep]        (8 GB Mac: through heavy.sh)

It reads tools/fixtures/contributions (invented positions, never player data) and writes only into a temp folder
($CR_TEST_TMP, else the system's): nothing under CompletionRoute/, tools/ or docs/ is created or changed, and the test
checks that itself.

Part 1 needs only tracked files: how the areas file is read (trusted and confirmed only, known maps only, heaviest
first, up to three points on one map), the step keys against the add-on's own (Core/Contribute.lua KeyFor through
Core/Guide.lua, under luajit), the commit in the provenance line, the options, the packager rule on that line, the
coverage count, and that tools/gen_completion_guides.py repeats the line and credits a contributed quest point.
Part 2 runs the generator for Classic Era twice into the temp folder (tools/wiki/gen_wiki_guides.py --out): once with
no contributions, once with the fixture.  It needs the gitignored inputs (tools/wiki/wiki.sqlite, tools/wiki/cache,
tools/db2) and is SKIPPED, loudly, on a checkout without them.  Part 3 passes a contributed step through the
quest-line generator (needs tools/db2/retail; skipped the same way).  --unit runs part 1 only.
"""
import contextlib
import hashlib
import io
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parent
sys.path.insert(0, str(TOOLS))
sys.path.insert(0, str(TOOLS / "wiki"))
import gen_wiki_guides as gw  # noqa: E402
import gen_completion_guides as gc  # noqa: E402
import package_release as pr  # noqa: E402
import coverage as cov  # noqa: E402

FIXTURE = TOOLS / "fixtures" / "contributions"
TMPROOT = os.environ.get("CR_TEST_TMP") or ("/private/tmp/claude-501" if os.path.isdir("/private/tmp/claude-501") else None)
GIT = shutil.which("git", path="/usr/bin") or shutil.which("git")
NOTE = "(location: player contributions"
fails = skipped = 0


def check(ok, msg, detail=""):
    global fails
    if ok:
        print("  ok   " + msg)
    else:
        fails += 1
        print("  FAIL " + msg + (f" :: {detail}" if detail != "" else ""))
    return ok


def skip(msg):
    global skipped
    skipped += 1
    print("  SKIP " + msg)


def git(repo, *args):
    env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    return subprocess.run([GIT, "-C", str(repo), "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid",
                           "-c", "commit.gpgsign=false", *args], check=True, capture_output=True, text=True, env=env).stdout


def data_repo(tmp):
    """a scratch checkout laid out like the data repository, holding the fixture, with one commit -> (folder, commit)"""
    repo = tmp / "datarepo"
    shutil.copytree(FIXTURE, repo / "contributions")
    git(repo, "init", "-q")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "fixture contributions")
    return repo / "contributions", git(repo, "rev-parse", "HEAD").strip()


class Gate:
    """collects what the packager's content scan says about one file"""

    def __init__(self):
        self.failures = []

    def fail(self, rule, path, detail):
        self.failures.append((rule, path, detail))


def gate(rel, text, category="wiki-cc-by-sa"):
    g = Gate()
    pr.Scanner({}).scan(rel, text.encode("utf-8"), category, g)
    return [f for f in g.failures if f[0] == "no-provenance"]


def raises(fn, *a, **k):
    try:
        fn(*a, **k)
    except SystemExit as e:
        return str(e.code)
    return None


# the add-on's own keys: parse step lines with Core/Guide.lua and ask Core/Contribute.lua KeyFor
KEYS_LUA = r'''
package.path = "./?.lua;" .. package.path
local ADDON, NS = "CompletionRoute", {}
STUB_MAPS = dofile("tools/maps_era.lua")
dofile("tools/stubs.lua")
GetBuildInfo = function() return "x", "0", "2026", 11508 end
local function load(path) assert(loadfile("CompletionRoute/" .. path))(ADDON, NS) end
for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", "Data/ZoneAliases.lua",
    "Core/Contribute.lua" }) do load(f) end
NS.Print, NS.Debug = function() end, function() end
local n = 0
for ln in io.lines(arg[1]) do
    if ln:find("(location: player contributions", 1, true) and ln:match("^[ACT] ") then
        n = n + 1
        local st = assert(NS.Guide.ParseLine(ln, n))
        local pts = {}
        for _, c in ipairs(st.coords or {}) do pts[#pts + 1] = ("%.1f,%.1f"):format(c.x * 100, c.y * 100) end
        io.write(tostring(NS.Contribute.KeyFor(st)), "\t", tostring(st.zone), "\t", table.concat(pts, ";"), "\t",
            tostring(st.qid and st.qid[1]), "\n")
    end
end
'''


def addon_keys(tmp, guide_file):
    """[(key, map, 'x,y;x,y', quest)] of the contributed steps of a guide file, as the add-on reads them; None without
    luajit"""
    lj = shutil.which("luajit")
    if not lj:
        return None
    script = tmp / "contrib_keys.lua"
    script.write_text(KEYS_LUA, encoding="utf-8")
    r = subprocess.run([lj, "-joff", str(script), str(guide_file)], cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit("contrib_keys.lua failed: " + r.stderr[-600:])
    return [tuple(ln.split("\t")) for ln in r.stdout.splitlines() if ln]


def step_lines(text):
    return [ln for ln in text.splitlines() if re.match(r"^[ACT] ", ln)]


def quest_of(line):
    m = re.search(r"\|QID\|(\d+)\|", line)
    return int(m.group(1)) if m else None


def find(lines, act, qid, qo=None):
    """the one step line of a quest: action, quest id, optional |QO| number (0 = a C step without the tag)"""
    out = []
    for ln in lines:
        if not ln.startswith(act + " ") or quest_of(ln) != qid:
            continue
        m = re.search(r"\|QO\|(\d+)\|", ln)
        if qo is None or (int(m.group(1)) if m else 0) == qo:
            out.append(ln)
    return out[0] if len(out) == 1 else None


def state(paths):
    """size, mtime and (for small files) sha256 of files that a test run must not touch"""
    out = {}
    for p in paths:
        if p.exists():
            s = p.stat()
            out[p] = (s.st_size, s.st_mtime_ns, hashlib.sha256(p.read_bytes()).hexdigest() if s.st_size < 30_000_000 else "")
        else:
            out[p] = None
    return out


# ---------------------------------------------------------------------------------------------------------------------
def part1(tmp):
    print("reading the areas file")
    atlas = gw.wikimaps.Atlas()
    maps = atlas.sets["era"]
    c = gw.Contributions(FIXTURE, "era", maps)
    check(set(c.areas) == {"A:46", "A:45", "A:5805", "A:60", "A:9999999", "C:45:0", "C:52:1", "C:52:2", "C:60:1", "C:7:1",
                           "T:54", "T:60", "T:6181"}, "only keys with a usable area are kept", sorted(c.areas))
    check(dict(c.skipped) == {"single": 2, "unknown map": 2, "malformed": 1, "not a quest step": 1},
          "single areas, unknown maps, a position off the map and a non-quest key are counted and not used", dict(c.skipped))
    check("T:37" not in c.areas and "C:3904:1" not in c.areas, "a 'single' area is never used")
    check("A:176" not in c.areas and [a["map"] for a in c.areas["A:45"]] == [1429],
          "an area on a map this client does not have is skipped; the same step's other area stays")
    check([a["w"] for a in c.areas["C:52:2"]] == [20, 15, 10, 8, 5], "areas are ordered heaviest first, whatever the file's order")
    one = c.points("A:46")
    check(c.tag(one) == (1429, "74.0,72.4") and c.note(one) == " (location: player contributions, 3 players)",
          "accept: the heaviest area, one point, the note names the source and the players", (c.tag(one), c.note(one)))
    two = c.points("C:52:1", gw.CONTRIB_POINTS)
    check(c.tag(two) == (1429, "70.2,77.4;76.6,80.2") and c.note(two) == " (location: player contributions, 1 player, 2 areas)",
          "an objective with two areas gets two points", (c.tag(two), c.note(two)))
    three = c.points("C:52:2", gw.CONTRIB_POINTS)
    check(c.tag(three) == (1429, "68.2,74.4;66.0,70.0;72.0,78.0") and c.note(three).endswith(", 4 players, 3 areas)"),
          "an objective takes at most three areas, all on the heaviest one's map", (c.tag(three), c.note(three)))
    check(len(c.points("C:52:2")) == 1 and c.points("T:37") == [] and c.points("A:1") == [],
          "points() gives one area by default and none for a step without a usable area")
    far = c.far("T:60", 1429, "43.3,65.8", atlas.yards)
    check(far is not None and far[1] > 500, "a wiki point far from the contributed area on the same map is reported", far)
    check(c.far("A:60", 1429, "43.3,65.8", atlas.yards) is None, "... a near one is not")
    check(c.far("C:60:1", 1429, "37.9,83.2;61.6,53.6", atlas.yards) is None,
          "... nor a step with several wiki points when one of them is near")
    check(c.far("T:54", 1429, "42.1,65.9", atlas.yards) is None, "... nor an area on another map")
    none = gw.Contributions(FIXTURE, "tbc", atlas.sets["tbc"])
    check(none.areas == {} and none.commit is None, "a folder with no areas file for the client gives nothing")
    bad = tmp / "bad" / "areas"
    bad.mkdir(parents=True)
    (bad / "era.json").write_text(json.dumps({"flavor": "retail", "areas": {}}), encoding="utf-8")
    check(raises(gw.Contributions, tmp / "bad", "era", maps) is not None, "an areas file of another client stops the run")
    (bad / "era.json").write_text("{ not json", encoding="utf-8")
    check(raises(gw.Contributions, tmp / "bad", "era", maps) is not None, "a broken areas file stops the run")
    odd = {"flavor": "era", "areas": {"A:1": "x", "T:1": [{"map": True, "x": 1, "y": 1, "contributors": 2, "weight": 3,
                                                          "confidence": "trusted"}],
                                      "T:2": [{"map": 1429, "x": float("nan"), "y": 1, "contributors": 2, "weight": 3,
                                               "confidence": "trusted"}],
                                      "T:3": [{"map": 1429, "x": "50", "y": 1, "contributors": 2, "weight": 3,
                                               "confidence": "confirmed"}],
                                      "T:4": [{"map": 1429, "x": 50, "y": 50, "contributors": 2, "weight": 3,
                                               "confidence": "certain"}]}}
    (bad / "era.json").write_text(json.dumps(odd), encoding="utf-8")
    o = gw.Contributions(tmp / "bad", "era", maps)
    check(o.areas == {} and o.skipped["malformed"] == 5, "malformed areas (wrong types, NaN, an unknown confidence) are dropped",
          (o.areas, dict(o.skipped)))

    print("step keys")
    check(gw.objective_key(52, 2, True, 2) == "C:52:2", "an objective step with |QO|n| has key C:<quest>:n")
    check(gw.objective_key(45, 0, False, 1) == "C:45:0", "the only objective step of a quest, written without |QO|, has key 0")
    check(gw.objective_key(45, 1, False, 3) is None, "several objective steps without |QO| share key 0 in the add-on: no key")
    synth = tmp / "synthetic_guide.lua"
    cases = [("A Q|QID|46|M|74.0,72.4|Z|1429; Elwynn Forest|N|From X. (location: player contributions, 3 players)|", "A:46"),
             ("T Q|QID|6181|M|56.9,47.1|Z|1436; Westfall|N|To X. (location: player contributions, 1 player)|", "T:6181"),
             ("C Q|QID|52|QO|2|T|Bear|M|68.2,74.4;66.0,70.0;72.0,78.0|Z|1429; Elwynn Forest|N|Bears (location: player "
              "contributions, 4 players, 3 areas)|", gw.objective_key(52, 2, True, 2)),
             ("C Q|QID|45|M|79.0,56.4|Z|1429; Elwynn Forest|N|Search. (location: player contributions, 2 players)|",
              gw.objective_key(45, 0, False, 1))]
    synth.write_text("\n".join(ln for ln, _ in cases) + "\n", encoding="utf-8")
    got = addon_keys(tmp, synth)
    if got is None:
        skip("luajit is not installed: the generator's keys were not compared with Core/Contribute.lua KeyFor")
    else:
        check([g[0] for g in got] == [k for _, k in cases],
              "the generator's keys are the add-on's own (Core/Contribute.lua KeyFor on steps parsed by Core/Guide.lua)",
              [g[0] for g in got])
        check(got[2][2] == "68.2,74.4;66.0,70.0;72.0,78.0" and got[2][1] == "1429",
              "the add-on reads a contributed step's three points and its map", got[2])

    print("options and provenance")
    check(gw.parse_args(["era", "--contributions", "x", "--out=y", "--no-spine"]) == (["era"], {"--no-spine"},
                                                                                     {"--contributions": "x", "--out": "y"}),
          "--contributions DIR and --out DIR are read (both spellings)")
    check(raises(gw.parse_args, ["--contributions"]) and raises(gw.parse_args, ["--bogus"])
          and raises(gw.parse_args, ["--no-contributions", "--contributions", "x"])
          and raises(gw.parse_args, ["--measure-fallback", "--out", "x"]), "bad option use stops the run")
    check(gw.contributions_dir(str(FIXTURE), {}) == FIXTURE and gw.contributions_dir(None, {"CR_CONTRIB": str(FIXTURE)}) == FIXTURE,
          "the folder comes from --contributions, else $CR_CONTRIB")
    check(raises(gw.contributions_dir, str(tmp / "nowhere"), {}) and raises(gw.contributions_dir, None, {"CR_CONTRIB": str(tmp / "nowhere")}),
          "a folder asked for by name must exist")
    keep_default = gw.CONTRIB_DEFAULT
    try:
        gw.CONTRIB_DEFAULT = tmp / "nowhere" / "contributions"
        check(gw.contributions_dir(None, {}) is None, "no option, no variable, no sibling checkout: no contributions")
        gw.CONTRIB_DEFAULT = FIXTURE
        check(gw.contributions_dir(None, {}) == FIXTURE, "the sibling checkout's contributions folder is the default")
    finally:
        gw.CONTRIB_DEFAULT = keep_default
    check(gw.CONTRIB_DEFAULT == ROOT.parent / "wow-completionist-data" / "contributions",
          "the default is ../wow-completionist-data/contributions next to this checkout")
    check(gw.Gen.__init__.__defaults__ == (False, None, None), "Gen reads no contributions unless it is given a folder")
    check(c.commit == "unknown", "a contributions folder that is not the top of a checkout of its own has no known commit "
          "(the fixture sits inside this repository)", c.commit)
    cdir, sha = data_repo(tmp)
    c2 = gw.Contributions(cdir, "era", maps)
    check(c2.commit == sha and re.fullmatch(r"[0-9a-f]{40}", sha) is not None,
          "a checkout of the data repository gives its commit (git rev-parse HEAD)", c2.commit)
    hdr = c2.header()
    check("wow-completionist-data" in hdr and "CC BY-SA 4.0" in hdr and f"commit {sha}" in hdr and hdr.startswith("-- "),
          "the header line names the data repository, CC BY-SA 4.0 and the commit", hdr)
    step = "A Q|QID|46|M|74.0,72.4|Z|1429; Elwynn Forest|N|From X. (location: player contributions, 3 players)|\n"
    check(gate("Guides/Imported_Wiki_era.lua", hdr + "\n" + step) == [], "the packager passes a contributed step under that header")
    check(len(gate("Guides/Imported_Wiki_era.lua", step)) == 1, "... and fails it without the header")
    check(len(gate("Guides/Imported_Wiki_era.lua", c.header() + "\n" + step)) == 1, "... and under a header with an unknown commit")
    (cdir / "areas" / "era.json").write_text((cdir / "areas" / "era.json").read_text(encoding="utf-8") + "\n", encoding="utf-8")
    c3 = gw.Contributions(cdir, "era", maps)
    check(c3.commit == sha + "-dirty" and len(gate("Guides/Imported_Wiki_era.lua", c3.header() + "\n" + step)) == 1,
          "areas that differ from the commit are marked -dirty, and the packager fails that header", c3.commit)
    git(cdir.parent, "checkout", "-q", "--", "contributions/areas/era.json")
    check(gw.Contributions(cdir, "era", maps).commit == sha, "... and clean again once restored")

    print("coverage and the completion generator")
    wiki = tmp / "cov" / "Imported_Wiki_era.lua"
    wiki.parent.mkdir()
    wiki.write_text(hdr + "\n" + step + "T Q|QID|46|Z|1429; Elwynn Forest|N|To X. No coordinates on the wiki; the quest is in "
                    "Elwynn Forest.|\nA R|QID|47|M|1.0,2.0|Z|1429; Elwynn Forest|N|From Y.|\n"
                    "C S|QID|48|QO|1|M|1.0,2.0;3.0,4.0|Z|1429; Elwynn Forest|N|Z (location: player contributions, 2 players, 2 areas)|\n"
                    "C S|QID|48|QO|2|M|5.0,6.0|Z|1429; Elwynn Forest|N|Z (location: player contributions, 2 players)|\n", encoding="utf-8")
    found = cov.scan(wiki, build=True)
    check(found["quest-contrib"] == {46: 1, 48: 2} and found["quest"][46] is True and found["quest"][48] is True
          and found["quest"][47] is True and 47 not in found["quest-contrib"],
          "tools/coverage.py counts a contributed step as located and counts such steps per quest", found["quest-contrib"])
    keep_guides = gc.GUIDES
    try:
        gc.GUIDES = wiki.parent
        for what in ("achievements", "questlines"):
            h = gc.header("era", what)
            check(hdr in h and h.index(hdr) < h.index("local _, NS = ..."),
                  f"tools/gen_completion_guides.py repeats the provenance line in its {what} header")
        check(hdr not in gc.header("era", "missions"), "... and not in the missions header (no wiki steps)")
        wiki.write_text("-- hdr\n" + step.replace(" (location: player contributions, 3 players)", ""), encoding="utf-8")
        check(not any("player contributions" in ln for ln in gc.header("era", "questlines")),
              "... and writes no such line when the wiki file has none")
    finally:
        gc.GUIDES = keep_guides
    return cdir, sha


# ---------------------------------------------------------------------------------------------------------------------
def run_generator(args):
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            gw.main(args)
    except BaseException:
        print(out.getvalue()[-3000:])
        raise
    return out.getvalue()


def part2(tmp, cdir, sha):
    print("the generator, Classic Era, without and with the fixture (into the temp folder)")
    need = [gw.WIKI, ROOT / "tools" / "wiki" / "cache" / "wiki_raw.sqlite"] + [ROOT / "tools" / "db2" / f / "QuestV2.csv" for f in gw.FLAVORS]
    missing = [str(p.relative_to(ROOT)) for p in need if not p.exists()]
    if missing:
        skip("the generator's gitignored inputs are missing (" + ", ".join(missing[:3]) + "): the generator was NOT run. "
             "Fetch and parse the wiki first (tools/wiki/README.md)")
        return
    build = gw.GUIDES / "Imported_Wiki_era.lua"
    watched = [build, gw.GUIDES / "Imported_Spine_era.lua", gw.WIKI, gw.VERIF, ROOT / "tools" / "wiki" / "cache" / "parts_era.json"]
    before = state(watched)
    base_dir, with_dir = tmp / "base", tmp / "with"
    log0 = run_generator(["era", "--no-contributions", "--out", str(base_dir)])
    log1 = run_generator(["era", "--contributions", str(cdir), "--out", str(with_dir)])
    check(state(watched) == before, "the two runs changed nothing in the checkout (guide, spine, wiki.sqlite, the chart, the spine sidecar)")
    base = (base_dir / "Imported_Wiki_era.lua").read_text(encoding="utf-8")
    new = (with_dir / "Imported_Wiki_era.lua").read_text(encoding="utf-8")
    check("player contributions: none read" in log0 and str(cdir) in log1, "the run says which contributions folder it read")

    # --- no contributions: the file is what the build holds ---
    check("player contributions" not in base, "without contributions no step and no header line mentions them")
    if build.exists():
        date = re.compile(r"GENERATED \d{4}-\d\d-\d\d")
        built = build.read_text(encoding="utf-8")
        same = date.sub("GENERATED", base, 1) == date.sub("GENERATED", built, 1)
        why = "if the wiki tables or the generator changed since that file was made, regenerate it first"
        if not same and sorted(base.splitlines()[1:]) == sorted(built.splitlines()[1:]):
            # the same lines in another order: step order is made in tools/wiki/gen_spine.py, where quests that tie in
            # rank are ordered by set iteration and object address (fixup, frozen_resplit); not a contributions change
            why = "the same lines in another order: the spine's order of tied quests is not stable from run to run (tools/wiki/gen_spine.py)"
        check(same, "without contributions the output is byte-identical to the build's Guides/Imported_Wiki_era.lua "
              "(but for the date in line 1)", why)
        spine = gw.GUIDES / "Imported_Spine_era.lua"
        if spine.exists():
            check(date.sub("GENERATED", (base_dir / "Imported_Spine_era.lua").read_text(encoding="utf-8"), 1)
                  == date.sub("GENERATED", spine.read_text(encoding="utf-8"), 1), "... and so is the spine")
    else:
        skip("no Guides/Imported_Wiki_era.lua in this checkout: the output without contributions was not compared with a build file")

    # --- preconditions: what the wiki gives these steps today (the fixture's README) ---
    b, n = step_lines(base), step_lines(new)
    drift = "the wiki data changed: pick another quest for this case (tools/fixtures/contributions/README.md)"
    pre = {
        "A:46": find(b, "A", 46), "A:45": find(b, "A", 45), "A:176": find(b, "A", 176), "A:5805": find(b, "A", 5805),
        "C:45:0": find(b, "C", 45, 0), "C:52:1": find(b, "C", 52, 1), "C:52:2": find(b, "C", 52, 2),
        "C:3904:1": find(b, "C", 3904, 1), "T:37": find(b, "T", 37), "T:6181": find(b, "T", 6181),
        "A:60": find(b, "A", 60), "T:60": find(b, "T", 60), "C:60:1": find(b, "C", 60, 1), "C:7:1": find(b, "C", 7, 1),
        "T:54": find(b, "T", 54),
    }
    ok = check(all(pre.values()), "every fixture quest step is in the Classic Era guides", [k for k, v in pre.items() if not v])
    if not ok:
        return
    nopoint = ["A:46", "A:45", "A:176", "A:5805", "C:45:0", "C:52:1", "C:52:2", "C:3904:1", "T:37"]
    check(all("|M|" not in pre[k] for k in nopoint), "precondition: these steps have no wiki point", drift)
    check("the wiki's Sentinel Hill page" in pre["T:6181"], "precondition: A Swift Message's turn-in comes from a wiki place page", drift)
    wikipt = ["A:60", "T:60", "C:60:1", "C:7:1", "T:54"]
    check(all("|M|" in pre[k] and "(location:" not in pre[k] for k in wikipt), "precondition: these steps have a wiki point", drift)

    # --- with contributions ---
    def new_line(key):
        act, q, *o = key.split(":")
        return find(n, act, int(q), int(o[0]) if o else None)

    ln = new_line("A:46")
    check(ln is not None and "|M|74.0,72.4|Z|1429; Elwynn Forest|" in ln and ln.endswith("N|From Bounty Board. (location: player contributions, 3 players)|"),
          "a step with no wiki point gets the contributed point and a note that says where it came from", ln)
    ln = new_line("A:45")
    check(ln is not None and "|M|79.4,55.9|Z|1429; Elwynn Forest|" in ln and ln.endswith("(location: player contributions, 2 players)|"),
          "an area on an unknown map is skipped and the step takes its next area", ln)
    check(new_line("A:176") == pre["A:176"], "a step whose only area is on an unknown map does not change")
    ln = new_line("A:5805")
    check(ln is not None and "|U|14646|M|42.4,66.9|Z|1429; Elwynn Forest|" in ln
          and ln.endswith("N|Starts from the item Goldshire Gift Voucher. (location: player contributions, 2 players)|"),
          "an item-started accept the wiki cannot place takes the contributed point and keeps its item", ln)
    ln = new_line("C:45:0")
    check(ln is not None and "|QO|" not in ln and "|M|79.0,56.4|Z|1429; Elwynn Forest|" in ln and NOTE in ln,
          "an objective step without |QO| takes the area of key C:<quest>:0", ln)
    ln = new_line("C:52:1")
    check(ln is not None and "|QO|1|" in ln and "|M|70.2,77.4;76.6,80.2|Z|1429; Elwynn Forest|" in ln
          and ln.endswith("(location: player contributions, 1 player, 2 areas)|"), "an objective with two areas gets two points", ln)
    ln = new_line("C:52:2")
    check(ln is not None and "|QO|2|" in ln and "|M|68.2,74.4;66.0,70.0;72.0,78.0|Z|1429; Elwynn Forest|" in ln
          and ln.endswith("(location: player contributions, 4 players, 3 areas)|"),
          "an objective with five areas gets the three heaviest on one map", ln)
    check(new_line("C:3904:1") == pre["C:3904:1"] and new_line("T:37") == pre["T:37"], "'single' areas change nothing")
    ln = new_line("T:6181")
    check(ln is not None and "|M|56.9,47.1|Z|1436; Westfall|" in ln and ln.endswith("N|To Thor. (location: player contributions, 1 player)|")
          and "Sentinel Hill" not in ln, "a contributed area outranks the wiki place page", ln)
    check(all(new_line(k) == pre[k] for k in wikipt), "a step with a wiki point keeps it, near or far from the contributed area",
          [k for k in wikipt if new_line(k) != pre[k]])
    credited = [ln for ln in n if NOTE in ln]
    check(len(credited) == 7 and "No coordinates on the wiki" not in "".join(credited),
          "seven steps credit player contributions, none of them still says the wiki has no coordinates", len(credited))

    # --- nothing else changed ---
    strip_pre = re.compile(r"\|PRE\|[\d;]+\|")
    fixture_quests = {46, 45, 5805, 52, 6181}
    diff = (Counter(strip_pre.sub("|", ln) for ln in b) - Counter(strip_pre.sub("|", ln) for ln in n)) + \
           (Counter(strip_pre.sub("|", ln) for ln in n) - Counter(strip_pre.sub("|", ln) for ln in b))
    other = sorted({quest_of(ln) for ln in diff} - fixture_quests)
    check(len(b) == len(n) and not other, "no step of any other quest changed, and no step was added or removed",
          (len(b), len(n), other[:10]))

    # --- provenance ---
    head = new[:4000]
    hline = next((ln for ln in new.splitlines()[:20] if "merged player contributions" in ln), "")
    check(hline.startswith("-- ") and "wow-completionist-data" in hline and "CC BY-SA 4.0" in hline and f"commit {sha}" in hline,
          "the generated file's header names the data repository, its licence and the commit the areas came from", hline)
    check(pr.CONTRIB_HEADER.search(head) is not None and gate("Guides/Imported_Wiki_era.lua", new) == [],
          "the packager's gate passes the generated file")
    check(len(gate("Guides/Imported_Wiki_era.lua", new.replace(hline + "\n", "", 1))) == 1,
          "... and fails it when that header line is taken out")
    check(new.index(hline) < new.index("local _, NS = ...") and base.count("\n") + 1 == new.count("\n"),
          "the line stands in the header, before the code, and is the only line added")

    # --- the chart ---
    v0, v1 = sqlite3.connect(base_dir / "verification.sqlite"), sqlite3.connect(with_dir / "verification.sqlite")
    q = "select steps, wiki, poi, place, fallback, zone, none, contrib from wiki_point_sources where flavor='era' and build='no-fallback'"
    r0, r1 = v0.execute(q).fetchone(), v1.execute(q).fetchone()
    check(r0 is not None and r0[7] == 0 and sum(r0[1:]) == r0[0], "wiki_point_sources without contributions: contrib 0, the sources add up", r0)
    check(r1 is not None and r1[7] == 7 and sum(r1[1:]) == r1[0] and r1[0] == r0[0] and r1[1] == r0[1],
          "wiki_point_sources with the fixture: contrib 7, same steps, same wiki points, the sources add up", r1)
    check(r1[3] == r0[3] - 1 and r0[5] + r0[6] - r1[5] - r1[6] == 6,
          "one step moved from the wiki place page to contributions, six from zone-only or no location", (r0, r1))
    cq = "select quest_id, field, wiki_value, db2_value, note from wiki_db2_conflict where flavor='era' and field like '%_xy_contrib' order by quest_id"
    rows = v1.execute(cq).fetchall()
    check(v0.execute(cq).fetchall() == [], "without contributions no contribution conflict is logged")
    check([(r[0], r[1]) for r in rows] == [(7, "C_xy_contrib"), (60, "T_xy_contrib")],
          "a wiki point over 100 yd from the contributed area on the same map is logged; near ones and other maps are not",
          [(r[0], r[1]) for r in rows])
    t60 = next((r for r in rows if r[0] == 60), None)
    yd = int(re.match(r"(\d+) yd", t60[4]).group(1)) if t60 and re.match(r"(\d+) yd", t60[4]) else 0
    check(t60 is not None and t60[2].startswith("1429:43.3,65.8") and t60[3] == "1429:60.0,40.0" and "T:60" in t60[4]
          and "3 players, confirmed" in t60[4] and 800 < yd < 900,
          "the conflict row holds the wiki point, the contributed area, the distance and who stands behind it", t60)
    keep = "select count(*) from wiki_db2_conflict where flavor='era' and field not like '%_xy_contrib'"
    check(v0.execute(keep).fetchone() == v1.execute(keep).fetchone(), "the other conflict rows are the same in both runs")
    w1 = sqlite3.connect(with_dir / "wiki.sqlite")
    stats = dict(w1.execute("select metric, value from gen_stats where flavor='era'"))
    check(stats.get("steps_contrib") == 7 and stats.get("contrib_conflicts") == 2, "the generator's statistics count the source",
          {k: v for k, v in stats.items() if "contrib" in k})
    for con in (v0, v1, w1):
        con.close()
    check("steps located 7" in log1 and "player contributions 7" in log1 and "'single': 2" in log1 and "'unknown map': 2" in log1,
          "the run reports what it used and what it left out")

    # --- the add-on reads the same keys ---
    got = addon_keys(tmp, with_dir / "Imported_Wiki_era.lua")
    if got is None:
        skip("luajit is not installed: the generated steps were not read back through the add-on")
    else:
        c = gw.Contributions(cdir, "era", gw.wikimaps.Atlas().sets["era"])
        bad = []
        for key, mid, pts, _q in got:
            want = c.tag(c.points(key, gw.CONTRIB_POINTS if key.startswith("C:") else 1)) if key in c.areas else None
            if not want or str(want[0]) != mid or want[1] != pts:
                bad.append((key, mid, pts, want))
        check(len(got) == 7 and not bad, "every contributed step, parsed by Core/Guide.lua and keyed by Core/Contribute.lua "
              "KeyFor, has the key, map and points of the areas it was given", bad or len(got))
    found = cov.scan(with_dir / "Imported_Wiki_era.lua", build=True)
    check(found["quest-contrib"] == {46: 1, 45: 2, 5805: 1, 52: 2, 6181: 1} and all(found["quest"][q] for q in found["quest-contrib"]),
          "tools/coverage.py counts those quests as located and their contributed steps", found["quest-contrib"])
    check((with_dir / "Imported_Spine_era.lua").exists() and (with_dir / "parts_era.json").exists(),
          "the spine and its sidecar were written into the temp folder too")


# ---------------------------------------------------------------------------------------------------------------------
def part3(tmp, sha):
    print("a contributed step through the quest-line generator (Retail tables, a synthetic wiki file)")
    d = gc.DB2 / "retail"
    need = ["QuestLine", "QuestLineXQuest", "QuestPOIBlob", "QuestPOIPoint"]
    if not all((d / f"{t}.csv").exists() for t in need):
        skip("tools/db2/retail/{" + ",".join(need) + "}.csv are missing: the quest-line generator was NOT run")
        return
    import csv
    rows = list(csv.DictReader((d / "QuestLineXQuest.csv").open(encoding="utf-8")))
    seen = Counter(r["QuestID"] for r in rows)
    first = {}
    for r in sorted(rows, key=lambda r: (int(r["QuestLineID"]), int(r["OrderIndex"] or 0))):
        first.setdefault(r["QuestLineID"], r["QuestID"])
    q = next(int(v) for v in first.values() if seen[v] == 1)       # the first quest of a line, in no other line
    hdr = ('-- Steps whose note says "(location: player contributions, ...)" take their map point from where players stood, '
           "not from the wiki: merged player contributions, wow-completionist-data contributions/areas/retail.json "
           f"(https://github.com/danielalanbates/wow-completionist-data, CC BY-SA 4.0), commit {sha} (see Guides/WIKI_DATA_LICENSE.md).")
    a = f"A Fixture quest|QID|{q}|M|41.5,62.0|Z|84; Stormwind City|N|From Foo. (location: player contributions, 2 players)|"
    c = (f"C Fixture quest|QID|{q}|QO|1|M|43.0,60.5;44.1,58.2|Z|84; Stormwind City|N|Do it. (location: player contributions, "
         "3 players, 2 areas)|")
    g = tmp / "ql"
    g.mkdir()
    (g / "Imported_Wiki_retail.lua").write_text("\n".join(["-- synthetic wiki file (test)", hdr, "local _, NS = ...", a, c]) + "\n",
                                                encoding="utf-8")
    keep = gc.GUIDES
    out = io.StringIO()
    try:
        gc.GUIDES = g
        with contextlib.redirect_stdout(out):
            gc.gen_questlines("retail")
    finally:
        gc.GUIDES = keep
    text = (g / gc.STORY_FILE.format(fl="retail")).read_text(encoding="utf-8")
    lines = text.splitlines()
    check(a in lines and c in lines, "the contributed accept and objective steps pass through unchanged, point, map and note",
          [ln for ln in lines if f"|QID|{q}|" in ln][:3])
    check(hdr in lines[:20] and gate("Guides/Imported_QuestLines_retail.lua", text) == [],
          "the quest-line file repeats the provenance line and passes the packager's gate")
    check(len(gate("Guides/Imported_QuestLines_retail.lua", text.replace(hdr + "\n", "", 1))) == 1, "... which fails it without the line")


def main():
    if not GIT:
        raise SystemExit("test_contrib_gen: git is needed (a scratch checkout stands in for the data repository)")
    tmp = Path(tempfile.mkdtemp(prefix="cr-test-contrib-", dir=TMPROOT))
    guides_before = sorted((p.name, p.stat().st_size, p.stat().st_mtime_ns) for p in gw.GUIDES.glob("Imported_*.lua"))
    try:
        cdir, sha = part1(tmp)
        if "--unit" in sys.argv:
            print("parts 2 and 3 (the generators) not run: --unit")
        else:
            part2(tmp, cdir, sha)
            part3(tmp, sha)
        print("the checkout")
        check(sorted((p.name, p.stat().st_size, p.stat().st_mtime_ns) for p in gw.GUIDES.glob("Imported_*.lua")) == guides_before,
              "no generated guide under CompletionRoute/Guides was created, changed or removed")
    finally:
        if "--keep" in sys.argv:
            print(f"kept {tmp}")
        else:
            shutil.rmtree(tmp, ignore_errors=True)
    print(f"test_contrib_gen: {'FAILED, ' + str(fails) + ' check(s)' if fails else 'passed'}" + (f" ({skipped} part(s) SKIPPED)" if skipped else ""))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
