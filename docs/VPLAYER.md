# The virtual player

`tools/vplayer.lua` plays every guide the way a character would, without a character, a server or a
subscription.

```
luajit tools/vplayer.lua <era|tbc|mop|retail> [--limit N] [--shard i/n] [--type Leveling]
                         [--guide ID] [--faction Horde] [--guidecap 20] [--out PATH] [--verbose]
python3 tools/collect_vplayer.py       # -> docs/verification.sqlite
```

## How it differs from the route sweep

`route_sweep.lua` asks *"can the router reach step 1, and is the optimizer's order legal?"*.  It never
moves.  The virtual player asks the question that actually matters — **would a character finish this
guide?** — and answers it by running the real addon:

1. `Progress.Load(id)` — the real loader, including access-chain prefixes and gold-guide circuits.
2. For the current step: `Router.TravelSecondsFromPlayer(step)` (this is the real router, so a step
   with no route is counted), then the player is teleported onto the step's coordinates.
3. The step's action is performed **against the world, not against the addon**: an `A` puts its quest
   in the log, a `C`/`K` finishes the objectives, a `T` flags the quest complete, a `B` fills the bags,
   an `L` raises the level, `h`/`f` set the bind/taxi flags.
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
