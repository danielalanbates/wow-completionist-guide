-- CompletionRoute :: Core/Progress.lua
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
    if NS.Account and NS.Account.me then return NS.Account.Done(P.guide.id) end
    local c = NS.db.char
    c.done[P.guide.id] = c.done[P.guide.id] or {}
    return c.done[P.guide.id]
end
-- Steps the player manually stepped BACK to. Auto-completion must not immediately re-tick them,
-- otherwise the Back arrow looks like it does nothing (the quest is still complete in the game).
local function charReopened()
    local c = NS.db.char
    c.reopened = c.reopened or {}
    c.reopened[P.guide.id] = c.reopened[P.guide.id] or {}
    return c.reopened[P.guide.id]
end
local function charSkipped()
    if NS.Account and NS.Account.me then return NS.Account.Skipped(P.guide.id) end
    local c = NS.db.char
    c.skipped[P.guide.id] = c.skipped[P.guide.id] or {}
    return c.skipped[P.guide.id]
end

function P.Load(id)
    local g = G.registry[id]
    if not g then NS:Error("Unknown guide: " .. tostring(id)) return false end
    P.guide = g
    -- Gold guides are routes, not checklists: fold one into a circuit before its steps are read
    -- (Core/Farm.lua Circuitize). Turn it off with /cr farm circuit, or per guide with /cr farm uncircuit.
    if g.type == "Gold" and not g.loop and not g.noCircuit and NS.db.profile.farm and NS.db.profile.farm.circuitizeGold then
        local ok, res, n = pcall(NS.Farm.Circuitize, g)
        if ok and res then NS:Print(("Gold guide folded into a %d-stop circuit - just follow it, nothing to click."):format(n))
        else g.noCircuit = true NS:Debug("circuitize " .. id .. ": " .. tostring(res or n)) end
    end
    P.steps = G.Steps(id)
    -- Behind a locked access chain (Siren Isle, Argus, Zereth Mortis...)? Put the unlock steps first, the way
    -- comprehensive zone guides open with the zone intro. Negative indices keep the guide's own progress keys intact.
    local prefix = NS.Access and NS.Access.PrefixFor(P.steps, id)
    if prefix and #prefix > 0 then
        local merged = {}
        for _, s in ipairs(prefix) do merged[#merged + 1] = s end
        for _, s in ipairs(P.steps) do merged[#merged + 1] = s end
        P.steps = merged
        NS:Print(("Access: %d steps to unlock %s first"):format(#prefix, prefix[1].accessTitle or "the area"))
    end
    NS.db.char.guide = id
    dirty = true
    P.cursor = nil
    NS:Print("Guide: " .. (g.name or g.id) .. " (" .. #P.steps .. " steps, from " .. (g.source or "?") .. ")")
    P.Refresh()
    if g.loop then
        if NS.Farm and NS.Farm.OnLoad then pcall(NS.Farm.OnLoad, g) end
        P.StartAtNearest()
    end
    NS:Fire("GUIDE_LOADED", g)
    return true
end

function P.IsDone(step)
    if charReopened()[step.index] then return false end
    if charDone()[step.index] or charSkipped()[step.index] then return true end
    -- opt-in: a step another character already finished counts as done for this one
    if NS.Account and NS.Account.Enabled() and P.guide then
        if NS.Account.OtherDid(P.guide.id, step.index) then return true end
        -- quest IDs line up across guides; step indices only line up inside one guide
        if step.qid and NS.Account.OtherDidQuest(step.qid) then return true end
    end
    return false
end
function P.MarkDone(step, manual)
    if not step then return end
    charReopened()[step.index] = nil
    charDone()[step.index] = true
    if (step.action == "T" or step.action == "t") and step.qid and NS.Account then
        for _, q in ipairs(step.qid) do NS.Account.RecordQuest(q) end
    end
    dirty = true
    NS:Debug("done: " .. step.action .. " " .. step.title)
    NS:Fire("STEP_DONE", step)
    P.Refresh()
end
function P.Skip(step) if step then charReopened()[step.index] = nil charSkipped()[step.index] = true dirty = true P.Refresh() end end
-- Back one step: reopen the newest done/skipped step that sits BEFORE the current one.  The look-ahead
-- auto-completer ticks steps up to 40 ahead, so "the highest done index" is often a future step; using it
-- made Back appear to do nothing.  Reopened steps are pinned (see charReopened) until ticked forward again.
function P.Undo()
    local d, s = charDone(), charSkipped()
    local limit = P.current and P.current.index or math.huge
    local best
    local function consider(idx) if idx < limit and (not best or idx > best) then best = idx end end
    for idx in pairs(d) do consider(idx) end
    for idx in pairs(s) do consider(idx) end
    if not best then   -- nothing before the current step: fall back to the newest done step anywhere
        for idx in pairs(d) do if not best or idx > best then best = idx end end
        for idx in pairs(s) do if not best or idx > best then best = idx end end
    end
    if not best then return end
    charReopened()[best] = true
    P.cursor = nil
    d[best] = nil s[best] = nil
    if NS.Account and NS.Account.me and P.guide then
        local ad, as = NS.Account.Done(P.guide.id), NS.Account.Skipped(P.guide.id)
        if ad then ad[best] = nil end
        if as then as[best] = nil end
    end
    dirty = true
    P.Refresh()
end
-- Forward one step by hand (same as the arrow): tick the current step done.
function P.Forward() if P.current then P.MarkDone(P.current, true) end end
function P.Reset()
    if not P.guide then return end
    if NS.Account and NS.Account.me then
        NS.Account.me.done[P.guide.id] = {}
        NS.Account.me.skipped[P.guide.id] = {}
    end
    NS.db.char.done[P.guide.id] = {}
    NS.db.char.skipped[P.guide.id] = {}
    if NS.db.char.reopened then NS.db.char.reopened[P.guide.id] = {} end
    dirty = true
    P.cursor = nil
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
    elseif a == "G" then
        -- farm waypoint: nothing to click, you complete it by standing there
        if step.coords then if nearCoords(step, step.radius or (NS.db.profile.farm and NS.db.profile.farm.radius) or 40) then return true end
        elseif inZone(step) then return true end
    elseif a == "R" then
        if step.coords then if nearCoords(step, 30) then return true end
        elseif inZone(step) then return true end
    elseif a == "P" then
        -- Portal step: completed if the player has entered the destination zone, OR is within portal range
        local map = U.PlayerPos()
        if step.zone and map and map ~= step.zone then
            local targetMap = step.title and U.MapIDByName(step.title)
            if not targetMap or map == targetMap or inZone({ zone = targetMap }) then
                return true
            end
        end
        if step.coords and nearCoords(step, 30) then return true end
    elseif a == "F" or a == "b" or a == "J" or a == "H" or a == "D" then
        if step.coords then if nearCoords(step, 60) then return true end
        elseif step.zone and inZone(step) then return true end
    elseif a == "L" then
        if step.minlevel and U.PlayerLevel() >= step.minlevel then return true end
    elseif a == "U" then
        if step.item and step.hadItem and U.ItemCount(step.item) == 0 then return true end
        if step.item and U.ItemCount(step.item) > 0 then step.hadItem = true end
        if step.qid then
            if anyQuestDone(step.qid, U.IsQuestComplete) then return true end
            -- Imported "use" lines complete on quest objective progress (their |q qid/obj goal),
            -- not on turn-in: mirror the C branch
            for _, q in ipairs(step.qid) do
                if U.IsOnQuest(q) then
                    local _, complete = U.QuestLogState(q)
                    if complete then return true end
                    local oi = tonumber(step.qo)
                    if oi then
                        local f, r, fin = U.QuestObjective(q, oi)
                        if fin or (r and r > 0 and f >= r) then return true end
                    elseif U.AllObjectivesDone(q) then return true end
                end
            end
        end
        if step.loot then
            local ok = true
            for _, l in ipairs(step.loot) do if U.ItemCount(l.id) < l.qty then ok = false end end
            if ok then return true end
        end
    elseif a == "B" then
        if step.loot then local ok = true for _, l in ipairs(step.loot) do if U.ItemCount(l.id) < l.qty then ok = false end end if ok then return true end end
    elseif a == "h" then
        if step.bindDone then return true end
    elseif a == "f" then
        if step.taxiDone then return true end
    end
    -- achievement steps (tools/gen_completion_guides.py): done when the client says the achievement,
    -- or the named criteria-tree node, is earned.  Clients without achievements answer nil -> manual.
    if step.ach and U.AchievementDone(step.ach, step.achCrit) then return true end
    -- generic: quest already complete => step obsolete
    if step.qid and (a ~= "A" and a ~= "a") and anyQuestDone(step.qid, U.IsQuestComplete) then return true end
    return false
end

-- ---------------------------------------------------------------------------
-- Ordering / current step
-- ---------------------------------------------------------------------------
-- pending = applicable, not done steps in guide order
-- The leading run of finished steps is skipped with a cursor.  Refresh calls this up to 25 times per
-- pass, and a retail zone guide is ~1,800 steps: without the cursor every call re-walks the whole
-- completed prefix, which is quadratic in the guide and hitches the client late in a long guide.
-- Only DONE steps advance the cursor - a step can be inapplicable now (level gate, PRE quest) and
-- applicable later, so those must stay in front of it.  Anything that un-completes a step resets it.
function P.Pending(limit)
    local out = {}
    if not P.steps then return out end
    local i = P.cursor or 1
    while i <= #P.steps and P.IsDone(P.steps[i]) do i = i + 1 end
    P.cursor = i
    for k = i, #P.steps do
        local s = P.steps[k]
        if not P.IsDone(s) and Cond.StepApplies(s) then
            out[#out + 1] = s
            if limit and #out >= limit then break end
        end
    end
    return out
end

function P.Refresh(force)
    if not P.guide then return end
    -- Pending's cursor assumes a step never un-completes without one of the paths below clearing it.
    -- Changing the completion scope (Options: character/realm/flavor/account) can un-complete steps
    -- anywhere in the guide, so notice that here rather than trust every caller to remember.
    local scope, acc = NS.db.profile.scope, NS.db.profile.accountWide
    if P.scopeSeen ~= scope or P.accSeen ~= acc then
        P.scopeSeen, P.accSeen, P.cursor = scope, acc, nil
    end
    -- 1) auto-complete anything already satisfied (scan a window ahead so obsolete steps vanish)
    local changed, passes, wp = false, 0, 0
    repeat
        local any = false
        local reopened = charReopened()
        for i, s in ipairs(P.Pending(40)) do
            -- Farm waypoints only tick when they are the step you are actually walking to, and only ONE
            -- per refresh: a circuit loops back on itself, so waypoints inside the radius would otherwise
            -- cascade and swallow the whole lap (leaving the player with no current step at all).
            local skip = (s.action == "G") and (i > 1 or wp > 0)
            if not reopened[s.index] and not skip and P.CheckStep(s) then
                charDone()[s.index] = true any = true
                if s.action == "G" then wp = wp + 1 end
            end
        end
        changed = changed or any
        passes = passes + 1
    until not any or passes >= 25   -- a guide picked up mid-way can have hundreds of already-done steps
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
    if not newcur and P.guide and P.guide.loop then
        -- Farm circuits never "finish": wipe the lap and start the loop again from the nearest waypoint.
        if not P.inLap then
            P.inLap = true
            local ok, err = pcall(P.NewLap)
            P.inLap = nil
            if not ok then NS:Error("lap restart failed: " .. tostring(err)) end
        end
        return
    end
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

-- ---------------------------------------------------------------------------
-- Farm circuits (guide.loop): the route repeats forever, no clicking, no completion screen
-- ---------------------------------------------------------------------------
-- Clear the lap and hand the lap to Farm for its stats, then start again at the nearest waypoint.
function P.NewLap()
    if not P.guide then return end
    local id = P.guide.id
    NS.db.char.laps = NS.db.char.laps or {}
    NS.db.char.laps[id] = (NS.db.char.laps[id] or 0) + 1
    if NS.Farm and NS.Farm.OnLapComplete then pcall(NS.Farm.OnLapComplete, P.guide) end
    if NS.Account and NS.Account.me then
        NS.Account.me.done[id] = {}
        NS.Account.me.skipped[id] = {}
    end
    NS.db.char.done[id] = {}
    NS.db.char.skipped[id] = {}
    if NS.db.char.reopened then NS.db.char.reopened[id] = {} end
    dirty = true
    P.cursor = nil
    NS:Fire("LAP_COMPLETE", P.guide, NS.db.char.laps[id])
    P.Refresh()
    P.StartAtNearest()
end

-- A circuit is a closed loop, so any waypoint is a legal start: tick off the ones behind us so the
-- player walks the shortest way onto the ring instead of back to the author's first node.
function P.StartAtNearest()
    if not (P.guide and P.guide.loop and P.steps and #P.steps > 0 and NS.Router) then return end
    local _, _, _, pinst, pwx, pwy = U.PlayerPos()
    if not pwx then return end
    local best, bestd
    for i, s in ipairs(P.steps) do
        local tx, ty, ti = NS.Router.StepWorld(s)
        if tx and ti == pinst then
            local d = math.sqrt((tx - pwx) ^ 2 + (ty - pwy) ^ 2)
            if not bestd or d < bestd then best, bestd = i, d end
        end
    end
    if not best then return end
    -- Standing on the nearest waypoint (which is what happens the instant a lap closes) would tick it,
    -- then the next, and the ring would eat itself: aim at the one AFTER it instead.
    local radius = (P.steps[best].radius) or (NS.db.profile.farm and NS.db.profile.farm.radius) or 40
    if bestd <= radius then best = best % #P.steps + 1 end
    local done = charDone()
    for i = 1, #P.steps do done[P.steps[i].index] = (i < best) or nil end
    dirty = true
    P.cursor = nil
    P.Refresh()
end

function P.Lap(id) return (NS.db.char.laps or {})[id or (P.guide and P.guide.id)] or 0 end

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
    if a == "G" or a == "R" or a == "F" or a == "b" or a == "J" or a == "H" or a == "D" then if P.CheckStep(P.current) then P.MarkDone(P.current) end end
    NS:Fire("TICK")
end)

local function autoload(attempt)
    local ok, err = pcall(function()
        local id = NS.db.char.guide
        if id and G.registry[id] then P.Load(id) return end
        local s = G.SuggestNext(nil) or G.Suggest()  -- location-aware pick at login too
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
    -- feature matrix for the SQL chart; silent, results live in CompletionRouteDB.featureVerify
    NS:After(30, function() if NS.RunFeatureVerify then pcall(NS.RunFeatureVerify, true) end end)
    -- File-driven verification pathway: set CompletionRouteDB.autoVerifyAll = true in the
    -- SavedVariables before launching and the client sweeps every guide by itself, then clears
    -- the flag. Far more reliable than typing a slash command through synthetic keystrokes.
    NS:After(40, function()
        if CompletionRouteDB and CompletionRouteDB.autoDemo and NS.Beacon then
            CompletionRouteDB.autoDemo = nil
            pcall(NS.Beacon.Demo)
        end
    end)
    -- Probe: the client's truth about map instances and which transit edges resolved, written to
    -- CompletionRouteDB.probe so an offline reader can compare with tools/maps_<flavor>.lua (no typing needed).
    NS:After(42, function()
        if not (CompletionRouteDB and NS.TravelGraph and NS.TravelGraph.Build) then return end
        local ok, err = pcall(function()
            local HBD = LibStub("HereBeDragons-2.0")
            local TG = NS.TravelGraph
            if not TG.built then TG.Build() end
            local probe = { at = date("%Y-%m-%d %H:%M:%S"), flavor = NS.flavor, nodes = #TG.nodes, unresolved = {}, maps = {} }
            for _, u in ipairs(TG.unresolved or {}) do probe.unresolved[#probe.unresolved + 1] = u end
            local ids = { 85, 84, 1, 18, 590, 582, 588, 622, 624, 1533, 1536, 1565, 1525, 1670, 2248, 2339, 2022, 2112, 862, 895, 1161, 1409,
                          627, 125, 630, 371, 390, 114, 117, 198, 201, 207, 249, 241, 245, 71, 81, 2354, 2432, 2424, 122, 1270, 14, 1244, 2257 }
            for _, id in ipairs(ids) do
                local info = C_Map.GetMapInfo(id)
                local wx, wy, inst = HBD:GetWorldCoordinatesFromZone(0.5, 0.5, id)
                probe.maps[#probe.maps + 1] = ("%d|%s|type %s|inst %s|%s"):format(id, info and info.name or "?", tostring(info and info.mapType), tostring(inst), wx and "ok" or "NO WORLD COORDS")
            end
            for _, t in ipairs(NS.TransitData or {}) do
                for _, side in ipairs({ t.from, t.to }) do
                    local m = NS.Util.MapIDByName(side[1])
                    if not m then probe.unresolved[#probe.unresolved + 1] = "zone name unknown: " .. tostring(side[1]) end
                end
            end
            CompletionRouteDB.probe = probe
        end)
        if not ok then CompletionRouteDB.probe = { error = tostring(err) } end
    end)
    -- same file-driven pathway for the route sweep and for a clean self-quit (flushes SavedVariables)
    -- file-driven circuit self test (arm CompletionRouteDB.autoFarmTest = true before launching)
    NS:After(50, function()
        if CompletionRouteDB and CompletionRouteDB.autoFarmTest and NS.Farm and NS.Farm.SelfTest then
            CompletionRouteDB.autoFarmTest = nil
            pcall(NS.Farm.SelfTest)
        end
    end)
    NS:After(45, function()
        if CompletionRouteDB and CompletionRouteDB.autoSweep and NS.RunRouteSweep then
            local resume = CompletionRouteDB.autoSweep == "resume"
            CompletionRouteDB.autoSweep = nil
            pcall(NS.RunRouteSweep, nil, resume)
        end
    end)
    if CompletionRouteDB and tonumber(CompletionRouteDB.autoQuitAfter) then
        local secs = tonumber(CompletionRouteDB.autoQuitAfter)
        CompletionRouteDB.autoQuitAfter = nil
        -- Quit()/ForceQuit()/Logout() are protected in the world (taint popup), so only mark the run as
        -- finished; the driver (tools/verify_ingame.py) quits the client from outside.
        NS:After(secs, function() CompletionRouteDB.verifyRunDone = date("%Y-%m-%d %H:%M:%S") NS:Print("verification run complete - safe to quit") end)
    end
    NS:After(35, function()
        if CompletionRouteDB and CompletionRouteDB.autoVerifyAll and NS.RunVerifyAll then
            local resume = CompletionRouteDB.autoVerifyAll == "resume"
            CompletionRouteDB.autoVerifyAll = nil
            pcall(NS.RunVerifyAll, function()
                if CompletionRouteDB.autoVerifyQuit then
                    if ForceQuit then ForceQuit() elseif Quit then Quit() end
                end
            end, resume)
        end
    end)
end)


-- ---------------------------------------------------------------------------
-- Access chains (Data/Access.lua): steps that unlock a place, injected before a guide that starts there
-- ---------------------------------------------------------------------------
NS.Access = {}
local Access = NS.Access
-- Which locked chain (if any) does the route from the player to `step` go through?
function Access.LockedChainTo(step)
    local R, TG = NS.Router, NS.TravelGraph
    if not (R and TG and step) then return nil end
    local tx, ty, ti = R.StepWorld(step)
    if not tx then return nil end
    local _, _, _, inst, wx, wy = NS.Util.PlayerPos()
    if not wx then return nil end
    if inst == ti then return nil end   -- already on that continent: nothing to unlock
    local ok, path = pcall(TG.FindPath, wx, wy, inst, tx, ty, ti, {})
    if not ok or not path then return nil end
    local chains = {}
    for _, leg in ipairs(path.legs or {}) do   -- chains stack (Midnight intro -> Silvermoon -> Eversong -> Harandar): keep route order
        if leg.mode == "access" and leg.data and leg.data.locked then chains[#chains + 1] = leg.data.access end
    end
    return chains[1], chains
end
function Access.ParseSteps(a, guideId)
    local out, n = {}, 0
    for line in ((a.steps or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        n = n + 1
        local s = NS.Guide.ParseLine(line, n, nil)
        if s then out[#out + 1] = s end
    end
    for i, s in ipairs(out) do
        s.index = i - #out - 1          -- -k .. -1
        s.guide, s.access, s.accessTitle = guideId, a.key, a.title
    end
    return out
end
function Access.PrefixFor(steps, guideId)
    if not steps or #steps == 0 or not NS.AccessData then return nil end
    local first
    for _, s in ipairs(steps) do if NS.Router.StepWorld(s) then first = s break end end
    local _, chains = Access.LockedChainTo(first)
    if not chains or #chains == 0 then return nil end
    local out = {}
    for _, a in ipairs(chains) do for _, st in ipairs(Access.ParseSteps(a, guideId)) do out[#out + 1] = st end end
    for i, st in ipairs(out) do st.index = i - #out - 1 end   -- renumber the whole prefix -k .. -1
    return out
end
