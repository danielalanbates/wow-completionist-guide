#!/usr/bin/env python3
# CompletionRoute :: tools/wiki/gen_wiki_guides.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Generate per-zone quest guides from the Warcraft Wiki (the source of truth), one file per client.

    nice -n 10 python3 tools/wiki/gen_wiki_guides.py [era tbc mop retail forever]
                                 [--contributions DIR | --no-contributions] [--out DIR] [--no-spine]

Inputs : tools/wiki/wiki.sqlite (tools/wiki/parse_wiki.py), tools/db2/<flavor>/QuestV2.csv (+ retail
         QuestObjective.csv, QuestPOIBlob.csv, QuestPOIPoint.csv; tools/wiki/fetch_db2.py, tools/wiki/db2_fetch.py),
         tools/maps_<flavor>.lua.  Warcraft Wiki and Blizzard client data, plus players' own contributions:
         <contributions>/areas/<flavor>.json, the merged areas of the open data repository (wow-completionist-data,
         tools/contrib.py there; CC BY-SA 4.0; docs/CONTRIBUTE.md).  The contributions folder is --contributions DIR,
         else $CR_CONTRIB, else ../wow-completionist-data/contributions next to this checkout when it exists;
         --no-contributions reads none.  With no areas file for a client its output does not change by a byte.
Outputs: CompletionRoute/Guides/Imported_Wiki_<flavor>.lua        the wiki guides (CC BY-SA 4.0 data)
         tools/wiki/wiki.sqlite tables flavor_quests / flavor_gap / flavor_skip / gen_stats
         docs/verification.sqlite tables wiki_db2_conflict, wiki_point_sources (build "no-fallback")
         then tools/wiki/gen_spine.py writes Imported_Spine_<flavor>.lua (--no-spine skips it)
         --out DIR writes all of it into DIR instead and nothing anywhere else: the guide and spine files, the spine's
         parts_<flavor>.json, the four wiki.sqlite tables (DIR/wiki.sqlite) and the chart (DIR/verification.sqlite).
         tools/test_contrib_gen.py runs the generator that way.
The output is gitignored like every other Imported_* file.  There is one build: this file is what the TOCs load,
what tools/install.sh installs and what tools/package_release.py packages.

    nice -n 10 python3 tools/wiki/gen_wiki_guides.py --measure-fallback [flavors]

OFFLINE MEASUREMENT ONLY, never part of the build (tools/measure/README.md).  It answers one question: how many steps
that have no wiki point would a reference database locate, and which wiki points lie far from it.  It reads
tools/measure/questie/Imported_Quests_<flavor>.lua (older guides made from a local Questie checkout; gitignored, never
under CompletionRoute/) and writes only tools/measure/out/Imported_Wiki_<flavor>.lua (first statement: error(), so a
client that loaded it would stop at once; tools/install.sh and the packager refuse its content), the
wiki_point_sources row of build "fallback" and table wiki_fallback_conflict.  It never writes under CompletionRoute/,
never touches wiki.sqlite, the spine or wiki_db2_conflict, and --no-fallback (the old name of the default) is accepted
and ignored.

Flavor membership (docs/WIKI_DATA_SPEC.md 6): a wiki quest belongs to a client when its id is in that client's
QuestV2, it never shipped-and-was-pulled (RemovedFromBeta/Alpha/PTR), it is not Forever-only (except on forever) or Season of Discovery,
it was not removed at or before the client's game version ({{Classic only}}, {{Removed}}, ==Patch changes==), and
its added patch fits the client.  When a quest id has several pages ("(Classic)", "(BC Classic)" twins) the page made
for that client wins.

Step location priority (docs/WIKI_DATA_SPEC.md 3/4):
  1. {{co}} written in the questbox start/end or on the objective bullet itself
  2. the linked NPC / object / place page ({{Npcbox}} location, {{Npclocations}} row for the client's expansion,
     lead sentence); an item objective follows the item page's drop sources to a page with coordinates.  A coordinate
     that already stood on its page before patch 4.0.3 is a Classic-map number (tools/wiki/fetch_coord_history.py).
  3. retail only: the client's own quest pin (QuestPOIBlob/QuestPOIPoint): the turn-in area for T (and for A when the
     wiki names the same NPC for both), the objective area for C.  Note "(location: Blizzard quest POI, ...)".  Ships.
  4. a place players contributed (class Contributions): the merged area of the step's key, "A:<quest>" for an accept,
     "T:<quest>" for a turn-in, "C:<quest>:<objective>" for an objective (the number of the step's |QO| tag, 0 for a
     step without one: Core/Contribute.lua KeyFor).  Only areas marked "trusted" or "confirmed" on a map this client
     has; accept and turn-in take the heaviest, an objective up to three on one map.  Note "(location: player
     contributions, N players)".  Ships; the file header then names the data repository and its commit.
     A wiki point more than 100 yd from the contributed area of the same step on the same map is logged
     (wiki_db2_conflict, field A_xy_contrib / C_xy_contrib / T_xy_contrib): a lead for fixing the wiki, the guide
     keeps the wiki point.
     (--measure-fallback only, never in the build, reads no contributions: the same step in the reference file; the
     note then says "(location: Blizzard data)" or "(location: Questie data)".)
  5. the wiki page of the place an NPC/object page with no point names first in its location field ("[[Razor Hill]],
     [[Durotar]]"), when that place is not a map itself.  Note "(location: the wiki's <place> page; ...)".  Ships.
  6. otherwise the step names the quest's zone (|Z| without |M|, "No coordinates on the wiki; the quest is in <zone>"),
     so the router still takes the player there; with no zone either it has no location and says so.
Where every step's point came from is counted per client and build in docs/verification.sqlite wiki_point_sources.
Item-started quests (Blizzard ItemSparse.StartQuestID, tools/db2/<flavor>/ItemSparse.csv): the accept step is where the
item is obtained.  Its point comes from the wiki item page (the {{Coords}} in its "found / fished / dropped" sentences,
else the drop source pages), found through the questbox start link or, when the wiki starts the quest elsewhere or not
at all, through the item id; the note names the page the point came from.  A source page about a zone or continent
(its {{co}} rows are neighbours and landmarks) or a topic page whose only {{co}} rows stand in body sections (a
profession, holiday or system article) never gives a point: a zone source gives a zone-level accept (|Z| without |M|,
"zone only" in the note).  The accept carries |U|<item>|: the arrow switches to "Use <item>" when the item is in the
bags and the player is within 40 yd of the step's point (or the step has no location; Routing/Router.lua).
Chains: the questbox `previous` links become |PRE| (any one of them, ";"), and a `next` link adds the reverse edge.
Only quests that exist on the same client are kept in PRE, so a chain never waits for a quest that cannot exist.
World quests, callings and emissary quests are left out (time-limited, not completionist steps).
"""
import csv
import datetime
import json
import math
import os
import re
import shutil
import sqlite3
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import wikimaps  # noqa: E402
import wikitext as WT  # noqa: E402
import gen_spine  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
WIKI = ROOT / "tools" / "wiki" / "wiki.sqlite"
GUIDES = ROOT / "CompletionRoute" / "Guides"
# --measure-fallback (offline measurement, never part of the build): reference input and output, outside CompletionRoute/
MEASURE_IN = ROOT / "tools" / "measure" / "questie"
MEASURE_OUT = ROOT / "tools" / "measure" / "out"
VERIF = ROOT / "docs" / "verification.sqlite"
FLAVORS = ["era", "tbc", "mop", "retail", "forever"]
# WoW Forever (product wowf, 1.60.x): Era content (1.12 base + the 1.13-1.15 Era line) plus its own 1.60 additions
# (Skyborne, Zephras Isle, Mount Hyjal, Riverglades, new class quests) on reshaped maps (tools/maps_forever.lua).
# The client runs the era code path (Core/Init.lua: NS.flavor "era", NS.isForever).
CLASSICISH = ("era", "tbc", "forever")
# flavor -> (expansion number, last original patch it is built on)
EXP = {"era": (1, (1, 12, 9)), "tbc": (2, (2, 4, 9)), "mop": (5, (5, 4, 9)), "retail": (99, (99, 0, 0)),
       "forever": (1, (1, 12, 9))}
CO_KEY = {"era": ("wow", "classic", "vanilla", "era"), "tbc": ("tbc", "bc"), "mop": ("mop",), "retail": (),
          "forever": ("wow", "classic", "vanilla", "era", "forever")}
# --measure-fallback: Forever has no reference file of its own, so its comparison uses the era file (Era maps;
# reshaped maps are converted, see Gen.era_to_forever / Core/Util.lua).
FALLBACK_OF = {"forever": "era"}
SKIP_TYPES = re.compile(r"world quest|calling|emissary", re.I)
DELIVERY = re.compile(r"^(speak|talk|report|return|bring|take|deliver|go|travel|meet|seek|find|visit|"
                      r"give|hand|show|tell|carry|ask)\b", re.I)
# player contributions (docs/CONTRIBUTE.md): the merged areas of the open data repository
CONTRIB_REPO = "wow-completionist-data"
CONTRIB_URL = "https://github.com/danielalanbates/wow-completionist-data"
CONTRIB_DEFAULT = ROOT.parent / CONTRIB_REPO / "contributions"      # a sibling checkout of the data repository
CONTRIB_NOTE = "(location: player contributions"                    # tools/package_release.py looks for this
CONTRIB_KEY = re.compile(r"^(?:[AT]:\d{1,7}|C:\d{1,7}:\d{1,2})$")    # quest step keys (Core/Contribute.lua KeyFor)
CONTRIB_USED = ("trusted", "confirmed")     # "single" (one player, nobody agrees yet) is never used
CONTRIB_POINTS = 3                          # an objective step takes up to this many areas; accept and turn-in one
CONTRIB_FAR_YD = 100.0                      # a wiki point further than this from the contributed area is logged


def pkey(p):
    m = re.match(r"^\s*(\d+)\.(\d+)(?:\.(\d+))?", p or "")
    return (int(m.group(1)), int(m.group(2)), int(m.group(3) or 0)) if m else None


def patch_line(k):
    """which release line a patch belongs to: orig / era / forever / tbc / wrath / cata / mop (Classic lines)"""
    if not k:
        return None
    a, b = k[0], k[1]
    if a == 1 and b >= 60:
        return "forever"
    if a == 1 and b >= 13:
        return "era"
    if (a, b) == (2, 5):
        return "tbc"
    if (a, b) == (3, 4):
        return "wrath"
    if (a, b) == (4, 4):
        return "cata"
    if (a, b) == (5, 5):
        return "mop"
    return "orig"


VARIANT_FOR = {
    "classic": {"era", "tbc", "forever"}, "bc classic": {"tbc"}, "anniversary classic": {"tbc"},
    "wrath classic": {"mop"}, "cata classic": {"mop"}, "mop classic": {"mop"},
    "season of discovery": set(), "beta": set(), "alpha": set(), "forever": {"forever"}, "hardcore": set(),
}
VARIANT_PREF = {
    "era": ["classic"], "tbc": ["bc classic", "anniversary classic", "classic"],
    "mop": ["mop classic", "cata classic", "wrath classic"], "retail": [], "forever": ["forever", "classic"],
}


def membership(r, fl, qv2):
    """-> (ok, reason)"""
    if r["id"] not in qv2[fl]:
        return False, "not in QuestV2"
    if r["beta"]:
        return False, "removed from beta/alpha/ptr"
    if r["forever"] and fl != "forever":
        return False, "Forever only"
    if r["sod"]:
        return False, "Season of Discovery"
    v = (r["variant"] or "").lower()
    if v in VARIANT_FOR and fl not in VARIANT_FOR[v]:
        return False, f"page variant ({r['variant']})"
    e, vmax = EXP[fl]
    rk = pkey(r["removed_patch"])
    if r["classic_only"]:
        if fl == "retail":
            return False, "Classic only"
        if rk:
            args = (r["classic_only_args"] or "").split(",")
            if rk[0] < e or (rk[0] == e and not any(a in CO_KEY[fl] for a in args)):
                return False, f"Classic only, removed {r['removed_patch']}"
    else:
        if rk:
            line = patch_line(rk)
            if line == "orig" and (fl == "retail" or rk <= vmax):
                return False, f"removed {r['removed_patch']}"
            if line not in ("orig", None) and line == fl:
                return False, f"removed {r['removed_patch']}"
            # Forever was built from the Era line: an Era-line removal (1.13-1.15) is assumed to carry over
            if fl == "forever" and line == "era":
                return False, f"removed {r['removed_patch']} (Era line)"
        elif r["removed_flag"] and fl == "retail":
            return False, "removed"
    ak = pkey(r["added_patch"])
    if ak:
        line = patch_line(ak)
        if line == "forever" and fl != "forever":
            return False, "added in Forever"
        if fl == "retail" and line != "orig":
            return False, f"added in Classic patch {r['added_patch']}"
        if fl == "era" and not ((line == "orig" and ak <= vmax) or line == "era"):
            return False, f"added {r['added_patch']}"
        if fl == "tbc" and not ((line == "orig" and ak <= vmax) or line == "tbc"):
            return False, f"added {r['added_patch']}"
        if fl == "mop" and not ((line == "orig" and ak <= vmax) or line in ("wrath", "cata", "mop")):
            return False, f"added {r['added_patch']}"
        if fl == "forever" and not ((line == "orig" and ak <= vmax) or line in ("era", "forever")):
            return False, f"added {r['added_patch']}"
    return True, ""


def flavor_gate(fl):
    """the flavor guard at the top of a generated file.  Forever runs NS.flavor "era", so the era files step aside
    for Forever's own (NS.isForever) and the Forever files load nowhere else."""
    if fl == "forever":
        return "if not NS.isForever then return end"
    if fl == "era":
        return 'if NS.flavor ~= "era" or NS.isForever then return end'
    return f'if NS.flavor ~= "{fl}" then return end'


def clean(s, n=180):
    s = re.sub(r"\s+", " ", (s or "").replace("|", "/").replace("]==]", "]=]")).strip()
    return s[:n]


def fmt_xy(x, y):
    return f"{x:.1f},{y:.1f}"


class Fallback:
    """--measure-fallback only: steps of the reference file tools/measure/questie/Imported_Quests_<flavor>.lua indexed
    by quest id.  Never read by the build."""
    RE_LINE = re.compile(r"^([ACT]) .*?\|QID\|(\d+)\|")

    def __init__(self, fl, convert=None):
        self.fl = fl
        self.path = MEASURE_IN / f"Imported_Quests_{FALLBACK_OF.get(fl, fl)}.lua"
        self.q = defaultdict(lambda: {"A": None, "T": None, "C": {}})
        if not self.path.exists():
            raise SystemExit(f"--measure-fallback {fl}: {self.path.relative_to(ROOT)} is missing (tools/measure/README.md)")
        for ln in self.path.read_text(encoding="utf-8", errors="replace").splitlines():
            m = self.RE_LINE.match(ln)
            if not m:
                continue
            act, qid = m.group(1), int(m.group(2))
            mm = re.search(r"\|M\|([\d.,;]+)\|", ln)
            zz = re.search(r"\|Z\|([^|]+)\|", ln)
            if not (mm and zz):
                continue
            note = (re.search(r"\|N\|([^|]*)\|", ln) or [None, ""])[1]
            pts = mm.group(1)
            if convert:
                zid = re.match(r"\s*(\d+)", zz.group(1))
                pts = convert(int(zid.group(1)) if zid else None, pts)
            if fl == "retail":
                src = "Questie data" if "(Questie)" in note else "Blizzard data"
            else:
                src = "Questie data"
            rec = (pts, zz.group(1).strip(), src)
            if act == "C":
                qo = re.search(r"\|QO\|(\d+)\|", ln)
                self.q[qid]["C"].setdefault(int(qo.group(1)) if qo else 0, rec)
            elif self.q[qid][act] is None:
                self.q[qid][act] = rec

    def get(self, qid, act, qo=None):
        r = self.q.get(qid)
        if not r:
            return None
        if act != "C":
            return r[act]
        if qo is not None and qo in r["C"]:
            return r["C"][qo]
        if 0 in r["C"]:
            return r["C"][0]
        return r["C"][min(r["C"])] if r["C"] and qo is None else None


class QuestPOI:
    """the client's own quest map pins (retail QuestPOIBlob + QuestPOIPoint, Blizzard data via wago.tools): the turn-in
    area (ObjectiveIndex -1) and each objective's area (ObjectiveIndex n-1 for QO n; index 32 is the client's "next
    waypoint" hint, not an objective).  Shippable client facts.  Era, TBC and MoP Classic carry no quest pins (MoP's table holds only
    Archaeology dig sites), so this is retail only."""

    def __init__(self, fl, maps):
        self.q = defaultdict(dict)
        d = ROOT / "tools" / "db2" / fl
        # the client build the tables were read from (tools/db2/<flavor>/BUILD, written by the DB2 fetcher); every
        # file that ships a pin names it
        self.build = ((d / "BUILD").read_text(encoding="utf-8").strip() if (d / "BUILD").exists() else "") or "unknown"
        if not (d / "QuestPOIBlob.csv").exists() or not (d / "QuestPOIPoint.csv").exists():
            print(f"  note: tools/db2/{fl}/QuestPOIBlob.csv / QuestPOIPoint.csv missing - no client quest pins for {fl} "
                  "(fetch them: python3 tools/wiki/db2_fetch.py QuestPOIBlob QuestPOIPoint -- retail)")
            return
        blobs = [r for r in csv.DictReader((d / "QuestPOIBlob.csv").open(encoding="utf-8"))
                 if int(r["QuestID"] or 0) > 0 and int(r["ObjectiveIndex"]) != 32]
        want = {r["ID"] for r in blobs}
        pts = defaultdict(list)
        for r in csv.DictReader((d / "QuestPOIPoint.csv").open(encoding="utf-8")):
            if r["QuestPOIBlobID"] in want:
                pts[r["QuestPOIBlobID"]].append((float(r["X"]), float(r["Y"])))
        for b in sorted(blobs, key=lambda r: int(r["ID"])):
            m = maps.maps.get(int(b["UiMapID"]))
            p = pts.get(b["ID"])
            if not m or not p or not isinstance(m["w"], float) or not m["w"] or not m["h"]:
                continue
            wx, wy = sum(a for a, _ in p) / len(p), sum(c for _, c in p) / len(p)
            y01, x01 = (m["topX"] - wx) / m["h"], (m["leftY"] - wy) / m["w"]
            if not (-0.02 <= x01 <= 1.02 and -0.02 <= y01 <= 1.02):
                continue
            self.q[int(b["QuestID"])].setdefault(int(b["ObjectiveIndex"]), (int(b["UiMapID"]), fmt_xy(
                min(max(x01, 0.0), 1.0) * 100.0, min(max(y01, 0.0), 1.0) * 100.0)))

    def get(self, qid, oi):
        return self.q.get(qid, {}).get(oi)


def contributions_dir(arg=None, env=None):
    """the contributions folder to read: --contributions DIR, else $CR_CONTRIB, else the contributions folder of a
    sibling checkout of the data repository (../wow-completionist-data) when there is one; None when there is none.
    A folder asked for by name must exist."""
    env = os.environ if env is None else env
    for label, v in (("--contributions", arg), ("CR_CONTRIB", env.get("CR_CONTRIB"))):
        if v:
            d = Path(v).expanduser()
            if not d.is_dir():
                raise SystemExit(f"gen_wiki_guides: {label} {v}: no such folder")
            return d
    return CONTRIB_DEFAULT if CONTRIB_DEFAULT.is_dir() else None


def contrib_commit(folder, fl):
    """the data repository commit the areas of one client came from: HEAD of the git checkout whose top folder holds
    this contributions folder.  "unknown" when the folder is not that (a plain copy, a folder inside some other
    repository) or git cannot say; "<commit>-dirty" when areas/<fl>.json is not exactly what that commit holds.
    tools/package_release.py ships a contributed step only under a plain commit."""
    git = shutil.which("git", path="/usr/bin") or shutil.which("git")
    if not git:
        return "unknown"

    def run(*a):
        r = subprocess.run([git, "-C", str(folder), *a], capture_output=True, text=True, timeout=60)
        return r.stdout.strip() if r.returncode == 0 else None
    try:
        top = run("rev-parse", "--show-toplevel")
        if not top or (Path(top) / "contributions").resolve() != Path(folder).resolve():
            return "unknown"
        head = run("rev-parse", "HEAD")
        if not head or not re.fullmatch(r"[0-9a-f]{40,64}", head):
            return "unknown"
        rel = f"areas/{fl}.json"
        tracked, changed = run("ls-files", "--error-unmatch", "--", rel), run("status", "--porcelain", "--", rel)
        return head if tracked and changed == "" else head + "-dirty"
    except (OSError, subprocess.SubprocessError):
        return "unknown"


class Contributions:
    """the merged player contributions of one client: <folder>/areas/<flavor>.json, which tools/contrib.py of the open
    data repository (wow-completionist-data, CC BY-SA 4.0) builds from the texts players export with the add-on's
    Contribute box (docs/CONTRIBUTE.md).  Per step key it lists areas {map, x, y, r, weight, cells, contributors,
    confidence}.  Kept here: quest step keys (A:<quest>, T:<quest>, C:<quest>:<objective>), confidence "trusted" (a
    maintainer's own play) or "confirmed" (two or more players in the same place), on a map this client has and can
    place a point on; heaviest first.  The file is public input: every field is checked, and only a map id, positions
    and a player count ever reach a guide."""

    def __init__(self, folder, fl, maps):
        self.folder, self.fl = Path(folder), fl
        self.path = self.folder / "areas" / f"{fl}.json"
        self.areas = {}                 # key -> [{map, x, y, n (players), w (weight), confidence}], heaviest first
        self.skipped = Counter()        # why -> areas not used
        self.commit = None
        if not self.path.is_file():
            return
        try:
            doc = json.loads(self.path.read_text(encoding="utf-8"))
            areas = doc["areas"]
            if doc.get("flavor") != fl or not isinstance(areas, dict):
                raise ValueError(f"flavor {doc.get('flavor')!r}, areas {type(areas).__name__}")
        except (OSError, ValueError, KeyError, TypeError) as e:
            raise SystemExit(f"gen_wiki_guides: {self.path} is not the contributions areas file of {fl}: {e}")
        for key in sorted(areas):
            rows = areas[key] if isinstance(areas[key], list) else [None]
            if not CONTRIB_KEY.match(key):
                self.skipped["not a quest step"] += len(rows)
                continue
            keep = []
            for a in rows:
                why = self.check(a, maps)
                if why:
                    self.skipped[why] += 1
                else:
                    keep.append({"map": int(a["map"]), "x": float(a["x"]), "y": float(a["y"]), "n": int(a["contributors"]),
                                 "w": float(a["weight"]), "confidence": a["confidence"]})
            if keep:
                self.areas[key] = sorted(keep, key=lambda a: -a["w"])      # stable: the file's order breaks ties
        self.commit = contrib_commit(self.folder, fl)

    @staticmethod
    def check(a, maps):
        """why an area is not used, or None"""
        if not isinstance(a, dict) or a.get("confidence") not in CONTRIB_USED + ("single",):
            return "malformed"
        if a["confidence"] == "single":
            return "single"
        v = [a.get(k) for k in ("map", "x", "y", "contributors", "weight")]
        if not all(isinstance(n, (int, float)) and not isinstance(n, bool) and math.isfinite(n) for n in v):
            return "malformed"
        m, x, y, n, w = v
        if m != int(m) or n != int(n) or n < 1 or w <= 0 or not (0 < x < 100 and 0 < y < 100):
            return "malformed"
        mm = maps.maps.get(int(m))
        if not mm or not mm["w"] or not mm["h"]:
            return "unknown map"
        return None

    def points(self, key, limit=1):
        """the usable areas of a step, heaviest first: at most `limit`, all on the heaviest one's map (the points of a
        step share one map: |M|x,y;x,y|Z|map|), no point twice"""
        out, seen = [], set()
        for a in self.areas.get(key, ()):
            xy = fmt_xy(a["x"], a["y"])
            if (out and a["map"] != out[0]["map"]) or xy in seen:
                continue
            seen.add(xy)
            out.append(a)
            if len(out) >= limit:
                break
        return out

    @staticmethod
    def tag(ar):
        """(mapID, 'x,y;x,y') of points()"""
        return ar[0]["map"], ";".join(fmt_xy(a["x"], a["y"]) for a in ar)

    @staticmethod
    def note(ar):
        """the note suffix of a step that takes its point(s) from points(): the players behind the heaviest area"""
        n = ar[0]["n"]
        return (f" {CONTRIB_NOTE}, {n} player{'' if n == 1 else 's'}"
                + (f", {len(ar)} areas" if len(ar) > 1 else "") + ")")

    def far(self, key, mid, pts, yards):
        """(area, yards) when the heaviest usable area of this step on map `mid` lies more than CONTRIB_FAR_YD from
        every point of pts ('x,y;x,y' on that map); None when it is near, or when no area is on that map"""
        a = next((a for a in self.areas.get(key, ()) if a["map"] == mid), None)
        if not a:
            return None
        ds = []
        for pr in pts.split(";"):
            try:
                x, y = (float(v) for v in pr.split(","))
            except ValueError:
                continue
            d = yards(self.fl, mid, (x, y), (a["x"], a["y"]))
            if d is not None:
                ds.append(d)
        return (a, min(ds)) if ds and min(ds) > CONTRIB_FAR_YD else None

    def header(self):
        """the header line of a file that ships contributed points: the source, its licence and the commit"""
        return (f'-- Steps whose note says "{CONTRIB_NOTE}, ...)" take their map point from where players stood, not '
                f"from the wiki: merged player contributions, {CONTRIB_REPO} contributions/areas/{self.fl}.json "
                f"({CONTRIB_URL}, CC BY-SA 4.0), commit {self.commit} (see Guides/WIKI_DATA_LICENSE.md).")


def objective_key(qid, qo, use_qo, steps):
    """the contribution key of an objective step, as the add-on numbers it (Core/Contribute.lua KeyFor: "C:<quest>:" ..
    (tonumber(step.qo) or 0)): the step's |QO| number, or 0 for a step written without the tag.  Several untagged
    objective steps of one quest share key 0 in the add-on, so none of them can be told apart: no key (None)."""
    if use_qo:
        return f"C:{qid}:{qo}"
    return f"C:{qid}:0" if steps <= 1 else None


class Places:
    """an NPC or object page with no coordinates often names where it stands ("| location = [[Razor Hill]], [[Durotar]]").
    The first linked place that is not itself a map (a town, camp or building, not the zone) and whose own wiki page
    has a point stands in for it.  Read from the raw page cache (tools/wiki/fetch_wiki.py / fetch_titles.py)."""
    RAW = ROOT / "tools" / "wiki" / "cache" / "wiki_raw.sqlite"

    def __init__(self):
        self.raw = sqlite3.connect(f"file:{self.RAW}?mode=ro", uri=True) if self.RAW.exists() else None
        self.cache = {}

    # a {{Patch x.y.z|note=...}} line saying the place was made or moved in a later patch than the client's: its point
    # is not where the place is on that client (Lor'danel, "Added" at 4.0.3a, took over from Auberdine; "Valormok:
    # Subzone moved further south"; Grommash Hold "Remodeled and moved"; Shimmering Deep "Replaced the Shimmering
    # Flats").  A place that was only destroyed, rebuilt or "replaced by" something later still stood there before
    # (Brill, Stonewrought Dam, Misty Reed Post), and "Subzone added to existing area" names an area that was already
    # there (Pig and Whistle Tavern): those are kept.
    POST_CATA = re.compile(r"\{\{\s*patch\s*(\d+)\.\d+[^|}]*\|\s*note\s*=\s*(?:(?:area|subzone|town|zone)\s+)?"
                           r"(?:\w+\s+and\s+)?(?:added\b(?!\s+to\s+(?:an?\s+|the\s+)?existing)|moved\b|relocated\b|"
                           r"replaced\b(?!\s+by\b))", re.I)
    # an NPC page that says where the NPC stood before the Cataclysm ("Before the [[Cataclysm (event)|Cataclysm]], she was
    # located in the [[Valley of Strength]]"): its location field describes a later place.  Group 1 is the rest of that
    # sentence, whose links name the earlier place.  A caption such as "Trenton's model prior to the Cataclysm" is not
    # a move (no verb of place).
    MOVED = re.compile(r"(?:before|prior to)\s[^.\n]{0,40}?cataclysm[^.\n]{0,160}?\b(?:located|found|stood|standing|"
                       r"stationed|resided|lived|was in|was at|were in|were at)\b([^.\n]*)|\bpre-cataclysm\b", re.I)

    def text(self, page):
        if self.raw is None:
            return ""
        r = self.raw.execute("select wikitext from pages where title = ?", (page,)).fetchone()
        return (r[0] if r else "") or ""

    # the first patch major a client does not have: a place made or moved in it is not where that client has it
    NEWER = {"era": 2, "forever": 2, "tbc": 3, "mop": 6}

    def post_cata(self, page, fl="era"):
        """was this place made, moved or destroyed in a patch the client does not have (Lor'danel, 4.0.3, on Era)?"""
        lim = self.NEWER.get(fl)
        return lim is not None and any(int(m.group(1)) >= lim for m in self.POST_CATA.finditer(self.text(page)))

    # a link that names a landmark the NPC stood some way off from, not the place itself ("on an island northeast of
    # the [[Ravencrest Monument]]": 748 yd off on era).  "near the southern gates of [[Gadgetzan]]" and "just west of
    # [[Ameth'Aran]]" are at the place.
    BESIDE = re.compile(r"(?<!just )(?<!right )\b(?:(?:north|south|east|west)(?:east|west)?\s+of|across\s+from|opposite|"
                        r"beyond)\s+(?:the\s+)?$", re.I)

    def classic_links(self, page):
        """None when the page does not say its NPC stood elsewhere before the Cataclysm; else the links of the sentence
        that says where, in its order, leaving out a landmark the NPC only stood near (BESIDE); [] when it links no
        place"""
        m = self.MOVED.search(self.text(page))
        if not m:
            return None
        seg, out = m.group(1) or "", []
        for lk in re.finditer(r"\[\[[^\[\]]+\]\]", seg):
            if not self.BESIDE.search(seg[max(0, lk.start() - 40):lk.start()]):
                out += [t for t, _ in WT.links(lk.group(0))]
        return out

    def links(self, page):
        """the location field's links, most specific first"""
        if page in self.cache:
            return self.cache[page]
        out = []
        text = self.text(page)
        box = next(WT.find_templates(text, re.compile(r"npcbox|objectbox", re.I)), None)
        if box:
            out = [t for t, _ in WT.links(WT.split_params(box[3])[1].get("location", ""))]
        self.cache[page] = out
        return out


class Gen:
    def __init__(self, fallback=False, contributions=None, out=None):
        """contributions: the folder whose areas/<flavor>.json holds merged player contributions (None: read none;
        never read by --measure-fallback).  out: write everything into this folder instead of the checkout (see the
        module text)."""
        self.db = sqlite3.connect(f"file:{WIKI}?mode=ro", uri=True) if out else sqlite3.connect(WIKI)
        self.db.row_factory = sqlite3.Row
        self.atlas = wikimaps.Atlas()
        self.use_fallback = fallback
        self.contrib_dir = Path(contributions) if contributions and not fallback else None
        self.out_dir = Path(out) if out else None
        self.contrib_seen = {}              # client -> Contributions of its last run (main() reports it)
        self.titles = {r["title"]: (r["page_title"], r["kind"]) for r in self.db.execute("select * from titles")}
        self.npc_pts = defaultdict(list)
        # coordinates that already stood on their page before patch 4.0.3 are Classic-map numbers
        # (tools/wiki/fetch_coord_history.py, docs/WIKI_DATA_SPEC.md): they are read as "(Classic)" points
        marks = wikimaps.history_marks()
        if not marks:
            print("  note: tools/wiki/cache/coord_history.sqlite missing or empty - pre-4.0.3 Classic-map numbers are not "
                  "marked (Blasted Lands points move ~5.5 units on the Classic clients); run tools/wiki/fetch_coord_history.py")
        self.history_marked = 0
        for r in self.db.execute("select title, zone, x, y, source, badge, classic from npc_coords order by title, idx"):
            zone, classic = wikimaps.mark_classic(marks, r["title"], r["zone"], r["x"], r["y"]) if r["x"] is not None else (r["zone"], None)
            self.history_marked += classic is not None
            self.npc_pts[r["title"]].append((zone, r["x"], r["y"], r["source"], r["badge"], classic if classic is not None else r["classic"]))
        self.npc_classic = {r["title"]: r["page_classic"] for r in self.db.execute("select title, page_classic from npcs")}
        self.items = {r["title"]: (r["item_id"], json.loads(r["sources_json"] or "[]"))
                      for r in self.db.execute("select * from items")}
        cols = [c[1] for c in self.db.execute("pragma table_info(items)")]
        self.item_pts = {r["title"]: json.loads(r["coords_json"] or "[]")
                         for r in self.db.execute("select * from items")} if "coords_json" in cols else {}
        self.item_by_id = {}
        for t, (iid, _src) in self.items.items():
            if iid and (iid not in self.item_by_id or "(item)" in t):
                self.item_by_id[iid] = t
        self.objs = defaultdict(list)
        for r in self.db.execute("select * from quest_objectives order by quest_id, page_title, idx"):
            self.objs[(r["quest_id"], r["page_title"])].append(dict(r))
        self.rows = [dict(r) for r in self.db.execute("select * from quests")]
        self.qv2 = {}
        for fl in FLAVORS:
            p = ROOT / "tools" / "db2" / fl / "QuestV2.csv"
            if not p.exists():
                sys.exit(f"missing {p} - run tools/wiki/fetch_db2.py")
            self.qv2[fl] = {int(r["ID"]) for r in csv.DictReader(p.open(encoding="utf-8"))}
        # quest -> [(item id, item name)] that start it, per client (Blizzard ItemSparse.StartQuestID)
        self.starter = {}
        for fl in FLAVORS:
            p = ROOT / "tools" / "db2" / fl / "ItemSparse.csv"
            self.starter[fl] = defaultdict(list)
            if p.exists():
                for r in csv.DictReader(p.open(encoding="utf-8")):
                    q = int(r.get("StartQuestID") or 0)
                    if q:
                        self.starter[fl][q].append((int(r["ID"]), r.get("Display_lang") or ""))
        self.qobj = Counter()
        p = ROOT / "tools" / "db2" / "retail" / "QuestObjective.csv"
        if p.exists():
            for r in csv.DictReader(p.open(encoding="utf-8")):
                self.qobj[int(r["QuestID"])] += 1
        self.conflicts = []
        self.place_cache = {}
        self.clean_pts = {}
        self.subzone_dropped = []
        self.places = Places()
        self.place_rejected = Counter()     # (client, why) -> place-page points not used (place_coords)
        self.moved_seen = set()             # (client, NPC page) already counted by place_links
        self.place_zone_cache = {}

    # ---- locations ---------------------------------------------------------------------------------
    def era_to_forever(self, mid, pts):
        """'x,y;x,y' (percent) on an Era map -> the same places on the Forever map (only reshaped maps change)"""
        a = self.atlas.sets["era"].maps.get(mid) if mid else None
        b = self.atlas.sets["forever"].maps.get(mid) if mid else None
        if not a or not b or not isinstance(a.get("w"), float) or not isinstance(b.get("w"), float):
            return pts
        if max(abs(a[k] - b[k]) for k in ("topX", "leftY", "w", "h")) < 0.5:
            return pts
        out = []
        for pr in pts.split(";"):
            try:
                x, y = (float(v) / 100.0 for v in pr.split(","))
            except ValueError:
                out.append(pr)
                continue
            wx, wy = a["topX"] - y * a["h"], a["leftY"] - x * a["w"]
            out.append(fmt_xy((b["leftY"] - wy) / b["w"] * 100.0, (b["topX"] - wx) / b["h"] * 100.0))
        return ";".join(out)

    def resolve_title(self, t):
        if not t:
            return None, None
        r = self.titles.get(t)
        return r if r else (t, None)

    def place(self, zone, x, y, fl, classic, added):
        k = (zone, x, y, fl, classic, added)
        if k not in self.place_cache:
            self.place_cache[k] = self.atlas.place(zone, x, y, fl, classic, added)
        return self.place_cache[k]

    def coords_list(self, pts, fl, classic, added, home_name=None):
        """[(zone, x, y)] wiki points -> (mapID, 'x,y;x,y') on the client, all points on one map"""
        placed = []
        for z, x, y in pts:
            r = self.place(z, x, y, fl, classic, added)
            if r:
                placed.append(r)
        if not placed:
            return None
        if home_name:
            hn = wikimaps.norm(home_name)
            inz = [p for p in placed if wikimaps.norm(self.atlas.sets[fl].maps[p[0]]["name"]) == hn]
            if inz:
                placed = inz
        mid = placed[0][0]
        same = [p for p in placed if p[0] == mid][:4]
        return mid, ";".join(fmt_xy(p[1], p[2]) for p in same)

    def page_rows(self, title):
        """the page's coordinate rows, with a subzone row that its own parent-zone row contradicts (same expansion badge,
        same page version; wikimaps.Atlas.subzone_conflict) moved onto the parent row's point.  The row stays, under the
        subzone's name, because the choice between rows prefers the guide's own zone: dropping it would let a later
        expansion's row win (Gornek in Spires of Arak for a Valley of Trials quest).  Off the subzone map, it goes."""
        if title in self.clean_pts:
            return self.clean_pts[title]
        pts = self.npc_pts.get(title) or []
        out = []
        for a in pts:
            row = a
            for b in pts:
                if a is not b and a[4] == b[4] and a[5] == b[5] and self.atlas.subzone_conflict(a[:3], b[:3], bool(a[5])):
                    moved = self.atlas.parent_point_on_sub(a[0], b[:3], bool(a[5]))
                    row = (a[0], moved[0], moved[1]) + a[3:] if moved else None
                    self.subzone_dropped.append((title,) + a[:3])
                    break
            if row:
                out.append(row)
        self.clean_pts[title] = out
        return out

    @staticmethod
    def foreign(zone, fl):
        """is a wiki coordinate written for a game this client is not?  '(Forever)' points are WoW Forever's own (Zephras
        Isle's portal stands in Alterac Mountains only there); Season of Discovery is on no client this addon builds."""
        z = (zone or "").lower()
        return ("(forever)" in z and fl != "forever") or "(season of discovery)" in z

    def page_points(self, title, fl, home_name, own_only=False):
        """best coordinates on an NPC/object/place page for this client.  own_only (a place page standing in for an NPC):
        only the page's own point counts, from its infobox, {{Npclocations}} or lead sentence.  A coordinate in a
        section of the page (portals, quests, rewards, notes, inhabitants) is something else at that place, not the
        place, and a coordinate written for another game (foreign) is never used."""
        pts = self.page_rows(title)
        if own_only:
            pts = [p for p in pts if p[3] in ("location", "npclocations", "lead") and not self.foreign(p[0], fl)]
        if not pts:
            return [], False
        e = EXP[fl][0]

        def score(p):
            zone, x, y, src, badge, classic = p
            s = 4 if self.foreign(zone, fl) else 0
            # A point on a map this client does not have (a retail subzone map such as Valley of Trials on Classic, or a
            # retail-only zone) ranks after a point on a map it does have.  A subzone point is only usable through
            # world-coordinate conversion, so an entry for the zone itself is better.
            if self.atlas.sets[fl].resolve(zone) is None:
                s += 1.5
            if fl in CLASSICISH:
                s += 0 if classic else 2
                if fl == "tbc" and "(burning crusade)" in zone.lower():
                    s -= 1
            else:
                s += 2 if classic else 0
            if badge:
                s += 0 if badge <= e else 3
                s += (e - badge) * 0.05 if badge <= e else 0
            s += {"location": 0, "npclocations": 0.2, "lead": 0.5}.get(src, 1.0)
            if home_name and wikimaps.norm(re.sub(r"\s*\([^()]*\)$", "", zone)) == wikimaps.norm(home_name):
                s -= 0.5
            return s
        ranked = sorted(pts, key=score)
        best = ranked[0]
        group = [p for p in ranked if p[0] == best[0] and p[5] == best[5]]
        return [(p[0], p[1], p[2]) for p in group], self.exact(fl, best[5], best[4])

    @staticmethod
    def exact(fl, classic, badge=0):
        """is a wiki point written for this client's version?  Retail: always.  Classic clients: a point on a
        Classic page / Classic zone, or an {{Npclocations}} row badged with an expansion the client has."""
        if fl == "retail":
            return True
        e = EXP[fl][0]
        if fl in CLASSICISH:
            return bool(classic) or (0 < (badge or 0) <= e)
        return (not classic) and 0 < (badge or 0) <= e

    def zone_page(self, page, fl):
        """is this the wiki page of a zone, city or continent?  Its {{co}} rows are neighbours, entrances and landmarks
        ("Hellfire Peninsula" lists the Exodar portal, "Silithus" the road to Un'Goro Crater), never the zone itself"""
        for S in (self.atlas.sets[fl], self.atlas.sets["retail"]):
            mid = S.resolve(page)
            if mid is not None and S.maps[mid]["type"] <= 3:
                return True
        return False

    def topic_page(self, page):
        """a 'place' page whose every {{co}} row stands in a body section: a profession, class, holiday, expansion or
        system article ("Tailoring", "Noblegarden", "Pet tamer") listing other places, not a place an item drops in"""
        pts = self.npc_pts.get(page) or []
        return bool(pts) and all(str(p[3]).startswith("body:") for p in pts)

    def entity_coords(self, title, fl, added, home_name, depth=0, places=False, ref_maps=()):
        """(mapID, 'x,y', page, exact, via) for a linked page; items follow their drop sources (depth 1).  A zone's page
        gives no point (a zone-level answer, item_zone), nor does a topic page reached as an item's source.  With
        places=True a page with no point of its own takes the point of the place its location field names first (via =
        that place), when that point lies in one of ref_maps (see place_coords)."""
        page, kind = self.resolve_title(title)
        if not page:
            return None
        if kind in ("place", None) and (self.zone_page(page, fl) or (depth and self.topic_page(page))):
            return None
        if kind in ("npc", "object", "place") or page in self.npc_pts:
            pts, ex = self.page_points(page, fl, home_name)
            if pts:
                r = self.coords_list(pts, fl, bool(self.npc_classic.get(page)), added, home_name)
                if r:
                    return r[0], r[1], page, ex, ""
            elif places and kind in ("npc", "object"):
                r = self.place_coords(page, fl, added, home_name, ref_maps)
                if r:
                    return r
        if depth == 0 and page in self.items:
            pts = [(z, x, y) for x, y, z in self.item_pts.get(page, []) if z]
            if pts:
                r = self.coords_list(pts, fl, False, added, home_name)
                if r:
                    return r[0], r[1], page, fl == "retail", ""
            for src in self.items[page][1]:
                r = self.entity_coords(src, fl, added, home_name, 1, places, ref_maps)
                if r:
                    return r
        return None

    def far_from_fallback(self, maps, c, f, limit=300.0):
        """--measure-fallback: is the wiki point c = (mapID, 'x,y;...') more than `limit` yd from the fallback record f =
        ('x,y;...', 'mapID; name', source), or on another continent?"""
        try:
            fz = int(f[1].split(";")[0])
            fx, fy = (float(v) for v in f[0].split(";")[0].split(","))
            wx, wy = (float(v) for v in c[1].split(";")[0].split(","))
        except (ValueError, TypeError, IndexError):
            return False
        a, b = maps.to_world(c[0], wx, wy), maps.to_world(fz, fx, fy)
        if not a or not b or a[0] != b[0]:
            return True
        return ((a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2) ** 0.5 > limit

    def item_zone(self, page, fl, added):
        """a zone-only place for an item page whose sources name a zone but give no point: (mapID, zone name) or None"""
        maps = self.atlas.sets[fl]
        for src in self.items.get(page, (None, []))[1]:
            t, kind = self.resolve_title(src)
            for name in (t, src):
                mid = maps.resolve(name, added) if name else None
                if mid is not None and maps.maps[mid]["type"] in (3, 4, 5, 6):
                    return mid
        return None

    def place_coords(self, page, fl, added, home_name, ref_maps=()):
        """the point of the first place named in an NPC/object page's location field (place_links) that is not a map
        itself.  Only the place page's own point counts (page_points own_only: not a portal, quest or NPC listed on it,
        not a coordinate written for another game), a place made or moved in a later patch than the client's is
        skipped, and the point must lie in one of ref_maps (the zone maps the NPC page names; agree()), so a place of
        the same name elsewhere never moves the step to another zone.  With no reference map the place link is the
        page's own word and the point is used (resolve_pending counts it when it lies outside the quest's zone)."""
        maps = self.atlas.sets[fl]
        links = self.place_links(page, fl)
        zone = links[-1] if len(links) > 1 else None
        for ln in links[:-1] if zone else links:
            pg, kind = self.resolve_title(ln)
            if not pg or maps.resolve(pg) is not None or self.atlas.sets["retail"].resolve(pg) is not None:
                continue    # a zone, city or subzone map: that is a zone-level answer, not a place
            if self.places.post_cata(pg, fl):
                self.place_rejected[(fl, "place made or moved in a later patch")] += 1
                continue
            pts, ex = self.page_points(pg, fl, zone or home_name, own_only=True)
            if not pts:
                continue
            if zone and wikimaps.norm(wikimaps.base_zone(pts[0][0])) != wikimaps.norm(zone) and \
                    maps.resolve(pts[0][0]) != maps.resolve(zone):
                continue    # the place page points into another zone than the NPC page names
            r = self.coords_list(pts, fl, bool(self.npc_classic.get(pg)), added, zone or home_name)
            if not r:
                break
            if ref_maps and not any(self.agree(fl, r[0], m) for m in ref_maps):
                self.place_rejected[(fl, "outside the NPC's or the quest's maps")] += 1
                continue
            return r[0], r[1], page, ex, pg
        return None

    def place_links(self, page, fl):
        """the links that say where an NPC/object page's subject stands on this client, most specific first: the
        location field; on the Classic clients, when the page says the NPC stood elsewhere before the Cataclysm, that
        sentence instead, up to its first link that is a zone map (only its first link when none is).  Shadowmage
        Vivian Lagrave stands in the Undercity now and "was located at [[Kargath]], [[Badlands]]" before; a page that
        says she moved but links no place gives nothing, so the step keeps the quest's zone."""
        if fl in CLASSICISH:
            old = self.places.classic_links(page)
            if old is not None:
                S, out = self.atlas.sets[fl], []
                for t in old:
                    out.append(t)
                    m = S.resolve(t)
                    if m is not None and S.maps[m]["type"] == 3:
                        break
                else:
                    out = out[:1]
                if (fl, page) not in self.moved_seen:
                    self.moved_seen.add((fl, page))
                    self.place_rejected[(fl, "npc moved at the Cataclysm: its earlier place used" if out else
                                         "npc moved at the Cataclysm: no earlier place linked")] += 1
                return out
        return self.places.links(page)

    def agree(self, fl, a, b):
        """do two maps name the same area: the same map, one inside the other, or the same zone (MapSet.home)"""
        S = self.atlas.sets[fl]
        return a == b or S.is_ancestor(a, b) or S.is_ancestor(b, a) or S.home(a) == S.home(b)

    def entity_maps(self, title, fl, added, draenor=False, seen=None):
        """the zone-type maps (UiMap type 3 or more) on this client that a linked page names: the page itself when it is
        a place that is a map (an objective "Travel to Dalaran"), else the links of an NPC/object page's location
        field (place_links), in the page's order (most specific first).  When those links name no map at all, a linked
        place counts as the zone its own page says it lies in (place_zone: "[[Kargath]]" is in the Badlands); a map the
        NPC page names always wins over that guess (A'dal's "[[Terrace of Light]], [[Shattrath City]]": the Terrace's
        page names the Isle of Quel'Danas first).  Items follow their drop sources."""
        page, kind = self.resolve_title(title)
        if not page:
            return []
        S = self.atlas.sets[fl]
        out = []
        if kind not in ("npc", "object", "item"):
            own = S.resolve(page, added, draenor)
            if own is not None and S.maps[own]["type"] >= 3:
                return [own]
        links = self.place_links(page, fl)
        for ln in links:
            m = S.resolve(ln, added, draenor)
            if m is not None and S.maps[m]["type"] >= 3 and m not in out:
                out.append(m)
        if not out:
            for ln in links:
                pg, k = self.resolve_title(ln)
                m = self.place_zone(pg, fl, added, draenor) if pg and k not in ("npc", "object", "item") else None
                if m is not None and m not in out:
                    out.append(m)
        if not out and page in self.items:
            # item pages name each other as sources ("dropped by <container>", "contains <item>"): never walk a page twice
            seen = seen if seen is not None else set()
            seen.add(page)
            for src in self.items[page][1][:3]:
                sp = self.resolve_title(src)[0]
                if not sp or sp in seen:
                    continue
                for m in self.entity_maps(src, fl, added, draenor, seen):
                    if m not in out:
                        out.append(m)
        return out

    def place_zone(self, page, fl, added=None, draenor=False):
        """the zone map a place page that is not a map itself says it lies in: the first link of its lead (infobox
        included) that is a zone map on this client ("Kargath is a Horde outpost in the [[Badlands]]"; "The Valley of
        Strength ... [[Orgrimmar]]"); None when it links none.  The page's words, not the map its own point lands on,
        so place_coords can check that point against it."""
        k = (page, fl, added, draenor)
        if k not in self.place_zone_cache:
            S, z = self.atlas.sets[fl], None
            for ln, _ in WT.links(WT.sections(self.places.text(page)).get("", "")):
                m = S.resolve(ln, added, draenor)
                if m is not None and S.maps[m]["type"] == 3:
                    z = m
                    break
            self.place_zone_cache[k] = z
        return self.place_zone_cache[k]

    # Classic clients: a lead sentence that says the subject is at a place ("located in [[Southshore]]"); one that names
    # a place for another reason does not ("agents of his that he sent to the [[Arathi Highlands]]")
    PRESENT = re.compile(r"\b(?:present|found|located|seen|appears?|stands?|standing|stationed|resides?|lives?|encountered|"
                         r"waits?|waiting|stays?|(?:is|are|was|were)\s+(?:in|at|on|inside|within|outside|near)|"
                         r"(?:can|may|could)\s+be)\b", re.I)

    def lead_maps(self, title, fl, added, draenor=False):
        """the zone maps an NPC/object page's lead text links outside its infobox ("He is also present in ... [[Nazmir]]").
        On the Classic clients (era, tbc, forever), where an NPC stands in one place, only a sentence of an NPC page
        that says the subject is there counts (PRESENT): Archmage Malin "sent [agents] to the [[Arathi Highlands]]" and stands in
        Stormwind.  And a page that says its NPC stood elsewhere before the Cataclysm gives none there: its lead
        describes the later place (Shadowmage Vivian Lagrave is "located in ... [[Blackrock Depths]]" now and was in
        Kargath then; place_links).  MoP and Retail keep every lead link: their NPCs reappear across expansions and the
        location field lists only some of the places (tried 2026-11-12: the sentence rule changed 60 Retail step lines,
        many to a wrong zone; Garrosh Hellscream's Borean Tundra quests went to the Sanctum of Domination)."""
        page, kind = self.resolve_title(title)
        if not page:
            return []
        # an NPC stands somewhere; an item or object page's lead names where the thing is found in other words, so every
        # link of it counts (The Third Fleet's mead is bought in the Wetlands)
        classic = fl in CLASSICISH and kind == "npc"
        if classic and self.places.classic_links(page) is not None:
            return []
        S = self.atlas.sets[fl]
        lead = re.sub(r"\{\{\s*(?:npcbox|objectbox).*?\n\s*\}\}", "", WT.sections(self.places.text(page)).get("", ""),
                      flags=re.S | re.I)
        out = []
        for sentence in (re.split(r"(?<=[.!?])\s+|\n+", lead) if classic else [lead]):
            if classic and not self.PRESENT.search(sentence):
                continue
            for ln, _ in WT.links(sentence):
                m = S.resolve(ln, added, draenor)
                if m is not None and S.maps[m]["type"] >= 3 and m not in out:
                    out.append(m)
        return out

    def zone_choice(self, fl, emaps, zmid, refs, lead=()):
        """the map a step with no point names (|Z| only).  The NPC/object page's own location field outranks the
        quest-log category: the category is where the quest is filed, not where its giver stands (Magistrate Henry
        Maleb is filed under Alterac Mountains and stands in Southshore; In Defense of Frostwolf is filed under the
        battleground and given in Orgrimmar).  The category wins when the page agrees with it (agree()): a location
        map in it (a page map inside it is the more precise answer), or else a map the page's lead links (lead_maps:
        Patch's location field names Azshara and the Twilight Highlands, his lead adds that he is "also present ... in
        [[Nazmir]]", where the quest is filed).  Among several page maps the one that agrees with the quest's located
        steps (refs) wins, then a zone map over a dungeon or micro map.  With no page map: the category, else the first
        located step's map."""
        S = self.atlas.sets[fl]
        if emaps:
            if zmid is not None:
                for m in emaps:
                    if self.agree(fl, m, zmid):
                        return m if S.is_ancestor(zmid, m) else zmid
                if any(self.agree(fl, m, zmid) for m in lead):
                    return zmid
            for m in emaps:
                if any(self.agree(fl, m, r) for r in refs):
                    return m
            return sorted(emaps, key=lambda m: S.maps[m]["type"] != 3)[0]
        if zmid is not None:
            return zmid
        return refs[0] if refs else None

    # ---- one client ---------------------------------------------------------------------------------
    def run(self, fl):
        maps = self.atlas.sets[fl]
        fb = Fallback(fl, self.era_to_forever if fl == "forever" else None) if self.use_fallback else None
        poi = QuestPOI(fl, maps) if fl == "retail" else None
        contrib = Contributions(self.contrib_dir, fl, maps) if self.contrib_dir else None
        if contrib is not None and not contrib.areas:
            self.contrib_seen[fl], contrib = contrib, None      # no areas file, or nothing usable in it
        elif contrib is not None:
            self.contrib_seen[fl] = contrib
        st = Counter()
        skip = []
        by_id = defaultdict(list)
        all_ids = set()
        for r in self.rows:
            all_ids.add(r["id"])
            ok, why = membership(r, fl, self.qv2)
            if ok:
                by_id[r["id"]].append(r)
            else:
                skip.append((fl, r["id"], r["page_title"], why))
                if why == "" or (why == "not in QuestV2" and fl == "era" and not r["beta"] and not r["forever"]
                                 and not r["sod"] and pkey(r["added_patch"]) and pkey(r["added_patch"]) <= (1, 12, 9)
                                 and not r["removed_patch"] and not (r["variant"] or "").lower() in VARIANT_FOR):
                    self.conflicts.append((fl, r["id"], "membership", "added <= 1.12, not removed", "not in QuestV2",
                                           r["page_title"], r["revid"], "wiki says vanilla quest; client lacks it"))
        st["wiki_quest_ids"] = len(all_ids)
        chosen = {}
        pref = VARIANT_PREF[fl]
        for qid, rs in by_id.items():
            def rank(r):
                v = (r["variant"] or "").lower()
                return (pref.index(v) if v in pref else len(pref), -(r["revid"] or 0))
            chosen[qid] = sorted(rs, key=rank)[0]
        for qid, r in list(chosen.items()):
            if SKIP_TYPES.search(r["qtype"] or ""):
                skip.append((fl, qid, r["page_title"], f"type {r['qtype']}"))
                del chosen[qid]
        st["assigned"] = len(chosen)
        gaps = sorted(self.qv2[fl] - all_ids)
        st["db2_only_gap"] = len(gaps)

        # chains: previous (any of) + reverse of next
        pre = defaultdict(set)
        for qid, r in chosen.items():
            for p in (r["prev_ids"] or "").split(","):
                if p and int(p) in chosen and int(p) != qid:
                    pre[qid].add(int(p))
        for qid, r in chosen.items():
            for n in (r["next_ids"] or "").split(","):
                if n and int(n) in chosen and int(n) != qid and not chosen[int(n)]["prev_ids"]:
                    pre[int(n)].add(qid)

        guides = defaultdict(list)
        steps_out = {}
        for qid, r in chosen.items():
            added = pkey(r["added_patch"])
            classic_q = bool(r["page_classic"])
            zone_name = r["zone"] or r["category"] or ""
            # a Warlords of Draenor quest's zone is Draenor's map, not the Outland zone of the same name
            draenor_q = "alternate universe" in zone_name.lower() or (added is not None and (6, 0, 0) <= added < (7, 0, 0))
            zmid = maps.resolve(zone_name, added, draenor_q) if zone_name else None
            home_name = maps.maps[zmid]["name"] if zmid else zone_name
            name = clean(r["name"] or r["page_title"], 120)
            gate = ""
            if r["faction"] in ("Alliance", "Horde"):
                gate += f"FACTION|{r['faction']}|"
            if r["races"]:
                gate += f"R|{clean(r['races'], 80).replace(' and ', ',')}|"
            if r["classes"]:
                gate += f"C|{clean(r['classes'], 60)}|"
            lvl = r["levelreq"]
            if lvl and lvl > 1:
                gate += f"LVL|{lvl}|"
            lines = []          # step text, or a dict for a step resolve_pending() fills in
            first_map = None

            page_exact = self.exact(fl, classic_q, 0) or (
                fl == "mop" and (r["variant"] or "").lower() in VARIANT_FOR and "mop" in VARIANT_FOR[(r["variant"] or "").lower()])

            def versioned(c, ex, act, qo=None):
                """the build keeps every wiki point.  --measure-fallback: a wiki point written for another version (the
                wiki is retail-first) that the reference file puts more than 300 yd away is recorded and replaced"""
                if ex or not fb:
                    return (c, "", "wiki")
                f = fb.get(qid, act, qo)
                if not f:
                    return (c, "", "wiki")
                try:
                    fz = int(f[1].split(";")[0])
                    fx, fy = (float(v) for v in f[0].split(";")[0].split(","))
                    wx, wy = (float(v) for v in c[1].split(";")[0].split(","))
                except ValueError:
                    return (c, "", "wiki")
                a = maps.to_world(c[0], wx, wy)
                b = maps.to_world(fz, fx, fy)
                if a and b and a[0] == b[0]:
                    d = ((a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2) ** 0.5
                    if d <= 300:
                        return (c, "", "wiki")
                else:
                    d = -1
                self.conflicts.append((fl, qid, f"{act}_xy_version", f"{c[0]}:{c[1]}", f"{f[1]}:{f[0]}",
                                       r["page_title"], r["revid"],
                                       f"wiki point is for another game version; {d:.0f} yd from client data"
                                       if d >= 0 else "wiki point is for another game version; other continent"))
                return (("Z", f), f" (location: {f[2]}; the wiki lists another version's position)", "fallback")

            def item_point_ok(e, act, qo=None):
                """a point an item page gave (its own {{co}} or a drop source's page) for this step: always kept by the
                build.  --measure-fallback: it gives way to the reference point for the step when the two are more than
                300 yd apart or on different continents (counted in st).  (Checking it against the quest's own zone was tried and dropped:
                many of a sample of 32 such points were right, e.g. Frozen Ectoplasm from Winterspring for a Tanaris
                quest.)"""
                f = fb.get(qid, act, qo) if fb else None
                if f and self.far_from_fallback(maps, (e[0], e[1]), f):
                    st["item_points_far_from_fallback"] += 1
                    return False
                return True

            def contrib_check(act, key, c):
                """a wiki point against the contributed area of the same step: on the same map and more than 100 yd
                apart, it is logged as a lead for fixing the wiki.  The guide keeps the wiki point."""
                hit = contrib.far(key, c[0], c[1], self.atlas.yards) if (contrib and key and c[0] != "Z") else None
                if hit:
                    a, yd = hit
                    self.conflicts.append((fl, qid, f"{act}_xy_contrib", f"{c[0]}:{c[1]}",
                                           f"{a['map']}:{fmt_xy(a['x'], a['y'])}", r["page_title"], r["revid"],
                                           f"{yd:.0f} yd from the player-contributed area of {key} ({a['n']} player"
                                           f"{'' if a['n'] == 1 else 's'}, {a['confidence']})"))
                    st["contrib_conflicts"] += 1

            def loc_tag(kind, ent_list, act, qo=None):
                """-> (M/Z text, note suffix, source) for an A/T step.  Order: the wiki's own point, the client's quest
                pin (retail), the heaviest area players contributed, the reference file (--measure-fallback only, which
                reads no contributions).  The wiki place page and the zone-level answer come after every step of the
                quest has been tried (resolve_pending)."""
                for e in ent_list:
                    if e.get("coords"):
                        c = self.coords_list([(x[2], x[0], x[1]) for x in e["coords"]], fl, classic_q, added, home_name)
                        if c:
                            return versioned(c, page_exact, act, qo)
                for e in ent_list:
                    if e.get("title"):
                        c = self.entity_coords(e["title"], fl, added, home_name)
                        if c and self.resolve_title(e["title"])[0] in self.items:
                            # an item page: the point is where the item is found or dropped; say which page gave it
                            if not item_point_ok(c, act, qo):
                                continue
                            v = versioned((c[0], c[1]), c[3], act, qo)
                            return (v[0], v[1] + f" (point: the wiki's {clean(c[2], 60)} page)", v[2]) if v[2] == "wiki" else v
                        if c:
                            return versioned((c[0], c[1]), c[3], act, qo)
                if poi:
                    # the turn-in pin is the ender's area; it stands for the giver only when the wiki names the same NPC
                    same = {e.get("title") for e in starts if e.get("title")} == {e.get("title") for e in ends if e.get("title")}
                    pin = poi.get(qid, -1) if (act == "T" or same) else None
                    if pin:
                        return pin, " (location: Blizzard quest POI, the turn-in area)", "poi"
                if contrib:
                    ar = contrib.points(f"{act}:{qid}")
                    if ar:
                        return contrib.tag(ar), contrib.note(ar), "contrib"
                if fb:
                    f = fb.get(qid, act, qo)
                    if f:
                        return ("Z", f), f" (location: {f[2]})", "fallback"
                return None, "", "none"

            def zone_only(text_head, text_tail, mid):
                """a step the wiki gives no point for still names a zone (the router takes you there): the zone the NPC
                page names, else the quest's (zone_choice)"""
                if mid is None or mid not in maps.maps:
                    return None
                zn = maps.maps[mid]["name"]
                return f"{text_head}Z|{mid}; {zn}|{text_tail} No coordinates on the wiki; the quest is in {clean(zn, 60)}.|"

            def mz(c):
                if c[0] == "Z":
                    f = c[1]
                    return f"M|{f[0]}|Z|{f[1]}|"
                return f"M|{c[1]}|Z|{c[0]}; {maps.maps[c[0]]['name']}|"

            def pending(head, tail, ents):
                """a step with no wiki, quest-pin or fallback point: resolved by resolve_pending once the quest's other
                steps are known"""
                lines.append({"head": head, "tail": tail, "ents": [e for e in ents if e.get("title")]})

            def resolve_pending():
                """place page, then zone, for the steps pending() kept back.  The NPC/object page names the reference
                maps (entity_maps); a place point must lie in one of them.  The zone-level step takes zone_choice(), which
                weighs those maps against the quest's zone and the maps of its located steps (refs)."""
                refs = []
                for ln in lines:
                    if isinstance(ln, str) and "|M|" in ln:
                        m = re.search(r"\|Z\|(\d+);", ln)
                        if m and int(m.group(1)) not in refs:
                            refs.append(int(m.group(1)))
                for i, p in enumerate(lines):
                    if isinstance(p, str):
                        continue
                    emaps = []
                    for e in p["ents"]:
                        for m in self.entity_maps(e["title"], fl, added, draenor_q):
                            if m not in emaps:
                                emaps.append(m)
                    # Only the maps the NPC/object page names (its location field, or the zone its linked place's own
                    # page names) can overrule the place it links; the quest-log category cannot.  Checked against the
                    # category instead, 16 era place points were rejected and the category zone was wrong for all 16
                    # (class quests filed under some zone, givers who stand a zone away), while 9 of the points were
                    # 43-297 yd from where the quest is done (measured against the local reference, measurement only;
                    # docs/WIKI_DATA_SPEC.md).  A point with no reference map that lies outside the category and every
                    # located step of the quest is counted (place_off_category).
                    ref_maps = emaps
                    c = None
                    for e in p["ents"]:
                        c = self.entity_coords(e["title"], fl, added, home_name, places=True, ref_maps=ref_maps)
                        if c and c[4]:
                            break
                        c = None
                    if c:
                        lines[i] = (f"{p['head']}{mz((c[0], c[1]))}{p['tail']} (location: the wiki's {clean(c[4], 60)} "
                                    f"page; {clean(c[2], 60)}'s own page has no point)|")
                        st["steps_place"] += 1
                        if not emaps:
                            others = ([zmid] if zmid is not None else []) + refs
                            if not others:
                                st["place_unchecked"] += 1
                            elif not any(self.agree(fl, c[0], m) for m in others):
                                st["place_off_category"] += 1
                        continue
                    lead = [m for e in p["ents"] for m in self.lead_maps(e["title"], fl, added, draenor_q)] if emaps else []
                    mid = self.zone_choice(fl, emaps, zmid, refs, lead)
                    zl = zone_only(p["head"], p["tail"], mid)
                    lines[i] = zl or f"{p['head']}{p['tail']} No coordinates on the wiki.|"
                    st["steps_zone" if zl else "steps_none"] += 1
                    if zl and emaps and mid != zmid:
                        st["zone_from_npc_page"] += 1

            starts = json.loads(r["start_json"] or "[]")
            ends = json.loads(r["end_json"] or "[]") or starts
            if r["faction"] in ("Alliance", "Horde"):
                starts = [e for e in starts if e.get("faction") in ("", r["faction"])] or starts
                ends = [e for e in ends if e.get("faction") in ("", r["faction"])] or ends
            ptag = f"PRE|{';'.join(str(p) for p in sorted(pre[qid]))}|" if pre.get(qid) else ""
            # A
            auto = bool(starts) and all(e.get("auto") for e in starts)
            c, suf, src = loc_tag("start", starts, "A")
            who = next((clean(e.get("label") or e.get("title"), 60) for e in starts if e.get("title")), "")
            item = r["item_start"] if r["item_start"] and self.resolve_title(r["item_start"])[0] in self.items else None
            # Blizzard says an item starts this quest: the accept is where that item is obtained
            starters = self.starter.get(fl, {}).get(qid, [])
            utag, izone, also = "", None, None
            if starters:
                st["item_quests"] += 1
                utag = f"U|{starters[0][0]}|"
                page = item and self.resolve_title(item)[0]
                if not page:
                    # by item id, else the questbox start link when it is the item's page ("Gronnling Scale")
                    page = next((self.item_by_id[i] for i, _ in starters if i in self.item_by_id), None) or next(
                        (self.resolve_title(e["title"])[0] for e in starts
                         if e.get("title") and self.resolve_title(e["title"])[0] in self.items), None)
                    if not who or not c or src == "contrib":
                        # (a contributed point changes no wording: the note is what it is without contributions)
                        item = page or starters[0][1] or None
                    else:
                        # the wiki names a giver and has its point: keep it, and say the item starts it too
                        also = re.sub(r"\s*\(item\)$", "", page or starters[0][1] or "") or None
                # (the wiki's item page outranks a contributed accept: the wiki's own point comes first)
                if page and (not c or src in ("fallback", "contrib")):
                    e = self.entity_coords(page, fl, added, home_name)
                    if e and not item_point_ok(e, "A"):
                        e = None    # --measure-fallback: far from the reference point for the accept
                    if e:
                        c, suf, src = versioned((e[0], e[1]), e[3], "A")
                        item, also = item or page, None
                        if src == "wiki":
                            suf += f" (point: the wiki's {clean(e[2], 60)} page)"
                    elif not c:
                        izone = self.item_zone(page, fl, added)
                st["item_quests_point"] += 1 if c else 0
                st["item_quests_zone"] += 1 if izone is not None and not c else 0
            if item:
                iname = re.sub(r"\s*\(item\)$", "", item)
                note = f"Starts from the item {clean(iname, 60)}."
            elif also and who:
                note = f"From {who}; the item {clean(also, 60)} starts it too."
            elif auto:
                note = "Accepted automatically when you reach the area."
            elif who:
                note = f"From {who}."
            else:
                note = "Quest giver not named on the wiki."
            if c:
                lines.append(f"A {name}|QID|{qid}|{ptag}{utag}{mz(c)}{gate}N|{note}{suf}|")
                if c[0] != "Z":
                    first_map = c[0]
                st[f"steps_{src}"] += 1
                if src == "wiki" and not starters:
                    # (an item-started quest is accepted wherever the player opens the item: nothing to compare)
                    contrib_check("A", f"A:{qid}", c)
            elif izone is not None:
                lines.append(f"A {name}|QID|{qid}|{ptag}{utag}Z|{izone}; {maps.maps[izone]['name']}|{gate}"
                             f"N|{note} (zone only: the wiki's {clean(page, 60)} page names where it drops, with no point)|")
                st["steps_zone"] += 1
            else:
                pending(f"A {name}|QID|{qid}|{ptag}{utag}", f"{gate}N|{note}", starts)
            st["steps"] += 1
            # C per objective bullet
            bullets = self.objs.get((qid, r["page_title"]), [])
            counted = [b for b in bullets if b["kind"] != "provided"]
            use_qo = True
            if fl == "retail" and self.qobj.get(qid) is not None and counted and self.qobj[qid] != len(counted):
                use_qo = False
                self.conflicts.append((fl, qid, "objective_count", str(len(counted)), str(self.qobj[qid]),
                                       r["page_title"], r["revid"], "QO tags dropped"))
            provided_ids = []
            for b in bullets:
                if b["kind"] == "provided":
                    it = self.items.get(self.resolve_title(b["target_title"])[0] or "")
                    if it and it[0]:
                        provided_ids.append(it[0])
            qo = 0
            for b in counted:
                qo += 1
                cc = None
                bc = json.loads(b["coords_json"] or "[]")
                if bc:
                    cc = self.coords_list([(x[2], x[0], x[1]) for x in bc], fl, classic_q, added, home_name)
                    cc = versioned(cc, page_exact, "C", qo) if cc else None
                if not cc and b["target_title"]:
                    e = self.entity_coords(b["target_title"], fl, added, home_name)
                    if e and self.resolve_title(b["target_title"])[0] in self.items and not item_point_ok(e, "C", qo):
                        e = None    # --measure-fallback: an item's drop point far from the reference objective point
                    if e:
                        cc = versioned((e[0], e[1]), e[3], "C", qo)
                if not cc and poi and use_qo:
                    pin = poi.get(qid, qo - 1)
                    if pin:
                        cc = (pin, " (location: Blizzard quest POI, the objective area)", "poi")
                ckey = objective_key(qid, qo, use_qo, len(counted))
                if cc and cc[2] == "wiki":
                    contrib_check("C", ckey, cc[0])
                elif not cc and contrib and ckey:
                    ar = contrib.points(ckey, CONTRIB_POINTS)
                    if ar:
                        cc = (contrib.tag(ar), contrib.note(ar), "contrib")
                elif not cc and contrib and f"C:{qid}:0" in contrib.areas:
                    st["contrib_ambiguous"] += 1    # several objective steps without |QO| share the add-on's key 0
                if not cc and fb:
                    f = fb.get(qid, "C", qo)
                    if f:
                        cc = (("Z", f), f" (location: {f[2]})", "fallback")
                tags = f"QO|{qo}|" if use_qo else ""
                if b["kind"] == "kill" and b["target_title"]:
                    tags += f"T|{clean(b['target_title'], 60)}|"
                if b["kind"] == "item" and b["target_title"]:
                    it = self.items.get(self.resolve_title(b["target_title"])[0] or "")
                    if it and it[0]:
                        tags += f"L|{it[0]} {b['count'] or 1}|"
                if provided_ids and qo == 1:
                    tags += f"U|{provided_ids[0]}|"
                if b["optional"]:
                    tags += "O|"
                text = clean(b["text"]) or "Complete the objective."
                if cc:
                    lines.append(f"C {name}|QID|{qid}|{tags}{mz(cc[0])}{gate}N|{text}{cc[1]}|")
                    st[f"steps_{cc[2]}"] += 1
                else:
                    pending(f"C {name}|QID|{qid}|{tags}", f"{gate}N|{text}",
                            [{"title": b["target_title"]}] if b["target_title"] else [])
                st["steps"] += 1
            if not counted:
                f = fb.get(qid, "C") if fb else None
                prose = clean(r["objectives_text"]) or "Complete the objectives."
                if f:
                    lines.append(f"C {name}|QID|{qid}|M|{f[0]}|Z|{f[1]}|{gate}N|{prose} (location: {f[2]})|")
                    st["steps_fallback"] += 1
                    st["steps"] += 1
                elif r["objectives_text"] and not DELIVERY.match(r["objectives_text"]):
                    # the one objective step of a quest whose page lists no bullets carries no |QO|: the add-on's key 0
                    ar = contrib.points(objective_key(qid, 0, False, 1), CONTRIB_POINTS) if contrib else None
                    if ar:
                        lines.append(f"C {name}|QID|{qid}|{mz(contrib.tag(ar))}{gate}N|{prose}{contrib.note(ar)}|")
                        st["steps_contrib"] += 1
                    else:
                        lines.append(f"C {name}|QID|{qid}|{gate}N|{prose}|")
                        st["steps_none"] += 1
                    st["steps"] += 1
            # T (skipped for bonus objectives: they complete on their own)
            if not re.search(r"bonus objective", r["qtype"] or "", re.I):
                c, suf, src = loc_tag("end", ends, "T")
                who = next((clean(e.get("label") or e.get("title"), 60) for e in ends if e.get("title")), "")
                note = f"To {who}." if who else "Turn in."
                if c:
                    lines.append(f"T {name}|QID|{qid}|{mz(c)}{gate}N|{note}{suf}|")
                    st[f"steps_{src}"] += 1
                    if src == "wiki":
                        contrib_check("T", f"T:{qid}", c)
                    # the wiki's turn-in point against the client's own turn-in pin (both builds; WIKI_DATA_SPEC.md 3)
                    pin = poi.get(qid, -1) if (poi and src == "wiki" and c[0] != "Z") else None
                    if pin and pin[0] == c[0]:
                        a = [float(v) for v in c[1].split(";")[0].split(",")]
                        b2 = [float(v) for v in pin[1].split(",")]
                        yd = self.atlas.yards(fl, c[0], a, b2)
                        if yd and yd > 50:
                            self.conflicts.append((fl, qid, "turnin_xy", f"{c[0]}:{c[1]}", f"{pin[0]}:{pin[1]}",
                                                   r["page_title"], r["revid"], f"{yd:.0f} yd from the client quest pin"))
                else:
                    pending(f"T {name}|QID|{qid}|", f"{gate}N|{note}", ends)
                st["steps"] += 1
            resolve_pending()
            # home zone: the quest-log category when it is a map, else where the steps are
            hm = zmid if zmid is not None else first_map
            if hm is None:
                for ln in lines:
                    m = re.search(r"\|Z\|(\d+)", ln)
                    if m and int(m.group(1)) in maps.maps:
                        hm = int(m.group(1))
                        break
            hm = maps.home(hm) if hm is not None else 0
            fac = r["faction"] if r["faction"] in ("Alliance", "Horde") else "Both"
            lv = r["level"] if (r["level"] or 0) > 0 else None
            guides[(hm, fac)].append((qid, lv, r["levelreq"], name, lines))
            steps_out[qid] = len(lines)

        # ---- write ------------------------------------------------------------------------------------
        today = datetime.date.today().isoformat()
        if self.out_dir:
            self.out_dir.mkdir(parents=True, exist_ok=True)
        out = (self.out_dir or GUIDES) / f"Imported_Wiki_{fl}.lua"
        hdr = []
        if self.use_fallback:
            # the measurement file: outside CompletionRoute/, and it stops any client that loads it
            MEASURE_OUT.mkdir(parents=True, exist_ok=True)
            out = MEASURE_OUT / f"Imported_Wiki_{fl}.lua"
            hdr = ["-- MEASUREMENT ONLY, never part of the add-on (tools/wiki/gen_wiki_guides.py --measure-fallback): steps whose",
                   "-- note says \"(location: Blizzard data)\" / \"(location: Questie data)\" took their map point from the",
                   "-- reference file tools/measure/questie/Imported_Quests_" + FALLBACK_OF.get(fl, fl) + ".lua. Do not copy "
                   "this file into CompletionRoute/.",
                   'error("Completionist\'s Guide: an offline measurement file was loaded; it is not part of the add-on")']
        hdr += [
            f"-- Completionist's Guide :: Imported_Wiki_{fl}.lua - GENERATED {today} by tools/wiki/gen_wiki_guides.py",
            "-- Quest data (names, ids, givers, enders, chains, objectives, coordinates) is derived from",
            "-- Warcraft Wiki, https://warcraft.wiki.gg, by its contributors, licensed under CC BY-SA 4.0",
            "-- (https://creativecommons.org/licenses/by-sa/4.0/). This data file is shared under the same licence;",
            "-- see Guides/WIKI_DATA_LICENSE.md. Page histories (authors) are on each quest's wiki page.",
            "-- Flavor membership: Blizzard client QuestV2 table via wago.tools (facts only).",
        ]
        if poi and st["steps_poi"]:
            hdr.append("-- Steps whose note says \"(location: Blizzard quest POI, ...)\" take their map point from the client's "
                       f"quest pins, not from the wiki: Blizzard QuestPOIBlob + QuestPOIPoint tables via wago.tools, build "
                       f"{poi.build} (client data, facts only; see Guides/WIKI_DATA_LICENSE.md).")
        if contrib and st["steps_contrib"]:
            hdr.append(contrib.header())
        hdr += ["local _, NS = ...", flavor_gate(fl), "local R = NS.Guide.Register", ""]
        body = []
        # zone order, split of huge zone guides and the step order inside each guide: tools/wiki/gen_spine.py
        parts, cycles = gen_spine.build_parts(fl, guides, pre, maps, chosen)
        for p in parts:
            gname = p["name"].replace('"', '\\"')
            zfield = str(p["zone"]) if p["zone"] is not None else '"Other"'
            facf = f'faction="{p["faction"]}", ' if p["faction"] != "Both" else ""
            levels = f"minlevel={p['minlevel']}, maxlevel={p['maxlevel']}, "
            # forever=true: the points are already on Forever's maps (Core/Guide.lua skips the Era->Forever remap)
            native = "forever=true, " if fl == "forever" else ""
            if p.get("oversize"):
                native += f'oversize="{p["oversize"]}", '
            body.append(f'R({{ id="{p["id"]}", name="{gname}", type="Quests", zone={zfield}, {facf}{levels}'
                        f'{native}author="Warcraft Wiki contributors (CC BY-SA 4.0)", source="CompletionRoute", text=[==[')
            body.extend(p["lines"])
            body.append("]==] })")
        nguides = len(parts)
        out.write_text("\n".join(hdr + body) + "\n", encoding="utf-8")
        st["guides"] = nguides
        st["zone_guides"] = len(guides)
        st["file_kb"] = out.stat().st_size // 1024
        if self.use_fallback:
            return st       # the measurement writes nothing else: no spine sidecar, no wiki.sqlite tables
        gen_spine.write_sidecar(fl, parts, pre, cycles, self.out_dir)

        # ---- SQL ---------------------------------------------------------------------------------------
        db = sqlite3.connect(self.out_dir / "wiki.sqlite" if self.out_dir else WIKI)
        db.executescript("""
        create table if not exists flavor_quests(flavor text, quest_id int, page_title text, steps int,
            primary key(flavor, quest_id));
        -- in_old_guides: always 0 since 2026-11-11 (the older generated guides are no longer part of the project)
        create table if not exists flavor_gap(flavor text, quest_id int, in_old_guides int, primary key(flavor, quest_id));
        create table if not exists flavor_skip(flavor text, quest_id int, page_title text, reason text);
        create table if not exists gen_stats(flavor text, metric text, value int, primary key(flavor, metric));
        """)
        for t in ("flavor_quests", "flavor_gap", "flavor_skip", "gen_stats"):
            db.execute(f"delete from {t} where flavor=?", (fl,))
        db.executemany("insert into flavor_quests values (?,?,?,?)",
                       [(fl, q, chosen[q]["page_title"], steps_out.get(q, 0)) for q in chosen])
        db.executemany("insert into flavor_gap values (?,?,?)",
                       [(fl, q, 0) for q in gaps])
        db.executemany("insert into flavor_skip values (?,?,?,?)", skip)
        db.executemany("insert into gen_stats values (?,?,?)", [(fl, k, v) for k, v in st.items()])
        db.commit()
        db.close()
        return st

    def verif(self):
        """the chart: docs/verification.sqlite, or the one in the --out folder"""
        return sqlite3.connect(self.out_dir / "verification.sqlite" if self.out_dir else VERIF)

    def point_sources(self, fl, st):
        """where each step's point came from, per client and build, into docs/verification.sqlite wiki_point_sources.
        build "no-fallback" is the build (the only one that is installed or shipped); "fallback" is the
        --measure-fallback comparison.  Column contrib (player contributions) was added on 2026-11-12: a chart made
        before that gets it here, 0 for its older rows."""
        con = self.verif()
        con.execute("""create table if not exists wiki_point_sources(flavor text, build text, steps int, wiki int, poi int,
                       place int, fallback int, zone int, none int, measured text, contrib int default 0,
                       primary key (flavor, build))""")
        if "contrib" not in [c[1] for c in con.execute("pragma table_info(wiki_point_sources)")]:
            con.execute("alter table wiki_point_sources add column contrib int default 0")
        con.execute("insert or replace into wiki_point_sources (flavor, build, steps, wiki, poi, place, fallback, zone, "
                    "none, measured, contrib) values (?,?,?,?,?,?,?,?,?,datetime('now'),?)",
                    (fl, "fallback" if self.use_fallback else "no-fallback", st["steps"], st["steps_wiki"], st["steps_poi"],
                     st["steps_place"], st["steps_fallback"], st["steps_zone"], st["steps_none"], st["steps_contrib"]))
        con.commit()
        con.close()

    def write_fallback_conflicts(self, flavors):
        """--measure-fallback: the wiki points the reference file puts more than 300 yd away, in their own table (the
        build's wiki_db2_conflict is left alone)"""
        con = sqlite3.connect(VERIF)
        con.execute("""create table if not exists wiki_fallback_conflict(flavor text, quest_id int, field text,
                       wiki_value text, db2_value text, page_title text, revid int, note text)""")
        con.executemany("delete from wiki_fallback_conflict where flavor=?", [(f,) for f in flavors])
        rows = [c for c in self.conflicts if c[2].endswith("_xy_version")]
        con.executemany("insert into wiki_fallback_conflict values (?,?,?,?,?,?,?,?)", rows)
        con.commit()
        return Counter((c[0], c[2]) for c in rows)

    def write_conflicts(self, flavors):
        con = self.verif()
        con.execute("""create table if not exists wiki_db2_conflict(flavor text, quest_id int, field text,
                       wiki_value text, db2_value text, page_title text, revid int, note text)""")
        con.executemany("delete from wiki_db2_conflict where flavor=?", [(f,) for f in flavors])
        con.executemany("insert into wiki_db2_conflict values (?,?,?,?,?,?,?,?)", self.conflicts)
        con.commit()
        con.close()
        return Counter((c[0], c[2]) for c in self.conflicts)


FLAGS = ("--measure-fallback", "--no-fallback", "--no-spine", "--no-contributions")
VALUED = ("--contributions", "--out")


def parse_args(argv):
    """-> (flavors, flags, {option: value}); stops on anything it does not know"""
    flavors, flags, opts, bad = [], set(), {}, []
    it = iter(argv)
    for a in it:
        name, eq, val = a.partition("=")
        if name in VALUED:
            val = val if eq else next(it, "")
            if not val or val.startswith("--"):
                raise SystemExit(f"gen_wiki_guides: {name} needs a folder")
            opts[name] = val
        elif a in FLAGS:
            flags.add(a)
        elif a in FLAVORS:
            flavors.append(a)
        else:
            bad.append(a)
    if bad:
        raise SystemExit(f"gen_wiki_guides: unknown argument(s) {' '.join(bad)}")
    if "--measure-fallback" in flags and "--out" in opts:
        raise SystemExit("gen_wiki_guides: --measure-fallback writes tools/measure/out/ only; --out does not apply")
    if "--no-contributions" in flags and "--contributions" in opts:
        raise SystemExit("gen_wiki_guides: --contributions and --no-contributions exclude each other")
    return flavors, flags, opts


def main(argv=None):
    args, flags, opts = parse_args(sys.argv[1:] if argv is None else argv)
    flavors = args or FLAVORS
    measure = "--measure-fallback" in flags
    cdir = None if (measure or "--no-contributions" in flags) else contributions_dir(opts.get("--contributions"))
    g = Gen(fallback=measure, contributions=cdir, out=opts.get("--out"))
    if measure:
        print("MEASUREMENT ONLY (--measure-fallback): writing tools/measure/out/, nothing under CompletionRoute/")
    elif g.out_dir:
        print(f"writing everything into {g.out_dir} (--out): no guide, table or chart of the checkout is changed")
    if not measure:
        print(f"player contributions: {cdir}" if cdir else "player contributions: none read (no contributions folder)")
    print(f"{len(g.rows)} wiki quest rows, {len({r['id'] for r in g.rows})} ids; "
          f"{g.history_marked} NPC coordinates read as Classic-map numbers (pre-4.0.3 page history)")
    for fl in flavors:
        st = g.run(fl)
        s = st["steps"] or 1
        print(f"{fl:6} wiki ids {st['wiki_quest_ids']}, assigned {st['assigned']}, guides {st['guides']}, "
              f"steps {st['steps']}: wiki coords {st['steps_wiki']} ({100*st['steps_wiki']/s:.1f}%), client quest POI "
              f"{st['steps_poi']}, player contributions {st['steps_contrib']}, wiki place page {st['steps_place']}, "
              + (f"reference file {st['steps_fallback']} ({100*st['steps_fallback']/s:.1f}%), " if measure else "")
              + f"zone only {st['steps_zone']}, none {st['steps_none']} "
              f"({100*st['steps_none']/s:.1f}%); DB2-only gap {st['db2_only_gap']}; {st['file_kb']} KB")
        g.point_sources(fl, st)
        print(f"       zone guides {st['zone_guides']} -> {st['guides']} guides after splitting (gen_spine.MAX_STEPS)")
        print(f"       item-started quests {st['item_quests']}: accept point {st['item_quests_point']}, zone only "
              f"{st['item_quests_zone']}"
              + (f"; item-page points dropped for the reference point (over 300 yd): {st['item_points_far_from_fallback']}"
                 if measure else ""))
        cb = g.contrib_seen.get(fl)
        if cb is not None and not cb.path.is_file():
            print(f"       player contributions: no areas/{fl}.json in that folder (nothing changes for {fl})")
        elif cb is not None:
            print(f"       player contributions: {len(cb.areas)} step keys usable, commit {cb.commit}; areas not used: "
                  f"{dict(sorted(cb.skipped.items()))}; steps located {st['steps_contrib']}, wiki points over "
                  f"{CONTRIB_FAR_YD:.0f} yd from a contributed area {st['contrib_conflicts']}, objective steps with an "
                  f"ambiguous key {st['contrib_ambiguous']}")
        if not measure and "--no-spine" not in flags:
            gen_spine.build_spine(fl, flavor_gate(fl), g.out_dir)
    if measure:
        c = g.write_fallback_conflicts(flavors)
        print("wiki points far from the reference (docs/verification.sqlite wiki_fallback_conflict):", dict(c))
        return
    c = g.write_conflicts(flavors)
    print("conflicts logged (docs/verification.sqlite wiki_db2_conflict):", dict(c))
    print(f"subzone rows corrected (a parent-zone row on the same page disagrees): {len(g.subzone_dropped)}; first: {g.subzone_dropped[:8]}")
    print("place-page points not used:", dict(sorted(g.place_rejected.items())))


if __name__ == "__main__":
    main()
