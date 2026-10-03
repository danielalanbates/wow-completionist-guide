-- CompletionRoute :: Data/Roads_kalimdor.lua  (see Roads_ek.lua for the format and the "approx" caveat)
local ADDON, NS = ...
NS.RoadData = NS.RoadData or {}
local R = NS.RoadData
local function add(t) R[#R + 1] = t end
-- ===================== DUROTAR / BARRENS (approx, Horde) =====================
add{ zone = "Durotar", name = "Valley of Trials - Razor Hill - Orgrimmar", pts = { {43.0, 68.0}, {47.0, 62.0}, {51.0, 55.0}, {52.5, 43.5}, {50.0, 36.0}, {47.0, 25.0}, {45.5, 14.0}, {46.0, 11.0} } }
add{ zone = "Durotar", name = "Razor Hill - Barrens", pts = { {52.5, 43.5}, {46.0, 45.0}, {40.0, 46.0}, {36.0, 47.0} } }
add{ zone = "The Barrens", name = "Durotar border - Crossroads", pts = { {66.0, 30.0}, {61.0, 30.0}, {56.0, 30.0}, {52.0, 30.3} } }
add{ zone = "The Barrens", name = "Crossroads - Ratchet", pts = { {52.0, 30.3}, {56.0, 33.0}, {60.0, 36.0}, {63.0, 37.5} } }
add{ zone = "The Barrens", name = "Crossroads - Camp Taurajo - Thousand Needles", pts = { {52.0, 30.3}, {51.0, 38.0}, {49.0, 46.0}, {46.0, 54.0}, {44.5, 59.0}, {45.0, 66.0}, {46.5, 75.0}, {47.0, 84.0}, {45.5, 92.0} } }
add{ zone = "The Barrens", name = "Crossroads - Ashenvale", pts = { {52.0, 30.3}, {51.0, 22.0}, {49.0, 14.0}, {47.0, 7.0}, {45.0, 2.0} } }
add{ zone = "The Barrens", name = "Crossroads - Stonetalon", pts = { {52.0, 30.3}, {47.0, 28.0}, {42.0, 27.0}, {38.0, 26.0}, {34.0, 24.0} } }
-- ===================== MULGORE (approx, Horde) =====================
add{ zone = "Mulgore", name = "Camp Narache - Bloodhoof - Thunder Bluff", pts = { {44.0, 76.0}, {45.5, 68.0}, {47.5, 60.5}, {46.0, 52.0}, {44.0, 44.0}, {41.0, 37.0}, {39.0, 30.0} } }
add{ zone = "Mulgore", name = "Bloodhoof - Barrens", pts = { {47.5, 60.5}, {54.0, 55.0}, {60.0, 49.0}, {66.0, 45.0}, {71.0, 40.0} } }
-- ===================== TELDRASSIL / DARKSHORE (approx, Alliance) =====================
add{ zone = "Teldrassil", name = "Shadowglen - Dolanaar - Darnassus", pts = { {58.0, 43.0}, {56.5, 50.0}, {55.5, 57.0}, {52.0, 58.0}, {46.0, 56.0}, {40.0, 52.0}, {36.0, 49.0} } }
add{ zone = "Teldrassil", name = "Dolanaar - Rut'theran", pts = { {55.5, 57.0}, {55.0, 65.0}, {54.5, 74.0}, {55.0, 83.0}, {55.9, 89.6} } }
add{ zone = "Darkshore", name = "Auberdine - Ashenvale road", pts = { {36.5, 45.5}, {40.0, 50.0}, {43.0, 58.0}, {44.0, 66.0}, {43.0, 74.0}, {42.0, 82.0}, {44.0, 90.0}, {46.0, 97.0} } }
add{ zone = "Ashenvale", name = "Darkshore border - Astranaar", pts = { {20.0, 8.0}, {23.0, 16.0}, {26.0, 25.0}, {30.0, 34.0}, {34.5, 49.0} } }
add{ zone = "Ashenvale", name = "Astranaar - Splintertree - Barrens", pts = { {34.5, 49.0}, {42.0, 52.0}, {50.0, 57.0}, {58.0, 62.0}, {66.0, 64.0}, {73.0, 61.0}, {78.0, 58.0}, {85.0, 62.0}, {90.0, 66.0} } }
add{ zone = "Ashenvale", name = "Astranaar - Stonetalon", pts = { {34.5, 49.0}, {32.0, 58.0}, {30.0, 67.0}, {28.0, 76.0} } }
