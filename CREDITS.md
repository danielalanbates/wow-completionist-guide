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
* **Questie's quest database** (QuestieDB, <https://github.com/Questie/QuestieDB>, data imported from
  <https://github.com/Questie/Questie>; copying permitted under GPL-3.0 per its LICENSE.md), commit
  `ed772a8939e569203d92c580961b23858d7e615f`, for steps the emulator rung also leaves without a point: quest giver /
  ender / objective npc and object ids, item drop sources, explore-objective areas and their zone coordinates, with its
  Corrections applied. Facts only (ids and coordinates); no text, code or artwork. The Questie name and logo are not
  used in the add-on: a placed step's note says "(location: community quest database spawn of npc N)". Source and
  commit of every value: `docs/verification.sqlite`, table `questie_points`. See `docs/EMU_DATA.md`.
* **AllTheThings** (<https://github.com/ATTWoWAddon/AllTheThings>, MIT licence), commit
  `789b0feb395396c181999063b691f854167595c6`, folders `db/Vanilla`, `db/Camelot`, `db/TBC`, `db/Mists`,
  `db/Standard` (owner decision 2026-11-27), for steps the rungs above still leave without a point: quest giver npc /
  object ids and spawn coordinates, quest start and objective coordinates, achievement and criterion coordinates.
  Facts only (ids and coordinates); no text, code or artwork. The add-on's guide files do not name it: a placed step's
  note says "(location: community database ...)". Source and commit of every value: `docs/verification.sqlite`,
  table `att_points`. See `docs/EMU_DATA.md`. Its licence notice:

  > MIT License
  >
  > Copyright (c) 2026 AllTheThings WoW Addon
  >
  > Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
  > documentation files (the "Software"), to deal in the Software without restriction, including without limitation
  > the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
  > permit persons to whom the Software is furnished to do so, subject to the following conditions:
  >
  > The above copyright notice and this permission notice shall be included in all copies or substantial portions of
  > the Software.
  >
  > THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
  > WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
  > COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
  > OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
