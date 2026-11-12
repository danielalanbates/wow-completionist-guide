-- CompletionRoute :: tools/test_skip.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- Offline tests of quest-level skipping (Core/Skip.lua, Routing/Replan.lua, docs/ROUTING.md "Skipping quests"):
--   1. mechanics on a small synthetic guide (always runs): dependency closure with any-one / all-of prerequisites, a
--      leaf skips at once, cancel changes nothing, confirm drops the chain, the rebuilt list (riders, travel, ACTIVE /
--      PRE-only steps out; a step serving a kept quest stays), counts, ticks kept, the per-step Skip (warning; an accept
--      drops its quest), breadcrumbs (the target stays fully doable), the guide-only fallback, a second guide rebuilt
--      on open, SavedVariables round trip, unskip
--   1b. regressions from the review: a guide's own PRE the index lacks (warning, nothing stranded, also in a guide opened
--      later), another class's dependents not named, a dropped travel step's rider, prerequisite cycles, `never`
--      quests, the re-plan model leaving out steps this character never sees
--   2. every flavor's REAL generated guides (when Data/QuestDeps_<fl>.lua and the guides exist): closure equals a
--      whole-index reachability reference, known chains, nothing stranded after single drops on wiki and
--      storyline guides, a row from one search equals FindPath pair by pair, then per sample guide: drop the quest with
--      the most dependents, check the rebuild, run the time-sliced re-plan frame by frame and check every rule and that
--      it never costs more travel time than "baked order minus removed steps" (the arrow's route and the |M|-only route),
--      a speed change mid-job changes nothing, the spine entry sharing the quests rebuilds on open, a reload shows the
--      same guide, unskip gives back the identical list
-- Per-frame CPU is measured on every re-plan frame; run under the interpreter to match the client:
--   luajit -joff tools/test_skip.lua [era tbc mop retail forever]      (CR_SKIP_SAMPLES=n guides per flavor, default 3)
package.path = "./?.lua;" .. package.path
local FLAVORS = {}
for i = 1, #arg do FLAVORS[#FLAVORS + 1] = arg[i] end
if #FLAVORS == 0 then FLAVORS = { "era", "tbc", "mop", "retail", "forever" } end
local SAMPLES = tonumber(os.getenv("CR_SKIP_SAMPLES") or "") or 3
local FRAME_LIMIT_MS = 2.0
local passed, failed = 0, 0
local function t(name, cond, detail)
    if cond then passed = passed + 1 print("ok   " .. name)
    else failed = failed + 1 print("FAIL " .. name .. (detail ~= nil and (" :: " .. tostring(detail)) or "")) end
    return cond
end
local function exists(p) local f = io.open(p, "r") if f then f:close() return true end return false end
local allFrames, pausedFrames, budgetMs, applyMs = {}, {}, nil, {}

-- ---------------------------------------------------------------------------
-- Harness: the real addon on stubs, one flavor, optional saved variables
-- ---------------------------------------------------------------------------
local TOC = { era = 11507, tbc = 20506, mop = 50504, retail = 120100, forever = 16001 }
local TAXI = { era = "Data/Taxi_era.lua", tbc = "Data/Taxi_tbc.lua", mop = "Data/Taxi_mop.lua", retail = "Data/Taxi_retail.lua",
               forever = "Data/Taxi_forever.lua" }
local W
local function harness(flavor, opts)
    opts = opts or {}
    W = { quests = {}, level = 1 }
    STUB_MAPS = dofile("tools/maps_" .. flavor .. ".lua")
    dofile("tools/stubs.lua")
    GetBuildInfo = function() return "x", "0", "2026", TOC[flavor] end
    UnitLevel = function() return W.level end
    C_QuestLog = {
        IsOnQuest = function(q) local s = W.quests[q] return s == "log" or s == "complete" end,
        IsQuestFlaggedCompleted = function(q) return W.quests[q] == "done" end,
        IsComplete = function(q) return W.quests[q] == "complete" end,
        GetLogIndexForQuestID = function(q) local s = W.quests[q] return (s == "log" or s == "complete") and 1 or nil end,
        GetQuestObjectives = function() return {} end,
        GetAllCompletedQuestIDs = function() local o = {} for q, s in pairs(W.quests) do if s == "done" then o[#o + 1] = q end end return o end,
        GetTitleForQuestID = function() return nil end,
    }
    PLAYER = { map = 1429, x = 0.5, y = 0.5 }
    local ADDON, NS = "CompletionRoute", {}
    local function load(p, optional)
        if optional and not exists("CompletionRoute/" .. p) then return false end
        assert(loadfile("CompletionRoute/" .. p))(ADDON, NS)
        return true
    end
    local files = { "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", TAXI[flavor] }
    if flavor == "forever" then files[#files + 1] = "Data/MapFix_forever.lua" end
    for _, f in ipairs({ "Data/Transit.lua", "Data/Access.lua", "Data/Inns.lua", "Data/ZoneAliases.lua", "Data/Roads_ek.lua",
        "Data/Roads_kalimdor.lua", "Routing/CostModel.lua", "Routing/TravelGraph.lua", "Routing/Roads.lua", "Routing/StepOrder.lua", "Routing/Router.lua",
        "Routing/Replan.lua", "Core/Account.lua", "Core/Professions.lua", "Core/Progress.lua", "Core/Skip.lua", "Core/Recommend.lua" }) do
        files[#files + 1] = f
    end
    for _, f in ipairs(files) do load(f) end
    load("Data/Imported_Entrances.lua", true)
    local have = {}
    if opts.real then
        for _, f in ipairs({ "Guides/Imported_Wiki_" .. flavor .. ".lua", "Guides/Imported_Quests_" .. flavor .. "_gaps.lua",
                             "Guides/Imported_Spine_" .. flavor .. ".lua", "Data/RouteOrder_" .. flavor .. ".lua",
                             "Data/QuestDeps_" .. flavor .. ".lua" }) do
            have[f] = load(f, true)
        end
    end
    CompletionRouteDB, CompletionRouteCharDB = opts.db, opts.chardb
    for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", "CompletionRoute") end
    NS.printed = {}
    NS.Print = function(_, ...) local p = {} for i = 1, select("#", ...) do p[#p + 1] = tostring(select(i, ...)) end NS.printed[#NS.printed + 1] = table.concat(p, " ") end
    NS.Debug, NS.Error = function() end, function() end
    NS.db.profile.routing.liveBudgetMs = 1e9    -- the live window has its own budget test (tools/test_live_route.lua)
    NS.Guide.SuggestNext = function() return nil end
    NS.Guide.Suggest = function() return nil end
    NS.TravelGraph.Build()
    return NS, have
end
local function place(map, x, y)
    local wx, wy, inst = z2w(x, y, map)
    if not wx then return false end
    PLAYER.map, PLAYER.x, PLAYER.y, PLAYER.wx, PLAYER.wy, PLAYER.inst = map, x, y, wx, wy, inst
    return true
end

-- SavedVariables round trip: what the client writes at logout and reads at the next login
local function ser(v)
    local tv = type(v)
    if tv == "table" then
        local parts = {}
        for k, x in pairs(v) do
            local ks = type(k) == "number" and ("[" .. ser(k) .. "]") or ("[" .. ("%q"):format(tostring(k)) .. "]")
            local xs = ser(x)
            if xs then parts[#parts + 1] = ks .. "=" .. xs end
        end
        return "{" .. table.concat(parts, ",") .. "}"
    elseif tv == "string" then return ("%q"):format(v)
    elseif tv == "number" then
        if v ~= v then return "0/0" elseif v == math.huge then return "math.huge" elseif v == -math.huge then return "-math.huge" end
        return ("%.17g"):format(v)
    elseif tv == "boolean" then return tostring(v) end
    return nil
end
local function roundTrip(v) return assert(loadstring("return " .. ser(v)))() end

local function idx(list) local o = {} for k, s in ipairs(list) do o[k] = s.index end return table.concat(o, ",") end
local function setOf(list) local o = {} for _, s in ipairs(list) do o[s] = true end return o end
-- progress marks are stored by stable step key (Core/Account.lua stepDone / stepSkipped, docs/STEP_KEYS.md)
local function marks(NSx, field, gid) local all = NSx.Account.me[field] return (all and all[gid]) or {} end
local function ticked(NSx, gid, step) return marks(NSx, "stepDone", gid)[step.key] == true end
local function skippedStep(NSx, gid, step) return marks(NSx, "stepSkipped", gid)[step.key] == true end

-- ---------------------------------------------------------------------------
-- 1) Mechanics on a synthetic guide
-- ---------------------------------------------------------------------------
do
    local NS = harness("era")
    local S, P, G, RP, A = NS.Skip, NS.Progress, NS.Guide, NS.Replan, NS.Account
    local Z, WF = "|Z|1429; Elwynn Forest|", "|Z|1436; Westfall|"
    local lines = {
        "A Root|QID|101|M|40,40" .. Z,                       -- 1
        "A Leaf|QID|109|M|41,40" .. Z,                       -- 2
        "C Root|QID|101|M|45,45" .. Z,                       -- 3
        "N Use the torch on the pile|",                      -- 4  rider of 3 (no place, no quest)
        "T Root|QID|101|M|40,40" .. Z,                       -- 5
        "C Leaf|QID|109|M|42,41" .. Z,                       -- 6
        "T Leaf|QID|109|M|41,40" .. Z,                       -- 7
        "F Fly to Westfall|M|50,50" .. Z,                    -- 8  travel whose stretch is only dropped quests
        "A Child|QID|102|PRE|101|M|50,50" .. WF,             -- 9
        "C Child|QID|102|M|52,52" .. WF,                     -- 10
        "T Child|QID|102|M|50,50" .. WF,                     -- 11
        "A Grandchild|QID|103|PRE|102|M|50,50" .. WF,        -- 12
        "T Grandchild|QID|103|M|51,51" .. WF,                -- 13
        "R Back to Elwynn|M|42,42" .. Z,                     -- 14 travel that still serves kept quests
        "f Get the flight path|M|42,42" .. Z,                -- 15 always kept
        "A Either|QID|105|PRE|101;104|M|43,43" .. Z,         -- 16 any-one prerequisite, 104 stays
        "T Either|QID|105|M|43,43" .. Z,                     -- 17
        "A Both|QID|106|PRE|101&104|M|44,44" .. Z,           -- 18 all-of prerequisite: locked
        "T Both|QID|106|M|44,44" .. Z,                       -- 19
        "T Shared|QID|102^104|M|46,46" .. Z,                 -- 20 serves 104 too: kept
        "A Other|QID|104|M|47,47" .. Z,                      -- 21
        "T Other|QID|104|M|47,47" .. Z,                      -- 22
        "N Only while on the grandchild|ACTIVE|103|",        -- 23 ACTIVE on a dropped quest
        "N Waits for the child|PRE|102|M|48,48" .. Z,        -- 24 quest-less step waiting for a dropped quest
    }
    G.Register({ id = "t:skip:a", name = "Skip A", type = "Quests", zone = 1429, faction = "Alliance", minlevel = 1, maxlevel = 10, text = table.concat(lines, "\n") })
    G.Register({ id = "t:skip:b", name = "Skip B", type = "Quests", zone = 1436, faction = "Alliance", minlevel = 1, maxlevel = 10, text = table.concat({
        "A Child|QID|102|PRE|101|M|50,50" .. WF, "T Child|QID|102|M|50,50" .. WF, "A Solo|QID|110|M|51,50" .. WF, "T Solo|QID|110|M|51,50" .. WF }, "\n") })
    -- breadcrumb: the guide says 108 needs 107; the index (the wiki's words) says 107 is a breadcrumb and dropped the edge
    G.Register({ id = "wiki:test:crumb", name = "Crumb", type = "Quests", zone = 1429, faction = "Alliance", text = table.concat({
        "A Breadcrumb|QID|107|M|40,41" .. Z, "T Breadcrumb|QID|107|M|41,41" .. Z, "A Target|QID|108|PRE|107|M|41,41" .. Z, "T Target|QID|108|M|41,42" .. Z }, "\n") })
    G.Register({ id = "owp:test:crumb", name = "Crumb (other source)", type = "Quests", zone = 1429, faction = "Alliance", text = G.registry["wiki:test:crumb"].text })
    -- free: what tools/gen_quest_deps.py writes for a breadcrumb edge it dropped (108's guide PRE 107)
    NS.QuestDeps = { flavor = "era", pre = "102:101\n103:102\n105:101;104\n106:101&104\n", free = "108:107\n", crumb = "", never = "",
                     name = "101=Root\n102=Child\n103=Grandchild\n106=Both\n" }
    place(1429, 0.4, 0.4)
    W.level = 5

    local prompts, accept = {}, false
    S.Prompt = function(text, fn) prompts[#prompts + 1] = text if accept then fn() end return true end

    P.Load("t:skip:a")
    local base = P.steps
    t("loads with nothing skipped: the list is the guide's own", P.steps == P.baseSteps and #P.steps == 24)
    local function deps(q) local d = S.Dependents(q) table.sort(d) return table.concat(d, ",") end
    t("closure: 101 locks 102, 103 (through 102) and 106 (all-of), not 105 (any-one)", deps(101) == "102,103,106", deps(101))
    t("closure: 104 locks 106 only (105 still opens through 101)", deps(104) == "106", deps(104))
    t("closure: a leaf has no dependents", deps(109) == "", deps(109))
    W.quests[106] = "done"
    t("closure: a quest already done is never locked", deps(101) == "102,103", deps(101))
    W.quests[106] = nil
    -- tick two steps before anything is skipped: they must survive the rebuild
    P.MarkDone(base[2]) P.MarkDone(base[3])
    local doneBefore = P.VisibleDone()
    t("two ticks before skipping", doneBefore == 2, doneBefore)

    -- leaf: no question, skipped at once with a chat line
    local n0 = #NS.printed
    local r = S.SkipQuest(109)
    t("leaf quest skips at once (no warning)", r == "skipped" and #prompts == 0, r)
    t("leaf skip says so in one chat line", NS.printed[n0 + 1] and NS.printed[n0 + 1]:find("Skipped") ~= nil and #NS.printed == n0 + 1, NS.printed[n0 + 1])
    t("leaf's steps left the list", #P.steps == 21 and not setOf(P.steps)[base[2]], #P.steps)
    t("leaf skip leaves nothing locked", next(S.Store().locks) == nil)

    -- chain: warning, cancel does nothing
    local before = idx(P.steps)
    local ver = S.version
    local job0 = RP.Job()
    r = S.SkipQuest(101)
    t("chain: asks first", r == "asked" and #prompts == 1, r)
    t("warning names the quest and the blocked ones", prompts[1] and prompts[1]:find("Root") and prompts[1]:find("Child") and prompts[1]:find("Grandchild") and prompts[1]:find("Both"), prompts[1])
    t("warning splits this guide / other guides", prompts[1] and prompts[1]:find("3 in this guide, 0 in other guides", 1, true), prompts[1])
    t("warning counts the cost", prompts[1] and prompts[1]:find("removes 4 of your quests from this guide (14 steps)", 1, true), prompts[1])
    t("cancel changes nothing", idx(P.steps) == before and S.version == ver and not S.IsRemoved(101))
    t("cancel does not touch the re-plan already running for the leaf skip", RP.Job() == job0 and job0 ~= nil)

    -- confirm: the rebuild
    accept = true
    local cur0 = P.current
    r = S.SkipQuest(101)
    t("confirm drops the chain", r == "asked" and S.IsRoot(101) and S.LockedBy(102) == 101 and S.LockedBy(103) == 101 and S.LockedBy(106) == 101)
    t("an any-one dependent is not locked", not S.IsRemoved(105))
    local kept = {}
    for _, s in ipairs(P.steps) do kept[#kept + 1] = s.index end
    table.sort(kept)
    t("rebuilt list: exactly the steps that still serve something", table.concat(kept, ",") == "14,15,16,17,20,21,22", table.concat(kept, ","))
    t("rider of a dropped step went with it", not setOf(P.steps)[base[4]])
    t("travel step that only served dropped quests went", not setOf(P.steps)[base[8]])
    t("travel step still serving kept quests stayed", setOf(P.steps)[base[14]] == true)
    t("flight-path step stays", setOf(P.steps)[base[15]] == true)
    t("step shared with a kept quest stays", setOf(P.steps)[base[20]] == true)
    t("ACTIVE / PRE-only steps of dropped quests went", not setOf(P.steps)[base[23]] and not setOf(P.steps)[base[24]])
    t("counts follow the rebuild (7 steps)", #P.steps == 7 and P.baseSteps == base)
    t("current step moved off the dropped quest", P.current ~= cur0 and P.current and not (P.current.qid and S.IsRemoved(P.current.qid[1])), P.current and P.current.title)
    t("ticks of dropped steps are kept but not counted", P.VisibleDone() == 0 and ticked(NS, "t:skip:a", base[3]))
    local _, pct = A.GuideProgress("t:skip:a", #P.steps, "char", (function() local k = {} for _, s in ipairs(P.steps) do k[s.key] = true end return k end)())
    t("guide progress counts only kept steps", pct == 0, pct)
    local total, keep = S.ViewOf(G.registry["t:skip:a"])
    t("guide list sees the rebuilt total", total == 7 and keep and keep[base[14].key] and not keep[base[1].key], total)
    t("re-planning starts after the rebuild", RP.running == true)
    local guard = 0
    while RP.Step(1e9) and guard < 1000 do guard = guard + 1 end
    t("re-plan finishes and is saved under the rebuild key", not RP.running and S.HasPlan("t:skip:a", S.PlanKey(base)))
    t("re-plan keeps the same steps", #P.steps == 7)

    -- per-step Skip on an accept that others need: same warning; a plain step skip otherwise
    prompts = {}
    accept = false
    local a104
    for _, s in ipairs(P.steps) do if s.action == "A" and s.qid[1] == 104 then a104 = s end end
    r = S.SkipStep(a104)
    t("per-step Skip on an accept with dependents warns", r == "asked" and #prompts == 1 and prompts[1]:find("Skipping this step", 1, true), r)
    t("...and cancel leaves the step alone", not skippedStep(NS, "t:skip:a", a104) and not S.IsRemoved(104))
    -- per-step Skip on the accept of a quest nothing needs: that is not doing the quest, so the quest goes at once (its
    -- turn-in would otherwise be the next step, with the quest never accepted)
    local a105
    for _, s in ipairs(P.steps) do if s.action == "A" and s.qid[1] == 105 then a105 = s end end
    r = S.SkipStep(a105)
    local left105 = false
    for _, s in ipairs(P.steps) do if s.qid and s.qid[1] == 105 then left105 = true end end
    t("per-step Skip on a leaf accept drops the quest at once (no warning)", r == "skipped" and S.IsRoot(105) and #prompts == 1, r)
    t("...its turn-in left with it (nothing stranded)", not left105 and not skippedStep(NS, "t:skip:a", a105))
    t("...and the current step is not a step of that quest", not (P.current and P.current.qid and P.current.qid[1] == 105), P.current and P.current.title)
    S.Unskip(105)
    t("...unskip brings the accept and the turn-in back", (function() local n = 0 for _, s in ipairs(P.steps) do if s.qid and s.qid[1] == 105 then n = n + 1 end end return n == 2 end)())
    -- per-step Skip on an objective is a plain step skip
    local c104
    for _, s in ipairs(P.steps) do if s.qid and s.qid[1] == 104 and s.action == "A" then c104 = s end end
    W.quests[104] = "log"
    r = S.SkipStep(c104)
    t("per-step Skip on an accept already in the log is a plain step skip", r == "step" and skippedStep(NS, "t:skip:a", c104), r)
    marks(NS, "stepSkipped", "t:skip:a")[c104.key] = nil
    W.quests[104] = nil
    while RP.Step(1e9) do end

    -- the second guide that shares the dropped quests is rebuilt when it is opened
    P.Load("t:skip:b")
    t("second guide rebuilt on open (only the unrelated quest left)", #P.steps == 2 and P.steps[1].qid[1] == 110, idx(P.steps))
    local said = false
    for _, line in ipairs(NS.printed) do if line:find("left out for skipped quests", 1, true) then said = true end end
    t("...and says so when it loads", said)
    while RP.Step(1e9) do end

    -- breadcrumbs: the index has no 107 -> 108 edge (it freed it), so skipping the breadcrumb blocks nothing, and the
    -- target's own accept step (|PRE|107) stops waiting for it: the target stays fully doable
    P.Load("wiki:test:crumb")
    t("breadcrumb blocks nothing in a guide the index covers", deps(107) == "", deps(107))
    r = S.SkipQuest(107)
    local crumbSteps = {}
    for _, s in ipairs(P.steps) do if s.qid and s.qid[1] == 108 then crumbSteps[#crumbSteps + 1] = s end end
    t("breadcrumb skips at once", r == "skipped" and not S.IsRemoved(108), r)
    t("...the target keeps its accept and turn-in", #crumbSteps == 2, #crumbSteps)
    t("...and its accept opens without the breadcrumb", crumbSteps[1] and crumbSteps[1].action == "A" and NS.Cond.StepApplies(crumbSteps[1]))
    t("...the current step is the target's accept", P.current and P.current.qid and P.current.qid[1] == 108 and P.current.action == "A", P.current and P.current.title)
    S.Unskip(107)
    t("before any skip the target still waits for the breadcrumb (the guide's own order)", not NS.Cond.StepApplies(crumbSteps[1]))
    local saved = NS.QuestDeps
    NS.QuestDeps = nil
    t("no index file: the loaded guide's PRE tags are used", deps(107) == "108", deps(107))
    NS.QuestDeps = saved
    P.Load("owp:test:crumb")
    t("a guide from another source: the freed edge is still soft (the index knows it)", deps(107) == "", deps(107))
    while RP.Step(1e9) do end

    -- SavedVariables round trip: the same rebuilt (and re-planned) guide after a reload
    P.Load("t:skip:a")
    while RP.Step(1e9) do end
    local shown = idx(P.steps)
    local db, chardb = roundTrip(CompletionRouteDB), roundTrip(CompletionRouteCharDB)
    local NS2 = harness("era", { db = db, chardb = chardb })
    NS2.QuestDeps = saved
    NS2.Guide.Register({ id = "t:skip:a", name = "Skip A", type = "Quests", zone = 1429, faction = "Alliance", minlevel = 1, maxlevel = 10, text = table.concat(lines, "\n") })
    NS2.Account.Init()
    place(1429, 0.4, 0.4)
    NS2.Progress.Load("t:skip:a")
    t("reload: same rebuilt guide, same order", idx(NS2.Progress.steps) == shown, idx(NS2.Progress.steps) .. " vs " .. shown)
    t("reload: no second re-plan for the same rebuild", not NS2.Replan.running)
    t("reload: skips and locks persisted", NS2.Skip.IsRoot(101) and NS2.Skip.IsRoot(109) and NS2.Skip.LockedBy(103) == 101)
    t("reload: ticks persisted", NS2.Progress.VisibleDone() == 0 and ticked(NS2, "t:skip:a", base[3]))
    -- unskip on the reloaded character: the identical list, then a re-plan
    NS2.Skip.Unskip(101)
    NS2.Skip.Unskip(109)
    t("unskip restores the identical list", idx(NS2.Progress.steps) == idx(NS2.Progress.baseSteps) and #NS2.Progress.steps == 24, idx(NS2.Progress.steps))
    t("unskip unlocks the dependents", not NS2.Skip.IsRemoved(102) and not NS2.Skip.IsRemoved(106))
    t("unskip: the ticks come back", NS2.Progress.VisibleDone() == 2, NS2.Progress.VisibleDone())
    t("unskip re-plans", NS2.Replan.running == true)
    NS2.Replan.Cancel()
    NS2.Skip.SkipQuest(101, { confirm = true })
    NS2.Skip.Unskip("all")
    t("unskip all clears everything", not NS2.Skip.Any() and #NS2.Progress.steps == 24)
    NS2.Replan.Cancel()
    print(("mechanics: %d passed, %d failed so far"):format(passed, failed))
end

-- ---------------------------------------------------------------------------
-- 2) Real generated guides, every flavor
-- ---------------------------------------------------------------------------
local ACCEPT = { A = true, a = true, ["!"] = true }
local OBJ = { C = true, K = true, l = true, U = true }
local TURNIN = { T = true, t = true }
local RIDER = { N = true, U = true, K = true, l = true, C = true }
local TRAVEL = { R = true, F = true, b = true, J = true, H = true, D = true }

local function parseDeps(D)
    local pre, rev = {}, {}
    for q, rest in D.pre:gmatch("(%d+):([^\n]+)") do
        q = tonumber(q)
        local l = { andor = rest:find("&") and "and" or "or" }
        for p in rest:gmatch("%d+") do l[#l + 1] = tonumber(p) rev[tonumber(p)] = rev[tonumber(p)] or {} table.insert(rev[tonumber(p)], q) end
        pre[q] = l
    end
    return pre, rev
end
-- reference: what can be had is grown forward from the quests with no prerequisite over the WHOLE index (any one of an
-- "or" list, all of an "and" list); a drop locks what could be had before and cannot be had after.  Independent of the
-- addon's dependents-first search, and exact on prerequisite cycles.
local function obtainable(pre, rev, gone)
    local ok, work = {}, {}
    local function has(p) return not gone[p] and (pre[p] == nil or ok[p]) end
    local function try(q)
        if ok[q] or gone[q] then return end
        local l = pre[q]
        local b
        if l.andor == "and" then b = true for _, p in ipairs(l) do if not has(p) then b = false break end end
        else b = false for _, p in ipairs(l) do if has(p) then b = true break end end end
        if b then ok[q] = true work[#work + 1] = q end
    end
    for p, ds in pairs(rev) do if pre[p] == nil and not gone[p] then for _, q in ipairs(ds) do try(q) end end end
    local h = 1
    while h <= #work do
        for _, q in ipairs(rev[work[h]] or {}) do try(q) end
        h = h + 1
    end
    return ok
end
local okNone = setmetatable({}, { __mode = "k" })
local function bruteClosure(pre, root, rev)
    okNone[pre] = okNone[pre] or obtainable(pre, rev, {})
    local before, after = okNone[pre], obtainable(pre, rev, { [root] = true })
    local out = {}
    for q in pairs(before) do if not after[q] and q ~= root then out[#out + 1] = q end end
    table.sort(out)
    return table.concat(out, ",")
end
local KNOWN = {   -- hand-checked chains (quest -> quests that need it)
    era = { 7, "15,21", true }, forever = { 7, "15,21", true },
    tbc = { 10140, "10141,10142,10254" }, mop = { 29408, "29409,29410" }, retail = { 28757, "28769,28784" },
}

-- the remaining route as the arrow walks it: travel seconds from the player through every planned step it can point at
-- (its |M| point, or the quest objective / zone without one), priced by the live router one pair at a time
local function routeCost(NS, list, plannable, exact)
    local R = NS.Router
    local t, prev = 0, nil
    local cache = {}
    for _, s in ipairs(list) do
        -- which steps count is the cost model's rule (Routing/CostModel.lua), the one the re-planner prices with:
        -- every step the arrow visits (Located), or only those with a firm point (Firm: own |M| or an NPC's)
        local CM = NS.CostModel
        local counts
        if CM then counts = exact and CM.Firm(s) or (not exact and CM.Located(s))
        else counts = s.zone and (s.coords or not exact) end
        if plannable[s] and counts and R.StepWorld(s) then
            local c
            if not prev then c = R.TravelSecondsFromPlayer(s) else
                cache[prev] = cache[prev] or {}
                c = cache[prev][s]
                if c == nil then c = R.TravelSeconds(prev, s) or false cache[prev][s] = c end
            end
            t = t + (c or NS.Replan.NOROUTE)
            prev = s
        end
    end
    return t
end

-- every rule the re-planner must keep, checked from scratch on the lists (not on its own model)
local function checkPlan(NS, B, N, plannable, level, logStart, logCap)
    local why
    local posN = {}
    for k, s in ipairs(N) do posN[s] = k end
    if #B ~= #N then return "length " .. #B .. " vs " .. #N end
    for k, s in ipairs(B) do
        if not posN[s] then return "step lost: " .. s.index end
        if not plannable[s] and posN[s] ~= k then return "a done step moved: " .. s.index end
    end
    -- anchors: the same planned steps before every planned anchor
    local function before(list, pos, a)
        local set = 0
        for k = 1, pos[a] - 1 do if plannable[list[k]] then set = set + list[k].index * 7919 % 1000003 end end
        return set
    end
    local posB = {}
    for k, s in ipairs(B) do posB[s] = k end
    for _, s in ipairs(B) do
        if plannable[s] and NS.Replan.IsAnchor(s) and before(B, posB, s) ~= before(N, posN, s) then return "anchor moved: " .. s.index end
    end
    -- precedence the baseline keeps
    local byQ, tins = {}, {}
    for _, s in ipairs(B) do
        local q = s.qid and s.qid[1]
        if q and plannable[s] then
            byQ[q] = byQ[q] or {}
            table.insert(byQ[q], s)
            if TURNIN[s.action] then tins[q] = tins[q] or {} table.insert(tins[q], s) end
        end
    end
    local function rank(a) return ACCEPT[a] and 0 or OBJ[a] and 1 or TURNIN[a] and 2 or nil end
    for q, l in pairs(byQ) do
        for _, x in ipairs(l) do
            for _, y in ipairs(l) do
                local rx, ry = rank(x.action), rank(y.action)
                if rx and ry and posB[x] < posB[y] and (rx < ry or (rx == ry and rx ~= 1)) and posN[x] > posN[y] then
                    return ("quest %d: %s %d after %s %d"):format(q, x.action, x.index, y.action, y.index)
                end
            end
        end
    end
    for _, s in ipairs(B) do
        if plannable[s] and s.pre then
            for _, p in ipairs(s.pre) do
                for _, tt in ipairs(tins[p] or {}) do
                    if posB[tt] < posB[s] and posN[tt] > posN[s] then return ("PRE %d turn-in after %s %d"):format(p, s.action, s.index) end
                end
            end
        end
    end
    -- quest log
    local function peak(list)
        local open, log, pk = {}, logStart, logStart
        for _, s in ipairs(list) do
            if plannable[s] then
                local q = s.qid and s.qid[1]
                if q and C_QuestLog.IsOnQuest(q) then open[q] = true end
            end
        end
        for _, s in ipairs(list) do
            if plannable[s] then
                local q = s.qid and s.qid[1]
                if ACCEPT[s.action] and q and not open[q] then open[q] = true log = log + 1
                elseif TURNIN[s.action] and q and open[q] then open[q] = nil log = log - 1 end
                if log > pk then pk = log end
            end
        end
        return pk
    end
    local pb, pn = peak(B), peak(N)
    if pn > math.max(logCap, pb) then return ("quest log peak %d > max(%d, %d)"):format(pn, logCap, pb) end
    -- level gates: a step above the level needs min(K(level), its baseline turn-ins) turn-ins before it
    local function turnsBefore(list)
        local out, tb = {}, 0
        for _, s in ipairs(list) do
            if plannable[s] then out[s] = tb if TURNIN[s.action] then tb = tb + 1 end end
        end
        return out
    end
    local tbB, tbN = turnsBefore(B), turnsBefore(N)
    local function K(L)
        for _, s in ipairs(B) do
            if plannable[s] and s.action ~= "L" and (s.minlevel or 0) >= L then return tbB[s] end
        end
        return 0
    end
    for _, s in ipairs(B) do
        local g = plannable[s] and s.action ~= "L" and s.minlevel
        if g and g > level and tbN[s] < math.min(K(g), tbB[s]) then return ("level gate %d broken at %d (%d < %d)"):format(g, s.index, tbN[s], math.min(K(g), tbB[s])) end
    end
    return nil
end

-- the rebuild's own promises, checked on the lists
local function checkRebuild(base, list, removed)
    local shown = setOf(list)
    for _, s in ipairs(base) do
        if s.qid then
            local keep = false
            for _, q in ipairs(s.qid) do if not removed[q] then keep = true end end
            if keep and not shown[s] then return "dropped a step that serves a kept quest: " .. s.index end
            if not keep and shown[s] then return "kept a step of a removed quest: " .. s.index end
        end
    end
    -- no orphaned rider: a quest-less unlocated rider on screen follows a step that is on screen
    local head
    for _, s in ipairs(base) do
        if (s.coords and s.zone) or s.qid then head = s
        elseif shown[s] and RIDER[s.action] and (s.index or 0) > 0 and head and not shown[head] then return "orphaned rider " .. s.index end
    end
    -- no orphaned travel step: its stretch (to the next travel step on screen) has a quest step on screen, or none at all
    for k, s in ipairs(base) do
        if shown[s] and TRAVEL[s.action] and not s.qid and (s.index or 0) > 0 then
            local served, cut = false, false
            for j = k + 1, #base do
                local x = base[j]
                if TRAVEL[x.action] and shown[x] then break end
                if x.qid then if shown[x] then served = true break else cut = true end end
            end
            if cut and not served then return "orphaned travel step " .. s.index end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- 1b) Regressions from the 2026-11-10 review: stranded dependents, a dropped travel step's rider, quests for another
--     class, prerequisite cycles, the per-step Skip on an accept
-- ---------------------------------------------------------------------------
do
    local NS = harness("era")
    local S, P, G, Cond = NS.Skip, NS.Progress, NS.Guide, NS.Cond
    local Z, WF = "|Z|1429; Elwynn Forest|", "|Z|1436; Westfall|"
    local prompts, accept = {}, true
    S.Prompt = function(text, fn) prompts[#prompts + 1] = text if accept then fn() end return true end
    NS.QuestDeps = { flavor = "era", pre = "302:301\n330:301\n202:201\n602:601;603\n603:602\n", free = "", crumb = "", never = "",
                     name = "301=Root\n302=Linked\n330=Paladin only\n" }
    place(1429, 0.4, 0.4)
    W.level = 5
    local own = {
        "A Root|QID|301|M|40,40" .. Z, "T Root|QID|301|M|41,40" .. Z,
        "A Linked|QID|302|PRE|301|M|42,40" .. Z,                 -- the index knows this one
        "A Guide only|QID|310|PRE|301|M|43,40" .. Z,             -- only this guide says 310 needs 301
        "C Guide only|QID|310|M|44,40" .. Z,
        "T Guide only|QID|310|M|45,40" .. Z,
        "A Needs guide only|QID|311|PRE|310|M|46,40" .. Z,       -- and 311 needs 310
        "T Needs guide only|QID|311|M|47,40" .. Z,
        "T Linked|QID|302|M|48,40" .. Z,
        "A Paladin only|QID|330|PRE|301|C|Paladin|M|49,41" .. Z, -- never this warrior's
        "T Paladin only|QID|330|C|Paladin|M|49,42" .. Z,
        "A Free|QID|320|M|49,40" .. Z, "T Free|QID|320|M|50,40" .. Z,
    }
    G.Register({ id = "wiki:reg:own", name = "Own PRE", type = "Quests", zone = 1429, faction = "Alliance", minlevel = 1, maxlevel = 10, text = table.concat(own, "\n") })
    G.Register({ id = "t:reg:other", name = "Other", type = "Quests", zone = 1429, faction = "Alliance", minlevel = 1, maxlevel = 10, text = table.concat({
        "A Root|QID|301|M|40,40" .. Z, "T Root|QID|301|M|41,40" .. Z, "A Solo|QID|340|M|42,42" .. Z, "T Solo|QID|340|M|42,43" .. Z }, "\n") })
    local function deps(q) local d = S.Dependents(q) table.sort(d) return table.concat(d, ",") end
    local function questsShown() local o, seen = {}, {} for _, s in ipairs(P.steps) do local q = s.qid and s.qid[1] if q and not seen[q] then seen[q] = true o[#o + 1] = q end end table.sort(o) return table.concat(o, ",") end

    -- (a) the loaded guide's own PRE edge the index does not have: this guide can never offer the dependent, so it is in
    --     the warning (as "in this guide") and out of this guide's rebuild with every step, but the index - what all
    --     guides share - does not lock it
    P.Load("wiki:reg:own")
    t("own PRE: the shared locks follow the index", deps(301) == "302,330", deps(301))
    local info = S.Describe(301)
    table.sort(info.locked)
    t("own PRE: the warning adds what this guide alone would lose", table.concat(info.locked, ",") == "302,310,311", table.concat(info.locked, ","))
    accept = false
    S.SkipQuest(301)
    local warn = prompts[#prompts] or ""
    t("own PRE: the warning names the guide-only dependents", warn:find("Guide only", 1, true) and warn:find("Needs guide only", 1, true), warn)
    t("another class's dependent is not named", not warn:find("Paladin only", 1, true), warn)
    t("the warning says which ones only this guide loses", warn:find("2 of them only here", 1, true), warn)
    t("...nor counted (3 quests need it, 3 in this guide)", warn:find("3 quests need it", 1, true) and warn:find("(3 in this guide, 0 in other guides)", 1, true), warn)
    t("...and the cost counts only this character's quests and steps", warn:find("removes 4 of your quests from this guide (9 steps)", 1, true), warn)
    accept = true
    S.SkipQuest(301)
    t("own PRE: the guide-only dependents are not locked in other guides", not S.IsRemoved(310) and not S.IsRemoved(311))
    t("another class's dependent is locked all the same", S.LockedBy(330) == 301)
    t("own PRE: nothing of a dependent stays in the rebuilt guide", questsShown() == "320", questsShown())
    t("own PRE: the current step is the free quest", P.current and P.current.qid and P.current.qid[1] == 320, P.current and P.current.title)
    local n0 = #NS.printed
    S.Unskip(310)
    t("own PRE: /cr unskip on one of them says why it is out", (NS.printed[n0 + 1] or ""):find("out of this guide", 1, true), NS.printed[n0 + 1])
    S.Unskip("all")
    t("unskip: the whole guide is back", #P.steps == #P.baseSteps and #P.steps == #own)

    -- (b) the drop made from another guide: that guide's view does not know 310; opening this guide later rebuilds it
    --     without 310 / 311 all the same (lazy, guide by guide)
    P.Load("t:reg:other")
    local r = S.SkipQuest(301, { confirm = true })
    t("drop from another guide: the index-known dependent is locked", S.LockedBy(302) == 301 and not S.IsRemoved(310), r)
    P.Load("wiki:reg:own")
    t("opened later: what this guide alone would strand is out of it", questsShown() == "320", questsShown())
    local base, gone = P.baseSteps, select(3, S.Project(P.baseSteps, nil, "wiki:reg:own"))
    t("...and in its rebuild key", S.PlanKey(base, nil, "wiki:reg:own") == S.PlanKey(base, gone) and gone[310] and gone[311])
    S.Unskip("all")
    NS.Replan.Cancel()

    -- (c) a travel step dropped by the travel rule takes its unlocated rider with it
    G.Register({ id = "t:reg:travel", name = "Travel", type = "Quests", zone = 1429, faction = "Alliance", minlevel = 1, maxlevel = 10, text = table.concat({
        "A Root|QID|201|M|40,40" .. Z, "T Root|QID|201|M|41,40" .. Z,
        "F Fly to Westfall|M|50,50" .. Z, "N Talk to the flight master there|",
        "A Child|QID|202|PRE|201|M|50,50" .. WF, "T Child|QID|202|M|51,51" .. WF,
        "R Back to Elwynn|M|42,42" .. Z, "A Keep|QID|220|M|48,48" .. Z, "T Keep|QID|220|M|48,49" .. Z }, "\n") })
    P.Load("t:reg:travel")
    S.SkipQuest(201, { confirm = true })
    local shown = {}
    for _, s in ipairs(P.steps) do shown[s.index] = true end
    t("travel step that served only dropped quests went", not shown[3])
    t("...and so did the note riding on it", not shown[4])
    t("travel step still serving a kept quest stays", shown[7] == true)
    t("rebuild promise holds (no orphaned rider or travel step)", checkRebuild(P.baseSteps, P.steps, S.Removed()) == nil, checkRebuild(P.baseSteps, P.steps, S.Removed()))
    S.Unskip("all")
    NS.Replan.Cancel()

    -- (d) a prerequisite cycle whose only way in is dropped goes with it (602 needs 601 or 603, 603 needs 602)
    t("cycle: dropping its only way in locks the whole cycle", deps(601) == "602,603", deps(601))
    W.quests[603] = "done"
    t("cycle: a cycle quest already done keeps the rest open", deps(601) == "", deps(601))
    W.quests[603] = nil
    local D0 = NS.QuestDeps
    NS.QuestDeps = { flavor = "era", pre = D0.pre .. "700:701\n701:700\n702:601;700\n", free = "", crumb = "", never = "700,701", name = D0.name }
    t("a quest the data never made obtainable is not locked by a drop", deps(601) == "602,603,702", deps(601))

    -- (e) a guide from another source adds its own PRE edges (one the index never freed)
    G.Register({ id = "owp:test:own", name = "Own source", type = "Quests", zone = 1429, faction = "Alliance", text = table.concat({
        "A Lead|QID|350|M|40,41" .. Z, "T Lead|QID|350|M|41,41" .. Z, "A After|QID|351|PRE|350|M|41,42" .. Z, "T After|QID|351|M|41,43" .. Z }, "\n") })
    P.Load("owp:test:own")
    t("a guide from another source adds its own PRE edges", deps(350) == "351", deps(350))
    NS.Replan.Cancel()
    -- (f) the re-plan model leaves out steps this character never sees (they would glue unrelated blocks together)
    local mlist = NS.Guide.Steps("wiki:reg:own")
    local M = NS.Replan.Build(mlist, { router = NS.Router, tick = function() end, isDone = function() return false end, level = 5 })
    local inModel = {}
    for _, s in ipairs(M.items) do inModel[s.index] = true end
    t("re-plan model: another class's steps are not planned", not inModel[10] and not inModel[11] and inModel[12] == true)
    print(("regressions: %d passed, %d failed so far"):format(passed, failed))
end

-- Nothing stranded in a rebuilt list: no quest keeps a step on screen while every accept of it this character can see
-- waits, through its own |PRE|, on a quest that is out (removed everywhere, or out of this guide), and no quest keeps its
-- objectives or turn-in while its accepts went.  Soft predecessors are read from the shipped index on their own here.
local function softSet(D)
    local free, crumb = {}, {}
    for q, rest in (D.free or ""):gmatch("(%d+):([^\n]+)") do
        free[tonumber(q)] = {}
        for p in rest:gmatch("%d+") do free[tonumber(q)][tonumber(p)] = true end
    end
    for p in (D.crumb or ""):gmatch("%d+") do crumb[tonumber(p)] = true end
    return function(qs, p)
        if crumb[p] then return true end
        for _, q in ipairs(qs or {}) do if free[q] and free[q][p] then return true end end
        return false
    end
end
local function stranded(NS, base, list, removed, isSoft)
    local inGuide, shown = {}, {}
    for _, s in ipairs(base) do if s.qid then for _, q in ipairs(s.qid) do inGuide[q] = true end end end
    for _, s in ipairs(list) do if s.qid then for _, q in ipairs(s.qid) do shown[q] = true end end end
    local function gone(p) return removed[p] or (inGuide[p] and not shown[p]) end
    local function blocked(s)
        local pre = s.pre
        if not pre or #pre == 0 then return false end
        if pre.andor == "and" then
            for _, p in ipairs(pre) do if gone(p) and not isSoft(s.qid, p) then return true end end
            return false
        end
        local counted = false
        for _, p in ipairs(pre) do
            if not (gone(p) and isSoft(s.qid, p)) then
                counted = true
                if not gone(p) then return false end
            end
        end
        return counted
    end
    local hasAcc, openAcc, accIn = {}, {}, {}
    for _, s in ipairs(base) do
        if s.qid and ACCEPT[s.action] and NS.Skip.EverApplies(s) then hasAcc[s.qid[1]] = true end
    end
    for _, s in ipairs(list) do
        if s.qid and ACCEPT[s.action] and NS.Skip.EverApplies(s) then
            accIn[s.qid[1]] = true
            if not blocked(s) then openAcc[s.qid[1]] = true end
        end
    end
    for _, s in ipairs(list) do
        local q = s.qid and s.qid[1]
        if q and hasAcc[q] and NS.Skip.EverApplies(s) then
            if not accIn[q] then return ("%s %d of quest %d kept, its accept went"):format(s.action, s.index, q) end
            if not openAcc[q] then return ("quest %d kept, every accept waits on a removed quest (%s %d)"):format(q, s.action, s.index) end
        end
    end
    return nil
end

local function realFlavor(fl)
    if not (exists("CompletionRoute/Data/QuestDeps_" .. fl .. ".lua") and exists("CompletionRoute/Guides/Imported_Wiki_" .. fl .. ".lua")) then
        print("skip " .. fl .. " (generated locally, gitignored: tools/gen_quest_deps.py, tools/wiki/gen_wiki_guides.py)")
        return
    end
    local t0 = os.clock()
    local NS = harness(fl, { real = true })
    local S, P, G, RP = NS.Skip, NS.Progress, NS.Guide, NS.Replan
    budgetMs = RP.FRAME_MS
    local accept = true
    S.Prompt = function(text, fn) if accept then fn() end return true end
    local pre, rev = parseDeps(NS.QuestDeps)
    -- (a) closure = brute-force fixpoint, on every quest with dependents (capped, deterministic)
    local roots = {}
    for p in pairs(rev) do roots[#roots + 1] = p end
    table.sort(roots)
    local step = math.max(1, math.floor(#roots / 60))
    local bad, n = 0, 0
    for i = 1, #roots, step do
        local q = roots[i]
        local d = S.Dependents(q)
        table.sort(d)
        n = n + 1
        if table.concat(d, ",") ~= bruteClosure(pre, q, rev) then bad = bad + 1 if bad <= 3 then print("     closure differs for " .. q .. ": " .. table.concat(d, ",") .. " vs " .. bruteClosure(pre, q, rev)) end end
    end
    t(fl .. ": closure equals the whole-index reachability reference on " .. n .. " roots", bad == 0, bad)
    local k = KNOWN[fl]
    if k then
        local d = S.Dependents(k[1])
        local set = {}
        for _, q in ipairs(d) do set[q] = true end
        local ok = true
        for q in k[2]:gmatch("%d+") do if not set[tonumber(q)] then ok = false end end
        if k[3] then table.sort(d) ok = ok and table.concat(d, ",") == k[2] end
        t(("%s: known chain %d -> %s%s"):format(fl, k[1], k[2], k[3] and " (exact)" or ""), ok, table.concat(d, ","))
    end
    -- (a2) nothing stranded, on guides of every family this client loads (the index's own, plus Blizzard
    --      storylines, whose |PRE| tags the index does not read): drop each quest an accept step waits on, one at a
    --      time, as Skip.Recompute would from that guide, and check the rebuilt list
    do
        local isSoft = softSet(NS.QuestDeps)
        -- storylines: the quest-line build the TOC loads (Imported_QuestLines_<fl>), or the older file in a checkout not
        -- regenerated since 2026-11-11 (both register the same story: ids, so only one is loaded)
        local story = "Guides/Imported_QuestLines_" .. fl .. ".lua"
        if not exists("CompletionRoute/" .. story) then story = "Guides/Imported_Storylines_" .. fl .. ".lua" end
        if exists("CompletionRoute/" .. story) then assert(loadfile("CompletionRoute/" .. story))("CompletionRoute", NS) end
        local fams = { wiki = {}, story = {} }
        for _, id in ipairs(G.list) do
            local fam = id:match("^(%a+):")
            if fams[fam] then table.insert(fams[fam], id) end
        end
        local checked, drops, bad, firstBad, guideOnly = 0, 0, 0, nil, 0
        for fam, ids in pairs(fams) do
            table.sort(ids)
            local stride = math.max(1, math.floor(#ids / 6))
            for i = 1, #ids, stride do
                local g = G.registry[ids[i]]
                local ok, steps = pcall(G.Steps, g.id)
                if ok and steps then
                    NS.player.faction = (g.faction == "Horde") and "Horde" or "Alliance"
                    local inGuide, ps, seenP = {}, {}, {}
                    for _, st in ipairs(steps) do if st.qid then inGuide[st.qid[1]] = true end end
                    for _, st in ipairs(steps) do
                        if st.qid and ACCEPT[st.action] and st.pre then
                            for _, p in ipairs(st.pre) do if inGuide[p] and not seenP[p] and #ps < 12 then seenP[p] = true ps[#ps + 1] = p end end
                        end
                    end
                    checked = checked + 1
                    for _, p in ipairs(ps) do
                        local removed = { [p] = true }
                        S.Closure(S.Index({ { id = g.id, steps = steps } }), { p }, removed)
                        local list, _, gone = S.Project(steps, removed, g.id)
                        for q in pairs(gone) do if not removed[q] then guideOnly = guideOnly + 1 end end
                        drops = drops + 1
                        local why = stranded(NS, steps, list, removed, isSoft)
                        if why then bad = bad + 1 firstBad = firstBad or (g.id .. " drop " .. p .. ": " .. why) end
                    end
                    g.steps = nil
                end
                if checked >= 18 then break end
            end
        end
        t(("%s: nothing stranded after %d single drops on %d guides (wiki, storylines; %d quests out of one guide only)"):format(fl, drops, checked, guideOnly),
            bad == 0 and drops > 0, firstBad)
        collectgarbage()
    end

    -- (b) sample guides: wiki zone guides with an in-guide chain, spread over the list
    local cands = {}
    for _, id in ipairs(G.list) do
        if id:match("^wiki:") then cands[#cands + 1] = id end
    end
    table.sort(cands)
    local picked = {}
    local stride = math.max(1, math.floor(#cands / (SAMPLES * 4)))
    for i = 1, #cands, stride do
        if #picked >= SAMPLES then break end
        local g = G.registry[cands[i]]
        local steps = G.Steps(g.id)
        local inGuide, best, bestN = {}, nil, 0
        for _, s in ipairs(steps) do if s.qid then inGuide[s.qid[1]] = true end end
        for q in pairs(inGuide) do
            local c = 0
            for _, d in ipairs(rev[q] or {}) do if inGuide[d] then c = c + 1 end end
            if c > bestN or (c == bestN and best and q < best) then best, bestN = q, c end
        end
        if best and bestN >= 1 and #steps >= 12 and #steps <= 400 and g.zone and MAPS[g.zone] then picked[#picked + 1] = { id = g.id, root = best } end
        g.steps = nil
    end
    t(fl .. ": found sample guides", #picked > 0, #picked)
    -- (b1) one search for a whole row costs exactly what FindPath costs pair by pair (scratch tables reused throughout)
    do
        local g = G.registry[picked[1].id]
        NS.player.faction = (g.faction == "Horde") and "Horde" or "Alliance"
        W.level = math.max(1, tonumber(g.minlevel) or 1)
        place(g.zone, 0.5, 0.5)
        local pts, st = {}, {}
        for _, s in ipairs(G.Steps(g.id)) do
            if s.zone then local x, y, i = NS.Router.StepWorld(s) if x then pts[#pts + 1] = { wx = x, wy = y, inst = i } st[#st + 1] = s end end
        end
        local opts = { speed = NS.Util.TravelSpeed(), walkFactor = NS.TravelGraph.WalkFactor(), graph = NS.TravelGraph.Snapshot(), scratch = {} }
        local maxd, np = 0, 0
        for k = 1, math.min(6, #pts) do
            local a = math.floor((k - 1) * #pts / 6) + 1
            local row = NS.Router.TravelRow(pts[a], pts, opts)
            for j = 1, #pts do
                local v = NS.Router.TravelSeconds(st[a], st[j])
                np = np + 1
                if (v == nil) ~= (row[j] == nil) then maxd = math.huge elseif v then maxd = math.max(maxd, math.abs(v - row[j])) end
            end
        end
        t(("%s: a row from one search equals FindPath pair by pair (%d pairs, max diff %.6f s)"):format(fl, np, maxd), np > 0 and maxd < 1e-6, maxd)
        g.steps = nil
    end
    local frames, saves, accepted, roundTripped, speedTested = {}, {}, 0, false, false
    for _, pk in ipairs(picked) do
        local g = G.registry[pk.id]
        -- a fresh character for each guide
        W.quests = {}
        S.Store(true).roots, S.Store(true).locks, S.Store(true).plans = {}, {}, {}
        S.version = S.version + 1
        NS.db.char.done, NS.db.char.skipped, NS.db.char.reopened, NS.db.char.stepReopened = {}, {}, {}, {}
        if NS.Account.me then
            NS.Account.me.done, NS.Account.me.skipped = NS.db.char.done, NS.db.char.skipped
            NS.Account.me.stepDone, NS.Account.me.stepSkipped, NS.Account.me.stepMeta = {}, {}, {}
        end
        NS.player.faction = (g.faction == "Horde") and "Horde" or "Alliance"
        UnitFactionGroup = function() return NS.player.faction end
        W.level = math.max(1, tonumber(g.minlevel) or 1)
        place(g.zone, 0.5, 0.5)
        NS.Router.Invalidate() NS.TravelGraph.Build()
        P.Load(pk.id)
        local base = P.steps
        local baseIdx = idx(base)
        -- tick the first three steps on screen that are not turn-ins (a ticked turn-in records its quest as done)
        local nt = 0
        for _, s in ipairs(P.steps) do
            if nt < 3 and not TURNIN[s.action] then P.MarkDone(s) nt = nt + 1 end
        end
        local ticks = {}
        for k in pairs(marks(NS, "stepDone", pk.id)) do ticks[#ticks + 1] = k end
        local r = S.SkipQuest(pk.root)
        local removed = S.Removed()
        local nLocked = 0
        for _ in pairs(S.Store().locks) do nLocked = nLocked + 1 end
        local tag = ("%s %s (drop %d, %d locked)"):format(fl, pk.id, pk.root, nLocked)
        t(tag .. ": dropped", r == "asked" or r == "skipped", r)
        local B = P.steps
        t(tag .. ": rebuild keeps every promise", checkRebuild(base, B, removed) == nil, checkRebuild(base, B, removed))
        local proj = S.Project(base, removed)
        t(tag .. ": counts match the rebuild", #B == #proj and #B < #base and P.VisibleDone() <= #B, #B .. "/" .. #base)
        local ticksKept = true
        for _, k in ipairs(ticks) do if not marks(NS, "stepDone", pk.id)[k] then ticksKept = false end end
        t(tag .. ": every tick survives the rebuild", ticksKept)
        -- re-plan, frame by frame, exactly as the client drives it
        -- planned: still to do and ever shown to this character (steps for another class / race / faction stay put)
        local plannable = {}
        for _, s in ipairs(B) do if (s.index or 0) > 0 and not P.IsDone(s) and RP.EverApplies(s) then plannable[s] = true end end
        local logStart, logCap = NS.Router.QuestLog()
        local J = RP.Job()
        t(tag .. ": re-plan running ('re-planning...')", RP.running and J ~= nil)
        if J then J.frameLog = {} end
        local guard = 0
        -- the first sample of each flavor runs with the collector paused: that isolates the slicing itself from the
        -- Lua collector's own pauses (which in the client land on whatever code happens to allocate)
        local paused = (pk == picked[1])
        if paused then collectgarbage("stop") end
        while RP.Step(RP.FRAME_MS) and guard < 2e6 do guard = guard + 1 end
        if paused then collectgarbage("restart") end
        local last = RP.last or {}
        for _, ms in ipairs((J and J.frameLog) or {}) do
            frames[#frames + 1] = ms
            if paused then pausedFrames[#pausedFrames + 1] = ms else allFrames[#allFrames + 1] = ms end
        end
        local N = P.steps
        local why = checkPlan(NS, B, N, plannable, W.level, logStart, logCap or 25)
        t(tag .. ": re-plan keeps every rule", why == nil, why)
        local cb, cn = routeCost(NS, B, plannable), routeCost(NS, N, plannable)
        t(tag .. (": never slower than baked minus removed (%.0f s -> %.0f s)"):format(cb, cn), cn <= cb + 0.01, cn - cb)
        local xb, xn = routeCost(NS, B, plannable, true), routeCost(NS, N, plannable, true)
        t(tag .. (": ...nor through the steps with their own point (%.0f s -> %.0f s)"):format(xb, xn), xn <= xb + 0.5, xn - xb)
        if last.accepted then
            accepted = accepted + 1
            -- applying a new order is one Progress.Refresh in its own frame (the live window inside it keeps its own
            -- 3 ms budget, as after any step tick): measured, not part of the re-plan's slices
            local lb = NS.db.profile.routing.liveBudgetMs
            NS.db.profile.routing.liveBudgetMs = nil
            P.cursor = nil
            NS.StepOrder.plan = nil
            local a0 = debugprofilestop()
            P.Refresh(true)
            applyMs[#applyMs + 1] = debugprofilestop() - a0
            NS.db.profile.routing.liveBudgetMs = lb
            t(tag .. ": an accepted re-plan beats the margin", (cb - cn) >= (last.margin or 0) - 0.01, ("test %.1f -> %.1f (saves %.1f); planner %s -> %s, margin %s"):format(cb, cn, cb - cn, tostring(last.baseCost), tostring(last.newCost), tostring(last.margin)))
        else
            t(tag .. ": a re-plan that did not win leaves the order alone", N == B)
        end
        saves[#saves + 1] = { id = pk.id, base = cb, new = cn, accepted = last.accepted, steps = last.steps, frames = last.frames,
                              cpu = last.cpu, moves = last.stats and (last.stats.moves + last.stats.rev) or 0, pairs = last.stats and last.stats.pairs or 0,
                              searches = last.stats and last.stats.searches or 0, proxy = last.exactWorse, pass = last.pass }
        -- the spine entry built on this guide shares its quests: rebuilt when opened
        local shown = idx(P.steps)
        local spine
        for _, id in ipairs(G.list) do if G.registry[id].part == pk.id then spine = id break end end
        if spine then
            -- keep the chain from moving on: an entry whose remaining steps are all above the level would hand over to `next`
            local nxt = G.registry[spine].next
            G.registry[spine].next = nil
            P.Load(spine)
            G.registry[spine].next = nxt
            local sp = P.steps
            t(tag .. ": spine entry loaded", P.guide.id == spine, P.guide.id)
            t(tag .. ": spine entry sharing the quests is rebuilt on open", checkRebuild(P.baseSteps, sp, removed) == nil and #sp < #P.baseSteps,
                spine .. " " .. tostring(checkRebuild(P.baseSteps, sp, removed)) .. " " .. #sp .. "/" .. #P.baseSteps)
            RP.Cancel()
            P.Load(pk.id)
            t(tag .. ": back on the guide: the same list (saved re-plan applied)", idx(P.steps) == shown)
        end
        -- reload once per flavor: the same rebuilt guide from the saved variables
        if not roundTripped then
            roundTripped = true
            local NS2 = harness(fl, { real = true, db = roundTrip(CompletionRouteDB), chardb = roundTrip(CompletionRouteCharDB) })
            NS2.Account.Init()
            NS2.player.faction = NS.player.faction
            NS2.Progress.Load(pk.id)
            t(tag .. ": reload shows the same rebuilt guide", idx(NS2.Progress.steps) == shown and not NS2.Replan.running)
            NS2 = nil
            collectgarbage()
            -- the second harness reset the shared fake world: put this character back
            W.level = math.max(1, tonumber(g.minlevel) or 1)
            place(g.zone, 0.5, 0.5)
        end
        -- unskip: the identical list again, then a re-plan
        NS.Skip.Unskip(pk.root)
        t(tag .. ": unskip restores the identical list", idx(P.steps) == baseIdx, idx(P.steps))
        t(tag .. ": unskip re-plans", RP.running)
        RP.Cancel()
        -- the player mounts part-way through a job: the job keeps the cost set it started with (same numbers as above)
        if not speedTested and (last.frames or 0) >= 10 then
            speedTested = true
            S.Store(true).plans = {}
            S.SkipQuest(pk.root, { confirm = true })
            local n2, J2 = 0, RP.Job()
            while RP.Step(RP.FRAME_MS) do
                n2 = n2 + 1
                if n2 == 3 then GetUnitSpeed = function() return 30 end end
            end
            GetUnitSpeed = function() return 0 end
            local l2 = RP.last or {}
            t(tag .. (": mounting mid-job (frame 3 of %d) changes nothing: %.1f -> %.1f s as before"):format(n2, l2.baseCost or -1, l2.newCost or -1),
                J2 ~= nil and n2 > 3 and math.abs((l2.baseCost or -1) - (last.baseCost or -2)) < 1e-6 and math.abs((l2.newCost or -1) - (last.newCost or -2)) < 1e-6
                and l2.accepted == last.accepted, ("%s/%s vs %s/%s"):format(tostring(l2.baseCost), tostring(l2.newCost), tostring(last.baseCost), tostring(last.newCost)))
            NS.Skip.Unskip(pk.root)
            RP.Cancel()
        end
    end
    table.sort(frames)
    if #frames > 0 then
        print(("     %s re-plan frames: %d, p50 %.2f ms, p99 %.2f ms, max %.2f ms"):format(fl, #frames, frames[math.ceil(#frames * 0.5)],
            frames[math.ceil(#frames * 0.99)], frames[#frames]))
    end
    for _, sv in ipairs(saves) do
        print(("     %s %-28s %4d steps  %6.0f s -> %6.0f s  (%s, %d moves, %d pairs from %d searches, %d frames, %.0f ms CPU)"):format(fl, sv.id, sv.steps or 0,
            sv.base, sv.new, sv.accepted and ("accepted" .. (sv.pass == 2 and ", |M|-only search" or "")) or (sv.proxy and "kept baseline: the gain was only at zone stand-ins" or "kept baseline"),
            sv.moves, sv.pairs, sv.searches or 0, sv.frames or 0, sv.cpu or 0))
    end
    print(("     %s: %d guides, %d re-plans accepted, %.1f s"):format(fl, #picked, accepted, os.clock() - t0))
end

for _, fl in ipairs(FLAVORS) do realFlavor(fl) collectgarbage() end

local jitOn = jit and jit.status and jit.status()
local function frameStats(list, label)
    table.sort(list)
    local over = 0
    for _, ms in ipairs(list) do if ms > FRAME_LIMIT_MS then over = over + 1 end end
    print(("re-plan per-frame CPU, %s, %d frames: p50 %.2f ms, p99 %.2f ms, max %.2f ms, %d over %.1f ms (budget %.1f ms, %s)"):format(label,
        #list, list[math.ceil(#list * 0.5)], list[math.ceil(#list * 0.99)], list[#list], over, FRAME_LIMIT_MS, budgetMs,
        jitOn and "JIT ON - run with luajit -joff for the client's number" or "interpreter"))
    return list[#list], list[math.ceil(#list * 0.99)], over
end
if #pausedFrames > 0 then
    local mx = frameStats(pausedFrames, "collector paused")
    t("re-plan slices never take more than " .. FRAME_LIMIT_MS .. " ms in one frame (collector paused)", mx <= FRAME_LIMIT_MS, mx)
end
if #allFrames > 0 then
    local mx, p99, over = frameStats(allFrames, "collector running")
    t("re-plan frames: p99 under " .. FRAME_LIMIT_MS .. " ms with the collector running", p99 <= FRAME_LIMIT_MS, p99)
    t("re-plan frames never take more than " .. FRAME_LIMIT_MS .. " ms, collector running", mx <= FRAME_LIMIT_MS, over .. " of " .. #allFrames .. ", max " .. mx)
end
if #applyMs > 0 then
    table.sort(applyMs)
    print(("applying an accepted re-plan (one Progress.Refresh, live window at its 3 ms budget): %d times, median %.2f ms, max %.2f ms"):format(#applyMs,
        applyMs[math.ceil(#applyMs / 2)], applyMs[#applyMs]))
end
print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
print("ALL SKIP TESTS PASSED")
