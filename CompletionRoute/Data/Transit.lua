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
    { from = { "Stormwind City", 49.2, 87.2 }, to = { "Valdrakken", 59.5, 41.0 }, mode = "portal", fac = "A", cost = 6, flavors = { retail = true }, title = "Take the Stormwind Portal Room portal to Valdrakken" },
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
    { from = { "Orgrimmar", 57.6, 89.5 }, to = { "Valdrakken", 59.5, 41.0 }, mode = "portal", fac = "H", cost = 6, flavors = { retail = true }, title = "Take the Orgrimmar Portal Room portal to Valdrakken" },
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
}
