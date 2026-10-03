-- CompletionRoute :: Core/Farm.lua
-- Gold guides done the way Zygor never did them: a farm CIRCUIT you just walk.
--
-- A farm guide is an ordinary guide with `loop = true` whose steps are all `G` waypoints.  Nothing is
-- ever clicked: the waypoint ticks when you stand on it, the arrow swings to the next one, and when the
-- ring closes Progress.NewLap wipes the lap and starts again at the nearest node.  You follow the same
-- route around the zone forever, which is exactly how people actually farm.
--
-- The node data is community-driven and local-first:
--   * every world-object loot you take is recorded (account-wide, shared by all your characters),
--   * GatherMate2 / GatherMate / Routes / HandyNotes databases are imported if you have them,
--   * `/cr farm build <kind>` re-solves the circuit (Routing/Loop.lua) from whatever data exists,
--   * `/cr farm export` writes a plain-text node list you can hand to anyone else.
-- Nothing proprietary ships with the addon; the routes improve as the account plays.
--
-- Copyright (c) 2026 Daniel Bates / Bates LLC.  All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 (see LICENSE); 10% revenue share for commercial use.
local ADDON, NS = ...
local U, G = NS.Util, NS.Guide
local F = {}
NS.Farm = F

F.GUIDE_PREFIX = "CR_Farm_"

-- ---------------------------------------------------------------------------
-- Node store (account-wide, in CompletionRouteDB.farmNodes)
-- ---------------------------------------------------------------------------
local function store()
    local db = NS.db and NS.db.global
    if not db then return nil end
    db.farmNodes = db.farmNodes or {}
    return db.farmNodes
end

-- key rounds to ~10 yards of zone space so repeat harvests stack instead of piling up
local function nodeKey(x, y) return ("%d:%d"):format(math.floor(x * 1000 + 0.5), math.floor(y * 1000 + 0.5)) end

-- Record one gather node.  kind = "Herbalism" / "Mining" / "Skinning" / "Fishing" / "Chest" / item name.
function F.Record(mapID, x, y, kind, source)
    local s = store()
    if not (s and mapID and x and y) then return end
    s[mapID] = s[mapID] or {}
    local k = nodeKey(x, y)
    local n = s[mapID][k]
    if n then
        n.count = (n.count or 1) + 1
        n.x = (n.x * (n.count - 1) + x) / n.count
        n.y = (n.y * (n.count - 1) + y) / n.count
        if kind and not n.kind then n.kind = kind end
    else
        s[mapID][k] = { x = x, y = y, kind = kind, count = 1, src = source or "self" }
    end
    F.dirty = true
    return true
end

function F.NodeCount(mapID, kind)
    local s = store()
    if not s then return 0 end
    local n = 0
    for map, nodes in pairs(s) do
        if not mapID or map == mapID then
            for _, node in pairs(nodes) do if not kind or node.kind == kind then n = n + 1 end end
        end
    end
    return n
end

-- Zones we have enough data for, most nodes first
function F.Zones(kind, minNodes)
    local s = store()
    local out = {}
    if not s then return out end
    for map, nodes in pairs(s) do
        local n, kinds = 0, {}
        for _, node in pairs(nodes) do
            if not kind or node.kind == kind then n = n + 1 kinds[node.kind or "?"] = (kinds[node.kind or "?"] or 0) + 1 end
        end
        if n >= (minNodes or 8) then out[#out + 1] = { map = map, count = n, kinds = kinds } end
    end
    table.sort(out, function(a, b) return a.count > b.count end)
    return out
end

-- ---------------------------------------------------------------------------
-- Recorder: any world object you loot is a farm node
-- ---------------------------------------------------------------------------
local GATHER_KIND_BY_CLASS = { [7] = "Trade Goods", [12] = "Quest" }

local function lootKind()
    -- name the node after what came out of it (Peacebloom, Copper Ore, ...); falls back to "Node"
    local n = (GetNumLootItems and GetNumLootItems()) or 0
    for i = 1, n do
        local link = GetLootSlotLink and GetLootSlotLink(i)
        if link then
            local name = link:match("%[(.-)%]")
            if name then return name end
        end
    end
    return "Node"
end

local function isObjectLoot()
    if not GetLootSourceInfo then return nil end
    local n = (GetNumLootItems and GetNumLootItems()) or 0
    for i = 1, n do
        local guid = GetLootSourceInfo(i)
        if type(guid) == "string" then
            if guid:find("^GameObject") then return true end
            if guid:find("^Creature") or guid:find("^Vehicle") then return false end
        end
    end
    return nil
end

function F.OnLoot()
    if not (NS.db and NS.db.profile.farm and NS.db.profile.farm.record) then return end
    local obj = isObjectLoot()
    if obj == false then return end            -- a corpse: not a gather node
    local map, x, y = U.PlayerPos()
    if not (map and x) then return end
    if obj == nil and not (NS.db.profile.farm.recordUnknown) then return end
    F.Record(map, x, y, lootKind(), "self")
end

-- ---------------------------------------------------------------------------
-- Importers: use the databases the player already has (their own, or a community pack they installed)
-- ---------------------------------------------------------------------------
-- GatherMate2 packs coords as a 0..1e6 int: floor(x*1e4)*1e4 + floor(y*1e4)  (its own encoding)
local function gm2coord(v)
    local x = math.floor(v / 10000) / 10000
    local y = (v % 10000) / 10000
    return x, y
end

local GM2_KIND = { Herb = "Herbalism", Mine = "Mining", Gas = "Gas Cloud", Fish = "Fishing", Treasure = "Treasure", Archaeology = "Archaeology" }

function F.ImportGatherMate2()
    local db = _G.GatherMate2DB or _G.GatherMate2ConfigDB
    if type(db) ~= "table" then return 0, "GatherMate2 database not found" end
    local added = 0
    for dbname, maps in pairs(db) do
        local kind = GM2_KIND[dbname]
        if kind and type(maps) == "table" then
            for mapID, nodes in pairs(maps) do
                if type(nodes) == "table" and tonumber(mapID) then
                    for coord in pairs(nodes) do
                        local x, y = gm2coord(tonumber(coord) or 0)
                        if x > 0 and x <= 1 and y > 0 and y <= 1 then
                            if F.Record(tonumber(mapID), x, y, kind, "GatherMate2") then added = added + 1 end
                        end
                    end
                end
            end
        end
    end
    return added
end

function F.ImportRoutes()
    local db = _G.RoutesDB
    if type(db) ~= "table" then return 0, "Routes database not found" end
    local added = 0
    local global = db.global or db
    for _, zoneTbl in pairs(global.routes or {}) do
        if type(zoneTbl) == "table" then
            for _, route in pairs(zoneTbl) do
                if type(route) == "table" and type(route.route) == "table" and route.zone then
                    local mapID = tonumber(route.zone) or U.MapIDByName(tostring(route.zone))
                    if mapID then
                        for _, coord in ipairs(route.route) do
                            local x, y = gm2coord(tonumber(coord) or 0)
                            if x > 0 and y > 0 then
                                if F.Record(mapID, x, y, route.db and GM2_KIND[route.db] or "Route", "Routes") then added = added + 1 end
                            end
                        end
                    end
                end
            end
        end
    end
    return added
end

function F.ImportAll()
    local total, notes = 0, {}
    for name, fn in pairs({ GatherMate2 = F.ImportGatherMate2, Routes = F.ImportRoutes }) do
        local ok, n, err = pcall(fn)
        if ok and n and n > 0 then total = total + n notes[#notes + 1] = ("%s: %d"):format(name, n)
        elseif ok and err then notes[#notes + 1] = ("%s: %s"):format(name, err) end
    end
    return total, table.concat(notes, ", ")
end

-- ---------------------------------------------------------------------------
-- Circuit building
-- ---------------------------------------------------------------------------
-- Build (or rebuild) a farm circuit for a zone and register it as a loop guide.
function F.BuildRoute(mapID, kind, opts)
    opts = opts or {}
    local s = store()
    if not (s and s[mapID]) then return nil, "no recorded nodes in that zone" end
    local pts = {}
    for _, n in pairs(s[mapID]) do
        if not kind or n.kind == kind or (n.kind or ""):find(kind, 1, true) then
            local wx, wy, inst = U.World(mapID, n.x, n.y)
            if wx then pts[#pts + 1] = { wx = wx, wy = wy, inst = inst, map = mapID, x = n.x, y = n.y, kind = n.kind, weight = n.count or 1 } end
        end
    end
    if #pts < 3 then return nil, ("only %d nodes here - farm a while, or /cr farm import"):format(#pts) end
    local tour, len = NS.Loop.Build(pts, { cell = opts.cell or 40, minWeight = opts.minWeight or 1, budget = opts.budget or 40000 })
    if not tour then return nil, len end
    local zoneName = U.MapName(mapID)
    local text = NS.Loop.ToGuideText(tour, mapID, zoneName, { radius = opts.radius or (NS.db.profile.farm and NS.db.profile.farm.radius) or 40 })
    local id = ("%s%d_%s"):format(F.GUIDE_PREFIX, mapID, (kind or "All"):gsub("%W", ""))
    local speed = U.TravelSpeed and U.TravelSpeed() or 7
    local guide = {
        id = id, name = ("%s - %s circuit"):format(zoneName, kind or "Gathering"), type = "Gold", loop = true,
        zone = zoneName, source = "CompletionRoute", author = "your account (recorded + imported nodes)",
        text = text, farm = { map = mapID, kind = kind, nodes = #tour, length = len, built = time and time() or nil,
                              lapSeconds = len and speed and (len / math.max(1, speed)) or nil },
    }
    -- rebuilding replaces the old ring
    if G.registry[id] then
        G.registry[id].text, G.registry[id].steps, G.registry[id].farm = text, nil, guide.farm
        G.registry[id].name = guide.name
    else
        G.Register(guide)
    end
    NS.db.global.farmRoutes = NS.db.global.farmRoutes or {}
    NS.db.global.farmRoutes[id] = { map = mapID, kind = kind, nodes = #tour, length = len, text = text, name = guide.name }
    return G.registry[id], #tour, len
end

-- Register the routes this account built in an earlier session (so they survive a reload)
function F.RegisterSaved()
    local saved = NS.db and NS.db.global and NS.db.global.farmRoutes
    if not saved then return 0 end
    local n = 0
    for id, r in pairs(saved) do
        if not G.registry[id] and type(r.text) == "string" and r.text:find("%S") then
            G.Register({ id = id, name = r.name or id, type = "Gold", loop = true, zone = r.map and U.MapName(r.map),
                         source = "CompletionRoute", text = r.text, farm = { map = r.map, kind = r.kind, nodes = r.nodes, length = r.length } })
            n = n + 1
        end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- Turning an imported "gold guide" into a circuit
-- ---------------------------------------------------------------------------
-- Zygor-style gold guides are a wall of note steps you click through: "go here, kill these, now click
-- Next".  What a farmer actually wants is the loop.  Circuitize takes every located step of such a
-- guide, solves the shortest closed tour through them (Routing/Loop.lua) and hands back G waypoints
-- carrying the original text as their notes - so the guide's knowledge survives, the clicking does not.
local NO_CIRCUIT = { A = true, a = true, T = true, t = true, ["!"] = true, h = true, H = true, f = true, F = true, b = true, J = true, D = true }

-- Yards per unit of zone coordinate on `map` (x and y differ: zones are not square)
local function zoneScale(map)
    local ax, ay = U.World(map, 0.4, 0.5)
    local bx, by = U.World(map, 0.6, 0.5)
    local cx, cy = U.World(map, 0.5, 0.4)
    local dx, dy = U.World(map, 0.5, 0.6)
    if not (ax and cx) then return nil end
    local sx = math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) / 0.2
    local sy = math.sqrt((cx - dx) ^ 2 + (cy - dy) ^ 2) / 0.2
    if sx <= 0 or sy <= 0 then return nil end
    return sx, sy
end

-- A patrol ring around one farm spot: standing still is not a route, and mobs/nodes respawn behind you.
local function ringAround(map, x, y, yards, n)
    local sx, sy = zoneScale(map)
    if not sx then return {} end
    local out = {}
    for i = 1, n do
        local a = (i - 1) / n * math.pi * 2
        local px = math.max(0.02, math.min(0.98, x + (yards / sx) * math.cos(a)))
        local py = math.max(0.02, math.min(0.98, y + (yards / sy) * math.sin(a)))
        out[#out + 1] = { x = px, y = py }
    end
    return out
end

function F.Circuitize(guide, opts)
    opts = opts or {}
    if not (guide and NS.Loop) then return nil, "no guide" end
    local steps = G.Steps(guide.id)
    if not steps or #steps == 0 then return nil, "no steps" end
    -- The guide already IS a ring (Zygor "path ... loop on", or one of ours): keep the author's order,
    -- they walked it. Re-solving a hand-tuned route only makes it worse.
    local waypoints = 0
    for _, st in ipairs(steps) do if st.action == "G" then waypoints = waypoints + 1 end end
    if waypoints >= 4 then
        guide.loop = true
        guide.circuitized = true
        guide.farm = guide.farm or { nodes = waypoints, authored = true }
        return guide, waypoints, nil
    end
    local pts, quest, located = {}, 0, 0
    for _, st in ipairs(steps) do
        local wx, wy, inst = NS.Router.StepWorld(st)
        if wx and st.coords then
            located = located + 1
            if NO_CIRCUIT[st.action] then quest = quest + 1
            else pts[#pts + 1] = { wx = wx, wy = wy, inst = inst, map = st.zone, x = st.coords[1].x, y = st.coords[1].y,
                                   kind = st.title, weight = 1, note = st.note, step = st } end
        end
    end
    -- "Kill kodos in the Barrens" - a zone and no coordinates. That IS a farm guide, it just never
    -- said where: lay a hunting ring across the zone and let the recorder tighten it as loot drops.
    if #pts == 0 then
        local zones, order = {}, {}
        for _, st in ipairs(steps) do
            if st.zone and not NO_CIRCUIT[st.action] and not zones[st.zone] then
                zones[st.zone] = st order[#order + 1] = st.zone
                if #order >= 2 then break end
            end
        end
        for _, map in ipairs(order) do
            local st = zones[map]
            for i = 1, 12 do
                local a = (i - 1) / 12 * math.pi * 2
                local x = math.max(0.05, math.min(0.95, 0.5 + 0.22 * math.cos(a)))
                local y = math.max(0.05, math.min(0.95, 0.5 + 0.20 * math.sin(a)))
                local wx, wy, inst = U.World(map, x, y)
                if wx then pts[#pts + 1] = { wx = wx, wy = wy, inst = inst, map = map, x = x, y = y,
                                             kind = st.title, weight = 1, note = st.note, step = st, patrol = true } end
            end
        end
        if #pts == 0 then return nil, "no farmable stops and no zone to sweep" end
        opts.minStops = 0
    end
    if quest > located * 0.5 then return nil, "mostly quest steps - this is a questing guide, not a farm route" end
    -- Most imported gold guides are ONE spot ("kill clefthooves here"). A single point is not a route,
    -- so patrol it: a ring around each stop, sized to the spread of the guide's own stops.
    if #pts < (opts.minStops or 6) then
        local spread = 0
        for _, a in ipairs(pts) do for _, b in ipairs(pts) do
            spread = math.max(spread, math.sqrt((a.wx - b.wx) ^ 2 + (a.wy - b.wy) ^ 2))
        end end
        local ringYards = math.max(60, math.min(220, spread > 0 and spread / 2 or 120))
        local ringPts = math.max(4, math.min(8, math.ceil(14 / #pts)))
        local extra = {}
        for _, p in ipairs(pts) do
            for _, r in ipairs(ringAround(p.map, p.x, p.y, ringYards, ringPts)) do
                local wx, wy, inst = U.World(p.map, r.x, r.y)
                if wx then extra[#extra + 1] = { wx = wx, wy = wy, inst = inst, map = p.map, x = r.x, y = r.y,
                                                 kind = p.kind, weight = 1, note = p.note, step = p.step, patrol = true } end
            end
        end
        for _, e in ipairs(extra) do pts[#pts + 1] = e end
    end
    local tour, len = NS.Loop.Build(pts, { cell = opts.cell or 25, budget = 20000 })
    if not tour or #tour < 3 then return nil, "could not close a loop here" end
    local lines = {}
    for i, p in ipairs(tour) do
        local st = p.step
        local zone = (st and st.zone) or p.map
        local note = (st and st.note) or ""
        local title = (st and st.title ~= "" and st.title) or ("Stop " .. i)
        if p.patrol then note = (note ~= "" and (note .. " ") or "") .. "(patrol leg - keep moving, everything respawns behind you)" end
        lines[#lines + 1] = ("G %s|M|%.2f,%.2f|Z|%d; %s|RAD|%d|%s"):format(
            title, p.x * 100, p.y * 100, zone, U.MapName(zone),
            (NS.db.profile.farm and NS.db.profile.farm.radius) or 40,
            note ~= "" and ("N|" .. note:gsub("|", "/") .. "|") or "")
    end
    guide.stepsOriginal = guide.stepsOriginal or steps
    guide.textOriginal = guide.textOriginal or guide.text
    guide.text = table.concat(lines, "\n")
    guide.steps = nil
    guide.loop = true
    guide.circuitized = true
    guide.farm = guide.farm or { nodes = #tour, length = len }
    return guide, #tour, len
end

-- Undo (put the authored guide back)
function F.Uncircuitize(guide)
    if not (guide and guide.circuitized) then return nil end
    guide.text, guide.steps, guide.loop, guide.circuitized = guide.textOriginal, nil, nil, nil
    return guide
end

-- ---------------------------------------------------------------------------
-- Lap stats: what a circuit is actually worth (measured, never guessed)
-- ---------------------------------------------------------------------------
local lap = nil

local function itemValue(itemID)
    -- Auctionator if the player runs it, else the vendor price; label which one we used
    if _G.Auctionator and Auctionator.API and Auctionator.API.v1 then
        local ok, v = pcall(Auctionator.API.v1.GetAuctionPriceByItemID, "CompletionRoute", itemID)
        if ok and v and v > 0 then return v, "AH" end
    end
    local sell = select(11, (C_Item and C_Item.GetItemInfo or GetItemInfo)(itemID))
    return sell or 0, "vendor"
end

local function snapshotBags()
    local snap = {}
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        local slots = (C_Container and C_Container.GetContainerNumSlots or GetContainerNumSlots)(bag) or 0
        for slot = 1, slots do
            local info = C_Container and C_Container.GetContainerItemInfo and C_Container.GetContainerItemInfo(bag, slot)
            local id, count
            if type(info) == "table" then id, count = info.itemID, info.stackCount
            elseif GetContainerItemInfo then local _, c, _, _, _, _, _, _, _, iid = GetContainerItemInfo(bag, slot) id, count = iid, c end
            if id then snap[id] = (snap[id] or 0) + (count or 1) end
        end
    end
    return snap
end

function F.OnLoad(guide)
    if not (guide and guide.loop) then lap = nil return end
    lap = { start = GetTime and GetTime() or 0, bags = snapshotBags(), money = GetMoney and GetMoney() or 0, guide = guide.id }
end

function F.OnLapComplete(guide)
    if not (lap and guide and lap.guide == guide.id) then F.OnLoad(guide) return end
    local now = GetTime and GetTime() or 0
    local secs = now - lap.start
    local after = snapshotBags()
    local gained, value, priceSrc = {}, 0, "vendor"
    for id, n in pairs(after) do
        local delta = n - (lap.bags[id] or 0)
        if delta > 0 then
            gained[id] = delta
            local v, src = itemValue(id)
            value = value + v * delta
            if src == "AH" then priceSrc = "AH" end
        end
    end
    value = value + math.max(0, (GetMoney and GetMoney() or 0) - lap.money)
    local hist = NS.db.global.farmStats or {}
    NS.db.global.farmStats = hist
    local h = hist[guide.id] or { laps = 0, seconds = 0, value = 0 }
    h.laps = h.laps + 1
    h.seconds = h.seconds + secs
    h.value = h.value + value
    h.last = { seconds = secs, value = value, at = time and time() or nil, priceSrc = priceSrc }
    hist[guide.id] = h
    if secs > 0 then
        NS:Print(("Lap %d done in %s - %s (%s/hr, %s prices)"):format(h.laps, U.FmtTime(secs), U.FmtMoney(value),
            U.FmtMoney(value * 3600 / secs), priceSrc))
    end
    lap = { start = now, bags = after, money = GetMoney and GetMoney() or 0, guide = guide.id }
end

function F.Stats(id)
    local h = NS.db.global.farmStats and NS.db.global.farmStats[id]
    if not h or h.laps == 0 then return nil end
    return { laps = h.laps, avgSeconds = h.seconds / h.laps, avgValue = h.value / h.laps,
             perHour = h.seconds > 0 and (h.value * 3600 / h.seconds) or 0, last = h.last }
end

-- ---------------------------------------------------------------------------
-- Export / import as text (the community half: hand your nodes to someone else)
-- ---------------------------------------------------------------------------
function F.Export(mapID)
    local s = store()
    local out = {}
    if not s then return "" end
    for map, nodes in pairs(s) do
        if not mapID or map == mapID then
            for _, n in pairs(nodes) do
                out[#out + 1] = ("%d %.4f %.4f %s %d"):format(map, n.x, n.y, (n.kind or "Node"):gsub("%s", "_"), n.count or 1)
            end
        end
    end
    return table.concat(out, "\n")
end

function F.ImportText(text)
    local n = 0
    for line in (tostring(text) .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        local map, x, y, kind, count = line:match("^%s*(%d+)%s+([%d%.]+)%s+([%d%.]+)%s+(%S+)%s*(%d*)")
        if map then
            for _ = 1, math.max(1, tonumber(count) or 1) do
                F.Record(tonumber(map), tonumber(x), tonumber(y), (kind:gsub("_", " ")), "shared")
            end
            n = n + 1
        end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- In-client self test: prove the circuit engine on a live client without walking anywhere
-- ---------------------------------------------------------------------------
-- Builds a throwaway ring of waypoints ON the player (so every one is inside its own radius),
-- loads it, and watches the engine drive itself: waypoints must tick with nothing clicked, the lap
-- counter must roll over instead of the guide "finishing", and a waypoint must always be current.
-- Results land in CompletionRouteDB.farmSelfTest for the offline collector. The previous guide is
-- restored at the end.
function F.SelfTest(done)
    local map, x, y = U.PlayerPos()
    if not (map and x) then if done then done() end return nil, "no player position" end
    local id = "CR_Farm_SelfTest"
    local lines = {}
    for i = 1, 6 do
        lines[#lines + 1] = ("G Self test %d|M|%.2f,%.2f|Z|%d; %s|RAD|200|N|Engine self test - no walking required.|")
            :format(i, x * 100, y * 100, map, U.MapName(map))
    end
    local prev = NS.Progress.guide and NS.Progress.guide.id
    if G.registry[id] then G.registry[id].text, G.registry[id].steps = table.concat(lines, "\n"), nil
    else G.Register({ id = id, name = "Circuit self test", type = "Gold", loop = true, zone = U.MapName(map),
                      source = "CompletionRoute", text = table.concat(lines, "\n"), farm = { map = map, nodes = 6 } }) end
    NS.db.char.laps = NS.db.char.laps or {}
    NS.db.char.laps[id] = 0
    NS.Progress.Reset()
    local res = { at = date("%Y-%m-%d %H:%M:%S"), flavor = NS.flavor, zone = U.MapName(map), checks = {} }
    local function chk(name, pass, detail)
        res.checks[#res.checks + 1] = { name = name, pass = pass and true or false, detail = tostring(detail or "") }
        NS:Print(("%s [circuit self test] %s%s"):format(pass and "|cff00ff00PASS|r" or "|cffff4040FAIL|r", name,
            detail and ("  - " .. tostring(detail)) or ""))
    end
    NS.Progress.Load(id)
    chk("circuit loads with a current waypoint", NS.Progress.current ~= nil,
        NS.Progress.current and NS.Progress.current.title)
    chk("all steps are waypoints", (function()
        for _, st in ipairs(NS.Progress.steps or {}) do if st.action ~= "G" then return false end end
        return true
    end)(), (#(NS.Progress.steps or {})) .. " waypoints")
    local ticks, startLap = 0, NS.Progress.Lap(id)
    local function tick()
        ticks = ticks + 1
        NS.Progress.Refresh()
        local laps = NS.Progress.Lap(id)
        if laps >= startLap + 2 or ticks > 40 then
            chk("laps roll over instead of finishing", laps >= startLap + 2, ("%d laps in %d refreshes"):format(laps - startLap, ticks))
            chk("a waypoint is always current", NS.Progress.current ~= nil,
                NS.Progress.current and NS.Progress.current.title or "none - the ring emptied itself")
            local st = F.Stats(id)
            chk("lap value recorded", st ~= nil, st and ("%d laps, %s per lap"):format(st.laps, U.FmtMoney(st.avgValue)) or "no stats")
            local pass, fail = 0, 0
            for _, c in ipairs(res.checks) do if c.pass then pass = pass + 1 else fail = fail + 1 end end
            res.passed, res.failed = pass, fail
            CompletionRouteDB.farmSelfTest = res
            NS:Print(("circuit self test: %d passed, %d failed - saved to CompletionRouteDB.farmSelfTest"):format(pass, fail))
            if prev and G.registry[prev] then NS.Progress.Load(prev) end
            if done then done() end
            return
        end
        NS:After(0.4, tick)
    end
    NS:After(0.5, tick)
    return res
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------
NS:RegisterEvent("LOOT_OPENED", function() pcall(F.OnLoot) end)
NS:On("PLAYER_READY", function()
    NS:After(4, function()
        pcall(F.RegisterSaved)
        if NS.db.profile.farm and NS.db.profile.farm.autoImport then
            local n, notes = F.ImportAll()
            if n > 0 then NS:Print(("Farm: imported %d gather nodes (%s). /cr farm build"):format(n, notes)) end
        end
        pcall(F.RegisterSeeds)
    end)
end)

return F
