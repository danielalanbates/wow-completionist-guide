-- CompletionRoute :: Core/Contribute.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- "Contribute": the player's own play builds the location database (docs/CONTRIBUTE.md).
--
-- With the Contribute box on the guide window ticked, the addon notes WHERE the player stands when a step is done:
--   * the forward arrow is clicked on the current step          (kind m, weight 1: the player may be anywhere near)
--   * a quest is accepted or turned in (the client's own events) (kind a, weight 3: the player stands at the NPC)
--   * a quest objective of a step in the guide's next steps ticks up (kind o, weight 2: where the mob, item or
--     object was)
-- Nothing else is stored: a map id, a position on it, the quest id or step key, a weight.  No character, realm or
-- account name, no time stamps.  Nothing is sent anywhere; the data sits in the account's saved variables until the
-- player exports it (/cr contribute export) to share with the open quest database.
--
-- From those samples the most likely places are worked out (C.Areas): the densest cluster first, each with a centre
-- and a radius.  They are used at once on this machine: a step the guide has no point for is routed to its learned
-- spot (Router.StepWorld, source "learned"), and the current step's areas are drawn on the world map as circles.
local ADDON, NS = ...
local U = NS.Util
local C = {}
NS.Contribute = C

local HBD = LibStub and LibStub("HereBeDragons-2.0", true)
local HBDPins = LibStub and LibStub("HereBeDragons-Pins-2.0", true)

C.CELL = 0.2            -- map-% grid the samples are merged on (positions are stored as 0..100)
C.MAX_CELLS = 80        -- per step key: the lightest cell goes when a new one would exceed this
C.RADIUS = 1.5          -- map-% : cells closer than this to a cluster's centre belong to it
C.MIN_R = 0.3           -- smallest circle drawn / reported
C.WEIGHT = { m = 1, o = 2, a = 3 }
local ACCEPT = { A = true, a = true }
local TURNIN = { T = true, t = true }

local function flavor() return NS.dataFlavor or NS.flavor or "?" end
local function enabled() return NS.db and NS.db.profile and NS.db.profile.contribute and true or false end
C.Enabled = enabled

-- account-wide store: contrib.spots[flavor][key][cell] = weight ; cell = "<map>,<x*5>,<y*5>" on the CELL grid
local function store(create)
    if not NS.db then return nil end
    local g = NS.db.global
    if not g.contrib then
        if not create then return nil end
        g.contrib = { v = 1, spots = {} }
    end
    local t = g.contrib.spots[flavor()]
    if not t and create then t = {} g.contrib.spots[flavor()] = t end
    return t
end

-- The database key of a step.  Quest steps are keyed by quest, not by guide, so every guide that has the quest
-- shares what was learned; anything else is keyed by its guide and stable step key (Core/Guide.lua AssignKeys).
function C.KeyFor(step)
    if not step then return nil end
    local q = step.qid and step.qid[1]
    if q then
        if ACCEPT[step.action] then return "A:" .. q end
        if TURNIN[step.action] then return "T:" .. q end
        return "C:" .. q .. ":" .. (tonumber(step.qo) or 0)
    end
    if step.guide and step.key then return "G:" .. tostring(step.guide) .. "#" .. tostring(step.key) end
    return nil
end

local areasCache, worldCache = {}, {}
local function forget(key) areasCache[key] = nil worldCache[key] = nil end

-- one sample at the player's position
function C.Record(key, kind)
    if not key or not enabled() then return false end
    if (UnitOnTaxi and UnitOnTaxi("player")) or (UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")) then return false end
    local map, x, y = U.PlayerPos()
    if not map or not x or not y or x <= 0 or y <= 0 or x >= 1 or y >= 1 then return false end
    local t = store(true)
    if not t then return false end
    local cells = t[key]
    if not cells then cells = {} t[key] = cells end
    local q = 1 / C.CELL
    local cell = ("%d,%d,%d"):format(map, math.floor(x * 100 * q + 0.5), math.floor(y * 100 * q + 0.5))
    if not cells[cell] then
        local n, lightest, lw = 0, nil, nil
        for c, w in pairs(cells) do
            n = n + 1
            if not lw or w < lw then lightest, lw = c, w end
        end
        if n >= C.MAX_CELLS and lightest then cells[lightest] = nil end
    end
    cells[cell] = (cells[cell] or 0) + (C.WEIGHT[kind] or 1)
    forget(key)
    C.lastKey, C.lastKind = key, kind
    NS:Fire("CONTRIBUTE_SAMPLE", key, kind)
    return true
end

local function parse(cells)
    local out = {}
    for c, w in pairs(cells) do
        local m, x, y = c:match("^(%d+),(%-?%d+),(%-?%d+)$")
        if m then out[#out + 1] = { m = tonumber(m), x = tonumber(x) * C.CELL, y = tonumber(y) * C.CELL, w = w } end
    end
    -- a fixed order, so the same samples always give the same areas
    table.sort(out, function(a, b)
        if a.m ~= b.m then return a.m < b.m end
        if a.x ~= b.x then return a.x < b.x end
        return a.y < b.y
    end)
    return out
end

-- The most likely places for a key, heaviest first: { m = map, x = , y = (0..100), r = radius in map %, w = weight,
-- n = cells }.  Greedy: the cell with the most weight around it seeds a cluster, the cluster's weighted centre is
-- taken once more, its cells are removed, and the rest is searched again.  A leftover lighter than 15% of all the
-- weight (and lighter than 2) is noise and gives no area.  At most four areas.
function C.Areas(key)
    if not key then return {} end
    local hit = areasCache[key]
    if hit then return hit end
    local out = {}
    local t = store(false)
    local cells = t and t[key]
    if cells then
        local pts = parse(cells)
        local total = 0
        for _, p in ipairs(pts) do total = total + p.w end
        local R2 = C.RADIUS * C.RADIUS
        while #pts > 0 and #out < 4 do
            local best, bw
            for i, p in ipairs(pts) do
                local w = 0
                for _, o in ipairs(pts) do
                    if o.m == p.m then
                        local dx, dy = o.x - p.x, o.y - p.y
                        if dx * dx + dy * dy <= R2 then w = w + o.w end
                    end
                end
                if not bw or w > bw then best, bw = i, w end
            end
            if #out > 0 and (bw < 2 or bw < total * 0.15) then break end
            local seed = pts[best]
            local cx, cy = seed.x, seed.y
            for _ = 1, 2 do
                local sx, sy, sw = 0, 0, 0
                for _, o in ipairs(pts) do
                    if o.m == seed.m then
                        local dx, dy = o.x - cx, o.y - cy
                        if dx * dx + dy * dy <= R2 then sx, sy, sw = sx + o.x * o.w, sy + o.y * o.w, sw + o.w end
                    end
                end
                if sw > 0 then cx, cy = sx / sw, sy / sw end
            end
            local keep, mine, w, far = {}, 0, 0, 0
            for _, o in ipairs(pts) do
                local dx, dy = o.x - cx, o.y - cy
                local d2 = dx * dx + dy * dy
                if o.m == seed.m and d2 <= R2 then
                    mine, w = mine + 1, w + o.w
                    if d2 > far then far = d2 end
                else
                    keep[#keep + 1] = o
                end
            end
            if mine == 0 then break end
            out[#out + 1] = { m = seed.m, x = cx, y = cy, r = math.max(C.MIN_R, math.sqrt(far)), w = w, n = mine }
            pts = keep
        end
    end
    areasCache[key] = out
    return out
end

-- the learned world position of a step (nil when nothing was learned for it): Routing/Router.lua StepWorld asks
-- this for a step the guide gives no point for
function C.StepWorld(step)
    local key = C.KeyFor(step)
    if not key then return nil end
    local w = worldCache[key]
    if w == nil then
        w = false
        local a = C.Areas(key)[1]
        if a and HBD then
            local ok, wx, wy, inst = pcall(HBD.GetWorldCoordinatesFromZone, HBD, a.x / 100, a.y / 100, a.m)
            if ok and wx then w = { wx, wy, inst } end
        end
        worldCache[key] = w
    end
    if w then return w[1], w[2], w[3] end
    return nil
end

function C.Stats()
    local keys, cells, weight = 0, 0, 0
    local t = store(false)
    for _, cs in pairs(t or {}) do
        keys = keys + 1
        for _, w in pairs(cs) do cells, weight = cells + 1, weight + w end
    end
    return keys, cells, weight
end

function C.Clear()
    if NS.db and NS.db.global.contrib then NS.db.global.contrib.spots[flavor()] = nil end
    areasCache, worldCache = {}, {}
    NS:Fire("CONTRIBUTE_SAMPLE")
end

function C.SetEnabled(on)
    NS.db.profile.contribute = on and true or false
    if on and not NS.db.global.contribSeen then
        NS.db.global.contribSeen = true
        NS:Print("Contribute is on: the addon notes where you stand when you accept or turn in a quest, when an objective "
            .. "ticks, and when you click the forward arrow. Only map positions and quest ids are kept, in your saved "
            .. "variables. /cr contribute shows what was collected; /cr contribute export gives a text to share.")
    end
    NS:Fire("CONTRIBUTE_CHANGED", NS.db.profile.contribute)
end

-- Text for sharing: one line per key, "flavor|client build|key|map,x,y,weight;...".  No names of any kind.
function C.Export()
    local lines = {}
    local build = (GetBuildInfo and select(1, GetBuildInfo())) or "?"
    local t = store(false) or {}
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local parts = {}
        for _, p in ipairs(parse(t[k])) do parts[#parts + 1] = ("%d,%.1f,%.1f,%d"):format(p.m, p.x, p.y, p.w) end
        lines[#lines + 1] = ("%s|%s|%s|%s"):format(flavor(), build, k, table.concat(parts, ";"))
    end
    return table.concat(lines, "\n"), #keys
end

-- ---------------------------------------------------------------------------
-- What is recorded
-- ---------------------------------------------------------------------------
-- 1. the forward arrow on the current step (Core/Progress.lua MarkDone fires STEP_DONE with manual and wasCurrent)
NS:On("STEP_DONE", function(step, manual, wasCurrent)
    if manual and wasCurrent and enabled() then C.Record(C.KeyFor(step), "m") end
end)

-- 2. accept and turn-in, straight from the client: the player is standing at the giver or the ender
NS:RegisterEvent("QUEST_ACCEPTED", function(_, a, b)
    local q = tonumber(b) or tonumber(a)      -- (questID) on Retail, (log index, questID) on the Classic clients
    if q and enabled() then C.Record("A:" .. q, "a") end
end)
NS:RegisterEvent("QUEST_TURNED_IN", function(_, q)
    q = tonumber(q)
    if q and enabled() then C.Record("T:" .. q, "a") end
end)

-- 3. objective progress on the quests of the guide's next steps: where the count went up is where the thing is
local seen = {}      -- [key] = fulfilled count last seen
local function pollObjectives()
    if not enabled() or not (NS.Progress and NS.Progress.Pending) then return end
    local ok, pending = pcall(NS.Progress.Pending, 20)
    if not ok or not pending then return end
    for _, s in ipairs(pending) do
        local q = s.qid and s.qid[1]
        if q and not ACCEPT[s.action] and not TURNIN[s.action] and U.IsOnQuest(q) then
            local key = C.KeyFor(s)
            local okq, have = pcall(U.QuestObjective, q, tonumber(s.qo) or 1)
            have = okq and tonumber(have) or nil
            if have then
                if seen[key] and have > seen[key] then C.Record(key, "o") end
                seen[key] = have
            end
        end
    end
end
C.PollObjectives = pollObjectives
NS:RegisterEvent("QUEST_LOG_UPDATE", function() NS:Throttle("contribute-objectives", 0.3, pollObjectives) end)

-- ---------------------------------------------------------------------------
-- Circles on the world map for the current step's learned areas
-- ---------------------------------------------------------------------------
local TEX = "Interface\\AddOns\\" .. ADDON .. "\\Textures\\circle"
local RGB = { A = { 1, 0.82, 0 }, T = { 0.4, 1, 0.4 }, C = { 1, 0.45, 0.25 }, G = { 0.24, 0.78, 1 } }
local circles = {}
local function circle(i)
    if not circles[i] then
        local f = CreateFrame("Frame", nil, UIParent)
        f:SetSize(24, 24)
        f.tex = f:CreateTexture(nil, "OVERLAY")
        f.tex:SetAllPoints()
        f.tex:SetTexture(TEX)
        circles[i] = f
    end
    return circles[i]
end

function C.UpdateMap()
    C.mapState = "no lib"
    if not HBDPins then return end
    pcall(HBDPins.RemoveAllWorldMapIcons, HBDPins, C)
    for _, f in pairs(circles) do f:Hide() end
    if not NS.db or not NS.db.profile.beacon or not NS.db.profile.beacon.pins then C.mapState = "pins off" return end
    local s = NS.Progress and NS.Progress.current
    local key = C.KeyFor(s)
    local areas = key and C.Areas(key) or {}
    if #areas == 0 then C.mapState = "nothing learned for this step" return end
    -- a circle's size on the map: its radius is in map %, the canvas is the whole map
    local canvas = WorldMapFrame and WorldMapFrame.GetCanvas and WorldMapFrame:GetCanvas()
    local width = (canvas and canvas.GetWidth and canvas:GetWidth()) or 1000
    if not width or width <= 0 then width = 1000 end
    local c = RGB[key:sub(1, 1)] or RGB.G
    local n = 0
    for i, a in ipairs(areas) do
        local f = circle(i)
        local d = math.max(18, math.min(260, 2 * a.r / 100 * width))
        f:SetSize(d, d)
        f.tex:SetVertexColor(c[1], c[2], c[3], i == 1 and 0.9 or 0.55)
        local ok = pcall(HBDPins.AddWorldMapIconMap, HBDPins, C, f, a.m, a.x / 100, a.y / 100, 1)
        if ok then n = n + 1 end
    end
    C.mapState = ("%d learned area(s) drawn"):format(n)
end
NS:On("STEP_CHANGED", function() NS:Throttle("contribute-map", 0.5, function() pcall(C.UpdateMap) end) end)
NS:On("CONTRIBUTE_SAMPLE", function()
    if NS.Router and NS.Router.Invalidate then pcall(NS.Router.Invalidate) end
    NS:Throttle("contribute-map", 0.5, function() pcall(C.UpdateMap) end)
end)
NS:On("PLAYER_READY", function() NS:After(4, function() pcall(C.UpdateMap) end) end)

-- ---------------------------------------------------------------------------
-- /cr contribute [on|off|clear|export]
-- ---------------------------------------------------------------------------
local exportFrame
local function showExport()
    local text, n = C.Export()
    if n == 0 then NS:Print("Contribute: nothing collected on this client yet.") return end
    if not exportFrame then
        local f = CreateFrame("Frame", "CompletionRouteContributeExport", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
        f:SetSize(560, 360); f:SetPoint("CENTER"); f:SetFrameStrata("DIALOG")
        if f.SetBackdrop then
            f:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                            tile = true, tileSize = 16, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
            f:SetBackdropColor(0.05, 0.05, 0.08, 0.97)
        end
        f.title = f:CreateFontString(nil, "OVERLAY", U.Font("Title"))
        f.title:SetPoint("TOPLEFT", 12, -10)
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", -2, -2)
        local scroll = CreateFrame("ScrollFrame", "CompletionRouteContributeExportScroll", f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 12, -34); scroll:SetPoint("BOTTOMRIGHT", -32, 12)
        local eb = CreateFrame("EditBox", nil, scroll)
        eb:SetMultiLine(true); eb:SetAutoFocus(false); eb:SetWidth(500)
        eb:SetFontObject(U.Font("Small"))
        eb:SetScript("OnEscapePressed", function() f:Hide() end)
        scroll:SetScrollChild(eb)
        f.eb = eb
        tinsert(UISpecialFrames, "CompletionRouteContributeExport")
        exportFrame = f
    end
    exportFrame.title:SetText(("Contribute: %d places. Select all (Ctrl+A), copy, and send it to the open quest database."):format(n))
    exportFrame.eb:SetText(text)
    exportFrame:Show()
    exportFrame.eb:HighlightText()
    exportFrame.eb:SetFocus()
end
C.ShowExport = showExport

function C.Slash(arg)
    arg = (arg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if arg == "on" or arg == "off" then C.SetEnabled(arg == "on")
    elseif arg == "clear" then C.Clear() NS:Print("Contribute: this client's collected places were cleared.") return
    elseif arg == "export" then showExport() return end
    local keys, cells, weight = C.Stats()
    NS:Print(("Contribute is %s. Collected on this client: %d steps, %d spots (weight %d). "
        .. "/cr contribute on|off|export|clear"):format(enabled() and "ON" or "off", keys, cells, weight))
    local s = NS.Progress and NS.Progress.current
    local key = C.KeyFor(s)
    if key then
        local areas = C.Areas(key)
        if #areas > 0 then
            local a = areas[1]
            NS:Print(("  current step: %d learned area(s); best %.1f, %.1f on map %d (radius %.1f, weight %d)"):format(
                #areas, a.x, a.y, a.m, a.r, a.w))
        end
    end
end
