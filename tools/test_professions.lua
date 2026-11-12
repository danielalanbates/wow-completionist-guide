-- CompletionRoute :: tools/test_professions.lua
-- Invariants over every generated Guides/Imported_Professions_<fl>.lua, plus a walk through a sample in a stubbed world.
-- Stubs the WoW API (tools/stubs.lua); nothing here is proof about a live client.
-- Copyright (c) 2026 Daniel Bates / Bates LLC.  All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- Run from the repo root: luajit tools/test_professions.lua            (every flavor with a generated file)
--                         luajit tools/test_professions.lua --one era  (one flavor, used internally)
package.path = "./?.lua;" .. package.path
local FLAVORS = { "era", "tbc", "mop", "retail", "forever" }

if arg[1] ~= "--one" then
    local bad = 0
    print(("%-8s %7s %6s %6s %5s %6s %6s %6s %5s  %s"):format("flavor", "guides", "steps", "make", "alt", "recipe", "short", "walked", "fail", "file"))
    for _, fl in ipairs(FLAVORS) do
        local path = "CompletionRoute/Guides/Imported_Professions_" .. fl .. ".lua"
        local f = io.open(path)
        if f then
            f:close()
            local p = io.popen("luajit tools/test_professions.lua --one " .. fl .. " 2>&1")
            local failed, row = true, nil
            for line in p:lines() do
                if line:find("^FAIL") or line:find("^ERROR") or line:find("stack traceback") then print(line) end
                if line:find("^ROW ") then row = line:sub(5) end
                if line:find("^FLAVOR OK") then failed = false end
            end
            p:close()
            print(row or (fl .. ": no result row"))
            if failed then bad = bad + 1 end
        else
            print(fl .. ": no generated file, skipped")
        end
    end
    if bad > 0 then print(bad .. " FLAVOR(S) FAILED") os.exit(1) end
    print("ALL PROFESSION GUIDE TESTS PASSED")
    os.exit(0)
end

local flavor = arg[2]
local SKILL_LINE = { Cooking = "185", Fishing = "356", ["First Aid"] = "129", Archaeology = "794" }
local TOC = { era = 11507, tbc = 20506, mop = 50504, retail = 120100, forever = 16001 }
local TAXI = { era = "Data/Taxi_era.lua", tbc = "Data/Taxi_tbc.lua", mop = "Data/Taxi_mop.lua", retail = "Data/Taxi_retail.lua", forever = "Data/Taxi_forever.lua" }
local failures, total = 0, 0
local function fail(msg) failures = failures + 1 print("FAIL " .. flavor .. ": " .. msg) end
local function check(cond, msg) total = total + 1 if not cond then fail(msg) end end

-- ---- client tables: which spells each profession has and their grey thresholds
local function csvRows(path)
    local f = assert(io.open(path, "r"))
    local content = f:read("*a") f:close()
    local rows, field, row, inq, i, n = {}, {}, {}, false, 1, #content
    while i <= n do
        local c = content:sub(i, i)
        if inq then
            if c == '"' then
                if content:sub(i + 1, i + 1) == '"' then field[#field + 1] = '"' i = i + 1 else inq = false end
            else field[#field + 1] = c end
        elseif c == '"' then inq = true
        elseif c == "," then row[#row + 1] = table.concat(field) field = {}
        elseif c == "\n" then row[#row + 1] = table.concat(field) field = {} rows[#rows + 1] = row row = {}
        elseif c ~= "\r" then field[#field + 1] = c end
        i = i + 1
    end
    if #field > 0 or #row > 0 then row[#row + 1] = table.concat(field) rows[#rows + 1] = row end
    return rows
end
local rows = csvRows("tools/db2/" .. flavor .. "/SkillLineAbility.csv")
local hdr = {}
for k, v in ipairs(rows[1]) do hdr[v] = k end
local sla, slaYellow = {}, {}     -- [skill line][spell] = grey; [spell] = yellow
for i = 2, #rows do
    local r = rows[i]
    local sl, sp = r[hdr.SkillLine], r[hdr.Spell]
    if sl and sp then
        sla[sl] = sla[sl] or {} sla[sl][sp] = tonumber(r[hdr.TrivialSkillLineRankHigh]) or 0
        slaYellow[sp] = tonumber(r[hdr.TrivialSkillLineRankLow]) or 0
    end
end
rows = nil
-- MoP Classic only: the Pandaren Way of the Grill (SkillLine 975, a child of Cooking 185 in the client's SkillLine table)
-- is part of Cooking there; its recipes take Cooking past 525 (gen_professions.py WAYS).  Only that one Way is accepted.
if flavor == "mop" and sla["975"] then
    sla["185"] = sla["185"] or {}
    for sp, grey in pairs(sla["975"]) do sla["185"][sp] = sla["185"][sp] or grey end
end

-- ---- the client's maps
local maps = {}
do
    local mapChunk = assert(io.open("tools/maps_" .. flavor .. ".lua")):read("*a")
    for id in mapChunk:gmatch("%[(%d+)%]%s*=%s*{") do maps[tonumber(id)] = true end
end

-- ---- the real addon code against the stubs
local ADDON, NS = "CompletionRoute", {}
INTERFACE_VERSION = TOC[flavor]
dofile("tools/stubs.lua")
GetBuildInfo = function() return "0", "0", "", TOC[flavor] end
local z2w = z2w
local function load(path) assert(loadfile("CompletionRoute/" .. path))(ADDON, NS) end
local okLoad, errLoad = pcall(function()
    for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", TAXI[flavor], "Data/Transit.lua", "Data/Access.lua",
        "Data/Inns.lua", "Data/ZoneAliases.lua", "Data/Roads_ek.lua", "Data/Roads_kalimdor.lua", "Routing/CostModel.lua", "Routing/TravelGraph.lua", "Routing/Roads.lua",
        "Routing/StepOrder.lua", "Routing/Router.lua", "Core/Account.lua", "Core/Professions.lua", "Core/Progress.lua", "Core/Recommend.lua" }) do load(f) end
end)
check(okLoad, "addon core loads: " .. tostring(errLoad))
if not okLoad then print("ROW " .. flavor .. " core load failed") return end
NS.flavor = flavor == "forever" and "era" or flavor
NS.isForever = flavor == "forever" or nil
NS.dataFlavor = flavor
-- map lookups must answer for this flavor's map set, not the stub's
local U = NS.Util
local realMapIDByIDOrName = U.MapIDByIDOrName
U.MapIDByIDOrName = function(id, name) if id and maps[id] then return id end return realMapIDByIDOrName(id, name) end

CompletionRouteDB, CompletionRouteCharDB = nil, nil
for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", "CompletionRoute") end
NS.db.profile.routing.assumeAllTaxi = true
local G, Pr, Prof = NS.Guide, NS.Progress, NS.Professions

local file = "Guides/Imported_Professions_" .. flavor .. ".lua"
-- PROF_TEST_FILE: run the invariants over another file (used to prove they catch a doctored guide)
local override = os.getenv("PROF_TEST_FILE")
local okGen, errGen
if override then okGen, errGen = pcall(function() assert(loadfile(override))(ADDON, NS) end) else okGen, errGen = pcall(load, file) end
check(okGen, "generated file loads: " .. tostring(errGen))
if flavor == "mop" or flavor == "retail" then
    local okA, errA = pcall(load, "Core/Archaeology.lua")
    check(okA, "Core/Archaeology.lua loads: " .. tostring(errA))
end

-- ---- every invariant, on every guide of the file
local guides, stepsTotal, makes, altPts, recipes, short = 0, 0, 0, 0, 0, 0
local ids = {}
for _, id in ipairs(G.list) do if tostring(id):find("^prof:") and id ~= "prof:archaeology:active" then ids[#ids + 1] = id end end
check(#ids > 0, "the file registers guides")
local ACTIONS_OK = { ["="] = true, B = true, M = true, R = true, N = true, A = true, T = true, C = true, U = true }
for _, id in ipairs(ids) do
    guides = guides + 1
    local g = G.registry[id]
    local text = g.text
    local prev, parseFail = g.skillMin, 0
    for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        if line ~= "" then
            local s, err = G.ParseLine(line, 1, nil)
            if not s then parseFail = parseFail + 1 fail(id .. " does not parse: " .. tostring(err) .. " :: " .. line:sub(1, 90)) end
            local a = line:sub(1, 1)
            if not ACTIONS_OK[a] then fail(id .. " unexpected action '" .. a .. "'") end
            -- every step has a name (2026-11-12: retail Midnight Cooking had "M |SKILL|...|SPELL|1296257|", a recipe the
            -- client's SpellName table does not name; tools/wiki/gen_professions.py now leaves such a recipe out)
            check(s == nil or (s.title or ""):find("%S") ~= nil, id .. " step without a name: " .. line:sub(1, 90))
            -- no note ends in a price with its currency lost ("... and Shim'dak in Zul'Aman for 120": the wiki's
            -- currency template does not survive as text; tools/wiki/gen_professions.py display_source drops it)
            local note = line:match("|N|([^|]*)|")
            check(not (note and (note:find(" for %d[%d,]*%s*%.?%s*$") or note:find(" for %d[%d,]*%s*%.?%)"))),
                id .. " note ends in a cut-off price: " .. line:sub(1, 160))
            total = total + 1
            local alt = line:match("|ALT|([^|]*)|")
            if alt then
                for entry in alt:gmatch("[^;]+") do
                    local mid, x, y = entry:match("^(%d+),([%d%.]+),([%d%.]+),")
                    mid, x, y = tonumber(mid), tonumber(x), tonumber(y)
                    altPts = altPts + 1
                    check(mid and maps[mid], id .. " ALT map unknown to client: " .. entry)
                    check(x and y and x >= 0 and x <= 100 and y >= 0 and y <= 100, id .. " ALT point out of range: " .. entry)
                end
            end
            local mxy, zone = line:match("|M|([%d%.,]+)|Z|(%d+)")
            if mxy then
                local mx, my = mxy:match("([%d%.]+),([%d%.]+)")
                mx, my = tonumber(mx), tonumber(my)
                check(mx and my and mx >= 0 and mx <= 100 and my >= 0 and my <= 100, id .. " M point out of range: " .. line:sub(1, 80))
                check(maps[tonumber(zone)], id .. " M map unknown to client: " .. zone)
            end
            local zid = line:match("|Z|(%d+)")
            if zid then check(maps[tonumber(zid)], id .. " Z map unknown to client: " .. zid) end
            -- the engine completes a step when EITHER SKILL or RECIPE holds, so a make step must not carry RECIPE:
            -- the character already knows the recipe it is making and the step would finish at once
            if a == "M" then
                check(not (line:find("|RECIPE|", 1, true) and line:find("|SKILL|", 1, true)), id .. " make step carries both SKILL and RECIPE: " .. line:sub(1, 80))
            end
            local spell = line:match("|RECIPE|(%d+)|") or line:match("|SPELL|(%d+)|")
            if spell then
                recipes = recipes + 1
                local lines = sla[SKILL_LINE[g.prof]] or {}
                check(lines[spell] ~= nil, id .. " spell " .. spell .. " is not in this client's SkillLineAbility for " .. g.prof)
            end
            local target = line:match("|SKILL|[^;|]+;(%d+)")
            if target and a == "M" then
                target = tonumber(target)
                makes = makes + 1
                check(target > prev, id .. " SKILL targets not strictly rising: " .. prev .. " then " .. target)
                local sp = line:match("|SPELL|(%d+)|")
                if sp then
                    local grey = (sla[SKILL_LINE[g.prof]] or {})[sp]
                    check(grey and grey > prev, id .. " recipe " .. sp .. " is grey (" .. tostring(grey) .. ") at skill " .. prev)
                    -- one continuous skill track: a recipe far below its yellow cannot be learned yet (the wiki's per-expansion scale leaking in)
                    if flavor ~= "retail" then
                        check((slaYellow[sp] or 0) - prev <= 125, id .. " recipe " .. sp .. " used at skill " .. prev .. " but yellow is " .. tostring(slaYellow[sp]))
                    end
                end
                prev = target
            end
        end
    end
    check(parseFail == 0, id .. " has lines that do not parse")
    check(prev == g.skillMax, id .. " does not reach its band end: stops at " .. prev .. ", band end " .. tostring(g.skillMax))
    check(g.skillMax > g.skillMin, id .. " has an empty band")
    local steps = G.Steps(id)
    check(steps and #steps > 0, id .. " has no steps")
    stepsTotal = stepsTotal + (steps and #steps or 0)
    local f2 = id:match(":(%a+)$")
    check(g.faction == f2 and g.name:find("(" .. f2 .. ")", 1, true), id .. " faction mismatch: " .. tostring(g.faction) .. " / " .. tostring(g.name))
    check(g.type == "Professions" and g.folder == g.prof, id .. " type/folder wrong")
    if flavor == "retail" and g.prof ~= "Archaeology" then check(g.tier, id .. " has no tier") end
    if flavor == "forever" then check(g.forever == true, id .. " not marked Forever-native") end
    if g.skillMax < 75 and g.prof ~= "Archaeology" and flavor ~= "retail" then short = short + 1 end
end

-- ---- retail expansion tiers (2026-11-11): Outland and Shadowlands Cooking had no guide, Pandaria stopped at 22 and
-- Cataclysm at 36, because the learn skill fell back to the yellow threshold.  The client's own values (recipe item
-- RequiredSkillRank, MinSkillLineRank of an automatic recipe) and the recipe page's opening sentence now give it.  Tiers
-- the wiki's trainer table leaves empty take their trainers from the trainers' own pages (Category:Cooking trainers).
if flavor == "retail" then
    local reach, alt = {}, {}
    for _, id in ipairs(ids) do
        local g = G.registry[id]
        if g.prof == "Cooking" and g.tier then
            local k = g.tier .. ":" .. g.faction
            reach[k] = math.max(reach[k] or 0, g.skillMax)
            if g.skillMin <= 1 and g.text:find("|ALT|", 1, true) then alt[k] = true end
        end
    end
    for _, tier in ipairs({ 2547, 2546, 2545, 2752 }) do
        for _, fac in ipairs({ "Alliance", "Horde" }) do
            check((reach[tier .. ":" .. fac] or 0) >= 75, ("Cooking tier %d (%s) reaches 75, got %s"):format(tier, fac, tostring(reach[tier .. ":" .. fac])))
        end
    end
    -- Pandaria (2544): past 25 only Recipe: Spicy Salmon / Spicy Vegetable Chips (Exalted with the Tillers) or the Way
    -- recipes (their own skill lines, not planned) skill it, so a plan without a reputation grind stops at 22.  It must
    -- still have a guide for both factions; the reputation check below keeps the Exalted recipes out.
    for _, fac in ipairs({ "Alliance", "Horde" }) do
        check((reach["2544:" .. fac] or 0) >= 22, ("Cooking tier 2544 (%s) reaches 22, got %s"):format(fac, tostring(reach["2544:" .. fac])))
    end
    for _, tier in ipairs({ 2541, 2873, 2908 }) do
        check(alt[tier .. ":Alliance"] and alt[tier .. ":Horde"], ("Cooking tier %d lists a trainer for both factions"):format(tier))
    end
    -- Maraclozh (Khaz Algar fishing trainer): his page reads "[[Umbral Bazaar]], [[City of Threads]]{{Co|51.6|25.6|Undermine}}";
    -- the linked map wins over the {{Co}} zone, so his point is on the City of Threads (2213), not Undermine (2346)
    local mara
    for _, id in ipairs(ids) do
        local g = G.registry[id]
        if g.prof == "Fishing" then
            for m in g.text:gmatch("(%d+),[%d.]+,[%d.]+,Maraclozh") do mara = tonumber(m) end
        end
    end
    check(mara == 2213, ("Maraclozh's trainer point is on map %s, want the City of Threads (2213)"):format(tostring(mara)))
end

-- ---- MoP Classic Cooking 525-600 (2026-11-11 review): without the Tillers' Exalted recipes the plan stopped at 530.
-- Past 525 Pandaren cooking goes through a Way (wiki "Way of the Grill": 525 skill, then Ready for Greatness and Way of the
-- Grill (quest)); the plan uses the Way of the Grill, taught only by Kol Ironpaw, and must reach 600 for both factions with
-- the quest chain before the first Way recipe.
if flavor == "mop" then
    for _, fac in ipairs({ "Alliance", "Horde" }) do
        local g = G.registry["prof:mop:Cooking:8:" .. fac]
        check(g and g.skillMax == 600, ("mop Cooking band 8 (%s) reaches %s, want 600"):format(fac, tostring(g and g.skillMax)))
        local text = g and g.text or ""
        local q, way = text:find("T Way of the Grill|QID|31311|", 1, true), text:find("= Train Charbroiled Tiger Steak|", 1, true)
        check(q and way and q < way, ("mop Cooking band 8 (%s): the Way of the Grill quest comes before the first Way recipe"):format(fac))
        check(text:find("ALT|376,53.0,51.3,Kol Ironpaw|", 1, true), ("mop Cooking band 8 (%s): the Way recipes are trained at Kol Ironpaw"):format(fac))
    end
end

-- ---- no plan buys a recipe item the client gates behind a faction standing (2026-11-11 review).  ItemSparse
-- MinFactionID / MinReputation >= 4 (Friendly) on these Cooking and First Aid recipe items, all clients: a skill plan
-- cannot assume a reputation grind (Pandaria Cooking reached 75 only through Spicy Salmon, Exalted with the Tillers).
do
    local GATED = { [19442] = "Formula: Powerful Anti-Venom (Argent Dawn Honored)", [74657] = "Recipe: Spicy Salmon",
        [74658] = "Recipe: Spicy Vegetable Chips", [85502] = "Recipe: Viseclaw Soup", [85505] = "Recipe: Krasarang Fritters",
        [182668] = "Recipe: Feast of Gluttonous Hedonism", [142331] = "Recipe: Spiced Falcosaur Omelet",
        [162287] = "Recipe: Galley Banquet", [162288] = "Recipe: Bountiful Captain's Feast", [162289] = "Recipe: Bountiful Captain's Feast",
        [162292] = "Recipe: Grilled Catfish", [162293] = "Recipe: Seasoned Loins", [166263] = "Recipe: Sanguinated Feast",
        [166367] = "Recipe: Wild Berry Bread", [166368] = "Recipe: Seasoned Steak and Potatoes", [166806] = "Recipe: Boralus Blood Sausage",
        [168368] = "Recipe: Famine Evaluator And Snack Table", [168369] = "Recipe: Famine Evaluator And Snack Table" }
    local gated = 0
    for _, id in ipairs(ids) do
        for line in G.registry[id].text:gmatch("[^\n]+") do
            local it = line:match("^B [^|]*|L|(%d+) ")
            if it and line:find("|RECIPE|", 1, true) and GATED[tonumber(it)] then
                gated = gated + 1
                print("  FAIL " .. id .. " buys " .. GATED[tonumber(it)] .. ", which needs a faction standing")
            end
        end
    end
    check(gated == 0, flavor .. ": " .. gated .. " recipe buy steps need a faction standing")
end

-- ---- why make steps carry SPELL and not RECIPE: the engine finishes a step on EITHER tag
do
    SPELLS_KNOWN[4242] = true
    InstallProfessionAPI(flavor == "retail" and "retail" or flavor == "mop" and "mop" or "era")
    PROFS = { { name = "Cooking", rank = 10, max = 300, key = 185 } }
    Prof.Invalidate()
    local both = G.ParseLine("M Dish|SKILL|Cooking;75|RECIPE|4242|")
    local spell = G.ParseLine("M Dish|SKILL|Cooking;75|SPELL|4242|")
    check(Pr.CheckStep(both) == true, "engine contract changed: SKILL+RECIPE no longer completes on the recipe alone, make steps could carry RECIPE now")
    check(Pr.CheckStep(spell) == false, "a SPELL-tagged make step must stay open below its skill target")
    SPELLS_KNOWN[4242] = nil
end

-- ---- Core/Archaeology.lua: active list, static fallback, rebuild when a site is finished
if flavor == "mop" or flavor == "retail" then
    local A = NS.Archaeology
    check(A ~= nil, "NS.Archaeology exists")
    local total_sites = 0
    for cont, list in pairs(NS.ArchaeologySites or {}) do
        for _, s in ipairs(list) do
            total_sites = total_sites + 1
            check(maps[s[3]] and s[4] >= 0 and s[4] <= 100 and s[5] >= 0 and s[5] <= 100, "dig site out of range or unknown map: " .. tostring(s[2]))
        end
        check(maps[cont], "dig site continent unknown: " .. tostring(cont))
    end
    check(total_sites > 0, "static dig site list generated")
    local cont, list = next(NS.ArchaeologySites or {})
    if cont and list[1] then
        local site = list[1]
        local realInfo, realPos, realZone = C_Map.GetMapInfo, U.PlayerPos, U.MapName
        C_Map.GetMapInfo = function(id)
            if id == cont then return { mapID = id, mapType = 2, parentMapID = 947, name = "Continent" } end
            if id == site[3] then return { mapID = id, mapType = 3, parentMapID = cont, name = "Zone" } end
            return realInfo(id)
        end
        U.PlayerPos = function() return site[3], 0.5, 0.5 end
        C_ResearchInfo = nil
        check(A.ActiveSites(cont) == nil, "no dig site API reads as unknown")
        local text = A.BuildText()
        check(text:find("full site list", 1, true), "no API: static list with an honest note")
        check(select(2, text:gsub("\n", "")) <= 12, "no API: the static list is capped")
        for line in text:gmatch("[^\n]+") do check(G.ParseLine(line, 1, nil) ~= nil, "static dig line parses: " .. line:sub(1, 60)) end
        local active = "Fixture Dig"
        C_ResearchInfo = { GetDigSitesForMap = function(m)
            if m ~= site[3] then return {} end
            return { { researchSiteID = 9001, name = active, position = { x = 0.40, y = 0.60 } },
                     { researchSiteID = 9002, name = "Mixin Dig", position = { GetXY = function() return 0.45, 0.65 end } },
                     { researchSiteID = 9003, name = "Bad Dig", position = { x = 0, y = 0 } } }
        end }
        text = A.BuildText()
        check(text:find("Fixture Dig", 1, true) and text:find("Mixin Dig", 1, true) and not text:find("Bad Dig", 1, true), "active sites listed, a zero position dropped")
        check(not text:find("full site list", 1, true), "active list has no fallback note")
        local s = G.ParseLine(text:match("[^\n]+"), 1, nil)
        check(s and s.action == "M" and s.coords and s.coords[1], "active line is a located make step, not a proximity waypoint")
        G.registry[A.GUIDE_ID].steps = nil
        check(pcall(Pr.Load, A.GUIDE_ID), "dynamic guide loads")
        local first = Pr.current and Pr.current.title
        check(first == "Fixture Dig" or first == "Mixin Dig", "dynamic guide points at an active site: " .. tostring(first))
        check(Pr.CheckStep(Pr.current) == false, "arriving does not finish a dig site")
        local steps = G.Steps(A.GUIDE_ID)
        NS.db.char.done[A.GUIDE_ID] = { [1] = true }
        active = "Replacement Dig"
        A.Refresh()
        local again, seen = G.Steps(A.GUIDE_ID), false
        for _, st in ipairs(again) do if st.title == "Replacement Dig" then seen = true end end
        check(seen, "a finished site is replaced after the refresh")
        check(not next(NS.db.char.done[A.GUIDE_ID] or {}), "old ticks do not carry over to the new site list")
        check(steps ~= again, "steps were rebuilt")
        C_Map.GetMapInfo, U.PlayerPos, U.MapName = realInfo, realPos, realZone
        C_ResearchInfo = nil
    end
    Pr.guide, Pr.steps = nil, nil
end

-- ---- every guide walked through the engine in the fake world: set the skill to each target and confirm it advances
local walked = 0
local function shape() if flavor == "retail" then return "retail" elseif flavor == "mop" then return "mop" else return "era" end end
InstallProfessionAPI(shape())
local KEY = { Cooking = 185, Fishing = 356, ["First Aid"] = 129, Archaeology = 794 }
local function fire(evt) for _, h in ipairs(NS.wowHandlers[evt] or {}) do pcall(h, evt) end end
local sample = ids     -- every guide: they are short, so the whole file takes seconds
PLAYER = { map = PLAYER and PLAYER.map or 1429, x = 0.487, y = 0.42 } PLAYER.wx, PLAYER.wy, PLAYER.inst = z2w(PLAYER.x, PLAYER.y, PLAYER.map)
for _, id in ipairs(sample) do
    local g = G.registry[id]
    SPELLS_KNOWN, PROFS, TIERS = {}, { { name = g.prof, rank = g.skillMin, max = 900, key = KEY[g.prof] } }, {}
    OPEN_PROFESSION_WINDOW()
    if g.tier then TIERS[g.tier] = { rank = g.skillMin, max = 900 } end
    Prof.Invalidate()
    local ok, err = pcall(Pr.Load, id)
    check(ok, id .. " loads: " .. tostring(err))
    -- a make step must stay open for a character who already knows the recipe but has not reached the skill
    local guard = 0
    while ok and Pr.current and guard < 400 do
        guard = guard + 1
        local s = Pr.current
        local before = s
        if s.action == "M" and s.spell and s.skill and (s.skill.target > (PROFS[1].rank or 0)) and not s.checkedOpen then
            s.checkedOpen = true
            SPELLS_KNOWN[s.spell] = true
            Prof.Invalidate() Pr.Refresh()
            check(Pr.current == s, id .. " make step closed by knowing the recipe alone: " .. tostring(s.title))
        end
        if s.skill then
            PROFS[1].rank = s.skill.target
            if s.skill.tier then TIERS[s.skill.tier] = { rank = s.skill.target, max = 900 } end
        end
        if s.recipe then SPELLS_KNOWN[s.recipe] = true end
        Prof.Invalidate()
        fire("CHAT_MSG_SKILL")
        Pr.Refresh()
        if Pr.current == before and (s.skill or s.recipe) then
            -- the character now has the skill or the spell: this step can only be open if the engine or the tag is wrong
            fail(id .. " tagged step did not complete after its condition was met: " .. tostring(s.title))
            break
        end
        if Pr.current == before then
            -- manual steps (N, A/C/T quest gates, U, B, R) are what the player presses the arrow for
            local okSkip = pcall(Pr.Skip or Pr.Next or function() end)
            if Pr.current == before then
                if Pr.MarkDone then pcall(Pr.MarkDone, s) Pr.Refresh() end
            end
            if Pr.current == before then
                local done = Pr.MarkSets()   -- the guide's done set, by step key
                done[s.key] = true
                Pr.cursor = nil
                Pr.Refresh()
            end
            if Pr.current == before then fail(id .. " stuck on step: " .. tostring(s.title)) break end
        end
    end
    check(guard < 400, id .. " did not finish within 400 moves")
    walked = walked + 1
end

print(("ROW %-8s %7d %6d %6d %5d %6d %6d %6d %5d  %s"):format(flavor, guides, stepsTotal, makes, altPts, recipes, short, walked, failures, file))
if failures == 0 then print("FLAVOR OK") end
