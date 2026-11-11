-- CompletionRoute :: tools/cost_matrix.lua — step-to-step travel-seconds matrices for the offline route
-- optimizer (FINISH_PLAN W3, tools/optimize_routes.py).
--
-- Loads the REAL addon the way tools/vplayer.lua does (Core/Guide parser, Routing/TravelGraph with the
-- flavor's taxi network, transit, roads, access chains, Routing/Router) and, per quest guide, writes one JSON
-- line: the parsed steps (action, quest id, PRE, level gate, point index, anchor flag, the checksum parts, the cost
-- model's kind) plus the matrix of travel seconds between the guide's priced points and from the start point (the
-- guide zone's centre, where vplayer starts a character).
--
-- Everything that decides a cost comes from the cost model (CompletionRoute/Routing/CostModel.lua, docs/ROUTING.md
-- "One cost model"), installed through tools/cm_offline.lua exactly as tools/vplayer.lua installs it:
--   * which steps are priced and where (own |M|, an NPC's point, a new zone's centre, for a step the planning character
--     walks to - the character most of the guide's located steps are written for (CostModel.Persona: faction, class,
--     race, profession), not a step that ticks by itself; the rest ride along: CostModel.PlanSteps);
--   * a point is keyed by place AND level key: a leg is priced at the speed (and, taxi "band", the flight paths) of the
--     planning level of the step it leaves from;
--   * no hearth and no teleports; the offline flight-path rule (--taxi, default CostModel.OFFLINE_TAXI);
--   * the constants the optimizer needs (no-route cost, version) are written into every row as "cm".
-- Costs are Router.TravelRow (one TravelGraph.FindPaths search per source point = Router.TravelSeconds pair by pair:
-- a walk below 700 yd, else the graph without the hearth).  --verify N re-checks N random pairs per guide against
-- Router.TravelSeconds and records the largest difference in the row (`verify_maxdiff`); --exact uses
-- Router.TravelSeconds for every pair.
--
-- Usage: luajit tools/cost_matrix.lua <era|tbc|mop|retail|forever> [--out PATH] [--guide ID] [--guides-file F]
--                                     [--prefix wiki:,qdb:,qpoi:] [--sample K] [--limit N] [--exact] [--verify 200]
--                                     [--taxi faction|band] [--list [--steps]]
--   --list           one {"id","n","sum","cmv","nl","np","who"} row per quest guide, no matrices (finds unbaked or stale
--                    guides; nl = located steps, np = located steps the planning character walks to: < 2 = nothing to bake)
--   --list --steps   the same plus each step's checksum parts (tools/test_route_order.lua checks the three copies)
-- Output (default): $CR_TMP/costmx/<flavor>.jsonl, CR_TMP defaulting to the optimizer's job directory (never the repo)
package.path = "./?.lua;" .. package.path

local flavor = arg[1] or "era"
local outPath, onlyGuide, guideSet, prefixes, sampleK, limit, exact, nverify = nil, nil, nil, nil, 1, math.huge, false, 200
local listOnly, listSteps, taxiPolicy = false, false, nil
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
    elseif a == "--steps" then listSteps = true
    elseif a == "--taxi" then taxiPolicy = arg[i + 1]
    elseif a == "--verify" then nverify = tonumber(arg[i + 1]) end
end
prefixes = prefixes or { "wiki:", "qdb:", "qpoi:" }   -- the quest guides: wiki zone guides + the _gaps guides
outPath = outPath or ((os.getenv("CR_TMP") or "/Users/daniel/.claude/jobs/ff3c728a/tmp") .. "/costmx/" .. flavor .. ".jsonl")

local TOC = { era = 11507, tbc = 20506, mop = 50504, retail = 120100, forever = 16001 }
local TAXI = { era = "Data/Taxi_era.lua", tbc = "Data/Taxi_tbc.lua", mop = "Data/Taxi_mop.lua", retail = "Data/Taxi_retail.lua",
               forever = "Data/Taxi_forever.lua" }
local EXTRA = { forever = "Data/MapFix_forever.lua" }

STUB_MAPS = dofile("tools/maps_" .. flavor .. ".lua")
local ADDON, NS = "CompletionRoute", {}
dofile("tools/stubs.lua")
function GetBuildInfo() return "x", "0", "2026", TOC[flavor] end
local FACTION = "Alliance"
function UnitFactionGroup() return FACTION end
function UnitLevel() return 1 end

PLAYER = { map = next(MAPS), x = 0.5, y = 0.5 }
do
    local wx, wy, inst = z2w(0.5, 0.5, PLAYER.map)
    PLAYER.wx, PLAYER.wy, PLAYER.inst = wx, wy, inst
end

local function load(path)
    local f = io.open("CompletionRoute/" .. path, "r")
    if not f then io.stderr:write("skip " .. path .. "\n") return end
    f:close()
    assert(loadfile("CompletionRoute/" .. path))(ADDON, NS)
end
for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", TAXI[flavor], EXTRA[flavor] or TAXI[flavor],
    "Data/Transit.lua", "Data/Imported_Entrances.lua", "Data/Access.lua", "Data/Inns.lua", "Data/ZoneAliases.lua",
    "Data/Roads_ek.lua", "Data/Roads_kalimdor.lua",
    "Routing/CostModel.lua", "Routing/TravelGraph.lua", "Routing/Roads.lua", "Routing/StepOrder.lua", "Routing/Router.lua",
    "Core/Account.lua", "Core/Progress.lua", "Core/Instances.lua",
    ("Guides/Imported_Wiki_" .. flavor .. ".lua"), ("Guides/Imported_Quests_" .. flavor .. "_gaps.lua") }) do load(f) end
CompletionRouteDB, CompletionRouteCharDB = nil, nil
if flavor == "forever" and not NS.isForever then error("cost_matrix forever: Core/Init.lua did not detect Forever") end
for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", "CompletionRoute") end
NS.db.profile.debug = false
NS.Print, NS.Debug, NS.Error = function() end, function() end, function() end
NS.db.profile.routing.baked = false          -- matrices are built on the AUTHOR order, never on a baked one
local G, R, U, TG, CM = NS.Guide, NS.Router, NS.Util, NS.TravelGraph, NS.CostModel
local FL = NS.dataFlavor or NS.flavor
-- the offline character: speed by planning level, no hearth or teleports, the offline flight-path rule
local OFF = dofile("tools/cm_offline.lua")
local ctl = OFF.Install(NS, MAPS, { taxi = taxiPolicy })
if ctl.policy == "known" then error("cost_matrix --taxi must be faction or band (a static matrix cannot learn flight paths)") end

local function ptStep(p) return { coords = { { x = 0.5, y = 0.5 } }, zone = p.zone, _wx = p.wx, _wy = p.wy, _winst = p.inst, _cmk = "own" } end
-- one row: seconds from point a to every point in pts (nil = no route), priced at a's level
local function row(a, pts, graph)
    ctl.SetLevel(a.level)
    if exact then
        local sa, out = ptStep(a), {}
        for j, b in ipairs(pts) do out[j] = R.TravelSeconds(sa, ptStep(b)) end
        return out
    end
    local speed, fly = CM.PlanTravel(a.level)
    return R.TravelRow(a, pts, { speed = speed, walkFactor = CM.WalkFactor(fly, NS.db.profile.routing.terrainFactor),
                                 graph = graph or TG.Snapshot() })
end

-- ---------------------------------------------------------------------------
-- Step metadata the optimizer needs
-- ---------------------------------------------------------------------------
local ACCEPT = { A = true, a = true, ["!"] = true }
local OBJ = { C = true, K = true, l = true, U = true }
local TURNIN = { T = true, t = true }
local KIND = { own = "o", npc = "n", zone = "z", ride = "r", none = "-" }
local checksum = G.RouteChecksum      -- ONE definition (Core/Guide.lua); the optimizer folds the parts written below

local function jnum(v) if v == nil then return "null" end if v == math.floor(v) then return tostring(v) end return ("%.1f"):format(v) end
local function jstr(s) return '"' .. tostring(s):gsub('[%c"\\]', function(ch) return ("\\u%04x"):format(ch:byte()) end) .. '"' end
local function jlist(t, f) local o = {} for i = 1, #t do o[i] = (f or jnum)(t[i]) end return "[" .. table.concat(o, ",") .. "]" end
local function jobj(t)
    local keys, o = {}, {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do local v = t[k] o[#o + 1] = jstr(k) .. ":" .. (type(v) == "string" and jstr(v) or ("%.10g"):format(v)) end
    return "{" .. table.concat(o, ",") .. "}"
end
local CMJ = jobj(CM.Export(ctl.policy))
local function jwho(who)
    local o = {}
    for _, k in ipairs({ "faction", "class", "race", "prof" }) do if who[k] then o[#o + 1] = jstr(k) .. ":" .. jstr(who[k]) end end
    return "{" .. table.concat(o, ",") .. "}"
end

-- [action, kind, quest, pre, minlevel, point, anchor, zone, hx, hy, cost-model kind, keep objective order]; point = -1
-- for a step the planning character does not walk to (it rides along; every step of a list row); keep = 1 on an
-- objective step of a quest whose objective steps keep their author order (CostModel.PlanSteps)
local function stepRow(s, pi, keepObj)
    local q = s.qid and s.qid[1] or 0
    local kind = ACCEPT[s.action] and "A" or OBJ[s.action] and "C" or TURNIN[s.action] and "T" or "O"
    local anchor = (not s.route) or s.sticky or false
    local _, _, z, hx, hy = G.RouteChecksumParts(s)
    local keep = (kind == "C" and keepObj and keepObj[q]) and 1 or 0
    return ("[%s,%s,%d,%s,%d,%d,%d,%d,%d,%d,%s,%d]"):format(jstr(s.action), jstr(kind), q, jlist(s.pre or {}),
        s.minlevel or 0, pi, anchor and 1 or 0, z, hx, hy, jstr(KIND[CM.Kind(s)] or "-"), keep)
end

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
                local extra = ""
                if listSteps then
                    local rows = {}
                    for i, s in ipairs(steps) do rows[i] = stepRow(s, -1) end
                    extra = ",\"steps\":[" .. table.concat(rows, ",") .. "]"
                end
                -- located steps, and the ones the planning character walks to (fewer than 2: nothing to bake)
                local who = CM.Persona(steps, g)
                local walk = CM.PlanSteps(steps, who)
                local nl, np = 0, 0
                for i, s in ipairs(steps) do
                    if CM.Located(s) then nl = nl + 1 if walk[i] then np = np + 1 end end
                end
                out:write(("{\"id\":%s,\"n\":%d,\"sum\":%d,\"cmv\":%d,\"nl\":%d,\"np\":%d,\"who\":%s%s}\n"):format(jstr(id), #steps,
                    checksum(steps), CM.VERSION, nl, np, jwho(who), extra))
                n = n + 1
                g.steps = nil
            elseif steps and #steps > 0 and not g.empty then
                local tg0 = os.clock()
                -- the planning character (CostModel.Persona); its faction decides the flight masters too
                local who = CM.Persona(steps, g)
                FACTION = who.faction or ((g.faction == "Horde") and "Horde" or "Alliance")
                NS.player.faction = FACTION
                local start = CM.StartLevel(g)
                ctl.SetLevel(start)
                R.Invalidate()
                TG.Build()
                -- start where vplayer starts a character: the guide zone's centre, at the guide's start level
                local szone, swx, swy, sinst = OFF.StartPoint(NS, g, steps)
                local startPt = swx and { wx = swx, wy = swy, inst = sinst, zone = szone, level = start } or nil
                -- the priced points: a located step the planning character walks to (CostModel.PlanSteps), at its
                -- point, keyed by place and level key (speed band / taxi bin); every other step rides with the block before it
                local walk, keepObj = CM.PlanSteps(steps, who)
                local pts, key2pt, rows = {}, {}, {}
                for i, s in ipairs(steps) do
                    local pi = -1
                    if walk[i] and CM.Located(s) then
                        local wx, wy, inst = R.StepWorld(s)
                        if wx then
                            local lv = CM.Level(s, start)
                            local lk = CM.LevelKey(lv, ctl.policy)
                            local k = ("%d:%.1f:%.1f:%d"):format(inst, wx, wy, lk)
                            pi = key2pt[k]
                            if not pi then
                                pts[#pts + 1] = { wx = wx, wy = wy, inst = inst, zone = s.zone, level = lk }
                                pi = #pts key2pt[k] = pi
                            end
                            pi = pi - 1   -- 0-based for the solver
                        end
                    end
                    rows[i] = stepRow(s, pi, keepObj)
                end
                -- matrix: one graph search per source point (the flight-path rule may depend on its level: own snapshot)
                local snaps = {}
                local function snapFor(level)
                    ctl.SetLevel(level)
                    local k = CM.LevelKey(level, ctl.policy)
                    if not snaps[k] then snaps[k] = TG.Snapshot() end
                    return snaps[k]
                end
                local mrows = {}
                for i, a in ipairs(pts) do
                    local r = row(a, pts, (not exact) and snapFor(a.level) or nil)
                    local o = {}
                    for j = 1, #pts do o[j] = (j == i) and 0 or (r[j] or -1) end
                    mrows[i] = jlist(o)
                end
                -- no start point (no map for the guide's zone): the first leg is free, as in vplayer
                local startRow = {}
                if startPt then
                    local r = row(startPt, pts, (not exact) and snapFor(startPt.level) or nil)
                    for j = 1, #pts do startRow[j] = r[j] or -1 end
                else
                    for j = 1, #pts do startRow[j] = 0 end
                end
                -- verify the rows against the real router on random pairs
                local maxDiff, nv = 0, 0
                if not exact and #pts > 1 and nverify > 0 then
                    math.randomseed(#pts * 7919 + #steps)
                    local tries = math.min(nverify, #pts * #pts)
                    for _ = 1, tries do
                        local i, j = math.random(#pts), math.random(#pts)
                        if i ~= j then
                            ctl.SetLevel(pts[i].level)
                            local real = R.TravelSeconds(ptStep(pts[i]), ptStep(pts[j]))
                            local mine = row(pts[i], { pts[j] }, snapFor(pts[i].level))[1]
                            nv = nv + 1
                            local diff
                            if real == nil and mine == nil then diff = 0
                            elseif real == nil or mine == nil then diff = 1e9
                            else diff = math.abs(real - mine) end
                            if diff > maxDiff then maxDiff = diff end
                        end
                    end
                end
                if maxDiff > maxDiffAll then maxDiffAll = maxDiff end
                verified = verified + nv
                out:write(("{\"flavor\":%s,\"id\":%s,\"name\":%s,\"faction\":%s,\"minlevel\":%d,\"n\":%d,\"sum\":%d,\"npts\":%d,\"placed\":%s,\"exact\":%s,\"verify_n\":%d,\"verify_maxdiff\":%s,\"secs\":%s,\"cm\":%s,\"who\":%s,\"levels\":%s,\"steps\":[%s],\"start\":%s,\"m\":[%s]}\n")
                    :format(jstr(FL), jstr(id), jstr(g.name or id), jstr(g.faction or "Both"), start, #steps, checksum(steps), #pts,
                        startPt and "true" or "false", exact and "true" or "false", nv, jnum(maxDiff), jnum(os.clock() - tg0), CMJ, jwho(who),
                        jlist((function() local l = {} for i, p in ipairs(pts) do l[i] = p.level end return l end)()),
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
io.stderr:write(("DONE cost_matrix %s: %d guides in %.0fs -> %s | verified %d pairs, max |row-real| = %.3f s | cost model v%d, taxi %s\n")
    :format(FL, n, os.clock() - t0, outPath, verified, maxDiffAll, CM.VERSION, ctl.policy))
