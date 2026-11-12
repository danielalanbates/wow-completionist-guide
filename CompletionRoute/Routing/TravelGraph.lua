-- CompletionRoute :: Routing/TravelGraph.lua
-- The travel-system graph (written from scratch, open data):
--   nodes  = flight masters (from wago.tools TaxiNodes), transit endpoints (boats/zeppelins/portals/trams),
--            the character's hearth location, plus a virtual start (player) and goal.
--   edges  = taxi flights (real polyline lengths), transit rides, hearth (cast + cooldown), class teleports, hearth
--            toys and engineering transporters (Data/Teleports.lua, Routing/Teleports.lua), and implicit
--            straight-line walking between any two nodes on the same continent instance.
-- Dijkstra over that graph gives the cheapest (in seconds) way from A to B: this is what powers
-- "hearth when it's faster", "fly from X to Y", "take the boat", and the step-order optimizer.
--
-- What invalidates what (kept costs are expensive to rebuild: a 24-step window holds up to 552 pair costs):
--   * an access chain unlocks (its unlock quest is turned in)  -> the access edges are rebuilt, the path cache is wiped
--   * a flight path is learned                                  -> the path cache is wiped (TG.TaxiChanged)
--   * the hearth is re-bound, a teleport or hearth item becomes  -> only costs FROM the player are dropped
--     (un)available                                                (TG.oneShotGen, read by Routing/StepOrder.lua)
--   * any other quest turn-in                                   -> nothing
local ADDON, NS = ...
local U, HBD = NS.Util, NS.HBD
local TG = {}
NS.TravelGraph = TG

TG.nodes = {}          -- array of nodes
TG.taxiByID = {}       -- taxiNodeID -> node
TG.built = false
-- profiling counters (cheap; read by tools/route_sweep.lua); builds / accessRebuilds count graph (re)builds
TG.stats = { calls = 0, pops = 0, relax = 0, capped = 0, skipped = 0, builds = 0, accessRebuilds = 0 }

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
-- (static data: Inns, Transit, Roads - written on Era maps, so Forever converts reshaped maps first)
local function zoneToWorld(zoneName, x, y)
    local mapID = U.MapIDByName(zoneName)
    if not mapID then return nil end
    local x01, y01 = U.EraToForever(mapID, x / 100, y / 100)
    return HBD:GetWorldCoordinatesFromZone(x01, y01, mapID)
end
TG.zoneToWorld = zoneToWorld

-- ---------------------------------------------------------------------------
-- Build static part of the graph (taxi + transit)
-- ---------------------------------------------------------------------------
-- Quests turned in this session: the completed-quest flag can lag the QUEST_TURNED_IN event by a moment.
TG.turnedIn = {}
local function questDone(q)
    if TG.turnedIn[q] then return true end
    return (C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted and C_QuestLog.IsQuestFlaggedCompleted(q)) and true or false
end
TG.QuestDone = questDone
function TG.AccessUnlocked(a)
    if not a.unlock then return false end
    for _, q in ipairs(a.unlock) do
        if questDone(q) then return true end
    end
    return false
end

-- `cond` on a Data/Transit.lua, Data/Access.lua or Data/Teleports.lua entry: the edge exists only for characters it
-- holds for.  Either a function (NS) -> bool, or a table whose every key must hold:
--   class = "MAGE" or { MAGE = true, ... }   race = "Human" or { ... }   level = minimum level
--   quest = id or { ids } (any one turned in)  notQuest = id or { ids } (none turned in)
--   spell = id (known)   item = id (in the bags)   toy = id (in the toy box)
local function oneOf(want, have)
    if type(want) == "table" then return want[have] and true or false end
    return want == have
end
local function anyQuest(q)
    if type(q) ~= "table" then return questDone(q) end
    for _, id in ipairs(q) do if questDone(id) then return true end end
    return false
end
function TG.CondOK(cond)
    if cond == nil then return true end
    if type(cond) == "function" then
        local ok, v = pcall(cond, NS)
        return ok and v and true or false
    end
    if type(cond) ~= "table" then return true end
    local p = NS.player or {}
    if cond.class and not oneOf(cond.class, p.class) then return false end
    if cond.race and not oneOf(cond.race, p.race) then return false end
    if cond.level and ((UnitLevel and UnitLevel("player")) or 0) < cond.level then return false end
    if cond.quest and not anyQuest(cond.quest) then return false end
    if cond.notQuest and anyQuest(cond.notQuest) then return false end
    if cond.spell and not U.SpellKnown(cond.spell) then return false end
    if cond.item and not U.HasItem(cond.item) then return false end
    if cond.toy and not U.HasToy(cond.toy) then return false end
    return true
end
-- quest ids a `cond` reads (a turn-in of one of them changes the graph)
local function condQuests(cond, into)
    if type(cond) ~= "table" then return end
    for _, k in ipairs({ "quest", "notQuest" }) do
        local q = cond[k]
        if type(q) == "table" then for _, id in ipairs(q) do into[id] = true end elseif q then into[q] = true end
    end
end
-- a cond that can change during play without a turn-in (spell learned, item looted, level gained, or a function)
local function condDynamic(cond)
    return type(cond) == "function" or (type(cond) == "table" and (cond.spell or cond.item or cond.toy or cond.level)) and true or false
end

-- A turn-in changes the graph only when it unlocks an access chain or flips a quest `cond`: then the access and
-- transit edges are rebuilt and the kept costs dropped.  Any other turn-in keeps everything (the old rule rebuilt the
-- whole graph after every turn-in, and StepOrder then recomputed every kept pair cost).
TG.unlockQuests = {}   -- [questID] = true, filled by TG.Build
function TG.OnQuestTurnedIn(questID)
    if not questID then return false end
    TG.turnedIn[questID] = true
    local what = TG.unlockQuests[questID]
    if what == "access" then TG.accessDirty = true return true end
    if what then TG.built = false return true end     -- a transit `cond` reads it: full (lazy) rebuild
    -- a one-shot (teleport) cond may read it: work out what is usable again now (no bag, spell or cooldown event follows
    -- a turn-in); T.Recheck bumps oneShotGen when what is offered changed, so only the costs from the player are re-priced
    if NS.Teleports and NS.Teleports.QuestMatters and NS.Teleports.QuestMatters(questID) then NS.Teleports.Recheck() end
    return false
end
if NS.RegisterEvent then NS:RegisterEvent("QUEST_TURNED_IN", function(_, questID) TG.OnQuestTurnedIn(questID) end) end

-- Costs FROM the player (hearth, teleports) depend on one-shot state: bump this and StepOrder drops only those.
TG.oneShotGen = 0
function TG.OneShotChanged()
    TG.oneShotGen = TG.oneShotGen + 1
    if NS.Router and NS.Router.Invalidate then NS.Router.Invalidate() end
end
-- A flight path was learned: pair costs may change (taxi policy "known"), so the path cache goes, and with it
-- StepOrder's kept costs.  The graph itself stays: every flight master of the faction is already a node.
function TG.TaxiChanged()
    TG.PathCacheWipe()
    if NS.Router and NS.Router.Invalidate then NS.Router.Invalidate() end
end
-- spells learned, items looted, a level gained: a transit/access `cond` of that kind may have flipped
function TG.RecheckConds()
    if not TG.built or not TG.condEntries or #TG.condEntries == 0 then return end
    for _, e in ipairs(TG.condEntries) do
        if TG.CondOK(e.row.cond) ~= e.ok then TG.built = false return end
    end
end
if NS.RegisterEvent then
    for _, ev in ipairs({ "SPELLS_CHANGED", "BAG_UPDATE_DELAYED", "PLAYER_LEVEL_UP", "NEW_TOY_ADDED" }) do
        NS:RegisterEvent(ev, function() if NS.Throttle then NS:Throttle("tg-conds", 1, TG.RecheckConds) else TG.RecheckConds() end end)
    end
end

-- Known internal DB2 nodes that are not open-world player flight masters
local TAXI_BLACKLIST = {
    [2084] = true, -- Norwington Estate carriage quest script
    [3] = true,    -- Programmer Isle
}

-- Access chains (Data/Access.lua): a one-way edge into a place an intro quest line unlocks. Locked -> the edge starts
-- where the chain starts and costs the whole chain; unlocked -> the cheap `after` edge (portal, airship...). Progress
-- injects the chain's steps in front of a guide whose step 1 is behind a locked one.  Returns the unresolved count.
local function buildAccess(flavor, fac)
    TG.accessEdges = {}
    local missing = 0
    for _, a in ipairs(NS.AccessData or {}) do
        local okFlavor = (not a.flavors) or a.flavors[flavor]
        local okFac = (not a.fac) or a.fac == fac
        if okFlavor and okFac then
            for _, q in ipairs(a.unlock or {}) do TG.unlockQuests[q] = TG.unlockQuests[q] or "access" end
            local cq = {}
            condQuests(a.cond, cq)
            for q in pairs(cq) do TG.unlockQuests[q] = TG.unlockQuests[q] or "access" end
            local condOK = TG.CondOK(a.cond)
            if a.cond and condDynamic(a.cond) then TG.condEntries[#TG.condEntries + 1] = { row = a, ok = condOK, access = true } end
            if condOK then
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
    end
    return missing
end

-- Rebuild only the access edges (an unlock quest was turned in): drop the access nodes, add them again in their new
-- state, re-index.  Taxi, transit and road nodes stay as they are.
function TG.RebuildAccess()
    if not TG.nodes or #TG.nodes == 0 then return TG.Build() end
    local keep = {}
    for _, n in ipairs(TG.nodes) do if n.mode ~= "access" then keep[#keep + 1] = n end end
    TG.nodes = keep
    for i, n in ipairs(TG.nodes) do n.id = i end
    local kept = {}
    for _, e in ipairs(TG.condEntries or {}) do if not e.access then kept[#kept + 1] = e end end
    TG.condEntries = kept
    buildAccess(NS.flavor, faction())
    TG.Index()
    TG.built, TG.accessDirty = true, false
    TG.stats.accessRebuilds = (TG.stats.accessRebuilds or 0) + 1
end
-- the graph as the next search needs it: a full build, or only the access edges after an unlock
function TG.Ensure()
    if not TG.built then TG.Build() elseif TG.accessDirty then TG.RebuildAccess() end
end

function TG.Build()
    TG.nodes, TG.taxiByID, TG.unresolved = {}, {}, {}
    TG.unlockQuests, TG.condEntries, TG.accessDirty = {}, {}, false
    TG.stats.builds = (TG.stats.builds or 0) + 1
    local flavor = NS.flavor
    -- Forever has its own taxi network (Data/Taxi_forever.lua); era data is the fallback
    local taxi = NS.TaxiData and (NS.TaxiData[NS.dataFlavor or flavor] or NS.TaxiData[flavor] or NS.TaxiData.tbc)
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
        local okCond = true
        if okFlavor and okFac and t.cond then
            local cq = {}
            condQuests(t.cond, cq)
            for q in pairs(cq) do TG.unlockQuests[q] = "full" end     -- a turn-in of one of them rebuilds the graph
            okCond = TG.CondOK(t.cond)
            if condDynamic(t.cond) then TG.condEntries[#TG.condEntries + 1] = { row = t, ok = okCond } end
        end
        if okFlavor and okFac and okCond then
            local ax, ay, ai = zoneToWorld(t.from[1], t.from[2], t.from[3])
            local bx, by, bi = zoneToWorld(t.to[1], t.to[2], t.to[3])
            -- a spot learned by actually taking this portal beats the hand-typed (+-2%) coordinate
            local fix = NS.db and NS.db.global.transitFix and NS.db.global.transitFix[t.title or ""]
            if fix and ax and fix.from and fix.from[3] == ai then ax, ay = fix.from[1], fix.from[2] end
            if fix and bx and fix.to and fix.to[3] == bi then bx, by = fix.to[1], fix.to[2] end
            if ax and bx then
                local a = newNode("transit", ai, ax, ay, t.from.name or t.from[1]); a.mode = t.mode
                local b = newNode("transit", bi, bx, by, t.to.name or t.to[1]); b.mode = t.mode
                addEdge(a, b, t.cost, t.mode, t.title, t)
                if t.twoway ~= false then addEdge(b, a, t.cost, t.mode, t.title, t) end
            else missing = missing + 1 TG.unresolved = TG.unresolved or {} TG.unresolved[#TG.unresolved + 1] = (t.title or "?") .. " [" .. tostring(ax and "" or t.from[1]) .. (bx and "" or (" " .. tostring(t.to[1]))) .. "]" end
        end
    end
    missing = missing + buildAccess(flavor, fac)
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

-- Flight paths are shared between characters only on retail and WoW Forever (Core/Init.lua NS.taxiShared). Everywhere
-- else each character has its own: the account-wide set (CompletionRouteDB.knownTaxi) is kept but not routed on.
function TG.TaxiShared()
    if NS.taxiShared ~= nil then return NS.taxiShared end
    return NS.flavor == "retail" or NS.isForever or false
end
function TG.IsTaxiKnownID(id)
    if not id then return false end
    if NS.db and NS.db.char and NS.db.char.knownTaxi and NS.db.char.knownTaxi[id] then return true end
    if TG.TaxiShared() and NS.db and NS.db.global and NS.db.global.knownTaxi and NS.db.global.knownTaxi[id] then return true end
    return false
end
function TG.IsTaxiKnown(node) return (node and TG.IsTaxiKnownID(node.taxiID)) or false end
-- "known" (default): a flight leg u -> v needs v discovered by this character (account-wide where the client shares
-- flight paths).  u may be new: walking to a flight master discovers it, so the route may walk there, pick it up and
-- fly on - that walk leg is labelled "pick up the flight path".  Every hop of a multi-hop flight lands on a node,
-- so each one must be known, exactly as in the client.  "faction": every flight master the faction can use, discovered
-- or not (the old default; an undiscovered destination is labelled "(new flight path)").  assumeAllTaxi (offline
-- harnesses) and an unset policy (an NS.db built by hand) mean "faction"; Core/Init.lua's default is "known".
function TG.TaxiPolicy()
    local c = cfg()
    if c.assumeAllTaxi then return "faction" end
    if c.taxiPolicy == "known" then return "known" end
    return "faction"
end
-- may the route fly INTO this node?
function TG.TaxiUsable(node)
    if TG.TaxiPolicy() == "faction" then return true end
    return TG.IsTaxiKnown(node)
end
local function markKnown(id)
    if not id then return false end
    local new = not (NS.db and NS.db.char and NS.db.char.knownTaxi and NS.db.char.knownTaxi[id])
    if NS.db and NS.db.char then
        NS.db.char.knownTaxi = NS.db.char.knownTaxi or {}
        NS.db.char.knownTaxi[id] = true
    end
    if NS.db and NS.db.global then
        NS.db.global.knownTaxi = NS.db.global.knownTaxi or {}
        NS.db.global.knownTaxi[id] = true
    end
    return new
end
TG.MarkTaxiKnown = markKnown
-- Harvesting flight paths ONLY when the player opens a flight master's map meant a character
-- who had not done that this session routed with zero flights - the arrow then points in a
-- straight line across the world instead of "fly Stormwind -> Morgan's Vigil". The game already
-- knows which nodes you have; ask it for every continent at login, and support the classic
-- taxi API too (C_TaxiMap does not exist on every client).
--   C_TaxiMap.GetAllTaxiNodes (flight map open): entries carry `state` (Current / Reachable / Unreachable)
--   C_TaxiMap.GetTaxiNodesForMap (world map data, any time): entries carry `isUndiscovered` where the client has it;
--     only an explicit false counts, an entry without the field says nothing about this character
local function harvestList(list)
    local learned = 0
    local unreachable = (Enum and Enum.FlightPathState and Enum.FlightPathState.Unreachable) or 2
    for _, n in ipairs(list or {}) do
        local known = n.nodeID and ((n.state ~= nil and n.state ~= unreachable) or (n.state == nil and n.isUndiscovered == false))
        if known and markKnown(n.nodeID) then learned = learned + 1 end
    end
    return learned
end

local function harvestMap(mapID)
    if not (C_TaxiMap and mapID) then return 0 end
    local n = 0
    if C_TaxiMap.GetAllTaxiNodes then
        local ok, list = pcall(C_TaxiMap.GetAllTaxiNodes, mapID)
        if ok then n = n + harvestList(list) end
    end
    if C_TaxiMap.GetTaxiNodesForMap then
        local ok, list = pcall(C_TaxiMap.GetTaxiNodesForMap, mapID)
        if ok then n = n + harvestList(list) end
    end
    return n
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
    learned = learned + harvestMap(map)
    for _, m in ipairs(continentMaps()) do learned = learned + harvestMap(m) end
    -- retail FlightMapFrame pin harvest
    if FlightMapFrame and FlightMapFrame.pinPools and FlightMapFrame.pinPools.FlightMap_FlightPointPinTemplate then
        local unreachable = (Enum and Enum.FlightPathState and Enum.FlightPathState.Unreachable) or 2
        for pin in FlightMapFrame.pinPools.FlightMap_FlightPointPinTemplate:EnumerateActive() do
            local d = pin.taxiNodeData
            if d and d.nodeID and d.state ~= nil and d.state ~= unreachable and markKnown(d.nodeID) then learned = learned + 1 end
        end
    end
    -- classic clients: while a flight master's map is open the legacy API lists your nodes
    if NumTaxiNodes and TaxiNodeGetType then
        for i = 1, (NumTaxiNodes() or 0) do
            local t = TaxiNodeGetType(i)
            if t == "REACHABLE" or t == "CURRENT" then
                local nm = TaxiNodeName and TaxiNodeName(i)
                local node = nm and TG.NodeByName and TG.NodeByName(nm)
                if node and node.taxiID and markKnown(node.taxiID) then learned = learned + 1 end
            end
        end
    end
    if learned > 0 then
        TG.TaxiChanged()
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
        if TG.TaxiShared() then for _ in pairs(NS.db.global.knownTaxi or {}) do n = n + 1 end end
        if n == 0 and TG.TaxiPolicy() == "known" and not NS.db.char.taxiHintShown then
            NS.db.char.taxiHintShown = true
            NS:Print("|cffff9900No flight paths known yet|r - open a flight master's map once on each continent and I can route you by air. Until then the route walks, and picks up flight masters on the way. (/cr taxi)")
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
        local old = NS.db.char.bind
        NS.db.char.bind = { wx = wx, wy = wy, inst = inst, map = map, x = x, y = y, name = GetBindLocation and GetBindLocation() or "Home" }
        NS:Debug("Hearth location recorded: " .. tostring(NS.db.char.bind.name))
        -- a new home moves every hearth-first route (costs from the player); pair costs never use the hearth
        if not old or old.inst ~= inst or dist(old.wx, old.wy, wx, wy) > 30 then TG.OneShotChanged() end
    end
end
TG.RecordBindHere = recordBindHere
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
    if unit == "player" and (spellID == NS.HEARTH_SPELL or spellID == NS.ASTRAL_RECALL
                             or (NS.Teleports and NS.Teleports.IsHearthSpell(spellID))) then hearthPending = true end
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
-- roadFactor (1.0) instead of the off-road terrainFactor (Routing/CostModel.lua TERRAIN), so Dijkstra prefers the road
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
-- tf: the walking factor, fixed once per search (TG.WalkFactor)
local function walkCost(ax, ay, bx, by, speed, tf)
    local d = dist(ax, ay, bx, by)
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

-- opts.tick (optional): called after every node the search settles.  The quest-skip re-planner (Routing/Replan.lua)
-- runs inside a coroutine and passes a tick that yields when its frame budget is spent, so one long search (a retail
-- continent is ~700 pops, tens of ms in plain Lua) is spread over several frames.  A search that yielded does not
-- write its answer into the path cache if the graph was rebuilt while it waited.
function TG.FindPath(sx, sy, sinst, gx, gy, ginst, opts)
    TG.stats.calls = TG.stats.calls + 1
    TG.Ensure()
    if not (sx and gx and sinst and ginst) then return nil end
    opts = opts or {}
    local tick, cache0 = opts.tick, TG.pathCache
    local c = cfg()
    local speed = opts.speed or U.TravelSpeed()
    local tf = TG.WalkFactor()
    local useHearth = (opts.hearth == nil) and (c.hearth ~= false) or opts.hearth
    local useTaxi = (opts.taxi == nil) and (c.taxi ~= false) or opts.taxi
    local useTransit = (opts.transit == nil) and (c.transit ~= false) or opts.transit
    -- teleports are one-shot resources like the hearth: never on a pairwise (hearth = false) query
    local useTele = ((opts.teleports == nil) and (opts.hearth ~= false) and (c.teleports ~= false) and NS.Teleports ~= nil)
                    or (opts.teleports == true and NS.Teleports ~= nil)
    local ckey
    if not useHearth and not useTele then
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
        local wc, d = walkCost(sx, sy, gx, gy, speed, tf)
        best = { cost = wc, legs = { { mode = "walk", from = start, to = goal, cost = wc, dist = d } } }
        if d < 300 then return TG.PathCacheStore(ckey, best) end   -- nothing beats walking 300 yards
    end
    -- hearth virtual node
    local hearthNodes = {}
    if useHearth then
        local hx, hy, hinst, hname = TG.HearthWorld()
        if hx then
            local ready, cd, kind, id, isToy = U.HearthReady()
            local aready, acd, akind, aid = U.AstralRecallReady()
            local function hnode(cdleft, k, i, label, toy)
                if cdleft > 15 * 60 then return end
                local hn = { id = "hearth" .. k, kind = "hearth", inst = hinst, wx = hx, wy = hy, name = hname or "Home", edges = {} }
                local cost = (c.hearthCost or NS.CostModel.HEARTH) + cdleft
                addEdge(start, hn, cost, "hearth", label .. " to " .. (hname or "your inn"), { kind = k, id = i, cd = cdleft, toy = toy })
                hearthNodes[#hearthNodes + 1] = hn
            end
            -- the Hearthstone, or (not in the bags) a hearthstone toy on the same cooldown
            if id then hnode(cd, "item", id, (id == NS.HEARTH_ITEM) and "Hearth" or ("Hearth (" .. U.ItemName(id) .. ")"), isToy) end
            if akind then hnode(acd, "spell", NS.ASTRAL_RECALL, "Astral Recall") end
        end
    end
    -- teleports (Routing/Teleports.lua): a spell this character knows, or an item or toy it owns, whose cooldown has
    -- at most 15 minutes left (the hearth's rule): an edge from here to its fixed landing point.  The hearth cost
    -- (60 s) holds a 10 s cast; a teleport pays the same overhead with its own cast time, plus the cooldown left.
    if useTele then
        for _, a in ipairs(NS.Teleports.Available()) do
            if a.inst and a.cd <= 15 * 60 then
                local tn = { id = "tele:" .. a.key, kind = "teleport", inst = a.inst, wx = a.wx, wy = a.wy, name = a.dest, edges = {} }
                local cost = (c.hearthCost or NS.CostModel.HEARTH) - 10 + (a.cast or 10) + a.cd
                addEdge(start, tn, cost, "teleport", a.title, { kind = (a.kind == "spell") and "spell" or "item", id = a.id,
                                                               toy = (a.kind == "toy"), cd = a.cd, key = a.key })
                hearthNodes[#hearthNodes + 1] = tn
            end
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
        local wc, dd = walkCost(u.wx, u.wy, v.wx, v.wy, speed, tf)
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
                -- any flight master may be walked to (that is how a new one is discovered); flying INTO one is the rule
                local usable = (v.kind ~= "taxi") or useTaxi
                if v.kind == "transit" and not useTransit then usable = false end
                if usable then
                    local wc, dd = walkCost(u.wx, u.wy, v.wx, v.wy, speed, tf)
                    local nd = du + wc
                    if nd < (d[v] or INF) then d[v] = nd prev[v] = u prevEdge[v] = { mode = "walk", cost = wc, dist = dd } heap:push(nd, v) end
                end
            end
        end
        if goal.inst == u.inst and u ~= start then
            local wc, dd = walkCost(u.wx, u.wy, goal.wx, goal.wy, speed, tf)
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
            if tick then tick() end
            if iterations > 20000 then TG.stats.capped = TG.stats.capped + 1 break end
            -- explicit edges
            for _, e in ipairs(u.edges) do
                local v = e.to
                local ok = true
                if e.mode == "taxi" and (not useTaxi or not TG.TaxiUsable(v)) then ok = false end
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
    -- a ticked search may have waited across a graph rebuild: answer, but keep it out of the new cache
    if tick and TG.pathCache ~= cache0 then ckey = nil end
    if not d[goal] then return TG.PathCacheStore(ckey, best) end
    if best and best.cost <= d[goal] + 1 then return TG.PathCacheStore(ckey, best) end
    -- rebuild path
    local legs = {}
    local v = goal
    while prev[v] do
        local e = prevEdge[v]
        local leg = { mode = e.mode, from = prev[v], to = v, cost = e.cost, title = e.title, data = e.data, dist = e.dist }
        if e.mode == "road" then leg.mode = "walk" leg.road = true leg.dist = e.data.dist leg.cost = d[v] - d[prev[v]] end
        if e.mode == "taxi" then
            leg.discover = not TG.IsTaxiKnown(v)          -- "faction" policy: landing at a flight master never discovered
            if leg.discover then leg.title = leg.title .. " (new flight path)" end
            leg.pickup = not TG.IsTaxiKnown(prev[v])      -- taking off from one: walking there discovers it
        end
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
    -- the walk onto a flight master the character has not discovered yet is where it gets picked up
    for i, l in ipairs(merged) do
        if l.mode == "taxi" and l.pickup then
            local w = merged[i - 1]
            if w and w.mode == "walk" then
                w.pickup = true
                w.title = "Walk to " .. (l.from.name or "the flight master") .. " and pick up the flight path"
            else l.pickup = nil end
        end
    end
    return TG.PathCacheStore(ckey, { cost = d[goal], legs = merged })
end

-- ---------------------------------------------------------------------------
-- One source, many goals (the quest-skip re-planner's cost rows, Routing/Replan.lua)
-- ---------------------------------------------------------------------------
-- The graph as it is now, for a job that runs over many frames: the node lists, the road grid, continent connectivity,
-- the routing settings and which flight masters may be used.  TravelGraph.Build replaces these tables (a quest turn-in,
-- a learned flight path), so a job priced on one snapshot never mixes costs from two graphs.
function TG.Snapshot()
    TG.Ensure()
    local c = cfg()
    local snap = { nodes = TG.nodes, byInst = TG.byInst or {}, roadGrid = TG.roadGrid, instFind = TG.instFind, instComp = TG.instComp,
                   useTaxi = c.taxi ~= false, useTransit = c.transit ~= false, roadFactor = c.roadFactor or 1.0,
                   preferTaxi = c.preferTaxi and true or false }
    if TG.TaxiPolicy() ~= "faction" then
        local ok = {}
        for _, n in ipairs(TG.nodes) do if n.kind == "taxi" or n.taxiID then ok[n] = TG.TaxiUsable(n) and true or false end end
        snap.taxiOK = ok
    end
    return snap
end
-- the off-road walking factor FindPath uses (flying flattens the terrain; Routing/CostModel.lua)
function TG.WalkFactor()
    local fly = (U.CanFly and U.CanFly()) and true or false
    return NS.CostModel.WalkFactor(fly, cfg().terrainFactor)
end

local function snapReachable(gr, a, b)
    if a == b then return true end
    if not gr.instFind then return true end
    if not gr.instComp[a] or not gr.instComp[b] then return false end
    return gr.instFind(a) == gr.instFind(b)
end

-- FindPaths(sx, sy, sinst, goals, opts, out) -> out[i] = seconds to goals[i] ({wx, wy, inst}), nil = no route.
-- Exactly what FindPath(..., { hearth = false }) costs for each goal one by one (tools/test_skip.lua checks it), from ONE
-- search: every goal is a node of it, reached by walking from any graph node on its continent, and the search stops
-- when the last goal is settled.  opts: speed (yd/s), walkFactor (TG.WalkFactor), graph (TG.Snapshot), tick (called
-- after every settled node and every 64 walking links: the re-planner yields from it), scratch (a table the caller keeps
-- between searches: the search's own tables are reused instead of grown afresh, so the Lua collector has less to do in
-- the frames a job runs in).  Allocates no per-link tables.
function TG.FindPaths(sx, sy, sinst, goals, opts, out)
    opts = opts or {}
    out = out or {}
    local gr = opts.graph or TG.Snapshot()
    local tick = opts.tick
    local speed = opts.speed or U.TravelSpeed()
    local tf = opts.walkFactor or TG.WalkFactor()
    local k = tf / speed
    local sqrt = math.sqrt
    local useTaxi, useTransit, roadFactor, taxiOK = gr.useTaxi, gr.useTransit, gr.roadFactor, gr.taxiOK
    -- goals: the direct walk, and the ones the graph has to answer
    local best, gnodes, byInstG, pending = {}, {}, {}, 0
    for i = 1, #goals do
        local g = goals[i]
        out[i] = nil
        if g and g.inst and sinst then
            local b
            if g.inst == sinst then
                local dx, dy = sx - g.wx, sy - g.wy
                local d = sqrt(dx * dx + dy * dy)
                b = d * k
                if d < 300 then out[i] = b b = nil best[i] = false end   -- nothing beats walking 300 yards
            end
            if best[i] == nil then
                best[i] = b or false
                if snapReachable(gr, sinst, g.inst) then
                    local gn = { goal = i, inst = g.inst, wx = g.wx, wy = g.wy }
                    gnodes[i] = gn
                    local l = byInstG[g.inst] if not l then l = {} byInstG[g.inst] = l end
                    l[#l + 1] = gn
                    pending = pending + 1
                else
                    out[i] = b
                end
            end
        end
    end
    if pending > 0 then
        local INF = math.huge
        local start = { inst = sinst, wx = sx, wy = sy, edges = {} }
        local sc = opts.scratch
        if sc and sc.busy then sc = nil end
        local d, closed, hc, hn, seen
        if sc then
            sc.busy = true
            sc.d, sc.closed, sc.hc, sc.hn, sc.seen = sc.d or {}, sc.closed or {}, sc.hc or {}, sc.hn or {}, sc.seen or {}
            d, closed, hc, hn, seen = sc.d, sc.closed, sc.hc, sc.hn, sc.seen
        else
            d, closed, hc, hn, seen = {}, {}, {}, {}, {}
        end
        local ns = 1
        d[start], seen[1] = 0, start
        -- binary heap over parallel arrays
        local hs = 1
        hc[1], hn[1] = 0, start
        local function push(cost, node)
            hs = hs + 1
            local i = hs
            while i > 1 do
                local p = (i - i % 2) / 2
                if hc[p] <= cost then break end
                hc[i], hn[i] = hc[p], hn[p]
                i = p
            end
            hc[i], hn[i] = cost, node
        end
        local function pop()
            if hs == 0 then return nil end
            local tc, tn = hc[1], hn[1]
            local lc, ln = hc[hs], hn[hs]
            hc[hs], hn[hs] = nil, nil
            hs = hs - 1
            if hs > 0 then
                local i = 1
                while true do
                    local l = 2 * i
                    if l > hs then break end
                    local r = l + 1
                    if r <= hs and hc[r] < hc[l] then l = r end
                    if hc[l] >= lc then break end
                    hc[i], hn[i] = hc[l], hn[l]
                    i = l
                end
                hc[i], hn[i] = lc, ln
            end
            return tc, tn
        end
        local function relax(v, nd)
            local old = d[v]
            if old == nil then ns = ns + 1 seen[ns] = v d[v] = nd push(nd, v)
            elseif nd < old then d[v] = nd push(nd, v) end
        end
        local iterations = 0
        while pending > 0 do
            local du, u = pop()
            if not u then break end
            if not closed[u] then
                closed[u] = true
                if u.goal then
                    pending = pending - 1
                else
                    iterations = iterations + 1
                    if tick then tick() end
                    if iterations > 20000 then break end
                    -- explicit edges (taxi, transit, roads)
                    local edges = u.edges
                    for e = 1, #edges do
                        local ed = edges[e]
                        local v = ed.to
                        local ok = true
                        -- as FindPath: flying INTO an undiscovered flight master is the rule; taking off from one is fine
                        if ed.mode == "taxi" and (not useTaxi or (taxiOK and not taxiOK[v])) then ok = false end
                        if v.kind == "transit" and not useTransit and ed.mode ~= "hearth" then ok = false end
                        if ok and not closed[v] then
                            local ecost = ed.cost
                            if ed.mode == "road" then ecost = ed.data.dist * (ed.data.factor or roadFactor) / speed end
                            if ed.mode == "taxi" and gr.preferTaxi then ecost = ecost * 0.6 end
                            relax(v, du + ecost)
                        end
                    end
                    local ux, uy, ui = u.wx, u.wy, u.inst
                    -- nearby road vertices (3x3 grid cells, as TravelGraph.RoadNear)
                    local grid = gr.roadGrid and gr.roadGrid[ui]
                    if grid then
                        local cx, cy = math.floor(ux / 1500), math.floor(uy / 1500)
                        for dx = -1, 1 do
                            for dy = -1, 1 do
                                local cell = grid[(cx + dx) .. ":" .. (cy + dy)]
                                if cell then
                                    for i = 1, #cell do
                                        local v = cell[i]
                                        if v ~= u and not closed[v] then
                                            local ax, ay = ux - v.wx, uy - v.wy
                                            relax(v, du + sqrt(ax * ax + ay * ay) * k)
                                        end
                                    end
                                end
                            end
                        end
                    end
                    -- walk to every other node on this continent
                    local same = gr.byInst[ui] or gr.nodes
                    for i = 1, #same do
                        local v = same[i]
                        if v.inst == ui and v ~= u and not v.road and not closed[v] then
                            local usable = true
                            -- any flight master may be walked to (that is how a new one is discovered), as FindPath
                            if v.kind == "taxi" then usable = useTaxi and true or false end
                            if v.kind == "transit" and not useTransit then usable = false end
                            if usable then
                                local ax, ay = ux - v.wx, uy - v.wy
                                relax(v, du + sqrt(ax * ax + ay * ay) * k)
                            end
                        end
                        if tick and i % 64 == 0 then tick() end
                    end
                    -- and on to the goals there (not from the start: that is the direct walk)
                    local gl = u ~= start and byInstG[ui]
                    if gl then
                        for i = 1, #gl do
                            local g = gl[i]
                            if not closed[g] then
                                local ax, ay = ux - g.wx, uy - g.wy
                                relax(g, du + sqrt(ax * ax + ay * ay) * k)
                            end
                        end
                    end
                end
            end
        end
        for i, gn in pairs(gnodes) do
            local g, b = d[gn], best[i]
            if not g then out[i] = b or nil
            elseif b and b <= g + 1 then out[i] = b
            else out[i] = g end
        end
        -- hand the tables back empty (their slots stay allocated for the next search)
        for i = 1, ns do local v = seen[i] d[v], closed[v], seen[i] = nil, nil, nil end
        for i = 1, hs do hc[i], hn[i] = nil, nil end
        if sc then sc.busy = false end
    end
    return out
end

-- Human readable description of a path
function TG.Describe(path)
    if not path then return "no route" end
    local out = {}
    for _, l in ipairs(path.legs) do
        if l.mode == "walk" then out[#out + 1] = ("%s %s to %s%s"):format(l.road and "Follow the road" or "Walk", U.FmtDist(l.dist), l.to.name or "?",
                                                                        l.pickup and " (pick up the flight path)" or "")
        elseif l.mode == "taxi" then out[#out + 1] = ("Fly %s -> %s"):format(l.from.name, l.to.name)
        elseif l.mode == "hearth" then out[#out + 1] = l.title
        else out[#out + 1] = l.title or (l.mode .. " to " .. (l.to.name or "?")) end
    end
    return table.concat(out, "; ") .. (" (~%s)"):format(U.FmtTime(path.cost))
end

-- The one line under the step card.  A player does not need the walk spelled out ("Walk 2.1k yd to Durotar": the
-- arrow and the distance on the card already say it), so only the legs that need a decision are named: a flight, a
-- boat, zeppelin or portal, a hearth or teleport, a flight path to pick up.  A route that is only walking shows
-- nothing.  TG.Describe above stays the full description (/cr route, the step's detail panel, bug reports).
function TG.Summary(path)
    if not path or not path.legs then return "" end
    local out = {}
    for _, l in ipairs(path.legs) do
        if l.mode == "walk" then
            if l.pickup then out[#out + 1] = "pick up the flight path at " .. (l.to.name or "the flight master") end
        elseif l.mode == "taxi" then out[#out + 1] = "fly to " .. (l.to.name or "?")
        else out[#out + 1] = l.title or (l.mode .. " to " .. (l.to.name or "?")) end
    end
    if #out == 0 then return "" end
    local s = table.concat(out, ", then ")
    return s:sub(1, 1):upper() .. s:sub(2) .. ("  (~%s)"):format(U.FmtTime(path.cost))
end

NS:On("ADDON_READY", function() NS:After(0.5, function() pcall(TG.Build) end) end)

-- Learn real portal / boat spots: remember where the player stood just before a teleport-sized jump and,
-- if that was near one end of a transit edge and they landed near the other, store both spots so the
-- arrow aims at the actual portal (down to 0 yd) instead of an approximate room centre.
do
    local last, lastT = nil, 0
    local lf = CreateFrame("Frame")
    lf:SetScript("OnUpdate", function(_, el)
        lastT = lastT + el
        if lastT < 0.25 then return end
        lastT = 0
        local _, _, _, inst, wx, wy = U.PlayerPos()
        if not wx then return end
        if last and (last.inst ~= inst or dist(last.wx, last.wy, wx, wy) > 300) then
            pcall(TG.LearnTransit, last, { inst = inst, wx = wx, wy = wy })
            -- the landing spot of a teleport the route just used (Routing/Teleports.lua keeps it within reach of the data)
            if NS.Teleports and NS.Teleports.OnJump then pcall(NS.Teleports.OnJump, { inst = inst, wx = wx, wy = wy }) end
        end
        last = { inst = inst, wx = wx, wy = wy }
    end)
end
function TG.LearnTransit(a, b)
    if not TG.nodes or not NS.db then return end
    for _, n in ipairs(TG.nodes) do
        if n.kind == "transit" and n.inst == a.inst and dist(n.wx, n.wy, a.wx, a.wy) < 150 then
            for _, e in ipairs(n.edges) do
                local t = e.to
                if e.title and t.inst == b.inst and dist(t.wx, t.wy, b.wx, b.wy) < 400 then
                    local g = NS.db.global
                    g.transitFix = g.transitFix or {}
                    local fixFrom = { a.wx, a.wy, a.inst }
                    local fixTo = { b.wx, b.wy, b.inst }
                    -- the edge may be the reverse direction of the data row (twoway)
                    local row = e.data
                    if row and row.from and U.MapIDByName and n.name ~= (row.from.name or row.from[1]) then fixFrom, fixTo = fixTo, fixFrom end
                    g.transitFix[e.title] = { from = fixFrom, to = fixTo }
                    NS:Debug("Learned transit spot: " .. e.title)
                    TG.built = false
                    return
                end
            end
        end
    end
end
