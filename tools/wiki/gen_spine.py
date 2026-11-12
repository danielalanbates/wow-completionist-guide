#!/usr/bin/env python3
# CompletionRoute :: tools/wiki/gen_spine.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""The generated leveling spine (docs/FINISH_PLAN.md W2): step order inside each wiki zone guide, the split of huge
zone guides, and the per-faction chain of guides from level 1 to the cap.

    nice -n 10 python3 tools/wiki/gen_spine.py [era tbc mop retail]   # re-chain from the last generator run

gen_wiki_guides.py calls build_parts() for every zone guide while it writes Guides/Imported_Wiki_<fl>.lua, saves the
part list to tools/wiki/cache/parts_<fl>.json and then calls build_spine(), so one generator run writes everything.

Inputs (community + client facts only): the wiki quest rows (level, levelreq, previous/next chains, faction, added
patch), Warcraft Wiki zone pages (cache/wiki_raw.sqlite: "previous zone level", "(Classic)" infobox level) and
Template:Level (cache/template_level.json: zone level ranges and their expansion), and for retail the pinned DB2
tables QuestLine / QuestLineXQuest / Campaign / CampaignXQuestLine (tools/db2/retail, gitignored).

1. Zone order.  A topological sort over the wiki PRE edges inside the zone guide (every in-guide prerequisite
   before the quest), ties broken by quest level (Classic) or storyline (retail: campaign quest lines in campaign
   order, then the other quest lines, then the rest), then by quest-giver hub, then quest id.
2. Split.  A zone guide over MAX_STEPS steps is cut into consecutive slices of that order (each ~TARGET steps,
   never over MAX_STEPS), preferring cuts where the level (Classic) or the quest line (retail) changes.  The order is
   topological, so a slice never needs a quest from a later slice of the same zone.
3. Step order inside a slice: a simulated player.  Pick the first quest of the order that can be taken; accept
   every takeable quest at that hub (quests whose givers are within HUB_YD of each other, level window +2, quest-log
   cap LOG_CAP); do the open objectives by nearest neighbour; turn in by nearest neighbour; after each turn-in,
   accept what that turn-in unlocked at the same hub.  A quest's steps stay A, C..., T; an A never comes before
   the T of any in-slice prerequisite.
4. Spine.  Per faction: every slice of that faction or of both factions, sorted by a level/expansion key with the
   wiki PRE edges between slices as hard edges (Kahn topological sort).  Retail adds starter zones first, then the
   expansions in release order, campaign slices in Campaign/CampaignXQuestLine order inside each expansion.
   The spine is written as Guides/Imported_Spine_<fl>.lua: one "Leveling" guide per position (menu folder
   "Leveling (generated)"), whose text is the slice's text, with `next` set to the following position.
5. SQL (docs/verification.sqlite): guide_parts, spine_order, spine_violations.  A violation is a quest in the
   spine whose every in-spine prerequisite sits later in the spine (reason pre_after); a quest whose prerequisites
   are all outside this faction's spine is logged as pre_not_in_spine (it cannot be taken by that faction at all).
"""
import copy
import csv
import datetime
import heapq
import json
import os
import re
import sqlite3
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / "tools" / "wiki" / "cache"
RAW = CACHE / "wiki_raw.sqlite"
TEMPLATE_LEVEL = CACHE / "template_level.json"
GUIDES = ROOT / "CompletionRoute" / "Guides"
VERIF = ROOT / "docs" / "verification.sqlite"
DB2 = ROOT / "tools" / "db2"

MAX_STEPS = 250
TARGET = 200
HUB_YD = 50.0
LOG_CAP = 20
FAR = 1e9
CLASSIC_LIKE = ("era", "tbc", "forever")
# Template:Level section header -> expansion number (release order)
EXP_SECTIONS = {"WORLD OF WARCRAFT": 1, "THE BURNING CRUSADE": 2, "WRATH OF THE LICH KING": 3, "CATACLYSM": 4,
                "MISTS OF PANDARIA": 5, "WARLORDS OF DRAENOR": 6, "LEGION": 7, "BATTLE FOR AZEROTH": 8,
                "SHADOWLANDS": 9, "DRAGONFLIGHT": 10, "THE WAR WITHIN": 11, "MIDNIGHT": 12}
# rough level band of an expansion on a client that still uses the original levels (mop) - last resort only
EXP_BAND = {1: (1, 60), 2: (58, 70), 3: (68, 80), 4: (80, 85), 5: (85, 90)}
RE_M = re.compile(r"\|M\|([\d.]+),([\d.]+)")
RE_Z = re.compile(r"\|Z\|\s*(\d+)")


def pmajor(p):
    m = re.match(r"^\s*(\d+)\.", p or "")
    return int(m.group(1)) if m else None


# ---------------------------------------------------------------------------------------------------------------
# wiki zone levels
# ---------------------------------------------------------------------------------------------------------------
class ZoneLevels:
    def __init__(self):
        self.raw = sqlite3.connect(f"file:{RAW}?mode=ro", uri=True) if RAW.exists() else None
        self.tpl, self.tpl_exp = {}, {}
        if TEMPLATE_LEVEL.exists():
            d = json.loads(TEMPLATE_LEVEL.read_text(encoding="utf-8"))
            t = d["query"]["pages"][0]["revisions"][0]["slots"]["main"]["content"]
            exp = None
            for ln in t.split("\n"):
                s = ln.strip()
                if s in ("BATTLEGROUNDS", "DUNGEONS"):
                    break                      # the later blocks are instances; zones only
                if s in EXP_SECTIONS:
                    exp = EXP_SECTIONS[s]
                    continue
                for m in re.finditer(r"-->\|([^=<]+)=(\d+)(?:-(\d+))?<!--", ln):
                    lo, hi = int(m.group(2)), int(m.group(3) or m.group(2))
                    for k in m.group(1).split("|"):
                        k = k.strip().lower()
                        if k and k not in self.tpl:
                            self.tpl[k] = (lo, hi)
                            if exp:
                                self.tpl_exp[k] = exp
        self.cache = {}

    def page(self, title):
        if not self.raw:
            return ""
        r = self.raw.execute("select wikitext from pages where title=? limit 1", (title,)).fetchone()
        return r[0] if r and r[0] else ""

    @staticmethod
    def names(z):
        out = [z]
        if z.startswith("The "):
            out.append(z[4:])
        else:
            out.append("The " + z)
        return out

    def get(self, fl, z):
        """-> ((lo, hi) or None, expansion or None) from the wiki, for the client's version"""
        k = (fl, z)
        if k in self.cache:
            return self.cache[k]
        rng, exp = None, None
        for n in self.names(z):
            key = n.lower()
            if key in self.tpl_exp and exp is None:
                exp = self.tpl_exp[key]
            if fl == "retail" and rng is None and key in self.tpl:
                rng = self.tpl[key]
        if fl != "retail":
            for n in self.names(z):
                txt = ""
                if fl in CLASSIC_LIKE:
                    txt = self.page(n + " (Classic)")
                    m = re.search(r"\|\s*level\s*=\s*(\d+)\s*-\s*(\d+)", txt)
                    if m:
                        rng = (int(m.group(1)), int(m.group(2)))
                        break
                txt = self.page(n)
                m = re.search(r"previous zone level:\s*(\d+)\s*-\s*(\d+)", txt, re.I)
                if m and fl == "mop":
                    rng = (int(m.group(1)), int(m.group(2)))
                    break
                m = re.search(r"\|\s*level\s*=\s*(\d+)\s*-\s*(\d+)", txt)
                if m:
                    rng = (int(m.group(1)), int(m.group(2)))
                    break
        self.cache[k] = (rng, exp)
        return self.cache[k]


# ---------------------------------------------------------------------------------------------------------------
# retail storylines (DB2)
# ---------------------------------------------------------------------------------------------------------------
class Storylines:
    def __init__(self, fl):
        self.ok = False
        self.q_line = {}       # quest -> (questline, order in line)
        self.line_name = {}
        self.line_camp = {}    # questline -> (campaign id, order in campaign)
        if fl != "retail":
            return
        d = DB2 / "retail"
        need = [d / f"{t}.csv" for t in ("QuestLine", "QuestLineXQuest", "CampaignXQuestLine")]
        if not all(p.exists() for p in need):
            print("  note: retail QuestLine/Campaign tables missing (tools/wiki/fetch_db2.py) - no storyline split")
            return
        self.ok = True
        for r in csv.DictReader((d / "QuestLine.csv").open(encoding="utf-8")):
            self.line_name[int(r["ID"])] = r["Name_lang"]
        for r in csv.DictReader((d / "CampaignXQuestLine.csv").open(encoding="utf-8")):
            ql, c, o = int(r["QuestLineID"]), int(r["CampaignID"]), int(r["OrderIndex"] or 0)
            if ql not in self.line_camp or (c, o) < self.line_camp[ql]:
                self.line_camp[ql] = (c, o)
        for r in csv.DictReader((d / "QuestLineXQuest.csv").open(encoding="utf-8")):
            q, ql, o = int(r["QuestID"]), int(r["QuestLineID"]), int(r["OrderIndex"] or 0)
            cur = self.q_line.get(q)
            # a quest in several lines: the campaign line wins, then the lowest line id
            better = cur is None or ((ql in self.line_camp, -ql) > (cur[0] in self.line_camp, -cur[0]))
            if better:
                self.q_line[q] = (ql, o)

    def key(self, q):
        """sort key: campaign quest lines in campaign order, then other quest lines, then the rest"""
        if not self.ok or q not in self.q_line:
            return (2, 0, 0, 0)
        ql, o = self.q_line[q]
        if ql in self.line_camp:
            c, co = self.line_camp[ql]
            return (0, c * 1000 + co, ql, o)
        return (1, ql, ql, o)

    def line(self, q):
        return self.q_line.get(q, (None, 0))[0] if self.ok else None


# ---------------------------------------------------------------------------------------------------------------
# steps, hubs, levels
# ---------------------------------------------------------------------------------------------------------------
def step_pos(line, maps):
    m, z = RE_M.search(line), RE_Z.search(line)
    if not (m and z):
        return None
    return maps.to_world(int(z.group(1)), float(m.group(1)), float(m.group(2)))


def dist(a, b):
    if a is None or b is None:
        return 0.0
    if a[0] != b[0]:
        return FAR
    return ((a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2) ** 0.5


class Hubs:
    """greedy clustering of giver / ender points: a point within HUB_YD of a hub's first point joins it"""

    def __init__(self):
        self.centers = []
        self.by_inst = defaultdict(list)

    def of(self, p):
        if p is None:
            return None
        for i in self.by_inst[p[0]]:
            if dist(self.centers[i], p) <= HUB_YD:
                return i
        self.centers.append(p)
        self.by_inst[p[0]].append(len(self.centers) - 1)
        return len(self.centers) - 1


def eff_level(r):
    lv = r["level"] if (r["level"] or 0) > 0 else None
    lr = r["levelreq"] if (r["levelreq"] or 0) > 1 else None
    return lv or lr


class Quest:
    __slots__ = ("qid", "lv", "lr", "name", "lines", "steps", "a", "cs", "t", "elv", "hub", "rank", "row", "fac")

    def __init__(self, tup, row, maps):
        self.qid, self.lv, self.lr, self.name, self.lines = tup[:5]
        self.row = row
        self.elv = eff_level(row) if row else (self.lv or None)
        self.steps = [(ln[0], ln, step_pos(ln, maps)) for ln in self.lines]
        self.a = next((s for s in self.steps if s[0] == "A"), None)
        self.cs = [s for s in self.steps if s[0] == "C"]
        self.t = next((s for s in self.steps if s[0] == "T"), None)
        if self.a and self.a[2] is None:
            # a giver without a point: anchor the quest on its first located step
            p = next((s[2] for s in self.steps if s[2] is not None), None)
            self.a = (self.a[0], self.a[1], p) if p else self.a
        self.hub = None
        self.rank = 0


def zone_order(qs, pre, fl, story, hubs, default_lvl):
    """topological order of one zone guide: every in-guide prerequisite first (all of them), ties by
    level (Classic) / storyline (retail), then hub, then quest id.  Returns (order, broken edges)."""
    ids = {q.qid: q for q in qs}
    preds = {q.qid: {p for p in pre.get(q.qid, ()) if p in ids} for q in qs}
    succ = defaultdict(list)
    for q, ps in preds.items():
        for p in ps:
            succ[p].append(q)
    for q in sorted(qs, key=lambda q: (q.elv if q.elv is not None else default_lvl, q.qid)):
        q.hub = hubs.of(q.a[2] if q.a else None)

    def key(q):
        lvl = q.elv if q.elv is not None else default_lvl
        hub = q.hub if q.hub is not None else 1 << 30
        if fl == "retail":
            return (story.key(q.qid), lvl, hub, q.qid)
        return (lvl, hub, q.qid)
    indeg = {q: len(ps) for q, ps in preds.items()}
    heap = [(key(ids[q]), q) for q, d in indeg.items() if d == 0]
    heapq.heapify(heap)
    out, placed, broken = [], set(), []
    remaining = set(ids)
    while remaining:
        if not heap:
            # a cycle in the wiki chains: release the lowest-key quest and record the edges it skips
            q = min(remaining, key=lambda x: key(ids[x]))
            for p in preds[q]:
                if p not in placed:
                    broken.append((q, p))
            indeg[q] = 0
            heapq.heappush(heap, (key(ids[q]), q))
        _, q = heapq.heappop(heap)
        if q in placed:
            continue
        placed.add(q)
        remaining.discard(q)
        out.append(ids[q])
        for s in succ[q]:
            if s in placed:
                continue
            indeg[s] -= 1
            if indeg[s] == 0:
                heapq.heappush(heap, (key(ids[s]), s))
    for i, q in enumerate(out):
        q.rank = i
    return out, broken


def boundary_key(q, fl, story):
    if fl == "retail" and story.ok:
        return story.line(q.qid)
    return q.elv


def split(order, fl, story):
    """consecutive slices of the zone order, each <= MAX_STEPS steps, cut where level / quest line changes"""
    total = sum(len(q.lines) for q in order)
    if total <= MAX_STEPS:
        return [order]
    n = -(-total // TARGET)
    target = total / n
    parts, cur, acc = [], [], 0
    for i, q in enumerate(order):
        cur.append(q)
        acc += len(q.lines)
        nxt = order[i + 1] if i + 1 < len(order) else None
        if nxt is None:
            break
        nlen = len(nxt.lines)
        changes = boundary_key(q, fl, story) != boundary_key(nxt, fl, story)
        if acc + nlen > MAX_STEPS or (acc >= 0.8 * target and changes) or acc >= 1.15 * target:
            parts.append(cur)
            cur, acc = [], 0
    if cur:
        if parts and sum(len(q.lines) for q in parts[-1]) + acc <= MAX_STEPS and acc < 0.35 * target:
            parts[-1].extend(cur)
        else:
            parts.append(cur)
    return parts


def order_slice(qs, pre, hubs, skip):
    """the simulated-player step order of one slice (see the module doc, point 3); skip = {quest: prerequisites
    released to break a wiki chain cycle}.  A quest may sit in a slice twice as two FACTION-gated copies.
    Returns (lines, A idx, T idx) keyed "qid", or "qid@Faction" for such copies."""
    by_q = defaultdict(list)
    for q in qs:
        by_q[q.qid].append(q)
    K = {id(q): (str(q.qid) if len(by_q[q.qid]) == 1 else f"{q.qid}@{q.fac}") for q in qs}
    preds = {id(q): [p for p in pre.get(q.qid, ()) if p in by_q and p not in skip.get(q.qid, ())] for q in qs}
    P = sorted(qs, key=lambda q: q.rank)
    accepted, done = set(), set()
    cnext = {id(q): 0 for q in qs}
    t_done = set()
    out, a_idx, t_idx = [], {}, {}
    state = {"cur": None, "lvl": min((q.elv for q in qs if q.elv is not None), default=0)}

    def emit(step):
        out.append(step[1])
        if step[2] is not None:
            state["cur"] = step[2]

    def pdone(p):
        return all(id(o) in done for o in by_q[p])

    def avail(q):
        return id(q) not in accepted and all(pdone(p) for p in preds[id(q)])

    def lvl_ok(q, base):
        return q.elv is None or q.elv <= max(state["lvl"], base) + 2

    def accept(q):
        accepted.add(id(q))
        a_idx[K[id(q)]] = len(out)
        if q.a:
            emit(q.a)
        if not q.cs and not q.t:
            done.add(id(q))

    def finish(q):
        done.add(id(q))
        if q.elv is not None:
            state["lvl"] = max(state["lvl"], q.elv)

    def active():
        return [q for q in P if id(q) in accepted and id(q) not in done]

    def accept_at_hub(h, base):
        if h is None:
            return
        n_act = len(active())
        for q in P:
            if n_act >= LOG_CAP:
                break
            if q.hub == h and avail(q) and lvl_ok(q, base):
                accept(q)
                n_act += 1

    guard = 0
    while len(done) < len(qs):
        guard += 1
        if guard > 10 * len(qs) + 10:
            raise RuntimeError("order_slice did not converge")
        act = active()
        if not act:
            q0 = next((q for q in P if avail(q)), None)
            if q0 is None:
                # a circular wiki chain that crosses zones (a quest moved in from another zone closed the loop):
                # release the quest with the fewest open prerequisites and drop those from its PRE tag, or the
                # client would hide the whole loop forever
                q0 = min((q for q in P if id(q) not in accepted),
                         key=lambda q: (sum(1 for p in preds[id(q)] if not pdone(p)), q.rank))
                for p in [p for p in preds[id(q0)] if not pdone(p)]:
                    preds[id(q0)].remove(p)
                    pre[q0.qid].discard(p)
                    CYCLES.append((q0.qid, p))
                    if q0.a:
                        q0.a = (q0.a[0], drop_pre(q0.a[1], p), q0.a[2])
                        q0.lines = [q0.a[1] if ln.startswith("A ") else ln for ln in q0.lines]
            accept(q0)
            accept_at_hub(q0.hub, q0.elv or 0)
            continue
        # objectives, nearest neighbour (a quest's own objectives keep their wiki order)
        while True:
            cands = [q for q in active() if cnext[id(q)] < len(q.cs)]
            if not cands:
                break
            q = min(cands, key=lambda q: (dist(state["cur"], q.cs[cnext[id(q)]][2]), q.rank))
            emit(q.cs[cnext[id(q)]])
            cnext[id(q)] += 1
            if cnext[id(q)] == len(q.cs) and not q.t:
                finish(q)
        # turn-ins, nearest neighbour; take what each turn-in unlocks at that hub
        while True:
            cands = [q for q in active() if cnext[id(q)] >= len(q.cs) and q.t and id(q) not in t_done]
            if not cands:
                break
            q = min(cands, key=lambda q: (dist(state["cur"], q.t[2]), q.rank))
            t_idx[K[id(q)]] = len(out)
            emit(q.t)
            t_done.add(id(q))
            finish(q)
            th = hubs.of(q.t[2]) if q.t[2] is not None else q.hub
            accept_at_hub(th, q.elv or 0)
    return out, a_idx, t_idx


def drop_pre(line, p):
    def fix(m):
        keep = [x for x in m.group(1).split(";") if x and x != str(p)]
        return f"|PRE|{';'.join(keep)}|" if keep else "|"
    return re.sub(r"\|PRE\|([\d;]+)\|", fix, line)


def band_of(qs):
    lv = [q.lv for q in qs if q.lv]
    lr = [q.lr for q in qs if q.lr]
    lo = min(lr + lv) if (lr or lv) else None
    hi = sorted(lv)[int(0.9 * (len(lv) - 1))] if lv else None
    if hi is not None and lo is not None and hi < lo:
        hi = lo
    return lo, hi


def median(xs):
    xs = sorted(xs)
    return xs[len(xs) // 2] if xs else None


# ---------------------------------------------------------------------------------------------------------------
# entry point used by gen_wiki_guides.py
# ---------------------------------------------------------------------------------------------------------------
_ZL = None
ORDERS = {}        # faction -> frozen spine order of guide ids (build_parts' final fix-up)
HARD = []          # quests whose cross-guide PRE edges are hard in the spine (see build_parts)
CYCLES = []        # (quest, prerequisite) released inside a slice: a cross-zone circular wiki chain


def qfac_of(sl, fac):
    """quest -> its own faction when it differs from the guide's; two gated copies (A + H) together count as both"""
    f = defaultdict(set)
    for q in sl:
        f[q.qid].add(q.fac)
    out = {}
    for qid, fs in f.items():
        own = "Both" if (len(fs) > 1 or "Both" in fs) else next(iter(fs))
        if own != fac:
            out[str(qid)] = own
    return out


def finalize(p, fl, story, pre, hubs, skip):
    """(re)compute a part's step order, level band and name from its quest list"""
    sl = sorted(p["_qs"], key=lambda q: q.rank)
    zrng, exp, zname, fac = p["_zrng"], p["expansion"], p["zone_name"], p["faction"]
    lines, a_idx, t_idx = order_slice(sl, pre, hubs, skip)
    lo, hi = band_of(sl)
    if not (lo is not None and hi is not None):
        if zrng:
            lo, hi = zrng
        elif fl == "mop" and exp in EXP_BAND:
            lo, hi = EXP_BAND[exp]
    band = (f" {lo}-{hi}" if hi > lo else f" {lo}") if lo and hi else ""
    flabel = "" if fac == "Both" else f" ({fac})"
    name = f"{zname} Quests{band}{flabel}"
    if p["parts"] > 1:
        tag = f"Part {p['part']}/{p['parts']}"
        if p["rule"] == "storyline":
            lines_c = Counter(story.line(q.qid) for q in sl if story.line(q.qid))
            if lines_c:
                nm = (story.line_name.get(lines_c.most_common(1)[0][0]) or "").strip()
                if nm:
                    tag += f": {nm}"
        name += f" - {tag}"
    elv = [q.elv for q in sl if q.elv is not None]
    med = median(elv) if elv else None
    if med is None:
        med = (zrng[0] + zrng[1]) / 2 if zrng else (lo if lo else None)
    camp = [story.key(q.qid) for q in sl if story.key(q.qid)[0] == 0]
    p.update({"name": name, "minlevel": lo or 1, "maxlevel": hi or lo or 1, "lvl_med": med,
              "campaign": min(camp)[1] if camp else None, "quests": [q.qid for q in sl],
              "qfac": qfac_of(sl, fac),
              "a_idx": a_idx, "t_idx": t_idx, "steps": len(lines), "lines": lines,
              "oversize": (f"{len(lines)} steps: holds a prerequisite loop across zones that a cut would break "
                           f"(PRE order wins over the {MAX_STEPS}-step limit)") if len(lines) > MAX_STEPS else ""})


def build_parts(fl, guides, pre, maps, chosen, rounds=80):
    """guides: {(home map, faction): [(qid, level, levelreq, name, lines)]} -> (list of part dicts, cycles)"""
    global _ZL
    if _ZL is None:
        _ZL = ZoneLevels()
    story = Storylines(fl)
    parts = []
    cycles = []
    hubs = Hubs()              # one hub index per client, so a quest moved to another zone's guide keeps its hub
    skip = defaultdict(set)
    for (hm, fac) in sorted(guides, key=lambda k: ((maps.maps.get(k[0]) or {"name": "~"})["name"], k[1])):
        qs = [Quest(t, chosen.get(t[0]), maps) for t in guides[(hm, fac)]]
        for q in qs:
            q.fac = fac
        zname = maps.maps[hm]["name"] if hm in maps.maps else "Other Quests"
        zrng, zexp = _ZL.get(fl, zname) if hm in maps.maps else (None, None)
        lv_known = [q.elv for q in qs if q.elv is not None]
        default_lvl = median(lv_known) if lv_known else (zrng[0] if zrng else 0)
        order, broken = zone_order(qs, pre, fl, story, hubs, default_lvl)
        base = f"wiki:{fl}:{hm}:{fac}"
        cycles += [(base, q, p) for q, p in broken]
        for q, p in broken:
            skip[q].add(p)
            # a circular wiki chain (q needs p, p needs q): the zone order keeps p after q, so q's PRE tag must not
            # name p, or the client hides both quests forever
            pre[q].discard(p)
            qq = next(x for x in qs if x.qid == q)
            qq.lines = [drop_pre(ln, p) if ln.startswith("A ") else ln for ln in qq.lines]
            apos = qq.a[2] if qq.a else None
            qq.steps = [(ln[0], ln, st[2]) for ln, st in zip(qq.lines, qq.steps)]
            qq.a = next(((x[0], x[1], apos) for x in qq.steps if x[0] == "A"), None)
        slices = split(order, fl, story)
        # expansion of the zone: Template:Level section, else the median added patch of its quests
        majors = [pmajor(q.row["added_patch"]) for q in qs if q.row and pmajor(q.row["added_patch"])]
        exp = zexp or (median(majors) if majors else None)
        if fl != "retail" and exp and exp > 5:
            exp = None
        for k, sl in enumerate(slices, 1):
            parts.append({
                "id": base if len(slices) == 1 else f"{base}:{k}",
                "base": base, "part": k, "parts": len(slices),
                "rule": "none" if len(slices) == 1 else ("storyline" if (fl == "retail" and story.ok) else "level"),
                "zone": hm if hm in maps.maps else None, "zone_name": zname, "faction": fac,
                "zone_lo": zrng[0] if zrng else None, "expansion": exp, "_zrng": zrng, "_qs": list(sl),
                "moved_in": 0,
            })
    for p in parts:
        finalize(p, fl, story, pre, hubs, skip)
    # Cross-guide repair: a quest whose every prerequisite sits in a guide that comes LATER on a faction's spine
    # moves into that prerequisite's guide (right after it), when that guide serves the quest's faction.  Its own
    # dependents follow in the next round.  Repeat until nothing moves.
    moved_total = 0
    moved_zone = [0]
    nmov = {}
    cur_hard = set()
    visited = {}

    def relocate(parts):
        nonlocal moved_total
        by_id = {p["id"]: p for p in parts}
        fac_of = {q: p.get("qfac", {}).get(str(q), p["faction"]) for p in parts for q in p["quests"]}
        for rnd in range(rounds):
            moves = {}
            sp = {}
            need = defaultdict(dict)
            for faction in ("Alliance", "Horde"):
                seq, viol, _ = build_spine_for(fl, faction, parts, pre, frozenset(cur_hard))
                pos = {p["id"]: i for i, p in enumerate(seq)}
                q_part = {q: p["id"] for p in seq for q in p["quests"]
                          if p.get("qfac", {}).get(str(q), faction) in (faction, "Both")}
                sp[faction] = (seq, pos, q_part)
                for gid, q, why, det in viol:
                    if why != "pre_after":
                        continue
                    opts = [int(x) for x in det.split(";") if x and int(x) in q_part]
                    if not opts:
                        continue
                    o = min(opts, key=lambda x: pos[q_part[x]])
                    need[q][faction] = (by_id[gid], by_id[q_part[o]], o)
            for q, per in need.items():
                X = next(iter(per.values()))[0]
                qf = X.get("qfac", {}).get(str(q), X["faction"])
                pf = {fac_of.get(x) for x in pre.get(q, ())}
                # the guide of the quest's earliest prerequisite on every spine that has one
                ys = {}
                for faction in ("Alliance", "Horde"):
                    _, pos_f, qp_f = sp[faction]
                    o_f = [x for x in pre.get(q, ()) if x in qp_f]
                    if o_f:
                        ys[faction] = (by_id[qp_f[min(o_f, key=lambda x: pos_f[qp_f[x]])]], min(o_f, key=lambda x: pos_f[qp_f[x]]))

                def fits(z):
                    """z is at or after the prerequisite's guide on every spine that needs it (else it ping-pongs)"""
                    for faction, (Y, _) in ys.items():
                        if z is Y:
                            continue
                        pz, py = sp[faction][1].get(z["id"]), sp[faction][1].get(Y["id"])
                        if pz is None or py is None or pz <= py:
                            return False
                    return True

                # 1. join the prerequisite's guide, right after it, when that guide serves the quest's faction - or
                #    any faction's guide if all prerequisites are that faction's (the PRE tag hides the quest from
                #    the other faction anyway).  (Tried 2026-11-07: moving to the own zone's next part / a new
                #    continuation part first keeps zones purer but ping-pongs between zones and never reached 0.)
                cand = None
                for faction, (Y, o) in ys.items():
                    if Y is X:
                        continue
                    scope_ok = Y["faction"] in ("Both", qf) or (qf == "Both" and pf == {Y["faction"]})
                    if scope_ok and fits(Y):
                        cand = (Y, o)
                        break
                if cand:
                    moves[q] = (X, cand[0], cand[1])
                    continue
                # 2. else the earliest guide with the quest's own faction scope after the prerequisite everywhere
                best = None
                for z in parts:
                    if z["faction"] != qf or z is X or z["zone"] is None or not fits(z):
                        continue
                    score = sum(sp[f][1].get(z["id"], 0) for f in ys)
                    if best is None or score < best[0]:
                        best = (score, z)
                if best:
                    moves[q] = (X, best[1], None)
            if not moves:
                break
            if rnd == rounds - 1:
                print(f"  {fl}: repair pass stopped after {rounds} rounds with {len(moves)} quests still moving")
            # the moved quests' dependents in the same guide go with them now (each needs only moved quests),
            # instead of one chain link per round
            frontier = list(moves.items())
            while frontier:
                q, (X, Y, o) = frontier.pop()
                for d in X["_qs"]:
                    if d.qid in moves or q not in pre.get(d.qid, ()):
                        continue
                    if not all(x in moves for x in pre.get(d.qid, ()) if x in fac_of):
                        continue
                    df = X.get("qfac", {}).get(str(d.qid), X["faction"])
                    if Y["faction"] not in ("Both", df):
                        continue
                    moves[d.qid] = (X, Y, q)
                    frontier.append((d.qid, moves[d.qid]))
            # a quest sent back to a guide it already left is ping-ponging (moving it changes both guides' sort
            # keys): stop moving it and make its prerequisite edges hard instead
            for q in list(moves):
                X, Y, o = moves[q]
                if Y["id"] in visited.get(q, ()):
                    del moves[q]
                    cur_hard.add(q)
            for q, (X, Y, o) in moves.items():
                visited.setdefault(q, set()).add(X["id"])
            dbg = os.environ.get("SPINE_DEBUG_Q")
            if dbg:
                for q, (X, Y, o) in moves.items():
                    if str(q) == dbg:
                        print(f"    round {rnd}: move {q} {X['id']} -> {Y['id']} after {o}")
                if int(dbg) in need:
                    print(f"    round {rnd}: {dbg} needs {[(f, v[0]['id'], v[1]['id']) for f, v in need[int(dbg)].items()]}")
            changed = set()
            for q, (X, Y, o) in moves.items():
                qo = next((x for x in X["_qs"] if x.qid == q), None)
                if qo is None:
                    where = [(p["id"], q in p["quests"]) for p in parts if any(x.qid == q for x in p["_qs"])]
                    raise RuntimeError(f"quest {q} not in {X['id']} (quests list: {q in X['quests']}); in {where}; to {Y['id']}")
                X["_qs"].remove(qo)
                prer = next((x.rank for x in Y["_qs"] if x.qid == o), max((x.rank for x in Y["_qs"]), default=0))
                qo.rank = prer + 0.5
                Y["_qs"].append(qo)
                Y["moved_in"] += 1
                nmov[q] = nmov.get(q, 0) + 1
                if X["zone"] != Y["zone"]:
                    moved_zone[0] += 1
                changed.update((X["id"], Y["id"]))
            moved_total += len(moves)
            for gid in changed:
                p = by_id[gid]
                if p["_qs"]:
                    finalize(p, fl, story, pre, hubs, skip)
            parts = [p for p in parts if p["_qs"]]
            by_id = {p["id"]: p for p in parts}
        return parts

    def resplit(parts):
        """a guide that grew over MAX_STEPS from moved-in quests is cut again; its zone's parts are renumbered"""
        out, touched, cut = [], set(), False
        for p in parts:
            if p["steps"] <= MAX_STEPS:
                out.append(p)
                continue
            touched.add(p["base"])
            cut = True
            sl = sorted(p["_qs"], key=lambda q: q.rank)
            for j, piece in enumerate(split(sl, fl, story)):
                c = dict(p)
                c.update({"_qs": list(piece), "_sub": j, "moved_in": p["moved_in"] if j == 0 else 0})
                out.append(c)
        cnt = Counter(p["base"] for p in out)
        for p in out:
            # continuation parts (fractional numbers) and zones that lost a part are renumbered too
            if p["part"] != int(p["part"]) or p["parts"] != cnt[p["base"]]:
                touched.add(p["base"])
        for base in touched:
            ps = sorted([p for p in out if p["base"] == base], key=lambda p: (p["part"], p.get("_sub", 0)))
            for k, p in enumerate(ps, 1):
                p.update({"part": k, "parts": len(ps), "id": base if len(ps) == 1 else f"{base}:{k}",
                          "rule": p["rule"] if p["rule"] != "none" else ("storyline" if (fl == "retail" and story.ok) else "level")})
                p.pop("_sub", None)
                finalize(p, fl, story, pre, hubs, skip)
        return out, cut

    for attempt in range(8):
        parts = relocate(parts)
        parts, again = resplit(parts)
        if not again:
            break
    else:
        # the cut and the repair keep undoing each other (a guide that must hold a whole cross-zone loop):
        # PRE order wins, the guide may stay over MAX_STEPS and gen_spine reports it
        parts = relocate(parts)
    # Final fix-up on a FROZEN spine order: whatever is still out of order (quests that ping-pong between guides,
    # loops between guides) moves forward only - the faction's own quest into the guide that holds its
    # prerequisite, a both-faction quest as a FACTION-gated copy for the stuck faction (the original keeps serving
    # the other faction, gated to it).  Guide order never changes here, so every fix is final and it terminates.
    orders = {f: [p["id"] for p in build_spine_for(fl, f, parts, pre)[0]] for f in ("Alliance", "Horde")}
    stats = {"moves": 0, "copies": 0, "passes": 0, "cuts": 0}

    def fixup(parts, orders):
        copies = fixed_moves = 0
        for it in range(1000):
            by_id = {p["id"]: p for p in parts}
            changed = set()
            for faction in ("Alliance", "Horde"):
                other = "Horde" if faction == "Alliance" else "Alliance"
                seq, viol, _ = build_spine_for(fl, faction, parts, pre, fixed=orders[faction])
                pos = {p["id"]: i for i, p in enumerate(seq)}
                q_part = {q: p for p in seq for q in p["quests"]
                          if p.get("qfac", {}).get(str(q), faction) in (faction, "Both")}
                for gid, q, why, det in viol:
                    if why != "pre_after":
                        continue
                    X = by_id[gid]
                    opts = [int(x) for x in det.split(";") if x and int(x) in q_part]
                    if not opts:
                        continue
                    o = min(opts, key=lambda x: pos[q_part[x]["id"]])
                    Y = q_part[o]
                    qo = next((x for x in X["_qs"] if x.qid == q and x.fac in (faction, "Both")), None)
                    if qo is None:
                        continue
                    orank = next((x.rank for x in Y["_qs"] if x.qid == o), 0) + 0.5
                    if qo.fac == faction or Y is X:
                        if Y is X:
                            continue
                        X["_qs"].remove(qo)
                        qo.rank = orank
                        Y["_qs"].append(qo)
                        fixed_moves += 1
                    else:
                        c = copy.copy(qo)
                        for tgt, fac in ((c, faction), (qo, other)):
                            tgt.lines = [re.sub(r"\|N\|", f"|FACTION|{fac}|N|", ln, count=1) if "|FACTION|" not in ln
                                         else ln for ln in qo.lines]
                            apos = qo.a[2] if qo.a else None
                            tgt.steps = [(ln[0], ln, st[2]) for ln, st in zip(tgt.lines, qo.steps)]
                            tgt.a = next(((x[0], x[1], apos) for x in tgt.steps if x[0] == "A"), None)
                            tgt.cs = [x for x in tgt.steps if x[0] == "C"]
                            tgt.t = next((x for x in tgt.steps if x[0] == "T"), None)
                            tgt.fac = fac
                        c.rank = orank
                        Y["_qs"].append(c)
                        copies += 1
                    changed.update((X["id"], Y["id"]))
            if not changed:
                break
            for gid in changed:
                if by_id[gid]["_qs"]:
                    finalize(by_id[gid], fl, story, pre, hubs, skip)
            gone = {p["id"] for p in parts if not p["_qs"]}
            parts = [p for p in parts if p["_qs"]]
            orders = {f: [g for g in o if g not in gone] for f, o in orders.items()}
        stats["moves"] += fixed_moves
        stats["copies"] += copies
        stats["passes"] += it
        return parts, orders

    def frozen_resplit(parts, orders):
        """cut a guide the fix-up grew past MAX_STEPS into consecutive parts that take its place in both orders
        (in-guide prerequisite order first, so no cut separates a quest from a later prerequisite)"""
        out, cut = [], False
        for p in parts:
            if p["steps"] <= MAX_STEPS:
                out.append(p)
                continue
            qs = p["_qs"]
            ids = defaultdict(list)
            for q in qs:
                ids[q.qid].append(q)
            preds = {id(q): {id(o) for x in pre.get(q.qid, ()) for o in ids.get(x, ()) if o is not q} for q in qs}
            succ = defaultdict(list)
            for q in qs:
                for x in preds[id(q)]:
                    succ[x].append(q)
            indeg = {id(q): len(preds[id(q)]) for q in qs}
            heap = [(q.rank, id(q), q) for q in qs if indeg[id(q)] == 0]
            heapq.heapify(heap)
            topo, seen = [], set()
            while len(topo) < len(qs):
                if not heap:
                    q = min((q for q in qs if id(q) not in seen), key=lambda q: q.rank)
                    heapq.heappush(heap, (q.rank, id(q), q))
                _, _, q = heapq.heappop(heap)
                if id(q) in seen:
                    continue
                seen.add(id(q))
                topo.append(q)
                for sq in succ[id(q)]:
                    indeg[id(sq)] -= 1
                    if indeg[id(sq)] == 0 and id(sq) not in seen:
                        heapq.heappush(heap, (sq.rank, id(sq), sq))
            for r, q in enumerate(topo):
                q.rank = r
            pieces = split(topo, fl, story)
            if len(pieces) == 1:
                out.append(p)
                continue
            cut = True
            stats["cuts"] += 1
            news = []
            for j, piece in enumerate(pieces):
                c = dict(p)
                c.update({"_qs": list(piece), "id": f"{p['id']}~{j + 1}"})
                news.append(c)
            out.extend(news)
            for f in orders:
                if p["id"] in orders[f]:
                    k = orders[f].index(p["id"])
                    orders[f][k:k + 1] = [c["id"] for c in news]
        if cut:
            # renumber the zone guides that were cut: base:1..n, in the order the parts sit on the Alliance spine
            # (both spines keep a zone's parts in the same order)
            for base in {p["base"] for p in out if "~" in p["id"]}:
                ps = [p for p in out if p["base"] == base]
                rank = {}
                for i, g in enumerate(orders["Alliance"]):
                    rank.setdefault(g, i)
                for i, g in enumerate(orders["Horde"]):
                    rank.setdefault(g, 1_000_000 + i)
                ps.sort(key=lambda p: (rank.get(p["id"], 1 << 30), p["part"]))
                ren = {}
                for k, p in enumerate(ps, 1):
                    new_id = base if len(ps) == 1 else f"{base}:{k}"
                    ren[p["id"]] = new_id
                    p.update({"id": new_id, "part": k, "parts": len(ps),
                              "rule": p["rule"] if p["rule"] != "none" else ("storyline" if (fl == "retail" and story.ok) else "level")})
                    finalize(p, fl, story, pre, hubs, skip)
                for f in orders:
                    orders[f] = [ren.get(g, g) for g in orders[f]]
        return out, orders, cut

    for _k in range(4):
        parts, orders = fixup(parts, orders)
        parts, orders, cut = frozen_resplit(parts, orders)
        if not cut:
            break
    else:
        parts, orders = fixup(parts, orders)
    ORDERS.clear()
    ORDERS.update(orders)
    print(f"  {fl}: final fix-up on the frozen spine: {stats['moves']} quests moved forward, {stats['copies']} faction "
          f"copies, {stats['passes']} passes, {stats['cuts']} oversize guides cut in place")
    hard = set()
    for p in parts:
        del p["_qs"]
        del p["_zrng"]
    HARD[:] = sorted(hard)
    if os.environ.get("SPINE_DEBUG"):
        print("  top movers:", sorted(nmov.items(), key=lambda kv: -kv[1])[:8])
    for q, p in CYCLES:
        g = next((x["id"] for x in parts if q in x["quests"]), "")
        cycles.append((g, q, p))
    del CYCLES[:]
    print(f"  {fl}: {moved_total} quest moves into a later guide holding a prerequisite "
          f"({moved_zone[0]} of them into another zone's guide)")
    return parts, cycles


def write_sidecar(fl, parts, pre, cycles, out_dir=None):
    """out_dir (gen_wiki_guides.py --out): the sidecar goes there instead of tools/wiki/cache"""
    (out_dir or CACHE).mkdir(parents=True, exist_ok=True)
    side = {"flavor": fl, "generated": datetime.date.today().isoformat(),
            "parts": [{k: v for k, v in p.items() if k != "lines"} for p in parts],
            "pre": {str(q): sorted(ps) for q, ps in pre.items() if ps},
            "cycles": cycles, "hard": list(HARD), "orders": dict(ORDERS)}
    ((out_dir or CACHE) / f"parts_{fl}.json").write_text(json.dumps(side), encoding="utf-8")


# ---------------------------------------------------------------------------------------------------------------
# the spine
# ---------------------------------------------------------------------------------------------------------------
def spine_key(p, fl, enemy=False):
    """enemy: a both-faction guide in a zone whose faction quests are almost all the other faction's (neutral
    quests in an enemy capital or starting zone) - those come at the end of the faction's spine"""
    e = 1 if enemy else 0
    lv = p["lvl_med"] if p["lvl_med"] is not None else 999
    lo = p["minlevel"] or 999
    zn = p["zone_name"]
    if fl == "retail":
        starter = 0 if (p["zone_lo"] is not None and p["zone_lo"] <= 1) else 1
        exp = p["expansion"] or 99
        camp = p["campaign"] if p["campaign"] is not None else 1 << 30
        zl = p["zone_lo"] if p["zone_lo"] is not None else 999
        return (e, starter, exp, camp, zl, lv, zn, p["part"])
    return (e, lv, lo, zn, p["part"])


def build_spine_for(fl, faction, parts, pre, hard=frozenset(), fixed=None):
    nodes = [p for p in parts if p["faction"] in (faction, "Both") and p["zone"] is not None]
    nid = {p["id"]: i for i, p in enumerate(nodes)}
    q_part = {}

    def mine(p, q):
        """a quest moved into a both-faction guide keeps its own faction"""
        return p.get("qfac", {}).get(str(q), faction) in (faction, "Both")
    for i, p in enumerate(nodes):
        for q in p["quests"]:
            if mine(p, q):
                q_part[q] = i
    own = Counter()
    for p in parts:
        if p["faction"] in ("Alliance", "Horde"):
            own[(p["zone"], p["faction"])] += len(p["quests"])
    other = "Horde" if faction == "Alliance" else "Alliance"

    def enemy(p):
        if p["faction"] != "Both":
            return False
        o, m = own[(p["zone"], other)], own[(p["zone"], faction)]
        return o >= 5 and o >= 3 * max(1, m)
    keys = [spine_key(p, fl, enemy(p)) for p in nodes]
    succ = defaultdict(set)
    preds = defaultdict(set)

    def edge(a, b):
        if a != b and b not in succ[a]:
            succ[a].add(b)
            preds[b].add(a)
    by_base = defaultdict(list)
    for i, p in enumerate(nodes):
        by_base[p["base"]].append(i)
    for b, ix in by_base.items():
        ix.sort(key=lambda i: nodes[i]["part"])
        for a, c in zip(ix, ix[1:]):
            edge(a, c)
    for i, p in enumerate(nodes):
        for q in p["quests"]:
            if not mine(p, q):
                continue
            opts = [q_part[x] for x in pre.get(q, ()) if x in q_part]
            if not opts or i in opts:
                continue
            j = min(opts, key=lambda j: keys[j])
            # only a prerequisite that sorts earlier anyway becomes a hard edge; one that sorts later (a level-1
            # zone with one quest that needs a level-30 guide) would drag the whole guide back, so it is left as a
            # violation and build_parts moves that quest into the later guide instead
            if keys[j] <= keys[i] or q in hard:
                edge(j, i)
    indeg = {i: len(preds[i]) for i in range(len(nodes))}
    if fixed is not None:
        # a frozen order (build_parts' final fix-up): keep it, append any guide it does not list
        known = [nid[g] for g in fixed if g in nid]
        rest = sorted((i for i in range(len(nodes)) if i not in set(known)), key=lambda i: keys[i])
        indeg = {}
        heap = []
    else:
        known, rest = None, None
        heap = [(keys[i], i) for i in range(len(nodes)) if indeg[i] == 0]
    heapq.heapify(heap)
    order, placed, forced = [], set(), 0
    if known is not None:
        order, placed = known + rest, set(known + rest)
    while len(order) < len(nodes):
        if not heap:
            # a cycle between guides: release a guide whose own zone's earlier parts are all placed, with the fewest
            # open predecessors (the repair pass in build_parts then moves the quests that this leaves early)
            rest = [j for j in range(len(nodes)) if j not in placed]
            okb = [j for j in rest if not any(a not in placed and nodes[a]["base"] == nodes[j]["base"] for a in preds[j])]
            i = min(okb or rest, key=lambda j: (sum(1 for a in preds[j] if a not in placed), keys[j]))
            forced += 1
            indeg[i] = 0
            heapq.heappush(heap, (keys[i], i))
        _, i = heapq.heappop(heap)
        if i in placed:
            continue
        placed.add(i)
        order.append(i)
        for s in succ[i]:
            if s not in placed:
                indeg[s] -= 1
                if indeg[s] == 0:
                    heapq.heappush(heap, (keys[s], s))
    pos = {i: k for k, i in enumerate(order)}
    # violations, with the client's "any one of" PRE semantics
    viol = []
    for i in order:
        p = nodes[i]
        for q in p["quests"]:
            if not mine(p, q):
                continue
            ps = pre.get(q, ())
            if not ps:
                continue
            opts = [x for x in ps if x in q_part]
            if not opts:
                viol.append((p["id"], q, "pre_not_in_spine", ";".join(str(x) for x in sorted(ps))))
                continue
            ok = False
            for x in opts:
                j = q_part[x]
                if pos[j] < pos[i]:
                    ok = True
                elif j == i:
                    def ix(tab, n):
                        t = p[tab]
                        return t.get(f"{n}@{faction}", t.get(str(n)))
                    ti, ai = ix("t_idx", x), ix("a_idx", q)
                    if ti is not None and ai is not None and ti < ai:
                        ok = True
                    elif ti is None and ai is not None:
                        # a prerequisite with no turn-in step (bonus objective): accepted earlier is enough
                        aj = ix("a_idx", x)
                        ok = aj is not None and aj < ai
                if ok:
                    break
            if not ok:
                viol.append((p["id"], q, "pre_after", ";".join(str(x) for x in sorted(opts))))
    return [nodes[i] for i in order], viol, forced


def lua_str(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


def build_spine(fl, gate_line=None, out_dir=None):
    """out_dir (gen_wiki_guides.py --out): read the sidecar from that folder and write the spine file and the chart
    (verification.sqlite) there, nothing in the checkout"""
    side_p = (out_dir or CACHE) / f"parts_{fl}.json"
    if not side_p.exists():
        print(f"  spine {fl}: no {side_p.name} - run tools/wiki/gen_wiki_guides.py {fl} first")
        return None
    side = json.loads(side_p.read_text(encoding="utf-8"))
    parts = side["parts"]
    pre = {int(q): [int(x) for x in ps] for q, ps in side["pre"].items()}
    gate_line = gate_line or f'if NS.flavor ~= "{fl}" then return end'
    today = datetime.date.today().isoformat()
    hdr = [
        f"-- Completionist's Guide :: Imported_Spine_{fl}.lua - GENERATED {today} by tools/wiki/gen_spine.py",
        "-- The generated leveling path: the Imported_Wiki_" + fl + ".lua zone guides (Warcraft Wiki, CC BY-SA 4.0,",
        "-- https://warcraft.wiki.gg) chained per faction by level band" +
        (", expansion and campaign order (Blizzard QuestLine/Campaign client tables via wago.tools, facts only)."
         if fl == "retail" else " and the wiki's quest chains."),
        "-- Every entry reuses the zone guide's text (nothing is copied); `next` is the following entry.",
        "local _, NS = ...", gate_line,
        "local G = NS.Guide",
        "local function T(id) return function() local g = G.registry[id] if not g then return \"\" end",
        "    local t = g.text if type(t) == \"function\" then t = t() end return t or \"\" end end",
        "local R = G.Register", "",
    ]
    body, rows, vrows, stats = [], [], [], {}
    for faction, fk in (("Alliance", "A"), ("Horde", "H")):
        seq, viol, forced = build_spine_for(fl, faction, parts, pre, frozenset(side.get("hard", ())),
                                            fixed=side.get("orders", {}).get(faction))
        floor_min = 1
        for k, p in enumerate(seq, 1):
            sid = f"spine:{fl}:{fk}:{k:03d}"
            nxt = f'"spine:{fl}:{fk}:{k + 1:03d}"' if k < len(seq) else "nil"
            # the menu sorts by minlevel, then name: keep minlevel monotone so the folder reads in spine order
            floor_min = max(floor_min, p["minlevel"] or 1)
            maxl = max(p["maxlevel"] or floor_min, floor_min)
            zf = str(p["zone"]) if p["zone"] is not None else '"Other"'
            body.append(f'R({{ id="{sid}", name="{k:03d}. {lua_str(p["name"])}", type="Leveling", '
                        f'folder="Leveling (generated)", zone={zf}, faction="{faction}", minlevel={floor_min}, '
                        f'maxlevel={maxl}, next={nxt}, part="{p["id"]}", '
                        # Forever zone guides are already on Forever maps (forever=true); the spine entry
                        # copies their text, so it must skip the runtime Era->Forever conversion too
                        + ('forever=true, ' if fl == "forever" else '')
                        + f'author="Warcraft Wiki contributors '
                        f'(CC BY-SA 4.0); order: CompletionRoute", source="CompletionRoute", text=T("{p["id"]}") }})')
            rows.append((fl, faction, k, p["id"], p["zone_name"], p["minlevel"], p["maxlevel"], len(p["quests"]),
                         p["steps"], sid, p["name"]))
        for gid, q, why, det in viol:
            vrows.append((fl, gid, q, why, faction, det))
        c = Counter(v[2] for v in viol)
        stats[faction] = {"guides": len(seq), "quests": sum(len(p["quests"]) for p in seq),
                          "steps": sum(p["steps"] for p in seq), "pre_after": c.get("pre_after", 0),
                          "pre_not_in_spine": c.get("pre_not_in_spine", 0), "cycles_forced": forced}
    out = (out_dir or GUIDES) / f"Imported_Spine_{fl}.lua"
    out.write_text("\n".join(hdr + body) + "\n", encoding="utf-8")
    con = sqlite3.connect(out_dir / "verification.sqlite" if out_dir else VERIF)
    con.executescript("""
    create table if not exists spine_order(flavor text, faction text, position int, guide_id text, zone text,
        level_min int, level_max int, quests int, steps int, spine_id text, name text);
    create table if not exists spine_violations(flavor text, guide_id text, quest_id int, reason text,
        faction text, detail text);
    create table if not exists guide_parts(flavor text, base_id text, guide_id text, part int, parts int,
        rule text, steps int, quests int, level_min int, level_max int, name text);
    """)
    con.execute("delete from spine_order where flavor=?", (fl,))
    con.execute("delete from spine_violations where flavor=?", (fl,))
    con.execute("delete from guide_parts where flavor=?", (fl,))
    con.executemany("insert into spine_order values (?,?,?,?,?,?,?,?,?,?,?)", rows)
    con.executemany("insert into spine_violations values (?,?,?,?,?,?)", vrows)
    con.executemany("insert into spine_violations values (?,?,?,?,?,?)",
                    [(fl, g, q, "pre_cycle", "", f"wiki chain cycle: {p} not before {q} inside the zone")
                     for g, q, p in side.get("cycles", [])])
    con.executemany("insert into guide_parts values (?,?,?,?,?,?,?,?,?,?,?)",
                    [(fl, p["base"], p["id"], p["part"], p["parts"], p["rule"], p["steps"], len(p["quests"]),
                      p["minlevel"], p["maxlevel"], p["name"]) for p in parts])
    con.commit()
    bases = len({p["base"] for p in parts})
    over = sum(1 for p in parts if p["steps"] > MAX_STEPS)
    print(f"  spine {fl}: zone guides {bases} -> {len(parts)} guides ({over} over {MAX_STEPS} steps, "
          f"{len(side.get('cycles', []))} wiki chain cycles broken); " +
          "; ".join(f"{f}: {s['guides']} guides / {s['quests']} quests / {s['steps']} steps, pre_after "
                    f"{s['pre_after']}, pre_not_in_spine {s['pre_not_in_spine']}, forced {s['cycles_forced']}"
                    for f, s in stats.items()))
    return stats


def main():
    flavors = [a for a in sys.argv[1:] if not a.startswith("--")] or ["era", "tbc", "mop", "retail"]
    gates = {}
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import gen_wiki_guides  # noqa: E402  (only for the flavor guard line)
        gates = {f: gen_wiki_guides.flavor_gate(f) for f in flavors} if hasattr(gen_wiki_guides, "flavor_gate") else {}
    except Exception:
        pass
    for fl in flavors:
        build_spine(fl, gates.get(fl))


if __name__ == "__main__":
    main()
