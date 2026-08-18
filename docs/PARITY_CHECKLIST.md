# Zygor-parity verification checklist

Automated (`/or verify`, auto-runs 25s after login, persisted to SavedVariables `lastVerify`):
- [x] travel graph builds (156 nodes, tbc taxi data)
- [x] guides registered (716: 2 native + 714 Zygor-imported)
- [x] player world position via HBD
- [ ] guide auto-loads at login (FIXED type-case bug 2026-08-18, pending retest)
- [ ] current step + optimizer order
- [ ] route to current step + arrow recommendation
- [ ] secure item/hearth button exists (Arrow.lua load error, diagnosing via scriptErrors)
- [ ] hearth location known (added tavern-name seeds + resting-learn, pending retest)

Manual/visual (screenshots):
- [x] guide window renders, buttons work (Guides menu opens, 715 listed)
- [x] arrow frame renders
- [ ] arrow points the right way (walk toward target, bearing decreases dist)
- [ ] arrow becomes quest-item button at the spot; click uses item
- [ ] arrow becomes Hearthstone when hearth is faster; click hearths
- [ ] step auto-completes on quest accept/objective/turn-in
- [ ] reordering: /or order differs from author order when player is far from step 1
- [ ] guide chaining to `next` guide on completion
- [ ] flight-path learning at flight master (TAXIMAP_OPENED)
- [ ] cross-continent route includes zeppelin (Meln: UC -> Durotar route should use UC->Grom'gol/Org zeppelin)

Known not-at-parity (documented gaps vs Zygor): gold/profession/dungeon guide engines, gear advisor,
talent advisor, model viewer/creature detector, guide editor, dynamic XP-based guide skipping, walking
wall-awareness (straight-line + terrain factor only).
