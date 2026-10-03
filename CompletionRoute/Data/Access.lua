-- CompletionRoute :: Data/Access.lua
-- ACCESS CHAINS: places you cannot simply travel to - an intro quest line, an item, an airship or a portal that
-- only exists after a quest. Each entry is (1) a transit edge for the router (from -> to, one-way, `cost` seconds
-- for doing the chain the first time, `after` = the cheaper edge that exists once `unlock` quests are complete)
-- and (2) the STEPS to get there, in CompletionRoute guide format (docs/GUIDE_FORMAT.md). When a guide's first
-- step lies behind a locked chain, Progress injects these steps in front of the guide (negative step indices),
-- exactly the way comprehensive zone guides open with the zone intro.
-- Facts only (quest ids, NPCs, map coordinates). Coordinates are map percentages; approximate +-2%.
-- `unlock` = quest ids that mark the chain done (any one complete = unlocked). `fac` = "A"|"H"|nil.
local ADDON, NS = ...
NS.AccessData = {
    -- ---------------- The War Within: Siren Isle (11.0.7) ----------------
    { key = "siren_isle", flavors = { retail = true }, unlock = { 84720 }, cost = 420,
      from = { "Dornogal", 41.86, 26.16 }, to = { "Siren Isle", 69.3, 48.0 },
      after = { from = { "Isle of Dorn", 55.40, 33.86 }, cost = 150, title = "Talk to Skaggit on the airship (Isle of Dorn) to sail to the Siren Isle" },
      title = "Siren Isle expedition: Dawn in Dornogal -> Skaggit's airship",
      steps = [[
A The Expedition Awaits|QID|84719|M|41.86,26.16|Z|Dornogal|N|Dawn, inside the building.|
T The Expedition Awaits|QID|84719|M|55.40,33.86|Z|Isle of Dorn|N|Skaggit, on the airship.|
A To the Siren Isle!|QID|84720|M|55.40,33.86|Z|Isle of Dorn|N|Skaggit, on the airship.|
C Talk to Skaggit to depart|QID|84720|QO|1|M|55.40,33.86|Z|Isle of Dorn|N|"I am ready to embark."|
C Rendezvous with Skaggit|QID|84720|QO|2|M|69.83,49.78|Z|Siren Isle|N|Jump off the ship into the water.|
T To the Siren Isle!|QID|84720|M|69.31,48.05|Z|Siren Isle|N|Skaggit walks to this spot.|
]] },
    -- ---------------- The War Within: K'aresh / Tazavesh (11.2) ----------------
    { key = "karesh", flavors = { retail = true }, unlock = { 84957 }, cost = 300,
      from = { "Dornogal", 43.36, 30.58 }, to = { "Tazavesh", 59.74, 83.36 },
      after = { from = { "Dornogal", 40.30, 22.66 }, cost = 20, title = "Take the Spatial Rift in Dornogal to Tazavesh (K'aresh)" },
      title = "K'aresh: the Locus-Walker's invitation -> Spatial Rift to Tazavesh",
      steps = [[
A A Shadowy Invitation|QID|84956|M|43.36,30.58|Z|Dornogal|
T A Shadowy Invitation|QID|84956|M|42.13,26.92|Z|Dornogal|N|Locus-Walker.|
A Return to the Veiled Market|QID|84957|M|42.13,26.92|Z|Dornogal|
C Follow the Locus-Walker|QID|84957|QO|1|M|40.30,22.66|Z|Dornogal|
C Take the Spatial Rift to Tazavesh|QID|84957|QO|2|M|40.30,22.66|Z|Dornogal|N|Click the Spatial Rift.|
T Return to the Veiled Market|QID|84957|M|59.74,83.36|Z|Tazavesh|N|Locus-Walker.|
]] },
    -- ---------------- Shadowlands: Zereth Mortis (9.2) ----------------
    { key = "zereth_mortis", flavors = { retail = true }, unlock = { 64944 }, cost = 900,
      from = { "Oribos", 38.91, 69.97 }, to = { "Zereth Mortis", 24.91, 53.61 },
      after = { from = { "Oribos", 38.91, 69.97 }, cost = 60, title = "Tal-Inara in Oribos: travel to Zereth Mortis" },
      title = "Zereth Mortis: Call of the Primus (Tal-Inara in Oribos) -> the Crucible -> portal",
      steps = [[
A Call of the Primus|QID|64942|M|38.91,69.97|Z|Oribos|N|Tal-Inara. Requires "Charge of the Covenants" (64007). If you have been to Zereth Mortis on another character, tell her so to skip the intro.|
C Travel to the Arbiter's Chamber|QID|64942|QO|1|M|38.92,69.95|Z|Oribos|N|"I am ready to go."|
T Call of the Primus|QID|64942|M|32.65,51.14|Z|The Crucible|N|The Primus.|
A A Hasty Voyage|QID|64944|M|34.14,52.34|Z|The Crucible|
C Ride the Anima Wyrm, clear the Mawsworn, enter the portal|QID|64944|QO|2|M|33.25,46.87|Z|The Crucible|N|Scenario: mount the Anima Wyrm at 33.25,46.87, defeat the Mawsworn, control the Winged Soul Eater at 32.75,72.63, then take the portal to Zereth Mortis.|
T A Hasty Voyage|QID|64944|M|24.91,53.61|Z|Zereth Mortis|N|Pelagos.|
]] },
    -- ---------------- Mists of Pandaria: Isle of Thunder (5.2) ----------------
    { key = "isle_of_thunder_h", fac = "H", flavors = { retail = true }, unlock = { 32680 }, cost = 600,
      from = { "Vale of Eternal Blossoms", 61.5, 19.8 }, to = { "Isle of Thunder", 28.4, 52.4 },
      after = { from = { "Vale of Eternal Blossoms", 62.5, 22.5 }, cost = 20, title = "Take the Shrine of Two Moons portal to the Isle of Thunder" },
      title = "Isle of Thunder (Horde): Thunder Calls -> Scout Captain Elsia in Townlong Steppes -> landing",
      steps = [[
A Thunder Calls|QID|32678|M|61.5,19.8|Z|Vale of Eternal Blossoms|N|Auto-offered at the Shrine of Two Moons (quest box under the minimap).|
T Thunder Calls|QID|32678|M|50.8,73.4|Z|Townlong Steppes|N|Scout Captain Elsia.|
A The Storm Gathers|QID|32680|M|50.8,73.4|Z|Townlong Steppes|
C Tell Elsia you are ready; discover the Isle of Thunder|QID|32680|M|50.8,73.4|Z|Townlong Steppes|
T The Storm Gathers|QID|32680|M|28.4,52.4|Z|Isle of Thunder|N|Lor'themar Theron.|
]] },
    { key = "isle_of_thunder_a", fac = "A", flavors = { retail = true }, unlock = { 32681 }, cost = 600,
      from = { "Vale of Eternal Blossoms", 84.8, 62.3 }, to = { "Isle of Thunder", 34.6, 89.5 },
      after = { from = { "Vale of Eternal Blossoms", 84.5, 62.0 }, cost = 20, title = "Take the Shrine of Seven Stars portal to the Isle of Thunder" },
      title = "Isle of Thunder (Alliance): Thunder Calls -> Vereesa Windrunner in Townlong Steppes -> landing",
      steps = [[
A Thunder Calls|QID|32679|M|84.8,62.3|Z|Vale of Eternal Blossoms|N|Auto-offered at the Shrine of Seven Stars.|
T Thunder Calls|QID|32679|M|49.9,69.0|Z|Townlong Steppes|N|Vereesa Windrunner.|
A The Storm Gathers|QID|32681|M|49.9,69.0|Z|Townlong Steppes|
C Tell Vereesa you are ready; discover the Isle of Thunder|QID|32681|M|49.9,69.0|Z|Townlong Steppes|
T The Storm Gathers|QID|32681|M|34.6,89.5|Z|Isle of Thunder|N|Lady Jaina Proudmoore.|
]] },
    -- ---------------- Midnight (12.0): Quel'Thalas ----------------
    { key = "midnight_h", fac = "H", flavors = { retail = true }, unlock = { 88719 }, cost = 600,
      from = { "Orgrimmar", 52.97, 77.46 }, to = { "2432", 52.5, 88.2, name = "Isle of Quel'Danas" },
      title = "Midnight: the Image of Lady Liadrin in Orgrimmar -> Light's Summon to Quel'Danas",
      steps = [[
A Midnight|QID|91281|M|52.97,77.46|Z|Orgrimmar|
C Locate the Image of Lady Liadrin|QID|91281|QO|1|M|53.43,77.32|Z|Orgrimmar|
T Midnight|QID|91281|M|53.43,77.32|Z|Orgrimmar|N|Image of Lady Liadrin.|
A A Voice from the Light|QID|88719|M|53.43,77.32|Z|Orgrimmar|N|If you have done the Midnight intro on another character, choose the skip option.|
U Use Light's Summon to travel to Quel'Danas|QID|88719|QO|2|U|239151|
A Silvermoon Negotiations|QID|86733|M|52.53,88.19|Z|2432; Isle of Quel'Danas|N|Lor'themar Theron.|
C Arrive at the Sanctum of Light|QID|86733|QO|1|M|45.44,70.34|Z|2443; Silvermoon City|
]] },
    { key = "midnight_a", fac = "A", flavors = { retail = true }, unlock = { 88719 }, cost = 600,
      from = { "Stormwind City", 53.26, 54.32 }, to = { "2432", 52.5, 88.2, name = "Isle of Quel'Danas" },
      title = "Midnight: the Image of Lady Liadrin in Stormwind -> Light's Summon to Quel'Danas",
      steps = [[
A Midnight|QID|91281|M|53.26,54.32|Z|Stormwind City|
C Locate the Image of Lady Liadrin|QID|91281|QO|1|M|53.26,54.32|Z|Stormwind City|
T Midnight|QID|91281|M|53.26,54.32|Z|Stormwind City|N|Image of Lady Liadrin.|
A A Voice from the Light|QID|88719|M|53.26,54.32|Z|Stormwind City|N|If you have done the Midnight intro on another character, choose the skip option.|
U Use Light's Summon to travel to Quel'Danas|QID|88719|QO|2|U|239151|
A Silvermoon Negotiations|QID|86733|M|52.53,88.19|Z|2432; Isle of Quel'Danas|N|Lor'themar Theron.|
C Arrive at the Sanctum of Light|QID|86733|QO|1|M|45.44,70.34|Z|2443; Silvermoon City|
]] },
    -- ---------------- Battle for Azeroth: Nazjatar (8.2), Alliance ----------------
    { key = "nazjatar_a", fac = "A", flavors = { retail = true }, unlock = { 56043 }, cost = 400,
      from = { "Boralus", 70.66, 27.19 }, to = { "Nazjatar", 48.33, 92.62 },
      after = { from = { "Boralus", 67.99, 21.91 }, cost = 90, title = "Harbormaster Cyrus Crestfall in Boralus: sail to Nazjatar" },
      title = "Nazjatar (Alliance): Send the Fleet - Genn Greymane in Boralus -> set sail with Cyrus Crestfall",
      steps = [[
A Send the Fleet|QID|56043|M|70.66,27.19|Z|Boralus|N|Genn Greymane. Requires the Tiragarde Sound / war campaign intro.|
C Set sail with Harbormaster Cyrus Crestfall|QID|56043|QO|1|M|67.99,21.91|Z|Boralus|N|"Greymane is waiting, I'm ready to set sail."|
T Send the Fleet|QID|56043|M|48.33,92.62|Z|Nazjatar|N|Genn Greymane, after the landing.|
]] },
    -- ---------------- The War Within: Undermine (11.1) ----------------
    { key = "undermine", flavors = { retail = true }, unlock = { 83151 }, cost = 1500,
      from = { "Dornogal", 42.22, 26.98 }, to = { "Undermine", 24.10, 51.17 },
      after = { from = { "The Ringing Deeps", 72.95, 73.20 }, cost = 60, title = "Take the Rocket Drill at Gutterside Rocket Station down to Undermine" },
      title = "Undermine: When Opportunity Explodes (Renzik in Dornogal) -> Gazlowe in the Ringing Deeps -> the Rocket Drill",
      steps = [[
A When Opportunity Explodes|QID|83137|M|42.22,26.98|Z|Dornogal|N|Renzik "The Shiv". Requires the Khaz Algar leveling campaign. Done it before? pick the skip option.|
T When Opportunity Explodes|QID|83137|M|63.00,78.39|Z|The Ringing Deeps|N|Monte Gazlowe.|
A Mixed Messages|QID|83139|M|63.00,78.39|Z|The Ringing Deeps|
C Mixed Messages: tollbooth, mining camp, talk to Aberee / Ishqikle / Trella|QID|83139|M|63.04,78.33;65.89,75.47;65.80,75.29|Z|The Ringing Deeps|
N Follow the "Undermined" campaign chapter 1 through "Down Undermine" (83151): Pamsy's Rocketboard at 70.33,89.58 then the Rocket Drill at Gutterside Rocket Station|M|72.95,73.20|Z|The Ringing Deeps|
T Down Undermine|QID|83151|M|24.10,51.17|Z|Undermine|N|Monte Gazlowe.|
]] },
    -- ---------------- Battle for Azeroth: Nazjatar (8.2), Horde ----------------
    -- APPROXIMATE: Horde facts from memory / community sources: Nathanos
    -- Blightcaller offers "Send the Fleet" (56044) at the Port of Zandalar; sail from the harbor. Verify in game.
    { key = "nazjatar_h", fac = "H", flavors = { retail = true }, unlock = { 56044 }, cost = 400, approx = true,
      from = { "Zuldazar", 58.0, 62.5 }, to = { "Nazjatar", 50.9, 94.2 },
      after = { from = { "Zuldazar", 58.0, 62.5 }, cost = 90, title = "Harbormaster at the Port of Zandalar: sail to Nazjatar" },
      title = "Nazjatar (Horde): Send the Fleet - Nathanos at the Port of Zandalar -> set sail",
      steps = [[
A Send the Fleet|QID|56044|M|58.0,62.5|Z|Zuldazar|N|Nathanos Blightcaller at the Port of Zandalar (approximate position).|
C Set sail with the harbormaster|QID|56044|QO|1|M|58.0,62.5|Z|Zuldazar|
T Send the Fleet|QID|56044|M|50.9,94.2|Z|Nazjatar|N|Nathanos, after the landing (Newhome).|
]] },
    -- ---------------- Legion: Argus (7.3) ----------------
    -- Once "Into the Night" is done the Vindicaar beacon in Dalaran (Krasus' Landing) takes you straight to Argus.
    { key = "argus_h", fac = "H", flavors = { retail = true }, unlock = { 48440 }, cost = 1500,
      from = { "627", 28.48, 48.33, name = "Dalaran" }, to = { "Krokuun", 40.30, 23.70 },
      after = { from = { "627", 73.0, 46.5, name = "Dalaran" }, cost = 30, title = "Take the Lightforged Beacon at Krasus' Landing (Dalaran) to the Vindicaar on Argus" },
      title = "Argus (Horde): The Hand of Fate - Khadgar in Dalaran -> Bladefist Bay -> the Exodar -> the Vindicaar",
      steps = [[
A The Hand of Fate|QID|47835^48507|M|28.48,48.33|Z|627; Dalaran|N|Archmage Khadgar. Requires "Assault on Broken Shore" (46734).|
C Meet the escort at Bladefist Bay|QID|47835^48507|QO|1|M|58.29,12.09|Z|Durotar|
T The Hand of Fate|QID|47835^48507|M|58.29,12.09|Z|Durotar|N|Lady Liadrin.|
A Two If By Sea|QID|47867|M|58.29,12.09|Z|Durotar|
C Set sail for the Exodar|QID|47867|QO|1|M|58.29,12.09|Z|Durotar|N|"I'm ready."|
T Two If By Sea|QID|47867|M|21.38,55.08|Z|Azuremyst Isle|N|Vindicator Boros (scenario version of Azuremyst).|
A Light's Exodus|QID|47223|M|21.38,55.08|Z|Azuremyst Isle|
T Light's Exodus|QID|47223|M|33.77,65.54|Z|The Exodar|N|Prophet Velen in the Vault of Lights.|
A The Vindicaar|QID|47224|M|33.77,65.54|Z|The Exodar|
C Activate the beacon, board the Vindicaar|QID|47224|M|33.68,66.33|Z|The Exodar|
T The Vindicaar|QID|47224|N|Prophet Velen aboard the Vindicaar.|
A Into the Night|QID|48440|N|Prophet Velen.|
C Depart for Argus|QID|48440|QO|1|N|"I am ready."|
T Into the Night|QID|48440|M|40.30,23.70|Z|Krokuun|N|Prophet Velen on Argus.|
]] },
    { key = "argus_a", fac = "A", flavors = { retail = true }, unlock = { 48440 }, cost = 1500,
      from = { "627", 28.48, 48.33, name = "Dalaran" }, to = { "Krokuun", 40.30, 23.70 },
      after = { from = { "627", 73.0, 46.5, name = "Dalaran" }, cost = 30, title = "Take the Lightforged Beacon at Krasus' Landing (Dalaran) to the Vindicaar on Argus" },
      title = "Argus (Alliance): The Hand of Fate - Khadgar in Dalaran -> Stormwind Harbor -> the Exodar -> the Vindicaar",
      steps = [[
A The Hand of Fate|QID|47221^48506|M|28.48,48.33|Z|627; Dalaran|N|Archmage Khadgar. Requires "Assault on Broken Shore" (46734).|
C Meet the escort at Stormwind Harbor|QID|47221^48506|QO|1|M|21.36,30.39|Z|Stormwind City|
T The Hand of Fate|QID|47221^48506|M|21.36,30.39|Z|Stormwind City|N|Vereesa Windrunner.|
A Two If By Sea|QID|47222|M|21.36,30.39|Z|Stormwind City|
C Set sail for the Exodar|QID|47222|QO|1|M|21.36,30.39|Z|Stormwind City|N|"I'm ready."|
T Two If By Sea|QID|47222|M|20.64,53.26|Z|Azuremyst Isle|N|Vindicator Boros (scenario version of Azuremyst).|
A Light's Exodus|QID|47223|M|20.64,53.26|Z|Azuremyst Isle|
T Light's Exodus|QID|47223|M|33.77,65.54|Z|The Exodar|N|Prophet Velen in the Vault of Lights.|
A The Vindicaar|QID|47224|M|33.77,65.54|Z|The Exodar|
C Activate the beacon, board the Vindicaar|QID|47224|M|33.68,66.33|Z|The Exodar|
T The Vindicaar|QID|47224|N|Prophet Velen aboard the Vindicaar.|
A Into the Night|QID|48440|N|Prophet Velen.|
C Depart for Argus|QID|48440|QO|1|N|"I am ready."|
T Into the Night|QID|48440|M|40.30,23.70|Z|Krokuun|N|Prophet Velen on Argus.|
]] },
    -- ---------------- Midnight (12.0): each Quel'Thalas zone is its own instance ----------------
    -- Quel'Danas (2858) -> Silvermoon City (2443, inst 2907) -> Eversong Woods (2594, inst 3074) -> Harandar (2413) ;
    -- Silvermoon -> Voidstorm (2405). The first trip is the campaign quest; afterwards the same portals stay open.
    { key = "midnight_silvermoon", flavors = { retail = true }, unlock = { 86733 }, cost = 240,
      from = { "2432", 52.53, 88.19, name = "Isle of Quel'Danas" }, to = { "2443", 45.44, 70.34, name = "Silvermoon City" },
      after = { from = { "2432", 52.53, 88.19, name = "Isle of Quel'Danas" }, cost = 60, title = "Travel from Quel'Danas to the Sanctum of Light (Silvermoon City)" },
      title = "Midnight: Silvermoon Negotiations - Lor'themar on Quel'Danas -> the Sanctum of Light",
      steps = [[
A Silvermoon Negotiations|QID|86733|M|52.53,88.19|Z|2432; Isle of Quel'Danas|N|Lor'themar Theron. Requires the Midnight intro up to "Light's Last Stand" (86852).|
C Arrive at the Sanctum of Light|QID|86733|QO|1|M|45.44,70.34|Z|2443; Silvermoon City|
]] },
    { key = "midnight_eversong", flavors = { retail = true }, unlock = { 86737 }, cost = 300,
      from = { "2443", 45.44, 70.34, name = "Silvermoon City" }, to = { "2594", 44.70, 44.98, name = "Eversong Woods" },
      after = { from = { "2443", 45.44, 70.34, name = "Silvermoon City" }, cost = 90, title = "Leave the Sanctum of Light for Eversong Woods (Fairbreeze Village)" },
      title = "Midnight: Fair Breeze, Light Bloom - Lor'themar in the Sanctum of Light -> Eversong Woods",
      steps = [[
A Fair Breeze, Light Bloom|QID|86737|M|45.44,70.34|Z|2443; Silvermoon City|N|Lor'themar Theron.|
C Obtain the Arcane Projector from Rommath|QID|86737|QO|1|M|45.31,70.51|Z|2443; Silvermoon City|
F Fairbreeze Village|M|44.70,44.98|Z|2594; Eversong Woods|N|Vael'thas Dawnsoar, flight master.|
]] },
    { key = "midnight_harandar", flavors = { retail = true }, unlock = { 86899 }, cost = 300,
      from = { "2594", 45.40, 45.52, name = "Eversong Woods" }, to = { "Harandar", 75.64, 53.58 },
      after = { from = { "2594", 45.14, 46.93, name = "Eversong Woods" }, cost = 20, title = "Take the Mysterious Rootway (Eversong Woods) to Harandar" },
      title = "Midnight: The Root Cause - Orweyna in Eversong Woods -> the Mysterious Rootway to Harandar",
      steps = [[
A The Root Cause|QID|86899|M|45.40,45.52|Z|2594; Eversong Woods|N|Orweyna (turn in "Harandar" 89402 first if you carry it).|
C Talk to Orweyna|QID|86899|QO|1|M|45.40,45.52|Z|2594; Eversong Woods|N|"I'm ready. Let's go!"|
C Take the portal to Harandar|QID|86899|QO|2|M|45.14,46.93|Z|2594; Eversong Woods|N|Click the Mysterious Rootway.|
T The Root Cause|QID|86899|M|75.64,53.58|Z|Harandar|N|Orweyna.|
]] },
    { key = "midnight_voidstorm", flavors = { retail = true }, unlock = { 86549 }, cost = 600,
      from = { "2443", 45.31, 70.17, name = "Silvermoon City" }, to = { "Voidstorm", 34.25, 60.45 },
      after = { from = { "2443", 35.28, 66.18, name = "Silvermoon City" }, cost = 20, title = "Take the Portal to Voidstorm (Silvermoon City)" },
      title = "Midnight: Magisters' Terrace: Homecoming - Umbric in the Sanctum of Light -> the Portal to Voidstorm",
      steps = [[
A Magisters' Terrace: Homecoming|QID|86543|M|45.31,70.17|Z|2443; Silvermoon City|N|Magister Umbric. Level 86, or the Midnight achievement.|
N Follow the Voidstorm opening chapter to "No Fear of the Dark" (86549)|M|45.31,70.17|Z|2443; Silvermoon City|
C Connect the three Shadow Foci|QID|86549|QO|1|M|35.01,65.45|Z|2443; Silvermoon City|
C Enter the Portal to Voidstorm|QID|86549|QO|3|M|35.28,66.18|Z|2443; Silvermoon City|
T No Fear of the Dark|QID|86549|M|34.25,60.45|Z|Voidstorm|N|Magister Umbric.|
]] },
}
