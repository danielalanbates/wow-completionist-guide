# CompletionRoute guide format

One step per line.  First character = action, then a space, then the title, then `|TAG|value|` pairs.
This is the WoW-Pro community syntax (so thousands of existing guide lines are valid) with a few additions.

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
| `C` / `K` / `l` | complete objectives / kill / loot | objectives done (`QO` index optional), quest complete, or `L` items in bags |
| `T` / `t` | turn in | quest flagged complete |
| `R` | run to | within 30 yd of `M` (or in zone `Z` if no `M`) |
| `F` / `f` | fly to / learn flight path | arrive at coords / taxi map opened |
| `H` | hearth | Hearthstone cast |
| `h` | set hearth | `HEARTHSTONE_BOUND` |
| `b` / `J` / `D` | boat-zeppelin / portal / dungeon | arrive |
| `L` | reach level N | level ≥ N |
| `U` | use item `|U|id` | item consumed / quest complete |
| `B` / `r` / `N` / `M` / `=` / `$` | buy / repair-sell / note / misc / treasure | `B`: has `L` items; others manual |

## Tags
`QID` (`^` or, `&` and) · `PRE` prereq quests · `ACTIVE` only while on quest (negative = while not on) · `AVAILABLE` hide when done · `M` `x,y;x,y` · `Z` `mapID; name` (name only also works) · `N` note (`\n`, `[color=RRGGBB]`) · `L` `itemID qty;itemID qty` · `QO` objective index · `T` target name · `U`/`ITEM` item id (drives the arrow's item button) · `C` class list (`;`), `-` prefix = not · `R` race · `P` profession `Name;skill` · `LVL` min level (negative = max) · `FACTION` · `S` sticky, `US` unsticky, `S!US` · `O` optional · `NC` non-combat · `RANK` · `SPELL` · `BUFF`.

CompletionRoute-only: `|ROUTE|` mark a step as reorderable, `|FIXED|` never reorder. Defaults: A/C/T/K/r/B/$/l/! reorderable, everything else fixed (acts as an anchor).

## Registering a guide (Lua)
```lua
local _, NS = ...
NS.Guide.Register({ id="OR_Human_01_06_Northshire", name="Human Starter (1-6)", type="Leveling",
  zone="Elwynn Forest", faction="Alliance", minlevel=1, maxlevel=6, next="OR_Elwynn_06_12",
  author="you", source="CompletionRoute", text=[[ ...lines... ]] })
```
Add the file to `CompletionRoute/Guides/Guides.xml`. Files are CC BY-SA 4.0 — put the header comment in.

## Access chains
A guide may start somewhere that needs an unlock (Siren Isle, Argus, Zereth Mortis...). Do not write the unlock
into every guide: `Data/Access.lua` holds it once per place, in this same step format, and the addon prepends it
to any guide whose first step is behind the lock (see docs/ROUTING.md "Access chains").
