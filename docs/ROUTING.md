# Routing engine

## Travel graph (`Routing/TravelGraph.lua`)
* **Nodes**: taxi nodes for the current flavor/faction (`Data/Taxi_<flavor>.lua`, generated from wago.tools
  `TaxiNodes/TaxiPath/TaxiPathNode` — world coordinates + real polyline flight lengths), transit endpoints
  (`Data/Transit.lua`), the character's hearth (`NS.db.char.bind` learned, else `Data/Inns.lua` seed via `GetBindLocation()`),
  virtual start (player) and goal.
* **Edges**: taxi (`3s + length / taxiSpeed(32)`). Policy `routing.taxiPolicy`: **`faction` (default)** = every
  flight master the faction can use is routable, learned or not - the route walks you to the right flight master and
  labels a leg to an unlearned node "(new flight path)"; `known` = only learned nodes (the old behaviour, still
  harvested at login / TAXIMAP_OPENED).
  transit (`cost` seconds = avg wait + ride), hearth (`hearthCost(60) + cooldown remaining`, hidden if >15 min),
  implicit walking between any two nodes on the same continent instance: `dist * terrainFactor(1.25) / speed`.
  Speed = live `GetUnitSpeed` if moving, else guess from level (7 / 11.2 / 14 yd/s).
* **Search**: Dijkstra with a binary heap; complete walking graph is relaxed lazily on pop (~200 nodes → cheap).
  Direct walk < 300 yd short-circuits.
* **Output**: `{cost, legs[{mode, from, to, cost, title, data}]}`; consecutive walk legs merged.
  `TravelGraph.Describe(path)` → "Walk 457 yd to Darkshire; Fly … ; Take the boat … (~10m)".

## Step-order optimizer (`Routing/StepOrder.lua`)
Given the next `window` (10) pending steps: build precedence (`A<C<T` per quest, `PRE` turn-in before accept,
non-routable/sticky steps as anchors keeping author order around them), greedy nearest-feasible-neighbour from the
player using `Router.TravelSeconds` (walk-only under 700 yd, else Dijkstra without hearth), then Or-opt improvement.
Author order breaks ties. Toggle with the `Route` button or `/or options`.

## Arrow recommendation (`Routing/Router.lua`)
1. step has `|U|item` in bags and you're within 40 yd (or step has no location) → **item button**
2. step is `H` → **hearth button**
3. first leg of the path is `hearth` → **hearth button** with "saves time" + ETA
4. first leg walk → arrow to leg end (a flight master / dock / the goal); text explains what happens there
5. first leg taxi/transit → arrow to that node with "Fly to X" / "Take the boat …"

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
* Faction policy assumes you can fly from any flight master to any other. In every WoW version you must have
  DISCOVERED the destination flight master before you can fly there; the leg is labelled "(new flight path)" so
  the player knows they may have to walk that last hop the first time. `known` policy is the strict option.
* Elevator/instance portals, class teleports (mage portals, druid Moonglade taxi), summoning stones: add to `Transit.lua`
  with `cond` (not yet supported → add `cond=function() end` evaluation in `TG.Build`).
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
The graph is rebuilt after a quest turn-in so a freshly unlocked chain switches to its `after` edge.
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
