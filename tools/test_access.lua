-- Offline check of Data/Access.lua on the retail map table: every entry resolves, every chain step parses and
-- resolves a zone, and from Orgrimmar (Horde) / Stormwind (Alliance) a route to each destination exists that
-- goes through the chain. Then: a fake guide whose first step is on the Siren Isle gets the chain injected.
--   luajit tools/test_access.lua
-- The same per-entry checks then run on the MoP Classic map table for the entries flagged for mop
-- (`luajit tools/test_access.lua --flavor mop`, started by the retail run): Pandaria and the Isle of Thunder.
package.path = "./?.lua;" .. package.path
local FL = (arg[1] == "--flavor" and arg[2]) or "retail"
STUB_MAPS = dofile("tools/maps_" .. FL .. ".lua")
local ADDON, NS = "CompletionRoute", {}
dofile("tools/stubs.lua")
function GetBuildInfo() return "x", "0", "2026", FL == "mop" and 50504 or 120100 end
FACTION, LEVEL = "Horde", 80
function UnitFactionGroup() return FACTION end
function UnitLevel() return LEVEL end
PLAYER = { map = 85, x = 0.5, y = 0.5 }
local function place(map, x, y) local wx, wy, inst = z2w(x, y, map) PLAYER.map, PLAYER.x, PLAYER.y, PLAYER.wx, PLAYER.wy, PLAYER.inst = map, x, y, wx, wy, inst end
local function load(path) local fn = assert(loadfile("CompletionRoute/" .. path)) fn(ADDON, NS) end
for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", "Data/Taxi_" .. FL .. ".lua", "Data/Transit.lua", "Data/Access.lua", "Data/Inns.lua", "Data/ZoneAliases.lua",
    "Data/Roads_ek.lua", "Data/Roads_kalimdor.lua", "Routing/CostModel.lua", "Routing/TravelGraph.lua", "Routing/Roads.lua", "Routing/StepOrder.lua", "Routing/Router.lua", "Core/Account.lua", "Core/Progress.lua" }) do load(f) end
NS.flavor = FL
NS.db = NS.db or { profile = { routing = {} }, char = { knownTaxi = {}, done = {}, skipped = {} }, global = {} }
NS.db.global = NS.db.global or {}
NS.db.profile.routing = NS.db.profile.routing or {}
local TG, G, U = NS.TravelGraph, NS.Guide, NS.Util
local fails = 0
local function check(ok, msg) if ok then print("  ok   " .. msg) else fails = fails + 1 print("  FAIL " .. msg) end end
for _, fac in ipairs({ "Horde", "Alliance" }) do
    FACTION = fac NS.player = { faction = fac }
    place(fac == "Horde" and 85 or 84, 0.5, 0.5)
    TG.built = false TG.Build()
    print(("%s from %s: %d nodes, %d access edges, unresolved: %s"):format(fac, fac == "Horde" and "Orgrimmar" or "Stormwind", #TG.nodes, #TG.accessEdges, table.concat(TG.unresolved or {}, "; ")))
    for _, a in ipairs(NS.AccessData) do
        -- an entry for another client is never built here (TG.Build reads `flavors`); it is checked by that client's run
        if ((not a.fac) or a.fac == (fac == "Horde" and "H" or "A")) and ((not a.flavors) or a.flavors[FL]) then
            local bx, by, bi = TG.zoneToWorld(a.to[1], a.to[2], a.to[3])
            check(bx ~= nil, a.key .. " destination resolves")
            local p = bx and TG.FindPath(PLAYER.wx, PLAYER.wy, PLAYER.inst, bx, by, bi, {})
            local via = false
            for _, l in ipairs(p and p.legs or {}) do if l.mode == "access" and l.data.access.key == a.key then via = true end end
            check(p ~= nil, a.key .. " route exists (cost " .. tostring(p and math.floor(p.cost)) .. ")")
            check(via, a.key .. " route uses the chain: " .. (p and TG.Describe(p) or "-"):sub(1, 110))
            local steps = NS.Access.ParseSteps(a, "test")
            check(#steps > 0, a.key .. " chain parses: " .. #steps .. " steps")
            local located = 0
            for _, s in ipairs(steps) do if NS.Router.StepWorld(s) then located = located + 1 end end
            check(located >= #steps - 3, a.key .. " chain steps located " .. located .. "/" .. #steps)
            -- MoP Classic chains are written quest by quest (no "follow the chapter" N summaries like the retail ones):
            -- every quest the chain accepts is turned in inside the chain, before the next one is accepted.  A chain that
            -- leaves one open skips the quest its successor needs (the Horde way into Pandaria accepted Into the Mists
            -- and then Touching Ground, without turning in Into the Mists or doing Paint it Red! in between)
            if a.flavors and a.flavors.mop then
            local open, order = {}, true
            for _, s in ipairs(steps) do
                local q = s.qid and s.qid[1]
                if q and s.action == "A" then
                    if next(open) ~= nil then order = false end
                    open[q] = true
                elseif q and s.action == "T" then
                    open[q] = nil
                end
            end
            check(order and next(open) == nil, a.key .. " chain turns in each quest before it accepts the next")
            end
        end
    end
end
if FL ~= "retail" then
    if fails > 0 then print(fails .. " ACCESS TESTS FAILED (" .. FL .. ")") os.exit(1) end
    print("ALL ACCESS TESTS PASSED (" .. FL .. ")")
    os.exit(0)
end
do
    local rc = os.execute("luajit tools/test_access.lua --flavor mop")
    check(rc == 0 or rc == true, "MoP Classic access entries (luajit tools/test_access.lua --flavor mop)")
end
-- prefix injection: fake guide starting on the Siren Isle, Horde at Orgrimmar
FACTION = "Horde" NS.player = { faction = "Horde" } place(85, 0.5, 0.5) TG.built = false TG.Build()
G.Register({ id = "test:siren", name = "Siren test", type = "Test", text = "C Kill things on the isle|QID|99999|M|50,50|Z|Siren Isle|\nT Turn in|QID|99999|M|51,51|Z|Siren Isle|" })
local steps = G.Steps("test:siren")
local prefix = NS.Access.PrefixFor(steps, "test:siren")
check(prefix and #prefix == 6 and prefix[1].index == -6 and prefix[6].index == -1, "Siren Isle guide gets the 6-step unlock chain with indices -6..-1")
G.Register({ id = "test:harandar", name = "Harandar test", type = "Test", text = "C Pet|QID|99998|M|57.22,51.08|Z|Harandar|" })
local hp = NS.Access.PrefixFor(G.Steps("test:harandar"), "test:harandar")
local keys = {} for _, st in ipairs(hp or {}) do keys[st.access] = true end
check(hp and #hp == 7 + 2 + 3 + 4 and keys.midnight_h and keys.midnight_silvermoon and keys.midnight_eversong and keys.midnight_harandar and hp[1].index == -#hp,
      "Harandar guide gets the stacked chains intro+Silvermoon+Eversong+Harandar (" .. tostring(hp and #hp) .. " steps)")
-- unlocked: no prefix
C_QuestLog.IsQuestFlaggedCompleted = function(q) return q == 84720 end
TG.built = false TG.Build()
check(NS.Access.PrefixFor(steps, "test:siren") == nil, "once 84720 is complete no chain is injected (airship edge used instead)")
local bx, by, bi = TG.zoneToWorld("Siren Isle", 69.3, 48.0)
local p = TG.FindPath(PLAYER.wx, PLAYER.wy, PLAYER.inst, bx, by, bi, {})
check(p and TG.Describe(p):find("Skaggit") ~= nil, "unlocked route goes via the airship: " .. (p and TG.Describe(p):sub(1, 120) or "-"))

-- Turn-ins (docs/ROUTING.md "What changes the graph"): an ordinary turn-in keeps the graph and every kept cost; the
-- turn-in of an access chain's unlock quest rebuilds only the access edges, even before the client's completed-quest
-- flag catches up with the QUEST_TURNED_IN event.
do
    local kx, ky, ki = TG.zoneToWorld("Tazavesh", 59.74, 83.36)
    local function viaRift(path)     -- the unlocked K'aresh edge (the Spatial Rift), not the locked chain
        for _, l in ipairs(path and path.legs or {}) do
            if l.mode == "access" and l.data.access.key == "karesh" then return not l.data.locked end
        end
        return false
    end
    local p0 = TG.FindPath(PLAYER.wx, PLAYER.wy, PLAYER.inst, kx, ky, ki, {})
    check(p0 and not viaRift(p0), "K'aresh locked: the route does the Locus-Walker chain")
    local builds, rebuilds, cache, nodes = TG.stats.builds, TG.stats.accessRebuilds, TG.pathCache, #TG.nodes
    TG.FindPath(PLAYER.wx, PLAYER.wy, PLAYER.inst, kx, ky, ki, { hearth = false })   -- something worth keeping in the cache
    check(TG.OnQuestTurnedIn(424242) == false and TG.built and not TG.accessDirty, "an ordinary turn-in does not touch the graph")
    TG.FindPath(PLAYER.wx, PLAYER.wy, PLAYER.inst, kx, ky, ki, {})
    check(TG.stats.builds == builds and TG.stats.accessRebuilds == rebuilds and TG.pathCache == cache,
          "an ordinary turn-in keeps the graph and the path cache (builds " .. TG.stats.builds - builds .. ", access rebuilds " .. TG.stats.accessRebuilds - rebuilds .. ")")
    check(TG.unlockQuests[84957] == "access", "K'aresh unlock quest 84957 is in the unlock set")
    check(TG.OnQuestTurnedIn(84957) == true and TG.accessDirty, "the unlock turn-in marks the access edges dirty")
    local p1 = TG.FindPath(PLAYER.wx, PLAYER.wy, PLAYER.inst, kx, ky, ki, {})
    check(TG.stats.builds == builds and TG.stats.accessRebuilds == rebuilds + 1, "the unlock rebuilt only the access edges, not the whole graph")
    check(TG.pathCache ~= cache, "the unlock dropped the path cache (and with it StepOrder's kept costs)")
    check(#TG.nodes == nodes, "access-only rebuild keeps the node count (" .. #TG.nodes .. " vs " .. nodes .. ")")
    check(viaRift(p1), "after the unlock turn-in the route takes the Spatial Rift: " .. (p1 and TG.Describe(p1):sub(1, 120) or "-"))
    -- a full build from scratch agrees with the access-only rebuild
    TG.built = false TG.Build()
    local p2 = TG.FindPath(PLAYER.wx, PLAYER.wy, PLAYER.inst, kx, ky, ki, {})
    check(#TG.nodes == nodes and p2 and p1 and math.abs(p2.cost - p1.cost) < 0.01,
          ("full rebuild matches the access-only rebuild (%s vs %s s)"):format(tostring(p2 and math.floor(p2.cost)), tostring(p1 and math.floor(p1.cost))))
end

-- `cond` on a Data/Transit.lua entry (TG.CondOK): the edge exists only for characters it holds for; a quest cond is
-- re-read on the turn-in of that quest (a full rebuild, since it is a transit edge)
do
    local saved = NS.TransitData
    local extra = { from = { "Orgrimmar", 50, 50 }, to = { "Silithus", 50, 50 }, mode = "portal", cost = 5, title = "Test cond portal",
                    cond = { class = "MAGE", quest = 424243 } }
    NS.TransitData = { extra }
    for _, row in ipairs(saved) do NS.TransitData[#NS.TransitData + 1] = row end
    local function hasEdge()
        for _, n in ipairs(TG.nodes) do for _, e in ipairs(n.edges) do if e.title == "Test cond portal" then return true end end end
        return false
    end
    NS.player = { faction = "Horde", class = "WARRIOR" }
    TG.built = false TG.Build()
    check(not hasEdge(), "cond: a warrior gets no mage-only edge")
    NS.player.class = "MAGE"
    TG.built = false TG.Build()
    check(not hasEdge(), "cond: a mage without the cond quest gets no edge")
    check(TG.unlockQuests[424243] == "full", "cond quest registered for a full rebuild")
    check(TG.OnQuestTurnedIn(424243) == true and not TG.built, "cond quest turn-in marks the graph for a rebuild")
    TG.Ensure()
    check(hasEdge(), "cond: a mage who turned the quest in gets the edge")
    check(TG.CondOK({ notQuest = 424243 }) == false and TG.CondOK({ level = 1 }) and TG.CondOK(function() return true end) and TG.CondOK(nil),
          "cond: notQuest / level / function forms")
    NS.TransitData = saved
    NS.player = { faction = "Horde" }
    TG.built = false TG.Build()
    -- the Maelstrom portal is conjured for the quest The Maelstrom (27203): its edge goes once that quest is turned in
    local function maelstrom()
        for _, n in ipairs(TG.nodes) do for _, e in ipairs(n.edges) do
            if e.title and e.title:find("portal to the Maelstrom", 1, true) then return true end
        end end
        return false
    end
    check(maelstrom() and TG.unlockQuests[27203] == "full", "Maelstrom portal edge exists before The Maelstrom (27203) is turned in")
    TG.OnQuestTurnedIn(27203) TG.Build()
    check(not maelstrom(), "Maelstrom portal edge is gone after The Maelstrom (27203) is turned in")
    TG.turnedIn[27203] = nil
    TG.built = false TG.Build()
end

-- Legion Class Order Halls: verify all 12 class order halls resolve and are routable
local order_halls = {
    { map = "695", name = "Skyhold (Warrior)" },
    { map = "702", name = "Netherlight Temple (Priest)" },
    { map = "717", name = "Dreadscar Rift (Warlock)" },
    { map = "726", name = "The Maelstrom (Shaman)" },
    { map = "734", name = "Hall of the Guardian (Mage)" },
    { map = "739", name = "Trueshot Lodge (Hunter)" },
    { map = "747", name = "The Dreamgrove (Druid)" },
    { map = "720", name = "The Fel Hammer (Demon Hunter)" },
    { map = "647", name = "Acherus: The Ebon Hold (Death Knight)" },
    { map = "709", name = "The Wandering Isle (Monk)" },
    { map = "628", name = "Dalaran Underbelly (Rogue)" },
    { map = "24",  name = "Light's Hope Chapel (Paladin)" },
}
for _, oh in ipairs(order_halls) do
    local ox, oy, oi = TG.zoneToWorld(oh.map, 50, 50)
    check(ox ~= nil, oh.name .. " map " .. oh.map .. " resolves")
    local rp = ox and TG.FindPath(PLAYER.wx, PLAYER.wy, PLAYER.inst, ox, oy, oi, {})
    check(rp ~= nil, oh.name .. " routable from capital (cost " .. tostring(rp and math.floor(rp.cost)) .. "s)")
end

-- Extended Transit Destinations (Shadowlands, Dragonflight, BfA, Darkmoon)
local extended_destinations = {
    { map = "1543", name = "The Maw (Shadowlands)" },
    { map = "1911", name = "Torghast (Shadowlands)" },
    { map = "1961", name = "Korthia (Shadowlands)" },
    { map = "1970", name = "Zereth Mortis (Shadowlands)" },
    { map = "2133", name = "Zaralek Cavern (Dragonflight)" },
    { map = "2200", name = "Emerald Dream (Dragonflight)" },
    { map = "Nazjatar", name = "Nazjatar (BfA)" },
    { map = "1462", name = "Mechagon (BfA)" },
    { map = "407",  name = "Darkmoon Island (World Events)" },
}
for _, ed in ipairs(extended_destinations) do
    local ex, ey, ei = TG.zoneToWorld(ed.map, 50, 50)
    check(ex ~= nil, ed.name .. " map " .. ed.map .. " resolves")
    local ep = ex and TG.FindPath(PLAYER.wx, PLAYER.wy, PLAYER.inst, ex, ey, ei, {})
    check(ep ~= nil, ed.name .. " routable from capital (cost " .. tostring(ep and math.floor(ep.cost)) .. "s)")
end

-- Dungeon doors (Core/Instances.lua).  No door table ships: a door is known once the player has walked in (learned),
-- imported one, or the Retail journal gives it.  Without one a step inside The Deadmines is not sent to a door; with a
-- learned door it routes there from Stormwind, and a player standing inside routes back out through it.
do
    load("Core/Instances.lua")
    check(NS.EntranceSeed == nil, "no seeded door table is loaded")
    FACTION = "Alliance" NS.player = { faction = "Alliance" } place(84, 0.5, 0.5) TG.built = false TG.Build()
    local dm, westfall = U.MapIDByName("The Deadmines"), U.MapIDByName("Westfall")
    check(dm ~= nil and westfall ~= nil, "The Deadmines and Westfall resolve (" .. tostring(dm) .. ", " .. tostring(westfall) .. ")")
    local st = { action = "C", zone = dm, coords = { { x = 0.5, y = 0.5 } } }
    NS.Router.TravelSecondsFromPlayer(st)
    check(st._locSource ~= "entrance" and NS.Instances.Entrance(dm) == nil, "no door known yet: the Deadmines step is not sent to a door")
    -- the player walks in once: Core/Instances.lua stores the last outdoor position under "map:<interior map>"
    NS.db.global.instanceEntrances = { ["map:" .. dm] = { map = westfall, x = 0.43, y = 0.72, name = "The Deadmines", learned = 1 } }
    st = { action = "C", zone = dm, coords = { { x = 0.5, y = 0.5 } } }
    local secs = NS.Router.TravelSecondsFromPlayer(st)
    check(secs ~= nil and st._locSource == "entrance", "with a learned door the Deadmines step routes to it from Stormwind (" .. tostring(secs and math.floor(secs)) .. "s)")
    place(dm, 0.5, 0.5)
    local out = NS.Router.TravelSecondsFromPlayer({ action = "T", zone = 84, coords = { { x = 0.5, y = 0.5 } } })
    check(out ~= nil, "from inside the Deadmines a Stormwind step routes via the learned door (" .. tostring(out and math.floor(out)) .. "s)")
    place(84, 0.5, 0.5)
    NS.db.global.instanceEntrances = nil
end

-- Achievement steps (tools/gen_completion_guides.py): |ACH|id;crit| parses and ticks from the client API
local sa = G.ParseLine("C Explore Elwynn|ACH|776;1234|N|x|", 1)
check(sa and sa.ach == 776 and sa.achCrit == 1234, "ACH tag parses achievement + criteria-tree id")
local earned = {}
GetAchievementInfo = function(id) return id, "a", 10, earned[id] or false end
GetAchievementCriteriaInfoByID = function(id, c) return "c", 0, earned[c] or false end
check(not NS.Progress.CheckStep(sa), "ACH step open while criterion unearned")
earned[1234] = true
check(NS.Progress.CheckStep(sa), "ACH step ticks once the criterion is earned")
local sm = G.ParseLine("N Gronnlings Abound|MISSION|2|N|x|", 1)
check(sm and sm.mission == 2, "MISSION tag parses")
GetAchievementInfo, GetAchievementCriteriaInfoByID = nil, nil

print(fails == 0 and "ALL ACCESS TESTS PASSED" or (fails .. " ACCESS TESTS FAILED"))
os.exit(fails == 0 and 0 or 1)

