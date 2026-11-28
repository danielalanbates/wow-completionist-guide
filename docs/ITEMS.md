# Items category and Batch mode (2026-11-28)

Owner spec: Gold removed; Items added; Batch checkbox added.

## Items
| What | How |
|---|---|
| Unit | one item id (`Core/AutoRoute.lua` `A.ItemUnits`) |
| Source | every route step naming an item: `L` loot lists, `B` buy with `U`/`ITEM`, `$` treasure; mount/pet routes included |
| Quest-bound item | the whole quest (accept → objectives → turn-in) is routed |
| Done | item in bags/bank (`U.ItemCount`) or its steps done |
| Order | closest by travel time (same picker as Quests) |

**Coverage gap (honest):** only items our community data gives a source for — era 413, retail 2,809 item ids in the pool (vplayer 2026-11-28). Not every item in the game yet.

Next pathways:
- Add drop tables from wago.tools DB2 / Wowhead (facts only, per-value source URL) as `L` steps on kill spots.
- Collections: mounts / pets / toys via `C_MountJournal`, `C_PetJournal`, `PlayerHasToy` as "owned" checks.
- Vendor lists (wiki) as `B` steps.

## Batch mode
- Box "Batch" on the routes list (top right), or `/cr batch [on|off]`. Saved in `profile.autoBatch`.
- Quests / Achievements / Legacy: closest unit + every other open unit in the player's zone or that unit's zone, max `A.BATCH_MAX` (15). Accepts first, objectives, turn-ins; step optimizer orders them.
- Dungeons: always gathers all quests before the entrance (unchanged).
- Measured (vplayer era, 150 items): batch 238 s/quest vs one-at-a-time 247 s/quest (~4% less travel).

## Gold
Removed from categories, TOCs (`Imported_Gold_*` no longer loaded), recommended list, `/cr gold`. Test archived to `archive/gold/`. Generator `tools/wiki/gen_gold.py` kept, unused.

SQL record: `docs/verification.sqlite` table `category_runs`, labels `items-2026-11-28`, `batch-2026-11-28`.
