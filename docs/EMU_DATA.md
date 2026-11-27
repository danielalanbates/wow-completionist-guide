# Emulator spawn points (last rung for steps with no point)

Steps that the wiki, Blizzard quest pins and Blizzard subzones leave with only a zone (`|Z|`) or nothing take the
world position of their NPC or object from an open emulator database on GitHub.

| Client | Sources, in order |
|---|---|
| Classic Era, WoW Forever | cmangos/classic-db `Full_DB/ClassicDB_1_12_1_z2815.sql.gz` |
| TBC Anniversary | cmangos/tbc-db `Full_DB/TBCDB_1.11.0_Vengeance_One_A_Cmangos_Story.sql.gz` |
| MoP Classic | TrinityCore TDB442.26081 (cata_classic), then TDB1210.26091 (master) |
| Retail | TrinityCore TDB1210.26091 (master), then TDB442.26081 |

* **Rebuild:** `sh tools/emu/fetch_emu.sh` downloads the dumps into `$CR_TMP/emu/dl`, writes the compact
  `tools/db2/emu/<source>.sqlite` (gitignored, about 47 MB in all) with `tools/emu/extract_emu.py`, and deletes the
  dumps. Nothing is unpacked to disk (gzip / `7zz e -so` streams).
* **What a step takes** (`tools/emu/emu_points.py`, called at the end of `gen_wiki_guides.py`; Dungeons copy the wiki
  lines): A = quest starter (`creature_questrelation` / `creature_queststarter`, gameobject equivalents), T = quest
  ender (`*_involvedrelation` / `*_questender`), C = objective target (cmangos `ReqCreatureOrGOId1-4`, TrinityCore
  `quest_objectives` type 0/2; the step's QO slot first). World x,y become uiMap % with the client's own UiMap /
  UiMapAssignment rectangles (wago.tools). A step with a zone keeps only spawns on that map (or its subzone maps); a
  step with no zone is placed only when all spawns of the entity are in one zone. Several spawns: the one nearest the
  median of the in-zone spawns.
* **Check:** `python3 tools/emu/agree_emu.py <flavor> CompletionRoute/Guides/Imported_Wiki_<flavor>.lua` places steps
  that already have a wiki point again from spawns; 2026-11-27: median distance 0.10-0.22 map units on all five
  clients, 85-94% within 3 units.
* **Licence:** the databases are GPL. Only ids and coordinates, which are facts, are used; no text, scripts or table
  layouts are copied into the addon. Attribution: `CREDITS.md`, the guide file header, and each step's note.
* **Not used:** AzerothCore (WotLK) adds nothing the TrinityCore 4.4.2 database lacks for these clients; the
  Cataclysm Preservation Project's 4.3.4 TDB (2022) is older than TrinityCore's own 4.4.2. wago.tools DB2 has no
  creature spawn positions (quest pins are used by the earlier rung).
