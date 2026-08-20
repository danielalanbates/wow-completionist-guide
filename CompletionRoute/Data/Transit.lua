-- CompletionRoute :: Data/Transit.lua
-- Hand-authored transit edges: boats, zeppelins, trams, portals, orbs.  Facts about the game world.
-- Each entry: { from = {zone, x, y}, to = {zone, x, y}, mode, fac = "A"|"H"|nil, cost = seconds (avg wait + ride),
--              flavors = {era=true, tbc=true, ...} (nil = all), title = "..." , twoway = true (default) }
-- Coordinates are map percentages (0-100) on the named zone map.  Zone names are English uiMap names.
-- NOTE: some coordinates are approximate (±2%). Walking cost is derived from them; a small error is harmless.
-- Contributions welcome — keep this list factual and flavour-tagged.
local ADDON, NS = ...
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
}
