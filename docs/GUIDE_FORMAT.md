# CompletionRoute guide format

One step per line.  First character = action, then a space, then the title, then `|TAG|value|` pairs.
One step per line: an action letter, a title, then `|TAG|value|` pairs.

```
A A Threat Within|QID|783|M|48.15,42.95|Z|1429; Elwynn Forest|N|From Deputy Willem.|
C Wolves Across the Border|QID|33|M|46.89,39.05;51.6,40.9|Z|1429; Elwynn Forest|L|750 8|N|Diseased Young Wolves.|S|
T Wolves Across the Border|QID|33|M|48.94,40.17|Z|1429; Elwynn Forest|
U Use the Blackjack|QID|4402|U|5865|M|45.6,68.5|Z|1411; Durotar|
h Goldshire|M|43.7,65.8|Z|1429; Elwynn Forest|N|Set hearth at the Lion's Pride Inn.|
```

## Actions
| char | meaning | auto-complete when |
|---|---|---|
| `A` / `a` / `!` | accept quest | on quest or already complete |
| `C` / `K` / `l` | complete objectives / kill / loot | objectives done (`QO` index optional), quest complete, or `L` items in bags (with a `QID`, the bags count only while you are on the quest) |
| `T` / `t` | turn in | quest flagged complete |
| `R` | run to | within 30 yd of `M` (or in zone `Z` if no `M`); with `ALT`, within 30 yd of **any** of the listed places; or the named NPC's window opens (see "Talking") |
| `F` / `f` | fly to / learn flight path | arrive at coords / taxi map opened |
| `H` | hearth | Hearthstone cast |
| `h` | set hearth | `HEARTHSTONE_BOUND` |
| `b` / `J` / `D` | boat-zeppelin / portal / dungeon | arrive |
| `L` | reach level N | level ≥ N |
| `U` | use item `|U|id` | item consumed / quest complete |
| `B` | buy | the `L` items are in the bags; without `L`, the `U`/`ITEM` item is (`COUNT` of them, 1 without `COUNT`) |
| `r` | repair-sell | a merchant window opens (any merchant) |
| `$` | treasure | with `M`: something is looted while you stand within 25 yd of the spot (`RAD` changes the distance); with `QID` or `L`: see below; otherwise manual |
| `N` | note | the named NPC's window opens (see "Talking"), the `L` items are in the bags, or the `MISSION` succeeds; a note with nothing to read stays manual |
| `=` / `M` | train at a trainer (label **Train**) / make or do (label **Make**) | the step's `SKILL` or `RECIPE` tag; manual without one |
| `G` | farm waypoint (gold circuits) | you stand within `RAD` yards of it — nothing to click |

## What completes a step by itself
A step completes only on something the client reports; nothing is guessed, and a step with no such signal waits for
the forward arrow (`tools/census_step_kinds.lua` lists them per guide family). Besides the table above:

| rule | applies to | completes when |
|---|---|---|
| Items | every action except accept and turn-in, when the step has `L|id qty|` with every `qty` of 1 or more | the bags hold every count. With a `QID` the count is read only while the character is on the quest. |
| Talking | `N` and `R` steps with no `QID`, `ACH`, `SKILL`, `RECIPE`, `L` or `MISSION` | a gossip, quest, merchant, trainer, flight-master, bank or auctioneer window opens and the NPC's name is, whole and in any letter case, the step's `T` tag, one of its `ALT` names (without a trailing `(place)`), the name in a note that reads `From <name>.` or `To <name>.`, or the name after `Talk to` / `Speak with` in the note or the title. Only the step on screen. `C` and `l` steps without a quest use the `Talk to` / `Speak with` words only. |
| Mission | a step with `MISSION|id|` (Retail) | the client reports that mission as completed with success. Not limited to the step on screen: the id is exact. |
| Quest generic | any step but an accept that has a `QID` | the quest is flagged complete. |

Talking never completes an accept, a turn-in or any step with a quest id (the quest log does that), a train or buy
step (the recipe or the item does), a hearth step (the bind does) or a kill step (its `T` tag is the thing to kill).

## Tags
`QID` (`^` or, `&` and) · `PRE` prereq quests · `ACTIVE` only while on quest (negative = while not on) · `AVAILABLE` hide when done · `M` `x,y;x,y` · `Z` `mapID; name` (name only also works) · `N` note (`\n`, `[color=RRGGBB]`) · `L` `itemID qty;itemID qty` · `QO` objective index · `T` target name · `U`/`ITEM` item id (drives the arrow's item button) · `C` class list (`;`), `-` prefix = not · `R` race · `P` profession `Name;skill` · `LVL` min level (negative = max) · `FACTION` · `S` sticky, `US` unsticky, `S!US` · `O` optional · `NC` non-combat · `RANK` · `SPELL` · `BUFF`.

CompletionRoute-only: `|RAD|` waypoint radius in yards (`G` steps) · `|KIND|` what grows there · `|ROUTE|` mark a step as reorderable, `|FIXED|` never reorder. Defaults: A/C/T/K/r/B/$/l/! reorderable, everything else fixed (acts as an anchor).

## Profession and gold tags
Any action can carry these (`Core/Guide.lua` parses, `Core/Professions.lua` reads the client, `Core/Progress.lua` completes).

| tag | value | meaning |
|---|---|---|
| `SKILL` | `Profession;target` or `Profession;target;tierSkillLineID` | The step completes when the character's skill in that profession is at or above `target`. Profession is the English name (`Cooking`, `First Aid`, ...). With the third field (retail only) the skill of that expansion tier (`SkillLine` id such as 2545 Cataclysm Cooking; table on the wiki page `TradeSkillLineID`). |
| `RECIPE` | `spellID` | The step completes when the character knows that spell: a recipe or a profession rank. Ranks that later ranks replace still read as known on Classic clients (skill cap reached). |
| `ALT` | `mapID,x,y,Name;mapID,x,y,Name;...` | Alternative locations for one step. x and y are 0-100; `mapID` follows the `Z` convention. The engine picks the cheapest for this character when the guide loads and whenever the player changes continent, then fills `step.coords` and `step.zone`, so everything downstream sees a normal located step. The chosen Name is added to the step title. `Name` may contain commas, not `;` or `\|`. A map this client does not have is dropped. |
| `COUNT` | `n` | How many to make or buy. Display only, except on a `B` step that names its item with `U`/`ITEM` and has no `L`: that step completes when the bags hold `n` of the item. |

Examples:
```
= Train Journeyman Cooking|RECIPE|3102|ALT|<mapID>,<x>,<y>,<trainer>;<mapID>,<x>,<y>,<trainer>|
M Spiced Wolf Meat|SKILL|Cooking;50|COUNT|12|
M <recipe>|SKILL|Cooking;75;2545|N|Retail tier skill.|
```
A step with both `SKILL` and `RECIPE` completes when either condition holds. A skill the client cannot report (a retail tier
that has not been read since the window was opened, a collapsed Skills pane) never completes a step; the step title
says to open the window. `RECIPE` on Classic also uses the recipes the trade skill window has listed so far.

## Registering a guide (Lua)
```lua
local _, NS = ...
NS.Guide.Register({ id="OR_Human_01_06_Northshire", name="Human Starter (1-6)", type="Leveling",
  zone="Elwynn Forest", faction="Alliance", minlevel=1, maxlevel=6, next="OR_Elwynn_06_12",
  author="you", source="CompletionRoute", text=[[ ...lines... ]] })
```
Add the file to `CompletionRoute/Guides/Guides.xml`. Files are CC BY-SA 4.0 — put the header comment in.

Fields: `id`, `name`, `type`, `folder`, `zone`, `faction`, `class`, `race`, `minlevel`, `maxlevel`, `next`, `author`, `source`, `text`,
and the list fields below. `class`/`race` are the same lists as the `C`/`R` step tags and apply to the guide list.

| field | value | used for |
|---|---|---|
| `type` | `"Professions"` with `folder` = the profession name, or `"Gold"` with `folder` = the kind | category in the menu |
| `prof` | `"Cooking"` | which skill the guide is about |
| `skillMin` / `skillMax` | numbers | the skill band the guide covers (a character at skill `skillMax` has outgrown it) |
| `tier` | retail tier SkillLine id | read this tier's skill, not the profession's main one |
| `requires` | `"Herbalism;75"` | a skill the guide assumes. Guides whose requirement is met list ahead of ones it is not, and the missing skill is named |
| `goldKind` | `Gathering`, `Mob Farming`, `Fishing`, `Daily Gold`, `Methods`, `Instances` | gold sub-grouping |
| `loop`, `farm` | see below | circuits |

Gold and Professions guides are never loaded automatically as the next guide, not even through a `next` field.
Finishing one prints a message instead of opening a leveling guide.

The guide list ranks every guide for a level from these registration fields only, never by parsing the guide
(`Core/Recommend.lua`, `/cr list [level] [category]`, `/cr gold [level]`, `/cr prof`). A guide whose level or skill band
does not contain the viewed level or skill is left out, except guides with no level data at all (the `Any level` bucket).
A guide's level range is taken from `minlevel`/`maxlevel`, and otherwise from its own name when the name states one (`Dun Morogh (1-12)`) for
Leveling, Quests, Dungeons, Reputation and Dailies guides; no other derivation is attempted.

## Loop guides (gold / farm circuits)
`NS.Guide.Register{ ..., type = "Gold", loop = true }` makes a guide a **circuit**: its `G` waypoints complete
by proximity, and when the last one is reached `Progress.NewLap` clears the lap, records what it was worth and
re-enters the ring at the nearest waypoint. Circuits never finish and never load a "next" guide. Imported gold
guides are folded into circuits automatically — see `docs/GOLD_ROUTES.md`.

## Access chains
A guide may start somewhere that needs an unlock (Siren Isle, Argus, Zereth Mortis...). Do not write the unlock
into every guide: `Data/Access.lua` holds it once per place, in this same step format, and the addon prepends it
to any guide whose first step is behind the lock (see docs/ROUTING.md "Access chains").
