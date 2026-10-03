#!/usr/bin/env python3
"""Generate CompletionRoute/Guides/Imported_Quests_retail.lua — every retail quest that has a map POI,
grouped into one "<Zone> Quests" guide per zone, with real coordinates.

    luajit  tools/questie_quest_index.lua "<questie_dir>"   # optional but recommended: names + faction
    python3 tools/gen_quest_guides_retail.py [build]        # default: newest wow build on wago.tools

Why this exists
---------------
Questie's database (tools/gen_quest_guides.lua) stops at MoP, so on retail the addon had NO community
quest guides at all offline — only the 113 WoW-Pro guides and whatever a Zygor installation lends at
runtime.  Retail's own client data does carry the quest map pins: QuestPOIBlob (quest -> uiMap +
objective index) and QuestPOIPoint (the world coordinates of each pin).  That is 21,766 quests with
locations, which is what the router actually needs.

What the data does and does not give
------------------------------------
* ObjectiveIndex -1  = the single "turn in here" pin.  It is the TURN-IN, and it is only a good guess
  for the quest giver: measured over 4,851 WoW-Pro quests carrying both, the giver sits within 50 yd
  of the ender just 58.6% of the time (p75 633 yd, p90 1,628 yd).  So the accept step prefers the real
  giver spawn from tools/db2/questie_index.tsv where Questie knows it, and only falls back to the
  turn-in pin otherwise — the step note says which of the two it is.
* ObjectiveIndex 0..31 = one objective area each; the centroid of its points becomes a C step.
* ObjectiveIndex 32   = the client's "next waypoint" hint, not an objective; skipped.
* Quest NAMES are not in client data (the server sends them).  Where tools/db2/questie_index.tsv
  exists (Questie's community database, see tools/questie_quest_index.lua) the real name, faction,
  class and level requirement are merged in; everything newer than MoP keeps a "Quest <id>" title that
  Core/Guide.lua swaps for the live one from C_QuestLog.GetTitleForQuestID.
* Faction/class/level gating therefore covers the old world (Questie) but not the modern expansions:
  in a Legion+ zone a guide still lists both factions' quests, and the ones you cannot take sit in the
  list until you skip them.  That is the main known limitation of these guides.

Output is gitignored (Blizzard game data, same as the other Imported_*.lua), the generator is not.
"""
import csv, io, re, subprocess, sys, collections
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / "tools" / "db2" / "retail"
OUT = ROOT / "CompletionRoute" / "Guides" / "Imported_Quests_retail.lua"
QUESTIE_INDEX = ROOT / "tools" / "db2" / "questie_index.tsv"
UA = "CompletionRoute-tools/1.0"


def newest_build():
    raw = subprocess.run(["curl", "-sS", "-m", "60", "-A", UA, "https://wago.tools/api/builds"],
                         check=True, capture_output=True).stdout.decode()
    import json
    return json.loads(raw)["wow"][0]["version"]


def fetch(table, build):
    """wago.tools DB2 csv, cached under tools/db2/retail/ so re-runs are offline"""
    path = CACHE / f"{table}.csv"
    if not path.exists() or path.stat().st_size == 0:
        CACHE.mkdir(parents=True, exist_ok=True)
        url = f"https://wago.tools/db2/{table}/csv?build={build}"
        data = subprocess.run(["curl", "-sS", "-L", "-m", "180", "-A", UA, url],
                              check=True, capture_output=True).stdout
        path.write_bytes(data)
    return list(csv.DictReader(io.StringIO(path.read_text(encoding="utf-8"))))


def load_maps():
    """tools/maps_retail.lua: [uiMapID] = { name, instanceID, topX, leftY, width, height, parent, type }"""
    txt = (ROOT / "tools" / "maps_retail.lua").read_text(encoding="utf-8")
    maps = {}
    for m in re.finditer(r'\[(\d+)\] = \{ "((?:[^"\\]|\\.)*)", (-?\d+), (-?[\d.]+), (-?[\d.]+), '
                         r'(-?[\d.]+), (-?[\d.]+), (\d+), (\d+) \}', txt):
        maps[int(m.group(1))] = dict(name=m.group(2).replace('\\"', '"').replace("\\\\", "\\"),
                                     inst=int(m.group(3)), topX=float(m.group(4)), leftY=float(m.group(5)),
                                     w=float(m.group(6)), h=float(m.group(7)),
                                     parent=int(m.group(8)), type=int(m.group(9)))
    return maps


def load_questie_index():
    """qid -> (name, faction, classes, minlevel) from tools/questie_quest_index.lua; optional"""
    if not QUESTIE_INDEX.exists():
        print("no tools/db2/questie_index.tsv - guides will use placeholder names and no gating")
        return {}
    out = {}
    for r in csv.DictReader(QUESTIE_INDEX.open(encoding="utf-8"), delimiter="\t"):
        out[int(r["qid"])] = dict(name=r["name"], faction=r["faction"], classes=r["classes"],
                                  minlevel=int(r["minlevel"] or 0), zone=r.get("giver_zone", ""),
                                  x=float(r.get("giver_x") or 0), y=float(r.get("giver_y") or 0))
    print(f"questie index: {len(out)} quests")
    return out


def main():
    build = sys.argv[1] if len(sys.argv) > 1 else newest_build()
    print(f"build {build}")
    qidx = load_questie_index()
    maps = load_maps()
    blobs = fetch("QuestPOIBlob", build)
    points = fetch("QuestPOIPoint", build)
    print(f"maps={len(maps)} blobs={len(blobs)} points={len(points)}")

    by_blob = collections.defaultdict(list)
    for p in points:
        by_blob[p["QuestPOIBlobID"]].append((float(p["X"]), float(p["Y"])))

    def to_zone(uimap, pts):
        """world coords -> (x01, y01) on uimap; None when the map is unknown or the point is off it"""
        m = maps.get(uimap)
        if not m or not pts or m["w"] == 0 or m["h"] == 0:
            return None
        wx = sum(p[0] for p in pts) / len(pts)
        wy = sum(p[1] for p in pts) / len(pts)
        y01 = (m["topX"] - wx) / m["h"]
        x01 = (m["leftY"] - wy) / m["w"]
        if not (-0.02 <= x01 <= 1.02 and -0.02 <= y01 <= 1.02):
            return None
        return min(max(x01, 0.0), 1.0), min(max(y01, 0.0), 1.0)

    quests = collections.defaultdict(lambda: dict(anchor=None, objectives={}))
    off_map = 0
    for b in blobs:
        oi = int(b["ObjectiveIndex"])
        if oi == 32:                      # client "next waypoint" hint, not an objective
            continue
        qid, uimap = int(b["QuestID"]), int(b["UiMapID"])
        pos = to_zone(uimap, by_blob.get(b["ID"], []))
        if not pos:
            off_map += 1
            continue
        rec = quests[qid]
        if oi == -1:
            if rec["anchor"] is None:
                rec["anchor"] = (uimap, pos)
        else:
            rec["objectives"].setdefault(oi, (uimap, pos))

    # group quests into zone guides by where they are handed in (else by their first objective)
    zones = collections.defaultdict(list)
    homeless = 0
    for qid, rec in quests.items():
        home = rec["anchor"][0] if rec["anchor"] else (
            rec["objectives"][min(rec["objectives"])][0] if rec["objectives"] else None)
        if home is None or home not in maps:
            homeless += 1
            continue
        zones[home].append(qid)

    # Quests the client knows (QuestV2) that have NO map pin but whose giver Questie has a spawn for:
    # without this pass they were in no guide at all.  They join the giver's zone guide with an accept
    # on the real giver and a location-less turn-in (the client names/places it once accepted).
    qv2 = CACHE / "QuestV2.csv"
    client_ids = {int(r["ID"]) for r in csv.DictReader(qv2.open(encoding="utf-8"))} if qv2.exists() else set()
    byname0 = {}
    for mid, m in sorted(maps.items()):
        if m["name"] not in byname0 or (m["type"] == 3 and maps[byname0[m["name"]]]["type"] != 3):
            byname0[m["name"]] = mid
    unpinned = 0
    for qid, e in qidx.items():
        if qid in quests or qid not in client_ids or not e["zone"] or e["x"] <= 0:
            continue
        mid = byname0.get(e["zone"])
        if mid is None:
            continue
        quests[qid]["unpinned"] = True
        zones[mid].append(qid)
        unpinned += 1
    print(f"{unpinned} pin-less client quests added at their Questie giver")

    def zline(uimap):
        m = maps[uimap]
        return f"|Z|{uimap}; {m['name']}|"

    lines = [
        "-- AUTO-GENERATED by tools/gen_quest_guides_retail.py from Blizzard client data",
        f"-- (wago.tools QuestPOIBlob + QuestPOIPoint, build {build}).  Local use only - gitignored.",
        "-- Step titles are \"Quest <id>\"; the live client swaps in the real name (Core/Guide.lua StepTitle).",
        "local _, NS = ...",
        'if NS.flavor ~= "retail" then return end',
        "local R = NS.Guide.Register",
    ]
    nguides = nsteps = 0
    named = givers = 0

    # zone name -> the canonical retail uiMapID (lowest id among zone-type maps, as the addon does)
    byname = {}
    for mid, m in sorted(maps.items()):
        key = m["name"]
        prev = byname.get(key)
        if prev is None or (m["type"] == 3 and maps[prev]["type"] != 3):
            byname[key] = mid

    def tags(qid):
        """|FACTION| / |C| / |LVL| for a quest Questie knows about"""
        e = qidx.get(qid)
        if not e:
            return "", f"Quest {qid}"
        t = ""
        if e["faction"] in ("Alliance", "Horde"):
            t += f"FACTION|{e['faction']}|"
        if e["classes"]:
            t += f"C|{e['classes']}|"
        if e["minlevel"] > 1:
            t += f"LVL|{e['minlevel']}|"
        return t, (e["name"] or f"Quest {qid}")

    def giver(qid):
        """(uiMapID, x01, y01) of the real quest giver, when Questie has a spawn for it"""
        e = qidx.get(qid)
        if not e or not e["zone"] or e["x"] <= 0:
            return None
        mid = byname.get(e["zone"])
        if mid is None:
            return None
        return mid, e["x"] / 100.0, e["y"] / 100.0
    for uimap in sorted(zones, key=lambda z: maps[z]["name"]):
        m = maps[uimap]
        qids = sorted(zones[uimap])
        body = []
        for qid in qids:
            rec = quests[qid]
            anchor = rec["anchor"]
            gate, title = tags(qid)
            if qid in qidx:
                named += 1
            g = giver(qid)
            if g:
                gmap, gx, gy = g
                givers += 1
                body.append(f"A {title}|QID|{qid}|M|{gx*100:.1f},{gy*100:.1f}{zline(gmap)}{gate}"
                            f"N|Quest giver location (Questie).|")
            elif anchor:
                amap, (ax, ay) = anchor
                body.append(f"A {title}|QID|{qid}|M|{ax*100:.1f},{ay*100:.1f}{zline(amap)}{gate}"
                            f"N|Approximate: this is the turn-in pin, the giver may be elsewhere.|")
            else:
                body.append(f"A {title}|QID|{qid}|{gate}N|No turn-in pin in client data.|")
            if rec.get("unpinned"):
                body[-1] = body[-1].replace("N|Quest giver location (Questie).|",
                                            "N|Quest giver location (Questie); no map pin in client data.|")
            for oi in sorted(rec["objectives"]):
                omap, (ox, oy) = rec["objectives"][oi]
                body.append(f"C {title}|QID|{qid}|QO|{oi+1}|"
                            f"M|{ox*100:.1f},{oy*100:.1f}{zline(omap)}{gate}")
            if anchor:
                amap, (ax, ay) = anchor
                body.append(f"T {title}|QID|{qid}|M|{ax*100:.1f},{ay*100:.1f}{zline(amap)}{gate}")
            else:
                body.append(f"T {title}|QID|{qid}|{gate}")
        if not body:
            continue
        nguides += 1
        nsteps += len(body)
        name = m["name"].replace('"', '\\"')
        lines.append(f'R({{ id="qpoi:retail:{uimap}", name="{name} Quests", type="Quests", zone={uimap}, '
                     f'author="Blizzard quest POI data", source="CompletionRoute", text=[==[')
        lines.extend(body)
        lines.append("]==] })")
    lines.append("")
    OUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT)}: {nguides} zone guides, {nsteps} steps, "
          f"{len(quests)} quests ({homeless} without a usable map, {off_map} pins off their map); "
          f"{named} quests named + gated from Questie, {len(quests)-named} named live by the client; "
          f"{givers} accept steps on the real quest giver, {len(quests)-givers} on the turn-in pin")


if __name__ == "__main__":
    main()
