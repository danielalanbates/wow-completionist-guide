-- CompletionRoute :: tools/cost_matrix.lua — step-to-step travel-seconds matrices for the offline route
-- optimizer (FINISH_PLAN W3, tools/optimize_routes.py).
--
-- Loads the REAL addon the way tools/vplayer.lua does (Core/Guide parser, Routing/TravelGraph with the
-- flavor's taxi network, transit, roads, access chains, Routing/Router) and, per quest guide, writes one JSON
-- line:  the parsed steps (action, quest id, PRE, level gate, anchor flag, point index) plus the matrix of
-- travel seconds between the guide's distinct step locations and from the start point (the guide zone's
-- centre, where vplayer starts a character).
--
-- Costs are exactly Router.TravelSeconds(a, b): walk-only below 700 yd, otherwise TravelGraph.FindPath
-- (taxi, boats/zeppelins/portals, roads, access chains) WITHOUT the hearth - the router never spends the
-- hearth on a pairwise leg because it is a one-shot resource with a cooldown.  The start column is
-- Router.TravelSecondsFromPlayer (which may use the hearth, as the live router does).
--
-- FindPath is a point-to-point Dijkstra (~6 ms on a modern continent), so a 250-point guide would need
-- 62,500 searches.  --fast (default) runs the SAME search once per source point (TravelGraph nodes, edges,
-- usability rules and walk costs read from the live graph) and reads every goal off it; --exact calls
-- Router.TravelSeconds for every pair.  Fast mode re-checks --verify N random pairs per guide against
-- Router.TravelSeconds and records the largest difference in the row (`verify_maxdiff`).
--
-- Usage: luajit tools/cost_matrix.lua <era|tbc|mop|retail|forever> [--out PATH] [--guide ID] [--guides-file F]
--                                     [--prefix wiki:,qdb:,qpoi:] [--sample K] [--limit N] [--exact] [--verify 200] [--list]
-- Output (default): /Users/daniel/.claude/jobs/ff3c728a/tmp/costmx/<flavor>.jsonl  (never the repo)
package.path = "./?.lua;" .. package.path

local flavor = arg[1] or "era"
local outPath, onlyGuide, guideSet, prefixes, sampleK, limit, exact, nverify = nil, nil, nil, nil, 1, math.huge, false, 200
local listOnly = false   -- --list: one {"id","n","sum"} row per quest guide, no matrices (finds unbaked/stale guides)
for i = 2, #arg do
    local a = arg[i]
    if a == "--out" then outPath = arg[i + 1]
    elseif a == "--guide" then onlyGuide = arg[i + 1]
    elseif a == "--guides-file" then guideSet = {} for l in io.lines(arg[i + 1]) do if l ~= "" then guideSet[l] = true end end
    elseif a == "--prefix" then prefixes = {} for p in arg[i + 1]:gmatch("[^,]+") do prefixes[#prefixes + 1] = p end
    elseif a == "--sample" then sampleK = tonumber(arg[i + 1])
    elseif a == "--limit" then limit = tonumber(arg[i + 1])
    elseif a == "--exact" then exact = true
    elseif a == "--list" then listOnly = true
    elseif a == "--verify" then nverify = tonumber(arg[i + 1]) end
end
prefixes = prefixes or { "wiki:", "qdb:", "qpoi:" }   -- the quest guides: wiki zone guides + the _gaps guides
outPath = outPath or ("/Users/daniel/.claude/jobs/ff3c728a/tmp/costmx/" .. flavor .. ".jsonl")

local TOC = { era = 11507, tbc = 20506, mop = 50504, retail = 120100, forever = 16001 }
local TAXI = { era = "Data/Taxi_era.lua", tbc = "Data/Taxi_tbc.lua", mop = "Data/Taxi_mop.lua", retail = "Data/Taxi_retail.lua",
               forever = "Data/Taxi_forever.lua" }
local EXTRA = { forever = "Data/MapFix_forever.lua" }

local LEVEL = 1
STUB_MAPS = dofile("tools/maps_" .. flavor .. ".lua")
local ADDON, NS = "CompletionRoute", {}
dofile("tools/stubs.lua")
function GetBuildInfo() return "x", "0", "2026", TOC[flavor] end
local FACTION = "Alliance"
function UnitFactionGroup() return FACTION end
function UnitLevel() return LEVEL end

PLAYER = { map = next(MAPS), x = 0.5, y = 0.5 }
local function place(map, x, y)
    if not map then return false end
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
    assert(loadfile("CompletionRoute/" .. path))(ADDON, NS)
end
for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", TAXI[flavor], EXTRA[flavor] or TAXI[flavor],
    "Data/Transit.lua", "Data/Imported_Entrances.lua", "Data/Access.lua", "Data/Inns.lua", "Data/ZoneAliases.lua",
    "Data/Roads_ek.lua", "Data/Roads_kalimdor.lua",
    "Routing/TravelGraph.lua", "Routing/Roads.lua", "Routing/StepOrder.lua", "Routing/Router.lua",
    "Core/Account.lua", "Core/Progress.lua", "Core/Instances.lua",
    ("Guides/Imported_Wiki_" .. flavor .. ".lua"), ("Guides/Imported_Quests_" .. flavor .. "_gaps.lua") }) do load(f) end
CompletionRouteDB, CompletionRouteCharDB = nil, nil
if flavor == "forever" and not NS.isForever then error("cost_matrix forever: Core/Init.lua did not detect Forever") end
for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", "CompletionRoute") end
NS.db.profile.debug = false
NS.Print, NS.Debug, NS.Error = function() end, function() end, function() end
NS.db.profile.routing.baked = false          -- matrices are built on the AUTHOR order, never on a baked one
-- The client now flies only into discovered flight paths (taxiPolicy "known", docs/ROUTING.md).  The bake keeps the
-- faction-wide rule it was built with until the cost-model rework (docs/IDEAS.md) decides otherwise; `settle` below
-- still implements the old "known" rule (both ends learned), so do not switch this without changing it too.
NS.db.profile.routing.taxiPolicy = "faction"
local G, R, U, TG = NS.Guide, NS.Router, NS.Util, NS.TravelGraph
local FL = NS.dataFlavor or NS.flavor

-- ---------------------------------------------------------------------------
-- One-to-many TravelGraph.FindPath (hearth off), same rules as the real search
-- ---------------------------------------------------------------------------
local sqrt, INF = math.sqrt, math.huge
local function cfg() return NS.db.profile.routing end
local function walkCost(ax, ay, bx, by, speed)
    local dx, dy = ax - bx, ay - by
    local d = sqrt(dx * dx + dy * dy)
    local tf = (U.CanFly and U.CanFly()) and 1.05 or (cfg().terrainFactor or 1.25)
    return d * tf / speed, d
end
local Heap = {} Heap.__index = Heap
local function newHeap() return setmetatable({ n = 0, a = {} }, Heap) end
function Heap:push(cost, item)
    self.n = self.n + 1
    local a, i = self.a, self.n
    a[i] = { cost, item }
    while i > 1 do local p = math.floor(i / 2) if a[p][1] <= a[i][1] then break end a[p], a[i] = a[i], a[p] i = p end
end
function Heap:pop()
    local a = self.a
    if self.n == 0 then return nil end
    local top = a[1]
    a[1] = a[self.n]; a[self.n] = nil; self.n = self.n - 1
    local i, n = 1, self.n
    while true do
        local l, r, s = 2 * i, 2 * i + 1, i
        if l <= n and a[l][1] < a[s][1] then s = l end
        if r <= n and a[r][1] < a[s][1] then s = r end
        if s == i then break end
        a[s], a[i] = a[i], a[s]; i = s
    end
    return top[1], top[2]
end

-- Dijkstra from (sx,sy,sinst) over the whole graph with no goal; returns the closed set with distances.
local function settle(sx, sy, sinst, speed)
    local c = cfg()
    local useTaxi, useTransit = (c.taxi ~= false), (c.transit ~= false)
    local roadFactor = c.roadFactor or 1.0
    local start = { id = "start", kind = "start", inst = sinst, wx = sx, wy = sy, edges = {} }
    local d, closed, order = {}, {}, {}
    local heap = newHeap()
    d[start] = 0 heap:push(0, start)
    local nodes = TG.nodes
    local iterations = 0
    while true do
        local du, u = heap:pop()
        if not u then break end
        if not closed[u] then
            closed[u] = true
            if u ~= start then order[#order + 1] = u end
            iterations = iterations + 1
            if iterations > 20000 then break end
            for _, e in ipairs(u.edges) do
                local v = e.to
                local ok = true
                if e.mode == "taxi" and (not useTaxi or not TG.TaxiUsable(u) or not TG.TaxiUsable(v)) then ok = false end
                if (v.kind == "transit") and not useTransit and e.mode ~= "hearth" then ok = false end
                if ok and not closed[v] then
                    local ecost = e.cost
                    if e.mode == "road" then ecost = e.data.dist * (e.data.factor or roadFactor) / speed end
                    if e.mode == "taxi" and c.preferTaxi then ecost = ecost * 0.6 end
                    local nd = du + ecost
                    if nd < (d[v] or INF) then d[v] = nd heap:push(nd, v) end
                end
            end
            local near = TG.RoadNear(u.inst, u.wx, u.wy)
            if near then
                for i = 1, #near do
                    local v = near[i]
                    if v ~= u and not closed[v] then
                        local nd = du + walkCost(u.wx, u.wy, v.wx, v.wy, speed)
                        if nd < (d[v] or INF) then d[v] = nd heap:push(nd, v) end
                    end
                end
            end
            local same = (TG.byInst and TG.byInst[u.inst]) or nodes
            for i = 1, #same do
                local v = same[i]
                if v.inst == u.inst and v ~= u and not v.road and not closed[v] then
                    local usable = (v.kind ~= "taxi") or (useTaxi and TG.TaxiUsable(v))
                    if v.kind == "transit" and not useTransit then usable = false end
                    if usable then
                        local nd = du + walkCost(u.wx, u.wy, v.wx, v.wy, speed)
                        if nd < (d[v] or INF) then d[v] = nd heap:push(nd, v) end
                    end
                end
            end
        end
    end
    -- group the settled graph nodes by instance: the goal is reached by walking from one of them
    local byInst = {}
    for _, u in ipairs(order) do
        local l = byInst[u.inst] if not l then l = {} byInst[u.inst] = l end
        l[#l + 1] = u
    end
    return d, byInst
end

local WALK_ONLY_BELOW = 700   -- Router.lua
-- travel seconds from point A to every point B (nil = no route), equal to Router.TravelSeconds
local function rowFast(a, pts, speed)
    local row = {}
    local tf = cfg().terrainFactor or 1.25
    local d, byInst
    for j, b in ipairs(pts) do
        local v
        if a.inst == b.inst then
            local dx, dy = a.wx - b.wx, a.wy - b.wy
            local dd = sqrt(dx * dx + dy * dy)
            if dd < WALK_ONLY_BELOW then v = dd * tf / speed end
        end
        if not v then
            -- FindPath: direct walk candidate, InstReachable short-cut, Dijkstra, keep the walk if <= search + 1
            local best
            if a.inst == b.inst then best = walkCost(a.wx, a.wy, b.wx, b.wy, speed) end
            if a.inst == b.inst and best and sqrt((a.wx - b.wx) ^ 2 + (a.wy - b.wy) ^ 2) < 300 then v = best
            elseif not TG.InstReachable(a.inst, b.inst) then v = best
            else
                if not d then d, byInst = settle(a.wx, a.wy, a.inst, speed) end
                local g = INF
                for _, u in ipairs(byInst[b.inst] or {}) do
                    local c = d[u] + walkCost(u.wx, u.wy, b.wx, b.wy, speed)
                    if c < g then g = c end
                end
                if g == INF then v = best
                elseif best and best <= g + 1 then v = best
                else v = g end
            end
        end
        row[j] = v
    end
    return row
end

local function ptStep(p) return { coords = { { x = 0.5, y = 0.5 } }, zone = p.zone, _wx = p.wx, _wy = p.wy, _winst = p.inst } end
local function rowExact(a, pts)
    local sa, row = ptStep(a), {}
    for j, b in ipairs(pts) do row[j] = R.TravelSeconds(sa, ptStep(b)) end
    return row
end

-- ---------------------------------------------------------------------------
-- Step metadata the optimizer needs
-- ---------------------------------------------------------------------------
local ACCEPT = { A = true, a = true, ["!"] = true }
local OBJ = { C = true, K = true, l = true, U = true }
local TURNIN = { T = true, t = true }
-- same checksum as tools/optimize_routes.py and Core/Guide.lua RouteOrder check (a guide regenerated since
-- the bake gets its author order back instead of a permutation of different steps)
local function checksum(steps)
    local c = 0
    for _, s in ipairs(steps) do
        c = (c * 31 + s.action:byte() + ((s.qid and s.qid[1]) or 0)) % 2147483647
    end
    return c
end
NS.RouteChecksum = NS.RouteChecksum or checksum

local function jnum(v) if v == nil then return "null" end if v == math.floor(v) then return tostring(v) end return ("%.1f"):format(v) end
local function jstr(s) return '"' .. tostring(s):gsub('[%c"\\]', function(ch) return ("\\u%04x"):format(ch:byte()) end) .. '"' end
local function jlist(t, f) local o = {} for i = 1, #t do o[i] = (f or jnum)(t[i]) end return "[" .. table.concat(o, ",") .. "]" end

-- ---------------------------------------------------------------------------
-- Run
-- ---------------------------------------------------------------------------
os.execute(("mkdir -p %q"):format(outPath:match("^(.*)/[^/]*$") or "."))
local out = assert(io.open(outPath, "w"))
local t0 = os.clock()
local n, seen = 0, 0
local maxDiffAll, verified = 0, 0
for _, id in ipairs(G.list) do
    if n >= limit then break end
    local g = G.registry[id]
    local okPrefix = false
    for _, p in ipairs(prefixes) do if id:sub(1, #p) == p then okPrefix = true end end
    if okPrefix and ((not onlyGuide) or id == onlyGuide) and ((not guideSet) or guideSet[id]) then
        seen = seen + 1
        if (seen - 1) % sampleK == 0 then
            local steps = G.Steps(id)
            if listOnly and steps and #steps > 0 and not g.empty then
                out:write(("{\"id\":%s,\"n\":%d,\"sum\":%d}\n"):format(jstr(id), #steps, checksum(steps)))
                n = n + 1
                g.steps = nil
            elseif steps and #steps > 0 and not g.empty then
                local tg0 = os.clock()
                FACTION = (g.faction == "Horde") and "Horde" or "Alliance"
                NS.player.faction = FACTION
                local lv = tonumber(g.minlevel) or 1
                for _, s in ipairs(steps) do if s.minlevel and s.minlevel > 0 and (not g.minlevel) then lv = math.min(lv, s.minlevel) end end
                LEVEL = math.max(1, lv)
                R.Invalidate()
                TG.Build()
                local speed = U.TravelSpeed()
                -- start where vplayer starts a character: the guide zone's centre
                local zone = g.zone
                if not zone then for _, s in ipairs(steps) do if s.zone then zone = s.zone break end end end
                local placed = zone and MAPS[zone] and place(zone, 0.5, 0.5) or false
                -- distinct step locations (only steps with their own coordinates count as located)
                local pts, key2pt, rows = {}, {}, {}
                for i, s in ipairs(steps) do
                    local pi = -1
                    if s.coords and s.zone then
                        local wx, wy, inst = R.StepWorld(s)
                        if wx then
                            local k = ("%d:%.1f:%.1f"):format(inst, wx, wy)
                            pi = key2pt[k]
                            if not pi then
                                pts[#pts + 1] = { wx = wx, wy = wy, inst = inst, zone = s.zone }
                                pi = #pts key2pt[k] = pi
                            end
                            pi = pi - 1   -- 0-based for the solver
                        end
                    end
                    local q = s.qid and s.qid[1] or 0
                    local kind = ACCEPT[s.action] and "A" or OBJ[s.action] and "C" or TURNIN[s.action] and "T" or "O"
                    local anchor = (not s.route) or s.sticky or false
                    rows[i] = ("[%s,%s,%d,%s,%d,%d,%d]"):format(jstr(s.action), jstr(kind), q, jlist(s.pre or {}),
                        s.minlevel or 0, pi, anchor and 1 or 0)
                end
                -- matrix
                local mrows = {}
                for i, a in ipairs(pts) do
                    local row = exact and rowExact(a, pts) or rowFast(a, pts, speed)
                    for j = 1, #pts do if row[j] == nil then row[j] = -1 end end
                    mrows[i] = jlist(row)
                end
                local startRow = {}
                for j, b in ipairs(pts) do
                    local v = placed and R.TravelSecondsFromPlayer(ptStep(b)) or nil
                    startRow[j] = v or -1
                end
                -- verify the fast matrix against the real router on random pairs
                local maxDiff, nv = 0, 0
                if not exact and #pts > 1 and nverify > 0 then
                    math.randomseed(#pts * 7919 + #steps)
                    local tries = math.min(nverify, #pts * #pts)
                    for _ = 1, tries do
                        local i, j = math.random(#pts), math.random(#pts)
                        local real = R.TravelSeconds(ptStep(pts[i]), ptStep(pts[j]))
                        local mine = rowFast(pts[i], { pts[j] }, speed)[1]
                        nv = nv + 1
                        local diff
                        if real == nil and mine == nil then diff = 0
                        elseif real == nil or mine == nil then diff = 1e9
                        else diff = math.abs(real - mine) end
                        if diff > maxDiff then maxDiff = diff end
                    end
                end
                if maxDiff > maxDiffAll then maxDiffAll = maxDiff end
                verified = verified + nv
                out:write(("{\"flavor\":%s,\"id\":%s,\"name\":%s,\"faction\":%s,\"minlevel\":%d,\"speed\":%s,\"n\":%d,\"sum\":%d,\"npts\":%d,\"placed\":%s,\"exact\":%s,\"verify_n\":%d,\"verify_maxdiff\":%s,\"secs\":%s,\"steps\":[%s],\"start\":%s,\"m\":[%s]}\n")
                    :format(jstr(FL), jstr(id), jstr(g.name or id), jstr(g.faction or "Both"), LEVEL, jnum(speed), #steps, checksum(steps), #pts,
                        placed and "true" or "false", exact and "true" or "false", nv, jnum(maxDiff), jnum(os.clock() - tg0),
                        table.concat(rows, ","), jlist(startRow), table.concat(mrows, ",")))
                n = n + 1
                if n % 25 == 0 then
                    out:flush()
                    io.stderr:write(("%d guides %.0fs (last %s, %d pts, %.1fs)\n"):format(n, os.clock() - t0, id, #pts, os.clock() - tg0))
                end
                g.steps = nil   -- free the parse
            end
        end
    end
end
out:close()
io.stderr:write(("DONE cost_matrix %s: %d guides in %.0fs -> %s | verified %d pairs, max |fast-real| = %.3f s\n")
    :format(FL, n, os.clock() - t0, outPath, verified, maxDiffAll))
