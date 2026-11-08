# Third-party notices

Completionist's Guide (the CompletionRoute add-on and its tools) is © 2026 Daniel Bates / Bates LLC.
All rights reserved. It is licensed under PolyForm Noncommercial 1.0.0 with the 10% commercial rider (see
[LICENSE](LICENSE)). Contact: help@batesai.org, <https://batesai.org>.

The following third-party material is used. Nothing from any commercial guide is used, read or shipped.

| Material | Where | Licence | Shipped? |
|---|---|---|---|
| **Warcraft Wiki** quest, NPC, object, item and achievement pages (<https://warcraft.wiki.gg>, by the Warcraft Wiki contributors) | `tools/wiki/` fetches the raw wikitext into a gitignored cache. `CompletionRoute/Guides/Imported_Wiki_<flavor>.lua` is derived from it. | **CC BY-SA 4.0**, <https://creativecommons.org/licenses/by-sa/4.0/>. Attribution and share-alike: see [CompletionRoute/Guides/WIKI_DATA_LICENSE.md](CompletionRoute/Guides/WIKI_DATA_LICENSE.md) | The data files may be redistributed only under CC BY-SA 4.0 with attribution. They are generated, not committed. |
| Blizzard client data tables (QuestV2, QuestObjective, QuestPOI*, UiMap, TaxiNodes...), via <https://wago.tools> | `tools/db2/<flavor>/` (gitignored). Used for facts: which quest ids a client has, map extents, flight paths. | © Blizzard Entertainment | Facts only. Raw tables are never committed. |
| **HereBeDragons-2.0** (Nevcairiel) | `CompletionRoute/Libs/HereBeDragons/` | upstream project licence. The bundled files carry no licence header. **TODO before release:** add the upstream LICENSE text here. | yes, unmodified |
| **CallbackHandler-1.0** (Ace3 project) | `CompletionRoute/Libs/CallbackHandler-1.0/` | Ace3 project licence. The bundled file carries no licence header. **TODO before release:** add the upstream LICENSE text here. | yes, unmodified |
| **LibStub** | `CompletionRoute/Libs/LibStub/` | public domain (stated in the file header) | yes, unmodified |
| **Questie** database (local checkout) | `tools/gen_quest_guides.lua` writes `Imported_Quests_<classic flavor>.lua`. Used **locally only**: as coordinate fallback where the wiki has none, and as the `_gaps` guides for quests the wiki lacks. | GPL-3.0 | **No.** Generated locally, gitignored, never redistributed. |
| **WoW-Pro** guides installed by the user | `Adapters/WoWPro.lua` reads them at runtime | CC BY-NC-ND | **No.** Runtime interop only. Nothing is copied into this repository. |

World of Warcraft and Blizzard Entertainment are trademarks or registered trademarks of Blizzard Entertainment, Inc.
This project is not affiliated with or endorsed by Blizzard Entertainment, Warcraft Wiki, Questie or WoW-Pro.
