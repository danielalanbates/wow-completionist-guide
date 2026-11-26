#!/usr/bin/env python3
# CompletionRoute :: tools/gen_doors.py
# Copyright (c) 2026 Daniel Bates / BatesAI. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Generate CompletionRoute/Data/Doors_retail.lua: the outdoor door of every Retail instance uiMap.

    python3 tools/gen_doors.py            (reads tools/db2/retail/*.csv and tools/maps_retail.lua)

Blizzard client data only (wago.tools DB2):
  JournalInstanceEntrance  the Encounter Journal's door pin (world coordinates + continent), joined to the instance's
                           Map through JournalInstance.MapID; a faction-neutral pin wins, then the lowest row id
  Map.Corpse_0/1/CorpseMapID  where a ghost is sent back to: the instance entrance, used when there is no journal pin
A uiMap gets a door only when it is a dungeon/micro/orphan map (types 4/5/6) on a continent of its own: one on the same
continent as the outdoor world is walkable already.  Pocket maps without either source (Brawl'gar Arena, Ember Court,
Telogrus Rift...) get no door: there is no Blizzard fact to put one on, and a guessed point would send the arrow astray.

Output: NS.DoorData.retail[uiMapID] = { continent, worldX, worldY, journalInstanceID or 0, "journal"|"corpse"|"twin" }
Core/Instances.lua uses it after a door the player learned and the live journal (and matches the live journal's pin
by journalInstanceID).
"""
import csv
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "CompletionRoute", "Data", "Doors_retail.lua")
DB2 = os.path.join(HERE, "db2", "retail")


def rows(t):
    with open(os.path.join(DB2, t + ".csv"), newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def load_maps(path):
    out = {}
    pat = re.compile(r'\s*\[(\d+)\] = \{ "((?:[^"\\]|\\.)*)", (-?\d+), [^,]+, [^,]+, [^,]+, [^,]+, (-?\d+), (\d+)')
    for line in open(path, encoding="utf-8"):
        m = pat.match(line)
        if m:
            out[int(m.group(1))] = (m.group(2), int(m.group(3)), int(m.group(4)), int(m.group(5)))
    return out


def outdoor_continent(maps, uid):
    """continent of the nearest ancestor that is not itself a dungeon/micro/orphan map"""
    seen = set()
    p = maps[uid][2]
    while p and p in maps and p not in seen:
        seen.add(p)
        if maps[p][3] not in (4, 5, 6):
            return maps[p][1]
        p = maps[p][2]
    return None


def build(maps, map_rows, ji_rows, door_rows):
    ji_map = {}
    for r in ji_rows:
        try:
            ji_map[r["ID"]] = int(r["MapID"])
        except (KeyError, ValueError):
            pass
    journal = {}                                   # instance map id -> (cont, wx, wy, jid)
    for r in sorted(door_rows, key=lambda r: (r.get("Faction") != "-1", int(r["ID"]))):
        try:
            mid, wx, wy, cont = ji_map[r["JournalInstanceID"]], float(r["Position_0"]), float(r["Position_1"]), int(r["MapID"])
        except (KeyError, ValueError):
            continue
        if (wx or wy) and mid not in journal:
            journal[mid] = (cont, wx, wy, int(r["JournalInstanceID"]))
    corpse = {}
    for r in map_rows:
        try:
            cm, x, y = int(r["CorpseMapID"]), float(r["Corpse_0"]), float(r["Corpse_1"])
        except (KeyError, ValueError):
            continue
        if cm >= 0 and (x or y):
            corpse[int(r["ID"])] = (cm, x, y, 0)
    doors = {}
    for uid, (name, inst, parent, typ) in sorted(maps.items()):
        if typ not in (4, 5, 6):
            continue
        oc = outdoor_continent(maps, uid)
        if oc is not None and oc == inst:
            continue                               # same continent as the outdoor world: walkable
        d, src = journal.get(inst), "journal"
        if not d:
            d, src = corpse.get(inst), "corpse"
        if d and d[0] != inst:                     # a door on the instance's own continent leads nowhere
            doors[uid] = (d[0], d[1], d[2], d[3], src, name)
    # a phase/scenario copy of an instance (its own Map row with no pin: Legion's Icecrown Citadel, the timewalking
    # Arcatraz) uses the door of the uiMap with the same name under the same parent uiMap
    twin = {}
    for uid, d in sorted(doors.items()):
        twin.setdefault((maps[uid][0], maps[uid][2]), d)
    for uid, (name, inst, parent, typ) in sorted(maps.items()):
        if typ in (4, 5, 6) and uid not in doors and (name, parent) in twin:
            oc = outdoor_continent(maps, uid)
            d = twin[(name, parent)]
            if (oc is None or oc != inst) and d[0] != inst:
                doors[uid] = (d[0], d[1], d[2], d[3], "twin", name)
    return doors


def main():
    maps = load_maps(os.path.join(HERE, "maps_retail.lua"))
    build_id = open(os.path.join(DB2, "BUILD")).read().strip() if os.path.exists(os.path.join(DB2, "BUILD")) else "?"
    doors = build(maps, rows("Map"), rows("JournalInstance"), rows("JournalInstanceEntrance"))
    lines = ["-- GENERATED by tools/gen_doors.py from wago.tools DB2 (JournalInstanceEntrance, JournalInstance, Map) build "
             + build_id + ". Do not edit by hand.",
             "-- [uiMapID] = {continent, worldX, worldY, journalInstanceID (0 = none), source}  (Core/Instances.lua)",
             "local _, NS = ...", "NS.DoorData = NS.DoorData or {}", "NS.DoorData.retail = {"]
    for uid, (c, x, y, jid, src, name) in sorted(doors.items()):
        lines.append('  [%d]={%d,%.1f,%.1f,%d,"%s"}, -- %s' % (uid, c, x, y, jid, src, name.replace("\\'", "'")))
    lines.append("}")
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print("doors:", len(doors), "journal", sum(1 for d in doors.values() if d[4] == "journal"),
          "corpse", sum(1 for d in doors.values() if d[4] == "corpse"),
          "twin", sum(1 for d in doors.values() if d[4] == "twin"), "->", os.path.relpath(OUT))


if __name__ == "__main__":
    main()
