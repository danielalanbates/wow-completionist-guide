#!/usr/bin/env python3
# CompletionRoute :: tools/test_subzones.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""tools/gen_subzones.py: subzone centres from WorldMapOverlay, on a tiny synthetic DB2 set, plus known places on the
real tables when they are present (skipped otherwise).   python3 tools/test_subzones.py"""
import csv, sys, tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_subzones as GS  # noqa: E402

fails = 0


def check(ok, msg):
    global fails
    if not ok:
        fails += 1
        print("FAIL", msg)


def write(d, name, rows):
    with open(d / f"{name}.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)


with tempfile.TemporaryDirectory() as td:
    d = Path(td) / "x"
    d.mkdir()
    write(d, "AreaTable", [
        {"ID": "14", "AreaName_lang": "Durotar", "ParentAreaID": "0"},
        {"ID": "362", "AreaName_lang": "Razor Hill", "ParentAreaID": "14"},
        {"ID": "363", "AreaName_lang": "Shared A", "ParentAreaID": "14"},
        {"ID": "364", "AreaName_lang": "Shared B", "ParentAreaID": "14"}])
    ov = lambda i, a0, a1="0", l="400", r="600", t="200", b="400": {
        "ID": i, "UiMapArtID": "5", "TextureWidth": "256", "TextureHeight": "256", "OffsetX": "380", "OffsetY": "180",
        "HitRectTop": t, "HitRectBottom": b, "HitRectLeft": l, "HitRectRight": r, "AreaID_0": a0, "AreaID_1": a1,
        "AreaID_2": "0", "AreaID_3": "0"}
    write(d, "WorldMapOverlay", [ov("1", "362"), ov("2", "363", "364"), ov("3", "14")])
    write(d, "UiMapXMapArt", [{"ID": "1", "PhaseID": "0", "UiMapArtID": "5", "UiMapID": "1411"}])
    write(d, "UiMapArt", [{"ID": "5", "UiMapArtStyleID": "1"}])
    write(d, "UiMapArtStyleLayer", [{"ID": "1", "LayerIndex": "0", "LayerWidth": "1000", "LayerHeight": "1000",
                                     "UiMapArtStyleID": "1"}])
    GS.DB2 = Path(td)
    t = GS.build("x")
    e = t.get("razorhill", [None])[0]
    check(e and e["map"] == 1411 and e["x"] == 50.0 and e["y"] == 30.0 and e["parent_name"] == "Durotar",
          f"Razor Hill centre {e}")
    check("shareda" not in t and "sharedb" not in t, "an overlay shared by two areas gives no point")
    check("durotar" not in t, "a zone (ParentAreaID 0) is not a subzone")
    check(GS.norm("Valley of Honor (Orgrimmar)") == "valleyofhonor", "wiki disambiguator dropped")

GS.DB2 = Path(__file__).resolve().parents[1] / "tools" / "db2"
known = {"era": [("razorhill", 1411, 54.6, 42.7), ("goldshire", 1429, 41.2, 64.7)],
         "tbc": [("bloodwatch", 1950, 54.7, 55.5)],
         "mop": [("klaxxivess", 422, 57.5, 31.9)]}
for fl, rows in known.items():
    if not all((GS.DB2 / fl / f"{x}.csv").exists() for x in GS.TABLES):
        print("skip", fl, "(DB2 tables not fetched)")
        continue
    t = GS.build(fl)
    for n, m, x, y in rows:
        e = next((e for e in t.get(n, []) if e["map"] == m), None)
        check(e and abs(e["x"] - x) < 3 and abs(e["y"] - y) < 3, f"{fl} {n} on {m}: {t.get(n)}")

# the location field's "formerly" guard (gen_wiki_guides Places.formerly): Magistrate Henry Maleb stands in Shadowfang
# Keep now and in Southshore on the Classic clients, so the Classic subzone rung must not place him at the keep
sys.path.insert(0, str(Path(__file__).resolve().parent / "wiki"))
import gen_wiki_guides as GW  # noqa: E402
pl = GW.Places.__new__(GW.Places)
pl.raw, pl.cache = None, {}
pages = {"Maleb": "{{Npcbox\n | name = Maleb\n | location = [[Shadowfang Keep]] ([[Silverpine Forest]])<br /> formerly "
                  "[[Southshore]], [[Hillsbrad Foothills]]\n}}",
         "Grull": "{{Npcbox\n | name = Grull\n | location = [[Camp Narache]], [[Mulgore]]\n}}"}
pl.text = pages.get
check(pl.formerly("Maleb"), "location field 'formerly' detected")
check(not pl.formerly("Grull"), "plain location field is not 'formerly'")
src = open(Path(__file__).resolve().parent / "wiki" / "gen_wiki_guides.py", encoding="utf-8").read()
check("if fl in CLASSICISH and self.places.formerly(page):" in src, "subzone rung checks Places.formerly on Classic")

# Dungeons guides (tools/wiki/gen_dungeons.py) copy the zone guides' step lines, so a subzone point reaches a dungeon
# step only when Imported_Dungeons_<fl>.lua is regenerated after Imported_Wiki_<fl>.lua (it was not, 11-26: the
# dungeon zone-only count stayed the same).  Every wiki subzone line of a quest the dungeon file carries must be in it.
GD = Path(__file__).resolve().parents[1] / "CompletionRoute" / "Guides"


def subzone_gap(fl, dfile=None):
    wf, df = GD / f"Imported_Wiki_{fl}.lua", Path(dfile) if dfile else GD / f"Imported_Dungeons_{fl}.lua"
    if not wf.exists() or not df.exists():
        return None
    qid = lambda ln: (ln.strip()[:1], ln.split("|QID|", 1)[1].split("|", 1)[0]) if "|QID|" in ln else None
    dl = df.read_text(encoding="utf-8").splitlines()
    dset, dq = {ln.strip() for ln in dl}, {qid(ln) for ln in dl}
    return [ln.strip() for ln in wf.read_text(encoding="utf-8").splitlines()
            if "(location: Blizzard map data for " in ln and qid(ln) in dq and ln.strip() not in dset]


check(subzone_gap("era", "/nonexistent") is None, "missing dungeon file is skipped")
for fl in ("era", "tbc", "forever", "mop", "retail"):
    gap = subzone_gap(fl)
    if gap is None:
        print("skip", fl, "dungeons (guides not generated)")
        continue
    check(not gap, f"{fl}: {len(gap)} wiki subzone steps missing from Imported_Dungeons (regenerate gen_dungeons.py); "
                   f"first: {gap[:1]}")

print("test_subzones:", "FAIL" if fails else "ok")
sys.exit(1 if fails else 0)
