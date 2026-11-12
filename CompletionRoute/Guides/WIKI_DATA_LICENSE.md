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
They hold wiki chains and names only.

## Teleports

`Data/Teleports.lua` is a hand-authored list of class teleports and teleport items. Spell, item and toy ids are facts checked against
Blizzard's client tables; each landing point comes from a Warcraft Wiki coordinate (the page is named in the entry) or a Blizzard
TaxiNodes position, so the file is shared under the same CC BY-SA 4.0 licence.

## Achievement guides

`Imported_Achievements_mop.lua` and `Imported_Achievements_retail.lua` list Blizzard's achievements and criteria (client tables via
wago.tools, facts only). Where a criterion has a place, its point comes from the quest's step in `Imported_Wiki_<flavor>.lua`, from a
wiki NPC, object, item or achievement page, or from Blizzard's own tables (quest map pins, exploration overlays, dungeon encounters),
so these files are shared under the same CC BY-SA 4.0 licence. They are written by `tools/gen_completion_guides.py`.

## Storyline guides

`Imported_QuestLines_retail.lua` follows Blizzard's quest lines (QuestLine and QuestLineXQuest tables, facts only). Each quest's steps
are its steps in `Imported_Wiki_retail.lua` (wiki text and points); a step the wiki leaves without a point takes Blizzard's quest map
pin, and a quest with no wiki page is listed as "Quest <id>" with Blizzard's pins only. The file is shared under the same CC BY-SA 4.0
licence and written by `tools/gen_completion_guides.py`.

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

**Player contributions (shipped when there are any).** A step whose note says
`(location: player contributions, N players)` takes its map point from where players of this add-on stood when they
accepted the quest, turned it in or made progress on the objective. Players switch this on themselves (the
**Contribute** box), export a text that holds map positions and quest ids only (no character, realm or account
name, no times) and send it to the open data repository, `wow-completionist-data`
(<https://github.com/danielalanbates/wow-completionist-data>), where the contributions are merged and published under
CC BY-SA 4.0. Only places a maintainer played or two or more players agree on are used, and only for a step that
neither the wiki nor a quest pin places. A file with such steps names the repository and the commit of the merged
data in its header. The achievement and quest-line files repeat that line when they take such a step or its point.

**Nothing else.** No step takes its text or its map point from another add-on's data. A step for which the wiki, a
quest pin (on Retail) and player contributions give no point names its zone only, or has no location and says so.
