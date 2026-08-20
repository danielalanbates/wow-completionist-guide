# Status / handoff (2026-08-19)

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
  `cat OpenRoute/Guides/Imported_*.lua > /dev/null` to materialize the baked data.

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
* `OpenRoute/UI/Beacon.lua` — marker over the step NPC/mob's head via nameplates, matching marker
  on target/mouseover frames, secure `/targetexact` button on the arrow, minimap + world map pins.
* `OpenRoute/Core/Account.lua` — all progress in `OpenRouteDB.chars["Name-Realm"]`, opt-in
  `profile.accountWide` (default OFF so completionists do everything on every character).
* `/or verifyfeatures` (+ silent auto-run 30s after login) → `OpenRouteDB.featureVerify`;
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
1. **Single account table + per-character keys (chosen).** One `OpenRouteDB.chars` map; reads union
   on demand. Cheap, survives character deletion (`/or forget`), and the opt-in gate is a single
   branch in `Progress.IsDone`.
2. Mirror-on-write into both SV files — rejected, two sources of truth drift.
3. Quest-ID-level union instead of step-index union — more accurate across *different* guides
   covering the same quest, but needs a quest→step reverse index for ~50k quests. **This is the
   natural next improvement**: build `qid -> {guide, step}` once at login and union on QID so a
   quest done on an alt clears the equivalent step in a different guide too.

### Still open
* **In-game verification of these two features has NOT been done.** On 2026-08-20 a live FFXI
  client (another session's benchmark) held the display for the whole work window and Daniel's
  standing rule is: if FFXI is running, do not take over the screen. Everything else — offline
  tests, per-flavor load tests, TOC validation, install to all four flavors — is green.
  When the display is free, run `python3 tools/verify_ingame.py _anniversary_ _classic_era_
  _classic_ _retail_` then `python3 tools/collect_verify.py`; OpenRoute auto-runs its verifiers
  25s/30s after login so nothing has to be typed into the client. In-game screenshot proof of the
  nameplate marker over a real NPC's head is the one piece that still needs a human-visible pass.
* The QID-level union described above.
* Guide-list badge only shows for already-parsed guides; a cached step-count table would let every
  row show a percentage without parsing 9k guides.
