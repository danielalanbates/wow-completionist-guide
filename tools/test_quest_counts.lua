-- Offline tests of the routes list's quest counts, natural order and prefill (2026-11-13):
--   1. Core/QuestCounts.lua   which quests a route has (QC.Groups / QC.Resolve), the generated index and its fallback,
--                             counts by scope, folder tallies with each quest id once, dropped quests left out
--   2. UI/GuideMenu.lua       the order of routes in a folder (M.RouteLess), the right-hand texts ("12 / 40 quests",
--                             "312 / 1,040 quests", never "0 completed"), the total line, refresh when the completed
--                             quests arrive late or a quest is turned in, and that the scan parses no quest route
--   3. Core/Progress.lua      P.Prefill: every step whose quest is already completed is ticked at once, anywhere in
--                             the route, and the current step is the first one still open
--   4. the real data of every client (when generated): the index equals what the parser gives for every route, for an
--                             Alliance and a Horde character; the order of the real route names; the scan's cost
-- Run from the repo root:  luajit -joff tools/test_quest_counts.lua [flavor ...]     (no flavor = all five)
-- Stubs only: nothing here has run in a client.
package.path = "./?.lua;" .. package.path
local ADDON = "CompletionRoute"

local fails, checks = 0, 0
local function check(ok, what, detail)
    checks = checks + 1
    if not ok then fails = fails + 1 print("FAIL " .. what .. (detail ~= nil and ("  :: " .. tostring(detail)) or "")) end
    return ok
end
local function exists(p) local f = io.open(p, "r") if f then f:close() return true end return false end

local TOC = { era = 11507, tbc = 20506, mop = 50504, retail = 120100, forever = 16001 }
local TOCFILE = { era = "CompletionRoute_Vanilla.toc", tbc = "CompletionRoute_TBC.toc", mop = "CompletionRoute_Mists.toc",
                  retail = "CompletionRoute.toc", forever = "CompletionRoute_Forever.toc" }
local TAXI = { era = "Data/Taxi_era.lua", tbc = "Data/Taxi_tbc.lua", mop = "Data/Taxi_mop.lua", retail = "Data/Taxi_retail.lua",
               forever = "Data/Taxi_forever.lua" }
local FLAVORS = { "era", "tbc", "forever", "mop", "retail" }

-- the generated files a client's TOC lists (route files, the baked order, the quest index)
local function tocData(flavor)
    local out = {}
    local fh = assert(io.open("CompletionRoute/" .. TOCFILE[flavor], "r"))
    for line in fh:lines() do
        line = line:gsub("\r$", ""):gsub("\\", "/")
        if line:match("^Guides/Imported_.*%.lua$") or line:match("^Data/RouteOrder_") or line:match("^Data/QuestIndex_") then out[#out + 1] = line end
    end
    fh:close()
    return out
end

-- The real addon on stubs.  W.done[quest] = true: the client reports the quest completed.
--   opts.who    { faction, class token, race }       opts.real   load the flavor TOC's route and data files
--   opts.db / opts.chardb   saved variables
local W
local function harness(flavor, opts)
    opts = opts or {}
    W = { done = {}, on = {}, level = opts.level or 30 }
    STUB_MAPS = dofile("tools/maps_" .. flavor .. ".lua")
    dofile("tools/stubs.lua")
    local who = opts.who or { "Alliance", "WARRIOR", "Human" }
    UnitFactionGroup = function() return who[1] end
    UnitClass = function() return who[2], who[2] end
    UnitRace = function() return who[3], who[3] end
    GetBuildInfo = function() return "x", "0", "2026", TOC[flavor] end
    UnitLevel = function() return W.level end
    C_QuestLog = {
        IsOnQuest = function(q) return W.on[q] or false end,
        IsQuestFlaggedCompleted = function(q) return W.done[q] or false end,
        IsComplete = function() return false end,
        GetLogIndexForQuestID = function(q) return W.on[q] and 1 or nil end,
        GetQuestObjectives = function() return {} end,
        GetAllCompletedQuestIDs = function() local o = {} for q, v in pairs(W.done) do if v then o[#o + 1] = q end end return o end,
        GetTitleForQuestID = function() return nil end,
    }
    PLAYER = { map = 1429, x = 0.5, y = 0.5 }
    GameTooltip = CreateFrame()
    local NS = {}
    local function load(p, optional)
        if optional and not exists("CompletionRoute/" .. p) then return false end
        assert(loadfile("CompletionRoute/" .. p))(ADDON, NS)
        return true
    end
    local files = { "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", TAXI[flavor] }
    if flavor == "forever" then files[#files + 1] = "Data/MapFix_forever.lua" end
    for _, f in ipairs({ "Data/Transit.lua", "Data/Access.lua", "Data/Inns.lua", "Data/ZoneAliases.lua", "Data/Roads_ek.lua",
        "Data/Roads_kalimdor.lua", "Routing/CostModel.lua", "Routing/TravelGraph.lua", "Routing/Roads.lua", "Routing/StepOrder.lua", "Routing/Router.lua",
        "Routing/Replan.lua", "Core/Account.lua", "Core/QuestCounts.lua", "Core/Professions.lua", "Core/Progress.lua", "Core/Skip.lua",
        "Core/Recommend.lua", "UI/GuideMenu.lua" }) do
        files[#files + 1] = f
    end
    for _, f in ipairs(files) do load(f) end
    if opts.real then
        for _, f in ipairs(tocData(flavor)) do load(f, true) end
        for _, f in ipairs({ "Guides/Leveling/Alliance_Human_01_06_Northshire.lua", "Guides/Leveling/Horde_Orc_Troll_01_06_ValleyOfTrials.lua" }) do load(f, true) end
    end
    CompletionRouteDB, CompletionRouteCharDB = opts.db, opts.chardb
    for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", ADDON) end
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
local function fire(NS, evt, ...) for _, h in ipairs(NS.wowHandlers[evt] or {}) do h(evt, ...) end end
local function setOf(list) local s, n = {}, 0 for _, q in ipairs(list) do if not s[q] then s[q] = true n = n + 1 end end return s, n end
local function sameSet(a, b)
    local sa, na = setOf(a)
    local sb, nb = setOf(b)
    if na ~= nb then return false end
    for q in pairs(sa) do if not sb[q] then return false end end
    return true
end

-- run the list's background work to the end (the client does one scanStep per frame), redrawing in between as the
-- client does; returns how many frames it took
local function settle(NS)
    local M, T = NS.GuideMenu, NS.GuideMenu._test
    local frames = 0
    for _ = 1, 8 do
        M.Refresh()
        local guard = 0
        repeat guard = guard + 1 frames = frames + 1 until T.scanStep() or guard > 500000
    end
    M.Refresh()
    return frames
end
-- the right-hand text of the row of a route (gid) or a folder (path), colour codes removed; nil when not on screen
local function plain(t) return t and (t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) or nil end
local function rightOf(NS, gid, path)
    for _, b in ipairs(NS.GuideMenu._test.buttons) do
        if b.__shown and ((gid and b.gid == gid) or (path and b.nodePath == path)) then return plain(b.right:GetText()) end
    end
    return nil
end
local function expandAll(NS)
    local T = NS.GuideMenu._test
    local function walk(n) for _, k in ipairs(n.kids) do T.expanded[k.path] = true walk(k) end end
    walk(T.buildTree())
end

local want = {}
for _, a in ipairs(arg or {}) do want[a] = true end
local synthetic = not next(want) or want.synthetic

-- ===========================================================================
-- 1. Which quests a route has
-- ===========================================================================
if synthetic then
do
    local NS = harness("era")
    local G, QC, A = NS.Guide, NS.QuestCounts, NS.Account
    local Z = "|Z|1429; Elwynn Forest|"
    local function reg(def) def.source = def.source or "test" return G.Register(def) end
    reg({ id = "q:mix", name = "Mix Quests 1-10", type = "Quests", text = table.concat({
        "A One|QID|101|M|40,40" .. Z,
        "C One|QID|101|QO|1|M|41,41" .. Z,
        "T One|QID|101|M|40,40" .. Z,
        "A Two|QID|102|M|42,42" .. Z,                         -- accepted here, never turned in by this route: not counted
        "A Side|QID|103|O|M|42,42" .. Z,                      -- optional: not counted
        "T Side|QID|103|O|M|42,42" .. Z,
        "A Horde only|QID|104|FACTION|Horde|M|43,43" .. Z,
        "T Horde only|QID|104|FACTION|Horde|M|43,43" .. Z,
        "A Mage only|QID|105|C|Mage|M|43,43" .. Z,
        "T Mage only|QID|105|C|Mage|M|43,43" .. Z,
        "A Human only|QID|106|R|Human|M|43,43" .. Z,
        "T Human only|QID|106|R|Human|M|43,43" .. Z,
        "A Either|QID|107^108|M|44,44" .. Z,                  -- two ids on one step: both are the route's quests
        "T Either|QID|107^108|M|44,44" .. Z,
        "A Both ways|QID|109|FACTION|Horde|M|44,44" .. Z,     -- offered to Horde by one step and to everyone by another
        "T Both ways|QID|109|M|44,44" .. Z,
        "R Run somewhere|M|45,45" .. Z,
    }, "\n") })
    local groups = QC.Groups(G.Steps("q:mix"))
    check(groups.quest == true, "a route that turns a quest in is a quest route")
    local list = QC.Resolve(groups)
    check(sameSet(list, { 101, 106, 107, 108, 109 }), "route quests for an Alliance human warrior: the quests it turns in; accept-only, optional / other faction / other class left out",
        table.concat(list, ","))
    local qs, isQuest = QC.Quests(G.registry["q:mix"], true)
    check(isQuest and sameSet(qs, list), "QC.Quests reads the same from the parsed steps")
    check(#qs == 5, "each quest id once")

    -- a route with objective steps that name quests but no turn-in (an achievement list) is not a quest route
    reg({ id = "q:ach", name = "Some Achievements", type = "Achievements", text = "C Crit one|QID|201|ACH|6;1|\nC Crit two|QID|202|ACH|6;2|" })
    reg({ id = "q:prof", name = "Cooking 1-75", type = "Professions", prof = "Cooking", skillMin = 1, skillMax = 75,
          text = "A Trainer quest|QID|211|\nT Trainer quest|QID|211|\nM Cook|SKILL|Cooking;75|" })
    reg({ id = "q:gold", name = "Daily Gold: Somewhere", type = "Gold", text = "A Daily|QID|221|\nT Daily|QID|221|" })
    check(QC.IsQuestRoute(G.registry["q:ach"], true) == false, "an achievement list with quest criteria is not a quest route")
    check(QC.IsQuestRoute(G.registry["q:prof"], true) == false and QC.IsQuestRoute(G.registry["q:gold"], true) == false,
        "profession and gold routes are not quest routes")
    local d, t = QC.Count(G.registry["q:prof"], "char", true)
    check(d == 0 and t == 0, "... and count 0 of 0")

    -- counts by scope
    reg({ id = "q:b", name = "Beta Quests 5-10", type = "Quests", text = "A Three|QID|301|\nT Three|QID|301|\nA One again|QID|101|\nT One again|QID|101|" })
    A.me.quests = { [101] = true, [107] = true, [999999] = true }      -- 999999: a hidden tracking quest no route names
    A.ClearCompletionCaches()
    d, t = QC.Count(G.registry["q:mix"], "char", true)
    check(d == 2 and t == 5, "this character: 2 of 5", d .. "/" .. t)
    NS.db.global.chars["Alt-Test"] = { name = "Alt", realm = A.me.realm, flavor = NS.flavor, gametype = A.GameType(), faction = "Alliance",
        quests = { [108] = true, [101] = true, [102] = true } }
    NS.db.global.chars["Far-Elsewhere"] = { name = "Far", realm = "Elsewhere", flavor = "retail", gametype = "retail", faction = "Horde",
        quests = { [106] = true, [104] = true } }
    A.ClearCompletionCaches()
    d, t = QC.Count(G.registry["q:mix"], "char", true)
    check(d == 2 and t == 5, "character scope ignores the other characters", d .. "/" .. t)
    d, t = QC.Count(G.registry["q:mix"], "realm", true)
    check(d == 3 and t == 5, "server scope adds the alt on this server, each quest once", d .. "/" .. t)
    d, t = QC.Count(G.registry["q:mix"], "flavor", true)
    check(d == 3 and t == 5, "game type scope leaves out a character of another game type", d .. "/" .. t)
    d, t = QC.Count(G.registry["q:mix"], "account", true)
    check(d == 4 and t == 5, "account scope adds every character (a quest outside this character's list still does not count)", d .. "/" .. t)
    -- the option "also match by quest ID across different routes" off: other characters' quests tick no step
    -- (A.OtherDidQuest), so they are not counted either (review finding: a row said "completed" for a route that
    -- then opened with open steps)
    NS.db.profile.accountQuests = false
    A.ClearCompletionCaches()
    d, t = QC.Count(G.registry["q:mix"], "account", true)
    check(d == 2 and t == 5, "accountQuests off: a wider scope counts this character's quests only", d .. "/" .. t)
    do
        local alt = NS.db.global.chars["Alt-Test"]
        local keepQ = alt.quests
        alt.quests = { [101] = true, [106] = true, [107] = true, [108] = true, [109] = true }
        A.ClearCompletionCaches()
        check(A.GuideIsComplete(G.registry["q:mix"], "account") == false, "accountQuests off: an alt's quests do not finish the route in a wider scope")
        NS.db.profile.accountQuests = true
        A.ClearCompletionCaches()
        check(A.GuideIsComplete(G.registry["q:mix"], "account") == true, "accountQuests on: they do")
        alt.quests = keepQ
    end
    NS.db.profile.accountQuests = true
    A.ClearCompletionCaches()
    check(A.GuideIsComplete(G.registry["q:mix"], "char") == false, "a part-done quest route is not finished")

    -- a tally counts each quest id once across routes; hidden ids and non-quest routes add nothing
    local tally = QC.Tally("char")
    for _, id in ipairs({ "q:mix", "q:b", "q:ach", "q:prof", "q:gold" }) do QC.Count(G.registry[id], "char", true) QC.TallyAdd(tally, G.registry[id]) end
    check(tally.total == 6 and tally.done == 2 and tally.routes == 2, "tally: 6 quests in two quest routes (101 is in both), 2 done",
        tally.done .. "/" .. tally.total .. " in " .. tally.routes)

    -- finished: every quest done by the characters in scope
    A.me.quests = { [101] = true, [102] = true, [106] = true, [107] = true, [108] = true, [109] = true }
    A.ClearCompletionCaches()
    check(A.GuideIsComplete(G.registry["q:mix"], "char") == true, "all done: finished")
    -- a quest the route only accepts (102: no turn-in step) does not keep it open (review finding: 88 Retail routes
    -- hold such quests, most of them repeatable area tasks the client does not keep as completed)
    A.me.quests[102] = nil
    A.ClearCompletionCaches()
    check(A.GuideIsComplete(G.registry["q:mix"], "char") == true and A.GuideCompletedBy(G.registry["q:mix"]) == A.key,
        "a quest with no turn-in step is not needed for 'completed'")
    local key = A.GuideCompletedBy(G.registry["q:mix"])
    check(key == A.key, "... and credited to this character")
    A.me.quests[109] = nil
    A.ClearCompletionCaches()
    check(A.GuideIsComplete(G.registry["q:mix"], "char") == false and A.GuideCompletedBy(G.registry["q:mix"]) == nil, "one missing: not finished, credited to nobody")

    -- a dropped quest (/cr skip) leaves the route's count
    NS.db.profile.skipConfirm = false
    local S = NS.Skip
    S.Store(true).roots[109] = true
    S.version = S.version + 1
    A.ClearCompletionCaches()
    d, t = QC.Count(G.registry["q:mix"], "char", true)
    check(d == 4 and t == 4, "a dropped quest is not counted", d .. "/" .. t)
    S.Store(true).roots[109] = nil
    S.version = S.version + 1
    A.ClearCompletionCaches()

    -- QC.Fmt
    check(QC.Fmt(0) == "0" and QC.Fmt(999) == "999" and QC.Fmt(1040) == "1,040" and QC.Fmt(34268) == "34,268" and QC.Fmt(1234567) == "1,234,567", "thousands separators")

    -- another character: Horde mage orc
    local NS2 = harness("era", { who = { "Horde", "MAGE", "Orc" } })
    NS2.Guide.Register({ id = "q:mix", name = "Mix", type = "Quests", text = G.registry["q:mix"].text })
    local l2 = NS2.QuestCounts.Quests(NS2.Guide.registry["q:mix"], true)
    check(sameSet(l2, { 101, 104, 105, 107, 108, 109 }), "the same route for a Horde orc mage", table.concat(l2, ","))
end

-- ===========================================================================
-- 2. The generated index: used without parsing, ignored when stale
-- ===========================================================================
do
    local NS = harness("era")
    local G, QC, A = NS.Guide, NS.QuestCounts, NS.Account
    local text = "A One|QID|101|\nT One|QID|101|\nA H|QID|104|FACTION|Horde|\nT H|QID|104|FACTION|Horde|\nA W|QID|105|C|Warrior|\nT W|QID|105|C|Warrior|"
    G.Register({ id = "i:a", name = "Indexed Quests 1-5", type = "Quests", source = "test", text = text })
    G.Register({ id = "i:spine", name = "001. Indexed Quests 1-5", type = "Leveling", source = "test", part = "i:a", text = function() return text end })
    G.Register({ id = "i:stale", name = "Stale Quests 1-5", type = "Quests", source = "test", text = text .. "\nA New|QID|110|\nT New|QID|110|" })
    G.Register({ id = "i:none", name = "Unlisted Quests", type = "Quests", source = "test", text = "A X|QID|120|\nT X|QID|120|" })
    -- an index of another format version is ignored as a whole
    NS.QuestIndex = { flavor = "era", v = 1, conds = {}, r = { ["i:a"] = #text .. "|101,555" } }
    check(QC.Quests(G.registry["i:a"]) == nil, "an index of another format version is not used")
    NS.QuestIndex = { flavor = "era", v = QC.INDEX_V, conds = { "Horde\t\t", "\tWarrior\t" }, r = {
        ["i:a"] = #text .. "|101|1:104|2:105,101",
        ["i:stale"] = #text .. "|101|1:104|2:105",
    } }
    local parses = {}
    local steps0 = G.Steps
    G.Steps = function(id) parses[id] = (parses[id] or 0) + 1 return steps0(id) end
    local l, isQuest = QC.Quests(G.registry["i:a"])
    check(l and isQuest and sameSet(l, { 101, 105 }) and #l == 2, "index entry read for this character, an id in two groups once", l and table.concat(l, ","))
    check(not parses["i:a"] and G.registry["i:a"].steps == nil, "... without parsing the route")
    local ls = QC.Quests(G.registry["i:spine"])
    check(ls and sameSet(ls, { 101, 105 }) and not parses["i:spine"], "a leveling chain entry reads its zone route's entry, unparsed")
    check(QC.Quests(G.registry["i:stale"]) == nil, "an entry made from another version of the route is not used")
    check(QC.Quests(G.registry["i:none"]) == nil, "a route the index does not list is not known without parsing")
    local lf = QC.Quests(G.registry["i:stale"], true)
    check(lf and sameSet(lf, { 101, 105, 110 }) and parses["i:stale"] == 1, "... the steps are read instead and give the current quests", lf and table.concat(lf, ","))
    QC.Quests(G.registry["i:stale"], true)
    check(parses["i:stale"] == 1, "... once: the answer is kept")
    A.me.quests = { [101] = true }
    A.ClearCompletionCaches()
    local d, t = QC.Count(G.registry["i:spine"])
    check(d == 1 and t == 2, "count from the index", tostring(d) .. "/" .. tostring(t))
    check(QC.Peek(G.registry["i:none"], "char") == nil, "Peek never computes")
    G.Steps = steps0
end

-- ===========================================================================
-- 2b. A folder of routes without quests is drawn without parsing them (review finding: expanding Achievements on
--     Retail parsed 203 routes in one redraw, 880 ms, and kept their steps)
-- ===========================================================================
do
    local NS = harness("era")
    local G, QC, A, M = NS.Guide, NS.QuestCounts, NS.Account, NS.GuideMenu
    local T = M._test
    local idx = { flavor = "era", v = QC.INDEX_V, conds = {}, r = {} }
    for i = 1, 30 do
        local text = ("C Crit one|ACH|%d;1|\nC Crit two|ACH|%d;2|"):format(600 + i, 600 + i)
        G.Register({ id = "ach:" .. i, name = "Feat " .. i, type = "Achievements", zone = "Feats", source = "test", text = text })
        idx.r["ach:" .. i] = tostring(#text)
    end
    NS.QuestIndex = idx
    A.me.quests = { [1] = true }
    A.ClearCompletionCaches()
    local parses, steps0 = 0, G.Steps
    G.Steps = function(id) parses = parses + 1 return steps0(id) end
    M.Show()
    expandAll(NS)
    settle(NS)
    local held = 0
    for i = 1, 30 do if G.registry["ach:" .. i].steps then held = held + 1 end end
    check(parses == 0 and held == 0, "scan and redraw of an open folder of 30 tick-only routes: nothing parsed, no steps kept", parses .. " parsed, " .. held .. " held")
    for i = 1, 30 do A.GuideCompletedBy(G.registry["ach:" .. i]) end
    check(parses == 0, "'who finished it' of a tick-only route nobody has a tick in needs no parse", parses)
    -- an alt ticked every step of one of them: that one is parsed to answer, and its steps are let go again
    local keys = {}
    for k in pairs(G.KeySet(steps0("ach:7"))) do keys[k] = true end
    G.registry["ach:7"].steps = nil
    NS.db.global.chars["Alt-Test"] = { name = "Alt", realm = A.me.realm, flavor = NS.flavor, gametype = A.GameType(), faction = "Alliance",
        quests = {}, stepDone = { ["ach:7"] = keys } }
    A.ClearCompletionCaches()
    parses = 0
    local who = A.GuideCompletedBy(G.registry["ach:7"])
    check(who == "Alt-Test" and parses == 1 and G.registry["ach:7"].steps == nil, "a tick-only route an alt finished: credited, parsed once, steps released",
        tostring(who) .. " " .. parses)
    A.GuideCompletedBy(G.registry["ach:7"])
    check(parses == 1, "... and the answer is kept", parses)
    -- in Account scope the row then reads completed; the other 29 are still not parsed by the redraw
    A.SetScope("account") M.RescanCompletion()
    parses = 0
    settle(NS)
    check(rightOf(NS, "ach:7") == "completed" and parses <= 2, "the finished one reads completed; the redraw parses no other row", tostring(rightOf(NS, "ach:7")) .. " " .. parses)
    held = 0
    for i = 1, 30 do if G.registry["ach:" .. i].steps then held = held + 1 end end
    check(held == 0, "no steps kept after the redraw", held)
    A.SetScope("char")
    G.Steps = steps0
end

-- ===========================================================================
-- 3. The order of routes in a folder
-- ===========================================================================
do
    local NS = harness("era")
    local G, M = NS.Guide, NS.GuideMenu
    local T = M._test
    local n = 0
    local function reg(def)
        n = n + 1
        def.id = def.id or ("o:" .. n)
        def.source, def.text = "test", def.text or "A Q|QID|" .. (5000 + n) .. "|\nT Q|QID|" .. (5000 + n) .. "|"
        return G.Register(def)
    end
    -- registered out of order on purpose
    local names = { "Kun-Lai Quests 87-88 - Part 10/12", "Kun-Lai Quests 86-87 - Part 2/12", "Kun-Lai Quests 85-86 - Part 1/12", "Kun-Lai Quests 88-89 - Part 11/12",
        "Kun-Lai Quests 87 - Part 9/12", "Kun-Lai Quests 89-90 - Part 12/12", "Kun-Lai Quests 86 - Part 3/12" }
    for _, nm in ipairs(names) do reg({ name = nm, type = "Quests", zone = "Kun-Lai" }) end
    -- a second series with the same shown name: the faction route's parts, not to be interleaved with the first
    reg({ name = "Kun-Lai Quests 85-90 (Alliance) - Part 2/2", type = "Quests", zone = "Kun-Lai" })
    reg({ name = "Kun-Lai Quests 85-90 (Alliance) - Part 1/2", type = "Quests", zone = "Kun-Lai" })
    reg({ name = "Kun-Lai Quests 80-90", type = "Quests", zone = "Kun-Lai", minlevel = 80 })
    -- the list sorts only the folders whose routes it shows (review finding: making every route's sort key on the
    -- first open was most of a 39 ms frame on Retail); a closed folder costs no key
    do
        T.expanded["\\Quests"], T.expanded["\\Quests\\Kun-Lai"] = nil, nil
        local lazy = T.buildTreeLazy()
        check(T.sortKeys() == 0, "closed folders: no sort key is made", T.sortKeys())
        T.expanded["\\Quests"], T.expanded["\\Quests\\Kun-Lai"] = true, true
        lazy = T.buildTreeLazy()
        local lf = lazy.kidByName["Quests"].kidByName["Kun-Lai"]
        check(T.sortKeys() == #lf.guides and lf.guides[1].name == "Kun-Lai Quests 80-90" and lf.guides[2].name:find("Part 1/12", 1, true),
            "an open folder is sorted, and only its routes get keys", T.sortKeys() .. " " .. lf.guides[1].name)
        T.expanded["\\Quests"], T.expanded["\\Quests\\Kun-Lai"] = nil, nil
    end
    local tree = T.buildTree()
    local folder = tree.kidByName["Quests"].kidByName["Kun-Lai"]
    local got = {}
    for i, g in ipairs(folder.guides) do got[i] = g.name:gsub("Kun%-Lai Quests ", "") end
    check(table.concat(got, " | ") == "80-90 | 85-86 - Part 1/12 | 86-87 - Part 2/12 | 86 - Part 3/12 | 87 - Part 9/12 | 87-88 - Part 10/12 | 88-89 - Part 11/12 | 89-90 - Part 12/12 | 85-90 (Alliance) - Part 1/2 | 85-90 (Alliance) - Part 2/2",
        "a zone's parts run 1, 2, 3 ... 10, 11, 12; the whole-zone route first; a second series after, in its own order", table.concat(got, " | "))

    -- the leveling chain: by chain number, whatever the level or the name
    reg({ id = "spine:era:A:010", name = "010. Zeta Quests 1-5", type = "Leveling", folder = "Leveling (generated)", minlevel = 1 })
    reg({ id = "spine:era:A:002", name = "002. Omega Quests 20-30", type = "Leveling", folder = "Leveling (generated)", minlevel = 20 })
    reg({ id = "spine:era:A:001", name = "001. Beta Quests 9-12 - Part 2/2", type = "Leveling", folder = "Leveling (generated)", minlevel = 9 })
    reg({ id = "spine:era:A:100", name = "100. Alpha Quests 1-3", type = "Leveling", folder = "Leveling (generated)", minlevel = 1 })
    reg({ id = "spine:era:A:011", name = "011. Beta Quests 1-9 - Part 1/2", type = "Leveling", folder = "Leveling (generated)", minlevel = 1 })
    tree = T.buildTree()
    folder = tree.kidByName["Leveling"].kidByName["Leveling (generated)"]
    got = {}
    for i, g in ipairs(folder.guides) do got[i] = g.id:match("(%d+)$") end
    check(table.concat(got, ",") == "001,002,010,011,100", "leveling chain routes are in chain order", table.concat(got, ","))

    -- professions by skill range; gold by its level range although the row does not show it
    for _, p in ipairs({ { "Cooking 150-225", 150, 225 }, { "Cooking 1-75", 1, 75 }, { "Cooking 225-300", 225, 300 }, { "Cooking 75-150", 75, 150 } }) do
        reg({ name = p[1], type = "Professions", prof = "Cooking", skillMin = p[2], skillMax = p[3], text = "M Cook|SKILL|Cooking;" .. p[3] .. "|" })
    end
    for _, nm in ipairs({ "Mob Farming 20-25: Humanoids in Wetlands", "Mob Farming 5-10: Beasts in Elwynn", "Mob Farming 10-15: Beasts in Westfall" }) do
        reg({ name = nm, type = "Gold", goldKind = "Mob Farming", noCircuit = true, text = "N Farm|" })
    end
    tree = T.buildTree()
    got = {}
    for i, g in ipairs(tree.kidByName["Professions"].kidByName["Cooking"].guides) do got[i] = g.name end
    check(table.concat(got, ",") == "Cooking 1-75,Cooking 75-150,Cooking 150-225,Cooking 225-300", "profession routes run by skill range", table.concat(got, ","))
    got = {}
    for i, g in ipairs(tree.kidByName["Gold"].kidByName["Mob Farming"].guides) do got[i] = g.name:match("^Mob Farming ([%d%-]+)") end
    check(table.concat(got, ",") == "5-10,10-15,20-25", "gold routes sort by the level range in their name", table.concat(got, ","))

    -- the flat search results use the same order
    local rows = T.searchRows("kun-lai")
    got = {}
    for i, r in ipairs(rows) do got[i] = r.guide.name:match("Part (%d+/%d+)") or "whole" end
    check(table.concat(got, ",") == "whole,1/12,2/12,3/12,9/12,10/12,11/12,12/12,1/2,2/2", "search results are in the same natural order", table.concat(got, ","))
    rows = T.searchRows("quests")
    check(rows[1].guide.id == "spine:era:A:001" and rows[5].guide.id == "spine:era:A:100", "search: chain routes first, in chain order")
    -- the order does not depend on the order of registration: sort a shuffled copy
    local a = {}
    for _, g in ipairs(G.Available()) do a[#a + 1] = g end
    local b = {}
    for i = #a, 1, -1 do b[#b + 1] = a[i] end
    table.sort(a, M.RouteLess) table.sort(b, M.RouteLess)
    local same = true
    for i = 1, #a do if a[i] ~= b[i] then same = false end end
    check(same, "the order is total: the same whatever order the routes came in")
    check(T.natural("Part 10/12") > T.natural("Part 2/12") and T.natural("A 9") < T.natural("A 10"), "numbers compare as numbers")
end

-- ===========================================================================
-- 4. The routes list: quest counts on rows and folders, the total, refreshes
-- ===========================================================================
do
    local NS = harness("era")
    local G, QC, A, M = NS.Guide, NS.QuestCounts, NS.Account, NS.GuideMenu
    local T = M._test
    local function quests(from, to)
        local l = {}
        for q = from, to do l[#l + 1] = ("A Q%d|QID|%d|\nT Q%d|QID|%d|"):format(q, q, q, q) end
        return table.concat(l, "\n")
    end
    local function reg(def) def.source = "test" return G.Register(def) end
    reg({ id = "m:z1", name = "Zone One Quests 1-10", type = "Quests", zone = "Zone One", text = quests(1001, 1040) })
    reg({ id = "m:z2", name = "Zone Two Quests 10-20", type = "Quests", zone = "Zone Two", text = quests(1041, 1050) })
    reg({ id = "m:z2b", name = "Zone Two Quests 10-20 (Alliance)", type = "Quests", zone = "Zone Two", faction = "Alliance", text = quests(1049, 1052) })
    reg({ id = "spine:era:A:001", name = "001. Zone One Quests 1-10", type = "Leveling", folder = "Leveling (generated)", part = "m:z1",
          text = function() return G.registry["m:z1"].text end })
    reg({ id = "m:gold", name = "Fishing: Somewhere", type = "Gold", goldKind = "Fishing", noCircuit = true, text = "N Fish|" })
    reg({ id = "m:prof", name = "Cooking 1-75", type = "Professions", prof = "Cooking", skillMin = 1, skillMax = 75, text = "N Cook|" })
    -- the client: 12 quests of Zone One done, all of Zone Two (both routes), and hundreds of hidden tracking ids
    for q = 1001, 1012 do W.done[q] = true end
    for q = 1041, 1052 do W.done[q] = true end
    for q = 70000, 70400 do W.done[q] = true end
    A.HarvestCompleted(true)
    expandAll(NS)
    local frames = settle(NS)
    check(rightOf(NS, "m:z1") == "12 / 40 quests", "a route row shows its quests done out of its quests", rightOf(NS, "m:z1"))
    check(rightOf(NS, "m:z2") == "completed" and rightOf(NS, "m:z2b") == "completed", "a finished route still reads as complete", rightOf(NS, "m:z2"))
    check(rightOf(NS, "spine:era:A:001") == "12 / 40 quests", "a never-opened leveling chain entry shows the same count as its zone route", rightOf(NS, "spine:era:A:001"))
    check(rightOf(NS, nil, "\\Quests") == "24 / 52 quests", "a folder counts each quest id once (1049 and 1050 are in two routes)", rightOf(NS, nil, "\\Quests"))
    check(rightOf(NS, nil, "\\Quests\\Zone Two") == "12 / 12 quests", "a sub-folder has its own count", rightOf(NS, nil, "\\Quests\\Zone Two"))
    check(rightOf(NS, nil, "\\Leveling") == "12 / 40 quests", "the Leveling folder counts its chain's quests", rightOf(NS, nil, "\\Leveling"))
    check(rightOf(NS, nil, "\\Gold") == "" and rightOf(NS, nil, "\\Professions") == "", "a folder without quest routes shows no count",
        tostring(rightOf(NS, nil, "\\Gold")))
    check(plain(T.totalLine:GetText()) == "Quests done: 24 of 52", "the total at the top: every quest once, hidden tracking ids not counted", plain(T.totalLine:GetText()))
    for _, b in ipairs(T.buttons) do
        if b.__shown then check(not (b.right:GetText() or ""):find("0 completed"), "no row says '0 completed'") end
    end
    do
        local src = assert(io.open("CompletionRoute/UI/GuideMenu.lua")):read("*a")
        check(not src:find('"|cff6666660 completed|r"', 1, true) and not src:find("%d completed", 1, true), "the '0 completed' / 'N completed' folder text is gone from the source")
    end
    check(A.me.stepDone["m:z1"] == nil and G.registry["m:z1"].steps == nil, "nothing was loaded or kept parsed for those numbers")

    -- thousands
    reg({ id = "m:big", name = "Big Quests", type = "Storylines", zone = "Big", text = quests(20001, 21500) })
    expandAll(NS)
    settle(NS)
    check(rightOf(NS, "m:big") == "0 / 1,500 quests", "large numbers get separators", rightOf(NS, "m:big"))
    check(plain(T.totalLine:GetText()) == "Quests done: 24 of 1,552", "... in the total too", plain(T.totalLine:GetText()))

    -- a turn-in while the list is open: the numbers move (the frame counts as shown)
    T.frame.IsShown = function() return true end
    fire(NS, "QUEST_TURNED_IN", 1013)
    settle(NS)
    check(rightOf(NS, "m:z1") == "13 / 40 quests" and plain(T.totalLine:GetText()) == "Quests done: 25 of 1,552", "a turn-in updates the row and the total",
        tostring(rightOf(NS, "m:z1")) .. " ; " .. tostring(plain(T.totalLine:GetText())))
    -- the completed list arriving late (Classic): 20 more quests appear in the client's list after login
    for q = 1014, 1033 do W.done[q] = true end
    fire(NS, "QUEST_QUERY_COMPLETE")
    settle(NS)
    check(rightOf(NS, "m:z1") == "33 / 40 quests" and rightOf(NS, nil, "\\Quests") == "45 / 52 quests", "a completed list that arrives late updates the numbers",
        tostring(rightOf(NS, "m:z1")) .. " ; " .. tostring(rightOf(NS, nil, "\\Quests")))
    T.frame.IsShown = function() return false end
    -- closed, then opened: counted again on open
    fire(NS, "QUEST_TURNED_IN", 1034)
    M.Show()
    settle(NS)
    check(rightOf(NS, "m:z1") == "34 / 40 quests", "a turn-in while the list was closed shows when it is opened", rightOf(NS, "m:z1"))

    -- the client learns of completed quests with no event at all (a late cache): opening the list asks it again
    -- ...but only while the client has not handed over a list this session (review finding: 4 to 6 ms on every open
    -- with a Retail-sized list); after that QUEST_TURNED_IN keeps the quests current
    for q = 1035, 1036 do W.done[q] = true end
    local t0 = GetTime()
    GetTime = function() return t0 + 100 end
    local asked, get0 = 0, C_QuestLog.GetAllCompletedQuestIDs
    C_QuestLog.GetAllCompletedQuestIDs = function() asked = asked + 1 return get0() end
    check(A.clientListSeen == true, "the client's list was seen this session")
    M.Show()
    check(asked == 0, "the client gave its list already: opening the list does not ask again", asked)
    A.clientListSeen = nil          -- as on a client whose list had not arrived
    GetTime = function() return t0 + 200 end
    M.Show()
    settle(NS)
    check(asked == 1 and rightOf(NS, "m:z1") == "36 / 40 quests", "opening the list asks the client for its completed quests again", rightOf(NS, "m:z1"))
    C_QuestLog.GetAllCompletedQuestIDs = get0
    -- the saved count follows without a recount
    do
        local n = 0 for _ in pairs(A.me.quests) do n = n + 1 end
        check(A.me.questCount == n, "the saved quest count is right after a harvest", A.me.questCount .. " vs " .. n)
        fire(NS, "QUEST_TURNED_IN", 987001)
        check(A.me.questCount == n + 1, "... and after a turn-in", A.me.questCount)
        local pairs0, walked = pairs, 0
        pairs = function(t) if t == A.me.quests then walked = walked + 1 end return pairs0(t) end
        A.HarvestCompleted(true)
        pairs = pairs0
        check(walked == 0 and A.me.questCount == n + 1, "a harvest that adds nothing does not walk the saved quests again", walked)
        A.me.quests[987001] = nil
        A.me.questCount = n
    end

    -- the stored answers are cleared with no quest changing while the list is open (the old-marks import ending, an
    -- options check box): the rows are counted again (review finding: the row went blank until the list was reopened)
    T.frame.IsShown = function() return true end
    settle(NS)
    local before = rightOf(NS, "m:z1")
    A.ClearCompletionCaches()
    settle(NS)
    check(before == "36 / 40 quests" and rightOf(NS, "m:z1") == before, "caches cleared with the list open: the row keeps its count", tostring(rightOf(NS, "m:z1")))
    check(rightOf(NS, nil, "\\Quests") ~= nil and not rightOf(NS, nil, "\\Quests"):find("%.%.%."), "... and the folder row", tostring(rightOf(NS, nil, "\\Quests")))
    T.frame.IsShown = function() return false end
    A.me.quests[1035], A.me.quests[1036], W.done[1035], W.done[1036] = nil, nil, nil, nil
    A.ClearCompletionCaches() M.RescanCompletion()
    settle(NS)

    -- scope: an alt on this server finished the rest of Zone One
    local alt = { name = "Alt", realm = A.me.realm, flavor = NS.flavor, gametype = A.GameType(), faction = "Alliance", quests = {} }
    for q = 1001, 1040 do alt.quests[q] = true end
    NS.db.global.chars["Alt-Test"] = alt
    A.SetScope("realm") M.RescanCompletion()
    settle(NS)
    check(rightOf(NS, "m:z1") == "completed" and rightOf(NS, nil, "\\Quests") == "52 / 52 quests", "server scope counts the alt's quests",
        tostring(rightOf(NS, "m:z1")) .. " ; " .. tostring(rightOf(NS, nil, "\\Quests")))
    A.SetScope("char") M.RescanCompletion()
    settle(NS)
    check(rightOf(NS, "m:z1") == "34 / 40 quests", "back to this character", rightOf(NS, "m:z1"))

    -- the level filter changes what a folder holds: its tally is its own
    T.prefs().onlyLevel = true
    M.SetViewLevel(5)
    settle(NS)
    local q = rightOf(NS, nil, "\\Quests")
    check(q == "34 / 40 quests", "with the level filter on, a folder counts only the routes it shows", q)
    T.prefs().onlyLevel = false
    M.SetViewLevel(nil)
end
end

-- ===========================================================================
-- 5. Prefill: steps of completed quests are ticked when a route is opened
-- ===========================================================================
if synthetic then
do
    local NS = harness("era")
    local G, A, P = NS.Guide, NS.Account, NS.Progress
    local Z = "|M|40,40|Z|1429; Elwynn Forest|"
    -- 100 quests, three steps each: far more than the 40-step look-ahead of the auto-completer
    local lines = {}
    for q = 1, 100 do
        lines[#lines + 1] = ("A Q%d|QID|%d%s"):format(q, 3000 + q, Z)
        lines[#lines + 1] = ("C Q%d|QID|%d|QO|1%s"):format(q, 3000 + q, Z)
        lines[#lines + 1] = ("T Q%d|QID|%d%s"):format(q, 3000 + q, Z)
    end
    G.Register({ id = "p:long", name = "Long Quests 1-60", type = "Quests", source = "test", text = table.concat(lines, "\n") })
    -- the character did quests 61-100 (the far end) and quest 2
    for q = 61, 100 do W.done[3000 + q] = true end
    W.done[3002] = true
    A.HarvestCompleted(true)
    P.Load("p:long")
    local done = A.Done("p:long")
    local n = 0
    for _ in pairs(done) do n = n + 1 end
    check(n == 41 * 3, "every step of a completed quest is ticked at load, also beyond the look-ahead window", n)
    check(P.current and P.current.action == "A" and P.current.qid[1] == 3001, "the current step is the first one still open", P.current and P.current.title)
    check(done["A3100"] and done["C3100.1"] and done["T3100"] and done["A3002"], "accept, objective and turn-in steps alike")
    check(#P.Pending() == 59 * 3, "what is left is exactly the open quests' steps", #P.Pending())

    -- ... and without the saved list: the client's own flag is enough (a character new to the addon)
    local NS2 = harness("era")
    NS2.Guide.Register({ id = "p:long", name = "Long Quests 1-60", type = "Quests", source = "test", text = table.concat(lines, "\n") })
    for q = 61, 100 do W.done[3000 + q] = true end
    NS2.Progress.Load("p:long")
    n = 0
    for _ in pairs(NS2.Account.Done("p:long")) do n = n + 1 end
    check(n == 40 * 3, "prefill reads the client's completed flag when nothing was harvested yet", n)

    -- a route opened BEFORE the completed list arrives (Classic: the cache is late): ticked when it does
    local NS3 = harness("era")
    local G3, A3, P3 = NS3.Guide, NS3.Account, NS3.Progress
    G3.Register({ id = "p:long", name = "Long Quests 1-60", type = "Quests", source = "test", text = table.concat(lines, "\n") })
    P3.Load("p:long")
    n = 0
    for _ in pairs(A3.Done("p:long")) do n = n + 1 end
    check(n == 0 and P3.current.qid[1] == 3001, "nothing known yet: nothing ticked")
    -- the list arrives; the client's per-quest flag is still empty for old quests (W.done stays empty), only the list has them
    local list = {}
    for q = 1, 30 do list[#list + 1] = 3000 + q end
    for q = 90, 100 do list[#list + 1] = 3000 + q end
    C_QuestLog.GetAllCompletedQuestIDs = function() return list end
    fire(NS3, "QUEST_QUERY_COMPLETE")
    n = 0
    for _ in pairs(A3.Done("p:long")) do n = n + 1 end
    check(n == 41 * 3, "the completed list arriving after the route was loaded ticks every step of those quests", n)
    check(P3.current and P3.current.qid[1] == 3031 and P3.current.action == "A", "... and the current step moves to the first open quest", P3.current and P3.current.title)
    -- a later turn-in ticks that quest's steps wherever they are in the route
    fire(NS3, "QUEST_TURNED_IN", 3080)
    P3.Refresh()
    check(A3.Done("p:long")["A3080"] and A3.Done("p:long")["C3080.1"] and A3.Done("p:long")["T3080"], "a quest turned in out of order ticks its far-away steps")

    -- the kinds of step that used to be missed, in one route
    local NS4 = harness("era")
    local G4, A4, P4 = NS4.Guide, NS4.Account, NS4.Progress
    local pad = {}
    for i = 1, 45 do pad[i] = ("A Filler %d|QID|%d%s"):format(i, 4500 + i, Z) end      -- 45 open steps in front: the rest is beyond the window
    local tail = {
        "A Accept only|QID|4001" .. Z,                              -- 46 accept step of a completed quest
        "C Objective|QID|4002|QO|2" .. Z,                           -- 47 objective step
        "K Kill for it|QID|4002" .. Z,                              -- 48 kill step keyed by a quest
        "A Either one|QID|4003^4004" .. Z,                          -- 49 several ids, any (one done)
        "T Either one|QID|4003^4004" .. Z,                          -- 50
        "A Needs both|QID|4005&4006" .. Z,                          -- 51 several ids, all (one done): stays open
        "A Has both|QID|4007&4008" .. Z,                            -- 52 several ids, all (both done)
        "T Zone only|QID|4009|Z|1429; Elwynn Forest|",              -- 53 no map point, only a zone
        "T No place at all|QID|4010|",                              -- 54
        "N Note for a quest|QID|4011" .. Z,                         -- 55 a note keyed by a quest
        "A Other faction|QID|4012|FACTION|Horde" .. Z,              -- 56 not this character's step, quest done on an alt-like id: ticked, harmless
        "A Gated|QID|4013|LVL|58" .. Z,                             -- 57 behind a level gate, quest already done
        "A Behind a prerequisite|QID|4014|PRE|4999" .. Z,           -- 58 its prerequisite is not done, the quest itself is
        "R Run to the inn|M|43.7,65.8|Z|1429; Elwynn Forest|",      -- 59 travel: not a state, stays
        "A Still open|QID|4020" .. Z,                               -- 60
        "T Still open|QID|4020" .. Z,                               -- 61
        "A Optional done|QID|4021|O" .. Z,                          -- 62
    }
    local all = {}
    for _, l in ipairs(pad) do all[#all + 1] = l end
    for _, l in ipairs(tail) do all[#all + 1] = l end
    G4.Register({ id = "p:kinds", name = "Kinds Quests 1-60", type = "Quests", source = "test", text = table.concat(all, "\n") })
    for _, q in ipairs({ 4001, 4002, 4003, 4005, 4007, 4008, 4009, 4010, 4011, 4012, 4013, 4014, 4021 }) do W.done[q] = true end
    W.level = 10
    A4.HarvestCompleted(true)
    -- a baked order that puts the tail first and the fillers last must make no difference to what is ticked
    P4.Load("p:kinds")
    local d = A4.Done("p:kinds")
    local function key(i) for _, s in ipairs(G4.Steps("p:kinds")) do if s.index == i then return s.key end end end
    local ticked, open = { 46, 47, 48, 49, 50, 52, 53, 54, 55, 56, 57, 58, 62 }, { 51, 59, 60, 61 }
    for _, i in ipairs(ticked) do check(d[key(i)] == true, "prefill ticks step " .. i .. ": " .. tail[i - 45]:match("^[^|]+")) end
    for _, i in ipairs(open) do check(not d[key(i)], "prefill leaves step " .. i .. " open: " .. tail[i - 45]:match("^[^|]+")) end
    for i = 1, 45 do if d[key(i)] then check(false, "a filler step was ticked") break end end
    check(P4.current and P4.current.title == "Filler 1", "the current step is the first open one", P4.current and P4.current.title)
    check(P4.NextGate() == nil, "a completed quest behind a level gate no longer parks the route as 'more steps at level 58'", tostring(P4.NextGate()))

    -- the Back arrow: a step the player stepped back to is not re-ticked by a later prefill
    for i = 1, 45 do W.done[4500 + i] = true end
    A4.HarvestCompleted(true)
    P4.Refresh()
    check(P4.current and P4.current.title == "Needs both", "after the fillers are done the route stands at the first step that is really open", P4.current and P4.current.title)
    P4.Undo()
    local back = P4.current
    check(back and back.key ~= key(51), "Back reopens a ticked step", back and back.title)
    fire(NS4, "QUEST_TURNED_IN", 4020)      -- the completed quests change: prefill runs again
    P4.Refresh()
    check(P4.current == back, "a step the player stepped back to stays open through a prefill", P4.current and P4.current.title)
    P4.Forward()

    -- Start over: marks are cleared, and what the game reports as done ticks again at once, everywhere
    P4.StartOver()
    d = A4.Done("p:kinds")
    check(d[key(46)] and d[key(58)] and d[key(1)] and not d[key(51)], "Start over re-ticks the completed quests' steps across the whole route")

    -- baked order: the same route with a baked order that reverses it
    local NS5 = harness("era")
    local G5, A5, P5 = NS5.Guide, NS5.Account, NS5.Progress
    G5.Register({ id = "p:kinds", name = "Kinds Quests 1-60", type = "Quests", source = "test", text = table.concat(all, "\n") })
    local st = G5.Steps("p:kinds")
    local rev = {}
    for i = #st, 1, -1 do rev[#rev + 1] = i end
    local sum = G5.RouteChecksum(st)
    G5.registry["p:kinds"].steps = nil
    NS5.RouteOrder = { ["p:kinds"] = { n = #st, sum = sum, o = table.concat(rev, ",") } }
    for _, q in ipairs({ 4001, 4002, 4003, 4005, 4007, 4008, 4009, 4010, 4011, 4012, 4013, 4014, 4021 }) do W.done[q] = true end
    W.level = 10
    A5.HarvestCompleted(true)
    P5.Load("p:kinds")
    check(G5.registry["p:kinds"].baked == true, "the baked order applies")
    local d5 = A5.Done("p:kinds")
    local same = true
    for _, i in ipairs(ticked) do if not d5[key(i)] then same = false end end
    for _, i in ipairs(open) do if d5[key(i)] then same = false end end
    check(same, "under a baked order the same steps are ticked")
    check(P5.current and P5.current.title == "Still open" and P5.current.action == "T" or (P5.current and P5.current.index == 61), "... and the current step is the first open one of the baked list",
        P5.current and (P5.current.index .. " " .. P5.current.title))

    -- quest-level skip: a dropped quest's steps are out; bringing it back returns them ticked when the quest is done
    local NS6 = harness("era")
    local G6, A6, P6, S6 = NS6.Guide, NS6.Account, NS6.Progress, NS6.Skip
    local ql = {}
    for q = 1, 60 do
        ql[#ql + 1] = ("A S%d|QID|%d%s"):format(q, 6000 + q, Z)
        ql[#ql + 1] = ("T S%d|QID|%d%s"):format(q, 6000 + q, Z)
    end
    G6.Register({ id = "p:skip", name = "Skip Quests 1-60", type = "Quests", source = "test", text = table.concat(ql, "\n") })
    NS6.QuestDeps = { flavor = "era", pre = "", free = "", crumb = "", never = "", name = "" }
    W.done[6060] = true
    A6.HarvestCompleted(true)
    P6.Load("p:skip")
    S6.SkipQuest(6055, { confirm = true })
    check(S6.IsRemoved(6055), "quest 6055 dropped")
    local onScreen = false
    for _, s in ipairs(P6.steps) do if s.qid and s.qid[1] == 6055 then onScreen = true end end
    check(not onScreen and A6.Done("p:skip")["T6060"], "its steps are out of the list; the other completed quest stays ticked")
    -- the player does the quest after all (the steps are not in the list, so nothing ticks them), then brings it back
    W.done[6055] = true
    fire(NS6, "QUEST_TURNED_IN", 6055)
    P6.Refresh()
    check(not A6.Done("p:skip")["A6055"], "a step that is not in the list is not ticked")
    S6.Unskip(6055)
    check(A6.Done("p:skip")["A6055"] and A6.Done("p:skip")["T6055"], "brought back: its steps return already ticked (the quest is completed)")
    check(P6.current and P6.current.qid[1] == 6001, "the current step is still the first open one")

    -- the chain walks into a route at the end of another: the next route is prefilled too
    local NS7 = harness("era")
    local G7, A7, P7 = NS7.Guide, NS7.Account, NS7.Progress
    G7.Register({ id = "c:one", name = "One", type = "Leveling", source = "test", next = "c:two", text = "A X|QID|7001" .. Z .. "\nT X|QID|7001" .. Z })
    local l2 = {}
    for q = 1, 50 do l2[#l2 + 1] = ("A Y%d|QID|%d%s\nT Y%d|QID|%d%s"):format(q, 7100 + q, Z, q, 7100 + q, Z) end
    G7.Register({ id = "c:two", name = "Two", type = "Leveling", source = "test", text = table.concat(l2, "\n") })
    for q = 30, 50 do W.done[7100 + q] = true end
    A7.HarvestCompleted(true)
    NS7.db.char.guide = "c:one"
    P7.chainLoading = true P7.Load("c:one") P7.chainLoading = nil        -- as the login loads the saved route
    check(P7.guide.id == "c:one" and P7.current.qid[1] == 7001, "the saved route loads at login")
    W.done[7001] = true
    fire(NS7, "QUEST_TURNED_IN", 7001)
    P7.Refresh()
    check(P7.guide.id == "c:two", "the chain walks into the next route", P7.guide.id)
    n = 0
    for _ in pairs(A7.Done("c:two")) do n = n + 1 end
    check(n == 21 * 2 and P7.current.qid[1] == 7101, "... which is prefilled: 21 completed quests ticked, the first open step current", n)
    check(NS7.db.char.recent == nil or NS7.db.char.recent["c:two"] == nil or (NS7.db.char.recent["c:two"].s or 0) <= (NS7.db.char.recent["c:one"] and NS7.db.char.recent["c:one"].s or 0),
        "catching up is not progress: it does not move a route up in Recent")
end
end

-- ===========================================================================
-- 6. The real data of every client
-- ===========================================================================
local function pct(sorted, p) return sorted[math.max(1, math.ceil(#sorted * p))] or 0 end
for _, fl in ipairs(FLAVORS) do
    if (not next(want) or want[fl]) then
        local wiki = "CompletionRoute/Guides/Imported_Wiki_" .. fl .. ".lua"
        local index = "CompletionRoute/Data/QuestIndex_" .. fl .. ".lua"
        if not exists(wiki) then
            print(("skip %s: %s not generated here"):format(fl, wiki))
        elseif not exists(index) then
            print(("skip %s: %s not generated here (run luajit -joff tools/gen_quest_index.lua %s)"):format(fl, index, fl))
        else
            for _, who in ipairs({ { "Alliance", "WARRIOR", "Human" }, { "Horde", "MAGE", "Orc" } }) do
                local NS = harness(fl, { real = true, who = who })
                local G, QC, A, M = NS.Guide, NS.QuestCounts, NS.Account, NS.GuideMenu
                local T = M._test
                local tag = fl .. " " .. who[1]
                check(NS.QuestIndex and NS.QuestIndex.flavor == fl, tag .. ": the quest index of this client loaded")
                local avail = G.Available()

                -- (a) the index gives what the parser gives, for every route this character sees
                local stale, wrong, unlisted, questRoutes, bad = 0, 0, 0, 0, nil
                for _, g in ipairs(avail) do
                    if not g.loop and not G.IsSideGuide(g) then
                        local src = g.part and G.registry[g.part] or g
                        local fromIndex, isQuestEntry = QC._test.fromIndex(src)
                        if fromIndex and not isQuestEntry then fromIndex = nil end
                        local had = g.steps ~= nil
                        local steps = G.Steps(g.id)
                        local groups = QC.Groups(steps)
                        local parsed = QC.Resolve(groups)
                        if not had then g.steps = nil end
                        if groups.quest then
                            questRoutes = questRoutes + 1
                            if not fromIndex then
                                if NS.QuestIndex.r[src.id] then stale = stale + 1 else unlisted = unlisted + 1 end
                                bad = bad or g.id
                            elseif not sameSet(fromIndex, parsed) then wrong = wrong + 1 bad = bad or g.id end
                        elseif fromIndex then wrong = wrong + 1 bad = bad or g.id end
                    end
                end
                check(stale == 0 and unlisted == 0, ("%s: every quest route is in the index and current (%d stale, %d unlisted of %d; re-run tools/gen_quest_index.lua %s)"):format(
                    tag, stale, unlisted, questRoutes, fl), bad)
                check(wrong == 0, ("%s: the index names the same quests as the parsed steps for all %d quest routes"):format(tag, questRoutes), bad)
                collectgarbage()

                -- (b) the scan: no quest route is parsed; the frames stay short
                QC._test.reset()
                local parsedQuestRoute, parsedOther = 0, 0
                local steps0 = G.Steps
                G.Steps = function(id)
                    local g = G.registry[id]
                    if g and not g.steps then
                        if not g.loop and not G.IsSideGuide(g) and select(2, QC._test.fromIndex(g.part and G.registry[g.part] or g)) then parsedQuestRoute = parsedQuestRoute + 1
                        else parsedOther = parsedOther + 1 end
                    end
                    return steps0(id)
                end
                -- a character with a third of the client's quests done
                local i = 0
                for _, line in pairs(NS.QuestIndex.r) do
                    for q in line:gsub("^%d+|", ""):gmatch("%d+") do
                        i = i + 1
                        if i % 3 == 0 then A.me.quests[tonumber(q)] = true end
                    end
                end
                A.ClearCompletionCaches()
                M.RescanCompletion()
                local times, quick = {}, {}
                local guard = 0
                M.Refresh()
                while true do
                    guard = guard + 1
                    local before = parsedOther
                    local t0 = os.clock()
                    local finished = T.scanStep()
                    local ms = (os.clock() - t0) * 1000
                    times[#times + 1] = ms
                    if parsedOther == before then quick[#quick + 1] = ms end       -- a frame that parsed nothing
                    if finished or guard > 500000 then break end
                end
                G.Steps = steps0
                table.sort(times) table.sort(quick)
                check(parsedQuestRoute == 0, ("%s: the scan parsed no quest route (%d other routes, as before)"):format(tag, parsedOther), parsedQuestRoute)
                -- the slice budget is 4 ms; a frame that parses nothing may overrun by one route's count, never by much
                check(pct(quick, 1) < 12, ("%s: frames that parse nothing stay near the 4 ms budget (max %.1f ms over %d frames)"):format(tag, pct(quick, 1), #quick))
                -- the folder tallies and the total: one redraw asks for them, the next frames add them up
                expandAll(NS)
                M.Refresh()
                local tally = {}
                guard = 0
                while true do
                    guard = guard + 1
                    local t0 = os.clock()
                    local finished = T.scanStep()
                    tally[#tally + 1] = (os.clock() - t0) * 1000
                    if finished or guard > 500000 then break end
                end
                table.sort(tally)
                check(pct(tally, 1) < 12, ("%s: tally frames stay near the 4 ms budget (max %.1f ms over %d frames)"):format(tag, pct(tally, 1), #tally))
                settle(NS)
                local total = plain(T.totalLine:GetText())
                -- for comparison: the same scan with no index (every route parsed, as before 2026-11-13)
                local scanMs, oldMs, oldMax = 0, 0, 0
                for _, ms in ipairs(times) do scanMs = scanMs + ms end
                do
                    local keep = NS.QuestIndex
                    NS.QuestIndex = nil
                    QC._test.reset()
                    A.ClearCompletionCaches()
                    M.RescanCompletion()
                    guard = 0
                    while true do
                        guard = guard + 1
                        local t0 = os.clock()
                        local finished = T.scanSlice()
                        local ms = (os.clock() - t0) * 1000
                        oldMs = oldMs + ms
                        if ms > oldMax then oldMax = ms end
                        if finished or guard > 500000 then break end
                    end
                    NS.QuestIndex = keep
                    QC._test.reset()
                    A.ClearCompletionCaches()
                    M.RescanCompletion()
                    settle(NS)
                    check(plain(T.totalLine:GetText()) == total, tag .. ": without the index (every route parsed) the total is the same", plain(T.totalLine:GetText()))
                end

                -- (c) the total equals a plain union over every quest route
                local seen, done, tot = {}, 0, 0
                for _, g in ipairs(avail) do
                    local list, isQuest = QC.Quests(g, false)
                    if isQuest then
                        for _, q in ipairs(list) do
                            if not seen[q] then seen[q] = true tot = tot + 1 if A.me.quests[q] then done = done + 1 end end
                        end
                    end
                end
                check(total == ("Quests done: %s of %s"):format(QC.Fmt(done), QC.Fmt(tot)), tag .. ": the total line equals the union of all quest routes", total)
                check(tot > 1000, tag .. ": more than 1,000 quests are counted", tot)

                -- (d) no folder row says "0 completed"; quest folders show quests
                local nodes, withQuests = 0, 0
                for _, b in ipairs(T.buttons) do
                    if b.__shown and b.nodePath then
                        nodes = nodes + 1
                        local r = plain(b.right:GetText()) or ""
                        if r:find(" quests$") then withQuests = withQuests + 1 end
                        if r:find("0 completed") or r == "..." then check(false, tag .. ": folder row " .. b.nodePath .. " reads '" .. r .. "'") end
                    end
                end
                check(withQuests > 0, ("%s: %d of %d folder rows show a quest count"):format(tag, withQuests, nodes))

                -- (e) the order of the real names in every folder
                local tree = T.buildTree()
                local folders, chainBad, partBad, profBad, firstBad = 0, 0, 0, 0, nil
                local function walk(nd)
                    if #nd.guides > 1 and not nd.synthetic then
                        folders = folders + 1
                        local lastChain, lastSeries, lastPart, lastProf, lastSkill = -1, nil, 0, nil, -1
                        local closed = {}
                        for _, g in ipairs(nd.guides) do
                            local chain = tonumber(tostring(g.id):match("^spine:.-:(%d+)$"))
                            if chain then
                                if chain <= lastChain then chainBad = chainBad + 1 firstBad = firstBad or g.id end
                                lastChain = chain
                            elseif lastChain >= 0 and false then chainBad = chainBad + 1 end
                            if not chain then
                                local shown = G.DisplayName(g)
                                local base, k, n = shown:match("^(.-)%s*%-%s*Part%s+(%d+)%s*/%s*(%d+)")
                                local own = ((g.name or ""):find("%(Alliance%)") or (g.name or ""):find("%(Horde%)")) and "f" or "b"
                                local series = base and (base .. "/" .. n .. own .. "/" .. (tostring(g.id):match("^(.*):%d+$") or "")) or nil
                                if series then
                                    k = tonumber(k)
                                    if series == lastSeries then
                                        if k <= lastPart then partBad = partBad + 1 firstBad = firstBad or g.id end
                                    else
                                        -- a series must not come back after another row was shown in between
                                        if closed[series] then partBad = partBad + 1 firstBad = firstBad or g.id end
                                        if lastSeries then closed[lastSeries] = true end
                                    end
                                    lastSeries, lastPart = series, k
                                else
                                    if lastSeries then closed[lastSeries] = true end
                                    lastSeries, lastPart = nil, 0
                                end
                                if g.prof and g.skillMin then
                                    local pk = g.prof .. "/" .. tostring(g.tier) .. "/" .. tostring(g.faction)
                                    if pk == lastProf and g.skillMin < lastSkill then profBad = profBad + 1 firstBad = firstBad or g.id end
                                    lastProf, lastSkill = pk, g.skillMin
                                end
                            end
                        end
                    end
                    for _, k in ipairs(nd.kids) do walk(k) end
                end
                walk(tree)
                check(chainBad == 0, ("%s: leveling chain routes are in chain order in all %d folders"):format(tag, folders), firstBad)
                check(partBad == 0, tag .. ": every zone's parts are adjacent and ascending", firstBad)
                check(profBad == 0, tag .. ": profession routes of one profession run by skill", firstBad)
                -- the flat search over everything keeps the chain first and in order
                local rows = T.searchRows("quests")
                local last, sbad = -1, 0
                local seenOther = false
                for _, r in ipairs(rows) do
                    local chain = tonumber(tostring(r.guide.id):match("^spine:.-:(%d+)$"))
                    if chain then
                        if chain <= last or seenOther then sbad = sbad + 1 end
                        last = chain
                    else seenOther = true end
                end
                check(sbad == 0, ("%s: search results (%d rows for 'quests') keep the chain first and in order"):format(tag, #rows))

                print(("%-16s %4d routes, %4d quest routes, %s | scan %d frames, %.0f ms in all, p95 %.1f, max %.1f ms (%d routes parsed; frames that parse nothing: max %.1f ms) | tallies %d frames, max %.1f ms | no index: %.0f ms in all, max %.1f ms"):format(
                    tag, #avail, questRoutes, total, #times, scanMs, pct(times, 0.95), pct(times, 1), parsedOther, pct(quick, 1),
                    #tally, pct(tally, 1), oldMs, oldMax))
                NS = nil
                collectgarbage() collectgarbage()
            end
        end
    end
end

print(("%d checks, %d failed"):format(checks, fails))
if fails > 0 then os.exit(1) end
print("quest counts OK")
