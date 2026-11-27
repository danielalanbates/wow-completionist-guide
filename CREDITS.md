# Credits

Data sources used by the generators (facts only where noted). Full licence notes for shipped data are in
`CompletionRoute/Guides/WIKI_DATA_LICENSE.md`.

* **Warcraft Wiki** (<https://warcraft.wiki.gg>), its contributors, CC BY-SA 4.0: quest text, givers, enders, chains,
  coordinates.
* **Blizzard client tables** via wago.tools (<https://wago.tools>): map rectangles (UiMap, UiMapAssignment), quest
  membership, quest pins, subzone overlays, flight points. Facts only.
* **Open emulator world databases** (GPL), for quest steps the sources above leave without a point: the world
  position of the quest giver, ender or objective target (ids and coordinates only, which are facts; no text, scripts
  or other content is taken). See `docs/EMU_DATA.md`.
  * cmangos classic-db, <https://github.com/cmangos/classic-db> (GPL-3.0): Classic Era and WoW Forever.
  * cmangos tbc-db, <https://github.com/cmangos/tbc-db> (GPL-3.0): TBC Anniversary.
  * TrinityCore TDB 4.4.2 (cata_classic) and TDB 12.1.0 (master) world databases,
    <https://github.com/TrinityCore/TrinityCore> (GPL-2.0): MoP Classic and Retail.
  Each placed step's note names the repository ("(location: cmangos/tbc-db spawn of npc 10257)"); the commit of
  every value is in `docs/verification.sqlite`, table `emu_points` (column `source`, `commit_sha`).
