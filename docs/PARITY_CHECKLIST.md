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

Round 2 (same session):
- [x] quest-state auto-complete logic vs REAL quest log: A-step(on-quest 5481)=true, T-step(completed 8)=true, T-step(active 5481)=false
- [x] U-step item button: Hearthstone icon + live 43m cooldown overlay rendered in place of arrow
- [x] guide chaining: completing a guide auto-loaded its `next` ("Guide finished. Loading next: Human Starter")
- [x] TAXIMAP_OPENED handler runs against C_TaxiMap.GetTaxiNodesForMap (33 nodes returned; learns 0 outside taxi UI, correct); fixed a broken unreachable-state condition
- [x] WoW-Pro adapter live: 39 guides imported after enabling WoWPro (AddOns.txt)

Round 3:
- [x] gold / dungeon / profession / dailies / titles guide types all load+parse through the same engine (Clefthoof Meat 5 steps, Ragefire Chasm 8, Felweed 2, Netherwing 147, Champion of the Naaru 137)
- [x] gear advisor (UI/ItemScore.lua): class stat-weights, scores real items (equipped weapon 8.7, Felstone Spaulders 44.1), compares vs equipped slot, tooltip annotation hooked (OnTooltipSetItem / TooltipDataProcessor) — tooltip line render still to be eyeballed
- [x] guide window readability pass: 430px wide, GameFontNormal rows, 44px row height, resize grip (scale drag) — Daniel's feedback addressed

Still needs a real play session: turn-in/objective completion during actual questing, flight-master visit
to confirm learned-taxi persistence, reorder quality over hours. Everything mechanical is verified.

Known feature gaps vs Zygor (by design, documented): gold/profession/dungeon guide engines, gear/talent
advisors, model viewer, guide editor UI, wall-aware walking (straight-line x terrain factor).
