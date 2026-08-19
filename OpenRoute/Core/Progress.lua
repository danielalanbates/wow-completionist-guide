-- OpenRoute :: Core/Progress.lua
-- Tracks the active guide: which steps are done/skipped, auto-completion from game events,
-- and exposes the ordered list of upcoming steps (after the route optimizer has its say).
local ADDON, NS = ...
local U, Cond, G = NS.Util, NS.Cond, NS.Guide
local P = {}
NS.Progress = P

P.guide = nil        -- guide record
P.steps = nil        -- parsed steps (original order)
P.order = nil        -- array of step indices in display order (optimizer output)
P.current = nil      -- current step table
local dirty = true

local function charDone()
    local c = NS.db.char
    c.done[P.guide.id] = c.done[P.guide.id] or {}
    return c.done[P.guide.id]
end
local function charSkipped()
    local c = NS.db.char
    c.skipped[P.guide.id] = c.skipped[P.guide.id] or {}
    return c.skipped[P.guide.id]
end

function P.Load(id)
    local g = G.registry[id]
    if not g then NS:Error("Unknown guide: " .. tostring(id)) return false end
    P.guide = g
    P.steps = G.Steps(id)
    NS.db.char.guide = id
    dirty = true
    NS:Print("Guide: " .. (g.name or g.id) .. " (" .. #P.steps .. " steps, from " .. (g.source or "?") .. ")")
    P.Refresh()
    NS:Fire("GUIDE_LOADED", g)
    return true
end

function P.IsDone(step) return charDone()[step.index] or charSkipped()[step.index] end
function P.MarkDone(step, manual)
    if not step then return end
    charDone()[step.index] = true
    dirty = true
    NS:Debug("done: " .. step.action .. " " .. step.title)
    NS:Fire("STEP_DONE", step)
    P.Refresh()
end
function P.Skip(step) if step then charSkipped()[step.index] = true dirty = true P.Refresh() end end
function P.Undo()
    -- un-complete the most recent done/skipped step by original index before current
    local d, s = charDone(), charSkipped()
    local best
    for idx in pairs(d) do if not best or idx > best then best = idx end end
    for idx in pairs(s) do if not best or idx > best then best = idx end end
    if best then d[best] = nil s[best] = nil dirty = true P.Refresh() end
end
function P.Reset()
    if not P.guide then return end
    NS.db.char.done[P.guide.id] = {}
    NS.db.char.skipped[P.guide.id] = {}
    dirty = true
    P.Refresh()
end

-- ---------------------------------------------------------------------------
-- Auto-completion logic per action
-- ---------------------------------------------------------------------------
local function anyQuestDone(qids, fn)
    if not qids then return false end
    if qids.andor == "and" then for _, q in ipairs(qids) do if not fn(q) then return false end end return true end
    for _, q in ipairs(qids) do if fn(q) then return true end end
    return false
end
P.anyQuestDone = anyQuestDone

local function nearCoords(step, radius)
    if not step.coords or not step.zone then return false end
    local map, x, y = U.PlayerPos()
    if not map then return false end
    for _, c in ipairs(step.coords) do
        local d = U.ZoneDistance(map, x, y, step.zone, c.x, c.y)
        if d and d < (radius or 40) then return true end
    end
    return false
end
local function inZone(step)
    if not step.zone then return false end
    local map = U.PlayerPos()
    if map == step.zone then return true end
    -- allow parent (e.g. city inside continent) equality
    local info = map and C_Map.GetMapInfo(map)
    return info and info.parentMapID == step.zone
end

-- returns true if step is (now) complete or obsolete
function P.CheckStep(step)
    local a = step.action
    if a == "A" or a == "a" or a == "!" then
        if step.qid and anyQuestDone(step.qid, function(q) return U.IsOnQuest(q) or U.IsQuestComplete(q) end) then return true end
    elseif a == "T" or a == "t" then
        if step.qid and anyQuestDone(step.qid, U.IsQuestComplete) then return true end
    elseif a == "C" or a == "K" or a == "l" then
        if step.qid then
            if anyQuestDone(step.qid, U.IsQuestComplete) then return true end
            -- on quest & objectives done
            local allon = true
            for _, q in ipairs(step.qid) do
                if U.IsOnQuest(q) then
                    local idx, complete = U.QuestLogState(q)
                    if complete then return true end
                    if step.qo then
                        -- specific objective index e.g. "1" or "Kill x"
                        local oi = tonumber(step.qo)
                        if oi then local f, r, fin = U.QuestObjective(q, oi) if fin or (r and r > 0 and f >= r) then return true end end
                    else
                        if U.AllObjectivesDone(q) then return true end
                    end
                else allon = false end
            end
        end
        if step.loot and not step.qid then
            local ok = true
            for _, l in ipairs(step.loot) do if U.ItemCount(l.id) < l.qty then ok = false end end
            if ok then return true end
        end
    elseif a == "R" then
        if step.coords then if nearCoords(step, 30) then return true end
        elseif inZone(step) then return true end
    elseif a == "F" or a == "b" or a == "J" or a == "H" or a == "D" then
        if step.coords then if nearCoords(step, 60) then return true end
        elseif step.zone and inZone(step) then return true end
    elseif a == "L" then
        if step.minlevel and U.PlayerLevel() >= step.minlevel then return true end
    elseif a == "U" then
        if step.item and step.hadItem and U.ItemCount(step.item) == 0 then return true end
        if step.item and U.ItemCount(step.item) > 0 then step.hadItem = true end
        if step.qid and anyQuestDone(step.qid, U.IsQuestComplete) then return true end
    elseif a == "B" then
        if step.loot then local ok = true for _, l in ipairs(step.loot) do if U.ItemCount(l.id) < l.qty then ok = false end end if ok then return true end end
    elseif a == "h" then
        if step.bindDone then return true end
    elseif a == "f" then
        if step.taxiDone then return true end
    end
    -- generic: quest already complete => step obsolete
    if step.qid and (a ~= "A" and a ~= "a") and anyQuestDone(step.qid, U.IsQuestComplete) then return true end
    return false
end

-- ---------------------------------------------------------------------------
-- Ordering / current step
-- ---------------------------------------------------------------------------
-- pending = applicable, not done steps in guide order
function P.Pending(limit)
    local out = {}
    if not P.steps then return out end
    for _, s in ipairs(P.steps) do
        if not P.IsDone(s) and Cond.StepApplies(s) then
            out[#out + 1] = s
            if limit and #out >= limit then break end
        end
    end
    return out
end

function P.Refresh(force)
    if not P.guide then return end
    -- 1) auto-complete anything already satisfied (scan a window ahead so obsolete steps vanish)
    local changed = false
    local pend = P.Pending(40)
    for _, s in ipairs(pend) do
        if P.CheckStep(s) then charDone()[s.index] = true changed = true end
    end
    if changed then NS:Fire("STEPS_AUTOCOMPLETED") end
    -- 2) let optimizer order the upcoming window
    local window = NS.db.profile.routing.window or 10
    local upcoming = P.Pending(window + 5)
    if NS.Router and NS.db.profile.routing.enabled and NS.db.profile.routing.reorder then
        upcoming = NS.Router.OrderSteps(upcoming) or upcoming
    end
    P.order = upcoming
    local newcur = upcoming[1]
    if newcur ~= P.current then
        P.current = newcur
        NS:Fire("STEP_CHANGED", newcur)
    end
    NS:Fire("PROGRESS_REFRESHED")
    if not newcur and P.guide then
        -- pick what to run next: the authored chain if it still fits our level,
        -- else the most optimal leveling guide for our level + position
        local nxt = P.guide.next and G.registry[P.guide.next]
        if nxt and nxt.maxlevel and U.PlayerLevel() > nxt.maxlevel + 0.9 then nxt = nil end
        local eta
        if not nxt then nxt, eta = G.SuggestNext(P.guide.id) end
        if nxt and nxt.id ~= P.guide.id then
            local where = eta and (" (~%dm away)"):format(math.max(1, math.floor(eta / 60 + 0.5))) or ""
            NS:Print("Guide finished. Loading next: " .. nxt.name .. where)
            P.Load(nxt.id)
        end
    end
end

function P.Upcoming(n) local out = {} for i = 1, math.min(n or 6, P.order and #P.order or 0) do out[i] = P.order[i] end return out end

-- ---------------------------------------------------------------------------
-- Events that can complete steps
-- ---------------------------------------------------------------------------
local function refreshSoon() NS:Throttle("progress", 0.3, function() P.Refresh() end) end
for _, e in ipairs({ "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_REMOVED", "UNIT_QUEST_LOG_CHANGED", "BAG_UPDATE_DELAYED",
    "ZONE_CHANGED", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED_INDOORS", "PLAYER_LEVEL_UP", "PLAYER_ENTERING_WORLD", "PLAYER_CONTROL_GAINED", "MERCHANT_SHOW", "PLAYER_REGEN_ENABLED" }) do
    NS:RegisterEvent(e, refreshSoon)
end
NS:RegisterEvent("HEARTHSTONE_BOUND", function()
    for _, s in ipairs(P.Pending(15)) do if s.action == "h" then s.bindDone = true break end end
    refreshSoon()
end)
NS:RegisterEvent("CONFIRM_BINDER", function() end)
NS:RegisterEvent("TAXIMAP_OPENED", function()
    for _, s in ipairs(P.Pending(15)) do if s.action == "f" then s.taxiDone = true break end end
    refreshSoon()
end)
NS:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spellID)
    if unit ~= "player" then return end
    if spellID == NS.HEARTH_SPELL or spellID == NS.ASTRAL_RECALL then
        for _, s in ipairs(P.Pending(15)) do if s.action == "H" then charDone()[s.index] = true break end end
        refreshSoon()
    end
end)
-- position-based checks (R steps) — light poll
local acc = 0
NS.eventFrame:SetScript("OnUpdate", function(_, el)
    acc = acc + el
    if acc < 1.0 then return end
    acc = 0
    if not P.current then return end
    local a = P.current.action
    if a == "R" or a == "F" or a == "b" or a == "J" or a == "H" or a == "D" then if P.CheckStep(P.current) then P.MarkDone(P.current) end end
    NS:Fire("TICK")
end)

local function autoload(attempt)
    local ok, err = pcall(function()
        local id = NS.db.char.guide
        if id and G.registry[id] then P.Load(id) return end
        local s = G.Suggest()
        if s then P.Load(s.id)
        elseif attempt < 3 then NS:After(6, function() autoload(attempt + 1) end)  -- adapters may still be importing
        else NS:Print("No guide matched your level/faction. /or guides") end
    end)
    if not ok then
        NS.db.char.lastAutoloadError = tostring(err)
        NS:Error("autoload failed: " .. tostring(err))
        if attempt < 3 then NS:After(6, function() autoload(attempt + 1) end) end
    end
end
NS:On("PLAYER_READY", function()
    NS:After(2, function() autoload(1) end)
    NS:After(25, function() if NS.RunVerify then pcall(NS.RunVerify, true) end end)
end)
