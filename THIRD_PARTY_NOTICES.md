# Third-party notices

Completionist's Guide (the CompletionRoute add-on and its tools) is © 2026 Daniel Bates / Bates LLC.
All rights reserved. It is licensed under PolyForm Noncommercial 1.0.0 with the 10% commercial rider (see
[LICENSE](LICENSE)). Contact: help@batesai.org, <https://batesai.org>.

The following third-party material is used. Nothing from any commercial guide is used, read or shipped.

| Material | Where | Licence | Shipped? |
|---|---|---|---|
| **Warcraft Wiki** quest, NPC, object, item and achievement pages (<https://warcraft.wiki.gg>, by the Warcraft Wiki contributors) | `tools/wiki/` fetches the raw wikitext into a gitignored cache. `CompletionRoute/Guides/Imported_Wiki_<flavor>.lua` is derived from it. | **CC BY-SA 4.0**, <https://creativecommons.org/licenses/by-sa/4.0/>. Attribution and share-alike: see [CompletionRoute/Guides/WIKI_DATA_LICENSE.md](CompletionRoute/Guides/WIKI_DATA_LICENSE.md) | The data files may be redistributed only under CC BY-SA 4.0 with attribution. They are generated, not committed. |
| **Warcraft Wiki** teleport and location pages (Teleport: Stormwind, Nighthaven, Everlook...) | `CompletionRoute/Data/Teleports.lua`: the landing point of each teleport, one map coordinate per entry, with the page named in its `src`. Committed (facts, a few dozen points). | **CC BY-SA 4.0**, attribution in the file header | yes, as facts with attribution |
| Blizzard client data tables (QuestV2, QuestObjective, QuestPOI*, UiMap, TaxiNodes...), via <https://wago.tools> | `tools/db2/<flavor>/` (gitignored). Used for facts: which quest ids a client has, map extents, flight paths. | © Blizzard Entertainment | Facts only. Raw tables are never committed. |
| **HereBeDragons-2.0** and **HereBeDragons-Pins-2.0** (Nevcairiel) | `CompletionRoute/Libs/HereBeDragons/` | BSD, as declared by the upstream add-on (`## X-License: BSD` in its TOC). Upstream publishes no licence text (checked 2026-11-10: the repository has no LICENSE file), so none is bundled. | yes; one CompletionRoute change in `HereBeDragons-2.0.lua`, a WoW Forever detection guard |
| **CallbackHandler-1.0** (Ace3 project) | `CompletionRoute/Libs/CallbackHandler-1.0/` | Ace3 licence (BSD-style). The full text ships next to it as `Libs/CallbackHandler-1.0/LICENSE.txt`. | yes, unmodified |
| **LibStub** | `CompletionRoute/Libs/LibStub/` | public domain (stated in the file header) | yes, unmodified |
| **Questie** database (local checkout) | `tools/gen_quest_guides.lua` writes `Imported_Quests_<classic flavor>.lua`. Used **locally only**: as coordinate fallback where the wiki has none, and as the `_gaps` guides for quests the wiki lacks. | GPL-3.0 | **No.** Generated locally, gitignored, never redistributed. |

Release packages are built by `tools/package_release.py`, which fails any build that would ship Questie- or
other addons' guide data and writes a provenance record for every shipped file ([docs/RELEASE.md](docs/RELEASE.md)).
Each package carries `LICENSE.txt` and an `ATTRIBUTION.md` that lists its wiki, Blizzard-data and library files.

World of Warcraft and Blizzard Entertainment are trademarks or registered trademarks of Blizzard Entertainment, Inc.
This project is not affiliated with or endorsed by Blizzard Entertainment, Warcraft Wiki or Questie.
