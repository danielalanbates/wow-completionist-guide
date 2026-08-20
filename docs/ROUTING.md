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
