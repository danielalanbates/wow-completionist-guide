-- CompletionRoute :: tools/test_parked.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- Offline test of the guide-finished logic in Core/Progress.lua: a guide that runs dry while a level gate still holds
-- steps back is parked, and comes back when the character reaches the level, without loops or bouncing.
-- Run: luajit tools/test_parked.lua   (from repo root)
package.path = "./?.lua;" .. package.path
local ADDON, NS = "CompletionRoute", {}
dofile("tools/stubs.lua")
local z2w = z2w
PLAYER = { map = 1429, x = 0.487, y = 0.42 } PLAYER.wx, PLAYER.wy, PLAYER.inst = z2w(PLAYER.x, PLAYER.y, PLAYER.map)

local passed, failed = 0, 0
local function t(name, cond, detail)
    if cond then passed = passed + 1 print("ok   " .. name)
    else failed = failed + 1 print("FAIL " .. name .. (detail and (" :: " .. tostring(detail)) or "")) end
end

-- a tiny mutable world: quest state and level
local W = { level = 1, quests = {} }
function UnitLevel() return W.level end
C_QuestLog = {
    IsOnQuest = function(q) local s = W.quests[q] return s == "log" or s == "complete" end,
    IsQuestFlaggedCompleted = function(q) return W.quests[q] == "done" end,
    IsComplete = function(q) return W.quests[q] == "complete" end,
    GetLogIndexForQuestID = function(q) local s = W.quests[q] return (s == "log" or s == "complete") and 1 or nil end,
    GetQuestObjectives = function() return {} end,
    GetAllCompletedQuestIDs = function() local out = {} for q, s in pairs(W.quests) do if s == "done" then out[#out + 1] = q end end return out end,
    GetTitleForQuestID = function() return nil end,
}

local function load(path) assert(loadfile("CompletionRoute/" .. path))(ADDON, NS) end
for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", "Data/Taxi_tbc.lua", "Data/Transit.lua", "Data/Access.lua",
    "Data/Inns.lua", "Data/ZoneAliases.lua", "Data/Roads_ek.lua", "Data/Roads_kalimdor.lua", "Routing/TravelGraph.lua", "Routing/Roads.lua",
    "Routing/StepOrder.lua", "Routing/Router.lua", "Core/Account.lua", "Core/Professions.lua", "Core/Progress.lua", "Core/Recommend.lua" }) do load(f) end
CompletionRouteDB, CompletionRouteCharDB = nil, nil
for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", "CompletionRoute") end
NS.Account.Init()
local printed = {}
NS.Print = function(_, s) printed[#printed + 1] = s end
NS.Debug, NS.Error = function() end, function() end
NS.TravelGraph.Build()
local P, G = NS.Progress, NS.Guide

-- SuggestNext is real but we want the chain under test to be `next` and the parked logic
local suggestions = {}
local realSuggestNext = G.SuggestNext
G.SuggestNext = function(ex) return table.remove(suggestions, 1) end

local Z = "|Z|1429; Elwynn Forest|"
local function A(q, x, lvl) return ("A Q%d|QID|%d|M|%d,40%s%s"):format(q, q, x, Z, lvl and ("LVL|%d|"):format(lvl) or "") end
local function T(q, x, lvl) return ("T Q%d|QID|%d|M|%d,42%s%s"):format(q, q, x, Z, lvl and ("LVL|%d|"):format(lvl) or "") end
local function reg(id, nxt, lines, extra)
    local def = { id = id, name = id, type = "Leveling", faction = "Alliance", minlevel = 1, maxlevel = 60, next = nxt, source = "test", text = table.concat(lines, "\n") }
    for k, v in pairs(extra or {}) do def[k] = v end
    G.registry[id] = nil
    G.Register(def)
end
local function reset(level)
    W.level, W.quests = level, {}
    for _, k in ipairs({ "done", "skipped", "reopened", "laps" }) do NS.db.char[k] = {} end
    NS.db.char.guide, NS.db.char.parked, NS.db.char.parkReturn = nil, {}, nil
    if NS.Account.me then NS.Account.me.done, NS.Account.me.skipped = {}, {} end
    suggestions = {}
    P.chainDepth = 0
end
-- play everything currently pending in the loaded guide; returns number of steps done
local function playAll()
    local n, guard, id = 0, 0, P.guide and P.guide.id
    while P.current and guard < 200 and P.guide.id == id do
        guard = guard + 1
        local s = P.current
        if s.action == "A" then W.quests[s.qid[1]] = "log" else W.quests[s.qid[1]] = "done" end
        P.Refresh()
        if P.current == s then P.MarkDone(s) end
        n = n + 1
    end
    return n
end

-- 1. A wide-band guide runs dry at level 1, is parked at its lowest gate and the chain goes on.
reg("t:wide", "t:b", { A(1, 40), T(1, 41), A(2, 42, 5), T(2, 43, 5), A(3, 44, 10), T(3, 45, 10) })
reg("t:b", nil, { A(11, 50), T(11, 51) })
reset(1)
P.Load("t:wide")
t("wide guide plays its level-1 steps", P.guide.id == "t:wide" and P.current and P.current.qid[1] == 1)
playAll()
t("wide guide moved on to the next guide after running dry", P.guide.id == "t:b", P.guide and P.guide.id)
local rec = P.ParkedRecord("t:wide")
t("wide guide is parked at its lowest gate (5)", rec and rec.level == 5, rec and rec.level)
t("a parked guide is reported as waiting", P.ParkedWaiting("t:wide"))
local told = false
for _, s in ipairs(printed) do if tostring(s):find("parked", 1, true) then told = true end end
t("the player was told", told)

-- 2. Levelling inside the next guide does NOT yank the player out of it (no bounce).
W.level = 5
P.Refresh()
t("reaching the gate mid-guide does not switch guides", P.guide.id == "t:b" and P.current ~= nil)
t("the gate counts as open now", not P.ParkedWaiting("t:wide"))

-- 3. When the guide in progress ends, the parked guide comes back with its steps open.
playAll()
t("parked guide came back when the current guide ended", P.guide.id == "t:wide", P.guide and P.guide.id)
t("its level-5 step is current", P.current and P.current.qid[1] == 2)
playAll()
t("the guide parks again at the next gate", P.ParkedRecord("t:wide") and P.ParkedRecord("t:wide").level == 10)

-- 4. The chain continues where it was going, not back along the parked guide's own `next`.
reg("t:g1", "t:g2", { A(21, 40), A(22, 41, 3), T(22, 42, 3) })
reg("t:g2", "t:g3", { A(31, 50), T(31, 51) })
reg("t:g3", nil, { A(41, 60), T(41, 61) })
reset(1)
P.Load("t:g1")
playAll()
t("g1 parked, chain on g2", P.guide.id == "t:g2" and P.ParkedRecord("t:g1") and P.ParkedRecord("t:g1").level == 3)
W.level = 3
playAll()
t("g1 resumes after g2", P.guide.id == "t:g1", P.guide and P.guide.id)
playAll()
t("after the detour the chain goes to g3 (not g1's next g2)", P.guide.id == "t:g3", P.guide and P.guide.id)
t("the detour marker is cleared", NS.db.char.parkReturn == nil)
t("g1 finished: not parked any more", P.ParkedRecord("t:g1") == nil)

-- 5. A gate above the client's cap never parks anything.
reg("t:cap", nil, { A(51, 40), T(51, 41), A(52, 42, 75), T(52, 43, 75) })
reset(60)
P.Load("t:cap")
playAll()
t("a gate above the level cap does not park", P.ParkedRecord("t:cap") == nil)

-- 6. Parked guide whose gated steps were finished elsewhere: resuming it finds nothing, it un-parks, no recursion.
reg("t:p", "t:q", { A(61, 40), A(62, 41, 3), T(62, 42, 3) })
reg("t:q", nil, { A(71, 50), T(71, 51) })
reset(1)
P.Load("t:p")
playAll()
t("p parked at 3", P.ParkedRecord("t:p") and P.ParkedRecord("t:p").level == 3)
W.level = 3
W.quests[62] = "done"                       -- done somewhere else
playAll()                                   -- finishes t:q, comes back to t:p, finds nothing left
t("p un-parked after its steps were done elsewhere", P.ParkedRecord("t:p") == nil, P.ParkedRecord("t:p") and P.ParkedRecord("t:p").level)
t("no bounce: the chain stopped cleanly", P.current == nil)

-- 7. The player loading a guide by hand ends a detour.
reg("t:d1", "t:d2", { A(81, 40), A(82, 41, 3), T(82, 42, 3) })
reg("t:d2", "t:d3", { A(83, 50), T(83, 51) })
reg("t:d3", nil, { A(84, 60), T(84, 61) })
reg("t:other", nil, { A(85, 70), T(85, 71) })
reset(1)
P.Load("t:d1")
playAll()
W.level = 3
playAll()                                   -- d2 ends, detour to d1, parkReturn = d3
t("detour set a return point", NS.db.char.parkReturn == "t:d3" and P.guide.id == "t:d1", tostring(NS.db.char.parkReturn))
P.Load("t:other")
t("loading a guide by hand clears the return point", NS.db.char.parkReturn == nil)

-- 8. Reset forgets a park.
reg("t:r", nil, { A(91, 40), A(92, 41, 3), T(92, 42, 3) })
reset(1)
P.Load("t:r")
playAll()
P.Load("t:r")
W.quests = {}                               -- a real Reset: the character abandons the quest too
P.Reset()
t("Reset forgets the park", P.ParkedRecord("t:r") == nil, P.ParkedRecord("t:r") and P.ParkedRecord("t:r").level)

-- 9. SuggestNext skips a guide that is parked and still waiting, and offers it once the gate opens.
G.SuggestNext = realSuggestNext
reg("t:sa", nil, { A(101, 40), T(101, 41) }, { minlevel = 20, maxlevel = 20 })
for id in pairs(G.registry) do if id:sub(1, 2) == "t:" and id ~= "t:sa" then G.registry[id].faction = "Horde" end end  -- Alliance test character
reset(20)
NS.db.char.parked["t:sa"] = { level = 25 }
local nx = G.SuggestNext("t:none")
t("SuggestNext passes over a guide that is parked and waiting", nx == nil or nx.id ~= "t:sa", nx and nx.id)
NS.db.char.parked["t:sa"] = { level = 20 }
nx = G.SuggestNext("t:none")
t("once the gate opens it is offered again", nx and nx.id == "t:sa", nx and nx.id)
NS.db.char.parked["t:sa"] = nil

-- 10. A level-up with nothing left to do brings a parked guide back (no end-of-guide event involved).
reg("t:lone", nil, { A(111, 40), A(112, 41, 4), T(112, 42, 4) })
G.SuggestNext = function() return nil end   -- nothing else to do at this level
reset(1)
P.Load("t:lone")
playAll()
t("lone guide stays loaded with nothing to do (no next)", P.guide.id == "t:lone" and P.current == nil)
W.level = 4
P.Refresh()          -- PLAYER_LEVEL_UP
t("a level-up opens the step in the same guide", P.current and P.current.qid[1] == 112)

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
print("ALL PARKED GUIDE TESTS PASSED")
