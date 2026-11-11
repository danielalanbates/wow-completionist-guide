# Beta bug reports (`/cr bug`)

Daniel's beta is the only in-game check. A report has to carry everything needed to reproduce the problem
offline, because the AI never logs in or plays. This page covers what a report holds, how it gets into SQL,
and how to replay it.

**Nothing here has run in a real client yet.** All of it is tested offline against stubs and the virtual player
(`tools/test_bug_report.lua`, `tools/test_ingest_beta_reports.py`). The first in-game `/cr bug` is the real test.

## In game

* `/cr bug [what went wrong]` saves a report and prints its id, for example
  `Bug report era-20261110-153012-3fa2 saved (3 stored)`.
* The **Report** button on the guide window does the same. It saves the snapshot at the moment of the click,
  then opens a small box for an optional note (Enter saves the note, Escape skips it).
* `/cr bug list` shows the newest ten report ids with guide, step and note.
* Reports reach the disk only at `/reload` or logout, like all SavedVariables.

Reports live in `CompletionRouteDB.bugReports` (account-wide SavedVariables, one file per client folder), newest
first. The store keeps at most 50 reports and about 400 KB. One report is capped at about 16 KB; a larger one is
trimmed (log lines first, then the error stack, then long id lists) and marked `trimmed`.

## What a report holds

Code: `CompletionRoute/Core/BugReport.lua`. Every part is read under its own `pcall`; a part that fails is
named in `errors` and the rest still saves.

| Part | Fields |
|---|---|
| id, time | `id` (`<flavor>-<YYYYMMDD>-<HHMMSS>-<hex>`), `at`, `epoch`, `schema`, `note` |
| client | `client.flavor`, `dataFlavor`, `isForever`, `build`, `buildNum`, `interface`, `locale`; `addon.version` |
| character | `char.class`, `race`, `level`, `levelFrac`, `faction`, `speed`, `canFly`, `mounted`, `flying`, `dead`, `hardcore`. **No character or realm name.** |
| guide | `guide.id`, `name`, `type`, `source`, `baked`, `steps`, `authored`, `sum` (author-order checksum, the same `G.RouteChecksum` the bake uses) |
| step | `step.index`, `pos`, `action`, `title`, `line`, `raw` (the guide line as written), `qid`, `qo`, `zone`, `coords`, `locSource` (`guide`, `quest`, `zone`, `entrance`), `access`, `optional`, `item`, `pre` |
| upcoming | the 8 visible steps: index, action, title, quest ids, zone, point, location source, seconds from the step before (the first: from the player) |
| order and plan | `order` (the window order the player saw), `plan` (the live planner's kept plan, the baseline of its next refresh) |
| progress | done, skipped and reopened step indices of this guide (as ranges like `1..12,15`), counts, scope |
| quest log | `quests.done`, `log`, `complete` for every quest the guide names; `objectives` (fulfilled, required, finished) for those in the log; `items` (bag counts of the hearthstone and the items the visible steps use) |
| position | `player.map`, `mapName`, `x`, `y` (0 to 100), `wx`, `wy`, `inst`, `inInstance`, `instanceType`, zone text |
| route | `route.found`, `secs`, `desc`, and up to 12 legs with mode, title, from, to, world points, seconds, yards, new-flight-path flag; `arrow` (mode, text, why, ETA, distance, borrowed step); `stepOrder` (the planner's last info) |
| travel | taxi policy, known flight paths (ranges), hearth (learned or seed, ready or cooldown, hearthstone in bags), learned portal and boat spots (`transitFix`), the learned dungeon door for this step |
| options | the routing settings, scope, account-wide, arrow, beacon, auto-advance, debug |
| log and errors | the last 30 lines of the addon log (`/cr log`, debug lines included), `lastError`, `luaErrorCount` |
| cost | `captureMs` and `sectionMs` (what the click cost in the client) |

**Names.** The snapshot never reads the character or realm name. Free text (log lines, error text, the note) can
still carry one, for example the `/cr chars` listing, so every character and realm name the account store knows is
replaced by `<char>` or `<realm>` in those fields. Game text (titles, zone names) is left alone. A realm called
after a zone (Azshara, Silvermoon) is also replaced in the log lines; that is the price of the rule.

**Lua errors.** `Core/BugReport.lua` loads right after `Core/Init.lua` and wraps the client's error handler. The
wrapper always calls the previous handler and returns what it returns, so an error is never swallowed. It keeps
only errors whose message, or stack outside its own frames, names `AddOns/CompletionRoute/`. It is re-wrapped at
`PLAYER_LOGIN` if another addon replaced the handler. The same error raised again is counted, not stored twice. The
last one is kept in `CompletionRouteDB.lastError`, so a report made after a `/reload` still has it, with its age.
If an error-display addon that does not chain took the handler first, the report falls back to that addon's
own error list.

**Cost of a click.** The route comes from the arrow's own cached path (refreshed when it is over 20 s old or the
player moved 40 yd), and the upcoming steps' seconds are step-to-step costs the live planner already cached.
Measured under `luajit -joff` (the client's plain Lua 5.1 proxy) in the virtual player: under 1 ms on all five
flavors. The first version searched from the player for every visible step and cost 115 to 181 ms on
era, mop and retail.

## Into SQL

```
python3 tools/ingest_beta_reports.py                 # every client under /Volumes/x10/.../World of Warcraft
python3 tools/ingest_beta_reports.py --db /tmp/x.sqlite --sv path/to/CompletionRoute.lua
```

It reads `CompletionRouteDB.bugReports` from `<wow>/*/WTF/Account/*/SavedVariables/CompletionRoute.lua`. Each file
is converted by `tools/sv_to_json.lua` (luajit, empty environment, instruction budget, never written). The
script compares size and modification time before and after, and skips a file the game rewrote while it was
being read. Rows go into `beta_reports` in `docs/verification.sqlite` (or `--db`):

* key `id`; a report seen again is updated, never duplicated; the same report in two client folders counts once;
* summary columns: time, client folder, flavor, build, addon version, class, race, level, faction, guide, step,
  action, quest id, location source, map, x, y, route, route seconds, arrow mode, note, error, failed sections;
* `status` (default `new`) and `triage` are for whoever triages; ingesting again never overwrites them, nor
  `first_seen`;
* `json` holds the whole report;
* the account folder name is not stored, only a 10-character hash of it (`account`).

It prints a short summary and the new reports, newest first.

## Replay

```
luajit tools/vplayer.lua --repro <report id>          # looked up in docs/verification.sqlite (--db PATH)
luajit tools/vplayer.lua --repro latest
luajit tools/vplayer.lua --repro report.json          # a file: one report, a list, or sv_to_json output
luajit tools/vplayer.lua --repro <id> --show          # print the report only, load nothing
luajit tools/vplayer.lua --repro <id> --check         # exit 1 when the step or the route differ
```

Code: `tools/vplayer_repro.lua`, hooked into `tools/vplayer.lua`. The report decides the flavor (Forever included),
the order mode (baked when the client's guide was baked and `Data/RouteOrder_<fl>.lua` exists) and the live window.
It loads spine, gold and profession guide files when the guide is one of those. The virtual character is put
where the report says:

* faction, class, race, level with the XP fraction, dead or alive;
* the quest log (done, in log, ready to turn in) with objective counts, and bag counts;
* done, skipped and reopened steps, and the live planner's kept plan;
* flight paths known, taxi policy and the other routing options, the hearth (learned spot or the inn seed,
  cooldown, hearthstone), learned portal spots and the learned dungeon door;
* the travel speed and "can fly" exactly as the client measured them;
* map, x and y through the offline map transform. The script prints how far that lands from the client's world
  position, which also checks the map data. If the map is unknown offline, the client's world position is used.

It then prints the report as recorded, followed by the offline replay: guide text check (the author-order checksum
against the client's; a mismatch means the guide changed since the report and indices may not line up), current
step, route legs with seconds, the arrow, and the next steps next to the client's. The last line is
`RESULT MATCH <id>` or `RESULT DIFF <id>: step, route legs, route time, arrow mode`. Route time counts as the same
within 5 s or 5%.

A DIFF is information, not a failure of the replay. It means the offline world and the client disagree:
quest data, map data, a learned spot, the 3 ms budget the client had per planner call, or the bug itself.

**Self-test.** `luajit tools/vplayer.lua <flavor> --capture auto --capture-steps 7 --capture-out r.json` plays seven
steps of the first suitable guide in the fake world, moves to the faction capital so the route has several legs,
and saves a report with the real `Core/BugReport.lua`. `--repro r.json --check` must then say MATCH.
On 2026-11-10 it did on all five flavors with author order, and on era with baked order, for example era 5 legs
(walk, tram, walk, taxi, walk; 7m 40s on both sides), mop 7 legs, tbc 8 legs including a boat. This proves the
capture and the replay agree with each other in the fake world. It does not prove the client produces the same
report; only Daniel's first real reports can show that.

## Workflow

1. Daniel hits a problem, types `/cr bug what went wrong` (or clicks Report), keeps playing, and later logs out
   or reloads.
2. `python3 tools/ingest_beta_reports.py` (on the 8 GB Mac, as the only heavy job).
3. For each new id: `luajit tools/vplayer.lua --repro <id>`. MATCH means the bug reproduces offline and can be
   fixed and tested there. DIFF points at where the offline model and the client part ways.
4. Set `status` and `triage` in `beta_reports` when it is understood or fixed.

## Not done

* The reason menu on right-click skip (wrong place / can't do / already done) proposed in `docs/IDEAS.md`.
* An opt-in to keep the character name, and the companion app view of reports.
* The fallback to an error-display addon's own list is written against BugGrabber's `GetDB()` and is not tested
  against the real addon.
* `/cr bug` in a real client on any flavor: not run. Frame code (`InputBoxTemplate`, `BackdropTemplate`) and the
  error-handler chain are written to the documented APIs and load under `tools/test_load_all.lua`, nothing more.
