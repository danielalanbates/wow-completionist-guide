-- CompletionRoute :: Core/Instances.lua
-- "Route into a dungeon" without inventing data.
--
-- A guide step inside a dungeon/raid/scenario map has no travel edge into it: the sweep has always
-- called those "no route (instance map, expected)".  That is honest but useless to the player, who
-- still has to find the door.  So we learn the doors instead of shipping a coordinate table:
--   * the last outdoor position before a loading screen that puts you inside IS the entrance,
--   * on retail, C_EncounterJournal.GetDungeonEntrancesForMap gives the client's own answer,
--   * entrances are account-wide and export with the farm nodes, so a guild can share one file.
-- Router.StepWorld then routes to the entrance whenever the target is inside an instance you are
-- not currently in, and the arrow points at the door instead of nowhere.
--
-- Copyright (c) 2026 Daniel Bates / Bates LLC.  All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 (see LICENSE); 10% revenue share for commercial use.
local ADDON, NS = ...
local U = NS.Util
local I = {}
NS.Instances = I

local lastOutdoor = nil   -- { map, x, y, wx, wy, inst, t }

local function db()
    if not (NS.db and NS.db.global) then return nil end
    NS.db.global.instanceEntrances = NS.db.global.instanceEntrances or {}
    return NS.db.global.instanceEntrances
end

-- Is this uiMap an instance interior? (mapType 4 dungeon / 5 raid / 6 orphan-scenario)
function I.IsInstanceMap(mapID)
    if not mapID then return false end
    local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
    if not info then return false end
    local t = info.mapType
    return t == 4 or t == 5 or t == 6
end

-- Remember where we were standing right before the loading screen
local function noteOutdoor()
    if IsInInstance and IsInInstance() then return end
    local map, x, y, inst, wx, wy = U.PlayerPos()
    if map and wx and not I.IsInstanceMap(map) then
        lastOutdoor = { map = map, x = x, y = y, wx = wx, wy = wy, inst = inst, t = GetTime and GetTime() or 0 }
    end
end

function I.Learn()
    if not (IsInInstance and IsInInstance()) then return end
    local d = db()
    if not (d and lastOutdoor) then return end
    local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local _, _, _, _, _, _, _, instID = GetInstanceInfo and GetInstanceInfo()
    local keys = {}
    if map then keys[#keys + 1] = "map:" .. map end
    if instID then keys[#keys + 1] = "inst:" .. instID end
    for _, k in ipairs(keys) do
        if not d[k] then
            d[k] = { map = lastOutdoor.map, x = lastOutdoor.x, y = lastOutdoor.y,
                     name = GetInstanceInfo and GetInstanceInfo() or nil, learned = time and time() or nil }
            NS:Debug(("learned instance entrance %s at %s %.1f,%.1f"):format(k, U.MapName(lastOutdoor.map), lastOutdoor.x * 100, lastOutdoor.y * 100))
        end
    end
end

-- Retail's own answer, when the client has one (no data of ours involved)
function I.FromJournal(mapID)
    if not (C_EncounterJournal and C_EncounterJournal.GetDungeonEntrancesForMap) then return nil end
    local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
    local parent = info and info.parentMapID
    -- the entrance pins live on the OUTDOOR map, so ask the parent chain
    local hops = 0
    while parent and parent ~= 0 and hops < 6 do
        local ok, list = pcall(C_EncounterJournal.GetDungeonEntrancesForMap, parent)
        if ok and type(list) == "table" then
            for _, e in ipairs(list) do
                if e.position and (e.journalInstanceID or e.name) then
                    local x, y = e.position:GetXY()
                    if x then return { map = parent, x = x, y = y, name = e.name, src = "journal" }, e end
                end
            end
        end
        local pinfo = C_Map.GetMapInfo(parent)
        parent = pinfo and pinfo.parentMapID
        hops = hops + 1
    end
    return nil
end

-- Best known entrance for an instance map: learned first (it is where YOU actually walked in),
-- then the client's journal.  Returns world coords + a description.
function I.Entrance(mapID)
    if not mapID then return nil end
    local d = db()
    local rec = d and d["map:" .. mapID]
    if not rec then
        local j = I.FromJournal(mapID)
        if j then
            rec = j
            if d then d["map:" .. mapID] = j end
        end
    end
    if not rec then
        -- last fallback: the seeded door (Data/Imported_Entrances.lua, tools/gen_entrances.py), keyed by
        -- the interior map's name so every floor of a multi-level dungeon finds it
        local seed = NS.EntranceSeed and NS.EntranceSeed[U.MapName(mapID) or ""]
        if seed then rec = { map = seed[1], x = seed[2], y = seed[3], name = U.MapName(mapID), src = "seed" } end
    end
    if not rec then return nil end
    local wx, wy, inst = U.World(rec.map, rec.x, rec.y)
    if not wx then return nil end
    return wx, wy, inst, rec
end

function I.Count() local n = 0 for _ in pairs(db() or {}) do n = n + 1 end return n end

-- Export/import alongside the farm nodes (same plain-text spirit: shareable, no addon required)
function I.Export()
    local out = {}
    for k, r in pairs(db() or {}) do
        out[#out + 1] = ("%s %d %.4f %.4f %s"):format(k, r.map, r.x, r.y, (r.name or "?"):gsub("%s", "_"))
    end
    return table.concat(out, "\n")
end
function I.ImportText(text)
    local d, n = db(), 0
    if not d then return 0 end
    for line in (tostring(text) .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        local key, map, x, y, name = line:match("^%s*(%S+)%s+(%d+)%s+([%d%.]+)%s+([%d%.]+)%s*(%S*)")
        if key and not d[key] then
            d[key] = { map = tonumber(map), x = tonumber(x), y = tonumber(y), name = (name or ""):gsub("_", " "), src = "shared" }
            n = n + 1
        end
    end
    return n
end

NS:RegisterEvent("PLAYER_ENTERING_WORLD", function() pcall(I.Learn) NS:After(2, function() pcall(noteOutdoor) end) end)
NS:RegisterEvent("ZONE_CHANGED_NEW_AREA", function() pcall(noteOutdoor) end)
NS:RegisterEvent("ZONE_CHANGED", function() pcall(noteOutdoor) end)
NS:RegisterEvent("PLAYER_STOPPED_MOVING", function() pcall(noteOutdoor) end)

return I
