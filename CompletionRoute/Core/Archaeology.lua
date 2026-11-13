-- CompletionRoute :: Core/Archaeology.lua
-- Archaeology dig-site guide (mop, retail): the sites this character can dig right now, rebuilt when one is finished.
-- Copyright (c) 2026 Daniel Bates / Bates LLC.  All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- Where the active sites come from, best first (API names from warcraft.wiki.gg API pages):
--   1. C_ResearchInfo.GetDigSitesForMap(uiMapID): { researchSiteID, position (0..1 on that map), name, ... }
--   2. static list NS.ArchaeologySites (Guides/Imported_Professions_<fl>.lua, client ResearchSite data) with a note that it
--      lists every site of the continent, because the client gave no active list.
-- A step here is an M step, not a proximity waypoint: arriving at a site must not tick it, the site is done when its
-- finds are dug.  The client then replaces the site and fires an event, and this guide is rebuilt from the new list.
local ADDON, NS = ...
if NS.flavor ~= "mop" and NS.flavor ~= "retail" then return end
local U, G = NS.Util, NS.Guide
local A = {}
NS.Archaeology = A
A.GUIDE_ID = "prof:archaeology:active"

local MAX_STATIC = 12    -- the fallback is every site of a continent: only the nearest few make a usable list

local function continentOf(mapID)
    if not (mapID and C_Map and C_Map.GetMapInfo) then return nil end
    local continentType = Enum and Enum.UIMapType and Enum.UIMapType.Continent or 2
    for _ = 1, 8 do
        local info = C_Map.GetMapInfo(mapID)
        if not info then return nil end
        if info.mapType == continentType then return mapID end
        if not info.parentMapID or info.parentMapID == 0 then return nil end
        mapID = info.parentMapID
    end
    return nil
end
A.ContinentOf = continentOf

-- The zones of a continent that can hold a site, from the static list (one query per zone, only when the list is rebuilt).
local function zonesOf(continent)
    local seen, out = {}, {}
    for _, s in ipairs((NS.ArchaeologySites or {})[continent] or {}) do
        if not seen[s[3]] then seen[s[3]] = true out[#out + 1] = s[3] end
    end
    return out
end

-- Active sites on this continent, or nil when the client has no API for it.  Each: { id, name, map, x (0..1), y (0..1) }.
function A.ActiveSites(continent)
    local fn = C_ResearchInfo and C_ResearchInfo.GetDigSitesForMap
    if type(fn) ~= "function" then return nil end
    local out, seen = {}, {}
    for _, map in ipairs(zonesOf(continent)) do
        local ok, list = pcall(fn, map)
        if ok and type(list) == "table" then
            for _, s in ipairs(list) do
                local p = s.position
                local x, y = p and (p.x or (p.GetXY and select(1, p:GetXY()))), p and (p.y or (p.GetXY and select(2, p:GetXY())))
                local id = s.researchSiteID or s.name
                if id and x and y and x > 0 and x < 1 and y > 0 and y < 1 and not seen[id] then
                    seen[id] = true
                    out[#out + 1] = { id = id, name = s.name or "Dig site", map = map, x = x, y = y }
                end
            end
        end
    end
    return out
end

local function staticSites(continent)
    local out = {}
    for _, s in ipairs((NS.ArchaeologySites or {})[continent] or {}) do
        out[#out + 1] = { id = s[1], name = s[2], map = s[3], x = s[4] / 100, y = s[5] / 100 }
    end
    return out
end

-- Nearest-first from the player, then each next site nearest to the last.  Sites the distance cannot be measured for keep their order.
local function order(sites)
    if not (U.PlayerPos and U.ZoneDistance) then return sites end
    local map, px, py = U.PlayerPos()
    if not map then return sites end
    local out, pool, cm, cx, cy = {}, { unpack(sites) }, map, px, py
    while #pool > 0 do
        local bestI, bestD
        for i, s in ipairs(pool) do
            local d = U.ZoneDistance(cm, cx, cy, s.map, s.x, s.y)
            if d and (not bestD or d < bestD) then bestI, bestD = i, d end
        end
        if not bestI then for _, s in ipairs(pool) do out[#out + 1] = s end break end
        local s = table.remove(pool, bestI)
        out[#out + 1] = s
        cm, cx, cy = s.map, s.x, s.y
    end
    return out
end

function A.BuildText()
    local map = U.PlayerPos and U.PlayerPos()
    local continent = continentOf(map)
    if not continent then return "N Log in on a continent with dig sites|N|Your position is not known yet, or this place has no dig sites. Reload the route once you are on a continent.|\n" end
    local sites = A.ActiveSites(continent)
    local active = sites ~= nil and #sites > 0
    local note = "Use Survey until the site is empty. This list rebuilds by itself when a site is finished."
    if not active then
        sites = staticSites(continent)
        note = "This client did not report your active dig sites, so this is the full site list for this continent. Check your map for the shovel icons."
    end
    if #sites == 0 then return "N No dig sites here|N|No site data for this continent. Train Archaeology and open your map to see your sites.|\n" end
    sites = order(sites)
    local lines = {}
    for i, s in ipairs(sites) do
        if not active and i > MAX_STATIC then break end
        local name = tostring(s.name):gsub("|", "/")
        local mapName = U.MapName and U.MapName(s.map) or ""
        lines[#lines + 1] = ("M %s|M|%.1f,%.1f|Z|%d; %s|N|%s|"):format(name, s.x * 100, s.y * 100, s.map, tostring(mapName):gsub("|", "/"), note)
    end
    return table.concat(lines, "\n") .. "\n"
end

-- Throw away the old steps and their ticks and show the new list.  Only when this guide is the one being played.
function A.Refresh()
    local g = G.registry[A.GUIDE_ID]
    if not g then return end
    g.steps = nil
    local P = NS.Progress
    if P and P.guide and P.guide.id == A.GUIDE_ID then
        P.Load(A.GUIDE_ID)
        -- the step numbers now mean other sites, so the old ticks must not carry over
        if P.guide and P.guide.id == A.GUIDE_ID and P.Reset then P.Reset() end
    end
end

G.Register({ id = A.GUIDE_ID, name = "Archaeology: active dig sites", type = "Professions", folder = "Archaeology", prof = "Archaeology", dynamic = true,
    author = "Client dig site data", source = "Blizzard client tables and live dig sites", minlevel = 20, skillMin = 1,
    skillMax = NS.flavor == "mop" and 600 or 950, text = A.BuildText })

-- Wiki event pages: RESEARCH_ARTIFACT_DIG_SITE_UPDATED (named ARTIFACT_DIG_SITE_UPDATED before 7.0.3) fires when a new site
-- replaces a finished one; ARTIFACT_DIGSITE_COMPLETE was added in 5.4.0.  NS:RegisterEvent pcalls, so a missing event is harmless.
local lastContinent
local function onSiteChange() NS:Throttle("archaeology", 1.0, A.Refresh) end
for _, evt in ipairs({ "RESEARCH_ARTIFACT_DIG_SITE_UPDATED", "ARTIFACT_DIG_SITE_UPDATED", "ARTIFACT_DIGSITE_COMPLETE" }) do
    NS:RegisterEvent(evt, onSiteChange)
end
NS:RegisterEvent("ZONE_CHANGED_NEW_AREA", function()
    local c = continentOf(U.PlayerPos and U.PlayerPos())
    if c and c ~= lastContinent then
        lastContinent = c
        onSiteChange()
    end
end)
