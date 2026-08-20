-- CompletionRoute :: Routing/TravelGraph.lua
-- The travel-system graph (the Zygor "LibRover" equivalent, written from scratch, open data):
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
function TG.Build()
    TG.nodes, TG.taxiByID = {}, {}
    local flavor = NS.flavor
    local taxi = NS.TaxiData and (NS.TaxiData[flavor] or NS.TaxiData.tbc)
    local fac = faction()
    if taxi then
        for id, n in pairs(taxi.nodes) do
            local name, cont, wx, wy, f = n[1], n[2], n[3], n[4], n[5]
            if f == "N" or f == fac then
                local node = newNode("taxi", cont, wx, wy, name)
                node.taxiID = id
                TG.taxiByID[id] = node
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
                local a = newNode("transit", ai, ax, ay, t.from[1]); a.mode = t.mode
                local b = newNode("transit", bi, bx, by, t.to[1]); b.mode = t.mode
                addEdge(a, b, t.cost, t.mode, t.title, t)
                if t.twoway ~= false then addEdge(b, a, t.cost, t.mode, t.title, t) end
            else missing = missing + 1 end
        end
    end
    TG.built = true
    NS:Debug(("TravelGraph: %d nodes, %d transit entries unresolved"):format(#TG.nodes, missing))
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
    if cfg().assumeAllTaxi then return true end
    return NS.db.char.knownTaxi[node.taxiID] == true
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
            if not NS.db.char.knownTaxi[n.nodeID] then learned = learned + 1 end
            NS.db.char.knownTaxi[n.nodeID] = true
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

-- every continent we have taxi data for, so a login harvest covers the whole world
local function continentMaps()
    local out, seen = {}, {}
    local map = U.PlayerPos()
    local info = map and C_Map.GetMapInfo(map)
    while info and info.mapType and info.mapType > 2 and info.parentMapID and info.parentMapID > 0 do
        info = C_Map.GetMapInfo(info.parentMapID)
    end
    if info and not seen[info.mapID] then out[#out + 1] = info.mapID seen[info.mapID] = true end
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
    -- classic clients: while a flight master's map is open the legacy API lists your nodes
    if NumTaxiNodes and TaxiNodeGetType then
        for i = 1, (NumTaxiNodes() or 0) do
            local t = TaxiNodeGetType(i)
            if t == "REACHABLE" or t == "CURRENT" then
                local nm = TaxiNodeName and TaxiNodeName(i)
                if nm then
                    local node = TG.NodeByName and TG.NodeByName(nm)
                    if node and node.taxiID and not NS.db.char.knownTaxi[node.taxiID] then
                        NS.db.char.knownTaxi[node.taxiID] = true
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
        if n == 0 and not NS.db.char.taxiHintShown then
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
-- Dijkstra
-- ---------------------------------------------------------------------------
local function walkCost(ax, ay, bx, by, speed)
    local d = dist(ax, ay, bx, by)
    return d * (cfg().terrainFactor or 1.25) / speed, d
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
function TG.FindPath(sx, sy, sinst, gx, gy, ginst, opts)
    if not TG.built then TG.Build() end
    if not (sx and gx and sinst and ginst) then return nil end
    opts = opts or {}
    local c = cfg()
    local speed = opts.speed or U.TravelSpeed()
    local useHearth = (opts.hearth == nil) and (c.hearth ~= false) or opts.hearth
    local useTaxi = (opts.taxi == nil) and (c.taxi ~= false) or opts.taxi
    local useTransit = (opts.transit == nil) and (c.transit ~= false) or opts.transit

    local start = { id = "start", kind = "start", inst = sinst, wx = sx, wy = sy, name = "You", edges = {} }
    local goal = { id = "goal", kind = "goal", inst = ginst, wx = gx, wy = gy, name = "Destination", edges = {} }
    -- direct walk
    local best
    if sinst == ginst then
        local wc, d = walkCost(sx, sy, gx, gy, speed)
        best = { cost = wc, legs = { { mode = "walk", from = start, to = goal, cost = wc, dist = d } } }
        if d < 300 then return best end   -- nothing beats walking 300 yards
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
    -- Dijkstra over: start, goal, hearth nodes, all graph nodes
    local nodes = TG.nodes
    local INF = math.huge
    local d, prev, prevEdge, closed = {}, {}, {}, {}
    local heap = newHeap()
    d[start] = 0
    heap:push(0, start)
    local function relaxWalk(u, du)
        -- walk to every node in same instance (lazy complete graph)
        for i = 1, #nodes do
            local v = nodes[i]
            if v.inst == u.inst and v ~= u and not closed[v] then
                local usable = (v.kind ~= "taxi") or (useTaxi and TG.IsTaxiKnown(v))
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
            if iterations > 5000 then break end
            -- explicit edges
            for _, e in ipairs(u.edges) do
                local v = e.to
                local ok = true
                if e.mode == "taxi" and (not useTaxi or not TG.IsTaxiKnown(u) or not TG.IsTaxiKnown(v)) then ok = false end
                if (v.kind == "transit") and not useTransit and e.mode ~= "hearth" then ok = false end
                if ok and not closed[v] then
                    local nd = du + e.cost
                    if nd < (d[v] or INF) then d[v] = nd prev[v] = u prevEdge[v] = e heap:push(nd, v) end
                end
            end
            -- walking from here (start walks too; from a taxi node you can walk anywhere on the continent)
            relaxWalk(u, du)
        end
    end
    if not d[goal] then return best end
    if best and best.cost <= d[goal] + 1 then return best end
    -- rebuild path
    local legs = {}
    local v = goal
    while prev[v] do
        local e = prevEdge[v]
        tinsert(legs, 1, { mode = e.mode, from = prev[v], to = v, cost = e.cost, title = e.title, data = e.data, dist = e.dist })
        v = prev[v]
    end
    -- merge consecutive walk legs
    local merged = {}
    for _, l in ipairs(legs) do
        local last = merged[#merged]
        if last and last.mode == "walk" and l.mode == "walk" then last.to = l.to last.cost = last.cost + l.cost last.dist = (last.dist or 0) + (l.dist or 0)
        else merged[#merged + 1] = l end
    end
    return { cost = d[goal], legs = merged }
end

-- Human readable description of a path
function TG.Describe(path)
    if not path then return "no route" end
    local out = {}
    for _, l in ipairs(path.legs) do
        if l.mode == "walk" then out[#out + 1] = ("Walk %s to %s"):format(U.FmtDist(l.dist), l.to.name or "?")
        elseif l.mode == "taxi" then out[#out + 1] = ("Fly %s -> %s"):format(l.from.name, l.to.name)
        elseif l.mode == "hearth" then out[#out + 1] = l.title
        else out[#out + 1] = l.title or (l.mode .. " to " .. (l.to.name or "?")) end
    end
    return table.concat(out, "; ") .. (" (~%s)"):format(U.FmtTime(path.cost))
end

NS:On("ADDON_READY", function() NS:After(0.5, function() pcall(TG.Build) end) end)
