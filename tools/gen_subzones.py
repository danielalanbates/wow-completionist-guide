#!/usr/bin/env python3
# CompletionRoute :: tools/gen_subzones.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Subzone centres per client from Blizzard map data (wago.tools DB2, the client's own build; tools/wiki/fetch_db2.py).

UiMapAssignment gives almost no subzone rows (0 on era, tbc and forever; 31 on mop; 124 on retail), so the source is
the explored-area overlays instead: WorldMapOverlay (AreaID_0..3, hit rectangle in map-art pixels) -> UiMapXMapArt
(art -> uiMap) -> UiMapArt -> UiMapArtStyleLayer (art size in pixels, layer 0).  Each overlay that covers exactly one
AreaTable area that is a subzone (ParentAreaID != 0) gives that area a rectangle on a uiMap; its centre, in the map's
0-100 coordinates, is the subzone point.  An area whose overlays on one map are more than MAX_SPAN units apart is left
out (two places of one name).  An area that has no single-area overlay at all (Booty Bay, Honor Hold, Ammen Vale) takes
the rectangle of the overlays it shares with other areas, but only when that rectangle spans SHARED_SPAN units or less
each way, so its centre lies within a few yards of every area in it; such points carry "shared": true.

    python3 tools/gen_subzones.py [flavor ...]     # writes tools/db2/<flavor>/Subzones.json, prints counts
    import gen_subzones as GS; GS.load("era")      # {norm(name): [{"area", "name", "parent", "parent_name", "map", "x", "y"}]}
"""
import csv, json, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DB2 = ROOT / "tools" / "db2"
FLAVORS = ("era", "tbc", "forever", "mop", "retail")
TABLES = ("AreaTable", "WorldMapOverlay", "UiMapXMapArt", "UiMapArt", "UiMapArtStyleLayer")
MAX_SPAN = 25.0
SHARED_SPAN = 12.0
csv.field_size_limit(1 << 28)


def norm(s):
    """the match key: lower case letters and digits, a trailing wiki disambiguator dropped ("Valley of Honor
    (Orgrimmar)" -> "valleyofhonor")"""
    s = re.sub(r"\s*\([^()]*\)\s*$", "", s or "")
    return re.sub(r"[^0-9a-z]", "", s.lower())


def _rows(fl, t):
    p = DB2 / fl / f"{t}.csv"
    if not p.exists():
        sys.path.insert(0, str(ROOT / "tools" / "wiki"))
        import db2_fetch  # noqa: E402
        p = db2_fetch.fetch(fl, t)
        if not p:
            return []
    with open(p, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def build(fl):
    area = {r["ID"]: r for r in _rows(fl, "AreaTable")}
    size = {}
    for r in _rows(fl, "UiMapArtStyleLayer"):
        if r["LayerIndex"] == "0":
            size[r["UiMapArtStyleID"]] = (float(r["LayerWidth"]), float(r["LayerHeight"]))
    art_wh = {r["ID"]: size.get(r["UiMapArtStyleID"]) for r in _rows(fl, "UiMapArt")}
    art_map = {}
    for r in _rows(fl, "UiMapXMapArt"):
        if r["PhaseID"] == "0":
            art_map.setdefault(r["UiMapArtID"], r["UiMapID"])
    boxes, shared = {}, {}      # (area, uiMap) -> [x0, y0, x1, y1] in 0-100; single-area / shared overlays
    for r in _rows(fl, "WorldMapOverlay"):
        ids = [r[f"AreaID_{i}"] for i in range(4) if r.get(f"AreaID_{i}", "0") not in ("0", "")]
        subs = [i for i in ids if i in area and area[i]["ParentAreaID"] != "0"]
        if not subs:
            continue
        wh, mid = art_wh.get(r["UiMapArtID"]), art_map.get(r["UiMapArtID"])
        if not wh or not mid or not wh[0] or not wh[1]:
            continue
        l, rt, t, b = (float(r[k]) for k in ("HitRectLeft", "HitRectRight", "HitRectTop", "HitRectBottom"))
        if rt <= l or b <= t:   # no hit rectangle: the texture's own
            l, t = float(r["OffsetX"]), float(r["OffsetY"])
            rt, b = l + float(r["TextureWidth"]), t + float(r["TextureHeight"])
        bx = [l / wh[0] * 100, t / wh[1] * 100, rt / wh[0] * 100, b / wh[1] * 100]
        dest = boxes if len(ids) == 1 else shared
        for aid in (subs if len(ids) > 1 else ids if ids == subs else []):
            k = (aid, int(mid))
            b = bx
            if k in dest:
                o = dest[k]
                b = [min(o[0], b[0]), min(o[1], b[1]), max(o[2], b[2]), max(o[3], b[3])]
            dest[k] = b
    single = {aid for aid, _ in boxes}
    rows = [(k, v, False) for k, v in boxes.items()]
    rows += [(k, v, True) for k, v in shared.items() if k[0] not in single]
    out = {}
    for (aid, mid), (x0, y0, x1, y1), sh in sorted(rows, key=lambda kv: (int(kv[0][0]), kv[0][1])):
        lim = SHARED_SPAN if sh else MAX_SPAN * 2
        if x1 - x0 > lim or y1 - y0 > lim:
            continue
        a = area[aid]
        p = area.get(a["ParentAreaID"], {})
        out.setdefault(norm(a["AreaName_lang"].strip()), []).append({
            "area": int(aid), "name": a["AreaName_lang"].strip(), "parent": int(a["ParentAreaID"]),
            "parent_name": p.get("AreaName_lang", ""), "map": mid,
            "x": round(max(0.0, min(100.0, (x0 + x1) / 2)), 1), "y": round(max(0.0, min(100.0, (y0 + y1) / 2)), 1)})
        if sh:
            out[norm(a["AreaName_lang"].strip())][-1]["shared"] = True
    return out


def load(fl):
    p = DB2 / fl / "Subzones.json"
    if not p.exists():
        if not all((DB2 / fl / f"{t}.csv").exists() for t in TABLES):
            return {}
        p.write_text(json.dumps(build(fl), sort_keys=True, indent=0), encoding="utf-8")
    return json.loads(p.read_text(encoding="utf-8"))


if __name__ == "__main__":
    for fl in sys.argv[1:] or FLAVORS:
        d = build(fl)
        (DB2 / fl / "Subzones.json").write_text(json.dumps(d, sort_keys=True, indent=0), encoding="utf-8")
        print(fl, "names", len(d), "points", sum(len(v) for v in d.values()))
