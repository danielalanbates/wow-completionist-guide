# Contribute: players build the location database

Added 2026-11-11 at the owner's request. Offline-tested only (`tools/test_contribute.lua`); **nothing here has run
in a real client.** Code: `CompletionRoute/Core/Contribute.lua`, the box in `UI/GuideFrame.lua`.

## Why

The public build takes its map points from the Warcraft Wiki and Blizzard client data. On the Classic clients that
leaves about half of the steps with only a zone. Other addons' location databases cannot be copied (their licences do
not allow it), so the gap is closed with first-hand data: where players actually stand when they do a step.

## What the player sees

* A **Contribute** tick box on the guide window, left of the Routes button. Off by default. The word **Contribute**
  next to it is a button: a click opens the export window (the same as `/cr contribute export`).
* While it is ticked the addon notes the player's map position when:

| Trigger | Stored under | Weight | Why |
|---|---|---:|---|
| a quest is accepted (client event) | `A:<quest id>` | 3 | the player stands at the giver |
| a quest is turned in (client event) | `T:<quest id>` | 3 | the player stands at the ender |
| an objective of one of the guide's next steps ticks up | `C:<quest id>:<objective>` | 2 | where the mob, item or object was |
| the forward arrow is clicked on the step on screen | the step's key | 1 | the player may be anywhere near |

* Nothing is noted on a flight, as a ghost, or where the client gives no map position (most instances).
* Stored: map id, position on a 0.2 map-% grid, a weight. **No character, realm or account name, no time stamps.**
  At most 80 grid cells per step. Account-wide, per client flavor: `CompletionRouteDB.contrib.spots[flavor][key]`.
* Nothing is sent anywhere. `/cr contribute export` opens a window with a text to copy (one line per step:
  `flavor|client build|key|map,x,y,weight;...`). `/cr contribute` shows counts; `on`, `off`, `clear` do what they say.

## How the most likely places are worked out (`Contribute.Areas`)

The cell with the most weight within 1.5 map % seeds a cluster; the cluster's weighted centre is taken twice; its
cells are removed and the rest is searched again. A leftover lighter than 15% of all the weight (and lighter than 2)
is noise. Up to four areas per step, heaviest first, each with a centre and a radius (at least 0.3 map %). One stray
forward-arrow click far from five accepts therefore changes nothing.

## How the places are used

* **Routing.** `Router.StepWorld` gives a step without a point of its own its heaviest learned area (after the live
  quest objective, before the zone-centre stand-in). The arrow shows "(learned spot)".
* **Map.** The current step's areas are drawn on the world map as circles sized by their radius (yellow accept,
  green turn-in, orange objective, blue other), when "minimap + world map pins" is on.

## Not built yet

* **Getting the data to everyone.** An importer in the open data repository (`wow-completionist-data`) that merges
  exported texts, and a generator step that writes the merged areas into the shipped guides with the note
  "(location: player contributions)". Until then contributions only help on the machine that made them.
* Kill credit that arrives late (a mob that dies at range) puts the sample where the player stood, not where the
  mob was. Areas are therefore approximate; more samples tighten them.
* The circle size on the world map assumes the map canvas width; it was not checked in a client.
* Treasures, rares and gathering nodes that are not guide steps are not recorded.
