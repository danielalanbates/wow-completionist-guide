-- Offline check of Data/Access.lua on the retail map table: every entry resolves, every chain step parses and
-- resolves a zone, and from Orgrimmar (Horde) / Stormwind (Alliance) a route to each destination exists that
-- goes through the chain. Then: a fake guide whose first step is on the Siren Isle gets the chain injected.
--   luajit tools/test_access.lua
package.path = "./?.lua;" .. package.path
STUB_MAPS = dofile("tools/maps_retail.lua")
local ADDON, NS = "CompletionRoute", {}
dofile("tools/stubs.lua")
function GetBuildInfo() return "x", "0", "2026", 120100 end
FACTION, LEVEL = "Horde", 80
function UnitFactionGroup() return FACTION end
function UnitLevel() return LEVEL end
PLAYER = { map = 85, x = 0.5, y = 0.5 }
local function place(map, x, y) local wx, wy, inst = z2w(x, y, map) PLAYER.map, PLAYER.x, PLAYER.y, PLAYER.wx, PLAYER.wy, PLAYER.inst = map, x, y, wx, wy, inst end
local function load(path) local fn = assert(loadfile("CompletionRoute/" .. path)) fn(ADDON, NS) end
for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", "Data/Taxi_retail.lua", "Data/Transit.lua", "Data/Access.lua", "Data/Inns.lua", "Data/ZoneAliases.lua",
    "Data/Roads_ek.lua", "Data/Roads_kalimdor.lua", "Routing/TravelGraph.lua", "Routing/Roads.lua", "Routing/StepOrder.lua", "Routing/Router.lua", "Core/Account.lua", "Core/Progress.lua" }) do load(f) end
NS.flavor = "retail"
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
        if (not a.fac) or a.fac == (fac == "Horde" and "H" or "A") then
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
        end
    end
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

print(fails == 0 and "ALL ACCESS TESTS PASSED" or (fails .. " ACCESS TESTS FAILED"))
os.exit(fails == 0 and 0 or 1)

