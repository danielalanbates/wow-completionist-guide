# Warcraft Wiki data: licence and attribution

The files `Imported_Wiki_era.lua`, `Imported_Wiki_tbc.lua`, `Imported_Wiki_mop.lua` and `Imported_Wiki_retail.lua`
in this folder hold quest data from **Warcraft Wiki** (<https://warcraft.wiki.gg>), written by the Warcraft Wiki
contributors. That data covers quest names and ids, quest givers and enders, quest chains, objectives, faction, race,
class and level requirements, and map coordinates.

* **Source:** Warcraft Wiki, <https://warcraft.wiki.gg>. Each quest's authors are in the history of its page,
  `https://warcraft.wiki.gg/wiki/<Quest title>` (the `page_title` column in `tools/wiki/wiki.sqlite`).
* **Licence:** Creative Commons Attribution-ShareAlike 4.0 International (CC BY-SA 4.0),
  <https://creativecommons.org/licenses/by-sa/4.0/>.
* **Changes:** these files were made with `tools/wiki/parse_wiki.py` and `tools/wiki/gen_wiki_guides.py`. The wikitext
  was turned into the guide step format (`docs/GUIDE_FORMAT.md`): coordinates were moved onto each game client's
  map IDs, objectives became steps, and the wiki's `previous`/`next` links became `PRE` tags. Which quests appear in
  which game version was checked against Blizzard's client quest table (QuestV2, via wago.tools). That table supplies
  facts only, not wiki text.
* **ShareAlike:** if you redistribute these data files, or anything adapted from them, you must use CC BY-SA 4.0 (or
  a compatible licence) and keep this attribution.
* **No endorsement:** Warcraft Wiki and its contributors do not endorse this project.

## Gold guides

`Imported_Gold_era.lua`, `Imported_Gold_tbc.lua`, `Imported_Gold_mop.lua`, `Imported_Gold_retail.lua` and `Imported_Gold_forever.lua` hold data
derived from the same source under the same licence: where herbs, ore and fish occur, mob and NPC locations, daily quest ids and givers, Auction
House and bank locations, and instance entrances, all placed on each client's maps by `tools/wiki/gen_gold.py`. Pages used include *Herb*, *Herbs by
Area*, *Mining node* and each node's page, *Fishing locations*, *Auction House*, *Guide to making money*, and individual NPC, quest and instance pages;
their authors are in each page's history. The advice text in those files is original wording. The files carry no auction price and no gold-per-hour figure.

## Profession guides

`Imported_Professions_era.lua`, `Imported_Professions_tbc.lua`, `Imported_Professions_mop.lua`, `Imported_Professions_retail.lua` and
`Imported_Professions_forever.lua` hold data derived from the same source under the same licence: profession trainers and their locations, how each
recipe is learned, where reagents come from, skill books and rank quests, and fishing locations, placed on each client's maps by
`tools/wiki/gen_professions.py`. Pages used include *Cooking trainers*, *Fishing trainers*, *First Aid trainers*, *Archaeology trainers*, *Fishing locations*,
*First Aid recipes*, the *List of ... Cooking Recipes* pages, and individual NPC, recipe, item and quest pages; their authors are in each page's history.
Which recipes exist on a client, their skill thresholds and reagents, and the Archaeology dig sites come from Blizzard's client tables via wago.tools
(facts only). See `docs/PROFESSIONS.md`.

## Quest prerequisite index

`Data/QuestDeps_era.lua`, `Data/QuestDeps_tbc.lua`, `Data/QuestDeps_mop.lua`, `Data/QuestDeps_retail.lua` and `Data/QuestDeps_forever.lua`
(written by `tools/gen_quest_deps.py`) hold the quest chains (`previous`/`next` links) and quest names of the files above, under the same
licence, plus breadcrumb flags read from the wording of the quest pages ("is a breadcrumb", "(optional breadcrumb)", "previous = ... (optional)").
For quests the wiki lacks they also hold chain order from the gaps guides and from Blizzard's quest-line tables (facts only).

## What this licence does not cover

The rest of the add-on is *not* under CC BY-SA. That includes all Lua code, the routing engine, the tools and the
hand-written guides. It is © 2026 Daniel Bates / Bates LLC, all rights reserved, and is licensed under PolyForm
Noncommercial 1.0.0 with the 10% commercial rider (see `LICENSE` at the repository root, help@batesai.org,
<https://batesai.org>). The wiki data files are kept separate from that code.

## Steps that are not wiki data

Some steps come from a locally generated file that is *not* wiki data. A note in the step says
`(location: Blizzard data)` or `(location: Questie data)`. The tools only do this when the wiki has no usable
coordinate for a step. Those coordinates come from `Imported_Quests_<flavor>.lua`: Blizzard quest-POI client data
on retail, and the Questie database on Classic. Like every `Imported_*` file, they are generated locally and never
committed. To get a file that is wiki data only (the shippable variant), run
`python3 tools/wiki/gen_wiki_guides.py --no-fallback`.
