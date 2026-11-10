-- Offline test for the farm-circuit (gold guide) engine: luajit tools/test_farm.lua
-- Covers: G waypoint parsing, loop guides that never "finish", lap wrap, entering the ring at the
-- nearest waypoint, the TSP loop builder, GatherMate2 decode, node record/export/import, lap value.
package.path = "./?.lua;" .. package.path
local ADDON, NS = "CompletionRoute", {}
dofile("tools/stubs.lua")
local z2w, MAPS = z2w, MAPS
PLAYER = { map = 1429, x = 0.487, y = 0.42 } PLAYER.wx, PLAYER.wy, PLAYER.inst = z2w(PLAYER.x, PLAYER.y, PLAYER.map)

-- extra stubs the farm engine touches
NUM_BAG_SLOTS = 4
local BAGS = {}   -- [bag][slot] = {itemID=, stackCount=}
C_Container = C_Container or {}
C_Container.GetContainerNumSlots = function(bag) return BAGS[bag] and #BAGS[bag] or 0 end
C_Container.GetContainerItemInfo = function(bag, slot) return BAGS[bag] and BAGS[bag][slot] end
C_Container.GetItemCooldown = function() return 0, 0 end
function GetMoney() return 0 end
C_Item = C_Item or {}
C_Item.GetItemInfo = function(id) return "Item " .. id, nil, nil, nil, nil, nil, nil, nil, nil, nil, 500 end
local LOOT = { n = 0, guid = "GameObject-0-1-2-3-4-5", link = "|cff|Hitem:765|h[Silverleaf]|h|r" }
function GetNumLootItems() return LOOT.n end
function GetLootSourceInfo() return LOOT.guid end
function GetLootSlotLink() return LOOT.link end

local function load(path) local fn = assert(loadfile("CompletionRoute/" .. path)) fn(ADDON, NS) end
for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", "Data/Taxi_tbc.lua",
    "Data/Transit.lua", "Data/Access.lua", "Data/Inns.lua", "Data/ZoneAliases.lua", "Data/Roads_ek.lua",
    "Data/Roads_kalimdor.lua", "Routing/TravelGraph.lua", "Routing/Roads.lua", "Routing/StepOrder.lua",
    "Routing/Router.lua", "Routing/Loop.lua", "Core/Account.lua", "Core/Progress.lua", "Core/Farm.lua",
    "Data/Farm_routes.lua", "Core/Instances.lua" }) do load(f) end
CompletionRouteDB, CompletionRouteCharDB = nil, nil
for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", "CompletionRoute") end
NS.db.profile.routing.assumeAllTaxi = true
local G, P, F, L, U = NS.Guide, NS.Progress, NS.Farm, NS.Loop, NS.Util

-- 1) G steps parse, are never reordered, and carry a radius
local s = G.ParseLine("G Elwynn 3|M|60.00,55.00|Z|1429; Elwynn Forest|RAD|60|N|Herbs|", 1)
assert(s and s.action == "G" and s.radius == 60 and s.route == false and s.coords[1].x == 0.6, "G parse failed")
print("G waypoint parse OK")

-- 2) seed circuits register and are loop guides
local n = F.RegisterSeeds()
assert(n >= 4, "expected the seed rings to register, got " .. n)  -- only the stub map table resolves offline
local seed = G.registry["CR_Farm_Seed_1429_Herbalism"]
assert(seed and seed.loop and seed.type == "Gold", "Elwynn seed ring missing")
assert(G.registry["CR_Farm_Seed_1429_Mining"], "a combined seed must become one ring per profession")
assert(seed.requires == "Herbalism;1" and seed.goldKind == "Gathering", "seed ring fields")
local steps = G.Steps(seed.id)
assert(#steps == 14, "ring should be 14 waypoints, got " .. #steps)
for _, st in ipairs(steps) do assert(st.action == "G" and st.coords and st.zone == 1429, "bad ring step") end
-- a generated Gathering guide for the same zone and profession suppresses the seed
do
    NS.Guide.Register({ id = "t:gen_gather_1436", name = "gen", type = "Gold", goldKind = "Gathering", loop = true, zone = 1436,
        minlevel = 10, maxlevel = 20, requires = "Herbalism;1", text = "G x|M|50,50|Z|1436; Westfall|RAD|60|", farm = { map = 1436, kind = "Herbalism", nodes = 1 } })
    G.registry["CR_Farm_Seed_1436_Herbalism"] = nil
    for i = #G.list, 1, -1 do if G.list[i] == "CR_Farm_Seed_1436_Herbalism" then table.remove(G.list, i) end end
    F.RegisterSeeds()
    assert(not G.registry["CR_Farm_Seed_1436_Herbalism"], "seed registered despite a generated guide for the zone and profession")
    assert(G.registry["CR_Farm_Seed_1436_Mining"], "the other profession's seed for the zone should stay")
end
print(("seed circuits OK: %d rings, Elwynn ring = %d waypoints"):format(n, #steps))

-- a generated Gathering circuit replaces the fallback rings
do
    local saved = {}
    for _, id in ipairs(G.list) do saved[id] = G.registry[id] end
    G.Register({ id = "t:generated_gather", name = "Generated", type = "Gold", goldKind = "Gathering", loop = true, source = "t",
        text = "G x|M|50,50|Z|1429; Elwynn Forest|" })
    assert(F.RegisterSeeds() == 0, "seed rings registered although generated circuits exist")
    G.registry["t:generated_gather"] = nil
    for i = #G.list, 1, -1 do if G.list[i] == "t:generated_gather" then table.remove(G.list, i) end end
end
print("generated circuits replace the fallback rings OK")

-- 3) loading a circuit enters it at the NEAREST waypoint, not waypoint 1
P.Load(seed.id)
assert(P.guide.id == seed.id and P.current, "circuit did not load")
local firstIdx = P.current.index
local function distTo(st)
    local tx, ty = NS.Router.StepWorld(st)
    return math.sqrt((tx - PLAYER.wx) ^ 2 + (ty - PLAYER.wy) ^ 2)
end
local nearest, nd
for _, st in ipairs(P.steps) do local d = distTo(st) if not nd or d < nd then nearest, nd = st.index, d end end
assert(firstIdx == nearest, ("entered ring at %d, nearest is %d"):format(firstIdx, nearest))
print(("enter-at-nearest OK: waypoint %d (%.0f yd away)"):format(firstIdx, nd))

-- 4) a waypoint completes by standing on it - no click anywhere
local cur = P.current
local cx, cy = cur.coords[1].x, cur.coords[1].y
PLAYER.map, PLAYER.x, PLAYER.y = 1429, cx, cy
PLAYER.wx, PLAYER.wy, PLAYER.inst = z2w(cx, cy, 1429)
P.Refresh()
assert(P.current ~= cur, "standing on the waypoint did not advance the circuit")
print("proximity auto-advance OK (nothing clicked)")

-- 5) the ring never finishes: walking every waypoint starts lap 2
local lap0 = P.Lap(seed.id)
local guard = 0
while P.current and guard < 200 do
    local st = P.current
    local x, y = st.coords[1].x, st.coords[1].y
    PLAYER.map, PLAYER.x, PLAYER.y = st.zone, x, y
    PLAYER.wx, PLAYER.wy, PLAYER.inst = z2w(x, y, st.zone)
    P.Refresh()
    if P.current == st then P.MarkDone(st) end   -- (radius edge case) keep the walk moving
    guard = guard + 1
    if P.Lap(seed.id) > lap0 then break end
end
assert(P.Lap(seed.id) > lap0, "circuit finished instead of starting a new lap")
assert(P.current ~= nil, "no waypoint after the lap rolled over")
print(("lap wrap OK: lap %d, next waypoint %s"):format(P.Lap(seed.id), P.current.title))

-- 6) loop builder: a shuffled square must come back as a ring, not a zig-zag
local pts = {}
for _, c in ipairs({ { 0, 0 }, { 100, 0 }, { 200, 0 }, { 200, 100 }, { 200, 200 }, { 100, 200 }, { 0, 200 }, { 0, 100 } }) do
    pts[#pts + 1] = { wx = c[1], wy = c[2], inst = 0, map = 1429, weight = 1 }
end
local shuffled = { pts[1], pts[5], pts[2], pts[7], pts[3], pts[8], pts[4], pts[6] }
local tour, len = L.Build(shuffled, { cell = 10 })
assert(tour and #tour == 8, "loop builder dropped points")
assert(math.abs(len - 800) < 1, ("perimeter should be 800 yd, got %.1f"):format(len))
print(("loop builder OK: 8 nodes, %.0f yd (optimal)"):format(len))

-- clustering collapses a respawn pile into one node
local pile = {}
for i = 1, 20 do pile[i] = { wx = 5 + i * 0.1, wy = 5, inst = 0, weight = 1 } end
pile[21] = { wx = 500, wy = 500, inst = 0, weight = 1 }
assert(#L.Cluster(pile, 30) == 2, "clustering failed")
print("clustering OK")

-- 7) recorder: looting a world object records a node; a corpse does not
NS.db.profile.farm.record = true
LOOT.n, LOOT.guid = 1, "GameObject-0-1-2-3-4-5"
PLAYER.map, PLAYER.x, PLAYER.y = 1429, 0.42, 0.66
F.OnLoot()
assert(F.NodeCount(1429) == 1, "world-object loot was not recorded")
LOOT.guid = "Creature-0-1-2-3-4-5"
PLAYER.x, PLAYER.y = 0.43, 0.67
F.OnLoot()
assert(F.NodeCount(1429) == 1, "a corpse was recorded as a gather node")
print("recorder OK: objects in, corpses out")

-- 8) GatherMate2 decode + import
_G.GatherMate2DB = { Herb = { [1429] = { [(math.floor(0.5 * 10000) * 10000) + math.floor(0.25 * 10000)] = 765 } } }
local added = F.ImportGatherMate2()
assert(added == 1, "GatherMate2 import added " .. tostring(added))
local found = false
for _, node in pairs(NS.db.global.farmNodes[1429]) do
    if node.src == "GatherMate2" then
        assert(math.abs(node.x - 0.5) < 0.001 and math.abs(node.y - 0.25) < 0.001, "GatherMate2 coords decoded wrong")
        assert(node.kind == "Herbalism", "kind lost")
        found = true
    end
end
assert(found, "imported node missing")
print("GatherMate2 import OK")

-- 9) export / import round trip
local text = F.Export(1429)
assert(select(2, text:gsub("\n", "\n")) + 1 == 2, "export line count wrong")
NS.db.global.farmNodes = {}
assert(F.ImportText(text) == 2, "text import failed")
assert(F.NodeCount(1429) == 2, "round trip lost nodes")
print("export/import round trip OK")

-- 10) building a real circuit from recorded nodes, and it loads as a loop guide
for i = 1, 12 do
    local a = (i / 12) * math.pi * 2
    F.Record(1429, 0.5 + 0.2 * math.cos(a), 0.5 + 0.2 * math.sin(a), "Herbalism")
end
local g, count, length = F.BuildRoute(1429, "Herbalism")
assert(g, "BuildRoute failed: " .. tostring(count))
assert(count >= 10 and g.loop and g.type == "Gold", "built circuit is not a loop guide")
local bs = G.Steps(g.id)
assert(#bs == count and bs[1].action == "G", "built circuit has no waypoints")
-- a ring, not a zig-zag: consecutive waypoints are neighbours on the circle
local maxHop = 0
for i = 1, #bs do
    local a, b = bs[i], bs[i % #bs + 1]
    local ax, ay = NS.Router.StepWorld(a)
    local bx, by = NS.Router.StepWorld(b)
    maxHop = math.max(maxHop, math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2))
end
assert(maxHop < length / 4, ("route zig-zags: longest hop %.0f of %.0f yd"):format(maxHop, length))
print(("BuildRoute OK: %s, %d waypoints, %.0f yd, longest hop %.0f yd"):format(g.name, count, length, maxHop))

-- 11) lap value: bag deltas priced and stored
BAGS = { [0] = { { itemID = 765, stackCount = 4 } } }
F.OnLoad(g)
BAGS[0][1].stackCount = 14
F.OnLapComplete(g)
local st2 = F.Stats(g.id)
assert(st2 and st2.laps == 1, "lap stats missing")
assert(math.abs(st2.avgValue - 10 * 500) < 1, "lap value wrong: " .. tostring(st2.avgValue))
print(("lap stats OK: %d laps, %s per lap"):format(st2.laps, U.FmtMoney(st2.avgValue)))

-- 12) an imported "gold guide" that is a wall of clickable notes becomes a circuit
G.Register({ id = "t:gold_notes", name = "Bear Meat", type = "GOLD", source = "Community", text = table.concat({
    "N Kill bears here|Z|1429; Elwynn Forest|M|40.00,50.00|N|They drop bear meat.|",
    "C Collect Bear Meat|Z|1429; Elwynn Forest|M|44.00,52.00|",
    "N More bears|Z|1429; Elwynn Forest|M|46.00,58.00|",
}, "\n") })
local gg = G.registry["t:gold_notes"]
assert(gg.type == "Gold", "guide type not normalised (GOLD -> Gold)")
local res, stops = F.Circuitize(gg)
assert(res and gg.loop and stops >= 3, "note-style gold guide did not fold into a circuit")
local gs = G.Steps(gg.id)
for _, st in ipairs(gs) do assert(st.action == "G", "circuit still contains clickable steps") end
local patrol = 0
for _, st in ipairs(gs) do if (st.note or ""):find("patrol") then patrol = patrol + 1 end end
assert(patrol > 0, "a 3-stop guide should gain patrol legs, not just 3 dots")
assert((gs[1].note or ""):find("bear meat") or (gs[2].note or ""):find("bear meat") or (gs[3].note or ""):find("bear meat"),
    "the guide's own text was lost in the fold")
print(("gold-guide circuitize OK: %d stops, %d patrol legs, notes preserved"):format(stops, patrol))

-- 14) instance entrance: a step inside a dungeon routes to the door we learned
MAPS[2000] = { "Test Dungeon", 0, -9000, 200, 500, 500, 1429, 4 }   -- mapType 4 = dungeon interior
NS.db.global.instanceEntrances = { ["map:2000"] = { map = 1429, x = 0.42, y = 0.71, name = "Test Dungeon" } }
local dstep = G.ParseLine("C Kill the boss|Z|2000; Test Dungeon|M|50.00,50.00|", 1)
dstep.index = 1
local ex, ey = NS.Router.StepWorld(dstep)
local doorx, doory = z2w(0.42, 0.71, 1429)
assert(ex and math.abs(ex - doorx) < 1 and math.abs(ey - doory) < 1, "dungeon step did not route to the learned entrance")
assert(dstep._locSource == "entrance", "entrance substitution not flagged")
print("instance entrance routing OK (dungeon step -> the door)")

-- 15) the in-client self test drives the engine with the player standing still
PLAYER.map, PLAYER.x, PLAYER.y = 1429, 0.50, 0.50
PLAYER.wx, PLAYER.wy, PLAYER.inst = z2w(0.50, 0.50, 1429)
local st = F.SelfTest()
assert(st and st.failed == 0, "circuit self test failed: " .. tostring(st and st.failed))
assert(#st.checks == 5, "expected 5 self-test checks, got " .. #st.checks)
print(("in-client self test OK: %d checks, %d failed"):format(#st.checks, st.failed))

print("ALL FARM TESTS PASSED")
