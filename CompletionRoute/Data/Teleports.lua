-- CompletionRoute :: Data/Teleports.lua
-- TELEPORTS the router may use as a first leg, exactly like the Hearthstone (Routing/Teleports.lua): class teleports,
-- Hearthstone stand-ins (toys and items that share the Hearthstone's destination and cooldown), the Dalaran and
-- Garrison hearthstones and engineering transporters.  An entry becomes an edge only for a character who knows the
-- spell or owns the item or toy, when its cooldown has at most 15 minutes left (the Hearthstone's rule).
--
-- Facts only.  Ids and names: Blizzard client tables (SpellName / ItemSparse, cooldowns from ItemEffect, reagents from
-- SpellReagents, via wago.tools) at the builds pinned in tools/wiki/fetch_db2.py, checked by tools/check_teleports.py.
-- Landing points: Warcraft Wiki (warcraft.wiki.gg, CC BY-SA 4.0, by the Warcraft Wiki contributors) - the page named
-- in `src`, whose {{Co|x|y|map}} is on the modern (retail) map given in `cite` - or a Blizzard TaxiNodes position
-- (Data/Taxi_<flavor>.lua).  `to` is that point in world coordinates { instance, worldX, worldY, name }, so one entry
-- serves every client (city maps were redrawn, the world was not); tools/test_teleports.lua recomputes every `to` from
-- its `cite`.  A landing spot the player actually arrives at is learned and replaces `to` (CompletionRouteDB.teleportFix).
--
-- Fields:
--   key, kind = "spell" | "item", id, name (DB2 name; `names` = per-flavor name where a client spells it differently)
--   flavors = { era, tbc, mop, retail } (NS.flavor: "era" covers WoW Forever), fac = "A" | "H", class = "MAGE" ...
--   reagent = { [dataFlavor] = itemID }   the spell needs this item in the bags (Rune of Teleportation on Classic)
--   equip = { [dataFlavor] = true }       a trinket that only works while worn (Classic engineering transporters)
--   profession = SkillLine id the item needs (202 Engineering; ItemSparse RequiredSkill, whose retail tier lines such as
--                2506 "Classic Engineering" have 202 as their SkillLine parent); a character known to lack it is skipped
--   spell = the item's use spell (ItemEffect), cast = cast seconds, cd = cooldown seconds (informational: the live
--   cooldown comes from the client), hearth = true: a Hearthstone stand-in (no `to`: it goes to the hearth),
--   cond = same as Data/Transit.lua `cond` (Routing/TravelGraph.lua TG.CondOK), approx = landing point is approximate
--   src = where the facts come from ("wiki <page>"; "point: wiki <page>" for the page holding the coordinate);
--   wiki = the cited pages, where `src` cannot name them plainly (tools/check_teleports.py --wiki reads them)
local ADDON, NS = ...
local CLASSIC = { era = true, tbc = true, mop = true, retail = true }
local TBC_ON = { tbc = true, mop = true, retail = true }
local MOP_ON = { mop = true, retail = true }
local RETAIL = { retail = true }
local RUNE = { era = 17031, forever = 17031, tbc = 17031 }   -- Rune of Teleportation: SpellReagents era/forever/tbc, none on mop/retail

NS.TeleportData = {
    -- ===================== MAGE: Alliance cities =====================
    { key = "mage_stormwind", kind = "spell", id = 3561, name = "Teleport: Stormwind", class = "MAGE", fac = "A", flavors = CLASSIC,
      reagent = RUNE, cast = 10, to = { 0, -9041.1, 917.6, "Wizard's Sanctum, Stormwind City" },
      cite = { 84, 46.35, 90.24 }, src = "wiki Teleport: Stormwind" },
    { key = "mage_ironforge", kind = "spell", id = 3562, name = "Teleport: Ironforge", class = "MAGE", fac = "A", flavors = CLASSIC,
      reagent = RUNE, cast = 10, to = { 0, -4613.7, -915.4, "Hall of Mysteries, Ironforge" },
      cite = { 87, 25.52, 8.43 }, src = "wiki Teleport: Ironforge" },
    -- Darnassus: the city on Classic clients; retail's default (Battle for Azeroth) Darkshore phase lands on Mist's Edge
    { key = "mage_darnassus", kind = "spell", id = 3565, name = "Teleport: Darnassus", class = "MAGE", fac = "A", flavors = { era = true, tbc = true, mop = true },
      reagent = RUNE, cast = 10, to = { 1, 9656.5, 2518.2, "Temple of the Moon, Darnassus" },
      cite = { 89, 43.47, 78.68 }, src = "wiki Teleport: Darnassus" },
    { key = "mage_darnassus_bfa", kind = "spell", id = 3565, name = "Teleport: Darnassus", class = "MAGE", fac = "A", flavors = RETAIL,
      cast = 10, to = { 1, 7414.7, 46.2, "Mist's Edge, Darkshore" }, cite = { 62, 45.95, 18.75 },
      src = "wiki Teleport: Darnassus (Battle for Azeroth phase; Zidormi switches it back to the city)" },
    { key = "mage_exodar", kind = "spell", id = 32271, name = "Teleport: Exodar", class = "MAGE", fac = "A", flavors = TBC_ON,
      reagent = RUNE, cast = 10, to = { 530, -4031.3, -11569.6, "Vault of Lights, The Exodar" },
      cite = { 103, 47.62, 59.83 }, src = "wiki Teleport: Exodar" },
    { key = "mage_theramore", kind = "spell", id = 49359, name = "Teleport: Theramore", class = "MAGE", fac = "A", flavors = TBC_ON,
      reagent = RUNE, cast = 10, to = { 1, -3748.3, -4440.0, "Jaina's tower, Theramore Isle" },
      cite = { 70, 66.0, 49.0 }, src = "wiki Teleport: Theramore" },
    -- ===================== MAGE: Horde cities =====================
    -- Orgrimmar was rebuilt in Cataclysm: the wiki's spot (Pathfinder's Den, by the south gate) is the modern one
    { key = "mage_orgrimmar", kind = "spell", id = 3567, name = "Teleport: Orgrimmar", class = "MAGE", fac = "H", flavors = CLASSIC,
      reagent = RUNE, cast = 10, to = { 1, 1445.1, -4499.7, "Pathfinder's Den, Orgrimmar" },
      cite = { 85, 57.11, 89.82 }, src = "wiki Teleport: Orgrimmar (modern city; approximate on Classic Era and TBC)" },
    { key = "mage_undercity", kind = "spell", id = 3563, name = "Teleport: Undercity", class = "MAGE", fac = "H", flavors = { era = true, tbc = true, mop = true },
      reagent = RUNE, cast = 10, to = { 0, 1773.4, 61.7, "Temple of the Damned, Undercity" },
      cite = { 90, 84.59, 16.33 }, src = "wiki Teleport: Undercity" },
    { key = "mage_undercity_bfa", kind = "spell", id = 3563, name = "Teleport: Undercity", class = "MAGE", fac = "H", flavors = RETAIL,
      cast = 10, to = { 0, 1947.2, -98.2, "hill by the Ruins of Lordaeron, Tirisfal Glades" }, cite = { 18, 69.3, 62.75 },
      src = "wiki Teleport: Undercity (Battle for Azeroth phase; Zidormi switches it back to the city)" },
    { key = "mage_thunderbluff", kind = "spell", id = 3566, name = "Teleport: Thunder Bluff", class = "MAGE", fac = "H", flavors = CLASSIC,
      reagent = RUNE, cast = 10, to = { 1, -967.4, 284.7, "Pools of Vision, Thunder Bluff" },
      cite = { 88, 22.22, 16.87 }, src = "wiki Teleport: Thunder Bluff" },
    { key = "mage_silvermoon", kind = "spell", id = 32272, name = "Teleport: Silvermoon", names = { retail = "Teleport: Silvermoon (Burning Crusade)" },
      class = "MAGE", fac = "H", flavors = TBC_ON, reagent = RUNE, cast = 10, to = { 530, 9998.4, -7106.7, "Sunfury Spire, Silvermoon City" },
      cite = { 110, 58.27, 19.25 }, src = "wiki Teleport: Silvermoon" },
    { key = "mage_stonard", kind = "spell", id = 49358, name = "Teleport: Stonard", class = "MAGE", fac = "H", flavors = TBC_ON,
      reagent = RUNE, cast = 10, to = { 0, -10469.1, -3331.7, "Stonard, Swamp of Sorrows" },
      cite = { 51, 49.85, 55.81 }, src = "wiki Teleport: Stonard" },
    -- ===================== MAGE: expansion hubs =====================
    { key = "mage_shattrath_a", kind = "spell", id = 33690, name = "Teleport: Shattrath", class = "MAGE", fac = "A", flavors = TBC_ON,
      reagent = RUNE, cast = 10, to = { 530, -1902.5, 5442.8, "Terrace of Light, Shattrath City" },
      cite = { 111, 53.01, 49.21 }, src = "wiki Teleport: Shattrath" },
    { key = "mage_shattrath_h", kind = "spell", id = 35715, name = "Teleport: Shattrath", class = "MAGE", fac = "H", flavors = TBC_ON,
      reagent = RUNE, cast = 10, to = { 530, -1902.5, 5442.8, "Terrace of Light, Shattrath City" },
      cite = { 111, 53.01, 49.21 }, src = "wiki Teleport: Shattrath" },
    { key = "mage_dalaran_northrend", kind = "spell", id = 53140, name = "Teleport: Dalaran", names = { retail = "Teleport: Dalaran - Northrend" },
      class = "MAGE", flavors = MOP_ON, cast = 10, to = { 571, 5807.7, 588.3, "Violet Gate, Dalaran (Northrend)" },
      cite = { 125, 55.93, 46.8 }, src = "wiki Teleport: Dalaran - Northrend" },
    { key = "mage_ancient_dalaran", kind = "spell", id = 120145, name = "Ancient Teleport: Dalaran", class = "MAGE", flavors = MOP_ON,
      cast = 10, to = { 0, 302.9, 347.0, "above Dalaran Crater, Hillsbrad Foothills" },
      cite = { 25, 30.91, 36.35 }, src = "wiki Ancient Teleport: Dalaran" },
    { key = "mage_tolbarad_a", kind = "spell", id = 88342, name = "Teleport: Tol Barad", class = "MAGE", fac = "A", flavors = MOP_ON,
      cast = 10, to = { 732, -369.3, 1058.6, "Baradin Base Camp, Tol Barad Peninsula" },
      cite = { 245, 73.68, 60.93 }, src = "wiki Teleport: Tol Barad" },
    { key = "mage_tolbarad_h", kind = "spell", id = 88344, name = "Teleport: Tol Barad", class = "MAGE", fac = "H", flavors = MOP_ON,
      cast = 10, to = { 732, -603.8, 1387.5, "Hellscream's Grasp, Tol Barad Peninsula" },
      cite = { 245, 55.78, 80.07 }, src = "wiki Teleport: Tol Barad" },
    { key = "mage_vale_a", kind = "spell", id = 132621, name = "Teleport: Vale of Eternal Blossoms", class = "MAGE", fac = "A", flavors = MOP_ON,
      cast = 10, to = { 870, 917.5, 294.7, "Summer Terrace, Shrine of Seven Stars" },
      cite = { 390, 86.31, 61.06 }, src = "wiki Teleport: Vale of Eternal Blossoms" },
    { key = "mage_vale_h", kind = "spell", id = 132627, name = "Teleport: Vale of Eternal Blossoms", class = "MAGE", fac = "H", flavors = MOP_ON,
      cast = 10, to = { 870, 1579.5, 897.7, "Golden Terrace, Shrine of Two Moons" },
      cite = { 390, 62.51, 21.83 }, src = "wiki Teleport: Vale of Eternal Blossoms" },
    { key = "mage_stormshield", kind = "spell", id = 176248, name = "Teleport: Stormshield", class = "MAGE", fac = "A", flavors = RETAIL,
      cast = 10, to = { 1116, 3744.3, -4055.9, "Andromath's Rise, Stormshield" },
      cite = { 622, 62.68, 35.79 }, src = "wiki Teleport: Stormshield" },
    { key = "mage_warspear", kind = "spell", id = 176242, name = "Teleport: Warspear", class = "MAGE", fac = "H", flavors = RETAIL,
      cast = 10, to = { 1116, 5267.8, -4060.3, "Tower of Elements, Warspear" },
      cite = { 624, 58.84, 51.36 }, src = "wiki Teleport: Warspear" },
    { key = "mage_dalaran_broken_isles", kind = "spell", id = 224869, name = "Teleport: Dalaran - Broken Isles", class = "MAGE", flavors = RETAIL,
      cast = 10, to = { 1220, -828.7, 4371.7, "Krasus' Landing, Dalaran (Broken Isles)" },
      cite = { 627, 60.93, 44.73 }, src = "wiki Teleport: Dalaran - Broken Isles" },
    { key = "mage_boralus", kind = "spell", id = 281403, name = "Teleport: Boralus", class = "MAGE", fac = "A", flavors = RETAIL,
      cast = 10, to = { 1643, 1137.3, -538.6, "Sanctum of the Sages, Boralus" },
      cite = { 1161, 70.91, 16.39 }, src = "wiki Teleport: Boralus" },
    { key = "mage_dazaralor", kind = "spell", id = 281404, name = "Teleport: Dazar'alor", class = "MAGE", fac = "H", flavors = RETAIL,
      cast = 10, to = { 1642, -1657.7, 359.8, "Hall of Ancient Paths, Dazar'alor" },
      cite = { 1165, 65.75, 74.33 }, src = "wiki Teleport: Dazar'alor" },
    { key = "mage_oribos", kind = "spell", id = 344587, name = "Teleport: Oribos", class = "MAGE", flavors = RETAIL,
      cast = 10, to = { 2222, -1834.2, 1542.2, "western point of Oribos" },
      cite = { 1670, 20.37, 50.32 }, src = "wiki Teleport: Oribos" },
    { key = "mage_valdrakken", kind = "spell", id = 395277, name = "Teleport: Valdrakken", class = "MAGE", flavors = RETAIL,
      cast = 10, to = { 2444, 282.6, -1059.6, "Seat of the Aspects, Valdrakken" },
      cite = { 2112, 59.2, 37.9 }, src = "wiki Teleport: Valdrakken (point: wiki Seat of the Aspects)" },
    { key = "mage_dornogal", kind = "spell", id = 446540, name = "Teleport: Dornogal", class = "MAGE", flavors = RETAIL,
      cast = 10, to = { 2552, 2922.0, -2394.3, "Foundation Hall, Dornogal" },
      cite = { 2339, 41, 27 }, src = "wiki Teleport: Dornogal (point: wiki Foundation Hall)" },
    -- ===================== DRUID / DEATH KNIGHT =====================
    { key = "druid_moonglade", kind = "spell", id = 18960, name = "Teleport: Moonglade", class = "DRUID", flavors = CLASSIC,
      cast = 10, to = { 1, 7888.2, -2503.1, "Nighthaven, Moonglade" },
      cite = { 80, 48.6, 39.2 }, src = "wiki Teleport: Moonglade (point: wiki Nighthaven)" },
    -- MoP Classic only: on retail the gate leads to one of two Acherus (Plaguelands or Broken Shore) depending on Legion progress
    { key = "dk_death_gate", kind = "spell", id = 50977, name = "Death Gate", class = "DEATHKNIGHT", flavors = { mop = true },
      cast = 10, cd = 60, to = { 0, 2352.4, -5666.9, "Acherus: The Ebon Hold" }, approx = true,
      cite = { taxi = 315, flavor = "mop" }, src = "wiki Death Gate (Acherus over the Eastern Plaguelands); point: TaxiNodes 315, the hold's flight master" },
    -- ===================== ENGINEERING TRANSPORTERS =====================
    -- Classic Era and TBC: trinkets (ItemSparse InventoryType 12) - they only work while worn.  Since patch 3.2.0 they are
    -- used from the bags (Forever and MoP Classic: InventoryType 0); toys on MoP Classic and retail (Toy table).
    { key = "eng_everlook", kind = "item", id = 18984, name = "Dimensional Ripper - Everlook", spell = 23442, flavors = CLASSIC,
      profession = 202, equip = { era = true, tbc = true }, cast = 10, cd = 14400, to = { 1, 6751.9, -4632.5, "Everlook, Winterspring" },
      cite = { 83, 59.2, 49.8 }, src = "wiki Dimensional Ripper - Everlook (point: wiki Everlook); Goblin Engineering" },
    { key = "eng_gadgetzan", kind = "item", id = 18986, name = "Ultrasafe Transporter: Gadgetzan", spell = 23453, flavors = CLASSIC,
      profession = 202, equip = { era = true, tbc = true }, cast = 10, cd = 14400, to = { 1, -7117.2, -3740.9, "Gadgetzan, Tanaris" },
      cite = { 71, 51, 28 }, src = "wiki Ultrasafe Transporter: Gadgetzan (point: wiki Gadgetzan); Gnomish Engineering" },
    { key = "eng_area52", kind = "item", id = 30542, name = "Dimensional Ripper - Area 52", spell = 36890, flavors = TBC_ON,
      profession = 202, equip = { tbc = true }, cast = 10, cd = 14400, to = { 530, 3077.6, 3643.6, "Area 52, Netherstorm" },
      cite = { 109, 33, 64 }, src = "wiki Dimensional Ripper - Area 52 (point: wiki Area 52); Goblin Engineering" },
    { key = "eng_toshley", kind = "item", id = 30544, name = "Ultrasafe Transporter: Toshley's Station", spell = 36941, flavors = TBC_ON,
      profession = 202, equip = { tbc = true }, cast = 10, cd = 14400, to = { 530, 1949.0, 5590.8, "Toshley's Station, Blade's Edge Mountains" },
      cite = { 105, 60, 68 }, src = "wiki Ultrasafe Transporter: Toshley's Station (point: wiki Toshley's Station); Gnomish Engineering" },
    -- ===================== HUB HEARTHSTONES (own destination, own cooldown) =====================
    { key = "dalaran_hearthstone", kind = "item", id = 140192, name = "Dalaran Hearthstone", spell = 222695, flavors = RETAIL,
      cast = 10, cd = 1200, to = { 1220, -828.7, 4371.7, "Dalaran (Broken Isles)" }, approx = true,
      cite = { 627, 60.93, 44.73 }, wiki = { "Dalaran Hearthstone", "Teleport: Dalaran - Broken Isles" },
      src = "wiki Dalaran Hearthstone (names the city only; point: Krasus' Landing from wiki Teleport: Dalaran - Broken Isles)" },
    { key = "garrison_hearthstone_a", kind = "item", id = 110560, name = "Garrison Hearthstone", spell = 171253, fac = "A", flavors = RETAIL,
      cast = 10, cd = 1200, cond = { quest = 34586 }, to = { 1116, 1866.6, 219.5, "Lunarfall garrison, Shadowmoon Valley" },
      cite = { taxi = 1476, flavor = "retail" }, wiki = { "Garrison Hearthstone", "Establish Your Garrison (Alliance)" },
      src = "wiki Garrison Hearthstone; quest 34586 from wiki Establish Your Garrison (Alliance); point: TaxiNodes 1476" },
    { key = "garrison_hearthstone_h", kind = "item", id = 110560, name = "Garrison Hearthstone", spell = 171253, fac = "H", flavors = RETAIL,
      cast = 10, cd = 1200, cond = { quest = 34378 }, to = { 1116, 5578.9, 4564.8, "Frostwall garrison, Frostfire Ridge" },
      cite = { taxi = 1432, flavor = "retail" }, wiki = { "Garrison Hearthstone", "Establish Your Garrison (Horde)" },
      src = "wiki Garrison Hearthstone; quest 34378 from wiki Establish Your Garrison (Horde); point: TaxiNodes 1432" },
    -- ===================== HEARTHSTONE STAND-INS (wiki Hearthstone, "Hearthstone equivalents") =====================
    -- Same destination and shared cooldown as the Hearthstone (checked: their use spell shares the Hearthstone's
    -- SpellCategories Category or ChargeCategory in each client).  Used only when no Hearthstone is in the bags.
    { key = "hs_dark_portal_classic", kind = "item", id = 184871, name = "Dark Portal", spell = 348699, hearth = true, flavors = { tbc = true, mop = true }, src = "wiki Hearthstone; DB2" },
    { key = "hs_naaru_embrace", kind = "item", id = 260221, name = "Naaru's Embrace", spell = 1265709, hearth = true, flavors = { tbc = true, mop = true }, src = "wiki Hearthstone; DB2" },
    { key = "hs_ethereal_portal", kind = "item", id = 54452, name = "Ethereal Portal", spell = 75136, hearth = true, flavors = MOP_ON, src = "wiki Hearthstone; DB2" },
    { key = "hs_innkeepers_daughter", kind = "item", id = 64488, name = "The Innkeeper's Daughter", spell = 94719, hearth = true, flavors = MOP_ON, src = "wiki Hearthstone; DB2" },
    { key = "hs_dark_portal", kind = "item", id = 93672, name = "Dark Portal", spell = 136508, hearth = true, flavors = MOP_ON, src = "wiki Hearthstone; DB2" },
    { key = "hs_tome_of_town_portal", kind = "item", id = 142542, name = "Tome of Town Portal", spell = 231504, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
    { key = "hs_greatfather_winter", kind = "item", id = 162973, name = "Greatfather Winter's Hearthstone", spell = 278244, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
    { key = "hs_headless_horseman", kind = "item", id = 163045, name = "Headless Horseman's Hearthstone", spell = 278559, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
    { key = "hs_lunar_elder", kind = "item", id = 165669, name = "Lunar Elder's Hearthstone", spell = 285362, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
    { key = "hs_peddlefeet", kind = "item", id = 165670, name = "Peddlefeet's Lovely Hearthstone", spell = 285424, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
    { key = "hs_noble_gardener", kind = "item", id = 165802, name = "Noble Gardener's Hearthstone", spell = 286031, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
    { key = "hs_fire_eater", kind = "item", id = 166746, name = "Fire Eater's Hearthstone", spell = 286331, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
    { key = "hs_brewfest_reveler", kind = "item", id = 166747, name = "Brewfest Reveler's Hearthstone", spell = 286353, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
    { key = "hs_holographic", kind = "item", id = 168907, name = "Holographic Digitalization Hearthstone", spell = 298068, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
    { key = "hs_eternal_traveler", kind = "item", id = 172179, name = "Eternal Traveler's Hearthstone", spell = 308742, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
    { key = "hs_night_fae", kind = "item", id = 180290, name = "Night Fae Hearthstone", spell = 326064, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
    { key = "hs_necrolord", kind = "item", id = 182773, name = "Necrolord Hearthstone", spell = 340200, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
    { key = "hs_venthyr_sinstone", kind = "item", id = 183716, name = "Venthyr Sinstone", spell = 342122, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
    { key = "hs_kyrian", kind = "item", id = 184353, name = "Kyrian Hearthstone", spell = 345393, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
    { key = "hs_dominated", kind = "item", id = 188952, name = "Dominated Hearthstone", spell = 363799, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
    { key = "hs_enlightened", kind = "item", id = 190196, name = "Enlightened Hearthstone", spell = 366945, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
    { key = "hs_broker_matrix", kind = "item", id = 190237, name = "Broker Translocation Matrix", spell = 367013, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
    { key = "hs_timewalker", kind = "item", id = 193588, name = "Timewalker's Hearthstone", spell = 375357, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
    { key = "hs_ohnir_windsage", kind = "item", id = 200630, name = "Ohn'ir Windsage's Hearthstone", spell = 391042, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
    { key = "hs_path_of_the_naaru", kind = "item", id = 206195, name = "Path of the Naaru", spell = 412555, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
    { key = "hs_deepdweller", kind = "item", id = 208704, name = "Deepdweller's Earthen Hearthstone", spell = 420418, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
    { key = "hs_of_the_flame", kind = "item", id = 209035, name = "Hearthstone of the Flame", spell = 422284, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
    { key = "hs_draenic_hologem", kind = "item", id = 210455, name = "Draenic Hologem", spell = 438606, hearth = true, flavors = RETAIL,
      cond = { race = { Draenei = true, LightforgedDraenei = true } }, src = "wiki Hearthstone (draenei heritage reward); DB2" },
    { key = "hs_notorious_thread", kind = "item", id = 228940, name = "Notorious Thread's Hearthstone", spell = 463481, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
    { key = "hs_redeployment_module", kind = "item", id = 235016, name = "Redeployment Module", spell = 1217281, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
    { key = "hs_explosive", kind = "item", id = 236687, name = "Explosive Hearthstone", spell = 1220729, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
    { key = "hs_post_master", kind = "item", id = 245970, name = "P.O.S.T. Master's Express Hearthstone", spell = 1240219, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
    { key = "hs_cosmic", kind = "item", id = 246565, name = "Cosmic Hearthstone", spell = 1242509, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
    { key = "hs_naaru_enfold", kind = "item", id = 263489, name = "Naaru's Enfold", spell = 1270583, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
    { key = "hs_preyseeker", kind = "item", id = 263933, name = "Preyseeker's Hearthstone", spell = 1270814, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
    { key = "hs_corewarden", kind = "item", id = 265100, name = "Corewarden's Hearthstone", spell = 1273401, hearth = true, flavors = RETAIL, src = "wiki Hearthstone; DB2" },
}
