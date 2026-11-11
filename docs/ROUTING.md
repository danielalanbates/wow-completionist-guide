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
4. Measure: `luajit tools/vplayer.lua <fl> --guides-file F --order author|baked --live on|off`, then
   `python3 tools/collect_routes.py collect` -> `route_compare`, `opt_violations` in `docs/verification.sqlite`.
   Check: `luajit tools/test_route_order.lua`.

## Skipping quests

(2026-11-10.) `Core/Skip.lua`, `Routing/Replan.lua`, `Routing/TravelGraph.lua` (`FindPaths`), `Data/QuestDeps_<flavor>.lua`,
`tools/gen_quest_deps.py`, `tools/test_skip.lua`.

**What the player does.** "Skip quest" in the step details, the right-click menu on the step, or `/cr skip [questID]`
(default: the current step's quest). A quest that nothing needs goes at once with one chat line. A quest other quests
need opens a confirmation: it names the quest, lists the quests that can no longer be done (first four names, then
"and N more", split *in this guide* / *in other guides*, plus how many of them only this guide loses), and says what
dropping the chain costs: quests and steps leaving this guide, quests leaving other guides, and, when the guide still has
`|LVL|` gates ahead, that fewer quests means level-gated steps may open later (parking handles an under-level player; no
filler quests are added). Only quests this character could take are named and counted. Confirm drops the quest and
locks its dependents; cancel changes nothing. The per-step Skip (`/cr skipstep`, the step's Skip button, the right-click
item) on the accept of a quest that is not in the quest log drops the quest: skipping only the accept would leave its
objectives and turn-in with nothing to work on. On a turn-in that other quests need it gives the same warning.
`/cr unskip <questID|all>`, `/cr skipped`.

**Data.** Quest ids are global, so a drop applies to every guide. The reverse index is built offline per client by
`tools/gen_quest_deps.py` from the generated guides that client loads, in priority order wiki -> gaps guides -> retail
storylines (a quest's prerequisites come from the first source that has the quest at all). WoW-Pro text is not read
(its licence forbids derivatives). Fields: `pre` (hard prerequisites), `free` (predecessors a quest's guides list but
that were dropped as soft), `crumb` (breadcrumb quests), `never` (quests the hard prerequisites make unobtainable: a cycle
with no way in, and what needs it), `name`. Output `Data/QuestDeps_<flavor>.lua` is gitignored, loaded by each TOC after
its RouteOrder file, shipped per client by `tools/install.sh`, and parsed on first use (about 12 ms on retail, once).
When the file is missing, or a guide comes from a family the index is not built from (WoW-Pro, native), that guide's own
`|PRE|` tags fill in quests the index has no entry for.

| | era | tbc | mop | retail | forever |
|---|---:|---:|---:|---:|---:|
| Quests in the client's guides | 4,268 | 6,666 | 17,711 | 29,937 | 4,452 |
| Quests with hard prerequisites | 2,163 | 3,237 | 9,613 | 18,071 | 2,249 |
| PRE edges | 2,410 | 3,552 | 11,737 | 21,959 | 2,504 |
| Breadcrumb edges dropped | 20 | 22 | 63 | 130 | 21 |
| "(optional)" edges dropped | 4 | 4 | 31 | 79 | 7 |
| Quests with freed predecessors (`free`) | 15 | 15 | 81 | 193 | 19 |
| Unobtainable by the data (`never`) | 0 | 0 | 0 | 179 | 0 |
| File size | 93 KB | 142 KB | 413 KB | 743 KB | 96 KB |

**Breadcrumbs.** The wiki has no breadcrumb field, so the generator trusts only explicit wording (raw wikitext in
`tools/wiki/cache/wiki_raw.sqlite`, read-only): a quest page that calls itself a breadcrumb ("'''X''' is an optional
breadcrumb...", "This quest is a breadcrumb...", "This breadcrumb quest..."), another quest's chain listing that marks it
("[[X]] (optional breadcrumb)", "Optional breadcrumb: [[X]]", "Breadcrumbs:" lists), and, per edge, "(optional)" after a
link in a quest's own `previous=` field. 145 pages and 186 optional `previous` links match. A plain "(optional)" in a
Progression list is not trusted: it also marks side quests whose own follow-ups need them. Leaving a breadcrumb out of the
index is not enough on its own: the guides still list it in the target's `|PRE|`, and `Conditions.StepApplies` hides a
step until its PRE is done. So a PRE predecessor the player skipped that is soft for that step (`free` or `crumb`) is no
longer waited for (`Skip.PreOpen`), and the target stays fully doable: accept, objectives and turn-in. On era, skipping
Eagan Peltskinner (5261) leaves Wolves Across the Border (33) with its accept as the next step, Deliveries to Sven (164)
no longer blocks Sven's Revenge (95), and the three "A Call to Arms: The Plaguelands!" breadcrumbs no longer block Clear
the Way (5092). Gaps-guide and storyline edges have no breadcrumb information.

**Lock rule.** First the dropped quest's dependents are found (index edges, transitively). Then the ones that can still
be had are grown from what lies outside them (least fixpoint): `p1;p2` opens with any one, `p1&p2` needs all. Growing
instead of cutting matters for prerequisite cycles with an any-one list: on retail, dropping 82863 now locks the 19
quests that hang on it, where cutting outward from the dropped quest locked 1 (12 sit behind a cycle). A quest the
character has done or has on the log is past its prerequisites and never locked; a dropped quest that was already turned
in blocks nothing; a quest the data never made obtainable (`never`) is not this drop's doing. Locks are recomputed from
the remaining roots on every drop and unskip, so unskipping one quest frees exactly what only it blocked. Checked against
a whole-index reachability reference (reachable before minus reachable after) on about 60 roots per client: exact on all
five. Stored per character in `A.me.questSkip` (`roots`, `locks`, `plans`), never shared: like a step skip it is one
character's choice, whatever the progress scope. Quests for another class, race or faction are locked like any other but
not named or counted in the warning (tbc, Blood Elf mage, Reclaiming Sunstrider Isle: 16 named instead of 21).

**What one guide loses.** A guide only offers a quest once one of that quest's accept steps (that this character can see)
opens. When every one of them waits, through the guide's own `|PRE|`, on a removed quest the index does not link
(storylines order quests the wiki does not chain; WoW-Pro tags; the first-source rule), the quest is out of that guide,
with every step and with what needs it there. This is per guide, not a shared lock, because another guide may still
offer the quest. The loaded guide's losses are part of the warning ("N of them only here"); other guides work theirs out
when opened, and `/cr unskip` on such a quest says why it is out. Measured by dropping every PRE predecessor of an accept,
one at a time, on sample wiki, WoW-Pro and storyline guides (`tools/test_skip.lua`): no quest is left on screen whose
accepts all wait on a removed quest, and none keeps its objectives or turn-in without its accept (era 89 drops on 13
guides, tbc 105 on 13, mop 108 on 14, retail 132 on 18, forever 47 on 7). The cost is real: dropping one quest of a
Blizzard storyline guide takes the rest of that storyline out of that guide (story:retail:546, 689 steps, loses 357 to one
quest no other quest needs; the warning lists 116 quests "only here").

**Rebuild.** The guide on screen is a projection of the guide's own steps (`P.baseSteps`, baked order). Out go: every
step whose quests are all removed or lost by this guide (a step serving any remaining quest this character can take
stays), steps shown only while on a removed quest (`|ACTIVE|`), quest-less steps waiting for removed prerequisites, run /
fly / boat / portal / hearth / dungeon steps whose stretch up to the next kept travel step only served removed quests,
and then the unlocated note / use / kill / loot steps riding with any removed step, travel steps included (the
optimizer's block rule). Flight-path and hearth-bind steps always stay. Ticks stay keyed by author index, so nothing is
lost; step numbers, "step x of y", done counts, the guide list percentage and the "guide complete" check all follow the
rebuilt list. The current step is re-chosen at once (the arrow re-targets). Other guides are rebuilt when opened. Unskip
gives back the identical list.

**Re-plan.** After a drop or unskip, and the first time another guide with removed steps is opened, the remaining guide
is re-planned for travel time. Model = the offline bake's: only steps still to do that this character can ever see
(steps for another class, race, faction or profession keep their places and bind nothing), anchors fixed and cutting
segments, blocks of one step with an `|M|` point plus the steps after it without one, A < C < T per quest, PRE turn-in
before the dependent, quest log at most max(cap, the baseline's own peak) (removed quests free space), level gates as in
the bake. Every step the arrow can point at is priced: its `|M|` point, or without one the live quest objective or the
zone centre, as `Router.StepWorld` and the live window see it; a leg runs from one block's last priced step to the next
block's first.

* **One cost set per job.** Speed, walking factor, player position and the travel graph (`TravelGraph.Snapshot`: nodes,
  roads, continent links, usable flight masters) are fixed when the job starts, so mounting, flying, a turn-in that
  rebuilds the graph or a learned flight path mid-job cannot mix two cost sets. The review's case (mop 115, foot to
  30 yd/s after 50 frames) used to accept an order 2.3% slower at the starting speed; it now reports the same numbers as
  with no speed change and keeps the baseline.
* **Rows, not pairs.** A block's costs to every block of its segment come from one Dijkstra with all of them as goals
  (`TravelGraph.FindPaths` through `Router.TravelRow`). Equal to `FindPath` pair by pair (largest difference 0.000000 s
  on 15,549 pairs over the five clients) and 13-23 times faster. Retail 122 (102 blocks): 14.4 s of CPU and about 4
  minutes at 60 fps before, 3.3 s and 67 s now.
* **Search** per segment from two starts, the baseline and a greedy nearest-feasible order, keeping the cheaper:
  first-improvement Or-opt (1-3 blocks moved next to one of their nearest blocks by travel time, so other continents
  count; every block when the segment has at most 60) and 2-opt (up to 40 blocks), with don't-look bits.
* **Acceptance.** The new order must save max(`StepOrder.MIN_GAIN`, `StepOrder.GAIN_FRAC` of it), the live window's
  margin, on the route the arrow walks, AND the route through the steps with their own `|M|` (the bake's measure) may not
  get longer: a zone centre only stands in for an objective, and a saving must not come from the stand-in alone. When the
  first search fails either test, a second search on the `|M|` steps alone gets its chance. So a kept re-plan never costs
  more than "baked order minus removed steps" by either measure; the test checks both with the live router, pair by
  pair. The decision is saved under the rebuild key (step count, route checksum, quests out of the guide), so a reload
  shows the same order without re-planning. The live window keeps working on top.

**CPU.** The re-plan is a coroutine resumed from an OnUpdate with `RP.FRAME_MS` = 0.8 ms; the graph search yields after
every settled node and every 64 walking links, and reuses its tables between searches (less work for the Lua
collector). The title shows "re-planning...". Applying a kept order is one `Progress.Refresh` in the next frame that keeps
the live window's travel costs (median 2.9 ms, max 3.1 ms over 7 applications; the live window inside it has its own
3 ms budget, as after any step tick). The click itself (warning, locks, rebuild) costs 0.3-4 ms, plus about 12 ms the
first time the retail index is parsed.

**Measured** (`CR_SKIP_SAMPLES=6 luajit -joff tools/test_skip.lua`: 30 real wiki guides, the quest with the most in-guide
dependents dropped in each, stub maps and the real travel graph, route orders as baked by 2026-11-10 22:17):

| | era | tbc | mop | retail | forever |
|---|---:|---:|---:|---:|---:|
| Re-plans kept / guides | 2 / 6 | 0 / 6 | 4 / 6 | 0 / 6 | 1 / 6 |
| Kept back: gain only at zone stand-ins | 0 | 3 | 0 | 2 | 1 |
| Remaining route, baked minus removed | 48,032 s | 49,152 s | 33,511 s | 25,351 s | 43,312 s |
| After re-plan | 47,483 s | 49,152 s | 29,839 s | 25,351 s | 42,248 s |
| Saved | 1.1% | 0% | 11.0% | 0% | 2.5% |

Kept re-plans save 5.5% to 28% (mop 119, mop 108). Overall 7 of 30 kept and 2.7% saved. The heaviest sample
(retail 1543, 189 steps) took 4.2 s of CPU over 5,267 frames (about 88 s at 60 fps). Per frame: collector paused, 6,803
frames, p99 0.86 ms, max 1.20 ms; collector running, 11,993 frames, p99 0.90 ms, max 1.53 ms; none over 2 ms.

**Limits.** Nothing here has run in a client (StaticPopup on retail 12.x is unverified; the popup falls back to a chat
line and `/cr skip <id> confirm`). A zone centre is a poor stand-in for an objective, and the plan cannot know where a
quest's objective is before the quest is taken: the second acceptance test keeps that from lengthening the route through
the known points, but savings on the arrow's measure are estimates. The live window recovers much of the same gain on its
own: on retail 122, before the latest bake, a kept re-plan plus the live window ended 0.2% longer than the live window
alone on the baked order (the review's simulation), so the table's savings are against the baked order, not against
what the live window already does. The baked orders are still being rebuilt by the offline bake and these numbers move with them (the same run
before the 22:17 bake kept 10 of 30 and saved 6.0%).
