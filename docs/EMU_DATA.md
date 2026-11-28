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

# Community quest database rung (after the emulator rung)

Chain: wiki -> Blizzard quest pins -> Blizzard subzones -> emulator spawns -> **community quest database**
(owner decision 2026-11-27: Questie data is allowed, facts only, GPLv3; the Questie name/logo never appear in the add-on).

| Client | Sources, in order |
|---|---|
| Classic Era | QuestieDB `data/Classic` |
| WoW Forever | `data/Forever`, then `data/Classic` |
| TBC Anniversary | `data/TBC` |
| MoP Classic, Retail | `data/MoP`, then `data/Cata` |

* **Rebuild:** `sh tools/questie/fetch_questie.sh`: shallow sparse clone of github.com/Questie/QuestieDB (`data`,
  `src/corrections`, `support`) into `$CR_TMP/questie`; `tools/questie/extract_questie.lua` (Lua 5.4+, the data
  literals exceed LuaJIT's constant limit) applies the expansion's Corrections (Era -> ... -> MoP cumulative, `_add` /
  `_remove` table operations; Forever: legacy Classic fixes then Forever's) and converts every spawn's areaId with
  QuestieDB's own areaId -> uiMap tables (`support/Zones`, `Zones/MoP`, `Forever/Zones`; base + override);
  `tools/questie/build_questie.py` writes `tools/db2/questie/<source>.sqlite` (gitignored, ~68 MB); the clone is deleted.
* **What a step takes** (`tools/questie/questie_points.py`): A = startedBy npc/object (item-started: the item's drop
  sources), T = finishedBy, C = objectives in Blizzard order (creature, object, item -> its npcDrops/objectDrops, kill
  credit), plus `triggerEnd` explore areas. Points are already zone % on a uiMap; the uiMap must exist on the client and
  be the step zone or a map inside it (converted through world coordinates). Item drops: the source with the most points
  in the zone wins, then the point nearest the median.
* **Check:** `python3 tools/questie/agree_questie.py <flavor> CompletionRoute/Guides/Imported_Wiki_<flavor>.lua`
  (2026-11-27: median 0.10-0.28 map units, 85.9-91.6% within 3 units on all five).
* **UI wording:** guide files never contain the word "questie" (`tools/install.sh` and the packager refuse such files);
  the note says "community quest database". Repo + commit per value: verification.sqlite `questie_points`.

# Community collection database rung (after the quest database rung)

Chain: wiki -> Blizzard quest pins -> Blizzard subzones -> emulator spawns -> community quest database ->
**community collection database** (owner decision 2026-11-27: AllTheThings data is allowed, MIT, facts only; its
name never appears in guide files).

| Client | Source folder (`db/`) |
|---|---|
| Classic Era | `Vanilla` |
| WoW Forever | `Camelot`, then `Vanilla` |
| TBC Anniversary | `TBC` |
| MoP Classic | `Mists` |
| Retail | `Standard` |

* **Rebuild:** `sh tools/att/fetch_att.sh`: shallow, blobless, sparse clone of only those five `db/` folders (no
  LocalizationDB; ~40 MB of a ~7 GB repo) into `$CR_TMP/att`; `tools/att/extract_att.lua` (Lua 5.4+) runs the
  compiled category files against a stand-in namespace and walks the tree (NeverImplemented and Hidden*Triggers are
  skipped); `tools/att/build_att.py` writes `tools/db2/att/<source>.sqlite` (gitignored, ~10 MB in all; same tables as
  the quest database plus `ach` / `achvia`); the clone is deleted.
* **What a step takes** (`tools/att/att_points.py`): A = giver npc/object spawns (`qgs` / `providers` / the npc the
  quest is listed under), else the quest's own start coordinates; C = the objective's (`qo`) npcs or its own
  coordinates (Classic clients only; Retail's data has no objectives). No quest enders: T steps are left alone.
  Quests whose data differs per faction (`aqd` / `hqd`) are not read. Same zone rules as the quest database rung.
* **Achievements** (`tools/gen_completion_guides.py`, Retail and MoP): an achievement line still without a point takes
  one when all coordinates of the achievement and its criteria (and spawns of criterion npcs without coordinates) are
  on one map, inside the zone found so far, within 10 map units of their median.
* **Check:** `python3 tools/att/agree_att.py <flavor> CompletionRoute/Guides/Imported_Wiki_<flavor>.lua` (A steps
  with a wiki point; 2026-11-27: median 0.10-0.28 map units, 82.8-92.7% within 3 units).
* **UI wording:** the note says "(location: community database spawn of npc N)", "... start of quest N)" or
  "... objective K of quest N)". Repo + commit per value: verification.sqlite `att_points`. Credit and MIT notice:
  `CREDITS.md`.
