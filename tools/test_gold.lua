-- CompletionRoute :: tools/test_gold.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- Offline invariants of the generated gold guides (tools/wiki/gen_gold.py -> Guides/Imported_Gold_<flavor>.lua):
--   every guide parses and every step line parses; every point is on a map the client knows with coordinates in 0-100;
--   circuits have enough waypoints and the ring closes; no text claims a price or a rate; level and goldKind are set;
--   names are unique; faction-specific guides name the right faction and only point at that faction's cities;
--   every level band on every client has a gold guide for both factions, and Recommend.ForLevel returns gold guides
--   at every level from 1 to the cap; WoW Forever's routes carry forever=true (they are written on Forever's own maps).
--   Generated files are gitignored: a fresh clone SKIPS.
-- Run: luajit tools/test_gold.lua   (from repo root; loads every flavor's guide file, run through the heavy lock)
package.path = "./?.lua;" .. package.path
local TOC = { era = 11508, tbc = 20506, mop = 50504, retail = 121500, forever = 16001 }
local RUNS = { forever = "era" }
local CAP = { era = 60, tbc = 70, mop = 90, retail = 90, forever = 60 }
local KINDS = { Gathering = true, ["Mob Farming"] = true, Fishing = true, ["Daily Gold"] = true, Methods = true, Instances = true }
local fail = 0
local function check(ok, msg) if not ok then print("FAIL " .. msg) fail = fail + 1 end end

local function harness(flavor, faction)
    local ADDON, NS = "CompletionRoute", {}
    STUB_MAPS = dofile("tools/maps_" .. flavor .. ".lua")
    dofile("tools/stubs.lua")
    GetBuildInfo = function() return "x", "0", "2026", TOC[flavor] end
    UnitFactionGroup = function() return faction end
    GetMaxPlayerLevel, GetMaxLevelForPlayerExpansion = nil, nil
    local function load(path) assert(loadfile("CompletionRoute/" .. path))(ADDON, NS) end
    for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", "Data/ZoneAliases.lua",
        "Core/Professions.lua", "Core/Recommend.lua" }) do load(f) end
    NS.Print, NS.Debug = function() end, function() end
    load("Guides/Imported_Gold_" .. flavor .. ".lua")
    CompletionRouteDB, CompletionRouteCharDB = nil, nil
    for _, h in ipairs(NS.wowHandlers and NS.wowHandlers.ADDON_LOADED or {}) do h("ADDON_LOADED", "CompletionRoute") end
    if InstallProfessionAPI then InstallProfessionAPI("none") end
    return NS
end

-- a coarse check: amounts of money, a rate, or a market claim anywhere in a guide's text
local MONEY = { "%d+%s*gold", "%d+%s*silver", "%d+%s*copper", "%d+%s*g[^%a%d]", "gold per hour", "gold/h", "g/hr", "per hour", "gph",
    "profit of", "guaranteed profit", "worth %d", "sells for %d" }
local function claimsMoney(s)
    local low = " " .. s:lower() .. " "
    for _, p in ipairs(MONEY) do if low:find(p) then return p end end
    return nil
end

local HOSTILE = { Alliance = { "Orgrimmar", "Thunder Bluff", "Undercity", "Silvermoon" }, Horde = { "Stormwind", "Ironforge", "Darnassus", "Exodar" } }
local function yd(MAPS, m, ax, ay, bx, by)
    local d = MAPS[m]
    if not d or not d[5] then return 0 end
    return math.sqrt(((ax - bx) * d[5]) ^ 2 + ((ay - by) * d[6]) ^ 2)
end

local function checkGuides(flavor, NS, MAPS)
    local G = NS.Guide
    local stats = { guides = 0, steps = 0, kinds = {}, circuits = 0, wpMin = 1e9, wpMax = 0, hopMax = 0, hopMaxFrac = 0, located = 0 }
    local names, nameDup = {}, 0
    for _, id in ipairs(G.list) do
        local g = G.registry[id]
        if id:find("^gold:") and g then
            stats.guides = stats.guides + 1
            local who = flavor .. ":" .. id
            local kind = g.goldKind
            check(KINDS[kind], who .. " goldKind " .. tostring(kind))
            check(g.folder == kind, who .. " folder/goldKind mismatch")
            -- WoW Forever's gold routes are placed on Forever's own maps: without forever=true the add-on would move a
            -- point on a reshaped map (Data/MapFix_forever.lua: Mulgore, Eastern Plaguelands, Redridge, Stormwind) again
            if flavor == "forever" then check(g.forever == true, who .. " not marked Forever-native (forever=true)") end
            check(g.type == "Gold", who .. " type " .. tostring(g.type))
            check(g.minlevel and g.maxlevel and g.minlevel >= 1 and g.minlevel <= g.maxlevel and g.maxlevel <= CAP[flavor],
                ("%s level band %s-%s"):format(who, tostring(g.minlevel), tostring(g.maxlevel)))
            stats.kinds[kind] = (stats.kinds[kind] or 0) + 1
            if names[g.name] then nameDup = nameDup + 1 check(false, who .. " duplicate name: " .. g.name) end
            names[g.name] = true
            check(not claimsMoney(g.name), who .. " name claims money: " .. g.name)
            if g.faction then
                check(g.faction == "Alliance" or g.faction == "Horde", who .. " bad faction " .. g.faction)
                local opp = g.faction == "Alliance" and "%(Horde%)" or "%(Alliance%)"
                check(not g.name:find(opp), who .. " faction/name mismatch: " .. g.name)
            end
            if g.name:find("%(Alliance%)") then check(g.faction == "Alliance", who .. " name says Alliance, field " .. tostring(g.faction)) end
            if g.name:find("%(Horde%)") then check(g.faction == "Horde", who .. " name says Horde, field " .. tostring(g.faction)) end
            if g.requires then
                local prof, need = NS.Professions.ParseSpec(g.requires)
                check(prof and need and need >= 1, who .. " bad requires " .. g.requires)
            end
            if kind == "Gathering" then
                check(g.requires and g.loop and g.farm and g.farm.coarse, who .. " gathering fields")
                check(g.name:find("(coarse)", 1, true), who .. " gathering guide not labelled coarse")
                check(g.requires:match("^(%a+);") == g.farm.kind, who .. " requires/kind mismatch")
            end
            if not g.loop then check(g.noCircuit, who .. " non-circuit guide would be folded into a circuit") end
            -- parse every line
            local lines = 0
            local steps = {}
            for ln in g.text:gmatch("[^\n]+") do
                lines = lines + 1
                local st, err = G.ParseLine(ln, lines)
                if not st then check(false, who .. " unparsable: " .. ln .. " (" .. tostring(err) .. ")")
                else
                    steps[#steps + 1] = st
                    check(not claimsMoney(ln), who .. " claims money/rate: " .. ln)
                    if st.coords then
                        for _, c in ipairs(st.coords) do
                            check(c.x > 0 and c.x < 1 and c.y > 0 and c.y < 1, who .. " coords out of range: " .. ln)
                        end
                    end
                    if st.zone then
                        check(MAPS[st.zone], who .. " unknown map: " .. ln)
                        if st.coords then stats.located = stats.located + 1 end
                    end
                    if st.alts then
                        for _, a in ipairs(st.alts) do
                            check(MAPS[a.map], who .. " unknown ALT map: " .. a.map)
                            check(a.x > 0 and a.x < 1 and a.y > 0 and a.y < 1, who .. " ALT out of range: " .. ln)
                            if g.faction then
                                for _, city in ipairs(HOSTILE[g.faction]) do
                                    check(not (a.name or ""):find(city, 1, true), who .. " sends " .. g.faction .. " to " .. city)
                                end
                            end
                        end
                    end
                end
            end
            stats.steps = stats.steps + #steps
            if g.loop then
                stats.circuits = stats.circuits + 1
                check(#steps >= 6, who .. " circuit has only " .. #steps .. " waypoints")
                stats.wpMin = math.min(stats.wpMin, #steps)
                stats.wpMax = math.max(stats.wpMax, #steps)
                check(g.farm and g.farm.nodes == #steps, who .. " farm.nodes disagrees with the waypoints")
                -- the ring closes: all waypoints on one map, and no leg (the closing one included) is a jump across the world
                local perim, longest = 0, 0
                local map0 = steps[1].zone
                for i, st in ipairs(steps) do
                    check(st.action == "G" and st.coords and st.zone == map0, who .. " waypoint is not a located G step on the ring's map")
                    local nx = steps[i % #steps + 1]
                    if st.coords and nx.coords then
                        local d = yd(MAPS, map0, st.coords[1].x, st.coords[1].y, nx.coords[1].x, nx.coords[1].y)
                        perim = perim + d
                        longest = math.max(longest, d)
                    end
                end
                local frac = longest / perim
                stats.hopMax = math.max(stats.hopMax, longest)
                stats.hopMaxFrac = math.max(stats.hopMaxFrac, frac)
                check(frac <= 0.55, ("%s longest leg is %.0f%% of the whole ring (%.0f of %.0f yd)"):format(who, frac * 100, longest, perim))
            end
        end
    end
    check(stats.guides > 0, flavor .. ": no gold guides registered")
    check(nameDup == 0, flavor .. ": duplicate guide names")
    return stats
end

local function checkCoverage(flavor, NS, faction)
    local R, G = NS.Recommend, NS.Guide
    local cap = R.LevelCap()
    check(cap == CAP[flavor], ("%s: LevelCap %s, expected %s"):format(flavor, tostring(cap), CAP[flavor]))
    local missing, minCount = 0, 1e9
    for level = 1, cap do
        local list = R.ForLevel(level, { category = "Gold", fitOnly = true })
        local n = 0
        for _, e in ipairs(list) do if e.g.id:find("^gold:") then n = n + 1 end end
        if n == 0 then missing = missing + 1 print(("FAIL %s/%s: Recommend.ForLevel has no gold guide at level %d"):format(flavor, faction, level)) end
        minCount = math.min(minCount, n)
    end
    check(missing == 0, ("%s/%s: %d levels without a gold guide"):format(flavor, faction, missing))
    local bands = R.Bands()
    local empty = {}
    for _, b in ipairs(bands) do
        local found = false
        for _, id in ipairs(G.list) do
            local g = G.registry[id]
            if id:find("^gold:") and g and (not g.faction or g.faction == faction) and g.minlevel <= b.max and g.maxlevel >= b.min then found = true break end
        end
        if not found then empty[#empty + 1] = b.label end
    end
    check(#empty == 0, ("%s/%s: empty bands: %s"):format(flavor, faction, table.concat(empty, ",")))
    return minCount
end

print(("%-7s %6s %5s  %-44s %4s %5s %5s %5s"):format("flavor", "guides", "steps", "kinds", "circ", "wpMin", "wpMax", "fbmin"))
local ran = 0
for _, flavor in ipairs({ "era", "tbc", "mop", "retail", "forever" }) do
    local path = "CompletionRoute/Guides/Imported_Gold_" .. flavor .. ".lua"
    local fh = io.open(path, "r")
    if not fh then
        print("skip " .. path .. " (generated locally, gitignored: tools/wiki/gen_gold.py)")
    else
        local whole = fh:read("*a") fh:close()
        check(whole:find("CC BY%-SA 4%.0") and whole:find("warcraft%.wiki%.gg"), flavor .. ": attribution header missing")
        local guard = flavor == "forever" and 'if not NS.isForever then return end' or ('if NS.flavor ~= "%s" or NS.isForever then return end'):format(flavor)
        check(whole:find(guard, 1, true), flavor .. ": flavor guard missing")
        for _, bad in ipairs({ "Questie", "WoW%-Pro", "WoWPro" }) do
            check(not whole:find(bad), flavor .. ": gold guide file mentions " .. bad)
        end
        whole = nil
        collectgarbage()
        ran = ran + 1
        local NS = harness(flavor, "Alliance")
        check(NS.flavor == (RUNS[flavor] or flavor) and (NS.isForever and true or false) == (flavor == "forever"), flavor .. ": flavor detection")
        local stats = checkGuides(flavor, NS, MAPS)
        local fa = checkCoverage(flavor, NS, "Alliance")
        local NSh = harness(flavor, "Horde")
        local fb = checkCoverage(flavor, NSh, "Horde")
        local kinds = {}
        for _, k in ipairs({ "Gathering", "Mob Farming", "Fishing", "Daily Gold", "Methods", "Instances" }) do
            kinds[#kinds + 1] = k:sub(1, 1) .. (k:find(" ") and k:sub(k:find(" ") + 1, k:find(" ") + 1) or "") .. "=" .. (stats.kinds[k] or 0)
        end
        print(("%-7s %6d %5d  %-44s %4d %5d %5d %5d"):format(flavor, stats.guides, stats.steps, table.concat(kinds, " "), stats.circuits,
            stats.circuits > 0 and stats.wpMin or 0, stats.wpMax, math.min(fa, fb)))
        print(("        longest single leg %.0f yd, largest share of a ring %.0f%%"):format(stats.hopMax, stats.hopMaxFrac * 100))
        NS, NSh = nil, nil
        collectgarbage()
    end
end
if ran == 0 then print("no gold guide files; nothing checked") end
if fail > 0 then
    print(("GOLD GUIDE TESTS FAILED: %d"):format(fail))
    os.exit(1)
end
print("ALL GOLD GUIDE TESTS PASSED (" .. ran .. " flavors)")
