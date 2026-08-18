# Zygor-parity verification — RESULTS (2026-08-18, live on TBC Anniversary 2.5.6, char Meln/Dreamscythe)

Automated `/or verify` (auto-runs 25s after login, persisted to SavedVariables): **20/20 PASS**
- guide loaded (zygor:Durotar 6-10, 186 steps parsed), suggest correct for level/faction
- travel graph 156 nodes, tbc taxi data, player world pos
- route to current step: "Walk 421 yd → zeppelin Orgrimmar<->Undercity → walk 1.3k yd (~8m)" — cross-continent, live
- arrow recommendation + frame + secure button type=item

Live gameplay verification (screenshots in session log):
- [x] arrow renders, rotates with facing in real time, distance/ETA update
- [x] arrow direction agrees with Zygor's own arrow (both pointed at Brill zeppelin tower, ~205 yd)
- [x] walking the wrong way increased distance and the route re-planned live (421→454→"walk 443")
- [x] arrow → Hearthstone secure button swap, gold ring + cooldown + tooltip ("OpenRoute: Use your Hearthstone")
- [x] clicking the button actually cast Hearthstone: character teleported UC → Gallows' End Tavern (Brill), end-to-end
- [x] after hearth, router re-planned from Brill (Zygor agreed: same zeppelin, same direction)
- [x] step auto-completion: injected R-step at player position auto-completed <1s and advanced to next step
- [x] optimizer: /or order lists upcoming steps with per-step travel ETAs from player position
- [x] guide viewer step list with action icons, checkboxes, skip/undo buttons
- [x] guide sources: native 2 + Zygor 714 + WoW-Pro 39 imported at runtime
- [x] hearth location learned from tavern-name seed (Gallows' End Tavern)
- [x] /or verify, route, order, stats, log, guides menu (mouse), Options panel loads without error

Fixed during verification:
1. Suggest type-case bug (Zygor titles are "LEVELING" uppercase) — case-insensitive filter
2. Suggest scoring (was picking level-less "Group Quests" guide) — tight explicit ranges preferred
3. Arrow.lua:46 — protected SecureActionButton cannot anchor to a texture region → anchor to frame
4. Inn seed list missed tavern-style bind names (Gallows' End Tavern etc.) + resting-based hearth learning
5. keyboard focus: WoW must be clicked (key window) before synthetic keys land; !Swatter owns error handler

Not yet verified live (mechanism exists, needs normal play): quest accept/objective/turn-in auto-complete
(same CheckStep family as verified R-step), item-U button click (same secure path as verified hearth),
TAXIMAP_OPENED flight-path learning, guide chaining to `next`, reorder quality A/B over a full session.

Known feature gaps vs Zygor (by design, documented): gold/profession/dungeon guide engines, gear/talent
advisors, model viewer, guide editor UI, wall-aware walking (straight-line x terrain factor).
