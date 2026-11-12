# Warcraft Wiki data: licence and attribution

The files `Imported_Wiki_era.lua`, `Imported_Wiki_tbc.lua`, `Imported_Wiki_mop.lua`, `Imported_Wiki_retail.lua` and
`Imported_Wiki_forever.lua` in this folder hold quest data from **Warcraft Wiki** (<https://warcraft.wiki.gg>), written by the Warcraft Wiki
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

## Leveling path

`Imported_Spine_era.lua`, `Imported_Spine_tbc.lua`, `Imported_Spine_mop.lua`, `Imported_Spine_retail.lua` and
`Imported_Spine_forever.lua` chain the wiki zone guides above into one leveling path (`tools/wiki/gen_spine.py`), by level
band and the wiki's quest chains, and on retail also Blizzard's quest-line and campaign order (client tables, facts only).
Each entry points at a wiki zone guide and copies no step text. They are shared under the same licence.

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
The released files are built with `--wiki-only`: wiki chains and names only. The local development build also takes chain order
for quests the wiki lacks from the gaps guides and from Blizzard's quest-line tables, and is never released.

## Teleports

`Data/Teleports.lua` is a hand-authored list of class teleports and teleport items. Spell, item and toy ids are facts checked against
Blizzard's client tables; each landing point comes from a Warcraft Wiki coordinate (the page is named in the entry) or a Blizzard
TaxiNodes position, so the file is shared under the same CC BY-SA 4.0 licence.

## Achievement guides

`Imported_Achievements_mop.lua` and `Imported_Achievements_retail.lua` list Blizzard's achievements and criteria (client tables via
wago.tools, facts only). Where a criterion has a place, its point comes from the quest's step in `Imported_Wiki_<flavor>.lua` or from a
wiki NPC page, so these files are shared under the same CC BY-SA 4.0 licence. They are written by `tools/gen_completion_guides.py`.

## What this licence does not cover

The rest of the add-on is *not* under CC BY-SA. That includes all Lua code, the routing engine and the tools. It is
© 2026 Daniel Bates / Bates LLC, all rights reserved, and is licensed under PolyForm
Noncommercial 1.0.0 with the 10% commercial rider (see `LICENSE` at the repository root, help@batesai.org,
<https://batesai.org>). The wiki data files are kept separate from that code. The hand-written guides in `Leveling/`
are CC BY-SA 4.0 by the CompletionRoute contributors, as each file's header says.

## Steps that are not wiki data

**Client quest pins (retail, shipped).** In `Imported_Wiki_retail.lua`, a step whose note says
`(location: Blizzard quest POI, the turn-in area)` or `(location: Blizzard quest POI, the objective area)` takes its map
point from Blizzard's own quest map pins, the client tables `QuestPOIBlob` and `QuestPOIPoint` (via wago.tools; the
file header names the client build). The tools use a pin only when the wiki has no coordinate for that step. A pin is
client data (a fact: where the game draws the quest's area), not wiki text, and it is not covered by the wiki's licence.

**Local fallback points (never shipped).** Some steps come from a locally generated file that is *not* wiki data. A note in the step says
`(location: Blizzard data)` or `(location: Questie data)`. The tools only do this when the wiki has no usable
coordinate for a step. Those coordinates come from `Imported_Quests_<flavor>.lua`: Blizzard quest-POI client data
on retail, and the Questie database on Classic. Like every `Imported_*` file, they are generated locally and never
committed. To get a file without them (the shippable variant: wiki data plus the
client quest pins above), run `python3 tools/wiki/gen_wiki_guides.py --no-fallback`. A release package holds only that variant:
`tools/package_release.py` fails any build whose wiki files still carry such steps (`docs/RELEASE.md`).
