# Third-party notices

Completionist's Guide (the CompletionRoute add-on and its tools) is © 2026 Daniel Bates / Bates LLC.
All rights reserved. It is licensed under PolyForm Noncommercial 1.0.0 with the 10% commercial rider (see
[LICENSE](LICENSE)). Contact: help@batesai.org, <https://batesai.org>.

The following third-party material is used. Nothing from any commercial guide and nothing from any other add-on
(Questie included) is used, read, generated, installed or shipped: there is one build, and it is the one a release
ships (2026-11-11).

| Material | Where | Licence | Shipped? |
|---|---|---|---|
| **Warcraft Wiki** quest, NPC, object, item and achievement pages (<https://warcraft.wiki.gg>, by the Warcraft Wiki contributors) | `tools/wiki/` fetches the raw wikitext into a gitignored cache. `CompletionRoute/Guides/Imported_Wiki_<flavor>.lua` is derived from it. | **CC BY-SA 4.0**, <https://creativecommons.org/licenses/by-sa/4.0/>. Attribution and share-alike: see [CompletionRoute/Guides/WIKI_DATA_LICENSE.md](CompletionRoute/Guides/WIKI_DATA_LICENSE.md) | The data files may be redistributed only under CC BY-SA 4.0 with attribution. They are generated, not committed. |
| **Warcraft Wiki** teleport and location pages (Teleport: Stormwind, Nighthaven, Everlook...) | `CompletionRoute/Data/Teleports.lua`: the landing point of each teleport, one map coordinate per entry, with the page named in its `src`. Committed (facts, a few dozen points). | **CC BY-SA 4.0**, attribution in the file header | yes, as facts with attribution |
| Blizzard client data tables (QuestV2, QuestObjective, QuestPOI*, QuestLine, Achievement, Criteria, GarrMission, UiMap, TaxiNodes...), via <https://wago.tools> | `tools/db2/<flavor>/` (gitignored). Used for facts: which quest ids a client has, Retail quest map pins for steps the wiki gives no point for, quest-line order, achievements, missions, map extents, flight paths. | © Blizzard Entertainment | Facts only, in the generated data files. Raw tables are never committed. |
| **HereBeDragons-2.0** and **HereBeDragons-Pins-2.0** (Nevcairiel) | `CompletionRoute/Libs/HereBeDragons/` | BSD, as declared by the upstream add-on (`## X-License: BSD` in its TOC). Upstream publishes no licence text (checked 2026-11-10: the repository has no LICENSE file), so none is bundled. | yes; one CompletionRoute change in `HereBeDragons-2.0.lua`, a WoW Forever detection guard |
| **CallbackHandler-1.0** (Ace3 project) | `CompletionRoute/Libs/CallbackHandler-1.0/` | Ace3 licence (BSD-style). The full text ships next to it as `Libs/CallbackHandler-1.0/LICENSE.txt`. | yes, unmodified |
| **LibStub** | `CompletionRoute/Libs/LibStub/` | public domain (stated in the file header) | yes, unmodified |

**Not used: Questie.** Until 2026-11-11 a local "dev build" on the developer's machine filled gaps from a Questie
database checkout (GPL-3.0): map points the wiki lacks, guides for quests the wiki has no page for, dungeon doors.
None of it was ever committed or released, and since that day none of it is generated, loaded or installed either.
The tools that read the checkout are in `archive/questie-tooling/` (unmaintained). One explicit offline comparison
against those older files remains (`tools/measure/README.md`); it never writes into the add-on.

**Not read at run time: other addons' saved data.** Until 2026-11-12 the add-on copied gathering nodes from
GatherMate2 and Routes at login when they were installed. That import, its option and its command are removed; farm
circuits are built from the nodes the player loots.

Release packages are built by `tools/package_release.py`, which fails when the add-on folder holds Questie- or
other addons' guide data and writes a provenance record for every shipped file ([docs/RELEASE.md](docs/RELEASE.md)).
Each package carries `LICENSE.txt` and an `ATTRIBUTION.md` that lists its wiki, Blizzard-data and library files.

World of Warcraft and Blizzard Entertainment are trademarks or registered trademarks of Blizzard Entertainment, Inc.
This project is not affiliated with or endorsed by Blizzard Entertainment, Warcraft Wiki or Questie.
