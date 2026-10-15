#!/usr/bin/env python3
"""Audit every retail quest step's location (A accept / C complete / T turn-in) against authoritative data,
and write the committed correction table the addon applies at parse time.

    luajit tools/questie_spawns.lua "<questie_dir>"          # all Questie giver/ender spawns (gitignored)
    python3 tools/audit_quest_locations_retail.py [--write-fixes | --verify]

Inputs (all local; nothing is fetched):
  * steps as the addon itself parses them      tools/dump_quest_steps.lua retail (needs Guides/Imported_*_retail.lua)
  * Blizzard quest POI                         tools/db2/retail/QuestPOIBlob.csv + QuestPOIPoint.csv
                                               (ObjectiveIndex -1 = turn-in pin, 0..31 = objective areas)
  * Questie giver/ender spawns (pre-MoP quests) tools/db2/questie_spawns.tsv
  * map bounds                                  tools/maps_retail.lua   (percent -> world yards)

Rules (docs/STATUS.md "Quest location audit"):
  T  -> nearest Blizzard turn-in pin or Questie ender spawn.
  C  -> the objective's POI area (inside the polygon, or within 40 yd of it); no QO = any objective.
  A  -> nearest Questie giver spawn.  Post-MoP quests have no giver reference: they are corrected only by
        cross-source consensus (2+ independent sources agree within 40 yd and this one is farther).
        The three generated files (Quests/Storylines/Achievements) come from the same Blizzard data and
        count as ONE source for consensus; WoW-Pro and the legacy guides are the other two.
  A step is WRONG when it is > 40 yd from every reference (or on another continent/instance), its map
  is unknown, or its coordinates are outside 0-100.  It is corrected to the nearest reference.
Outputs: docs/quest_location_audit_retail.tsv, table quest_location_audit in docs/verification.sqlite, and
with --write-fixes CompletionRoute/Data/QuestCoordFixes_retail.lua (keyed by the step's own old location,
so only the exact wrong step is moved; applied by Core/Guide.lua G.Steps).
"""
import collections, csv, math, re, sqlite3, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DB2 = ROOT / "tools" / "db2"
TOL = 40.0
GENERATED = {"Imported_Quests_retail", "Imported_Storylines_retail", "Imported_Achievements_retail"}


def src_group(f):
    if f in GENERATED:
        return "blizzard"
    if f.startswith("Leveling/"):
        return "native"
    return f


def load_maps():
    txt = (ROOT / "tools" / "maps_retail.lua").read_text(encoding="utf-8")
    maps = {}
    for m in re.finditer(r'\[(\d+)\] = \{ "((?:[^"\\]|\\.)*)", (-?\d+), (-?[\d.]+), (-?[\d.]+), '
                         r'(-?[\d.]+), (-?[\d.]+), (\d+), (\d+) \}', txt):
        maps[int(m.group(1))] = dict(name=m.group(2).replace('\\"', '"'), inst=int(m.group(3)),
                                     topX=float(m.group(4)), leftY=float(m.group(5)),
                                     w=float(m.group(6)), h=float(m.group(7)), parent=int(m.group(8)),
                                     type=int(m.group(9)))
    return maps


MAPS = load_maps()


def to_world(mid, x, y):
    """percent coords on uiMap -> (inst, wx, wy) in yards; None if the map has no bounds"""
    m = MAPS.get(mid)
    if not m or m["w"] == 0 or m["h"] == 0:
        return None
    return (m["inst"], m["topX"] - y / 100.0 * m["h"], m["leftY"] - x / 100.0 * m["w"])


def to_map(mid, wx, wy):
    m = MAPS[mid]
    return ((m["leftY"] - wy) / m["w"] * 100.0, (m["topX"] - wx) / m["h"] * 100.0)


def best_map(inst, wx, wy, prefer=None):
    """the zone map (type 3, else smallest) containing a world point; prefer a given map if it contains it"""
    def inside(mid):
        m = MAPS[mid]
        if m["inst"] != inst or m["w"] == 0:
            return False
        x, y = to_map(mid, wx, wy)
        return 0 <= x <= 100 and 0 <= y <= 100
    if prefer and prefer in MAPS and inside(prefer):
        return prefer
    cands = [mid for mid in MAPS if inside(mid)]
    if not cands:
        return None
    zones = [c for c in cands if MAPS[c]["type"] == 3]
    pool = zones or [c for c in cands if MAPS[c]["type"] >= 3] or cands
    return min(pool, key=lambda c: (MAPS[c]["w"] * MAPS[c]["h"], c))


# zone name -> canonical retail uiMap (same rule as gen_quest_guides_retail.py)
BYNAME = {}
for _mid, _m in sorted(MAPS.items()):
    _p = BYNAME.get(_m["name"])
    if _p is None or (_m["type"] == 3 and MAPS[_p]["type"] != 3):
        BYNAME[_m["name"]] = _mid


def dist(a, b):
    if a[0] != b[0]:
        return math.inf
    return math.hypot(a[1] - b[1], a[2] - b[2])


def seg_dist(p, a, b):
    ax, ay, bx, by, px, py = a[0], a[1], b[0], b[1], p[0], p[1]
    dx, dy = bx - ax, by - ay
    L = dx * dx + dy * dy
    t = 0 if L == 0 else max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / L))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


class Area:
    """a POI blob in world space"""
    def __init__(self, inst, mid, pts):
        self.inst, self.mid, self.pts = inst, mid, pts
        self.c = (inst, sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts))

    def distance(self, w):
        if w[0] != self.inst:
            return math.inf
        p = (w[1], w[2])
        pts = self.pts
        if len(pts) >= 3:
            inside = False
            j = len(pts) - 1
            for i in range(len(pts)):
                xi, yi = pts[i]
                xj, yj = pts[j]
                if (yi > p[1]) != (yj > p[1]) and p[0] < (xj - xi) * (p[1] - yi) / (yj - yi) + xi:
                    inside = not inside
                j = i
            if inside:
                return 0.0
            return min(seg_dist(p, pts[i], pts[i - 1]) for i in range(len(pts)))
        if len(pts) == 2:
            return seg_dist(p, pts[0], pts[1])
        return math.hypot(p[0] - pts[0][0], p[1] - pts[0][1])

    def target(self, near=None):
        """centroid when it lies in the area (convex-ish blobs), else the vertex nearest the old spot"""
        if len(self.pts) < 3 or self.distance(self.c) == 0 or near is None:
            return self.c, self.mid
        p = min(self.pts, key=lambda q: math.hypot(q[0] - near[1], q[1] - near[2]))
        return (self.inst, p[0], p[1]), self.mid


def load_poi():
    pts = collections.defaultdict(list)
    for r in csv.DictReader((DB2 / "retail" / "QuestPOIPoint.csv").open(encoding="utf-8")):
        pts[r["QuestPOIBlobID"]].append((float(r["X"]), float(r["Y"])))
    turnin = collections.defaultdict(list)
    objs = collections.defaultdict(lambda: collections.defaultdict(list))
    for b in csv.DictReader((DB2 / "retail" / "QuestPOIBlob.csv").open(encoding="utf-8")):
        oi, mid, qid = int(b["ObjectiveIndex"]), int(b["UiMapID"]), int(b["QuestID"])
        p = pts.get(b["ID"])
        if not p or oi == 32 or mid not in MAPS or MAPS[mid]["w"] == 0:
            continue
        a = Area(MAPS[mid]["inst"], mid, p)
        x, y = to_map(mid, a.c[1], a.c[2])
        if not (-2 <= x <= 102 and -2 <= y <= 102):   # pin off its own map: the generator drops these too
            continue
        (turnin[qid] if oi == -1 else objs[qid][oi]).append(a)
    return turnin, objs


def load_questie():
    out = collections.defaultdict(lambda: {"A": [], "T": []})
    path = DB2 / "questie_spawns.tsv"
    if not path.exists():
        print("WARN no tools/db2/questie_spawns.tsv (run tools/questie_spawns.lua): no giver references")
        return out
    for r in csv.DictReader(path.open(encoding="utf-8"), delimiter="\t"):
        mid = BYNAME.get(r["zone"])
        if mid is None:
            continue
        w = to_world(mid, float(r["x"]), float(r["y"]))
        if w:
            out[int(r["qid"])][r["role"]].append((w, mid))
    return out


class Pt:
    def __init__(self, w, mid):
        self.w, self.mid = w, mid

    def distance(self, w):
        return dist(self.w, w)

    def target(self, near=None):
        return self.w, self.mid


def read_steps(mode="nofix"):
    path = ROOT / "tools" / "db2" / "retail" / "quest_steps_dump.tsv"
    with path.open("w", encoding="utf-8") as fh:
        subprocess.run(["luajit", "tools/dump_quest_steps.lua", "retail", mode], cwd=ROOT, check=True, stdout=fh)
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        f = line.split("\t")
        rows.append(dict(file=f[0], guide=f[1], line=int(f[2]), action=f[3],
                         qids=[int(q) for q in f[4].split(",") if q], qo=f[5],
                         map=int(f[6]) if f[6] else None, x=float(f[7]) if f[7] else None,
                         y=float(f[8]) if f[8] else None, zname=f[9], ncoords=int(f[10]),
                         fixed=(len(f) > 11 and f[11] == "fixed"), key=f[12] if len(f) > 12 else ""))
    return rows


def fmt(mid, x, y):
    return "" if x is None else f"{mid}:{x:.1f},{y:.1f}"


def main():
    write = "--write-fixes" in sys.argv
    verify = "--verify" in sys.argv     # re-audit WITH the fix table applied: residual errors only, no outputs
    turnin, objs = load_poi()
    qz = load_questie()
    steps = read_steps("fix" if verify else "nofix")
    print(f"steps={len(steps)} poi_turnin={len(turnin)} poi_obj={len(objs)} questie={len(qz)}")

    # consensus pool: (action, qid, qo) -> source group -> [world points]
    pool = collections.defaultdict(lambda: collections.defaultdict(list))
    for s in steps:
        if s["x"] is None or s["map"] is None or len(s["qids"]) != 1:
            continue
        w = to_world(s["map"], s["x"], s["y"])
        if w and 0 <= s["x"] <= 100 and 0 <= s["y"] <= 100:
            key = (s["action"], s["qids"][0], s["qo"] if s["action"] == "C" else "")
            pool[key][src_group(s["file"])].append((w, s["map"]))

    def refs_for(action, qid, qo, file=""):
        """(kind, [reference objects])"""
        if action == "C" and file == "Imported_Achievements_retail":
            # achievement criteria "complete quest X": done at the turn-in, or anywhere in its objectives
            r = turnin.get(qid, []) + [a for lst in objs.get(qid, {}).values() for a in lst]
            r += [Pt(w, m) for w, m in qz[qid]["T"]] if qid in qz else []
            return ("quest-completion", r)
        if action == "T":
            r = turnin.get(qid, []) + [Pt(w, m) for w, m in qz[qid]["T"]] if qid in qz else turnin.get(qid, [])
            return ("poi-turnin/questie-ender", r)
        if action == "C":
            o = objs.get(qid)
            if not o:
                return ("poi-objective", [])
            try:
                oi = int(qo) - 1
            except ValueError:
                oi = None
            if oi is not None and oi in o:
                return ("poi-objective", o[oi])
            return ("poi-objective-any", [a for lst in o.values() for a in lst])
        if qid in qz and qz[qid]["A"]:
            return ("questie-giver", [Pt(w, m) for w, m in qz[qid]["A"]])
        return ("none", [])

    def consensus(action, qid, qo, group):
        """a location 2+ OTHER independent sources agree on within TOL, or None"""
        key = (action, qid, qo if action == "C" else "")
        others = [(g, pts) for g, pts in pool.get(key, {}).items() if g != group and g != "native"]
        if len(others) < 2:
            return None
        (g1, p1), (g2, p2) = others[0], others[1]
        best = None
        for a in p1:
            for b in p2:
                d = dist(a[0], b[0])
                if d <= TOL and (best is None or d < best[0]):
                    best = (d, a)
        return Pt(best[1][0], best[1][1]) if best else None

    results, fixes = [], {}
    for s in steps:
        if len(s["qids"]) != 1:      # "accept all of these" multi-QID steps carry one shared pin
            continue
        qid, action, qo = s["qids"][0], s["action"], s["qo"]
        kind, refs = refs_for(action, qid, qo, s["file"])
        old = fmt(s["map"], s["x"], s["y"])
        status, d, new, problem = "ok", None, "", ""
        w = None
        if s["x"] is not None:
            if not (0 <= s["x"] <= 100 and 0 <= s["y"] <= 100):
                problem = "coords-out-of-range"
            elif s["map"] is None:
                problem = "unknown-zone"
            else:
                w = to_world(s["map"], s["x"], s["y"])
                if w is None:
                    problem = "map-without-bounds"
        cons = None
        if not refs and action == "A":
            cons = consensus(action, qid, qo, src_group(s["file"]))
            if cons is not None:
                kind, refs = "consensus", [cons]
        if not refs:
            status = "no-reference"
        elif s["x"] is None:
            status = "missing-coords"
        elif problem == "map-without-bounds":
            status = "unchecked-map"
        else:
            if w is not None:
                ds = [(r.distance(w), r) for r in refs]
                d, r = min(ds, key=lambda t: t[0])
            else:
                r = refs[0]
                d = math.inf
            if d > TOL:
                status = problem or ("wrong-zone" if d == math.inf else "wrong")
            if w is not None and d > TOL and kind == "questie-giver":
                # Questie's giver data predates retail's revamps: require independent agreement before moving
                cons = consensus(action, qid, qo, src_group(s["file"]))
                if cons is None or min(x.distance(cons.w) for x in refs) > TOL:
                    status = "disputed"
        if status in ("wrong", "wrong-zone", "missing-coords", "coords-out-of-range", "unknown-zone"):
            if w is not None:
                r = min(refs, key=lambda t: t.distance(w))
            else:
                r = refs[0]
            tw, tmid = r.target(w)
            mid = None
            for cand in (s["map"], tmid):
                if cand in MAPS and MAPS[cand]["inst"] == tw[0] and MAPS[cand]["w"]:
                    cx, cy = to_map(cand, tw[1], tw[2])
                    if 0 <= cx <= 100 and 0 <= cy <= 100:
                        mid = cand
                        break
            mid = mid or best_map(tw[0], tw[1], tw[2]) or tmid
            nx, ny = to_map(mid, tw[1], tw[2])
            new = fmt(mid, nx, ny)
            if s["key"]:
                fixes[s["key"]] = (mid, round(nx, 2), round(ny, 2))
            status = status + "->fixed" if write else status
        results.append(dict(flavor="retail", guide_file=s["file"], guide=s["guide"], line=s["line"], qid=qid,
                            action=action + (qo if action == "C" and qo else ""), ref=kind, old_coords=old,
                            new_coords=new, distance_yd="" if d is None else ("inf" if d == math.inf else f"{d:.0f}"),
                            status=status))

    out = ROOT / "docs" / "quest_location_audit_retail.tsv"
    cols = ["flavor", "guide_file", "guide", "line", "qid", "action", "ref", "old_coords", "new_coords",
            "distance_yd", "status"]
    with out.open("w", encoding="utf-8", newline="") as fh:
        wr = csv.DictWriter(fh, cols, delimiter="\t", lineterminator="\n")
        wr.writeheader()
        for r in results:
            if r["status"] not in ("ok", "no-reference"):   # counted in the summary, not listed
                wr.writerow(r)

    summ = collections.defaultdict(collections.Counter)
    for r in results:
        st = r["status"].replace("->fixed", "")
        c = summ[r["guide_file"]]
        c["checked"] += 1
        c[st] += 1
        if r["status"].endswith("->fixed"):
            c["fixed"] += 1
    for f in sorted(summ):
        print(f, dict(summ[f]))
    if verify:
        return

    db = sqlite3.connect(ROOT / "docs" / "verification.sqlite")
    db.execute("CREATE TABLE IF NOT EXISTS quest_location_audit (flavor TEXT, guide_file TEXT, qid INTEGER, "
               "action TEXT, old_coords TEXT, new_coords TEXT, distance_yd TEXT, status TEXT, guide TEXT, "
               "line INTEGER, ref TEXT)")
    db.execute("DELETE FROM quest_location_audit WHERE flavor='retail'")
    db.executemany("INSERT INTO quest_location_audit VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                   [(r["flavor"], r["guide_file"], r["qid"], r["action"], r["old_coords"], r["new_coords"],
                     r["distance_yd"], r["status"], r["guide"], r["line"], r["ref"])
                    for r in results if r["status"] not in ("ok", "no-reference")])
    db.execute("CREATE TABLE IF NOT EXISTS quest_location_audit_summary (flavor TEXT, guide_file TEXT, "
               "checked INTEGER, ok INTEGER, wrong INTEGER, fixed INTEGER, no_reference INTEGER, disputed INTEGER, "
               "unchecked INTEGER)")
    db.execute("DELETE FROM quest_location_audit_summary WHERE flavor='retail'")
    for f, c in summ.items():
        wrong = sum(v for k, v in c.items() if k in ("wrong", "wrong-zone", "missing-coords",
                                                       "coords-out-of-range", "unknown-zone"))
        db.execute("INSERT INTO quest_location_audit_summary VALUES (?,?,?,?,?,?,?,?,?)",
                   ("retail", f, c["checked"], c["ok"], wrong, c["fixed"], c["no-reference"], c["disputed"],
                    c["unchecked-map"]))
    db.commit()

    if write:
        lines = ["-- GENERATED by tools/audit_quest_locations_retail.py --write-fixes.  Do not hand-edit: re-run it.",
                 "-- Quest step location corrections for retail, applied at parse time by Core/Guide.lua (G.Steps).",
                 "-- Key = action|qid|qo|old uiMap|old x,y (the step's own wrong location, 1 decimal) -> correct spot,",
                 "-- taken from Blizzard QuestPOI (turn-in pins / objective areas), Questie giver/ender spawns, or",
                 "-- cross-source consensus.  Only the exact wrong step moves; anything else is untouched.",
                 "local _, NS = ...",
                 'if NS.flavor ~= "retail" then return end',
                 "NS.QuestCoordFixes = {"]
        for k in sorted(fixes):
            mid, x, y = fixes[k]
            lines.append(f'["{k}"]={{{mid},{x},{y}}},')
        lines.append("}")
        (ROOT / "CompletionRoute" / "Data" / "QuestCoordFixes_retail.lua").write_text("\n".join(lines) + "\n",
                                                                                      encoding="utf-8")
        print(f"wrote {len(fixes)} fixes")


if __name__ == "__main__":
    main()
