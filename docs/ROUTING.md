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
before the step that names it, non-routable and sticky steps as anchors with everything before them staying before them,
a step the cost model does not locate (no place at all, or done where the player already is: "One cost model" below)
staying on the block before it, and a quest log that a repair may not push above the cap or the baseline's own peak.

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
`SO.KeptCost(a, b)` reads a kept pair cost without ever searching (nil when unpriced or stale); `/cr bug` uses it for
its upcoming list ([BETA_REPORTS.md](BETA_REPORTS.md)).

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

Bakes, per shipped quest guide (the wiki zone guides, ids `wiki:*`), the fastest legal step order. (Until 2026-11-11
the bake also ordered the Questie-derived `qdb:*`/`qpoi:*` gaps guides of the dev build; those guides are gone, and the
measurements below that name such ids are history.)

1. `luajit tools/cost_matrix.lua <fl> [--sample K] [--guide ID] [--exact] [--taxi faction|band]` loads the real addon
   (parser, TravelGraph with the flavor's taxi/transit/roads/access, Router) and writes one JSON line per guide to
   `$CR_TMP/costmx/<fl>.jsonl` or `--out` (never the repo): the parsed steps (with the checksum parts and the cost
   model's kind), the travel-seconds matrix between the guide's priced points, a start column from the guide zone's
   centre (where vplayer starts) and the cost model's constants (`"cm"`). Which steps are priced, where, at what speed
   and with which flight paths is the cost model's decision ("One cost model" below). Rows come from
   `Router.TravelRow` (one `TravelGraph.FindPaths` search per source point, equal to `Router.TravelSeconds` pair by
   pair: a walk below 700 yd, else the graph without the hearth); `--verify N` re-checks N random pairs per guide
   against `Router.TravelSeconds` (`verify_maxdiff`, 0.000 s on every run so far). The old private Dijkstra copy
   (`settle`) is gone.
2. `venv/bin/python tools/optimize_routes.py <fl>` (OR-Tools 9.15 in `../venv`, python 3.12 via uv). Model per
   guide: blocks = a priced step + the steps after it that ride along; anchors (non-routable / sticky steps) cut the
   guide into independently solved segments. Hard rules: A < C < T per quest, PRE turn-in < every step that names it
   (only edges the author order keeps; until 2026-11-10 only accepts), objective steps of a quest in author order when
   one of them ticks by itself (`CostModel.PlanSteps`), quest log <= 20 (era/forever) / 25 (tbc/mop) / 35 (retail) or the author's own peak, level gates
   (a step above the start level needs as many turn-ins before it as the author needed before its first step of that
   level). Solve: feasible nearest-neighbour vs author order -> OR-Tools routing (order/log/turn-in dimensions, guided
   local search, 2 s + 0.1 s/block, max 30 s) -> exact DP over precedence-closed subsets on the metric closure of the
   costs (<= 90 blocks, 6 s): when it finishes its optimum is a true lower bound (`lb_exact`), otherwise the bound is
   max(assignment, MST, Held-Karp) and ignores precedence (loose). Writes `Data/RouteOrder_<fl>.lua` or `--lua-out`
   (gitignored; only guides the bake makes > 1 s faster and, with `--gate`, that vplayer confirms) as
   `O[id] = { n, sum, o = "1-5,9,6-8", va, vb }` (va / vb: the gate's measured seconds, "Bake gate" below).
3. `Core/Guide.lua G.Steps` permutes a guide's parsed steps when `n` and the checksum still match (`G.BakedOrder`;
   spine entries look up their `part`). `s.index` stays the author index, so saved progress never moves;
   `P.Undo` compares display positions. Option "use the pre-computed fastest order" = `routing.baked`. The live
   12-step window (`Router.OrderSteps`) still runs on top.
   The bake's flight rule is the cost model's `OFFLINE_TAXI` (faction-wide, decided and measured 2026-11-10 in "One
   cost model"), installed by `tools/cm_offline.lua`; it never sees teleports or the hearth (one-shot legs).
4. Measure: `luajit tools/vplayer.lua <fl> --guides-file F --order author|baked --live on|off`, then
   `python3 tools/collect_routes.py collect` -> `route_compare`, `opt_violations` in `docs/verification.sqlite`.
   Check: `luajit tools/test_route_order.lua` (fails on a stale entry) and `luajit tools/test_cost_parity.lua`.
5. One bake (2026-11-11, `docs/RELEASE.md`). There is no separate release bake: `tools/cost_matrix.lua` loads only
   files the TOCs load (no `_gaps` guides, no `Data/Imported_Entrances.lua`) and lists only `wiki:` guides, so
   `tools/bake_resume.py` bakes exactly what ships. `tools/package_release.py` fails a `RouteOrder` row for a guide
   that only a never-shipped file registers and notes rows that name no guide.

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
`tools/gen_quest_deps.py` from the wiki quest guides that client loads (`Imported_Wiki_<flavor>.lua`), and from nothing
else. For a quest the index lacks, a guide outside the wiki and spine families (quest lines, hand-written, live) speaks
through its own `|PRE|` tags. No other addon's guide text is read. Fields: `pre` (hard prerequisites), `free` (predecessors a quest's guides list but
that were dropped as soft), `crumb` (breadcrumb quests), `never` (quests the hard prerequisites make unobtainable: a cycle
with no way in, and what needs it), `name`. Output `Data/QuestDeps_<flavor>.lua` is gitignored, loaded by each TOC after
its RouteOrder file, shipped per client by `tools/install.sh`, and parsed on first use (about 12 ms on retail, once).
When the file is missing, or a guide comes from a family the index is not built from (hand-written, live), that guide's own
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
the Way (5092). A quest-line guide's own `|PRE|` edges have no breadcrumb information.

**Lock rule.** First the dropped quest's dependents are found (index edges, transitively). Then the ones that can still
be had are grown from what lies outside them (least fixpoint): `p1;p2` opens with any one, `p1&p2` needs all. Growing
instead of cutting matters for prerequisite cycles with an any-one list: on retail, dropping 82863 now locks the 19
quests that hang on it, where cutting outward from the dropped quest locked 1 (12 sit behind a cycle). A quest the
character has done or has on the log is past its prerequisites and never locked; a dropped quest that was already turned
in blocks nothing; a quest the data never made obtainable (`never`) is not this drop's doing. Locks are recomputed from
the remaining roots on every drop and unskip, so unskipping one quest frees exactly what only it blocked, and once per
session when the prerequisite data is not the data they were worked out from (`questSkip.deps`, length and hash of the
four `QuestDeps` strings; checked at the first guide load, `Skip.CheckData`), so a data update that chains quests
differently is followed. Checked against
a whole-index reachability reference (reachable before minus reachable after) on about 60 roots per client: exact on all
five. Stored per character in `A.me.questSkip` (`roots`, `locks`, `plans`), never shared: like a step skip it is one
character's choice, whatever the progress scope. Quests for another class, race or faction are locked like any other but
not named or counted in the warning (tbc, Blood Elf mage, Reclaiming Sunstrider Isle: 16 named instead of 21).

**What one guide loses.** A guide only offers a quest once one of that quest's accept steps (that this character can see)
opens. When every one of them waits, through the guide's own `|PRE|`, on a removed quest the index does not link
(quest lines order quests the wiki does not chain), the quest is out of that guide,
with every step and with what needs it there. This is per guide, not a shared lock, because another guide may still
offer the quest. The loaded guide's losses are part of the warning ("N of them only here"); other guides work theirs out
when opened, and `/cr unskip` on such a quest says why it is out. Measured by dropping every PRE predecessor of an accept,
one at a time, on sample wiki and storyline guides (`tools/test_skip.lua`): no quest is left on screen whose
accepts all wait on a removed quest, and none keeps its objectives or turn-in without its accept (era 89 drops on 13
guides, tbc 105 on 13, mop 108 on 14, retail 132 on 18, forever 47 on 7). The cost is real: dropping one quest of a
Blizzard storyline guide takes the rest of that storyline out of that guide (story:retail:546, 689 steps, loses 357 to one
quest no other quest needs; the warning lists 116 quests "only here").

**Rebuild.** The guide on screen is a projection of the guide's own steps (`P.baseSteps`, baked order). Out go: every
step whose quests are all removed or lost by this guide (a step serving any remaining quest this character can take
stays), steps shown only while on a removed quest (`|ACTIVE|`), quest-less steps waiting for removed prerequisites, run /
fly / boat / portal / hearth / dungeon steps whose stretch up to the next kept travel step only served removed quests,
and then the unlocated note / use / kill / loot steps riding with any removed step, travel steps included (the
optimizer's block rule). Flight-path and hearth-bind steps always stay. Ticks stay keyed by stable step key
([STEP_KEYS.md](STEP_KEYS.md)), so nothing is lost; step numbers, "step x of y", done counts, the guide list percentage and the "guide complete" check all follow the
rebuilt list. The current step is re-chosen at once (the arrow re-targets). Other guides are rebuilt when opened. Unskip
gives back the identical list.

**Re-plan.** After a drop or unskip, and the first time another guide with removed steps is opened, the remaining guide
is re-planned for travel time. Model = the offline bake's: only steps still to do that this character can ever see
(steps for another class, race, faction or profession keep their places and bind nothing), anchors fixed and cutting
segments, blocks of one step with an `|M|` point plus the steps after it without one, A < C < T per quest, PRE turn-in
before the dependent, quest log at most max(cap, the baseline's own peak) (removed quests free space), level gates as in
the bake. Every step the arrow can point at is priced: its `|M|` point, or without one the live quest objective or the
cost model's point (an NPC's point from elsewhere in the guide, the step it rides with, a new zone's centre), as
`Router.StepWorld` and the live window see it; a leg runs from one block's last priced step to the next block's first.

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
* **The leg from the player** is priced as the arrow prices it (`Router.TravelSecondsFromPlayer`: hearthstone and the
  other one-shot legs included), for the starting and the new order alike, and again for both in each pass; every other
  leg is the hearth-free row. Before 2026-11-12 the first leg was hearth-free too, so a baked order whose first step is
  one hearth away looked 800 s dearer than it is and a re-plan 577 s slower was accepted and saved (forever 1423
  Alliance, drop 5246).
* **The search prices that leg too** (2026-11-12). Until then the search ran on hearth-free costs only, so an order
  better only because it opens with the hearthstone was never looked for (acceptance priced it, the search did not).
  Now the segment that starts at the player prices its first leg with `playerCost`, the acceptance price: the greedy
  start may open with the hearth, and Or-opt may move a run to the front of that segment. Only where a one-shot leg can
  win at all: `Replan.OneShotLandings` lists where the hearth and the usable teleports land, by `TravelGraph.FindPath`'s
  own rule (the routing options; the hearth's place known; at most 15 minutes of cooldown left), one multi-goal search
  per landing place prices the blocks from there, and a block whose hearth-free leg is no dearer than (hearth base cost
  less its 10 s cast) + (time from the landing) keeps the hearth-free row, which is then exactly `playerCost`.
  No usable one-shot: the search is the one of before. Acceptance is unchanged. `tools/test_skip.lua` 1c: east of
  Elwynn then Goldshire, player in Redridge, Hearthstone ready: the search now finds "Goldshire first" (485 s -> 299 s by
  the arrow) and it is accepted; priced hearth-free (`oneShot = false`) nothing better is found; with the Hearthstone on
  a 60 minute cooldown the order stays. Cost on the 15 real samples of test_skip (stubs, `luajit -joff`, hearth in
  Goldshire): the same 15 results, frames 106/374/2396/4624/363 -> 125/413/2456/5058/340 (era/tbc/mop/retail/forever;
  130/439/2840/5942/391 in a run under more load), every frame within the 0.8 ms budget as before.
* **Acceptance.** The new order must save max(`StepOrder.MIN_GAIN`, `StepOrder.GAIN_FRAC` of it), the live window's
  margin, on the route the arrow walks, AND the route through the steps with a firm point (their own `|M|` or an NPC's)
  may not get longer: a zone centre only stands in for an objective, and a saving must not come from the stand-in alone. When the
  first search fails either test, a second search on the `|M|` steps alone gets its chance. So a kept re-plan never costs
  more than "baked order minus removed steps" by either measure; the test checks both with the live router, pair by
  pair. The decision is saved under the rebuild key (a checksum of the guide's step keys and author indices in list
  order, plus the quests out of the guide), so a reload shows the same order without re-planning, and a regenerated
  guide never gets an order planned for its previous version. A key in the older format (step count, route checksum,
  quests) is converted once when it still matches ([STEP_KEYS.md](STEP_KEYS.md)). The live window keeps working on top.

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
| `tools/cost_matrix.lua` (the bake) | the cost model's `OFFLINE_TAXI` = `faction` (since 2026-11-10 through `tools/cm_offline.lua`; `--taxi band` for experiments) |
| `tools/vplayer.lua` | `--taxi model` (default since 2026-11-10) = the bake's rule; `all` = `faction`; `band`; `learn` = `known`, starting each guide with nothing known |
| `tools/route_sweep.lua` | `faction`, pinned |
| `tools/test_*.lua` | `assumeAllTaxi` or `faction`, except the taxi tests in `test_offline.lua` |

`vplayer --taxi learn` discovers the flight master the route took off from (it walked there) and any flight master
within 40 yd of each step the player stands on (an `f` step's included). The bake's gain under `learn` was measured on
2026-11-10 ("One cost model", flight paths).

## What changes the graph (2026-11-10, branch routing-graph)

A quest turn-in used to set `TG.built = false`: the next search rebuilt every taxi, transit and road node, replaced the
path cache, and StepOrder then dropped every kept pair cost. Now each event drops only what it changes:

| Event | What is rebuilt or dropped |
|---|---|
| Turn-in of an access chain's `unlock` quest (or a quest an Access `cond` reads) | the access edges only (`TG.RebuildAccess`); path cache, so StepOrder's kept costs |
| Turn-in of a quest a Transit `cond` reads | the whole graph (lazily, `TG.Ensure`) |
| A spell learned, item looted, level gained that flips a Transit/Access `cond` | the whole graph (`TG.RecheckConds`) |
| A flight path learned | path cache (`TG.TaxiChanged`); StepOrder's kept costs |
| Hearth re-bound (moved > 30 yd), a teleport or hearth item becomes usable or unusable | only the costs from the player (`TG.oneShotGen`, `TG.OneShotChanged`) |
| Turn-in of a quest a teleport `cond` reads (the Garrison Hearthstone's) | what is usable is worked out again at once (`T.Recheck`; no bag, toy or spell event follows a turn-in); the costs from the player only when that changed what is offered |
| An Options switch or slider: flights, comfort mode, the flight rule, transit, roads, terrain factor | path cache, so StepOrder's kept costs |
| An Options switch or slider: hearth, teleports, hearth base cost | only the costs from the player |
| Any other turn-in | nothing |

The unlock set is collected at build time (`TG.unlockQuests`). Quests turned in this session (`TG.turnedIn`) count as
completed at once, because `IsQuestFlaggedCompleted` can lag the `QUEST_TURNED_IN` event. Tests: `tools/test_access.lua`
(an ordinary turn-in keeps the graph and the path cache; the K'aresh unlock rebuilds only the access edges and matches
a full rebuild), `tools/test_live_route.lua` (kept costs survive a turn-in; a one-shot change re-prices only the
from-player costs; every cost-changing Options control drops what it makes stale - comfort mode and the terrain slider
used to leave the path cache alone, and the hearth base cost slider left the kept from-player costs).

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
  and TBC (ItemSparse InventoryType 12), bag items on Forever and MoP Classic, toys on MoP Classic and retail. They carry
  `profession = 202` (Engineering, from ItemSparse `RequiredSkill`; on retail that is a tier line whose SkillLine parent
  is 202). A character the client says has no Engineering is skipped (`Core/Professions.lua` `Prof.Knows`); when the
  skill list cannot tell (no API, a collapsed header) the client's `IsUsableItem` / `C_ToyBox.IsToyUsable` decides, and
  that answer also covers the Gnomish / Goblin specialisation;
* the Dalaran and Garrison hearthstones (the garrison one needs "Establish Your Garrison");
* 36 Hearthstone stand-ins (toys and items that share the Hearthstone's destination and cooldown). One is used only
  when no Hearthstone is in the bags (`U.HearthReady`); its cast also counts for H steps and the bind recorder.

Rule (the hearth's): an edge from the player when the spell is known (and its reagent, Rune of Teleportation on Era,
Forever and TBC, is in the bags) or the item or toy is owned and usable (`C_ToyBox.IsToyUsable`, `IsUsableItem`), its
`cond` holds, and its cooldown has at most 15 minutes left. Cost = `hearthCost - 10 + cast + cooldown left`. Never on a
pairwise (`hearth = false`) query, so step-order costs and the bake are unchanged. What is usable is recomputed on
`SPELLS_CHANGED`, `BAG_UPDATE_DELAYED`, `PLAYER_EQUIPMENT_CHANGED`, `NEW_TOY_ADDED`, `TOYS_UPDATED`, cooldown events and
level-up, profession changes (1 s throttle) and at once on the turn-in of a quest a `cond` reads; a change bumps
`TG.oneShotGen`. Option: "suggest class teleports, transporters and hub hearthstones". `/cr teleports` lists every
candidate and why it is or is not offered (including "needs Engineering").

Landing points are world coordinates `{ instance, x, y }`, so one entry serves every client: a wiki `{{Co|x|y|map}}` on
the modern map (`cite`, converted with `tools/maps_retail.lua`) or a TaxiNodes position. Darnassus and Undercity land
elsewhere on retail (the Battle for Azeroth phase Zidormi controls), so they have a retail entry each. The Orgrimmar
spot is the modern city's; on Classic Era and TBC it is approximate. After a teleport cast the first jump that lands
within 500 yd of the data point is stored (`CompletionRouteDB.teleportFix`) and used from then on.

Checks: `tools/test_teleports.lua` (every landing point recomputed from its citation; Era mage with and without rune,
cooldown, Options, arrow, learned landing; worn trinket; Engineering needed; retail hearth toy, Garrison Hearthstone
quest, including the `QUEST_TURNED_IN` event alone making it usable), and `tools/check_teleports.py --fetch --wiki`
(names in SpellName / ItemSparse per client, reagents in SpellReagents, use spells and cooldowns in ItemEffect, trinket
slot, `profession` against ItemSparse `RequiredSkill` both ways, shared Hearthstone cooldown in SpellCategories, and
every cited wiki page holding the id and coordinate). Last run (2026-11-10, after the fixes): 134 entry-client checks
and 73 wiki checks, 0 failures; with one `profession` removed and one added where DB2 has none, 6 failures, exit 1.

Not done: Zen Pilgrimage (the wiki gives no landing point, and the Peak of Serenity cannot be left on foot), retail
Death Gate (which Acherus depends on Legion progress), Dreamwalk and class-hall teleports (the landing is a hub whose
exits are not in the graph), Midnight's Teleport: Silvermoon City (no landing point on the wiki), Kirin Tor rings,
Ruby Slippers (must be worn), random-destination wormholes, Ultrasafe Transporter: Mechagon (item 167075, use spell
291981, a single fixed teleport in SpellEffect; not a toy and no `RequiredSkill` in retail DB2; a stack-of-100 consumable
made with Junkyard Tinkering; the wiki says only "Rustbolt" and gives no coordinate, and the Rustbolt page has none
either, so the landing point would need DB2 SpellTargetPosition, which the harness does not read yet).

Nothing here has run in a client: the secure `toy` button type, `C_ToyBox.IsToyUsable`, the cooldown readings for
toys, the Engineering check on each client's skill API and the landing spots all need Daniel's beta.


## One cost model (2026-11-10, branch cost-model)

`Routing/CostModel.lua` (loaded by all six TOCs before the travel graph, the live window and the re-planner, and by the
offline tools through `tools/cm_offline.lua`) holds every rule that decides what a leg costs. Before it, the bake, the
live window and vplayer each had their own: a zone-only step cost nothing in the bake but sent the live window and
vplayer to the zone centre, a leg with no route cost 1,800 s, 600 s and 0 s, and the bake priced a whole guide at its
lowest level's speed.

| Rule | What it says | Who reads it |
|---|---|---|
| Located (`CM.Locate`, once per guide in author order) | A step is priced at its own `|M|` point (`own`); with none, at the point of the NPC its note names ("From X." / "To X.") when another step of the guide has that NPC's point (`npc`); with neither, it is done where the player already is when it has no zone or the zone of the last priced point before it (`ride`: no leg, it joins the block before it); otherwise at the centre of the new zone (`zone`). | cost_matrix, optimize_routes (through the rows), StepOrder `located`, Replan blocks, Router.StepWorld (after the live quest objective), vplayer |
| No route | `CM.NOROUTE` = 1,800 s for a leg the router cannot path. | optimize_routes (row `cm`), StepOrder, Replan, vplayer |
| Hearth step | an `H` step costs `CM.HEARTH` = 60 s offline instead of the trip; no other leg uses the hearth or a teleport offline. | optimize_routes, vplayer (the quest guides the bake orders have no H step) |
| Speed | ground speed by level band (7, 11.2 from 40, 14 from 60 yd/s on Classic clients; 14 from 10 on retail), retail flies from 10 at 45 yd/s; offline a leg is priced at the planning level of the step it leaves from (the guide's start level raised by every `|LVL|` up to that step). | U.TravelSpeed in game, cost_matrix and vplayer offline |
| Walking factor | 1.25 off road (the Options slider in game), 1.05 when flying, the same for a short walk below 700 yd as for the graph's walks (a short walk used the ground factor even when flying). | TravelGraph, Router.TravelSeconds and TravelRow |
| Offline flight paths | `CM.OFFLINE_TAXI` = `faction` (see below). | cost_matrix, vplayer `--taxi model` |
| Planning character | one baked order serves everyone who plays the guide, so it is planned for one character (`CM.Persona`): the guide's faction (in a guide for both factions: the faction at least half of its located steps are tagged for, else none), then the class, race and profession at least half of the located steps it takes so far name (else none). The bake walks to the steps that character takes (`CM.Takes`) and that do not tick by themselves (`CM.PlanSteps`: a second accept or turn-in, an objective already done). The rest ride along. | cost_matrix; vplayer `--who plan` plays exactly this character, `--who gate` a real character of its faction, class and race |
| Gate limits | `CM.GATE_FRAC` = 1%, `CM.GATE_ABS` = 30 s (see "Bake gate"). | optimize_routes (row `cm`), test_route_order |

The Python optimizer holds no copy of these: every cost_matrix row carries `"cm"` (version, no-route and hearth cost,
flight rule, gate limits) and `optimize_routes.py` refuses a row without it. `CM.VERSION` is stamped into every row; bump it
when a rule changes and `tools/bake_resume.py` treats every row as stale. It is 2 since the planning character change
below. The client files read the constants straight from `NS.CostModel` (no fallback copies: StepOrder, Replan and Router
assert that it loaded first, and `tools/validate_toc.lua` checks the order in all six TOCs).

**Planning character per guide (2026-11-11 fix).** The first version planned every guide for a character with no class,
race or profession and, in a guide for both factions, no faction tag. A guide whose steps all carry such a condition then
had nothing to bake: a race's starting zone (The Lost Isles, every step `R|Goblin`), a class campaign, a guide for both
factions whose steps are all Alliance-tagged. `CM.Persona` now plans each guide for the character most of its located
steps are written for. Over every quest guide (located steps the planning character walks to, faction-only rule -> per
guide; "no bake" = at least 2 located steps but fewer than 2 walked to; "v1 entry" = the guide has an entry in today's
stale RouteOrder file, so it would have lost its bake in the rebake):

| | era | tbc | mop | retail | forever |
|---|---:|---:|---:|---:|---:|
| Quest guides (for both factions) | 234 (80) | 354 (122) | 772 (316) | 1,021 (683) | 240 (82) |
| Guides with a planning character other than the faction-only one | 4 | 7 | 18 | 140 | 4 |
| Located steps walked to (of all located) | 9,112 -> 9,131 (10,725) | 14,591 -> 14,694 (16,664) | 36,852 -> 38,056 (40,695) | 60,961 -> 67,131 (74,856) | 9,337 -> 9,348 (11,057) |
| No bake (with a v1 entry) | 1 (0) -> 0 | 0 -> 0 | 7 (5) -> 2 (1) | 78 (70) -> 10 (9) | 3 (0) -> 0 |

Retail's 140: faction 83, class 35, race 12, faction and class 8, class and race 2. The 12 guides still without a bake
are split between classes with no class covering half of the located steps (`wiki:mop:327:Both`, `qdb:mop:10024:Both`,
`wiki:retail:327:Both` and 9 retail `qpoi:` class-trainer guides): one order cannot serve them, and they play in author
order with the live window. A guide for both factions with a tagged minority (for example 72 Alliance, 14 Horde and 68
untagged located steps) keeps the untagged steps; the gate then checks the bake for both factions. `cost_matrix --list`
reports `nl`, `np` and `who` per guide; `tools/test_cost_parity.lua` checks the rule on synthetic guides and on five real
guides that need it, and lists the guides left without a bake.

**Why this located rule.** `tools/cost_holdout.lua` takes quest steps whose point is known (3,000 per client, every third
quest guide), hides the point, and predicts the detour prev -> step -> next with each candidate rule. Mean absolute error
and bias, seconds per step:

| Rule | era | tbc | mop | retail | forever |
|---|---|---|---|---|---|
| ride along with the step before | 108 / -108 | 64 / -64 | 27 / -27 | 81 / -81 | 110 / -110 |
| zone centre (the live window's old rule) | 192 / +165 | 173 / +148 | 170 / +162 | 117 / +109 | 194 / +165 |
| NPC's point, else ride | 93 / -87 | 50 / -50 | 27 / -22 | 96 / -37 | 89 / -84 |
| NPC's point, else zone centre | 68 / +45 | 63 / +44 | 71 / +64 | 88 / +70 | 65 / +43 |
| **NPC's point, else ride in the same zone, else zone centre (chosen)** | **40 / -13** | **30 / -12** | **22 / 0** | **50 / +23** | **38 / -12** |

Over the quest guides' steps: era 3,136 own, 0 npc, 265 ride, 47 zone, 110 none; tbc 3,095 / 0 / 209 / 36 / 0; mop 3,110 /
23 / 132 / 39 / 0; retail 3,132 / 88 / 716 / 235 / 0; forever 3,179 / 4 / 548 / 52 / 118 (every third guide). The hold-out
samples are steps whose point is known; a true zone-only step may sit elsewhere, so this ranks the rules but does not
prove the error on zone-only steps.

**vplayer's world.** vplayer now walks the cost model's way (from the last priced step's point at that step's planning
level, no hearth, 1,800 s for a leg with no route) and finishes one objective per `|QO|` step: a quest is complete when
every numbered objective the guide names is done (any objective step used to finish the whole quest, so a second
objective somewhere else was never walked to). `--who plan` plays the planning character.

**Parity** (`tools/test_cost_parity.lua`). For sample quest guides of every client: cost_matrix, then the optimizer's
predicted seconds of the author order and of its baked order, then vplayer playing both orders with `--who plan --live
off`. Required: within 2% (and 1 s) per guide. With the full solver on 20 guides per client (evenly spread over the quest
guide ids): era 20/20, tbc 20/20, retail 20/20, forever 20/20 and mop 19/20 inside 2%, most of them to the second. The
mop miss (`wiki:mop:25:Both:1`, -7.5%) was a prerequisite turned in only by faction-tagged steps: vplayer's planning
character never took them, so it never saw the quest that needed them; it now counts such a prerequisite as earlier
content, as the bake does, and the re-run gives 20/20. The harness itself runs 6 guides per client (30, evenly spread
over the quest guides with at least 10 steps) with short solver limits. One kind of guide cannot pass by construction: an
author order that breaks its own rules (an accept listed before the in-guide turn-in of its prerequisite, the optimizer's
`dropped_edges`; only Questie-derived `qdb:` gaps guides have them). The client cannot play such an order as written: it
shows the hidden step later, or, when the quest is turned in first, never. A miss on such a guide is listed with that
reason and does not fail the test; any other miss fails it. First run: 28 of 30 inside 2%, most to the second; the two
misses are both of that kind and both in the author order only (`qdb:era:357:Horde` -3.9%, forever `qdb:era:15:Alliance`
-26.6%); 4 more guides of that kind agreed anyway. Since 2026-11-11 the harness samples only guides with at least 2 steps
the planning character walks to (a guide priced at 0 s "agreed" at 0 = 0 before: 4 of 60 in a 20-per-client run) and
fails on a sampled guide predicted at 0 s; last run (cost model v2): 30 of 30 inside 2%, none excused.

**Predicted against measured** (20 guides per client, evenly spread over the quest guide ids; vplayer's default warrior;
seconds summed over the sample; "before" = branch base 472f8a4 with its own bake and vplayer, "after" = this branch):

| | era | tbc | mop | retail | forever |
|---|---:|---:|---:|---:|---:|
| Before: saving the model predicts | 43,687 | 39,479 | 14,050 | 13,407 | 58,755 |
| Before: vplayer, live window off | 25,935 | 24,374 | 5,924 | 1,635 | 31,097 |
| Before: vplayer, live window on | -1,234 | 2,581 | 1,584 | 307 | 94 |
| After: saving the model predicts | 33,818 | 35,645 | 12,497 | 17,244 | 45,446 |
| After: vplayer, live window off | 21,459 | 27,194 | 10,965 | 10,421 | 30,228 |
| After: vplayer, live window on | 2,943 | 4,873 | 3,937 | 9,067 | 9,073 |
| After: vplayer `--who plan`, live window off | = predicted within 2% per guide | | | | |
| After review fixes (2026-11-11, cost model v2): saving the model predicts | 33,818 | 35,620 | 13,038 | 17,573 | 45,446 |
| After review fixes: vplayer, live window off | 21,459 | 27,169 | 10,965 | 10,421 | 30,228 |
| After review fixes: vplayer, live window on | 2,943 | 4,261 | 3,937 | 9,067 | 9,073 |
| After review fixes: `--who plan`, live window off, inside 2% | 20/20 | 20/20 | 20/20 | 20/20 | 20/20 |

Measured over predicted (live window off) went from 0.59 / 0.62 / 0.42 / 0.12 / 0.53 to 0.63 / 0.76 / 0.88 / 0.60 / 0.67
(0.63 / 0.76 / 0.84 / 0.59 / 0.67 with the planning character per guide; the sample has 0 / 1 / 1 / 4 / 0 guides it
changes, so era and forever are unchanged to the second).
The author order alone: retail predicted 72,563 s against 20,168 s measured before (vplayer hearthed home and walked to
zone centres), 57,451 s against 50,867 s after. The gap that remains with the warrior is not the cost model: it levels by
experience, so `|LVL|` steps open later than the bake assumes and the order it plays differs; it takes its own class and
faction steps; and quests whose prerequisites lie in other guides stay hidden from a fresh character. The planning
character removes those and agrees.

**Flight paths offline: faction-wide stays.** `--taxi band` (cost_matrix, vplayer) allows only flight masters in zones
whose lowest wiki-guide level is at or below the leg's planning level (5-level bins; capitals and starting areas sit in
level-1 zones). The same 20 guides per client baked both ways (faction / band baked orders, guides whose orders differ),
then played by the warrior with the live window under the client's rule (`--taxi learn`, every guide starting with no
flight path) and under `--taxi all`:

| | era | tbc | mop | retail | forever |
|---|---:|---:|---:|---:|---:|
| Baked orders faction / band / differing | 13 / 13 / 4 | 13 / 13 / 5 | 10 / 9 / 8 | 13 / 13 / 2 | 15 / 15 / 8 |
| `learn`: author order | 86,127 | 108,568 | 49,526 | 44,785 | 156,337 |
| `learn`: faction bake | 83,718 | 98,849 | 45,019 | 35,520 | 150,217 |
| `learn`: band bake | 84,600 | 100,602 | 44,428 | 35,520 | 149,660 |
| `all`: author / faction / band | 67,140 / 64,197 / 64,989 | 77,564 / 72,691 / 74,607 | 41,941 / 38,004 / 37,944 | 41,635 / 32,568 / 32,609 | 117,416 / 108,343 / 107,821 |

Both bakes save time under `learn` on every client. Band is 1.3% better on mop and 0.4% on forever, worse on era (1.1%)
and tbc (1.8%), equal on retail; over all five the faction bake is 1,487 s (0.4%) faster under `learn`. Band also makes
the costs depend on wiki level data and needs a graph snapshot per level bin, so the bake keeps `faction`. The client
always uses the character's discovered flight paths, and the live window re-prices on top of the bake.

**CPU** (`luajit -joff`, the same windows on both trees). The live window, one `Router.OrderSteps` call on 340 era and 364
retail windows of the sample guides, unbudgeted: era cold (no kept costs) mean 61.7 -> 39.1 ms, warm mean 1.64 -> 1.25 ms
(p95 3.37 -> 3.17); retail cold 320 -> 190 ms, warm 1.64 -> 1.18 ms (p95 2.89 -> 2.58). Steps that ride along make fewer
blocks, and a search fixes its walking factor once. In game each call still stops at 3 ms (a 2026-11-11 re-run of the
budgeted client loop after the review fixes, mean per call / total to converge: era 3.92 / 44 ms against 4.15 / 66 ms on
the base, retail 8.49 / 138 ms against 11.1 / 243 ms).

The re-planner (`tools/test_skip.lua` under `luajit -joff`; corrected 2026-11-11, the first version of this paragraph
compared against one base run whose 1.43 ms maximum was a mop outlier). Three runs per tree, then two more on the final
code: per-frame p50 0.80-0.81 ms and p99 0.82-0.89 ms on both trees; collector paused max 0.99-1.06 ms base, 0.96-1.21 ms
branch; collector running max 0.96-0.98 ms base, 1.42-1.47 ms branch, always on retail. No frame is over 2 ms. Total work
went up on retail: its re-plans take 4,548-4,663 frames against 3,354-3,496, and `wiki:retail:111:Both:1` 2,740-2,803 ms of
CPU against 1,912-1,949 ms (+41%). Why, from a probe that prints both search passes of every re-plan in the test (22
re-plans per tree): (1) the test guides now play in author order, because checksum version 2 makes their baked entries
stale, so the re-planner starts from a worse order and accepts 20 re-plans instead of 10; (2) the cost model makes NPC-point
and new-zone steps start blocks, so 111:Both:1 has 109 blocks instead of 77; (3) on 2 of the 3 retail re-plans the first
search (all priced steps) saves a lot but lengthens the legs between firm points (111:Both:1: 16,293 -> 10,889 s, firm legs
10,354 -> 10,541 s), so the firm-only second search runs, as designed (10 of 22 re-plans ran it on the base, 5 on the
branch). Summed over the 22 re-plans: 6,979 ms base, 8,650 ms branch (+24%), all of it retail (+1,830 ms; era, tbc, mop and
forever together -120 ms). The worst frame with the collector running is most likely a collector step inside a slice (the
branch allocates more on retail; the reviewer's instrumented copy moved that frame away, not re-checked here). Accepted as is: the slices keep their 0.8 ms budget, a
re-plan runs once per skip in the background, and the extra work comes from more blocks and the stand-in guard.

**Not covered.** The speed bands are the client's old guess and are the same on every Classic client (MoP Classic and
TBC Anniversary riding levels differ); Classic characters never fly offline. Multi-point steps are still priced at the
first point. Nothing here has run in a client.

## Bake gate and stale-bake check (2026-11-10, branch cost-model)

**Checksum version 2.** `G.RouteChecksum` folds, per step, the action, first quest id, zone id and first map point in
0.5 % steps (`G.RouteChecksumParts`), so a guide whose points moved or whose step changed zone no longer matches an old
bake (the 2026-11-09 map fix had left old orders in force). One definition, three copies: Core/Guide.lua computes it,
`tools/cost_matrix.lua` calls Core/Guide.lua's and writes each step's parts into its rows, and `tools/optimize_routes.py`
folds those integer parts (no float maths in Python). `tools/test_route_order.lua` checks that all three agree on every
quest guide (era 234, tbc 354, mop 772, retail 1,021, forever 240), that a re-parse gives the same value, a pinned value
for a test guide, and that a moved point (0.6 % or more) or a zone change changes it while a title or an in-step move does
not. Bug reports record the checksum's version (`sumv`); `vplayer --repro` compares only reports of the same version.

**Stale entries.** Version 2 invalidates every existing entry (era 168, tbc 258 + 2 for deleted guides, mop 501, retail 854,
forever 169 + 1). The game already handles that: `G.BakedOrder` applies an entry only when the step count and checksum
match, so a stale guide plays in author order with the live window on top. `tools/test_route_order.lua` now checks that
for every stale guide and then FAILS, naming the flavor, the count, the first ids and the re-bake command; an entry for a
guide that no longer exists fails too. `CR_ROUTE_ORDER_DIR=<folder>` points it at a fresh bake before it is installed.

**Gate.** `optimize_routes.py --gate` plays author order + live window and baked order + live window in vplayer for
every guide the model would bake, and keeps the bake only when it is not slower by more than max(`CM.GATE_FRAC`,
`CM.GATE_ABS`) = max(1%, 30 s); the limits come from the rows' `"cm"`, never from a copy. The character is a real one
(`vplayer --who gate`, the real condition rules) of the guide's planning character's faction, class and race, a Human or
Orc warrior where it has none, with the bake's flight rule. A guide for both factions is played twice, as Alliance and
as Horde (`--both-as`), and must pass both: Horde players get the same order. A guide vplayer cannot finish in both
orders is rejected. A kept entry stores the measurements: `O[id] = { n, sum, o, va = <author + live s>, vb = <baked +
live s> }`, plus `vah`, `vbh` for the Horde play of a guide for both factions (`va`, `vb` are then Alliance's).
`G.BakedOrder` reads only `n`, `sum` and `o`, so the extra fields are ignored on every client (tested), and
`tools/package_release.py` reads only the id. A rejected guide gets no entry. `--gate-only [--regate] [--gate-ids F]` gates
rows already solved. `--current F` (a `cost_matrix --list`) writes entries only for guides that still match.

`tools/bake_resume.py` runs the gate in every batch (`--no-gate` skips it). The optimizer saves a batch's solved rows
before the gate starts (fixed 2026-11-11: they were written only after it, so a run killed during the gate solved the
batch again), and a vplayer failure leaves them saved without a verdict and exits 3. A row solved but not gated (a
`--no-gate` run, a run killed during the gate, a vplayer failure) is gated on the next start without being solved again
(`tools/test_bake_gate.py`; also checked end to end by killing a 4-guide era run while the gate's vplayer was playing:
the restart gated the 4 rows without solving them). Rows solved under another cost-model version are stale. The final
write keeps only entries for guides that match the current list. `--lua-dir` writes the RouteOrder files elsewhere,
`--only-file FLAVOR=ids` limits a run to some guides.

**Several batches at once (2026-11-12).** `--jobs N` (default 1) runs N batches in parallel; each batch is one
single-threaded cost-matrix, solve and gate chain of about 100 to 300 MB with its own scratch files. The optimizer puts
its rows into the shared `<flavor>.jsonl` under a lock (`<flavor>.jsonl.lock`) after reading the file again, so a batch
never writes back an older copy of rows another batch saved meanwhile (`save_rows(own=)`). Its progress file is
`<flavor>.jsonl.solving.<pid>`, removed however the solve ends; one left by a `kill -9` is removed on the next start.
Measured: 12 small Era guides took 14 s with `--jobs 3` and 42 s with one job, rows identical apart from `solve_s`,
RouteOrder byte-identical; an independent check killed a 4-job run with `kill -9` mid-way and the resumed run matched a
one-job run row for row. The live Retail bake went from about 20 minutes per 20-guide batch to about 1 minute per batch
on this 8-core Mac with `--jobs 4`. The solver's limits are wall-clock, so with more jobs than fast cores a solve does
less in its time; the gate still decides what is kept.

**The generator writes the same bytes on every run (2026-11-12).** `tools/wiki/gen_spine.py` broke rank ties by object
address and walked a set of guide ids, so every regeneration moved a few sibling quests on MoP and Retail and made
those guides' baked orders stale. Ties now break by the quest's place in the guide. Eight hash seeds gave byte-identical
guide, spine and sidecar files on all five clients; `tools/test_gen_determinism.py` checks two.

**Saved quest-skip re-plans reset once.** `Core/Skip.lua` saves a re-plan under `S.PlanKey`, which includes
`G.RouteChecksum` of the guide's list in its current (baked or author) order. Checksum version 2 changes that value for
every guide (all 234 era guides checked), and so does any rebake that changes a guide's order. After this update, a guide
with skipped quests shows its rebuilt list without the saved re-plan, and `Core/Progress.lua` re-plans it once in the
background the next time it is opened (the decision is saved again). Nothing is lost but that one re-plan; keeping the
old key would not help, because the rebake changes the baked order the saved re-plan was made from.

Measured on the same 20 sample guides per client (this branch's bake, the gate's own vplayer runs):

| | era | tbc | mop | retail | forever |
|---|---:|---:|---:|---:|---:|
| Baked orders checked | 13 | 13 | 10 | 13 | 15 |
| Kept / rejected | 8 / 5 | 11 / 2 | 10 / 0 | 12 / 1 | 14 / 1 |
| Kept: vplayer saves (s) | 4,467 | 5,846 | 3,937 | 9,200 | 9,251 |
| Rejected: would have cost (s) | 1,524 | 973 | 0 | 133 | 178 |

The same gate on the base branch's bake and vplayer (old cost model) would have rejected 5 of 13, 3 of 14, 2 of 11, 3 of
16 and 2 of 16.

After the review fixes (2026-11-11: planning character per guide, the gate plays that character and both factions of a
guide for both), the same 20 guides per client, full solver:

| | era | tbc | mop | retail | forever |
|---|---:|---:|---:|---:|---:|
| Baked orders checked (of them for both factions, played twice) | 13 (7) | 13 (6) | 11 (5) | 14 (10) | 15 (5) |
| Kept / rejected | 7 / 6 | 11 / 2 | 11 / 0 | 13 / 1 | 13 / 2 |
| Kept: vplayer saves (s, both plays summed) | 3,045 | 10,249 | 7,441 | 12,744 | 12,060 |
| Rejected: net effect if kept (s, + = slower) | -620 | +120 | 0 | +133 | -570 |
| Gate time for the 20 (s) | 17 | 16 | 23 | 32 | 17 |

Rejected only because of the Horde play: `wiki:era:1452:Both` (Alliance -2,336 s, Horde +302 s) and `wiki:forever:1452:Both`
(-1,259 / +332). Rejected only because of the Alliance play: `wiki:era:1448:Both` (+281 / -159) and `wiki:tbc:1449:Both`
(+1,547 / -1,465). The rule is "no player slower than author order + live window by more than the allowance", so a bake
that saves one faction a lot and costs the other more than 1% is dropped; that is why the net effect of the rejected bakes
is negative on era and forever.

A second sample, the guides the planning character changes (all of them on era 4, tbc 5, forever 4; 17 on mop; 20 of 134
on retail, evenly spread): 50 guides, `--who plan` parity 50/50 inside 2%, 40 baked, 30 kept by the gate (vplayer saves
24,153 s), 10 rejected (mop 3, retail 7: mostly a guide for both factions planned for one faction whose other faction then
plays it slower, e.g. `wiki:retail:1355:Both:5`, Horde-planned, Alliance +3,438 s). Before the fix, 21 of these 50 had at
most one step to bake. The gate does not play a character without the planning character's class or race; on this sample
the default warrior was never slower with a kept bake than with author order (largest +2 s), and the four bakes that made
it slower by more than the allowance (+364 to +3,438 s) were all rejected by the gate's own plays.

The gate's vplayer runs: two per batch, four when the batch holds guides for both factions (the Horde runs play only
those). On these samples a 20-guide gate took 16 to 32 s (4 to 10 s before the Horde runs); the largest zone guides take
much longer, and a guide vplayer cannot finish within `--gate-cap` (600 s of CPU per guide) is rejected.
