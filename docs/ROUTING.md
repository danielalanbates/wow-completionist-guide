# Routing engine

## Travel graph (`Routing/TravelGraph.lua`)
* **Nodes**: taxi nodes for the current flavor/faction (`Data/Taxi_<flavor>.lua`, generated from wago.tools
  `TaxiNodes/TaxiPath/TaxiPathNode` — world coordinates + real polyline flight lengths), transit endpoints
  (`Data/Transit.lua`), the character's hearth (`NS.db.char.bind` learned, else `Data/Inns.lua` seed via `GetBindLocation()`),
  virtual start (player) and goal.
* **Edges**: taxi (`3s + length / taxiSpeed(32)`). Policy `routing.taxiPolicy`: **`known` (default since 2026-11-10)**
  = a flight may only land at a flight master this character has discovered; it may take off from an undiscovered
  one, because walking there discovers it (see "Flight paths" below); `faction` = every flight master the faction can
  use, discovered or not (the old default; a landing at an undiscovered one is labelled "(new flight path)").
  transit (`cost` seconds = avg wait + ride; optional `cond`), hearth (`hearthCost(60) + cooldown remaining`, hidden
  if >15 min), teleports (`Data/Teleports.lua`, same rule as the hearth, see "Teleports" below),
  implicit walking between any two nodes on the same continent instance: `dist * terrainFactor(1.25) / speed`.
  Speed = live `GetUnitSpeed` if moving, else guess from level (7 / 11.2 / 14 yd/s).
* **Search**: Dijkstra with a binary heap; complete walking graph is relaxed lazily on pop (~200 nodes → cheap).
  Direct walk < 300 yd short-circuits.
* **Output**: `{cost, legs[{mode, from, to, cost, title, data}]}`; consecutive walk legs merged.
  `TravelGraph.Describe(path)` → "Walk 457 yd to Darkshire; Fly … ; Take the boat … (~10m)".

## Live window over the baked order (`Routing/StepOrder.lua`, tier B)
The next `window` (24) pending steps arrive in baked order (`Data/RouteOrder_<flavor>.lua`, or author order when there is
no bake), and that order is the **baseline**. Hard rules (never traded for time): `A < C < T` per quest, `PRE` turn-in
before the accept, non-routable and sticky steps as anchors with everything before them staying before them, a step with
no place at all staying on the block before it, and a quest log that a repair may not push above the cap or the
baseline's own peak.

A repair runs segment Or-opt (1-3 blocks) and precedence-safe 2-opt from the baseline and from a greedy
nearest-feasible route seeded at the player. It replaces the baseline only when it saves more than the margin
(`SO.MIN_GAIN`, `SO.GAIN_FRAC`). A repair that wins becomes the plan, and the plan is what the next refresh has to beat,
so the route does not flip as the player walks. The cost includes the leg from the end of the window to the step after
it, so a repair cannot win by stranding the rest of the route. An off-route player shows up as a long first leg, and the
greedy start picks the near block.

CPU: pair costs are kept between refreshes (dropped when the guide, the speed or the path cache changes), from-player
searches are limited to `SO.FIRST_LEGS`, and a call stops at `routing.liveBudgetMs` (3 ms) and returns the baseline; the
caller retries 0.2 s later and the kept costs make the retry cheaper. A single router call is not interruptible, so a
call can overrun its budget by one Dijkstra. Author order breaks ties. Toggle with the `Route` button or `/or options`.

Tests: `tools/test_live_route.lua` (margins, plan stability, 400 random windows for precedence and the log cap, budget,
off-route). `tools/vplayer.lua` takes `CR_SO`, `CR_WINDOW`, `CR_LIVE_BUDGET_MS` for experiments and prints repair times.

## Parked guides (`Core/Progress.lua`)
A guide that runs dry while a `|LVL|` gate still holds steps back is parked (`char.parked[id] = { level = n }`), lowest
gate first; a gate above the client's level cap does not count. It comes back only at a transition: when the guide in
progress has finished. It never pulls the player off a guide being played, and the chain then continues from where it
was heading (`char.parkReturn`), not from the parked guide's own `next`. `G.SuggestNext` passes over a guide still
waiting. A guide the player picks ends any detour. `tools/vplayer.lua --chain Alliance|Horde` plays a whole spine with this
logic and fails on a bounce; `tools/test_parked.lua` and `tools/test_live_route.lua` cover it in stubs.

## Arrow recommendation (`Routing/Router.lua`)
1. step has `|U|item` in bags and you're within 40 yd (or step has no location) → **item button**
2. step is `H` → **hearth button** (the Hearthstone, or a hearth toy when no stone is in the bags)
3. first leg of the path is `hearth` → **hearth button** with "saves time" + ETA
4. first leg is `teleport` → **teleport button**: casts the spell, uses the item, or uses the toy (secure `toy`
   action) for that leg, "Click to teleport" + ETA
5. first leg walk → arrow to leg end (a flight master / dock / the goal); text explains what happens there, including
   "(pick up the flight path)" when the flight master there is not discovered yet
6. first leg taxi/transit → arrow to that node with "Fly to X" / "Take the boat …"

## Roads: predetermined paths through zones (2026-08-20)
* **Data**: `Data/Roads_ek.lua`, `Data/Roads_kalimdor.lua` — polylines in map percentages per zone
  (`{ zone=, name=, pts={{x,y},...}, flavors=, fac=, factor= }`) or world coordinates (`{ inst=, w={{wx,wy},...} }`).
  Polyline ends snap to any other road vertex within 40 yd (interior 8 yd) — that is how a road continues across a
  zone border, i.e. the **zone entrance**. Seed entries are marked *approx* (authored from the maps, ± a few %).
* **Graph**: every vertex is a node of kind `road`, chained by `road` edges costed `dist * roadFactor(1.0) / speed`
  versus `terrainFactor(1.25)` off-road, so Dijkstra follows the road whenever it is < 25 % longer than the crow
  flies, and ignores a real detour (tested). Road nodes live in a 1500-yd grid (`TG.RoadNear`) so the lazy
  complete-walking relaxation only touches nearby vertices — ~120 seed vertices cost nothing measurable.
* **Arrow**: merged walk legs keep `via` points; `Router.Recommendation` aims at the next via point > 25 yd ahead,
  so the arrow turns with the road. `Describe` prints "Follow the road …".
* **Recorder** (`Routing/Roads.lua`): while on the ground (not taxi / flying / dead) the player's path is stored at
  one point per 25 yd in `CompletionRouteDB.roadTrace[inst]`, broken into segments on any 200-yd jump (hearth,
  portal, loading screen), capped at 40k points (oldest dropped). Traces are re-folded into the live graph every
  3 min (`TG.RebuildRoads`) at factor 0.97, so an exact recorded path always beats an approx authored one.
  `/cr road [rebuild|clear|on|off]`. Option: "record the roads I walk".
* **Sharing**: `tools/roads_from_trace.py <SavedVariables/CompletionRoute.lua>` → Douglas-Peucker-simplified,
  de-duplicated `Data/Roads_traced.lua` (add to the TOCs once). `tools/trace_roads.py <marked_map.png> "<Zone>"`
  extracts polylines from a zone map image whose roads were painted pure red (#FF0000) — Daniel's "download the
  zone map, mark the paths" pipeline; blue (#0000FF) blobs come out as POI coordinates.

## Known limitations / ideas
* Only ~40 seed roads exist (SW↔Redridge↔Burning Steppes corridor, Westfall, Duskwood, Dun Morogh/Loch Modan/
  Wetlands, Tirisfal/Silverpine, Durotar/Barrens/Mulgore, Teldrassil/Darkshore/Ashenvale) and they are approximate.
  Coverage grows automatically from play (recorder) or from traced map images; both produce exact data.
* The `faction` policy (now an option) assumes you can fly from any flight master to any other. In every WoW version
  you must have DISCOVERED the destination flight master before you can fly there; that is why `known` is the default.
* `cond` is supported on `Transit.lua` and `Access.lua` entries (2026-11-10, `TG.CondOK`): class, race, level, quest,
  notQuest, spell, item, toy, or a function. Elevator/instance portals and summoning stones are still not authored.
* Taxi speed is a constant; some TBC routes are faster. Fine for ranking.
* Multi-coordinate steps use the nearest coordinate; the optimizer uses the first.

## Retail cross-continent transit (2026-08-21)
The first full in-game retail sweep (9,456 guides from Orgrimmar) had 2,706 guides with no route to step 1.
Cause: `Data/Transit.lua` only knew Classic/TBC boats, zeppelins and the Dark Portal - nothing led off the two
old continents. Added (all approximate +-2%, see the file header; flights inside each continent come from
`Data/Taxi_retail.lua`):
* Stormwind / Orgrimmar **Portal Rooms** (8.1.5+): Boralus | Dazar'alor, Stormshield | Warspear (Ashran),
  Dalaran (Broken Isles, given as uiMapID "627" because retail has two Dalarans), Jade Forest, Caverns of Time,
  Silithus, Azsuna, Oribos, Valdrakken, Dornogal, plus Ironforge/Exodar | Thunder Bluff/Silvermoon.
* Eastern / Western **Earthshrine** (Cataclysm): Mount Hyjal, Vashj'ir, Deepholm, Uldum, Twilight Highlands, Tol Barad.
* Northrend: Stormwind Harbor -> Valiance Keep, Menethil -> Valgarde, Orgrimmar zeppelin -> Warsong Hold,
  Undercity zeppelin -> Vengeance Landing; Orgrimmar <-> Thunder Bluff zeppelin; Pandaria shrines -> capitals.
A zone may be given as a uiMapID string with `name = "..."` for display when the English name is ambiguous.

Verify offline from a capital: `luajit tools/route_sweep.lua retail --from 85 --faction Horde --out
docs/route_sweep_from_retail_85_Horde.tsv` then `python3 tools/collect_route_sweep.py` (table `route_sweep_from`).
Result: 59 -> 24 no-route of 837 baked guides; the 24 are Outland dungeon *instance maps* (Slave Pens, Botanica...)
- there is no transit edge into an instance, the guide's own steps walk you in. Remaining gaps to author when
seen in game: Oribos ring portals to the four Shadowlands zones, Dragon Isles / Khaz Algar internal portals,
Midnight (Quel'Thalas instance 2858) access.

## Zone names that exist many times (retail)
Retail has 7 maps called "Arathi Highlands" (zone, warfront, scenarios), 6 "Isle of Quel'Danas", 3 "Durotar".
`U.MapIDByName` used to take whichever came first from `HBD:GetAllMapIDs()` (arbitrary order, so a guide could
route to a phased warfront copy one session and the real zone the next). Now: prefer zone-type maps (mapType 3),
then the LOWEST uiMapID - the canonical zone always has the oldest id. (`Core/Util.lua buildNameIndex`)

## Router cost
`TG.FindPath` is Dijkstra over a lazy complete walking graph: every popped node relaxes every other node on the
same continent. With retail's ~1,450 nodes that is ~1.3M distance evaluations per call and a guide sweep makes
thousands of calls. Two cheap fixes (`Routing/TravelGraph.lua`): a per-instance node index (`TG.byInst`) so the
inner loop only sees nodes on the player's continent, and `TG.InstReachable` - union-find over the instances that
explicit edges connect - so a goal on a continent nothing leads to (or that only the hearth reaches) is answered
without a search. 37x fewer relaxations, identical routes (same TSV). `TG.stats` counts calls/pops/relaxations;
`tools/route_sweep.lua` prints them.

## Access chains - places you have to unlock first (2026-08-21)
`Data/Access.lua`. Some zones cannot be travelled to at all until an intro quest line is done: the Siren Isle
(airship after "To the Siren Isle!"), K'aresh (Spatial Rift after the Locus-Walker's invitation), Zereth Mortis
(Call of the Primus), the Isle of Thunder (Thunder Calls), Argus (The Hand of Fate -> the Vindicaar), Nazjatar
(Send the Fleet), Undermine (the Rocket Drill), Midnight's Quel'Thalas (Light's Summon). Each entry is
* a **transit edge** for the router: locked -> from where the chain starts, cost = the whole chain; unlocked
  (`unlock` quest complete) -> the cheap `after` edge (portal / airship / beacon);
* the **steps** to do it, in guide format (quest ids, NPC, coordinates) - `Progress.Load` injects them in front
  of any guide whose first located step lies behind a locked chain (indices -k..-1, so the guide's own progress
  keys are untouched; chat: "Access: N steps to unlock ... first"). Comprehensive zone guides open the same way.
When an `unlock` quest is turned in, only the access edges are rebuilt (2026-11-10, see "What changes the graph"), so
a freshly unlocked chain switches to its `after` edge; any other turn-in leaves the graph alone.
Offline check: `luajit tools/test_access.lua` (resolves, routes through, parses, injects, un-injects when done).
Entries marked `approx = true` were written from memory / Wowhead (e.g. Horde
Nazjatar) - verify in game. Not yet chained: Dalaran-Crater / scenario starts, pet-battle maps inside instances.


## Full guide sweep after transit additions (2026-09-25)

The offline sweep processed all 15,865 current guide records (771,737 steps) across Era, TBC, MoP, and retail.
It found no load failures, quest precedence violations, or unreachable first steps from each guide’s modeled starting zone. Retail had 10 guide windows
where the measured first-window route cost exceeded author order; all individual guide rows are in
`verification.sqlite` / `verification.sql` and `route_sweep_retail.tsv`. Treat the optimizer as a bounded heuristic,
not a proof of a global optimum. The 10 cases need review if a zero-regression guarantee is required.

```sql
SELECT flavor, COUNT(*) AS guides, SUM(steps) AS steps,
       ROUND(100.0 * SUM(located) / NULLIF(SUM(steps), 0), 1) AS located_pct,
       SUM(CASE WHEN route_ok = 'no' THEN 1 ELSE 0 END) AS unreachable,
       SUM(CASE WHEN order_ok = 0 THEN 1 ELSE 0 END) AS precedence_violations,
       SUM(CASE WHEN opt_cost > author_cost + 1 THEN 1 ELSE 0 END) AS slower_windows
FROM route_sweep GROUP BY flavor ORDER BY flavor;
```

## Tier A: offline route optimizer (FINISH_PLAN W3, 2026-11-07)

Bakes, per quest guide (wiki zone guides `wiki:*` + gaps guides `qdb:*`/`qpoi:*`), the fastest legal step order.

1. `luajit tools/cost_matrix.lua <fl> [--sample K] [--guide ID] [--exact]` loads the real addon (parser, TravelGraph
   with the flavor's taxi/transit/roads/access, Router) and writes one JSON line per guide to
   `~/.claude/jobs/.../tmp/costmx/<fl>.jsonl` (never the repo): the parsed steps and the travel-seconds matrix between
   the guide's distinct step locations, plus a start column from the guide zone's centre (where vplayer starts).
   Costs = `Router.TravelSeconds` (walk < 700 yd, else FindPath with taxi/boats/portals/roads; **no hearth** - the
   pairwise router never spends the one-shot hearth). Default mode runs FindPath's search once per source point
   (same graph, rules and walk costs) instead of once per pair; every guide re-checks 200 random pairs against
   `Router.TravelSeconds` and records the largest difference (`verify_maxdiff`; 0.000 s on every run so far).
2. `venv/bin/python tools/optimize_routes.py <fl>` (OR-Tools 9.15 in `../venv`, python 3.12 via uv). Model per
   guide: blocks = a located step + the unlocated steps after it; anchors (non-routable / sticky steps) cut the guide
   into independently solved segments. Hard rules: A < C < T per quest, PRE turn-in < accept (only edges the author
   order keeps), quest log <= 20 (era/forever) / 25 (tbc/mop) / 35 (retail) or the author's own peak, level gates
   (a step above the start level needs as many turn-ins before it as the author needed before its first step of that
   level). Solve: feasible nearest-neighbour vs author order -> OR-Tools routing (order/log/turn-in dimensions, guided
   local search, 2 s + 0.1 s/block, max 30 s) -> exact DP over precedence-closed subsets on the metric closure of the
   costs (<= 90 blocks, 6 s): when it finishes its optimum is a true lower bound (`lb_exact`), otherwise the bound is
   max(assignment, MST, Held-Karp) and ignores precedence (loose). Writes `Data/RouteOrder_<fl>.lua` (gitignored;
   only guides the bake makes > 1 s faster) as `O[id] = { n, sum, o = "1-5,9,6-8" }`.
3. `Core/Guide.lua G.Steps` permutes a guide's parsed steps when `n` and the checksum still match (`G.BakedOrder`;
   spine entries look up their `part`). `s.index` stays the author index, so saved progress never moves;
   `P.Undo` compares display positions. Option "use the pre-computed fastest order" = `routing.baked`. The live
   12-step window (`Router.OrderSteps`) still runs on top.
   The bake keeps the faction-wide flight rule (`cost_matrix.lua` pins `taxiPolicy = "faction"`; its `settle` copy
   still has the old both-ends rule for `known`) and never sees teleports (it does not load `Routing/Teleports.lua`, and
   pairwise costs exclude one-shot legs anyway). The cost-model rework (docs/IDEAS.md) decides whether that changes.
4. Measure: `luajit tools/vplayer.lua <fl> --guides-file F --order author|baked --live on|off`, then
   `python3 tools/collect_routes.py collect` -> `route_compare`, `opt_violations` in `docs/verification.sqlite`.
   Check: `luajit tools/test_route_order.lua`.

## Flight paths: only the ones the character has discovered (2026-11-10, branch routing-graph)

Default `routing.taxiPolicy = "known"`. A taxi edge u→v is usable only when v is discovered. u may be undiscovered:
the route walks there, the player talks to the flight master (that discovers it) and flies on. That walk leg gets
`pickup = true`, the title "Walk to X and pick up the flight path", and `Describe` adds "(pick up the flight path)".
Every hop of a multi-hop flight lands on a node, so each must be discovered, as in the client.

Which flight paths count:
* **Classic Era, TBC Anniversary, MoP Classic**: each character has its own (`CompletionRouteCharDB.knownTaxi`).
* **Retail and WoW Forever**: the client shares discovered flight paths across the account, so the account-wide set
  (`CompletionRouteDB.knownTaxi`) counts too (`NS.taxiShared`, set in `Core/Init.lua`).
Older builds copied the account-wide set into every character on every client. On the first load of this build a
Classic character's set starts empty once (the old copy is kept as `knownTaxiMerged`, unused); the next flight-master
visit refills it. A profile still on the old `faction` default moves to `known` once (`routing.taxiKnown1`); Options
still offers the old rule.

Learning: `TAXIMAP_OPENED` (flight map open: `C_TaxiMap.GetAllTaxiNodes` states, the retail flight-map pins, the
Classic `TaxiNodeGetType` list) and 8 s after login `C_TaxiMap.GetTaxiNodesForMap` on every continent, where only an
explicit `isUndiscovered == false` counts. A node the client does not mark as discovered is never assumed. Not checked
in a client: whether the Classic clients fill `isUndiscovered` at all. If they do not, a Classic character flies only
after opening a flight master's map on each continent (the login hint says so).

A learned flight path wipes the path cache (`TG.TaxiChanged`), so StepOrder recomputes its pair costs.

Which rule each tool uses:

| Tool | Flight rule |
|---|---|
| The client | `known` (Options: "fly to every flight master your faction can use" = `faction`) |
| `tools/cost_matrix.lua` (the bake) | `faction`, pinned, unchanged (its output for `wiki:era:1416:Alliance` and `wiki:retail:76:Horde:1` is identical before and after this branch, apart from the run time) |
| `tools/vplayer.lua` | `--taxi all` (default) = `faction`; `--taxi learn` = `known`, starting each guide with nothing known |
| `tools/route_sweep.lua` | `faction`, pinned |
| `tools/test_*.lua` | `assumeAllTaxi` or `faction`, except the taxi tests in `test_offline.lua` |

`vplayer --taxi learn` discovers the flight master the route took off from (it walked there) and any flight master
within 40 yd of each step the player stands on (an `f` step's included). The bake gain has not been re-measured under
`learn`; that belongs to the cost-model rework.

## What changes the graph (2026-11-10, branch routing-graph)

A quest turn-in used to set `TG.built = false`: the next search rebuilt every taxi, transit and road node, replaced the
path cache, and StepOrder then dropped every kept pair cost. Now each event drops only what it changes:

| Event | What is rebuilt or dropped |
|---|---|
| Turn-in of an access chain's `unlock` quest (or a quest an Access `cond` reads) | the access edges only (`TG.RebuildAccess`); path cache, so StepOrder's kept costs |
| Turn-in of a quest a Transit `cond` reads | the whole graph (lazily, `TG.Ensure`) |
| A spell learned, item looted, level gained that flips a Transit/Access `cond` | the whole graph (`TG.RecheckConds`) |
| A flight path learned | path cache (`TG.TaxiChanged`); StepOrder's kept costs |
| Hearth re-bound (moved > 30 yd), a teleport or hearth item becomes usable or unusable, a teleport quest `cond` turned in | only the costs from the player (`TG.oneShotGen`, `TG.OneShotChanged`) |
| Any other turn-in | nothing |

The unlock set is collected at build time (`TG.unlockQuests`). Quests turned in this session (`TG.turnedIn`) count as
completed at once, because `IsQuestFlaggedCompleted` can lag the `QUEST_TURNED_IN` event. Tests: `tools/test_access.lua`
(an ordinary turn-in keeps the graph and the path cache; the K'aresh unlock rebuilds only the access edges and matches
a full rebuild), `tools/test_live_route.lua` (kept costs survive a turn-in; a one-shot change re-prices only the
from-player costs).

Measured with `luajit -joff tools/vplayer.lua <fl> --guides-file F --turnins --guidecap 300` on 12 wiki guides per flavor
(every 7th wiki guide id; the ids are in docs/STATUS.md, 2026-11-10), before = the branch base's `Init`, `Util`, `Progress`,
`TravelGraph`, `StepOrder`, `Router` loaded through `CR_OVERRIDE`. The handler time covers every `QUEST_TURNED_IN`
handler, including the Progress refresh and live re-plan it starts:

| Flavor | Turn-ins | Handler ms, mean / p50 / p95 / max | Graph builds in handlers | Router calls in handlers | Whole run, CPU s |
|---|---:|---|---:|---:|---:|
| era, before | 227 | 9.30 / 0.71 / 47.7 / 80.2 | 95 | 2,926 | 19 |
| era, after | 227 | 5.24 / 0.62 / 32.5 / 66.8 | 0 | 2,067 | 5 |
| retail, before | 293 | 90.4 / 25.4 / 300 / 784 | 225 | 10,409 | 193 |
| retail, after | 293 | 37.6 / 7.5 / 180 / 524 | 0 | 9,911 | 43 |

The whole-run CPU falls more than the handler time because every rebuild also emptied the path cache, so later
searches outside the handler repeated Dijkstras that had been cached. Results: the 12 retail rows are identical before
and after. 11 of 12 era rows are identical; `wiki:era:1431:Alliance` simulated 143 steps and 9,017 s instead of 144
and 9,185 s. Re-running it with a path-cache wipe added to every turn-in reproduced the old row exactly, so the
difference comes from costs now kept across a turn-in (most likely the from-player costs, which the existing 40-yd
rule lets go a little stale), not from a changed cost model.

The re-plan after a turn-in still costs something (the window moved by one step and the player moved), but it no longer
rebuilds the graph or recomputes the pair costs the window already had.

## Teleports (2026-11-10, branch routing-graph)

`Data/Teleports.lua` (73 entries) + `Routing/Teleports.lua`. Kinds:
* class spells: every mage teleport per faction and expansion (Classic cities, Exodar, Silvermoon, Theramore, Stonard,
  Shattrath, Dalaran Northrend, Ancient Dalaran, Tol Barad, Vale of Eternal Blossoms, Stormshield, Warspear, Dalaran
  Broken Isles, Boralus, Dazar'alor, Oribos, Valdrakken, Dornogal), Teleport: Moonglade, Death Gate (MoP Classic only);
* engineering transporters (Everlook, Gadgetzan, Area 52, Toshley's Station): trinkets that must be worn on Classic Era
  and TBC (ItemSparse InventoryType 12), bag items on Forever and MoP Classic, toys on MoP Classic and retail;
* the Dalaran and Garrison hearthstones (the garrison one needs "Establish Your Garrison");
* 36 Hearthstone stand-ins (toys and items that share the Hearthstone's destination and cooldown). One is used only
  when no Hearthstone is in the bags (`U.HearthReady`); its cast also counts for H steps and the bind recorder.

Rule (the hearth's): an edge from the player when the spell is known (and its reagent, Rune of Teleportation on Era,
Forever and TBC, is in the bags) or the item or toy is owned and usable (`C_ToyBox.IsToyUsable`, `IsUsableItem`), its
`cond` holds, and its cooldown has at most 15 minutes left. Cost = `hearthCost - 10 + cast + cooldown left`. Never on a
pairwise (`hearth = false`) query, so step-order costs and the bake are unchanged. What is usable is recomputed on
`SPELLS_CHANGED`, `BAG_UPDATE_DELAYED`, `PLAYER_EQUIPMENT_CHANGED`, `NEW_TOY_ADDED`, `TOYS_UPDATED`, cooldown events and
level-up (1 s throttle); a change bumps `TG.oneShotGen`. Option: "suggest class teleports, transporters and hub
hearthstones". `/cr teleports` lists every candidate and why it is or is not offered.

Landing points are world coordinates `{ instance, x, y }`, so one entry serves every client: a wiki `{{Co|x|y|map}}` on
the modern map (`cite`, converted with `tools/maps_retail.lua`) or a TaxiNodes position. Darnassus and Undercity land
elsewhere on retail (the Battle for Azeroth phase Zidormi controls), so they have a retail entry each. The Orgrimmar
spot is the modern city's; on Classic Era and TBC it is approximate. After a teleport cast the first jump that lands
within 500 yd of the data point is stored (`CompletionRouteDB.teleportFix`) and used from then on.

Checks: `tools/test_teleports.lua` (every landing point recomputed from its citation; Era mage with and without rune,
cooldown, Options, arrow, learned landing; worn trinket; retail hearth toy, Garrison Hearthstone quest), and
`tools/check_teleports.py --fetch --wiki` (names in SpellName / ItemSparse per client, reagents in SpellReagents, use
spells and cooldowns in ItemEffect, trinket slot, shared Hearthstone cooldown in SpellCategories, and every cited wiki
page holding the id and coordinate). Last run: 134 entry-client checks and 73 wiki checks, 0 failures.

Not done: Zen Pilgrimage (the wiki gives no landing point, and the Peak of Serenity cannot be left on foot), retail
Death Gate (which Acherus depends on Legion progress), Dreamwalk and class-hall teleports (the landing is a hub whose
exits are not in the graph), Midnight's Teleport: Silvermoon City (no landing point on the wiki), Kirin Tor rings,
Ruby Slippers (must be worn), random-destination wormholes. Nothing here has run in a client: the secure `toy` button
type, `C_ToyBox.IsToyUsable`, the cooldown readings for toys and the landing spots all need Daniel's beta.

