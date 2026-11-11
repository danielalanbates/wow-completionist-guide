#!/usr/bin/env python3
# CompletionRoute :: tools/package_release.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Release packager with a data-provenance gate (docs/RELEASE.md).

    python3 tools/package_release.py                  dry run (the default): assemble the add-on in a temp folder, run
                                                      the gate, measure every zip layout, print the report. Writes nothing.
    python3 tools/package_release.py --write [--version 2.0.0-beta1]
                                                      also write dist/<version>/: the assembled add-on, provenance.json,
                                                      gate.txt and, only when the gate passes, the zip(s). Older
                                                      dist/<version> folders move to dist/archive/.

Options: --layout universal|per-client|both (default: universal, see docs/RELEASE.md for the measured sizes),
--data-root DIR (generated data taken from DIR first, same relative paths), --wow-dir DIR (WoW folder whose
WTF/Account names count as personal data), --personal-term TEXT (repeatable), --stage-dir DIR (keep the assembled
add-on there, pass or fail), --repo DIR, --out DIR, --tmp DIR.

What ships: the git-tracked code under CompletionRoute/ plus the locally generated data (gitignored Imported_*.lua and
RouteOrder_*.lua), limited to what the six TOCs load (plus their XML includes, Textures/ and licence files), plus
LICENSE.txt, ATTRIBUTION.md and README.md written here. RULES below gives every shippable path its category, licence,
source and generator; the generators were read to fill it in. WoW-Pro- and Questie-derived files are runtime or
install-time interop only: they are never packaged and their lines are removed from the packaged TOCs. The version is
stamped into the packaged TOCs only.

The gate fails the build when a packaged file has no provenance (no rule, or a "tracked" file git does not track), is
WoW-Pro- or Questie-derived (by rule or by content), says it must not be redistributed, mentions the commercial guide
product this project replaced (file names and contents, case-insensitive), holds personal data (e-mail addresses other
than help@batesai.org, home or volume paths, WoW account names), holds a secret or key pattern, would be packaged
through a symlink that is not a generated-data link into a checkout, when a packaged TOC or XML lists a file that is not
in the package, or when a licence notice is missing.

This tool never creates a git tag, never pushes and never creates a GitHub release: public releases wait for Daniel's
beta. Exit code: 0 gate passed, 1 gate failed, 2 usage error.
"""
import argparse
import datetime
import fnmatch
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parent
ADDON = "CompletionRoute"
TEMPLATES = TOOLS / "release"
GIT = "/usr/bin/git" if os.path.exists("/usr/bin/git") else "git"
WOW_DIR = "/Volumes/x10/Video Games/Mac/World of Warcraft"      # same default as tools/install.sh
PERSONAL_TERMS_FILE = TOOLS / "release" / "personal_terms.local.txt"   # gitignored (*.local.*): one term per line
NEXT_VERSION = "2.0.0"      # the next public release (docs/FINISH_PLAN.md M8); dev builds get a -dev suffix

# client -> the TOC files it reads (Forever ships two identical TOCs, see tools/validate_toc.lua)
CLIENTS = {
    "retail": ("CompletionRoute.toc",),
    "mop": ("CompletionRoute_Mists.toc",),
    "tbc": ("CompletionRoute_TBC.toc",),
    "era": ("CompletionRoute_Vanilla.toc",),
    "forever": ("CompletionRoute_Forever.toc", "CompletionRoute_Camelot.toc"),
}
# Measured 2026-11-10 on the local data (docs/RELEASE.md): the universal zip is 6.1 MB (43 MB unpacked); per client
# era 0.6, tbc 0.7, mop 1.4, retail 4.1, forever 0.6 MB, 7.3 MB together. A client loads only the files its own TOC
# lists, so the other clients' data costs a Classic player about 40 MB of disk, not memory or load time.
DEFAULT_LAYOUT = "universal"
# shipped with every package although no TOC lists them
ALWAYS = ("Textures/*", "Guides/WIKI_DATA_LICENSE.md", "Libs/*/LICENSE*")

OWN = "PolyForm Noncommercial 1.0.0 + 10% commercial rider (LICENSE.txt); (c) 2026 Daniel Bates / Bates LLC, all rights reserved"
CC_BY_SA = "CC BY-SA 4.0, https://creativecommons.org/licenses/by-sa/4.0/ (attribution in ATTRIBUTION.md)"
BLIZZARD = "game facts from Blizzard Entertainment client data tables, exported by wago.tools; World of Warcraft (c) Blizzard Entertainment"

SHIPPABLE = ("own-code", "own-data", "own-doc", "wiki-cc-by-sa", "blizzard-client-data", "third-party-library")
INTEROP = ("interop-wowpro", "interop-questie")
# categories whose content is scanned for WoW-Pro / Questie material (code and docs may name them: interop, notices)
DATA_CATEGORIES = ("own-data", "wiki-cc-by-sa", "blizzard-client-data")


@dataclass(frozen=True)
class Rule:
    pattern: str        # path inside CompletionRoute/, "/"-separated; "*" never crosses a "/"
    category: str
    licence: str
    source: str
    generator: str
    origin: str         # tracked (in git) | generated (gitignored, built locally) | packager (written here)
    why: str = ""       # interop rules: why the file never ships


R = Rule
# First match wins. Interop rules come first. Each "generator" and "source" was read from the generator in tools/.
RULES = (
    # ---- runtime / install-time interop: never shipped, TOC lines stripped from the packaged copy -----------------
    R("Guides/Imported_WoWPro_*.lua", "interop-wowpro", "WoW-Pro guides: CC BY-NC-ND", "guide text exported from the "
      "WoW-Pro add-on installed on this machine (file header: do not redistribute)", "local export (script retired)",
      "generated", "WoW-Pro-derived. Players who install WoW-Pro get its guides at runtime through Adapters/WoWPro.lua"),
    R("Guides/Imported_Quests_*_gaps.lua", "interop-questie", "Questie: GPL-3.0", "Imported_Quests_<flavor>.lua minus "
      "the quests the wiki covers: Questie on Classic clients, Blizzard quest POI plus Questie giver points, names and "
      "level gates on retail", "tools/wiki/gen_wiki_guides.py", "generated",
      "Questie-derived; built at install time on Daniel's machine only"),
    R("Guides/Imported_Quests_*.lua", "interop-questie", "Questie: GPL-3.0", "generator input: Classic from a local "
      "Questie checkout (tools/gen_quest_guides.lua), retail from Blizzard quest POI plus tools/db2/questie_index.tsv "
      "(tools/gen_quest_guides_retail.py)", "tools/gen_quest_guides.lua, tools/gen_quest_guides_retail.py", "generated",
      "Questie-derived generator input; no TOC loads it"),
    R("Guides/Imported_Storylines_*.lua", "interop-questie", "Questie: GPL-3.0 (mixed with Blizzard data)",
      "QuestLine order from Blizzard tables, but the step lines are copied from Imported_Quests_retail.lua (Questie giver "
      "points, names, faction and level gates) and bare quests take their names from tools/db2/questie_index.tsv",
      "tools/gen_completion_guides.py (storylines)", "generated",
      "Questie-derived until gen_completion_guides.py builds storylines from Imported_Wiki_retail.lua and Blizzard data only"),
    R("Data/Imported_Entrances.lua", "interop-questie", "Questie: GPL-3.0", "dungeon entrances from Questie's "
      "Database/Zones/data/dungeons.lua", "tools/gen_entrances.py", "generated",
      "Questie-derived; Core/Instances.lua falls back to doors it learns and the retail encounter journal"),
    # ---- Warcraft Wiki data (CC BY-SA 4.0) --------------------------------------------------------------------------
    R("Guides/Imported_Wiki_*.lua", "wiki-cc-by-sa", CC_BY_SA, "Warcraft Wiki quest pages; which quests a client has: "
      "Blizzard QuestV2 table (facts). Built with fallback points it carries '(location: Questie data)' lines, which "
      "fail the gate: ship the --no-fallback build", "tools/wiki/gen_wiki_guides.py (zone split and order: "
      "tools/wiki/gen_spine.py)", "generated"),
    R("Guides/Imported_Spine_*.lua", "wiki-cc-by-sa", CC_BY_SA, "the wiki zone guides chained by level band and the "
      "wiki's quest chains (retail: also Blizzard QuestLine/Campaign order, facts)", "tools/wiki/gen_spine.py", "generated"),
    R("Guides/Imported_Gold_*.lua", "wiki-cc-by-sa", CC_BY_SA, "Warcraft Wiki herb, ore, fishing, NPC, quest and "
      "instance pages (points the wiki file credits to Questie are dropped); Blizzard tables for facts",
      "tools/wiki/gen_gold.py", "generated"),
    R("Guides/Imported_Professions_*.lua", "wiki-cc-by-sa", CC_BY_SA, "Warcraft Wiki trainer, recipe, reagent and "
      "fishing pages; recipe membership, skill levels, reagents and dig sites from Blizzard tables (facts)",
      "tools/wiki/gen_professions.py", "generated"),
    R("Guides/Imported_Achievements_*.lua", "wiki-cc-by-sa", CC_BY_SA, "Blizzard Achievement/Criteria/Map tables; "
      "criterion points from Imported_Wiki_<flavor>.lua (rows credited to Questie skipped) and wiki NPC pages",
      "tools/gen_completion_guides.py (achievements)", "generated"),
    # ---- Blizzard client data -------------------------------------------------------------------------------------
    R("Guides/Imported_Missions_*.lua", "blizzard-client-data", BLIZZARD, "Blizzard GarrMission table",
      "tools/gen_completion_guides.py (missions)", "generated"),
    R("Data/Taxi_*.lua", "blizzard-client-data", BLIZZARD, "Blizzard TaxiNodes, TaxiPath and TaxiPathNode tables",
      "tools/gen_taxi.py", "tracked"),
    R("Data/MapFix_forever.lua", "blizzard-client-data", BLIZZARD, "Blizzard UiMapAssignment table (era and Forever)",
      "tools/gen_mapfix_forever.py", "tracked"),
    R("Data/ZoneAliases.lua", "blizzard-client-data", BLIZZARD, "Blizzard UiMap ids; English names edited by hand",
      "tools/gen_maps.py + hand edits", "tracked"),
    # ---- own data -------------------------------------------------------------------------------------------------
    R("Data/RouteOrder_*.lua", "own-data", OWN, "baked step orders computed from the addon's own travel graph",
      "tools/optimize_routes.py (costs: tools/cost_matrix.lua)", "generated"),
    R("Data/Access.lua", "own-data", OWN, "hand-authored access chains (quest ids, NPCs, coordinates)", "hand-authored", "tracked"),
    R("Data/Transit.lua", "own-data", OWN, "hand-authored boats, zeppelins, trams and portals", "hand-authored", "tracked"),
    R("Data/Inns.lua", "own-data", OWN, "hand-authored innkeeper seed list", "hand-authored", "tracked"),
    R("Data/Farm_routes.lua", "own-data", OWN, "hand-authored coarse farm rings", "hand-authored", "tracked"),
    R("Data/Roads_*.lua", "own-data", OWN, "roads authored from the zone maps or traced in game",
      "hand-authored; tools/roads_from_trace.py, tools/trace_roads.py", "tracked"),
    R("Guides/Leveling/*.lua", "own-data", "CC BY-SA 4.0 (file header); CompletionRoute contributors",
      "hand-written community guides", "hand-authored", "tracked"),
    R("Textures/*.tga", "own-data", OWN, "drawn by script", "tools/gen_textures.py", "tracked"),
    R("Guides/WIKI_DATA_LICENSE.md", "own-doc", OWN, "licence notice for the wiki data files", "hand-written", "tracked"),
    # ---- third-party libraries ------------------------------------------------------------------------------------
    R("Libs/LibStub/*", "third-party-library", "public domain (stated in LibStub.lua)", "LibStub, unmodified",
      "upstream", "tracked"),
    R("Libs/CallbackHandler-1.0/*", "third-party-library", "Ace3 licence, BSD-style (Libs/CallbackHandler-1.0/LICENSE.txt)",
      "CallbackHandler-1.0 minor 8 from the Ace3 project, unmodified", "upstream", "tracked"),
    R("Libs/HereBeDragons/*.lua", "third-party-library", "BSD, as declared by upstream (HereBeDragons.toc X-License: BSD; "
      "no licence text upstream)", "HereBeDragons-2.0 r35 (one CompletionRoute guard for WoW Forever) and "
      "HereBeDragons-Pins-2.0 r16, by Nevcairiel", "upstream", "tracked"),
    # ---- own code -------------------------------------------------------------------------------------------------
    R("*.toc", "own-code", OWN, "own", "hand-written (version stamped by tools/package_release.py)", "tracked"),
    R("Guides/Guides.xml", "own-code", OWN, "own", "hand-written", "tracked"),
    R("Core/*.lua", "own-code", OWN, "own", "hand-written", "tracked"),
    R("Routing/*.lua", "own-code", OWN, "own", "hand-written", "tracked"),
    R("UI/*.lua", "own-code", OWN, "own", "hand-written", "tracked"),
    R("Adapters/*.lua", "own-code", OWN, "own (runtime interop code; reads add-ons the player installed)", "hand-written", "tracked"),
)
PACKAGER = {
    "LICENSE.txt": R("LICENSE.txt", "own-doc", OWN, "the repository LICENSE", "tools/package_release.py", "packager"),
    "ATTRIBUTION.md": R("ATTRIBUTION.md", "own-doc", OWN, "tools/release/ATTRIBUTION.md plus the shipped file list",
                        "tools/package_release.py", "packager"),
    "README.md": R("README.md", "own-doc", OWN, "tools/release/README.md", "tools/package_release.py", "packager"),
}
# library folder -> (display name, licence, authors, changes, licence file that must ship or None)
LIBS = {
    "Libs/LibStub": ("LibStub", "public domain, as stated in LibStub.lua",
                     "Kaelten, Cladhaire, ckknight, Mikk, Ammo, Nevcairiel, joshborke", "unmodified", None),
    "Libs/CallbackHandler-1.0": ("CallbackHandler-1.0 (Ace3 project)", "Ace3 licence (BSD-style); full text in "
                                 "`Libs/CallbackHandler-1.0/LICENSE.txt`", "Ace3 Development Team", "unmodified",
                                 "Libs/CallbackHandler-1.0/LICENSE.txt"),
    "Libs/HereBeDragons": ("HereBeDragons-2.0 and HereBeDragons-Pins-2.0", "BSD, as declared by the upstream add-on "
                           "(`X-License: BSD`); upstream publishes no licence text", "Nevcairiel",
                           "HereBeDragons-2.0.lua has one CompletionRoute change: a WoW Forever detection guard", None),
}
LICENSE_MUST_SAY = ("PolyForm Noncommercial License 1.0.0", "ten percent (10%)", "All rights reserved",
                    "help@batesai.org", "https://batesai.org")

# The commercial guide product this project replaced is never named in this repository (project rule), so the name
# is stored shifted by one letter and decoded at runtime.
_DENY = ("azhps",)


def denylist():
    return tuple("".join(chr((ord(c) - 98) % 26 + 97) for c in w) for w in _DENY)


def redact(s):
    """report and manifest text never spell out the denylisted name, even when a planted file name holds it"""
    for w in denylist():
        s = re.sub(re.escape(w), "[product name]", s, flags=re.I)
    return s


ALLOWED_EMAILS = {"help@batesai.org"}
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")
LOCAL_PATH = re.compile(r"/Users/(?!Shared\b)[A-Za-z0-9._-]+|/home/[A-Za-z0-9._-]+|[A-Za-z]:[\\/]+Users[\\/]+[A-Za-z0-9._-]+"
                        r"|/Volumes/[A-Za-z0-9._-]+")
SECRETS = (
    ("private key block", re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----")),
    ("AWS access key id", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("GitHub token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,})")),
    ("sk- API key", re.compile(r"(?<![A-Za-z0-9])sk-(?:ant-|proj-|live-)?[A-Za-z0-9_-]{24,}")),
    ("Slack token", re.compile(r"\bxox[abposr]-[A-Za-z0-9-]{10,}")),
    ("Google API key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}")),
    ("Stripe key", re.compile(r"\b(?:sk|rk|pk)_live_[A-Za-z0-9]{16,}")),
    ("Telegram bot token", re.compile(r"\b\d{8,10}:AA[A-Za-z0-9_-]{33}\b")),
    ("JSON web token", re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}")),
    ("credential assignment", re.compile(r"(?i)\b(?:api[_-]?key|secret[_-]?key|client[_-]?secret|access[_-]?token|"
                                         r"auth[_-]?token|password|passwd)\b[\"']?\s*[:=]\s*[\"'][^\"'\s]{8,}[\"']")),
)
INTEROP_MARK = re.compile(r"(?i)questie|wow-?pro")
NO_REDISTRIBUTE = re.compile(r"(?i)do not (?:redistribute|commit)|not for redistribution|local use only")
TOC_FILE_LINE = re.compile(r"^\s*([^#\s][^\r\n]*?)\s*$")
XML_REF = re.compile(r"<(?:Script|Include)\s+[^>]*?file\s*=\s*\"([^\"]+)\"", re.I)
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+.][0-9A-Za-z.+-]+)?$")


def match(pattern, rel):
    pp, rp = pattern.split("/"), rel.split("/")
    return len(pp) == len(rp) and all(fnmatch.fnmatchcase(r, p) for r, p in zip(rp, pp))


def rule_for(rel):
    for r in RULES:
        if match(r.pattern, rel):
            return r
    return None


@dataclass
class Finding:
    rule: str           # gate rule id (docs/RELEASE.md)
    path: str
    detail: str

    def text(self):
        return redact(f"[{self.rule}] {self.path}: {self.detail}")


@dataclass
class Result:
    version: str = ""
    commit: str = ""
    dirty: bool = False
    failures: list = field(default_factory=list)
    warnings: list = field(default_factory=list)
    files: dict = field(default_factory=dict)          # rel -> manifest record
    clients: dict = field(default_factory=dict)        # client -> sorted rels
    excluded: list = field(default_factory=list)
    stripped: list = field(default_factory=list)
    not_packaged: list = field(default_factory=list)
    packages: list = field(default_factory=list)
    layout: str = DEFAULT_LAYOUT
    stage: Path = None
    commit_time: int = 0

    @property
    def ok(self):
        return not self.failures

    def fail(self, rule, path, detail):
        self.failures.append(Finding(rule, path, detail))


def git(repo, *args):
    p = subprocess.run([GIT, "-C", str(repo), *args], capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip() or f"git {' '.join(args)} failed")
    return p.stdout


def mask(s):
    return (s[:2] + "..." if len(s) > 2 else "...") + f" ({len(s)} chars)"


def lineno(text, pos):
    return text.count("\n", 0, pos) + 1


def hit_lines(text, rx):
    """sorted distinct line numbers of every match, counted in one pass"""
    out, line, last = [], 1, 0
    for m in rx.finditer(text):
        line += text.count("\n", last, m.start())
        last = m.start()
        if not out or out[-1] != line:
            out.append(line)
    return out


def snippet(text, pos, width=100):
    a = text.rfind("\n", 0, pos) + 1
    b = text.find("\n", pos)
    line = text[a:b if b >= 0 else len(text)].strip()
    return line if len(line) <= width else line[:width] + "..."


def symlink_component(addon, rel):
    """the first path component of addon/rel that is a symlink (relative), or None"""
    cur = addon
    parts = rel.split("/")
    for i, part in enumerate(parts):
        cur = cur / part
        if cur.is_symlink():
            return "/".join(parts[:i + 1])
    return None


def read_toc_refs(text):
    """file lines of a TOC, as (raw line, rel path with / separators)"""
    out = []
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = TOC_FILE_LINE.match(line)
        if m:
            out.append((line, m.group(1).replace("\\", "/")))
    return out


def stamp_toc(text, version, strip_rels):
    """the packaged TOC: interop lines removed, ## Version set (added after ## Title if missing)"""
    out, have = [], False
    for line in text.splitlines():
        if line.startswith("## Version:"):
            out.append(f"## Version: {version}")
            have = True
            continue
        refs = read_toc_refs(line)
        if refs and refs[0][1] in strip_rels:
            continue
        out.append(line)
    if not have:
        at = next((i + 1 for i, l in enumerate(out) if l.startswith("## Title:")), 0)
        out.insert(at, f"## Version: {version}")
    return "\n".join(out) + "\n"


def personal_terms(opts, res):
    terms, labels = [], []
    for t in opts.personal_term or []:
        terms.append(t)
        labels.append("--personal-term")
    if PERSONAL_TERMS_FILE.exists() and not opts.no_local_terms:
        for line in PERSONAL_TERMS_FILE.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                terms.append(line)
                labels.append(PERSONAL_TERMS_FILE.name)
    wow = Path(opts.wow_dir) if opts.wow_dir else None
    if wow and wow.is_dir():
        n = 0
        for acc in sorted(wow.glob("_*_/WTF/Account/*")):
            if acc.is_dir() and acc.name != "SavedVariables":
                terms.append(acc.name)
                labels.append("WoW account name (WTF/Account)")
                n += 1
        res.warnings.append(f"personal data: {n} WoW account name(s) found under the WoW folder's WTF/Account are checked")
    elif wow:
        res.warnings.append("personal data: WoW folder not found, account names were not checked "
                            "(pass --wow-dir, --personal-term or tools/release/personal_terms.local.txt)")
    out = []
    for t, label in zip(terms, labels):
        if len(t) < 4:
            res.warnings.append(f"personal data: a term from {label} is shorter than 4 characters and was skipped")
            continue
        out.append((re.compile(r"(?<![A-Za-z0-9])" + re.escape(t) + r"(?![A-Za-z0-9])", re.I), label))
    return out


class Scanner:
    def __init__(self, terms):
        self.deny = denylist()
        self.terms = terms

    def scan(self, rel, data, category, res):
        text = data.decode("utf-8", errors="replace") if not rel.endswith(".tga") else data.decode("latin-1")
        low = text.lower()
        for w in self.deny:
            if w in rel.lower():
                res.fail("commercial-reference", rel, "the file name names the commercial guide product this project replaced")
            pos = low.find(w)
            if pos >= 0:
                res.fail("commercial-reference", rel, f"names the commercial guide product this project replaced "
                         f"({low.count(w)} time(s), first at line {lineno(text, pos)})")
        if category in DATA_CATEGORIES:
            first = INTEROP_MARK.search(text)
            if first:
                lines = hit_lines(text, INTEROP_MARK)
                res.fail("interop-derived", rel, f"{len(lines)} line(s) credit Questie or WoW-Pro data, first at line "
                         f"{lines[0]}: {snippet(text, first.start())}")
        if category != "own-doc":
            m = NO_REDISTRIBUTE.search(text)
            if m:
                res.fail("not-redistributable", rel, f"says it must not be redistributed (line {lineno(text, m.start())}: "
                         f"{snippet(text, m.start())})")
        for m in EMAIL.finditer(text):
            if m.group(0).lower() not in ALLOWED_EMAILS:
                res.fail("personal-data", rel, f"e-mail address {mask(m.group(0))} at line {lineno(text, m.start())}")
                break
        m = LOCAL_PATH.search(text)
        if m:
            res.fail("personal-data", rel, f"local machine path {mask(m.group(0))} at line {lineno(text, m.start())}")
        for rx, label in self.terms:
            if rx.search(rel):
                res.fail("personal-data", rel, f"the file name holds a personal term from {label}")
            m = rx.search(text)
            if m:
                res.fail("personal-data", rel, f"personal term from {label} at line {lineno(text, m.start())}")
        for label, rx in SECRETS:
            m = rx.search(text)
            if m:
                res.fail("secret", rel, f"{label} pattern at line {lineno(text, m.start())}")


def render(template, values):
    text = (TEMPLATES / template).read_text(encoding="utf-8")
    for k, v in values.items():
        text = text.replace("@" + k + "@", v)
    left = re.findall(r"@[A-Z_]+@", text)
    if left:
        raise RuntimeError(f"{template}: unfilled placeholder(s) {left}")
    return text


def bullet(rels):
    return "\n".join(f"* `{r}`" for r in rels) if rels else "* (none in this package)"


def assemble(opts):
    """plan, stage and gate the add-on; returns a Result (stage folder filled, zips not yet built)"""
    res = Result()
    repo = Path(opts.repo).resolve()
    addon = repo / ADDON
    if not addon.is_dir():
        raise SystemExit(f"package_release: {addon} is not a folder")
    # ---- git: what is tracked, which commit -----------------------------------------------------------------------
    try:
        tracked = set(git(repo, "ls-files", "-z", "--", ADDON).split("\0")) - {""}
        tracked = {t[len(ADDON) + 1:] for t in tracked}
        res.commit = git(repo, "rev-parse", "HEAD").strip()
        commit_time = int(git(repo, "log", "-1", "--format=%ct").strip() or 0)
        status = git(repo, "status", "--porcelain", "--untracked-files=no", "--", ADDON, "LICENSE")
        res.dirty = bool(status.strip())
        common = Path(git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir").strip())
        main_checkout = common.parent if common.name == ".git" else None
    except RuntimeError as e:
        res.fail("no-provenance", ADDON, f"not a git checkout, so no file can be tied to a commit ({e})")
        tracked, commit_time, main_checkout = set(), 0, None
    if res.dirty:
        res.warnings.append("uncommitted changes to tracked files: provenance.json records sha256 per file, but the "
                            "commit alone does not reproduce this build")
    short = res.commit[:7] or "nogit"
    res.version = opts.version or f"{NEXT_VERSION}-dev.{short}" + ("-dirty" if res.dirty else "")
    if not VERSION_RE.match(res.version):
        raise SystemExit(f"package_release: version {res.version!r} is not like 2.0.0 or 2.0.0-beta1")
    allowed_roots = [addon.resolve()]
    if main_checkout:
        allowed_roots.append((main_checkout / ADDON).resolve())
    overlays = [Path(d).resolve() for d in (opts.data_root or [])]
    allowed_roots += overlays
    for o in overlays:
        if not o.is_dir():
            raise SystemExit(f"package_release: --data-root {o} is not a folder")
        for dirpath, _, filenames in os.walk(o):
            for name in filenames:
                rel = (Path(dirpath) / name).relative_to(o).as_posix()
                r = rule_for(rel)
                if name != ".DS_Store" and not (r and r.origin == "generated"):
                    res.fail("no-provenance", rel, f"a --data-root ({o.name}/) may only provide generated data; "
                             "tracked or unknown files there are never packaged")

    # ---- plan: what each client's TOCs load ----------------------------------------------------------------------
    all_files = []
    for dirpath, dirnames, filenames in os.walk(addon, followlinks=False):
        d = Path(dirpath)
        for name in filenames + [n for n in dirnames if (d / n).is_symlink()]:
            if name != ".DS_Store":
                all_files.append((d / name).relative_to(addon).as_posix())
    strip, toc_text = set(), {}
    per_client = {c: set() for c in CLIENTS}
    xml_seen = {}

    def source_of(rel):
        r = rule_for(rel)
        if r and r.origin == "generated":
            for o in overlays:
                if os.path.lexists(o / rel):
                    return o / rel
        return addon / rel

    def add_xml(rel, into):
        if rel in xml_seen:
            into.update(xml_seen[rel])
            return
        xml_seen[rel] = set()
        src = source_of(rel)
        if not src.is_file() or symlink_component(addon, rel):
            return
        base = rel.rsplit("/", 1)[0] + "/" if "/" in rel else ""
        for ref in XML_REF.findall(src.read_text(encoding="utf-8", errors="replace")):
            sub = os.path.normpath(base + ref.replace("\\", "/")).replace(os.sep, "/")
            xml_seen[rel].add(sub)
            if sub.lower().endswith(".xml"):
                add_xml(sub, xml_seen[rel])
        into.update(xml_seen[rel])

    for client, tocs in CLIENTS.items():
        for toc in tocs:
            per_client[client].add(toc)
            p = addon / toc
            if not p.is_file():
                res.fail("toc-missing-file", toc, f"the {client} TOC itself is missing")
                continue
            toc_text[toc] = p.read_text(encoding="utf-8", errors="replace")
            for line, rel in read_toc_refs(toc_text[toc]):
                r = rule_for(rel)
                if r and r.category in INTEROP:
                    strip.add(rel)
                    res.stripped.append({"toc": toc, "line": line.strip(), "why": r.why})
                    continue
                per_client[client].add(rel)
                if rel.lower().endswith(".xml"):
                    add_xml(rel, per_client[client])
        for f in all_files:
            if any(match(g, f) for g in ALWAYS):
                per_client[client].add(f)
    universal = set().union(*per_client.values())
    for f in sorted(set(all_files) - universal):
        r = rule_for(f)
        if r and r.category in INTEROP:
            res.excluded.append({"path": f, "category": r.category, "source": r.source, "why": r.why})
        else:
            res.not_packaged.append(f)

    # ---- stage ----------------------------------------------------------------------------------------------------
    stage = Path(opts.stage) / ADDON
    stage.mkdir(parents=True, exist_ok=True)
    res.stage = stage
    present = set()
    for rel in sorted(universal):
        r = rule_for(rel)
        src = source_of(rel)
        if not os.path.lexists(src):
            continue            # reported by the TOC check below
        present.add(rel)
        link = symlink_component(addon, rel) if src == addon / rel else (rel if src.is_symlink() else None)
        via = ""
        if link:
            target = src.resolve()
            inside = next((root for root in allowed_roots if target.is_relative_to(root)), None)
            same = inside is not None and target.relative_to(inside).as_posix() == rel
            if r and r.origin == "generated" and link == rel and target.is_file() and same:
                via = "symlink into a checkout"
            else:
                res.fail("symlink", rel, "would be packaged through a symlink (" + (
                    "a parent folder is a link" if link != rel else "only generated data may be a link to the same "
                    "path in a checkout or --data-root") + ")")
                continue
        if not src.is_file():
            res.fail("no-provenance", rel, "not a regular file")
            continue
        if r is None:
            res.fail("no-provenance", rel, "no rule in tools/package_release.py RULES says where this file comes from")
        elif r.category in INTEROP:
            res.fail("interop-derived", rel, f"{r.category}: {r.why}")
        elif r.origin == "tracked" and rel not in tracked:
            res.fail("no-provenance", rel, f"matches {r.pattern} ({r.category}), which must be tracked in git, but git "
                     "does not track it")
        data = src.read_bytes()
        if rel in toc_text:
            data = stamp_toc(toc_text[rel], res.version, strip).encode("utf-8")
        out = stage / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(data)
        res.files[rel] = {
            "path": f"{ADDON}/{rel}", "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
            "category": r.category if r else "unknown", "licence": r.licence if r else "", "source": r.source if r else "",
            "generator": r.generator if r else "", "origin": r.origin if r else "unknown",
            "via": via or ("--data-root" if src != addon / rel else ""),
        }

    # ---- files written by the packager ----------------------------------------------------------------------------
    lic = repo / "LICENSE"
    lic_text = lic.read_text(encoding="utf-8") if lic.is_file() else ""
    missing = [s for s in LICENSE_MUST_SAY if s not in lic_text]
    if missing:
        res.fail("missing-notice", "LICENSE.txt", "the repository LICENSE is missing or lacks: " + "; ".join(missing))
    by_cat = {}
    for rel, rec in res.files.items():
        by_cat.setdefault(rec["category"], []).append(rel)
    libs = []
    for d, (name, licence, authors, changes, lic_file) in LIBS.items():
        if any(rel.startswith(d + "/") for rel in res.files):
            libs.append(f"* **{name}** (`{d}/`) by {authors}. Licence: {licence}. Changes: {changes}.")
            if lic_file and lic_file not in res.files:
                res.fail("missing-notice", lic_file, f"{name} ships without its licence text")
    vals = {
        "VERSION": res.version,
        "WIKI_FILES": bullet(sorted(by_cat.get("wiki-cc-by-sa", []))),
        "CCBYSA_OWN_FILES": bullet(sorted(r for r in by_cat.get("own-data", []) if "CC BY-SA" in res.files[r]["licence"])),
        "BLIZZARD_FILES": bullet(sorted(by_cat.get("blizzard-client-data", []))),
        "LIBRARIES": "\n".join(libs) or "* (none)",
        "PACKAGE_NOTE": "One `CompletionRoute` folder serves every client: each client loads only its own TOC's files. "
                        "If you downloaded a per-client zip, it holds only that client's data.",
    }
    made = {"LICENSE.txt": lic_text, "ATTRIBUTION.md": render("ATTRIBUTION.md", vals), "README.md": render("README.md", vals)}
    for rel, text in made.items():
        data = text.encode("utf-8")
        (stage / rel).write_bytes(data)
        r = PACKAGER[rel]
        res.files[rel] = {"path": f"{ADDON}/{rel}", "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                          "category": r.category, "licence": r.licence, "source": r.source, "generator": r.generator,
                          "origin": r.origin, "via": ""}
        present.add(rel)
        for c in per_client:
            per_client[c].add(rel)

    # ---- gate: content of every staged file -----------------------------------------------------------------------
    scanner = Scanner(personal_terms(opts, res))
    for rel, rec in sorted(res.files.items()):
        scanner.scan(rel, (stage / rel).read_bytes(), rec["category"], res)

    # ---- gate: every TOC / XML line points at a file in that client's package -------------------------------------
    for client, rels in per_client.items():
        have = rels & present
        for toc in CLIENTS[client]:
            if toc not in toc_text:
                continue
            staged = (stage / toc).read_text(encoding="utf-8") if (stage / toc).is_file() else ""
            if f"## Version: {res.version}" not in staged:
                res.fail("toc-missing-file", toc, "packaged TOC is not stamped with the release version")
            for _, rel in read_toc_refs(staged):
                if rel not in have:
                    res.fail("toc-missing-file", toc, f"lists {rel}, which is not in the {client} package")
        for xml, refs in xml_seen.items():
            if xml in have:
                for rel in sorted(refs):
                    if rel not in have:
                        res.fail("toc-missing-file", xml, f"includes {rel}, which is not in the {client} package")
        res.clients[client] = sorted(r for r in have if r in res.files)     # zips hold only what was staged
    # one finding per (rule, path, detail): clients share TOCs and XML
    seen, uniq = set(), []
    for f in res.failures:
        k = (f.rule, f.path, f.detail)
        if k not in seen:
            seen.add(k)
            uniq.append(f)
    res.failures = uniq
    for rel, rec in res.files.items():
        rec["clients"] = [c for c in CLIENTS if rel in res.clients.get(c, ())]
    res.commit_time = commit_time
    return res


def write_zip(path, stage, rels, commit_time):
    ts = datetime.datetime.fromtimestamp(max(commit_time, 315532800), datetime.timezone.utc).timetuple()[:6]
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for rel in sorted(rels):
            zi = zipfile.ZipInfo(f"{ADDON}/{rel}", ts)
            zi.external_attr = 0o644 << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, (stage / rel).read_bytes(), compresslevel=9)
    data = path.read_bytes()
    return {"name": path.name, "files": len(rels), "bytes_unpacked": sum((stage / r).stat().st_size for r in rels),
            "bytes_zip": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def build_zips(res, folder, layouts):
    """every requested zip into folder; returns {package name: record}"""
    out = {}
    if "universal" in layouts:
        rels = sorted(set().union(*map(set, res.clients.values())))
        rec = write_zip(folder / f"{ADDON}-{res.version}.zip", res.stage, rels, res.commit_time)
        rec["client"] = "all"
        out[rec["name"]] = rec
    if "per-client" in layouts:
        for c, rels in res.clients.items():
            rec = write_zip(folder / f"{ADDON}-{res.version}-{c}.zip", res.stage, rels, res.commit_time)
            rec["client"] = c
            out[rec["name"]] = rec
    return out


def manifest(res):
    return {
        "format": 1,
        "product": "Completionist's Guide (CompletionRoute add-on)",
        "version": res.version, "commit": res.commit, "dirty": res.dirty,
        "built": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "layout": res.layout,
        "gate": {"result": "PASS" if res.ok else "FAIL",
                 "failures": [{"rule": f.rule, "path": redact(f.path), "detail": redact(f.detail)} for f in res.failures],
                 "warnings": res.warnings},
        "packages": res.packages,
        "files": [dict(res.files[k], path=redact(res.files[k]["path"])) for k in sorted(res.files)],
        "excluded": res.excluded,
        "toc_lines_stripped": res.stripped,
        "not_packaged": [redact(f) for f in res.not_packaged],
    }


def report(res, measured, dry, out=sys.stdout):
    p = lambda s="": print(s, file=out)  # noqa: E731
    p(f"Completionist's Guide release packager: {'DRY RUN, nothing written (--write builds dist/)' if dry else 'WRITE'}")
    p(f"version {res.version}, commit {res.commit[:12] or '-'}{' (uncommitted changes)' if res.dirty else ''}")
    cats = {}
    for rec in res.files.values():
        cats[rec["category"]] = cats.get(rec["category"], 0) + 1
    p(f"packaged {len(res.files)} files: " + ", ".join(f"{k} {v}" for k, v in sorted(cats.items())))
    if res.excluded:
        p(f"never shipped ({len(res.excluded)}): " + ", ".join(e["path"] for e in res.excluded))
    if res.stripped:
        p(f"TOC lines stripped from the packaged copy ({len(res.stripped)}): "
          + ", ".join(sorted({s["line"].replace(chr(92), '/') for s in res.stripped})))
    if res.not_packaged:
        p(f"not loaded by any TOC, not packaged ({len(res.not_packaged)}): " + redact(", ".join(res.not_packaged)))
    if measured:
        w = max(len(r["name"]) for r in measured)
        p("sizes (zip = deflate level 9):")
        p(f"  {'package':{w}} {'files':>6} {'unpacked MB':>12} {'zip MB':>8}")
        for rec in measured:
            p(f"  {rec['name']:{w}} {rec['files']:6d} {rec['bytes_unpacked'] / 1e6:12.2f} {rec['bytes_zip'] / 1e6:8.2f}")
        per = [r for r in measured if r["client"] != "all"]
        if per and len(per) < len(measured):
            p(f"  {'per-client zips together':{w}} {'':6} {sum(r['bytes_unpacked'] for r in per) / 1e6:12.2f} "
              f"{sum(r['bytes_zip'] for r in per) / 1e6:8.2f}")
    for w in res.warnings:
        p(f"note: {w}")
    if res.ok:
        p("GATE: PASS")
    else:
        p(f"GATE: FAIL ({len(res.failures)} problem(s))")
        for f in res.failures:
            p("  " + f.text())


def parse_args(argv):
    ap = argparse.ArgumentParser(description="Assemble the add-on and gate it on data provenance (docs/RELEASE.md).")
    ap.add_argument("--write", action="store_true", help="write dist/<version>/ (default: dry run, nothing written)")
    ap.add_argument("--version", help=f"release version for the TOCs and file names (default {NEXT_VERSION}-dev.<commit>)")
    ap.add_argument("--layout", choices=("universal", "per-client", "both"), default=DEFAULT_LAYOUT)
    ap.add_argument("--repo", default=str(ROOT), help="repository root (default: this checkout)")
    ap.add_argument("--out", help="output folder for --write (default <repo>/dist)")
    ap.add_argument("--tmp", help="parent folder for the temporary staging folder")
    ap.add_argument("--stage-dir", help="assemble into this new folder and keep it, even when the gate fails (for "
                    "inspection or for loading the packaged TOCs with tools/test_load_all.lua); never a release artifact")
    ap.add_argument("--data-root", action="append", help="folder with generated data at the same relative paths; wins over CompletionRoute/")
    ap.add_argument("--wow-dir", default=os.environ.get("WOW_DIR", WOW_DIR), help="WoW folder whose WTF/Account names are personal data")
    ap.add_argument("--personal-term", action="append", help="extra personal term the package must not contain (repeatable)")
    ap.add_argument("--no-local-terms", action="store_true", help=f"ignore {PERSONAL_TERMS_FILE.name}")
    ap.add_argument("--no-measure", action="store_true", help="skip building the zips of the other layout")
    return ap.parse_args(argv)


def write_dist(opts, res, man, measured, chosen, zdir):
    """dist/<version>/. A passing build gets the assembled add-on and its zip(s), and every other dist/<version>
    moves to dist/archive/ (one current build). A failing build gets only gate.txt and provenance.json and archives nothing."""
    dist = Path(opts.out).resolve() if opts.out else Path(opts.repo).resolve() / "dist"
    dest = dist / res.version
    dist.mkdir(parents=True, exist_ok=True)
    if res.ok:
        archive = dist / "archive"
        for old in sorted(dist.iterdir()):
            if old.is_dir() and old.name not in ("archive", res.version):
                archive.mkdir(exist_ok=True)
                target = archive / old.name
                if target.exists():
                    target = archive / f"{old.name}-{datetime.datetime.now().strftime('%Y%m%d%H%M%S')}"
                shutil.move(str(old), str(target))
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir()
    if res.ok:
        shutil.copytree(res.stage, dest / ADDON)
        for r in chosen:
            shutil.copy2(zdir / r["name"], dest / r["name"])
    (dest / "provenance.json").write_text(json.dumps(man, indent=1) + "\n", encoding="utf-8")
    with open(dest / "gate.txt", "w", encoding="utf-8") as fh:
        report(res, measured, False, fh)
    return dest


def run(argv=None, out=sys.stdout):
    """the whole build; returns (exit code, Result, manifest dict)"""
    opts = parse_args(argv)
    tmp = tempfile.mkdtemp(prefix="cr-release-", dir=opts.tmp)
    try:
        opts.stage = Path(tmp) / "stage"
        if opts.stage_dir:
            opts.stage = Path(opts.stage_dir).resolve()
            if opts.stage.exists() and any(opts.stage.iterdir()):
                raise SystemExit(f"package_release: --stage-dir {opts.stage} is not empty")
        res = assemble(opts)
        res.layout = opts.layout
        layouts = {"universal", "per-client"} if opts.layout == "both" else {opts.layout}
        measure = layouts if opts.no_measure else {"universal", "per-client"}
        zdir = Path(tmp) / "zips"
        zdir.mkdir()
        recs = build_zips(res, zdir, measure)
        chosen = [r for r in recs.values() if ("universal" if r["client"] == "all" else "per-client") in layouts]
        res.packages = chosen if res.ok else []
        man = manifest(res)
        measured = sorted(recs.values(), key=lambda r: r["name"])
        if opts.write:
            dest = write_dist(opts, res, man, measured, chosen, zdir)
        report(res, measured, not opts.write, out)
        if opts.write:
            print(f"wrote {dest}" + ("" if res.ok else " (gate.txt and provenance.json only: the gate failed)"), file=out)
        return (0 if res.ok else 1), res, man
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    try:
        code, _, _ = run(sys.argv[1:])
    except SystemExit as e:
        if isinstance(e.code, str):
            print(e.code, file=sys.stderr)
            return 2
        raise
    return code


if __name__ == "__main__":
    sys.exit(main())
