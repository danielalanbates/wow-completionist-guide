# Routing engine

## Travel graph (`Routing/TravelGraph.lua`)
* **Nodes**: taxi nodes for the current flavor/faction (`Data/Taxi_<flavor>.lua`, generated from wago.tools
  `TaxiNodes/TaxiPath/TaxiPathNode` — world coordinates + real polyline flight lengths), transit endpoints
  (`Data/Transit.lua`), the character's hearth (`NS.db.char.bind` learned, else `Data/Inns.lua` seed via `GetBindLocation()`),
  virtual start (player) and goal.
* **Edges**: taxi (`3s + length / taxiSpeed(32)`; only if BOTH endpoints are learned — Classic requires it),
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

## Known limitations / ideas
* Walking is straight-line × terrain factor: no walls, cliffs, rivers, indoor maps. Zygor's LibRover has hand-authored
  "border" and "walled segment" data. Pathway: add optional per-zone polyline "road" nodes to `Transit.lua`
  (mode `road`, cost 0) — the same graph handles it.
* Elevator/instance portals, class teleports (mage portals, druid Moonglade taxi), summoning stones: add to `Transit.lua`
  with `cond` (not yet supported → add `cond=function() end` evaluation in `TG.Build`).
* Taxi speed is a constant; some TBC routes are faster. Fine for ranking.
* Multi-coordinate steps use the nearest coordinate; the optimizer uses the first.
