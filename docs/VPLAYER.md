# The virtual player

`tools/vplayer.lua` plays every guide the way a character would, without a character, a server or a
subscription.

```
luajit tools/vplayer.lua <era|tbc|mop|retail|forever> [--limit N] [--shard i/n] [--type Leveling]
                         [--guide ID] [--faction Horde] [--guidecap 20] [--out PATH] [--verbose]
                         [--order author|baked] [--route-order PATH] [--live on|off] [--who warrior|plan]
                         [--taxi model|all|band|learn] [--turnins]
# --order baked loads Data/RouteOrder_<fl>.lua (tools/optimize_routes.py), or --route-order PATH; --live off disables
# the live window; --who plan plays the character the bake plans for; --taxi learn: fly only into discovered flight
# paths, starting each guide with none; --turnins: time QUEST_TURNED_IN; CR_TRACE=F writes one line per visited step
python3 tools/collect_vplayer.py       # -> docs/verification.sqlite
```

## Replaying a beta bug report

`luajit tools/vplayer.lua --repro <report id | latest | report.json> [--db PATH] [--check] [--show]` puts the
virtual character where a `/cr bug` report says (flavor, guide, step progress, quest log, position, level,
faction, flight paths, hearth, speed, options) and prints the route and the next steps next to what the client
recorded, ending in `RESULT MATCH` or `RESULT DIFF` (current step, open steps, route legs, route time, arrow mode).
`<flavor> --capture auto --capture-out r.json [--capture-done 6623]` makes a report in the fake world for the
round-trip self-test. See [BETA_REPORTS.md](BETA_REPORTS.md).

## How it differs from the route sweep

`route_sweep.lua` asks *"can the router reach step 1, and is the optimizer's order legal?"*.  It never
moves.  The virtual player asks the question that actually matters — **would a character finish this
guide?** — and answers it by running the real addon:

1. `Progress.Load(id)` — the real loader, including access-chain prefixes and gold-guide circuits.
2. For the current step: the travel time by the cost model ("Cost model" below; the real router, so a step
   with no route is counted), then the player is teleported onto the step's point.
3. The step's action is performed **against the world, not against the addon**: an `A` puts its quest
   in the log, a `C`/`K`/`l`/`U` finishes its `|QO|` objective (the whole quest when it names none), a `T` flags
   the quest complete, a `B` fills the bags, an `L` raises the level, `h`/`f` set the bind/taxi flags.
4. `Progress.Refresh()` runs — the same auto-completion the client runs on `QUEST_LOG_UPDATE`.
5. If the step ticked, that is an **auto** step.  If it did not, see below.

The world is a real mutable state table (`W`): quest log, completed quests, objectives, bags, level,
bind point.  `C_QuestLog`, `C_Item`, `UnitLevel` and friends read from it, so every code path in
`Progress.CheckStep` and `Cond.StepApplies` behaves exactly as it does in the client.

## auto / manual / stall — the distinction that matters

* **auto** — the step ticked by itself once the world satisfied it.  This is the addon working.
* **manual** — the step *can never* tick, because it does not carry the data the check needs: a note,
  a `C Kill Kresh` with neither `|QID|` nor `|L|`, an `R` with no coords and no zone.  In game these
  are the steps you press the forward arrow for; other guide addons behave the same way.  Not a bug — but the
  count is worth watching, because it is exactly "how much clicking does this guide still cost you".
* **stall** — the step carried everything it needed and *still* did not tick.  **That is a bug**, and
  it lands in `docs/vplayer_<flavor>_stalls.tsv` / the `vplayer_stalls` table with its action, title,
  quest id and zone.

Classifying by action letter alone was wrong and reported ~50 false bugs on the first retail run; the
classifier (`autoable()`) now asks what data the step actually has.

## Level gating

A guide's `|LVL|` steps are invisible to a character below that level, so parking the virtual player
at the guide's `minlevel` would silently skip them and the guide would look finished.  When the guide
runs out of steps, `levelGateBump()` raises the level to the lowest gate still holding a step back and
carries on, so gated content is played rather than skipped.

## Circuits

Gold guides fold into farm circuits, which by design never end.  The virtual player walks **two full
laps** and calls that a pass — enough to exercise `NewLap`, the lap wipe and `StartAtNearest` (the
re-entry bug that made a closing lap eat itself is pinned by `tools/test_farm.lua` #5).

## Per-guide time cap, and the recap pass

Each guide gets `--guidecap` seconds (default 90) before the run gives up on it and writes
`guide time cap` in the row's error column. That keeps one pathological guide from stalling a shard;
it does **not** mean the guide is broken. The handful that hit it are simply the largest zone guides
(Dalaran, Isle of Dorn), so finish the run and then replay just those with a bigger budget:

```
for g in $(sqlite3 docs/verification.sqlite "select guide from vplayer_guides where error='guide time cap'"); do
  luajit tools/vplayer.lua retail --guide "$g" --guidecap 900 --out /tmp/recap_$RANDOM.tsv
done
```

Progress is flushed every 25 guides, so a long shard is watchable in `tail -f`.

## Flight paths: `--taxi model|all|band|learn` (2026-11-10)

The client now flies only into flight paths the character has discovered (docs/ROUTING.md). vplayer's default
`--taxi model` is the bake's own rule (`CostModel.OFFLINE_TAXI`, faction-wide), so its numbers stay comparable with the
bake and with earlier runs (`all` is the same rule by name; `band` is the experimental level-band rule). `--taxi learn`
uses the client's rule: each guide (or a whole `--chain`) starts with no flight path known, on the character and on the
account. A flight master is discovered when the route the player took flew from it, which means the player walked
there, and when it is within 40 yd of the step the player is placed on (an `f` step's flight master, for example). The
`DONE` line reports how many were discovered. vplayer still models no teleports (its character is a warrior with no
toys) and no Hearthstone in the bags.

## Cost model and the planning character (2026-11-10, branch cost-model)

vplayer prices travel exactly as the bake does (`Routing/CostModel.lua`, docs/ROUTING.md "One cost model"), installed
through `tools/cm_offline.lua`:

* a leg runs from the point of the last step the cost model locates to the next one, at the speed of the planning level
  of the step it leaves from (the guide's start level raised by every `|LVL|` up to that step), never with the
  hearth (until 2026-11-10 it ran from wherever the player stood, at the warrior's level, and could hearth);
* a step that rides along (no point, same zone) costs nothing and does not move the player; a zone-only step in a new
  zone goes to the zone centre, an NPC step to the NPC's point from elsewhere in the guide;
* a leg with no route costs `CostModel.NOROUTE` (1,800 s; it used to cost 0); an `H` step costs `CostModel.HEARTH`;
* an objective step finishes only its own `|QO|` objective; the quest is complete once every numbered objective the
  guide names is done. A second objective somewhere else is now walked to, as in the client.

`--who plan` plays the character the bake plans for instead of the warrior: no class, race or profession steps, no other
faction's steps (none with a faction tag in a guide for both factions), every prerequisite that no step it takes turns in
counts as done before the guide, and every level gate is open. With `--live off` it walks exactly the order it is given,
which is what `tools/test_cost_parity.lua` compares with the optimizer. `--route-order PATH` plays another RouteOrder file
(the bake gate's own, a test bake). `--repro` and `--capture` still replay the client's own way (from the player's spot,
hearth allowed).

## Turn-in cost: `--turnins` (2026-11-10)

vplayer used to complete turn-ins without the `QUEST_TURNED_IN` event, so the cost of what the addon does on that
event was never measured. `--turnins` fires every registered handler at each turn-in, as the client does, and times them
(the Progress refresh and live re-plan they start included). It also counts graph builds and router calls made while
the handlers run, and prints a `TURNIN` line. Run it under `luajit -joff`, which is closer to the client's plain Lua 5.1;
`CR_OVERRIDE` loads older copies of addon files for a before/after comparison (docs/ROUTING.md "What changes the graph").

## What it does not cover

It does not prove Blizzard's API still answers the way the addon assumes, and it does not draw a
single frame.  Those need a live client — see [LOCAL_SERVER.md](LOCAL_SERVER.md) for what is still
possible once the subscription lapses (retail stays free; Era/TBC/MoP go dark).

## Output

| table | one row per |
|---|---|
| `vplayer_guides` | guide played: steps, simulated, auto, manual, stalls, laps, yards walked, sim seconds, no-route steps, finished |
| `vplayer_stalls` | step that should have auto-completed and did not |
| `vplayer_runs` | flavor per collection: totals, % auto, stalled guides, errors |
