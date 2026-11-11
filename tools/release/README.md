# Completionist's Guide @VERSION@

A World of Warcraft add-on (folder `CompletionRoute`). It has quest, gold and profession guides, and a travel router
that picks flight paths, boats, zeppelins, portals and your hearthstone, then points an arrow at the next step.

**Beta.** Bugs are expected. Please send reports to help@batesai.org.

## Install

1. Quit World of Warcraft.
2. Unzip this file. Move the `CompletionRoute` folder into `Interface/AddOns/` inside your game client's folder
   (`_retail_`, `_classic_era_`, `_anniversary_`, `_classic_`, or your WoW Forever folder).
3. Start the game and make sure "Completionist's Guide" is ticked in the AddOns list on the character screen.

@PACKAGE_NOTE@

## Use

* `/cr` shows or hides the guide window. `/cr guides` picks a guide. `/cr list [level]` lists guides for a level.
* `/cr gold [level]` gold guides. `/cr prof` profession guides for your current skill.
* `/cr route` explains the current route. `/cr order` shows the planned order of the next steps.
* `/cr taxi` shows how many of your flight paths the add-on knows. `/cr hearth` shows where your hearthstone goes.
* `/cr options` opens the settings.
* The guide window shows one step at a time. Steps complete themselves from your quest log, bags, position,
  flights and hearthstone. The right arrow marks a step done by hand, the left arrow goes back one step. Click
  the step for its details and the Complete, Skip and Show on map buttons. `Route` turns reordering on or off.

Open a flight master's map once on each continent so the router knows your flight paths. Hearth once, or bind at an
inn, so it learns where your inn is.

## Where the data comes from

Quest, gold and profession data comes from Warcraft Wiki (CC BY-SA 4.0) and from Blizzard's game client data tables.
The route orders and the rest of the add-on are our own work. No commercial guide content, no WoW-Pro guide text and
no Questie data are in this package. See `ATTRIBUTION.md` for sources and licences.

## Licence

(c) 2026 Daniel Bates / Bates LLC. All rights reserved. Free for players: PolyForm Noncommercial 1.0.0 with a 10%
commercial rider, see `LICENSE.txt`. The Warcraft Wiki data files are CC BY-SA 4.0, see `ATTRIBUTION.md`.

Contact: help@batesai.org · https://batesai.org

World of Warcraft is a trademark of Blizzard Entertainment, Inc. This add-on is not affiliated with or endorsed by
Blizzard Entertainment or Warcraft Wiki.
