# Gold guides as circuits (farm routes)

*"The gold guides need work. The user shouldn't have to manually click thru steps. It should be more of
a route that they always follow around zones."* — Daniel, 2026-08-22

That is what this describes. A gold guide in CompletionRoute is no longer a list of steps you tick; it is a
**closed loop you walk forever**, with nothing to click.

## The pieces

| File | Job |
|---|---|
| `Routing/Loop.lua` | Turns a cloud of points into the shortest closed tour: cluster → nearest-neighbour → 2-opt → Or-opt → 2-opt, all in world yards. |
| `Core/Farm.lua` | Node store, node recorder, GatherMate2/Routes importers, circuit builder, lap stats, `Circuitize` (folds an imported gold guide into a ring). |
| `Data/Farm_routes.lua` | Fallback ellipse rings, one per gathering profession, registered only when no generated Gathering guide is installed. Labelled "(coarse)". |
| `tools/wiki/gen_gold.py` | Generates `Guides/Imported_Gold_<flavor>.lua` (see *Generated gold guides*). |
| `tools/test_gold.lua` | Offline invariants for those files, printed as a table per flavor. |
| `Core/Progress.lua` | `G` waypoints complete on proximity; `NewLap` wipes the lap and re-enters the ring at the nearest waypoint, so a circuit never "finishes". |
| `Core/Instances.lua` | Learns dungeon entrances so steps inside instances route to the door instead of nowhere. |

## The guide format addition

```
G Peacebloom 4|M|43.20,65.80|Z|1429; Elwynn Forest|RAD|40|N|Herbs along the road|
```

* `G` = farm waypoint. Never reordered by the optimizer (the ring already is the order).
* `RAD` = yards that count as "reached" (default `profile.farm.radius`, 40).
* A guide with `loop = true` repeats: after the last waypoint, `Progress.NewLap` clears the lap, counts it,
  prices what went into your bags, and starts again at the nearest waypoint.

Entering the ring is always at the **nearest** waypoint, and never the one you are already standing on —
otherwise a closing lap would tick every waypoint in sequence and eat itself (this is `test_farm.lua` #5).

## Where the nodes come from (no proprietary data ships)

1. **You.** Every world-object loot (`GameObject-…` loot source) records a node, account-wide. Corpses are
   ignored, so a farm route never fills up with mob kills.
2. **Addons you already have.** `GatherMate2` and `Routes` databases are imported at login if present
   (`/cr farm import`). Their coordinate packing is decoded in `Farm.ImportGatherMate2`.
3. **Other people.** `/cr farm export` writes a plain-text node list (`map x y kind count`) into
   `CompletionRouteDB.farmExport`; `Farm.ImportText` reads it back. Hand the file to a guildmate.

## Folding an imported gold guide into a circuit

`Farm.Circuitize(guide)` runs automatically when a `Gold` guide is loaded (`profile.farm.circuitizeGold`):

1. Guide already has ≥4 `G` waypoints → **keep the author's order** (they walked it; re-solving makes it worse).
2. Otherwise take every located non-quest step and solve the tour.
3. Fewer than 6 stops → **patrol legs**: a ring around each stop sized to the spread of the guide's own stops,
   because one dot is not a route and everything respawns behind you.
4. No coordinates at all but a zone ("kill kodos in the Barrens") → a hunting ring across the zone.
5. Mostly quest steps → refused: that is a questing guide, not a farm route.

Circuit coverage will be re-measured on the wiki-sourced gold guides (FINISH_PLAN.md); the earlier
measurement used third-party guides that were removed on 2026-11-07.

## What a lap is worth

`Farm.OnLapComplete` snapshots your bags at the start of a lap and diffs them at the end, prices the delta
with **Auctionator** if you run it (else vendor price), adds any coin gained, and stores
laps / seconds / value in `CompletionRouteDB.farmStats`. The window title shows `lap 3 — waypoint 12 of 48`
plus the running gold/hour, and `/cr farm stats` lists every circuit you have walked. These are measured
numbers, never an estimate someone typed into a guide.

## Verifying it in the client without walking

`/cr farm selftest` (or arm `CompletionRouteDB.autoFarmTest = true` before launching, like the existing
`autoSweep` / `autoVerifyAll` flags) builds a throwaway 6-waypoint ring **on the player**, loads it, and lets
the engine drive itself: waypoints must tick with nothing clicked, the lap counter must roll over twice
instead of the guide "finishing", a waypoint must always be current, and the lap value must be recorded.
Results go to `CompletionRouteDB.farmSelfTest`; the previous guide is restored afterwards.

That degenerate ring found a real bug: with every waypoint inside its own radius the auto-completer cascaded
through the whole lap and left the player with no current step. Auto-completion now ticks **at most one
waypoint per refresh**, so a circuit can never swallow itself.

`RunFeatureVerify` (`/cr verifyfeatures`, and automatic 30 s after login) also gained a `farm` and a
`dungeon` group: seed rings registered, a circuit's waypoints all locate, a route exists to waypoint 1,
sampled gold guides fold into circuits (and are folded back), lap engine present, recorder wired, import path,
pricing source, instance entrances known, and whether a dungeon step resolves to a door.

## Commands

```
/cr farm              status: nodes here, nodes on the account, current circuit + gold/hr
/cr farm build [kind] solve a circuit for the zone you are standing in ("Herbalism", "Mining", ...)
/cr farm record       toggle node recording
/cr farm import       pull GatherMate2 / Routes now
/cr farm export [all] dump nodes to CompletionRouteDB.farmExport for sharing
/cr farm stats        laps, average lap time, gold/hr per circuit
/cr farm radius <yd>  how close counts as reaching a waypoint
```

## Generated gold guides

`tools/wiki/gen_gold.py` writes one file per client. "Generic" means realm-independent: **no auction price, vendor total or gold-per-hour figure is ever
written into a guide.** What a lap is worth is measured in game (*What a lap is worth*, above).

| goldKind | What it is | Where the data comes from | Level band |
|---|---|---|---|
| `Gathering` | One circuit per zone per profession (Herbalism, Mining, Skinning). The note names what grows there and the skill needed; `requires` carries the lowest skill, so zones you qualify for list first. | *Herbs by Area* and the *Herb* table; each node's `==Locations==`; for Skinning, Npcbox `creature = Beast` with a location in the zone | the zone's wiki level range |
| `Mob Farming` | Ring through a real cluster of humanoids (cloth, coin) or beasts (leather). | wiki NPC coordinates and the wiki quest guides' `T|mob|` points. Only ordinary hostile populations with a known level inside the zone's band; friendly, elite, rare and named creatures are dropped, as are creatures whose page says they were added after this client's patch | the zone's wiki level range |
| `Fishing` | Where to fish, what bites, the 100% catch skill. | *Fishing locations* | the zone's wiki level range |
| `Daily Gold` | Repeatable dailies that pay money, grouped by giver zone, most money first, at most 25 per hub. Accept and turn-in steps with `QID`, level-gated. Covenant and Aldor/Scryers dailies are left out because they depend on a side choice. | wiki quests (Type Daily, `money` present) on this client | quest level to cap |
| `Methods` | Short step lists in original wording for every band 1-9, 10-19, ... to the cap, plus any-level Auction House, flipping and bank-alt guides; per faction. `ALT` points at the nearest Auction House, bank or vendor. | wiki auctioneer, banker, vendor and innkeeper coordinates | the band |
| `Instances` | Old-expansion instances at or near the cap, an `R` to each entrance then a `D`. | wiki instance pages for entrances; *Template:Level* for which expansion an instance belongs to | cap-10 to cap |

Era and Forever have no Instances guides: no older content exists there. Burning Crusade has none either: *Template:Level* merges Classic, Burning Crusade and Wrath into one *Pre-Cataclysm* section, and its levels are retail-scaled, so that client's old instances cannot be told from its own. Mists gets *Pre-Cataclysm*; retail also gets *Cataclysm and Pandaria* and one group per later expansion. Only instances whose wiki page gives an entrance coordinate this client can place are listed, and a group with fewer than two is dropped.

**Other projects' data.** Steps whose location came from Questie are never used for a ring or a daily point (`World._read_wiki_guides` drops them and counts them; a daily
whose giver point came from there keeps only its quest id and the wiki's zone). `Data/Imported_Entrances.lua` is not read by the generator because that file is built from
Questie's data; the runtime engine can still use it as a fallback for instance doors.

### How a ring gets its shape

No shippable node database exists, so gathering rings stay labelled **(coarse)**. But they are not ellipses at the map centre any more: `build_tour` clusters the zone's real
quest and NPC points (ground the game actually places things on), drops isolated clusters, keeps at most 20 spread by farthest-point insertion, then solves a shortest closed tour
in yards (nearest neighbour + 2-opt). Mob rings additionally take only the biggest group of clusters joined by hops of 800 yards or less, so a ring is a hunting ground and not
a sprint across the zone. This keeps a ring off most unreachable ground, but it does not prove it: nothing checks terrain. The route sharpens as nodes are recorded (`/cr farm build`).

### Skill numbers

Classic-era numbers come from each node's own page. A node whose page has no number uses its expansion's starting skill (the former skill range table on the wiki's *Mining* page).
Retail has no skill gate on old nodes (the wiki: since patch 6.0.2 nodes are gatherable at skill 1), so retail guides require skill 1.

### Tests and SQL

`luajit tools/test_gold.lua` (through `heavy.sh` on the 8 GB Mac). `docs/verification.sqlite` has a `gold_guides` table (flavor, id, name, kind, band, zone, faction, steps, loop, requires, source).

## Honesty about the fallback rings

`Data/Farm_routes.lua` ships ellipse rings over well-known gathering zones, one per profession. They are **not surveyed node routes** — no free, redistributable node database exists
(commercial ones are proprietary; the GatherMate packs carry no licence). They register only when no generated Gathering guide is installed. A ring waypoint that lands on a cliff is
expected until the zone has been farmed once.

## Dungeon steps (the other odd guide type)

98 dungeon guides had steps inside instance maps, which have no travel edge into them — the sweep called them
"no route (instance map, expected)". `Core/Instances.lua` now:

* remembers the last outdoor position before a loading screen that puts you inside (that *is* the door),
* asks `C_EncounterJournal.GetDungeonEntrancesForMap` on retail, which is the client's own answer,
* exports/imports entrances as text like farm nodes.

`Router.StepWorld` substitutes the entrance whenever the target is inside an instance you are not currently
in, so the arrow points at the door and the ETA is real. Inside the instance the guide's own coordinates take
over again. **Unverified in game as of this commit** — the learned half needs a character to walk into a
dungeon, and the journal half needs retail running.
