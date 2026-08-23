-- Route EVERY guide in EVERY zone offline, with real zone bounds, and check that
--   (1) the steps get locations, (2) the optimizer's order respects quest precedence (A < C < T, PRE before A),
--   (3) the optimized order is never slower than the author's order, (4) a route exists from the zone to step 1.
-- Usage:  luajit tools/route_sweep.lua <era|tbc|mop|retail> [--limit N] [--out docs/route_sweep_<flavor>.tsv]
-- Then:   python3 tools/collect_route_sweep.py   (folds the TSVs into docs/verification.sqlite, table route_sweep)
package.path = "./?.lua;" .. package.path
local flavor = arg[1] or "era"
local limit, outPath = math.huge, nil
for i = 2, #arg do
    if arg[i] == "--limit" then limit = tonumber(arg[i + 1]) end
    if arg[i] == "--out" then outPath = arg[i + 1] end
    if arg[i] == "--from" then FROM_MAP = tonumber(arg[i + 1]) end        -- route every guide from this uiMapID (e.g. 85 Orgrimmar) instead of the guide's own zone
    if arg[i] == "--faction" then FORCE_FACTION = arg[i + 1] end         -- Horde|Alliance: skip guides of the other faction
end
outPath = outPath or ("docs/route_sweep_" .. flavor .. ".tsv")
local TOC = { era = 11507, tbc = 20506, mop = 50504, retail = 120100 }
local TAXI = { era = "Data/Taxi_era.lua", tbc = "Data/Taxi_tbc.lua", mop = "Data/Taxi_mop.lua", retail = "Data/Taxi_retail.lua" }

STUB_MAPS = dofile("tools/maps_" .. flavor .. ".lua")
local ADDON, NS = "CompletionRoute", {}
dofile("tools/stubs.lua")
function GetBuildInfo() return "x", "0", "2026", TOC[flavor] end
FACTION, LEVEL = "Alliance", 10
function UnitFactionGroup() return FACTION end
function UnitLevel() return LEVEL end
PLAYER = { map = 1429, x = 0.5, y = 0.5 }
local function place(map, x, y)
    local wx, wy, inst = z2w(x, y, map)
    if not wx then return false end
    PLAYER.map, PLAYER.x, PLAYER.y, PLAYER.wx, PLAYER.wy, PLAYER.inst = map, x, y, wx, wy, inst
    return true
end
place(next(MAPS), 0.5, 0.5)

local function load(path)
    local f = io.open("CompletionRoute/" .. path, "r")
    if not f then io.stderr:write("skip " .. path .. "\n") return end
    f:close()
    local fn = assert(loadfile("CompletionRoute/" .. path)) fn(ADDON, NS)
end
for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", TAXI[flavor], "Data/Transit.lua", "Data/Access.lua", "Data/Inns.lua", "Data/ZoneAliases.lua",
    "Data/Roads_ek.lua", "Data/Roads_kalimdor.lua", "Routing/TravelGraph.lua", "Routing/Roads.lua", "Routing/StepOrder.lua", "Routing/Router.lua", "Routing/Loop.lua",
    "Core/Account.lua", "Core/Progress.lua", "Core/Farm.lua", "Core/Instances.lua", "Data/Farm_routes.lua", "Adapters/Zygor.lua", "Adapters/WoWPro.lua",
    "Guides/Imported_Zygor.lua", "Guides/Imported_WoWPro.lua",
    "Guides/Imported_Quests_era.lua", "Guides/Imported_Quests_tbc.lua", "Guides/Imported_Quests_wotlk.lua", "Guides/Imported_Quests_cata.lua", "Guides/Imported_Quests_mop.lua" }) do load(f) end
CompletionRouteDB, CompletionRouteCharDB = nil, nil
for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", "CompletionRoute") end
NS.db.profile.debug = false
NS.Print = function() end   -- silence chat
pcall(NS.Adapters.Zygor.ImportStatic)   -- baked third-party guides register lazily at PLAYER_READY in the client
pcall(NS.Adapters.WoWPro.ImportStatic)
NS.TravelGraph.Build()
io.stderr:write(("flavor=%s maps=%d graph nodes=%d roads=%d guides=%d\n"):format(NS.flavor, (function() local n = 0 for _ in pairs(MAPS) do n = n + 1 end return n end)(), #NS.TravelGraph.nodes, NS.TravelGraph.roadCount or 0, #NS.Guide.list))

local G, P, R, U = NS.Guide, NS.Progress, NS.Router, NS.Util
local window = NS.db.profile.routing.window or 10

local function qkey(s) return s.qid and s.qid[1] end
-- does `order` respect quest precedence?  returns ok, reason
local function precedenceOK(order)
    local pos, firstA, lastC = {}, {}, {}
    for i, s in ipairs(order) do pos[s] = i end
    for i, s in ipairs(order) do
        local q = qkey(s)
        if q then
            local a = s.action
            if (a == "A" or a == "a" or a == "!") and not firstA[q] then firstA[q] = i end
            if a == "C" or a == "K" or a == "l" or a == "U" then lastC[q] = i end
        end
    end
    for i, s in ipairs(order) do
        local q = qkey(s)
        if q then
            local a = s.action
            if (a == "C" or a == "K" or a == "l" or a == "U" or a == "T" or a == "t") and firstA[q] and firstA[q] > i and s.index > order[firstA[q]].index then
                return false, ("%s of %d before its accept"):format(a, q)
            end
            if (a == "T" or a == "t") and lastC[q] and lastC[q] > i and s.index > order[lastC[q]].index then
                return false, ("turn-in of %d before its complete"):format(q)
            end
            if (a == "A" or a == "a") and s.pre then
                for _, pq in ipairs(s.pre) do
                    for j, s2 in ipairs(order) do
                        if j > i and (s2.action == "T" or s2.action == "t") and qkey(s2) == pq and s2.index < s.index then
                            return false, ("accept of %d before PRE %d turn-in"):format(q, pq)
                        end
                    end
                end
            end
        end
    end
    return true
end
local function chainCost(list)
    local t, prev = 0, nil
    for _, s in ipairs(list) do
        local c = prev and R.TravelSeconds(prev, s) or R.TravelSecondsFromPlayer(s)
        t = t + (c or 600)
        prev = s
    end
    return t
end

local out = assert(io.open(outPath, "w"))
out:write("flavor\tguide\tname\ttype\tfaction\tzone\tzone_name\tsteps\tlocated\tunknown_zone\twindow\torder_ok\torder_reason\topt_cost\tauthor_cost\troute_ok\troute\terror\n")
local n, fails, slower, noRoute, prec = 0, 0, 0, 0, 0
local unknown = {}   -- zone id/name -> step count, for zones this flavor cannot resolve
local t0 = os.clock()
for _, id in ipairs(G.list) do
    if n >= limit then break end
    local g = G.registry[id]
    local steps = G.Steps(id)
    if steps and #steps > 0 and not g.empty and not (FORCE_FACTION and g.faction and g.faction ~= FORCE_FACTION) then
        n = n + 1
        FACTION = (g.faction == "Horde") and "Horde" or "Alliance"
        NS.player.faction = FACTION
        LEVEL = math.max(1, tonumber(g.minlevel) or 1)
        NS.db.char.done, NS.db.char.skipped, NS.db.char.guide = {}, {}, nil
        -- place the player at the centre of the guide's zone (first located step's zone if the guide has none)
        local zone = g.zone
        if not zone then for _, s in ipairs(steps) do if s.zone then zone = s.zone break end end end
        if FROM_MAP then zone = FROM_MAP end
        local placed = zone and place(zone, 0.5, 0.5)
        local located, unknownZone = 0, 0
        for _, s in ipairs(steps) do
            s._wx, s._winst, s._zwx = nil, nil, nil
            if s.zone and not MAPS[s.zone] then unknownZone = unknownZone + 1 local k = tostring(s.zone) .. " " .. tostring(s.zoneName) unknown[k] = (unknown[k] or 0) + 1
            elseif not s.zone then local k = "(none) " .. tostring(s.zoneName) unknown[k] = (unknown[k] or 0) + 1 end
            if R.StepWorld(s) then located = located + 1 end
        end
        local err, orderOK, reason, optCost, authorCost, routeOK, routeTxt = nil, true, "", -1, -1, "", ""
        NS.Router.Invalidate()
        NS.TravelGraph.Build()   -- faction-specific taxi nodes
        local ok, e = pcall(P.Load, id)
        if not ok then err = tostring(e) else
            local order = P.order or {}
            orderOK, reason = precedenceOK(order)
            reason = reason or ""
            -- compare the optimized head window with the same steps in author order (the optimizer only looks `window` ahead)
            local author = P.Pending(#order)
            local head, ahead = {}, {}
            for k = 1, math.min(window, #order) do head[k] = order[k] ahead[k] = author[k] end
            local ok2, a, b = pcall(function() return chainCost(head), chainCost(ahead) end)
            if ok2 then optCost, authorCost = a, b else err = "cost: " .. tostring(a) end
            local tx, ty, ti
            if order[1] then tx, ty, ti = R.StepWorld(order[1]) end   -- (`a and f()` would truncate to one value)
            if placed and tx then
                -- route from the placed player straight to step 1 (Progress.current can be a location-less step,
                -- and a FindPath error must show up as an error, not as "no route")
                local okP, path = pcall(NS.TravelGraph.FindPath, PLAYER.wx, PLAYER.wy, PLAYER.inst, tx, ty, ti, {})
                if not okP then err = (err and err .. "; " or "") .. "FindPath: " .. tostring(path) path = nil end
                local z = order[1].zone and MAPS[tonumber(order[1].zone) or -1]
                local instanceMap = z and (z[8] == 4 or z[8] == 5 or z[8] == 6)
                routeOK = path and "yes" or (instanceMap and "no-instance" or "no")
                routeTxt = path and NS.TravelGraph.Describe(path) or ("step1 inst=" .. tostring(ti) .. " player inst=" .. tostring(PLAYER.inst))
            else routeOK = placed and "n/a" or "unplaced" end
        end
        if err then fails = fails + 1 end
        if not orderOK then prec = prec + 1 end
        if optCost > authorCost + 1 then slower = slower + 1 end
        if routeOK == "no" then noRoute = noRoute + 1 end
        local zname = zone and MAPS[zone] and MAPS[zone][1] or ""
        out:write(table.concat({ NS.flavor, id, (g.name or ""):gsub("\t", " "), g.type or "", g.faction or "Both", tostring(zone or ""), zname, #steps, located, unknownZone,
            #(P.order or {}), orderOK and 1 or 0, reason, ("%.0f"):format(optCost), ("%.0f"):format(authorCost), routeOK, (routeTxt:gsub("\t", " ")), ((err or ""):gsub("\t", " ")) }, "\t") .. "\n")
        if n % 200 == 0 then io.stderr:write(("%d guides  %.0fs  load-fail=%d precedence=%d slower=%d no-route=%d\n"):format(n, os.clock() - t0, fails, prec, slower, noRoute)) end
    end
end
out:close()
local uf = assert(io.open(outPath:gsub("%.tsv$", "") .. "_unknown.tsv", "w"))
local keys = {} for k in pairs(unknown) do keys[#keys + 1] = k end
table.sort(keys, function(a, b) return unknown[a] > unknown[b] end)
uf:write("zone\tsteps\n") for _, k in ipairs(keys) do uf:write(k .. "\t" .. unknown[k] .. "\n") end uf:close()
local st = NS.TravelGraph.stats if st then io.stderr:write(("router: %d FindPath calls, %d pops, %d walk-relaxations, %d capped, %d skipped-unreachable\n"):format(st.calls, st.pops, st.relax, st.capped, st.skipped or 0)) end
io.stderr:write(("DONE %s: %d guides in %.0fs -> %s | load-fail=%d precedence-violations=%d optimizer-slower=%d no-route=%d\n"):format(flavor, n, os.clock() - t0, outPath, fails, prec, slower, noRoute))
