-- CompletionRoute :: tools/test_auto_route.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- Offline tests of Core/AutoRoute.lua (category routing, owner spec 2026-11-27) on synthetic routes:
--   categories offered; Quests loads ONE quest at a time and picks the closest; a quest never comes before its
--   prerequisite; the next quest loads by itself after a turn-in; level gates; Dungeons collects the dungeon's quests
--   before the entrance; Items routes to the closest unowned item; Batch takes the zone's open quests together;
--   the choice is per character.
-- Run: luajit tools/test_auto_route.lua   (from repo root)
package.path = "./?.lua;" .. package.path
local ADDON, NS = "CompletionRoute", {}
dofile("tools/stubs.lua")
PLAYER = { map = 1429, x = 0.40, y = 0.60 }
PLAYER.wx, PLAYER.wy, PLAYER.inst = z2w(PLAYER.x, PLAYER.y, PLAYER.map)
local passed, failed = 0, 0
local function t(name, cond, detail)
    if cond then passed = passed + 1 print("ok   " .. name)
    else failed = failed + 1 print("FAIL " .. name .. (detail and (" :: " .. tostring(detail)) or "")) end
end
local DONE, LOG, LEVEL = {}, {}, 5
function UnitLevel() return LEVEL end
C_QuestLog.IsQuestFlaggedCompleted = function(q) return DONE[q] == true end
C_QuestLog.GetAllCompletedQuestIDs = function() local o = {} for q in pairs(DONE) do o[#o + 1] = q end return o end
C_QuestLog.IsOnQuest = function(q) return LOG[q] ~= nil end
C_QuestLog.GetLogIndexForQuestID = function(q) return LOG[q] and 1 or nil end
C_QuestLog.IsComplete = function(q) return LOG[q] == "complete" end
C_QuestLog.GetQuestObjectives = function(q) return LOG[q] == "complete" and { { finished = true, numFulfilled = 1, numRequired = 1 } } or { { finished = false, numFulfilled = 0, numRequired = 1 } } end
local function load(path) assert(loadfile("CompletionRoute/" .. path))(ADDON, NS) end
for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", "Data/Taxi_tbc.lua", "Data/Transit.lua", "Data/Access.lua",
    "Data/Inns.lua", "Data/ZoneAliases.lua", "Routing/CostModel.lua", "Routing/TravelGraph.lua", "Routing/Roads.lua", "Routing/StepOrder.lua", "Routing/Router.lua",
    "Core/Account.lua", "Core/Professions.lua", "Core/Progress.lua", "Core/Recommend.lua", "Core/AutoRoute.lua", "Core/Farm.lua" }) do load(f) end
CompletionRouteDB, CompletionRouteCharDB = nil, nil
for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", "CompletionRoute") end
NS.db.profile.routing.assumeAllTaxi = true
local printed = {}
NS.Print, NS.Debug = function(_, m) printed[#printed + 1] = tostring(m) end, function() end
local errs = {}
NS.Error = function(_, m) errs[#errs + 1] = tostring(m) end
local G, P, A = NS.Guide, NS.Progress, NS.Auto
NS.TravelGraph.Build()

-- Elwynn (1429): quest 101 near the player, 102 far, 103 needs 102, 104 needs level 10
G.Register({ id = "t:quests", name = "Test Quests", type = "Quests", zone = 1429, minlevel = 1, maxlevel = 10, text = table.concat({
    "A Far One|QID|102|M|80.0,80.0|Z|1429; Elwynn Forest|",
    "C Far One|QID|102|M|81.0,80.0|Z|1429; Elwynn Forest|",
    "T Far One|QID|102|M|80.0,80.0|Z|1429; Elwynn Forest|",
    "A Near One|QID|101|M|41.0,60.0|Z|1429; Elwynn Forest|",
    "C Near One|QID|101|M|42.0,61.0|Z|1429; Elwynn Forest|",
    "T Near One|QID|101|M|41.0,60.0|Z|1429; Elwynn Forest|",
    "A Follow-up|QID|103|PRE|102|M|40.5,60.5|Z|1429; Elwynn Forest|",
    "T Follow-up|QID|103|M|40.5,60.5|Z|1429; Elwynn Forest|",
    "A Later|QID|104|LVL|10|M|40.2,60.1|Z|1429; Elwynn Forest|",
    "T Later|QID|104|M|40.2,60.1|Z|1429; Elwynn Forest|",
}, "\n") })
G.Register({ id = "t:dungeon", name = "Test Dungeon", type = "Dungeons", instance = "Dungeon", zone = 1429, minlevel = 1, maxlevel = 20, text = table.concat({
    "A Dungeon Quest|QID|201|M|45.0,60.0|Z|1429; Elwynn Forest|",
    "A Dungeon Quest Two|QID|202|M|60.0,60.0|Z|1429; Elwynn Forest|",
    "D Enter The Test Dungeon|M|70.0,70.0|Z|1429; Elwynn Forest|",
    "C Dungeon Quest|QID|201|M|70.0,70.0|Z|1429; Elwynn Forest|",
    "C Dungeon Quest Two|QID|202|M|70.0,70.0|Z|1429; Elwynn Forest|",
    "T Dungeon Quest|QID|201|M|45.0,60.0|Z|1429; Elwynn Forest|",
    "T Dungeon Quest Two|QID|202|M|60.0,60.0|Z|1429; Elwynn Forest|",
}, "\n") })
G.Register({ id = "t:items", name = "Test Items", type = "Pets", zone = 1429, minlevel = 1, maxlevel = 20, text = table.concat({
    "$ Far Chest|L|9002 1|M|85.0,85.0|Z|1429; Elwynn Forest|",
    "B Near Bread|ITEM|9001|M|40.1,60.1|Z|1429; Elwynn Forest|",
}, "\n") })
BAGS = {}
C_Item = C_Item or {}
C_Item.GetItemCount = function(id) return BAGS[id] or 0 end

local function cats() local s = {} for _, c in ipairs(A.Categories()) do s[c] = true end return s end
local c = cats()
t("categories: Quests, Dungeons, Items offered; no Gold", c.Quests and c.Dungeons and c.Items and not c.Gold)
t("categories: no Achievements / Legacy without routes", not c.Achievements and not c["Legacy Points"])

local function quests()
    local s = {}
    for _, st in ipairs(P.steps or {}) do for _, q in ipairs(st.qid or {}) do s[q] = true end end
    local n = 0 for _ in pairs(s) do n = n + 1 end
    return s, n
end
t("start Quests", A.Start("quests"))
local qs, n = quests()
t("one quest at a time", n == 1, n)
t("the closest quest first (101)", qs[101], next(qs))
t("route is the category route", P.guide and P.guide.auto == "Quests")
t("choice is per character", NS.db.char.auto and NS.db.char.auto.cat == "Quests")
-- play quest 101
LOG[101] = "log" P.Refresh()
LOG[101] = "complete" P.Refresh()
LOG[101] = nil DONE[101] = true P.Refresh()
qs = quests()
t("next quest loads by itself after the turn-in (102, not 103 before its prerequisite)", qs[102] and not qs[103], next(qs))
LOG[102] = "complete" P.Refresh()
LOG[102] = nil DONE[102] = true P.Refresh()
qs = quests()
t("the follow-up opens once its prerequisite is done", qs[103], next(qs))
LOG[103] = "complete" P.Refresh() LOG[103] = nil DONE[103] = true P.Refresh()
t("level gate: 104 (level 10) not offered at level 5", P.current == nil, P.current and P.current.title)
LEVEL = 10 P.Refresh()
qs = quests()
t("level gate opens at level 10", qs[104], next(qs))
t("no errors in Quests", #errs == 0, errs[1])

-- Dungeons: both quests before the entrance
LEVEL = 10
t("start Dungeons", A.Start("dungeons"))
local seen = {}
for _ = 1, 12 do
    local s = P.current
    if not s then break end
    seen[#seen + 1] = s.action .. (s.qid and s.qid[1] or "")
    if s.action == "A" then LOG[s.qid[1]] = "log"
    elseif s.action == "C" then LOG[s.qid[1]] = "complete"
    elseif s.action == "T" then LOG[s.qid[1]] = nil DONE[s.qid[1]] = true
    else P.MarkDone(s) end
    P.Refresh()
end
local order = table.concat(seen, ",")
local enter = order:find("D")
t("dungeon: every quest accepted before the entrance", enter and order:find("A201") < enter and order:find("A202") < enter, order)
t("dungeon: turn-ins after the run", order:find("T201") and order:find("T201") > enter, order)
t("dungeon finished and recorded", NS.db.char.auto.done.Dungeons["t:dungeon"] == true)

-- Dungeons: a dungeon whose run is level-gated is skipped for now, never recorded as done
G.Register({ id = "t:dungeon2", name = "Gated Dungeon", type = "Dungeons", instance = "Dungeon", zone = 1429, minlevel = 1, maxlevel = 20, text = table.concat({
    "A Gated Quest|QID|301|M|44.0,60.0|Z|1429; Elwynn Forest|",
    "D Enter Gated|LVL|30|M|72.0,72.0|Z|1429; Elwynn Forest|",
    "T Gated Quest|QID|301|LVL|30|M|44.0,60.0|Z|1429; Elwynn Forest|",
}, "\n") })
A.Invalidate()
t("start Dungeons (gated)", A.Start("dungeons") ~= nil)
for _ = 1, 6 do
    local s = P.current
    if not s then break end
    if s.action == "A" then LOG[s.qid[1]] = "log" else P.MarkDone(s) end
    P.Refresh()
end
t("gated dungeon: quest collected", LOG[301] ~= nil)
t("gated dungeon: not recorded as done", NS.db.char.auto.done.Dungeons["t:dungeon2"] ~= true, tostring(NS.db.char.auto.done.Dungeons["t:dungeon2"]))
A.Start("dungeons")
t("gated dungeon: re-checked on a new start, still not done", NS.db.char.auto.done.Dungeons["t:dungeon2"] ~= true)
-- per character: a second character starts with no progress
local saved = NS.db.char
NS.db.char = {}
t("per character: fresh character has no category / progress", A.Store().cat == nil and next(A.Store().done) == nil)
NS.db.char = saved
t("per character: first character keeps its progress", A.Store().done.Dungeons["t:dungeon"] == true)

-- Items
NS.db.char = {}
A.Invalidate()
t("start Items", A.Start("items"))
local function curItem() return A.current and A.current.item end
t("items: closest unowned item first (bread)", curItem() == 9001, curItem())
BAGS[9001] = 1
P.Refresh()
t("items: owned -> next item (far chest)", curItem() == 9002, curItem())
local nItems = 0 for _, u in ipairs(A.ItemUnits()) do nItems = nItems + 1 end
t("items: one unit per item id", nItems == 2, nItems)

-- Batch (fresh quests: 301/302 open in Elwynn, 303 needs 302, 304 in another zone)
G.Register({ id = "t:batch", name = "Batch Quests", type = "Quests", zone = 1429, minlevel = 1, maxlevel = 10, text = table.concat({
    "A B1|QID|301|M|43.0,60.0|Z|1429; Elwynn Forest|", "T B1|QID|301|M|43.0,60.0|Z|1429; Elwynn Forest|",
    "A B2|QID|302|M|60.0,40.0|Z|1429; Elwynn Forest|", "T B2|QID|302|M|60.0,41.0|Z|1429; Elwynn Forest|",
    "A B3|QID|303|PRE|302|M|44.0,60.0|Z|1429; Elwynn Forest|", "T B3|QID|303|M|44.0,60.0|Z|1429; Elwynn Forest|",
    "A B4|QID|304|M|50.0,50.0|Z|1436; Westfall|", "T B4|QID|304|M|50.0,50.0|Z|1436; Westfall|",
}, "\n") })
DONE[101], DONE[102], DONE[103], DONE[104] = true, true, true, true
NS.db.char = {}
A.Invalidate()
A.SetBatch(true)
t("batch: on", A.BatchOn())
t("start Quests batched", A.Start("quests"))
local qs = {}
for _, u in ipairs(A.current and A.current.batch or {}) do qs[u.q] = true end
t("batch: open quests of the zone together (301, 302)", qs[301] and qs[302], A.current and A.current.key)
t("batch: prerequisite / other-zone quests left out", not qs[303] and not qs[304])
local st = P.guide and P.guide.steps or {}
t("batch: accepts come first", st[1] and st[1].action == "A" and st[2] and st[2].action == "A", st[1] and st[1].action)
DONE[301], DONE[302] = true, true
P.Refresh()
t("batch: done batch moves on (303 now open)", A.current and (A.current.q == 303 or (A.current.batch and A.current.batch[1].q == 303)), A.current and A.current.key)
A.SetBatch(false)
t("batch: off", not A.BatchOn())

print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
