# Status / handoff (2026-08-18)

Built in one autonomous session. Verified so far:
* luajit offline test passes (parser, Dijkstra incl. hearth-first and cross-continent boat paths, precedence-safe reordering).
* In-game (TBC Anniversary 2.5.6, char Meln, Undercity): addon loads without error, guide window + arrow render,
  `/or guides` lists 715 guides imported live from the local Zygor install (adapter works).
* NOT yet verified in-game: native guide auto-suggest (frame said "no guide" — check `/or stats` / `/or log`),
  arrow bearing sign, item/hearth button, WoW-Pro adapter (WoWPro addon was disabled on this character), StepOrder live.

Testing tips: WoW keystrokes via scratch `type.py` only after `lsappinfo front` == "Wow" (a mis-focused burst once typed into the terminal).
`/or log` opens a copyable in-game log; Trade chat drowns normal prints.

Next: 1) fix "no guide" on login (Suggest/faction) 2) verify arrow direction + item button on Murn (lvl 1 shaman, Thunder Bluff)
3) write more native guides (1-20 both factions) 4) road/wall data for walking accuracy (see docs/ROUTING.md).
