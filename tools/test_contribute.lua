-- CompletionRoute :: tools/test_contribute.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- Offline test of Core/Contribute.lua: what is recorded and when, how the most likely places are worked out, that a
-- step without a point is routed to its learned spot, and that the export holds no names.
-- Run: luajit tools/test_contribute.lua   (from repo root)
package.path = "./?.lua;" .. package.path
local ADDON, NS = "CompletionRoute", {}
dofile("tools/stubs.lua")
local z2w = z2w
PLAYER = { map = 1429, x = 0.487, y = 0.42 } PLAYER.wx, PLAYER.wy, PLAYER.inst = z2w(PLAYER.x, PLAYER.y, PLAYER.map)
local function stand(x, y, map)
    PLAYER.map, PLAYER.x, PLAYER.y = map or PLAYER.map, x / 100, y / 100
    PLAYER.wx, PLAYER.wy, PLAYER.inst = z2w(PLAYER.x, PLAYER.y, PLAYER.map)
end

local passed, failed = 0, 0
local function t(name, cond, detail)
    if cond then passed = passed + 1 print("ok   " .. name)
    else failed = failed + 1 print("FAIL " .. name .. (detail and (" :: " .. tostring(detail)) or "")) end
end

local W = { quests = {}, obj = {}, taxi = false, dead = false }
function UnitLevel() return 10 end
function UnitOnTaxi() return W.taxi end
function UnitIsDeadOrGhost() return W.dead end
C_QuestLog = {
    IsOnQuest = function(q) return W.quests[q] == "log" end,
    IsQuestFlaggedCompleted = function(q) return W.quests[q] == "done" end,
    IsComplete = function() return false end,
    GetLogIndexForQuestID = function(q) return W.quests[q] == "log" and 1 or nil end,
    GetQuestObjectives = function(q) return { { numFulfilled = W.obj[q] or 0, numRequired = 8, finished = false, text = "x" } } end,
    GetAllCompletedQuestIDs = function() return {} end,
    GetTitleForQuestID = function() return nil end,
}

-- the client's loot window, combat log, target and instance state (creatures, objects and items, 2026-11-12)
W.now, W.inst, W.guids, W.class, W.loot, W.fishing, W.cl, W.targetName = 1000, false, {}, {}, {}, false, {}, nil
function GetTime() return W.now end
function IsInInstance() return W.inst, W.inst and "party" or "none" end
function UnitGUID(u) return W.guids[u] end
function UnitClassification(u) return W.class[u] or "normal" end
function UnitName(u) if u == "target" then return W.targetName end return "Tester" end
function GetNumLootItems() return #W.loot end
function GetLootSourceInfo(slot) local l = W.loot[slot] return l and l.guid, 1 end
function GetLootSlotLink(slot) local l = W.loot[slot] return l and l.link end
function IsFishingLoot() return W.fishing end
function CombatLogGetCurrentEventInfo() return unpack(W.cl) end
-- the world map pins Contribute places (HereBeDragons-Pins): kept so the test can see the circles
local PINS = { world = {} }
function PINS:AddWorldMapIconMap(ref, frame, map, x, y) if ref == NS.Contribute then self.world[#self.world + 1] = { frame = frame, map = map, x = x, y = y } end end
function PINS:RemoveAllWorldMapIcons(ref) if ref == NS.Contribute then self.world = {} end end
function PINS:AddMinimapIconMap() end
function PINS:RemoveAllMinimapIcons() end
local stubLib = LibStub
LibStub = function(name, silent) if name == "HereBeDragons-Pins-2.0" then return PINS end return stubLib(name, silent) end

local function load(path) assert(loadfile("CompletionRoute/" .. path))(ADDON, NS) end
for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", "Data/Taxi_tbc.lua", "Data/Transit.lua", "Data/Access.lua",
    "Data/Inns.lua", "Data/ZoneAliases.lua", "Data/Roads_ek.lua", "Data/Roads_kalimdor.lua", "Routing/CostModel.lua", "Routing/TravelGraph.lua", "Routing/Roads.lua",
    "Routing/StepOrder.lua", "Routing/Router.lua", "Core/Account.lua", "Core/Professions.lua", "Core/Progress.lua", "Core/Recommend.lua", "Core/Contribute.lua",
    "UI/Beacon.lua" }) do load(f) end
CompletionRouteDB, CompletionRouteCharDB = nil, nil
for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", "CompletionRoute") end
NS.Print, NS.Debug, NS.Error = function() end, function() end, function() end
local C, P = NS.Contribute, NS.Progress

-- keys
t("accept key is the quest's", C.KeyFor({ action = "A", qid = { 179 } }) == "A:179")
t("turn-in key is the quest's", C.KeyFor({ action = "T", qid = { 179 } }) == "T:179")
t("objective key carries the objective", C.KeyFor({ action = "C", qid = { 179 }, qo = "2" }) == "C:179:2")
t("a step with no quest is keyed by guide and step key", C.KeyFor({ action = "N", guide = "g:x", key = "h:abc" }) == "G:g:x#h:abc")
t("a step with neither has no key", C.KeyFor({ action = "N" }) == nil)

-- off by default
t("off by default", C.Enabled() == false and C.Record("A:179", "a") == false and C.Stats() == 0)
C.SetEnabled(true)
t("on after the box is ticked", C.Enabled() == true and NS.db.profile.contribute == true)

-- most likely place: five samples close together, one stray click far away
for _, p in ipairs({ { 48.7, 42.0 }, { 48.8, 42.1 }, { 48.6, 41.9 }, { 48.7, 42.2 }, { 48.9, 42.0 } }) do stand(p[1], p[2]) C.Record("A:179", "a") end
stand(20, 80) C.Record("A:179", "m")
local a = C.Areas("A:179")
t("one area from five close samples and a stray click", #a == 1, #a)
t("its centre is the middle of the five", a[1] and math.abs(a[1].x - 48.74) < 0.15 and math.abs(a[1].y - 42.04) < 0.15, a[1] and (a[1].x .. "," .. a[1].y))
t("its weight is the five accepts (3 each)", a[1] and a[1].w == 15, a[1] and a[1].w)
t("its radius is small but not zero", a[1] and a[1].r >= C.MIN_R and a[1].r < 1, a[1] and a[1].r)

-- two real places (a mob that is in two camps): two areas, heaviest first
for i = 1, 6 do stand(30 + (i % 3) * 0.2, 30 + (i % 2) * 0.2) C.Record("C:200:1", "o") end
for i = 1, 3 do stand(60 + (i % 2) * 0.2, 55) C.Record("C:200:1", "o") end
local b = C.Areas("C:200:1")
t("two camps give two areas", #b == 2, #b)
t("the heavier camp comes first", b[1] and b[2] and b[1].w > b[2].w and math.abs(b[1].x - 30.2) < 0.5 and math.abs(b[2].x - 60.1) < 0.5)

-- no samples while flying on a taxi or dead
W.taxi = true stand(10, 10)
t("nothing recorded on a taxi", C.Record("A:300", "a") == false)
W.taxi, W.dead = false, true
t("nothing recorded as a ghost", C.Record("A:300", "a") == false)
W.dead = false

-- the cap
for i = 1, C.MAX_CELLS + 25 do stand(5 + (i % 60) * 1.0, 5 + math.floor(i / 60) * 1.0) C.Record("T:400", "a") end
local n = 0
for _ in pairs(NS.db.global.contrib.spots[NS.dataFlavor or NS.flavor]["T:400"]) do n = n + 1 end
t("a key never holds more than MAX_CELLS cells", n <= C.MAX_CELLS, n)

-- client events
stand(52, 47)
for _, h in ipairs(NS.wowHandlers.QUEST_ACCEPTED or {}) do h("QUEST_ACCEPTED", 3, 501) end      -- Classic: log index, quest id
for _, h in ipairs(NS.wowHandlers.QUEST_ACCEPTED or {}) do h("QUEST_ACCEPTED", 502) end         -- Retail: quest id
for _, h in ipairs(NS.wowHandlers.QUEST_TURNED_IN or {}) do h("QUEST_TURNED_IN", 501, 100, 0) end
t("accept is recorded from the Classic event", #C.Areas("A:501") == 1)
t("accept is recorded from the Retail event", #C.Areas("A:502") == 1)
t("turn-in is recorded", #C.Areas("T:501") == 1 and math.abs(C.Areas("T:501")[1].x - 52) < 0.2)

-- the forward arrow: only a manual tick of the step on screen
local step = { action = "N", guide = "g:test", key = "h:1", title = "Look at the view" }
NS:Fire("STEP_DONE", step, false, true)
t("an automatic tick of a non-quest step records nothing", #C.Areas(C.KeyFor(step)) == 0)
NS:Fire("STEP_DONE", step, true, false)
t("a manual tick of a step that is not on screen records nothing", #C.Areas(C.KeyFor(step)) == 0)
stand(33, 66)
NS:Fire("STEP_DONE", step, true, true)
t("the forward arrow records where the player stands", #C.Areas(C.KeyFor(step)) == 1 and math.abs(C.Areas(C.KeyFor(step))[1].y - 66) < 0.2)

-- objective progress on the guide's next steps
local cstep = { action = "C", qid = { 600 }, qo = "1", title = "Wolves" }
P.Pending = function() return { cstep } end
W.quests[600] = "log" W.obj[600] = 0
stand(40, 40) C.PollObjectives()
t("the first look at an objective records nothing", #C.Areas("C:600:1") == 0)
W.obj[600] = 1 stand(41, 40) C.PollObjectives()
W.obj[600] = 1 stand(70, 70) C.PollObjectives()      -- no progress here
W.obj[600] = 3 stand(41.2, 40.2) C.PollObjectives()
local o = C.Areas("C:600:1")
t("each tick of the objective is a sample where it happened", #o == 1 and o[1].w == 4 and math.abs(o[1].x - 41.1) < 0.2, o[1] and (o[1].w .. " @ " .. o[1].x))

-- a step with no point is routed to its learned spot
local nopt = { action = "A", qid = { 179 }, title = "Dwarven Outfitters" }
local wx, wy, inst = NS.Router.StepWorld(nopt)
local ex, ey = z2w(a[1].x / 100, a[1].y / 100, 1429)
t("Router.StepWorld uses the learned spot", wx and math.abs(wx - ex) < 1 and math.abs(wy - ey) < 1 and nopt._locSource == "learned", tostring(nopt._locSource))
local own = { action = "A", qid = { 179 }, title = "x", zone = 1429, coords = { { x = 0.10, y = 0.10 } } }
NS.Router.StepWorld(own)
t("a step with its own point keeps it", own._locSource ~= "learned", tostring(own._locSource))

-- off again: nothing more is recorded, what was learned stays in use
C.SetEnabled(false)
stand(90, 90)
t("off: no more samples", C.Record("A:179", "a") == false and #C.Areas("A:179") == 1)

-- export: one line per key, no names
local text, keys = C.Export()
local lines = 0
for _ in text:gmatch("[^\n]+") do lines = lines + 1 end
t("export has one line per key", lines == keys and keys >= 7, lines .. "/" .. keys)
t("export lines are flavor|build|key|cells", text:find("|A:179|1429,", 1, true) ~= nil and text:match("^%a+|[^|\n]*|[^|\n]+|%d+,[%d%.]+,[%d%.]+,%d+") ~= nil, text:sub(1, 120))
t("export holds no character or realm name", not text:find(tostring(NS.player and NS.player.name or "Tester"), 1, true) or (NS.player and NS.player.name) == nil)

C.Clear()
t("clear empties this client's data", C.Stats() == 0 and #C.Areas("A:179") == 0)

-- ===========================================================================
-- Creatures (N:), objects (O:) and the items steps name (I:)
-- ===========================================================================
local FL = NS.dataFlavor or NS.flavor
local function rec(key) local s = NS.db.global.contrib.spots[FL] return s and s[key] end
local function weight(key)
    local r, w = rec(key), 0
    for _, v in pairs(r or {}) do if type(v) == "number" then w = w + v end end
    return w
end
local function npc(id, spawn) return ("Creature-0-3110-0-47-%d-%08X"):format(id, spawn or 1) end
local function obj(id, spawn) return ("GameObject-0-3110-0-47-%d-%08X"):format(id, spawn or 1) end
local function itemLink(id) return ("|cffffffff|Hitem:%d::::::::20:::::::::|h[x]|h|r"):format(id) end
local function loot(slots, fishing) W.loot, W.fishing = slots, fishing or false C.OnLoot() end
local ME, PET = "Player-3110-0000ABCD", "Pet-0-3110-0-47-416-0100000001"
W.guids.player = ME
-- the client hands combat log events only to a frame that registered for them
local function cl(sub, src, dst, dname)
    W.cl = { 1.0, sub, false, src, "x", 0, 0, dst, dname, 0, 0 }
    if C.combatLogOn then C._onCombatLog() end
end
local function later(s) W.now = W.now + (s or C.THROTTLE + 1) end

-- GUIDs: the id is the creature's or the object's; a player, a pet or an item in the bags is no place
local k1, i1 = C.SourceOf(npc(2345))
local k2, i2 = C.SourceOf(obj(178000))
local k3, i3 = C.SourceOf("Vehicle-0-3110-0-47-31337-00000ABCDE")
t("a creature GUID gives N and its npc id", k1 == "N" and i1 == 2345, tostring(k1) .. tostring(i1))
t("an object GUID gives O and its object id", k2 == "O" and i2 == 178000, tostring(k2) .. tostring(i2))
t("a vehicle counts as a creature", k3 == "N" and i3 == 31337)
t("a player, a pet or an item in the bags is no place",
    C.SourceOf(ME) == nil and C.SourceOf(PET) == nil and C.SourceOf("Item-3110-0-4000000012345678") == nil and C.SourceOf(nil) == nil)

-- off: nothing, and the combat log is not listened to
C.SetEnabled(false)
stand(30, 30)
C.SyncCombatLog()
t("off: the combat log is not listened to", C.combatLogOn == false)
loot({ { guid = npc(2345), link = itemLink(2589) } })
loot({ { guid = obj(178000), link = itemLink(2770) } })
t("off: a looted corpse or chest records nothing", rec("N:2345") == nil and rec("O:178000") == nil and C.Stats() == 0)

C.SetEnabled(true)
t("on: the combat log is listened to", C.combatLogOn == true)

-- a creature the player hurt dies (combat log)
stand(30.0, 30.0)
cl("SWING_DAMAGE", ME, npc(2345, 7), "Crushridge Warmonger")
cl("UNIT_DIED", nil, npc(2345, 7), "Crushridge Warmonger")
t("a creature the player hurt dies: N:<npc id>", weight("N:2345") == C.WEIGHT.k, weight("N:2345"))
later()
cl("UNIT_DIED", nil, npc(2345, 8), "Crushridge Warmonger")
t("a creature someone else killed records nothing", weight("N:2345") == C.WEIGHT.k)
cl("SWING_DAMAGE", "Player-3110-0000FFFF", npc(2345, 8), "Crushridge Warmonger")
cl("UNIT_DIED", nil, npc(2345, 8), "Crushridge Warmonger")
t("a creature only another player hurt records nothing", weight("N:2345") == C.WEIGHT.k)
cl("PARTY_KILL", "Player-3110-0000FFFF", npc(2345, 9), "Crushridge Warmonger")
t("a party member's killing blow on a creature the player never hurt records nothing", weight("N:2345") == C.WEIGHT.k)
stand(30.4, 30.2)
cl("PARTY_KILL", ME, npc(2345, 10), "Crushridge Warmonger")
cl("UNIT_DIED", nil, npc(2345, 10), "Crushridge Warmonger")
t("the player's killing blow records one sample, not two", weight("N:2345") == 2 * C.WEIGHT.k, weight("N:2345"))

-- the throttle: one sample per key every C.THROTTLE seconds
later(1)
cl("SPELL_DAMAGE", ME, npc(2345, 11), "Crushridge Warmonger")
cl("UNIT_DIED", nil, npc(2345, 11), "Crushridge Warmonger")
t("a second kill within the throttle adds nothing", weight("N:2345") == 2 * C.WEIGHT.k)
later()
cl("SPELL_PERIODIC_DAMAGE", ME, npc(2345, 12), "Crushridge Warmonger")
cl("UNIT_DIED", nil, npc(2345, 12), "Crushridge Warmonger")
t("after the throttle the next kill counts", weight("N:2345") == 3 * C.WEIGHT.k, weight("N:2345"))

-- the pet's damage tags the creature too
later()
W.guids.pet = PET
for _, h in ipairs(NS.wowHandlers.UNIT_PET or {}) do h("UNIT_PET", "player") end
cl("SWING_DAMAGE", PET, npc(3000, 1), "Young Wolf")
cl("UNIT_DIED", nil, npc(3000, 1), "Young Wolf")
t("a creature the pet hurt counts", weight("N:3000") == C.WEIGHT.k)

-- no table is made per combat log event: a long fight leaves memory where it was
do
    -- damage to two creatures in turn (ring writes), auras, and deaths of a creature the player never hurt
    local a, b, c = npc(4000, 1), npc(4001, 2), npc(4002, 3)
    W.cl = { 1.0, "SWING_DAMAGE", false, ME, "x", 0, 0, a, "A", 0, 0 }
    collectgarbage("collect") collectgarbage("stop")
    local before = collectgarbage("count")
    for i = 1, 2000 do
        local r = i % 3
        if r == 0 then W.cl[2], W.cl[8] = "SPELL_DAMAGE", ((i % 2 == 0) and a or b)
        elseif r == 1 then W.cl[2], W.cl[8] = "SPELL_AURA_APPLIED", a
        else W.cl[2], W.cl[8] = "UNIT_DIED", c end
        C._onCombatLog()
    end
    local grew = collectgarbage("count") - before
    collectgarbage("restart")
    t("2000 combat log events make no garbage", grew < 4, ("%.2f KB"):format(grew))
end

-- rares: the target says so before the kill; the flag sits in the key's record
later()
W.guids.target, W.class.target, W.targetName = npc(777, 1), "rare", "Old Greypaw"
for _, h in ipairs(NS.wowHandlers.PLAYER_TARGET_CHANGED or {}) do h("PLAYER_TARGET_CHANGED") end
W.guids.target, W.class.target = nil, nil
stand(60, 61)
cl("SWING_DAMAGE", ME, npc(777, 1), "Old Greypaw")
cl("UNIT_DIED", nil, npc(777, 1), "Old Greypaw")
t("a rare creature: one N: key with the rare flag in its record", C.IsRare("N:777") == true and weight("N:777") == C.WEIGHT.k
    and rec("R:777") == nil and rec("N:777:rare") == nil)
t("an ordinary creature carries no flag", C.IsRare("N:2345") == false)

-- a looted corpse: the player stands at it (weight 2); a rare elite the target is
later()
stand(31, 30)
loot({ { guid = npc(2345, 20), link = itemLink(2589) } })
t("a looted corpse records N:<npc id> (weight 2)", weight("N:2345") == 3 * C.WEIGHT.k + C.WEIGHT.l, weight("N:2345"))
W.guids.target, W.class.target, W.targetName = npc(888, 1), "rareelite", "Rak'shiri"
stand(70, 20)
loot({ { guid = npc(888, 1), link = itemLink(12345) } })
t("a looted rare elite (the target) is flagged", C.IsRare("N:888") == true and weight("N:888") == C.WEIGHT.l)
W.guids.target, W.class.target, W.targetName = nil, nil, nil
later()
loot({ { guid = npc(5000, 1) }, { guid = npc(5000, 2) }, { guid = npc(5000, 3) } })
t("area loot of three corpses of one creature: one sample", weight("N:5000") == C.WEIGHT.l, weight("N:5000"))

-- objects: chest, treasure, herb, ore
stand(44, 55)
loot({ { guid = obj(1731, 1), link = itemLink(2770) } })        -- Copper Vein
t("a looted node records O:<object id> (weight 3)", weight("O:1731") == C.WEIGHT.g)
later()
loot({ { guid = obj(180582, 1), link = itemLink(6303) } }, true)
t("a fishing catch is no object's place", rec("O:180582") == nil)
loot({ { guid = "Item-3110-0-4000000012345678", link = itemLink(2589) } })
t("a container opened in the bags records nothing", C.StatsByKind().N + C.StatsByKind().O == 6, C.StatsByKind().N .. "+" .. C.StatsByKind().O)

-- items the next steps name (L and U)
local signet = { action = "C", qid = { 512 }, qo = "1", loot = { { id = 3505, qty = 7 } }, title = "Noble Deaths" }
local contract = { action = "A", qid = { 522 }, item = 3668, title = "Assassin's Contract" }
P.Pending = function() return { signet, contract } end
NS:Fire("PROGRESS_REFRESHED")
later()
stand(40.2, 18.0)
loot({ { guid = npc(2242, 1), link = itemLink(3505) }, { guid = npc(2242, 1), link = itemLink(2589) } })
t("an item a next step names (L) records I:<item id>", weight("I:3505") == C.WEIGHT.l, weight("I:3505"))
t("an item no step names records nothing", rec("I:2589") == nil)
later()
loot({ { guid = obj(2843, 1), link = itemLink(3668) } })
t("an item a next step uses (U) records I:<item id>, at the object's weight", weight("I:3668") == C.WEIGHT.g)
later()
loot({ { guid = "Item-3110-0-4000000012345679", link = itemLink(3505) } })
t("the same item from a container in the bags records nothing", weight("I:3505") == C.WEIGHT.l)
later()
loot({ { guid = nil, link = itemLink(3505) } }, true)
t("the same item fished up records where the player fishes", weight("I:3505") == 2 * C.WEIGHT.l)

-- never inside an instance
later()
W.inst = true
for _, h in ipairs(NS.wowHandlers.PLAYER_ENTERING_WORLD or {}) do h("PLAYER_ENTERING_WORLD") end
t("in an instance the combat log is let go", C.combatLogOn == false)
local before = C.Stats()
loot({ { guid = npc(9100, 1), link = itemLink(3505) }, { guid = obj(9200, 1) } })
C.Killed(npc(9101, 1), "Instance Mob")
t("in an instance a direct sample is refused too", C.RecordSeen("N:9102", "l") == false)
t("in an instance nothing is recorded", C.Stats() == before and rec("N:9100") == nil and rec("O:9200") == nil and rec("N:9101") == nil)
W.inst = false
for _, h in ipairs(NS.wowHandlers.ZONE_CHANGED_NEW_AREA or {}) do h("ZONE_CHANGED_NEW_AREA") end
t("back outside it is listened to again", C.combatLogOn == true)

-- Retail 12.x: the combat log is left alone; the loot window still works
do
    local toc = NS.tocversion
    NS.tocversion = 120105
    C.SyncCombatLog()
    t("Retail 12: the combat log is not registered", C.combatLogOn == false)
    later()
    stand(12, 12)
    loot({ { guid = npc(6000, 1) } })
    t("Retail 12: a looted corpse still records", weight("N:6000") == C.WEIGHT.l)
    NS.tocversion = toc
    C.SyncCombatLog()
end

-- the cell cap holds for creature keys, and the rare flag is neither a cell nor lost
for i = 1, C.MAX_CELLS + 25 do
    later()
    stand(5 + (i % 60) * 1.0, 5 + math.floor(i / 60) * 1.0)
    C.RecordSeen("N:777", "l", true)
end
local cells = 0
for _, v in pairs(rec("N:777")) do if type(v) == "number" then cells = cells + 1 end end
t("a creature key never holds more than MAX_CELLS cells", cells <= C.MAX_CELLS, cells)
t("the rare flag survives the cap", C.IsRare("N:777") == true)
local keys, cellsAll = C.Stats()
t("Stats counts cells, not the flag", type(keys) == "number" and type(cellsAll) == "number")

-- export: the new keys, one line each, same four fields; no flag, no names
local text, n2 = C.Export()
local lines2, bad = 0, 0
for line in text:gmatch("[^\n]+") do
    lines2 = lines2 + 1
    if not line:match("^%a+|[^|]*|[ATCGNOI]:[^|]+|%d+,[%d%.]+,[%d%.]+,%d+[;%d%.,]*$") then bad = bad + 1 end
end
t("export: one line per key, all in the four-field format", lines2 == n2 and bad == 0, lines2 .. "/" .. n2 .. " bad " .. bad)
t("export has the creature, object and item lines", text:find("|N:2345|", 1, true) and text:find("|O:1731|", 1, true)
    and text:find("|I:3505|", 1, true) and text:find("|N:777|", 1, true) and true or false)
t("export holds no flag and no creature name", not text:find("rare", 1, true) and not text:find("Warmonger", 1, true)
    and not text:find("Greypaw", 1, true))

-- ---------------------------------------------------------------------------
-- The world map: the current step's own areas and those of what it names
-- ---------------------------------------------------------------------------
local function drawn()
    local by = {}
    for _, p in ipairs(PINS.world) do
        local f = p.frame
        by[#by + 1] = { key = f.key, rgb = f.rgb, rare = f.rare, ring = f.ring.__shown == true, map = p.map }
    end
    return by
end
local function has(list, key) for _, d in ipairs(list) do if d.key == key then return d end end end

-- a step naming a creature killed while it was one of the next steps: linked by its key, drawn red
local warm = { action = "C", qid = { 504 }, qo = "1", target = "Crushridge Warmonger", title = "Crushridge Warmongers" }
P.Pending = function() return { warm } end
NS:Fire("PROGRESS_REFRESHED")
later()
stand(32, 29)
cl("SWING_DAMAGE", ME, npc(2345, 30), "Crushridge Warmonger")
cl("UNIT_DIED", nil, npc(2345, 30), "Crushridge Warmonger")
t("the kill links the step to the creature (ids only)", C.LinksFor("C:504:1") and C.LinksFor("C:504:1")["N:2345"] == true)
P.current = warm
NS:Fire("STEP_CHANGED", warm)
local d = drawn()
t("the map gets a red circle for the creature the step names", has(d, "N:2345") and has(d, "N:2345").rgb == C.RGB.N, #d)
t("its circle is on the creature's map", has(d, "N:2345") and has(d, "N:2345").map == 1429)

-- another step naming the same creature, never one of the next steps: this session's name finds it
local warm2 = { action = "K", target = "Crushridge Warmonger", title = "Kill Crushridge Warmonger", guide = "g:x", key = "h:w" }
P.current = warm2
C.UpdateMap()
t("a step that only names the creature gets its circle too", has(drawn(), "N:2345") ~= nil)

-- a rare: outlined
local grey = { action = "K", target = "Old Greypaw", title = "Kill Old Greypaw", guide = "g:x", key = "h:g" }
P.current = grey
C.UpdateMap()
local gd = has(drawn(), "N:777")
t("a rare creature's circle is outlined", gd and gd.rare == true and gd.ring == true)
P.current = warm
C.UpdateMap()
t("an ordinary creature's circle is not", has(drawn(), "N:2345") and has(drawn(), "N:2345").ring == false)

-- an item the step names: purple
P.current = signet
C.UpdateMap()
local id = has(drawn(), "I:3505")
t("the map gets a purple circle for the item the step names", id and id.rgb == C.RGB.I)
t("the item step's creature (its item dropped from it) is linked and drawn red",
    C.LinksFor("C:512:1") and C.LinksFor("C:512:1")["N:2242"] and has(drawn(), "N:2242") and has(drawn(), "N:2242").rgb == C.RGB.N)

-- a treasure step: the chest looted at its spot is linked; gold
local chest = { action = "$", title = "Open the chest", zone = 1429, coords = { { x = 0.50, y = 0.50 } }, guide = "g:t", key = "h:chest" }
P.current = chest
NS:Fire("STEP_CHANGED", chest)
later()
stand(50.1, 50.0)
loot({ { guid = obj(178000, 3), link = itemLink(2770) } })
t("a chest looted at the treasure step's spot is linked to it", C.LinksFor("G:g:t#h:chest") and C.LinksFor("G:g:t#h:chest")["O:178000"] == true)
C.UpdateMap()
local od = has(drawn(), "O:178000")
t("the map gets a gold circle for the step's object", od and od.rgb == C.RGB.O)
later()
stand(80, 80)
loot({ { guid = obj(1732, 1), link = itemLink(2771) } })
t("an object looted away from the spot is not linked", not C.LinksFor("G:g:t#h:chest")["O:1732"])

-- the step's own key keeps its colour, beside what it names
later()
stand(32.2, 29.7)
C.Record("C:504:1", "o")
P.current = warm
C.UpdateMap()
d = drawn()
t("the step's own areas keep their colour beside the creature's", has(d, "C:504:1") and has(d, "C:504:1").rgb == C.RGB.C and has(d, "N:2345"))

-- no frame churn: the circles are made once and reused
local made = 0 for _ in pairs(C._circles) do made = made + 1 end
for _ = 1, 5 do C.UpdateMap() end
local made2 = 0 for _ in pairs(C._circles) do made2 = made2 + 1 end
t("redrawing the map makes no new frames", made2 == made and made > 0, made .. " -> " .. made2)
t("never more than MAX_CIRCLES circles", #PINS.world <= C.MAX_CIRCLES)

-- a sample of something the step on screen does not name does not redraw the map
local redraws = 0
local real = C.UpdateMap
C.UpdateMap = function() redraws = redraws + 1 return real() end
later()
stand(20, 20)
loot({ { guid = npc(6100, 1) } })
local quiet = redraws
later()
stand(33, 30)
cl("SWING_DAMAGE", ME, npc(2345, 40), "Crushridge Warmonger")
cl("UNIT_DIED", nil, npc(2345, 40), "Crushridge Warmonger")
t("only a sample of what the step names redraws the map", quiet == 0 and redraws == 1, quiet .. "/" .. redraws)
C.UpdateMap = real

-- clear takes the links too
C.Clear()
t("clear empties the creature, object and item keys and the links", C.Stats() == 0 and C.LinksFor("C:504:1") == nil)
C.SetEnabled(false)
t("off again: the combat log is let go", C.combatLogOn == false)

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
print("ALL CONTRIBUTE TESTS PASSED")
