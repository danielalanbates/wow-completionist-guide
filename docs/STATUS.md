# Status / handoff (2026-08-22)

## Gold guides became routes (the ask: "no clicking through steps — a route they always follow")
* New guide type: **circuits**. `G` waypoints (`Core/Guide.lua`), proximity completion + endless laps
  (`Core/Progress.lua` `NewLap` / `StartAtNearest`), shortest closed tour solver (`Routing/Loop.lua`:
  cluster → nearest-neighbour → 2-opt → Or-opt), farm engine (`Core/Farm.lua`), 31 coarse seed rings
  (`Data/Farm_routes.lua`). Full write-up: **docs/GOLD_ROUTES.md**.
* Imported gold guides are folded into circuits on load. Measured over the baked Zygor set:
  **178 of 204 (87%) are walkable circuits on era / tbc / mop / retail** — 106 kept in the author's own
  order (Zygor's farming guides already carry `map` + `path` rings; the adapter now parses them), 72 solved
  here, avg 25.6 stops. The remaining 26 are auction-house / disenchant methods with no route at all and
  stay as note guides. Rows: `docs/verification.sqlite` tables `gold_circuits`, `guide_type_audit`
  (`luajit tools/audit_guides.lua <flavor>` → `python3 tools/collect_audit.py`).
* Nodes are community-driven and local-first: every world-object loot is recorded account-wide (corpses are
  not), GatherMate2 / Routes databases import if installed, `/cr farm export|import` moves plain text between
  players. **No third-party node data ships in this repo.**
* A lap prices itself: bag delta × Auctionator price (else vendor) + coin gained → `lap 3 — waypoint 12 of 48
  · 214g/hr` in the window title, `/cr farm stats` per circuit.
* Guide categories are folded (`Guide.NormalizeType`): Zygor's "GOLD" and "Professions"/"Profession" etc. no
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
  export/import round trip, built circuit is a ring not a zig-zag, lap pricing, gold-guide fold, Zygor path
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
* Guide window shows ONE step (Zygor-style): icon, "Accept  Title", note, distance/zone, route line; back/forward
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
now inherits the previous step's zone (Zygor/WoW-Pro semantics) instead of having none; (3) StepOrder keeps the
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
  baked import (797 Zygor + 119 WoW-Pro), **guide-menu tree** (9 ordered categories, all 873 guides
  reachable when expanded, collapsed view clean, flat search).
* Earlier in-game rounds (see git log 66a6f55..140a03d): arrow, hearth button, quest-item button +
  cooldown, auto-complete, guide chaining, taxi handler, gear advisor, standalone baked guides,
  location-aware suggestion at login.

## Guide browser (new, 2026-08-19)
`/or guides` now shows a Zygor-style collapsible tree: Category (Leveling, Dungeons, Dailies, Gold,
Professions, Reputation, Achievements, Titles, ...) -> folder (Zygor's original folder path, or zone
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

## 2026-08-21 (night) — four-way scope selector, reworked hand, Zygor source check

### Is there an official Zygor GitHub repo?
No. Zygor Guides is closed-source and subscription-only; there is no official source repository.
`github.com/Zygor-Guides` exists but is a marketing shell — one `.github` repo holding a promotional
README (last touched March 2025), zero stars/forks/members, no addon code. What *is* on GitHub is
community ports of the leaked/shipped 3.3.5a Lua: `danaton/ZygorGuidesWoTLK-ClassicPlus`,
`ErebusAres/ZygorGuidesRemaster-3.3.5a_WOTLK`, `SimonGaufreteau/ZygorGuidesViewer` (Project Epoch),
plus `tieonlinux/ZygorDownloader`. Useful as behaviour references only — they are someone else's
proprietary code, so nothing from them goes into this addon.

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
