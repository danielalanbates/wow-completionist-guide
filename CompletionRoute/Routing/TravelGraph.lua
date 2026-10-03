-- CompletionRoute :: Routing/TravelGraph.lua
-- The travel-system graph (written from scratch, open data):
--   nodes  = flight masters (from wago.tools TaxiNodes), transit endpoints (boats/zeppelins/portals/trams),
--            the character's hearth location, plus a virtual start (player) and goal.
--   edges  = taxi flights (real polyline lengths), transit rides, hearth (cast + cooldown), and implicit
--            straight-line walking between any two nodes on the same continent instance.
-- Dijkstra over that graph gives the cheapest (in seconds) way from A to B: this is what powers
-- "hearth when it's faster", "fly from X to Y", "take the boat", and the step-order optimizer.
local ADDON, NS = ...
local U, HBD = NS.Util, NS.HBD
local TG = {}
NS.TravelGraph = TG

TG.nodes = {}          -- array of nodes
TG.taxiByID = {}       -- taxiNodeID -> node
TG.built = false

local function cfg() return NS.db and NS.db.profile.routing or {} end
local function faction() return NS.player and NS.player.faction == "Alliance" and "A" or "H" end

local function newNode(kind, inst, wx, wy, name)
    local n = { id = #TG.nodes + 1, kind = kind, inst = inst, wx = wx, wy = wy, name = name, edges = {} }
    TG.nodes[#TG.nodes + 1] = n
    return n
end
local function addEdge(a, b, cost, mode, title, data)
    a.edges[#a.edges + 1] = { to = b, cost = cost, mode = mode, title = title, data = data }
end
local function dist(ax, ay, bx, by) local dx, dy = ax - bx, ay - by return math.sqrt(dx * dx + dy * dy) end

-- Convert zone-name coords to world; returns wx, wy, inst
local function zoneToWorld(zoneName, x, y)
    local mapID = U.MapIDByName(zoneName)
    if not mapID then return nil end
    return HBD:GetWorldCoordinatesFromZone(x / 100, y / 100, mapID)
end
TG.zoneToWorld = zoneToWorld

-- ---------------------------------------------------------------------------
-- Build static part of the graph (taxi + transit)
-- ---------------------------------------------------------------------------
function TG.AccessUnlocked(a)
    if not a.unlock then return false end
    for _, q in ipairs(a.unlock) do
        if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted and C_QuestLog.IsQuestFlaggedCompleted(q) then return true end
    end
    return false
end
-- the graph depends on which chains are unlocked: rebuild lazily after a turn-in
if NS.RegisterEvent then NS:RegisterEvent("QUEST_TURNED_IN", function() TG.built = false end) end

-- Known internal DB2 nodes that are not open-world player flight masters
local TAXI_BLACKLIST = {
    [2084] = true, -- Norwington Estate carriage quest script
    [3] = true,    -- Programmer Isle
}

function TG.Build()
    TG.nodes, TG.taxiByID, TG.unresolved = {}, {}, {}
    local flavor = NS.flavor
    local taxi = NS.TaxiData and (NS.TaxiData[flavor] or NS.TaxiData.tbc)
    local fac = faction()
    if taxi then
        for id, n in pairs(taxi.nodes) do
            if not TAXI_BLACKLIST[id] then
                local name, cont, wx, wy, f = n[1], n[2], n[3], n[4], n[5]
                if f == "N" or f == fac then
                    local node = newNode("taxi", cont, wx, wy, name)
                    node.taxiID = id
                    TG.taxiByID[id] = node
                end
            end
        end
        for _, p in ipairs(taxi.paths) do
            local a, b = TG.taxiByID[p[1]], TG.taxiByID[p[2]]
            if a and b then
                addEdge(a, b, 3 + (p[4] / (cfg().taxiSpeed or 32)), "taxi", "Fly to " .. b.name, { copper = p[3], len = p[4] })
            end
        end
    end
    local missing = 0
    for _, t in ipairs(NS.TransitData or {}) do
        local okFlavor = (not t.flavors) or t.flavors[flavor]
        local okFac = (not t.fac) or t.fac == fac
        if okFlavor and okFac then
            local ax, ay, ai = zoneToWorld(t.from[1], t.from[2], t.from[3])
            local bx, by, bi = zoneToWorld(t.to[1], t.to[2], t.to[3])
            if ax and bx then
                local a = newNode("transit", ai, ax, ay, t.from.name or t.from[1]); a.mode = t.mode
                local b = newNode("transit", bi, bx, by, t.to.name or t.to[1]); b.mode = t.mode
                addEdge(a, b, t.cost, t.mode, t.title, t)
                if t.twoway ~= false then addEdge(b, a, t.cost, t.mode, t.title, t) end
            else missing = missing + 1 TG.unresolved = TG.unresolved or {} TG.unresolved[#TG.unresolved + 1] = (t.title or "?") .. " [" .. tostring(ax and "" or t.from[1]) .. (bx and "" or (" " .. tostring(t.to[1]))) .. "]" end
        end
    end
    -- access chains (Data/Access.lua): a one-way edge into a place an intro quest line unlocks. Locked -> the
    -- edge starts where the chain starts and costs the whole chain; unlocked -> the cheap `after` edge (portal,
    -- airship...). Progress injects the chain's steps in front of a guide whose step 1 is behind a locked one.
    TG.accessEdges = {}
    for _, a in ipairs(NS.AccessData or {}) do
        local okFlavor = (not a.flavors) or a.flavors[flavor]
        local okFac = (not a.fac) or a.fac == fac
        if okFlavor and okFac then
            local unlocked = TG.AccessUnlocked(a)
            local src = (unlocked and a.after and a.after.from) or a.from
            local ax, ay, ai = zoneToWorld(src[1], src[2], src[3])
            local bx, by, bi = zoneToWorld(a.to[1], a.to[2], a.to[3])
            if ax and bx then
                local n1 = newNode("transit", ai, ax, ay, src.name or src[1]); n1.mode = "access"
                local n2 = newNode("transit", bi, bx, by, a.to.name or a.to[1]); n2.mode = "access"
                local title = unlocked and a.after and a.after.title or a.title
                addEdge(n1, n2, (unlocked and a.after and a.after.cost) or a.cost or 600, "access", title, { access = a, locked = not unlocked })
                TG.accessEdges[#TG.accessEdges + 1] = n1
            else missing = missing + 1 TG.unresolved[#TG.unresolved + 1] = "access " .. tostring(a.key) end
        end
    end
    TG.BuildRoads()
    TG.Index()
    TG.built = true
    NS:Debug(("TravelGraph: %d nodes (%d road), %d transit entries unresolved"):format(#TG.nodes, TG.roadCount or 0, missing))
end

-- ---------------------------------------------------------------------------
-- Known flight paths (learned from the taxi map)
-- ---------------------------------------------------------------------------
-- Classic's legacy taxi API gives names, not node IDs, so map a flight master's name back to a
-- graph node. Names are compared loosely: "Stormwind, Elwynn Forest" vs "Stormwind".
function TG.NodeByName(name)
    if not name or name == "" then return nil end
    local want = name:lower()
    local short = want:match("^([^,]+)") or want
    local best
    for _, n in ipairs(TG.nodes or {}) do
        if n.taxiID and n.name then
            local have = n.name:lower()
            if have == want then return n end
            if not best and (have:find(short, 1, true) or short:find((have:match("^([^,]+)") or have), 1, true)) then
                best = n
            end
        end
    end
    return best
end

function TG.IsTaxiKnown(node)
    if not node or not node.taxiID then return false end
    local id = node.taxiID
    if NS.db and NS.db.char and NS.db.char.knownTaxi and NS.db.char.knownTaxi[id] then return true end
    if NS.db and NS.db.global and NS.db.global.knownTaxi and NS.db.global.knownTaxi[id] then return true end
    return false
end
-- "faction" (default): every flight master your faction can use is routable, learned or not -
-- the route walks you to the one you need. "known": only flight paths this character has learned.
function TG.TaxiPolicy()
    local c = cfg()
    if c.taxiPolicy == "known" then return "known" end
    if c.taxiPolicy == "faction" or c.assumeAllTaxi or c.taxiPolicy == nil then return "faction" end
    return "faction"
end
function TG.TaxiUsable(node)
    if TG.TaxiPolicy() == "faction" then return true end
    return TG.IsTaxiKnown(node)
end
-- Harvesting flight paths ONLY when the player opens a flight master's map meant a character
-- who had not done that this session routed with zero flights - the arrow then points in a
-- straight line across the world instead of "fly Stormwind -> Morgan's Vigil". The game already
-- knows which nodes you have; ask it for every continent at login, and support the classic
-- taxi API too (C_TaxiMap does not exist on every client).
local function harvestList(list)
    local learned = 0
    local unreachable = (Enum and Enum.FlightPathState and Enum.FlightPathState.Unreachable) or 2
    for _, n in ipairs(list or {}) do
        if n.nodeID and n.state ~= nil and n.state ~= unreachable then
            if not TG.IsTaxiKnown({ taxiID = n.nodeID }) then learned = learned + 1 end
            if NS.db and NS.db.char and NS.db.char.knownTaxi then NS.db.char.knownTaxi[n.nodeID] = true end
            if NS.db and NS.db.global then
                NS.db.global.knownTaxi = NS.db.global.knownTaxi or {}
                NS.db.global.knownTaxi[n.nodeID] = true
            end
        end
    end
    return learned
end

local function nodesForMap(mapID)
    if not (C_TaxiMap and mapID) then return nil end
    if C_TaxiMap.GetAllTaxiNodes then return C_TaxiMap.GetAllTaxiNodes(mapID) end
    if C_TaxiMap.GetTaxiNodesForMap then return C_TaxiMap.GetTaxiNodesForMap(mapID) end
    return nil
end

local KNOWN_CONTINENTS = {
    12, 13, 101, 113, 424, 572, 619, 875, 876, 1550, 1978, 2274, -- Retail
    1414, 1415, 1945, 113, 390 -- Classic
}

-- every continent we have taxi data for, so a login harvest covers the whole world
local function continentMaps()
    local out, seen = {}, {}
    local map = U.PlayerPos()
    local info = map and C_Map.GetMapInfo(map)
    while info and info.mapType and info.mapType > 2 and info.parentMapID and info.parentMapID > 0 do
        info = C_Map.GetMapInfo(info.parentMapID)
    end
    if info and not seen[info.mapID] then out[#out + 1] = info.mapID seen[info.mapID] = true end
    for _, mid in ipairs(KNOWN_CONTINENTS) do
        if not seen[mid] and C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mid) then
            out[#out + 1] = mid seen[mid] = true
        end
    end
    for _, n in ipairs(TG.nodes or {}) do
        if n.map and not seen[n.map] then
            local mi = C_Map.GetMapInfo(n.map)
            while mi and mi.mapType and mi.mapType > 2 and mi.parentMapID and mi.parentMapID > 0 do
                mi = C_Map.GetMapInfo(mi.parentMapID)
            end
            if mi and not seen[mi.mapID] then out[#out + 1] = mi.mapID seen[mi.mapID] = true end
        end
    end
    return out
end

function TG.LearnTaxi(quiet)
    local learned = 0
    local map = U.PlayerPos()
    learned = learned + harvestList(nodesForMap(map))
    for _, m in ipairs(continentMaps()) do learned = learned + harvestList(nodesForMap(m)) end
    -- retail FlightMapFrame pin harvest
    if FlightMapFrame and FlightMapFrame.pinPools and FlightMapFrame.pinPools.FlightMap_FlightPointPinTemplate then
        local unreachable = (Enum and Enum.FlightPathState and Enum.FlightPathState.Unreachable) or 2
        for pin in FlightMapFrame.pinPools.FlightMap_FlightPointPinTemplate:EnumerateActive() do
            local d = pin.taxiNodeData
            if d and d.nodeID and d.state ~= nil and d.state ~= unreachable then
                if not TG.IsTaxiKnown({ taxiID = d.nodeID }) then learned = learned + 1 end
                if NS.db and NS.db.char and NS.db.char.knownTaxi then NS.db.char.knownTaxi[d.nodeID] = true end
                if NS.db and NS.db.global then
                    NS.db.global.knownTaxi = NS.db.global.knownTaxi or {}
                    NS.db.global.knownTaxi[d.nodeID] = true
                end
            end
        end
    end
    -- classic clients: while a flight master's map is open the legacy API lists your nodes
    if NumTaxiNodes and TaxiNodeGetType then
        for i = 1, (NumTaxiNodes() or 0) do
            local t = TaxiNodeGetType(i)
            if t == "REACHABLE" or t == "CURRENT" then
                local nm = TaxiNodeName and TaxiNodeName(i)
                if nm then
                    local node = TG.NodeByName and TG.NodeByName(nm)
                    if node and node.taxiID and not TG.IsTaxiKnown(node) then
                        if NS.db and NS.db.char and NS.db.char.knownTaxi then NS.db.char.knownTaxi[node.taxiID] = true end
                        if NS.db and NS.db.global then
                            NS.db.global.knownTaxi = NS.db.global.knownTaxi or {}
                            NS.db.global.knownTaxi[node.taxiID] = true
                        end
                        learned = learned + 1
                    end
                end
            end
        end
    end
    if learned > 0 then
        NS.Router.Invalidate()
        if not quiet then NS:Print("Learned " .. learned .. " flight path(s).") end
    end
    return learned
end

NS:RegisterEvent("TAXIMAP_OPENED", function() pcall(TG.LearnTaxi) end)
NS:On("PLAYER_READY", function()
    NS:After(8, function()
        pcall(TG.LearnTaxi, true)
        local n = 0
        for _ in pairs(NS.db.char.knownTaxi) do n = n + 1 end
        if n == 0 and TG.TaxiPolicy() == "known" and not NS.db.char.taxiHintShown then
            NS.db.char.taxiHintShown = true
            NS:Print("|cffff9900No flight paths known yet|r - open any flight master's map once and I can route you by air. Until then the arrow walks. (/cr taxi)")
        end
    end)
end)

-- ---------------------------------------------------------------------------
-- Hearth location (learned)
-- ---------------------------------------------------------------------------
function TG.HearthWorld()
    local b = NS.db.char.bind
    if b and b.wx then return b.wx, b.wy, b.inst, b.name end
    local name = GetBindLocation and GetBindLocation()
    local seed = name and NS.InnData and NS.InnData[name]
    if seed then
        local wx, wy, inst = zoneToWorld(seed[1], seed[2], seed[3])
        if wx then return wx, wy, inst, name end
    end
    return nil
end
local function recordBindHere()
    local map, x, y, inst, wx, wy = U.PlayerPos()
    if wx then
        NS.db.char.bind = { wx = wx, wy = wy, inst = inst, map = map, x = x, y = y, name = GetBindLocation and GetBindLocation() or "Home" }
        NS:Debug("Hearth location recorded: " .. tostring(NS.db.char.bind.name))
    end
end
NS:RegisterEvent("HEARTHSTONE_BOUND", function() NS:After(1, recordBindHere) end)
-- learn the hearth spot whenever we are resting AT our bind location (inn name == bind name)
NS:RegisterEvent("PLAYER_UPDATE_RESTING", function()
    if IsResting and IsResting() then
        local sub = GetSubZoneText and GetSubZoneText()
        local bindname = GetBindLocation and GetBindLocation()
        local b = NS.db.char.bind
        if sub and bindname and (sub == bindname or (GetMinimapZoneText and GetMinimapZoneText() == bindname)) and (not b or b.name ~= bindname) then
            recordBindHere()
        end
    end
end)
-- After hearthing we arrive at the inn: record position once loading finishes
local hearthPending = false
NS:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spellID)
    if unit == "player" and (spellID == NS.HEARTH_SPELL or spellID == NS.ASTRAL_RECALL) then hearthPending = true end
end)
NS:RegisterEvent("PLAYER_ENTERING_WORLD", function()
    if hearthPending then hearthPending = false NS:After(3, recordBindHere) end
end)
NS:RegisterEvent("PLAYER_CONTROL_GAINED", function()
    if hearthPending then hearthPending = false NS:After(1, recordBindHere) end
end)

-- ---------------------------------------------------------------------------
-- Roads: predetermined paths through zones (hand-authored Data/Roads_*.lua, image-traced via
-- tools/trace_roads.py, or recorded from this account's own play by Routing/Roads.lua).
-- A road is a polyline; every vertex is a graph node chained by "road" edges costed at
-- roadFactor (1.0) instead of the off-road terrainFactor (1.25), so Dijkstra prefers the road
-- when it is not much longer than the straight line. Road nodes are bucketed on a grid so the
-- lazy complete-walking graph only has to look at nearby road vertices.
-- ---------------------------------------------------------------------------
TG.roadGrid = {}       -- [inst][cellKey] = { node, ... }
TG.roadCount = 0
local ROAD_CELL = 1500 -- yards
local function cellKey(wx, wy) return math.floor(wx / ROAD_CELL) .. ":" .. math.floor(wy / ROAD_CELL) end
local function gridAdd(n)
    local g = TG.roadGrid[n.inst] if not g then g = {} TG.roadGrid[n.inst] = g end
    local k = cellKey(n.wx, n.wy)
    local cell = g[k] if not cell then cell = {} g[k] = cell end
    cell[#cell + 1] = n
end
-- road vertices within ~radius of (wx,wy) on instance inst (3x3 cells)
function TG.RoadNear(inst, wx, wy)
    local g = TG.roadGrid[inst]
    if not g then return nil end
    local out = {}
    local cx, cy = math.floor(wx / ROAD_CELL), math.floor(wy / ROAD_CELL)
    for dx = -1, 1 do for dy = -1, 1 do
        local cell = g[(cx + dx) .. ":" .. (cy + dy)]
        if cell then for i = 1, #cell do out[#out + 1] = cell[i] end end
    end end
    return out
end
-- Join polyline ends to an existing vertex within `snap` yards (junctions between roads).
local function roadVertex(inst, wx, wy, name, snap, mine)
    for _, n in ipairs(TG.RoadNear(inst, wx, wy) or {}) do
        if not mine[n] and dist(n.wx, n.wy, wx, wy) <= snap then return n end
    end
    local n = newNode("road", inst, wx, wy, name)
    n.road = true
    gridAdd(n)
    TG.roadCount = TG.roadCount + 1
    return n
end
local function addRoad(inst, pts, name, factor)
    local prev
    local mine = {}   -- never snap a polyline onto its own vertices (a 25-yd trace would eat its own tail)
    for i, pt in ipairs(pts) do
        local n = roadVertex(inst, pt[1], pt[2], name, (i == 1 or i == #pts) and 40 or 8, mine)
        mine[n] = true
        if prev and prev ~= n then
            local d = dist(prev.wx, prev.wy, n.wx, n.wy)
            addEdge(prev, n, 0, "road", nil, { dist = d, factor = factor })
            addEdge(n, prev, 0, "road", nil, { dist = d, factor = factor })
        end
        prev = n
    end
end
-- Accepts entries of the form
--   { zone = "Elwynn Forest", name = "...", pts = { {x%, y%}, ... } }        (map percentages)
--   { inst = 0, name = "...", w = { {wx, wy}, ... } }                         (world coordinates)
-- plus optional flavors = {era=true,...}, fac = "A"|"H", factor = road cost factor override.
function TG.AddRoadEntries(list, defaultFactor)
    local added = 0
    for _, r in ipairs(list or {}) do
        local okFlavor = (not r.flavors) or r.flavors[NS.flavor]
        local okFac = (not r.fac) or r.fac == faction()
        if okFlavor and okFac then
            local pts, inst = {}, r.inst
            if r.w then
                for _, pt in ipairs(r.w) do pts[#pts + 1] = { pt[1], pt[2] } end
            elseif r.zone and r.pts then
                for _, pt in ipairs(r.pts) do
                    local wx, wy, i = zoneToWorld(r.zone, pt[1], pt[2])
                    if wx then pts[#pts + 1] = { wx, wy } inst = i end
                end
            end
            if inst and #pts >= 2 then addRoad(inst, pts, r.name or r.zone or "road", r.factor or defaultFactor) added = added + 1 end
        end
    end
    return added
end
function TG.BuildRoads()
    TG.roadGrid, TG.roadCount = {}, 0
    if cfg().roads == false then return end
    local n = TG.AddRoadEntries(NS.RoadData, nil)
    -- roads this account has actually walked (Routing/Roads.lua recorder) - exact, so slightly preferred
    if NS.Roads and NS.Roads.TraceEntries then n = n + TG.AddRoadEntries(NS.Roads.TraceEntries(), 0.97) end
    NS:Debug(("Roads: %d polylines, %d vertices"):format(n, TG.roadCount))
end
function TG.RebuildRoads()
    -- drop old road nodes and rebuild (recorder adds traces over time)
    local keep = {}
    for _, n in ipairs(TG.nodes) do if not n.road then keep[#keep + 1] = n end end
    TG.nodes = keep
    for i, n in ipairs(TG.nodes) do n.id = i end
    TG.BuildRoads()
    TG.PathCacheWipe()
end

-- ---------------------------------------------------------------------------
-- Dijkstra
-- ---------------------------------------------------------------------------
local function walkCost(ax, ay, bx, by, speed)
    local d = dist(ax, ay, bx, by)
    local tf = (U.CanFly and U.CanFly()) and 1.05 or (cfg().terrainFactor or 1.25)
    return d * tf / speed, d
end

-- Simple binary heap
local Heap = {}
Heap.__index = Heap
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

-- FindPath(sx,sy,sinst, gx,gy,ginst, opts) -> path { cost=seconds, legs = {{mode,from,to,cost,title,data}} } or nil
-- opts: { hearth = bool(default cfg), taxi = bool, transit = bool, speed = yd/s }
-- Per-instance node lists (relaxWalk only looks at nodes on the same continent) and instance
-- connectivity: which continents can reach which through explicit edges (transit/taxi). A goal on a
-- continent no edge leads to is unreachable - answer that without exploring the whole graph.
function TG.Index()
    local byInst, comp = {}, {}
    local function find(i) while comp[i] and comp[i] ~= i do i = comp[i] end return i end
    local function union(a, b) a, b = find(a), find(b) if a ~= b then comp[a] = b end end
    for _, n in ipairs(TG.nodes) do
        if n.inst then
            comp[n.inst] = comp[n.inst] or n.inst
            if not n.road then
                local l = byInst[n.inst] if not l then l = {} byInst[n.inst] = l end
                l[#l + 1] = n
            end
        end
    end
    for _, n in ipairs(TG.nodes) do
        for _, e in ipairs(n.edges) do if n.inst and e.to.inst and n.inst ~= e.to.inst then union(n.inst, e.to.inst) end end
    end
    TG.byInst, TG.instComp = byInst, comp
    TG.instFind = function(i) return find(i) end
    TG.PathCacheWipe()
end

-- Hearth-free path cache.  The step-order optimizer asks for the SAME step pairs on every step
-- advance (a window of 10 costs up to 110 FindPath calls, ~6 ms each on a modern continent's ~160
-- nodes) — that was ~0.5 s of Lua per step on MoP/retail, a visible hitch in game and the reason the
-- virtual player hit its per-guide time cap.  Only hearth-free queries are cached: a hearth's cost
-- depends on a cooldown that ticks, so those stay live.  The key is exact (no coordinate rounding),
-- so a hit returns precisely what a fresh search would.  Dropped whenever the graph is rebuilt.
TG.pathCache, TG.pathCacheN = {}, 0
local PATH_CACHE_MAX = 20000        -- a full guide's window pairs fit easily; wipe rather than grow
function TG.PathCacheWipe() TG.pathCache, TG.pathCacheN = {}, 0 end
function TG.PathCacheStore(key, path)
    if not key then return path end
    if TG.pathCacheN >= PATH_CACHE_MAX then TG.PathCacheWipe() end
    TG.pathCache[key] = path or false      -- false = "searched, no path": still worth not repeating
    TG.pathCacheN = TG.pathCacheN + 1
    return path
end
function TG.InstReachable(a, b)
    if a == b then return true end
    if not TG.instFind then return true end
    local fa, fb = TG.instFind(a), TG.instFind(b)
    if not TG.instComp[a] or not TG.instComp[b] then return false end   -- no node at all on that continent
    return fa == fb
end

TG.stats = { calls = 0, pops = 0, relax = 0, capped = 0, skipped = 0 }   -- profiling counters (cheap; read by tools/route_sweep.lua)
function TG.FindPath(sx, sy, sinst, gx, gy, ginst, opts)
    TG.stats.calls = TG.stats.calls + 1
    if not TG.built then TG.Build() end
    if not (sx and gx and sinst and ginst) then return nil end
    opts = opts or {}
    local c = cfg()
    local speed = opts.speed or U.TravelSpeed()
    local useHearth = (opts.hearth == nil) and (c.hearth ~= false) or opts.hearth
    local useTaxi = (opts.taxi == nil) and (c.taxi ~= false) or opts.taxi
    local useTransit = (opts.transit == nil) and (c.transit ~= false) or opts.transit
    local ckey
    if not useHearth then
        ckey = ("%s|%s|%s|%s|%s|%s|%s|%s|%s|%s"):format(sinst, sx, sy, ginst, gx, gy, speed,
                                                     useTaxi and 1 or 0, useTransit and 1 or 0, TG.TaxiPolicy())
        local hit = TG.pathCache[ckey]
        if hit ~= nil then TG.stats.cached = (TG.stats.cached or 0) + 1 return hit or nil end
    end

    local start = { id = "start", kind = "start", inst = sinst, wx = sx, wy = sy, name = "You", edges = {} }
    local goal = { id = "goal", kind = "goal", inst = ginst, wx = gx, wy = gy, name = "Destination", edges = {} }
    -- direct walk
    local best
    if sinst == ginst then
        local wc, d = walkCost(sx, sy, gx, gy, speed)
        best = { cost = wc, legs = { { mode = "walk", from = start, to = goal, cost = wc, dist = d } } }
        if d < 300 then return TG.PathCacheStore(ckey, best) end   -- nothing beats walking 300 yards
    end
    -- hearth virtual node
    local hearthNodes = {}
    if useHearth then
        local hx, hy, hinst, hname = TG.HearthWorld()
        if hx then
            local ready, cd, kind, id = U.HearthReady()
            local aready, acd, akind, aid = U.AstralRecallReady()
            local function hnode(cdleft, k, i, label)
                if cdleft > 15 * 60 then return end
                local hn = { id = "hearth" .. k, kind = "hearth", inst = hinst, wx = hx, wy = hy, name = hname or "Home", edges = {} }
                local cost = (c.hearthCost or 60) + cdleft
                addEdge(start, hn, cost, "hearth", label .. " to " .. (hname or "your inn"), { kind = k, id = i, cd = cdleft })
                hearthNodes[#hearthNodes + 1] = hn
            end
            if U.HasItem(NS.HEARTH_ITEM) then hnode(cd, "item", NS.HEARTH_ITEM, "Hearth") end
            if akind then hnode(acd, "spell", NS.ASTRAL_RECALL, "Astral Recall") end
        end
    end
    -- unreachable continent (neither from here nor from the hearth) -> no graph search at all
    if not TG.InstReachable(sinst, ginst) then
        local viaHearth = false
        for _, hn in ipairs(hearthNodes) do if TG.InstReachable(hn.inst, ginst) then viaHearth = true end end
        if not viaHearth then TG.stats.skipped = TG.stats.skipped + 1 return TG.PathCacheStore(ckey, best) end
    end
    -- Dijkstra over: start, goal, hearth nodes, all graph nodes
    local nodes = TG.nodes
    local INF = math.huge
    local d, prev, prevEdge, closed = {}, {}, {}, {}
    local heap = newHeap()
    d[start] = 0
    heap:push(0, start)
    local roadFactor = c.roadFactor or 1.0
    local function relaxTo(u, du, v)
        local wc, dd = walkCost(u.wx, u.wy, v.wx, v.wy, speed)
        local nd = du + wc
        if nd < (d[v] or INF) then d[v] = nd prev[v] = u prevEdge[v] = { mode = "walk", cost = wc, dist = dd } heap:push(nd, v) end
    end
    local function relaxWalk(u, du)
        -- nearby road vertices (grid lookup - the full sweep below skips road nodes)
        local near = TG.RoadNear(u.inst, u.wx, u.wy)
        if near then
            for i = 1, #near do local v = near[i] if v ~= u and not closed[v] then relaxTo(u, du, v) end end
        end
        -- walk to every non-road node in same instance (lazy complete graph; per-instance index)
        local same = (TG.byInst and TG.byInst[u.inst]) or nodes
        TG.stats.relax = TG.stats.relax + #same
        for i = 1, #same do
            local v = same[i]
            if v.inst == u.inst and v ~= u and not v.road and not closed[v] then
                local usable = (v.kind ~= "taxi") or (useTaxi and TG.TaxiUsable(v))
                if v.kind == "transit" and not useTransit then usable = false end
                if usable then
                    local wc, dd = walkCost(u.wx, u.wy, v.wx, v.wy, speed)
                    local nd = du + wc
                    if nd < (d[v] or INF) then d[v] = nd prev[v] = u prevEdge[v] = { mode = "walk", cost = wc, dist = dd } heap:push(nd, v) end
                end
            end
        end
        if goal.inst == u.inst and u ~= start then
            local wc, dd = walkCost(u.wx, u.wy, goal.wx, goal.wy, speed)
            local nd = du + wc
            if nd < (d[goal] or INF) then d[goal] = nd prev[goal] = u prevEdge[goal] = { mode = "walk", cost = wc, dist = dd } heap:push(nd, goal) end
        end
    end
    local iterations = 0
    while true do
        local du, u = heap:pop()
        if not u then break end
        if not closed[u] then
            closed[u] = true
            if u == goal then break end
            iterations = iterations + 1
            TG.stats.pops = TG.stats.pops + 1
            if iterations > 20000 then TG.stats.capped = TG.stats.capped + 1 break end
            -- explicit edges
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
                    if nd < (d[v] or INF) then d[v] = nd prev[v] = u prevEdge[v] = e heap:push(nd, v) end
                end
            end
            -- walking from here (start walks too; from a taxi node you can walk anywhere on the continent)
            relaxWalk(u, du)
        end
    end
    if not d[goal] then return TG.PathCacheStore(ckey, best) end
    if best and best.cost <= d[goal] + 1 then return TG.PathCacheStore(ckey, best) end
    -- rebuild path
    local legs = {}
    local v = goal
    while prev[v] do
        local e = prevEdge[v]
        local leg = { mode = e.mode, from = prev[v], to = v, cost = e.cost, title = e.title, data = e.data, dist = e.dist }
        if e.mode == "road" then leg.mode = "walk" leg.road = true leg.dist = e.data.dist leg.cost = d[v] - d[prev[v]] end
        if e.mode == "taxi" then leg.discover = not TG.IsTaxiKnown(v) if leg.discover then leg.title = leg.title .. " (new flight path)" end end
        tinsert(legs, 1, leg)
        v = prev[v]
    end
    -- merge consecutive walk legs; keep the intermediate vertices so the arrow can follow the road
    local merged = {}
    for _, l in ipairs(legs) do
        local last = merged[#merged]
        if last and last.mode == "walk" and l.mode == "walk" then
            last.via = last.via or {}
            last.via[#last.via + 1] = { wx = last.to.wx, wy = last.to.wy, road = last.road or l.road }
            last.to = l.to last.cost = last.cost + l.cost last.dist = (last.dist or 0) + (l.dist or 0)
            last.road = last.road or l.road
        else merged[#merged + 1] = l end
    end
    return TG.PathCacheStore(ckey, { cost = d[goal], legs = merged })
end

-- Human readable description of a path
function TG.Describe(path)
    if not path then return "no route" end
    local out = {}
    for _, l in ipairs(path.legs) do
        if l.mode == "walk" then out[#out + 1] = ("%s %s to %s"):format(l.road and "Follow the road" or "Walk", U.FmtDist(l.dist), l.to.name or "?")
        elseif l.mode == "taxi" then out[#out + 1] = ("Fly %s -> %s"):format(l.from.name, l.to.name)
        elseif l.mode == "hearth" then out[#out + 1] = l.title
        else out[#out + 1] = l.title or (l.mode .. " to " .. (l.to.name or "?")) end
    end
    return table.concat(out, "; ") .. (" (~%s)"):format(U.FmtTime(path.cost))
end

NS:On("ADDON_READY", function() NS:After(0.5, function() pcall(TG.Build) end) end)
