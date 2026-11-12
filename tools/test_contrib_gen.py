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
Part 2 runs the generator for Classic Era into the temp folder (tools/wiki/gen_wiki_guides.py --out): with no
contributions, with the fixture, and with a broken areas file (the run goes on and writes what it writes without
contributions).  It needs the gitignored inputs (tools/wiki/wiki.sqlite, tools/wiki/cache, tools/db2) and is SKIPPED,
loudly, on a checkout without them.  Part 3 passes a contributed step through the quest-line generator (needs
tools/db2/retail; skipped the same way).  Part 4 is the key check on every step: it invents one area for every key
a Classic Era quest step can have (each with its own player count, so a note tells which key the generator looked
up), runs the generator on that, and reads every step back through Core/Guide.lua and Core/Contribute.lua KeyFor.
Part 5 is the gold and profession routes (tools/contrib_areas.py, used by tools/wiki/gen_gold.py and
tools/wiki/gen_professions.py): the add-on's step keys for steps with no quest ("G:<route>#<step key>") against the
Python copy on tricky synthetic lines, the rules on the fixture's G: keys, the provenance line and the packager; then
every step of every generated gold and profession file with an invented area for each key, read back through the
add-on (skipped without those files); then both generators for Classic Era into the temp folder, without and with the
fixture (skipped without their gitignored inputs; the run is stopped if it would ask the wiki for anything).
--unit runs parts 1 and 5a only.  --keys retail (or any clients, comma-separated) runs part 4 alone for those clients.
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
import contrib_areas as ca  # noqa: E402

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
local flavor = arg[2] or "era"
STUB_MAPS = dofile("tools/maps_" .. flavor .. ".lua")
dofile("tools/stubs.lua")
local TOC = { era = 11508, tbc = 20506, mop = 50504, retail = 121500, forever = 16001 }
GetBuildInfo = function() return "x", "0", "2026", TOC[flavor] end
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
            tostring(st.qid and st.qid[1]), "\t", tostring(ln:match("%(location: player contributions, (%d+) players?")), "\n")
    end
end
'''


def addon_keys(tmp, guide_file, fl="era"):
    """[(key, map, 'x,y;x,y', quest, players)] of the contributed steps of a guide file, as the add-on reads them, in
    file order; None without luajit"""
    lj = shutil.which("luajit")
    if not lj:
        return None
    script = tmp / "contrib_keys.lua"
    script.write_text(KEYS_LUA, encoding="utf-8")
    r = subprocess.run([lj, "-joff", str(script), str(guide_file), fl], cwd=ROOT, capture_output=True, text=True)
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
    check(dict(c.skipped) == {"single": 2, "unknown map": 2, "malformed": 1, "not a quest step": 10},
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
    good = {"map": 1429, "x": 50, "y": 50, "contributors": 2, "weight": 3, "confidence": "confirmed"}
    real = json.dumps({"flavor": "era", "areas": {"A:1": [good]}})
    unreadable = {
        "another client's file": json.dumps({"flavor": "retail", "areas": {"A:1": [good]}}).encode(),
        "broken JSON": b"{ not json", "an empty file": b"", "bytes that are not UTF-8": real.encode().replace(b"A:1", b"A:\xff"),
        "a list": b"[1, 2]", "null": b"null", "areas that are a list": b'{"flavor": "era", "areas": []}',
        "no flavor": json.dumps({"areas": {"A:1": [good]}}).encode(),
        "brackets nested 100,000 deep": b'{"flavor": "era", "areas": {"A:1": ' + b"[" * 100000 + b"]" * 100000 + b"}}",
    }
    wrong = []
    for name, raw in unreadable.items():
        (bad / "era.json").write_bytes(raw)
        try:
            u = gw.Contributions(tmp / "bad", "era", maps)
            if u.areas or not u.problem or u.commit is not None:
                wrong.append((name, u.areas, u.problem))
        except BaseException as e:      # SystemExit too: one bad public file must not stop the generator
            wrong.append((name, type(e).__name__, str(e)[:80]))
    check(not wrong, "an areas file that cannot be read (broken, empty, another client's, nested without end) is not used "
          "and does not stop the run; .problem says why", wrong)
    (bad / "era.json").write_bytes(b"\xef\xbb\xbf" + real.encode())
    u = gw.Contributions(tmp / "bad", "era", maps)
    check(u.problem is None and list(u.areas) == ["A:1"], "a file saved with a byte-order mark is read", (u.problem, u.areas))
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
    # hostile numbers and keys, written as raw JSON: none may raise, none may reach a guide
    huge = "9" * 400
    row = '{"map": %s, "x": %s, "y": %s, "contributors": %s, "weight": %s, "confidence": "%s"}'
    cases = {
        "A:10": row % (huge, 50, 50, 2, 3, "trusted"), "A:11": row % (1429, huge, 50, 2, 3, "trusted"),
        "A:12": row % (1429, 50, 50, huge, huge, "trusted"), "A:13": row % (1429, 50, 50, 2, "1e999", "trusted"),
        "A:14": row % (1429, "Infinity", 50, 2, 3, "trusted"), "A:15": row % (1429, 99.97, 50, 2, 3, "trusted"),
        "A:16": row % (1429, 50, 0.04, 2, 3, "trusted"), "A:17": row % (1429, 100, 50, 2, 3, "trusted"),
        "A:18": row % (1429, -3, 50, 2, 3, "trusted"), "A:19": row % (1429, 50, 50, 1, 3, "confirmed"),
        "A:20": row % (1429, 50, 50, 9, 3, "confirmed"), "A:21": row % (1429.5, 50, 50, 2, 3, "confirmed"),
        "A:22": row % (1429, 50, 50, 2, 3, "Trusted"), "A:23": row % (1429, 50, 50, 0, 3, "trusted"),
    }
    n_bad = len(cases)
    cases.update({"A:30": row % (947, 50, 50, 2, 3, "confirmed"), "A:31": row % (1415, 50, 50, 2, 3, "trusted"),
                  "A:40\\n": row % (1429, 50, 50, 2, 3, "confirmed"), "A:\\u0664\\u0661": row % (1429, 50, 50, 2, 3, "confirmed"),
                  "A:41|M|1.0,1.0|": row % (1429, 50, 50, 2, 3, "confirmed"), "a:42": row % (1429, 50, 50, 2, 3, "confirmed"),
                  "C:43": row % (1429, 50, 50, 2, 3, "confirmed"), "C:44:100": row % (1429, 50, 50, 2, 3, "confirmed"),
                  "A:50": row % (1429, 50, 50, 2, 3, "confirmed")})
    (bad / "era.json").write_text('{"flavor": "era", "areas": {' + ", ".join(f'"{k}": [{v}]' for k, v in cases.items()) + "}}",
                                  encoding="utf-8")
    try:
        h = gw.Contributions(tmp / "bad", "era", maps)
        got_h = (sorted(h.areas), dict(h.skipped), h.problem)
    except BaseException as e:
        got_h = (type(e).__name__, str(e)[:120])
    check(got_h == (["A:50"], {"malformed": n_bad, "continent or world map": 2, "not a quest step": 6}, None),
          "numbers too long for a float, infinities, positions that print as 0.0 or 100.0, 'confirmed' by one player, more "
          "players than weight, a continent or world map and keys that only look like a step key are dropped without an error",
          got_h)

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
        return None
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
        return base
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
        for key, mid, pts, _q, _n in got:
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

    # --- an areas file that cannot be read: the run goes on, says so, and writes what it writes without contributions ---
    broken = tmp / "broken" / "contributions"
    (broken / "areas").mkdir(parents=True)
    (broken / "areas" / "era.json").write_text('{"flavor": "era", "areas": {"A:46": [{"map": 1429, "x": 74.0', encoding="utf-8")
    try:
        log2 = run_generator(["era", "--contributions", str(broken), "--out", str(tmp / "brokenout")])
    except BaseException as e:
        log2 = None
        check(False, "a broken areas file does not stop the generator", f"{type(e).__name__}: {str(e)[:200]}")
    if log2 is not None:
        check(log2.count("WARNING: player contributions of era NOT USED") == 2, "a broken areas file: the run says so, per client and at the end")
        same = [n for n in ("Imported_Wiki_era.lua", "Imported_Spine_era.lua")
                if (tmp / "brokenout" / n).read_bytes() == (base_dir / n).read_bytes()]
        check(len(same) == 2, "... and the guide and the spine are byte-identical to the run without contributions", same)
    return base


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


# ---------------------------------------------------------------------------------------------------------------------
PLACE_NOTE = "(location: the wiki's "


def guides_of(text):
    """[[step lines]] per guide of a generated file and faction gate: a guide for both factions can hold a quest
    twice, once per faction (tools/wiki/gen_spine.py), and a player sees one of the two"""
    out, cur = [], None
    for ln in text.splitlines():
        if ln.startswith("R({"):
            cur = {}
            out.append(cur)
        elif cur is not None and re.match(r"^[ACT] ", ln):
            m = re.search(r"\|FACTION\|(\w+)\|", ln)
            cur.setdefault(m.group(1) if m else "", []).append(ln)
    return [g for by_faction in out for g in by_faction.values()]


def part4(tmp, fl, base=None):
    """the key check on every step.  One invented area for every key a quest step of this client can have, each with
    its own player count, so the count in a step's note tells which key the generator looked up for that step; the
    add-on must give the same step the same key."""
    print(f"every step of the {fl} guides: the generator's key against the add-on's (an invented area for every key)")
    need = [gw.WIKI, ROOT / "tools" / "wiki" / "cache" / "wiki_raw.sqlite", ROOT / "tools" / "db2" / fl / "QuestV2.csv"]
    if not all(p.exists() for p in need):
        skip(f"the generator's gitignored inputs are missing: the {fl} key check was NOT run")
        return
    if base is None:
        run_generator([fl, "--no-contributions", "--out", str(tmp / f"keys_base_{fl}")])
        base = (tmp / f"keys_base_{fl}" / f"Imported_Wiki_{fl}.lua").read_text(encoding="utf-8")
    b = step_lines(base)
    top = {}                                    # quest -> highest |QO| number of its steps
    for ln in b:
        m = re.search(r"\|QO\|(\d+)\|", ln)
        q = quest_of(ln)
        top[q] = max(top.get(q, 0), int(m.group(1)) if m else 0)
    maps = gw.wikimaps.Atlas().sets[fl]
    mid = next(i for i in sorted(maps.maps) if maps.maps[i]["type"] == 3 and maps.maps[i]["w"] and maps.maps[i]["h"])
    areas, by_n = {}, {}
    for q in sorted(top):
        for key in [f"A:{q}", f"T:{q}"] + [f"C:{q}:{o}" for o in range(0, min(top[q] + 2, 100))]:
            n = len(by_n) + 2                   # this key's player count: no other key has it
            x, y = 5 + (n % 900) / 10, 5 + ((n // 900) % 900) / 10
            by_n[n] = (key, gw.fmt_xy(x, y))
            areas[key] = [{"map": mid, "x": x, "y": y, "r": 0.5, "weight": n, "cells": 1, "contributors": n, "confidence": "confirmed"}]
    repo = tmp / f"keys_{fl}"
    (repo / "contributions" / "areas").mkdir(parents=True)
    (repo / "contributions" / "areas" / f"{fl}.json").write_text(json.dumps({"flavor": fl, "areas": areas}), encoding="utf-8")
    git(repo, "init", "-q")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "invented areas for every key")
    out_dir = tmp / f"keys_out_{fl}"
    run_generator([fl, "--contributions", str(repo / "contributions"), "--out", str(out_dir)])
    new_path = out_dir / f"Imported_Wiki_{fl}.lua"
    new = new_path.read_text(encoding="utf-8")
    n_lines = step_lines(new)
    got = addon_keys(tmp, new_path, fl)
    if got is None:
        skip("luajit is not installed: the generated steps were not read back through the add-on")
        return
    credited = [ln for ln in n_lines if NOTE in ln]
    wrong = []
    for ln, (key, zone, pts, _q, n) in zip(credited, got):
        want = by_n.get(int(n)) if n.isdigit() else None
        act = ln[0]
        if not want or want[0] != key or want[1] != pts or zone != str(mid) or key[0] != {"A": "A", "T": "T", "C": "C"}[act]:
            wrong.append((ln[:70], key, want))
    kinds = Counter(k[0][0] for k in got)
    check(len(got) == len(credited) and len(got) > 500 and not wrong,
          f"{len(got)} steps took a contributed point ({kinds['A']} accepts, {kinds['T']} turn-ins, {kinds['C']} objectives, "
          f"{sum(1 for k in got if k[0].endswith(':0') and k[0][0] == 'C')} of them without |QO|): for every one the add-on's key "
          "(Core/Contribute.lua KeyFor on the step parsed by Core/Guide.lua) is the key whose area the generator gave it, and "
          "the add-on reads that area's map and point", wrong[:5] or (len(got), len(credited)))
    check(len({k[0] for k in got if k[0][0] == "C"}) > 1 and any(k[0].split(":")[-1] not in ("0", "1") for k in got if k[0][0] == "C"),
          "objectives beyond the first were tested too")
    # no key twice in one guide (per faction): two steps a player sees in a guide never take the same area
    twice = 0
    for g in guides_of(new):
        ns = [m.group(1) for m in (re.search(r"\(location: player contributions, (\d+) players?", ln) for ln in g) if m]
        twice += len(ns) - len(set(ns))
    check(twice == 0, "no two steps of one guide took the same key's area", twice)
    # a point the wiki or the client's quest pin gave is never replaced, moved or re-credited.  (Lines are compared
    # without |PRE| and the faction gate: a quest whose guide changes, because its contributed steps now have a map,
    # is copied per faction or not by tools/wiki/gen_spine.py, with the same steps.)
    strip = re.compile(r"\|PRE\|[\d;]+(?=\|)|\|FACTION\|(?:Alliance|Horde)(?=\|)")
    own = {strip.sub("", ln) for ln in b if "|M|" in ln and PLACE_NOTE not in ln}
    kept = {strip.sub("", ln) for ln in n_lines if NOTE not in ln}
    lost = sorted(own - kept)

    def ident(lines):
        return {(ln[0], quest_of(ln), (re.search(r"\|QO\|(\d+)\|", ln) or [None, "0"])[1]) for ln in lines}
    check(len(own) > 500 and not lost and ident(b) == ident(n_lines),
          f"all {len(own)} different steps with a wiki point or a quest pin are unchanged although every one of them had a "
          "contributed area; no quest step was added or removed", (len(lost), lost[:3], len(ident(b) ^ ident(n_lines))))
    # what is left without a point: only objective steps the add-on cannot tell apart (several without |QO| in a quest)
    odd = []
    for g in guides_of(new):
        untagged = Counter(quest_of(ln) for ln in g if ln.startswith("C ") and "|QO|" not in ln)
        for ln in g:
            if "|M|" in ln:
                continue
            if not (ln.startswith("C ") and "|QO|" not in ln and untagged[quest_of(ln)] > 1):
                odd.append(ln[:80])
    check(not odd, "with an area for every key, the only steps left without a point are objective steps without |QO| that "
          "share the add-on's key 0 with another step of their quest", (len(odd), odd[:3]))
    check(not any(NOTE in ln for g in guides_of(new) for ln in g
                  if ln.startswith("C ") and "|QO|" not in ln
                  and sum(1 for o in g if o.startswith("C ") and "|QO|" not in o and quest_of(o) == quest_of(ln)) > 1),
          "... and none of those took an area")
    check(pr.CONTRIB_HEADER.search(new[:4000]) is not None and gate(f"Guides/Imported_Wiki_{fl}.lua", new) == [],
          "the packager's gate passes that file (its header names the commit of the scratch checkout)")


# ---------------------------------------------------------------------------------------------------------------------
# Part 5: the gold and profession routes (tools/contrib_areas.py)
ROUTE_KEYS_LUA = r"""
package.path = "./?.lua;" .. package.path
local ADDON, NS = "CompletionRoute", {}
local file, flavor = arg[1], arg[2]
STUB_MAPS = dofile("tools/maps_" .. flavor .. ".lua")
dofile("tools/stubs.lua")
local TOC = { era = 11508, tbc = 20506, mop = 50504, retail = 121500, forever = 16001 }
GetBuildInfo = function() return "x", "0", "2026", TOC[flavor] end
local function load(path) assert(loadfile("CompletionRoute/" .. path))(ADDON, NS) end
for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", "Data/ZoneAliases.lua",
    "Core/Contribute.lua" }) do load(f) end
-- Forever: the map fix the add-on applies to a route written on Era maps (a Forever-native route, forever=true, is not moved)
if flavor == "forever" then load("Data/MapFix_forever.lua") end
NS.Print, NS.Debug = function() end, function() end
assert(loadfile(file))(ADDON, NS)
for _, id in ipairs(NS.Guide.list) do
    for _, s in ipairs(NS.Guide.Steps(id) or {}) do
        local pts = {}
        for _, c in ipairs(s.coords or {}) do pts[#pts + 1] = ("%.1f,%.1f"):format(c.x * 100, c.y * 100) end
        io.write(id, "\t", s.index, "\t", tostring(NS.Contribute.KeyFor(s)), "\t", tostring(s.zone), "\t",
            table.concat(pts, ";"), "\t", tostring((s.note or ""):match("%(location: player contributions, (%d+) players?")),
            "\n")
    end
end
"""


def route_steps(tmp, guide_file, fl):
    """[(route id, step index, key, map, 'x,y;x,y', players or 'nil')] of every step of a route file, as the add-on
    reads it (Core/Guide.lua G.Steps, Core/Contribute.lua KeyFor); None without luajit"""
    lj = shutil.which("luajit")
    if not lj:
        return None
    script = tmp / "route_keys.lua"
    script.write_text(ROUTE_KEYS_LUA, encoding="utf-8")
    r = subprocess.run([lj, "-joff", str(script), str(guide_file), fl], cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit("route_keys.lua failed: " + r.stderr[-600:])
    return [tuple(ln.split("\t")) for ln in r.stdout.splitlines() if ln]


def route_guides(text):
    """[(route id, [text lines])] of a generated gold or profession file, in file order; FOREVER_NATIVE gets the ids of
    the routes that say forever=true"""
    out, cur = [], None
    for ln in text.splitlines():
        m = re.match(r'^R\(\{ id="([^"]+)"', ln)
        if m:
            if "forever=true" in ln.split("text=[==[", 1)[0]:
                FOREVER_NATIVE.add(m.group(1))
            cur = (m.group(1), [])
            out.append(cur)
            rest = ln.split("text=[==[", 1)
            if len(rest) == 2 and rest[1]:
                cur[1].append(rest[1])
        elif cur is not None:
            if ln.startswith("]==]"):
                cur = None
            else:
                cur[1].append(ln)
    return out


FOREVER_NATIVE = set()


def route_file(guides, header=()):
    """a route file the add-on loads: the guard, then one R({ ... }) per (route id, lines); a route the generated file
    marks forever=true keeps the mark (the add-on then does not move its points with the Forever map fix)"""
    out = ["-- route file written by tools/test_contrib_gen.py"] + list(header) + ["local _, NS = ...", "local R = NS.Guide.Register"]
    for gid, lines in guides:
        fv = "forever=true, " if gid in FOREVER_NATIVE else ""
        out.append(f'R({{ id="{gid}", name="{gid}", type="Gold", {fv}source="CompletionRoute", text=[==[')
        out.extend(lines)
        out.append("]==] })")
    return "\n".join(out) + "\n"


def areas_file(folder, fl, areas):
    (folder / "areas").mkdir(parents=True, exist_ok=True)
    (folder / "areas" / f"{fl}.json").write_text(json.dumps({"flavor": fl, "areas": areas}), encoding="utf-8")
    return folder


def area(m, x, y, n, w=None, conf="confirmed"):
    return {"map": m, "x": x, "y": y, "r": 0.4, "weight": w or n * 2, "cells": 1, "contributors": n, "confidence": conf}


# tricky step lines for the key check: every part of Core/Guide.lua StepBase and ParseLine that a key depends on
KEY_LINES = [
    "N Get a Fishing Pole|N|Sold by general goods vendors.|",
    "N Get a Fishing Pole|N|Same words again: the second one is #2.|",
    "N  get A fishing-pole!!|N|Case and punctuation fold away: a third #n of the same key.|",
    "M Dish at 48.1, 42.9 (Done?)|SKILL|Cooking;75;2545|SPELL|4242|COUNT|3|",
    "M Dish at 48.1, 42.9 (Done?)|SKILL|cooking ; 75 ; |SPELL|4242|",
    "= Train Sous-Chef’s Café Éclair|RECIPE|1234|ALT|1429,47.5,62.3,Lee Brown|",
    "C Explore the Ruins|ACH|6;2050|N|An achievement criterion.|",
    "C Explore the Ruins|ACH|6|N|The achievement itself.|",
    "N Go on a mission|MISSION|123|",
    "B Mild Spices|L|2678 20|COUNT|20|N|Bought.|",
    "P Take the portal|N|An alias for a note step.|",
    "s Speak with Bob|N|Another alias.|",
    "d Die on purpose|",
    "R Line one\\nline two|Z|1429; Elwynn Forest|",
    "N Odd tag|XYZ|value|N|An unknown tag with a value.|",
    "N Odd tag|XYZ|",
    "N Odd tag|XYZ|a$b",
    "N Flags|O|S|NC|FIXED|N|Flags take no value.|",
    "N |N|A step with no title.|",
    "U Use the item|U|16072|RECIPE|3413|",
    "A Nat Pagle, Angler Extreme|QID|6607|N|A quest step: keyed by the quest.|",
    "C Nat Pagle, Angler Extreme|QID|6607|QO|2|N|Objective 2.|",
    "C Nat Pagle, Angler Extreme|QID|6607|N|No QO: objective 0.|",
    "T Nat Pagle, Angler Extreme|QID|6607|",
    ";a comment",
    "-- another comment",
    "",
    "Q not a step|N|An unknown action.|",
    "  N Leading spaces and a trailing tab|N|x|\t",
]


def part5_unit(tmp, cdir, sha):
    print("gold and profession routes: step keys, the rules, the provenance line (tools/contrib_areas.py)")
    # --- keys: the Python copy against the add-on, on synthetic lines ---
    gid = "gold:era:test:keys"
    want = [(gid, k) for _, _, k in ca.step_keys(gid, KEY_LINES)]
    f = tmp / "route_keys_synthetic.lua"
    f.write_text(route_file([(gid, KEY_LINES)]), encoding="utf-8")
    got = route_steps(tmp, f, "era")
    if got is None:
        skip("luajit is not installed: the route step keys were not compared with the add-on")
    else:
        check([(g[0], g[2]) for g in got] == want and len(want) == 25,
              "the step key of every kind of route line is the add-on's own (Core/Guide.lua StepBase + AssignKeys, "
              "Core/Contribute.lua KeyFor): titles folded, written coordinates dropped, UTF-8, aliases, achievement, recipe, "
              "skill and mission ids, repeats, unknown tags, flags, quest steps", [(a, b) for a, b in zip(got, want) if (a[0], a[2]) != b][:4] or len(want))
    keys = [k for _, k in want]
    check(keys[1] == keys[0] + "#2" and keys[2] == keys[0] + "#3" and keys[20:24] == ["A:6607", "C:6607:2", "C:6607:0", "T:6607"],
          "repeats are numbered #2, #3; quest steps keep the quest keys", keys[:3] + keys[20:24])
    check(all(ca.GUIDE_KEY.fullmatch(k) for k in keys if k.startswith("G:")) and not ca.GUIDE_KEY.fullmatch("G:x#h:1a2b3c"),
          "every G: key the add-on makes fits the key pattern the reader accepts")

    # --- the reader on the fixture ---
    maps = gw.wikimaps.Atlas().sets["era"]
    a = ca.Areas(FIXTURE, "era", maps)
    g_keys = sorted(k for k in a.areas if k.startswith("G:"))
    check(g_keys == ["G:gold:era:fish:1448:23#N~eohyak8l5", "G:prof:era:Cooking:1:Alliance#M~ccphbexgm",
                     "G:prof:era:Fishing:1:Alliance#=~j30rr3glb", "G:prof:era:Fishing:1:Alliance#N~b0p3fig8g",
                     "G:prof:era:Fishing:1:Alliance#R~bisrkzq54", "G:prof:era:Fishing:1:Horde#R~a5g7q7wci"],
          "the routes' reader keeps the fixture's G: keys of the add-on's form", g_keys)
    check(dict(a.skipped) == {"single": 3, "unknown map": 2, "malformed": 1, "not a step key": 2, "continent or world map": 1}
          and "A:46" in a.areas,
          "... and the quest keys; 'single' areas, unknown maps, a continent map and keys of another form are counted and "
          "not used", dict(a.skipped))
    check([(x["map"], x["w"]) for x in a.areas["G:prof:era:Fishing:1:Horde#R~a5g7q7wci"]] == [(1411, 3.0)],
          "an area on a continent map (Kalimdor, 1414) is skipped though it is the heaviest of its key",
          a.areas["G:prof:era:Fishing:1:Horde#R~a5g7q7wci"])
    check([x["w"] for x in a.areas["G:prof:era:Cooking:1:Alliance#M~ccphbexgm"]] == [4.0],
          "a step whose heaviest area is 'single' takes the next one")

    # --- the rule, on lines shaped like the generated routes ---
    fish_a = ["= Train Apprentice Fishing|RECIPE|7620|ALT|1429,47.5,62.3,Lee Brown;1426,35.5,40.3,Paxton Ganter|",
              "N Get a Fishing Pole|N|Sold by general goods and fishing supply vendors.|",
              "R Dun Morogh|Z|1426; Dun Morogh|N|Fishing locations: 100% catch at skill 25.|",
              "M Fish in Dun Morogh|SKILL|Fishing;75|Z|1426; Dun Morogh|N|Catches here: Raw Brilliant Smallfish.|"]
    fish_h = ["R Durotar|Z|1411; Durotar|N|Fishing locations: 100% catch at skill 25.|"]
    cook = ["M Charred Wolf Meat|SKILL|Cooking;63|SPELL|2538|COUNT|68|N|About 68 crafts (estimated from the skill colours).|"]
    gold = ["R Travel to Felwood|Z|1448; Felwood|N|Skill 300 or better keeps the catch from being mostly junk here.|",
            "N Fish any open water or pool in the zone|Z|1448; Felwood|N|Likely catches: Raw Nightfin Snapper.|"]
    out_a = a.apply("prof:era:Fishing:1:Alliance", fish_a)
    check(out_a[0] == fish_a[0], "a step with its own points (ALT) is never changed, though its key has an area")
    check(out_a[1] == "N Get a Fishing Pole|M|63.1,75.4|Z|1453; Stormwind City|N|Sold by general goods and fishing supply "
          "vendors. (location: player contributions, 2 players)|", "a step with no point takes the area, the note says so", out_a[1])
    check(out_a[2:] == fish_a[2:] and a.outside == 1, "a step that names a zone keeps it when the area lies elsewhere (counted)",
          (out_a[2], a.outside))
    out_h = a.apply("prof:era:Fishing:1:Horde", fish_h)
    check(out_h == ["R Durotar|M|52.2,41.8|Z|1411; Durotar|N|Fishing locations: 100% catch at skill 25. (location: player "
                    "contributions, 1 player)|"], "... and takes an area that lies in it", out_h)
    out_c = a.apply("prof:era:Cooking:1:Alliance", cook)
    check(out_c[0].startswith("M Charred Wolf Meat|SKILL|Cooking;63|SPELL|2538|COUNT|68|M|42.2,64.6|Z|1429; Elwynn Forest|N|")
          and out_c[0].endswith(" (location: player contributions, 1 player)|"), "a make step takes its trusted area", out_c[0])
    out_g = a.apply("gold:era:fish:1448:23", gold)
    check(out_g[0] == gold[0] and out_g[1] == "N Fish any open water or pool in the zone|M|50.2,18.4|Z|1448; Felwood|N|Likely "
          "catches: Raw Nightfin Snapper. (location: player contributions, 2 players)|", "a gold route step takes its area", out_g)
    check(a.apply("prof:era:Fishing:1:Horde", fish_a) == fish_a and a.apply("prof:era:Cooking:2:Alliance", cook) == cook,
          "the same lines in another route have other keys: nothing changes")
    check(dict(a.used) == {"G": 4}, "four steps took a point", dict(a.used))
    none = ca.Areas(None, "era", maps)
    check(none.apply("prof:era:Fishing:1:Alliance", fish_a) == fish_a and ca.Areas(FIXTURE, "tbc", gw.wikimaps.Atlas().sets["tbc"]).areas == {},
          "no folder, or no areas file for the client: nothing changes")

    # --- quest keys in a route, a step with no note, the add-on reading it all back ---
    syn = areas_file(tmp / "routes_syn" / "contributions", "era", {
        "A:6607": [area(1429, 30.0, 40.0, 2)],
        "C:6607:2": [area(1429, 31.0, 41.0, 5, 20), area(1440, 50.0, 50.0, 6, 18), area(1429, 32.0, 42.0, 3, 9),
                     area(1429, 33.0, 43.0, 2, 6), area(1429, 34.0, 44.0, 2, 4)],
        "C:6610:0": [area(1429, 35.0, 45.0, 2)],
        "G:gold:era:test:syn#M~" + ca.step_base(ca.parse_step("M Fish in Somewhere|SKILL|Fishing;75|"))[2:]:
            [area(1429, 36.0, 46.0, 3)],
    })
    s = ca.Areas(syn, "era", maps)
    lines = ["A Nat Pagle, Angler Extreme|QID|6607|N|From Nat Pagle.|",
             "C Nat Pagle, Angler Extreme|QID|6607|QO|2|N|Misty Reed Mahi Mahi|",
             "C Clamlette Surprise|QID|6610|N|Giant Egg|", "C Clamlette Surprise|QID|6610|N|Zesty Clam Meat|",
             "M Fish in Somewhere|SKILL|Fishing;75|"]
    out = s.apply("gold:era:test:syn", lines)
    check(out[0] == "A Nat Pagle, Angler Extreme|QID|6607|M|30.0,40.0|Z|1429; Elwynn Forest|N|From Nat Pagle. (location: player "
          "contributions, 2 players)|", "a quest step in a route takes the quest key's area", out[0])
    check("|QO|2|M|31.0,41.0;32.0,42.0;33.0,43.0|Z|1429; Elwynn Forest|N|" in out[1] and out[1].endswith(", 5 players, 3 areas)|"),
          "an objective takes up to three areas, all on the heaviest one's map", out[1])
    check(out[2:4] == lines[2:4], "objective steps without QO that share the add-on's key 0 take nothing")
    check(out[4] == "M Fish in Somewhere|SKILL|Fishing;75|M|36.0,46.0|Z|1429; Elwynn Forest|N|(location: player contributions, "
          "3 players)|", "a step with no note gets one", out[4])
    f2 = tmp / "routes_syn.lua"
    f2.write_text(route_file([("gold:era:test:syn", out)]), encoding="utf-8")
    got = route_steps(tmp, f2, "era")
    if got is not None:
        rows = [(g[2], g[3], g[4], g[5]) for g in got]
        check(rows == [("A:6607", "1429", "30.0,40.0", "2"), ("C:6607:2", "1429", "31.0,41.0;32.0,42.0;33.0,43.0", "5"),
                       ("C:6610:0", "1429", "", "nil"), ("C:6610:0", "1429", "", "nil"),
                       (list(s.areas)[-1], "1429", "36.0,46.0", "3")],
              "the add-on reads each changed step back with its key, map, points and credit (the two steps left alone "
              "keep the zone they inherit from the step before)", rows)

    # --- the provenance line and the packager ---
    c2 = ca.Areas(cdir, "era", maps)
    hdr = c2.header()
    check(c2.commit == sha and f"commit {sha}" in hdr and "wow-completionist-data" in hdr and "CC BY-SA 4.0" in hdr,
          "the routes' header line names the data repository, its licence and the commit", hdr)
    text = route_file([("prof:era:Fishing:1:Alliance", out_a)], [hdr])
    check(gate("Guides/Imported_Professions_era.lua", text) == [] and gate("Guides/Imported_Gold_era.lua", text) == [],
          "the packager passes a route file with a contributed step under that line")
    check(len(gate("Guides/Imported_Gold_era.lua", route_file([("x", out_a)]))) == 1
          and len(gate("Guides/Imported_Gold_era.lua", route_file([("x", out_a)], [a.header()]))) == 1,
          "... and fails it without the line, or under a folder with no known commit")

    af = cdir / "areas" / "era.json"
    af.write_text(af.read_text(encoding="utf-8") + "\n", encoding="utf-8")
    try:
        c3 = ca.Areas(cdir, "era", maps)
        text3 = route_file([("prof:era:Fishing:1:Alliance", out_a)], [c3.header()])
        check(c3.commit == sha + "-dirty" and len(gate("Guides/Imported_Professions_era.lua", text3)) == 1
              and len(gate("Guides/Imported_Gold_era.lua", text3)) == 1,
              "the routes' reader marks areas that differ from the commit -dirty, and the packager fails that header", c3.commit)
    finally:
        git(cdir.parent, "checkout", "-q", "--", "contributions/areas/era.json")
    check(ca.Areas(cdir, "era", maps).commit == sha, "... and the plain commit is back once the file matches it again")

    # --- the command line ---
    fl3 = ("era", "tbc", "mop", "retail", "forever")
    check(ca.parse_args(["era", "--no-contributions", "--out=x"], fl3) == (["era"], None, Path("x"))
          and ca.parse_args(["--contributions", str(FIXTURE)], fl3) == (list(fl3), FIXTURE, None),
          "--contributions DIR, --no-contributions and --out DIR are read")
    check(raises(ca.parse_args, ["--contributions"], fl3) and raises(ca.parse_args, ["--bogus"], fl3)
          and raises(ca.parse_args, ["--no-contributions", "--contributions", "x"], fl3) and raises(ca.parse_args, ["nowhere"], fl3)
          and raises(ca.parse_args, ["--contributions", str(tmp / "nowhere")], fl3), "bad option use stops the run")


def part5_files(tmp):
    """every step of every generated gold and profession file: an invented area for every key, the routes' rule
    applied, and every step read back through the add-on"""
    print("every step of the generated gold and profession routes: an invented area for every key, read back by the add-on")
    atlas = gw.wikimaps.Atlas()
    ran = 0
    for fl in gw.FLAVORS:
        maps = atlas.sets[fl]
        default = next(i for i in sorted(maps.maps) if maps.maps[i]["type"] == 3 and maps.maps[i]["w"] and maps.maps[i]["h"])
        for kind in ("Gold", "Professions"):
            path = gw.GUIDES / f"Imported_{kind}_{fl}.lua"
            if not path.exists():
                skip(f"no {path.name}: its routes were not checked")
                continue
            text = path.read_text(encoding="utf-8")
            guides = route_guides(text)
            areas, by_n, expect, own = {}, {}, 0, []
            for gid, lines in guides:
                keyed = ca.step_keys(gid, lines)
                untagged = Counter(k for _, st, k in keyed if k.startswith("C:") and "QO" not in st["tags"])
                for i, st, key in keyed:
                    if key in areas:
                        continue
                    zm = re.match(r"\s*([0-9]+)", (st["tags"].get("Z") or ("",))[0] or "")
                    z = int(zm.group(1)) if zm else None
                    # the step's own zone when a point can stand on it, else a zone inside it, else any zone
                    mid = z if z in maps.maps and maps.maps[z]["type"] in (3, 4, 5, 6) and maps.maps[z]["w"] else \
                        next((m for m in sorted(maps.maps) if maps.maps[m]["type"] == 3 and maps.maps[m]["w"]
                              and z is not None and maps.is_ancestor(z, m)), default)
                    n = len(by_n) + 2
                    x, y = 5 + (n % 900) / 10, 5 + ((n // 900) % 900) / 10
                    by_n[n] = (key, mid, gw.fmt_xy(x, y))
                    areas[key] = [area(mid, x, y, n, n)]
            for gid, lines in guides:
                keyed = ca.step_keys(gid, lines)
                untagged = Counter(k for _, st, k in keyed if k.startswith("C:") and "QO" not in st["tags"])
                for i, st, key in keyed:
                    if "M" in st["tags"] or "ALT" in st["tags"]:
                        own.append((gid, lines[i]))
                        continue
                    zm = re.match(r"\s*([0-9]+)", (st["tags"].get("Z") or ("",))[0] or "")
                    inside = not zm or by_n[areas[key][0]["contributors"]][1] == int(zm.group(1)) \
                        or maps.is_ancestor(int(zm.group(1)), by_n[areas[key][0]["contributors"]][1])
                    if inside and not (key.startswith("C:") and "QO" not in st["tags"] and untagged[key] > 1):
                        expect += 1
            d = areas_file(tmp / f"routes_{kind}_{fl}" / "contributions", fl, areas)
            a = ca.Areas(d, fl, maps)
            new = [(gid, a.apply(gid, lines)) for gid, lines in guides]
            took = sum(a.used.values())
            f = tmp / f"routes_{kind}_{fl}.lua"
            f.write_text(route_file(new), encoding="utf-8")
            got = route_steps(tmp, f, fl)
            if got is None:
                skip("luajit is not installed: the routes were not read back through the add-on")
                return
            ran += 1
            wrong = []
            credited = [g for g in got if g[5] != "nil"]
            for gid, idx, key, zone, pts, n in credited:
                w = by_n.get(int(n))
                if not w or w[0] != key or str(w[1]) != zone or w[2] != pts.split(";")[0]:
                    wrong.append((gid, idx, key, zone, pts, w))
            kept = {ln for g, lines in new for ln in lines if "|M|" in ln or "|ALT|" in ln}
            changed = [ln for _, ln in own if ln not in kept]
            check(not wrong and len(credited) == took == expect and not changed and len(got) == sum(len(ca.step_keys(g, l)) for g, l in guides),
                  f"{fl} {kind}: {took} of {len(got)} steps took an invented area; for each the add-on's key is the one whose area "
                  f"it was given and it reads that area's map and point{' (Forever: read with the map fix loaded; a route without forever=true would have its points moved)' if fl == 'forever' else ''}; "
                  f"the {len(own)} steps with points of their own are unchanged",
                  (wrong[:3], len(credited), took, expect, changed[:2]))
    if ran:
        print(f"  ({ran} route files checked)")


def run_quiet(fn, argv):
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            fn(argv)
    except BaseException:
        print(out.getvalue()[-3000:])
        raise
    return out.getvalue()


def part5_generators(tmp, cdir, sha):
    """gen_professions.py and gen_gold.py for Classic Era into the temp folder: without contributions the files are
    the build's, with the fixture four steps take a point and the header names the commit"""
    print("the gold and profession generators, Classic Era, without and with the fixture (into the temp folder)")
    need = [gw.WIKI, ROOT / "tools" / "wiki" / "cache" / "wiki_raw.sqlite", ROOT / "tools" / "db2" / "era" / "SkillLineAbility.csv",
            ROOT / "tools" / "wiki" / "cache" / "extra_pages"]
    missing = [str(p.relative_to(ROOT)) for p in need if not p.exists()]
    if missing:
        skip("the route generators' gitignored inputs are missing (" + ", ".join(missing[:3]) + "): they were NOT run")
        return
    import wiki_fetch
    import gen_professions as gp
    import gen_gold as gg

    def offline(params):
        raise SystemExit(f"test_contrib_gen: the generator wanted a wiki page that is not cached ({str(params)[:120]})")
    keep_get = wiki_fetch._get
    wiki_fetch._get = offline
    watched = [gw.GUIDES / f"Imported_{k}_era.lua" for k in ("Gold", "Professions")] + [gw.VERIF]
    before = state(watched)
    try:
        for name, mod in (("Professions", gp), ("Gold", gg)):
            base_dir, with_dir = tmp / f"gen_{name}_base", tmp / f"gen_{name}_with"
            log0 = run_quiet(mod.main, ["era", "--no-contributions", "--out", str(base_dir)])
            log1 = run_quiet(mod.main, ["era", "--contributions", str(cdir), "--out", str(with_dir)])
            base = (base_dir / f"Imported_{name}_era.lua").read_text(encoding="utf-8")
            new = (with_dir / f"Imported_{name}_era.lua").read_text(encoding="utf-8")
            check("none read" in log0 and str(cdir) in log1, f"{name}: the run says which contributions folder it read")
            build = gw.GUIDES / f"Imported_{name}_era.lua"
            if build.exists():
                date = re.compile(r"GENERATED \d{4}-\d\d-\d\d")
                check(date.sub("", base, 1) == date.sub("", build.read_text(encoding="utf-8"), 1),
                      f"{name}: without contributions the output is the build's Guides/Imported_{name}_era.lua (but for the "
                      "date); if the generator or its inputs changed since that file was made, regenerate it first")
            nb, nn = base.splitlines(), new.splitlines()
            hline = next((ln for ln in nn[:12] if "merged player contributions" in ln), "")
            diff = [(a, b) for a, b in zip([ln for ln in nb], [ln for ln in nn if ln != hline]) if a != b]
            want = 3 if name == "Professions" else 1
            check(len(nn) == len(nb) + 1 and len(diff) == want and all(NOTE in b and "|M|" in b for _, b in diff),
                  f"{name}: the header line is the only line added and {want} step(s) took a fixture area", (len(nn) - len(nb), diff[:2]))
            check(f"commit {sha}" in hline and gate(f"Guides/Imported_{name}_era.lua", new) == []
                  and len(gate(f"Guides/Imported_{name}_era.lua", new.replace(hline + "\n", "", 1))) == 1,
                  f"{name}: the header names the fixture's commit, and the packager passes the file only with that line", hline)
            if name == "Professions":
                check(any(b.startswith("N Get a Fishing Pole|M|63.1,75.4|Z|1453; Stormwind City|") for _, b in diff)
                      and any(b.startswith("R Durotar|M|52.2,41.8|Z|1411; Durotar|") for _, b in diff)
                      and any(b.startswith("M Charred Wolf Meat|") and "|M|42.2,64.6|Z|1429;" in b for _, b in diff)
                      and "steps took a point" in log1 and "1 areas outside" in log1,
                      "Professions: the pole, the Durotar and the Charred Wolf Meat steps took theirs; Dun Morogh kept its zone",
                      [b[:60] for _, b in diff])
            else:
                check(diff and diff[0][1].startswith("N Fish any open water or pool in the zone|M|50.2,18.4|Z|1448; Felwood|"),
                      "Gold: the Felwood fishing step took its area", diff[:1])
            check((with_dir / "verification.sqlite").exists(), f"{name}: the chart went into the temp folder too")
    finally:
        wiki_fetch._get = keep_get
    check(state(watched) == before, "the generator runs changed nothing in the checkout (route files, the chart)")


def main():
    if not GIT:
        raise SystemExit("test_contrib_gen: git is needed (a scratch checkout stands in for the data repository)")
    tmp = Path(tempfile.mkdtemp(prefix="cr-test-contrib-", dir=TMPROOT))
    guides_before = sorted((p.name, p.stat().st_size, p.stat().st_mtime_ns) for p in gw.GUIDES.glob("Imported_*.lua"))
    keys_for = next((a.partition("=")[2] or (sys.argv[i + 1] if i + 1 < len(sys.argv) else "")
                     for i, a in enumerate(sys.argv) if a == "--keys" or a.startswith("--keys=")), None)
    try:
        if keys_for is not None:
            for fl in keys_for.split(","):
                if fl not in gw.FLAVORS:
                    raise SystemExit(f"test_contrib_gen: --keys takes clients ({', '.join(gw.FLAVORS)}), not {fl!r}")
                part4(tmp, fl)
        else:
            cdir, sha = part1(tmp)
            part5_unit(tmp, cdir, sha)
            if "--unit" in sys.argv:
                print("parts 2 to 4 and 5b, 5c (the generators and the generated routes) not run: --unit")
            else:
                base = part2(tmp, cdir, sha)
                part3(tmp, sha)
                if base is not None:
                    part4(tmp, "era", base)
                part5_files(tmp)
                part5_generators(tmp, cdir, sha)
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
