-- CompletionRoute :: Data/Transit.lua
-- Hand-authored transit edges: boats, zeppelins, trams, portals, orbs.  Facts about the game world.
-- Each entry: { from = {zone, x, y}, to = {zone, x, y}, mode, fac = "A"|"H"|nil, cost = seconds (avg wait + ride),
--              flavors = {era=true, tbc=true, ...} (nil = all), title = "..." , twoway = true (default) }
-- Coordinates are map percentages (0-100) on the named zone map.  Zone names are English uiMap names.
-- NOTE: some coordinates are approximate (±2%). Walking cost is derived from them; a small error is harmless.
-- Contributions welcome — keep this list factual and flavour-tagged.
local ADDON, NS = ...
local R = { cata = true, mop = true, wod = true, legion = true, bfa = true, sl = true, df = true, retail = true }   -- Cataclysm-onward clients
NS.TransitData = {
    -- ===================== NEUTRAL BOATS =====================
    { from = { "Stranglethorn Vale", 27.4, 77.2 }, to = { "The Barrens", 63.9, 38.6 }, mode = "boat", cost = 150, title = "Take the boat Booty Bay <-> Ratchet" },
    -- ===================== ALLIANCE BOATS =====================
    { from = { "Wetlands", 4.7, 56.9 }, to = { "Darkshore", 32.4, 43.9 }, mode = "boat", fac = "A", cost = 160, title = "Take the boat Menethil Harbor <-> Auberdine" },
    { from = { "Wetlands", 6.6, 59.5 }, to = { "Dustwallow Marsh", 71.7, 56.4 }, mode = "boat", fac = "A", cost = 160, title = "Take the boat Menethil Harbor <-> Theramore" },
    { from = { "Darkshore", 30.4, 40.6 }, to = { "Teldrassil", 55.4, 93.5 }, mode = "boat", fac = "A", cost = 120, title = "Take the boat Auberdine <-> Rut'theran Village" },
    { from = { "Darkshore", 30.9, 41.9 }, to = { "Azuremyst Isle", 20.4, 54.2 }, mode = "boat", fac = "A", cost = 140, flavors = { tbc = true, wrath = true, cata = true, mop = true, retail = true }, title = "Take the boat Auberdine <-> Valaar's Berth (Azuremyst)" },
    { from = { "Feralas", 30.9, 43.2 }, to = { "Feralas", 45.7, 43.9 }, mode = "boat", fac = "A", cost = 90, title = "Take the boat Forgotten Coast <-> Feathermoon Stronghold" },
    { from = { "Teldrassil", 55.9, 89.6 }, to = { "Darnassus", 30.1, 41.4 }, mode = "portal", fac = "A", cost = 5, title = "Enter the portal Rut'theran <-> Darnassus" },
    { from = { "Stormwind City", 69.9, 32.4 }, to = { "Ironforge", 76.6, 51.5 }, mode = "tram", fac = "A", cost = 110, title = "Ride the Deeprun Tram Stormwind <-> Ironforge" },
    { from = { "The Exodar", 47.5, 61.0 }, to = { "Azuremyst Isle", 32.6, 48.5 }, mode = "portal", fac = "A", cost = 5, flavors = { tbc = true, wrath = true, cata = true, mop = true, retail = true }, title = "Exit/Enter The Exodar (Azuremyst side)" },
    -- ===================== HORDE ZEPPELINS =====================
    { from = { "Durotar", 51.0, 12.0 }, to = { "Tirisfal Glades", 60.9, 58.8 }, mode = "zeppelin", fac = "H", cost = 170, title = "Take the zeppelin Orgrimmar <-> Undercity" },
    { from = { "Durotar", 51.0, 12.0 }, to = { "Stranglethorn Vale", 37.7, 52.9 }, mode = "zeppelin", fac = "H", cost = 170, title = "Take the zeppelin Orgrimmar <-> Grom'gol" },
    { from = { "Tirisfal Glades", 60.9, 58.8 }, to = { "Stranglethorn Vale", 37.7, 52.9 }, mode = "zeppelin", fac = "H", cost = 170, flavors = { tbc = true, wrath = true, cata = true, mop = true, retail = true }, title = "Take the zeppelin Undercity <-> Grom'gol" },
    { from = { "Silvermoon City", 49.5, 14.8 }, to = { "Undercity", 56.9, 11.4 }, mode = "portal", fac = "H", cost = 5, flavors = { tbc = true, wrath = true, cata = true, mop = true, retail = true }, title = "Use the Orb of Translocation Silvermoon <-> Undercity" },
    { from = { "Eastern Plaguelands", 59.7, 12.5 }, to = { "Ghostlands", 52.0, 98.0 }, mode = "portal", cost = 5, flavors = { tbc = true, wrath = true, cata = true, mop = true, retail = true }, title = "Walk through the portal Eastern Plaguelands <-> Ghostlands" },
    -- ===================== OUTLAND (TBC+) =====================
    { from = { "Blasted Lands", 58.7, 59.7 }, to = { "Hellfire Peninsula", 89.0, 50.0 }, mode = "portal", cost = 8, flavors = { tbc = true, wrath = true, cata = true, mop = true, retail = true }, title = "Walk through the Dark Portal" },
    -- Shattrath portals to capitals (one-way, TBC). Terrace of Light.
    { from = { "Shattrath City", 57.0, 48.5 }, to = { "Stormwind City", 49.6, 86.9 }, mode = "portal", fac = "A", cost = 5, twoway = false, flavors = { tbc = true }, title = "Take the Shattrath portal to Stormwind" },
    { from = { "Shattrath City", 57.0, 48.5 }, to = { "Ironforge", 27.2, 7.6 }, mode = "portal", fac = "A", cost = 5, twoway = false, flavors = { tbc = true }, title = "Take the Shattrath portal to Ironforge" },
    { from = { "Shattrath City", 57.0, 48.5 }, to = { "Darnassus", 40.9, 82.9 }, mode = "portal", fac = "A", cost = 5, twoway = false, flavors = { tbc = true }, title = "Take the Shattrath portal to Darnassus" },
    { from = { "Shattrath City", 57.0, 48.5 }, to = { "The Exodar", 25.0, 53.6 }, mode = "portal", fac = "A", cost = 5, twoway = false, flavors = { tbc = true }, title = "Take the Shattrath portal to The Exodar" },
    { from = { "Shattrath City", 57.0, 48.5 }, to = { "Orgrimmar", 39.7, 85.7 }, mode = "portal", fac = "H", cost = 5, twoway = false, flavors = { tbc = true }, title = "Take the Shattrath portal to Orgrimmar" },
    { from = { "Shattrath City", 57.0, 48.5 }, to = { "Undercity", 84.9, 16.4 }, mode = "portal", fac = "H", cost = 5, twoway = false, flavors = { tbc = true }, title = "Take the Shattrath portal to Undercity" },
    { from = { "Shattrath City", 57.0, 48.5 }, to = { "Thunder Bluff", 22.0, 16.9 }, mode = "portal", fac = "H", cost = 5, twoway = false, flavors = { tbc = true }, title = "Take the Shattrath portal to Thunder Bluff" },
    { from = { "Shattrath City", 57.0, 48.5 }, to = { "Silvermoon City", 58.1, 19.4 }, mode = "portal", fac = "H", cost = 5, twoway = false, flavors = { tbc = true }, title = "Take the Shattrath portal to Silvermoon" },
    { from = { "Shattrath City", 48.5, 42.0 }, to = { "Isle of Quel'Danas", 47.7, 30.6 }, mode = "portal", cost = 5, twoway = false, flavors = { tbc = true }, title = "Take the Shattrath portal to Isle of Quel'Danas" },
    -- Blasted Lands portal in capitals (TBC 2.4+ / for wrath onward retail differs)
    { from = { "Stormwind City", 49.6, 86.9 }, to = { "Blasted Lands", 55.4, 54.0 }, mode = "portal", fac = "A", cost = 5, twoway = false, flavors = { tbc = true }, title = "Take the Mage Quarter portal to Blasted Lands" },
    { from = { "Orgrimmar", 39.7, 85.7 }, to = { "Blasted Lands", 55.4, 54.0 }, mode = "portal", fac = "H", cost = 5, twoway = false, flavors = { tbc = true }, title = "Take the Valley of Spirits portal to Blasted Lands" },

    -- ===================== RETAIL (Cataclysm -> Midnight) =====================
    -- Zone given as a uiMapID string where the English name is ambiguous on this client (two Dalarans, two
    -- Shadowmoon Valleys); `name` is then the display name. Coordinates approximate (+-2%), see header.
    -- Stormwind Portal Room (Wizard's Sanctum, Mage Quarter), 8.1.5+
    { from = { "Stormwind City", 49.2, 87.2 }, to = { "Boralus", 70.0, 15.5 }, mode = "portal", fac = "A", cost = 6, flavors = { retail = true }, title = "Take the Stormwind Portal Room portal to Boralus" },
    { from = { "Stormwind City", 49.2, 87.2 }, to = { "Stormshield", 61.0, 37.0 }, mode = "portal", fac = "A", cost = 6, flavors = { retail = true }, title = "Take the Stormwind Portal Room portal to Stormshield (Ashran)" },
    { from = { "Stormwind City", 49.2, 87.2 }, to = { "627", 58.0, 43.0, name = "Dalaran" }, mode = "portal", fac = "A", cost = 6, flavors = { retail = true }, title = "Take the Stormwind Portal Room portal to Dalaran (Broken Isles)" },
    { from = { "Stormwind City", 49.2, 87.2 }, to = { "The Jade Forest", 45.7, 85.0 }, mode = "portal", fac = "A", cost = 6, flavors = { retail = true }, title = "Take the Stormwind Portal Room portal to Paw'don Village (Jade Forest)" },
    { from = { "Stormwind City", 49.2, 87.2 }, to = { "Tanaris", 64.8, 50.0 }, mode = "portal", fac = "A", cost = 6, flavors = { retail = true }, title = "Take the Stormwind Portal Room portal to the Caverns of Time" },
    { from = { "Stormwind City", 49.2, 87.2 }, to = { "Silithus", 41.5, 44.5 }, mode = "portal", fac = "A", cost = 6, flavors = { retail = true }, title = "Take the Stormwind Portal Room portal to Silithus" },
    { from = { "Stormwind City", 49.2, 87.2 }, to = { "Azsuna", 46.7, 41.4 }, mode = "portal", fac = "A", cost = 6, flavors = { retail = true }, title = "Take the Stormwind Portal Room portal to Azsuna" },
    { from = { "Stormwind City", 49.2, 87.2 }, to = { "Oribos", 47.0, 60.0 }, mode = "portal", fac = "A", cost = 6, flavors = { retail = true }, title = "Take the Stormwind Portal Room portal to Oribos" },
    { from = { "Stormwind City", 49.2, 87.2 }, to = { "Valdrakken", 59.66, 41.64 }, mode = "portal", fac = "A", cost = 6, flavors = { retail = true }, title = "Take portal between Stormwind and Valdrakken" },
    { from = { "Stormwind City", 49.2, 87.2 }, to = { "Dornogal", 48.0, 42.6 }, mode = "portal", fac = "A", cost = 6, flavors = { retail = true }, title = "Take the Stormwind Portal Room portal to Dornogal" },
    { from = { "Stormwind City", 49.2, 87.2 }, to = { "Ironforge", 27.0, 8.5 }, mode = "portal", fac = "A", cost = 6, flavors = { retail = true }, title = "Take the Stormwind Portal Room portal to Ironforge" },
    { from = { "Stormwind City", 49.2, 87.2 }, to = { "The Exodar", 48.0, 62.0 }, mode = "portal", fac = "A", cost = 6, flavors = { retail = true }, title = "Take the Stormwind Portal Room portal to the Exodar" },
    -- Stormwind: Eastern Earthshrine (Cataclysm zones) and the harbor
    { from = { "Stormwind City", 76.0, 18.5 }, to = { "Mount Hyjal", 62.7, 23.5 }, mode = "portal", fac = "A", cost = 6, flavors = R, title = "Take the Eastern Earthshrine portal to Mount Hyjal" },
    { from = { "Stormwind City", 76.0, 18.5 }, to = { "Kelp'thar Forest", 60.0, 34.0 }, mode = "portal", fac = "A", cost = 6, flavors = R, title = "Take the Eastern Earthshrine portal to Vashj'ir" },
    { from = { "Stormwind City", 76.0, 18.5 }, to = { "Deepholm", 49.0, 53.0 }, mode = "portal", fac = "A", cost = 6, flavors = R, title = "Take the Eastern Earthshrine portal to Deepholm" },
    { from = { "Stormwind City", 76.0, 18.5 }, to = { "Uldum", 54.5, 33.5 }, mode = "portal", fac = "A", cost = 6, flavors = R, title = "Take the Eastern Earthshrine portal to Uldum" },
    { from = { "Stormwind City", 76.0, 18.5 }, to = { "Twilight Highlands", 79.5, 78.0 }, mode = "portal", fac = "A", cost = 6, flavors = R, title = "Take the Eastern Earthshrine portal to Twilight Highlands" },
    { from = { "Stormwind City", 76.0, 18.5 }, to = { "Tol Barad Peninsula", 73.3, 60.0 }, mode = "portal", fac = "A", cost = 6, flavors = R, title = "Take the Eastern Earthshrine portal to Tol Barad" },
    { from = { "Stormwind City", 18.5, 25.5 }, to = { "Borean Tundra", 59.5, 69.0 }, mode = "boat", fac = "A", cost = 170, flavors = { wrath = true, cata = true, mop = true, wod = true, legion = true, bfa = true, sl = true, df = true, retail = true }, title = "Take the ship Stormwind Harbor <-> Valiance Keep (Borean Tundra)" },
    { from = { "Stormwind City", 22.5, 32.0 }, to = { "Teldrassil", 55.4, 93.5 }, mode = "boat", fac = "A", cost = 170, flavors = { cata = true, mop = true, wod = true, legion = true, bfa = true, sl = true, df = true, retail = true }, title = "Take the ship Stormwind Harbor <-> Rut'theran Village" },
    { from = { "Wetlands", 4.9, 57.0 }, to = { "Howling Fjord", 58.5, 62.0 }, mode = "boat", fac = "A", cost = 170, flavors = { wrath = true, cata = true, mop = true, wod = true, legion = true, bfa = true, sl = true, df = true, retail = true }, title = "Take the ship Menethil Harbor <-> Valgarde (Howling Fjord)" },
    -- Orgrimmar Portal Room (Gates of Orgrimmar), 8.1.5+
    { from = { "Orgrimmar", 57.6, 89.5 }, to = { "Zuldazar", 58.5, 59.5 }, mode = "portal", fac = "H", cost = 6, flavors = { retail = true }, title = "Take the Orgrimmar Portal Room portal to Dazar'alor" },
    { from = { "Orgrimmar", 57.6, 89.5 }, to = { "Warspear", 53.0, 38.0 }, mode = "portal", fac = "H", cost = 6, flavors = { retail = true }, title = "Take the Orgrimmar Portal Room portal to Warspear (Ashran)" },
    { from = { "Orgrimmar", 57.6, 89.5 }, to = { "627", 49.0, 48.0, name = "Dalaran" }, mode = "portal", fac = "H", cost = 6, flavors = { retail = true }, title = "Take the Orgrimmar Portal Room portal to Dalaran (Broken Isles)" },
    { from = { "Orgrimmar", 57.6, 89.5 }, to = { "The Jade Forest", 28.3, 15.5 }, mode = "portal", fac = "H", cost = 6, flavors = { retail = true }, title = "Take the Orgrimmar Portal Room portal to Honeydew Village (Jade Forest)" },
    { from = { "Orgrimmar", 57.6, 89.5 }, to = { "Tanaris", 64.8, 50.0 }, mode = "portal", fac = "H", cost = 6, flavors = { retail = true }, title = "Take the Orgrimmar Portal Room portal to the Caverns of Time" },
    { from = { "Orgrimmar", 57.6, 89.5 }, to = { "Silithus", 41.5, 44.5 }, mode = "portal", fac = "H", cost = 6, flavors = { retail = true }, title = "Take the Orgrimmar Portal Room portal to Silithus" },
    { from = { "Orgrimmar", 57.6, 89.5 }, to = { "Azsuna", 46.7, 41.4 }, mode = "portal", fac = "H", cost = 6, flavors = { retail = true }, title = "Take the Orgrimmar Portal Room portal to Azsuna" },
    { from = { "Orgrimmar", 57.6, 89.5 }, to = { "Oribos", 47.0, 60.0 }, mode = "portal", fac = "H", cost = 6, flavors = { retail = true }, title = "Take the Orgrimmar Portal Room portal to Oribos" },
    { from = { "Orgrimmar", 57.6, 89.5 }, to = { "Valdrakken", 56.58, 38.29 }, mode = "portal", fac = "H", cost = 6, flavors = { retail = true }, title = "Take portal between Orgrimmar and Valdrakken" },
    { from = { "Orgrimmar", 57.6, 89.5 }, to = { "Dornogal", 48.0, 42.6 }, mode = "portal", fac = "H", cost = 6, flavors = { retail = true }, title = "Take the Orgrimmar Portal Room portal to Dornogal" },
    { from = { "Orgrimmar", 57.6, 89.5 }, to = { "Thunder Bluff", 22.0, 17.0 }, mode = "portal", fac = "H", cost = 6, flavors = { retail = true }, title = "Take the Orgrimmar Portal Room portal to Thunder Bluff" },
    { from = { "Orgrimmar", 57.6, 89.5 }, to = { "Silvermoon City", 58.0, 19.5 }, mode = "portal", fac = "H", cost = 6, flavors = { retail = true }, title = "Take the Orgrimmar Portal Room portal to Silvermoon City" },
    -- Orgrimmar: Western Earthshrine (Cataclysm zones) and the zeppelin towers
    { from = { "Orgrimmar", 48.5, 37.5 }, to = { "Mount Hyjal", 62.7, 23.5 }, mode = "portal", fac = "H", cost = 6, flavors = R, title = "Take the Western Earthshrine portal to Mount Hyjal" },
    { from = { "Orgrimmar", 48.5, 37.5 }, to = { "Kelp'thar Forest", 60.0, 34.0 }, mode = "portal", fac = "H", cost = 6, flavors = R, title = "Take the Western Earthshrine portal to Vashj'ir" },
    { from = { "Orgrimmar", 48.5, 37.5 }, to = { "Deepholm", 49.0, 53.0 }, mode = "portal", fac = "H", cost = 6, flavors = R, title = "Take the Western Earthshrine portal to Deepholm" },
    { from = { "Orgrimmar", 48.5, 37.5 }, to = { "Uldum", 54.5, 33.5 }, mode = "portal", fac = "H", cost = 6, flavors = R, title = "Take the Western Earthshrine portal to Uldum" },
    { from = { "Orgrimmar", 48.5, 37.5 }, to = { "Twilight Highlands", 73.5, 52.5 }, mode = "portal", fac = "H", cost = 6, flavors = R, title = "Take the Western Earthshrine portal to Twilight Highlands" },
    { from = { "Orgrimmar", 48.5, 37.5 }, to = { "Tol Barad Peninsula", 59.5, 75.0 }, mode = "portal", fac = "H", cost = 6, flavors = R, title = "Take the Western Earthshrine portal to Tol Barad" },
    { from = { "Durotar", 51.0, 12.0 }, to = { "Borean Tundra", 41.5, 54.0 }, mode = "zeppelin", fac = "H", cost = 170, flavors = { wrath = true, cata = true, mop = true, wod = true, legion = true, bfa = true, sl = true, df = true, retail = true }, title = "Take the zeppelin Orgrimmar <-> Warsong Hold (Borean Tundra)" },
    { from = { "Tirisfal Glades", 60.9, 58.8 }, to = { "Howling Fjord", 78.5, 29.0 }, mode = "zeppelin", fac = "H", cost = 170, flavors = { wrath = true, cata = true, mop = true, wod = true, legion = true, bfa = true, sl = true, df = true, retail = true }, title = "Take the zeppelin Undercity <-> Vengeance Landing (Howling Fjord)" },
    { from = { "Durotar", 51.0, 12.0 }, to = { "Thunder Bluff", 22.0, 16.0 }, mode = "zeppelin", fac = "H", cost = 170, flavors = R, title = "Take the zeppelin Orgrimmar <-> Thunder Bluff" },
    -- Pandaria shrines (one-way back to the capitals); Legion Dalaran / Oribos / Valdrakken / Dornogal return portals are the two-way edges above
    { from = { "Vale of Eternal Blossoms", 62.5, 22.5 }, to = { "Orgrimmar", 57.6, 89.5 }, mode = "portal", fac = "H", cost = 6, twoway = false, flavors = { mop = true, wod = true, legion = true, bfa = true, sl = true, df = true, retail = true }, title = "Take the Shrine of Two Moons portal to Orgrimmar" },
    { from = { "Vale of Eternal Blossoms", 84.5, 62.0 }, to = { "Stormwind City", 49.2, 87.2 }, mode = "portal", fac = "A", cost = 6, twoway = false, flavors = { mop = true, wod = true, legion = true, bfa = true, sl = true, df = true, retail = true }, title = "Take the Shrine of Seven Stars portal to Stormwind" },
    -- Shadowlands: Oribos Ring of Transference portals to the four zones (two-way; the zones' return portals land in Oribos)
    { from = { "Oribos", 40.0, 40.0 }, to = { "Bastion", 49.5, 50.0 }, mode = "portal", cost = 8, flavors = { retail = true }, title = "Take the Oribos portal to Bastion" },
    { from = { "Oribos", 60.0, 40.0 }, to = { "Maldraxxus", 50.0, 50.0 }, mode = "portal", cost = 8, flavors = { retail = true }, title = "Take the Oribos portal to Maldraxxus" },
    { from = { "Oribos", 40.0, 60.0 }, to = { "Ardenweald", 50.0, 50.0 }, mode = "portal", cost = 8, flavors = { retail = true }, title = "Take the Oribos portal to Ardenweald" },
    { from = { "Oribos", 60.0, 60.0 }, to = { "Revendreth", 50.0, 50.0 }, mode = "portal", cost = 8, flavors = { retail = true }, title = "Take the Oribos portal to Revendreth" },
    -- Battle for Azeroth: Horde war-campaign boats Zuldazar harbor -> Kul Tiras footholds, Alliance Boralus harbor -> Zandalar footholds
    { from = { "Zuldazar", 58.0, 62.5 }, to = { "Tiragarde Sound", 61.5, 84.0 }, mode = "boat", fac = "H", cost = 60, flavors = { retail = true }, title = "Take the Zuldazar harbor boat to Plunder Harbor (Tiragarde Sound)" },
    { from = { "Zuldazar", 58.0, 62.5 }, to = { "Drustvar", 69.5, 63.5 }, mode = "boat", fac = "H", cost = 60, flavors = { retail = true }, title = "Take the Zuldazar harbor boat to Krazzlefrazz Outpost (Drustvar)" },
    { from = { "Zuldazar", 58.0, 62.5 }, to = { "Stormsong Valley", 35.5, 35.0 }, mode = "boat", fac = "H", cost = 60, flavors = { retail = true }, title = "Take the Zuldazar harbor boat to Warfang Hold (Stormsong Valley)" },
    { from = { "Boralus", 69.0, 22.0 }, to = { "Zuldazar", 43.5, 38.5 }, mode = "boat", fac = "A", cost = 60, flavors = { retail = true }, title = "Take the Boralus harbor boat to Xibala (Zuldazar)" },
    { from = { "Boralus", 69.0, 22.0 }, to = { "Nazmir", 45.5, 82.0 }, mode = "boat", fac = "A", cost = 60, flavors = { retail = true }, title = "Take the Boralus harbor boat to Redfield's Watch (Nazmir)" },
    { from = { "Boralus", 69.0, 22.0 }, to = { "Vol'dun", 56.5, 81.0 }, mode = "boat", fac = "A", cost = 60, flavors = { retail = true }, title = "Take the Boralus harbor boat to Port of Zem'lan (Vol'dun)" },
    -- ===================== LEGION CLASS ORDER HALLS (Retail) =====================
    -- Bidirectional connections between Dalaran (Broken Isles, 627) and the 12 class order halls
    { from = { "627", 70.0, 49.4, name = "Dalaran" }, to = { "695", 55.0, 40.0, name = "Skyhold" }, mode = "portal", cost = 8, flavors = { retail = true }, title = "Leap between Dalaran and Skyhold" },
    { from = { "627", 48.0, 42.0, name = "Dalaran" }, to = { "702", 50.0, 50.0, name = "Netherlight Temple" }, mode = "portal", cost = 6, flavors = { retail = true }, title = "Enter the portal between Dalaran and Netherlight Temple" },
    { from = { "627", 41.5, 37.0, name = "Dalaran" }, to = { "717", 78.0, 52.0, name = "Dreadscar Rift" }, mode = "portal", cost = 6, flavors = { retail = true }, title = "Enter the portal between Dalaran and Dreadscar Rift" },
    { from = { "717", 50.0, 50.0, name = "Dreadscar Rift" }, to = { "718", 50.0, 50.0, name = "Dreadscar Rift" }, mode = "walk", cost = 5, flavors = { retail = true }, title = "Move between Dreadscar Rift levels" },
    { from = { "627", 73.0, 43.0, name = "Dalaran" }, to = { "726", 30.0, 30.0, name = "The Maelstrom" }, mode = "portal", cost = 6, flavors = { retail = true }, title = "Enter the portal between Dalaran and The Maelstrom" },
    { from = { "627", 56.0, 46.0, name = "Dalaran" }, to = { "734", 50.0, 50.0, name = "Hall of the Guardian" }, mode = "portal", cost = 6, flavors = { retail = true }, title = "Teleport between Dalaran and Hall of the Guardian" },
    { from = { "734", 50.0, 50.0, name = "Hall of the Guardian" }, to = { "735", 50.0, 50.0, name = "Hall of the Guardian" }, mode = "walk", cost = 5, flavors = { retail = true }, title = "Move between Hall of the Guardian floors" },
    { from = { "627", 71.5, 43.5, name = "Dalaran" }, to = { "739", 50.0, 50.0, name = "Trueshot Lodge" }, mode = "flight", cost = 25, flavors = { retail = true }, title = "Fly the Great Eagle between Dalaran and Trueshot Lodge" },
    { from = { "627", 50.0, 50.0, name = "Dalaran" }, to = { "747", 45.0, 45.0, name = "The Dreamgrove" }, mode = "portal", cost = 8, flavors = { retail = true }, title = "Dreamwalk between Dalaran and The Dreamgrove" },
    { from = { "747", 45.0, 45.0, name = "The Dreamgrove" }, to = { "715", 50.0, 50.0, name = "Emerald Dreamway" }, mode = "portal", cost = 5, flavors = { retail = true }, title = "Pass between Emerald Dreamway and The Dreamgrove" },
    { from = { "627", 71.0, 44.0, name = "Dalaran" }, to = { "720", 60.0, 50.0, name = "The Fel Hammer" }, mode = "portal", cost = 8, flavors = { retail = true }, title = "Glide/Portal between Dalaran and The Fel Hammer" },
    { from = { "720", 50.0, 50.0, name = "The Fel Hammer" }, to = { "721", 50.0, 50.0, name = "The Fel Hammer" }, mode = "walk", cost = 5, flavors = { retail = true }, title = "Move between The Fel Hammer decks" },
    { from = { "627", 70.0, 45.0, name = "Dalaran" }, to = { "647", 30.0, 30.0, name = "Acherus: The Ebon Hold" }, mode = "portal", cost = 8, flavors = { retail = true }, title = "Death Gate / Fly between Dalaran and Acherus" },
    { from = { "647", 50.0, 50.0, name = "Acherus: The Ebon Hold" }, to = { "648", 50.0, 50.0, name = "Acherus: The Ebon Hold" }, mode = "walk", cost = 5, flavors = { retail = true }, title = "Move between Acherus levels" },
    { from = { "627", 60.0, 50.0, name = "Dalaran" }, to = { "709", 50.0, 50.0, name = "The Wandering Isle" }, mode = "portal", cost = 8, flavors = { retail = true }, title = "Zen Pilgrimage / Portal between Dalaran and The Wandering Isle" },
    { from = { "627", 50.0, 35.0, name = "Dalaran" }, to = { "628", 45.0, 45.0, name = "Dalaran Underbelly" }, mode = "walk", cost = 8, flavors = { retail = true }, title = "Enter the Underbelly secret entrance <-> Dalaran" },
    { from = { "627", 48.0, 42.0, name = "Dalaran" }, to = { "24", 50.0, 50.0, name = "Light's Hope Chapel" }, mode = "portal", cost = 6, flavors = { retail = true }, title = "Enter the portal between Dalaran and Light's Hope Chapel" },
    -- ===================== SHADOWLANDS EXTENDED (Retail) =====================
    { from = { "Oribos", 50.0, 50.0 }, to = { "1543", 45.0, 41.0, name = "The Maw" }, mode = "portal", cost = 12, flavors = { retail = true }, title = "Jump into the Maw / Waystone to Oribos" },
    { from = { "1543", 25.0, 35.0, name = "The Maw" }, to = { "1911", 50.0, 50.0, name = "Torghast" }, mode = "portal", cost = 8, flavors = { retail = true }, title = "Enter Torghast, Tower of the Damned" },
    { from = { "1543", 62.0, 68.0, name = "The Maw" }, to = { "1961", 38.0, 78.0, name = "Korthia" }, mode = "portal", cost = 8, flavors = { retail = true }, title = "Travel between The Maw and Korthia" },
    { from = { "1970", 34.8, 65.0, name = "Zereth Mortis" }, to = { "Oribos", 38.9, 70.0 }, mode = "portal", cost = 8, twoway = false, flavors = { retail = true }, title = "Take the Zereth Mortis portal back to Oribos" },
    -- ===================== DRAGONFLIGHT EXTENDED (Retail) =====================
    { from = { "Valdrakken", 53.0, 55.0 }, to = { "2133", 56.0, 56.0, name = "Zaralek Cavern" }, mode = "portal", cost = 10, flavors = { retail = true }, title = "Fly/Portal between Valdrakken and Zaralek Cavern (Loamm)" },
    { from = { "Valdrakken", 62.5, 57.5 }, to = { "2200", 50.0, 60.0, name = "Emerald Dream" }, mode = "portal", cost = 8, flavors = { retail = true }, title = "Enter the portal between Valdrakken and Emerald Dream" },
    -- ===================== BATTLE FOR AZEROTH EXTENDED (Retail) =====================
    { from = { "Nazjatar", 38.0, 55.0 }, to = { "Boralus", 70.0, 15.5 }, mode = "portal", fac = "A", cost = 8, twoway = false, flavors = { retail = true }, title = "Take the Mezzamere portal to Boralus" },
    { from = { "Nazjatar", 50.0, 52.0 }, to = { "Zuldazar", 58.5, 59.5 }, mode = "portal", fac = "H", cost = 8, twoway = false, flavors = { retail = true }, title = "Take the Newhome portal to Dazar'alor" },
    { from = { "Boralus", 67.4, 15.3 }, to = { "1462", 73.0, 37.0, name = "Mechagon" }, mode = "flight", fac = "A", cost = 45, flavors = { retail = true }, title = "Fly between Boralus and Rustbolt (Mechagon)" },
    { from = { "Zuldazar", 58.0, 62.5 }, to = { "1462", 73.0, 37.0, name = "Mechagon" }, mode = "flight", fac = "H", cost = 45, flavors = { retail = true }, title = "Fly between Port of Zandalar and Rustbolt (Mechagon)" },
    -- ===================== PANDARIA EXTENDED (Mists+) =====================
    { from = { "Isle of Thunder", 64.0, 73.0 }, to = { "Townlong Steppes", 50.0, 70.0 }, mode = "portal", fac = "H", cost = 8, twoway = false, flavors = { mop = true, wod = true, legion = true, bfa = true, sl = true, df = true, retail = true }, title = "Take the Sunreaver portal to Townlong Steppes" },
    { from = { "Isle of Thunder", 64.0, 73.0 }, to = { "Townlong Steppes", 50.0, 70.0 }, mode = "portal", fac = "A", cost = 8, twoway = false, flavors = { mop = true, wod = true, legion = true, bfa = true, sl = true, df = true, retail = true }, title = "Take the Kirin Tor portal to Townlong Steppes" },
    -- ===================== WORLD EVENTS: DARKMOON FAIRE =====================
    { from = { "Elwynn Forest", 41.8, 69.5 }, to = { "407", 52.0, 89.0, name = "Darkmoon Island" }, mode = "portal", fac = "A", cost = 8, title = "Enter the Darkmoon Faire portal (Elwynn Forest <-> Darkmoon Island)" },
    { from = { "Mulgore", 36.5, 36.0 }, to = { "407", 52.0, 89.0, name = "Darkmoon Island" }, mode = "portal", fac = "H", cost = 8, title = "Enter the Darkmoon Faire portal (Mulgore <-> Darkmoon Island)" },
    -- ===================== THE WAR WITHIN EXTENDED (Retail) =====================
    { from = { "Siren Isle", 69.3, 48.0 }, to = { "Isle of Dorn", 55.40, 33.86 }, mode = "boat", cost = 60, twoway = false, flavors = { retail = true }, title = "Sail Skaggit's airship from Siren Isle to Isle of Dorn" },
    { from = { "Undermine", 24.10, 51.17 }, to = { "The Ringing Deeps", 72.95, 73.20 }, mode = "portal", cost = 60, twoway = false, flavors = { retail = true }, title = "Take the Rocket Drill from Undermine to The Ringing Deeps" },
}
