-- CompletionRoute :: tools/test_doors.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- Offline tests of the shipped Retail instance doors (Data/Doors_retail.lua, tools/gen_doors.py) as the router uses them
-- (Core/Instances.lua I.Entrance, Routing/Router.lua EntranceFor, Routing/CostModel.lua zone points), against stubs:
--   * the data: every door is on another continent than its instance, journal pins dominate, twins copy a named door
--   * a step inside Blackfathom Deeps with a point, and one with only the zone, both route from Ashenvale (the 2026-11-26
--     Retail vplayer had them as no_route: no live journal offline, and zone-only steps took the map centre inside)
--   * a phase copy (Legion's Icecrown Citadel 698) uses the door of the Wrath uiMap of the same name
--   * a pocket map with no Blizzard door (Brawl'gar Arena) gets none: no guessed point
--   * the live journal's pin is matched by journalInstanceID, not the first pin on the parent map
-- Run: luajit tools/test_doors.lua   (from repo root)
package.path = "./?.lua;" .. package.path
local passed, failed = 0, 0
local function t(name, cond, detail)
    if cond then passed = passed + 1 print("ok   " .. name)
    else failed = failed + 1 print("FAIL " .. name .. (detail and (" :: " .. tostring(detail)) or "")) end
end

local MAPS_R = dofile("tools/maps_retail.lua")
local D = {}
assert(loadfile("CompletionRoute/Data/Doors_retail.lua"))("CompletionRoute", D)
local doors = D.DoorData and D.DoorData.retail
t("data loads", type(doors) == "table")
local n, journal, bad = 0, 0, {}
for uid, d in pairs(doors or {}) do
    n = n + 1
    if d[5] == "journal" then journal = journal + 1 end
    local m = MAPS_R[uid]
    if not m or not (m[8] == 4 or m[8] == 5 or m[8] == 6) then bad[#bad + 1] = uid .. " not an instance uiMap"
    elseif d[1] == m[2] then bad[#bad + 1] = uid .. " door on its own continent" end
end
t("at least 600 doors", n >= 600, n)
t("journal pins are most of them", journal * 2 > n, journal .. "/" .. n)
t("every door leaves its instance's continent", #bad == 0, bad[1])
t("Blackfathom Deeps (221) door is in Kalimdor", doors[221] and doors[221][1] == 1 and doors[221][4] == 227)
t("Legion Icecrown Citadel (698) uses the Wrath door", doors[698] and doors[698][5] == "twin" and doors[186] and doors[698][2] == doors[186][2])
t("Uldir (1148) pin is matched by Uldir's journal id, not the world-boss container's", doors[1148] and doors[1148][4] == 1031, doors[1148] and doors[1148][4])
t("Brawl'gar Arena (503) has no guessed door", doors[503] == nil)

-- ---------------------------------------------------------------------------
-- the router on a stubbed Retail client
-- ---------------------------------------------------------------------------
STUB_MAPS = MAPS_R
local NS = {}
dofile("tools/stubs.lua")
function GetBuildInfo() return "x", "0", "2026", 120100 end
function UnitLevel() return 30 end
local function load(path) assert(loadfile("CompletionRoute/" .. path))("CompletionRoute", NS) end
for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", "Data/Taxi_retail.lua", "Data/Doors_retail.lua",
    "Data/Transit.lua", "Data/Teleports.lua", "Data/Access.lua", "Data/Inns.lua", "Data/ZoneAliases.lua", "Data/Roads_ek.lua",
    "Data/Roads_kalimdor.lua", "Routing/CostModel.lua", "Routing/TravelGraph.lua", "Routing/Teleports.lua", "Routing/Roads.lua",
    "Routing/StepOrder.lua", "Routing/Router.lua", "Core/Account.lua", "Core/Progress.lua", "Core/Instances.lua" }) do load(f) end
CompletionRouteDB, CompletionRouteCharDB = nil, nil
for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", "CompletionRoute") end
NS.Print, NS.Debug = function() end, function() end
NS.TravelGraph.Build()
local R, I, CM = NS.Router, NS.Instances, NS.CostModel

local ex, ey, ei = I.Entrance(221)
t("Entrance(221) falls back to the shipped door", ex and ei == 1, tostring(ei))
local ashenvale = { zone = 63, coords = { { x = 0.2, y = 0.4 } }, action = "G", index = 1 }
local inside = { zone = 221, coords = { { x = 0.5, y = 0.5 } }, action = "C", index = 2 }
local zoneOnly = { zone = 221, action = "C", index = 3 }
t("a point inside BFD routes from Ashenvale", R.TravelSeconds(ashenvale, inside) ~= nil)
local zx, zy, zi = CM.World({ zone = 221, action = "C", index = 4, _cmk = "zone" })
t("a zone-only BFD step's point is the door", zi == 1 and zx == ex, tostring(zi))
zoneOnly._cmk = "zone"
t("a zone-only BFD step routes from Ashenvale", R.TravelSeconds(ashenvale, zoneOnly) ~= nil)
t("Brawl'gar Arena still has no entrance", I.Entrance(503) == nil)

-- live journal: two pins on the parent map, the second one is ours
C_EncounterJournal = { GetDungeonEntrancesForMap = function(map)
    if map ~= 63 then return {} end
    local function pos(x, y) return { GetXY = function() return x, y end } end
    return { { journalInstanceID = 9999, name = "Other", position = pos(0.1, 0.1) },
             { journalInstanceID = 227, name = "Blackfathom Deeps", position = pos(0.14, 0.14) } }
end }
local rec = I.FromJournal(221)
t("live journal pin matched by journalInstanceID", rec and rec.name == "Blackfathom Deeps", rec and rec.name)
C_EncounterJournal = nil

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
