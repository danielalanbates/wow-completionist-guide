# Attribution and third-party notices: Completionist's Guide @VERSION@

Completionist's Guide (the `CompletionRoute` add-on) is (c) 2026 Daniel Bates / Bates LLC, all rights reserved. It is
licensed under PolyForm Noncommercial 1.0.0 with a 10% commercial rider (`LICENSE.txt`). Contact: help@batesai.org,
https://batesai.org. That licence covers the code and the project's own data. The material below keeps its own terms.

## Warcraft Wiki data (CC BY-SA 4.0)

* **Source:** Warcraft Wiki, https://warcraft.wiki.gg, written by the Warcraft Wiki contributors. The authors of each
  page are listed in that page's history: `https://warcraft.wiki.gg/wiki/<page title>?action=history`.
* **Licence:** Creative Commons Attribution-ShareAlike 4.0 International (CC BY-SA 4.0),
  https://creativecommons.org/licenses/by-sa/4.0/
* **Changes:** the wikitext was parsed and written as guide steps. Coordinates were moved onto each game client's map
  IDs, objectives became steps, the wiki's previous/next links became prerequisites, and gold and profession pages
  became routes and skill plans. Which quests exist in which client was checked against Blizzard's client tables
  (facts only). The tools that did this are in the source repository (`tools/wiki/`).
* **ShareAlike:** if you redistribute these files, or anything adapted from them, you must license it under CC BY-SA
  4.0 (or a compatible licence) and keep this attribution. The rest of the add-on is not under CC BY-SA. The wiki
  data is kept in its own files, listed here.
* **No endorsement:** Warcraft Wiki and its contributors do not endorse this add-on.

Files in this package with Warcraft Wiki data:

@WIKI_FILES@

## Hand-written guides (CC BY-SA 4.0)

Written by the CompletionRoute contributors and licensed CC BY-SA 4.0, as each file's header says:

@CCBYSA_OWN_FILES@

## Blizzard client data

Facts such as flight-path nodes, map extents, quest ids, mission tables and (retail) quest map pins, taken from
Blizzard Entertainment's game client data tables as exported by wago.tools (https://wago.tools). The retail wiki
quest file uses a quest pin (QuestPOIBlob and QuestPOIPoint) only for a step the wiki gives no coordinate for; that
step's note says "(location: Blizzard quest POI, ...)" and the file header names the client build. World of Warcraft and Blizzard Entertainment are
trademarks or registered trademarks of Blizzard Entertainment, Inc. This add-on is not affiliated with or endorsed by
Blizzard Entertainment. Files built only from these tables:

@BLIZZARD_FILES@

## Player contributions (CC BY-SA 4.0)

A step whose note says "(location: player contributions, N players)" takes its map point from positions that
players of this add-on chose to share: where they stood when they accepted a quest, turned it in or made progress on
an objective. The contributions hold map positions and quest ids only (no character, realm or account names). They
are merged and published in the open data repository wow-completionist-data,
https://github.com/danielalanbates/wow-completionist-data, under CC BY-SA 4.0
(https://creativecommons.org/licenses/by-sa/4.0/). A point is used only for a step that the wiki and the client's
quest pin do not place. Each file with such steps names the repository and the commit of the merged data in its
header; a file with no such step holds no contributed data.

## Libraries

@LIBRARIES@

## Not included

No guide content from any other add-on, free or commercial, and no Questie data are in this package. The add-on
does not read other add-ons' guides either. Player contributions come from this add-on's own players, not from
another add-on's database.
