#!/usr/bin/env python3
# CompletionRoute :: tools/package_release.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Release packager with a data-provenance gate (docs/RELEASE.md).

    python3 tools/package_release.py                  dry run (the default): assemble the add-on in a temp folder, run
                                                      the gate, measure every zip layout, print the report. Writes
                                                      nothing (except the --db tables when --db is given).
    python3 tools/package_release.py --write [--version 2.0.0-beta1]
                                                      also write the build. A passing build becomes dist/<version>/
                                                      (the assembled add-on, its zip(s), provenance.json, gate.txt) and
                                                      every earlier build in dist/, the same version included, moves
                                                      to dist/archive/. A failing build writes only gate.txt and
                                                      provenance.json, to dist/failed/<version>-<time>/, and moves
                                                      nothing. Folders this packager did not write are never touched.

Options: --layout universal|per-client|both (default: universal, see docs/RELEASE.md for the measured sizes),
--data-root DIR (generated data taken from DIR first, same relative paths), --wow-dir DIR (WoW folder whose
WTF/Account account and character names count as personal data), --personal-term TEXT (repeatable), --stage-dir DIR
(keep the assembled add-on there, pass or fail), --allow-checkout-links (a git worktree whose generated files are
links into the main checkout: read through them), --db PATH (also write the data_provenance and release_gate tables
into that SQLite file), --repo DIR, --out DIR, --tmp DIR.

There is one build (2026-11-11): what the six TOCs list, what tools/install.sh installs, what the generators write and
what this packager packages are the same set. What ships: the git-tracked code under CompletionRoute/ plus the locally
generated data (gitignored Imported_*.lua, QuestDeps_*.lua and RouteOrder_*.lua), limited to what the six TOCs load
(plus their XML includes, Textures/ and licence files), plus LICENSE.txt, ATTRIBUTION.md and README.md written here.
RULES below gives every shippable path its category, licence, source and generator; the generators were read to fill
it in. A packaged TOC is the source TOC with the version stamped in, nothing else. Files derived from another add-on's
data (WoW-Pro, Questie) belong to builds that were retired: none may be in CompletionRoute/ at all, and no TOC may list
one.

The gate fails the build when a packaged file has no provenance (no rule, or a "tracked" file git does not track), when
a WoW-Pro- or Questie-derived file is in CompletionRoute/ or listed by a TOC, when a packaged data file credits such
data or a baked route order orders a guide that only such a file registers, when a file says it must not be
redistributed, mentions the commercial guide product this project replaced (file names and contents, case-insensitive),
holds personal data (e-mail addresses other than help@batesai.org, home or volume paths, WoW account and character
names), holds a secret or key pattern, would be packaged through a symlink (the one opt-in exception is
--allow-checkout-links), when a packaged TOC or XML lists a file that is not in the package, or when a licence notice
is missing.

This tool never creates a git tag, never pushes and never creates a GitHub release: public releases wait for Daniel's
beta. Exit code: 0 gate passed, 1 gate failed, 2 usage error, 3 the packager itself failed (traceback printed).
"""
import argparse
import datetime
import fnmatch
import hashlib
import json
import os
import re
import shutil
import sqlite3
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
PRODUCT = "Completionist's Guide (CompletionRoute add-on)"     # provenance.json "product": marks a folder as a build
# the packager files that decide what a package says (LICENSE.txt, ATTRIBUTION.md, README.md, provenance text): an
# uncommitted change to them makes the build dirty, like a change under CompletionRoute/
PACKAGER_FILES = ("package_release.py", "release/ATTRIBUTION.md", "release/README.md")

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
# never shipped, never installed, never loaded: files derived from another add-on's data, left over from a retired build
INTEROP = ("interop-wowpro", "interop-questie")
# categories whose content is scanned for WoW-Pro / Questie material (code and docs may name them: notices, comments)
DATA_CATEGORIES = ("own-data", "wiki-cc-by-sa", "blizzard-client-data")


@dataclass(frozen=True)
class Rule:
    pattern: str        # path inside CompletionRoute/, "/"-separated; "*" never crosses a "/"
    category: str
    licence: str
    source: str
    generator: str
    origin: str         # tracked (in git) | generated (gitignored, built locally) | packager (written here)
    why: str = ""       # never-shipped rules: why the file never ships


R = Rule
# First match wins. The never-shipped rules come first. Each "generator" and "source" was read from the generator in
# tools/ (the generators of the never-shipped files are in archive/questie-tooling/ or were removed).
RULES = (
    # ---- derived from another add-on's data: never shipped; one of these in CompletionRoute/ or in a TOC fails the gate
    R("Guides/Imported_WoWPro_*.lua", "interop-wowpro", "WoW-Pro guides: CC BY-NC-ND", "guide text exported from the "
      "WoW-Pro add-on installed on this machine (file header: do not redistribute)", "local export (script retired)",
      "generated", "WoW-Pro-derived; the add-on has not read these since 2026-11-11. Delete the file"),
    R("Guides/Imported_Quests_*_gaps.lua", "interop-questie", "Questie: GPL-3.0", "the older generated guides minus "
      "the quests the wiki covers: Questie on Classic clients, Blizzard quest POI plus Questie giver points, names and "
      "level gates on retail", "tools/wiki/gen_wiki_guides.py before 2026-11-11", "generated",
      "Questie-derived; a leftover of the dev build retired on 2026-11-11. Delete the file"),
    R("Guides/Imported_Quests_*.lua", "interop-questie", "Questie: GPL-3.0", "older guides made from a local Questie "
      "checkout (retail: Blizzard quest POI plus Questie names, givers and gates)",
      "archive/questie-tooling/gen_quest_guides.lua, gen_quest_guides_retail.py", "generated",
      "Questie-derived; only the offline measurement reads it. Move it to tools/measure/questie/ or delete it"),
    R("Guides/Imported_Storylines_*.lua", "interop-questie", "Questie: GPL-3.0 (mixed with Blizzard data)",
      "QuestLine order from Blizzard tables, but the step lines were copied from Imported_Quests_retail.lua (Questie "
      "giver points, names, faction and level gates)",
      "tools/gen_completion_guides.py before 2026-11-11 (storylines)", "generated",
      "Questie-derived; replaced by Guides/Imported_QuestLines_retail.lua (wiki + Blizzard data). Delete the file"),
    R("Data/Imported_*.lua", "interop-questie", "Questie: GPL-3.0", "dungeon entrances from Questie's "
      "Database/Zones/data/dungeons.lua (Imported_Entrances.lua); no generated file belongs in Data/Imported_*",
      "archive/questie-tooling/gen_entrances.py", "generated",
      "Questie-derived; Core/Instances.lua learns doors and asks the Retail journal. Delete the file"),
    # ---- Warcraft Wiki data (CC BY-SA 4.0) --------------------------------------------------------------------------
    R("Guides/Imported_Wiki_*.lua", "wiki-cc-by-sa", CC_BY_SA, "Warcraft Wiki quest pages; which quests a client has: "
      "Blizzard QuestV2 table (facts); on retail, the map point of a step the wiki gives none for and whose note says "
      "'(location: Blizzard quest POI, ...)': Blizzard QuestPOIBlob and QuestPOIPoint tables (facts; the file header "
      "names the client build); the map point of a step neither gives one for and whose note says '(location: player "
      "contributions, N players)': merged player contributions from the open data repository wow-completionist-data "
      "(CC BY-SA 4.0; the file header names the repository and the commit). A file that credits a point to another "
      "add-on's data ('(location: Questie data)': the retired dev build, or the offline measurement file) fails the gate",
      "tools/wiki/gen_wiki_guides.py (zone split and step order: tools/wiki/gen_spine.py)", "generated"),
    R("Guides/Imported_Spine_*.lua", "wiki-cc-by-sa", CC_BY_SA, "the wiki zone guides chained by level band and the "
      "wiki's quest chains (retail: also Blizzard QuestLine/Campaign order, facts); each entry points at a wiki guide "
      "and copies no step text", "tools/wiki/gen_spine.py (run by gen_wiki_guides.py)", "generated"),
    R("Guides/Imported_Gold_*.lua", "wiki-cc-by-sa", CC_BY_SA, "Warcraft Wiki herb, ore, fishing, NPC, quest and "
      "instance pages; Blizzard tables for facts",
      "tools/wiki/gen_gold.py", "generated"),
    R("Guides/Imported_Professions_*.lua", "wiki-cc-by-sa", CC_BY_SA, "Warcraft Wiki trainer, recipe, reagent and "
      "fishing pages; recipe membership, skill levels, reagents and dig sites from Blizzard tables (facts)",
      "tools/wiki/gen_professions.py", "generated"),
    R("Guides/Imported_Achievements_*.lua", "wiki-cc-by-sa", CC_BY_SA, "Blizzard Achievement, Criteria, Map, QuestPOI, "
      "WorldMapOverlay, AreaTable and DungeonEncounter tables (facts); criterion points from Imported_Wiki_<flavor>.lua "
      "(player contributions where that file credits them) and wiki NPC, object, item, glyph, race and achievement "
      "pages; each located step names its source",
      "tools/gen_completion_guides.py (achievements)",
      "generated"),
    R("Guides/Imported_QuestLines_*.lua", "wiki-cc-by-sa", CC_BY_SA, "Blizzard QuestLine/QuestLineXQuest order and "
      "QuestPOIBlob/QuestPOIPoint pins (facts); step text, gates and points from Imported_Wiki_retail.lua "
      "(player contributions where that file credits them); "
      "quests without a wiki page are 'Quest <id>' steps named live by the client",
      "tools/gen_completion_guides.py (quest lines)", "generated"),
    R("Data/QuestDeps_*.lua", "wiki-cc-by-sa", CC_BY_SA, "quest chains (previous/next links) and names from "
      "Imported_Wiki_<flavor>.lua, breadcrumb flags from the wording of the wiki quest pages",
      "tools/gen_quest_deps.py", "generated"),
    R("Data/Teleports.lua", "wiki-cc-by-sa", CC_BY_SA, "hand-authored teleport list: spell, item and toy ids checked "
      "against Blizzard tables (facts); each landing point from a Warcraft Wiki coordinate or a Blizzard TaxiNodes "
      "position, cited per entry", "hand-authored; checked by tools/check_teleports.py", "tracked"),
    # ---- Blizzard client data -------------------------------------------------------------------------------------
    R("Guides/Imported_Missions_*.lua", "blizzard-client-data", BLIZZARD, "Blizzard GarrMission table; the travel "
      "step to each mission table is written in the generator (own)", "tools/gen_completion_guides.py (missions)",
      "generated"),
    R("Data/Taxi_*.lua", "blizzard-client-data", BLIZZARD, "Blizzard TaxiNodes, TaxiPath and TaxiPathNode tables",
      "tools/gen_taxi.py", "tracked"),
    R("Data/MapFix_forever.lua", "blizzard-client-data", BLIZZARD, "Blizzard UiMapAssignment table (era and Forever)",
      "tools/gen_mapfix_forever.py", "tracked"),
    R("Data/ZoneAliases.lua", "blizzard-client-data", BLIZZARD, "Blizzard UiMap ids; English names edited by hand",
      "tools/gen_maps.py + hand edits", "tracked"),
    # ---- own data -------------------------------------------------------------------------------------------------
    R("Data/RouteOrder_*.lua", "own-data", OWN, "baked step orders computed from the addon's own travel graph over "
      "the shipped wiki quest guides; a row for a guide that only a Questie- or WoW-Pro-derived file registers fails the gate",
      "tools/optimize_routes.py (costs: tools/cost_matrix.lua; driver: tools/bake_resume.py)", "generated"),
    R("Data/Access.lua", "own-data", OWN, "hand-authored access chains (quest ids, NPCs, coordinates)", "hand-authored", "tracked"),
    R("Data/Transit.lua", "own-data", OWN, "hand-authored boats, zeppelins, trams and portals", "hand-authored", "tracked"),
    R("Data/Inns.lua", "own-data", OWN, "hand-authored innkeeper seed list", "hand-authored", "tracked"),
    R("Data/Farm_routes.lua", "own-data", OWN, "hand-authored coarse farm rings", "hand-authored", "tracked"),
    R("Data/Roads_*.lua", "own-data", OWN, "roads authored from the zone maps or traced in game",
      "hand-authored; tools/roads_from_trace.py, tools/trace_roads.py", "tracked"),
    R("Guides/Leveling/*.lua", "own-data", "CC BY-SA 4.0 (file header); CompletionRoute contributors",
      "hand-written community guides", "hand-authored", "tracked"),
    R("Textures/*.tga", "own-data", OWN, "drawn by script", "tools/gen_textures.py, tools/gen_pointer.py", "tracked"),
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
    R("Adapters/*.lua", "own-code", OWN, "own (live quest lists read from the game client's own API)", "hand-written", "tracked"),
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
# names of a credential in an assignment; preceded by a non-alphanumeric, so OPENAI_API_KEY= and api_key= both count
_CRED = r"(?:api[_-]?key|secret[_-]?key|client[_-]?secret|access[_-]?token|auth[_-]?token|bot[_-]?token|password|passwd)"
SECRETS = (
    ("private key block", re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----")),
    ("AWS access key id", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("GitHub token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,})")),
    # prefixed provider keys in one pass (one regex per provider took 0.7 s each on 42 MB); the label comes from the
    # group that matched (KEY_LABELS)
    ("API key", re.compile(r"(?<![A-Za-z0-9])(?:(?P<sk>sk-(?:ant-|proj-|live-)?[A-Za-z0-9_-]{24,})|"
                           r"(?P<csk>csk-[A-Za-z0-9]{32,})|(?P<gsk>gsk_[A-Za-z0-9]{40,})|(?P<hf>hf_[A-Za-z0-9]{30,})|"
                           r"(?P<xai>xai-[A-Za-z0-9]{40,})|(?P<npm>npm_[A-Za-z0-9]{36,})|"
                           r"(?P<glpat>glpat-[A-Za-z0-9_-]{20,}))")),
    ("Slack token", re.compile(r"\bxox[abposr]-[A-Za-z0-9-]{10,}")),
    ("Google API key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}")),
    ("Stripe key", re.compile(r"\b(?:sk|rk|pk)_live_[A-Za-z0-9]{16,}")),
    ("Telegram bot token", re.compile(r"\b\d{8,10}:AA[A-Za-z0-9_-]{33}\b")),
    ("JSON web token", re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}")),
    # quoted, or unquoted (an .env line, a shell export) when the value looks like a key: 16+ key characters with
    # letters and digits
    ("credential assignment", re.compile(r"(?i)(?<![A-Za-z0-9])" + _CRED + r"\b[\"']?\s*[:=]\s*(?:[\"'][^\"'\s]{8,}[\"']|"
                                         r"(?=[A-Za-z0-9_+/=-]*[0-9])(?=[A-Za-z0-9_+/=-]*[A-Za-z])[A-Za-z0-9_+/=-]{16,})")),
)
KEY_LABELS = {"sk": "sk- API key", "csk": "Cerebras API key", "gsk": "Groq API key", "hf": "Hugging Face token",
              "xai": "xAI API key", "npm": "npm token", "glpat": "GitLab token"}
INTEROP_MARK = re.compile(r"(?i)questie|wow-?pro")
# a wiki quest step whose map point is a Blizzard client quest pin (tools/wiki/gen_wiki_guides.py, retail), and the
# header line its file must carry: the client tables and the build they were read from
POI_NOTE = "(location: Blizzard quest POI"
POI_HEADER = re.compile(r"QuestPOIBlob \+ QuestPOIPoint tables via wago\.tools, build (?!unknown\b)\S")
# a step whose map point players contributed (tools/wiki/gen_wiki_guides.py class Contributions; an achievement
# criterion that takes such a quest point says "location: player contributions, ...; quest N"), and the header line its
# file must carry: the open data repository, its licence and the commit the areas came from.  "unknown" (the areas were
# not read from a checkout of that repository) and "<commit>-dirty" (they differ from the commit) do not ship.
CONTRIB_NOTE = "location: player contributions"
CONTRIB_HEADER = re.compile(r"merged player contributions, wow-completionist-data [^\n]*CC BY-SA 4\.0\), "
                            r"commit [0-9a-f]{40}(?![0-9A-Za-z-])")
NO_REDISTRIBUTE = re.compile(r"(?i)do not (?:redistribute|commit)|not for redistribution|local use only")
TOC_FILE_LINE = re.compile(r"^\s*([^#\s][^\r\n]*?)\s*$")
XML_REF = re.compile(r"<(?:Script|Include)\s+[^>]*?file\s*=\s*\"([^\"]+)\"", re.I)
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+.][0-9A-Za-z.+-]+)?$")
# a guide registration (generated: R({ id="..."; hand-written: NS.Guide.Register({ id = "...") and a baked order row
GUIDE_ID = re.compile(rb'(?:\bR|\.Register)\(\{\s*id\s*=\s*"([^"]+)"')
ORDER_ROW = re.compile(rb'^O\["([^"]+)"\]\s*=', re.M)


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

    def text(self, red=redact):
        return red(f"[{self.rule}] {self.path}: {self.detail}")


@dataclass
class Result:
    version: str = ""
    commit: str = ""
    dirty: bool = False
    failures: list = field(default_factory=list)
    warnings: list = field(default_factory=list)
    files: dict = field(default_factory=dict)          # rel -> manifest record
    clients: dict = field(default_factory=dict)        # client -> sorted rels
    excluded: list = field(default_factory=list)       # never-shipped files found in CompletionRoute/ (each one fails the gate)
    not_packaged: list = field(default_factory=list)
    packages: list = field(default_factory=list)
    layout: str = DEFAULT_LAYOUT
    stage: Path = None
    commit_time: int = 0
    variants: dict = field(default_factory=dict)       # client -> {rel: bytes} that differ in its per-client zip
    term_rx: object = None                              # personal terms, masked in every report and manifest string

    @property
    def ok(self):
        return not self.failures

    def fail(self, rule, path, detail):
        self.failures.append(Finding(rule, path, detail))

    def redact(self, s):
        """report text: never the product name, never a personal term (a planted file name may hold either)"""
        s = redact(s)
        return self.term_rx.sub("[personal term]", s) if self.term_rx else s

    def redact_all(self, v):
        """the same for every string in a manifest structure"""
        if isinstance(v, str):
            return self.redact(v)
        if isinstance(v, dict):
            return {k: self.redact_all(x) for k, x in v.items()}
        if isinstance(v, (list, tuple)):
            return [self.redact_all(x) for x in v]
        return v


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


def stamp_toc(text, version):
    """the packaged TOC: the source TOC with ## Version set (added after ## Title if missing); no other change"""
    out, have = [], False
    for line in text.splitlines():
        if line.startswith("## Version:"):
            out.append(f"## Version: {version}")
            have = True
            continue
        out.append(line)
    if not have:
        at = next((i + 1 for i, l in enumerate(out) if l.startswith("## Title:")), 0)
        out.insert(at, f"## Version: {version}")
    return "\n".join(out) + "\n"


def personal_terms(opts, res):
    """{lower-case term: label} for every personal term: --personal-term, the local terms file, and the WoW account
    and character names under <wow>/_*_/WTF/Account/<account>/<realm>/<character>"""
    found = []
    for t in opts.personal_term or []:
        found.append((t, "personal term (--personal-term)"))
    if PERSONAL_TERMS_FILE.exists() and not opts.no_local_terms:
        for line in PERSONAL_TERMS_FILE.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                found.append((line, f"personal term ({PERSONAL_TERMS_FILE.name})"))
    wow = Path(opts.wow_dir) if opts.wow_dir else None
    if wow and wow.is_dir():
        accounts, chars = set(), set()
        for acc in sorted(wow.glob("_*_/WTF/Account/*")):
            if not acc.is_dir() or acc.name == "SavedVariables":
                continue
            accounts.add(acc.name)
            for realm in sorted(acc.iterdir()):
                if realm.is_dir() and realm.name != "SavedVariables":
                    chars.update(c.name for c in realm.iterdir() if c.is_dir() and c.name != "SavedVariables")
        found += [(a, "WoW account name (WTF/Account)") for a in sorted(accounts)]
        found += [(c, "WoW character name (WTF/Account/<account>/<realm>)") for c in sorted(chars)]
        res.warnings.append(f"personal data: {len(accounts)} WoW account name(s) and {len(chars)} character name(s) "
                            "found under the WoW folder's WTF/Account are checked")
    elif wow:
        res.warnings.append("personal data: WoW folder not found, account and character names were not checked "
                            "(pass --wow-dir, --personal-term or tools/release/personal_terms.local.txt)")
    out = {}
    for t, label in found:
        if len(t) < 4:
            res.warnings.append(f"personal data: a {label} is shorter than 4 characters and was skipped")
            continue
        out.setdefault(t.lower(), label)
    return out


class Scanner:
    def __init__(self, terms):
        self.deny = denylist()
        self.terms = terms          # {lower-case term: label}
        # one pass per file for every personal term, longest first so a longer term wins over its prefix
        alts = "|".join(re.escape(t) for t in sorted(terms, key=len, reverse=True))
        self.term_rx = re.compile(r"(?<![A-Za-z0-9])(?:" + alts + r")(?![A-Za-z0-9])", re.I) if terms else None

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
        if category == "wiki-cc-by-sa" and POI_NOTE in text and not POI_HEADER.search(text[:4000]):
            res.fail("no-provenance", rel, f"{text.count(POI_NOTE)} step(s) take their map point from Blizzard quest pins "
                     f"('{POI_NOTE}, ...)') but the file header does not name QuestPOIBlob + QuestPOIPoint and the client "
                     "build (tools/wiki/gen_wiki_guides.py writes that line)")
        if category in DATA_CATEGORIES and CONTRIB_NOTE in text and not CONTRIB_HEADER.search(text[:4000]):
            steps = sum(1 for ln in text.splitlines() if CONTRIB_NOTE in ln and not ln.startswith("--"))
            res.fail("no-provenance", rel, f"{steps} step(s) credit their map point to player contributions "
                     f"('({CONTRIB_NOTE}, ...)') but the file header does not name the data repository "
                     "(wow-completionist-data, CC BY-SA 4.0) with the commit the areas came from, or the commit is "
                     "unknown or has local changes (tools/wiki/gen_wiki_guides.py writes that line from a clean "
                     "checkout of the data repository)")
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
        if self.term_rx:
            m = self.term_rx.search(rel)
            if m:
                res.fail("personal-data", rel, f"the file name holds a {self.terms[m.group(0).lower()]}")
            first = {}
            for m in self.term_rx.finditer(text):
                first.setdefault(self.terms[m.group(0).lower()], m.start())
            for label, pos in first.items():
                res.fail("personal-data", rel, f"{label} at line {lineno(text, pos)}")
        for label, rx in SECRETS:
            m = rx.search(text)
            if m:
                res.fail("secret", rel, f"{KEY_LABELS.get(m.lastgroup, label)} pattern at line {lineno(text, m.start())}")


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
    # the packager and its templates write LICENSE.txt, ATTRIBUTION.md, README.md and every provenance record, so an
    # uncommitted edit to them changes the package too (checked in the checkout this script runs from)
    try:
        tool_status = git(TOOLS, "status", "--porcelain", "--untracked-files=normal", "--", *PACKAGER_FILES)
        res.dirty = res.dirty or bool(tool_status.strip())
    except RuntimeError:
        res.warnings.append("the packager is not in a git checkout: its templates and rules cannot be tied to a commit")
    if res.dirty:
        res.warnings.append("uncommitted changes to the add-on, LICENSE or the packager and its templates: "
                            "provenance.json records sha256 per file, but the commit alone does not reproduce this build")
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
    never_listed, toc_text = set(), {}      # never-shipped files a TOC lists
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
                    # a TOC lists only what ships: nothing is stripped from the packaged copy any more
                    never_listed.add(rel)
                    res.fail("interop-derived", toc, f"lists {rel}, which never ships ({r.category}: {r.why}); remove the "
                             "line (tools/validate_toc.lua checks this too)")
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
            # one build: the source folder holds only what ships, so tools/install.sh stops on this file too
            res.excluded.append({"path": f, "category": r.category, "source": r.source, "why": r.why})
            res.fail("interop-derived", f, f"a file that never ships is in {ADDON}/ ({r.category}: {r.why})")
        else:
            res.not_packaged.append(f)

    # ---- stage ----------------------------------------------------------------------------------------------------
    stage = Path(opts.stage) / ADDON
    stage.mkdir(parents=True, exist_ok=True)
    res.stage = stage
    present, linked = set(), 0
    for rel in sorted(universal):
        r = rule_for(rel)
        src = source_of(rel)
        if not os.path.lexists(src):
            continue            # reported by the TOC check below
        present.add(rel)
        base = addon if src == addon / rel else Path(str(src)[:-len(rel) - 1])
        link = symlink_component(base, rel)
        via = ""
        if link:
            target = src.resolve()
            inside = next((root for root in allowed_roots if target.is_relative_to(root)), None)
            same = inside is not None and target.relative_to(inside).as_posix() == rel
            checkout_link = bool(r and r.origin == "generated" and link == rel and target.is_file() and same)
            if checkout_link and opts.allow_checkout_links:
                via = "symlink into a checkout"
                linked += 1
            else:
                res.fail("symlink", rel, "would be packaged through a symlink (" + (
                    "a parent folder is a link" if link != rel else
                    "a generated file linked to the same path in the main checkout: a git worktree may pass "
                    "--allow-checkout-links" if checkout_link else
                    "only generated data may be a link, and only to the same path in the main checkout, with "
                    "--allow-checkout-links") + ")")
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
            data = stamp_toc(toc_text[rel], res.version).encode("utf-8")
        out = stage / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(data)
        res.files[rel] = {
            "path": f"{ADDON}/{rel}", "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
            "category": r.category if r else "unknown", "licence": r.licence if r else "", "source": r.source if r else "",
            "generator": r.generator if r else "", "origin": r.origin if r else "unknown",
            "via": via or ("--data-root" if src != addon / rel else ""),
        }
    if linked:
        res.warnings.append(f"--allow-checkout-links: {linked} generated file(s) were read through links into the main "
                            "checkout; provenance.json marks them (via)")

    # ---- gate: baked route orders only for guides that ship -------------------------------------------------------
    # Data/RouteOrder_<flavor>.lua is computed over every quest guide the bake loaded. A row for a guide that never
    # ships (the retired Questie-derived _gaps guides, qdb:/qpoi:) is an order computed from that guide's Questie points.
    shipped_ids = set()
    for rel in res.files:
        if rel.startswith("Guides/") and rel.endswith(".lua"):
            shipped_ids.update(GUIDE_ID.findall((stage / rel).read_bytes()))
    interop_ids = {}            # guide id -> the never-shipped files that register it, TOC-listed files first
    for e in sorted(res.excluded, key=lambda e: (e["path"] not in never_listed, e["path"])):
        src = source_of(e["path"])
        if src.is_file() and e["path"].endswith(".lua"):
            for gid in GUIDE_ID.findall(src.read_bytes()):
                interop_ids.setdefault(gid, []).append(e["path"])
    for rel in sorted(res.files):
        if not match("Data/RouteOrder_*.lua", rel):
            continue
        rows = ORDER_ROW.findall((stage / rel).read_bytes())
        fl = rel[len("Data/RouteOrder_"):-len(".lua")]
        res.files[rel]["order_rows"] = len(rows)
        derived = [g for g in rows if g not in shipped_ids and g in interop_ids]
        orphan = [g for g in rows if g not in shipped_ids and g not in interop_ids]
        if derived:
            prefixes = {}
            for g in derived:
                p = g.split(b":", 1)[0].decode("utf-8", "replace") + ":"
                prefixes[p] = prefixes.get(p, 0) + 1
            files = sorted({next((f for f in interop_ids[g] if f"_{fl}" in f), interop_ids[g][0]) for g in derived})
            res.fail("interop-derived", rel, f"{len(derived)} of {len(rows)} baked order row(s) order guides that never ship "
                     f"because they are Questie- or WoW-Pro-derived ({', '.join(f'{k} {v}' for k, v in sorted(prefixes.items()))}; "
                     f"from {', '.join(files[:3])}{' ...' if len(files) > 3 else ''}); rebake over the shipped guides only "
                     "(docs/RELEASE.md)")
        if orphan:
            res.warnings.append(f"{rel}: {len(orphan)} baked order row(s) name a guide that is in no file here "
                                f"(stale bake: the client ignores them; rebake with tools/bake_resume.py), first "
                                f"{orphan[0].decode('utf-8', 'replace')}")

    # ---- files written by the packager ----------------------------------------------------------------------------
    lic = repo / "LICENSE"
    lic_text = lic.read_text(encoding="utf-8") if lic.is_file() else ""
    missing = [s for s in LICENSE_MUST_SAY if s not in lic_text]
    if missing:
        res.fail("missing-notice", "LICENSE.txt", "the repository LICENSE is missing or lacks: " + "; ".join(missing))
    for d, (name, _, _, _, lic_file) in LIBS.items():
        if any(rel.startswith(d + "/") for rel in res.files) and lic_file and lic_file not in res.files:
            res.fail("missing-notice", lic_file, f"{name} ships without its licence text")

    def notice_values(rels):
        """template values for ATTRIBUTION.md and README.md, listing only the files in rels"""
        by_cat = {}
        for rel in sorted(rels):
            by_cat.setdefault(res.files[rel]["category"], []).append(rel)
        libs = [f"* **{name}** (`{d}/`) by {authors}. Licence: {licence}. Changes: {changes}."
                for d, (name, licence, authors, changes, _) in LIBS.items() if any(r.startswith(d + "/") for r in rels)]
        return {
            "VERSION": res.version,
            "WIKI_FILES": bullet(by_cat.get("wiki-cc-by-sa", [])),
            "CCBYSA_OWN_FILES": bullet([r for r in by_cat.get("own-data", []) if "CC BY-SA" in res.files[r]["licence"]]),
            "BLIZZARD_FILES": bullet(by_cat.get("blizzard-client-data", [])),
            "LIBRARIES": "\n".join(libs) or "* (none)",
            "PACKAGE_NOTE": "One `CompletionRoute` folder serves every client: each client loads only its own TOC's "
                            "files. If you downloaded a per-client zip, it holds only that client's data.",
        }
    vals = notice_values(list(res.files))
    made = {"LICENSE.txt": lic_text, "ATTRIBUTION.md": render("ATTRIBUTION.md", vals), "README.md": render("README.md", vals)}
    # a per-client zip carries an ATTRIBUTION.md that lists only the files in that zip
    for c in per_client:
        text = render("ATTRIBUTION.md", notice_values([r for r in per_client[c] & present if r in res.files]))
        if text != made["ATTRIBUTION.md"]:
            res.variants[c] = {"ATTRIBUTION.md": text.encode("utf-8")}
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
    res.term_rx = scanner.term_rx
    for rel, rec in sorted(res.files.items()):
        scanner.scan(rel, (stage / rel).read_bytes(), rec["category"], res)
    for c, files in sorted(res.variants.items()):
        for rel, data in sorted(files.items()):
            scanner.scan(rel, data, res.files[rel]["category"], res)

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
                if rel in never_listed:
                    continue        # already reported: the TOC lists a file that never ships
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


def write_zip(path, stage, rels, commit_time, variants=None):
    """a reproducible zip of stage/<rels>; variants {rel: bytes} replace a staged file in this zip only"""
    ts = datetime.datetime.fromtimestamp(max(commit_time, 315532800), datetime.timezone.utc).timetuple()[:6]
    variants = variants or {}
    unpacked = 0
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for rel in sorted(rels):
            zi = zipfile.ZipInfo(f"{ADDON}/{rel}", ts)
            zi.external_attr = 0o644 << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            data = variants[rel] if rel in variants else (stage / rel).read_bytes()
            unpacked += len(data)
            z.writestr(zi, data, compresslevel=9)
    data = path.read_bytes()
    rec = {"name": path.name, "files": len(rels), "bytes_unpacked": unpacked, "bytes_zip": len(data),
           "sha256": hashlib.sha256(data).hexdigest()}
    if variants:
        # these entries differ from the files[] record of the same path (a per-client ATTRIBUTION.md)
        rec["differs"] = [{"path": f"{ADDON}/{rel}", "bytes": len(b), "sha256": hashlib.sha256(b).hexdigest()}
                          for rel, b in sorted(variants.items()) if rel in rels]
    return rec


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
            rec = write_zip(folder / f"{ADDON}-{res.version}-{c}.zip", res.stage, rels, res.commit_time,
                            res.variants.get(c))
            rec["client"] = c
            out[rec["name"]] = rec
    return out


def manifest(res):
    """provenance.json; every string is redacted (product name, personal terms) except "product" and "version", which
    mark a folder as a build (is_build)"""
    return dict(res.redact_all({
        "format": 1,
        "product": PRODUCT,
        "version": res.version, "commit": res.commit, "dirty": res.dirty,
        "built": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "layout": res.layout,
        "gate": {"result": "PASS" if res.ok else "FAIL",
                 "failures": [{"rule": f.rule, "path": f.path, "detail": f.detail} for f in res.failures],
                 "warnings": res.warnings},
        "packages": res.packages,
        "files": [res.files[k] for k in sorted(res.files)],
        "excluded": res.excluded,
        "not_packaged": res.not_packaged,
    }), product=PRODUCT, version=res.version)


def report(res, measured, dry, out=sys.stdout):
    p = lambda s="": print(res.redact(s), file=out)  # noqa: E731
    p(f"Completionist's Guide release packager: {'DRY RUN, nothing written (--write builds dist/)' if dry else 'WRITE'}")
    p(f"version {res.version}, commit {res.commit[:12] or '-'}{' (uncommitted changes)' if res.dirty else ''}")
    cats = {}
    for rec in res.files.values():
        cats[rec["category"]] = cats.get(rec["category"], 0) + 1
    p(f"packaged {len(res.files)} files: " + ", ".join(f"{k} {v}" for k, v in sorted(cats.items())))
    if res.excluded:
        p(f"files that never ship, found in {ADDON}/ ({len(res.excluded)}): " + ", ".join(e["path"] for e in res.excluded))
    if res.not_packaged:
        p(f"not loaded by any TOC, not packaged ({len(res.not_packaged)}): " + ", ".join(res.not_packaged))
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
            p("  " + f.text(res.redact))


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
    ap.add_argument("--allow-checkout-links", action="store_true",
                    help="a git worktree whose generated data files are links to the same path in the main checkout: "
                    "read through those links (every other symlink still fails the gate)")
    ap.add_argument("--db", help="also write tables data_provenance and release_gate into this SQLite file "
                    "(for example docs/verification.sqlite in the main checkout); never written by default")
    return ap.parse_args(argv)


def write_db(path, res, man):
    """data_provenance (one row per packaged file) and release_gate (one row per problem, or one PASS row) for this
    version, replacing the rows an earlier build of the same version wrote"""
    con = sqlite3.connect(path)
    try:
        con.executescript("""
        create table if not exists data_provenance(version text, commit_id text, path text, category text, licence text,
            source text, generator text, origin text, via text, bytes int, sha256 text, clients text,
            primary key(version, path));
        create table if not exists release_gate(version text, commit_id text, built text, result text, rule text,
            path text, detail text);
        """)
        con.execute("delete from data_provenance where version=?", (res.version,))
        con.execute("delete from release_gate where version=?", (res.version,))
        con.executemany("insert into data_provenance values (?,?,?,?,?,?,?,?,?,?,?,?)",
                        [(res.version, res.commit, f["path"], f["category"], f["licence"], f["source"], f["generator"],
                          f["origin"], f["via"], f["bytes"], f["sha256"], ",".join(f.get("clients", ())))
                         for f in man["files"]])
        gate = man["gate"]
        rows = [(res.version, res.commit, man["built"], gate["result"], f["rule"], f["path"], f["detail"])
                for f in gate["failures"]] or [(res.version, res.commit, man["built"], gate["result"], "", "", "")]
        con.executemany("insert into release_gate values (?,?,?,?,?,?,?)", rows)
        con.commit()
    finally:
        con.close()


def is_build(folder):
    """a folder this packager wrote: named like a version and holding that version's provenance.json"""
    if folder.is_symlink() or not folder.is_dir() or not VERSION_RE.match(folder.name):
        return False
    try:
        man = json.loads((folder / "provenance.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    return isinstance(man, dict) and man.get("product") == PRODUCT and man.get("version") == folder.name


def free_name(folder, name, stamp=None):
    """folder/name when free, else folder/name-<stamp> (when given), then -2, -3 ...: nothing is ever overwritten"""
    if not os.path.lexists(folder / name):
        return folder / name
    base = f"{name}-{stamp}" if stamp else name
    target, n = folder / base, 1
    while os.path.lexists(target):
        n += 1
        target = folder / f"{base}-{n}"
    return target


def dist_dir(opts):
    return Path(opts.out).resolve() if opts.out else Path(opts.repo).resolve() / "dist"


def write_dist(opts, res, man, measured, chosen, zdir):
    """A passing build becomes <out>/<version>/ (CompletionRoute/, the zip(s), provenance.json, gate.txt) and every
    earlier build in <out>, the same version included, moves to <out>/archive/: one current build, nothing deleted.
    A failing build writes only gate.txt and provenance.json, into <out>/failed/<version>-<time>/, and moves nothing,
    so it never displaces the build being tested. Folders the packager did not write are never moved or changed."""
    dist = dist_dir(opts)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    if res.ok:
        dest = dist / res.version
        if os.path.lexists(dest) and not is_build(dest):
            raise SystemExit(f"package_release: {dest} exists and was not written by this packager; move it away")
        dist.mkdir(parents=True, exist_ok=True)
        for old in sorted(dist.iterdir()):
            if is_build(old):
                (dist / "archive").mkdir(exist_ok=True)
                shutil.move(str(old), str(free_name(dist / "archive", old.name, stamp)))
    else:
        (dist / "failed").mkdir(parents=True, exist_ok=True)
        dest = free_name(dist / "failed", f"{res.version}-{stamp}")
    dest.mkdir()
    if res.ok:
        shutil.copytree(res.stage, dest / ADDON)
        for r in chosen:
            shutil.copy2(zdir / r["name"], dest / r["name"])
    (dest / "provenance.json").write_text(json.dumps(man, indent=1) + "\n", encoding="utf-8")
    with open(dest / "gate.txt", "w", encoding="utf-8") as fh:
        report(res, measured, False, fh)
    return dest


def check_paths(opts):
    """usage errors (exit 2) before any work: every folder option must be a folder, or (output folders) not exist yet"""
    def is_dir_or_absent(flag, path):
        if path and os.path.lexists(path) and not os.path.isdir(path):
            raise SystemExit(f"package_release: {flag} {path} exists and is not a folder")
    if opts.tmp and not os.path.isdir(opts.tmp):
        raise SystemExit(f"package_release: --tmp {opts.tmp} is not a folder")
    is_dir_or_absent("--out", opts.out)
    if opts.write:
        dist = dist_dir(opts)
        is_dir_or_absent("--out", str(dist))
        if opts.version and os.path.lexists(dist / opts.version) and not is_build(dist / opts.version):
            raise SystemExit(f"package_release: {dist / opts.version} exists and was not written by this packager; "
                             "move it away")
    is_dir_or_absent("--stage-dir", opts.stage_dir)
    if opts.stage_dir and os.path.isdir(opts.stage_dir) and any(Path(opts.stage_dir).iterdir()):
        raise SystemExit(f"package_release: --stage-dir {opts.stage_dir} is not empty")
    if opts.db:
        if os.path.islink(opts.db):
            # a git worktree's docs/verification.sqlite is a link into the main checkout: never write through it
            raise SystemExit(f"package_release: --db {opts.db} is a symlink; pass the real file")
        if os.path.isdir(opts.db) or not os.path.isdir(os.path.dirname(os.path.abspath(opts.db))):
            raise SystemExit(f"package_release: --db {opts.db} is a folder or its folder does not exist")


def run(argv=None, out=sys.stdout):
    """the whole build; returns (exit code, Result, manifest dict)"""
    opts = parse_args(argv)
    check_paths(opts)
    tmp = tempfile.mkdtemp(prefix="cr-release-", dir=opts.tmp)
    try:
        opts.stage = Path(opts.stage_dir).resolve() if opts.stage_dir else Path(tmp) / "stage"
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
        if opts.db:
            write_db(opts.db, res, man)
        report(res, measured, not opts.write, out)
        if opts.write:
            print(f"wrote {dest}" + ("" if res.ok else " (gate.txt and provenance.json only: the gate failed; no "
                                     "earlier build was moved)"), file=out)
        if opts.db:
            print(f"wrote tables data_provenance and release_gate ({len(man['files'])} files) to {opts.db}", file=out)
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
    except Exception:       # a crash is not a gate result: exit 1 means only "the gate failed"
        import traceback
        traceback.print_exc()
        print("package_release: internal error (exit 3); the gate did not run to the end", file=sys.stderr)
        return 3
    return code


if __name__ == "__main__":
    sys.exit(main())
