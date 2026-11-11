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
| Guide viewer with steps that auto-complete | ✅ `UI/GuideFrame.lua` + `Core/Progress.lua` (quest accept / objectives / turn-in / run-to / hearth / fly / level / item events) |
| Waypoint arrow | ✅ `UI/Arrow.lua` — world-coordinate bearing via HereBeDragons, distance + ETA, colour by distance |
| Arrow turns into the quest item when you should click it | ✅ secure item button replaces the arrow (`|U|itemID` / `|ITEM|` tag; combat-safe: queued until you leave combat) |
| Arrow turns into Hearthstone when hearthing is faster | ✅ router puts a `hearth` leg first when `(cast + cooldown + walk from inn) < walking/flying`; button shows Hearthstone (or Astral Recall) |
| Travel system: flight paths, boats, zeppelins, portals | ✅ `Routing/TravelGraph.lua` Dijkstra over ~180 taxi nodes (real polyline lengths from game data) + `Data/Transit.lua` |
| Only uses flight paths you have learned | ✅ learned when you open any flight map (`TAXIMAP_OPENED`), stored per character |
| Optimal quest routing for the chosen guide | ✅ `Routing/StepOrder.lua` — precedence-constrained reordering of the next N steps (accept → complete → turn-in kept, anchors like *run to zone* respected) |
| Skip quests | ✅ `Core/Skip.lua` — drop a quest from every guide; if other quests need it you are warned first, with their names, and confirming drops the whole chain. Breadcrumbs never block. The guide is rebuilt without those quests and without any quest it could then no longer offer (steps, counts and progress follow), then re-planned for travel time in the background (`Routing/Replan.lua`). `/cr unskip` brings everything back — [docs/ROUTING.md](docs/ROUTING.md#skipping-quests) |
| Guide library | ✅ native guides in `Guides/` (WoW-Pro line syntax, CC BY-SA) + a **runtime adapter** that reads your installed **WoW-Pro** guides (interop only, nothing copied) |
| Every quest in the game, covered | ✅ generated zone guides: Classic flavors from a local **Questie** checkout, **retail from Blizzard's own quest POI client data** (`tools/gen_quest_guides_retail.py` — 379 zone guides, 17,161 quests, 56,843 steps). No subscription required.
| Gold guides | ✅ realm-independent money guides by level, on every client: gathering, mob farming and fishing **circuits** you walk with nothing to click, plus daily gold, instance runs and step-by-step methods. No prices are shipped; laps are priced in game from Auctionator if present, else vendor value — [docs/GOLD_ROUTES.md](docs/GOLD_ROUTES.md) |
| Secondary professions | ✅ Cooking, Fishing, First Aid and Archaeology by client, with nearest trainer, a computed recipe path, skill targets that tick themselves, and live Archaeology dig-site circuits — [docs/PROFESSIONS.md](docs/PROFESSIONS.md) |
| Guides listed by level | ✅ `Core/Recommend.lua`: a *For level N* section, *Only guides for this level* filter, *Group by level* tree, and profession guides matched to your real skill |
| Dungeon guides | ✅ steps inside an instance route to the **entrance** (learned door + retail encounter journal), `Core/Instances.lua` |
| Options | ✅ `/or options` (Settings panel), `/or` commands |
| Beta bug reports | Built, offline-tested only: `/cr bug [note]` or the guide window's **Report** button saves a snapshot (guide, step, open steps, position, route, quest log including quests that only gate a step, profession skill, last 30 log lines, last addon Lua error; no character or realm name). `tools/ingest_beta_reports.py` loads reports into SQL and `vplayer --repro <id>` replays one offline — [docs/BETA_REPORTS.md](docs/BETA_REPORTS.md) |

Not yet: primary profession guides, talent advisor, gear finder, model viewer, guide editor UI, retail-specific hearth toys, indoor/dungeon-aware walking, per-zone "wall" data.

## Where the guides come from

The routing engine is the product; the guide content is deliberately **community-driven and
regenerable**, so nothing here depends on a subscription staying alive:

| Source | Flavors | How |
|---|---|---|
| **Warcraft Wiki** (warcraft.wiki.gg, CC BY-SA 4.0) — **the source of truth** | era, tbc, mop, retail, forever | `tools/wiki/` (fetch → parse → `gen_wiki_guides.py`) writes `Guides/Imported_Wiki_<flavor>.lua`: per-zone guides with the wiki's givers, enders, chains (`PRE`), objectives and coordinates. Flavor membership is checked against each client's QuestV2. See [tools/wiki/README.md](tools/wiki/README.md) |
| Blizzard quest POI client data (wago.tools `QuestPOIBlob`/`QuestPOIPoint`) | retail | `tools/gen_quest_guides_retail.py`. Now fills wiki gaps only: coordinates for steps the wiki has none for, plus `Imported_Quests_retail_gaps.lua` for quests the wiki lacks |
| **Questie** database (local checkout) | era, tbc, mop | `tools/gen_quest_guides.lua`. Local-only fallback where the wiki has no coordinate, plus `Imported_Quests_<flavor>_gaps.lua` for quests the wiki lacks |
| **WoW-Pro** guides installed on your machine | all | `Adapters/WoWPro.lua` (runtime interop) |
| Hand-authored native guides | all | `Guides/` |

Generated guide files are gitignored: the *generators* ship, the third-party-derived data does not.

**Community data only.** Completionist's Guide is built from Warcraft Wiki, Blizzard client data, Questie (generated locally at install) and WoW-Pro (read at runtime). It ships no commercial guide content.

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
* `/or order` — show the optimizer's order for the upcoming steps · `/or taxi` — flight paths learned · `/or hearth`
* `/cr farm` — farm circuits: status, `build`, `record`, `import`, `export`, `stats`, `radius`
* `/cr list [level] [category]` — best guides for a level · `/cr gold [level]` — gold guides · `/cr prof` — profession guides for your current skill
* `/or test` — routing self-test from your position to major cities · `/or import` — re-scan WoW-Pro guides
* `/cr skip [questID]` — skip a quest (default: the current step's); warns first when other quests need it · `/cr skipstep` — skip the current step (on an accept of a quest you do not have, that skips the quest, so its turn-in is not left behind)
* `/cr unskip <questID|all>` — bring skipped quests back · `/cr skipped` — list them and what they lock
* `/cr bug [what went wrong]` — save a bug report (also the **Report** button) · `/cr bug list` — stored reports · `/cr log` — the addon log
* Click the step for details (Complete, Skip, Skip quest) · right-click = skip menu · `<` back · `>` done · `Route` toggles reordering

Open a flight master's map once on each continent so the router knows which flight paths you have.
Hearth once (or bind at an inn) so the router learns exactly where your inn is (a seed list covers common inns).

## Guide format

See [docs/GUIDE_FORMAT.md](docs/GUIDE_FORMAT.md). It is the WoW-Pro community syntax
(`A Quest|QID|123|M|48.1,42.9|Z|1429; Elwynn Forest|N|note|`) plus CompletionRoute-only tags `|ROUTE|`, `|FIXED|`, `|RAD|` and the `G` farm-waypoint action.
Guides are plain Lua files registered in `CompletionRoute/Guides/Guides.xml`.

## Repository layout

```
CompletionRoute/            the addon (copy this folder into Interface/AddOns)
  Core/               Init, Util (HBD wrappers, quest/item helpers), Conditions, Guide parser, Progress, Slash
  Routing/            TravelGraph (Dijkstra), StepOrder (optimizer), Router (facade + arrow recommendation)
  Data/               Taxi_<flavor>.lua (generated), Transit.lua (hand-authored), Inns.lua (seed)
  UI/                 Arrow, GuideFrame, GuideMenu, Options
  Adapters/           WoWPro.lua (runtime import of an installed WoW-Pro)
  Guides/             native community guides (CC BY-SA)
  Libs/               LibStub, CallbackHandler, HereBeDragons-2.0
tools/                gen_taxi.py (wago.tools → Data), gen_textures.py, install.sh, test_offline.lua (luajit smoke test)
docs/                 design, format, verification log, roadmap / pathways for the next contributor
archive/              dead ends kept for reference
```

## Development

```
luajit tools/test_offline.lua        # parser + Dijkstra + optimizer smoke test with a stubbed WoW API
luajit tools/test_load_all.lua       # every TOC's file list loads clean on all five flavors (incl. Forever)
luajit tools/test_wiki.lua           # wiki guides parse, are flavor-gated, quest 7 has A/C/T with coords, spine has 0 PRE violations
luajit tools/test_route_order.lua    # baked RouteOrder never breaks precedence, loads on every flavor
luajit tools/vplayer.lua retail --shard 1/4    # play every guide; python3 tools/collect_vplayer.py
luajit tools/route_sweep.lua era     # route every guide from its own zone
luajit tools/test_bug_report.lua     # /cr bug snapshot, error hook, caps, SavedVariables reader, capture/replay round trip
python3 tools/test_ingest_beta_reports.py      # beta_reports ingest on a fixture (temp database)
python3 tools/ingest_beta_reports.py           # Daniel's /cr bug reports -> beta_reports; then:
luajit tools/vplayer.lua --repro <report id> --check   # replay one offline; exit 1 on a DIFF (docs/BETA_REPORTS.md)
python3 tools/gen_quest_guides_retail.py       # regenerate the retail quest guides from client data
python3 tools/gen_taxi.py tbc 2.5.6.69110 era 1.15.9.69109 mop 5.5.4.69155 retail 12.1.0.69382
```

## License

Copyright (c) 2026 Daniel Bates / Bates LLC. **All rights reserved.**

Licensed under the **PolyForm Noncommercial License 1.0.0** with a commercial-use rider: noncommercial
use is free; any commercial use requires a separate licence from Bates LLC, standard terms being a
royalty of **10% of gross revenue** attributable to the product incorporating this software. See
[LICENSE](LICENSE). Ask for a commercial licence at **help@batesai.org** · <https://batesai.org>.

Not affiliated with Blizzard, commercial guide publishers, or WoW-Pro. Third-party guide data is never redistributed here.
