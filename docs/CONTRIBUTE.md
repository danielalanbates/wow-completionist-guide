# Contribute: players build the location database

Added 2026-11-11 at the owner's request. Offline-tested only (`tools/test_contribute.lua`,
`tools/test_contrib_gen.py`); **nothing here has run in a real client.** Code: `CompletionRoute/Core/Contribute.lua`,
the box in `UI/GuideFrame.lua`; the merge is in the open data repository (`tools/contrib.py` there); the last step,
into the shipped guides, is in `tools/wiki/gen_wiki_guides.py`.

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

## How the data reaches everyone (built 2026-11-12, offline-tested only)

1. **The player sends the export.** The text goes into the *Location contribution* issue form of the open data
   repository (`wow-completionist-data`). A GitHub Action checks it and merges it with `tools/contrib.py` there.
2. **The data repository merges.** Per client it writes `contributions/areas/<flavor>.json`: for each step key
   (`A:<quest>`, `T:<quest>`, `C:<quest>:<objective>`, `G:<guide>#<step>`) a list of areas, heaviest first, each
   with a map id, a centre, a radius, a weight, a number of contributors and a confidence:

| Confidence | Means | Used in the guides |
|---|---|---|
| `trusted` | a maintainer's own play | yes |
| `confirmed` | two or more players put it in the same place | yes |
| `single` | one player, nobody agrees yet | no |

3. **The guide generator reads the areas.** `tools/wiki/gen_wiki_guides.py` looks for the contributions folder in
   this order: `--contributions DIR`, the environment variable `CR_CONTRIB`, then
   `../wow-completionist-data/contributions` next to this checkout. `--no-contributions` reads none. With no
   `areas/<flavor>.json` for a client, that client's files come out byte for byte as before.
4. **A contributed area fills a gap; it never replaces the wiki.** For a quest step the sources are tried in this
   order: the wiki's own point, Blizzard's quest pin (Retail), **a contributed area**, the wiki place page, the zone.

| Step | Key | Takes |
|---|---|---|
| accept | `A:<quest>` | the heaviest area |
| turn-in | `T:<quest>` | the heaviest area |
| objective | `C:<quest>:<n>`, `n` = the step's `QO` number, `0` for a step without `QO` | up to three areas, all on the heaviest one's map (the arrow goes to the nearest: `Router.NearestCoord`) |

   * An area on a map the client does not have is skipped. So is one on a continent or the world map (two players
     "in the same place" there can be hundreds of yards apart) and a malformed one: a position that would print on
     the map's edge, a `confirmed` area with one player, more players than weight, a number that is not one. The
     file is public input: only a map id, positions and a player count ever reach a guide.
   * An areas file that cannot be read at all (broken JSON, another client's file, larger than 100 MB) is not used.
     The run prints a `WARNING` for that client and again at the end, goes on, and writes that client's files as
     with no contributions.
   * The keys are the add-on's own (`Core/Contribute.lua` `KeyFor`); `tools/test_contrib_gen.py` parses the
     generated steps with `Core/Guide.lua` and compares.
   * When the wiki's objective count disagrees with the client's (Retail), the steps carry no `QO` and all share
     key 0 in the add-on. A quest with several such steps takes no objective area (the run counts them).
   * An accept that an item starts keeps the wiki's item page as its first source; a contributed area is used only
     when the wiki cannot place the item.
   * A contributed point counts as one of the quest's located steps. The generator uses those when it picks the
     zone for the quest's steps that still have no point, when it picks the quest's guide for a quest filed under no
     zone, and when it orders the steps of a guide.
5. **The step says so.** Its note ends with `(location: player contributions, 3 players)`, or
   `(..., 3 players, 2 areas)` for several points. The number is the players behind the heaviest area.
6. **The file says so.** A guide file with such steps names the source in its header: the data repository, CC BY-SA
   4.0, and the commit the areas came from (`git rev-parse HEAD` of the checkout; `unknown` when the folder is not
   a checkout of that repository; `<commit>-dirty` when the areas file differs from the commit).
   `tools/gen_completion_guides.py` repeats the line in the achievement and quest-line files, whose steps come
   from the wiki file. `tools/package_release.py` fails a file that credits player contributions without that
   line, or with an unknown or dirty commit.
7. **Disagreements are leads for the wiki.** When a step has a wiki point and a trusted or confirmed area on the
   same map more than 100 yd away, the guide keeps the wiki point and a row goes into `wiki_db2_conflict`
   (`docs/verification.sqlite`; field `A_xy_contrib`, `T_xy_contrib` or `C_xy_contrib`; the wiki point, the
   area, the distance). An accept that an item starts is not compared: players accept it wherever they open the item.
8. **Counted.** `wiki_point_sources` has a `contrib` column, the generator prints the count per client,
   `tools/coverage.py` writes `quest-contrib` and `quest-contrib-steps` (such a step counts as located), and
   `tools/status_report.py` shows them in the column *contributed*.

To ship new contributions: update the data repository checkout, regenerate (`docs/RELEASE.md` "Making a build"),
then bake again. A guide whose points changed needs a new baked order.

No contribution has been merged yet (2026-11-12), so no shipped file has changed. Tests:
`python3 tools/test_contrib_gen.py` (fixture: `tools/fixtures/contributions`, invented positions).

## Still open

* Kill credit that arrives late (a mob that dies at range) puts the sample where the player stood, not where the
  mob was. Areas are therefore approximate; more samples tighten them.
* The circle size on the world map assumes the map canvas width; it was not checked in a client.
* Treasures, rares and gathering nodes that are not guide steps are not recorded.
* `G:` keys (steps with no quest) are merged in the data repository but no generator reads them yet.
* The hand-written guides in `Guides/Leveling/` and the gold and profession guides take no contributed points.
