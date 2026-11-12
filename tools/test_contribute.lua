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

local function load(path) assert(loadfile("CompletionRoute/" .. path))(ADDON, NS) end
for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", "Data/Taxi_tbc.lua", "Data/Transit.lua", "Data/Access.lua",
    "Data/Inns.lua", "Data/ZoneAliases.lua", "Data/Roads_ek.lua", "Data/Roads_kalimdor.lua", "Routing/CostModel.lua", "Routing/TravelGraph.lua", "Routing/Roads.lua",
    "Routing/StepOrder.lua", "Routing/Router.lua", "Core/Account.lua", "Core/Professions.lua", "Core/Progress.lua", "Core/Recommend.lua", "Core/Contribute.lua" }) do load(f) end
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

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
print("ALL CONTRIBUTE TESTS PASSED")
