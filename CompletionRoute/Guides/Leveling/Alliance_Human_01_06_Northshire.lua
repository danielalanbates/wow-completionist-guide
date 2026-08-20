-- CompletionRoute community guide.  License: CC BY-SA 4.0.  Format: see docs/GUIDE_FORMAT.md
-- Author: CompletionRoute contributors (initial: BatesAI). Zone: Elwynn Forest (uiMap 1429). Flavor: Classic Era / Anniversary / TBC.
local _, NS = ...
NS.Guide.Register({
    id = "OR_Human_01_06_Northshire", name = "Human Starter: Northshire (1-6)", type = "Leveling", zone = "Elwynn Forest",
    faction = "Alliance", minlevel = 1, maxlevel = 6, author = "CompletionRoute community", source = "CompletionRoute",
    next = nil,
    text = [[
A A Threat Within|QID|783|M|48.15,42.95|Z|1429; Elwynn Forest|N|From Deputy Willem in front of the Abbey.|R|Human|
T A Threat Within|QID|783|M|48.92,41.61|Z|1429; Elwynn Forest|N|To Marshal McBride inside the Abbey.|
A Kobold Camp Cleanup|QID|7|PRE|783|M|48.92,41.61|Z|1429; Elwynn Forest|N|From Marshal McBride.|
A Eagan Peltskinner|QID|5261|PRE|783|M|48.15,42.95|Z|1429; Elwynn Forest|N|From Deputy Willem.|
T Eagan Peltskinner|QID|5261|M|48.94,40.17|Z|1429; Elwynn Forest|N|To Eagan Peltskinner behind the Abbey.|
A Wolves Across the Border|QID|33|PRE|5261|M|48.94,40.17|Z|1429; Elwynn Forest|N|From Eagan Peltskinner.|
C Wolves Across the Border|QID|33|M|46.89,39.05;51.6,40.9|Z|1429; Elwynn Forest|L|750 8|N|Diseased Young Wolves west and east of the Abbey.|S|
C Kobold Camp Cleanup|QID|7|M|47.5,36.1|Z|1429; Elwynn Forest|N|Kill 10 Kobold Vermin north of the Abbey.|T|Kobold Vermin|US|
T Wolves Across the Border|QID|33|M|48.94,40.17|Z|1429; Elwynn Forest|N|To Eagan Peltskinner.|
r Sell junk|ACTIVE|7|M|47.69,41.42|Z|1429; Elwynn Forest|N|Godric Rothgar, west side of the Abbey.|
T Kobold Camp Cleanup|QID|7|M|48.92,41.61|Z|1429; Elwynn Forest|N|To Marshal McBride.|
A Investigate Echo Ridge|QID|15|PRE|7|M|48.92,41.61|Z|1429; Elwynn Forest|N|From Marshal McBride.|
A Simple Letter|QID|3100|PRE|7|M|48.92,41.61|Z|1429; Elwynn Forest|N|From Marshal McBride.|C|Warrior|
A Consecrated Letter|QID|3101|PRE|7|M|48.92,41.61|Z|1429; Elwynn Forest|N|From Marshal McBride.|C|Paladin|
A Encrypted Letter|QID|3102|PRE|7|M|48.92,41.61|Z|1429; Elwynn Forest|N|From Marshal McBride.|C|Rogue|
A Hallowed Letter|QID|3103|PRE|7|M|48.92,41.61|Z|1429; Elwynn Forest|N|From Marshal McBride.|C|Priest|
A Glyphic Letter|QID|3104|PRE|7|M|48.92,41.61|Z|1429; Elwynn Forest|N|From Marshal McBride.|C|Mage|
A Tainted Letter|QID|3105|PRE|7|M|48.92,41.61|Z|1429; Elwynn Forest|N|From Marshal McBride.|C|Warlock|
T Simple Letter|QID|3100|M|50.24,42.28|Z|1429; Elwynn Forest|N|To Llane Beshere in the Hall of Arms.|C|Warrior|
T Consecrated Letter|QID|3101|M|50.43,42.12|Z|1429; Elwynn Forest|N|To Brother Sammuel in the Hall of Arms.|C|Paladin|
T Encrypted Letter|QID|3102|M|49.7,42.6|Z|1429; Elwynn Forest|N|To Jorik Kerridan behind the Abbey.|C|Rogue|
T Hallowed Letter|QID|3103|M|50.3,39.9|Z|1429; Elwynn Forest|N|To Priestess Anetta in the Abbey library.|C|Priest|
T Glyphic Letter|QID|3104|M|50.4,39.4|Z|1429; Elwynn Forest|N|To Khelden Bremen in the Abbey library.|C|Mage|
T Tainted Letter|QID|3105|M|49.87,42.65|Z|1429; Elwynn Forest|N|To Drusilla La Salle outside the Abbey.|C|Warlock|
C Investigate Echo Ridge|QID|15|M|48.39,35.52|Z|1429; Elwynn Forest|N|Kill 10 Kobold Workers at Echo Ridge Mine (north).|T|Kobold Worker|
T Investigate Echo Ridge|QID|15|M|48.92,41.61|Z|1429; Elwynn Forest|N|To Marshal McBride.|
A Skirmish at Echo Ridge|QID|21|PRE|15|M|48.92,41.61|Z|1429; Elwynn Forest|N|From Marshal McBride.|
A Brotherhood of Thieves|QID|18|M|48.15,42.95|Z|1429; Elwynn Forest|N|From Deputy Willem.|
A Milly Osworth|QID|3903|M|48.15,42.95|Z|1429; Elwynn Forest|N|From Deputy Willem.|
T Milly Osworth|QID|3903|M|49.8,45.4|Z|1429; Elwynn Forest|N|To Milly Osworth at the vineyard south-east of the Abbey.|
A Milly's Harvest|QID|3904|PRE|3903|M|49.8,45.4|Z|1429; Elwynn Forest|N|From Milly Osworth.|
C Milly's Harvest|QID|3904|M|52.6,46.6|Z|1429; Elwynn Forest|N|Collect 8 Milly's Harvest from the crates in the vineyard.|L|11119 8|
C Brotherhood of Thieves|QID|18|M|53.6,44.5|Z|1429; Elwynn Forest|N|Kill Defias Thugs in the vineyard for 12 Red Burlap Bandanas.|L|182 12|
T Milly's Harvest|QID|3904|M|49.8,45.4|Z|1429; Elwynn Forest|N|To Milly Osworth.|
A Grape Manifest|QID|3905|PRE|3904|M|49.8,45.4|Z|1429; Elwynn Forest|N|From Milly Osworth.|
T Grape Manifest|QID|3905|M|48.9,42.6|Z|1429; Elwynn Forest|N|To Brother Neals upstairs in the Abbey.|
T Brotherhood of Thieves|QID|18|M|48.15,42.95|Z|1429; Elwynn Forest|N|To Deputy Willem.|
A Bounty on Garrick Padfoot|QID|6|PRE|18|M|48.15,42.95|Z|1429; Elwynn Forest|N|From Deputy Willem.|
C Skirmish at Echo Ridge|QID|21|M|49.4,35.4|Z|1429; Elwynn Forest|N|Kill 12 Kobold Laborers inside Echo Ridge Mine.|T|Kobold Laborer|
C Bounty on Garrick Padfoot|QID|6|M|56.7,49.5|Z|1429; Elwynn Forest|N|Garrick Padfoot is in the small house across the river to the south-east.|T|Garrick Padfoot|L|182 1|
T Bounty on Garrick Padfoot|QID|6|M|48.15,42.95|Z|1429; Elwynn Forest|N|To Deputy Willem.|
T Skirmish at Echo Ridge|QID|21|M|48.92,41.61|Z|1429; Elwynn Forest|N|To Marshal McBride.|
A Report to Goldshire|QID|54|PRE|21|M|48.92,41.61|Z|1429; Elwynn Forest|N|From Marshal McBride.|
R Goldshire|QID|54|M|43.7,65.8|Z|1429; Elwynn Forest|N|Follow the road south to Goldshire.|
T Report to Goldshire|QID|54|M|42.1,65.9|Z|1429; Elwynn Forest|N|To Marshal Dughan in Goldshire.|
h Goldshire|M|43.7,65.8|Z|1429; Elwynn Forest|N|Set your hearth at the Lion's Pride Inn (Innkeeper Farley).|
]],
})
