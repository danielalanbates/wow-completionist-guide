# Stable step keys: progress that survives a guide update (2026-11-10)

IDEAS #6, branch `stable-step-id`. Offline only: **nothing here has run in a real WoW client.**

## The problem

Done, skipped and stepped-back marks were stored by guide id and **author step index** (`done[guide][7] = true`).
Every regeneration of the guide data (a wiki fix, a new quest, a WoW-Pro update read at runtime) shifts the indices
after the first changed line, so manual ticks and skips moved onto the wrong steps. Quest steps re-ticked themselves
from the quest log; notes, run-to steps, skips and stepped-back steps did not.

## The key

Every parsed step gets `step.key` (`Core/Guide.lua`, `G.AssignKeys`), computed once per parse, in author order, before
a baked route order is applied:

| Step | Key | Example |
|---|---|---|
| with a quest | action + quest ids (sorted, `+` between) + `.objective` | `A123`, `C123.2`, `T123+124` |
| without a quest | action + `~` + 45-bit hash of the title's words, plus its achievement / criteria, recipe, skill (name, target, tier) and mission ids | `N~2bq9z0k1f` |
| a repeat of the same key | `#2`, `#3`... counted in author order | `K207#2` |
| access-chain step (put in front of a guide) | `@<chain key>/` + the same recipe, counted inside its chain | `@siren_isle/A84719` |

- The title's words: lower case, punctuation and whitespace folded to one space, coordinates written into the text
  (`48.1, 42.9`) removed. A title never contains `|`, so there is no markup to strip.
- **Not part of a key:** coordinates, zone, note, flags (`|O|`, `|S|`, `|NC|`...), targets, items, level gates. A data
  fix that moves a point, changes a zone or rewrites a note keeps the key.
- An objective given as text (`|QO|Kill 10 wolves|`) is hashed; a number is kept as is.
- The hash is a polynomial hash modulo the prime 68,757,246,219,383 (about 2^46), exact in a Lua 5.1 double, written in
  base 36. No bit library, so it runs the same on all five clients.
- `G.KEY_VERSION = 1`. If the recipe ever changes, the version goes up and a migration maps old keys using the stored
  guide checksum (below).
- Adding the key changes nothing else: parse results and `G.RouteChecksum` are identical with and without it (checked
  on the synthetic guide and on every 40th real guide of every flavor), and the RouteOrder checksum is untouched.

**What still moves a mark.** A step whose quest-less title is reworded gets a new key (its tick is lost, never put on
another step). Inserting a step with exactly the same key in front of another one (two identical `N Talk to the guard`
lines, or a second objective-less `C` step of the same quest) renumbers the repeats behind it; on real data 2.4-4.0% of
steps are such repeats (table below).

## Collisions on the real guides

`tools/test_progress_keys.lua` parses every guide of every flavor (generated wiki, gaps, spine, professions, gold,
achievements, storylines, missions, native guides, and the WoW-Pro guides as the runtime adapter imports them from the
locally baked file). Keys are unique within a guide by construction (the repeat number); the test checks it, and checks
that no two **different** texts share a hash inside a guide (which would make them count as repeats of each other).
Equal keys in different guides do not matter: marks are stored per guide.

| Flavor | Guides | Steps | Quest steps | Other steps | Repeats | Duplicate keys | Hash collisions |
|---|---:|---:|---:|---:|---:|---:|---:|
| era | 659 | 37,509 | 33,157 | 4,352 | 1,518 | **0** | **0** |
| tbc | 897 | 57,428 | 52,058 | 5,370 | 2,215 | **0** | **0** |
| mop | 1,786 | 154,331 | 127,967 | 26,364 | 3,713 | **0** | **0** |
| retail | 4,967 | 605,873 | 398,048 | 207,825 | 19,452 | **0** | **0** |
| forever | 676 | 38,693 | 34,266 | 4,427 | 1,518 | **0** | **0** |

Collision rate within a guide: 0 of 893,834 steps.

## Cost

Measured with `luajit -joff` (the interpreter only, the closest offline stand-in for the client's Lua 5.1), CPU time:

| Flavor | Parse all guides (ms, keys included) | Key building alone (ms) | Share | Largest guide: steps, parse ms, keys ms |
|---|---:|---:|---:|---|
| era | 492 | 15.2 | 3.1% | 775, 9, 0.3 |
| tbc | 743 | 21.5 | 2.9% | 766, 9, 0.2 |
| mop | 2,005 | 83.0 | 4.1% | 6,614, 67, 12.9 |
| retail | 7,908 | 555.4 | 7.0% | 102,672 (`ach:retail:expansion_features_skyriding`), 1,060, 239.5 |
| forever | 525 | 16.3 | 3.1% | 775, 13, 0.3 |

About 0.9 microseconds per step on retail. Keys are built once per parse; nothing is hashed per frame. A normal zone
guide (a few hundred steps) costs well under 1 ms. The one very large retail achievement guide (102,672 steps, all
without quests) costs 0.24 s more on top of its 1.06 s parse, a hitch it already has. A first version built the base-36
digits with a loop of concatenations (0.4 s on that guide); one `string.char` call cut the encoding to a quarter.
Loading a guide also sums its keys once (`G.GuideSum`, stored next to the marks): 76 ms on that guide, about
0.7 microseconds per step, cached per parse. A guide with skipped quests sums keys and indices for its rebuild key
once per rebuilt list (89 ms there).
Absolute times on this Mac vary up to about 4x between runs (jobs run at nice 10 next to other agents' work and can land
on efficiency cores), so the share of parse time is the steadier figure; the client's own Lua 5.1 differs from
`luajit -joff` by a factor that was not measured.

**Play is unchanged.** `tools/vplayer.lua` on 15 era and 15 retail guides writes byte-identical result and stall files
before and after this branch.

## Storage

| Where | Field | Content |
|---|---|---|
| account file, `CompletionRouteDB.chars[<Name-Realm>]` | `stepDone[guide][key] = true` | ticked (by hand or by the auto-completer) |
| | `stepSkipped[guide][key] = true` | skipped as a step |
| | `stepMeta[guide] = { v, sum, mig, lost }` | key version; `G.GuideSum` (checksum of the guide's keys in author order) when last loaded or migrated; how many old marks were imported; how many matched no step |
| character file, `CompletionRouteCharDB` | `stepReopened[guide][key] = true` | stepped back to (`Progress.Undo`) |
| both (unchanged, read only) | `done`, `skipped`, `reopened` | the index-keyed tables of earlier releases |

Quest skips (`questSkip.roots` / `locks`) are keyed by quest id, which is the same in every data release, so they need
nothing. The saved re-plan order (`questSkip.plans[guide] = { k, o }`) is still a list of author indices, but its
rebuild key `k` is now `k1:<checksum of the step keys and author indices in list order>:<quests out>`, so it is applied
only to exactly the guide it was planned for. A key in the older format (step count, route checksum, quests) is
converted once when it still matches the guide (same rule as the marks, below).

## Migration (one time, per character and guide)

`Account.Migrate(guide, steps)` runs when a guide is loaded (`Progress.Load`), and when its progress or completion is
read for the guide list (`GuideProgress`, `GuideIsComplete` / `GuideCompletedBy` for guides without quests).

- It maps old index marks to keys with the guide **as it is now**. That is right only because the data has not been
  re-ordered since those marks were written: this is the first release with keys. From here on the keys carry marks
  across data changes.
- It runs once: `stepMeta[guide]` records that it ran, and is written for the logged-in character on every guide it
  loads, even without old marks, so index marks that a downgraded client writes later (perhaps on older data) are never
  mapped onto this data.
- Other characters' records are migrated too (account-wide progress counts their marks), but only those of this
  client's game type (`gametype`, hardcore folded in; a record from before game types counts by its `flavor` unless it
  is `era`, which Classic Era and WoW Forever both report). A record copied in from another client by
  `tools/sync_progress.lua` was written against that client's guide data and is migrated by that client.
- Access-chain steps (negative indices, put in front of a guide) are not carried over: their numbers depended on which
  chains were locked at each load. They are counted in `lost`, with any index that has no step; their quests re-tick
  from the quest log.
- The old tables are never written again (Reset clears them too, so a reset does not come back after a downgrade) and
  stay for one release.

**Downgrade.** The previous release reads its own tables, which still hold the progress made before the update. The
test loads the previous release's own code (git commit `b322bb6`) on the files this release wrote: no error, the old
ticks, skip and stepped-back step are there; ticks made after the update are not seen. Upgrading again uses the keyed
marks; nothing written while downgraded is imported for a guide that was already migrated.

## Everything that reads or writes marks

| File | What changed |
|---|---|
| `Core/Guide.lua` | `G.AssignKeys`, `G.StepBase`, `G.NormText`, `G.KeySum`, `G.GuideSum`, `G.KeySet`; keys built in `G.Steps` |
| `Core/Account.lua` | keyed sets (`Done`, `Skipped`, `Reopened`), `Migrate`, `Started`, `ClearMarks`; `OtherDid(guide, key)`; `GuideProgress` (keep = step keys; ticks of steps the guide no longer has do not count); quest-less "finished" counts only keys the guide has; roster counts; the scratch store of sweeps covers the keyed tables |
| `Core/Progress.lua` | done / skip / undo / reopen / reset / new lap / auto-complete / `VisibleDone` by `step.key`; migration on load; `P.MarkSets`, `P.MarksReport` (`/cr marks`); access-chain steps get `@chain/` keys |
| `Core/Skip.lua` | the rebuild keeps ticks by key; `ViewOf` keep set by key; rebuild key by step keys, old-format conversion |
| `Core/BugReport.lua` | done / skipped / reopened read from the keyed sets (still listed as author indices of the named guide); the report also carries `guide.keySum` and the step's `key` |
| `Core/Recommend.lua`, `Core/Slash.lua`, `Core/Sweep.lua`, `UI/GuideFrame.lua` | "started", `/cr why`, the account self-check, the sweep's scratch reset (it used to clear the character's real old tables), the Back button |
| `tools/vplayer.lua`, `tools/route_sweep.lua`, `tools/vplayer_repro.lua` | fresh-character resets cover the keyed tables; `--repro` puts the report's marks back under the offline parse's keys, marks access-chain steps after loading, and compares `keySum` (when the guide changed, the current step is found by its key) |
| `tools/sync_progress.lua` | unions `stepDone`, `stepSkipped` and `stepMeta` as well |
| `tools/clean_sweep_progress.py` (one-off cleanup of sweep pollution from old builds) | also clears swept `stepDone` / `stepSkipped` tables (checked on a temp file, not on real files) |
| `tools/sv_to_json.lua`, `tools/ingest_beta_reports.py` | nothing: they never read marks (a report's new fields travel in its JSON) |
| RouteOrder (`G.BakedOrder`) | unchanged: still maps a baked order by author index and checksum |

## Tests

`luajit -joff tools/test_progress_keys.lua [era tbc mop retail forever]` (178 checks, about 15-20 s, 260 MB):

1. The recipe on a synthetic guide (quest, objective, several quest ids, repeats, words, coordinates, access chains,
   parse unchanged).
2. A synthetic guide regenerated with one line inserted, one deleted, one point moved and one block moved, across a
   SavedVariables round trip: every tick, skip and stepped-back step stays on its step, a quest skip still drops exactly
   its quest's steps, the deleted step's tick counts nowhere, the old re-plan is not applied, account-wide marks follow,
   a baked order still applies by author index and checksum. The same marks by author index would sit on 3 wrong steps.
3. Migration from `tools/fixtures/progress_keys_account_SV.lua` and `..._character_SV.lua` (the real files' structure,
   placeholder names): this character's done, skipped and reopened marks, another character of the same game type,
   records of other clients and of unknown game type left alone, empty old tables, marks with no step, a real era
   guide, untouched old tables.
4. Idempotence (twice in a session, after a reload, after a downgraded client wrote more index marks), an old-format
   re-plan key converted and applied, and the downgrade with the previous release's own code.
5. `tools/sync_progress.lua` on temp copies of two client folders: keyed marks and migration records reach the other
   file; a second run changes nothing.
6. All five flavors' real guides: the table above, parse results unchanged on a sample, access-chain keys unique.
7. Per flavor, three wiki guides and one WoW-Pro guide regenerated the same way as in 2 with 8 marks and a quest skip:
   every mark on its step, no other step marked, the inserted step open, the skipped quest still out.

A mutation check (keys from author index; coordinates inside the key; migration off; every record migrated) makes the
test fail in each case.

## Open

- Not run in a client. The beta should check `/cr marks` on a guide after the first data update that lands with this.
- The previous release used for the downgrade check is the integration head this branch started from; the installed
  beta may be older.
- `tools/sync_progress.lua` unions marks, so a reset or a step taken back on one client comes back from another client's
  older copy of the same character. That was already so for the old tables.
