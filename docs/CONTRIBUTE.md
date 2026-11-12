# Contribute: players build the location database

Added 2026-11-11 at the owner's request; creatures, objects and items added 2026-11-12. Offline-tested only
(`tools/test_contribute.lua`, `tools/test_contrib_gen.py`); **nothing here has run in a real client.** Code:
`CompletionRoute/Core/Contribute.lua`, the box in `UI/GuideFrame.lua`, the step's creature names in `UI/Beacon.lua`
(`StepNames`); the merge is in the open data repository (`tools/contrib.py` there); the last step, into the shipped
guides, is in `tools/wiki/gen_wiki_guides.py`.

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
| a creature the player or the pet hurt dies (combat log: `UNIT_DIED`, or `PARTY_KILL` by the player) | `N:<npc id>` | 1 | the player may be at range |
| a creature's corpse is looted (the loot window's source is a `Creature` or `Vehicle` GUID) | `N:<npc id>` | 2 | the player stands at the corpse |
| a game object is looted: chest, treasure, herb, ore (source is a `GameObject` GUID) | `O:<object id>` | 3 | the player stands at the object |
| the loot holds an item that the current step or one of the next steps names (`L` tag or `U` item) | `I:<item id>` | 2 from a corpse or a catch, 3 from an object | where the item drops |

* Nothing is noted on a flight, as a ghost, or where the client gives no map position (most instances).
* Creatures, objects and items are **never noted inside an instance** (`IsInInstance`), and each such key takes at
  most **one sample every 5 seconds** (`C.THROTTLE`, kept in memory only): area loot of three corpses of one
  creature, or a kill plus its loot right after, is one sample.
* **Rares.** A creature whose classification is `rare` or `rareelite` (`UnitClassification`, read from the target when
  it is targeted and again at the kill or the loot) is flagged: `CompletionRouteDB.contrib.rare[flavor]["N:<npc id>"]
  = true`. It is a flag, not a key, and it sits beside the cells, never inside a key's record: a record holds cells
  and weights only, so a build without the creature keys (an older one, or another branch's, sharing the account's
  saved variables) can still add a record up. It is not in the export (the four-field format stays; the data
  repository can tell rares from Blizzard's creature data).
* Where the loot came from is `GetLootSourceInfo`, the same read as the treasure rule in `Core/Progress.lua` and the
  farm recorder in `Core/Farm.lua`. A fishing catch (`IsFishingLoot`) is no object's place (an item a step names that
  is fished up still counts, where the player fishes). An item opened in the bags (an `Item` GUID) is no place at all.
  A GUID the client keeps secret (Retail, in combat) ends the read. The loot is read on `LOOT_READY` and again on
  `LOOT_OPENED` (the throttle makes it one sample).
* **A treasure step's chest.** `Core/Progress.lua` hears the loot events first and ticks a treasure step at once, so
  the step on screen has already moved on when Contribute reads the loot. Contribute therefore remembers the treasure
  step that was just ticked (`STEP_DONE`, not manual, the step on screen) for one second and links the chest to that
  step. Two treasure steps side by side: the chest goes to the first.
* **The combat log** is listened to only while the box is ticked and outside instances (the frame registers and
  unregisters `COMBAT_LOG_EVENT_UNFILTERED` on the box, on entering the world and on a zone change). The creatures the
  player or the pet damaged are kept in a ring of eight GUIDs that is written in place: no table is made per event
  (the test runs 2,000 events and checks that memory did not grow). On **Retail 12.x the combat log is not used**:
  Retail 12.x hides combat information from addons (secret values) and its combat log rules could not be checked
  offline, so there a creature counts when its corpse is looted.
* Stored: map id, position on a 0.2 map-% grid, a weight. **No character, realm, account or creature name, no time
  stamps.** At most 80 grid cells per key. Account-wide, per client flavor: `CompletionRouteDB.contrib.spots[flavor][key]`.
* **Links** (ids only): a step whose creature was killed or looted while it was one of the next 20 steps (its name
  matched the step's `T` tag, "Kill X" or "from X"), whose item dropped from a creature or object, or whose treasure
  chest was looted at its spot, remembers that creature or object: `CompletionRouteDB.contrib.links[flavor][step key]`,
  at most six per step. They are used only for the map on this machine and are not exported.
* Nothing is sent anywhere. `/cr contribute export` opens a window with a text to copy (one line per key:
  `flavor|client build|key|map,x,y,weight;...`, the creature, object and item keys included). `/cr contribute` shows
  counts by kind and what the map shows for the step on screen; `on`, `off`, `clear` do what they say (`clear` takes
  the links too).

## How the most likely places are worked out (`Contribute.Areas`)

The cell with the most weight within 1.5 map % seeds a cluster; the cluster's weighted centre is taken twice; its
cells are removed and the rest is searched again. A leftover lighter than 15% of all the weight (and lighter than 2)
is noise. Up to four areas per step, heaviest first, each with a centre and a radius (at least 0.3 map %). One stray
forward-arrow click far from five accepts therefore changes nothing.

## How the places are used

* **Routing.** `Router.StepWorld` gives a step without a point of its own its heaviest learned area (after the live
  quest objective, before the zone-centre stand-in). The arrow shows "(learned spot)".
* **Map.** The current step's areas are drawn on the world map as circles sized by their radius (yellow accept,
  green turn-in, orange objective, blue other), when "minimap + world map pins" is on. Beside them go the learned
  areas of what the step names (`Contribute.MapKeys`), up to two areas each and 16 circles in all:

| What the step names | Found by | Key | Colour |
|---|---|---|---|
| its items | the `L` items and the `U` item | `I:<item id>` | purple |
| its creature | the names `Beacon.StepNames` gives (`T` tag, "Kill X", "from X") matched to a creature seen this session, and the step's links | `N:<npc id>` | red, a rare outlined in silver |
| its object | the step's links (the treasure's chest, the object its item came from) | `O:<object id>` | gold |

  The circle frames are made once and reused (HereBeDragons places them); a sample redraws the map only when it is of
  something the step on screen names.

## How the data reaches everyone (built 2026-11-12, offline-tested only)

1. **The player sends the export.** The text goes into the *Location contribution* issue form of the open data
   repository (`wow-completionist-data`). A GitHub Action checks it and merges it with `tools/contrib.py` there.
2. **The data repository merges.** Per client it writes `contributions/areas/<flavor>.json`: for each key
   (`A:<quest>`, `T:<quest>`, `C:<quest>:<objective>`, `G:<guide>#<step>`, and since 2026-11-12 `N:<npc>`,
   `O:<object>`, `I:<item>`: branch `contribute-kinds` there, not merged) a list of areas, heaviest first, each
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
  mob was. Areas are therefore approximate; more samples tighten them. The same holds for a kill from range
  (`N:`, weight 1).
* The circle size on the world map assumes the map canvas width; it was not checked in a client.
* **Not checked in any client:** the loot source GUIDs of herbs, ore and chests on each of the five clients, the
  combat log payload on WoW Forever, and whether Retail 12.x would allow the combat log outside combat (it is not
  registered there at all).
* Not recorded: a creature that dies to someone else after the player stopped hurting it and was pushed out of the
  eight-GUID ring by eight newer ones; kills by a totem or a guardian (only the player and the pet tag); creatures
  inside instances; fishing pools as places; a step's object that is neither a treasure step's chest nor the source
  of the step's item (steps do not name objects).
* A creature's name links it to a step only when the names match exactly (`T` tag "Crushridge Warmonger", not the
  plural of a title). Names seen this session are kept in memory only, so after a reload a step that has no link
  shows its creature's areas once that creature has been targeted, killed or looted again.
* `N:`, `O:`, `I:` keys reach the data repository (branch `contribute-kinds`), but no generator reads them yet, and
  the rare flag does not travel with the export.
* `G:` keys (steps with no quest) are merged in the data repository but no generator reads them yet.
* The tick box's tooltip in `UI/GuideFrame.lua` still says "Only map positions and quest ids are kept"; it should
  say game ids (that file belongs to another branch today).
* The hand-written guides in `Guides/Leveling/` and the gold and profession guides take no contributed points.
