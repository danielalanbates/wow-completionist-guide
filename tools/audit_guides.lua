-- Offline audit of every registered guide, by TYPE: which categories actually work and which need
-- creative handling.  luajit tools/audit_guides.lua [flavor]   (flavor picks the baked quest DB files)
-- Writes docs/audit_guides.csv (type, guides, steps, located, unlocated, pct) for the SQL chart.
package.path = "./?.lua;" .. package.path
local ADDON, NS = "CompletionRoute", {}
local flavor = (... or "tbc")
local TOC = { era = 11507, tbc = 20506, mop = 50504, retail = 120100 }
local TAXI = { era = "Data/Taxi_era.lua", tbc = "Data/Taxi_tbc.lua", mop = "Data/Taxi_mop.lua", retail = "Data/Taxi_retail.lua" }
STUB_MAPS = dofile("tools/maps_" .. flavor .. ".lua")
dofile("tools/stubs.lua")
function GetBuildInfo() return "x", "0", "2026", TOC[flavor] end
local z2w = z2w
PLAYER = { map = 1429, x = 0.487, y = 0.42 } PLAYER.wx, PLAYER.wy, PLAYER.inst = z2w(PLAYER.x, PLAYER.y, PLAYER.map)

local function load(path)
    local f = io.open("CompletionRoute/" .. path, "r")
    if not f then return end
    f:close()
    local fn = assert(loadfile("CompletionRoute/" .. path)) fn(ADDON, NS)
end
for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", TAXI[flavor],
    "Data/Transit.lua", "Data/Access.lua", "Data/Inns.lua", "Data/ZoneAliases.lua", "Data/Roads_ek.lua",
    "Data/Roads_kalimdor.lua", "Routing/TravelGraph.lua", "Routing/Roads.lua", "Routing/StepOrder.lua",
    "Routing/Router.lua", "Routing/Loop.lua", "Core/Account.lua", "Core/Progress.lua", "Core/Farm.lua",
    "Data/Farm_routes.lua", "Core/Instances.lua", "Adapters/Zygor.lua", "Adapters/WoWPro.lua",
    "Guides/Imported_Zygor.lua", "Guides/Imported_WoWPro.lua",
    "Guides/Imported_Quests_era.lua", "Guides/Imported_Quests_tbc.lua", "Guides/Imported_Quests_wotlk.lua",
    "Guides/Imported_Quests_cata.lua", "Guides/Imported_Quests_mop.lua" }) do load(f) end
CompletionRouteDB, CompletionRouteCharDB = nil, nil
for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", "CompletionRoute") end
pcall(NS.Adapters.Zygor.ImportStatic)
pcall(NS.Adapters.WoWPro.ImportStatic)
pcall(NS.Farm.RegisterSeeds)

local G = NS.Guide
local byType = {}
local actionByType = {}
for _, id in ipairs(G.list) do
    local g = G.registry[id]
    local t = g.type or "?"
    local row = byType[t] or { guides = 0, steps = 0, located = 0, unlocated = 0, noCoordGuides = 0, sample = id }
    byType[t] = row
    actionByType[t] = actionByType[t] or {}
    row.guides = row.guides + 1
    local ok, steps = pcall(G.Steps, id)
    if ok and steps then
        local loc = 0
        for _, s in ipairs(steps) do
            row.steps = row.steps + 1
            actionByType[t][s.action] = (actionByType[t][s.action] or 0) + 1
            if s.coords or s.zone then row.located = row.located + 1 loc = loc + 1
            else row.unlocated = row.unlocated + 1 end
        end
        if loc == 0 and #steps > 0 then row.noCoordGuides = row.noCoordGuides + 1 end
    end
end

local rows = {}
for t, r in pairs(byType) do rows[#rows + 1] = { t = t, r = r } end
table.sort(rows, function(a, b) return a.r.guides > b.r.guides end)
print(("%-14s %7s %9s %9s %9s %6s  %s"):format("TYPE", "GUIDES", "STEPS", "LOCATED", "NO-COORD", "PCT", "TOP ACTIONS"))
local csv = { "type,guides,steps,located,unlocated,nocoord_guides,pct_located" }
for _, e in ipairs(rows) do
    local r = e.r
    local pct = r.steps > 0 and (r.located / r.steps * 100) or 0
    local acts = {}
    for a, n in pairs(actionByType[e.t]) do acts[#acts + 1] = { a = a, n = n } end
    table.sort(acts, function(x, y) return x.n > y.n end)
    local top = {}
    for i = 1, math.min(4, #acts) do top[#top + 1] = ("%s:%d"):format(acts[i].a, acts[i].n) end
    print(("%-14s %7d %9d %9d %9d %5.1f%%  %s"):format(e.t, r.guides, r.steps, r.located, r.unlocated, pct, table.concat(top, " ")))
    csv[#csv + 1] = ("%s,%d,%d,%d,%d,%d,%.1f"):format(e.t, r.guides, r.steps, r.located, r.unlocated, r.noCoordGuides, pct)
end
-- ---- gold guides: how many fold into a walkable circuit? ----
local gold = { total = 0, folded = 0, authored = 0, stops = 0, yards = 0, measured = 0, fail = {} }
for _, id in ipairs(G.list) do
    local g = G.registry[id]
    if g.type == "Gold" and not g.loop then
        gold.total = gold.total + 1
        local ok, res, n, len = pcall(NS.Farm.Circuitize, g)
        if ok and res then
            gold.folded = gold.folded + 1 gold.stops = gold.stops + n
            if len then gold.yards = gold.yards + len gold.measured = gold.measured + 1
            else gold.authored = gold.authored + 1 end
        else
            local why = tostring((ok and n) or res)
            why = why:gsub("only %d+", "only N"):gsub("%d+", "N")
            gold.fail[why] = (gold.fail[why] or 0) + 1
            gold.examples = gold.examples or {}
            if #gold.examples < 8 then gold.examples[#gold.examples + 1] = ("%s  [%s]"):format(g.name or g.id, why) end
        end
    end
end
print("")
print(("GOLD GUIDES: %d imported, %d are circuits (%.0f%%) - %d already authored as rings, %d solved here; avg %.1f stops, solved rings avg %.0f yd"):format(
    gold.total, gold.folded, gold.total > 0 and gold.folded / gold.total * 100 or 0, gold.authored, gold.measured,
    gold.folded > 0 and gold.stops / gold.folded or 0, gold.measured > 0 and gold.yards / gold.measured or 0))
for why, n in pairs(gold.fail) do print(("  not folded (%d): %s"):format(n, why)) end
for _, e in ipairs(gold.examples or {}) do print("    e.g. " .. e) end
local gf = io.open("docs/audit_gold_" .. flavor .. ".csv", "w")
if gf then
    gf:write("metric,value\n")
    gf:write(("imported_gold_guides,%d\nfolded_to_circuit,%d\nauthored_rings,%d\nsolved_rings,%d\navg_stops,%.1f\navg_yards_solved,%.0f\n"):format(
        gold.total, gold.folded, gold.authored, gold.measured,
        gold.folded > 0 and gold.stops / gold.folded or 0, gold.measured > 0 and gold.yards / gold.measured or 0))
    for why, n in pairs(gold.fail) do gf:write(("not_folded:%s,%d\n"):format(why:gsub(",", ";"), n)) end
    gf:close()
end

local out = io.open("docs/audit_guides_" .. flavor .. ".csv", "w")
if out then out:write(table.concat(csv, "\n") .. "\n") out:close() print("wrote docs/audit_guides_" .. flavor .. ".csv") end
