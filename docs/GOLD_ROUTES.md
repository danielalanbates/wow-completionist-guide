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
| `Data/Farm_routes.lua` | 31 coarse seed rings so a fresh install has gold guides on day one. Explicitly labelled "(coarse)" — see *Honesty* below. |
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
4. **Legacy guides, if you have them.** Authored farming guides already contain `map <Zone>` + `path` vertex lists
   ("path follow smart; loop on"). The adapter now parses those into `G` waypoints, in the author's order —
   interop only, from the user's own install, nothing copied into this repo.

## Folding an imported gold guide into a circuit

`Farm.Circuitize(guide)` runs automatically when a `Gold` guide is loaded (`profile.farm.circuitizeGold`):

1. Guide already has ≥4 `G` waypoints → **keep the author's order** (they walked it; re-solving makes it worse).
2. Otherwise take every located non-quest step and solve the tour.
3. Fewer than 6 stops → **patrol legs**: a ring around each stop sized to the spread of the guide's own stops,
   because one dot is not a route and everything respawns behind you.
4. No coordinates at all but a zone ("kill kodos in the Barrens") → a hunting ring across the zone.
5. Mostly quest steps → refused: that is a questing guide, not a farm route.

Measured on the baked legacy set (`luajit tools/audit_guides.lua <flavor>`, rows in
`docs/verification.sqlite` tables `gold_circuits` / `guide_type_audit`):

| flavor | gold guides | are circuits | authored rings kept | solved here |
|---|---|---|---|---|
| era | 204 | 178 (87%) | 106 | 72 |
| tbc | 204 | 178 (87%) | 106 | 72 |
| mop | 204 | 178 (87%) | 106 | 72 |
| retail | 204 | 178 (87%) | 106 | 72 |

The 26 that stay lists are genuinely not routes — disenchanting and auction-house methods
("Strange Dust", "Lesser Magic Essence"). They keep working as note guides.

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

## Honesty about the seed rings

`Data/Farm_routes.lua` ships 31 ellipse rings over well-known gathering zones. They are **not surveyed node
routes** — no free, redistributable node database exists (commercial ones are proprietary; the GatherMate packs carry
no licence), and a fresh install with zero gold guides would be worse. A seed ring puts you circling the right
ground; the recorder then replaces it with the route your own harvests describe (`/cr farm build`). They are
labelled "(coarse)" in the guide list for exactly this reason, and a ring waypoint that lands on a cliff is
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
