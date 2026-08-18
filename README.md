# OpenRoute — open leveling guides with real travel routing for World of Warcraft

**Status: v0.1.0 — first playable prototype (TBC Anniversary / Classic Era / Mists / Retail TOCs).**
Built as a replacement for Zygor Guides Viewer that keeps the *one thing* no free addon has:
an optimal travel-routing engine (flight paths, boats/zeppelins/portals/tram, Hearthstone) driving a
smart arrow — while the guide content is community-driven and open.

## What it does today

| Zygor feature | OpenRoute |
|---|---|
| Guide viewer with steps that auto-complete | ✅ `UI/GuideFrame.lua` + `Core/Progress.lua` (quest accept / objectives / turn-in / run-to / hearth / fly / level / item events) |
| Waypoint arrow | ✅ `UI/Arrow.lua` — world-coordinate bearing via HereBeDragons, distance + ETA, colour by distance |
| Arrow turns into the quest item when you should click it | ✅ secure item button replaces the arrow (`|U|itemID` / `|ITEM|` tag; combat-safe: queued until you leave combat) |
| Arrow turns into Hearthstone when hearthing is faster | ✅ router puts a `hearth` leg first when `(cast + cooldown + walk from inn) < walking/flying`; button shows Hearthstone (or Astral Recall) |
| Travel system: flight paths, boats, zeppelins, portals | ✅ `Routing/TravelGraph.lua` Dijkstra over ~180 taxi nodes (real polyline lengths from game data) + `Data/Transit.lua` |
| Only uses flight paths you have learned | ✅ learned when you open any flight map (`TAXIMAP_OPENED`), stored per character |
| Optimal quest routing for the chosen guide | ✅ `Routing/StepOrder.lua` — precedence-constrained reordering of the next N steps (accept → complete → turn-in kept, anchors like *run to zone* respected) |
| Guide library | ✅ native guides in `Guides/` (WoW-Pro line syntax, CC BY-SA) + **runtime adapters** that read your installed **WoW-Pro** guides and **Zygor** guides (interop only, nothing copied) |
| Options | ✅ `/or options` (Settings panel), `/or` commands |

Not yet: gold/profession/dungeon guide types beyond what adapters import, talent advisor, gear finder, model viewer, guide editor UI, retail-specific hearth toys, indoor/dungeon-aware walking, per-zone "wall" data.

## Install

```
tools/install.sh                     # copies OpenRoute/ into _anniversary_/Interface/AddOns
tools/install.sh _classic_era_ _retail_
```
Or copy the `OpenRoute/` folder into `Interface/AddOns/`.

## Use

* `/or` — toggle guide window · `/or guides` — pick a guide · `/or route` — explain the current route
* `/or order` — show the optimizer's order for the upcoming steps · `/or taxi` — flight paths learned · `/or hearth`
* `/or test` — routing self-test from your position to major cities · `/or import` — re-scan WoW-Pro/Zygor
* Checkbox / Shift-click a step = complete · right-click = skip · `<` undo · `>` skip · `Route` toggles reordering

Open a flight master's map once on each continent so the router knows which flight paths you have.
Hearth once (or bind at an inn) so the router learns exactly where your inn is (a seed list covers common inns).

## Guide format

See [docs/GUIDE_FORMAT.md](docs/GUIDE_FORMAT.md). It is the WoW-Pro community syntax
(`A Quest|QID|123|M|48.1,42.9|Z|1429; Elwynn Forest|N|note|`) plus OpenRoute-only tags `|ROUTE|`, `|FIXED|`.
Guides are plain Lua files registered in `OpenRoute/Guides/Guides.xml`.

## Repository layout

```
OpenRoute/            the addon (copy this folder into Interface/AddOns)
  Core/               Init, Util (HBD wrappers, quest/item helpers), Conditions, Guide parser, Progress, Slash
  Routing/            TravelGraph (Dijkstra), StepOrder (optimizer), Router (facade + arrow recommendation)
  Data/               Taxi_<flavor>.lua (generated), Transit.lua (hand-authored), Inns.lua (seed)
  UI/                 Arrow, GuideFrame, GuideMenu, Options
  Adapters/           WoWPro.lua, Zygor.lua (runtime import of locally installed guides)
  Guides/             native community guides (CC BY-SA)
  Libs/               LibStub, CallbackHandler, HereBeDragons-2.0
tools/                gen_taxi.py (wago.tools → Data), gen_textures.py, install.sh, test_offline.lua (luajit smoke test)
docs/                 design, format, verification log, roadmap / pathways for the next contributor
archive/              dead ends kept for reference
```

## Development

```
luajit tools/test_offline.lua        # parser + Dijkstra + optimizer smoke test with a stubbed WoW API
python3 tools/gen_taxi.py tbc 2.5.6.69110 era 1.15.9.69109 mop 5.5.4.69155 retail 12.1.0.69382
```

## License
Code MIT · Guides CC BY-SA 4.0 · see [LICENSE](LICENSE). Not affiliated with Blizzard, Zygor or WoW-Pro.
