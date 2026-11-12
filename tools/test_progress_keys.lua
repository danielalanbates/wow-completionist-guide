-- CompletionRoute :: tools/test_progress_keys.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- Offline tests of stable step keys (Core/Guide.lua "Stable step keys", Core/Account.lua, docs/STEP_KEYS.md):
--   1. the key recipe on a synthetic guide: quest steps by action + quest ids + objective, other steps by a hash of
--      the title's words, repeats numbered; coordinates, zone and note never count; parsing results and the route
--      checksum are the same with and without keys
--   2. a regenerated guide (one line inserted, one deleted, one coordinate moved, one block moved): ticks, skips,
--      a step stepped back to and a quest skip stay on their steps across a SavedVariables round trip; marks keyed by
--      author index would have moved; a deleted step's tick counts nowhere; the saved re-plan is not applied to the new
--      data; a baked route order (Data/RouteOrder) still applies by author index and checksum
--   3. migration from a fixture of the SavedVariables layout before step keys (tools/fixtures/progress_keys_*_SV.lua),
--      on a baked guide (list order is not author order, as in game): index marks of this character (done, skipped,
--      reopened) and of other characters of this game type move to keys, records of other clients and of unknown game
--      type are left alone, marks with no step are counted, not placed; an alt whose record another character migrated
--      still imports its own stepped-back marks when it logs in
--   4. idempotence (twice in one session, after a reload, after a downgraded client wrote more index marks, a route
--      sweep after a data update), a re-plan saved under the old rebuild key, and the downgrade: the old tables are
--      untouched and the previous release's own code (git commit before this branch) still reads the progress made
--      before the update
--   5. tools/sync_progress.lua carries the keyed marks and migration records between client folders (temp files)
--   6. every flavor's real guides: keys unique in every guide (0 collisions), no two different texts share a hash,
--      parse results unchanged on a sample, key building cost (run with luajit -joff for the client's number)
--   7. real guides regenerated the same way as in 2 (CR_KEYS_SAMPLES per flavor, default 3)
-- Run from the repo root:  luajit -joff tools/test_progress_keys.lua [era tbc mop retail forever]
package.path = "./?.lua;" .. package.path
local FLAVORS = {}
for i = 1, #arg do FLAVORS[#FLAVORS + 1] = arg[i] end
if #FLAVORS == 0 then FLAVORS = { "era", "tbc", "mop", "retail", "forever" } end
local SAMPLES = tonumber(os.getenv("CR_KEYS_SAMPLES") or "") or 3
local OLD_COMMIT = os.getenv("CR_KEYS_OLD_COMMIT") or "b322bb6"   -- integration head this branch started from
local passed, failed, skipped = 0, 0, 0
local function t(name, cond, detail)
    if cond then passed = passed + 1 print("ok   " .. name)
    else failed = failed + 1 print("FAIL " .. name .. (detail ~= nil and (" :: " .. tostring(detail)) or "")) end
    return cond
end
local function skip(name, why) skipped = skipped + 1 print("skip " .. name .. " :: " .. why) end
local function exists(p) local f = io.open(p, "r") if f then f:close() return true end return false end
local function sh(cmd) local r = os.execute(cmd) return r == true or r == 0 end
local TMP = (os.getenv("CR_TEST_TMP") or "/private/tmp/claude-501") .. "/cr_test_progress_keys_" .. tostring(os.time())
if not sh("mkdir -p '" .. TMP .. "'") then TMP = "/tmp/cr_test_progress_keys_" .. tostring(os.time()) sh("mkdir -p '" .. TMP .. "'") end
local JIT = (jit and jit.status and jit.status()) and "JIT on" or "JIT off"

-- ---------------------------------------------------------------------------
-- Harness: the real addon on stubs, one flavor, optional saved variables, optional real guide data.
--   opts.db / opts.chardb   SavedVariables tables     opts.real   load the flavor TOC's guide and data files
--   opts.files              extra files (relative to CompletionRoute/), loaded when present
--   opts.code               a directory holding another CompletionRoute/Core and /Routing (the previous release)
-- ---------------------------------------------------------------------------
local TOC = { era = 11507, tbc = 20506, mop = 50504, retail = 120100, forever = 16001 }
local TOCFILE = { era = "CompletionRoute_Vanilla.toc", tbc = "CompletionRoute_TBC.toc", mop = "CompletionRoute_Mists.toc",
                  retail = "CompletionRoute.toc", forever = "CompletionRoute_Forever.toc" }
local TAXI = { era = "Data/Taxi_era.lua", tbc = "Data/Taxi_tbc.lua", mop = "Data/Taxi_mop.lua", retail = "Data/Taxi_retail.lua",
               forever = "Data/Taxi_forever.lua" }
local W
local function tocData(flavor)
    local out = {}
    local fh = io.open("CompletionRoute/" .. TOCFILE[flavor], "r")
    if not fh then return out end
    for line in fh:lines() do
        line = line:gsub("\r$", ""):gsub("\\", "/")
        if line:match("^Guides/Imported_.*%.lua$") or line:match("^Data/RouteOrder_") or line:match("^Data/QuestDeps_") then out[#out + 1] = line end
    end
    fh:close()
    return out
end
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
    local function path(p)
        if opts.code and (p:match("^Core/") or p:match("^Routing/")) then return opts.code .. "/CompletionRoute/" .. p end
        return "CompletionRoute/" .. p
    end
    local function load(p, optional)
        if optional and not exists(path(p)) then return false end
        assert(loadfile(path(p)))(ADDON, NS)
        return true
    end
    local files = { "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", TAXI[flavor] }
    if flavor == "forever" then files[#files + 1] = "Data/MapFix_forever.lua" end
    for _, f in ipairs({ "Data/Transit.lua", "Data/Access.lua", "Data/Inns.lua", "Data/ZoneAliases.lua", "Data/Roads_ek.lua",
        "Data/Roads_kalimdor.lua", "Routing/CostModel.lua", "Routing/TravelGraph.lua", "Routing/Roads.lua", "Routing/StepOrder.lua", "Routing/Router.lua",
        "Routing/Replan.lua", "Core/Account.lua", "Core/Professions.lua", "Core/Progress.lua", "Core/Skip.lua", "Core/Recommend.lua" }) do
        files[#files + 1] = f
    end
    -- the previous release (opts.code) predates Routing/CostModel.lua (branch cost-model): load it only when present there
    for _, f in ipairs(files) do load(f, opts.code ~= nil and f == "Routing/CostModel.lua") end
    load("Data/Imported_Entrances.lua", true)
    if opts.real then
        for _, f in ipairs(tocData(flavor)) do load(f, true) end
        for _, f in ipairs({ "Guides/Leveling/Alliance_Human_01_06_Northshire.lua", "Guides/Leveling/Horde_Orc_Troll_01_06_ValleyOfTrials.lua" }) do load(f, true) end
    end
    for _, f in ipairs(opts.files or {}) do load(f, true) end
    CompletionRouteDB, CompletionRouteCharDB = opts.db, opts.chardb
    for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", "CompletionRoute") end
    NS.printed = {}
    NS.Print = function(_, ...) local p = {} for i = 1, select("#", ...) do p[#p + 1] = tostring(select(i, ...)) end NS.printed[#NS.printed + 1] = table.concat(p, " ") end
    NS.Debug, NS.Error = function() end, function() end
    NS.db.profile.routing.liveBudgetMs = 1e9
    NS.db.profile.routing.reorder = false     -- author (or baked) order on screen: this file tests marks, not routing
    NS.Guide.SuggestNext = function() return nil end
    NS.Guide.Suggest = function() return nil end
    NS.TravelGraph.Build()
    return NS
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
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b)
            if type(a) ~= type(b) then return type(a) == "number" end
            return a < b
        end)
        local parts = {}
        for _, k in ipairs(keys) do
            local ks = type(k) == "number" and ("[" .. ser(k) .. "]") or ("[" .. ("%q"):format(tostring(k)) .. "]")
            local xs = ser(v[k])
            if xs then parts[#parts + 1] = ks .. "=" .. xs end
        end
        return "{" .. table.concat(parts, ",") .. "}"
    elseif tv == "string" then return ("%q"):format(v)
    elseif tv == "number" then return ("%.17g"):format(v)
    elseif tv == "boolean" then return tostring(v) end
    return nil
end
local function roundTrip(v) return assert(loadstring("return " .. ser(v)))() end
local function same(a, b) return ser(a) == ser(b) end
local function count(set) local n = 0 for _ in pairs(set or {}) do n = n + 1 end return n end
local function loadSV(file, name)
    local env = {}
    local fn = assert(loadfile(file))
    setfenv(fn, env)
    fn()
    return env[name]
end
local function marks(NSx, field, gid) local all = NSx.Account.me and NSx.Account.me[field] return (all and all[gid]) or {} end

-- ---------------------------------------------------------------------------
-- The synthetic guide, before and after a regeneration
-- ---------------------------------------------------------------------------
local Z = "|Z|1429; Elwynn Forest|"
local V1 = {
    "A Alpha|QID|201|M|40,40" .. Z,                         -- 1
    "N Talk to the guard at the gate|M|41,41" .. Z,         -- 2
    "C Alpha|QID|201|QO|1|M|42,42" .. Z,                    -- 3
    "C Alpha|QID|201|QO|2|M|43,43" .. Z,                    -- 4
    "T Alpha|QID|201|M|40,40" .. Z,                         -- 5
    "A Beta|QID|202|M|44,44" .. Z,                          -- 6
    "R Run to Goldshire|M|45,45" .. Z,                      -- 7
    "C Beta|QID|202|M|46,46" .. Z,                          -- 8
    "N Buy some food|M|47,47" .. Z,                         -- 9
    "T Beta|QID|202|M|44,44" .. Z,                          -- 10
    "A Gamma|QID|203|PRE|202|M|48,48" .. Z,                 -- 11
    "T Gamma|QID|203|M|48,49" .. Z,                         -- 12
    "A Delta|QID|204|M|50,50" .. Z,                         -- 13
    "N Use the torch on the pile|",                         -- 14 rider of 13
    "T Delta|QID|204|M|50,51" .. Z,                         -- 15
    "N Talk to the guard at the gate.|M|52,52" .. Z,        -- 16 same words as 2: a repeat
    "T Two at once|QID|206^205|M|53,53" .. Z,               -- 17
    "K Kill wolves|QID|207|M|54,54" .. Z,                   -- 18
    "K Kill the alpha wolf|QID|207|M|55,55" .. Z,           -- 19 same quest, no objective: a repeat
}
-- v2: a line inserted at the top, line 9 deleted, line 3's point moved, the block 13-15 moved up behind line 5
local V2 = { "N Welcome to the zone|" }
for i = 1, 5 do V2[#V2 + 1] = V1[i] end
V2[4] = V1[3]:gsub("|M|42,42", "|M|42.6,41.3")
for i = 13, 15 do V2[#V2 + 1] = V1[i] end
for _, i in ipairs({ 6, 7, 8, 10, 11, 12, 16, 17, 18, 19 }) do V2[#V2 + 1] = V1[i] end
-- where each v1 step is in v2 (nil = deleted)
local MOVE = { [1] = 2, [2] = 3, [3] = 4, [4] = 5, [5] = 6, [6] = 10, [7] = 11, [8] = 12, [10] = 13, [11] = 14, [12] = 15,
               [13] = 7, [14] = 8, [15] = 9, [16] = 16, [17] = 17, [18] = 18, [19] = 19 }
-- a baked order of v1 for section 3: every list position but one (13) differs from the author index
local BAKED = "19,1,18,2,17,3,16,4,15,5,14,6,13,7,12,8,11,9,10"
local function register(NS, id, lines)
    local G = NS.Guide
    local g = G.registry[id]
    if g then g.text, g.steps = table.concat(lines, "\n"), nil return g end
    return G.Register({ id = id, name = "Keys " .. id, type = "Quests", zone = 1429, faction = "Alliance", minlevel = 1, maxlevel = 10,
                        text = table.concat(lines, "\n") })
end
local function author(steps) local a = {} for _, s in ipairs(steps) do if (s.index or 0) > 0 then a[s.index] = s end end return a end

-- ---------------------------------------------------------------------------
-- 1) The key recipe
-- ---------------------------------------------------------------------------
do
    local NS = harness("era")
    local G = NS.Guide
    register(NS, "t:keys:a", V1)
    local A = author(G.Steps("t:keys:a"))
    t("quest steps: action + quest id", A[1].key == "A201" and A[5].key == "T201", A[1].key .. " " .. A[5].key)
    t("objective index is part of the key", A[3].key == "C201.1" and A[4].key == "C201.2", A[3].key .. " " .. A[4].key)
    t("several quest ids: sorted, so the written order does not matter", A[17].key == "T205+206", A[17].key)
    t("same quest, no objective: numbered by occurrence", A[18].key == "K207" and A[19].key == "K207#2", A[18].key .. " " .. A[19].key)
    t("a step without a quest: action + hash of its words", A[2].key:match("^N~[0-9a-z]+$") ~= nil, A[2].key)
    t("...case and punctuation fold: a repeat of the same words is numbered", A[16].key == A[2].key .. "#2", A[16].key)
    local seen, dup = {}, 0
    for _, s in ipairs(A) do if seen[s.key] then dup = dup + 1 end seen[s.key] = true end
    t("every key in the guide is different", dup == 0, dup)
    local function base(line) return (G.StepBase(G.ParseLine(line, 1, nil))) end
    t("coordinates, zone and note are not part of a key",
        base("N Talk to the guard at the gate|M|10.5,80|Z|1436; Westfall|N|A new note.|O|") == base(V1[2])
        and base("A Alpha|QID|201|M|77,12|Z|1436; Westfall|N|x|") == "A201")
    t("...nor flags and tags that are not its identity", base("C Alpha|QID|201|QO|1|M|1,1|NC|S|") == "C201.1")
    t("words that differ make a different key", base("N Talk to the guard at the tower|") ~= base(V1[2]))
    t("coordinates written into a title do not count", base("N Talk to the guard at 41.2, 40.8|") == base("N Talk to the guard at|"))
    t("an objective given as text is hashed", base("C Wolves|QID|207|QO|Kill 10 wolves|"):match("^C207%.[0-9a-z]+$") ~= nil, base("C Wolves|QID|207|QO|Kill 10 wolves|"))
    t("achievement, recipe and skill ids are part of an other step's key",
        base("M Bars|ACH|6;12|") ~= base("M Bars|ACH|6;13|") and base("M Bars|SKILL|Mining;50|") ~= base("M Bars|SKILL|Mining;75|")
        and base("M Bars|RECIPE|2657|") ~= base("M Bars|"))
    t("the action is part of a key", base("N Buy some food|") ~= base("B Buy some food|"))
    -- access chains: their own prefix, the chain's own numbering
    local chain = { key = "test_chain", title = "Test chain", steps = "A Unlock|QID|900|M|40,40" .. Z .. "\nN Talk|\nN Talk|\n" }
    local acc = NS.Access.ParseSteps(chain, "t:keys:a")
    t("access-chain steps: '@chain/' + the same recipe", acc[1].key == "@test_chain/A900" and acc[3].key == acc[2].key .. "#2", acc[1].key .. " " .. tostring(acc[3].key))
    -- parse results and the route checksum are the same with and without keys
    local function sig(steps)
        local out = {}
        local function enc(v)
            if type(v) ~= "table" then return tostring(v) end
            local ks = {}
            for k in pairs(v) do ks[#ks + 1] = tostring(k) end
            table.sort(ks)
            local p = {}
            for _, k in ipairs(ks) do
                local val = v[k] if val == nil then val = v[tonumber(k)] end
                if k ~= "key" then p[#p + 1] = k .. "=" .. enc(val) end
            end
            return "{" .. table.concat(p, ",") .. "}"
        end
        for i, s in ipairs(steps) do out[i] = enc(s) end
        return table.concat(out, "\n")
    end
    local withKeys = sig(G.Steps("t:keys:a"))
    local sumWith = G.RouteChecksum(author(G.Steps("t:keys:a")))
    local real = G.AssignKeys
    G.AssignKeys = function() end
    G.registry["t:keys:a"].steps = nil
    local plain = G.Steps("t:keys:a")
    G.AssignKeys = real
    t("parsing results are identical with and without keys (synthetic guide)", sig(plain) == withKeys)
    t("...and the route checksum", G.RouteChecksum(author(plain)) == sumWith)
    t("a step without a key is never done and cannot be ticked", (function()
        NS.Progress.Load("t:keys:a")
        local s = { action = "N", title = "made up", index = 5 }
        NS.Progress.MarkDone(s)
        return NS.Progress.IsDone(s) == false
    end)())
end

-- ---------------------------------------------------------------------------
-- 2) A regenerated guide keeps every mark on its step
-- ---------------------------------------------------------------------------
local v1Sum, v2Sum
do
    local NS = harness("era")
    local P, G, S, RP, A = NS.Progress, NS.Guide, NS.Skip, NS.Replan, NS.Account
    register(NS, "t:keys:a", V1)
    A.Init()
    place(1429, 0.1, 0.9)
    W.level = 5
    P.Load("t:keys:a")
    local s1 = author(P.steps)
    -- the player: ticks 1-4 by hand, steps back once (4 is reopened), ticks 9, 13, 16, skips the run step 7
    for i = 1, 4 do P.MarkDone(s1[i], true) end
    t("current step after four ticks", P.current == s1[5], P.current and P.current.index)
    P.Undo()
    t("Back reopens step 4", P.current == s1[4] and marks(NS, "stepDone", "t:keys:a")[s1[4].key] == nil and NS.db.char.stepReopened["t:keys:a"][s1[4].key] == true)
    for _, i in ipairs({ 9, 13, 16 }) do P.MarkDone(s1[i], true) end
    P.Skip(s1[7])
    local done = marks(NS, "stepDone", "t:keys:a")
    t("ticks are stored by step key", done[s1[2].key] and done["A201"] and done["C201.1"] and done["A204"] and count(done) == 6, count(done))
    t("nothing is written into the index-keyed tables of earlier releases",
        next(A.me.done["t:keys:a"] or {}) == nil and next(A.me.skipped["t:keys:a"] or {}) == nil and next((NS.db.char.reopened or {})["t:keys:a"] or {}) == nil)
    -- a quest skip (Core/Skip.lua): Delta leaves the guide with its rider; its accept stays ticked by key
    local r = S.SkipQuest(204, { confirm = true })
    local gone = {}
    for _, i in ipairs({ 13, 14, 15 }) do gone[s1[i]] = true end
    local cutOk = true
    for _, s in ipairs(P.steps) do if gone[s] then cutOk = false end end
    t("quest skip drops Delta and its rider", r == "skipped" and cutOk and #P.steps == 16, #P.steps)
    local guard = 0
    while RP.Step(1e9) and guard < 1000 do guard = guard + 1 end
    local plan = S.Store().plans["t:keys:a"]
    t("the re-plan decision is saved under a step-key rebuild key", plan and type(plan.k) == "string" and plan.k:match("^k1:") ~= nil, plan and plan.k)
    v1Sum = G.GuideSum("t:keys:a")
    t("the guide's checksum is stored next to the marks", A.me.stepMeta["t:keys:a"] and A.me.stepMeta["t:keys:a"].sum == v1Sum and A.me.stepMeta["t:keys:a"].v == 1)
    -- what the old storage would have shown after the regeneration: the same author indices on the new steps
    local idxDone = { 1, 2, 3, 9, 13, 16 }

    -- the regeneration, after a logout and login
    local db, chardb = roundTrip(CompletionRouteDB), roundTrip(CompletionRouteCharDB)
    local NS2 = harness("era", { db = db, chardb = chardb })
    local P2, G2, S2, RP2, A2 = NS2.Progress, NS2.Guide, NS2.Skip, NS2.Replan, NS2.Account
    register(NS2, "t:keys:a", V2)
    A2.Init()
    place(1429, 0.1, 0.9)
    W.level = 5
    P2.Load("t:keys:a")
    local s2 = author(P2.baseSteps)
    v2Sum = G2.GuideSum("t:keys:a")
    t("v2 is a different guide (checksum changed)", v2Sum ~= v1Sum and #s2 == 19, v1Sum .. " -> " .. tostring(v2Sum))
    local want = { done = {}, skipped = {}, reopened = {} }
    for _, i in ipairs({ 1, 2, 3, 13, 16 }) do want.done[MOVE[i]] = true end
    want.skipped[MOVE[7]] = true
    want.reopened[MOVE[4]] = true
    local d2, k2, r2 = marks(NS2, "stepDone", "t:keys:a"), marks(NS2, "stepSkipped", "t:keys:a"), NS2.db.char.stepReopened["t:keys:a"] or {}
    local wrong = {}
    for i, s in ipairs(s2) do
        if (d2[s.key] == true) ~= (want.done[i] == true) then wrong[#wrong + 1] = "done@" .. i end
        if (k2[s.key] == true) ~= (want.skipped[i] == true) then wrong[#wrong + 1] = "skip@" .. i end
        if (r2[s.key] == true) ~= (want.reopened[i] == true) then wrong[#wrong + 1] = "reopen@" .. i end
    end
    t("after the regeneration every tick, skip and reopened step is on its own step", #wrong == 0, table.concat(wrong, " "))
    t("the inserted step is not done", not P2.IsDone(s2[1]))
    t("the moved point kept its tick (C Alpha objective 1)", P2.IsDone(s2[4]) and s2[4].coords[1].x > 0.425)
    t("the reopened step is still open", not P2.IsDone(s2[5]))
    t("the step skipped by hand is still skipped (the run step, now 11)", P2.IsDone(s2[11]) and k2[s2[11].key])
    local wouldMove = 0
    for _, i in ipairs(idxDone) do if not want.done[i] then wouldMove = wouldMove + 1 end end
    t(("the same marks by author index would sit on %d wrong steps (the bug this fixes)"):format(wouldMove), wouldMove >= 3, wouldMove)
    -- the deleted step's tick is kept (harmless) and counts nowhere
    local stale = marks(NS2, "stepDone", "t:keys:a")[s1[9].key]
    t("the deleted step's tick matches no step and counts nowhere", stale == true and (function()
        for _, s in ipairs(s2) do if s.key == s1[9].key then return false end end
        return true end)())
    -- the quest skip: still out of this guide, exactly Delta's steps
    local outKeys = {}
    for _, s in ipairs(P2.steps) do outKeys[s.key] = true end
    t("the quest skip still drops exactly Delta and its rider (now 7-9)", #P2.steps == 16 and not outKeys[s2[7].key] and not outKeys[s2[8].key]
        and not outKeys[s2[9].key] and outKeys[s2[1].key], #P2.steps)
    t("visible done counts the steps on screen only (4: not the dropped accept, not the deleted step)", P2.VisibleDone() == 4, P2.VisibleDone())
    -- the saved re-plan belonged to v1: not applied, a new one runs
    local key2 = S2.PlanKey(P2.baseSteps)
    t("the re-plan saved on v1 is not applied to v2 (key differs), a new one starts", not S2.HasPlan("t:keys:a", key2) and RP2.running == true)
    t("the stored checksum follows the guide now loaded", (A2.me.stepMeta["t:keys:a"] or {}).sum == v2Sum)
    local report = table.concat(P2.MarksReport(), "\n")
    t("/cr marks: counts on this guide and the one mark whose step is gone", report:find("5 done, 1 skipped, 1 stepped back to", 1, true)
        and report:find("1 mark belongs", 1, true) and report:find(v2Sum, 1, true), report)
    guard = 0
    while RP2.Step(1e9) and guard < 1000 do guard = guard + 1 end
    S2.Unskip(204)
    t("unskip: Delta is back and its accept is still ticked", P2.IsDone(s2[7]) and #P2.steps == 19)
    local n, pct = A2.GuideProgress("t:keys:a", #P2.steps, "char")
    t("guide progress counts the keys the new guide has (5 ticks + 1 skip)", n == 6 and pct == 32, n .. " " .. pct)
    -- account-wide: another character's tick follows its step too
    A2.SetScope("account")
    NS2.db.global.chars["Alt-Test"] = { name = "Alt", flavor = "era", gametype = "era", stepDone = { ["t:keys:a"] = { [s1[12].key] = true } },
                                        stepMeta = { ["t:keys:a"] = { v = 1, mig = 0 } }, done = {}, skipped = {} }
    P2.cursor = nil
    t("another character's keyed tick counts on the moved step (T Gamma, now 15)", P2.IsDone(s2[15]) and not P2.IsDone(s2[12]))
    A2.SetScope("char")

    -- a baked route order (Data/RouteOrder) still applies by author index and checksum; keys do not depend on it
    local NS3 = harness("era")
    local G3 = NS3.Guide
    local plainKeys = {}
    register(NS3, "t:keys:b", V1)
    for _, s in ipairs(G3.Steps("t:keys:b")) do plainKeys[s.index] = s.key end
    local auth = author(G3.Steps("t:keys:b"))
    local rev = {}
    for i = 19, 1, -1 do rev[#rev + 1] = i end
    NS3.RouteOrder = { ["t:keys:b"] = { n = 19, sum = G3.RouteChecksum(auth), o = table.concat(rev, ",") } }
    G3.registry["t:keys:b"].steps = nil
    local baked = G3.Steps("t:keys:b")
    local sameKeys = true
    for _, s in ipairs(baked) do if plainKeys[s.index] ~= s.key then sameKeys = false end end
    t("a baked order applies (reversed list) and every step keeps its key", G3.registry["t:keys:b"].baked == true and baked[1].index == 19 and sameKeys)
    register(NS3, "t:keys:b", V2)
    local after = G3.Steps("t:keys:b")
    t("the stale bake is not applied to the regenerated guide (checksum differs)", not G3.registry["t:keys:b"].baked and after[1].index == 1)
end

-- ---------------------------------------------------------------------------
-- 3) Migration from the SavedVariables layout before step keys
-- ---------------------------------------------------------------------------
local FIX_ACCT, FIX_CHAR = "tools/fixtures/progress_keys_account_SV.lua", "tools/fixtures/progress_keys_character_SV.lua"
local REAL = "wiki:era:1429:Alliance"
local postUpgradeDB, postUpgradeChar
do
    local db0, char0 = loadSV(FIX_ACCT, "CompletionRouteDB"), loadSV(FIX_CHAR, "CompletionRouteCharDB")
    local NS = harness("era", { db = roundTrip(db0), chardb = roundTrip(char0), files = { "Guides/Imported_Wiki_era.lua", "Data/RouteOrder_era.lua" } })
    local P, G, A = NS.Progress, NS.Guide, NS.Account
    register(NS, "t:keys:a", V1)
    -- in game most guides are baked (Data/RouteOrder): the list the migration is handed is not in author order, so an
    -- index -> key map built from list positions would put every mark on another step
    NS.RouteOrder = NS.RouteOrder or {}
    NS.RouteOrder["t:keys:a"] = { n = 19, sum = G.RouteChecksum(author(G.Steps("t:keys:a"))), o = BAKED }
    G.registry["t:keys:a"].steps = nil
    A.Init()
    place(1429, 0.1, 0.9)
    W.level = 5
    local chars = NS.db.global.chars
    t("fixture: nothing is migrated before a guide is opened", chars["Tester-Test"].stepMeta and next(chars["Tester-Test"].stepMeta) == nil)
    P.Load("t:keys:a")
    local s = author(P.baseSteps)
    local moved = 0
    for i, x in ipairs(P.baseSteps) do if x.index ~= i then moved = moved + 1 end end
    t("the guide is loaded baked: " .. moved .. " of 19 list positions are not the author index", G.registry["t:keys:a"].baked == true and moved >= 17, moved)
    local me = A.me
    local function keysOf(set) local o = {} for k in pairs(set or {}) do o[#o + 1] = k end table.sort(o) return table.concat(o, " ") end
    local function keysAt(list) local o = {} for _, i in ipairs(list) do o[#o + 1] = s[i].key end table.sort(o) return table.concat(o, " ") end
    t("this character's ticks (author indices 1 2 3 9 16) are on their steps' keys", keysOf(me.stepDone["t:keys:a"]) == keysAt({ 1, 2, 3, 9, 16 }), keysOf(me.stepDone["t:keys:a"]))
    t("its skipped step (7)", keysOf(me.stepSkipped["t:keys:a"]) == keysAt({ 7 }))
    t("its reopened step (4, character file)", keysOf(NS.db.char.stepReopened["t:keys:a"]) == keysAt({ 4 }))
    local meta = me.stepMeta["t:keys:a"]
    t("migration record: version, checksum, 7 imported, 2 without a step (index 99, access-chain index -2)",
        meta and meta.v == 1 and meta.sum == G.GuideSum("t:keys:a") and meta.mig == 7 and meta.lost == 2, meta and ser(meta))
    t("IsDone after migration: ticks and the skip count, the reopened step does not",
        P.IsDone(s[1]) and P.IsDone(s[9]) and P.IsDone(s[16]) and P.IsDone(s[7]) and not P.IsDone(s[4]) and not P.IsDone(s[5]))
    local alt = chars["Alt-Test"]
    t("another character of this game type is migrated too (5, 10)", alt.stepMeta and alt.stepMeta["t:keys:a"] and keysOf(alt.stepDone["t:keys:a"]) == keysAt({ 5, 10 }),
        alt.stepDone and keysOf(alt.stepDone["t:keys:a"]))
    t("a record without a game type on an era client is left alone (Era and Forever both say 'era')", chars["Old-Test"].stepDone == nil and chars["Old-Test"].stepMeta == nil)
    t("records of other clients are left alone (retail, mop)", chars["Ret-Other"].stepDone == nil and chars["Mop-Other"].stepDone == nil)
    register(NS, "t:keys:empty", V1)
    t("a guide whose old tables are empty: no migration record until it is played", A.Migrate("t:keys:empty", G.Steps("t:keys:empty")) == 0
        and me.stepMeta["t:keys:empty"] == nil and alt.stepMeta["t:keys:empty"] == nil)
    -- account-wide: the alt's migrated ticks count; the unmigrated records' do not
    A.SetScope("account")
    P.cursor = nil
    t("account-wide: the alt's step 5 and 10 count, the retail record's 11 does not", P.IsDone(s[5]) and P.IsDone(s[10]) and not P.IsDone(s[11]))
    A.SetScope("char")
    -- the old tables are untouched, in both files
    for _, k in ipairs({ "Tester-Test", "Alt-Test", "Old-Test", "Ret-Other", "Mop-Other" }) do
        t("old tables of " .. k .. " are untouched", same(chars[k].done, db0.chars[k].done) and same(chars[k].skipped, db0.chars[k].skipped))
    end
    t("old reopened table (character file) is untouched", same(NS.db.char.reopened, char0.reopened))
    -- a real generated guide (when present): indices 1 2 4 of it land on its steps 1 2 4
    if G.registry[REAL] then
        local list = G.Steps(REAL)
        local n = A.GuideProgress(REAL, #list, "char")
        local rs = author(list)
        t("real guide " .. REAL .. ": old ticks 1 2 4 5 migrate on first view (guide list)", n == 4 and me.stepDone[REAL] and me.stepDone[REAL][rs[1].key] and me.stepDone[REAL][rs[2].key]
            and me.stepDone[REAL][rs[4].key] and me.stepDone[REAL][rs[5].key] and not me.stepDone[REAL][rs[3].key], n)
        -- with the real bake (Data/RouteOrder_era.lua, applied while its checksum matches the generated guide) author step 5
        -- is further down the list than position 5
        if G.registry[REAL].baked and list[5].index > 5 then
            t(("real guide baked: list position 5 is author step %d; the old tick 5 is on author step 5, not on it"):format(list[5].index),
                me.stepDone[REAL][rs[5].key] and not me.stepDone[REAL][list[5].key])
        else
            skip("real guide baked order", "Data/RouteOrder_era.lua does not apply to the current " .. REAL .. " or keeps position 5")
        end
        P.Load(REAL)
        t("...and show as done when it is loaded", P.IsDone(rs[1]) and P.IsDone(rs[4]) and P.IsDone(rs[5]) and not P.IsDone(rs[3]))
        P.Load("t:keys:a")
    else
        skip("real guide migration", REAL .. " not generated here")
    end

    -- 4) idempotence
    local snap = roundTrip(CompletionRouteDB)
    local snapChar = roundTrip(CompletionRouteCharDB)
    t("migrating again in the same session changes nothing", A.Migrate("t:keys:a", P.baseSteps, true) == 0 and same(CompletionRouteDB, snap) and same(CompletionRouteCharDB, snapChar))
    P.Load("t:keys:a")
    t("loading the guide again changes nothing", same(CompletionRouteDB, snap) and same(CompletionRouteCharDB, snapChar))
    -- progress made on this release (step 18 ticked), then a logout
    P.MarkDone(s[18], true)
    postUpgradeDB, postUpgradeChar = roundTrip(CompletionRouteDB), roundTrip(CompletionRouteCharDB)
    local NS2 = harness("era", { db = roundTrip(postUpgradeDB), chardb = roundTrip(postUpgradeChar) })
    register(NS2, "t:keys:a", V1)
    NS2.Account.Init()
    place(1429, 0.1, 0.9)
    NS2.Progress.Load("t:keys:a")
    local function markTables(db, cdb)
        local o = {}
        for k, c in pairs(db.chars) do o[k] = { c.done, c.skipped, c.stepDone, c.stepSkipped, c.stepMeta } end
        return ser(o) .. ser({ cdb.reopened, cdb.stepReopened })
    end
    t("after a reload nothing is migrated a second time", markTables(CompletionRouteDB, CompletionRouteCharDB) == markTables(postUpgradeDB, postUpgradeChar))
    -- a downgraded client wrote more index marks (maybe on older data): never imported once a guide is migrated
    local down = roundTrip(postUpgradeDB)
    down.chars["Tester-Test"].done["t:keys:a"][12] = true
    down.chars["Alt-Test"].done["t:keys:a"][11] = true
    local NS3 = harness("era", { db = down, chardb = roundTrip(postUpgradeChar) })
    register(NS3, "t:keys:a", V1)
    NS3.Account.Init()
    place(1429, 0.1, 0.9)
    NS3.Progress.Load("t:keys:a")
    local s3 = author(NS3.Progress.baseSteps)
    t("index marks a downgraded client writes later are not imported", not NS3.Progress.IsDone(s3[12])
        and not (NS3.db.global.chars["Alt-Test"].stepDone["t:keys:a"] or {})[s3[11].key])

    -- a re-plan saved under the rebuild key of the release before step keys: converted once, its order kept
    local NS4 = harness("era", { db = roundTrip(postUpgradeDB), chardb = roundTrip(postUpgradeChar) })
    local P4, S4, A4 = NS4.Progress, NS4.Skip, NS4.Account
    register(NS4, "t:keys:a", V1)
    A4.Init()
    place(1429, 0.1, 0.9)
    local base4 = author(NS4.Guide.Steps("t:keys:a"))
    local st = S4.Store(true)
    st.roots[204] = "t:keys:a"
    S4.Recompute()
    local _, _, gone = S4.Project(base4, S4.Removed(), "t:keys:a")
    local order = "2,1,3-12,16-19"     -- a made-up saved order of the 16 steps left (13-15 are out)
    st.plans["t:keys:a"] = { k = S4.LegacyPlanKey(base4, gone), o = order }
    P4.Load("t:keys:a")
    local shown = {}
    for i, x in ipairs(P4.steps) do shown[i] = x.index end
    t("a re-plan saved under the old rebuild key is converted and applied", st.plans["t:keys:a"].k == S4.PlanKey(P4.baseSteps, gone)
        and table.concat(shown, ",") == "2,1,3,4,5,6,7,8,9,10,11,12,16,17,18,19" and not NS4.Replan.running, table.concat(shown, ","))
end

-- ---------------------------------------------------------------------------
-- 3b) An alt's stepped-back marks live in the alt's own character file: another character that migrates the alt's
--     account record cannot see them, so the alt imports them on its own next load
-- 4c) A route sweep (/cr sweep, Core/Sweep.lua; /cr verifyall swaps the same scratch store) after the migration never
--     imports old marks again, on the same data or after a data update
-- ---------------------------------------------------------------------------
do
    local db0, char0 = loadSV(FIX_ACCT, "CompletionRouteDB"), loadSV(FIX_CHAR, "CompletionRouteCharDB")
    local GID = "t:keys:a"
    -- one session: log in as name (stubs.lua's own player is Tester), load the guide
    local function login(name, db, chardb, lines, files)
        local NS = harness("era", { db = db, chardb = chardb, files = files })
        UnitName = function() return name end
        NS.player.name, NS.player.realm = name, "Test"
        register(NS, GID, lines or V1)
        NS.Account.Init()
        place(1429, 0.1, 0.9)
        W.level = 5
        NS.Progress.Load(GID)
        return NS, author(NS.Progress.baseSteps)
    end
    -- the alt's character file, before step keys: it stepped back to A Beta (6); done / skipped are its record's copies
    local altChar = { done = { [GID] = { [5] = true, [10] = true } }, skipped = { [GID] = {} }, reopened = { [GID] = { [6] = true } },
                      laps = {}, parked = {}, knownTaxi = {}, bind = {} }
    -- control: the alt logs in first
    local NSa, sa = login("Alt", roundTrip(db0), roundTrip(altChar))
    local wantKey = sa[6].key
    t("alt first: its stepped-back step (6) is imported and stays open", NSa.db.char.stepReopened[GID][wantKey] == true and not NSa.Progress.IsDone(sa[6]))
    -- the main logs in first and opens the guide: the alt's record is migrated (done 5 and 10), its reopened set cannot be
    local NSm = login("Tester", roundTrip(db0), roundTrip(char0))
    local altRec = NSm.db.global.chars["Alt-Test"]
    t("main first: the alt's record is migrated, its stepped-back marks are left to the alt (ro = false)",
        altRec.stepMeta[GID] and altRec.stepMeta[GID].ro == false and altRec.stepMeta[GID].mig == 2, ser(altRec.stepMeta[GID]))
    t("...the main's own record has ro = true", NSm.Account.me.stepMeta[GID].ro == true)
    local NSb, sb = login("Alt", roundTrip(CompletionRouteDB), roundTrip(altChar))
    local metaB = NSb.Account.me.stepMeta[GID]
    t("then the alt logs in: its stepped-back step (6) is imported and stays open", (NSb.db.char.stepReopened[GID] or {})[sb[6].key] == true
        and not NSb.Progress.IsDone(sb[6]) and NSb.Progress.IsDone(sb[5]) and NSb.Progress.IsDone(sb[10]), sb[6].key)
    t("...recorded once (ro = true, 3 imported in all), the old table untouched", metaB.ro == true and metaB.mig == 3 and NSb.db.char.reopened[GID][6] == true, ser(metaB))
    t("...and not imported again (the alt steps forward, reloads)", (function()
        NSb.Progress.MarkDone(sb[6], true)
        local NSc, sc = login("Alt", roundTrip(CompletionRouteDB), roundTrip(CompletionRouteCharDB))
        return NSc.Account.Migrate(GID, NSc.Progress.baseSteps, true) == 0 and next(NSc.db.char.stepReopened[GID] or {}) == nil and NSc.Progress.IsDone(sc[6])
    end)())

    -- 4c) the main migrates (step 4 stepped back to), ticks step 4 forward again, logs out
    local NS1, s1 = login("Tester", roundTrip(db0), roundTrip(char0))
    NS1.Progress.MarkDone(s1[4], true)
    local afterDB, afterChar = roundTrip(CompletionRouteDB), roundTrip(CompletionRouteCharDB)
    local function markTables(db, cdb)
        local c = db.chars["Tester-Test"]
        return ser({ c.stepDone, c.stepSkipped, c.stepMeta, cdb.stepReopened, c.done, c.skipped, cdb.reopened })
    end
    for _, case in ipairs({ { "same data", V1 }, { "after a data update", V2 } }) do
        local NS, s = login("Tester", roundTrip(afterDB), roundTrip(afterChar), case[2], { "Core/Sweep.lua" })
        local P = NS.Progress
        local before = markTables(CompletionRouteDB, CompletionRouteCharDB)
        local c1, c2
        for _, x in ipairs(s) do if x.key == "C201.1" then c1 = x elseif x.key == "C201.2" then c2 = x end end
        t("sweep, " .. case[1] .. ": before it, objectives 1 and 2 of Alpha are done, nothing stepped back to",
            P.IsDone(c1) and P.IsDone(c2) and next(NS.db.char.stepReopened[GID] or {}) == nil)
        -- run the real Core/Sweep.lua over this guide (its frame's OnUpdate pumped by hand)
        local realCF, fr = CreateFrame, nil
        CreateFrame = function(...) local f = realCF(...) fr = f return f end
        NS.RunRouteSweep("keys " .. GID)
        CreateFrame = realCF
        local pumps = 0
        while fr and fr.scripts.OnUpdate and pumps < 100 do fr.scripts.OnUpdate(fr, 0) pumps = pumps + 1 end
        local res = CompletionRouteDB.routeSweep or {}
        t("sweep, " .. case[1] .. ": the sweep ran over the guide and finished", res.finishedAt ~= nil and res.total == 1 and NS.Account.scratch == nil, ser(res))
        t("sweep, " .. case[1] .. ": the old stepped-back mark is not imported again (no step stepped back to)",
            next(NS.db.char.stepReopened[GID] or {}) == nil, ser(NS.db.char.stepReopened[GID]))
        t("sweep, " .. case[1] .. ": objectives 1 and 2 of Alpha are still done", P.IsDone(c1) and P.IsDone(c2))
        t("sweep, " .. case[1] .. ": every mark table and migration record is as before the sweep", markTables(CompletionRouteDB, CompletionRouteCharDB) == before)
    end
end

-- ---------------------------------------------------------------------------
-- 4b) Downgrade: the previous release's own code reads the files this release wrote
-- ---------------------------------------------------------------------------
do
    local oldRoot = TMP .. "/old"
    local ok = sh("mkdir -p '" .. oldRoot .. "' && /usr/bin/git cat-file -e " .. OLD_COMMIT .. "^{commit} 2>/dev/null && /usr/bin/git archive "
        .. OLD_COMMIT .. " CompletionRoute/Core CompletionRoute/Routing | tar -x -C '" .. oldRoot .. "'")
    if not (ok and exists(oldRoot .. "/CompletionRoute/Core/Progress.lua")) then
        skip("downgrade with the previous release's code", "git commit " .. OLD_COMMIT .. " not available")
    elseif not postUpgradeDB then
        skip("downgrade with the previous release's code", "no post-upgrade files (section 3 failed)")
    else
        local okRun, err = pcall(function()
            local NS = harness("era", { db = roundTrip(postUpgradeDB), chardb = roundTrip(postUpgradeChar), code = oldRoot })
            t("previous release's code: no step keys in it (it is the old reader)", NS.Guide.AssignKeys == nil)
            register(NS, "t:keys:a", V1)
            NS.Account.Init()
            place(1429, 0.1, 0.9)
            W.level = 5
            NS.Progress.Load("t:keys:a")
            local s = author(NS.Progress.baseSteps)
            local P = NS.Progress
            t("previous release: the ticks made before the update are there (1 2 3 9 16)", P.IsDone(s[1]) and P.IsDone(s[2]) and P.IsDone(s[3]) and P.IsDone(s[9]) and P.IsDone(s[16]))
            t("previous release: the skipped step (7) and the reopened step (4) as before", P.IsDone(s[7]) and not P.IsDone(s[4]))
            t("previous release: a tick made after the update (18) is not seen (documented)", not P.IsDone(s[18]))
            local n = NS.Account.GuideProgress("t:keys:a", #s, "char")
            t("previous release: guide progress reads its own tables (6 of 19, plus the 2 marks without a step)", n == 8, n)
        end)
        t("previous release's code loads the new files without an error", okRun, err)
    end
end

-- ---------------------------------------------------------------------------
-- 5) tools/sync_progress.lua carries keyed marks and migration records between clients
-- ---------------------------------------------------------------------------
if postUpgradeDB then
    local wow = TMP .. "/wow"
    local function svPath(fl) return wow .. "/" .. fl .. "/WTF/Account/ACCT/SavedVariables/CompletionRoute.lua" end
    local function write(fl, db)
        sh("mkdir -p '" .. svPath(fl):match("^(.*)/") .. "'")
        local f = assert(io.open(svPath(fl), "w")) f:write("CompletionRouteDB = " .. ser(db) .. "\n") f:close()
    end
    write("_classic_era_", postUpgradeDB)
    write("_retail_", loadSV(FIX_ACCT, "CompletionRouteDB"))   -- an older copy: the layout before step keys
    local okSync = sh("luajit tools/sync_progress.lua --wow '" .. wow .. "' > '" .. TMP .. "/sync.log' 2>&1")
    local a, b = loadSV(svPath("_classic_era_"), "CompletionRouteDB"), loadSV(svPath("_retail_"), "CompletionRouteDB")
    local me0 = postUpgradeDB.chars["Tester-Test"]
    t("sync: runs", okSync, TMP .. "/sync.log")
    t("sync: keyed marks and migration records reach the other client's file",
        same(b.chars["Tester-Test"].stepDone, me0.stepDone) and same(b.chars["Tester-Test"].stepSkipped, me0.stepSkipped)
        and same(b.chars["Tester-Test"].stepMeta, me0.stepMeta) and same(b.chars["Alt-Test"].stepMeta, postUpgradeDB.chars["Alt-Test"].stepMeta))
    t("sync: both files hold the same characters", same(a.chars, b.chars))
    t("sync: old index tables are kept (unioned, unchanged here)", same(a.chars["Tester-Test"].done, me0.done))
    local function body(p) local f = io.open(p) local x = f:read("*a") f:close() return (x:gsub('%["lastSync"%] = "[^"]*"', "")) end
    local before = body(svPath("_retail_"))
    sh("luajit tools/sync_progress.lua --wow '" .. wow .. "' > /dev/null 2>&1")
    t("sync: a second run changes nothing (idempotent)", body(svPath("_retail_")) == before)
else
    skip("sync_progress", "no post-upgrade files (section 3 failed)")
end

-- ---------------------------------------------------------------------------
-- 6) + 7) Every flavor's real guides
-- ---------------------------------------------------------------------------
local ROWS = {}
local function realFlavor(fl)
    if not exists("CompletionRoute/" .. TAXI[fl]) or not exists("tools/maps_" .. fl .. ".lua") then skip(fl .. " real guides", "no data") return end
    local NS = harness(fl, { real = true })
    local G, P, S, A = NS.Guide, NS.Progress, NS.Skip, NS.Account
    A.Init()
    local row = { fl = fl, guides = 0, steps = 0, quest = 0, other = 0, repeats = 0, dup = 0, hashColl = 0, parseMs = 0, keyMs = 0,
                  maxKeyMs = 0, maxSteps = 0, sampled = 0, sampleDiff = 0 }
    local realAssign = G.AssignKeys
    local function sig(steps)
        local out = {}
        local function enc(v)
            if type(v) ~= "table" then return tostring(v) end
            local ks = {}
            for k in pairs(v) do if k ~= "key" then ks[#ks + 1] = k end end
            table.sort(ks, function(x, y) return tostring(x) < tostring(y) end)
            local p = {}
            for _, k in ipairs(ks) do p[#p + 1] = tostring(k) .. "=" .. enc(v[k]) end
            return "{" .. table.concat(p, ",") .. "}"
        end
        for i, s in ipairs(steps) do out[i] = enc(s) end
        return table.concat(out, "\n")
    end
    local candidates = {}
    for gi, id in ipairs(G.list) do
        local g = G.registry[id]
        local c0 = os.clock()
        local okS, steps = pcall(G.Steps, id)
        local pms = (os.clock() - c0) * 1000
        row.parseMs = row.parseMs + pms
        if okS and steps and #steps > 0 then
            row.guides = row.guides + 1
            row.steps = row.steps + #steps
            local auth = author(steps)
            local seen, texts = {}, {}
            for _, s in ipairs(auth) do
                if seen[s.key] then row.dup = row.dup + 1 end
                seen[s.key] = true
                if s.key:find("#%d+$") then row.repeats = row.repeats + 1 end
                local base, pre = G.StepBase(s)
                if s.qid and #s.qid > 0 then row.quest = row.quest + 1 else row.other = row.other + 1 end
                if pre then
                    if texts[base] and texts[base] ~= pre then row.hashColl = row.hashColl + 1 end
                    texts[base] = texts[base] or pre
                end
            end
            -- key building alone, on the parsed steps (what G.Steps adds to a parse)
            local k0 = os.clock()
            realAssign(auth)
            local km = (os.clock() - k0) * 1000
            row.keyMs = row.keyMs + km
            if #steps > row.maxSteps then row.maxSteps, row.maxId, row.maxKeyMs, row.maxParseMs = #steps, id, km, pms end
            -- parse results with and without keys, on every 40th guide
            if gi % 40 == 1 then
                local before = sig(auth)
                G.AssignKeys = function() end
                g.steps = nil
                local plain = G.Steps(id)
                G.AssignKeys = realAssign
                row.sampled = row.sampled + 1
                if sig(author(plain)) ~= before or G.RouteChecksum(author(plain)) ~= G.RouteChecksum(auth) then row.sampleDiff = row.sampleDiff + 1 end
            end
            local nq, nOther = 0, 0
            for _, s in ipairs(auth) do
                if s.qid and (s.action == "A") then nq = nq + 1 end
                if not s.qid then nOther = nOther + 1 end
            end
            if #candidates < SAMPLES and tostring(id):match("^wiki:") and #steps >= 30 and #steps <= 400 and nq >= 3 and (gi % 7 == 0) then candidates[#candidates + 1] = id end
        end
        if not (P.guide and P.guide.id == id) then g.steps = nil end
    end
    ROWS[#ROWS + 1] = row
    t(("%s: every key is unique within its guide (%d guides, %d steps, %d duplicate keys)"):format(fl, row.guides, row.steps, row.dup), row.guides > 0 and row.dup == 0, row.dup)
    t(("%s: no two different step texts share a hash within a guide (%d)"):format(fl, row.hashColl), row.hashColl == 0, row.hashColl)
    t(("%s: parse results and route checksums identical with and without keys (%d sampled guides)"):format(fl, row.sampled), row.sampled > 0 and row.sampleDiff == 0, row.sampleDiff)
    -- access chains of this flavor
    local accDup = 0
    for _, a in ipairs(NS.AccessData or {}) do
        local list = NS.Access.ParseSteps(a, "x")
        local seen = {}
        for _, s in ipairs(list) do if seen[s.key] or not s.key:find("^@") then accDup = accDup + 1 end seen[s.key] = true end
    end
    t(fl .. ": access-chain steps have unique '@chain/' keys", accDup == 0, accDup)

    -- 7) regenerate sample guides, with marks
    for _, id in ipairs(candidates) do
        local g = G.registry[id]
        local text = type(g.text) == "function" and g.text() or g.text
        local lines = {}
        for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do lines[#lines + 1] = line end
        local function ident(line) return (line:gsub("|M|[^|]*", "|M|")) end
        local identCount = {}
        for _, l in ipairs(lines) do local k = ident(l) identCount[k] = (identCount[k] or 0) + 1 end
        -- a fresh character
        A.me.stepDone, A.me.stepSkipped, A.me.stepMeta = {}, {}, {}
        A.me.done, A.me.skipped = {}, {}
        NS.db.char.done, NS.db.char.skipped = A.me.done, A.me.skipped
        NS.db.char.stepReopened, NS.db.char.reopened = {}, {}
        local st = S.Store(true)
        st.roots, st.locks, st.plans = {}, {}, {}
        S.version = S.version + 1
        W.quests = {}
        NS.player.faction = (g.faction == "Horde") and "Horde" or "Alliance"
        UnitFactionGroup = function() return NS.player.faction end
        W.level = math.max(1, tonumber(g.minlevel) or 1)
        g.steps = nil
        local zone
        for _, s in ipairs(G.Steps(id)) do if not zone and s.zone then zone = s.zone end end
        zone = zone or tonumber(g.zone)
        if not (zone and place(zone, 0.5, 0.5)) then place(1429, 0.5, 0.5) end
        P.Load(id)
        local auth = author(P.baseSteps)
        local n = #auth
        -- what the auto-completer ticks by itself here (level steps, a run-to step at the zone centre...)
        local auto = {}
        for k in pairs(marks(NS, "stepDone", id)) do auto[k] = true end
        -- marks on steps whose line is unique in the guide: 6 ticks and 2 skips spread over it
        local marked, picks = {}, {}
        for k = 1, 8 do
            local i = math.max(1, math.floor(k * n / 9))
            while i <= n and (marked[i] or identCount[ident(lines[auth[i].line])] ~= 1) do i = i + 1 end
            if i <= n then marked[i] = (k <= 6) and "done" or "skip" picks[#picks + 1] = i end
        end
        for i, kind in pairs(marked) do
            if kind == "done" then P.MarkDone(auth[i], true) else P.Skip(auth[i]) end
        end
        -- a quest skip: the first quest whose accept is in the guide and that nothing needs
        local dropQ
        for _, s in ipairs(auth) do
            if s.action == "A" and s.qid and #s.qid == 1 and not marked[s.index] and #S.Dependents(s.qid[1]) == 0 then dropQ = s.qid[1] break end
        end
        if dropQ then S.SkipQuest(dropQ, { confirm = true }) end
        NS.Replan.Cancel()
        -- the regeneration: insert a line at the top, delete an unmarked line (~45%), move the point of the first ticked
        -- step that has one, move a block of 3 lines from ~75% to ~25%
        local markedLine = {}
        for i in pairs(marked) do markedLine[auth[i].line] = true end
        local dropLines = {}
        if dropQ then for _, s in ipairs(auth) do if s.qid then for _, q in ipairs(s.qid) do if q == dropQ then dropLines[s.line] = true end end end end end
        local delAt = math.floor(#lines * 0.45)
        while delAt <= #lines and (markedLine[delAt] or dropLines[delAt] or not G.ParseLine(lines[delAt], delAt, nil)) do delAt = delAt + 1 end
        local movedLine
        for _, i in ipairs(picks) do
            if marked[i] == "done" and lines[auth[i].line]:find("|M|[%d%.]+,[%d%.]+") then movedLine = auth[i].line break end
        end
        local new = {}
        for li, line in ipairs(lines) do
            if li == movedLine then line = line:gsub("|M|([%d%.]+),([%d%.]+)", function(x, y) return ("|M|%.1f,%.1f"):format(tonumber(x) + 0.7, tonumber(y) - 0.4) end, 1) end
            new[li] = line
        end
        local from = math.floor(#new * 0.75)
        local block = { table.remove(new, from), table.remove(new, from), table.remove(new, from) }
        local to = math.floor(#new * 0.25)
        for k = 3, 1, -1 do table.insert(new, to, block[k]) end
        -- the deleted line: find it again by content after the move (the block move may have shifted it)
        local delLine = lines[delAt]
        for li, line in ipairs(new) do if line == delLine then table.remove(new, li) break end end
        table.insert(new, 1, "N Inserted by tools/test_progress_keys.lua|")
        g.text, g.steps = table.concat(new, "\n"), nil
        P.Load(id)
        local auth2 = author(P.baseSteps)
        local byIdent = {}
        for _, s in ipairs(auth2) do
            local k = ident(new[s.line] or "")
            byIdent[k] = s
        end
        local bad, found, mine = {}, 0, {}
        local d2, k2 = marks(NS, "stepDone", id), marks(NS, "stepSkipped", id)
        for i, kind in pairs(marked) do
            local s2 = byIdent[ident(lines[auth[i].line])]
            if not s2 then bad[#bad + 1] = "lost:" .. i
            else
                found = found + 1
                mine[s2] = true
                if kind == "done" and not d2[s2.key] then bad[#bad + 1] = "done:" .. i end
                if kind == "skip" and not k2[s2.key] then bad[#bad + 1] = "skip:" .. i end
            end
        end
        -- any other marked step must be one the auto-completer ticked itself (before, or now)
        local extra = {}
        for _, s in ipairs(auth2) do
            if (d2[s.key] or k2[s.key]) and not mine[s] and not auto[s.key] and not P.CheckStep(s) then extra[#extra + 1] = s.index .. ":" .. s.key end
        end
        t(("%s %s (%d steps): %d marks on their steps after insert/delete/move/reorder"):format(fl, id, n, found), #bad == 0 and found == #picks, table.concat(bad, " "))
        t(("%s %s: no other step is marked"):format(fl, id), #extra == 0, table.concat(extra, " "))
        t(("%s %s: the inserted step is not done"):format(fl, id), not P.IsDone(auth2[1]))
        if dropQ then
            local left = false
            for _, s in ipairs(P.steps) do if s.qid then for _, q in ipairs(s.qid) do if q == dropQ then left = true end end end end
            t(("%s %s: the skipped quest %d is still out of the regenerated guide"):format(fl, id, dropQ), not left)
        end
        NS.Replan.Cancel()
        g.text, g.steps = text, nil
    end
    collectgarbage()
end
for _, fl in ipairs(FLAVORS) do realFlavor(fl) end

if #ROWS > 0 then
    print("")
    print(("Step keys on real guides (%s, os.clock CPU; the client runs plain Lua 5.1 = luajit -joff):"):format(JIT))
    print("flavor   guides    steps   quest   other  repeats  dupKeys hashColl   parse ms  keys ms  keys%  largest guide: steps, parse ms, keys ms")
    for _, r in ipairs(ROWS) do
        print(("%-7s %7d %8d %7d %7d %8d %8d %8d %10.0f %8.1f %5.1f%%  %s: %d, %.0f, %.1f"):format(r.fl, r.guides, r.steps, r.quest, r.other, r.repeats,
            r.dup, r.hashColl, r.parseMs, r.keyMs, r.parseMs > 0 and 100 * r.keyMs / r.parseMs or 0, tostring(r.maxId), r.maxSteps, r.maxParseMs or 0, r.maxKeyMs))
    end
    print("(parse ms includes key building; keys ms = G.AssignKeys alone on the parsed steps; per guide: microseconds per step = keys ms * 1000 / steps)")
end
print(("%d passed, %d failed, %d skipped"):format(passed, failed, skipped))
if failed > 0 then os.exit(1) end
print("ALL PROGRESS KEY TESTS PASSED")
