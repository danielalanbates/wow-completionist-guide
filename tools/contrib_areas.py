#!/usr/bin/env python3
# CompletionRoute :: tools/contrib_areas.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Player contributions for the gold and profession routes (tools/wiki/gen_gold.py, tools/wiki/gen_professions.py).

The rule is the quest guides' rule (tools/wiki/gen_wiki_guides.py class Contributions, docs/CONTRIBUTE.md), applied to
the steps of a gold or profession route that have no point of their own (no |M| and no |ALT|):

  * the areas are <contributions>/areas/<flavor>.json of the open data repository (wow-completionist-data,
    tools/contrib.py there, CC BY-SA 4.0).  The folder is --contributions DIR, else $CR_CONTRIB, else
    ../wow-completionist-data/contributions next to this checkout when it exists; --no-contributions reads none;
  * a step's key is the add-on's own (Core/Contribute.lua KeyFor): A:<quest> / T:<quest> / C:<quest>:<QO number> for
    a quest step, "G:<guide id>#<step key>" for any other step, the step key made as Core/Guide.lua StepBase and
    AssignKeys make it (action, "~", a hash of the title's words and the achievement, recipe, skill and mission ids,
    "#2" on the second identical step).  step_keys() below is that code in Python; tools/test_contrib_gen.py checks
    it against the add-on itself, step for step, on every generated gold and profession route;
  * only "trusted" or "confirmed" areas on a map this client has and can place a point on (a zone, city, dungeon,
    micro or orphan map, never a continent or the world map); the heaviest one, and for a quest objective up to three
    on that map.  A step that names a zone keeps that zone unless the area lies in it (the zone is what the step is
    about: "Travel to Felwood");
  * the step gets |M|x,y|Z|<map>; <name>| and its note ends "(location: player contributions, N players)"; the file
    header then names the data repository, its licence and the commit the areas came from, which
    tools/package_release.py requires.  With no areas file for a client, nothing changes by a byte.

The reader is a copy of the quest generator's (that file is not imported: it is another workstream's), kept to the
same checks: the areas file is public input, and only a map id, positions and a player count ever reach a route.
"""
import json
import math
import os
import re
import shutil
import subprocess
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONTRIB_REPO = "wow-completionist-data"
CONTRIB_URL = "https://github.com/danielalanbates/wow-completionist-data"
CONTRIB_DEFAULT = ROOT.parent / CONTRIB_REPO / "contributions"      # a sibling checkout of the data repository
NOTE = "(location: player contributions"                            # tools/package_release.py looks for this
MAX_BYTES = 100_000_000                 # an areas file larger than this is not read
USED = ("trusted", "confirmed")         # "single" (one player, nobody agrees yet) is never used
POINTS = 3                              # a quest objective takes up to this many areas; every other step one
QUEST_KEY = re.compile(r"(?:[AT]:[0-9]{1,7}|C:[0-9]{1,7}:[0-9]{1,2})")
# the key of a step with no quest, as Core/Contribute.lua KeyFor makes it: the guide id (tools/contrib.py's character
# set), "#", an access-chain prefix "@<chain>/" (Core/Progress.lua), the action, "~", nine base-36 digits, a repeat
GUIDE_KEY = re.compile(r"G:[A-Za-z0-9 _:.\-/'()&,+!?]{1,140}#(?:@[A-Za-z0-9 _:.\-'()&,+!?]{1,60}/)?"
                       r"[A-Za-z!$=]~[0-9a-z]{9}(?:#[0-9]{1,4})?")

# ---- Core/Guide.lua, as far as a step's key needs it ------------------------------------------------------------------
ACTIONS = set("AaCTtKRHhFfNBbULlrDJM!$=GP*ds")
ALIAS = {"P": "N", "*": "N", "d": "N", "s": "N"}
FLAGS = {"O", "S", "US", "S!US", "NC", "NA", "NOAUTO", "CC", "CS", "CN", "ROUTE", "FIXED", "RUNE", "ELITE", "RARE",
         "DUNGEON", "CHAT", "H", "I", "V", "FAIL", "AP", "CT", "MS", "TOF", "EAB", "NOCACHE"}
VALUE_TAGS = {"QID", "PRE", "LEAD", "ACTIVE", "AVAILABLE", "M", "Z", "N", "L", "QO", "T", "U", "ITEM", "C", "R", "P",
              "LVL", "FACTION", "SPELL", "BUFF", "RANK", "ACH", "MISSION", "RAD", "KIND", "SKILL", "RECIPE", "COUNT", "ALT"}
WS = " \t\n\v\f\r"                      # Lua's %s in the C locale
HASH_P, HASH_B = 68757246219383, 131    # Core/Guide.lua hash45
DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
COORD_PAIR = re.compile(rb"[0-9]+\.[0-9]+[ \t\n\v\f\r]*,[ \t\n\v\f\r]*[0-9]+\.[0-9]+")
PUNCT_RUN = re.compile(rb"[\x00-\x20\x7f!-/:-@\[-`{-~]+")      # Lua's [%c%p%s]+ in the C locale


def lua_trim(s):
    return s.strip(WS)


def norm_text(t):
    """Core/Guide.lua G.NormText on bytes: ASCII lower case, written coordinates and runs of punctuation, spaces and
    control characters folded to one space, one leading and one trailing space dropped"""
    b = bytes(c + 32 if 65 <= c <= 90 else c for c in t.encode("utf-8"))
    b = PUNCT_RUN.sub(b" ", COORD_PAIR.sub(b" ", b))
    if b.startswith(b" "):
        b = b[1:]
    return b[:-1] if b.endswith(b" ") else b


def hash45(b, h=0):
    for c in b:
        h = (h * HASH_B + c) % HASH_P
    return h


def base36(n):
    out = []
    for _ in range(9):
        n, d = divmod(n, 36)
        out.append(DIGITS[d])
    return "".join(reversed(out))


def lua_number(s):
    """tonumber() of a plain decimal written in a guide, else None"""
    s = lua_trim(s or "")
    return int(s) if re.fullmatch(r"[0-9]+", s) else None


def parse_step(line):
    """Core/Guide.lua ParseLine, the fields a key and this module need: {action, title, tags: {tag: (value, part index)},
    parts}; None for a line the add-on does not read as a step"""
    text = lua_trim(line)
    if not text or text.startswith(";") or text.startswith("--"):
        return None
    if text[0] not in ACTIONS or text[1:2] != " ":
        return None
    parts = text.split("|")
    st = {"action": ALIAS.get(text[0], text[0]), "title": lua_trim(parts[0][2:]).replace("\\n", "\n"), "tags": {},
          "parts": parts, "lead": line[:len(line) - len(line.lstrip(WS))], "tail": line[len(line.rstrip(WS)):]}
    i = 1
    while i < len(parts):
        tag = lua_trim(parts[i])
        val = parts[i + 1] if i + 1 < len(parts) else None
        used = 2
        if tag == "":
            used = 1
        elif tag in FLAGS:
            used = 1
        elif tag not in VALUE_TAGS:
            # an unknown tag: Core/Guide.lua keeps a value only when one follows that reads as data
            if val is None or val == "" or (i + 2 >= len(parts) and re.search(r"[^A-Za-z0-9 \t\n\v\f\r;,.\-]", val)):
                used = 1
        if used == 2:
            st["tags"][tag] = (val, i + 1)
        i += used
    return st


def step_base(st):
    """Core/Guide.lua StepBase of a step with no quest: "<action>~<nine base-36 digits>" (quest steps: None)"""
    tags = {k: v[0] for k, v in st["tags"].items()}
    if re.search(r"[0-9]", tags.get("QID") or ""):
        return None
    t = norm_text(st["title"])
    m = re.match(r"^[ \t\n\v\f\r]*([0-9]+)[ \t\n\v\f\r]*;?[ \t\n\v\f\r]*([0-9]*)", tags.get("ACH") or "")
    if m:
        t += b"|a" + str(int(m.group(1))).encode() + b"." + (str(int(m.group(2))).encode() if m.group(2) else b"")
    m = re.search(r"[0-9]+", tags.get("RECIPE") or "")
    if m:
        t += b"|r" + str(int(m.group(0))).encode()
    m = re.match(r"^[ \t\n\v\f\r]*([^;]*?)[ \t\n\v\f\r]*;[ \t\n\v\f\r]*([0-9]+)[ \t\n\v\f\r]*;?[ \t\n\v\f\r]*([0-9]*)",
                 tags.get("SKILL") or "")
    if m and m.group(1) != "":
        name = bytes(c + 32 if 65 <= c <= 90 else c for c in m.group(1).encode("utf-8"))
        t += b"|s" + name + b"." + str(int(m.group(2))).encode() + b"." + (str(int(m.group(3))).encode() if m.group(3) else b"")
    m = re.search(r"[0-9]+", tags.get("MISSION") or "")
    if m:
        t += b"|m" + str(int(m.group(0))).encode()
    return st["action"] + "~" + base36(hash45(t))


def step_keys(gid, lines):
    """[(line index, parsed step, contribution key)] for every line the add-on reads as a step, in the guide's own
    order: the key Core/Contribute.lua KeyFor gives that step once Core/Guide.lua has parsed the guide (None for none)"""
    out, seen = [], Counter()
    for i, ln in enumerate(lines):
        st = parse_step(ln)
        if st is None:
            continue
        q = re.findall(r"[0-9]+", st["tags"].get("QID", ("",))[0] or "")
        if q:
            a = st["action"]
            qo = lua_number(st["tags"].get("QO", (None,))[0])
            key = f"A:{int(q[0])}" if a in "Aa" else f"T:{int(q[0])}" if a in "Tt" else f"C:{int(q[0])}:{qo or 0}"
        else:
            base = step_base(st)
            seen[base] += 1
            key = f"G:{gid}#{base}" + (f"#{seen[base]}" if seen[base] > 1 else "")
        out.append((i, st, key))
    return out


def fmt_xy(x, y):
    return f"{x:.1f},{y:.1f}"


# ---- where the areas come from --------------------------------------------------------------------------------------
def contributions_dir(arg=None, env=None, off=False):
    """the contributions folder to read: --contributions DIR, else $CR_CONTRIB, else the sibling checkout's; None with
    --no-contributions or when there is none.  A folder asked for by name must exist."""
    if off:
        return None
    env = os.environ if env is None else env
    for label, v in (("--contributions", arg), ("CR_CONTRIB", env.get("CR_CONTRIB"))):
        if v:
            d = Path(v).expanduser()
            if not d.is_dir():
                raise SystemExit(f"{label} {v}: no such folder")
            return d
    return CONTRIB_DEFAULT if CONTRIB_DEFAULT.is_dir() else None


def parse_args(argv, flavors):
    """(flavors, contributions folder or None, out folder or None) from a generator's command line:
    [flavors] [--contributions DIR | --no-contributions] [--out DIR]"""
    fls, opts, off, i = [], {}, False, 0
    while i < len(argv):
        a = argv[i]
        if a == "--no-contributions":
            off = True
        elif a.split("=", 1)[0] in ("--contributions", "--out"):
            k, eq, v = a.partition("=")
            if not eq:
                if i + 1 >= len(argv) or argv[i + 1].startswith("-"):
                    raise SystemExit(f"{k} needs a folder")
                i, v = i + 1, argv[i + 1]
            opts[k] = v
        elif a in flavors:
            fls.append(a)
        else:
            raise SystemExit(f"unknown argument {a!r} (clients: {' '.join(flavors)}; --contributions DIR, "
                             "--no-contributions, --out DIR)")
        i += 1
    if off and "--contributions" in opts:
        raise SystemExit("--no-contributions and --contributions DIR: pick one")
    return fls or list(flavors), contributions_dir(opts.get("--contributions"), off=off), \
        (Path(opts["--out"]) if "--out" in opts else None)


def commit_of(folder, fl):
    """the data repository commit the areas came from: HEAD of the checkout whose top folder holds this contributions
    folder; "unknown" when it is not that, "<commit>-dirty" when areas/<fl>.json differs from that commit.
    tools/package_release.py ships a contributed step only under a plain commit."""
    git = shutil.which("git", path="/usr/bin") or shutil.which("git")
    if not git:
        return "unknown"

    def run(*a):
        # --no-optional-locks: status must not refresh (write) the data repository's index; this only reads
        r = subprocess.run([git, "--no-optional-locks", "-C", str(folder), *a], capture_output=True, text=True, timeout=60)
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


class Areas:
    """the merged contributions of one client, for routes: per key (quest step keys and G: keys) the usable areas,
    heaviest first.  .problem says why a file was not read at all (the run goes on as with none); .skipped counts the
    areas left out; .used counts the steps that took a point, .outside the areas left out because they lie outside the
    zone the step names."""

    def __init__(self, folder, fl, maps):
        self.fl, self.maps = fl, maps
        self.folder = Path(folder) if folder else None
        self.areas, self.skipped, self.commit, self.problem = {}, Counter(), None, None
        self.used, self.outside = Counter(), 0
        self.path = self.folder / "areas" / f"{fl}.json" if self.folder else None
        if not self.path or not self.path.is_file():
            return
        try:
            if self.path.stat().st_size > MAX_BYTES:
                raise ValueError(f"larger than {MAX_BYTES} bytes")
            doc = json.loads(self.path.read_text(encoding="utf-8-sig"))
            if not isinstance(doc, dict) or not isinstance(doc.get("areas"), dict):
                raise ValueError('no "areas" table')
            if doc.get("flavor") != fl:
                raise ValueError(f"it is the file of client {str(doc.get('flavor'))[:20]!r}")
            areas = doc["areas"]
        except (OSError, ValueError, RecursionError) as e:
            self.problem = f"{type(e).__name__}: {str(e)[:200]}"
            return
        for key in sorted(areas):
            rows = areas[key] if isinstance(areas[key], list) else [None]
            if not (QUEST_KEY.fullmatch(key) or GUIDE_KEY.fullmatch(key)):
                self.skipped["not a step key"] += len(rows)
                continue
            keep = []
            for a in rows:
                why = self.check(a, maps)
                if why:
                    self.skipped[why] += 1
                else:
                    keep.append({"map": int(a["map"]), "x": float(a["x"]), "y": float(a["y"]), "n": int(a["contributors"]),
                                 "w": float(a["weight"])})
            if keep:
                self.areas[key] = sorted(keep, key=lambda a: -a["w"])
        self.commit = commit_of(self.folder, fl)

    @staticmethod
    def check(a, maps):
        """why an area is not used, or None (the quest generator's rules)"""
        if not isinstance(a, dict) or a.get("confidence") not in USED + ("single",):
            return "malformed"
        if a["confidence"] == "single":
            return "single"
        v = [a.get(k) for k in ("map", "x", "y", "contributors", "weight")]
        if not all(isinstance(n, (int, float)) and not isinstance(n, bool) and -1e9 < n < 1e9 and math.isfinite(n) for n in v):
            return "malformed"
        m, x, y, n, w = v
        if m != int(m) or n != int(n) or n < 1 or w <= 0 or n > w or not (0.05 <= x < 99.95 and 0.05 <= y < 99.95):
            return "malformed"
        if a["confidence"] == "confirmed" and n < 2:
            return "malformed"
        mm = maps.maps.get(int(m))
        if not mm or not mm["w"] or not mm["h"]:
            return "unknown map"
        if mm["type"] not in (3, 4, 5, 6):
            return "continent or world map"
        return None

    def points(self, key, limit=1):
        """the usable areas of a key, heaviest first: at most `limit`, all on the heaviest one's map, no point twice"""
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
    def note(ar):
        n = ar[0]["n"]
        return f"{NOTE}, {n} player{'' if n == 1 else 's'}" + (f", {len(ar)} areas" if len(ar) > 1 else "") + ")"

    def header(self):
        """the header line of a file that ships contributed points: the source, its licence and the commit"""
        return (f'-- Steps whose note says "{NOTE}, ...)" take their map point from where players stood: merged player '
                f"contributions, {CONTRIB_REPO} contributions/areas/{self.fl}.json ({CONTRIB_URL}, CC BY-SA 4.0), "
                f"commit {self.commit} (see Guides/WIKI_DATA_LICENSE.md).")

    def in_zone(self, mid, zone):
        return mid == zone or self.maps.is_ancestor(zone, mid)

    def apply(self, gid, lines):
        """the route's step lines with a contributed point on every step that has none of its own and whose key has a
        usable area (see the module text); a new list, the input is not changed"""
        if not self.areas:
            return list(lines)
        out = list(lines)
        keyed = step_keys(gid, lines)
        untagged = Counter(k for _, st, k in keyed if k and k.startswith("C:") and "QO" not in st["tags"])
        for i, st, key in keyed:
            tags = st["tags"]
            if "M" in tags or "ALT" in tags or not key or key not in self.areas:
                continue
            if any(t in tags and tags[t][0] is None for t in ("N", "Z")):
                continue        # a tag with no value after it (never written by the generators): left alone
            if key.startswith("C:") and "QO" not in tags and untagged[key] > 1:
                continue        # several objective steps of one quest share the add-on's key 0: none can be told apart
            ar = self.points(key, POINTS if key.startswith("C:") else 1)
            if not ar:
                continue
            mid = ar[0]["map"]
            zm = re.match(r"[ \t]*([0-9]+)", tags["Z"][0] or "") if "Z" in tags else None
            if zm and not self.in_zone(mid, int(zm.group(1))):
                self.outside += 1
                continue
            out[i] = self.with_point(st, mid, ";".join(fmt_xy(a["x"], a["y"]) for a in ar), self.note(ar))
            self.used[key[0]] += 1
        return out

    def with_point(self, st, mid, pts, note):
        """the step's line with |M|pts|Z|<map>; <name>| in front of its note (its own zone tag taken out) and the
        credit at the end of the note"""
        parts, tags = list(st["parts"]), st["tags"]
        name = self.maps.maps[mid]["name"].replace("|", "/")
        drop = {tags["Z"][1] - 1, tags["Z"][1]} if "Z" in tags else set()
        n_at = tags["N"][1] if "N" in tags else None
        new = []
        for j, p in enumerate(parts):
            if j in drop:
                continue
            if n_at is not None and j == n_at - 1:
                new += ["M", pts, "Z", f"{mid}; {name}"]
            new.append(p + " " + note if j == n_at else p)
        if n_at is None:
            if new and new[-1] == "":
                new.pop()
            new += ["M", pts, "Z", f"{mid}; {name}", "N", note, ""]
        return st["lead"] + "|".join(new) + st["tail"]
