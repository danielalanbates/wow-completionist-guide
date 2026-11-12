# CompletionRoute — the completionist's guide to World of Warcraft

*(formerly OpenRoute — same addon, renamed to say what it is. `/or` still works.)*

Community-driven guides for **every** quest, with optimal travel routing,
progress tracked **across all your characters**, and a marker over the head of whatever the current
step wants you to find. One addon, every version of the game — Era, TBC Anniversary, Mists, retail, WoW Forever.

**Status: beta.** v1.0.0 was withdrawn on 2026-11-07 (it bundled third-party guide content). v2.0 — Warcraft Wiki as the source of truth — is in progress; see [docs/FINISH_PLAN.md](docs/FINISH_PLAN.md).
Built as a comprehensive replacement for proprietary subscription guide addons that keeps the *one thing* no free addon has:
an optimal travel-routing engine (flight paths, boats/zeppelins/portals/tram, Hearthstone) driving a
smart arrow — while the guide content is community-driven and open.

## What it does today

| Feature | CompletionRoute |
|---|---|
| Guide viewer with steps that auto-complete | ✅ `UI/GuideFrame.lua` + `Core/Progress.lua` (quest accept / objectives / turn-in / run-to / hearth / fly / level / item events). *Offline-tested only (2026-11-12):* talking to the NPC a step names (one step per conversation), a merchant on a repair/sell step, `L` items on every kind of step, a bought item, any of a step's `ALT` places, a chest looted at a treasure's spot, a mission's success. What completes what: [docs/GUIDE_FORMAT.md](docs/GUIDE_FORMAT.md); what stays manual: `tools/census_step_kinds.lua` |
| Recent routes | *Offline-tested only:* the routes list opens with **Recent**: the routes this character has finished steps in, most recently used first (12 at most), each with its progress; click to load. Kept per character, survives `/reload`, parses no guide |
| Start over | *Offline-tested only:* a finished route shows a **Start over** button next to its end text; the step's right-click menu and the window's `...` menu offer it at any time (they ask first while steps are left). It clears the route's marks for this character and goes back to step one (`/cr reset` does the same). Circuits still lap by themselves |
| Waypoint arrow | ✅ `UI/Arrow.lua` — an archery arrow in natural colours (`tools/gen_pointer.py`), world-coordinate bearing via HereBeDragons, distance under it |
| Arrow turns into the quest item when you should click it | ✅ secure item button replaces the arrow (`|U|itemID` / `|ITEM|` tag; combat-safe: queued until you leave combat) |
| Arrow turns into Hearthstone when hearthing is faster | ✅ router puts a `hearth` leg first when `(cast + cooldown + walk from inn) < walking/flying`; button shows Hearthstone (or Astral Recall, or a hearth toy when no Hearthstone is in the bags) |
| Class teleports, transporters, hub hearthstones | ✅ *branch routing-graph, not yet run in a client:* `Data/Teleports.lua` — mage teleports, Teleport: Moonglade, Death Gate (MoP Classic), engineering transporters (Engineering only), Dalaran and Garrison hearthstones, 36 hearth toys; used as a first leg when known or owned with at most 15 min of cooldown left; the arrow's button casts or uses it (`/cr teleports`) |
| Travel system: flight paths, boats, zeppelins, portals | ✅ `Routing/TravelGraph.lua` Dijkstra over ~180 taxi nodes (real polyline lengths from game data) + `Data/Transit.lua` |
| Only uses flight paths you have discovered | ✅ *branch routing-graph:* a flight lands only at a flight master you have discovered (per character on Classic Era, TBC and MoP Classic; account-wide on Retail and WoW Forever, as the client shares them); the route may walk you to a new one and says "pick up the flight path". Learned from the flight map and at login |
| Optimal quest routing for the chosen guide | ✅ `Routing/StepOrder.lua` — precedence-constrained reordering of the next N steps (accept → complete → turn-in kept, anchors like *run to zone* respected) |
| Skip quests | ✅ `Core/Skip.lua` — drop a quest from every guide; if other quests need it you are warned first, with their names, and confirming drops the whole chain. Breadcrumbs never block. The guide is rebuilt without those quests and without any quest it could then no longer offer (steps, counts and progress follow), then re-planned for travel time in the background (`Routing/Replan.lua`). `/cr unskip` brings everything back — [docs/ROUTING.md](docs/ROUTING.md#skipping-quests) |
| Auto accept and turn-in (guide's quests only) | Built, offline-tested only: `Core/QuestAuto.lua`, off by default. Accepts and hands in only the quests of the guide's next steps, never skipped or dropped quests, never quests that cost gold, dailies the guide does not ask for, or a reward choice (unless the gear score sees a clear upgrade and you allow it). Hold Shift (or your chosen key) to do a quest giver yourself. Options > Auto quests, `/cr auto` — [docs/QUEST_AUTO.md](docs/QUEST_AUTO.md) |
| Guide library | ✅ every guide is built by this project: generated from the Warcraft Wiki and Blizzard client data, with players' own location contributions where both leave a gap, plus hand-written starter guides in `Guides/Leveling/`. No other addon's guides are read or needed |
| Quest coverage | ✅ generated zone guides from the **Warcraft Wiki**, with **Blizzard's own quest pins** on Retail where the wiki gives no point, then **players' contributed places** where neither has one (`tools/wiki/gen_wiki_guides.py`; none merged yet). A quest the wiki has no page for is not in a zone guide; Retail's live per-zone list (`Adapters/DynamicQuests.lua`) and the quest-line guides cover some of those. Numbers per client: [docs/STATUS.md](docs/STATUS.md) |
| Gold guides | ✅ realm-independent money guides by level, on every client: gathering, mob farming and fishing **circuits** you walk with nothing to click, plus daily gold, instance runs and step-by-step methods. No prices are shipped; laps are priced in game from Auctionator if present, else vendor value — [docs/GOLD_ROUTES.md](docs/GOLD_ROUTES.md) |
| Secondary professions | ✅ Cooking, Fishing, First Aid and Archaeology by client, with nearest trainer, a computed recipe path, skill targets that tick themselves, and live Archaeology dig-site circuits — [docs/PROFESSIONS.md](docs/PROFESSIONS.md) |
| Guides listed by level | ✅ `UI/GuideMenu.lua` + `Core/Recommend.lua`: a **Recommended** section on top of the routes list (the closest unfinished quest routes that fit your level, closest first, with the travel time; one graph search prices them all), *Only guides for this level* filter, *Group by level* tree, and profession guides matched to your real skill |
| Dungeon guides | ✅ steps inside an instance route to the **entrance** once it is known: a door you have walked through, or the Retail encounter journal (`Core/Instances.lua`). No door table ships, so a door you have not seen yet is "no route" on the Classic clients |
| Options | ✅ `/or options` (Settings panel), `/or` commands |
| Progress survives guide updates | Built, offline-tested only: ticks, skips and stepped-back steps are stored by a stable step key (quest + objective, or a hash of the step's words; never its line number or coordinates), so in a regenerated guide marks stay on their steps when lines are added, removed or moved. Two exceptions: a step whose quest-less text is reworded loses its mark (it is not given to another step), and among identical repeated steps (same quest and objective, or same words: 2.4-4.0% of steps) adding or removing one ahead of the others shifts their marks to a neighbouring identical step. Old progress is carried over once per character and guide; the previous release still reads its own tables after a downgrade. `/cr marks` shows how the loaded guide's progress is stored — [docs/STEP_KEYS.md](docs/STEP_KEYS.md) |
| Contribute | Built, offline-tested only: a **Contribute** box on the guide window. While ticked, the addon notes where you stand when you accept or turn in a quest, when an objective ticks and when you click the forward arrow; works out the most likely place for every step; routes steps that have no location to it; and draws the areas on the world map. Positions and quest ids only, kept locally; clicking the word **Contribute** (or `/cr contribute export`) gives a text to share — [docs/CONTRIBUTE.md](docs/CONTRIBUTE.md) |
| Beta bug reports | Built, offline-tested only: `/cr bug [note]` or **Report a bug** in the guide window's `...` menu saves a snapshot (guide, step, open steps, position, route, quest log including quests that only gate a step, profession skill, last 30 log lines, last addon Lua error; no character or realm name). `tools/ingest_beta_reports.py` loads reports into SQL and `vplayer --repro <id>` replays one offline — [docs/BETA_REPORTS.md](docs/BETA_REPORTS.md) |
| Release packager with a data-provenance gate | 🚧 `tools/package_release.py` ([docs/RELEASE.md](docs/RELEASE.md)): one universal zip, `provenance.json` for every file, `LICENSE.txt` + `ATTRIBUTION.md`; fails on data derived from another addon, personal data, secrets, symlinks and broken TOC lines. Dry run by default, never tags or publishes. There is one build: the TOCs, the installer and the packager handle the same files. |

Not yet: primary profession guides, talent advisor, gear finder, model viewer, guide editor UI, Zen Pilgrimage / Dreamwalk / class-hall teleports, indoor/dungeon-aware walking, per-zone "wall" data.

## Where the guides come from

The routing engine is the product; the guide content is deliberately **community-driven and
regenerable**, so nothing here depends on a subscription staying alive:

| Source | Flavors | How |
|---|---|---|
| **Warcraft Wiki** (warcraft.wiki.gg, CC BY-SA 4.0) — **the source of truth** | era, tbc, mop, retail, forever | `tools/wiki/` (fetch → parse → `gen_wiki_guides.py`) writes `Guides/Imported_Wiki_<flavor>.lua`: per-zone guides with the wiki's givers, enders, chains (`PRE`), objectives and coordinates. Flavor membership is checked against each client's QuestV2. See [tools/wiki/README.md](tools/wiki/README.md) |
| Blizzard client data (wago.tools DB2 exports) | all | which quests a client has (`QuestV2`); on Retail the quest map pins (`QuestPOIBlob`/`QuestPOIPoint`) for steps the wiki gives no point for, quest-line order, achievements and missions (`tools/gen_completion_guides.py`); flight paths (`tools/gen_taxi.py`) |
| Player contributions (the add-on's **Contribute** box, merged in [wow-completionist-data](https://github.com/danielalanbates/wow-completionist-data), CC BY-SA 4.0) | all | where players stood on accept, turn-in, objective progress and a step ticked by hand. `gen_wiki_guides.py` gives a step that the wiki and the quest pin do not place its contributed area, only when a maintainer played it or two players agree; the step's note and the file header say so. None merged yet. See [docs/CONTRIBUTE.md](docs/CONTRIBUTE.md) |
| Hand-authored native guides | all | `Guides/` |

Generated guide files are gitignored (they are large and rebuilt by the generators); a release zip holds them.

**Open quest database.** The same wiki and Blizzard data, as plain JSON and SQLite for any addon or tool, is published
separately at [wow-completionist-data](https://github.com/danielalanbates/wow-completionist-data) (CC BY-SA 4.0). It covers
quests, givers and enders, prerequisites, NPCs, objects, achievements and missions for all five clients, and every record
names its source and a confidence for its map point. Corrections are welcome there as pull requests.

**Community data only, one build.** Completionist's Guide is built from the Warcraft Wiki and Blizzard client data, plus the project's own code and data and its players' own location contributions. Nothing derived from Questie or from any other addon, free or commercial, is read, generated, installed or shipped: the build the developer runs is the build a release ships (since 2026-11-11). The tools that once read a local Questie checkout are in `archive/questie-tooling/`; one explicit offline comparison remains in `tools/measure/` and never touches the add-on. At run time the add-on reads no other addon's saved data either: the GatherMate2 and Routes node import was removed on 2026-11-12 (farm circuits use the nodes you loot yourself). Two optional hooks remain and neither reads stored data: a lap is priced through Auctionator's public price function when that addon is loaded, and the TOCs name TomTom as an optional dependency (load order only; no code uses it).

## Verification — no characters required

`tools/vplayer.lua` runs the real addon against a mutable fake world and **plays every guide to
completion**: it walks to each step through the real router, performs the step's action against the
world, and lets `Progress.Refresh()` auto-advance exactly as it does in the client. Every guide,
every flavor, in minutes, with no subscription and no server — see [docs/VPLAYER.md](docs/VPLAYER.md).
Why a private server is *not* the answer: [docs/LOCAL_SERVER.md](docs/LOCAL_SERVER.md).
In-game runs (the real API, the real frames) are driven by `tools/run_flavor_verify.py` and charted in
`docs/verification.sqlite`.

## Install

```bash
tools/install.sh                     # copies CompletionRoute/ into _anniversary_/Interface/AddOns
tools/install.sh _classic_era_ _retail_
```
Or copy the `CompletionRoute/` folder into `Interface/AddOns/`.
Release zips are built with `tools/package_release.py` (see [docs/RELEASE.md](docs/RELEASE.md)); none is published yet.

### macOS Companion App (`/Applications/Completionist's Guide.app`)
A native, lightweight macOS AppKit companion application (400 KB, zero external dependencies) is maintained in `/Applications/Completionist's Guide.app`:
- Displays live status of all 4 installed WoW clients (`_classic_era_`, `_anniversary_`, `_classic_`, `_retail_`).
- One-click guide baking and multi-client addon synchronization.
- Interactive offline test suite runner and diagnostic console.
- Embedded SQL verification report query interface from `docs/verification.sqlite`.
To rebuild and deploy:
```bash
./app/build_app.sh
```

## Use

* `/or` — toggle guide window · `/or guides` — pick a guide · `/or route` — explain the current route
* `/or order` — show the optimizer's order for the upcoming steps · `/or taxi` — flight paths discovered (this character, account) and the flight rule · `/or hearth`
* `/cr teleports` — every teleport, transporter and hearth toy the router knows for your class, and whether it is offered
* `/cr farm` — farm circuits: status, `build`, `record`, `export`, `stats`, `radius`
* `/cr list [level] [category]` — best guides for a level · `/cr gold [level]` — gold guides · `/cr prof` — profession guides for your current skill
* `/or test` — routing self-test from your position to major cities
* `/cr skip [questID]` — skip a quest (default: the current step's); warns first when other quests need it · `/cr skipstep` — skip the current step (on an accept of a quest you do not have, that skips the quest, so its turn-in is not left behind)
* `/cr unskip <questID|all>` — bring skipped quests back · `/cr skipped` — list them and what they lock
* `/cr bug [what went wrong]` — save a bug report (also **Report a bug** in the window's `...` menu) · `/cr bug list` — stored reports · `/cr log` — the addon log
* `/cr reset` — start the loaded route over: clear its marks for this character and go back to its first step (also the **Start over** buttons)
* `/cr marks` — the loaded guide's progress: done, skipped and stepped-back steps, marks whose step a guide update removed, what was carried over from the previous release, and the guide's version checksum
* `/cr auto` — auto accept / turn-in settings and the last decision · `/cr auto accept|turnin|reward` — toggle one · `/cr auto on|off` · `/cr auto key shift|ctrl|alt|none` — the key that pauses it (Options > CompletionRoute > **Auto quests** has the same switches)
* Guide window: one title line (route name, step N of M, **Contribute** and its box, **Routes**, `...`, close), the step card (action and title, note, one distance line) and the travel line · steps complete themselves · right arrow = mark done · left arrow = back one step · click the step = details with Complete / Skip / Skip quest / Show on map · right-click the step = skip, details, Start over · `...` = reorder steps on/off, Options, Report a bug, Start over · the word **Contribute** opens the text to share · a finished route shows **Start over** · closed with x: Esc > Options > AddOns > CompletionRoute has **Show step window** and **Routes**

Open a flight master's map once on each continent so the router knows which flight paths you have.
Hearth once (or bind at an inn) so the router learns exactly where your inn is (a seed list covers common inns).

## Guide format

See [docs/GUIDE_FORMAT.md](docs/GUIDE_FORMAT.md). It is a one-step-per-line syntax
(`A Quest|QID|123|M|48.1,42.9|Z|1429; Elwynn Forest|N|note|`) plus CompletionRoute-only tags `|ROUTE|`, `|FIXED|`, `|RAD|` and the `G` farm-waypoint action.
Guides are plain Lua files registered in `CompletionRoute/Guides/Guides.xml`.

## Repository layout

```
CompletionRoute/            the addon (copy this folder into Interface/AddOns)
  Core/               Init, Util (HBD wrappers, quest/item helpers), Conditions, Guide parser, Progress, Slash
  Routing/            TravelGraph (Dijkstra), Teleports (teleport legs), StepOrder (optimizer), Router (facade + arrow recommendation)
  Data/               Taxi_<flavor>.lua (generated), Transit.lua (hand-authored), Teleports.lua (DB2 ids + wiki landing points), Inns.lua (seed)
  UI/                 Arrow, GuideFrame, GuideMenu, Options
  Adapters/           DynamicQuests.lua (Retail: live per-zone quest lists from the client)
  Guides/             native community guides (CC BY-SA)
  Libs/               LibStub, CallbackHandler, HereBeDragons-2.0
tools/                gen_taxi.py (wago.tools → Data), gen_textures.py, install.sh, test_offline.lua (luajit smoke test)
docs/                 design, format, verification log, roadmap / pathways for the next contributor
archive/              retired tooling kept for reference (questie-tooling/: tools that read a local Questie checkout)
```

## Development

```
luajit tools/test_offline.lua        # parser + Dijkstra + optimizer smoke test with a stubbed WoW API
luajit tools/test_load_all.lua       # every TOC's file list loads clean on all five flavors (incl. Forever)
luajit tools/test_wiki.lua           # wiki guides parse, are flavor-gated, quest 7 has A/C/T with coords, spine has 0 PRE violations
luajit tools/test_route_order.lua    # baked RouteOrder never breaks precedence, loads on every flavor
luajit tools/test_teleports.lua      # teleport data (landing points vs citations) + teleport legs, hearth toys, arrow button
../venv/bin/python tools/check_teleports.py --fetch --wiki   # every teleport id/name/reagent/cooldown vs DB2, every cited wiki page
luajit tools/vplayer.lua retail --shard 1/4    # play every guide; python3 tools/collect_vplayer.py
luajit tools/vplayer.lua era --guides-file F --taxi learn       # fly only into discovered flight paths (default --taxi all)
luajit -joff tools/vplayer.lua era --guides-file F --turnins    # time the QUEST_TURNED_IN handlers
luajit tools/route_sweep.lua era     # route every guide from its own zone
luajit -joff tools/test_step_window.lua   # step window layout rules on a widget mock (widths before heights, note under the title, one title line), card notes, menus, Start over
luajit -joff tools/test_flow.lua          # Recent list, Start over, the completion rules of 2026-11-12 (talk, merchant, items, ALT places, treasure, mission)
luajit -joff tools/audit_step_text.lua    # every step of every flavor: lines needed by title, note and travel line at the default window size (estimate from character counts)
luajit -joff tools/census_step_kinds.lua  # per guide family: which steps complete by themselves and from what, which stay manual
luajit tools/test_bug_report.lua     # /cr bug snapshot, error hook, caps, SavedVariables reader, capture/replay round trip
luajit -joff tools/test_progress_keys.lua   # stable step keys: regenerated guides keep marks, migration, downgrade, collisions + cost on all five flavors
luajit -joff tools/test_quest_auto.lua  # auto accept / turn-in on fake gossip, old-gossip and greeting clients, all five flavors
python3 tools/test_ingest_beta_reports.py      # beta_reports ingest on a fixture (temp database)
python3 tools/ingest_beta_reports.py           # Daniel's /cr bug reports -> beta_reports; then:
luajit tools/vplayer.lua --repro <report id> --check   # replay one offline; exit 1 on a DIFF (docs/BETA_REPORTS.md)
python3 tools/wiki/gen_wiki_guides.py          # regenerate the wiki quest guides and the spine (then gen_gold, gen_professions,
                                               # tools/gen_completion_guides.py, tools/gen_quest_deps.py; docs/RELEASE.md)
python3 tools/gen_taxi.py tbc 2.5.6.69110 era 1.15.9.69109 mop 5.5.4.69155 retail 12.1.0.69382
python3 tools/package_release.py               # release dry run: assemble, provenance gate, zip sizes (writes nothing)
python3 tools/package_release.py --write --version 2.0.0-beta1   # dist/<version>/ (gitignored; a failing build: dist/failed/); never tags or publishes
python3 tools/test_package.py                  # every release-gate rule fires on a planted bad file
python3 tools/test_contrib_gen.py              # player contributions into the guides: fixture areas, keys vs the add-on, provenance (temp folder only)
```

## License

Copyright (c) 2026 Daniel Bates / Bates LLC. **All rights reserved.**

Licensed under the **PolyForm Noncommercial License 1.0.0** with a commercial-use rider: noncommercial
use is free; any commercial use requires a separate licence from Bates LLC, standard terms being a
royalty of **10% of gross revenue** attributable to the product incorporating this software. See
[LICENSE](LICENSE). Ask for a commercial licence at **help@batesai.org** · <https://batesai.org>.

Not affiliated with Blizzard or any guide publisher. No third-party guide data is used or redistributed here.
