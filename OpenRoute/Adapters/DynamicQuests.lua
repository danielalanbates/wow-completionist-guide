-- OpenRoute :: Adapters/DynamicQuests.lua
-- Retail has no Questie database, so "every quest" is covered live from the client instead:
-- each zone you visit gets a "<Zone> Quests (Live)" guide built from C_QuestLog.GetQuestsOnMap
-- (every quest currently offered/active on that map, with POI coords). The guide's text is a
-- function, so /or scan (or re-entering the zone) rebuilds it with fresh data.
local ADDON, NS = ...
if NS.flavor ~= "retail" then return end
local G = NS.Guide

local registered = {}   -- [uiMapId] = guide def

local function buildText(mapId)
    local quests = C_QuestLog.GetQuestsOnMap and C_QuestLog.GetQuestsOnMap(mapId) or {}
    local mi = C_Map.GetMapInfo(mapId)
    local zn = mi and mi.name or ("Map " .. mapId)
    local lines = {}
    for _, q in ipairs(quests) do
        local qid = q.questID
        local name = (QuestUtils_GetQuestName and QuestUtils_GetQuestName(qid))
            or (C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(qid)) or ("Quest " .. qid)
        name = name:gsub("[|\r\n]", " ")
        local m = (q.x and q.y) and ("%.1f,%.1f"):format(q.x * 100, q.y * 100) or nil
        if C_QuestLog.IsOnQuest(qid) then
            lines[#lines + 1] = m and ("C %s|QID|%d|M|%s|Z|%d; %s|"):format(name, qid, m, mapId, zn)
                                    or ("C %s|QID|%d|"):format(name, qid)
            lines[#lines + 1] = ("T %s|QID|%d|"):format(name, qid)
        else
            lines[#lines + 1] = m and ("A %s|QID|%d|M|%s|Z|%d; %s|"):format(name, qid, m, mapId, zn)
                                    or ("A %s|QID|%d|"):format(name, qid)
            lines[#lines + 1] = ("T %s|QID|%d|"):format(name, qid)
        end
    end
    -- Loremaster-style coverage: every storyline quest attached to this zone via quest lines,
    -- not just what is currently visible on the map.
    local seen = {}
    for _, q in ipairs(quests) do seen[q.questID] = true end
    if C_QuestLine and C_QuestLine.GetAvailableQuestLines then
        if C_QuestLine.RequestQuestLinesForMap then C_QuestLine.RequestQuestLinesForMap(mapId) end
        for _, ql in ipairs(C_QuestLine.GetAvailableQuestLines(mapId) or {}) do
            for _, qid in ipairs(C_QuestLine.GetQuestLineQuests and C_QuestLine.GetQuestLineQuests(ql.questLineID) or {}) do
                if not seen[qid] then
                    seen[qid] = true
                    local name = (QuestUtils_GetQuestName and QuestUtils_GetQuestName(qid))
                        or (C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(qid)) or ("Quest " .. qid)
                    name = name:gsub("[|\r\n]", " ")
                    lines[#lines + 1] = ("A %s|QID|%d|N|%s storyline.|"):format(name, qid, ql.questLineName or "Zone")
                    lines[#lines + 1] = ("T %s|QID|%d|"):format(name, qid)
                end
            end
        end
    end
    if #lines == 0 then lines[1] = "N No quests on this map right now|" end
    return table.concat(lines, "\n")
end

local function registerMap(mapId)
    if not mapId or mapId == 0 then return end
    local mi = C_Map.GetMapInfo(mapId)
    if not mi or mi.mapType ~= Enum.UIMapType.Zone then return end
    local id = "qdyn:" .. mapId
    if registered[mapId] then
        local g = G.registry[id]
        if g then g.steps = nil end   -- force re-parse with fresh data next time it is read
        NS:Fire("GUIDE_REGISTERED", g)
        return
    end
    registered[mapId] = G.Register({
        id = id, name = (mi.name or ("Map " .. mapId)) .. " Quests (Live)", type = "Quests",
        zone = mapId, author = "live client data", source = "OpenRoute",
        text = function() return buildText(mapId) end,
    })
end

local function scanHere()
    local mapId = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    -- walk up to the zone-level map
    local mi = mapId and C_Map.GetMapInfo(mapId)
    while mi and mi.mapType and mi.mapType > Enum.UIMapType.Zone and mi.parentMapID and mi.parentMapID > 0 do
        mapId = mi.parentMapID
        mi = C_Map.GetMapInfo(mapId)
    end
    registerMap(mapId)
end
NS.DynamicQuests = { Scan = scanHere, RegisterMap = registerMap }

NS:RegisterEvent("PLAYER_ENTERING_WORLD", function() C_Timer.After(3, scanHere) end)
NS:RegisterEvent("ZONE_CHANGED_NEW_AREA", function() C_Timer.After(1, scanHere) end)
