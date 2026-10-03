-- CompletionRoute :: Data/Roads_ek.lua
-- Predetermined paths through Eastern Kingdoms zones: the road network the router follows instead of
-- cutting straight lines across cliffs and rivers. Entries are polylines in map percentages on the
-- named zone map; the LAST point of one and the FIRST point of another are snapped together within
-- 40 yd, which is how a road continues across a zone border (the zone entrance).
--   { zone = "Elwynn Forest", name = "...", pts = { {x, y}, ... }, flavors = {...}, fac = "A"|"H", factor = 1.0 }
-- SOURCES: "approx" entries were authored from the zone maps and are within a few percent - good enough to
-- pick the right road and gate; an exact trace recorded in game (/cr road) always wins because it is costed
-- slightly cheaper. Replace approx entries with traced ones via tools/roads_from_trace.py, or trace a zone
-- map image with tools/trace_roads.py.
local ADDON, NS = ...
NS.RoadData = NS.RoadData or {}
local R = NS.RoadData
local function add(t) R[#R + 1] = t end

-- ===================== ELWYNN FOREST (approx) =====================
-- Stormwind gate -> Goldshire -> Crystal Lake fork -> Eastvale Logging Camp -> Redridge border (Three Corners road)
add{ zone = "Elwynn Forest", name = "Stormwind gate - Goldshire", pts = { {32.4, 49.3}, {35.5, 53.5}, {39.0, 59.5}, {42.1, 65.9} } }
add{ zone = "Elwynn Forest", name = "Goldshire - Eastvale - Redridge", pts = { {42.1, 65.9}, {48.0, 66.0}, {53.5, 64.5}, {60.0, 62.5}, {66.0, 60.5}, {72.0, 62.5}, {78.0, 65.0}, {84.0, 67.5}, {90.0, 69.0}, {95.5, 69.0} } }
add{ zone = "Elwynn Forest", name = "Goldshire - Westfall", pts = { {42.1, 65.9}, {40.5, 71.0}, {39.5, 78.0}, {37.5, 86.0}, {33.5, 92.0}, {30.5, 97.0} } }
add{ zone = "Elwynn Forest", name = "Goldshire - Northshire", pts = { {42.1, 65.9}, {45.0, 60.0}, {47.0, 55.0}, {48.5, 48.0}, {48.7, 43.5} } }
add{ zone = "Elwynn Forest", name = "Goldshire - Duskwood", pts = { {42.1, 65.9}, {45.5, 72.0}, {48.0, 79.0}, {49.5, 87.0}, {49.5, 96.0} } }
-- ===================== REDRIDGE MOUNTAINS (approx) =====================
add{ zone = "Redridge Mountains", name = "Elwynn border - Three Corners - Lakeshire", pts = { {4.0, 69.0}, {10.0, 68.5}, {15.5, 67.5}, {19.5, 62.0}, {22.5, 55.0}, {26.5, 50.0}, {30.6, 48.0} } }
add{ zone = "Redridge Mountains", name = "Three Corners - Duskwood", pts = { {15.5, 67.5}, {12.0, 74.0}, {9.0, 81.0}, {7.0, 88.0} } }
add{ zone = "Redridge Mountains", name = "Lakeshire - Burning Steppes pass", pts = { {30.6, 48.0}, {29.0, 42.0}, {26.5, 35.0}, {24.0, 28.0}, {21.0, 22.0}, {18.5, 16.0}, {17.0, 10.0} } }
-- ===================== BURNING STEPPES (approx) =====================
add{ zone = "Burning Steppes", name = "Redridge pass - Morgan's Vigil", pts = { {83.5, 97.0}, {84.5, 90.0}, {85.0, 82.0}, {84.5, 74.0}, {84.0, 68.5} }, fac = "A" }
add{ zone = "Burning Steppes", name = "Redridge pass - central road", pts = { {83.5, 97.0}, {80.0, 88.0}, {74.0, 78.0}, {66.0, 70.0}, {58.0, 64.0}, {50.0, 60.0} } }
-- ===================== WESTFALL (approx) =====================
add{ zone = "Westfall", name = "Elwynn border - Sentinel Hill", pts = { {69.0, 18.0}, {64.0, 28.0}, {59.0, 38.0}, {56.5, 47.5} } }
add{ zone = "Westfall", name = "Sentinel Hill - Duskwood", pts = { {56.5, 47.5}, {61.0, 54.0}, {67.0, 60.0}, {73.5, 65.0}, {80.0, 67.0}, {86.0, 67.5} } }
add{ zone = "Westfall", name = "Sentinel Hill - Moonbrook - Deadmines", pts = { {56.5, 47.5}, {52.0, 56.0}, {46.0, 64.0}, {42.5, 71.0}, {42.6, 72.0} } }
-- ===================== DUSKWOOD (approx) =====================
add{ zone = "Duskwood", name = "Elwynn border - Darkshire road", pts = { {17.0, 3.0}, {20.0, 12.0}, {25.0, 24.0}, {33.0, 33.0}, {45.0, 34.0}, {58.0, 38.0}, {66.0, 44.0}, {73.8, 44.3} } }
add{ zone = "Duskwood", name = "Westfall border - Sentinel road", pts = { {5.0, 33.0}, {12.0, 33.0}, {20.0, 33.0}, {25.0, 24.0} } }
add{ zone = "Duskwood", name = "Darkshire - Redridge", pts = { {73.8, 44.3}, {78.0, 38.0}, {83.0, 30.0}, {87.0, 22.0}, {90.0, 15.0} } }
add{ zone = "Duskwood", name = "Darkshire - Deadwind Pass", pts = { {73.8, 44.3}, {80.0, 50.0}, {88.0, 56.0}, {95.0, 58.0} } }
-- ===================== DUN MOROGH / LOCH MODAN (approx) =====================
add{ zone = "Dun Morogh", name = "Ironforge - Kharanos - Coldridge", pts = { {52.0, 35.0}, {52.5, 42.0}, {53.5, 47.0}, {54.5, 51.0}, {47.0, 52.5}, {41.0, 55.5}, {36.0, 60.0}, {30.0, 69.0} } }
add{ zone = "Dun Morogh", name = "Kharanos - Loch Modan pass", pts = { {54.5, 51.0}, {62.0, 52.0}, {70.0, 51.5}, {78.0, 50.0}, {86.0, 50.5}, {92.0, 52.0}, {97.0, 54.0} } }
add{ zone = "Loch Modan", name = "Dun Morogh pass - Thelsamar", pts = { {1.5, 47.0}, {8.0, 47.5}, {15.0, 49.0}, {22.0, 52.0}, {28.0, 58.0}, {34.0, 49.0} } }
add{ zone = "Loch Modan", name = "Thelsamar - Wetlands", pts = { {34.0, 49.0}, {30.0, 40.0}, {25.0, 30.0}, {22.0, 22.0}, {20.0, 14.0}, {19.0, 7.0} } }
add{ zone = "Loch Modan", name = "Thelsamar - Badlands", pts = { {34.0, 49.0}, {42.0, 52.0}, {50.0, 55.0}, {56.0, 62.0}, {62.0, 70.0}, {70.0, 80.0} } }
add{ zone = "Wetlands", name = "Loch Modan pass - Menethil", pts = { {47.0, 86.0}, {43.0, 78.0}, {38.0, 70.0}, {30.0, 60.0}, {22.0, 57.0}, {14.0, 57.5}, {9.5, 58.0} } }
add{ zone = "Wetlands", name = "Menethil - Arathi (Thandol Span)", pts = { {30.0, 60.0}, {38.0, 52.0}, {45.0, 44.0}, {50.0, 35.0}, {51.5, 24.0}, {50.5, 12.0}, {49.5, 4.0} } }
-- ===================== TIRISFAL / SILVERPINE (approx, Horde) =====================
add{ zone = "Tirisfal Glades", name = "Deathknell - Brill - Undercity", pts = { {31.0, 66.0}, {38.0, 63.0}, {46.0, 59.0}, {53.0, 57.0}, {60.0, 52.0}, {61.0, 62.0}, {61.5, 66.5} } }
add{ zone = "Tirisfal Glades", name = "Brill - Silverpine", pts = { {60.0, 52.0}, {58.0, 60.0}, {56.0, 68.0}, {55.0, 76.0}, {54.0, 84.0}, {53.5, 92.0} } }
add{ zone = "Tirisfal Glades", name = "Brill - Scarlet Monastery road", pts = { {60.0, 52.0}, {68.0, 48.0}, {76.0, 44.0}, {83.0, 38.0} } }
add{ zone = "Silverpine Forest", name = "Tirisfal border - The Sepulcher", pts = { {53.0, 5.0}, {51.0, 14.0}, {48.0, 24.0}, {46.0, 33.0}, {44.5, 41.5} } }
add{ zone = "Silverpine Forest", name = "The Sepulcher - Hillsbrad", pts = { {44.5, 41.5}, {48.0, 50.0}, {54.0, 58.0}, {60.0, 64.0}, {66.0, 68.0}, {70.0, 72.0}, {72.0, 78.0} } }
