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
| `G:...` | | a step with no quest is not for the quest guides |

The test checks each precondition against the generator's own output without contributions ("no wiki point",
"wiki point", "place page") and says so when the wiki has changed and another quest must be picked.
