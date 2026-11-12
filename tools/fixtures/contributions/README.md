# Test fixture: a contributions folder (invented data)

`areas/era.json` has the layout of `contributions/areas/<flavor>.json` in the open data repository
(`wow-completionist-data`, written by its `tools/contrib.py`). **Every position in it is invented. It is not
player data and it never ships.** `tools/test_contrib_gen.py` reads it; nothing else does.

Each key tests one rule of `tools/wiki/gen_wiki_guides.py` (class `Contributions`) on a real Classic Era quest:

| Key | Quest step | What it tests |
|---|---|---|
| `A:46` | Bounty on Murlocs, accept (no wiki point) | the step takes the contributed point and says so |
| `A:45` | Discover Rolf's Fate, accept (no wiki point) | the heaviest area is on a map no client has: skipped, the next one is used |
| `A:176` | Wanted: "Hogger", accept (no wiki point) | only an unknown map: the step does not change |
| `A:5805` | Welcome!, accept (item-started, no wiki point) | an item-started accept still takes a contributed point |
| `A:60`, `C:60:1` | Kobold Candles (wiki points) | a contributed area near a wiki point: nothing changes, nothing is logged |
| `T:60`, `C:7:1` | Kobold Candles turn-in, Kobold Camp Cleanup objective (wiki points) | far from the wiki point: the wiki point stays, a conflict row is logged |
| `T:54` | Report to Goldshire, turn-in (wiki point) | an area on another map than the wiki point is not compared |
| `C:45:0` | Discover Rolf's Fate, objective written without `QO` | the add-on's key 0 |
| `C:52:1` | Protect the Frontier, objective 1 (no wiki point) | two areas give two points |
| `C:52:2` | Protect the Frontier, objective 2 (no wiki point) | five areas out of order, one on another map: the three heaviest on one map |
| `C:3904:1`, `T:37` | Milly's Harvest objective, Find the Lost Guards turn-in | `single` areas are never used |
| `T:46` | | a position off the map is dropped |
| `T:6181` | A Swift Message, turn-in (wiki place page) | a contributed area outranks the wiki place page |
| `A:9999999` | | a quest no client has changes nothing |
| `G:wiki:...#h:1a2b3c` | | a step with no quest is not for the quest guides, and not of the add-on's key form either |

The `G:` keys below are steps of real Classic Era gold and profession routes (`tools/contrib_areas.py`, used by
`tools/wiki/gen_gold.py` and `tools/wiki/gen_professions.py`; `tools/test_contrib_gen.py` part 5). The quest guides'
reader skips them all ("not a quest step"); the routes' reader keeps the six of the add-on's form.

| Key | Route step | What it tests |
|---|---|---|
| `G:prof:era:Fishing:1:Alliance#N~b0p3fig8g` | Get a Fishing Pole (no point, no zone) | the step takes the area |
| `G:prof:era:Fishing:1:Horde#R~a5g7q7wci` | travel to Durotar (zone only) | a heavier area on the Kalimdor continent map (1414) is never used; the area in the step's zone is: the step takes it |
| `G:prof:era:Fishing:1:Alliance#R~bisrkzq54` | travel to Dun Morogh (zone only) | an area in Elwynn Forest, outside the step's zone: the step keeps its zone |
| `G:prof:era:Fishing:1:Alliance#=~j30rr3glb` | train Apprentice Fishing (ALT trainers) | a step with points of its own never changes |
| `G:prof:era:Cooking:1:Alliance#M~ccphbexgm` | make Charred Wolf Meat | the heaviest area is `single`: the trusted one is used |
| `G:gold:era:fish:1448:23#N~eohyak8l5` | fish any water in Felwood (gold route) | a gold route step takes its area |
| `G:prof:era:Fishing:1:Alliance#M~short` | | not the add-on's key form: never read |

The test checks each precondition against the generator's own output without contributions ("no wiki point",
"wiki point", "place page") and says so when the wiki has changed and another quest must be picked.
