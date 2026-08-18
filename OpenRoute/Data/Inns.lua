-- OpenRoute :: Data/Inns.lua
-- Seed list of innkeeper locations, keyed by the subzone name that GetBindLocation() returns.
-- Used only until the addon has *learned* the character's real hearth spot (recorded when you hearth or bind).
-- { zone = "uiMap name", x, y }  (map percentages)
local ADDON, NS = ...
NS.InnData = {
    -- Alliance
    ["Northshire Abbey"] = { "Elwynn Forest", 48.9, 41.6 }, ["Northshire Valley"] = { "Elwynn Forest", 48.9, 41.6 },
    ["Goldshire"] = { "Elwynn Forest", 43.7, 65.8 }, ["Stormwind City"] = { "Stormwind City", 52.6, 65.7 }, ["Trade District"] = { "Stormwind City", 52.6, 65.7 },
    ["Sentinel Hill"] = { "Westfall", 52.6, 53.6 }, ["Lakeshire"] = { "Redridge Mountains", 26.7, 44.4 }, ["Darkshire"] = { "Duskwood", 73.9, 44.4 },
    ["Kharanos"] = { "Dun Morogh", 47.0, 52.4 }, ["Ironforge"] = { "Ironforge", 18.2, 51.7 }, ["The Commons"] = { "Ironforge", 18.2, 51.7 },
    ["Thelsamar"] = { "Loch Modan", 35.3, 48.6 }, ["Menethil Harbor"] = { "Wetlands", 10.4, 60.9 }, ["Southshore"] = { "Hillsbrad Foothills", 51.4, 58.8 },
    ["Refuge Pointe"] = { "Arathi Highlands", 45.9, 47.3 }, ["Aerie Peak"] = { "The Hinterlands", 14.4, 41.7 },
    ["Dolanaar"] = { "Teldrassil", 55.6, 59.8 }, ["Darnassus"] = { "Darnassus", 67.9, 15.9 }, ["Craftsmen's Terrace"] = { "Darnassus", 67.9, 15.9 },
    ["Auberdine"] = { "Darkshore", 37.7, 41.5 }, ["Astranaar"] = { "Ashenvale", 34.9, 48.9 }, ["Theramore Isle"] = { "Dustwallow Marsh", 68.4, 47.6 },
    ["Nijel's Point"] = { "Desolace", 66.4, 8.2 }, ["Feathermoon Stronghold"] = { "Feralas", 30.5, 44.9 }, ["Talrendis Point"] = { "Azshara", 12.0, 78.0 },
    ["Azure Watch"] = { "Azuremyst Isle", 48.9, 51.7 }, ["Blood Watch"] = { "Bloodmyst Isle", 55.9, 61.5 }, ["The Exodar"] = { "The Exodar", 47.5, 61.0 },
    ["Honor Hold"] = { "Hellfire Peninsula", 56.5, 64.4 }, ["Telredor"] = { "Zangarmarsh", 68.5, 51.7 }, ["Allerian Stronghold"] = { "Terokkar Forest", 56.4, 54.5 },
    ["Telaar"] = { "Nagrand", 54.3, 74.9 }, ["Sylvanaar"] = { "Blade's Edge Mountains", 36.7, 65.4 }, ["Wildhammer Stronghold"] = { "Shadowmoon Valley", 37.6, 57.5 },
    -- Horde
    ["Valley of Trials"] = { "Durotar", 43.2, 68.6 }, ["Razor Hill"] = { "Durotar", 52.5, 41.9 }, ["Orgrimmar"] = { "Orgrimmar", 53.7, 74.9 }, ["Valley of Strength"] = { "Orgrimmar", 53.7, 74.9 },
    ["Sen'jin Village"] = { "Durotar", 55.6, 74.6 }, ["The Crossroads"] = { "The Barrens", 51.5, 30.3 }, ["Camp Taurajo"] = { "The Barrens", 44.5, 59.1 },
    ["Ratchet"] = { "The Barrens", 62.6, 37.4 }, ["Bloodhoof Village"] = { "Mulgore", 47.4, 59.7 }, ["Camp Narache"] = { "Mulgore", 45.0, 76.5 },
    ["Thunder Bluff"] = { "Thunder Bluff", 45.4, 64.0 }, ["Sun Rock Retreat"] = { "Stonetalon Mountains", 47.4, 63.6 }, ["Splintertree Post"] = { "Ashenvale", 73.4, 60.9 },
    ["Shadowprey Village"] = { "Desolace", 25.7, 71.0 }, ["Freewind Post"] = { "Thousand Needles", 45.7, 51.5 }, ["Camp Mojache"] = { "Feralas", 75.6, 43.7 },
    ["Brackenwall Village"] = { "Dustwallow Marsh", 35.9, 30.6 }, ["Deathknell"] = { "Tirisfal Glades", 30.9, 65.9 }, ["Brill"] = { "Tirisfal Glades", 61.5, 52.3 },
    ["Undercity"] = { "Undercity", 67.7, 38.5 }, ["The Trade Quarter"] = { "Undercity", 67.7, 38.5 }, ["The Sepulcher"] = { "Silverpine Forest", 43.5, 41.1 },
    ["Tarren Mill"] = { "Hillsbrad Foothills", 62.4, 20.4 }, ["Hammerfall"] = { "Arathi Highlands", 73.5, 41.9 }, ["Kargath"] = { "Badlands", 4.0, 45.0 },
    ["Grom'gol Base Camp"] = { "Stranglethorn Vale", 32.0, 47.9 }, ["Sunstrider Isle"] = { "Eversong Woods", 38.7, 20.9 }, ["Falconwing Square"] = { "Eversong Woods", 48.5, 47.1 },
    ["Silvermoon City"] = { "Silvermoon City", 79.9, 61.6 }, ["Tranquillien"] = { "Ghostlands", 46.9, 30.4 },
    ["Thrallmar"] = { "Hellfire Peninsula", 55.5, 36.4 }, ["Zabra'jin"] = { "Zangarmarsh", 33.5, 50.7 }, ["Stonebreaker Hold"] = { "Terokkar Forest", 50.6, 44.5 },
    ["Garadar"] = { "Nagrand", 56.6, 37.4 }, ["Thunderlord Stronghold"] = { "Blade's Edge Mountains", 50.9, 57.9 }, ["Shadowmoon Village"] = { "Shadowmoon Valley", 30.5, 27.5 },
    -- Neutral
    ["Booty Bay"] = { "Stranglethorn Vale", 27.0, 77.3 }, ["Gadgetzan"] = { "Tanaris", 51.9, 27.5 }, ["Everlook"] = { "Winterspring", 60.6, 50.4 },
    ["Light's Hope Chapel"] = { "Eastern Plaguelands", 81.6, 59.5 }, ["Marshal's Refuge"] = { "Un'Goro Crater", 44.4, 8.4 }, ["Cenarion Hold"] = { "Silithus", 51.9, 40.4 },
    ["Nighthaven"] = { "Moonglade", 51.8, 45.0 }, ["Shattrath City"] = { "Shattrath City", 55.5, 42.7 }, ["Lower City"] = { "Shattrath City", 55.5, 42.7 },
    ["Cenarion Refuge"] = { "Zangarmarsh", 78.5, 62.8 }, ["Area 52"] = { "Netherstorm", 32.5, 64.6 }, ["Altar of Sha'tar"] = { "Shadowmoon Valley", 62.7, 30.2 },
    ["Sanctum of the Stars"] = { "Shadowmoon Valley", 56.4, 59.4 }, ["Evergrove"] = { "Blade's Edge Mountains", 61.6, 39.0 }, ["Toshley's Station"] = { "Blade's Edge Mountains", 61.4, 68.6 },
    ["Mudsprocket"] = { "Dustwallow Marsh", 42.5, 72.7 },
}
