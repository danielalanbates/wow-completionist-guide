-- CompletionRoute :: tools/test_dungeons.lua
-- Offline tests of the Dungeons section of the routes list (owner, 2026-11-16: "We need a dungeons section that
-- includes all the quests leading up to the dungeon"; docs/DUNGEONS.md):
--   1. UI/GuideMenu.lua + Core/Recommend.lua on synthetic routes: a top-level "Dungeons" category, its folders in
--      expansion order with dungeons before raids (folderOrder), the routes of a folder by level, the level range on
--      the row, the "next for your level" tag (R.NextDungeon), and that none of it parses a route
--   2. the generated routes of every client (Guides/Imported_Dungeons_<flavor>.lua, tools/wiki/gen_dungeons.py), read
--      with the add-on's own parser through the flavor's TOC (tools/guide_walk.lua): registration fields, every quest
--      step is a step of the client's wiki quest routes, accept before objectives before turn-in, every |PRE| of an
--      accept is met earlier in the same route (or names a quest this client does not have), an "Enter" step before
--      the instance's objectives, the routes are registered unparsed
-- Run from the repo root:  luajit -joff tools/test_dungeons.lua [flavor ...]     (no flavor = all five)
-- Copyright (c) 2026 Daniel Bates / Bates LLC.  All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
package.path = "./?.lua;" .. package.path
local ADDON = "CompletionRoute"
local passed, failed = 0, 0
local function t(name, cond, detail)
    if cond then passed = passed + 1
    else failed = failed + 1 print("FAIL " .. name .. (detail ~= nil and (" :: " .. tostring(detail)) or "")) end
    return cond
end
local function exists(p) local f = io.open(p, "r") if f then f:close() return true end return false end
local want = {}
for i = 1, #arg do want[arg[i]] = true end

-- ---------------------------------------------------------------------------
-- 1. the list, on synthetic routes
-- ---------------------------------------------------------------------------
do
    local NS = {}
    dofile("tools/stubs.lua")
    local z2w = z2w
    PLAYER = { map = 1429, x = 0.487, y = 0.42 } PLAYER.wx, PLAYER.wy, PLAYER.inst = z2w(PLAYER.x, PLAYER.y, PLAYER.map)
    local function load(path) assert(loadfile("CompletionRoute/" .. path))(ADDON, NS) end
    for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", "Data/Taxi_tbc.lua", "Data/Transit.lua",
        "Data/Access.lua", "Data/Inns.lua", "Data/ZoneAliases.lua", "Data/Roads_ek.lua", "Data/Roads_kalimdor.lua", "Routing/CostModel.lua",
        "Routing/TravelGraph.lua", "Routing/Roads.lua", "Routing/StepOrder.lua", "Routing/Router.lua", "Core/Account.lua",
        "Core/QuestCounts.lua", "Core/Professions.lua", "Core/Progress.lua", "Core/Recommend.lua", "Core/Farm.lua" }) do load(f) end
    GameTooltip = CreateFrame()
    SlashCmdList = SlashCmdList or {}
    GameFontNormal = {}
    assert(loadfile("CompletionRoute/UI/GuideMenu.lua"))(ADDON, NS)
    CompletionRouteDB, CompletionRouteCharDB = nil, nil
    for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", "CompletionRoute") end
    NS.Account.Init()
    NS.db.profile.routing.assumeAllTaxi = true
    NS.TravelGraph.Build()
    local G, R, M = NS.Guide, NS.Recommend, NS.GuideMenu
    local T = M._test
    local level = 20
    UnitLevel = function() return level end
    local PARSES = 0
    local function reg(id, def)
        def.id, def.source = id, "CompletionRoute"
        def.type = def.type or "Dungeons"
        def.text = function() PARSES = PARSES + 1 return "A One|QID|11|\nT One|QID|11|\n" end
        G.Register(def)
    end
    -- names that sort the other way round from their levels, folders whose names sort the other way round from
    -- their expansion order
    reg("d:aaa", { name = "Aaa Keep", folder = "Classic Dungeons", folderOrder = 0, instance = "Dungeon", minlevel = 30, maxlevel = 40 })
    reg("d:dm", { name = "The Deadmines (Alliance)", faction = "Alliance", folder = "Classic Dungeons", folderOrder = 0,
                  instance = "Dungeon", minlevel = 15, maxlevel = 28 })
    reg("d:dmh", { name = "The Deadmines (Horde)", faction = "Horde", folder = "Classic Dungeons", folderOrder = 0,
                   instance = "Dungeon", minlevel = 15, maxlevel = 28 })
    reg("d:wc", { name = "Wailing Caverns", folder = "Classic Dungeons", folderOrder = 0, instance = "Dungeon", minlevel = 17, maxlevel = 24 })
    reg("d:raid", { name = "Aaa Raid", folder = "Classic Raids", folderOrder = 1, instance = "Raid", minlevel = 18, maxlevel = 22 })
    reg("d:mc", { name = "Molten Core", folder = "Classic Raids", folderOrder = 1, instance = "Raid", minlevel = 60, maxlevel = 60 })
    reg("d:late", { name = "Late Raid", folder = "Classic Raids", folderOrder = 1, instance = "Raid", minlevel = 68, maxlevel = 70 })
    reg("d:ramps", { name = "Hellfire Ramparts", folder = "Burning Crusade Dungeons", folderOrder = 2, instance = "Dungeon",
                     minlevel = 59, maxlevel = 67 })
    reg("q:zone", { name = "Elwynn Forest Quests 1-10", type = "Quests", zone = 1429, minlevel = 1, maxlevel = 10 })
    local root = T.buildTree()
    local dn
    for _, k in ipairs(root.kids) do if k.name == "Dungeons" then dn = k end end
    t("a top-level Dungeons category holds the dungeon routes", dn ~= nil and dn.count == 7, dn and dn.count)
    local names = {}
    for i, k in ipairs(dn and dn.kids or {}) do names[i] = k.name end
    t("its folders go by expansion, dungeons before raids", table.concat(names, ",") == "Classic Dungeons,Classic Raids,Burning Crusade Dungeons",
      table.concat(names, ","))
    local cd = dn and dn.kidByName["Classic Dungeons"]
    local order = {}
    for i, g in ipairs(cd and cd.guides or {}) do order[i] = g.id end
    t("routes in a folder go by the instance's level, lowest first", table.concat(order, ",") == "d:dm,d:wc,d:aaa", table.concat(order, ","))
    t("the faction route of the other faction is not listed", not table.concat(order, ","):find("d:dmh"))
    local label = T.guideLabel(G.registry["d:dm"], false)
    t("a dungeon row shows its level range", label:find("%[15%-28%]") ~= nil, label)
    t("the row shows the name without the faction", label:find("The Deadmines") ~= nil and not label:find("Alliance"), label)
    -- the dungeon for the level: a 5-player dungeon before a raid, then the range centred nearest the level
    local nd = R.NextDungeon(20)
    t("next dungeon at 20: Wailing Caverns (17-24, centre 20.5) before the Deadmines (15-28, centre 21.5)", nd and nd.id == "d:wc", nd and nd.id)
    t("a raid that fits better is not the pick while a dungeon fits", nd and nd.id ~= "d:raid")
    t("the row of that route says so", T.guideLabel(G.registry["d:wc"], false):find("next for your level") ~= nil)
    t("other dungeon rows do not", not T.guideLabel(G.registry["d:dm"], false):find("next for your level"))
    t("a quest route row never does", not T.guideLabel(G.registry["q:zone"], false):find("next for your level"))
    t("no pick when no dungeon fits", R.NextDungeon(5) == nil)
    t("level 60: the 5-player Hellfire Ramparts (59-67) before the raid Molten Core (60)", R.NextDungeon(60) and R.NextDungeon(60).id == "d:ramps",
      R.NextDungeon(60) and R.NextDungeon(60).id)
    t("level 69: a raid when no dungeon fits", R.NextDungeon(69) and R.NextDungeon(69).id == "d:late", R.NextDungeon(69) and R.NextDungeon(69).id)
    NS.Account.doneCache = NS.Account.doneCache or {}
    local scope = NS.Account.Scope()
    NS.Account.doneCache[scope] = NS.Account.doneCache[scope] or {}
    NS.Account.doneCache[scope]["d:wc"] = true
    R.Invalidate()
    nd = R.NextDungeon(20)
    t("a finished dungeon is not the pick", nd and nd.id == "d:dm", nd and nd.id)
    NS.Account.doneCache[scope]["d:wc"] = nil
    R.Invalidate()
    t("the list, the labels and the pick parse no route", PARSES == 0, PARSES)
    t("the Recommended section is unchanged: no dungeon pick in it", (function()
        for _, g in ipairs(M.Recommended(20)) do if g.type == "Dungeons" then return false end end
        return true end)())
    -- grouped by level, the dungeon routes go to the band of the level like every other route
    local prefs = T.prefs()
    prefs.groupByLevel = true
    local groot = T.buildTree()
    prefs.groupByLevel = false
    local band
    for _, k in ipairs(groot.kids) do if k.name == "20-29" then band = k end end
    t("grouped by level, the band of the level holds a Dungeons category", band and band.kidByName["Dungeons"] ~= nil)
    -- Prefill and CheckStep on D Enter steps: a pass whose quests are still open keeps its Enter step open; once every
    -- quest of that pass is done, Prefill ticks its Enter step so a completed route opens as finished; entering the
    -- instance (IsInInstance) completes the Enter step
    G.Register({ id = "d:prefill", name = "Prefill Dungeon", type = "Dungeons", folder = "Classic Dungeons", folderOrder = 0,
                 instance = "Dungeon", minlevel = 15, maxlevel = 25, source = "CompletionRoute",
                 text = "A Lead|QID|901|M|40,40|Z|1429; Elwynn Forest|\n"
                     .. "T Lead|QID|901|M|40,40|Z|1429; Elwynn Forest|\n"
                     .. "A Boss 1|QID|902|M|40,40|Z|1429; Elwynn Forest|\n"
                     .. "D Enter Prefill Dungeon|M|41,41|Z|1429; Elwynn Forest|\n"
                     .. "C Boss 1|QID|902|QO|1|M|42,42|Z|1429; Elwynn Forest|\n"
                     .. "T Boss 1|QID|902|M|40,40|Z|1429; Elwynn Forest|\n" })
    local P = NS.Progress
    COMPLETED_QUESTS = { 901 }
    NS.Account.HarvestCompleted(true)
    P.Load("d:prefill")
    t("with an inside quest still open, Prefill leaves the Enter step open", P.current and P.current.qid and P.current.qid[1] == 902,
      P.current and P.current.title)
    P.MarkDone(P.current)
    t("after accepting the outside quest, the current step is Enter", P.current and P.current.action == "D", P.current and P.current.action)
    IsInInstance = function() return true, "party" end
    P.Refresh()
    IsInInstance = nil
    t("entering the instance (IsInInstance) completes the Enter step", P.current and P.current.action == "C", P.current and P.current.action)
    COMPLETED_QUESTS = { 901, 902 }
    NS.Account.HarvestCompleted(true)
    P.Reset()
    t("when every quest of a dungeon route is completed, Prefill ticks the Enter step too and the route is finished",
      P.current == nil and #P.Pending() == 0, P.current and P.current.title)
    COMPLETED_QUESTS = {}
    print(("synthetic: %d passed, %d failed"):format(passed, failed))
end

-- ---------------------------------------------------------------------------
-- 2. the generated routes of every client
-- ---------------------------------------------------------------------------
local W = dofile("tools/guide_walk.lua")
local ran = 0
for _, fl in ipairs(W.FLAVORS) do
    local file = "CompletionRoute/Guides/Imported_Dungeons_" .. fl.name .. ".lua"
    if (next(want) == nil or want[fl.name]) and exists(file) then
        ran = ran + 1
        local p0, f0 = passed, failed
        -- the wiki routes' quest steps, by signature; and each dungeon route's steps in order
        local wikiSig, wikiQuests, otherFaction, wikiPre = {}, {}, {}, {}
        local routes, order = {}, {}
        local unparsed, regs = 0, 0
        local NS = W.Walk(fl, function(s, g, family)
            if family == "wiki quest guides" and s.qid then
                wikiSig[s.action .. ":" .. table.concat(s.qid, "+") .. ":" .. tostring(s.qo or "")] = true
                for _, q in ipairs(s.qid) do
                    wikiQuests[q] = true
                    -- [q] = the faction that cannot take q (its accept is gated to the other one)
                    if s.action == "A" and s.pre then wikiPre[q] = s.pre end
                    if s.action == "A" then
                        local f = s.faction
                        local o = (f == "Alliance" and "Horde") or (f == "Horde" and "Alliance") or false
                        if otherFaction[q] == nil then otherFaction[q] = o
                        elseif otherFaction[q] ~= o then otherFaction[q] = false end
                    end
                end
            elseif family == "dungeon routes" then
                local r = routes[g.id]
                r.steps[#r.steps + 1] = s
            end
        end, function(g, family)
            if family == "dungeon routes" then
                regs = regs + 1
                if type(g.text) == "string" and g.steps == nil then unparsed = unparsed + 1 end
                routes[g.id] = { g = g, steps = {} }
                order[#order + 1] = g.id
            end
        end)
        t(fl.name .. ": the file registers dungeon routes", #order > 0, #order)
        t(fl.name .. ": every route is registered as text and not parsed at load", unparsed == regs, unparsed .. "/" .. regs)
        local bad = {}
        local function note(kind, id, what)
            bad[kind] = bad[kind] or { n = 0, first = id .. ": " .. tostring(what) }
            bad[kind].n = bad[kind].n + 1
        end
        local idsSeen = {}
        -- the wiki's own chains can loop ("any one of" links back into the chain that leads to the quest): no order
        -- meets such a PRE, the zone routes have the same step; counted, not failed
        local cycles = 0
        local cyc = {}          -- [quest] = true when its prerequisites (followed back) run into a loop
        local function loops(x, path)
            if cyc[x] ~= nil then return cyc[x] end
            if path[x] then return true end
            path[x] = true
            local r = false
            for _, y in ipairs(wikiPre[x] or {}) do if loops(y, path) then r = true break end end
            path[x] = nil
            cyc[x] = r
            return r
        end
        local function inCycle(q, pre)
            for _, p in ipairs(pre) do if loops(p, { [q] = true }) then return true end end
            return false
        end
        for _, id in ipairs(order) do
            local r = routes[id]
            local g, steps = r.g, r.steps
            if idsSeen[id] then note("duplicate id", id, "") end
            idsSeen[id] = true
            if not id:match("^dungeon:" .. fl.name .. ":") then note("id prefix", id, "") end
            if g.type ~= "Dungeons" then note("type", id, g.type) end
            if not (g.folder and tonumber(g.folderOrder)) then note("folder", id, tostring(g.folder)) end
            if g.instance ~= "Dungeon" and g.instance ~= "Raid" then note("instance kind", id, tostring(g.instance)) end
            if g.minlevel and g.maxlevel and g.minlevel > g.maxlevel then note("level range", id, g.minlevel .. "-" .. g.maxlevel) end
            if g.faction and g.faction ~= "Alliance" and g.faction ~= "Horde" then note("faction", id, g.faction) end
            local firstA, lastC, firstT, turned = {}, {}, {}, {}
            local firstD, quests = nil, 0
            local seenD, dIdxs = {}, {}
            for i, s in ipairs(steps) do
                if s.action == "D" then
                    firstD = firstD or i
                    dIdxs[#dIdxs + 1] = i
                    if seenD[s.title] then note("duplicate Enter step title", id, s.title) end
                    seenD[s.title] = true
                    if s.zoneName == "The Great Sea" then note("Enter step on The Great Sea", id, s.title) end
                end
                if s.qid and #s.qid > 0 then
                    local q = s.qid[1]
                    if not wikiSig[s.action .. ":" .. table.concat(s.qid, "+") .. ":" .. tostring(s.qo or "")] then
                        note("quest step not in the wiki routes", id, s.action .. " " .. table.concat(s.qid, "+") .. " " .. tostring(s.title))
                    end
                    if s.action == "A" then
                        if firstA[q] then note("quest accepted twice", id, q) end
                        firstA[q] = firstA[q] or i
                        quests = quests + 1
                        -- every PRE of an accept is met before it in the same route: any one of them (all with "&"),
                        -- a quest this client does not have does not count
                        local pre = s.pre
                        if pre and #pre > 0 then
                            local need, have = 0, 0
                            for _, p in ipairs(pre) do
                                -- a quest of the other faction cannot be done by this route's character either
                                if wikiQuests[p] and not (g.faction and otherFaction[p] == g.faction) then
                                    need = need + 1
                                    if turned[p] then have = have + 1 end
                                end
                            end
                            local allOf = pre.andor == "and"
                            if need > 0 and ((allOf and have < need) or (not allOf and have == 0)) then
                                if inCycle(q, pre) then cycles = cycles + 1
                                else note("an accept whose PRE is not done earlier in the route", id, q .. " needs " .. table.concat(pre, ";")) end
                            end
                        end
                    elseif s.action == "C" then lastC[q] = i
                    elseif s.action == "T" then
                        if firstT[q] then note("quest turned in twice", id, q) end
                        firstT[q] = firstT[q] or i
                        turned[q] = true
                    end
                end
            end
            for q, ti in pairs(firstT) do
                if firstA[q] and firstA[q] > ti then note("turn-in before accept", id, q) end
                if lastC[q] and lastC[q] > ti then note("objective after turn-in", id, q) end
            end
            for q, ci in pairs(lastC) do
                if firstA[q] and firstA[q] > ci then note("objective before accept", id, q) end
            end
            if not firstD then note("no Enter step", id, "")
            elseif not steps[firstD].title:match("^Enter ") then note("Enter step title", id, steps[firstD].title) end
            if quests == 0 then note("no quest accepted", id, "") end
            -- the instance's objectives come after the first "Enter": the last objective step of the route is after it
            local lastObj = 0
            for q, ci in pairs(lastC) do if ci > lastObj then lastObj = ci end end
            if firstD and lastObj > 0 and lastObj < firstD then note("no objective after the Enter step", id, "") end
            -- every Enter step must have at least one quest step before the next Enter step (no empty pass)
            for di, at in ipairs(dIdxs) do
                local stop = dIdxs[di + 1] and (dIdxs[di + 1] - 1) or #steps
                local hasIn = false
                for k = at + 1, stop do
                    if steps[k].qid and #steps[k].qid > 0 then hasIn = true break end
                end
                if not hasIn then note("Enter pass with no quest step", id, steps[at].title) end
            end
        end
        for kind, b in pairs(bad) do t(fl.name .. ": " .. kind, false, b.n .. " route(s), first " .. b.first) end
        t(fl.name .. ": every check passed on every route", next(bad) == nil)
        if fl.name == "mop" or fl.name == "retail" then
            for _, rid in ipairs({ "dungeon:" .. fl.name .. ":deadmines:Alliance", "dungeon:" .. fl.name .. ":blackrock-caverns",
                                   "dungeon:" .. fl.name .. ":shadowfang-keep:Alliance", "dungeon:" .. fl.name .. ":shadowfang-keep:Horde" }) do
                local r = routes[rid]
                local nd = 0
                for _, s in ipairs(r and r.steps or {}) do if s.action == "D" then nd = nd + 1 end end
                t(fl.name .. ": " .. rid .. " runs in one pass", nd == 1, nd)
            end
        end
        if fl.name == "retail" then
            t("retail: Hellfire Citadel and Operation: Floodgate have routes",
              routes["dungeon:retail:hellfire-citadel:Alliance"] ~= nil and routes["dungeon:retail:operation-floodgate"] ~= nil)
            local za = routes["dungeon:retail:zul-aman:Alliance"]
            t("retail: Zul'Aman dungeon route is not polluted by the Midnight outdoor zone quests",
              za and #za.steps < 100, za and #za.steps)
        end
        if cycles > 0 then print(("%s: %d accept(s) whose PRE chain runs into a loop in the wiki data (not failed)"):format(fl.name, cycles)) end
        print(("%s: %d dungeon routes, %d checks passed, %d failed"):format(fl.name, #order, passed - p0, failed - f0))
        collectgarbage()
    end
end
if ran == 0 then print("generated part SKIPPED (no Guides/Imported_Dungeons_*.lua: run tools/wiki/gen_dungeons.py)") end
print(("test_dungeons: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
