# Archived: tools that read a local Questie checkout

Archived on 2026-11-11. The owner's decision that day: there is one build, the one a player gets from a public
release. It holds Warcraft Wiki data, Blizzard client data and the project's own code and data. Nothing derived from
Questie (or any other addon) is generated, loaded, installed or baked any more, so these tools have no job in the
build. They are kept here, unchanged and **not maintained**, because the project archives code instead of deleting it.
They are never run by any other tool, test or document. Paths inside them (`tools/...`, `CompletionRoute/Guides/...`)
are the ones they had before the move and would need fixing before any use.

| File | What it did | Why archived |
|---|---|---|
| `gen_quest_guides.lua` | wrote `Guides/Imported_Quests_<era, tbc, wotlk, cata, mop>.lua` from a Questie database checkout | Questie-derived guides; they fed the `_gaps` guides and the fallback map points, both gone |
| `gen_quest_guides_retail.py` | wrote `Guides/Imported_Quests_retail.lua` from Blizzard quest POI plus Questie names, givers and gates | mixed with Questie data; the wiki generator now reads the Blizzard quest pins itself |
| `questie_env.lua` | loaded the Questie database and its corrections for the two tools above and the audit | only used by archived tools |
| `questie_quest_index.lua` | wrote `tools/db2/questie_index.tsv` (names, factions, level gates) | input of `gen_quest_guides_retail.py` only |
| `questie_spawns.lua` | wrote `tools/db2/questie_spawns.tsv` (giver and ender positions) | input of the retail location audit only |
| `gen_entrances.py` | wrote `Data/Imported_Entrances.lua` (dungeon doors) from Questie's `dungeons.lua` | the file never shipped; `Core/Instances.lua` learns doors and asks the Retail journal |
| `audit_quest_locations.lua` | compared guide points with Questie spawns (Classic) | its reference is Questie |
| `audit_quest_locations_retail.py` | compared retail guide points with Blizzard quest POI and Questie spawns; could write `Data/QuestCoordFixes_retail.lua` | its giver reference is Questie; no fix table ships |
| `dump_quest_steps.lua` | dumped parsed steps for the retail audit | only used by that audit; loads `Imported_Quests_<flavor>.lua` |
| `build_verification.py` | charted the wiki guides against `Imported_Quests_<flavor>.lua` and the `_gaps` guides (`coverage` before/after, `wiki_gaps`, `wiki_vs_db2`) | every comparison reads Questie-derived files; `tools/coverage.py` and `tools/status_report.py` chart the build |

What is still available, as an explicit offline measurement that never touches the build: `tools/measure/README.md`.
