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
