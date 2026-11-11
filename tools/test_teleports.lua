-- CompletionRoute :: tools/test_teleports.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- Offline tests of teleports as router edges (Data/Teleports.lua, Routing/Teleports.lua), against stubs (no client):
--   * the data: unique keys, every field the router reads, and every landing point recomputed from its citation
--     (a Warcraft Wiki map coordinate on the retail map table tools/maps_retail.lua, or a TaxiNodes position)
--   * Classic Era, an Alliance mage: Teleport: Stormwind is a first leg only when known, the rune is in the bags and the
--     cooldown is at most 15 minutes; never on a pairwise query; the arrow casts it; the learned landing spot sticks;
--     an engineering trinket counts only while worn
--   * Retail, a Horde character: a hearth toy stands in for a missing Hearthstone (secure "toy" use), the Garrison
--     Hearthstone needs its quest, and a turn-in of that quest re-prices only the from-player costs
-- DB2 ids and names are checked separately by tools/check_teleports.py (needs the tools/db2 tables).
-- Run: luajit tools/test_teleports.lua   (from repo root)
package.path = "./?.lua;" .. package.path
local passed, failed = 0, 0
local function t(name, cond, detail)
    if cond then passed = passed + 1 print("ok   " .. name)
    else failed = failed + 1 print("FAIL " .. name .. (detail and (" :: " .. tostring(detail)) or "")) end
end

-- ---------------------------------------------------------------------------
-- 1) the data alone
-- ---------------------------------------------------------------------------
do
    local D = {}
    assert(loadfile("CompletionRoute/Data/Teleports.lua"))("CompletionRoute", D)
    local data = D.TeleportData
    t("data loads", type(data) == "table" and #data > 40, data and #data)
    local RET = dofile("tools/maps_retail.lua")
    local TAXI = {}
    local function taxiNode(fl, id)
        if not TAXI[fl] then
            local T = {}
            assert(loadfile("CompletionRoute/Data/Taxi_" .. fl .. ".lua"))("CompletionRoute", T)
            TAXI[fl] = T.TaxiData[fl]
        end
        return TAXI[fl].nodes[id]
    end
    local FLAV = { era = true, tbc = true, mop = true, retail = true }
    local CLASS = { MAGE = true, DRUID = true, DEATHKNIGHT = true, MONK = true, SHAMAN = true }
    local keys, bad, maxErr = {}, {}, 0
    for i, e in ipairs(data) do
        local why
        if type(e.key) ~= "string" or keys[e.key] then why = "missing or duplicate key" end
        keys[e.key or i] = true
        if not why and e.kind ~= "spell" and e.kind ~= "item" then why = "kind" end
        if not why and type(e.id) ~= "number" then why = "id" end
        if not why and (type(e.name) ~= "string" or e.name == "") then why = "name" end
        if not why and (type(e.src) ~= "string" or e.src == "") then why = "no source" end
        if not why and type(e.flavors) ~= "table" then why = "flavors" end
        if not why then for f in pairs(e.flavors) do if not FLAV[f] then why = "unknown flavor " .. f end end end
        if not why and e.class and not CLASS[e.class] then why = "class " .. tostring(e.class) end
        if not why and e.fac and e.fac ~= "A" and e.fac ~= "H" then why = "fac" end
        if not why and e.kind == "item" and type(e.spell) ~= "number" then why = "item without its use spell" end
        if not why and e.hearth then
            if e.to or e.cite then why = "a hearth stand-in has its own destination" end
        elseif not why then
            local to, c = e.to, e.cite
            if type(to) ~= "table" or type(to[1]) ~= "number" or type(to[2]) ~= "number" or type(to[3]) ~= "number" or type(to[4]) ~= "string" then
                why = "to = { inst, wx, wy, name }"
            elseif type(c) ~= "table" then why = "no cite"
            else
                local inst, wx, wy
                if c.taxi then
                    local n = taxiNode(c.flavor, c.taxi)
                    if n then inst, wx, wy = n[2], n[3], n[4] end
                else
                    local m = RET[c[1]]
                    if m then inst, wx, wy = m[2], m[3] - (c[3] / 100) * m[6], m[4] - (c[2] / 100) * m[5] end
                end
                if not inst then why = "cite does not resolve"
                elseif inst ~= to[1] then why = ("cite instance %s, to says %s"):format(inst, to[1])
                else
                    local err = math.sqrt((wx - to[2]) ^ 2 + (wy - to[3]) ^ 2)
                    if err > maxErr then maxErr = err end
                    if err > 1 then why = ("to is %.1f yd from its citation"):format(err) end
                end
            end
        end
        if why then bad[#bad + 1] = tostring(e.key) .. ": " .. why end
    end
    t("every entry is complete and its landing point matches its citation (max error " .. ("%.2f"):format(maxErr) .. " yd)", #bad == 0, table.concat(bad, "; "))
end

-- ---------------------------------------------------------------------------
-- a fresh stubbed client for one flavor
-- ---------------------------------------------------------------------------
local SPELLS, BAGS, WORN, TOYS, TOY_UNUSABLE, SPELL_CD, ITEM_CD
local function boot(flavor, toc, faction, class, race)
    STUB_MAPS = dofile("tools/maps_" .. flavor .. ".lua")
    local NS = {}
    dofile("tools/stubs.lua")
    SPELLS, BAGS, WORN, TOYS, TOY_UNUSABLE, SPELL_CD, ITEM_CD = {}, { [6948] = 1 }, {}, {}, {}, {}, {}
    function GetBuildInfo() return "x", "0", "2026", toc end
    function UnitFactionGroup() return faction end
    function UnitClass() return class, class end
    function UnitRace() return race, race end
    function UnitLevel() return 60 end
    function GetTime() return 100000 + os.clock() end       -- cooldown starts are absolute times, well above 0
    function IsPlayerSpell(id) return SPELLS[id] or false end
    function GetSpellCooldown(id) local c = SPELL_CD[id] if c then return GetTime() - (c[2] - c[1]), c[2] end return 0, 0 end
    C_Item.GetItemCount = function(id) return BAGS[id] or 0 end
    function IsEquippedItem(id) return WORN[id] or false end
    C_Container.GetItemCooldown = function(id) local c = ITEM_CD[id] if c then return GetTime() - (c[2] - c[1]), c[2] end return 0, 0 end
    if flavor == "retail" then
        function PlayerHasToy(id) return TOYS[id] or false end
        C_ToyBox = { IsToyUsable = function(id) return not TOY_UNUSABLE[id] end }
    else
        PlayerHasToy, C_ToyBox = nil, nil
    end
    local function load(path) assert(loadfile("CompletionRoute/" .. path))("CompletionRoute", NS) end
    local taxi = { era = "Data/Taxi_era.lua", retail = "Data/Taxi_retail.lua" }
    for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", taxi[flavor], "Data/Transit.lua",
        "Data/Teleports.lua", "Data/Access.lua", "Data/Inns.lua", "Data/ZoneAliases.lua", "Data/Roads_ek.lua", "Data/Roads_kalimdor.lua",
        "Routing/TravelGraph.lua", "Routing/Teleports.lua", "Routing/Roads.lua", "Routing/StepOrder.lua", "Routing/Router.lua",
        "Core/Account.lua", "Core/Progress.lua" }) do load(f) end
    CompletionRouteDB, CompletionRouteCharDB = nil, nil
    for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", "CompletionRoute") end
    NS.Print, NS.Debug = function() end, function() end
    NS.db.profile.routing.taxiPolicy = "faction"
    NS.TravelGraph.Build()
    return NS
end
local function place(map, x, y)
    local wx, wy, inst = z2w(x, y, map)
    PLAYER = { map = map, x = x, y = y, wx = wx, wy = wy, inst = inst }
end
local function legOf(path, mode)
    for _, l in ipairs(path and path.legs or {}) do if l.mode == mode then return l end end
end

-- ---------------------------------------------------------------------------
-- 2) Classic Era, Alliance mage in southern Westfall, going to Stormwind's Trade District
-- ---------------------------------------------------------------------------
do
    local NS = boot("era", 11507, "Alliance", "MAGE", "Human")
    local TG, T, R, U = NS.TravelGraph, NS.Teleports, NS.Router, NS.Util
    place(1436, 0.40, 0.75)
    local gx, gy, gi = z2w(0.60, 0.60, 1453)
    local function route(opts) return TG.FindPath(PLAYER.wx, PLAYER.wy, PLAYER.inst, gx, gy, gi, opts or {}) end
    T.Recheck()
    t("era: a mage who has not learned Teleport: Stormwind gets no teleport", not legOf(route(), "teleport"))
    SPELLS[3561] = true
    BAGS[17031] = nil
    local gen = TG.oneShotGen
    T.Recheck()
    t("era: known but no Rune of Teleportation: not offered", #T.Available() == 0 and not legOf(route(), "teleport"))
    BAGS[17031] = 5
    T.Recheck()
    t("era: learning the reagent changes what is offered (one-shot generation bumped)", TG.oneShotGen > gen, TG.oneShotGen - gen)
    local p = route()
    local tl = legOf(p, "teleport")
    t("era: with the rune the route starts with Teleport: Stormwind", p and p.legs[1].mode == "teleport" and tl.data.kind == "spell" and tl.data.id == 3561,
      p and TG.Describe(p))
    t("era: the teleport lands at the Wizard's Sanctum", tl and math.abs(tl.to.wx + 9041.1) < 1 and math.abs(tl.to.wy - 917.6) < 1)
    local pair = route({ hearth = false })
    t("era: a pairwise (hearth = false) query never spends a teleport", pair and not legOf(pair, "teleport"))
    SPELL_CD[3561] = { 20 * 60, 30 * 60 }      -- 20 of 30 minutes left
    t("era: 20 minutes of cooldown left: not offered (the hearth's 15-minute rule)", #T.Available() == 0)
    SPELL_CD[3561] = { 10 * 60, 30 * 60 }
    local av = T.Available()
    t("era: 10 minutes left: offered, and the wait is priced in", #av == 1 and math.abs(av[1].cd - 600) < 2, av[1] and av[1].cd)
    SPELL_CD[3561] = nil
    NS.db.profile.routing.teleports = false
    t("era: the Options switch turns teleports off", #T.Available() == 0 and not legOf(route(), "teleport"))
    NS.db.profile.routing.teleports = true
    -- the arrow: a guide step in Stormwind, the secure button casts the spell
    NS.Guide.Register({ id = "t:tele", name = "Tele Test", faction = "Alliance", minlevel = 1, maxlevel = 60, source = "test",
                        text = "R Trade District|M|60,60|Z|1453; Stormwind City|" })
    NS.Progress.Load("t:tele")
    R.Invalidate()
    local rec = R.Recommendation()
    t("era: the arrow offers the teleport as a click", rec and rec.mode == "teleport" and rec.spell == 3561 and not rec.item and rec.text:find("saves time", 1, true),
      rec and (rec.mode .. " " .. tostring(rec.text)))
    -- the landing spot actually reached is learned (and a far-off arrival is not)
    for _, h in ipairs(NS.wowHandlers.UNIT_SPELLCAST_SUCCEEDED or {}) do h("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 3561) end
    t("era: an arrival 600 yd off the data point is not learned", T.OnJump({ inst = 0, wx = -9041.1 + 600, wy = 917.6 }) == false)
    for _, h in ipairs(NS.wowHandlers.UNIT_SPELLCAST_SUCCEEDED or {}) do h("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 3561) end
    t("era: the real landing spot is learned", T.OnJump({ inst = 0, wx = -9030.0, wy = 925.0 }) == true)
    local inst, wx, wy = T.Dest(NS.TeleportData[1])
    t("era: the learned spot replaces the data point", inst == 0 and wx == -9030.0 and wy == 925.0)
    t("era: no jump without a cast", T.OnJump({ inst = 0, wx = -9030.0, wy = 925.0 }) == false)
    -- Classic engineering transporters are trinkets: in the bags is not enough
    local function offered(key) for _, a in ipairs(T.Available()) do if a.key == key then return a end end end
    BAGS[18984] = 1
    T.Recheck()
    t("era: Dimensional Ripper in the bags but not worn: not offered", not offered("eng_everlook"))
    WORN[18984] = true
    T.Recheck()
    local rip = offered("eng_everlook")
    t("era: worn Dimensional Ripper - Everlook: offered as an item", rip and rip.kind == "item" and rip.id == 18984)
    ITEM_CD[18984] = { 3 * 3600, 4 * 3600 }
    t("era: the Ripper's 4-hour cooldown with 3 hours left: not offered", not offered("eng_everlook"))
    -- class and faction filters
    NS.player.class = "WARRIOR"
    t("era: a warrior has no mage teleports among the candidates", (function()
        for _, e in ipairs(T.Candidates().move) do if e.class == "MAGE" then return false end end
        return true end)())
    NS.player.class, NS.player.faction = "MAGE", "Horde"
    t("era: a Horde mage is not offered Teleport: Stormwind", (function()
        for _, e in ipairs(T.Candidates().move) do if e.id == 3561 then return false end end
        return true end)())
    NS.player.faction = "Alliance"
    t("era: no hearth stand-ins exist on Classic Era (bag Hearthstone only)", #T.Candidates().hearth == 0)
end

-- ---------------------------------------------------------------------------
-- 3) Retail, Horde character in Feralas, bound at Razor Hill, with no Hearthstone in the bags
-- ---------------------------------------------------------------------------
do
    local NS = boot("retail", 120100, "Horde", "WARRIOR", "Orc")
    local TG, T, R, U = NS.TravelGraph, NS.Teleports, NS.Router, NS.Util
    function GetBindLocation() return "Razor Hill" end
    place(69, 0.5, 0.5)
    local gx, gy, gi = z2w(0.525, 0.419, 1)
    BAGS[6948] = nil
    TOYS[54452] = true                          -- Ethereal Portal
    T.Recheck()
    local ready, cd, kind, id, isToy = U.HearthReady()
    t("retail: no Hearthstone in the bags: a hearth toy stands in", ready and id == 54452 and isToy == true, tostring(id))
    local p = TG.FindPath(PLAYER.wx, PLAYER.wy, PLAYER.inst, gx, gy, gi, {})
    local hl = legOf(p, "hearth")
    t("retail: Feralas -> Razor Hill hearths with the toy", p and p.legs[1].mode == "hearth" and hl.data.id == 54452 and hl.data.toy == true,
      p and TG.Describe(p))
    t("retail: the toy's cast counts as a hearth (bind recorder, H steps)", T.IsHearthSpell(75136) and not T.IsHearthSpell(3561))
    BAGS[6948] = 1
    t("retail: with a Hearthstone in the bags the stone is used", select(4, U.HearthReady()) == 6948)
    BAGS[6948] = nil
    TOY_UNUSABLE[54452] = true
    T.Recheck()
    t("retail: a toy the client says is unusable is not used", (select(4, U.HearthReady())) == nil)
    TOY_UNUSABLE[54452] = nil
    T.Recheck()
    NS.Guide.Register({ id = "t:hs", name = "HS Test", faction = "Horde", minlevel = 1, maxlevel = 80, source = "test", text = "H Hearth to Razor Hill|" })
    NS.Progress.Load("t:hs")
    local rec = R.Recommendation()
    t("retail: an H step offers the hearth toy through the secure toy action", rec and rec.mode == "hearth" and rec.item == 54452 and rec.toy == true,
      rec and (tostring(rec.item) .. " " .. tostring(rec.toy)))
    -- Garrison Hearthstone: owned account-wide as a toy, usable only with a garrison
    TOYS[110560] = true
    T.Recheck()
    local function offered(key) for _, a in ipairs(T.Available()) do if a.key == key then return a end end end
    t("retail: Garrison Hearthstone without Establish Your Garrison: not offered", not offered("garrison_hearthstone_h"))
    t("retail: the Alliance garrison is never a Horde candidate", (function()
        for _, e in ipairs(T.Candidates().move) do if e.key == "garrison_hearthstone_a" then return false end end
        return true end)())
    t("retail: the garrison quest matters to the teleports", T.QuestMatters(34378) and not T.QuestMatters(84720))
    local gen = TG.oneShotGen
    local built = TG.stats.builds
    t("retail: its turn-in does not rebuild the graph", TG.OnQuestTurnedIn(34378) == false and TG.built and TG.stats.builds == built)
    t("retail: its turn-in re-prices the from-player costs", TG.oneShotGen > gen)
    T.Recheck()
    local g = offered("garrison_hearthstone_h")
    t("retail: after the turn-in the Garrison Hearthstone is offered as a toy, landing in Frostwall", g and g.kind == "toy" and g.inst == 1116, g and g.dest)
    -- the leg data the arrow reads for a toy teleport
    local fx, fy, fi = z2w(0.5, 0.5, 590)          -- Frostwall
    local pg = TG.FindPath(PLAYER.wx, PLAYER.wy, PLAYER.inst, fx, fy, fi, {})
    local gl = legOf(pg, "teleport")
    t("retail: a route to Frostwall uses the Garrison Hearthstone, as a toy", gl and gl.data.kind == "item" and gl.data.id == 110560 and gl.data.toy == true,
      pg and TG.Describe(pg))
end

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
print("ALL TELEPORT TESTS PASSED")
