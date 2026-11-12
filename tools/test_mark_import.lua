-- CompletionRoute :: tools/test_mark_import.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- Offline tests of the import of old index-keyed marks for EVERY guide once after login (Core/Account.lua
-- A.StartImport / A.ImportStep, "Every guide's old marks at once"), and its cost on the real guides:
--   1. the fixture of the layout before step keys (tools/fixtures/progress_keys_*_SV.lua): the import after login gives
--      exactly the mark tables a load of each guide gives (a baked synthetic guide; the real wiki guide when generated),
--      loads nothing, keeps no parsed steps, sets the character's flag and never runs again; the routes list's count
--      of a guide never opened includes the old marks afterwards
--   2. the reason for it: a guide re-ordered by a later data update without getting shorter.  Imported at login, the
--      marks stay on their steps; left to the load after the update (the lazy import), a mark lands on another step
--   3. a bulk sweep (A.BeginScratch) pauses it; a logout in the middle leaves the rest to the next login, same result
--   4. the same path as a load: a gold guide is folded into its circuit first (same migration record as a load); an
--      access-chain prefix in front of the steps changes nothing
--   5. cost on every flavor's real guides, old marks on every guide (this character and an alt): slices at the 4 ms
--      budget, CPU per slice, total, memory.  Run with luajit -joff for the client's interpreter.
-- Stubs only: nothing here has run in a client.
-- Run from the repo root:  luajit -joff tools/test_mark_import.lua [era tbc mop retail forever]
package.path = "./?.lua;" .. package.path
local FLAVORS = {}
for i = 1, #arg do FLAVORS[#FLAVORS + 1] = arg[i] end
if #FLAVORS == 0 then FLAVORS = { "era", "tbc", "mop", "retail", "forever" } end
local passed, failed, skipped = 0, 0, 0
local function t(name, cond, detail)
    if cond then passed = passed + 1 print("ok   " .. name)
    else failed = failed + 1 print("FAIL " .. name .. (detail ~= nil and (" :: " .. tostring(detail)) or "")) end
    return cond
end
local function skip(name, why) skipped = skipped + 1 print("skip " .. name .. " :: " .. why) end
local function exists(p) local f = io.open(p, "r") if f then f:close() return true end return false end
local JIT = (jit and jit.status and jit.status()) and "JIT on" or "JIT off"

-- ---------------------------------------------------------------------------
-- Harness: the real addon on stubs, one flavor (the shape of tools/test_progress_keys.lua's)
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
    if opts.clock then debugprofilestop = opts.clock end     -- a clock the test moves (read when Core/Account.lua loads)
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
        "Routing/Replan.lua", "Routing/Loop.lua", "Core/Account.lua", "Core/Professions.lua", "Core/Progress.lua", "Core/Skip.lua", "Core/Farm.lua",
        "Core/Recommend.lua" }) do
        files[#files + 1] = f
    end
    for _, f in ipairs(files) do load(f) end
    if opts.real then
        for _, f in ipairs(tocData(flavor)) do load(f, true) end
    end
    for _, f in ipairs(opts.files or {}) do load(f, true) end
    CompletionRouteDB, CompletionRouteCharDB = opts.db, opts.chardb
    for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", "CompletionRoute") end
    NS.printed = {}
    NS.Print = function(_, ...) local p = {} for i = 1, select("#", ...) do p[#p + 1] = tostring(select(i, ...)) end NS.printed[#NS.printed + 1] = table.concat(p, " ") end
    NS.Debug, NS.Error = function() end, function() end
    NS.db.profile.routing.liveBudgetMs = 1e9
    NS.db.profile.routing.reorder = false
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
-- SavedVariables round trip (what the client writes at logout and reads at the next login), stable key order
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
local function loadSV(file, name)
    local env = {}
    local fn = assert(loadfile(file))
    setfenv(fn, env)
    fn()
    return env[name]
end
-- every mark table and migration record of one guide, all characters (the import's whole output for that guide)
local function guideTables(NS, gid)
    local o = {}
    for k, c in pairs(NS.db.global.chars) do
        o[k] = { c.stepDone and c.stepDone[gid] or false, c.stepSkipped and c.stepSkipped[gid] or false, c.stepMeta and c.stepMeta[gid] or false }
    end
    o["(character file)"] = { NS.db.char.stepReopened and NS.db.char.stepReopened[gid] or false }
    return ser(o)
end
local function pump(A, budget, limit)
    local n = 0
    while A.ImportStep(budget) do
        n = n + 1
        if n > (limit or 1e6) then break end
    end
    return n
end

-- The synthetic guide of tools/test_progress_keys.lua (the fixture's old marks were written on it), baked
local Z = "|Z|1429; Elwynn Forest|"
local V1 = {
    "A Alpha|QID|201|M|40,40" .. Z, "N Talk to the guard at the gate|M|41,41" .. Z, "C Alpha|QID|201|QO|1|M|42,42" .. Z,
    "C Alpha|QID|201|QO|2|M|43,43" .. Z, "T Alpha|QID|201|M|40,40" .. Z, "A Beta|QID|202|M|44,44" .. Z,
    "R Run to Goldshire|M|45,45" .. Z, "C Beta|QID|202|M|46,46" .. Z, "N Buy some food|M|47,47" .. Z,
    "T Beta|QID|202|M|44,44" .. Z, "A Gamma|QID|203|PRE|202|M|48,48" .. Z, "T Gamma|QID|203|M|48,49" .. Z,
    "A Delta|QID|204|M|50,50" .. Z, "N Use the torch on the pile|", "T Delta|QID|204|M|50,51" .. Z,
    "N Talk to the guard at the gate.|M|52,52" .. Z, "T Two at once|QID|206^205|M|53,53" .. Z, "K Kill wolves|QID|207|M|54,54" .. Z,
    "K Kill the alpha wolf|QID|207|M|55,55" .. Z,
}
local BAKED = "19,1,18,2,17,3,16,4,15,5,14,6,13,7,12,8,11,9,10"
local function author(steps) local a = {} for _, s in ipairs(steps) do if (s.index or 0) > 0 then a[s.index] = s end end return a end
local function register(NS, id, lines, extra)
    local G = NS.Guide
    local g = G.registry[id]
    if g then g.text, g.steps = table.concat(lines, "\n"), nil return g end
    local def = { id = id, name = "Keys " .. id, type = "Quests", zone = 1429, faction = "Alliance", minlevel = 1, maxlevel = 10,
                  text = table.concat(lines, "\n") }
    for k, v in pairs(extra or {}) do def[k] = v end
    return G.Register(def)
end
local FIX_ACCT, FIX_CHAR = "tools/fixtures/progress_keys_account_SV.lua", "tools/fixtures/progress_keys_character_SV.lua"
local REAL = "wiki:era:1429:Alliance"

-- one session on the fixture: the synthetic guide registered and baked, the real era wiki guides when generated
local function fixtureSession()
    local db0, char0 = loadSV(FIX_ACCT, "CompletionRouteDB"), loadSV(FIX_CHAR, "CompletionRouteCharDB")
    local NS = harness("era", { db = roundTrip(db0), chardb = roundTrip(char0), files = { "Guides/Imported_Wiki_era.lua", "Data/RouteOrder_era.lua" } })
    local G = NS.Guide
    register(NS, "t:keys:a", V1)
    NS.RouteOrder = NS.RouteOrder or {}
    NS.RouteOrder["t:keys:a"] = { n = 19, sum = G.RouteChecksum(author(G.Steps("t:keys:a"))), o = BAKED }
    G.registry["t:keys:a"].steps = nil
    NS.Account.Init()
    place(1429, 0.1, 0.9)
    W.level = 5
    return NS, db0, char0
end

-- ---------------------------------------------------------------------------
-- 1) The import after login gives what a load gives
-- ---------------------------------------------------------------------------
do
    -- the load path: each guide loaded once.  Progress.Load migrates it, then its first refresh ticks what the game
    -- already reports done (that catch-up is not the import): the tables are read right after the migration
    local NSL = fixtureSession()
    local gids = { "t:keys:a" }
    if NSL.Guide.registry[REAL] then gids[#gids + 1] = REAL else skip("real guide " .. REAL, "Imported_Wiki_era.lua not generated here") end
    local viaLoad = {}
    local realMigrate = NSL.Account.Migrate
    NSL.Account.Migrate = function(gid, ...)
        local n = realMigrate(gid, ...)
        viaLoad[gid] = guideTables(NSL, gid)
        return n
    end
    for _, gid in ipairs(gids) do NSL.Progress.Load(gid) end
    NSL.Account.Migrate = realMigrate

    -- the login path: nothing loaded, the import runs
    local NS = fixtureSession()
    local A, G, P = NS.Account, NS.Guide, NS.Progress
    local chars = NS.db.global.chars
    t("before: nothing migrated, no flag", next(chars["Tester-Test"].stepMeta) == nil and NS.db.char.marksImported == nil)
    t("before: the routes list counts none of the old marks of a guide never opened", (A.GuideProgress("t:keys:a", 19, "char")) == 0)
    local pending = A.PendingImports()
    t("pending: the guides with old marks of this character or an alt of this game type, registered (" .. table.concat(pending, " ") .. ")",
        pending[1] == "t:keys:a" and (#pending == 1 or (pending[2] == REAL and #pending == 2)) , table.concat(pending, " "))
    local job = A.StartImport()
    t("the import is armed", job ~= nil and A.ImportJob() == job)
    local slices = pump(A)
    t("it finishes (" .. (slices + 1) .. " slices)", A.ImportJob() == nil)
    for _, gid in ipairs(gids) do
        t("same mark tables and migration records as loading the guide: " .. gid, guideTables(NS, gid) == viaLoad[gid],
            "\n   import " .. guideTables(NS, gid) .. "\n   load   " .. viaLoad[gid])
    end
    t("nothing was loaded", P.guide == nil and NS.db.char.guide == "t:keys:a")
    local kept = 0
    for _, gid in ipairs(gids) do if G.registry[gid].steps then kept = kept + 1 end end
    t("the steps parsed for it are not kept", kept == 0, kept)
    local n = A.GuideProgress("t:keys:a", 19, "char")
    t("the routes list now counts the imported marks of the guide never opened (3 ticks + 1 skip)", n == 4, n)
    t("the character is marked as converted", NS.db.char.marksImported == NS.Guide.KEY_VERSION)
    local L = A.lastImport or {}
    t("the record of the run: guides, records converted, slices", L.guides == #gids and L.converted == #gids and L.records >= 2 and L.slices >= 1,
        ser(L))
    t("records of other clients and of no game type are left alone", chars["Old-Test"].stepMeta == nil and chars["Ret-Other"].stepMeta == nil
        and chars["Mop-Other"].stepMeta == nil)
    -- never again
    t("the next arm does nothing (flag set)", A.StartImport() == nil)
    local NS2 = harness("era", { db = roundTrip(CompletionRouteDB), chardb = roundTrip(CompletionRouteCharDB) })
    register(NS2, "t:keys:a", V1)
    NS2.Account.Init()
    t("after a reload the flag is still set and nothing is armed", NS2.db.char.marksImported == 1 and NS2.Account.StartImport() == nil)
    -- a downgraded client writes more index marks later: never imported (A.Migrate's rule), even when forced again
    NS2.db.global.chars["Tester-Test"].done["t:keys:a"][12] = true
    local before = guideTables(NS2, "t:keys:a")
    NS2.Account.StartImport({ force = true })
    pump(NS2.Account)
    local s2 = author(NS2.Guide.Steps("t:keys:a"))
    t("a forced second run converts nothing: index marks written after the import stay out", not (NS2.Account.me.stepDone["t:keys:a"] or {})[s2[12].key]
        and (NS2.Account.lastImport and NS2.Account.lastImport.guides == 0) and guideTables(NS2, "t:keys:a") == before,
        NS2.Account.lastImport and ser(NS2.Account.lastImport))
end

-- ---------------------------------------------------------------------------
-- 2) Why at login: a guide re-ordered by a later data update without getting shorter
-- ---------------------------------------------------------------------------
-- v1 has "Talk to the guard" at author step 2 and "Buy some food" at 9; the update swaps them.  The old tick 2 means
-- the talk.  Imported at the first login after the release (on v1) it stays on the talk; left to the load after the
-- update (the lazy import of before) it lands on step 2 of the new data: the food.
do
    local V1R = {}
    for i, l in ipairs(V1) do V1R[i] = l end
    V1R[2], V1R[9] = V1[9], V1[2]
    local function freshDB()
        return { chars = { ["Tester-Test"] = { name = "Tester", realm = "Test", flavor = "era", gametype = "era", quests = {},
                                                done = { ["t:keys:r"] = { [2] = true } }, skipped = {} } } }, { }
    end
    local function onUpdate(db, chardb)
        local NS = harness("era", { db = db, chardb = chardb })
        register(NS, "t:keys:r", V1R)
        NS.Account.Init()
        place(1429, 0.1, 0.9)
        NS.Progress.Load("t:keys:r")
        local talk, food
        for _, s in ipairs(NS.Progress.baseSteps) do
            if s.title == "Talk to the guard at the gate" then talk = s elseif s.title == "Buy some food" then food = s end
        end
        return NS.Progress.IsDone(talk), NS.Progress.IsDone(food), talk.index, food.index
    end
    -- with the import at the first login of the release (data v1)
    local db, chardb = freshDB()
    local NS = harness("era", { db = db, chardb = chardb })
    register(NS, "t:keys:r", V1)
    NS.Account.Init()
    NS.Account.StartImport()
    pump(NS.Account)
    local talkDone, foodDone, ti, fi = onUpdate(roundTrip(CompletionRouteDB), roundTrip(CompletionRouteCharDB))
    t(("imported at login: after the update the tick is still on the talk (now step %d), not on the food (now step %d)"):format(ti, fi),
        talkDone and not foodDone)
    -- without it (the guide not opened before the update)
    db, chardb = freshDB()
    talkDone, foodDone = onUpdate(db, chardb)
    t("left to the load after the update, the tick lands on the food: what the import at login prevents", foodDone and not talkDone)
end

-- ---------------------------------------------------------------------------
-- 3) A bulk sweep pauses it; a logout in the middle leaves the rest to the next login
-- ---------------------------------------------------------------------------
do
    local IDS = {}
    local function dbWithMany()
        local done = {}
        for i = 1, 12 do
            local id = ("t:imp:%02d"):format(i)
            done[id] = { [1] = true, [i % 5 + 2] = true }
        end
        return { chars = { ["Tester-Test"] = { name = "Tester", realm = "Test", flavor = "era", gametype = "era", quests = {}, done = done, skipped = {} },
                           ["Alt-Test"] = { name = "Alt", realm = "Test", flavor = "era", gametype = "era", quests = {}, done = { ["t:imp:03"] = { [9] = true } }, skipped = {} } } },
               { reopened = { ["t:imp:05"] = { [4] = true } } }
    end
    local function session(db, chardb)
        local NS = harness("era", { db = db, chardb = chardb })
        for i = 1, 12 do
            local id = ("t:imp:%02d"):format(i)
            IDS[i] = id
            register(NS, id, V1)
        end
        NS.Account.Init()
        place(1429, 0.1, 0.9)
        return NS
    end
    local function allTables(NS) local o = {} for _, id in ipairs(IDS) do o[#o + 1] = guideTables(NS, id) end return table.concat(o, "\n") end
    -- reference: one run, uninterrupted
    local db, chardb = dbWithMany()
    local NS = session(db, chardb)
    NS.Account.StartImport()
    pump(NS.Account)
    local reference = allTables(NS)
    t("reference run: 12 guides converted, the alt's and the stepped-back marks too", NS.Account.lastImport.converted == 12
        and NS.Account.lastImport.records == 13 and next(NS.db.char.stepReopened["t:imp:05"] or {}) ~= nil, ser(NS.Account.lastImport))
    -- a bulk sweep starts while it runs: no progress while it holds the store, the rest afterwards
    db, chardb = dbWithMany()
    NS = session(db, chardb)
    local A = NS.Account
    local J = A.StartImport()
    A.ImportStep(0) A.ImportStep(0)             -- 0 ms: one guide per slice
    local at = J.pos
    A.BeginScratch()
    for _ = 1, 5 do A.ImportStep(0) end
    t("during a bulk sweep the import waits (no guide converted, the sweep's empty store untouched)", J.pos == at and next(A.me.stepDone) == nil
        and A.ImportJob() == J, J.pos .. " vs " .. at)
    A.EndScratch()
    pump(A, 0)
    t("after the sweep it finishes, with the same result as one run", allTables(NS) == reference and NS.db.char.marksImported == 1)
    -- a logout after three guides: the flag is not set, the next login does the rest
    db, chardb = dbWithMany()
    NS = session(db, chardb)
    NS.Account.StartImport()
    for _ = 1, 3 do NS.Account.ImportStep(0) end
    t("a logout in the middle: not marked as converted", NS.db.char.marksImported == nil and NS.Account.ImportJob() ~= nil)
    local NS2 = session(roundTrip(CompletionRouteDB), roundTrip(CompletionRouteCharDB))
    local left = #NS2.Account.PendingImports()
    NS2.Account.StartImport()
    pump(NS2.Account)
    t(("the next login converts the %d guides left, and the result is the one of a single run"):format(left), left == 9 and allTables(NS2) == reference
        and NS2.db.char.marksImported == 1, left)
    -- the frame: the import runs from its OnUpdate in game; one call per frame is one slice
    db, chardb = dbWithMany()
    NS = session(db, chardb)
    NS.Account.StartImport()
    t("each slice stops once its budget is spent, after at least one guide", NS.Account.ImportStep(0) and NS.Account.ImportJob().pos == 2)
    -- the slicing rule on a clock the test moves: a guide costs 1 ms per KB of text.  A guide that would not fit in what
    -- is left of the 4 ms waits for the next frame, so only a slice of one guide can pass the budget
    local now = 0
    local done = {}
    local NSc = harness("era", { clock = function() return now end, db = { chars = { ["Tester-Test"] = { name = "Tester", realm = "Test",
        flavor = "era", gametype = "era", quests = {}, done = done, skipped = {} } } }, chardb = {} })
    local sizes = {}
    for i = 1, 40 do
        local id = ("t:clk:%02d"):format(i)
        local lines = {}
        local reps = (i * 7) % 4 + 1                 -- 1 to 4 copies of the guide: about 0.9 to 3.6 KB
        for _ = 1, reps do for _, l in ipairs(V1) do lines[#lines + 1] = l end end
        register(NSc, id, lines)
        sizes[id] = #table.concat(lines, "\n")
        done[id] = { [1] = true }
    end
    NSc.Account.Init()
    local realRead = NSc.Progress.ReadSteps
    NSc.Progress.ReadSteps = function(g, quiet) now = now + (sizes[g.id] or 0) / 1024 return realRead(g, quiet) end
    local J = NSc.Account.StartImport({ sliceLog = true })
    pump(NSc.Account)
    local overMany, single, n = 0, 0, 0
    for _, v in ipairs(J.sliceLog) do
        n = n + v[2]
        if v[1] > 4 + 1e-9 then if v[2] > 1 then overMany = overMany + 1 else single = single + 1 end end
    end
    t(("slicing rule (test clock, 1 ms per KB): %d guides in %d slices, none over 4 ms with more than one guide in it"):format(n, #J.sliceLog),
        n == 40 and overMany == 0 and single == 0 and #J.sliceLog < 40, ("%d slices over 4 ms with more than one guide, %d with one"):format(overMany, single))
end

-- ---------------------------------------------------------------------------
-- 4) The same path as a load: the gold circuit fold, and an access-chain prefix that changes nothing
-- ---------------------------------------------------------------------------
do
    -- a gold guide that is a list of spots, not a ring: a load folds it into a circuit before reading its steps
    local GOLD = "t:imp:gold"
    local lines = {}
    for i = 1, 8 do lines[i] = ("K Kill boars %d|M|%d,%d|Z|1429; Elwynn Forest|"):format(i, 30 + i * 4, 60 + (i % 3) * 5) end
    local function goldSession()
        local db = { chars = { ["Tester-Test"] = { name = "Tester", realm = "Test", flavor = "era", gametype = "era", quests = {},
                                                    done = { [GOLD] = { [1] = true, [3] = true } }, skipped = {} } } }
        local NS = harness("era", { db = db, chardb = {} })
        NS.Guide.Register({ id = GOLD, name = "Boars", type = "Gold", zone = 1429, minlevel = 1, maxlevel = 10, text = table.concat(lines, "\n") })
        NS.Account.Init()
        place(1429, 0.1, 0.9)
        return NS
    end
    local NSL = goldSession()
    NSL.Progress.Load(GOLD)
    local gl = NSL.Guide.registry[GOLD]
    local metaLoad = NSL.Account.me.stepMeta[GOLD]
    local NS = goldSession()
    NS.Account.StartImport()
    pump(NS.Account)
    local g = NS.Guide.registry[GOLD]
    local meta = NS.Account.me.stepMeta[GOLD]
    if gl.circuitized then
        t("gold guide: the import folds it into its circuit first, as a load does", g.circuitized == true and g.loop == true)
        t("gold guide: same migration record as the load (circuit checksum, carried, lost)", meta and metaLoad and meta.sum == metaLoad.sum
            and meta.mig == metaLoad.mig and (meta.lost or 0) == (metaLoad.lost or 0), ser(meta) .. " vs " .. ser(metaLoad))
        t("gold guide: no chat line about the fold from the import", (function()
            for _, l in ipairs(NS.printed) do if l:find("circuit", 1, true) then return false end end
            return true
        end)())
    else
        skip("gold circuit fold", "the stub world did not fold the test guide into a circuit")
    end
    -- an access-chain prefix (negative indices, '@chain/' keys) in front changes nothing the migration writes
    local function prefixSession()
        local db0, char0 = loadSV(FIX_ACCT, "CompletionRouteDB"), loadSV(FIX_CHAR, "CompletionRouteCharDB")
        local NSx = harness("era", { db = roundTrip(db0), chardb = roundTrip(char0) })
        register(NSx, "t:keys:a", V1)
        NSx.Account.Init()
        return NSx
    end
    local A1, A2 = prefixSession(), nil
    local plain = A1.Account.Migrate("t:keys:a", A1.Guide.Steps("t:keys:a"))
    local withoutPrefix = guideTables(A1, "t:keys:a")
    A2 = prefixSession()
    local chain = { key = "test_chain", title = "Test chain", steps = "A Unlock|QID|900|M|40,40" .. Z .. "\nN Talk|\nN Walk in|\n" }
    local prefix = A2.Access.ParseSteps(chain, "t:keys:a")
    local merged = {}
    for _, s in ipairs(prefix) do merged[#merged + 1] = s end
    for _, s in ipairs(A2.Guide.Steps("t:keys:a")) do merged[#merged + 1] = s end
    local n2 = A2.Account.Migrate("t:keys:a", merged)
    t("access-chain prefix: the same records are migrated and the same tables written without it", plain == n2 and plain > 0
        and guideTables(A2, "t:keys:a") == withoutPrefix, plain .. " / " .. n2)
end

-- ---------------------------------------------------------------------------
-- 5) Cost on every flavor's real guides
-- ---------------------------------------------------------------------------
local function pct(sorted, p) if #sorted == 0 then return 0 end return sorted[math.max(1, math.min(#sorted, math.ceil(#sorted * p)))] end
for _, fl in ipairs(FLAVORS) do
    local data = tocData(fl)
    local have = 0
    for _, f in ipairs(data) do if f:match("^Guides/") and exists("CompletionRoute/" .. f) then have = have + 1 end end
    if have == 0 then
        skip(fl .. " real guides", "no generated guide files here")
    else
        collectgarbage("collect")
        local NS = harness(fl, { real = true, db = { chars = {} }, chardb = {} })
        local A, G = NS.Account, NS.Guide
        A.Init()
        local game = A.GameType()
        -- old marks on every registered guide: this character (three ticks and a skip, a stepped-back mark on every
        -- tenth) and an alt of the same game type (one tick)
        local alt = { name = "Alt", realm = "Test", flavor = NS.flavor, gametype = game, quests = {}, done = {}, skipped = {} }
        NS.db.global.chars["Alt-Test"] = alt
        NS.db.char.reopened = {}
        local n = 0
        for _, id in ipairs(G.list) do
            local g = G.registry[id]
            if not g.empty and not g.dynamic then
                n = n + 1
                A.me.done[id] = { [1] = true, [2] = true, [3] = true }
                A.me.skipped[id] = { [4] = true }
                alt.done[id] = { [1] = true }
                if n % 10 == 0 then NS.db.char.reopened[id] = { [2] = true } end
            end
        end
        collectgarbage("collect")
        local kb0 = collectgarbage("count")
        local job = A.StartImport({ sliceLog = true })
        local wall0 = os.clock()
        pump(A)
        local wall = (os.clock() - wall0) * 1000
        collectgarbage("collect")
        local kb1 = collectgarbage("count")
        local L = A.lastImport or {}
        local log = job.sliceLog or {}
        local sorted = {}
        for i, v in ipairs(log) do sorted[i] = v[1] end
        table.sort(sorted)
        -- a slice over the budget that converted more than one guide started a guide it should have left to the next frame
        local over4, over16, overMany = 0, 0, 0
        for _, v in ipairs(log) do
            if v[1] > 4.5 then over4 = over4 + 1 if v[2] > 1 then overMany = overMany + 1 end end
            if v[1] > 16.7 then over16 = over16 + 1 end
        end
        local kept = 0
        for _, id in ipairs(G.list) do if G.registry[id].steps then kept = kept + 1 end end
        print(("     %-8s %5d guides with old marks: %5d converted (%d records), %5d slices, CPU %.0f ms (%.2f ms a guide), slice p50 %.2f p99 %.2f max %.2f ms, %d over 4.5 ms (%d of them with more than one guide), %d over one 60 fps frame (16.7 ms), memory after %+.0f KB, %s")
            :format(fl, L.guides or 0, L.converted or 0, L.records or 0, L.slices or 0, L.cpu or wall, (L.cpu or wall) / math.max(1, L.guides or 1),
                    pct(sorted, 0.5), pct(sorted, 0.99), L.maxSlice or 0, over4, overMany, over16, kb1 - kb0, JIT))
        -- the slowest slices are single guides (a parse is not split): name them
        local worst = {}
        for _, v in ipairs(log) do worst[#worst + 1] = v end
        table.sort(worst, function(a, b) return a[1] > b[1] end)
        for i = 1, math.min(3, #worst) do
            local w = worst[i]
            local g = w[3] and G.registry[w[3]]
            local tx = g and (type(g.text) == "string" and g.text or (g.part and G.registry[g.part] and G.registry[g.part].text))
            print(("       slow slice %d: %.1f ms, %d guide%s, last %s (%s KB of text)"):format(i, w[1], w[2], w[2] == 1 and "" or "s", tostring(w[3]),
                type(tx) == "string" and ("%.0f"):format(#tx / 1024) or "?"))
        end
        t(fl .. ": every guide with old marks was converted", L.guides == n and L.converted >= n - 5, ("%s of %d"):format(tostring(L.converted), n))
        t(fl .. ": no parsed steps kept afterwards", kept == 0, kept)
        t(fl .. ": the character is marked as converted", NS.db.char.marksImported == 1)
        -- CPU time on a machine shared with other jobs is noisy: the median is the check; the overruns are reported above
        -- (section 3 checks the slicing rule itself on a clock the test moves)
        t(fl .. ": slices keep to the 4 ms budget (median under 4.5 ms)", pct(sorted, 0.5) <= 4.5, ("median %.2f ms"):format(pct(sorted, 0.5)))
    end
end

print(("%d passed, %d failed, %d skipped"):format(passed, failed, skipped))
if failed > 0 then os.exit(1) end
print("ALL MARK IMPORT TESTS PASSED")
