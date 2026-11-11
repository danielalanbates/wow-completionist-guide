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
-- Usage:  luajit tools/vplayer.lua <era|tbc|mop|retail|forever> [--limit N] [--shard i/n] [--type Leveling] [--guides-file F] [--spine]
--                                  [--guide ID] [--faction Horde] [--guidecap 20] [--out PATH]
--                                  [--order author|baked] [--live on|off]   (baked = Data/RouteOrder_<fl>.lua; live = 12-step window)
--                                  [--chain Alliance|Horde] [--questsperlevel 25]   (play the whole spine with the real chain logic)
--                                  [--route-order PATH]   with --order baked: load this RouteOrder file instead of
--                                                         Data/RouteOrder_<fl>.lua (the bake gate, tools/test_cost_parity.lua)
--                                  [--who warrior|plan|gate]   warrior (default) = a Human / Orc warrior levelling through
--                                                         the guide; plan = the character the bake plans for (see below);
--                                                         gate = a real character of the planning character's faction,
--                                                         class and race (a Human / Orc warrior where it has none): the
--                                                         bake gate (tools/optimize_routes.py --gate)
--                                  [--both-as Alliance|Horde]   play a guide for both factions as this faction (default:
--                                                         the planning character's faction with --who gate, else Alliance;
--                                                         not with --who plan)
--                                  [--taxi model|all|band|learn]   model (default) = the cost model's offline rule
--                                                       (Routing/CostModel.lua OFFLINE_TAXI, what the bake assumes);
--                                                       all = every flight master of the faction; band = flight masters in
--                                                       zones at or below the planning level; learn = start each guide (each
--                                                       chain) with no flight paths known, fly only into discovered ones,
--                                                       discover a flight master the route walks to and any within 40 yd of
--                                                       where the player stands (docs/VPLAYER.md)
-- Travel is priced by the cost model (docs/VPLAYER.md "Cost model"): each leg from the point of the last located step
-- to the next located step at the planning level of the step it leaves from, no hearth (an H step costs
-- CostModel.HEARTH), a leg with no route costs CostModel.NOROUTE; a step that rides along costs nothing and the
-- character stays where it is.  CR_TRACE=F writes
-- one line per visited step (index, action, quest, zone, coords, seconds, title, cost-model kind).
--                                  [--turnins]   fire QUEST_TURNED_IN at every turn-in, as the client does, and time the
--                                                handlers (graph rebuilds + the re-plan they cause); run under luajit -joff
--         luajit tools/vplayer.lua --repro <report id|latest|report.json> [--db PATH] [--check] [--show]   (replay a beta bug report)
--         luajit tools/vplayer.lua <flavor> --capture [guide id|auto] [--capture-steps N] [--capture-out F]  (make one here)
--         (tools/vplayer_repro.lua, docs/BETA_REPORTS.md)
-- Then:   python3 tools/collect_vplayer.py   (folds the TSVs into docs/verification.sqlite)
package.path = "./?.lua;" .. package.path

local flavor = arg[1] or "era"
local limit, shardI, shardN, onlyType, onlyGuide, forceFaction, guideCap, outPath = math.huge, 1, 1, nil, nil, nil, 90, nil
local verbose = false
local withSpine = false
local guideSet = nil
orderMode, liveWindow = "author", true
local chainFaction, questsPerLevel
local taxiMode = "model"
local fireTurnins = false
local routeOrderPath
local whoMode = "warrior"
local bothAs
for i = 2, #arg do
    local a = arg[i]
    if a == "--limit" then limit = tonumber(arg[i + 1])
    elseif a == "--shard" then shardI, shardN = arg[i + 1]:match("(%d+)/(%d+)") shardI, shardN = tonumber(shardI), tonumber(shardN)
    elseif a == "--type" then onlyType = arg[i + 1]
    elseif a == "--guide" then onlyGuide = arg[i + 1]
    elseif a == "--guides-file" then   -- one guide id per line (e.g. every guide that had no_route > 0)
        guideSet = {}
        for l in io.lines(arg[i + 1]) do if l ~= "" then guideSet[l] = true end end
    elseif a == "--faction" then forceFaction = arg[i + 1]
    elseif a == "--guidecap" then guideCap = tonumber(arg[i + 1])
    elseif a == "--out" then outPath = arg[i + 1]
    elseif a == "--spine" then withSpine = true   -- also load Guides/Imported_Spine_<fl>.lua (the generated leveling chain)
    elseif a == "--chain" then chainFaction = arg[i + 1] withSpine = true   -- play the whole spine for Alliance|Horde with the real chain logic
    elseif a == "--questsperlevel" then questsPerLevel = tonumber(arg[i + 1])
    elseif a == "--order" then orderMode = arg[i + 1]      -- author | baked (Data/RouteOrder_<fl>.lua, tools/optimize_routes.py)
    elseif a == "--live" then liveWindow = arg[i + 1] ~= "off" -- the 12-step live reorder window on top (default on)
    elseif a == "--taxi" then taxiMode = arg[i + 1]          -- model | all | band | learn (see the header)
    elseif a == "--route-order" then routeOrderPath = arg[i + 1]
    elseif a == "--turnins" then fireTurnins = true
    elseif a == "--who" then whoMode = arg[i + 1]          -- warrior (default) | plan | gate (see the header)
    elseif a == "--both-as" then bothAs = arg[i + 1]       -- Alliance | Horde: the faction a guide for both factions is played as
    elseif a == "--verbose" then verbose = true end
end
-- --repro / --capture: the report decides the flavor, the order mode, the live window and the spine (tools/vplayer_repro.lua)
local REPRO, reproOpts, reproReport
for i = 1, #arg do if arg[i] == "--repro" or arg[i] == "--capture" then REPRO = dofile("tools/vplayer_repro.lua") break end end
if REPRO then
    reproOpts = REPRO.ParseArgs(arg)
    if reproOpts.spec then
        reproReport = REPRO.Load(reproOpts.spec, reproOpts.db)
        if reproOpts.show then REPRO.Show(reproReport) os.exit(0) end
        flavor, orderMode, liveWindow, withSpine = REPRO.Settings(reproReport, withSpine)
    end
end
outPath = outPath or ("docs/vplayer_" .. flavor .. (shardN > 1 and ("_" .. shardI) or "") .. ".tsv")
local stallPath = outPath:gsub("%.tsv$", "") .. "_stalls.tsv"

-- forever = WoW Forever (wowf 1.60.x, Interface 16001): the era code path (NS.flavor "era", NS.isForever) on
-- Forever's own maps (tools/maps_forever.lua), taxi network, map fix and wiki/gaps guides, plus the era WoW-Pro file.
local TOC = { era = 11507, tbc = 20506, mop = 50504, retail = 120100, forever = 16001 }
local TAXI = { era = "Data/Taxi_era.lua", tbc = "Data/Taxi_tbc.lua", mop = "Data/Taxi_mop.lua", retail = "Data/Taxi_retail.lua",
               forever = "Data/Taxi_forever.lua" }
local WOWPRO = { forever = "era" }
local EXTRA = { forever = "Data/MapFix_forever.lua" }

-- ---------------------------------------------------------------------------
-- The fake world (mutable — this is what makes it a player and not a sweep)
-- ---------------------------------------------------------------------------
local W = { quests = {}, objectives = {}, bags = {}, level = 1, xp = 0, xpmax = 100, bind = "Northshire Abbey", taxi = {}, ach = {}, crit = {} }
local function wipeWorld(level)
    W.quests, W.objectives, W.bags, W.taxi, W.ach, W.crit = {}, {}, {}, {}, {}, {}
    W.level, W.xp = level or 1, 0
end

STUB_MAPS = dofile("tools/maps_" .. flavor .. ".lua")
local ADDON, NS = "CompletionRoute", {}
-- a fresh character's progress marks: by step key (Core/Account.lua stepDone / stepSkipped / stepMeta, the character
-- file's stepReopened) and the index-keyed tables of earlier releases
local function wipeMarks()
    local c = NS.db.char
    c.stepDone, c.stepSkipped, c.stepReopened = {}, {}, {}
    local me = NS.Account and NS.Account.me
    if me then
        me.done, me.skipped = c.done, c.skipped
        me.stepDone, me.stepSkipped, me.stepMeta = {}, {}, {}
    end
end
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
-- achievements (MoP Classic + retail have the API; Era/TBC do not, so their ACH steps stay manual)
if flavor == "mop" or flavor == "retail" then
    function GetAchievementInfo(id) return id, "ach" .. id, 10, W.ach[id] or false end
    function GetAchievementCriteriaInfoByID(id, crit) return "crit", 0, W.crit[crit] or W.ach[id] or false end
end

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
-- CR_OVERRIDE="Core/Progress.lua=/tmp/old/Progress.lua,..." loads those addon files from elsewhere (before/after runs)
local OVERRIDE = {}
for pair in (os.getenv("CR_OVERRIDE") or ""):gmatch("[^,]+") do
    local k, v = pair:match("^(.-)=(.+)$")
    if k then OVERRIDE[k] = v end
end
local function load(path)
    local full = OVERRIDE[path] or ("CompletionRoute/" .. path)
    local f = io.open(full, "r")
    if not f then io.stderr:write("skip " .. path .. "\n") return end
    f:close()
    assert(loadfile(full))(ADDON, NS)
end
for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", TAXI[flavor], EXTRA[flavor] or TAXI[flavor], "Data/Transit.lua", "Data/Imported_Entrances.lua", "Data/Access.lua",
    "Data/Inns.lua", "Data/ZoneAliases.lua", "Data/Roads_ek.lua", "Data/Roads_kalimdor.lua",
    "Routing/CostModel.lua", "Routing/TravelGraph.lua", "Routing/Roads.lua", "Routing/StepOrder.lua", "Routing/Router.lua", "Routing/Loop.lua",
    "Core/Account.lua", "Core/Progress.lua", "Core/Recommend.lua", "Core/Farm.lua", "Core/Instances.lua", "Data/Farm_routes.lua",
    "Adapters/WoWPro.lua",
    ("Guides/Imported_WoWPro_" .. (WOWPRO[flavor] or flavor) .. ".lua"),
    -- quest guides exactly as the flavor TOC loads them: wiki guides + the older generated guides' gaps
    ("Guides/Imported_Wiki_" .. flavor .. ".lua"), ("Guides/Imported_Quests_" .. flavor .. "_gaps.lua"),
    ("Guides/Imported_Achievements_" .. flavor .. ".lua"), ("Guides/Imported_Storylines_" .. flavor .. ".lua"),
    ("Guides/Imported_Missions_" .. flavor .. ".lua") }) do load(f) end
-- the spine reuses the wiki guides' text under "spine:" ids; only with --spine, so a default run plays each guide once
if withSpine then load("Guides/Imported_Spine_" .. flavor .. ".lua") end
if orderMode == "baked" then
    if routeOrderPath then
        assert(loadfile(routeOrderPath))(ADDON, NS)
    else
        load("Data/RouteOrder_" .. flavor .. ".lua")
    end
    if not NS.RouteOrder then error("vplayer --order baked: " .. (routeOrderPath or ("Data/RouteOrder_" .. flavor .. ".lua")) .. " is missing or empty (tools/optimize_routes.py)") end
elseif orderMode ~= "author" then error("vplayer --order must be author or baked") end
CompletionRouteDB, CompletionRouteCharDB = nil, nil
-- the label every output row carries (collect_vplayer.py keys on it): Forever must not overwrite era rows
FLABEL = NS.isForever and "forever" or NS.flavor
if flavor == "forever" and not NS.isForever then error("vplayer forever: Core/Init.lua did not detect Forever (Interface 16001)") end
for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", "CompletionRoute") end
NS.db.profile.debug = false
NS.db.profile.routing.baked = (orderMode == "baked")
NS.db.profile.routing.reorder = liveWindow
NS.db.profile.routing.liveBudgetMs = 1e9   -- the simulation has no frames: let each live repair finish (the 3 ms slice is unit-tested)
-- flight rule: "model" = the cost model's offline rule (what the bake assumes); "all" the faction-wide rule every run
-- before the cost model used; "band" the planning-level rule; "learn" the client's default (fly only into discovered
-- flight paths), with discovery simulated below
local TAXI_POLICY = { model = nil, all = "faction", band = "band", learn = "known" }
if TAXI_POLICY[taxiMode] == nil and taxiMode ~= "model" then error("vplayer --taxi must be model, all, band or learn") end
NS.db.profile.routing.taxiPolicy = (taxiMode == "learn") and "known" or "faction"
NS.Print, NS.Debug, NS.Error = function() end, function() end, function() end
pcall(NS.Adapters.WoWPro.ImportStatic)
NS.TravelGraph.Build()

local G, P, R, U, Cond, CM = NS.Guide, NS.Progress, NS.Router, NS.Util, NS.Cond, NS.CostModel
-- the cost model's offline character (tools/cm_offline.lua): installed for the per-guide and --chain runs, not for
-- --repro / --capture, which replay what a client recorded (its own speed, hearth and flight rule)
local OFF = dofile("tools/cm_offline.lua")
local ctl
if not REPRO then
    ctl = OFF.Install(NS, MAPS, { taxi = TAXI_POLICY[taxiMode] })
    if taxiMode == "model" then taxiMode = (ctl.policy == "faction") and "all" or ctl.policy end
end
-- --who plan: the character the bake plans for (CostModel.Persona / Takes): the faction, class, race and profession most
-- of the guide's located steps are written for (none where no one value covers half of them), so it takes exactly the
-- steps the bake walks to; it has done every prerequisite quest that no step it takes turns in (earlier content), and
-- meets every level gate - so it plays the given order exactly as the optimizer prices it (tools/test_cost_parity.lua).
-- --who gate: a real character (the real Core/Conditions.lua rules) of the planning character's faction, class and
-- race, a Human / Orc warrior where it has none, levelling through the guide: what the bake gate measures.
-- The default "warrior" is the Human / Orc warrior every earlier run used.
local planWho = {}
if whoMode == "plan" then
    Cond.ClassMatch = function(list) return CM.ListTakes(list, "class", planWho.class) end
    Cond.RaceMatch = function(list) return CM.ListTakes(list, "race", planWho.race) end
    Cond.ProfMatch = function(spec) return CM.ListTakes(spec, "prof", planWho.prof) end
    Cond.FactionMatch = function(f) return CM.FactionTakes(f, planWho.faction) end
    if bothAs then error("vplayer --both-as is not for --who plan (it plays the planning character's own faction)") end
elseif whoMode ~= "warrior" and whoMode ~= "gate" then error("vplayer --who must be warrior, plan or gate") end
if bothAs and bothAs ~= "Alliance" and bothAs ~= "Horde" then error("vplayer --both-as must be Alliance or Horde") end

-- --taxi learn: the route a step was reached by (last TravelGraph.FindPath of walkTo) and flight-path discovery
local lastPath, taxiLearned = nil, 0
if taxiMode == "learn" then
    local findPath = NS.TravelGraph.FindPath
    NS.TravelGraph.FindPath = function(...) local p = findPath(...) lastPath = p return p end
end
local function forgetTaxi()
    if taxiMode ~= "learn" then return end
    NS.db.char.knownTaxi, NS.db.global.knownTaxi = {}, {}
    NS.TravelGraph.TaxiChanged()
end
-- the player took off from (talked to) every flight master the route flew from, and talks to any within 40 yd of
-- the step it now stands on (an |f| step's flight master included)
local function discoverTaxi(path)
    if taxiMode ~= "learn" then return 0 end
    local TG, new = NS.TravelGraph, 0
    local function mark(id) if id and not TG.IsTaxiKnownID(id) then TG.MarkTaxiKnown(id) new = new + 1 end end
    for _, l in ipairs(path and path.legs or {}) do
        if l.mode == "taxi" then mark(l.from.taxiID) mark(l.to.taxiID) end
    end
    if PLAYER.wx then
        for _, n in ipairs(TG.byInst and TG.byInst[PLAYER.inst] or {}) do
            if n.taxiID and (n.wx - PLAYER.wx) ^ 2 + (n.wy - PLAYER.wy) ^ 2 <= 40 * 40 then mark(n.taxiID) end
        end
    end
    if new > 0 then TG.TaxiChanged() taxiLearned = taxiLearned + new end
    return new
end

-- wall-clock cost of every live repair (cold router caches included); CR_LIVE_BUDGET_MS plays the real per-call budget
local planMs = {}
if NS.StepOrder.Plan then
    local plan = NS.StepOrder.Plan
    NS.StepOrder.Plan = function(...)
        local t0 = os.clock()
        local a, b = plan(...)
        planMs[#planMs + 1] = (os.clock() - t0) * 1000
        return a, b
    end
end
if os.getenv("CR_LIVE_BUDGET_MS") then NS.db.profile.routing.liveBudgetMs = tonumber(os.getenv("CR_LIVE_BUDGET_MS")) end
-- CR_SO="MIN_GAIN=0,GAIN_FRAC=0" overrides StepOrder's tuning constants for an experiment; CR_WINDOW sets the window
for k, v in (os.getenv("CR_SO") or ""):gmatch("([%w_]+)=([%d%.]+)") do NS.StepOrder[k] = tonumber(v) end
if os.getenv("CR_WINDOW") then NS.db.profile.routing.window = tonumber(os.getenv("CR_WINDOW")) end

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
-- same as in other guide addons.  Judging by the action letter alone reported those as bugs, which they are not.
-- Returns true (auto) or false plus the reason it can only ever be manual.
local function autoable(step)
    local a = step.action
    if step.ach and GetAchievementInfo then return true end
    if a == "A" or a == "a" or a == "!" then
        if step.qid then return true end return false, "accept without QID"
    elseif a == "C" or a == "K" or a == "l" then
        if step.qid or step.loot then return true end return false, "objective without QID or loot"
    elseif a == "T" or a == "t" then
        if step.qid then return true end return false, "turn-in without QID"
    elseif a == "U" then
        if step.item then return true end
        if step.qid then
            -- WoW-Pro stamps profession "Learn Recipe" steps with synthetic qids (skill*10^6+level);
            -- no client API ever completes those, so in game they are a manual click
            for _, q in ipairs(step.qid) do if q < 1000000 then return true end end
            return false, "synthetic profession QID"
        end
        return false, "use without item or QID"
    elseif a == "B" then
        if step.loot then return true end return false, "buy without loot list"
    elseif a == "L" then
        if step.minlevel then return true end return false, "level step without a level"
    elseif a == "R" or a == "G" or a == "F" or a == "b" or a == "J" or a == "H" or a == "D" then
        -- CheckStep needs BOTH a resolved zone and (for the distance check) a real transform:
        -- a step whose zone did not resolve can never tick, in game or here - that is a manual
        -- click, not a stall (the guide-data bug stays visible in manual_reason)
        if not step.zone then return false, "travel step with unresolvable zone" end
        if step.coords and not (MAPS[step.zone] and MAPS[step.zone][3]) then return false, "no offline map transform" end
        return true
    elseif a == "h" or a == "f" then
        return true
    end
    return false, "note-class step (" .. a .. ")"
end

-- --turnins: what one QUEST_TURNED_IN costs (every handler, including the Progress refresh and live re-plan it starts)
-- (graph builds and router calls are counted only while the handlers run)
local turnin = { ms = {}, builds = 0, calls = 0, active = false }
if fireTurnins then
    local TG = NS.TravelGraph
    local build = TG.Build
    TG.Build = function(...) if turnin.active then turnin.builds = turnin.builds + 1 end return build(...) end
    for _, k in ipairs({ "TravelSeconds", "TravelSecondsFromPlayer" }) do
        local f = NS.Router[k]
        NS.Router[k] = function(...) if turnin.active then turnin.calls = turnin.calls + 1 end return f(...) end
    end
end
local function fireTurnin(q)
    turnin.active = true
    local t0 = os.clock()
    for _, h in ipairs(NS.wowHandlers.QUEST_TURNED_IN or {}) do pcall(h, "QUEST_TURNED_IN", q, 0, 0) end
    turnin.ms[#turnin.ms + 1] = (os.clock() - t0) * 1000
    turnin.active = false
end

local function finishObjectives(q)
    local objs = W.objectives[q]
    if not objs or #objs == 0 then objs = { { numFulfilled = 1, numRequired = 1, finished = true, text = "obj" } } W.objectives[q] = objs end
    for _, o in ipairs(objs) do o.finished = true o.numFulfilled = o.numRequired or 1 end
end
-- The numbered objectives (|QO| indices) the guide in play names for a quest, over the steps this character can ever
-- take (class, race, faction, profession).  A quest is complete once each of them is done, or once an objective step
-- with no index (the whole quest) is done - as in the client, where every objective is its own trip.  Routing/CostModel.lua
-- PlanSteps prices the same rule (until 2026-11-10 any objective step finished the whole quest here).
local OBJECTIVE_ACTION = { C = true, K = true, l = true, U = true }
local objNeed = { id = nil, map = nil }
local function namedObjectives(q)
    local id = P.guide and P.guide.id
    if objNeed.id ~= id or not objNeed.map then
        objNeed.id, objNeed.map = id, {}
        for _, s in ipairs((id and G.Steps(id)) or {}) do
            local n = tonumber(s.qo)
            if n and s.qid and OBJECTIVE_ACTION[s.action] and Cond.ClassMatch(s.class) and Cond.RaceMatch(s.race)
                and Cond.FactionMatch(s.faction) and Cond.ProfMatch(s.prof) then
                for _, qq in ipairs(s.qid) do local t = objNeed.map[qq] or {} t[n] = true objNeed.map[qq] = t end
            end
        end
    end
    return objNeed.map[q]
end
local function doObjective(q, qo)
    if W.quests[q] == "done" then return end
    local n = tonumber(qo)
    local need = n and namedObjectives(q)
    if not (need and need[n]) then W.quests[q] = "complete" finishObjectives(q) return end
    local objs = W.objectives[q]
    if not objs or #objs == 0 then
        objs = {}
        local max = 0
        for k in pairs(need) do if k > max then max = k end end
        for k = 1, max do objs[k] = { numFulfilled = need[k] and 0 or 1, numRequired = 1, finished = not need[k], text = "obj" .. k } end
        W.objectives[q] = objs
    end
    local o = objs[n]
    if o then o.finished, o.numFulfilled = true, o.numRequired or 1 end
    for _, x in ipairs(objs) do
        if not x.finished then if W.quests[q] ~= "complete" then W.quests[q] = "log" end return end
    end
    W.quests[q] = "complete"
end

-- --repro / --capture: move the player onto the step the way the client would route it (from where the player stands,
-- the hearth allowed).  Returns yards, seconds, routed, has a destination.
local function walkToClient(step)
    local secs = nil
    lastPath = nil
    local ok, v = pcall(R.TravelSecondsFromPlayer, step)
    if ok then secs = v end
    local path = lastPath
    local yards = 0
    local tx, ty, ti = R.StepWorld(step)
    if tx and PLAYER.wx and ti == PLAYER.inst then
        yards = math.sqrt((tx - PLAYER.wx) ^ 2 + (ty - PLAYER.wy) ^ 2)
    end
    -- teleport onto the step so the position-driven checks (R/G/F/b/J/H/D) can see us there
    if step.zone and MAPS[step.zone] and MAPS[step.zone][3] then
        local c = step.coords and step.coords[1]
        place(step.zone, c and c.x or 0.5, c and c.y or 0.5)
    end
    if secs ~= nil then discoverTaxi(path) end
    return yards, secs, (secs ~= nil), (tx ~= nil)
end

-- The cost model's walk (Routing/CostModel.lua, the bake's pricing): `here` is the point of the last located step the
-- character visited (or where it was put), and that step's planning level, which sets the speed of the next leg.
local here = { pt = nil, level = 1 }
-- an explicit placement (a guide's start, a chain's start): the next leg leaves from the player's spot
local function placeHere(level)
    here.pt = PLAYER.wx and { wx = PLAYER.wx, wy = PLAYER.wy, inst = PLAYER.inst, zone = PLAYER.map } or nil
    here.level = level or here.level
end
local function walkTo(step)
    if not ctl then return walkToClient(step) end
    lastPath = nil
    -- a step that rides along is done where the character stands: no leg, no move
    if not CM.Located(step) then return 0, 0, true, false end
    local tx, ty, ti = R.StepWorld(step)
    if not tx then return 0, 0, true, false end
    local secs, routed, yards = 0, true, 0
    if step.action == "H" then
        secs = CM.HEARTH     -- use the hearthstone: the cost model's hearth cost, not the trip (the bake prices it the same)
    elseif here.pt then
        ctl.SetLevel(here.level)
        local from = { coords = { { x = 0.5, y = 0.5 } }, zone = here.pt.zone, _wx = here.pt.wx, _wy = here.pt.wy, _winst = here.pt.inst, _cmk = "own" }
        local ok, v = pcall(R.TravelSeconds, from, step)
        if ok and v then secs = v else secs, routed = CM.NOROUTE, false end
        if here.pt.inst == ti then yards = math.sqrt((tx - here.pt.wx) ^ 2 + (ty - here.pt.wy) ^ 2) end
    end   -- (no start point: the first leg is free, as in the bake)
    local path = lastPath
    -- put the character on the step (its own zone and point, an NPC's point, or the zone centre) so the position-driven
    -- checks (R/G/F/b/J/H/D) can see it there
    local z, x, y = CM.MapPoint(step)
    if z and MAPS[z] and MAPS[z][3] then place(z, x, y) end
    here.pt = { wx = tx, wy = ty, inst = ti, zone = step.zone }
    here.level = CM.Level(step, here.level)
    ctl.SetLevel(here.level)
    if routed then discoverTaxi(path) end
    return yards, secs, routed, true
end

local function act(step)
    local a = step.action
    if a == "A" or a == "a" or a == "!" then
        for _, q in ipairs(step.qid or {}) do if W.quests[q] ~= "done" then W.quests[q] = "log" end end
    elseif a == "C" or a == "K" or a == "l" then
        for _, q in ipairs(step.qid or {}) do doObjective(q, step.qo) end
        for _, l in ipairs(step.loot or {}) do W.bags[l.id] = math.max(W.bags[l.id] or 0, l.qty or 1) end
    elseif a == "T" or a == "t" then
        for _, q in ipairs(step.qid or {}) do W.quests[q] = "done" W.objectives[q] = nil end
        if fireTurnins then for _, q in ipairs(step.qid or {}) do fireTurnin(q) end end
        W.xp = W.xp + 25
        if W.xp >= W.xpmax then W.xp, W.level = 0, W.level + 1 end
    elseif a == "U" then
        if step.item then
            W.bags[step.item] = 1
            pcall(P.CheckStep, step)     -- lets CheckStep latch step.hadItem
            W.bags[step.item] = nil
        end
        for _, q in ipairs(step.qid or {}) do doObjective(q, step.qo) end
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
    if step.ach then
        if step.achCrit then W.crit[step.achCrit] = true else W.ach[step.ach] = true end
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

if REPRO then
    os.exit(REPRO.Main(reproOpts, reproReport, { NS = NS, W = W, place = place, wipeWorld = wipeWorld, walkTo = walkTo, act = act,
        load = load, flavor = flavor, setChar = function(f, c, r) FACTION, CLASS, RACE = f, c, r end }))
end

-- ---------------------------------------------------------------------------
-- Play one guide
-- ---------------------------------------------------------------------------
local stallOut, noRouteOut
local traceOut = os.getenv("CR_TRACE") and assert(io.open(os.getenv("CR_TRACE"), "w"))
local function playGuide(g)
    local id = g.id
    local steps = G.Steps(id)
    if not steps or #steps == 0 or g.empty then return nil end

    local forBoth = g.faction ~= "Alliance" and g.faction ~= "Horde"
    FACTION = (g.faction == "Horde") and "Horde" or "Alliance"
    if whoMode == "plan" or whoMode == "gate" then
        local who = CM.Persona(steps, g)
        if whoMode == "plan" then
            planWho = who
            FACTION = who.faction or FACTION
        else
            FACTION = (forBoth and bothAs) or who.faction or FACTION
            CLASS = who.class or "WARRIOR"
            RACE = who.race or ((FACTION == "Horde") and "Orc" or "Human")
        end
    elseif forBoth and bothAs then
        FACTION = bothAs
    end
    NS.player.faction, NS.player.class, NS.player.race = FACTION, CLASS, RACE
    wipeWorld(math.max(1, tonumber(g.minlevel) or 1))
    if whoMode == "plan" then
        W.level = 999
        -- a prerequisite counts as done before the guide unless a step this character takes turns it in (a quest only
        -- another faction's or class's steps turn in is earlier content for it, as in CostModel.PlanSteps)
        local tin = {}
        for _, s in ipairs(steps) do
            if (s.action == "T" or s.action == "t") and s.qid and CM.Takes(s, planWho) then for _, q in ipairs(s.qid) do tin[q] = true end end
        end
        for _, s in ipairs(steps) do
            for _, q in ipairs(s.pre or {}) do if not tin[q] then W.quests[q] = "done" end end
        end
    end
    NS.db.char.done, NS.db.char.skipped, NS.db.char.reopened, NS.db.char.laps, NS.db.char.guide = {}, {}, {}, {}, nil
    NS.db.char.parked, NS.db.char.parkReturn = {}, nil
    wipeMarks()
    R.Invalidate()
    NS.TravelGraph.Build()
    forgetTaxi()

    -- start where a player would: the guide's own zone
    local zone = g.zone
    if not zone then for _, s in ipairs(steps) do if s.zone then zone = s.zone break end end end
    local placed = zone and MAPS[zone] and place(zone, 0.5, 0.5) or false
    if ctl then
        -- the guide's start: its zone's centre at its start level (no map for the zone: the first leg is free)
        if placed then placeHere(CM.StartLevel(g)) else here.pt, here.level = nil, CM.StartLevel(g) end
        ctl.SetLevel(here.level)
    end

    local row = { steps = #steps, sim = 0, auto = 0, manual = 0, stalls = 0, forced = 0, laps = 0,
                  yards = 0, seconds = 0, noroute = 0, finished = 0, err = "", reasons = {}, resumes = 0 }
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
            if P.guide == nil or P.guide.id ~= id then
                -- Chained away. A guide parked on a level gate (Core/Progress.lua) is not finished: the character
                -- reaches the gate and the real resume path brings the guide back.
                local rec = P.ParkedRecord and P.ParkedRecord(id)
                if rec and row.resumes < 200 then
                    row.resumes = row.resumes + 1
                    W.level = math.max(W.level, rec.level)
                    if not P.ResumeParked(id) then row.err = "resume failed" break end
                else
                    if P.ParkedRecord then
                        if not rec then row.finished = 1 end    -- moved on with nothing left behind
                    elseif P.guide and g.next and P.guide.id == g.next then
                        row.finished = 1                        -- (old Progress.lua) only a direct move to `next` counted
                    end
                    break
                end
            end
            if g.loop and laps >= 2 then row.finished = 1 break end       -- circuits never end: two laps is a pass
            local step = P.current
            if not step then
                if levelGateBump() then P.Refresh() end
                if not P.current then row.finished = 1 break end
                step = P.current
            end

            local fromMap = PLAYER.map
            local y, s, routed, hasDest = walkTo(step)
            if traceOut then traceOut:write(("%s\t%d\t%s\t%s\t%s\t%s\t%.1f\t%s\t%s\n"):format(id, step.index, step.action, tostring(step.qid and step.qid[1] or ""),
                tostring(step.zone or ""), step.coords and "xy" or "-", s or -1, ((step.title or ""):sub(1, 40):gsub("\t", " ")), CM.Kind(step))) end
            row.yards = row.yards + (y or 0)
            row.seconds = row.seconds + (s or 0)
            -- only a step that HAS a destination the router failed to path to is a routing gap;
            -- a locationless note/achievement step is just something the player does where they are
            if not routed and hasDest then
                row.noroute = row.noroute + 1
                if noRouteOut then
                    noRouteOut:write(table.concat({ FLABEL, id, step.index, step.action, tostring(fromMap or ""),
                        tostring(step.zone or ""), (tostring(step.zoneName or ""):gsub("\t", " ")) }, "\t") .. "\n")
                end
            end

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
                        stallOut:write(table.concat({ FLABEL, id, step.index, step.action,
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
-- --chain: play a whole spine the way a character does, with the real end-of-guide logic
-- ---------------------------------------------------------------------------
-- Starts at the faction's first spine guide and follows Progress's own chain (`next`, parked guides coming
-- back at their level, the return to where the chain was going).  The level comes from the XP model: one level
-- per --questsperlevel turn-ins (default 25, a slow character; 4 is what the per-guide mode uses).  SuggestNext
-- stays disabled, so the only way to load a guide is the chain logic under test.  The run fails on a bounce:
-- a guide loaded and left with no step done, repeatedly.
if chainFaction then
    FACTION, RACE = chainFaction, (chainFaction == "Horde") and "Orc" or "Human"
    NS.player.faction, NS.player.class, NS.player.race = FACTION, CLASS, RACE
    W.xpmax = 100
    local cap = NS.Recommend.LevelCap()
    wipeWorld(1)
    W.xpmax = 25 * (questsPerLevel or 25)   -- a turn-in is worth 25 xp (see act)
    NS.db.char.done, NS.db.char.skipped, NS.db.char.reopened, NS.db.char.laps, NS.db.char.guide = {}, {}, {}, {}, nil
    NS.db.char.parked, NS.db.char.parkReturn = {}, nil
    wipeMarks()
    local prefix = ("spine:%s:%s:"):format(flavor, chainFaction:sub(1, 1))
    local first
    for _, id in ipairs(G.list) do
        if id:sub(1, #prefix) == prefix and (not first or id < first) then first = id end
    end
    if not first then error("no spine guides for " .. chainFaction .. " (load them with --spine)") end
    place(G.registry[first].zone, 0.5, 0.5)
    placeHere(CM.StartLevel(G.registry[first]))
    ctl.SetLevel(here.level)
    R.Invalidate()
    NS.TravelGraph.Build()
    forgetTaxi()
    if not P.Load(first) then error("could not load " .. first) end
    local loads, tenureSteps, lastGuide, bounces, order, stepsDone = {}, 0, nil, 0, {}, 0
    local secs, stalls, noroute = 0, 0, 0
    loads[first] = 1
    order[1] = first
    lastGuide = first
    local capSteps = 400000
    local t0 = os.clock()
    while capSteps > 0 and os.clock() - t0 < (guideCap > 90 and guideCap or 900) do
        capSteps = capSteps - 1
        local step = P.current
        if not step then
            -- out of steps at this level: the character levels up (real time passes), the level-up event refreshes
            while W.level < cap and not P.current do
                W.level = W.level + 1
                W.xp = 0
                P.Refresh()
            end
            step = P.current
            if not step then break end
        end
        if P.guide.id ~= lastGuide then
            -- a guide change: count how many steps the previous tenure completed
            if tenureSteps == 0 and loads[lastGuide] and loads[lastGuide] > 1 then bounces = bounces + 1 end
            tenureSteps = 0
            lastGuide = P.guide.id
            loads[lastGuide] = (loads[lastGuide] or 0) + 1
            order[#order + 1] = lastGuide
        end
        local _, s, routed, hasDest = walkTo(step)
        secs = secs + (s or 0)
        if not routed and hasDest then noroute = noroute + 1 end
        act(step)
        if W.level > cap then W.level, W.xp = cap, 0 end
        P.Refresh()
        stepsDone = stepsDone + 1
        tenureSteps = tenureSteps + 1
        if P.current == step then
            stalls = stalls + 1
            P.MarkDone(step)
        end
    end
    local parkedLeft, reloaded, maxLoads = 0, 0, 0
    for _ in pairs(NS.db.char.parked or {}) do parkedLeft = parkedLeft + 1 end
    for _, c in pairs(loads) do
        if c > 1 then reloaded = reloaded + 1 end
        if c > maxLoads then maxLoads = c end
    end
    print(("CHAIN %s %s: %d guides loaded, %d distinct, %d resumed at least once (max %d loads of one guide), bounces %d, steps done %d, level %d, parked left %d, stalls %d, no_route %d, %.0f s travel, cap_left %d, taxi %s (%d discovered)"):format(
        flavor, chainFaction, #order, (function() local n = 0 for _ in pairs(loads) do n = n + 1 end return n end)(),
        reloaded, maxLoads, bounces, stepsDone, W.level, parkedLeft, stalls, noroute, secs, capSteps, taxiMode, taxiLearned))
    if bounces > 0 then os.exit(1) end
    os.exit(0)
end

-- ---------------------------------------------------------------------------
-- Run
-- ---------------------------------------------------------------------------
local out = assert(io.open(outPath, "w"))
out:write("flavor\tguide\tname\ttype\tfaction\tzone\tzone_name\tsteps\tsimulated\tauto\tmanual\tstalls\tforced\tlaps\tyards\tseconds\tno_route\tfinished\tmanual_reason\terror\n")
stallOut = assert(io.open(stallPath, "w"))
stallOut:write("flavor\tguide\tstep\taction\ttitle\tqid\tzone\tcoords\n")
noRouteOut = assert(io.open((outPath:gsub("%.tsv$", "")) .. "_noroute.tsv", "w"))
noRouteOut:write("flavor\tguide\tstep\taction\tfrom_map\tto_map\tto_name\n")

io.stderr:write(("vplayer %s: %d guides registered, shard %d/%d\n"):format(FLABEL, #G.list, shardI, shardN))
local n, finished, stalled, errored = 0, 0, 0, 0
local t0 = os.clock()
for gi, id in ipairs(G.list) do
    if n >= limit then break end
    if (gi % shardN) == (shardI % shardN) then
        local g = G.registry[id]
        local typeOK = (not onlyType) or (G.NormalizeType(g.type) == onlyType)
        local guideOK = ((not onlyGuide) or id == onlyGuide) and ((not guideSet) or guideSet[id])
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
                out:write(table.concat({ FLABEL, id, (g.name or ""):gsub("\t", " "), G.NormalizeType(g.type), g.faction or "Both",
                    tostring(g.zone or ""), zname, row.steps, row.sim, row.auto, row.manual, row.stalls, row.forced, row.laps,
                    ("%.0f"):format(row.yards), ("%.0f"):format(row.seconds), row.noroute, row.finished, topReason, row.err }, "\t") .. "\n")
                if verbose or n % 25 == 0 then
                    io.stderr:write(("%d guides %.0fs  finished=%d stalled=%d err=%d  last=%s\n"):format(n, os.clock() - t0, finished, stalled, errored, id))
                    out:flush() stallOut:flush()
                end
            end
        end
    end
end
out:close() stallOut:close() noRouteOut:close()
if #planMs > 0 then
    table.sort(planMs)
    local pct = function(p) return planMs[math.max(1, math.ceil(#planMs * p))] end
    io.stderr:write(("LIVE %s: %d repairs, ms p50 %.2f p95 %.2f p99 %.2f max %.1f\n"):format(flavor, #planMs, pct(0.5), pct(0.95), pct(0.99), planMs[#planMs]))
end
if #turnin.ms > 0 then
    local ms = {}
    local sum = 0
    for i, v in ipairs(turnin.ms) do ms[i] = v sum = sum + v end
    table.sort(ms)
    local pct = function(p) return ms[math.max(1, math.ceil(#ms * p))] end
    io.stderr:write(("TURNIN %s (jit %s): %d turn-ins, ms per turn-in mean %.2f p50 %.2f p95 %.2f max %.1f, total %.0f ms; graph builds %d, router calls %d\n"):format(
        flavor, (jit and jit.status and (jit.status() and "on" or "off")) or "n/a", #ms, sum / #ms, pct(0.5), pct(0.95), ms[#ms], sum, turnin.builds, turnin.calls))
end
io.stderr:write(("DONE %s shard %d/%d: %d guides in %.0fs -> %s | finished=%d stalled-guides=%d errors=%d | taxi %s (%d flight paths discovered)\n")
    :format(flavor, shardI, shardN, n, os.clock() - t0, outPath, finished, stalled, errored, taxiMode, taxiLearned))
