-- CompletionRoute :: tools/vplayer.lua — the virtual player.
--
-- route_sweep.lua asks "can the router reach step 1 and is the order legal?".  This asks the harder
-- question: *if a character actually played this guide, would it finish?*  It runs the REAL addon
-- (Core/Progress, Routing/Router, Core/Farm...) against a mutable fake world, and for every guide it
--   walks to the current step (Router.TravelSecondsFromPlayer, then teleports the player onto it),
--   performs the step's action against the world (accept -> quest in log, complete -> objectives
--   finished, turn-in -> quest flagged complete, buy/loot -> bags, L -> level, h/f -> bind/taxi),
--   and lets Progress.Refresh() auto-advance exactly the way it does in the client.
-- A step that does NOT tick after its own action was performed is a real bug (a "stall") and is
-- written out with its action, title and quest id.  Steps the client can never auto-tick (N/M/=/r/$)
-- are counted separately as "manual" — in game those are the ones you press the arrow for.
--
-- Why: it replaces "level a character through 9,519 guides" with a few minutes of CPU, and it keeps
-- working after the subscription lapses.  It does NOT replace in-game checks of the UI/API surface.
--
-- Usage:  luajit tools/vplayer.lua <era|tbc|mop|retail> [--limit N] [--shard i/n] [--type Leveling]
--                                  [--guide ID] [--faction Horde] [--guidecap 20] [--out PATH]
-- Then:   python3 tools/collect_vplayer.py   (folds the TSVs into docs/verification.sqlite)
package.path = "./?.lua;" .. package.path

local flavor = arg[1] or "era"
local limit, shardI, shardN, onlyType, onlyGuide, forceFaction, guideCap, outPath = math.huge, 1, 1, nil, nil, nil, 90, nil
local verbose = false
for i = 2, #arg do
    local a = arg[i]
    if a == "--limit" then limit = tonumber(arg[i + 1])
    elseif a == "--shard" then shardI, shardN = arg[i + 1]:match("(%d+)/(%d+)") shardI, shardN = tonumber(shardI), tonumber(shardN)
    elseif a == "--type" then onlyType = arg[i + 1]
    elseif a == "--guide" then onlyGuide = arg[i + 1]
    elseif a == "--faction" then forceFaction = arg[i + 1]
    elseif a == "--guidecap" then guideCap = tonumber(arg[i + 1])
    elseif a == "--out" then outPath = arg[i + 1]
    elseif a == "--verbose" then verbose = true end
end
outPath = outPath or ("docs/vplayer_" .. flavor .. (shardN > 1 and ("_" .. shardI) or "") .. ".tsv")
local stallPath = outPath:gsub("%.tsv$", "") .. "_stalls.tsv"

local TOC = { era = 11507, tbc = 20506, mop = 50504, retail = 120100 }
local TAXI = { era = "Data/Taxi_era.lua", tbc = "Data/Taxi_tbc.lua", mop = "Data/Taxi_mop.lua", retail = "Data/Taxi_retail.lua" }

-- ---------------------------------------------------------------------------
-- The fake world (mutable — this is what makes it a player and not a sweep)
-- ---------------------------------------------------------------------------
local W = { quests = {}, objectives = {}, bags = {}, level = 1, xp = 0, xpmax = 100, bind = "Northshire Abbey", taxi = {} }
local function wipeWorld(level)
    W.quests, W.objectives, W.bags, W.taxi = {}, {}, {}, {}
    W.level, W.xp = level or 1, 0
end

STUB_MAPS = dofile("tools/maps_" .. flavor .. ".lua")
local ADDON, NS = "CompletionRoute", {}
dofile("tools/stubs.lua")
function GetBuildInfo() return "x", "0", "2026", TOC[flavor] end

local FACTION, CLASS, RACE = "Alliance", "WARRIOR", "Human"
function UnitFactionGroup() return FACTION end
function UnitClass() return CLASS:sub(1, 1) .. CLASS:sub(2):lower(), CLASS end
function UnitRace() return RACE, RACE end
function UnitLevel() return W.level end
function UnitXP() return W.xp end
function UnitXPMax() return W.xpmax end
function GetBindLocation() return W.bind end

-- Quest log / bags come from W, not from a constant
C_QuestLog = {
    IsOnQuest = function(q) local s = W.quests[q] return s == "log" or s == "complete" end,
    IsQuestFlaggedCompleted = function(q) return W.quests[q] == "done" end,
    IsComplete = function(q) return W.quests[q] == "complete" end,
    GetLogIndexForQuestID = function(q) local s = W.quests[q] return (s == "log" or s == "complete") and 1 or nil end,
    GetQuestObjectives = function(q) return W.objectives[q] or {} end,
    GetAllCompletedQuestIDs = function()
        local t = {} for q, s in pairs(W.quests) do if s == "done" then t[#t + 1] = q end end return t
    end,
    GetTitleForQuestID = function() return nil end,
}
C_Item = {
    GetItemCount = function(id) return W.bags[id] or 0 end,
    GetItemNameByID = function(id) return "item" .. tostring(id) end,
    GetItemIconByID = function() return "" end,
}
function GetItemCount(id) return W.bags[id] or 0 end

-- ---------------------------------------------------------------------------
-- Position
-- ---------------------------------------------------------------------------
PLAYER = { map = next(MAPS), x = 0.5, y = 0.5 }
local function place(map, x, y)
    if not map then return false end
    local wx, wy, inst = z2w(x, y, map)
    if not wx then return false end
    PLAYER.map, PLAYER.x, PLAYER.y, PLAYER.wx, PLAYER.wy, PLAYER.inst = map, x, y, wx, wy, inst
    return true
end
place(next(MAPS), 0.5, 0.5)

-- ---------------------------------------------------------------------------
-- Load the addon exactly as route_sweep does
-- ---------------------------------------------------------------------------
local function load(path)
    local f = io.open("CompletionRoute/" .. path, "r")
    if not f then io.stderr:write("skip " .. path .. "\n") return end
    f:close()
    assert(loadfile("CompletionRoute/" .. path))(ADDON, NS)
end
for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", TAXI[flavor], "Data/Transit.lua", "Data/Access.lua",
    "Data/Inns.lua", "Data/ZoneAliases.lua", "Data/Roads_ek.lua", "Data/Roads_kalimdor.lua",
    "Routing/TravelGraph.lua", "Routing/Roads.lua", "Routing/StepOrder.lua", "Routing/Router.lua", "Routing/Loop.lua",
    "Core/Account.lua", "Core/Progress.lua", "Core/Farm.lua", "Core/Instances.lua", "Data/Farm_routes.lua",
    "Adapters/Zygor.lua", "Adapters/WoWPro.lua",
    "Guides/Imported_Zygor.lua", "Guides/Imported_WoWPro.lua",
    "Guides/Imported_Quests_era.lua", "Guides/Imported_Quests_tbc.lua", "Guides/Imported_Quests_wotlk.lua",
    "Guides/Imported_Quests_cata.lua", "Guides/Imported_Quests_mop.lua", "Guides/Imported_Quests_retail.lua" }) do load(f) end
CompletionRouteDB, CompletionRouteCharDB = nil, nil
for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", "CompletionRoute") end
NS.db.profile.debug = false
NS.Print, NS.Debug, NS.Error = function() end, function() end, function() end
pcall(NS.Adapters.Zygor.ImportStatic)
pcall(NS.Adapters.WoWPro.ImportStatic)
NS.TravelGraph.Build()

local G, P, R, U, Cond = NS.Guide, NS.Progress, NS.Router, NS.Util, NS.Cond

-- Progress.Refresh chains into the next guide when one finishes.  For a per-guide run that would
-- parse a second guide and confuse the row, so the chain is disabled and the switch is what tells
-- us the guide completed.
G.SuggestNext = function() return nil end
G.Suggest = function() return nil end

-- ---------------------------------------------------------------------------
-- Acting on a step
-- ---------------------------------------------------------------------------
-- Can the client EVER auto-complete this step?  Progress.CheckStep only ticks a step when the step
-- carries the data the check needs: an accept without |QID|, a "Kill Kresh" with neither QID nor |L|
-- loot, an |R| with no coords and no zone can never tick — in game you press the forward arrow, the
-- same as in Zygor.  Judging by the action letter alone reported those as bugs, which they are not.
-- Returns true (auto) or false plus the reason it can only ever be manual.
local function autoable(step)
    local a = step.action
    if a == "A" or a == "a" or a == "!" then
        if step.qid then return true end return false, "accept without QID"
    elseif a == "C" or a == "K" or a == "l" then
        if step.qid or step.loot then return true end return false, "objective without QID or loot"
    elseif a == "T" or a == "t" then
        if step.qid then return true end return false, "turn-in without QID"
    elseif a == "U" then
        if step.item or step.qid then return true end return false, "use without item or QID"
    elseif a == "B" then
        if step.loot then return true end return false, "buy without loot list"
    elseif a == "L" then
        if step.minlevel then return true end return false, "level step without a level"
    elseif a == "R" or a == "G" or a == "F" or a == "b" or a == "J" or a == "H" or a == "D" then
        if step.coords or step.zone then return true end return false, "travel step without coords or zone"
    elseif a == "h" or a == "f" then
        return true
    end
    return false, "note-class step (" .. a .. ")"
end

local function finishObjectives(q)
    local objs = W.objectives[q]
    if not objs or #objs == 0 then objs = { { numFulfilled = 1, numRequired = 1, finished = true, text = "obj" } } W.objectives[q] = objs end
    for _, o in ipairs(objs) do o.finished = true o.numFulfilled = o.numRequired or 1 end
end

-- Move the player onto the step (this is the "walking" part).  Returns yards, seconds, routed.
local function walkTo(step)
    local secs = nil
    local ok, v = pcall(R.TravelSecondsFromPlayer, step)
    if ok then secs = v end
    local yards = 0
    local tx, ty, ti = R.StepWorld(step)
    if tx and PLAYER.wx and ti == PLAYER.inst then
        yards = math.sqrt((tx - PLAYER.wx) ^ 2 + (ty - PLAYER.wy) ^ 2)
    end
    -- teleport onto the step so the position-driven checks (R/G/F/b/J/H/D) can see us there
    if step.zone and MAPS[step.zone] then
        local c = step.coords and step.coords[1]
        place(step.zone, c and c.x or 0.5, c and c.y or 0.5)
    end
    return yards, secs, (secs ~= nil)
end

local function act(step)
    local a = step.action
    if a == "A" or a == "a" or a == "!" then
        for _, q in ipairs(step.qid or {}) do if W.quests[q] ~= "done" then W.quests[q] = "log" end end
    elseif a == "C" or a == "K" or a == "l" then
        for _, q in ipairs(step.qid or {}) do
            if W.quests[q] ~= "done" then W.quests[q] = "complete" finishObjectives(q) end
        end
        for _, l in ipairs(step.loot or {}) do W.bags[l.id] = math.max(W.bags[l.id] or 0, l.qty or 1) end
    elseif a == "T" or a == "t" then
        for _, q in ipairs(step.qid or {}) do W.quests[q] = "done" W.objectives[q] = nil end
        W.xp = W.xp + 25
        if W.xp >= W.xpmax then W.xp, W.level = 0, W.level + 1 end
    elseif a == "U" then
        if step.item then
            W.bags[step.item] = 1
            pcall(P.CheckStep, step)     -- lets CheckStep latch step.hadItem
            W.bags[step.item] = nil
        end
        for _, q in ipairs(step.qid or {}) do if W.quests[q] ~= "done" then W.quests[q] = "complete" finishObjectives(q) end end
    elseif a == "B" then
        for _, l in ipairs(step.loot or {}) do W.bags[l.id] = math.max(W.bags[l.id] or 0, l.qty or 1) end
    elseif a == "L" then
        if step.minlevel then W.level = math.max(W.level, step.minlevel) W.xp = 0 end
    elseif a == "h" then
        step.bindDone = true
        W.bind = step.zoneName or step.title
    elseif a == "f" then
        step.taxiDone = true
    end
    -- generic: an objective-bearing step that named loot also fills the bag
    if step.loot and a ~= "B" and a ~= "C" and a ~= "K" and a ~= "l" then
        for _, l in ipairs(step.loot) do W.bags[l.id] = math.max(W.bags[l.id] or 0, l.qty or 1) end
    end
end

-- Some steps are gated by |LVL|: with the player parked at the guide's min level they are simply
-- never "pending" and the guide would look finished while skipping them.  Raise the level to the
-- lowest gate that is still holding a step back.
local function levelGateBump()
    if not P.steps then return false end
    local lowest
    for _, s in ipairs(P.steps) do
        if not P.IsDone(s) and s.minlevel and W.level < s.minlevel and s.action ~= "L" then
            local saved = W.level
            W.level = s.minlevel
            local applies = Cond.StepApplies(s)
            W.level = saved
            if applies and (not lowest or s.minlevel < lowest) then lowest = s.minlevel end
        end
    end
    if lowest then W.level = lowest return true end
    return false
end

-- ---------------------------------------------------------------------------
-- Play one guide
-- ---------------------------------------------------------------------------
local stallOut
local function playGuide(g)
    local id = g.id
    local steps = G.Steps(id)
    if not steps or #steps == 0 or g.empty then return nil end

    FACTION = (g.faction == "Horde") and "Horde" or "Alliance"
    NS.player.faction, NS.player.class, NS.player.race = FACTION, CLASS, RACE
    wipeWorld(math.max(1, tonumber(g.minlevel) or 1))
    NS.db.char.done, NS.db.char.skipped, NS.db.char.reopened, NS.db.char.laps, NS.db.char.guide = {}, {}, {}, {}, nil
    R.Invalidate()
    NS.TravelGraph.Build()

    -- start where a player would: the guide's own zone
    local zone = g.zone
    if not zone then for _, s in ipairs(steps) do if s.zone then zone = s.zone break end end end
    local placed = zone and MAPS[zone] and place(zone, 0.5, 0.5) or false

    local row = { steps = #steps, sim = 0, auto = 0, manual = 0, stalls = 0, forced = 0, laps = 0,
                  yards = 0, seconds = 0, noroute = 0, finished = 0, err = "", reasons = {} }
    local laps = 0
    local lapHook = function() laps = laps + 1 end
    NS:On("LAP_COMPLETE", lapHook)

    local ok, err = pcall(function()
        if not P.Load(id) then error("Load returned false") end
        local cap = math.min(#steps * 3 + 60, 4000)
        local t0 = os.clock()
        local guard = 0
        while guard < cap do
            guard = guard + 1
            if os.clock() - t0 > guideCap then row.err = "guide time cap" break end
            if P.guide == nil or P.guide.id ~= id then break end          -- chained away = finished
            if g.loop and laps >= 2 then row.finished = 1 break end       -- circuits never end: two laps is a pass
            local step = P.current
            if not step then
                if levelGateBump() then P.Refresh() end
                if not P.current then row.finished = 1 break end
                step = P.current
            end

            local y, s, routed = walkTo(step)
            row.yards = row.yards + (y or 0)
            row.seconds = row.seconds + (s or 0)
            if not routed then row.noroute = row.noroute + 1 end

            act(step)
            P.Refresh()
            row.sim = row.sim + 1

            local still = P.current
            if still == step then
                -- the action was performed and the step did not tick
                local canAuto, why = autoable(step)
                if canAuto then
                    row.stalls = row.stalls + 1
                    if stallOut and row.stalls <= 40 then
                        stallOut:write(table.concat({ NS.flavor, id, step.index, step.action,
                            (step.title or ""):gsub("\t", " "):sub(1, 90), tostring(step.qid and step.qid[1] or ""),
                            tostring(step.zone or ""), tostring(step.coords and "coords" or "nocoords") }, "\t") .. "\n")
                    end
                else
                    row.manual = row.manual + 1
                    row.reasons[why] = (row.reasons[why] or 0) + 1
                end
                P.MarkDone(step)
                row.forced = row.forced + 1
            else
                row.auto = row.auto + 1
            end
        end
        if guard >= cap and row.err == "" then row.err = "step cap" end
    end)
    if not ok then row.err = tostring(err):gsub("\t", " ") end

    -- unhook the lap counter
    for i, fn in ipairs(NS.callbacks.LAP_COMPLETE or {}) do if fn == lapHook then table.remove(NS.callbacks.LAP_COMPLETE, i) break end end
    row.laps = laps
    row.placed = placed
    return row
end

-- ---------------------------------------------------------------------------
-- Run
-- ---------------------------------------------------------------------------
local out = assert(io.open(outPath, "w"))
out:write("flavor\tguide\tname\ttype\tfaction\tzone\tzone_name\tsteps\tsimulated\tauto\tmanual\tstalls\tforced\tlaps\tyards\tseconds\tno_route\tfinished\tmanual_reason\terror\n")
stallOut = assert(io.open(stallPath, "w"))
stallOut:write("flavor\tguide\tstep\taction\ttitle\tqid\tzone\tcoords\n")

io.stderr:write(("vplayer %s: %d guides registered, shard %d/%d\n"):format(NS.flavor, #G.list, shardI, shardN))
local n, finished, stalled, errored = 0, 0, 0, 0
local t0 = os.clock()
for gi, id in ipairs(G.list) do
    if n >= limit then break end
    if (gi % shardN) == (shardI % shardN) then
        local g = G.registry[id]
        local typeOK = (not onlyType) or (G.NormalizeType(g.type) == onlyType)
        local guideOK = (not onlyGuide) or id == onlyGuide
        local facOK = (not forceFaction) or not g.faction or g.faction == forceFaction
        if typeOK and guideOK and facOK then
            local row = playGuide(g)
            if row then
                n = n + 1
                if row.finished == 1 then finished = finished + 1 end
                if row.stalls > 0 then stalled = stalled + 1 end
                if row.err ~= "" then errored = errored + 1 end
                local zname = g.zone and MAPS[g.zone] and MAPS[g.zone][1] or ""
                local topReason, topN = "", 0
                for why, c in pairs(row.reasons) do if c > topN then topReason, topN = why, c end end
                out:write(table.concat({ NS.flavor, id, (g.name or ""):gsub("\t", " "), G.NormalizeType(g.type), g.faction or "Both",
                    tostring(g.zone or ""), zname, row.steps, row.sim, row.auto, row.manual, row.stalls, row.forced, row.laps,
                    ("%.0f"):format(row.yards), ("%.0f"):format(row.seconds), row.noroute, row.finished, topReason, row.err }, "\t") .. "\n")
                if verbose or n % 100 == 0 then
                    io.stderr:write(("%d guides %.0fs  finished=%d stalled=%d err=%d  last=%s\n"):format(n, os.clock() - t0, finished, stalled, errored, id))
                    out:flush() stallOut:flush()
                end
            end
        end
    end
end
out:close() stallOut:close()
io.stderr:write(("DONE %s shard %d/%d: %d guides in %.0fs -> %s | finished=%d stalled-guides=%d errors=%d\n")
    :format(flavor, shardI, shardN, n, os.clock() - t0, outPath, finished, stalled, errored))
