# Status / handoff (2026-11-12: one build, the public one; a full rebake is needed)

## 2026-11-12: step window, routes list and options: text size, wording, scale, minimap button (`todo-ui`)

Offline only. **Nothing here has run in a real WoW client.** Branch `todo-ui` (worktree `wt-ui`), on top of the
Recommended section (`23ff876`). Not merged, pushed or installed. No generated data was touched.

| Item | What changed |
|---|---|
| Text size covers everything | The options pages (title, description, every check box, slider and pause-key label), every `UIPanelButtonTemplate` button label (step window, its two menus, the Details panel, the Start over question, the routes list's level buttons, the options page, the bug-report note window) and the titles of the bug-report and log windows now use `U.Font`, so the *Text size* slider covers them. Button labels: Title font (normal), Body (highlight) and a grey copy of Title (disabled; `GF.SyncFonts` re-copies it at login and when the slider moves). The log's lines stay in the client's chat font. |
| Nothing runs over | Buttons widen to their label (`GF.FitButton`, never narrower than before); both step-window menus widen to their widest row; the Details panel widens to hold its button row; the options rows are placed from the measured label heights (`O.Layout`: on show and after the slider), labels wrap at 540 px, and the scroll area and the Auto quests controls hang under their descriptions; the pause-key choice moves right of a long label; the routes list's "your level" hint hangs from **Current**, and *Group by level* moves right of a long first label; the note window's edit box hangs under its title and the window grows with it. |
| Wording | "routes" where it meant routes: options (*Lock step window*, *Step window scale*, *...order for quest routes*, the account-wide line now names the Character / Server / Game type / Account buttons at the top of the Routes window, the Auto quests page), the routes list (*Only routes for this level*), the step window (skip quest in every route, error line), `/cr` messages. The end-of-route text and the options description point at **Recommended** instead of the removed *For level N*. Developer self-test names (`/cr verify`, `verifyall`, `verifyfeatures`) keep "guide": they are keys in `featureVerify` and `docs/verification.sqlite`. |
| Step window scale | The Options slider runs 60-250, the grip's 0.6-2.5 (`GF.SCALE_MIN/MAX`), and scales about the top-left corner like the grip (`GF.SetScale`, which shares `hangAt` with it; a window hidden since login uses its saved corner). No slider acts on the value it reports when the page opens any more, so a grip-made 2.5 (or 1.37) is no longer cut to 2.0 (or 1.35). A saved scale outside the limits is clamped at login. |
| Minimap button | New `UI/Minimap.lua` (all six TOCs, after `UI/Options.lua`; `tools/validate_toc.lua` checks it): the addon's arrow on the client's round minimap-button art, on a circle 5 px outside the minimap's radius; on a square side (`GetMinimapShape`: SQUARE, CORNER-, SIDE-, TRICORNER-) on the square's edge. Left click: step window; right click: Routes; drag: around the edge, angle saved in `profile.minimapAngle` (default 200). Hidden when `profile.minimapButton` is false (Options: *Minimap button*). No library. |
| `/cr suggest` | `/cr next` stays "mark the step done"; the old second `next` branch (never reachable) is `/cr suggest` and in the help line. `/cr guides` is still `/cr routes`. |
| Leftovers | `autoAdvance` left the defaults and is dropped from saved profiles at load. Bug reports no longer carry `arrowStyle` or `autoAdvance`; they now carry `textSize`, `frameScale` and `minimapButton`. |

**Tests** (worktree, through `heavy.sh`, `luajit -joff`):

| Test | Result |
|---|---|
| `tools/test_ui.lua` (new): minimap button (made, round and square placement, clicks, tooltip, drag angle saved, hidden by the option), options pages (addon fonts on every text and button, no "guide" wording, no row overlaps at text size 2 and 6, page grows), scale slider (range, no change on show, corner kept, limits, hidden window), `/cr next` / `suggest` / `guides`, profile defaults | 90 checks pass |
| `tools/test_step_window.lua` (+34: button fonts; at a 19 pt button font the title line, both menus, the Details panel and the Start over buttons fit their labels) | 286 checks pass |
| `tools/test_bug_report.lua` (+3: removed settings gone, new ones reported, the note window opens) | 97 pass |
| `test_load_all.lua` (Minimap.lua loads on all six TOCs), `validate_toc.lua` (and a scratch TOC without `UI\Minimap.lua` fails it), `test_live_route`, `test_offline`, `test_level_list`, `test_flow`, `test_quest_auto`, `test_parked`, `test_skip`, `test_contribute`, `test_farm`, `test_access`, `test_teleports`, `test_gold`, `test_professions_engine`, `test_professions`, `test_progress_keys`, `test_wiki`, `test_route_order`; Python `test_package.py`, `test_ingest_beta_reports.py`, `test_contrib_gen.py` | pass |

**Not verified (needs the owner's eyes in game):** how the minimap button looks and drags on each client (the art
is the client's own minimap-button textures, the icon `Textures/arrow.tga` tilted 45 degrees); that the options
check boxes' labels wrap and centre as modelled in the Settings frame of every client; real label widths (the tests
use a character-count font model). The fonts are a model: pixel overlap cannot be checked offline.

## 2026-11-12: Contribute, three review findings fixed (`todo-contribute`)

Offline only. **Nothing here has run in a real WoW client.** Not merged, not pushed, not installed.

* **A treasure step's chest was never linked in the real event order**, so its gold circle never showed.
  `Core/Progress.lua` handles `LOOT_READY` and `LOOT_OPENED` first and ticks the step, and Contribute then looked at
  the next step. Now Contribute keeps the treasure step that was just ticked (`STEP_DONE`) for one second and links
  the chest to it, and reads the loot on `LOOT_READY` too. The test fires both events through the registered handlers
  after loading a real route, in place of calling `C.OnLoot()`.
* **The rare flag moved out of the cell record** to `contrib.rare[flavor][key]`. A record holds numbers only again,
  so `/cr contribute` on a build without this change no longer fails on these saved variables.
* **Tests for what was claimed but not tested:** Retail 12 secret values (loot source, loot link, target name,
  target GUID), the six-link cap, the 16-circle cap, two areas per named thing, a rare kill inside the throttle, the
  ring's dedupe, the killing blow's untag, a step change refreshing the wanted items. `test_contribute.lua`: 113 pass
  (was 89). 16 mutations of `Core/Contribute.lua` (the reviewer's 9 and 7 more) each fail at least one test.
* **Seen, not fixed (not this branch's file):** `Core/Progress.lua` `lootWindow` runs on `LOOT_READY` and again on
  `LOOT_OPENED`. With two treasure steps within 25 yards of each other, one chest ticks both.

## 2026-11-12: Contribute records creatures, objects and items, and draws them (`todo-contribute`)

Offline only. **Nothing here has run in a real WoW client.** Branch `todo-contribute` (worktree `wt-contrib`), cut
from `master` at `f30bbc1`. Not merged, not pushed, not installed. Details: `docs/CONTRIBUTE.md`.

| Part | What it does now |
|---|---|
| `Core/Contribute.lua` | While the box is ticked and outside instances: a creature the player or pet hurt that dies (combat log, Classic clients) or a looted corpse gives `N:<npc id>`; a looted chest, treasure, herb or ore gives `O:<object id>`; an item in the loot that the current or next steps name (`L`, `U`) gives `I:<item id>`. One sample per key every 5 s; a rare (`rare`, `rareelite`) is a flag beside its record (`contrib.rare`). Same grid, weights, 80-cell cap and export format. The combat log is registered only while ticked and outside instances, never on Retail 12.x; its handler makes no table per event. |
| World map | Beside the step's own circles: its items (purple), its creature (red, a rare outlined) and its object (gold), up to 16 circles from one reused frame pool. A step finds its creature by name (`UI/Beacon.lua` `StepNames`) and by links that hold ids only. |
| Data repository | `tools/contrib.py` accepts `N:`, `O:`, `I:` keys (branch `contribute-kinds` there, commit `ce6eab3`, not pushed). |

**Tests** (each once through `heavy.sh`): `test_contribute.lua` 89 pass (58 new); `validate_toc.lua`, `test_load_all.lua`,
`test_offline.lua`, `test_step_window.lua`, `test_progress_keys.lua`, `test_quest_auto.lua`, `test_contrib_gen.py`
pass; the data repository's 56 unit tests pass (2 new). Not done: the guide window's tooltip (`UI/GuideFrame.lua`)
still says "quest ids"; no generator reads the new keys yet.

## 2026-11-12: finished routes the player picks, first login, old marks at login, hearth-aware re-plan (`todo-flow`)

Offline only. **Nothing here has run in a real WoW client.** Branch `todo-flow` (worktree `wt-prog`), cut from `master`
at `f30bbc1`. Not merged, not pushed, not installed. Files: `Core/Progress.lua`, `Core/Account.lua`, `Core/Skip.lua`,
`Core/Recommend.lua`, `Routing/Replan.lua`; no UI file changed.

| Item | What changed |
|---|---|
| A finished route the player picks | `Progress.Load(id, opts)`: a load outside the chain (routes list, Recent, `/cr load`, `/cr switch`: they all call `P.Load(id)` plain) is *picked*. A picked route with nothing left stays loaded (`P.hold`): the step window shows its end screen with Start over (GuideFrame shows it whenever a route is loaded with no current step), the chat says "Route finished: X. Start over runs it again; Routes has the next one." (or names the level gate, and parks the route quietly). The hold ends when the route shows a step (Start over, a level-up), so a route that runs out during play chains on as before. `CompletionRouteCharDB.held` keeps it across `/reload` (in the sweep's scratch store). The Recent row stays a link to it. |
| GUIDE_LOADED once | It fired for the next route inside the chain and then again for the finished one on the way out of the first `P.Load`. Now a load counter (`P.loadSeq`) stops the outer load after its refresh when a nested load happened: one event, for the route that ends up loaded. |
| First login | No saved route: the routes list opens at every login until a route has been loaded once (was: once, then a suggested route was loaded at the next login). A saved route loads as before; a saved route gone from the data still gets the closest fitting one. `welcomed` is no longer read. |
| Old index marks at login | `Account.StartImport`, 10 s after login, converts every registered guide that still holds old marks of a character this client migrates, through `Progress.ReadSteps` (the load's own path: gold circuit fold, then the parsed steps; the access prefix is left out, as it holds only negative indices that no old mark maps to: tested equal). Time-sliced from an OnUpdate, 4 ms a frame, a guide that would not fit in the rest of the frame (text length at the measured rate) waits, parsed steps are dropped. A guide with more than 40 KB of text (`Account.IMPORT_MAX_TEXT`; the huge achievement lists of MoP and Retail, none on Era, TBC, Forever) is left out: one parse cannot be split, so its old marks are converted as before, when the guide is loaded or parsed by the routes list. An error in a slice ends the job for the session instead of repeating every frame (`Account.ImportTick`); a saved mark entry that is not a table counts as empty, in the import and in a load. Then `CompletionRouteCharDB.marksImported` is set; it never runs again. A bulk sweep pauses it; a logout in the middle leaves the rest for the next login. |
| Re-plan after a skip | The search prices the leg from the player as acceptance does when the Hearthstone or a teleport is usable (`Replan.OneShotLandings`, FindPath's own rule): the greedy start may open with it, and Or-opt may move a run to the front. A sound lower bound (hearth base cost - 10 s + hearth-free time from the landing, one multi-goal search per landing) skips the path search where a one-shot cannot win. Acceptance unchanged. |
| Wording | Chat lines in these files say route: "Route: X (N steps...)", "Route finished. Loading next: X", "Unknown route", "Gold route folded into a N-stop circuit", `/cr marks` ("No route loaded.", "this version of the route", "The route has changed", "for this route", "Route version"), the quest-skip warning and messages ("in this route, N in other routes", "from this route", "left this route", "out of this route", "later in the route"), `/cr list` ("Routes for level N"), `/cr prof` ("no route for this skill band"), the tooltip line "this route has no level data". "No route matched" already said route. |

**Measured** (`luajit -joff`, stubs, a machine shared with other jobs, so CPU numbers vary by about 15% between runs):

* Old-marks import, worst case of old marks on EVERY guide (this character and an alt), three runs: era 511 guides
  450-530 ms CPU, tbc 681 / 0.71-0.83 s, mop 1,230 / 1.75-2.07 s, retail 4,439 / 7.0-8.4 s (2,000-2,170 slices),
  forever 528 / 0.49-0.57 s; 0.9-1.9 ms a guide; median slice 3.1-3.4 ms. One guide is one parse and cannot be split:
  Retail `ach:retail:expansion_features_skyriding` (588 KB) 82-107 ms, 12-32 Retail slices and 2-3 MoP slices pass a
  60 fps frame (16.7 ms); none on era, tbc, forever (largest single guide 7-14 ms). A real character pays this only for
  the guides it has old marks in. On a test clock (1 ms per KB) no slice of more than one guide passes 4 ms.
  **After the review fix** (guides over 40 KB left to the lazy path; two runs): mop 14 of 1,230 left out, largest
  slice 15.2-15.5 ms, none over 16.7 ms; retail 66 of 4,439 left out, 6.9 s CPU, largest slice 16.7-20.0 ms, 0-3
  slices over 16.7 ms (was 92 ms, 18 slices); era, tbc, forever unchanged (nothing left out, largest 7-10 ms). So the
  Retail spike is cut to about one 60 fps frame, not removed: guides of 23-28 KB can still take 15-20 ms here.
* Re-plan, the 15 real samples of `tools/test_skip.lua`: the same 15 results as before; frames 106/374/2396/4624/363
  before, 125/413/2456/5058/340 after in one run and 130/439/2840/5942/391 in the final run (era/tbc/mop/retail/forever;
  a frame count follows CPU time, which varies with the machine's load). Without the bound (a path search per block)
  it was 161/466/3013/7758/580. One full run showed one frame of 3.48 ms (collector paused) on retail; the retail rerun
  had a maximum of 1.35 ms and the final full run passed (max 1.85 ms, budget check 2 ms).
* `tools/vplayer.lua era --chain Alliance` and `--chain Horde`: identical summaries with the old and new
  Progress/Account (272 and 360 loads, 0 bounces, level 60).

**Tests** (worktree, each through `heavy.sh`):

| Test | Result |
|---|---|
| `tools/test_flow.lua` | 206 checks pass; section 4 is new (finished route picked from the list, Recent and after `/reload`; chain during play; GUIDE_LOADED once; gated route; cycle depth; first login twice, then a pick). 19 of its checks fail on the old `Progress.lua`. |
| `tools/test_mark_import.lua` (new) | 54 pass on all five clients (5 added by the review fix: a guide over the text limit is left out and converted by its load; damaged entries; an error in a slice drops the job): same tables as loading each guide (fixture, baked synthetic guide, real `wiki:era:1429:Alliance`), the re-ordered-update case (imported: mark stays on its step; lazy: lands on another), sweep pause, logout mid-way, gold circuit fold, access prefix, slicing on a test clock, cost |
| `tools/test_skip.lua` | all pass (353); new 1c: opening with the hearth wins and is accepted, the hearth-free search finds nothing, a 60 min cooldown keeps the order; 1b's second check now expects the search to propose no slower order |
| `test_progress_keys.lua` (202, 1 skip: old commit not in this clone), `test_offline`, `test_load_all`, `validate_toc`, `test_parked`, `test_live_route`, `test_step_window`, `test_level_list`, `test_quest_auto`, `test_bug_report`, `test_teleports`, `test_farm`, `test_contribute`, `test_access`, `test_package.py` | pass |

**Open.** Not run in a client: the end screen of a held route, the list at first login and the import's frame cost
need the beta. The import now leaves guides over 40 KB to the lazy path, so for those (14 on MoP, 66 on Retail) a mark can
still land wrong after a re-ordering update, and the routes list counts their old marks only once it has parsed them;
converting them at login without a hitch needs a parse that can be split (`Core/Guide.lua`).

## 2026-11-12 morning: merged player contributions reach the shipped guides (`contributions-into-guides`)

Offline only. **Nothing here has run in a real WoW client.** Branch `contributions-into-guides` (worktree
`wt-contribgen`, its own copy of the generated data), cut from `master` at `e00d383`. Not merged, not pushed, not
installed. No add-on code changed: the add-on already records, exports and uses its own learned spots; this is the
tools' side. How it works: `docs/CONTRIBUTE.md`.

**What was missing.** Players' positions were merged in the data repository (`wow-completionist-data`,
`contributions/areas/<flavor>.json`) but no generator read them, so a contribution helped only on the machine that
made it.

**What is built.**

| Part | What it does now |
|---|---|
| `tools/wiki/gen_wiki_guides.py` | Reads `areas/<flavor>.json` from `--contributions DIR`, else `CR_CONTRIB`, else `../wow-completionist-data/contributions`. Source order for a quest step: wiki point, Blizzard quest pin, **contributed area**, wiki place page, zone. Only `trusted` and `confirmed` areas on a map the client has. Accept and turn-in take the heaviest area; an objective takes up to three on one map. Note `(location: player contributions, N players)`. The file header names the data repository, CC BY-SA 4.0 and its commit. `--out DIR` writes a whole run into another folder; `--no-contributions` reads none. |
| Conflicts | A wiki point more than 100 yd from the contributed area of the same step on the same map goes into `wiki_db2_conflict` (`A_xy_contrib`, `T_xy_contrib`, `C_xy_contrib`). The guide keeps the wiki point. |
| Statistics | `wiki_point_sources` has a `contrib` column (added to an existing chart on the next run); the run prints the count per client. |
| `tools/gen_completion_guides.py` | A contributed step passes through to the quest-line file unchanged. An achievement criterion that takes a contributed quest point says `location: player contributions, N players; quest <id>` instead of `wiki:`. Both files repeat the provenance line. |
| `tools/package_release.py` | A data file with a step that credits player contributions fails the gate (`no-provenance`) unless its header names the data repository with a full commit. `unknown` and `<commit>-dirty` fail. `ATTRIBUTION.md` and `WIKI_DATA_LICENSE.md` have an entry. |
| `tools/coverage.py`, `tools/status_report.py` | Such a step counts as located. New rows `quest-contrib` and `quest-contrib-steps`; new column *contributed*. |

**Keys.** The generator uses the add-on's own keys: `A:<quest>`, `T:<quest>`, `C:<quest>:<QO number>`, and
`C:<quest>:0` for an objective step written without `QO` (`Core/Contribute.lua` `KeyFor`). The test parses generated
steps with `Core/Guide.lua` and asks `KeyFor`: they agree. One limit: on Retail, when the wiki's objective count
differs from the client's, the steps carry no `QO` and several of them share key 0, so a quest with more than one
such step takes no objective area.

**Nothing changes for players today.** No contribution has been merged, so no `areas` file exists. Proof, in the
worktree, each generator run once:

| Run | Result against the copy it started from (sha256) |
|---|---|
| `gen_wiki_guides.py` (all five clients, default options: the sibling data repository has no `areas` folder) | 9 of 10 guide and spine files and 4 of 5 sidecars byte-identical. `Imported_Wiki_retail.lua` and `parts_retail.json` differ: see below. |
| `gen_completion_guides.py retail mop` (from the original retail wiki file) | all four files byte-identical |
| `gen_wiki_guides.py era --no-contributions --out <temp>` (inside the test) | guide, spine and sidecar byte-identical |

**The Retail difference is not from this work.** Four lines of `Imported_Wiki_retail.lua` moved: in guide
`wiki:retail:2371:Both:3` two sibling quests (86187 and 86188, same giver, same prerequisite) swapped places. Every
line is the same text. `parts_retail.json` shows the same swap, two more swapped pairs in `quests` lists that move
no line, and two entries of `cycles` in the other order. Step order is made in `tools/wiki/gen_spine.py`
`build_parts`, which got the same step lines and prerequisites in both runs. Its final fix-up gives quests it moves
behind the same prerequisite the same rank (`orank = rank + 0.5`), and it re-orders guides in the order of a set of
guide ids (`for gid in changed`: Python hashes strings differently in every process) and breaks rank ties by object
address (`frozen_resplit`: `(q.rank, id(q), q)`). `cycles` is filled in that set's order, and its two swapped
entries show the order differed between the two runs. The worktree copy was put back to the starting file
afterwards. The review below checked this with the unchanged generator and with a stable tie-break.

**Tests** (worktree, each once through `heavy.sh`):

| Test | Result |
|---|---|
| `python3 tools/test_contrib_gen.py` (new; fixture `tools/fixtures/contributions`, invented positions) | 94 checks pass (after the review). It runs the generator for Classic Era four times into a temp folder (no contributions, the fixture, a broken areas file, an invented area for every key) and the quest-line generator once on a synthetic wiki file. |
| `python3 tools/test_package.py` | all pass, 7 new checks for the contributions rule |
| `luajit tools/validate_toc.lua` | valid |
| `luajit -joff tools/test_wiki.lua` | pass (new check: a contributed step has a point, a player count and the header line; 0 such steps today) |
| `test_completion.lua` (runs the new place checks), `test_offline.lua`, `test_load_all.lua`, `test_contribute.lua` (31), `test_skip.lua` (342) | pass |
| `tools/coverage.py`, `tools/status_report.py` on the worktree's chart | same numbers as label `public-2026-11-11`; contributed 0 quests, 0 steps on every client |

What the fixture run shows on Classic Era: 7 steps take a contributed point (6 had only a zone or nothing, 1 came
from a wiki place page), 2 conflict rows are logged (832 and 880 yd), no step of any other quest changes, and the
packager's gate passes the file and fails it when the header line is removed.

**Review, same morning (second engineer; commits `93ecdf5`, `ce9c043` and this note).**

*Confirmed and fixed.*
* **A bad areas file crashed or stopped the generator.** A number too long for a float raised `OverflowError`,
  brackets nested 100,000 deep raised `RecursionError`, and broken JSON or another client's file stopped the whole
  run after earlier clients were already written. Now such an area is dropped, and a file that cannot be read is not
  used: the run prints `WARNING: player contributions of <client> NOT USED` (per client and again at the end) and
  writes that client's files as with no contributions (tested: byte-identical).
* **Loose checks on public input.** Now dropped: a position that would print as `0.0` or `100.0`, a `confirmed`
  area with one player, more players than weight, an area on a continent or the world map (two players "in the same
  place" there can be 500 yd apart; wiki points are never put on those maps either). Keys must match in full.
* **Attribution text.** `ATTRIBUTION.md` and `WIKI_DATA_LICENSE.md` said a contribution holds "map positions and
  quest ids only" and is taken on accept, turn-in and objective progress. It also holds the client flavor and
  build, step keys and weights, and a position is also taken when a step is ticked by hand. Corrected.

*Checked, no fault found.*
* **Keys, on every step.** One invented area for every key a quest step can have, each with its own player count,
  so a step's note tells which key the generator looked up. Read back through `Core/Guide.lua` and
  `Core/Contribute.lua` `KeyFor`: Classic Era 5,757 steps (1,741 accepts, 1,702 turn-ins, 2,314 objectives, 213 of
  them without `QO`), Retail 28,488 steps (8,930 / 5,761 / 13,797, 1,154 without `QO`). Every key agrees; no
  objective is off by one. The Era check is now part of `tools/test_contrib_gen.py`; `--keys retail` runs it for
  another client.
* **A contributed area never replaces a wiki point or a quest pin.** In the same runs every step had a contributed
  area: all 3,903 (Era) and 59,530 (Retail) different steps with a wiki point or a quest pin came out unchanged.
  The only steps left without a point were Retail objective steps without `QO` that share key 0 (66).
* **`single` never reaches a guide; unknown maps, positions outside the map and malformed rows do not either.**
* **The packager** fails a contributed step without the header line, with `unknown`, with `-dirty` and with a
  shortened commit, in the wiki, achievement and quest-line files.

*Byte-identity with no contributions (each run once, through `heavy.sh`; the worktree data equals `repo/` before
and after).*

| Run | Result against `repo/` (sha256) |
|---|---|
| `gen_completion_guides.py retail mop` | 4 of 4 files identical |
| `gen_wiki_guides.py`, all clients, `CR_CONTRIB` unset (finds the sibling data repository, which has no `areas`) | 13 of 15 identical. `Imported_Wiki_retail.lua`: 3 lines stand in another place, every line is the same text. `parts_retail.json`: the same reorder. |
| `gen_wiki_guides.py --out <scratch>`, all clients, `CR_CONTRIB` = an empty folder, `PYTHONHASHSEED=11` | 13 of 15 identical. `Imported_Wiki_retail.lua`: 2 lines stand in another place, every line is the same text. `parts_retail.json`: the same reorder. |
| the **unchanged `master` generator** in a scratch copy, same inputs, `PYTHONHASHSEED=11` | 10 of 15 identical. `Imported_Wiki_mop.lua` (3 lines in another place), `parts_mop.json`, `Imported_Wiki_retail.lua` (238 `diff` lines, one of them a guide's name), `Imported_Spine_retail.lua` (that name) and `parts_retail.json` differ from `repo/`. |
| `master` and this branch, each in a scratch copy with the same five-line stable tie-break in `gen_spine.py`, same seed | **all 15 files byte-identical to each other.** |

So the difference is not from this work: the unchanged generator does not reproduce `repo/`'s own MoP and Retail
files either, and once the tie order is fixed both generators write the same bytes. The cause is the tie order in
`tools/wiki/gen_spine.py` (`(q.rank, id(q), q)`: an object address; `for gid in changed`: a set of strings). Era,
TBC and Forever were byte-identical in every run. The stable tie-break (a sequence number in place of `id(q)`,
`sorted(changed)`) is a fix for its own change: against today's files it reorders `Imported_Wiki_mop.lua` (314
`diff` lines) and `Imported_Wiki_retail.lua` (3,138 `diff` lines) once, same lines in another order, so those
guides need a new baked order. Not done here: a bake is running.

*Found, not fixed (the data repository is read-only for this work).*
* `LICENSE-DATA` there lists `data/`, `corrections/` and the coverage report, not `contributions/`. Only
  `contributions/README.md` and the `licence` field of the areas file say CC BY-SA 4.0.
* The *Location contribution* issue form does not tell the player that the contribution is published under
  CC BY-SA 4.0 (`CONTRIBUTING.md` says so for pull requests only). Add both before the first contribution is merged;
  the add-on's attribution text relies on it.
* In the add-on, any step with a quest id that is not an accept or a turn-in is filed under `C:<quest>:<QO or 0>`.
  An achievement step "complete quest N" therefore adds to `C:N:0`, the key the generator uses for a quest's only
  objective step without `QO`. Those samples are still about that quest; no change made.

**Not verified.**
* Nothing was run in a client. A step with three contributed points relies on `Router.NearestCoord`, which the
  wiki guides already use for multi-point steps.
* No real contribution exists, so the path from the issue form to a shipped point was never run end to end with
  real data. The header line was produced from a scratch git checkout that stands in for the data repository.
* The full packager dry run was not repeated on this branch (its tests were).

**Stays open.**
* The MoP and Retail tie order above (stable tie-break, then a rebake of the guides it reorders).
* The two licence lines in the data repository above.
* `G:` keys (steps with no quest) are merged in the data repository and read by nothing. Hand-written, gold and
  profession guides take no contributed points.
* Found on the way, unchanged: an achievement criterion that takes a quest's point from the wiki file says
  `wiki: <page>` even when that point is a Blizzard quest pin there.
* `docs/status_table.txt` was not regenerated: it gets the *contributed* column after the next `tools/coverage.py`
  run in `repo/`.

**To apply** (after the running bake has finished): merge `contributions-into-guides` into `master` locally. No
regeneration, bake or install is needed while there are no contributions: the generators write the same files.
When the first contributions are merged in the data repository: `git -C ../wow-completionist-data pull`, then the
steps of `docs/RELEASE.md` "Making a build" (regenerate, bake the guides whose points changed, test, package).


## 2026-11-12 early morning: saved-state review, fixes on `state-review-fixes`

Offline only. **Nothing here has run in a real WoW client.** Branch `state-review-fixes` (worktree `wt-state`), `master`
at `026136a` merged in. Not pushed, not merged, **not installed**. A reviewer loaded the owner's real saved variables
(the copy of 2026-11-10) through the build and reported nine findings; a second pass tried to refute each and fixed
what held. All nine held. None was refuted.

**Before the next login on Classic Era, TBC Anniversary or MoP Classic.** The three live account files still hold
`autoVerifyAll`, `autoSweep` and `autoQuitAfter`, left by `tools/queue_verify.py` in August (checked 2026-11-12 05:20;
files last written Nov 7; no client was running). The build installed on the clients acts on them: 35 s after login
it loads every guide, twice, and a logout or `/reload` in the middle saves the sweep's scratch tables over the
character's marks. Either install this branch first, or delete those three lines (lines 3-5) from
`WTF/Account/<account>/SavedVariables/CompletionRoute.lua` in `_classic_era_`, `_anniversary_` and `_classic_`. This
pass may not write into the game folder, so neither was done. Retail and Forever carry no such keys.

| # | Finding | Fix | Check |
|---|---|---|---|
| 1 | Developer sweep keys in three live files start two overlapping sweeps at login; a logout during one saves its scratch tables; guides nobody opened end up parked | `Core/Init.lua` drops the six `auto*` keys at load unless `devRun` came with them (`queue_verify.py` writes it). `Core/Account.lua`: the scratch store is counted, also keeps the character file's saved guide, parked guides, detour return and laps, and is put back on `PLAYER_LOGOUT`. A second bulk run while one runs is refused (`NS.bulkRun`). | `test_progress_keys` 4d, 4e; `test_offline`. Real TBC file, fixed tree: no sweep starts; as a developer run with a logout 100 frames in, the saved record equals the one before. |
| 2 | The one-time import put old index marks on whatever step has that position now (real Retail character: 56 of 81 on quests it never did) | `Core/Account.lua`: a guide's marks are dropped when any index is past the guide's length (`stepMeta.stale`); a done mark lands on a quest step only when the record's completed quests (or the client) agree. `/cr marks` says so. | `test_progress_keys` 3, 3a; `test_offline` |
| 3 | Progress scope "This server" / "This game type" became "All characters" 30 s after every login | The login self-test asks `Account.OtherDid` with an explicit scope instead of flipping the saved flag, and prints nothing when quiet | `test_progress_keys` 4e, all four scopes |
| 4 | The launchd sync agent runs its own copy of `sync_progress.lua` from August, which deletes keyed marks, migration records and dropped quests | `tools/install.sh` replaces an out-of-date agent copy (`tools/refresh_sync_agent.sh`). The script carries tables it does not know through from the newest record and refuses a file of a later layout (`CompletionRouteDB.dataFormat`). | `test_progress_keys` 5 |
| 5 | A re-plan slower than the baked order was accepted: the planner priced the leg from the player without the hearthstone, the arrow with | `Routing/Replan.lua` prices the first leg of both orders as the arrow does, at the job's speed and walking factor (`TravelGraph.FindPath` takes `walkFactor`). The test was right. | `test_skip` 1b (synthetic: master accepts 485 s against 299 s; this branch does not), also under PUC Lua 5.1 |
| 6 | The sync multiplied recorded road traces on every run and rewrote every file | A segment is kept once; a file whose content would not change is not written | `test_progress_keys` 5 |
| 7 | One session on the previous beta and back gave a Classic character every flight path of the account | The character's set starts empty again when the build that ran last was 0.x or 1.x (it leaves its version in `luaErrorsVersion`) | `test_offline` |
| 8 | Real profiles keep a live window of 10; only 12 was converted | 10 -> 24 once, with its own marker (`routing.window10`): a build that converts only 12 (the previous beta, the build now installed) sets `window24` and keeps 10 | `test_offline`; the four real profiles read 24 after login |
| 9 | Saved quest locks were never recomputed when the prerequisite data changed | `Core/Skip.lua` stores a signature of the `QuestDeps` strings and recomputes at the first guide load of a session when it differs | `test_skip` |

**What differs from the report.** Finding 2's eight Retail zone guides are not in the build any more (the public
build dropped the gap guides), so on the real files no old mark is carried at all now: 9 logins on the fixed, merged
tree, 0 errors, 0 marks imported, a second login changes nothing. The checks of finding 2 are synthetic.

**Left by the interrupted first fixer and corrected here.** Its tests had not been run to green: `test_offline`
stopped at its account section (the alt fixture had no completed quests), `test_progress_keys` had three failing
checks (two tied to a generated guide that has since changed, one expecting no old result table where the fixture
holds one), and `test_skip` failed three "mounting mid-job" checks because the new first-leg price read the live
walking factor.

**Stays open.**
* The three armed live files (above). The fix only helps once this branch is installed.
* The agent's copy in `~/Library/Application Support/CompletionRoute/` is still the August one until `tools/install.sh`
  of this tree runs. The agent was not loaded when checked; its plist is still in `~/Library/LaunchAgents`.
* The import of old marks is still lazy (per guide, when first loaded or listed). A guide re-ordered without getting
  shorter can still put a mark on a step without a quest in the wrong place. A fix needs the import to run for every
  guide with old marks at the first login, through the same path as `Progress.Load` (circuit fold, access prefix).
* The re-plan search still starts from hearth-free costs: an order that is better only because it opens with the
  hearthstone is not looked for. Acceptance is now right.
* The login self-tests (`RunVerify`, `RunFeatureVerify`, the map probe) still run at every login, silently. They write
  only their own result tables. Moving them behind `devRun` needs `tools/collect_verify.py` to stop reading them from
  normal sessions.
* A bulk run that raises in its frame handler leaves `NS.bulkRun` set until `/reload` (further sweeps are refused; the
  saved state is still restored at logout).
* Seen on the way, developer tooling only: the verification quit button is never created, because the login handler
  in `Core/Progress.lua` clears `autoQuitAfter` before the one in `Core/Sweep.lua` reads it.
* `test_progress_keys` skips its downgrade section (commit `b322bb6` is not in this clone) and the baked-order check
  (the bake is running).

**Tests on the merged tree** (`luajit -joff`, each once): `validate_toc` valid; `test_progress_keys` 201 passed, 2
skipped; `test_skip` 342; `test_quest_auto` 1,272; `test_bug_report` 94; `test_offline` passed; `test_load_all` clean;
`test_live_route` 52; `test_parked` 26; `test_flow` 173; `test_step_window` 252; `test_contribute` 31. Under PUC Lua
5.1.5: `test_offline`, `test_skip era` (146) and `test_progress_keys era` (137) pass. `test_route_order` was not run
(the bake is running).


## 2026-11-12: one build (`public-build-only`)

Owner's decision ("i'm building an addon for the general public", "i should only be using the public version"): the
build on his clients must be exactly what a player gets from a public release. Until now his machine ran a dev build
with Questie-derived extras that never shipped. Those are gone. **Offline only: nothing here has run in a real WoW
client.** Branch `public-build-only` (worktree `wt-public`, its own copy of the data; `master` of 2026-11-12 is
merged in), not merged into `master`, not pushed, not installed. The main checkout, the Drive copy and the five
clients still hold the dev build until the steps under *To apply* below are run.

**What "one build" means now.** The six TOCs list only what ships. `tools/install.sh` installs only that and stops on
anything else. The generators write it by default. The bake covers it. The packager's gate passes on it, and a
packaged TOC is the source TOC plus the version stamp.

**Removed from the build**

* `Guides/Imported_Quests_<flavor>_gaps.lua`: guides made from a Questie checkout for quests the wiki has no page for
  (97 Era, 169 TBC, 434 MoP, 207 Retail, 97 Forever guides in the guide list).
* The Questie-derived map points inside the wiki guides (steps that said `(location: Questie data)` or
  `(location: Blizzard data)`). A step the wiki cannot place now names its zone, or has no location and says so.
* `Data/Imported_Entrances.lua` (dungeon doors from Questie). A door is known once the player has walked in, or the
  Retail journal gives it. On the Classic clients a fresh character knows none, and a step inside a dungeon is
  "no route" until then.
* The local build of `Data/QuestDeps_<flavor>.lua` (it also read the gaps guides and the quest lines). The index is
  built from the wiki guides only; a quest-line guide's own `PRE` tags fill in what it lacks (`Core/Skip.lua`).
* Baked route orders for the gaps guides, and every baked order whose guide changed (see *Route orders*).
* The gathering-node import (same reason, added 2026-11-12): `Core/Farm.lua` copied nodes from GatherMate2 and
  Routes at login when they were installed (`profile.farm.autoImport`, `/cr farm import`). The import, its option,
  its command, the in-client check and its test are gone; the nodes the player loots are still recorded and
  `/cr farm export` still works. The dead `/cr import` (it called adapter importers; none is left) went with it.
  Still there, and the owner's call: a lap is priced through Auctionator's public price function when that addon is
  loaded, and the TOCs name TomTom as an optional dependency that no code uses.

**What the owner loses on his own clients** (before = the dev build in `repo/` after the WoW-Pro removal, measured
read-only with the same scanner, label `dev-before-2026-11-11`; after = label `public-2026-11-11`; both in the
worktree's `docs/verification.sqlite`. The evening table below still counted WoW-Pro guides, so its numbers are a
little higher than this "before").

| | era | tbc | mop | retail | forever |
|---|---:|---:|---:|---:|---:|
| Wiki quest guides, before -> after | 139 -> 137 | 183 -> 189 | 335 -> 336 | 811 -> 836 | 146 -> 142 |
| Gaps guides, before -> after | 97 -> 0 | 169 -> 0 | 434 -> 0 | 207 -> 0 | 97 -> 0 |
| Spine (leveling) entries, before -> after | 184 -> 182 | 243 -> 254 | 476 -> 475 | 1,277 -> 1,317 | 193 -> 189 |
| Quests in a guide, before | 3,554 | 5,845 | 16,562 | 33,266 | 3,741 |
| Quests in a guide, after | 3,302 | 5,024 | 11,155 | 32,452 | 3,489 |
| ... of the client's quests | 4,807 | 6,160 | 17,140 | 66,552 | 6,616 |
| Quests lost from the guides | 252 | 821 | 5,407 | 814 | 252 |
| With a map point, before | 3,471 (97.7%) | 5,584 (95.5%) | 15,068 (91.0%) | 26,577 (79.9%) | 3,637 (97.2%) |
| With a map point, after | 2,431 (73.6%) | 3,852 (76.7%) | 8,627 (77.3%) | 24,780 (76.4%) | 2,596 (74.4%) |
| Zone only (no point), before | 43 (1.2%) | 50 (0.9%) | 40 (0.2%) | 3,674 (11.0%) | 59 (1.6%) |
| Zone only (no point), after | 771 (23.3%) | 1,115 (22.2%) | 2,085 (18.7%) | 4,371 (13.5%) | 788 (22.6%) |
| No location at all, before | 40 (1.1%) | 211 (3.6%) | 1,454 (8.8%) | 3,015 (9.1%) | 45 (1.2%) |
| No location at all, after | 100 (3.0%) | 57 (1.1%) | 443 (4.0%) | 3,301 (10.2%) | 105 (3.0%) |
| Wiki-guide steps with a point, before | 88.7% | 91.0% | 94.9% | 74.7% | 87.5% |
| Wiki-guide steps with a point, after | 48.5% | 52.1% | 57.0% | 71.1% | 49.3% |
| Achievements located (point or zone) | - | - | 84.8% -> 84.9% | 82.7% -> 82.7% | - |
| Item-started quests with a located accept, before | 113 / 269 | 194 / 213 | 330 / 418 | 1,051 / 1,458 | 123 / 456 |
| Item-started quests with a located accept, after | 101 / 269 | 179 / 213 | 267 / 418 | 1,034 / 1,458 | 111 / 456 |
| ... of those, the accept has a map point (not only a zone), before -> after | 71 -> 32 | 133 -> 68 | 251 -> 98 | 415 -> 304 | 71 -> 32 |
| Generated data this client loads, MB | 2.18 -> 1.83 | 3.21 -> 2.74 | 9.18 -> 7.42 | 31.35 -> 31.21 | 2.28 -> 1.93 |

In words: a quest counts as "with a map point" when at least one of its steps has one. On the three Classic-era
clients about one covered quest in four now has no point on any step (the arrow goes to the zone, not to the NPC), and
about half of all wiki-guide steps have no point. MoP Classic also loses a third of its covered quests (the wiki has
no page for them). Retail changes least, because Blizzard's own quest pins ship. Percentages are of the covered
quests; step shares are `wiki_point_sources` (the gaps guides' own steps are not in the "before" step share).

**Route orders: almost nothing is baked until the rebake.** A baked order applies only while its guide's step count
and checksum match, and the checksum covers each step's zone and first point. Removing the fallback points changed
nearly every wiki guide. `Data/RouteOrder_<flavor>.lua` in the worktree was rewritten by the optimizer's write-only
mode (`optimize_routes.py --merge --current`, on a scratch copy of the result rows) and now holds only rows that still
match a shipped guide: era 1 (was 123, 36 of them gaps guides), tbc 0 (227, 93), mop 0 (501, 217), retail 4 (854,
159), forever 2 (130, 47). No row for a guide that no longer exists, no stale row; `test_route_order` passes and
reports tbc and mop as NOT BAKED. Until `tools/bake_resume.py` runs, every other guide plays in author order with
the live window. Its dry run (list mode, against a scratch copy of the result rows) counts 1,611 of the 1,640 wiki
guides to do: tbc 183, forever 131, era 132, mop 334, retail 831. The 7 kept rows (`wiki:era:1421:Both`,
`wiki:retail:1408:Alliance`, `wiki:retail:1408:Horde`, `wiki:retail:588:Horde`, `wiki:retail:630:Alliance`,
`wiki:forever:1421:Both`, `wiki:forever:2521:Both`) were solved while the entrance seeds were still loaded; pass
them in `--force-file` to solve them again. No bake was run here.

**Code and tools**

* Addon: six TOCs (two lines out of each), `Core/Instances.lua` (no seeded doors), `Core/Skip.lua` (the index
  families), `Core/Farm.lua`, `Core/Init.lua`, `Core/Slash.lua` (the import), comments.
* `tools/wiki/gen_wiki_guides.py` writes the build by default (`--no-fallback` is accepted and ignored).
  `tools/gen_quest_deps.py` reads the wiki guides only. `tools/gen_completion_guides.py` stops on a wiki file that
  still holds another addon's points, and the quest-line file now repeats the wiki file's header line that names
  the Blizzard quest-pin tables and their client build (the gate asked for it).
* A generator fix the change exposed. Without the fallback points, two `test_wiki` checks failed: a step with no
  wiki point took the quest-log category because the NPC page's lead linked that zone for another reason (Archmage
  Malin "sent" agents to Arathi; Vivian Lagrave's lead names where she stands today). On Era, TBC and Forever a
  lead link now counts only in a sentence that says the NPC is there, and not at all when the page says the NPC
  stood elsewhere before the Cataclysm. MoP and Retail are unchanged (tried there, the same rule changed 60 Retail step
  lines, many to a wrong zone). 18 Era, 41 TBC and 18 Forever step lines name another zone; most are now the NPC's city
  (Undercity, Thunder Bluff, Shattrath, Kargath's Badlands). **Known wrong after it:** quests 6402 and 6403 (Reginald
  Windsor: now Blackrock Depths, should be Stormwind), 1450 (Falstad Wildhammer: now Ironforge, should be the
  Hinterlands) and 661 (Phin Odelic: Silverpine Forest, should be Hillsbrad; it was Arathi before, also wrong).
* One explicit offline comparison is kept: `gen_wiki_guides.py --measure-fallback` reads the older Questie-derived
  files from `tools/measure/questie/` and writes only `tools/measure/out/` (`tools/measure/README.md`). It can never
  be installed or loaded.
* The tools that read a Questie checkout are in `archive/questie-tooling/` (README there).
* `tools/install.sh`, `tools/validate_toc.lua` and the packager each refuse a file outside the build.
  `tools/cost_matrix.lua` and `tools/bake_resume.py` load and bake only shipped guides.
* `tools/coverage.py` measures the build only (new row `quest-zone`: covered quests with a zone but no point);
  `tools/status_report.py` shows `zone only` and `no location`.
* Merged from `master`: the step window, Recent, Start over, auto-advance, Contribute and the new pointer. Their
  tools read the TOCs, so only `tools/guide_walk.lua` (a gaps family) and sample notes in two tests changed.

**Results on the regenerated data (2026-11-12, each run once through `heavy.sh`)**

* Data regenerated with the default options in the documented order (`gen_wiki_guides.py`, `gen_gold.py`,
  `gen_professions.py`, `gen_completion_guides.py retail mop`, `gen_quest_deps.py`); no fetch was needed. A second
  run gave byte-identical files except the gold guides: `gen_gold.py` listed the nodes of a zone in a set's order,
  which changes from run to run (20 to 42 step lines per client). **Fixed in the independent check below:** ties go
  by name, and two runs in a row now give identical gold files.
* Gate: `python3 tools/package_release.py` (dry run) **passes**, exit 0, no problem and no stale-row note. 106 files,
  universal zip 7.13 MB. The packaged TOCs differ from the source TOCs by the `## Version` line only.
* Tests, all pass: `validate_toc`, the 22 `tools/test_*.lua` harnesses (`test_flow` 167 checks, `test_step_window`
  252, `test_quest_auto` 1,272, `test_skip` 332), `test_package.py`, and the 8 unit tests of
  `test_ingest_beta_reports.py` and `test_bake_gate.py`. The known `test_skip` failure
  (`forever wiki:forever:1423:Alliance`) is not in the run any more: the harness picks its cases from the
  regenerated guides and that one is not among them. The pricing difference behind it was not looked at, so it is
  hidden, not fixed.
* `tools/install.sh` was run against a scratch folder only: five clients install, and a planted `_gaps` file,
  `Imported_Quests_era.lua`, `Data/Imported_Entrances.lua`, an unknown `Imported_*` name and a `RouteOrder` of a
  flavor no client has each stop it before anything is copied. (At that point it still copied each client only its
  own flavor's data, 3.5 to 32 MB; see the independent check for what it installs now.)
* `tools/census_step_kinds.lua` and `tools/audit_step_text.lua` run on the build (Era now 11,898 steps in 331 guides).
* Not done: nothing was installed, merged, pushed or baked; the companion app was not rebuilt (one sentence of its
  About text changed in `app/main.swift`). The saved-progress effect of the removed guides was tested afterwards
  (independent check below).

**Independent check (2026-11-12, second pass on the same branch; offline only, nothing ran in a real client)**

A second agent re-checked the work above in `wt-public` and fixed what it confirmed (the commits from
`f5a0b3f` on).

* **Content.** Every file the six TOCs and `Guides.xml` load (88 files, plus the library file one XML includes) was searched, the regenerated data
  included: no `(location: Questie data)` or `(location: Blizzard data)` note, no `qdb:` or `qpoi:` id, no `_gaps`,
  `Imported_Quests` or `Imported_Entrances` reference, no reference in addon code to a file that is gone. The one hit
  is the comment in `Core/Farm.lua` that says the import was removed. The five `QuestDeps` headers say "Sources:
  Warcraft Wiki only". The location notes that remain are `Blizzard quest POI` (53,432 step lines in the Retail wiki and quest-line files; wago.tools
  tables named in each file's header) and `the wiki's <place> page`.
* **The data is what the generators write.** All five generators were run once more with the default options on
  the final code: the 19 non-gold files and 5 `QuestDeps` files came out byte for byte as they were. The gold files
  did not, because of the set order above; that is fixed (`gen_gold.py`, ties by name) and two further runs gave
  identical gold files. The gold files in the worktree are from that fixed generator.
* **Installed = packaged.** It was not: `install.sh` copied each client only its own flavor's data (72 to 78 files
  per client), the release zip holds 106, and a per-client zip 69 to 74 (no other client's TOC, no file its own TOC
  does not list). `install.sh` now copies the whole folder. Each of the five scratch client folders (103 files,
  45 MB) differs from the staged universal package by nine things: `LICENSE.txt`, `ATTRIBUTION.md`, `README.md`
  (written by the packager) and the `## Version` line of the six TOCs. `install.sh` also stops on a `RouteOrder`
  file that still holds `qdb:` / `qpoi:` rows (the main checkout's files hold 36 to 217 of them until they are
  rewritten). All its refusals were re-run on a scratch copy of the source: `_gaps`, `Imported_Quests_era`,
  `Imported_Entrances`, `Imported_Storylines`, an unknown family, a flavor no client has, a symlink, a Questie note
  inside a wiki file, an unknown adapter; each exits 1 with nothing copied.
* **Gate.** `heavy.sh python3 -B tools/package_release.py --tmp <scratch> --stage-dir <scratch>` on commit
  `c381177`: `packaged 106 files`, universal zip 7.13 MB, `GATE: PASS`, exit 0, no problem, no stale-row note.
* **Tests** (once each, through `heavy.sh`): `validate_toc`, the 22 `tools/test_*.lua` harnesses, `test_package.py`
  and the 8 unit tests all pass on `285a00c`; `validate_toc`, the gate, `test_flow` and the nine harnesses that read
  the gold guides or the changed tools were run again on `c381177` and pass. `test_progress_keys`
  passes with 2 checks skipped (no baked order applies to its sample guide; the previous release's commit is not in
  this clone). New in `test_flow` (173 checks): a character whose saved route is gone (`qdb:era:1431:Both`, with
  saved marks) logs in without an error; a fitting leveling route is loaded in its place, or, when none fits, the
  chat says "No route matched your level/faction. /cr routes"; the gone route is not listed under Recent and its
  marks stay in the saved file, unused. Nothing tells the player that the old route was retired.
* **Play-through** (`tools/vplayer.lua`, author order, live window on; 62 guides): 8 wiki quest guides per client
  spread over the level range, plus the largest guide with no located step and the largest with zone-only steps;
  4 achievement guides on MoP; 4 achievement and 4 quest-line guides on Retail. No stall and no addon error in any.
  Two exploration achievement guides (371 and 305 steps) ran into the harness's 90 s limit in the batch; replayed alone they finish every step (53 s and 29 s) with no stall
  and no no-route leg.
  No-route legs: Era 0, TBC 25, MoP 42 (12 in the wiki guides, 30 in the Cataclysm dungeon achievements), Retail 36
  (26 wiki, 2 achievement, 8 quest-line), Forever 0. Every one of the 103 goes into or out of a dungeon, raid or
  arena map: no door is known until the player has walked in (Classic clients) or the journal gives it (Retail).
* **What a guide without points looks like in game** (from the code, not seen in a client). A step that names
  only its zone: the arrow points at the centre of that zone with "(zone only)", or at the same NPC's point from
  another step of the guide, or at the quest's own objective once the quest is in the log; the card says "No
  coordinates on the wiki; the quest is in <zone>". A step with no location at all: no arrow, "no location - /cr
  why", and the card names the NPC only ("From Journeyman Engineer. No coordinates on the wiki."). Worst per client:

  | | era | tbc | mop | retail | forever |
  |---|---|---|---|---|---|
  | Guides with no point on any step (steps in them) | 9 (296) | 12 (182) | 20 (499) | 27 (2,024) | 8 (299) |
  | Guides with a point on under a quarter of their steps | 24 of 137 | 30 of 189 | 41 of 336 | 65 of 836 | 22 of 142 |
  | Guides with a point on under half of their steps | 64 | 83 | 123 | 148 | 62 |
  | Largest guide with no location on any step | `wiki:era:0:Both`, 162 steps | `wiki:tbc:0:Both`, 82 | `wiki:mop:0:Both`, 202 | `wiki:retail:0:Both:2`, 217 | `wiki:forever:0:Both`, 167 |
  | Largest guide with only zone-level steps | `wiki:era:1431:Both`, 12 (3 zone, 9 none) | `wiki:tbc:1431:Both`, 12 | `wiki:mop:245:Alliance`, 61 (all zone) | `wiki:retail:525:Horde:4`, 176 (142 zone, 34 none) | `wiki:forever:1442:Both`, 5 |

  The "Other Quests" guides (zone 0; 3 per client, 6 on Retail; 150 to 968 steps per client) are a plain list:
  every step has no location, and the Era one opens with a developer test quest ("The Pattymac Special"). They were
  like this before the change. The Tol Barad Peninsula guide (MoP, Alliance) is 61 steps that all say "the quest is
  in Tol Barad Peninsula": the arrow sits on the middle of the zone for the whole guide unless the client supplies
  the quest's objective position.
* **Zone-only steps and the wrong zone.** There is a reference to measure against after all: the offline files in
  `tools/measure/questie/` (read by a scratch script, nothing written). Of the zone-only accept and turn-in steps
  that the reference also places, the build names another map on Era 279 of 2,261 (12.3%), TBC 617 of 3,388
  (18.2%), MoP 767 of 5,444 (14.1%), Retail 791 of 2,913 (27.2%; the reference covers only a quarter there). For
  scale, steps that do have a wiki point sit on another map than the reference in 4.2%, 4.0%, 11.6% and 19.0% of
  cases. Much of the difference is a convention, not an error: the build names the dungeon or battleground and
  the reference names the zone of its door (TBC: Zul'Gurub 131, Karazhan 30, Hyjal Summit 16; Era: Alterac Valley
  22, Warsong Gulch 24). Plain wrong zones are in it too: Silverpine Forest for Hillsbrad Foothills (12 steps on Era
  and 12 on TBC; Magistrate Henry Maleb's quests 512 and 523 among them: he stands in Southshore, and the
  generator's own comment uses him as its example), Badlands for Searing Gorge (12), Orgrimmar for Undercity (13 on
  TBC). Not
  fixed here.
* **Also found.** `docs/status_table.txt` (the companion app's Coverage tab reads it) still showed the dev build
  of 2026-11-10 (Era "97.8% located"); it now holds the build's coverage numbers and says that its vplayer and
  route-gain columns are older runs. The apply steps said 26 guide files; there are 24. `tools/sync_progress.lua`
  said `install.sh` runs it; it does not.
* **Left for the owner or a later pass.** (1) `tools/sync_progress.lua` and its launchd agent merge saved progress
  between the owner's clients; a player has no such thing. The agent's plist of 2026-08-20 is in
  `~/Library/LaunchAgents` but is not loaded now. (2) `Core/Farm.lua` prices a lap with Auctionator's public
  function when that addon is loaded, and the TOCs name TomTom as an optional dependency no code uses. (3)
  `docs/vplayer_*.tsv` (tracked) are runs of 2026-11-08 and one still lists retired guide ids. (4) `docs/HANDOFF.md`
  sections 3 to 5 keep their dev-build wording under the head note. (5) The companion app was not rebuilt; it
  calls only `tools/install.sh`, `validate_toc.lua` and five harnesses, all of which exist. (6) CI
  (`.github/workflows/ci.yml`, `release.yml`) runs `validate_toc`, `test_load_all`, `test_offline` and
  `test_package.py`; none names a removed file.

**To apply** (main session; `W=~/Downloads/CompletionistGuide-work`, no heavy job running in `repo/`, `repo/` on
`master` with a clean tree; every generator, harness and packager run goes through `$W/heavy.sh`)

1. `cd $W/repo && /usr/bin/git status --short && /usr/bin/git merge --no-ff public-build-only` (merge locally, as
   always; `master` is an ancestor of the branch, so there is no conflict).
2. Move what is no longer part of the build out of `repo/CompletionRoute` (gitignored, so the merge leaves it; until
   it is gone `install.sh` and the gate refuse the folder):
   `mkdir -p $W/archive/dev-build-2026-11-11/RouteOrder $W/repo/tools/measure/questie`; copy the five
   `Data/RouteOrder_*.lua` into that `RouteOrder/` folder; move the five `Guides/Imported_Quests_<flavor>_gaps.lua`
   and `Data/Imported_Entrances.lua` to `$W/archive/dev-build-2026-11-11/`; move the six
   `Guides/Imported_Quests_<era, tbc, wotlk, cata, mop, retail>.lua` to `repo/tools/measure/questie/`.
3. Generated data. Preferred: regenerate in `repo/` (about 2 minutes; it also refreshes `tools/wiki/wiki.sqlite`,
   the spine sidecars in `tools/wiki/cache/` and the chart tables, which a copy does not):
   `python3 tools/wiki/gen_wiki_guides.py`, `python3 tools/wiki/gen_gold.py`, `python3 tools/wiki/gen_professions.py`,
   `python3 tools/gen_completion_guides.py retail mop`, `python3 tools/gen_quest_deps.py`. Then compare with the
   worktree: `(cd $W/wt-public/CompletionRoute && shasum Guides/Imported_*.lua Data/QuestDeps_*.lua) > <scratch>/want.sha`,
   then `(cd $W/repo/CompletionRoute && shasum -c <scratch>/want.sha)` must say OK for all 29 files (24 guide files,
   5 `QuestDeps`). If a file differs, stop, copy the worktree's files instead (`rsync -a`, no `--delete`) and find out
   why. (Verified in the worktree only: a regeneration there reproduces its files byte for byte. `repo/` has the same
   inputs, but that run has not been made.)
   Route orders: `rsync -a $W/wt-public/CompletionRoute/Data/RouteOrder_*.lua $W/repo/CompletionRoute/Data/` (7 rows
   in all; the old files hold `qdb:` / `qpoi:` rows, which `install.sh` now refuses).
   `cd $W/repo && /usr/bin/git status --short` must print nothing.
4. Chart rows: copy the "before" label, then measure the build:
   `sqlite3 $W/repo/docs/verification.sqlite "attach '$W/wt-public/docs/verification.sqlite' as w; insert or replace
   into coverage select * from w.coverage where label='dev-before-2026-11-11'; insert or replace into
   wiki_point_sources select * from w.wiki_point_sources where build='fallback';"`, then
   `python3 tools/coverage.py --label public-2026-11-11`. `docs/status_table.txt` is already the build's table (tracked).
5. Check in `repo/` (`export CR_TEST_TMP=<scratch folder>` first): `luajit tools/validate_toc.lua`; each
   `tools/test_*.lua` with `luajit -joff`; `python3 tools/test_package.py`; `$W/venv/bin/python -m unittest
   tools/test_ingest_beta_reports.py tools/test_bake_gate.py`; `python3 tools/package_release.py` (expect
   `GATE: PASS`, 106 files).
6. Rebake (about 1,611 of 1,640 guides, gate on): `caffeinate -is $W/heavy.sh python3 tools/bake_resume.py
   --dry-run`, then without `--dry-run`. To re-solve the 7 kept rows as well (they were solved while the door seeds
   were loaded) pass `--force-file <flavor>=<file>` with their ids, one per line. Afterwards `test_route_order`,
   `test_cost_parity` and the gate again, a `vplayer` run per client, `tools/collect_vplayer.py`, and
   `python3 tools/status_report.py > docs/status_table.txt` plus the two note lines if a column is still old.
7. Clients, only those not running (`pgrep -lf 'World of Warcraft.app/Contents/MacOS'`):
   `tools/install.sh _classic_era_ _anniversary_ _classic_ _retail_ _forever_`. Each client folder becomes the whole
   add-on folder (about 45 MB, was 3.5 to 32); `rsync --delete` removes the gaps guides and the door table. Installing
   before the bake ends is fine: guides then play in author order with the live window.
8. Drive copy: copy the tree without `--delete`, then remove there, under `CompletionRoute/`, the 11
   `Guides/Imported_Quests_*` files, `Data/Imported_Entrances.lua` and `Guides/Imported_Storylines_retail.lua` if it
   is still there, and from `tools/` the ten tools that moved to `archive/questie-tooling/`; replace its five
   `Data/RouteOrder_*.lua` with `repo/`'s. Until that is done the app's install from Drive stops with a message
   that names the file. The Drive copy was not looked at from here.
9. Push `master` by hand as usual. When `repo/` holds the data, `/usr/bin/git worktree remove $W/wt-public` frees
   about 800 MB.

## 2026-11-12: readable step window, Recent, Start over, more steps that finish themselves (`recents-restart-autoadvance`)

Owner's four beta requests. Offline only: **nothing here has run in a real WoW client.** Branch
`recents-restart-autoadvance`, not pushed, not merged.

**Step window (`UI/GuideFrame.lua`).** One hierarchy, top to bottom: a single title line (route name, cut with "..."
when long; "step N of M" in its own string so it is never cut; then Contribute and its box, Routes, `...`, close), the
card (action and title, note, one distance line), the travel line. The second button row is gone: Route (now "Reorder
steps: ON/OFF"), Opts and Report live in the `...` menu with Start over. The word **Contribute** is a button that opens
the export window. The arrows hang from the card, so they cannot reach the title or travel line. The card shows the
note without its trailing source note ("(location: ...)", "(zone only ...)", "(wiki: ...)", "(point: ...)",
"(Blizzard ...)") and without wiki asides in sentence form ("(This item drops from ...)", with "(click for more)");
the tooltip and the Details panel show the note whole (`G.CardNote`, guide data untouched). The Details panel now
grows with its text (a fixed 260 let a long note run over its buttons). The travel line may use three lines (was two).
The layout numbers are one table, `GF.L`.

**Text audit (`tools/audit_step_text.lua`, all five TOCs, 351,656 steps).** Width is estimated from character
counts (per-class character widths close to Friz Quadrata, at 17/13/12 pt; stated in the file), so it is good to
about a word per line.

| | era | tbc | mop | retail | forever |
|---|---:|---:|---:|---:|---:|
| Steps | 14,749 | 22,143 | 70,207 | 229,216 | 15,341 |
| Title on 2 lines / 3 lines | 905 / 0 | 1,467 / 0 | 5,029 / 11 | 15,965 / 103 | 913 / 0 |
| Title cut at 3 lines | 0 | 0 | 1 | 10 (23 with 10% wider text) | 0 |
| Note cut at 8 lines, before -> now | 0 -> 0 | 0 -> 0 | 2 -> 0 | 8 -> 0 | 0 -> 0 |
| Notes of 3 lines or more, before -> now | 512 -> 484 | 679 -> 625 | 1,707 -> 1,254 | 2,721 -> 1,154 | 519 -> 483 |
| Source notes and asides moved off the card | 5,556 | 8,430 | 25,153 | 95,136 | 5,575 |
| Notes with raw markup left | 0 | 0 | 3 | 5 | 0 |

The 11 cut titles are achievement descriptions of 140 to 191 characters; they end in "..." and are whole in the
tooltip and Details. The markup left is quest-text placeholders (`<NAME>`, `<NPC>`, `<Tracking Achievement>`, one
broken `}}`); a wiki external link in a note now reads as its label. The travel line cannot be enumerated offline
(live routing): sized by shape, a three-leg route with long flight-master names needs 3 lines (4 on Retail, cut).
**Pixel overlap cannot be verified offline**; `tools/test_step_window.lua` (222 checks) holds the code to the rules
that prevent it (widths set before heights are read, no fixed text heights, the note's anchor follows the title's
height, the card ends above the travel line, the title line is one chain) on a widget mock, at scale 0.6, 1 and 2.5
(the whole window scales, so the layout is the same).

**Recent (`UI/GuideMenu.lua`, `P.RecentList`).** The routes list opens with **Recent**, above "For level N": the
routes this character has finished at least one step in, most recently used first, 12 rows at most, each with its
progress, click to load. Hidden when empty. Built from `CompletionRouteCharDB.recent` (at most 30 records: sequence,
time, step total), so it parses no guide and survives `/reload`. A route goes to the top when the player picks it or
finishes a step in it; the chain walking through finished routes at login does not count. First run: seeded from the
routes that already have marks, most marks first. The list window's title now reads "Routes (N)".

**Start over (`P.StartOver`, `P.Reset`).** A route with no step left shows a **Start over** button under its end
text; the card's right-click menu and the `...` menu offer it at any time and ask first while steps are left. It
clears the route's marks for this character and returns to step one; what the game reports as done ticks again.
`/cr reset` is the same code and now also clears the event flags on steps (a "set hearth" step used to finish itself
again after a reset). Circuits still lap by themselves.

**Auto-advance.** Census first (`tools/census_step_kinds.lua`): of the steps the five TOCs load, these finish by
themselves, and from what.

| family | steps | by themselves | how | manual |
|---|---:|---:|---|---|
| Wiki quest guides (spine reuses them) | 156,337 | 100% | quest log: accept, objectives, turn-in | 0 |
| Quest lines (Retail) | 73,088 | 100% | quest log | 0 |
| Achievements (MoP, Retail) | 69,548 | 100% | achievement or criterion earned; quest log | 0 |
| Gold | 13,414 | 92.8% | G waypoint arrival 11,855; R/D arrival 505; quest log 92 | 962 `N` advice notes ("Sell or cook the catch", the Methods lists): nothing to read |
| Professions | 1,365 | 99.3% | skill reached, recipe learned, items in bags, arrival, quest log | 10 `N` notes ("Get a Fishing Pole", "Way of the Grill") |
| Missions (Retail) | 2,590 | 100%, was 0.2% | **new:** mission success event 2,584; arrival 6 | 0 |
| Hand-written leveling | 264 | 100% | quest log, arrival, hearth bound; **new:** merchant window (4) | 0 |
| Quest gaps (local only) | 35,050 | 100% | quest log | 0 |

So the shipped guides were already automatic except advice notes and missions. The new rules (all in
`docs/GUIDE_FORMAT.md`, "What completes a step by itself"; predicates in `NS.StepSignal`, `Core/Guide.lua`):
talking to the NPC a step names (`N`/`R` steps without a quest; `T` tag, `ALT` names, "From X." / "To X.", "Talk to
X" / "Speak with X"; whole name, any case; only the step on screen; never a secret name; one step per conversation); a
merchant window on a repair/sell step; `L` items on every action but accept and turn-in (with a quest id only while on the quest); a buy
step that names its item with `U`/`ITEM`; standing at any of an `R` step's `ALT` places; loot taken at a treasure's
spot; a mission's success. Left manual on purpose: advice notes, a buy or train step that only names the vendor, a
kill step's target, a treasure with no spot.
**Open:** the census says quest steps finish from the quest log, so if steps did not advance in play, a rule that
exists is failing in the client and cannot be seen offline. A bug report (`...` > Report a bug) on one such step
would show which.

**Tests.** New: `tools/test_step_window.lua` (222), `tools/test_flow.lua` (117). `validate_toc` and the twelve
harnesses of the task list pass (`test_progress_keys` needed Recent to stop rewriting an unchanged record).
**Look at first in the client:** the title line (does the route name get enough room next to "step N of M"); a
wrapped title with a long note; the `...` menu; the word Contribute; Start over on a finished fishing or profession
route; Recent after a `/reload`.


**Independent check, same day (commits after `be4b634`).** Everything below is offline too.
* *Auto-advance, rules tightened.* (1) **One conversation finishes one step**: a single click on an NPC fires
  `GOSSIP_SHOW` and `PLAYER_INTERACTION_MANAGER_FRAME_SHOW` for the same window (both events are in all four Blizzard
  UI sources), so two steps in a row naming the same NPC both went at once; the same happened to "talk to" a merchant
  right after a sell step. Now the same NPC finishes nothing more until its windows have been closed for two seconds.
  (2) "Talk to X" / "Speak with X" / "From X." / "To X." name X only when they are the whole instruction: words in
  the middle of a note, a second sentence, "and ...", ", then ..." leave the step manual. (3) A treasure step needs
  loot from a **game object** (`GetLootSourceInfo`), not a corpse looted beside the chest and not a fishing catch.
  (4) A step titled only "Repair" needs a merchant who repairs (`CanMerchantRepair`). (5) The quest panes are read
  through `"questnpc"` when `"npc"` is empty (Blizzard's quest frame uses that token).
* *API sources.* Events and payloads were checked against the generated API documentation in
  `Gethe/wow-ui-source`, branches `live` (12.1.5), `classic_era` (1.15.9), `classic_anniversary` (2.5.6) and `classic`
  (5.5.4): every window, close and loot event used is in all four; `GARRISON_MISSION_COMPLETE_RESPONSE` (missionID,
  canComplete, success, ...) is in `live` only and is not registered elsewhere (guarded). `CanMerchantRepair` and
  `IsFishingLoot` are called by Blizzard's own merchant and loot frames on all four; `GetLootSourceInfo` is listed
  for all five clients on warcraft.wiki.gg. **Not verified anywhere: WoW Forever** (no public source), and whether
  `UnitName("npc")` is filled in the quest panes (hence the `"questnpc"` fallback).
* *Recent.* The list no longer counts marks to decide what to show (one table read per saved record; a route with
  thousands of finished steps costs the same as one with two). A saved record whose route is gone from the data is
  passed over and ages out; the table stays at 30 records.
* *Step window.* At the largest text size with "re-planning..." showing, the room for the route name came out
  negative (a string anchored right-of-left is drawn over its neighbour): now "re-planning..." gives way first, then
  the name is hidden (it is in the line's tooltip), and the step count is cut last. The menus and the Start over
  question are clamped to the screen. In the end-of-route state the hidden card (the arrows hang from it) goes back to
  its plain place. A sentence in brackets is taken off the card only in a long note (over 150 characters); the
  audit table above is the re-run with that (notes of 3 lines or more: 6,138 before, 4,000 now; none cut at 8).
* *Click path back.* The x used to leave no way to show the window again without `/cr`. The options page
  (Esc > Options > AddOns > CompletionRoute) now has **Show step window** and **Routes**, and closing prints where.
* *Start over* was checked against another route's and another character's marks (untouched) and circuits (still lap).
* Still open: a herb or ore node looted within 25 yd of a treasure's spot would finish that step (no shipped guide
  has such a step); a finished quest route chains to the next route at once, so its end screen and Start over button
  are only seen on gold, profession and other side routes; no minimap button.

## 2026-11-11 night: Contribute (players build the location database)

Owner's request. A **Contribute** tick box on the guide window, left of Guides. While ticked, `Core/Contribute.lua`
notes the player's map position on quest accept and turn-in (client events), on objective ticks of the guide's next
steps, and on the forward arrow; clusters the samples into the most likely areas per step; `Router.StepWorld` uses the
heaviest area for a step with no point ("learned spot"); the current step's areas are drawn on the world map as
circles. No names or times are stored, nothing is sent; `/cr contribute export` gives a text to share. Details and
what is not built (merging contributions into the shipped data): [CONTRIBUTE.md](CONTRIBUTE.md).
Tests: new `tools/test_contribute.lua` (31 checks) and the touched harnesses pass. Not run in a client: the tick box,
the map circles and the export window are the parts most likely to need a beta report.


## 2026-11-11 night: no other addon's guides

Owner's decision: the addon is for the public, so it cannot depend on guides from another addon installed on the
player's machine. Removed: `Adapters/WoWPro.lua`, the `Imported_WoWPro_*` lines of all six TOCs, the optional
dependency, the installer's allowlist entry, and every tool and test that loaded those guides. The local export files
were deleted from the checkout, the Drive copy and the five clients. Each client lost 60 (Era, TBC, Forever), 123 (MoP)
or 418 (Retail) guides from its list, including the only Dailies guides; leveling now rests on the wiki-built chain
alone. Sections below that mention WoW-Pro describe the state before this change. The release packager still refuses
such a file if one is left in a checkout. Offline only; every harness passes except the known `test_skip` and
`test_route_order` items.


## 2026-11-11 evening: one tree, regenerated data, pre-merge review

Offline only. **Nothing here has run in a real WoW client.** Branch `integration` (in `repo/`), not pushed.

* **Merged:** `coverage-ach` and `coverage-prof` (their sections are below) on top of the nine feature branches. The
  generator conflicts (`tools/wiki/gen_wiki_guides.py`, `fetch_titles.py`) keep both sides' rules. One bug only showed
  with both together: item pages that name each other as sources made `entity_maps` recurse for ever (fixed).
* **Data regenerated in `repo/`** with the merged generators (wiki caches of both worktrees merged, no refetch beyond 4
  requests): wiki guides, spine, professions, gold, achievements, quest lines, missions, quest prerequisites. The old
  `Imported_Storylines_retail.lua` is in `~/Downloads/CompletionistGuide-work/archive/storylines-2026-11-11/`.

| | era | tbc | mop | retail | forever |
|---|---:|---:|---:|---:|---:|
| Quest guides (all guides) | 139 (184) | 183 (243) | 335 (476) | 811 (1,277) | 146 (193) |
| Quests covered, of the client's | 3,565 / 4,807 | 5,845 / 6,160 | 16,562 / 17,140 | 34,266 / 66,552 | 3,752 / 6,616 |
| Covered quests with a located step | 97.8% | 95.7% | 91.2% | 85.1% | 97.4% |
| Achievements located (point or zone) | - | - | 84.8% | 82.8% | - |
| Item-started quests with a located accept | 113 / 269 | 194 / 213 | 330 / 418 | 1,062 / 1,458 | 123 / 456 |

  (dev build = what the TOCs load on this Mac, label `integration-2026-11-11` in `docs/verification.sqlite`. The
  release-only shares are lower; see the two coverage sections below.)
* **Tests on the regenerated data:** every harness passes (18 Lua harnesses, `validate_toc`, `test_package.py`, the
  ingest and bake-gate unit tests) except:
  * `test_route_order`: red by design until the rebake below ends (checksum v2 made every old row stale).
  * `test_skip`, 1 of 332: `forever wiki:forever:1423:Alliance (drop 5246)`, "an accepted re-plan beats the margin".
    The re-planner prices the route before its re-plan at 4,163 s and the test at 3,360 s; both price the new route at
    3,301 s, so the route is not slower, but by the test's measure the gain (58 s) is under the 208 s margin.
    **Open:** find which leg the two price differently (`Routing/Replan.lua routeCost` against `tools/test_skip.lua
    routeCost`).
* **Pre-merge review of the merged tree.** Three lenses were started; a usage limit cut two of them off three times.
  * *Real-client API lens: finished.* Its findings are fixed in commit `529bc89`: the arrow frame is protected (its
    secure buttons make it so) and was shown/hidden in combat, which both the Forever and the MoP client had already
    recorded as `ADDON_ACTION_BLOCKED`; Retail 12.x secret values (cooldowns, NPC names and GUIDs, unit speed) were
    compared as plain numbers; the Retail TOC listed interface numbers that do not exist (now 120105); the item
    tooltip line never fired on TBC Anniversary and MoP Classic; the main options page ran off the Settings window.
    It also confirmed: every event registration is pcall-guarded, every global the addon reads exists or is guarded on
    all five clients, no protected function is called by addon code.
  * *Plain Lua 5.1 lens: cut off, but its runs were kept.* Under a real PUC Lua 5.1.5 (the client's interpreter) every
    harness passed on `integration` at `2a40df8`, including the coroutine re-planner. Measured cost under 5.1: the guide
    list's completion scan took 30-60 ms a frame (p95 127 ms MoP, 211 ms Retail; one Retail achievement guide of
    102,672 steps took 1.4 s). Fixed: the scan has a 4 ms per-frame budget, and the regenerated Retail achievement file
    is 6.6 MB instead of 17 MB. **Not re-measured after the fix.** Live window refresh 3-6 ms, login work under 100 ms.
    The Lua 5.1 binary and scripts are session scratch (not kept).
  * *Saved-progress and cross-feature lens: not done.* Still worth doing: upgrade from the previous beta's saved
    variables, a second character, a second client through the sync, a regenerated guide between sessions.
* **Not verified in a client and most likely to need a beta report:** the arrow's combat behaviour (it now stays as it
  is during a fight and updates after), teleport buttons, auto accept / turn-in, the scrolling options page.
* **Rebake (gate on): paused at 895 of 2,618 guides** when the Mac's disk reached the 8 GB floor (not this project's
  files). Done: tbc 352 (227 baked orders kept), forever 243 (130 kept), era 200 of 236 (123 kept so far). Not
  started: mop 769, retail 1,018; they play in author order with the live window. The gate rejected 3 to 6 of each
  batch of about 15 baked orders as slower in the simulated player. Resume: HANDOFF, update of 19:00.
* **Published** as PR #4, merged into `master`. **Installed** on Era, TBC, MoP and Retail (not WoW Forever, which was
  running). The Drive copy is not synced yet (disk).


## 2026-11-11: Coverage push A: achievements, item-started quests, storylines (`coverage-ach`)

Offline only. **Nothing here has run in a real WoW client.** Not merged, not installed. Sources: Warcraft Wiki and
Blizzard client tables only; no Questie, WoW-Pro or other data was used to build anything (Questie-derived local files
were read only by `coverage.py` to measure the TOC set below).

**Review fixes (same day).** An independent review found that the first pass placed many steps at the wrong spot:
topic pages (Tailoring, Abundance, Noblegarden, Cataclysm) and zone pages' "geography" rows (the Silithus page's
road to Un'Goro, the Hellfire Peninsula page's Exodar portal) used as points; glyphs at area-overlay centres (median
539 yd off) or inside dungeons; same-name NPCs elsewhere (Fiona in Boralus); "Dalaran" on uiMap 41 (Deadwind Pass);
Midnight content on the old Eversong Woods / Silvermoon maps; no source on wiki-derived rows. All fixed, numbers
re-measured below. The first pass reported retail 83.4% / mop 85.9%; those numbers counted the wrong places.

Two measurements, both in `docs/verification.sqlite` (`coverage`, `coverage_ach_types`, `item_quests`):
**ship** = what a release loads (`coverage.py --shippable` on real `gen_wiki_guides.py --no-fallback` builds; labels
`cov-before-ship-nf` (old code), `cov-fix-ship` (this branch)), **TOC** = what the TOCs load on Daniel's machine
(fallback points, gaps guides, WoW-Pro; labels `cov-before`, `cov-fix`). `cov-after*` are the first pass.

| | before (ship) | after (ship) | before (TOC) | after (TOC) |
|---|---:|---:|---:|---:|
| retail achievements located | 42.0% | **82.6%** | 43.1% | 82.7% |
| mop achievements located | 68.8% | **84.8%** | 68.4% | 84.8% |
| retail storylines covered / every quest has a point | 1,251 / 505 of 1,653 | 1,653 / 1,492 | 1,652 / 1,527 | 1,653 / 1,526 |
| retail storyline quests with a point | 11,024 of 17,991 | 17,246 | 17,299 | 17,298 |
| item-started quests, accept step point + zone-only: era | 21 + 0 of 269 | 32 + 28 | 74 + 2 | 73 + 3 |
| tbc | 37 + 0 of 213 | 68 + 75 | 132 + 0 | 134 + 28 |
| mop | 54 + 0 of 418 | 95 + 95 | 244 + 0 | 251 + 8 |
| retail | 195 + 0 of 1,458 | 293 + 335 | 498 + 7 | 542 + 212 |
| forever | 22 + 0 of 456 | 32 + 29 | 74 + 2 | 73 + 4 |

* **The metric** (the plan's 80% target): achievements with a point or a zone-only step / (achievements minus
  non-geographic ones). Internal rows (title or description marked DNT, `<DND>`, `<Hidden>`, Hidden Tracking, "char
  specific hidden copy") are left out of the guides and of both universes: retail 813, mop 17. Retail ship: point
  1,184 → 2,856, zone-only 2,378 → 4,200, non-geographic 2,725 → 2,665, neither 4,924 → 1,490 (of 11,211). mop: 315 →
  350, 1,059 → 1,353, 1,091 → 1,081, 624 → 305 (of 3,089). `status_report.py` shows it (`--label`).
* **Retail reaches 80% only with the achievement wiki-page source: 76.3% without it (mop 81.2%).** That source now
  takes only links the title or description names, never a topic page, a zone's page only as that zone, and a point
  only inside the achievement's zone. Two random samples of 40 of its picks after the fixes found 2 wrong:
  "Traversing the Spheres" (Korthia for Zereth Mortis; fixed) and "Treasure Hunter" (zone-only Tanaan Jungle, which
  its description excludes; not fixed). Retail: 113 point + 424 zone-only achievements rest on it; mop 19 + 54. A
  sample of 32 name-matched criterion points found 1 doubtful (Malfurion in Firelands for "Fireside Chat"; now
  zone-only Molten Front), against about 10 in the first pass.
* **Achievements** (`tools/gen_completion_guides.py`). Criteria located by Blizzard `Criteria.Type`, ship, point /
  zone / none, before → after:

  | type | retail | mop |
  |---|---|---|
  | 27 complete quest | 2,952/1,934/4,550 → 3,673/1,663/4,100 | 571/188/858 → 566/386/665 |
  | 0 kill creature | 902/2,971/1,026 → 891/2,964/1,044 | 237/1,401/179 → 238/1,422/157 |
  | 43 explore area | 275/1,463/52 → **1,754**/36/0 | 170/911/21 → **1,102**/0/0 |
  | 165 dungeon encounter | 31/1,597/439 → 18/2,046/3 | (none) |
  | 71 complete instance | 0/4/67 → 0/71/0 | 4/81/32 → 0/117/0 |
  | 216 dungeon (by name) | 34/59/688 → 62/601/118 | (none) |
  | 158 pet tamer | 775/478/546 → 757/663/379 | 51/2/351 → 51/187/166 |
  | 73 scripted event (delves) | 126/4/467 → 260/134/203 | 0/4/1 → 0/4/1 |
  | 36 own item | 12/0/1,163 → 191/301/683 | 0/0/781 → 97/220/464 |
  | 42 loot item | 6/0/314 → 39/157/124 | 0/0/148 → 23/95/30 |
  | 68 use object | 130/1/236 → 164/12/191 | 70/1/108 → 93/1/85 |
  | 28 spell target | 52/401/906 → 62/461/836 | 19/279/239 → 25/313/199 |
  | all criteria | 5,411/9,496/21,077 → 7,976/9,870/18,090 | 1,182/3,203/7,672 → 2,234/3,243/6,532 |

  Sources: explore = centre of the Blizzard `WorldMapOverlay` hit rectangle (checked against the wiki on Elwynn
  Forest: Northshire Valley 50.4,42.5 vs the wiki's 50.2,42.2); quest = wiki point, else Blizzard `QuestPOI` turn-in pin
  (retail; MoP Classic's QuestPOI has no quest rows), else wiki zone; encounter / instance = `DungeonEncounter.MapID` /
  `Map` → the instance map (zone-only); kill / object / item / NPC-named = wiki NPC, object and item pages; a criterion
  named after a map, or after an area a Blizzard overlay covers alone (`AreaTable` + `WorldMapOverlay`); meta parts
  take their part achievement's one zone. **Rules added by the review:** a zone's wiki page gives only that zone; a
  topic page (every `{{co}}` in a body section) gives nothing; a name-matched page's point must lie in the
  achievement's zone (instance, explore or quests-in zone, else the one zone or orphan map its description or title
  names) and not on a later expansion's map than its category names, else the step is that zone only (Fiona →
  Eastern Plaguelands, Malfurion → Molten Front, Rokhan → Orgrimmar); names that exist twice resolve for the
  achievement's expansion (category words, else the nearest category-named achievement ids, raised to the latest zone
  its text names): Midnight's Eversong Woods / Silvermoon (0 Midnight steps left on maps 94/110, was 137), Legion's
  Dalaran (0 steps on uiMap 41, was 248), Draenor's Shadowmoon Valley; a quest's wiki point on an old copy of a remade
  map gives way to Blizzard's pin. Achievement-level when no criterion has a place, retail ship: glyph wiki lists 70
  points (new table `glyph_points`, 74 glyphs from "Dragon Glyph" and the Dragon Isles "Glyph Hunter" pages; the
  checked 69 lie 0 yd from the wiki's own point, were median 539 yd), single-area overlay centres 13, race courses
  1,395 + 99 zone, the wiki page 113 + 424 zone, a named zone 311, the meta's zone 34 (TWW / Midnight glyphs have no
  wiki coordinates). "Name: <place>" never picks a dungeon for a glyph (10 were sent into instances); a zone-type copy
  of a continent ("Dragon Isles" 2063) is no zone. **Every located step names its source** ("(wiki: <page>)",
  "(Blizzard WorldMapOverlay 941)", "(zone only; Blizzard Map 1004)"). Retail achievements file 5.8 → 6.6 MB.
* **Non-geographic, marked `|NOGEO|reason|`**: feats, PvP, reputation, guild, character, collections,
  battlegrounds/arenas, and achievements whose criteria are only counters (level, skill, quests done, dailies,
  currency, titles, bank slots, reputation, archaeology finds, spells learned, ratings, recipes, pets collected or
  levelled, missions done). Still unlocated (ship): retail 1,490, mop 305: mostly cast-spell (type 29), quest criteria
  whose quest has no wiki page or pin, NPC names the wiki titles differently, Cup races without a course row, metas
  whose parts span zones, and TWW / Midnight glyphs with no wiki point and no single-area overlay.
* **Item-started quests** (`tools/wiki/gen_wiki_guides.py`): the universe is Blizzard `ItemSparse.StartQuestID` in each
  client's QuestV2. The accept goes where the item is obtained (the item page's own coords, else a drop/source page's
  point, else the source zone as zone-only), names the page its point came from, and carries `|U|<item>|`. The arrow
  switches to "Use <item>" only when the item is in the bags **and** the player is within 40 yd of the step's point
  (or the step has no location; `Routing/Router.lua`), so an item looted far from the step's point keeps the arrow on
  travel. **Review fixes:** a zone's page never gives a point (ship steps at a zone page's out-of-zone point: era, tbc,
  mop, forever 0, retail 4, all from other pages that share the spot; first pass 77, 136, 127, 286, 76; integration
  23, 23, 5, 172, 22; retail achievements 19 coincidences, was 113; quest lines 5, was 167), a topic page reached as a
  source gives none; zone sources give zone-only accepts (Salt of Shards: Silithus, was Un'Goro). In the TOC
  (fallback) build, an item page's point gives way to the client's own point when they are over 300 yd apart or on
  another continent: retail steps whose fallback point a wiki point replaced, against integration, C 678 (median
  270 yd, 317 over 300 yd, 79 on another continent) → 345 (median 74 yd, 0 over 300 yd), A 65 → 14, T 15 → 4, none
  over 300 yd. Checking item points against the quest's own zone was tried and dropped: many of a sample of 32
  such points were right (Frozen Ectoplasm from Winterspring for a Tanaris quest). Item pages parsed 15,725 → 25,904. Still not covered (ship): era 33 /
  tbc 8 / mop 14 / retail 66 / forever 233 quests with no wiki quest page, plus membership exclusions (Season of
  Discovery: era 109, forever 85; Classic only, removed). Covered but no location (ship): era 66, tbc 48, mop 115,
  retail 620, forever 76 (no item page, or sources with no point or zone).
* **Storylines** are now `Guides/Imported_QuestLines_retail.lua` (the retail TOC loads it; `story:retail:<id>` ids kept,
  so marks stay): Blizzard QuestLine order, each quest's wiki steps (fallback points dropped), Blizzard QuestPOI pins for
  steps the wiki leaves without one (ship: 23,991 steps), the quest's map as a zone-only accept where nothing else exists
  (ship: 7,618), and "Quest <id>" steps for the 2,345 quests without a wiki page (1,551 with a pin, 794 with no location).
  No Questie data, so no faction or level gates on wiki-less quests (they show for both factions). The file depends on
  the wiki build it reads: made from the default (fallback) build it has other steps (in this build 1,155 step keys only
  there) and its header says so, naming the Questie-derived source, so `package_release.py` refuses it; the same holds
  for the achievement files. A release regenerates both after `gen_wiki_guides.py --no-fallback`. File size 9.0 MB (old
  storylines file 6.1 MB).
* **Side effects.** `wikimaps.py` is coverage-prof's version (Dalaran by expansion), taken verbatim so both branches
  merge cleanly there. Regenerating the wiki guides changes a few guide splits, so baked orders go stale (see HANDOFF
  phase 5: after the merge `test_route_order.lua` lists 5 mop and 34 retail RouteOrder rows naming no guide until the
  rebake). `gen_wiki_guides.py`'s spine split is not byte-stable between two runs (pre-existing). Found, not fixed
  (pre-existing, in `gen_wiki_guides.py`'s NPC row choice): a quest's NPC point can come from another expansion's row
  of the NPC page (Midnight quests at Lor'themar's old Silvermoon spot, BfA micro-hub quests at Halford Wyrmbane's
  Dragonblight spot); the achievement file now skips such quest points on old map copies, the wiki guides keep them.
* **Tests.** All 18 `tools/test_*.lua` (`luajit -joff`; new `test_completion.lua`: the place rules on synthetic rows via
  `gen_completion_guides.py --selfcheck`, and the reviewed defects in the generated files; it fails 12 checks on the
  first-pass files), `validate_toc.lua`, `test_package.py` (2 more checks: achievement and quest-line files made from
  the fallback wiki build fail `interop-derived`) and the ingest unit tests pass. vplayer sample (author order,
  `--guidecap 20`, TOC build): retail 12 storyline + 6 achievement guides, mop 8 achievement + 8 wiki guides with item
  quests, era/tbc/forever 10 wiki guides with item quests each: 0 stalls; 56 of 64 finished, the other 8 are big
  achievement category guides stopped by vplayer's per-guide time cap. no_route steps there are travel-graph gaps
  (Voidstorm and Harandar have no edges) and instance doors.
* **Open:** a client check of zone-only and "Use <item>" accepts, the storyline guides and achievement criteria ticks;
  the unlocated rows above; TWW / Midnight glyph points; the Pandaria Cup; Forever-only item quests (no wiki pages);
  the NPC row choice above.

## 2026-11-11: Coverage workstream B: professions, routes, coordinates, release-ready points (`coverage-prof`)

Offline only. **Nothing here has run in a real WoW client.** Committed on `coverage-prof` (from `integration`), not
merged, not installed. Generated data was rebuilt only in this worktree; the main checkout needs the generators re-run
(docs/HANDOFF.md section 5, Phase 5). Every new data row names its source (wiki page or DB2 table).

* **Retail Cooking tiers** (`tools/wiki/gen_professions.py`, [PROFESSIONS.md](PROFESSIONS.md)). Cause: with no orange
  value in the wiki's recipe box the learn skill fell back to the yellow threshold, so no recipe was usable at skill 1
  and 7 of 12 tiers had no trainer. Now the client's own value comes first (ItemSparse `RequiredSkillRank` of the
  recipe item the wiki names; `MinSkillLineRank` for a recipe the client teaches by itself), then the wiki box, then the
  recipe page's opening sentence; a recipe the wiki gives no source for but whose recipe item the client has is a buy
  step; rows for one class only are skipped; tiers the trainer table leaves empty take trainers from
  `Category:<prof> trainers` (Npcbox point, or the page of the building they stand in). `tools/prof_tiers.py` prints
  the table (`prof_tier_runs`, labels `before-2026-11-11` / `after-2026-11-11`). Retail, reached / cap, trainers:

  | Tier | Before | After |
  |---|---|---|
  | Outland Cooking | no guide | 75 / 75, 4 |
  | Northrend Cooking | 73 / 75, 4 | 75 / 75, 4 |
  | Cataclysm Cooking | 36 / 75, 0 | 75 / 75, 0 |
  | Pandaria Cooking | 22 / 75, 3 | 75 / 75, 3 |
  | Shadowlands Cooking | no guide | 75 / 175, 1 (the client's recipes stop at grey 75; the wiki table says 175) |
  | Kul Tiran / Dragon Isles / Khaz Algar / Midnight Cooking | full, 0 trainers each | full, 3 / 1 / 3 / 1 |
  | Khaz Algar / Midnight Fishing | full, 0 trainers | full, 5 / 5 |
  | Legion, Draenor Cooking; Cataclysm Fishing | full, 0 trainers | unchanged (no located trainer page; Cataclysm has no landmass) |

  Every other profession x tier on all five clients already reached its cap and still does (era/tbc/forever 300/375,
  mop 600, Archaeology 600/950). Their plans changed: recipes the client teaches automatically now count from skill 1
  (era Cooking opens with Charred Wolf Meat), and MoP's Death-Knight-only bandage rows are no longer planned.
* **no_route** (`Data/Transit.lua`, `Data/Access.lua`, cited from the wiki). vplayer on the guides that had routable
  no_route rows in the Nov 7 sweep (mop 19, retail 39 guide parts; same guide build before and after, so only the
  data fix differs): **mop 14 -> 6, retail 57 -> 47** routable (all classes: mop 38 -> 27, retail 116 -> 102; tables
  `noroute_rerun` / `noroute_steps`, labels `routable-before/after-2026-11-11`). The Nov 7 figures were 27 / 62 on
  older guides. Causes and fixes: MoP Classic had no way into Pandaria and no Isle of Thunder chain (new mop-only access
  chains from the quest pages and the "Isle of Thunder" portal camps); no Maelstrom edges (Earthshrine portals to
  Thrall, Aggra's wyvern into Deepholm); no way out of K'aresh (Tazavesh portal to Dornogal). Left: Tol Barad on MoP
  Classic is its own instance (2755) and the wiki gives no point for the Blackstone Span (6 rows); retail Midnight
  (Voidstorm, Slayer's Rise, Naigtal, Val, Ritual Site, the Midnight Isle of Quel'Danas), Argus, the 10.0.7 Forbidden
  Reach and the player-housing zones have no cited exit; one Ashran and one Underrot row.
* **Blasted Lands offset: root cause found.** The transforms are right (the Nethergarde Keep flight master's wiki point
  lands on the Blizzard TaxiNodes position on both maps; regression check in `wikimaps.py`). Patch 4.0.3 redrew the
  map (it now reaches further south), and several pages still carry numbers measured on the Classic map with no
  "(Classic)" tag (Daio the Decrepit 34,50; Kum'isha 52,36), so they were converted as retail numbers and moved
  ~5.5 units. New `tools/wiki/fetch_coord_history.py` reads each page's last revision before 4.0.3 (87 pages, cached):
  a coordinate already there number for number is a Classic-map number (24 in Blasted Lands). Median error of the
  16 era Blasted Lands A/T steps against the local reference (measurement only): **5.54 -> 0.27** map units. What is
  left there are NPCs that moved at the Cataclysm (Quartermaster Lungertz: the wiki has no pre-4.0.3 point).
  Also fixed: "Dalaran" resolved to map 41, a micro map in Deadwind Pass (485 retail wiki steps; Classic drop
  sources too); now the Northrend city, or the Broken Isles one for "Dalaran (Broken Isles)" or a Legion-on page.
* **Release-ready wiki points** (`gen_wiki_guides.py --no-fallback`, the shipped build). Steps with a point,
  before -> after (same inputs; `wiki_point_sources`):

  | Client | Before | After: wiki + client quest POI + wiki place page | Zone-level | None |
  |---|---|---|---|---|
  | era | 3,881 / 9,644 (40.2%) | 4,829 (50.1%): 3,879 + 0 + 950 | 3,113 | 1,702 |
  | tbc | 6,262 / 14,796 (42.3%) | 7,849 (53.0%): 6,260 + 0 + 1,589 | 5,561 | 1,386 |
  | mop | 15,369 / 32,004 (48.0%) | 18,096 (56.5%): 15,369 + 0 + 2,727 | 11,525 | 2,383 |
  | retail | 35,120 / 87,580 (40.1%) | 62,081 (70.9%): 35,122 + 23,989 + 2,970 | 18,569 | 6,930 |
  | forever | 4,210 / 10,177 (41.4%) | 5,175 (50.9%): 4,208 + 0 + 967 | 3,252 | 1,750 |

  Steps that lose their point under `--no-fallback` (dev-build points minus release-build points, before): era 4,727,
  tbc 7,280, mop 15,026, retail 27,847, forever 4,731; recovered with a point: era 948, tbc 1,587, mop 2,727, retail
  26,961, forever 965; most of the rest now name the quest's zone. Shippable quest coverage (`coverage.py --guides` on
  the shipped files only, labels `ship_before` / `ship_after-2026-11-11`), quests with a located step: era 2,115 ->
  2,470, tbc 3,353 -> 3,920, mop 7,775 -> 8,639, retail 18,130 -> 23,375, forever 2,274 -> 2,640. Sources: retail
  `QuestPOIBlob`/`QuestPOIPoint` read directly (turn-in area for T, objective area for C, A only when the wiki names
  the same NPC as giver and ender); the wiki page of the place an NPC page names when it has no point itself
  (`fetch_titles.py` fetched 2,627 such pages); otherwise the quest's zone (`|Z|` only, honest note). Place-page
  points against the local reference (measurement only; release build; era 203, tbc 322, mop 590 steps compared):
  median 81 / 76 / 71 yd, p90 673 / 287 / 443 yd; 54-61% within 100 yd. Retail was not measured usefully (its
  reference is itself a quest pin). The Classic clients have no quest pins.
* **Packager dry run** (release build per RELEASE.md steps 1-2 in this worktree): **gate FAIL, 5 problems, all
  `RouteOrder_<fl>.lua` rows that order Questie-derived `_gaps` guides** (era 56, tbc 101, mop 217, retail 159,
  forever 55; plus stale-row notes). The wiki fallback lines, the old achievements/missions header and the local
  QuestDeps build no longer fail. A rebake over the shipped guides only (RELEASE.md step 3) is still needed.
* **Dev build** (fallback): quests with a located step, `coverage.py` label `dev-after-2026-11-11` against `ach-after`:
  era 3,486 -> 3,488, tbc 5,593 -> 5,596, mop 15,093 -> 15,099, retail 28,730 -> 29,194, forever 3,646 -> 3,659.
* **Tests.** New checks in `test_professions.lua` (tier reach and trainers; fails on the old retail file with 13
  failures), `test_wiki.lua` (zone-level / place / POI tags, no wiki point on map 41, Blasted Lands accepts),
  `wikimaps.py` (TaxiNodes calibration, Classic marks, Dalaran), `test_access.lua` (entries checked only on their
  clients, plus a MoP pass). Full run on 2026-11-11 with the dev build in place (`luajit -joff`): all 17
  `tools/test_*.lua` and `validate_toc.lua` pass (`test_skip.lua` 332/332, `test_quest_auto.lua` 1,272/1,272),
  `tools/test_package.py` passes, `test_ingest_beta_reports.py` 5/5.
* **Open:** nothing in a client; route orders are stale wherever points moved (Blasted Lands, Dalaran, every new POI,
  place and zone-level step); the pre-4.0.3 history was fetched for Blasted Lands only (`--changed-zones` covers every
  redrawn zone, not run); NPCs that moved at the Cataclysm keep their retail point on Classic; the routable no_route
  gaps listed above; Shadowlands Cooking 75-175 and the Legion/Draenor Cooking trainers.

## 2026-11-10: Stable step keys (`stable-step-id`, IDEAS #6)

Offline only. **Nothing here has run in a real WoW client.** Not merged, not installed. Details: [STEP_KEYS.md](STEP_KEYS.md).

* **What changed.** Done, skipped and stepped-back marks are stored by a stable step key instead of the author step
  index: quest steps by action + quest ids + objective, other steps by a 45-bit hash of the title's words (plus
  achievement, recipe, skill and mission ids), repeats numbered in author order, access-chain steps prefixed with their
  chain. Coordinates, zone and note are never part of a key. Keys are built once per parse; parse results and the
  RouteOrder checksum are unchanged. In a regenerated guide (or a WoW-Pro update read at runtime) marks stay on their
  steps through added, removed and moved lines and moved points, with two exceptions: a step whose quest-less title is
  reworded loses its mark (it is not given to another step), and among identical repeated steps (same quest and
  objective, or same words; 2.4-4.0% of steps) adding or removing one ahead of the others shifts their marks to a
  neighbouring identical step.
* **Storage.** New `stepDone` / `stepSkipped` / `stepMeta` in each character record of `CompletionRouteDB.chars`, and
  `stepReopened` in the character file. `stepMeta` keeps the guide's key checksum next to the marks for later
  migrations. The old index tables are read once and kept for one release.
* **Migration.** Once per character and guide, when the guide is loaded or its progress is shown: old index marks are
  mapped with the guide as it is now (the data has not been re-ordered since they were written). Other characters of the
  same game type are migrated too; records from other clients (copied by `tools/sync_progress.lua`) and records without
  a game type on Era/Forever are left to their own client. Access-chain marks and indices with no step are counted, not
  placed. A saved re-plan's rebuild key now binds the step keys; an old-format key is converted once.
* **Everything that reads or writes marks follows:** Progress (done, skip, undo, reopen, reset, laps, auto-complete,
  visible count), Account (scopes, OtherDid, guide %, "finished", roster, sweep scratch), Skip (rebuild, guide list
  view, rebuild key), BugReport (keyed sets, plus `guide.keySum` and the step's `key`), Recommend, `/cr why`, the Back
  button, `tools/vplayer.lua`, `tools/route_sweep.lua`, `tools/vplayer_repro.lua` (report marks put back by key,
  current step found by key when the guide changed), `tools/sync_progress.lua` (unions the new tables). New
  `/cr marks`. Fixed on the way (found by reading the code; no harness drives `/cr sweep`): a route sweep cleared the
  character's real progress for every swept guide, because it wrote to `CompletionRouteCharDB.done`, which stays the
  real table while the sweep's scratch sandbox swaps only the account record's fields.
* **Review fixes (2026-11-11).** (1) A route sweep or `/cr verifyall` re-ran the one-time migration for the logged-in
  character (the sweep's scratch store swaps out its record but not its character file) and put old stepped-back marks
  back, by the current index, onto steps the player had since ticked forward: the logged-in character is no longer
  migrated during a sweep. (2) An alt whose record another character migrated first never got its own stepped-back
  marks (they live in the alt's file): such a record now carries `ro = false` and the alt imports them on its next
  load. (3) The claim that every mark stays on its step was too strong (repeats, above). (4) The migration test now runs
  on a baked guide, as in game. Neither bug touches live data yet: none of the 11 real character files read has a
  stepped-back mark.
* **Tests.** New `tools/test_progress_keys.lua`: 196 checks, all pass on all five flavors (`luajit -joff`, about 15-20 s, 260 MB).
  A guide regenerated with one line inserted, one deleted, one point moved and one block moved keeps ticks, skips, a
  stepped-back step and a quest skip on their steps (the same marks by index would sit on 3 wrong steps); the same on 3
  wiki guides and 1 WoW-Pro guide per flavor; migration from a fixture of today's SavedVariables layout (placeholder
  names) on a baked guide; an alt's stepped-back marks after another character migrated its record; a route sweep through
  the real `Core/Sweep.lua` after the migration, on the same data and after a data update; idempotence; the downgrade, by loading the previous release's own code from git commit `b322bb6` on the new
  files; `tools/sync_progress.lua` on temp files. Key collisions: **0** in 893,834 steps (5 flavors); no two different
  texts share a hash in any guide. Cost (`-joff`): 0.9 microseconds per step on retail, 2.9-7.0% of parse time; the
  largest retail guide (102,672 steps) 0.24 s on a 1.06 s parse. `tools/vplayer.lua` on 15 era and 15 retail guides:
  byte-identical output before and after. Existing harnesses: all pass in the final run (2026-11-11, `test_skip.lua`
  332 of 332). Earlier runs failed `test_skip.lua`'s frame-time checks now and then (1-2 re-plan frames of about
  1,000-3,300 just over 2 ms). They fail the same way without this branch: in two back-to-back
  runs each, the integration head and this branch each failed once and passed once, and the same guide's re-plan took
  189-527 ms of CPU on the head and 212-946 ms on the branch for identical work (moves, pairs, searches). The spread is the
  machine (nice-10 jobs next to other agents' work), not the change.
* **Open:** a client check of `/cr marks` and of progress after the first data update; the previous release in the
  downgrade check is the integration head, the installed beta may be older; sync unions marks, so a reset on one client
  comes back from another client's older copy (as before).

## Auto accept and turn-in (`auto-quest`, 2026-11-10)

IDEAS #7. Offline only. **Nothing here has run in a real WoW client.** Committed on `auto-quest` (from `integration`),
not merged, not installed. Details and the client API matrix: [QUEST_AUTO.md](QUEST_AUTO.md).

* **New `Core/QuestAuto.lua`**, loaded right after `Core/Skip.lua` in all six TOCs (`tools/validate_toc.lua` checks the
  order). Off by default (`autoAccept`, `autoTurnin`; new `autoChooseReward` off and `autoModifier` = Shift).
* **Only the live window:** a quest is accepted or handed in only if a step of it is among the next `routing.window + 5`
  pending steps (`P.order`). Never a quest `/cr skip` dropped or locked, never one whose accept or turn-in step the
  player skipped, never one that costs gold, never a daily, weekly or repeatable unless the step is that daily (`!`, or a
  Dailies / Daily Gold guide). A full quest log is said in one chat line per quest giver. Holding the pause key pauses
  that conversation.
* **Turn-in:** `CompleteQuest()` only when `IsQuestCompletable()`; the reward is taken with 0 or 1 choice. With more it
  stops with one chat line, unless "Auto choose reward" is on and the new `ItemScore.ClearWinner` sees a usable item 10%
  over what it would replace and 1.5x better than the other choices; if any usable choice cannot be weighed, it picks
  nothing.
* **Clients:** `C_GossipInfo` (all five clients, per warcraft.wiki.gg), the old gossip API (none of them; fallback for
  old builds) and the greeting frame, detected at call time. No dialog without a quest giver (popups), no world quests,
  nothing the game auto-accepted. One action per dialog event; no re-pick loop after a decline.
* **UI:** Options > CompletionRoute > **Auto quests** page (three checkboxes and the pause-key dropdown), `/cr auto
  [accept|turnin|reward|on|off|key ...]` in the help line and README; `/cr bug` reports carry the settings and the last
  eight decisions.
* **Review fixes (2026-11-11):**
  * Major, fixed: with "Auto choose reward" on, an empty off hand counted as a +100% upgrade, so a warrior with a
    two-hand weapon offered a shield or a one-hand sword took it over a real upgrade (reproduced: `GetQuestReward 2`,
    "took item:shield ... (+100%)"). New `IS.ChoiceGain` weighs the hands together: a shield or off-hand item is weighed
    against the two-hander it takes off, a one-hand weapon against the main hand (the weaker weapon only for a dual
    wielder holding two weapons), a two-hander against both hands; an empty off hand next to a one-hand weapon, a
    ranged item with nothing in slot 18 (always so on MoP Classic and Retail) or a worn item whose stats cannot be read
    means nothing is picked. New checks: 3 per flavor and API family through the reward dialog, plus 23 direct
    `ChoiceGain`/`ClearWinner` checks (two-hand, sword and board, dual wield, staff caster, ranged, unreadable stats).
  * Minor, fixed: a full log printed one line per window quest at one quest giver (3 lines for 3 quests); now one line
    per quest giver ("Bravo and 2 more"), and the quest text that follows adds none.
  * Minor, fixed: the Retail "ignored quest" flag had no check (breaking it still passed); now two gossip checks.
  * Minor, fixed: merged the current `integration` (commit 22046c3); the 3 text conflicts kept both sides.
  * Minor, fixed: `docs/BETA_REPORTS.md` lists `options.questAuto`.
* **Tests:** new `tools/test_quest_auto.lua`, 1,272 checks on all five flavors x three API families (2026-11-11); 13
  deliberate breakages of the module were each caught on 2026-11-10, and 5 more (ignored flag, empty off hand, shield as
  the weaker hand, unreadable worn stats, per-quest log-full line) on 2026-11-11. All other harnesses, `validate_toc.lua`,
  the ingest unittest and `tools/test_package.py` pass.
  Not this branch: `tools/test_skip.lua`'s two "re-plan frames never over 2 ms" timing checks fail now and then on this
  loaded Mac (route bake running, load average 4 to 13): 5 of 8 runs here (1 to 3 frames over, worst 2.16 to 2.39 ms,
  JIT on; the one `-joff` run passed), and 2 of 3 runs (worst 2.15 and 2.45 ms) with the integration versions of the two
  files this branch changes in its load list (`Core/Init.lua`, `Core/Progress.lua`). The re-planner is untouched.
  2026-11-11 (load average about 2.5): 3 of 4 JIT runs failed one such check (worst 2.20 to 2.48 ms), the `-joff` run
  passed; with the integration versions of those two files, 1 of 2 runs failed (2.29 ms). The review fixes touch
  neither file nor anything `test_skip.lua` loads.
* **CPU** (`luajit -joff`, biggest real wiki guide per flavor): about 0.01 ms per dialog event, 0.06 to 0.36 ms right
  after a quest change; `ClearWinner` with four choices 0.012 ms (max 0.03 ms).
* **Open:** client test of every path; whether game-object quest givers give `UnitGUID("npc")`; quest ids from the
  greeting frame on the classic clients; reward data that arrives late is never chosen.

## 2026-11-10: one cost model and the bake gate (branch `cost-model`, IDEAS #9 then #1)

Offline only. **Nothing here has run in a real WoW client.** Not merged, not installed. Details and every table:
docs/ROUTING.md "One cost model" and "Bake gate and stale-bake check"; docs/VPLAYER.md "Cost model".

**Review fixes (2026-11-11).** A reviewer found one major and five minor problems; all are fixed or documented:
* **Guides with nothing to bake (major).** The planning character had no class, race or profession and, in a guide for
  both factions, no faction tag, so race starting zones, class campaigns and Alliance-only "Both" guides had nothing to
  bake: 89 quest guides, 75 of them with a bake today. Cost model version 2 plans each guide for the character most of
  its located steps are written for (`CostModel.Persona`: faction, then class, race, profession, each at least half).
  Left without a bake: 12 (mop 2, retail 10), all split between many classes. On a 50-guide sample of the changed guides:
  parity 50/50, 30 bakes kept by the gate (24,153 s saved), 10 rejected. Tests: `tools/test_cost_parity.lua` (synthetic
  rules, 5 real guides, no 0 s guide in the sample).
* **Gate for both factions.** The gate plays a real character of the planning character's faction, class and race
  (`vplayer --who gate`); a guide for both factions is played as Alliance and as Horde and must pass both (entries add
  `vah`/`vbh`). Same 20 guides per client: kept / rejected 7/6, 11/2, 11/0, 13/1, 13/2 (era, tbc, mop, retail, forever);
  two bakes are now rejected only for the Horde play.
* **Kill during the gate.** The solves were written only after the gate, so a killed run solved the batch again. They
  are now saved first; a vplayer failure exits 3 with the rows saved. `tools/test_bake_gate.py` (new) and an end-to-end
  kill test prove a restart gates without solving.
* **No hand-copied constants.** The client files read the cost model directly (no fallback literals); the gate limits
  live in `CostModel.GATE_FRAC`/`GATE_ABS`, which the optimizer reads from the rows and test_route_order from the file.
* **Saved quest-skip re-plans reset once** after this update (their key includes the route checksum, and the rebake
  changes the orders anyway): a guide with skipped quests is re-planned once in the background when next opened.
  Documented, not changed.
* **Re-planner CPU, corrected.** Slices keep p50 0.80 ms, p99 0.82-0.89 ms, no frame over 2 ms; but the worst frame with
  the collector running rose from 0.96-0.98 to 1.42-1.47 ms and retail re-plans do more work (+41% CPU on one guide, +24%
  summed over the test's 22 re-plans, all on retail): more blocks under the located rule, and the firm-only second search
  runs more often on retail. Accepted; the earlier "max 1.43 -> 1.46 ms" compared against one outlier run.

* **One cost model.** `Routing/CostModel.lua` (all six TOCs, before the travel graph) owns where a step is priced, the
  no-route cost (1,800 s everywhere; it was 1,800 / 600 / 0), the speed per level band (each leg at the planning level of
  the step it leaves from; the bake used the guide's lowest level), the walking factor (short walks now use the flying
  factor when flying, like the graph) and the offline flight rule. cost_matrix, optimize_routes (through the row's `"cm"`,
  no second copy), StepOrder, Replan, Router.StepWorld and vplayer read it. cost_matrix now uses `Router.TravelRow` instead
  of its own Dijkstra copy.
* **Located rule:** an NPC's point from elsewhere in the guide, else ride along in the zone the route is in, else the new
  zone's centre. Chosen by a hold-out test (`tools/cost_holdout.lua`, 3,000 steps per client): mean error 22-50 s per step,
  against 117-194 s for the zone centre alone and 27-110 s for riding along alone.
* **Parity** (`tools/test_cost_parity.lua`, new): the optimizer's predicted seconds and vplayer's (planning character, no
  live window) agree within 2% per guide: 100 of 100 sample guides with the full solver after one vplayer fix; the
  harness's own 30-guide run: 28 inside, the 2 misses are author orders that break their own prerequisites (qdb gaps
  guides; excused by rule, listed).
* **Predicted against measured** (20 guides per client, warrior, live window off), measured / predicted saving:
  before 0.59 / 0.62 / 0.42 / 0.12 / 0.53 (era, tbc, mop, retail, forever), after 0.63 / 0.76 / 0.88 / 0.60 / 0.67. With
  the live window on, the bake's measured saving went from -1,234 / 2,581 / 1,584 / 307 / 94 s to 2,943 / 4,873 / 3,937 /
  9,067 / 9,073 s.
* **Flight paths offline stay faction-wide.** A level-band rule changed 27 of 64 baked orders; under the client's
  discovered-only rule both bakes beat author order on every client and faction-wide is 0.4% faster overall.
* **vplayer changed:** cost-model walking, no hearth, 1,800 s per unroutable leg, one objective per `|QO|` step,
  `--who plan`, `--route-order`, `--taxi model|band`. Earlier vplayer numbers are not comparable.
* **Optimizer:** PRE now orders every step that names the prerequisite (was: accepts only); objective steps of a quest
  keep author order when one of them would tick by itself.
* **Checksum version 2** (zone + first point in 0.5 % steps) in Core/Guide.lua, cost_matrix and optimize_routes; the three
  agree on all 2,621 quest guides. Every existing baked entry is now stale (era 168, tbc 260, mop 501, retail 854, forever
  170): the game plays those guides in author order with the live window (vplayer: the stale files play second for second
  like author order on 40 sample guides). `tools/test_route_order.lua` **fails** on stale entries until the rebake.
* **Gate:** `optimize_routes.py --gate` keeps a bake only if vplayer finds baked + live no slower than author + live by more
  than max(1%, 30 s); entries carry `va`/`vb`. On the samples it kept 55 of 64 bakes (saves 32,701 s) and rejected 9 (would
  have cost 2,808 s); after the review fixes 55 of 66 (both factions played for guides for both, see above). `tools/bake_resume.py` gates every batch (`--no-gate`), resumes an ungated row without re-solving,
  writes entries only for current guides, and takes `--lua-dir` and `--only-file`.
* **CPU** (`luajit -joff`): the live window got cheaper (warm mean 1.64 -> 1.25 ms era, 1.64 -> 1.18 ms retail); re-plan
  slices keep their budget (p99 0.82-0.89 ms, none over 2 ms) but retail re-plans do more work (see the fixes above).
* **Harnesses:** all pass except `tools/test_route_order.lua` (fails on the stale entries above, by design, until the
  rebake; with `CR_ROUTE_ORDER_DIR` on the gated sample bakes of all five clients it passes) and the JIT-on frame check in
  `tools/test_skip.lua` (one frame of about 1,000 over 2 ms in some runs; the branch base fails it the same way, 1 of 3
  runs; under `luajit -joff`, the client's proxy, both pass with max 1.0-1.5 ms). New: `tools/test_bake_gate.py`
  (`venv/bin/python -m unittest tools/test_bake_gate.py`).
* **Next (orchestrator):** merge, then the full rebake with the gate, then `luajit tools/test_route_order.lua` must pass.
  See docs/HANDOFF.md section 5.

## Skipping quests (`quest-skip`)

Offline only. **Nothing here has run in a real WoW client.** Merged into `integration`, not installed. All 13 existing
harnesses pass, plus the new `tools/test_skip.lua` (542 checks with 6 guides per flavor). A second round fixed what two
reviewers found (below).

* **Skip a quest** from the step details ("Skip quest"), the right-click menu on the step, or `/cr skip [questID]`. If other
  quests need it, a confirmation names them (this guide / other guides, and which ones only this guide loses) and says what
  the guide loses; confirming drops the chain. `/cr unskip <questID|all>`, `/cr skipped`. The per-step Skip on the accept of
  a quest you do not have now drops the quest (it used to leave the turn-in behind); on a turn-in others need it warns.
  Per character, never shared.
* **The guide is rebuilt**, not just routed around: the dropped and locked quests, any quest this guide could then no
  longer offer (its accepts wait on a dropped quest through the guide's own `|PRE|`), and the notes, use-item and travel
  steps that only served them leave the list. Counts and progress follow; ticks are kept by author index; unskip gives back
  the identical list; other guides rebuild when opened; a reload shows the same guide. Checked by dropping every accept
  prerequisite one at a time on wiki, WoW-Pro and storyline guides: nothing stranded.
* **Breadcrumbs never block**, end to end: the index leaves them out, and a guide step that waits on a skipped breadcrumb
  stops waiting (era: skip Eagan Peltskinner, Wolves Across the Border's accept is next).
* **Locks** grow "can still be had" from outside the dropped quest's dependents, so prerequisite cycles go too (retail 82863:
  19 quests, was 1); exact against a whole-index reachability reference on all five clients. Quests for another class, race
  or faction are locked but not named or counted.
* **Re-plan for travel time** in the background (0.8 ms per frame, "re-planning..." in the title): one speed, position and
  graph per job; one Dijkstra per block row instead of one per pair (13-23x faster; retail 122: 3.3 s CPU, was 14.4 s);
  arrow-accurate costs (steps without `|M|` priced at the zone); two starts; kept only when it beats "baked order minus
  removed steps" by the live window's margin on the arrow's route AND does not lengthen the route through the `|M|` steps.
  On 30 sample guides (route orders as baked by 22:17): 7 kept, 2.7% less travel overall, 6 held back because the gain was
  only at zone stand-ins. Frames: max 1.53 ms of 11,993 with the collector running, none over 2 ms.
* **Data:** `tools/gen_quest_deps.py` -> `Data/QuestDeps_<flavor>.lua` (gitignored): hard prerequisites (era 2,163 quests,
  tbc 3,237, mop 9,613, retail 18,071, forever 2,249), freed breadcrumb / optional edges, breadcrumb quests, and quests the
  data never makes obtainable (retail 179).
* **Open:** client test of the popup, right-click menu and frame times; applying a kept order is one normal refresh
  (about 3 ms, the live window's own budget); heavy retail guides still re-plan for up to about 90 s in the background;
  a storyline guide loses the rest of its storyline when one quest of it is dropped (the warning says so). Details in
  `docs/ROUTING.md`, "Skipping quests".

## Beta bug reports: `/cr bug`, `beta_reports`, `vplayer --repro` (`beta-bug-report`)

IDEAS #3, merged into `integration`. Offline only. **Nothing here has run in a real WoW client.** Details: [BETA_REPORTS.md](BETA_REPORTS.md).

* **In game.** `/cr bug [note]` and a **Report** button on the guide window save a snapshot to
  `CompletionRouteDB.bugReports` (newest first, at most 50, about 400 KB; one report about 16 KB, trimmed past that).
  It holds flavor and build, addon version, class, race, level and faction (no character or realm name), the guide
  and step with its raw line and location source, the 8 visible steps, window order and kept plan, done and skipped
  steps and the open steps, the quest states of the guide's quests and of the quests that only gate a step (PRE,
  ACTIVE, AVAILABLE), profession skill for `|P|` and `SKILL` steps, objectives, map, x, y and world position, the
  route legs and arrow advice,
  flight paths, hearth and options, the last 30 log lines and the last Lua error raised inside the addon. Chat
  confirms the id. `/cr bug list` shows the stored ones. New file `Core/BugReport.lua`, loaded right after
  `Core/Init.lua` in all six TOCs.
* **Error hook.** Wraps the client's handler, always calls the previous one and returns its result, keeps only
  errors whose message or stack names this addon's folder in a path (not a bare `CompletionRouteDB`), re-wraps at
  login, counts repeats.
* **Names.** Character and realm names (2 letters or more) are replaced as whole words in the log, the error and the
  note; the note in any letter case.
* **SQL.** `tools/ingest_beta_reports.py` reads every client's SavedVariables through `tools/sv_to_json.lua`
  (sandboxed luajit, read-only) into `beta_reports` (key `id`; triage columns are never overwritten; the account
  folder is stored only as a hash). Run against the five real SavedVariables files into a temp database: all five
  read, 0 reports (none made yet), files unchanged.
* **Replay.** `luajit tools/vplayer.lua --repro <id|latest|file.json> [--check]` (new `tools/vplayer_repro.lua`).
  It restores the quest states, including gate-only quests, and profession skill, and compares the open steps both
  ways: a step open in the client but not offline is a DIFF. Self-test: `--capture` makes a report in the fake world,
  `--repro --check` replays it. MATCH with the same open steps on all five flavors (author order) and on era with
  baked order, with routes of 4 to 8 legs including tram, portal, boat and taxi.
* **Review fixes (same day).** A verifier found that reports left out quests named only by `PRE`/`ACTIVE`/`AVAILABLE`
  (78 of 137 era wiki guides have such steps), so a replay hid a step and still said MATCH; that 2-letter names and a
  lower-case name in the note were not scrubbed; that another addon's error naming `CompletionRouteDB` was kept;
  that the ingest crashed on a missing file; and that "under 1 ms" held only with warm caches. All five fixed, each
  with a regression test.
* **Cost of a click** (`luajit -joff`, virtual player): 0.2 to 0.7 ms when the arrow's path is fresh, also right
  after a graph rebuild (the upcoming list reads the planner's kept costs and never searches). When the arrow's
  path is stale the click runs one route search: 3.7 ms era, 8.2 tbc, 22 mop, 45 retail, 5.7 forever. Largest guide
  (retail, 1950 steps): 11.9 ms. Not measured in a client.
* **Tests.** New `tools/test_bug_report.lua` (93 checks) and `tools/test_ingest_beta_reports.py` (5 tests, fixture
  `tools/fixtures/beta_reports_SavedVariables.lua`). All existing harnesses pass (see the commit for the list).
* **Not done.** The skip-reason menu, an opt-in for the character name, a companion app view, and any in-client run.

## Routing graph: discovered flight paths, turn-in rebuilds, teleports (`routing-graph`)

Offline only. **Nothing here has run in a real WoW client; Daniel beta-tests.** Merged into `integration`, not
installed. All 14 harnesses pass (the 13 below plus the new `tools/test_teleports.lua`), and `tools/check_teleports.py
--fetch --wiki` reports 0 failures. Details: [ROUTING.md](ROUTING.md) "Flight paths", "What changes the graph", "Teleports".

* **Discovered flight paths only (IDEAS #2).** Default flight rule is now `known`: a flight lands only at a flight master
  the character has discovered; it may take off from a new one, and the walk there says "pick up the flight path".
  Per character on Classic Era, TBC Anniversary and MoP Classic; account-wide on Retail and WoW Forever. On first load a
  Classic character's flight paths start empty once (older builds had copied the whole account's set into it) and
  fill again at the next flight-master visit. A profile on the old `faction` default moves to `known` once; Options
  keeps the old rule. **Behaviour change Daniel will see:** a Classic alt walks until it has opened a flight master's map
  on each continent, unless the login harvest (`isUndiscovered == false` from `C_TaxiMap.GetTaxiNodesForMap`) works on
  that client, which is not verified.
* **Which rule the tools use.** The bake (`cost_matrix.lua`) and `route_sweep.lua` are pinned to `faction`, so the bake is
  unchanged (cost_matrix output for one era and one retail guide compared before/after: identical but for run time). `vplayer.lua` has `--taxi all|learn` (default `all`, unchanged). On the 12-guide samples below, `--taxi
  learn` (each guide starts with no flight path) costs era 58,842 -> 75,444 s of travel (+28%) and retail 16,664 ->
  19,083 s (+15%), with 8 and 29 flight paths discovered. The bake gain under `learn` was not re-measured.
* **Turn-ins no longer rebuild the graph (IDEAS #4).** Only the access edges are rebuilt when an access chain's unlock quest
  is turned in; a learned flight path wipes the path cache; a hearth re-bind or a teleport change drops only the costs
  from the player; any other turn-in changes nothing. Measured under `luajit -joff` with the new `vplayer --turnins`
  (12 guides per flavor, before = branch base code via `CR_OVERRIDE`): era handler time per turn-in 9.30 -> 5.24 ms mean
  (p95 47.7 -> 32.5), 95 -> 0 graph builds, whole run 19 -> 5 CPU s; retail 90.4 -> 37.6 ms mean (p95 300 -> 180),
  225 -> 0 builds, whole run 193 -> 43 CPU s. Retail results identical; one era guide differs slightly, explained in
  ROUTING.md. Guides: era `wiki:era:` 1416:Alliance, 1417:Alliance, 1447:Horde, 1428:Both, 1443:Both, 1431:Alliance,
  1423:Alliance, 1448:Both, 1455:Alliance:1, 1450:Both, 1433:Alliance, 1421:Both; retail `wiki:retail:` 648:Both,
  885:Both, 1565:Both:3, 1408:Alliance, 2255:Both:1, 76:Horde:1, 630:Both:4, 15:Horde, 105:Both, 1161:Both, 114:Horde:1,
  646:Both:4.
* **Teleports as router edges (IDEAS #5).** `Data/Teleports.lua`, 73 entries: 30 class spells (every mage teleport per
  faction and expansion, Teleport: Moonglade, Death Gate on MoP Classic), 4 engineering transporters, the Dalaran and
  Garrison hearthstones, 36 Hearthstone stand-ins. Ids, names, reagents, use spells, cooldowns, trinket slots and the
  shared Hearthstone cooldown are checked against each client's DB2; landing points come from Warcraft Wiki coordinates
  (or TaxiNodes) and are recomputed by the test. Used like the hearth: a first leg only when known or owned and usable,
  with at most 15 minutes of cooldown left; never in pairwise costs, so the bake is unchanged. The arrow's secure button
  casts the spell, uses the item, or uses the toy (`type = "toy"`). `/cr teleports` lists them. `cond` now works on
  Transit and Access entries.
* **Fixed on the way:** a combat-queued arrow-button change is replayed with an explicit argument count (it relied on `#`
  of a table with a nil hole); toggling taxi, transit or the flight rule in Options left StepOrder's kept costs stale.
* **Fixed after review (same day):**
  * Turning in "Establish Your Garrison" bumped the one-shot generation but did not re-check what is usable, so the
    Garrison Hearthstone stayed unused until some later bag, spell or toy event. The turn-in now re-checks at once
    (`T.Recheck`), and bumps only when what is offered changed. Test: the `QUEST_TURNED_IN` event alone, with no
    manual re-check, makes the next route to Frostwall use it.
  * `test_live_route.lua` and `test_parked.lua` had silently picked up the new `known` default with no flight paths
    known (walk-only routing). Both now pin the faction rule, as the other harnesses do.
  * Options: comfort mode and the terrain detour slider now wipe the path cache (they changed costs without dropping
    cached paths); the hearth base cost slider now re-prices the from-player costs. The two sliders act only when the
    value really changes, because opening the panel re-sets them. New test drives every cost-changing Options control
    (`test_live_route.lua` section 10); 4 of its checks fail on the old handlers.
  * Engineering transporters carry `profession = 202`, checked against ItemSparse `RequiredSkill` by
    `check_teleports.py`; a character the client says has no Engineering is not offered them.
  * Harness counts now: test_teleports 42 (was 35), test_live_route 52 (was 40), test_parked 26; all 14 pass, and
    `check_teleports.py --wiki` reports 134 entry-client and 73 wiki checks, 0 failures. None of these fixes is on the
    code path of `vplayer.lua` or `cost_matrix.lua` (neither loads `Routing/Teleports.lua` or `UI/Options.lua`), so the
    turn-in measurements above and the bake are unchanged.
* **Not done / unverified:** everything in-game (secure `toy` action, `C_ToyBox.IsToyUsable`, toy cooldowns, Classic
  taxi harvest, landing spots); Zen Pilgrimage, retail Death Gate, Dreamwalk, class halls, Midnight's Teleport:
  Silvermoon City, Ultrasafe Transporter: Mechagon (no landing coordinate on the wiki; DB2 SpellTargetPosition not read
  yet); Orgrimmar's landing point on Classic Era and TBC is the modern city's; engineering malfunctions are
  not priced; the bake and the cost-model rework (IDEAS #9) still use the faction rule.
  Noticed, older than this branch: the return leg of a two-way portal reuses the outbound title ("Take the Orgrimmar
  Portal Room portal to Silithus" when going from Silithus to Orgrimmar).

## Release packager with a data-provenance gate (`release-packager`)

Offline only. **Nothing here has run in a real WoW client, and no build has passed the gate on real data.** No tag, push
or GitHub release was made. All 12 `tools/test_*.lua` harnesses, `validate_toc` and `tools/test_package.py` (97 checks,
Python 3.12 and 3.9) pass.

* **`tools/package_release.py`** ([RELEASE.md](RELEASE.md)) assembles the add-on from the tracked code plus the local
  generated data, limited to what the TOCs load. It writes `provenance.json` (category, licence, source, generator per
  file), `LICENSE.txt`, `ATTRIBUTION.md` and a player README, and stamps the version into the packaged TOCs only. WoW-Pro
  and Questie-derived files never ship and their TOC lines are stripped (19 lines in 6 TOCs). Dry run by default.
* **Layout:** one universal zip (6.06 MB, 43 MB unpacked on today's data) instead of per-client zips (0.56 to 4.07 MB,
  7.27 MB together); each client loads only its own TOC's files. `--layout per-client` still builds them.
* **Gate** fails on: no provenance, WoW-Pro/Questie data (by file, by content, or a baked order row for a gaps guide),
  "do not redistribute", the replaced commercial product's name, personal data (e-mail, home paths, WoW account and
  character names), secrets, any symlink (worktrees: `--allow-checkout-links`), TOC lines with no packaged file, missing
  licence notices. `--db` writes `data_provenance` and `release_gate` tables.
* **Today's local data fails with 13 problems:** the wiki files carry fallback points (`--no-fallback` build needed),
  achievements and missions keep the old header (regenerate), and every `RouteOrder` file orders Questie-derived gaps
  guides (era 56, tbc 101, mop 44, retail 29, forever 55 rows). RELEASE.md lists the steps to a passing build, including
  a rebake inside the staged package; that rebake was smoke-tested on one era guide only.
* The staged package (interop lines stripped) loads clean in `test_load_all.lua` on all six TOCs. Stub load only.
* **Review fixes:** `--write` never deletes or displaces a build. A failing build goes to
  `dist/failed/<version>-<time>/`, a same-version rebuild archives the earlier one, and only the packager's own build
  folders are ever moved, so `--out` is safe anywhere. Per-client zips carry an `ATTRIBUTION.md` listing only their
  files. The secret rule also catches Cerebras, Groq, Hugging Face, xAI, npm and GitLab keys and unquoted
  `api_key=` lines. Personal terms in file names are masked in every report. Edits to the packager or its templates
  make a build `-dirty`. Usage errors exit 2, crashes 3. The player README describes the real guide-window controls.
* Also: CallbackHandler ships its Ace3 licence text; HereBeDragons is BSD as declared upstream (no upstream text);
  `WIKI_DATA_LICENSE.md` lists the Forever wiki and spine files and no longer calls the hand-written guides non-CC BY-SA;
  `release.yml` no longer publishes on a tag (manual run of the gate tests only).
* **Next:** regenerate wiki `--no-fallback`, gold, professions, achievements and missions; rebake route orders in the
  stage; `--write`; Daniel's beta; only then publish by hand.

# Status / handoff (2026-11-09, gold guides, secondary professions, guides by level)

Offline only. **Nothing here has run in a real WoW client; Daniel beta-tests.** Installed on all five clients. All 13 harnesses pass
(`test_offline`, `test_farm`, `test_access`, `test_load_all`, `validate_toc`, `test_wiki`, `test_route_order`, `test_level_list`,
`test_professions_engine`, `test_live_route`, `test_parked`, `test_professions`, `test_gold`).

| | era | tbc | mop | retail | forever |
|---|---:|---:|---:|---:|---:|
| Gold guides | 165 | 204 | 258 | 335 | 168 |
| Profession guides | 24 | 30 | 64 | 78 | 24 |
| Quest guides optimized (bake of 2026-11-10, map fix redone) | 234 of 234 | 354 of 354 | 772 of 772 | 1,021 of 1,021 | 240 of 240 |
| ...of which a baked order is kept (the rest stay in author order) | 168 | 260 | 501 | 854 | 170 |

* **Gold** (`tools/wiki/gen_gold.py`, [GOLD_ROUTES.md](GOLD_ROUTES.md)): realm-independent, no prices shipped. Gathering circuits are still labelled
  coarse because no shippable node database exists; they sharpen as the player records nodes.
* **Professions** (`tools/wiki/gen_professions.py`, `Core/Archaeology.lua`, [PROFESSIONS.md](PROFESSIONS.md)). Weakest area: retail Cooking
  tiers (Pandaria stops at 22 of 75, Cataclysm at 36 of 75; Outland and Shadowlands have no guide).
* **Guides by level** (`Core/Recommend.lua`, `UI/GuideMenu.lua`, `/cr list`, `/cr gold`, `/cr prof`).
* **Map fix.** On era, tbc and forever, wiki points in Badlands, Arathi Highlands, Swamp of Sorrows, Felwood and Teldrassil are Classic-map numbers and
  must not go through the retail-map conversion (`wikimaps.KEEP_NUMBERS`). Blasted Lands still shows a 5.5 unit offset with no clear cause.
* **Achievements** (`tools/gen_completion_guides.py`): point locations mop 202 to 305, retail 803 to 1,521; zone-only mop 1,062, retail 2,375; marked non-geographic
  (`|NOGEO|reason|`) mop 1,108, retail 3,001; still unlocated mop 631, retail 5,127. Plan target of 80% not met.
* **Optimizer stopped at the 2026-11-09 deadline.** Changed guides were redone on era, mop and retail, then spine guides on mop and retail until time ran out.
  Guides touched by the map fix on tbc and forever were not re-optimized. Finish with `tools/cost_matrix.lua` + `tools/optimize_routes.py --merge` on the rest.
* **Public release held.** The rule is that GitHub releases are bug free, and no client has loaded this yet. Companion app is 2.0.0-beta in /Applications.
* **Next:** beta reports from Daniel; finish mop and retail optimizer; achievements; retail Cooking tiers; a bake gate that drops guides vplayer finds slower;
  outleveled parked guides currently return once at the next guide change (kept for completionists, easy to gate on level in `parkedReady`).

# Status / handoff (2026-11-09, routing finish: live window, level-gate revisit, subzone map fixes)

Offline only. Nothing here ran in a client.

* **Level gates.** A guide that runs dry behind `|LVL|` gates is parked and comes back at its level, at the next guide
  transition, then the chain continues from where it was heading (`docs/ROUTING.md`, `tools/test_parked.lua`).
* **Live window (tier B).** The baked order is the baseline, a repair must save `max(15 s, 5%)`, the plan is what the next
  refresh must beat, window 24 steps (was 12), 3 ms budget per call with kept costs. A saved profile on the old 12 moves
  to 24. See the table below; the bake's *relative* gain shrank because the larger window also speeds up unbaked guides.
* **Wiki points.** A subzone map a client lacks lands on its parent zone (Valley of Trials no longer lands in The
  Barrens). A subzone row contradicted by its own parent-zone row is moved onto the parent's point (46 rows). A zone only
  one client has is read on that client's maps (Zephras Isle: 0 -> 64 steps with a wiki point). 163 guides changed, so
  their baked orders are stale until `tools/optimize_routes.py` is re-run.
* **Coverage.** Missions are non-geographic, no_route rows are classified in `noroute_class`. Era/TBC/Forever routable
  no_route = 0; mop 27 and retail 62 remain. Nothing else was closed this round.
* `tools/status_report.py`: the one-table summary per flavor.

  vplayer travel seconds, same sampled guides each column (pre-regeneration guides, so the bake still describes them):

  | | era | tbc | mop | retail | forever |
  |---|---|---|---|---|---|
  | Guides | 150 | 150 | 100 | 40 | 150 |
  | Old author + live | 748,877 | 586,180 | 345,514 | 78,523 | 671,412 |
  | Old baked + live | 700,796 | 532,711 | 303,127 | 72,036 | 638,046 |
  | New author + live | 683,251 | 533,791 | 291,476 | 76,869 | 618,301 |
  | **New baked + live** | **656,777** | **509,104** | **264,477** | **72,122** | **600,842** |
  | New vs old (baked + live) | 6.3% faster | 4.4% | 12.8% | 0.1% slower | 5.8% |
  | Bake gain over author, old / new | 6.4 / 3.9% | 9.1 / 4.6% | 12.3 / 9.3% | 8.3 / 6.2% | 5.0 / 2.8% |
  | Guides >1% slower than author, old / new | 22 / 16 | 7 / 11 | 13 / 18 | 6 / 9 | 16 / 23 |
  | Gain over baked with live off | 26.8% | 20.6% | 33.1% | 28.4% | 23.8% |
  | Guides >1% slower than baked with live off | 1 | 3 | 0 | 0 | 2 |

  Honest read: the player is faster on every flavor but retail (flat), and the window no longer undoes the bake (0-3 guides
  slower than baked with live off). The bake's own edge over author order shrank, and more guides sit >1% behind
  author + live on tbc, mop, retail and forever. A bake gate that drops a guide whose vplayer time is worse would zero that.

# Status / handoff (2026-11-08, Forever flavor, generated leveling spine, offline route optimizer)

Built by a 4-agent run (Forever ‖ spine → optimizer → independent verifier); verifier re-ran everything and fixed 4 bugs.
All 7 harnesses pass (`test_offline`, `test_farm`, `test_access`, `test_load_all`, `validate_toc`, `test_wiki`,
`test_route_order`). Installed on all 5 clients. **Nothing loaded in a real client yet — Daniel beta-tests.**

* **Forever** (wago product `wowf`, build 1.60.1.70790, Interface 16001). Era code path (`NS.flavor="era"`) with
  `NS.isForever` / `NS.dataFlavor="forever"`. `CompletionRoute_Forever.toc` + identical `_Camelot.toc` (the client
  binary carries both suffixes). Own QuestV2 (6,616 ids: 4,805 shared with era, 1,811 Forever-only, 190 of those on
  the wiki), own `Taxi_forever.lua` (90 nodes), `MapFix_forever.lua` + `U.EraToForever` for the 4 reshaped maps
  (Mulgore, Eastern Plaguelands, Redridge, Stormwind). HereBeDragons bumped to r35 Forever support.
  142 guides, coverage 3,752 / 6,616 (56.7%). vplayer: 293/293 finished, 0 stalls.
* **Spine** (`tools/wiki/gen_spine.py` → `Imported_Spine_<fl>.lua`, gitignored). In-zone order = topological over
  wiki PRE, then level (classic) / Campaign→QuestLine (retail), then 50 yd hub, then a simulated player (accept all at
  hub, objectives nearest-first, turn-ins, re-accept unlocks). Guides >250 steps split at ~200 by level / quest line.

  | Flavor | Zone guides | Max steps | Spine A / H | PRE violations |
  |---|---:|---:|---:|---:|
  | era | 137 | 243 | 94 / 86 | 0 |
  | tbc | 185 | 236 | 126 / 121 | 0 |
  | mop | 337 | 249 | 236 / 241 | 0 |
  | retail | 814 | 250 | 625 / 631 | 0 |
  | forever | 142 | 231 | 97 / 90 | 0 |

* **Optimizer (tier A)**: `tools/cost_matrix.lua` (real Router; matches `Router.TravelSeconds` exactly on 145,800
  pairs) + `tools/optimize_routes.py` (OR-Tools 9.15 in `~/Downloads/CompletionistGuide-work/venv`, py3.12;
  precedence, log cap 20/25/35, level gates, 30 s/guide) → `Data/RouteOrder_<fl>.lua` (gitignored, checksum-guarded;
  stale → author order). Option `routing.baked`. SQL: `route_compare`, `opt_violations` (0).

  | | era | tbc | mop | retail | forever |
  |---|---|---|---|---|---|
  | Guides optimized | all 234 | all 354 | 155 sample | 171 sample | all 239 |
  | Model saving, median / total | 27.5 / 39.5% | 29.4 / 39.7% | 21.4 / 31.0% | 20.9 / 22.1% | 28.5 / 39.4% |
  | vplayer baked vs author (live off) | 18.4% | 24.1% | 22.7% | 13.0% | 20.1% |
  | **vplayer in game (baked+live vs author+live)** | 6.4% | 9.1% | 12.7% | 6.5% | 5.0% |
  | Guides >1% slower (live on) | 22 | 7 | 16 | 26 | 16 |

  Honest read: the existing 12-step live window already captures 31–39%; the bake adds 5–13% on top, median guide 0%.
  Exact lower bounds exist for ~55% of guides and all of those are within 0.1% of optimal.
* **Known gaps / next:**
  1. Spine skips wide-level-band guides (e.g. "Darnassus 1-50") when remaining steps are level-gated and never
     returns — needs a `Core/Progress.lua` revisit rule (2/25 era spine guides unfinished in vplayer).
  2. Live window re-sorts the baked order greedily and can undo it → tier B replanner (W4) must respect the bake.
  3. Full mop/retail optimizer runs (samples only so far).
  4. Retail zone purity: off-map accepts 19% → 42% after PRE repair; 727 faction-gated quest copies.
  5. Valley of Trials wiki points land in The Barrens; Zephras Isle (Forever) has almost no wiki coords.
  6. Era maps file from 1.15.7 (client 1.15.9). Forever flying/profession API assumed era-like.

# Status / handoff (2026-11-07, wiki pipeline built: Warcraft Wiki → quest guides on all four clients)

* **Pipeline** (`tools/wiki/`, see [tools/wiki/README.md](../tools/wiki/README.md)):
  `fetch_wiki.py` (148,223 infobox pages) → `fetch_titles.py` (+16,056 linked pages: items, objects, places,
  redirects; 383 requests) → `parse_wiki.py` → `wiki.sqlite` → `fetch_db2.py` (pinned QuestV2 per flavor) →
  `gen_wiki_guides.py` → `Guides/Imported_Wiki_<fl>.lua` (CC BY-SA 4.0 header) + `Imported_Quests_<fl>_gaps.lua`.
  Everything generated is gitignored.
* **Parse rates** (40,357 Questbox pages): 2,488 are faction-disambiguation pages without a box, 168 have no id.
  That leaves 38,058 quest rows (37,297 ids). The start is linked on 81.5% and has its own `{{co}}` on 18.6%. Any
  start coordinate (own or on the linked page) exists for 43.4%. `previous` resolves to an id on 20,360 of 21,107.
  There are 51,803 objective bullets. NPC pages carry coordinates only 16.1% of the time, object pages 29.5%.
* **Per flavor** (steps = A + C + T lines). Coordinate source is wiki, fallback (Imported_Quests_<fl>, note-tagged),
  or none:

  | Flavor | QuestV2 | Wiki-assigned | Guides | Steps | Wiki coords | Fallback | None | QuestV2 with no wiki page |
  |---|---:|---:|---:|---:|---:|---:|---:|---:|
  | era | 4,807 | 3,299 | 131 | 9,712 | 3,111 (32.0%) | 5,497 (56.6%) | 1,104 (11.4%) | 816 |
  | tbc | 6,160 | 5,021 | 169 | 14,900 | 5,178 (34.8%) | 8,364 (56.1%) | 1,358 (9.1%) | 854 |
  | mop | 17,140 | 10,562 | 264 | 32,090 | 12,777 (39.8%) | 17,604 (54.9%) | 1,709 (5.3%) | 2,896 |
  | retail | 66,552 | 26,642 | 467 | 87,726 | 35,063 (40.0%) | 27,882 (31.8%) | 24,781 (28.2%) | 31,662 |

  * **Fallback sources.** Retail: 25,137 Blizzard POI and 2,747 Questie. Classic: all Questie.
  * **Version overrides.** Some fallback steps replaced a wiki point that was written for another game version
    and sat more than 300 yd from the client data: era 768, tbc 1,048, mop 2,453.
  * **Agreement check.** Where both sources place a giver or ender on the same continent, the wiki point and the
    old generated point agree within 50 yd for 81% (era), 86% (tbc), 94% (mop) and 76% (retail) of steps. Median
    gap is 4 to 7 yd.
* **Coverage** (`tools/coverage.py --label wiki-2026-11-07`, QuestV2 ids in a loaded guide): era 3,565 (74.2%),
  tbc 5,845 (94.9%), mop 16,562 (96.6%), retail 34,249 (51.5%). No quest that the old generated guides covered was
  lost. Retail quest guides went from 21,140 to 29,334 ids.
* **No duplicates.** The TOCs, `install.sh` (`--delete-excluded`; full `Imported_Quests_*` never shipped),
  `coverage.py`, `vplayer.lua`, `route_sweep.lua` and `audit_guides.lua` load `Imported_Wiki_<fl>` +
  `Imported_Quests_<fl>_gaps`. Of the old quests, 3,288 (era), 5,012 (tbc), 10,544 (mop) and 18,448 (retail) now
  come from the wiki.
* **SQL.** `docs/verification.sqlite` `wiki_db2_conflict` holds:
  * 165 era `membership` rows (wiki says vanilla, era client lacks the id);
  * 114 retail `objective_count` rows (`QO` dropped);
  * 694 retail `turnin_xy` rows (wiki ender over 50 yd from the POI pin);
  * `*_xy_version` rows.

  `wiki.sqlite` holds `flavor_quests`, `flavor_gap`, `flavor_skip` and `gen_stats`.
* **Achievements** are parsed into SQL (9,157 with an id). The wiki criteria have no criterion ids and no
  coordinates, so the DB2 achievement guides stay (see tools/wiki/README.md).
* **Tests:** `test_offline`, `test_farm`, `test_access`, `test_load_all` and `validate_toc` pass. New:
  `tools/test_wiki.lua`. It checks that all four wiki files parse (0 unparsable lines), are flavor-gated and carry
  the attribution header. It also checks era quest 7 Kobold Camp Cleanup: an A step at Marshal McBride 48.9,41.6
  Elwynn (PRE 783), a C step for Kobold Vermin at 50.0,36.6 (from the Classic mob page), and a T step.
  `vplayer` played the wiki guides as both factions:

  | Flavor | Guides | Finished | Stalls | no_route steps |
  |---|---:|---:|---:|---:|
  | era | 175 (all) | 175 | 0 | 78 |
  | tbc | 225 (all) | 225 | 0 | 24 |
  | mop | 176 (every second guide) | 176 | 0 | 177 |
  | retail | 161 (every fourth guide) | 160 | 0 | 261 |

  The one unfinished retail guide is "Revendreth Quests 57" (1,359 steps). It hit vplayer's per-guide time cap; it
  did not stall. Very large single-zone guides should be split, by storyline or level band.
* **Known gaps:**
  * Classic coordinates are thin on the wiki (NPC pages are retail-first), so era/tbc lean on the Questie fallback.
    The pure-wiki file (`--no-fallback`) would have only 32–40% of steps located, depending on the flavor.
  * Subzone/place pages are only fetched when linked directly.
  * `(provided)` / item-drop resolution depends on the item page listing its sources.
  * World quests, callings and emissary quests are excluded (2,856 retail).
  * Season of Discovery pages are excluded from era (637).
  * Forever has no TOC yet.
* **Independent re-verification (same day):** all six harnesses pass again. The vplayer sample in
  `docs/vplayer_<fl>.tsv` / `verification.sqlite` (`tools/collect_vplayer.py`):

  | Flavor | Guides | Finished | Stalls | no_route steps | Notes |
  |---|---:|---:|---:|---:|---|
  | era | 131 | 131 | 0 | 78 | |
  | tbc | 150 | 150 | 0 | 24 | |
  | mop | 150 | 150 | 0 | 146 | |
  | retail | 150 (every third) | 135 | 0 | 168 | 15 hit the `--guidecap 60` time cap (large zones, 169–1,342 steps); none stalled |

  `docs/verification.sqlite` `coverage` rows per flavor carry `wiki` / `after` / `before` labels with the
  wiki-vs-fallback location split; `wiki_gaps` 36,228 rows, `wiki_vs_db2` 12,296, `wiki_db2_conflict` 5,242.
  No row in it or in any tracked file names a third-party guide. The `.sqlite` is gitignored (local + Drive
  only) because its Classic fallback columns hold Questie-derived coordinates, which may not be published.

# Status / handoff (2026-11-07, third-party guides removed, wiki becomes source of truth)

* **Daniel's directive (2026-11-07): community sources only.** Every adapter, bake, export tool, coordinate-fix table and
  sweep/audit output that carried third-party (commercial) guide content was removed and purged from the **entire git
  history** with `git filter-repo`, then force-pushed. `tools/install.sh` installs only allowlisted generated guides
  and adapters. "legacy" in older sections below = that removed content.
* All numbers in older sections were measured with those guides loaded and are no longer valid. `docs/verification.sqlite`
  is rebuilt from community-only guides.
* **Source of truth for quest data = Warcraft Wiki (warcraft.wiki.gg, CC BY-SA 4.0)**: 40,357 pages carry `{{Questbox}}`
  (id, faction, level, start/end NPC, previous/next chain); 84,575 `{{Npcbox}}` pages carry `{{Coords|x|y|zone}}`.
  Blizzard client data (wago.tools DB2) fills objective areas. Wiki-derived data files must be CC BY-SA 4.0 with
  attribution (share-alike); code stays PolyForm NC.
* Daniel beta-tests in game himself. No AI in-game passes. Plan: docs/FINISH_PLAN.md.

# Status / handoff (2026-09-25, completionist coverage charted in SQL)

## What changed
* **`tools/coverage.py`**: measures every flavor against the client's own lists (wago.tools DB2: QuestV2,
  Achievement, CriteriaTree, QuestLine/QuestLineXQuest, GarrMission; item-started quests from Questie).
  Writes `coverage` (flavor, category, label, total, covered, missing, located) and `coverage_missing` (IDs)
  into `docs/verification.sqlite`. **covered** means the ID is in a guide the client loads. **located** means at least one of its steps has map coordinates, so the router can take you there.
* **`tools/gen_completion_guides.py`** (output gitignored, shipped by `install.sh` like Imported_Quests):
  `Imported_Achievements_{retail,mop}.lua`: one guide per achievement category, one step per criterion (cap 60) plus a FIXED
  "earn it" step. Quest criteria carry that quest's map pin, so the router orders them by travel time.
  `Imported_Storylines_retail.lua` (1,648 QuestLines in client order, `PRE`-chained so routing cannot break the story),
  `Imported_Missions_retail.lua` (1,757 missions on WoD/Legion/BfA/SL tables).
* New step tags: `|ACH|id;criteriaTreeId|` ticks from `GetAchievementInfo` / `GetAchievementCriteriaInfoByID`.
  On Era/TBC it stays a manual step because those clients have no achievement API. `|MISSION|id|` is manual because the client keeps no persistent flag for a completed mission.
* `gen_quest_guides_retail.py`: adds 4,014 client quests that have no map pin at their Questie quest giver.
  `gen_quest_guides.lua`: finds where an item that starts a quest drops or is sold (Questie itemDB). It now runs with `lua` 5.5,
  because the current Questie questDB exceeds LuaJIT's 65,536-constant limit.
* **Routing into and out of dungeons:** `tools/gen_entrances.py` writes `Data/Imported_Entrances.lua` (gitignored, from Questie
  dungeons.lua, ~90-100 doors per flavor). `Core/Instances.lua` uses it as the last fallback after learned and journal
  entrances. `Router.TravelSecondsFromPlayer` now routes from inside an instance via its door (+30 s).
* `vplayer.lua`: `--guides-file`, ACH support, and a `*_noroute.tsv` per run (from/to map of every unroutable step).
  `tools/collect_noroute.py` folds these into `noroute_rerun` / `noroute_steps`.
* Taxi CSVs are untracked (derived Blizzard data). `tools/gen_taxi.py` fetches them again.

## Coverage, measured (before → after)
| Flavor | Category | Total | Covered before | Covered after | Located after |
|---|---|---:|---:|---:|---:|
| era | quest | 4,807 | 3,852 | 3,852 | 3,745 |
| era | item-quest | 204 | 204 | 204 | 182 |
| tbc | quest | 6,160 | 5,748 | 5,748 | 5,417 |
| tbc | item-quest | 280 | 280 | 280 | 253 |
| mop | quest | 17,139 | 16,415 | 16,415 | 13,903 |
| mop | achievement | 3,106 | 930 | **3,106** | 694 |
| mop | item-quest | 475 | 475 | 475 | 379 |
| retail | quest | 66,420 | 31,616 | **35,493** | 32,506 |
| retail | achievement | 11,972 | 2,987 | **11,972** | 2,035 |
| retail | storyline | 1,648 | 1,548 | **1,648** | 1,536 |
| retail | mission | 1,757 | 0 | **1,757** | 0 |
| retail | item-quest | 372 | 183 | 239 | 183 |

Honest reading:
* Retail's QuestV2 holds 66k IDs, and most of the 30,927 still missing are hidden tracking and flag quests. The client data has no name or location for them, so they are not playable quests.
* The 955 era / 412 tbc / 724 mop quests still missing are client IDs that Questie does not know about either.
* Era and TBC ship 33 and 43 internal achievement rows but have no achievement UI, so no guides were generated for them.
* Most achievement criteria (kills, exploration, statistics) have no coordinates in client data. They are checklist steps that tick from the API, not routed steps.

## no_route (vplayer re-run of the guides that had no_route > 0)
Tables `noroute_rerun` / `noroute_steps` (label `rerun-2026-09-25`), code now includes the seeded dungeon doors and routing out of an instance:

| Flavor | Guides re-run | no_route before (Aug sweep) | after |
|---|---:|---:|---:|
| era | 5 (all) | 5 | 0 |
| tbc | 75 (all) | 137 | 39 |
| mop | 935 (all) | 1,337 | 513 |
| retail | 240 worst of 2,424 | 2,001 | 1,248 |

On the guides that were re-run, no_route fell from 3,480 steps to 1,800 (-48%). Retail's other 2,184 guides (2,642 no_route steps) were not re-run because they would take about 2.5 h. The remaining steps are mostly retail dungeons newer than MoP and Legion+ scenario maps. 0 stalls. 3 retail guides hit the 40 s CPU cap that this sample used.

## Tests
validate_toc, test_load_all (4 flavors), test_offline, test_access (now also covers the seeded door into and out of
the Deadmines and the ACH/MISSION tags), and test_farm all **pass**. vplayer sample on the new sets (label `new-guides-sample-2026-09-25`):
retail Storylines 60/60 finished, Achievements 30/30 (7,167 auto-ticked steps), Missions 6/6 (2,584 manual steps, as designed); MoP Achievements
30/30. 0 stalls across all of them.

## Install
`tools/install.sh _classic_era_ _anniversary_ _classic_` installed to Era (22 MB), TBC (25 MB) and MoP (38 MB).
**Retail was skipped because the retail client was running.** Install it with `tools/install.sh _retail_` after quitting WoW (it needs an install, not a /reload).

## Still open
* The in-game manual pass on TBC, MoP and retail still needs Daniel's permission to use the GUI and his Battle.net login.
* ACH criteria-tree IDs passed to `GetAchievementCriteriaInfoByID` have not been checked in game. The whole-achievement check and the quest-criterion QID check do not depend on them.
* Retail item-quests: 133 have no Questie giver or drop data. Dungeon-only item starters (for example VanCleef's letter) stay unlocated.
* Mission steps stay manual. Retail dungeons newer than MoP rely on the journal in game; offline they still have no route.

## Next pathways
1. Locate kill-type and exploration criteria: join Criteria.Asset with Questie npc spawns (MoP) and with WorldMapOverlay/AreaTable for exploration.
2. Give the 11,196 retail quests that have only pins a name and a faction gate from a newer community database.
3. Run a full vplayer sweep with the achievement, storyline and mission sets (~2-3 h at 3 workers on this Mac), then fold the results with collect_vplayer.py.
4. Seed retail entrances for Legion+ dungeons from the journal-instance DB2 (JournalInstance + AreaPOI).

# Status / handoff (2026-09-25, duplicate addon fixed)

## Retail guide switching / error spam
Retail had both the current `CompletionRoute` and obsolete `OpenRoute` installed. The old copy (Sep 18)
was missing its generated community quest files; retail `FrameXML.log` showed five failed TOC loads. It
was capable of running a second guide engine alongside the current addon. Archived the old folders from
all four active clients to `World of Warcraft/AddOns-archive/OpenRoute-legacy_20260925/<flavor>/OpenRoute`
(the files are preserved for rollback). `CompletionRoute` remains installed in all clients.

`tools/install.sh` now refuses an install when the obsolete `OpenRoute` folder is still active, preventing
the duplicate-engine condition from returning. Retail is already running; the archived code stays in memory
until the player reloads the UI. Type `/reload` in WoW to load only `CompletionRoute`. The game UI still
needs a player check after reload to confirm the repeated guide switching and Lua error bar have stopped.

# Status / handoff (2026-09-25, routing sweep complete)

## Post-transit routing sweep
Re-ran the full virtual routing sweep on branch `beacon-and-account-progress` at `5a56843`, using the
locally installed guide datasets (which remain gitignored) and the checked-in route engine/data. Results
are saved in `docs/route_sweep_{era,tbc,mop,retail}.tsv` and imported into `docs/verification.sqlite`
(`route_sweep` table); `docs/verification.sql` is refreshed from the full database.

| Flavor | Guides | Steps | Located | Precedence violations | Slower than author | Unreachable first step | Load errors | Faster than author |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| era | 1,111 | 56,461 | 96.3% | 0 | 0 | 0 | 0 | 158 |
| tbc | 1,061 | 82,994 | 98.6% | 0 | 0 | 0 | 0 | 193 |
| mop | 3,775 | 212,043 | 97.1% | 0 | 0 | 0 | 0 | 340 |
| retail | 9,918 | 420,239 | 95.5% | 0 | 10 | 0 | 0 | 738 |

Across all four flavors: **15,865 guides / 771,737 steps**, zero load errors, zero quest precedence violations,
and zero unreachable first steps from each guide’s modeled starting zone to its first located step. The retail optimizer's measured first window cost was higher than author
order in 10 guides (9,908/9,918 were equal or faster); this is a small heuristic quality exception, not a
route failure. Per-guide costs and paths are recorded in the SQL table and TSVs for follow-up.

The sweep is offline. It does not replace the pending manual in-game pass on TBC, MoP, and retail, which
requires the game UI and Battle.net login.

# Status / handoff (2026-09-25)

## Regression fixed: community quest guides had been wiped from all four clients
* The 2026-09-18/19 `tools/install.sh` runs came from a fresh clone with no `Guides/Imported_Quests_*.lua`
  (generated, gitignored). `rsync --delete` then removed them from every client, so the live addon carried
  only legacy + WoW-Pro guides and none of the community (Questie / Blizzard QuestPOI) guides.
* Restored the six files from the iCloud working copy (generated 2026-08-25) and reinstalled to
  era/tbc/mop/retail. `install.sh` now **refuses to run** if any `Imported_Quests_<tier>.lua` is missing.
* Checked: test_load_all, validate_toc, test_offline and test_access all pass. vplayer retail
  `--type Quests --limit 40`: 40/40 finished, 0 stalls.
* Still open: the in-game pass on TBC/MoP/retail (needs GUI + Battle.net login, so Daniel has to be present),
  and re-measuring `no_route` after the Sep transit edges (full sweep ~50 min; not run because the Mac had
  7 GB free and load ~40).

# Status / handoff (2026-09-19)

## Expansion Transit Hubs & Island Links Connected
Expanded `CompletionRoute/Data/Transit.lua` to bridge key routing gaps across Shadowlands, Dragonflight, Battle for Azeroth, Pandaria, World Events, and The War Within:
* **Shadowlands:**
  * Oribos <-> The Maw (`1543`): jump into Maw / Waystone return to Oribos.
  * The Maw (`1543`) <-> Torghast (`1911`): entrance to Torghast, Tower of the Damned.
  * The Maw (`1543`) <-> Korthia (`1961`): flight/flayer path between Maw and Korthia.
  * Zereth Mortis (`1970`) -> Oribos (`1670`): return portal from Zereth Mortis.
* **Dragonflight:**
  * Valdrakken (`2112`) <-> Zaralek Cavern (`2133`): Loamm portal / tunnel traversal.
  * Valdrakken (`2112`) <-> Emerald Dream (`2200`): Central Encampment portal.
* **Battle for Azeroth:**
  * Nazjatar -> Boralus (Alliance, Mezzamere portal) & Dazar'alor (Horde, Newhome portal).
  * Mechagon (`1462`) <-> Boralus (Alliance flight) & Dazar'alor (Horde flight).
* **Pandaria:**
  * Isle of Thunder (`504`) -> Townlong Steppes: Sunreaver & Kirin Tor return portals.
* **World Events:**
  * Darkmoon Island (`407`) <-> Elwynn Forest (Alliance) & Mulgore (Horde).
* **The War Within:**
  * Siren Isle (`2369`) -> Isle of Dorn (`2248`): Skaggit's airship return.
  * Undermine (`2346`) -> The Ringing Deeps (`2214`): Rocket Drill return.

## Verification & Test Suite Passing State
* `tools/test_access.lua`: 100% PASS across all 12 Legion Class Order Halls, all Access Chains, and all newly connected transit hubs (Maw, Torghast, Korthia, Zereth Mortis, Zaralek Cavern, Emerald Dream, Nazjatar, Mechagon, Darkmoon Island).
* `tools/validate_toc.lua`: All 4 TOCs validated clean.
* `tools/test_load_all.lua`: Clean load across all files on all 4 flavors.
* `tools/test_offline.lua`: ALL OFFLINE TESTS PASSED.
* `tools/test_farm.lua`: ALL FARM TESTS PASSED (14/14 checks).
* `tools/install.sh`: Synchronized latest baked guides and code to all 4 live game directories on `/Volumes/x10`.

## Companion App & Build Environment
* Updated `app/build_app.sh` to configure `DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"`, preventing interactive Xcode license prompts during autonomous builds.
* Recompiled and deployed native Swift 6 / AppKit companion app to `/Applications/Completionist's Guide.app`.

# Status / handoff (2026-09-18)

## Legion Class Order Halls Connected & Verified
Transit edges between Dalaran (Broken Isles, `627`) and the 12 Legion Class Order Halls were added to `CompletionRoute/Data/Transit.lua` and validated across all factions and client flavors:
* **Warrior:** Krasus' Landing jump pad <-> Skyhold (`695`, instance 1479).
* **Priest:** Dalaran Sanctuaries <-> Netherlight Temple (`702`, instance 1512).
* **Warlock:** Dalaran Sewers <-> Dreadscar Rift (`717`/`718`, instances 1107/1522).
* **Shaman:** Krasus' Landing portal <-> The Maelstrom (`726`, instance 1469).
* **Mage:** Chamber of the Guardian <-> Hall of the Guardian (`734`/`735`, instance 1513).
* **Hunter:** Krasus' Landing Great Eagle <-> Trueshot Lodge (`739`, instance 1220).
* **Druid:** Dalaran / Emerald Dreamway (`715`) <-> The Dreamgrove (`747`, instance 1220).
* **Demon Hunter:** Krasus' Landing glide/portal <-> The Fel Hammer (`720`/`721`, instance 1519).
* **Death Knight:** Dalaran sky / Death Gate <-> Acherus: The Ebon Hold (`647`/`648`, instance 1220).
* **Monk:** Dalaran portal / Zen Pilgrimage <-> The Wandering Isle (`709`, instance 1514).
* **Rogue:** Dalaran secret doors <-> Dalaran Underbelly / Hall of Shadows (`628`, instance 1220).
* **Paladin:** Dalaran portals <-> Light's Hope Chapel / Sanctum of Light (`24`, instance 0).
* **Test Verification:** Integrated into `tools/test_access.lua` checking resolution and full capital-to-order-hall Dijkstra paths for all 12 classes (100% passing).

## Optimizer Window Widened to 12
* Following the introduction of the Dijkstra travel path cache, `StepOrder.lua` lookahead performance was benchmarked across window sizes (8, 10, 12, 14, 15, 16, 18).
* In multi-zone benchmarks, Window 12 executes in ~0.52 ms per call while scanning 20% further into quest chains, preventing premature departures from quest hubs.
* Default window configured to `12` in `CompletionRoute/Core/Init.lua`.

## Native macOS Companion App Built & Deployed
Per operational directives ("Keep a .app version of any apps made in my applications folder. It should always be usable. Always update it to be current with all changes"), a native, ultra-lightweight AppKit companion application was created and installed directly to `/Applications/Completionist's Guide.app`:
* **App Bundle Size:** ~400 KB (native compiled Swift 6 / AppKit binary, zero electron/node/python runtime overhead).
* **Multi-Client Detection:** Automatically inspects the 4 World of Warcraft clients on `/Volumes/x10/Video Games/Mac/World of Warcraft` (`_classic_era_`, `_anniversary_`, `_classic_`, `_retail_`).
* **One-Click Sync:** Invokes `tools/install.sh` to bake and rsync flavor-isolated guides directly into all clients.
* **Diagnostics & Tests:** Embedded test runner executing `tools/test_offline.lua`, `tools/validate_toc.lua`, `tools/test_farm.lua`, and `tools/test_access.lua`.
* **SQL Verification Matrix Viewer:** Displays query results from `docs/verification.sqlite` (15,865 guides, 771,737 steps, 99.99% success rate).
* **Rebuild Script:** `app/build_app.sh` with custom `AppIcon.icns` generated via `app/make_icon.py`.

## Verification & Test Suite Passing State
* `tools/validate_toc.lua`: All 4 TOCs validated clean (Retail 49, Mists 47, TBC 47, Vanilla 47).
* `tools/test_load_all.lua`: Clean load across all files on all 4 flavors.
* `tools/test_offline.lua`: ALL OFFLINE TESTS PASSED (Parser, TravelGraph Dijkstra, StepOrder, SuggestNext, Account progress, Death handling, Taxi learning, Faction taxi, Roads, UI).
* `tools/test_farm.lua`: ALL FARM TESTS PASSED (14/14 checks, TSP solver, GatherMate2 decode, node import/export, lap value, in-client self test).
* `tools/test_access.lua`: ALL ACCESS TESTS PASSED (Portals, access chains, expansion gates, 12 Order Halls).
* `tools/install.sh`: Synchronized latest baked guides and code to all 4 live game directories on `/Volumes/x10`.

## Storage & Headroom Compliance
* Available disk space maintained comfortably above the 8 GB threshold (> 15 GiB available on `/System/Volumes/Data`).
* Project boundary preserved (no code written directly to the home folder).

# Status / handoff (2026-08-25)

The addon is now called **Completionist's Guide** in the client's addon list (`## Title` in every
TOC). The folder, namespace and SavedVariables stay `CompletionRoute`, so nothing a character has
recorded is invalidated by the rename.

## Every guide on every flavor was played, and none of them dead-ends

`tools/vplayer.lua` (the virtual player) ran the whole catalogue, six shards per flavor:

| flavor | guides | steps | steps played | auto-ticked | stalls | errors |
|---|---|---|---|---|---|---|
| era | 1,111 | 56,461 | 46,701 | 35,764 (76.6%) | **0** | 0 |
| tbc | 1,061 | 82,994 | 72,553 | 59,773 (82.4%) | **0** | 0 |
| mop | 3,775 | 212,043 | 186,422 | 137,122 (73.6%) | **0** | 1 |
| retail | 9,918 | 420,239 | 360,533 | 234,354 (65.0%) | **0** | 0 |
| **total** | **15,865** | **771,737** | **666,209** | **467,013** | **0** | **1** |

Folded into `docs/verification.sqlite` by `tools/collect_vplayer.py` — tables `vplayer_runs`,
`vplayer_guides`, `vplayer_stalls`. The single error is a step cap on `qdb:mop:OTHER`, the catch-all
guide holding every MoP quest with no zone: it is a harness bound, not an addon fault.

Three real defects came out of this run, all fixed:

### 1. Guides were baked onto clients that cannot run them
Guides key an era by the folder it lives in, not by the client it is installed under: MoP
Classic's install carries `Guides-Retail` **and** `Guides-MOP`, and TBC Anniversary's carries a
`Guides-MOP`. Tagging by install directory put 222 Shadowlands guides (≈7,000 retail guides in all)
on MoP Classic and 3,281 MoP guides on TBC Anniversary. The map-name gate did not catch them. Taking
the flavor from the `Guides-<ERA>` folder suffix — what the guide's own `files-<ERA>.xml` loads — is
authoritative:

| flavor | leaked bake | correct bake |
|---|---|---|
| era | 1,111 | 969 legacy + wowpro/quests = 1,111 played |
| tbc | 4,078 | 857 legacy (1,061 played) |
| mop | 10,275 | 3,265 legacy (3,775 played) |
| retail | 9,980 | 9,201 legacy (9,918 played) |

The catalogue got smaller and correct. A guide count is not a feature.

### 2. A note-only legacy step became a travel step that could never complete
The adapter fell back to `R` ("go to X") for any step it could not turn into an action. `R`
completes by standing at X — a step whose only content was a `|tip` block or a "wait for the race to
start" line had no X, so it could never tick and the guide dead-ended there. Six Dragonflight guides
stalled on exactly that, and they were the only stalls left in the whole 15,865-guide sweep. With no
destination the adapter now emits `N`, the forward-arrow note commercial guides show for that line.

### 3. The router burned ~0.5 s of Lua per step on modern maps
The step-order optimizer re-asks for the same step pairs on every step advance: a window of 10 is up
to 110 `FindPath` calls, and one `FindPath` is ~6 ms over a modern continent's ~160 graph nodes. In
game that is a visible hitch on every step; in the sweep it was why guides hit the per-guide time
cap. `TravelGraph` now caches hearth-free searches on an exact key (hearth cost rides a ticking
cooldown, so those stay live) and drops the cache whenever the graph is rebuilt. One 193-step zone
guide went **175 s → 6.5 s of CPU with a byte-identical result row**; the full four-flavor sweep went
from hours to about 50 minutes.

## What is still open

* **The in-game pass is blocked on the Battle.net password.** The launcher logged itself out on
  2026-08-24 with `BLZBNTBGS80000011 (3025)` and asks for the account password on every start. It was
  not guessed — repeated failures risk locking the account. Everything below the client is verified;
  what is not is the live UI/API surface on TBC, MoP and retail (Era passed in game on 2026-08-24,
  27/27 features, build 11509). Run `python3 tools/run_all_flavors.py --minutes=30 --collect
  --take-screen` once logged in. Era, TBC Anniversary and MoP Classic go dark when the subscription
  lapses — that pass is the only hard deadline this project has.
* **6,122 steps (0.9%) have a destination the router could not path to**, concentrated in Legion
  order halls, dungeon interiors and holiday-event instances — places reached by a portal or a queue
  rather than by travel. `Data/Access.lua` and `Data/Transit.lua` are where those links belong; the
  virtual player already reports them per guide, so the list is `select guide, no_route from
  vplayer_guides where no_route > 0 order by no_route desc`.
* **The optimizer window is 10.** With the path cache in place a wider window is now affordable and
  would produce better routes; it has not been measured yet.

# Status / handoff (2026-08-24, evening)

## All expansions are in
`tools/export_guides.lua` only ever read ONE legacy install (Anniversary/TBC) and only WoW-Pro's
Classic TOCs, so retail's guides — Legion through Midnight — were never imported. It now walks every
flavor directory, loads every legacy viewer under each, and picks the matching WoW-Pro TOC and
guide folder per era. Each guide is tagged with the flavor it came from and the adapters register only
`NS.flavor` matches.

| flavor | before | after |
|---|---|---|
| era | 1,058 | **1,111** |
| tbc | 1,114 | **4,078** |
| mop | 1,309 | **10,275** |
| retail | 910 | **9,980** |

Two fixes were needed: 40 guide files (incl. Horde BfA/Cata/MoP/WoD levelling) failed to parse because
LuaJIT rejects escape sequences WoW's own Lua 5.1 keeps — repaired by matching backslash-plus-next-char
so a genuine `\\` pair is consumed whole. And one merged bake is ~100 MB, so it is now one file per
flavor and `install.sh` ships each client only its own (retail 58M, mop 60M, tbc 37M, era 23M).

## In game: Era verified, TBC lost, then Battle.net logged itself out
* **Era: PASS.** 1,436 guides swept, 71,541 steps, 68,576 located, **0 precedence violations, 0 empty
  windows, 0 load failures**, 3 no-route, 2 optimizer-slower; features **27/27** (build 11509). This is
  the first in-game confirmation of the farm/circuit work from 2026-08-22. Evidence:
  `docs/screenshots/run_classic_era_0061.png` — "Tanaris Quests · step 2 of 323", one-step card, and
  the route line "Follow the road 1.6k yd to Camp Mojache, Feralas; Fly Camp Mojache…".
* **TBC: ran for 25 minutes and recorded nothing.** `tell application ... to quit` answers
  "User canceled (-128)" on the Classic clients and the process exits WITHOUT flushing
  SavedVariables, so the whole run was lost. The driver now raises the client and sends a real Cmd+Q,
  then warns explicitly if the SavedVariables mtime did not move.
* **Then the launcher logged out** with `BLZBNTBGS80000011 (3025)` and now asks for the account
  password. battle.net resolves, `us.actual.battle.net:1119` is reachable and the rest of the internet
  is fine, so this is session/account-side, not connectivity. **Blocked: needs Daniel's Battle.net
  password.** Not guessed — repeated failures risk locking the account.

## Launcher automation, corrected
Do NOT pick the version from the product page's GAME VERSION dropdown: the list is repositioned so the
*current* selection sits at a fixed spot, so a hard-coded row picks whatever was chosen last (it
silently re-selected Classic Era when asked for Burning Crusade Anniversary), and once Era is selected
that dropdown only offers Era / Hardcore / Season of Discovery. Use **GAMES → "3 Installed"**, which is
stable, then verify the cropped GAME VERSION label. `battlenet://<product>` URIs do not switch it.

## Next session
1. Log Battle.net back in, then `python3 tools/run_all_flavors.py --minutes=30 --collect --take-screen`
   for TBC, MoP and retail (Era is done).
2. The offline sweep over the full 25,000-guide set is running; `python3 tools/collect_vplayer.py`.

# Status / handoff (2026-08-24)

## The question that reframed the session
Daniel asked whether we could "download a personal copy of World of Warcraft" and test against it,
rather than run characters through every route. Answer, written up in **docs/LOCAL_SERVER.md**: the
open-source cores (AzerothCore / TrinityCore / CMaNGOS) only speak legacy builds and the four clients
here are modern ones, so a private server needs either an unlicensed legacy client or a patched-out
connection check. Neither happens in this repo. What *does* solve the efficiency problem is a virtual
player, and what still needs a real client stays possible for free on retail (Starter Edition, level
20) after the subscription lapses. **Era / TBC Anniversary / MoP Classic go dark with the sub — their
last in-game pass is the only hard deadline this project has.**

## Retail finally has community quest guides (it had none)
Offline — that is, without external addons, which is what happens when subscriptions end — retail carried
**910 guides: 797 baked from legacy guides (proprietary) and 113 WoW-Pro. Zero community quest guides.**
Questie's database stops at MoP, so "every quest, community-driven" was true on the classic flavors
and false on the one flavor that has to outlive the subscription.

Blizzard's own client data carries the quest map pins. `tools/gen_quest_guides_retail.py` folds
wago.tools **QuestPOIBlob** (quest → uiMap + objective index) and **QuestPOIPoint** (world coordinates)
into one "&lt;Zone&gt; Quests" guide per zone:

* **379 zone guides, 17,161 quests, 56,843 steps** — retail goes 910 → 1,289 guides.
* `tools/questie_quest_index.lua` merges Questie's community data on top: **5,965 quests get their real
  name plus `|FACTION|` / `|C|` / `|LVL|` gating**, and **4,995 accept steps get the real quest giver**.
* The rest keep a "Quest &lt;id&gt;" title that `Core/Guide.lua StepTitle` swaps for the live name the
  moment `C_QuestLog` can answer, and an accept pin taken from the turn-in — whose note says so.

**A claim I had to correct mid-session:** the generator first assumed the quest giver and the turn-in
are the same NPC. Measured against WoW-Pro, which authors both by hand: over 4,851 quests carrying
both coordinates, the giver is within 50 yd of the ender only **58.6%** of the time (p75 633 yd, p90
1,628 yd). For ~40% of quests that assumption pointed the arrow at the wrong end of the zone — the
exact failure this addon exists to avoid. Hence the Questie giver spawns.

Known limitation, stated plainly: Legion and later have no community database, so those zones still
list both factions' quests and you skip what you cannot take.

## The virtual player (docs/VPLAYER.md)
`tools/vplayer.lua` runs the **real** addon against a mutable fake world and plays every guide to
completion — walk to the step through the real router, perform its action against the world, let
`Progress.Refresh()` auto-advance exactly as in the client. No character, no server, no subscription.

Three things it found on its first outings:

1. **~50 false bugs from my own classifier.** A `C Kill Kresh` with neither `|QID|` nor `|L|`, an `R`
   with no coords, an accept with no `|QID|` can *never* auto-complete — in game you press the forward
   arrow, exactly as in other guide addons. `autoable()` now asks what data a step carries, so **manual** and
   **stall** mean different things and a stall is a real defect.
2. **`Progress.Pending` was quadratic.** It re-walked the whole completed prefix, and `Refresh` calls
   it up to 25 times per pass; on an 1,800-step retail zone guide that is a client-side hitch, not
   just a harness cost. A cursor now skips the leading run of *done* steps (inapplicable-now steps
   must stay in front of it) and every path that un-completes a step clears it — including a
   completion-scope change, which is the one that does not go through Undo/Reset/NewLap.
   Suramar's 1,206-step guide: over the old 20 s cap → **13 s, 992 steps, 100% auto, 0 stalls**.
3. **Level-gated steps were being skipped silently** — a guide looked "finished" while its `|LVL|`
   steps had never been applicable. `levelGateBump()` raises the level to the lowest gate still
   holding a step back.

## In-game verification: NOT run this session, and why
A live FFXI client (`horizon-loader.exe` on play.horizonxi.com, character Murn) plus a local
LandSandBoat server owned the display for the whole slot — load average peaked at 46-52 on 8 cores.
Launching WoW would have taken the screen out from under a live session. Nothing in this entry is
claimed as in-game verified; the circuits work from 2026-08-22 is **still** unverified in game.

To make that a single hands-free command when the screen is free:
`python3 tools/run_all_flavors.py --minutes=30 --collect` — it sets the launcher's GAME VERSION itself
(`--version-click`), runs Era → TBC Anniversary → MoP → retail (deadline order), and refuses to start
or continue while a wine/FFXI window or game process is alive.

## Working-copy traps worth remembering
* **iCloud eviction makes git unusable in this checkout.** `docs/screenshots` holds 655 dataless
  placeholder PNGs, so any `git status`/`git log` stat-walk hangs for minutes pulling them down. Do git
  work in a separate local clone and copy changed files in. Same for the harnesses: running them from
  iCloud cost ~4x in wall time (25% CPU, the rest waiting on writes).
* Licence: this branch predated the 2026-08-22 sweep and still carried MIT. LICENSE and all four TOC
  headers now match master — PolyForm Noncommercial 1.0.0 + 10% commercial rider, help@batesai.org.

# Status / handoff (2026-08-22)

## Gold guides became routes (the ask: "no clicking through steps — a route they always follow")
* New guide type: **circuits**. `G` waypoints (`Core/Guide.lua`), proximity completion + endless laps
  (`Core/Progress.lua` `NewLap` / `StartAtNearest`), shortest closed tour solver (`Routing/Loop.lua`:
  cluster → nearest-neighbour → 2-opt → Or-opt), farm engine (`Core/Farm.lua`), 31 coarse seed rings
  (`Data/Farm_routes.lua`). Full write-up: **docs/GOLD_ROUTES.md**.
* Imported gold guides are folded into circuits on load. Measured over the baked legacy set:
  **178 of 204 (87%) are walkable circuits on era / tbc / mop / retail** — 106 kept in the author's own
  order (authored farming guides already carry `map` + `path` rings; the adapter now parses them), 72 solved
  here, avg 25.6 stops. The remaining 26 are auction-house / disenchant methods with no route at all and
  stay as note guides. Rows: `docs/verification.sqlite` tables `gold_circuits`, `guide_type_audit`
  (`luajit tools/audit_guides.lua <flavor>` → `python3 tools/collect_audit.py`).
* Nodes are community-driven and local-first: every world-object loot is recorded account-wide (corpses are
  not), GatherMate2 / Routes databases import if installed, `/cr farm export|import` moves plain text between
  players. **No third-party node data ships in this repo.**
* A lap prices itself: bag delta × Auctionator price (else vendor) + coin gained → `lap 3 — waypoint 12 of 48
  · 214g/hr` in the window title, `/cr farm stats` per circuit.
* Guide categories are folded (`Guide.NormalizeType`): legacy "GOLD" and "Professions"/"Profession" etc. no
  longer split the guide menu into near-duplicate rows.

## Other odd guides
* **Dungeons (98 guides, 951 unlocated steps)**: `Core/Instances.lua` learns the door (last outdoor position
  before the loading screen) and asks retail's `C_EncounterJournal.GetDungeonEntrancesForMap`;
  `Router.StepWorld` routes to the entrance whenever the target is inside an instance you are not in.
* Guide-type audit after the fixes (tbc, % of steps that resolve to a location): Leveling 99.2, Quests 99.1,
  Dungeons 97.0, Reputation 98.2, Events 99.0, Dailies 99.5, Titles 98.8, Gold 82.4, Professions 79.4.
  Professions is the next real gap: 943 steps are craft/vendor lines with no location by nature.

## Verification state (honest)
* Offline: `tools/test_farm.lua` (14 checks: waypoint parse, seed rings, enter-at-nearest, proximity advance,
  lap wrap, TSP optimality on a known square, clustering, recorder object-vs-corpse, GatherMate2 decode,
  export/import round trip, built circuit is a ring not a zig-zag, lap pricing, gold-guide fold, legacy path
  import, instance-entrance substitution) — all pass. `test_offline`, `test_access`, `test_load_all`
  (4 flavors × 47-48 files), `validate_toc` all pass. Retail route sweep re-run with the new modules loaded:
  600 guides, 0 load-fail / 0 precedence / 0 slower / 0 no-route.
* **In game: NOT yet run for this change.** A FFXI verification sweep owned another session had the screen for
  the whole slot (peer message 2026-08-22), and launching WoW would have stolen focus mid-run. Nothing here is
  claimed as in-game verified. Next session: `python3 tools/run_flavor_verify.py _retail_ --minutes=65`
  (and per flavor), then walk one circuit per flavor and check: lap counter increments, no step needs a click,
  gold/hr appears, dungeon guide arrows point at the door.

# Status / handoff (2026-08-21)

## In-game verification, morning round (retail + MoP rerun)
* retail (Orialan 58, Orgrimmar Embassy, build 12.1.0.69404): one-step window live ("Netherwing - step 1 of 147",
  note, zone, route line "Walk 519 yd to Durotar; take the zeppelin Orgrimmar<->Grom'gol", arrow + ETA on screen,
  detail tooltip on hover) - docs/screenshots/run_retail_0062.png. features 16/16 (feature_runs 2026-08-21 07:45:34).
  The 30-minute slot was NOT enough for a full sweep of 9,456 guides: 2,230 swept (174k steps, 167.7k located,
  0 order violations, 0 empty windows, 0 load failures, 541 no-route) and verifyall 1,981/9,519 (0 failed).
  Recorded honestly in the new `ingame_sweep_partials` / `run_partials` tables. A full retail sweep needs ~2 h.
* Driver lessons: another app (Notes) was frontmost when the client reached character select, so
  run_flavor_verify.py refused to click Enter World (correct: never click into the wrong app). New
  tools/resume_flavor_verify.py picks a run up from character select (AppleScript `activate` - `open -a` does not
  raise the client). Driver output is now flushed live. The launcher GAME VERSION dropdown is at window origin
  +(175,628); with it open the rows are MoP Classic +(140,537), Burning Crusade Anniversary +(140,505),
  World of Warcraft Classic +(140,473), World of Warcraft (retail) +(140,584) (1440x788 launcher window).
* mop (Thorfirn, Darnassus) rerun --minutes=20: window live ("Western Plaguelands Quests (Alliance) - step 1 of 170",
  arrow to Rut'theran portal, 147 yd + ETA, route line) - run_classic_0061.png. Sweep FINISHED: 1151 guides,
  79,366 steps, 77,502 located, 0 order violations, 0 slower, 0 empty windows, 0 load failures, 122 no-route;
  verifyall 1311/1311 OK; features 16/16. All rows in docs/verification.sqlite (+ .sql dump).
* retail FULL sweep done (resumable across the 30-min AFK logouts; driver re-enters the world): 9,456 guides,
  263,329 steps, 239,009 located, 0 order violations, 0 optimizer-slower, 0 empty windows, 0 load failures;
  verifyall 9,519/9,519 OK. no-route 2,706 -> 1,637 after the retail transit edges (docs/ROUTING.md "Retail
  cross-continent transit"); the remainder is mostly instance maps (raids/dungeons/scenarios/pet battles in
  instances - labelled "(instance map, expected)" from the next sweep on) plus real gaps on BfA/Draenor/
  Shadowlands/Dragonflight/TWW (Oribos ring + BfA boats added, in-game numbers pending; see route_sweep_from).
* **Access chains** (Data/Access.lua, docs/ROUTING.md): Siren Isle, K'aresh, Zereth Mortis, Isle of Thunder, Argus,
  Nazjatar, Undermine, Midnight now carry their unlock quest line as steps that get injected before any guide
  starting there + a router edge. Sweep 4 (access chains live): real no-route **261 -> 37** of 9,456 (895 into
  instance maps, expected). The 37: pet/mount guides on special maps, Midnight's later zones (Harandar/Voidstorm
  need the campaign chain past Quel'Danas), phased race starters, three BfA dungeon-entrance guides. 4 guides
  "optimizer slower" by a few seconds - chain edges in the head-window cost; harmless, noted.
* Midnight per-zone chains (Silvermoon / Eversong / Harandar / Voidstorm, stacked in route order) are installed
  and pass tools/test_access.lua but are NOT yet swept in game: FFXI was on screen when the run was due. Next:
  `python3 tools/run_flavor_verify.py _retail_ --sweep-only --minutes=65` (launcher on retail), then
  `tools/collect_verify.py`. Expected: the 37 drop to ~10 (race starters Kezan/Wandering Isle/Haranir are phased
  intro maps - unreachable by design; Underrot/MOTHERLODE/Shrine of the Storm guides start inside the dungeon).
* Offline from Orgrimmar (Horde, 837 baked guides): routed 413, 0 real no-route, 24 instance maps.
* Retail lessons: AFK logout at 30 min (sweep/verifyall now resume; driver re-arms + clicks Enter World);
  "Arathi Highlands" exists 7 times on retail -> deterministic zone-name resolution; router 37x cheaper.

# Status / handoff (2026-08-20)

## In-game verification, evening round (tools/run_flavor_verify.py — one deliberate launch per flavor)
Driver: arms SavedVariables (autoVerifyAll + autoSweep), presses Play in Battle.net (Quartz click at window
origin + (155,696); the GAME VERSION dropdown is changed by hand/click first), clicks Enter World at (0.498, 0.918)
of the client window, screenshots every 30 s to docs/screenshots/run_<flavor>_*.png, quits from OUTSIDE
(Quit()/ForceQuit() are protected in the world → taint popup). Results → tools/collect_verify.py →
verification.sqlite tables `ingame_sweeps` / `ingame_sweep_errors`.
* tbc (Solcus 66, Terokkar): one-step window + arrows + route line on screen (onestep_window_tbc.png); sweep 1524
  guides, 78,480 steps, 75,781 located, 0 order violations, 0 empty windows, 67 no-route (all instance-map guides:
  BRD/BRS/... no transit into instances), 2 "slower" by 6 s.
* era (Majaba, Orgrimmar): window + route "walk 369 yd; zeppelin Orgrimmar↔Undercity" live; sweep 1341 guides,
  0 order violations, 0 empty windows, 3 no-route; verifyall 1445/1445; features 16/16.
* Bugs found live and fixed: detail-popup buttons were parented to the main window (showed at its bottom);
  GameTooltip:SetText 5th arg must be alpha not wrap (luaErrors in char SV); self-quit is impossible (protected).
* mop (Thorfirn, Darnassus): window + route via Rut'theran portal live (run_classic_0457.png), features 16/16;
  sweep did NOT finish in the 8-min slot (4430 guides) → rerun with --minutes=15.
* retail: launched, but the Mac screen locked (idle) before character select, so no capture/clicks were possible;
  client quit cleanly, flags disarmed. Rerun with --minutes=30 while the screen is unlocked (caffeinate -dimsu).
* Cross-game sync verified: 6 characters / 897 completed-quest records unioned across the 4 clients
  (docs/CROSS_GAME_SYNC.md; launchd agent blocked by TCC until luajit gets Full Disk Access).

## One-step window + login sync (2026-08-20, evening)
* Guide window shows ONE step: icon, "Accept  Title", note, distance/zone, route line; back/forward
  page arrows (back = un-complete last, forward = mark done). No tick box - steps complete themselves
  (Progress.CheckStep from quest log / bags / position / taxi / bind). Click the card for the detail popup.
* Login sync: Account.HarvestCompleted pulls C_QuestLog.GetAllCompletedQuestIDs (GetQuestsCompleted on old
  clients) into the character's account record at +3 s and +20 s, QUEST_TURNED_IN keeps it live; Progress.Refresh
  now auto-completes in passes until stable, so a guide picked up mid-way autofills. Other characters' records
  fill in when THEY log in; account-wide step crediting stays opt-in (Options).
* Guide browser: a guide shows "(CharacterName)" in green only when WHOLLY complete (every turn-in quest done, or
  every step ticked for quest-less guides); partial progress keeps the yellow percentage.
* Not yet verified on screen (client live). Offline suite covers harvest/autofill/(Character)/UI shape.

## Route sweep: every guide, every zone, every flavor (2026-08-20)
`luajit tools/route_sweep.lua <era|tbc|mop|retail>` routes EVERY guide offline with REAL zone bounds
(tools/maps_<flavor>.lua from wago.tools UiMap/UiMapAssignment via tools/gen_maps.py), player placed at the
guide's zone centre at the guide's min level, and checks: steps resolve to a location, the optimizer's order
respects A < C < T and PRE-before-accept, the optimized head window is never slower than author order, and a
route exists to step 1. `python3 tools/collect_route_sweep.py` → `docs/verification.sqlite` table `route_sweep`.
Result (all four): 0 load errors, 0 precedence violations, 0 optimizer-slower, 0 no-route;
located steps era 76.4 % (the rest are TBC/Outland guides that cannot exist on an era client), tbc 97.5 %,
mop 98.2 %, retail 97.0 % (rest: profession/"Instances & Other" guides with no zone at all).
Three real bugs this found and fixed: (1) quest-DB guides carry Classic-era uiMapIDs (Eastern Plaguelands 1423)
which MoP Classic / retail number differently (23) → 36k MoP steps had NO location — now resolved by name via
`Data/ZoneAliases.lua` (+ renamed/split-zone aliases, e.g. The Barrens → Northern Barrens); (2) a step without |Z|
now inherits the previous step's zone (guide semantics) instead of having none; (3) StepOrder keeps the
author's order when its heuristic is not strictly cheaper. Guide window rows are now "1. Accept  Title" with the
distance (or zone) on the right. In-game check of the new rows still pending (client was live, no keystrokes).

## Routing round 3 (2026-08-20): faction-wide flights + roads
* Flight routing no longer depends on learned paths (`taxiPolicy=faction` default, unlearned legs labelled).
* Road network: `Data/Roads_*.lua` polylines → graph vertices (grid-bucketed), arrow follows via points,
  passive recorder turns play into road data, `tools/roads_from_trace.py` + `tools/trace_roads.py` make it
  shareable / image-authored. Details + caveats in docs/ROUTING.md. Offline suite covers faction policy,
  road preference, detour rejection, recorder → graph. NOT yet verified in game this round (Daniel is away and a
  WoW Classic client is live on screen - no keystrokes sent). Next: `/reload`, `/cr taxi`, `/cr road`, `/cr route`
  on the Stormwind → Burning Steppes case.


## Verified
* luajit offline suite (`luajit tools/test_offline.lua`) passes end-to-end: parser, Dijkstra
  (hearth-first + cross-continent boat), precedence-safe StepOrder, SuggestNext (pick/exclude/refit),
  baked import (797 legacy + 119 WoW-Pro), **guide-menu tree** (9 ordered categories, all 873 guides
  reachable when expanded, collapsed view clean, flat search).
* Earlier in-game rounds (see git log 66a6f55..140a03d): arrow, hearth button, quest-item button +
  cooldown, auto-complete, guide chaining, taxi handler, gear advisor, standalone baked guides,
  location-aware suggestion at login.

## Guide browser (new, 2026-08-19)
`/or guides` now shows a collapsible tree: Category (Leveling, Dungeons, Dailies, Gold,
Professions, Reputation, Achievements, Titles, ...) -> folder (original folder path, or zone
for WoW-Pro/native) -> guide, with counts and level-sorted folders. Typing in the search box switches
to a flat level-sorted list. `/or switch` jumps straight to the suggested next guide.
Headless checks live at the end of tools/test_offline.lua via `NS.GuideMenu._test`.

## Quest DB (2026-08-19, goal: every quest, every version)
tools/gen_quest_guides.lua bakes EVERY quest from a local Questie checkout into per-zone "Quests"
guides (A/C/T steps, PRE chains, class tags, faction split; router optimizes order). Generated for
era/tbc/wotlk/cata/mop: 47,509 quests -> 1,380 zone guides, each file self-gates on NS.flavor so all
five ship in every TOC. Output is gitignored (Questie=GPL): run
  git clone --depth 1 https://github.com/Questie/Questie /tmp/Questie
  for fl in era tbc wotlk cata mop; do lua tools/gen_quest_guides.lua /tmp/Questie $fl; done
(needs lua5.4 - luajit hits the 65k-constant limit). Verified in-game on Anniversary: Quests category
(140 Horde-visible guides), Tirisfal Glades Quests (Horde) loads with 232 steps and live routing.
Multi-version (verified in-game 2026-08-19): single codebase, identical UI on every client.
* BC Anniversary (_anniversary_): full verification incl. tree, icons, quest guides (Tirisfal 232 steps).
* Classic Era (_classic_era_): 1347 guides, era Quests category (99), routing + chaining live.
* Mists Classic (_classic_): 4264 guides, mop Quests category (280), all 11 icon categories.
* Retail (_retail_): VERIFIED in-world 2026-08-19 (Orialan, Orgrimmar Embassy). 9462 guides, all 11
  icon categories; `/or scan` chat confirm; 'Orgrimmar Quests (Live)' loaded from the tree with 2
  live-scanned steps (Complete/Turn in: Report to the Trading Post) and full routing (arrow +
  "Walk 190 yd, ETA ~17s"). Login: token auth works, no password needed; Midnight launch queue was
  the only delay (7 -> 108 -> cleared after ~1h; one BLZ51900001 disconnect mid-queue).
Retail quest coverage: Adapters/DynamicQuests.lua (retail-gated) builds '<Zone> Quests (Live)' guides
from C_QuestLog.GetQuestsOnMap + C_QuestLine quest lines (Loremaster-style zone storylines), rebuilt
on zone change / login / `/or scan`.
Launcher automation gotchas: Battle.net 'GAME VERSION' dropdown is per-page; era page lists only its
3 rulesets - switch products via the retail page's GAME VERSION dropdown (PTRs + BCC Anniversary +
WoW Classic + Mists + retail). Clicks need window-origin +30pt offset; front the app and click inside
ONE python process.

## Testing tips
* WoW keystrokes via scratch type.py only after `lsappinfo front` == "Wow" (a mis-focused burst
  once typed into the terminal). `/or log` opens a copyable in-game log; Trade chat drowns prints.
* Battle.net launcher auto-logs-in (account solcus); WoW Classic favorite -> Burning Crusade
  Anniversary -> Play. Client loads from /Volumes/x10 and can take minutes to show a window.
* Install: `tools/install.sh` (bakes guides + rsyncs into _anniversary_ AddOns).
* Offline tests need luajit (lua5.4 lacks unpack); first run after iCloud eviction may need
  `cat CompletionRoute/Guides/Imported_*.lua > /dev/null` to materialize the baked data.

## Next
1. In-game screenshot pass on the new tree menu (open `/or guides`, expand Leveling, load a guide).
2. More native guides (1-20 both factions).
3. Road/wall data for walking accuracy (docs/ROUTING.md).
4. Real-play-session polish items (arrow bearing at speed, item button timing).

## Dev tooling & test suite (added 2026-08-19)
Researched community/Blizzard addon-dev resources and adopted the standard toolchain:
* `.luacheckrc` — luacheck (brew-installed) with WoW API read_globals; 0 errors.
  Found+fixed a real bug: ItemScore tooltip hooks used `local _, link = tip.GetItem and tip:GetItem()`,
  which truncates multi-returns, so `link` was ALWAYS nil (tooltip score annotation never fired).
* `tools/validate_toc.lua` — all 4 TOCs: files exist, no dupes, Interface + SavedVariables consistent.
  Gitignored baked `Guides/Imported_*` are skip-not-fail so CI checkouts pass.
* `tools/test_load_all.lua` — loads every own file from each flavor TOC under an auto-stubbing
  WoW mock (metatable stubs); catches syntax/load-time errors per flavor. 36/36 x4 clean.
  Third-party Libs/ are skipped (need a real client env).
* `tools/test_offline.lua` — baked-data assertions now BAKED-gated so it passes in fresh checkouts.
* `.pkgmeta` + `.github/workflows/release.yml` — BigWigs packager release on `v*` tags (GitHub
  releases now; add CF_API_KEY/WAGO_API_TOKEN secrets for CurseForge/Wago later).
* `.github/workflows/ci.yml` — luacheck (fail on errors only; 38 benign unused-local warnings
  remain visible) + all three Lua test tools on push/PR. Verified by simulating CI in a fresh
  local clone (no baked guides): all green.
Useful references: warcraft.wiki.gg addon API docs; in-client `ExportInterfaceFiles code` console
command dumps Blizzard's own UI source; BigWigsMods/packager; luacheck; wowUnit (in-game test
framework) if we ever want in-client assertions.

## 2026-08-20 — Target beacon + account-wide progression (PR #1, branch `beacon-and-account-progress`)
Shipped (see docs/BEACON_AND_ACCOUNT.md for the full design):
* `CompletionRoute/UI/Beacon.lua` — marker over the step NPC/mob's head via nameplates, matching marker
  on target/mouseover frames, secure `/targetexact` button on the arrow, minimap + world map pins.
* `CompletionRoute/Core/Account.lua` — all progress in `CompletionRouteDB.chars["Name-Realm"]`, opt-in
  `profile.accountWide` (default OFF so completionists do everything on every character).
* `/or verifyfeatures` (+ silent auto-run 30s after login) → `CompletionRouteDB.featureVerify`;
  `tools/collect_verify.py` → `docs/verification.sqlite`; `docs/verification.sql` = schema + reports.
* Offline coverage: `tools/test_offline.lua` sections 7 and 8. All green, all 4 flavors load clean.

### Pathways considered for "graphic over its head"
1. **Nameplate anchor (chosen).** `C_NamePlate.GetNamePlateForUnit` exists in Era through retail and
   is the only supported way to attach a frame to a unit's world position. Downside: the unit must
   have a nameplate up (in range, nameplates enabled).
2. World-space 3D overlay — **impossible**, no API projects world→screen for arbitrary points.
3. Raid target icons (`SetRaidTarget`) — **rejected**, needs group lead and overwrites the group's marks.
4. `C_SuperTrack` / blizzard quest POI arrows — retail-only, and hands control to Blizzard's own
   tracker; kept out so behaviour is identical across flavors.
Ground objects and loot containers have no nameplate and no world anchor, so those fall back to the
map pins. If a future flavor exposes an object-tracking API, extend `Beacon.UpdatePins`.

### Pathways considered for cross-character progress
1. **Single account table + per-character keys (chosen).** One `CompletionRouteDB.chars` map; reads union
   on demand. Cheap, survives character deletion (`/or forget`), and the opt-in gate is a single
   branch in `Progress.IsDone`.
2. Mirror-on-write into both SV files — rejected, two sources of truth drift.
3. Quest-ID-level union instead of step-index union — more accurate across *different* guides
   covering the same quest, but needs a quest→step reverse index for ~50k quests. **This is the
   natural next improvement**: build `qid -> {guide, step}` once at login and union on QID so a
   quest done on an alt clears the equivalent step in a different guide too.

### Superseded — verification is DONE (see docs/VERIFICATION_2026-08-20.md)
All four flavors were launched and verified live on 2026-08-20: era 1445/1445, tbc 1641/1641,
mop 4430/4430, retail 9519/9519 guides load, and 16/16 feature checks pass on every flavor.
The note below is kept for history.

### (historical) Still open
* **In-game verification of these two features has NOT been done.** On 2026-08-20 a live FFXI
  client (another session's benchmark) held the display for the whole work window and Daniel's
  standing rule is: if FFXI is running, do not take over the screen. Everything else — offline
  tests, per-flavor load tests, TOC validation, install to all four flavors — is green.
  When the display is free, run `python3 tools/verify_ingame.py _anniversary_ _classic_era_
  _classic_ _retail_` then `python3 tools/collect_verify.py`; CompletionRoute auto-runs its verifiers
  25s/30s after login so nothing has to be typed into the client. In-game screenshot proof of the
  nameplate marker over a real NPC's head is the one piece that still needs a human-visible pass.
* The QID-level union described above.
* Guide-list badge only shows for already-parsed guides; a cached step-count table would let every
  row show a percentage without parsing 9k guides.


## 2026-08-20 (afternoon) — renamed to CompletionRoute, Next Step category, all four flavors verified
* Addon renamed **OpenRoute -> CompletionRoute** (folder, TOCs, title, chat prefix,
  `CompletionRouteDB`). `/cr` and `/completionroute` are the new slashes; `/or` and `/openroute`
  still work. Installed SavedVariables were migrated in place and progress survived (verified in
  the live client). The old installed folders were moved to `<WoW>/AddOns-archive/`, so exactly one
  copy is live per client.
* **Next Step** is now the first category in the guide browser: everything level-matched to you
  right now, ETA-sorted. See docs/BEACON_AND_ACCOUNT.md section 3.
* `tools/queue_verify.py` arms the whole-catalogue sweep from disk, so no slash command has to be
  typed into the client (this is the reliable pathway — see the verification doc for why).
* Three real defects the sweep found were fixed and re-verified: WoW-Pro `s` steps, lazily-empty
  placeholder guides, and the arrow-check race in the feature verifier.

### Next
1. Native 1-20 guides for both factions (still the weakest content area).
2. Quest→step reverse index so the account-wide union is per-quest everywhere, not just on T steps.
3. Cached step counts so every guide row can show a completion badge without parsing.
4. Road/wall data for walking accuracy (docs/ROUTING.md).

## 2026-08-21 — manual step navigation and prerequisite gating
Both reported from a live Terokkar Forest run on the Anniversary client.

* **Back arrow did nothing.** Two causes, both fixed in `Core/Progress.lua`:
  1. `P.Undo()` un-ticked the *highest* done index, but the auto-completer scans 40 steps ahead, so
     that index was usually a step in the future — the visible step never moved. Undo now reopens the
     newest done/skipped step strictly *before* the current one (falling back to the global newest).
  2. Whatever it un-ticked was immediately re-ticked by the next `P.Refresh()`, because the quest is
     genuinely complete in the game. Reopened steps are now pinned in
     `NS.db.char.reopened[guideId][index]`: `P.IsDone` returns false for them and the auto-completer
     skips them until the player ticks forward again (`P.Forward()`, the > arrow, `/cr next`).
     `P.Reset()` clears the pins. `/cr back` and `/cr prev` are aliases of `/cr undo`.
* **A quest whose prerequisite is not met (or that is already done) still being pointed at.**
  `PRE|a;b` is an *any one of* list (Questie's `preQuestSingle`), but `Core/Conditions.lua` required
  *all* of them; `PRE|a&b` (`preQuestGroup`) is the all-of form. Conditions now honours the
  `andor` flag the parser already sets. `tools/gen_quest_guides.lua` used to emit only the first id
  of `preQuestSingle` and ignored `preQuestGroup` entirely — it now emits the full list with the
  right separator (regenerate the `Imported_Quests_*.lua` files from a Questie checkout to pick this
  up; the shipped ones still carry the single-id form, which is a subset and stays correct).
* **Diagnostics for the remaining case.** `/cr why` now prints, per quest, `client=` (what
  `IsQuestFlaggedCompleted` says) vs `harvested=` (what the login sync recorded) plus the prereq
  state of the current step; new `/cr quest <id>` prints the same for any quest and lists every step
  in the loaded guide that references it with its done/applies flags. If a step is still shown for a
  quest the character finished, that output says whether the client or the harvest is the liar.
* Offline regression tests added for both (`manual step navigation OK`, `prereq gating OK`);
  full `tools/test_offline.lua` suite green, installed to all four flavors.

### Not verified in-client yet
The two fixes above are covered by offline tests only — the Anniversary client was not driven for
this change (no screen takeover was taken). Confirming in game means: load a zone guide, click <
twice and check the step text walks backwards and *stays* there through a `/reload`.

## 2026-08-21 (later) — class-coloured hand pointer, corpse runs, name check

### Name: "Completionist's Guide"
Free as far as I can tell. No addon by that name on CurseForge, WoWInterface or GitHub; the
github.com/danielalanbates/completionists-guide slug is unused. Nearby names that DO exist and are
worth knowing about before committing: *Sue's Completist Guide* (a RestedXP achievement-leveling
guide), *Quest Completist* (5.2M downloads), *Completionism*, *Battle Pet Completionist* and
*ALL THE THINGS*. None of them is a routing addon, so the space is clear, but "Completist"/
"Completionist" is a crowded shelf — the current name (CompletionRoute) is the more searchable of
the two. CurseForge itself 403s scripted requests, so the slug check there is from search results,
not a direct 404; confirm by trying to claim the project name at upload time.

### Pointer is now a hand
* New `Textures/hand.tga` (generated by `tools/gen_textures.py`): a pointing hand drawn as one
  silhouette — index finger up, folded knuckles, thumb across the fist — in white with a dark
  outline, so `SetVertexColor` tints it. The union-then-outline trick in the generator is what stops
  it reading as three separate pills.
* `profile.arrow.style` = `"hand"` (new default) or `"arrow"` (the old three-colour chevron).
  Toggle with `/cr pointer` or the checkbox in `/cr options`.
* The hand is tinted to the player's **class colour** (`CUSTOM_CLASS_COLORS` first, so ElvUI-style
  overrides win). Distance still reads at a glance because the tint is dimmed to 0.72 past 400 yd
  and brightened to 1.25 within 60 yd — the chevron's green/yellow/red is unchanged if you prefer it.

### Death
* `Router.Recommendation()` now short-circuits on `UnitIsDeadOrGhost`, before any item or Hearthstone
  branch, so the pointer never offers something a corpse cannot click.
  - dead but not released -> "You are dead - release your spirit", no direction.
  - ghost -> mode `corpse`: the hand points at the body, with distance and a ghost-speed ETA.
    Position comes from `C_DeathInfo.GetCorpseMapPosition` on the current map, then its parent map.
    If the client will not say, the pointer says so and defers to the minimap corpse marker.
* The secure item button is force-hidden while dead, and `Beacon.WantedNames()` returns nothing, so
  over-head markers and the /target macro go quiet until you are back on your feet.

Offline tests: `death handling OK`, `pointer style OK`. Whole suite plus load/TOC/access tests green,
installed to all four flavors. Still not driven in a live client this session — the hand was
pixel-checked as a rendered PNG at in-game size in three class colours, not in game.

## 2026-08-21 (evening) — guide menu: scope check box + completion counts
* **Big scope check box** at the top of the guide browser, above the search field. Checked reads
  **"All characters"**, unchecked reads **"This character"**, with a grey line under it saying what
  that means. It is the same setting as `/cr accountwide`, so the two stay in sync in both
  directions, and flipping it re-scans the counts and refreshes the loaded guide's progress.
* **Completion count on the right of every row.** Category and folder rows show
  "*n* completed" (green once every guide under them is done, amber otherwise); guide rows show
  "completed" or their percentage.
* Deciding whether a guide is finished means parsing its steps and comparing the quests it turns in
  against what has been done — impossible to do inline for a 9.5k-guide retail catalogue on every
  keystroke. So it runs as a **background scan while the menu is open**, 40 guides per frame (~4s
  for retail, once), rows showing `...` until their guide has been answered. Step tables parsed
  purely to answer the question are dropped again, so the scan does not balloon memory. Results are
  cached per scope in `Account.doneCache` and cleared by `Account.ClearCompletionCaches()` whenever
  the completed-quest set or the scope changes.
* New `Account.GuideIsComplete(guide, "char"|"account")` is the scope-aware form of the existing
  `GuideCompletedBy`.
* Offline test `guide menu OK` covers the check box, the per-guide scan verdicts and the category
  roll-up. Whole suite plus load/TOC tests green; installed to all four flavors. Not seen in a live
  client yet — the numbers and layout are verified headlessly only.

## 2026-08-21 (night) — four-way scope selector, reworked hand, source check

### Are there official open source repos for commercial guide suites?
No. Commercial guides are closed-source and subscription-only; there is no official source repository.
What is on GitHub are occasionally community forks of old 3.3.5a era scripts. Useful as behaviour
references only — they are someone else's proprietary code, so nothing from them goes into this addon.

### Scope selector replaces the check box
The scope is no longer a yes/no, so it is no longer a tick box. The guide menu header is now a
label plus a small up/down pair (mouse wheel works too) stepping through four settings, narrow to
wide, each with a one-line explanation underneath:

| scope | means |
|---|---|
| `char` | This character |
| `realm` | This server — every character on this realm |
| `flavor` | This game type — Anniversary / Classic Era / Modern / … and Hardcore counted separately |
| `account` | All characters |

* `Account.Scope()` / `SetScope()` / `SCOPES` / `ScopeLabel()` / `ScopeDetail()` / `CharInScope()`.
* `profile.scope` is the new setting; `profile.accountWide` is kept as a mirror and **anything that
  still writes the boolean wins** — `Scope()` notices the disagreement and adopts it — so the options
  check box, old saved variables and the verifier's temporary override all keep working.
* Game type = client flavor + hardcore, because Hardcore progress is not interchangeable with normal
  progress on the same expansion. Hardcore is read from `C_GameRules.IsHardcoreActive` and stored per
  character as `gametype`.
* `OtherDid`, `OtherDidQuest`, `GuideProgress` and `GuideIsComplete` all filter by scope now.
* `/cr scope char|server|gametype|all` prints or sets it; `/cr accountwide` still toggles char/account.

### Hand pointer, second pass
The first hand was primitives unioned together and read as stacked pills. It is now traced as **one
continuous closed outline** (`HAND_OUTLINE`, a Catmull-Rom curve through 34 control points) with
named interior creases, so the anatomy is in the silhouette: index finger up and left of centre,
middle/ring/little curled into the palm at descending sizes, thumb out and across, palm heel
narrowing to the wrist. Over that: a baked greyscale shade/highlight pass (lit upper-left), a
fingernail, and a dark outline taken from the silhouette itself.

Honest limit: this is a clean stylised hand, not photoreal, and it should not try to be. The texture
is displayed at ~56 px and multiplied by a flat class colour, which destroys skin tone, freckles and
any fine texture — anything photoreal would turn to mush. If you want a photographic hand, the way to
do it is an authored PNG/TGA asset (or a Blizzard cursor rip) shipped un-tinted, and we would lose
the class-colour idea. Say which you prefer and I will build that instead.

Preview renders live in the scratchpad (`hand6.png`), verified at in-game size in three class
colours over a mid-tone background. Whole offline suite, load tests and TOC validation green;
installed to all four flavors. Nothing in this batch has been seen in a live client.

## Quest location audit: retail (2026-10-15)
`tools/audit_quest_locations_retail.py` checks every A/C/T step that has a single QID in the retail guides, using the
locations the addon itself parses (`tools/dump_quest_steps.lua`, so zone-name resolution is included). Each step is
converted to world yards with `tools/maps_retail.lua`.
References:
* **T**: Blizzard turn-in pin (QuestPOIBlob objective -1) or a Questie ender spawn.
* **C**: the objective's POI area (inside it or within 40 yd). Achievement "complete quest" criteria also accept the turn-in.
* **A**: Questie giver spawns (all of them; `tools/questie_spawns.lua`, MoP DB wins). Post-MoP quests have no giver
  data, so they are checked only by cross-source consensus: two independent sources (WoW-Pro, legacy, and the
  generated files counted as one source) agree within 40 yd and this step does not.

A step is wrong when it is more than 40 yd from every reference. These also count as wrong: another
instance or continent, coords outside 0-100, an unknown zone, or no coords where a reference exists.
The tool corrects each wrong step to the nearest reference and writes the committed table
`Data/QuestCoordFixes_retail.lua` (19,373 keys). `Core/Guide.lua` (`G.ApplyCoordFix`) applies the table at parse time.
Each key is the step's own old location (`action|qid|qo|uiMap|x,y`), so only that exact step moves.
Detail: `docs/quest_location_audit_retail.tsv`. Tables in `docs/verification.sqlite`: `quest_location_audit` and
`quest_location_audit_summary`.

| File | Checked | OK | Wrong (fixed) | of which >40 yd / other zone / no coords | No reference | Disputed (not fixed) |
|---|---:|---:|---:|---|---:|---:|
| Imported_Quests_retail | 64,871 | 50,584 | 6,913 | 2,629 / 288 / 3,996 | 7,373 | 1 |
| Imported_Storylines_retail | 69,061 | 54,666 | 4,137 | 3,591 / 339 / 207 | 10,257 | 1 |
| Imported_Achievements_retail (quest C steps) | 11,647 | 4,571 | 157 | 34 / 6 / 117 | 6,919 | 0 |
| Imported_WoWPro_retail | 66,494 | 40,023 | 7,293 | 3,999 / 1,731 / 1,443 (+120 unknown zone) | 18,633 | 542 |
| Imported_Legacy_retail | 96,077 | 46,552 | 8,376 | 3,373 / 2,616 / 2,348 (+34 unknown zone, 5 out of range) | 40,494 | 560 |
| Leveling/Northshire (retail) | 43 | 27 | 4 | 4 / 0 / 0 | 12 | 0 |
| Leveling/Valley of Trials (retail) | 19 | 13 | 0 | - | 6 | 0 |

What the numbers mean:
* In the generated files most wrong A steps were the turn-in-pin fallback ("Approximate"), which WoW-Pro and the
  legacy guides placed somewhere else. Most "no coords" steps are pin-less T steps, now filled from the Questie ender.
* A legacy or WoW-Pro "other zone" step usually has the right x,y on the wrong map (a phased or duplicate map
  name such as Wandering Isle 378/2366, Mardum 672/720, or Shattrath coords tagged Terokkar). The fix moves
  the step onto the POI's map.
* Disputed (1,258; was 1,104 before the verifier pass): the step is off Questie's giver, but no second source backs Questie (Questie is MoP-era and
  some givers moved later). These were left alone.
* Not fixed:
  * 98 steps on maps without bounds.
  * Multi-QID "accept all" steps (skipped).
  * C steps for quests with no POI objective area: about 20k, most of the "no reference" count.
  * Post-MoP A steps without consensus.
* Re-audit with the table applied (`--verify`) leaves 449 residual flags (about 0.15%). These come from consensus
  shifting once outliers move. A second `--write-fixes` pass would need keys from fixed positions, so it was not run.
* About 40 steps that were already correct share a key with a wrong step (same qid, action and spot, but a
  different source) and move with it. The move is to a reference location, so they stay correct.
* C fixes go to the objective area's centroid. When the centroid falls outside a concave area, they go to the
  area vertex nearest the old spot.
* Re-run after any guide regeneration:
  1. `luajit tools/questie_spawns.lua <Questie>`
  2. `python3 tools/audit_quest_locations_retail.py --write-fixes`
  3. Then `--verify`.

  Keys are exact, so a regenerated file whose coords move just skips stale keys. The audit then flags those steps again.

## Quest location audit — classic flavors (2026-10-15)

Every A/T/C step with a QID in `Imported_Quests_{era,tbc,wotlk,cata,mop}.lua` and the two `Leveling/` starter guides was
checked against Questie 11.38.0 **with its Corrections applied** (A → starter NPC/object/item-source spawns, T → ender
spawns, C → objective creature/object/item-drop/killCredit/triggerEnd/extraObjective spawns), same uiMap, 40 yd tolerance
(map sizes from `tools/maps_*.lua`; 2.0 map-% where a map has no size). Tool: `tools/audit_quest_locations.lua`;
rows: `docs/quest_location_audit_classic.tsv` and table `quest_location_audit` in `docs/verification.sqlite`.

Root causes found and fixed in the generator (`tools/gen_quest_guides.lua` + new `tools/questie_env.lua`), then
regenerated into all four installed clients and Drive:
- Questie's `Corrections/*Fixes.lua` were never applied, so moved/corrected spawns and starters were stale.
- Cata/MoP used Questie's *classic* areaId→uiMap table (|Z|1429 instead of 37); Questie-Mists uses `Zones/data/MoP/`.
- C steps only looked at creature/object objectives; item objectives (drop sources), killCredit, triggerEnd and
  extraObjectives were ignored, leaving thousands of C steps with no coords.

| flavor | file | steps checked | wrong (>40 yd / wrong zone) | missing coords (ref existed) | fixed | no reference (after) |
|---|---|---|---|---|---|---|
| era | Imported_Quests_era | 11005 | 139 | 1434 | 1573 | 1565 |
| era/tbc/wotlk | Leveling/Northshire | 43 | 7 | 0 | 7 | 0 |
| era/tbc/wotlk | Leveling/Valley of Trials | 19 | 10 | 0 | 10 | 0 |
| tbc | Imported_Quests_tbc | 16831 | 188 | 2190 | 2378 | 2497 |
| wotlk | Imported_Quests_wotlk | 23547 | 330 | 4263 | 4593 | 3162 |
| cata | Imported_Quests_cata | 38906 | 1785 | 6438 | 8223 | 8546 |
| mop | Imported_Quests_mop | 45571 | 1967 | 11540 | 13507 | 9913 |

After regeneration every step that has a Questie reference is within 40 yd of one (0 wrong in all five files).
"No reference" = Questie itself has no mappable spawn (unknown starter, instance-only ender, event NPC); nothing invented.
Leveling guides: 17 coords corrected (e.g. *Sting of the Scorpid* is from Hana'zua, not Gornek; Milly Osworth is
north-east of the Abbey); they are now skipped on Cata/MoP clients, where those pre-Cataclysm quests do not exist.

Caveats: the audit and generator share the Questie loader, so the "after" result proves the files match corrected
Questie, not that Questie is right; faction-specific fixes (`LoadFactionFixes`) are not applied; the Cata DB came from
Questie v11.38.0 on GitHub (the installed copy ships without it); wotlk map sizes are tbc+mop tables merged.

**Verifier pass (retail, 2026-10-15):** independent recompute of 40 random fixes and 20 random unflagged steps
found A/T placements within 0-4 yd of the reference. One systematic flaw fixed: turn-in steps with no Blizzard
turn-in pin were moved to Questie's single MoP-era ender spawn even when two independent guide sources (WoW-Pro +
legacy) agreed elsewhere (e.g. 27457 Eastern Plaguelands caravan). Those 154 steps are now `disputed` and left
in place; fixes total 26,726 (table 19,373 keys). "consensus" Accept fixes (6,576 rows) are guide-vs-guide, not
authoritative data.
