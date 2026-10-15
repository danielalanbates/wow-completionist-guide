-- CompletionRoute community guide.  License: CC BY-SA 4.0.  Format: see docs/GUIDE_FORMAT.md
-- Author: CompletionRoute contributors (initial: BatesAI). Zone: Durotar (uiMap 1411). Flavor: Classic Era / Anniversary / TBC.
local _, NS = ...
-- pre-Cataclysm quests (783, 4641, ...) do not exist on Cata/MoP clients (quest_location_audit: no Questie reference there)
if NS.flavor == "cata" or NS.flavor == "mop" then return end
NS.Guide.Register({
    id = "OR_OrcTroll_01_06_ValleyOfTrials", name = "Orc/Troll Starter: Valley of Trials (1-6)", type = "Leveling", zone = "Durotar",
    faction = "Horde", minlevel = 1, maxlevel = 6, author = "CompletionRoute community", source = "CompletionRoute",
    text = [[
A Your Place In The World|QID|4641|M|43.3,68.5|Z|1411; Durotar|N|From Kaltunk.|R|Orc;Troll|
T Your Place In The World|QID|4641|M|42.4,68.6|Z|1411; Durotar|N|To Gornek inside the Den.|
A Cutting Teeth|QID|788|PRE|4641|M|42.4,68.6|Z|1411; Durotar|N|From Gornek.|
C Cutting Teeth|QID|788|M|41.3,65.1;44.5,71.6|Z|1411; Durotar|N|Kill 10 Mottled Boars around the valley.|T|Mottled Boar|
T Cutting Teeth|QID|788|M|42.4,68.6|Z|1411; Durotar|N|To Gornek.|
A Sting of the Scorpid|QID|790|PRE|788|M|40.6,62.6|Z|1411; Durotar|N|From Hana'zua, lying wounded under the rock overhang north-west of the Den.|
A Vile Familiars|QID|792|PRE|788|M|42.5,68.4|Z|1411; Durotar|N|From Zureetha Fargaze outside the Den.|
A Lazy Peons|QID|4402|M|42.7,67.2|Z|1411; Durotar|N|From Foreman Thazz'ril.|U|5865|
C Lazy Peons|QID|4402|M|45.3,71.1;44.9,64.5;47.3,65.2|Z|1411; Durotar|N|Use the Foreman's Blackjack on sleeping peons near the trees.|U|5865|
C Sting of the Scorpid|QID|790|M|40.5,66.8|Z|1411; Durotar|N|Kill Scorpid Workers for 8 Scorpid Worker Tails.|L|4862 8|
C Vile Familiars|QID|792|M|45.8,58.5|Z|1411; Durotar|N|Kill 8 Vile Familiars at the Burning Blade Coven (north-east).|T|Vile Familiar|
T Lazy Peons|QID|4402|M|42.7,67.2|Z|1411; Durotar|N|To Foreman Thazz'ril.|
T Sting of the Scorpid|QID|790|M|40.6,62.6|Z|1411; Durotar|N|To Hana'zua.|
T Vile Familiars|QID|792|M|42.5,68.4|Z|1411; Durotar|N|To Zureetha Fargaze.|
A Burning Blade Medallion|QID|794|PRE|792|M|42.5,68.4|Z|1411; Durotar|N|From Zureetha Fargaze.|
C Burning Blade Medallion|QID|794|M|42.7,53.0|Z|1411; Durotar|N|Enter the Burning Blade Coven cave, kill Yarrog Baneshadow at the bottom.|T|Yarrog Baneshadow|L|4869 1|
T Burning Blade Medallion|QID|794|M|42.5,68.4|Z|1411; Durotar|N|To Zureetha Fargaze.|
A Report to Sen'jin Village|QID|805|PRE|794|M|42.5,68.4|Z|1411; Durotar|N|From Zureetha Fargaze.|
R Sen'jin Village|QID|805|M|55.6,74.6|Z|1411; Durotar|N|Leave the valley east and follow the road to Sen'jin Village.|
T Report to Sen'jin Village|QID|805|M|55.9,74.3|Z|1411; Durotar|N|To Master Gadrin.|
]],
})
