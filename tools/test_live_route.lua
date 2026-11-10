-- CompletionRoute :: tools/test_live_route.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- Offline tests of two routing behaviours, against stubs (no client):
--   * Routing/StepOrder.lua: the baked order is the baseline, a repair needs a real margin, the plan does not flip,
--     precedence and the quest log cap hold on random windows, the CPU budget stops a call, an off-route player is noticed
--   * Core/Progress.lua: a guide held back by level gates is parked, comes back at its level, and the chain goes on
--     from where it was heading, with no bouncing
-- Run: luajit tools/test_live_route.lua   (from repo root)
package.path = "./?.lua;" .. package.path
local ADDON, NS = "CompletionRoute", {}
dofile("tools/stubs.lua")
PLAYER = { map = 1429, x = 0.487, y = 0.42 }
PLAYER.wx, PLAYER.wy, PLAYER.inst = z2w(PLAYER.x, PLAYER.y, PLAYER.map)
local passed, failed = 0, 0
local function t(name, cond, detail)
    if cond then passed = passed + 1 print("ok   " .. name)
    else failed = failed + 1 print("FAIL " .. name .. (detail and (" :: " .. tostring(detail)) or "")) end
end
local function load(path) assert(loadfile("CompletionRoute/" .. path))(ADDON, NS) end
for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", "Data/Taxi_tbc.lua", "Data/Transit.lua", "Data/Access.lua",
    "Data/Inns.lua", "Data/ZoneAliases.lua", "Routing/TravelGraph.lua", "Routing/Roads.lua", "Routing/StepOrder.lua", "Routing/Router.lua",
    "Core/Account.lua", "Core/Professions.lua", "Core/Progress.lua", "Core/Recommend.lua" }) do load(f) end
CompletionRouteDB, CompletionRouteCharDB = nil, nil
for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", "CompletionRoute") end
NS.Print, NS.Debug = function() end, function() end
local SO, P, G = NS.StepOrder, NS.Progress, NS.Guide

-- ---------------------------------------------------------------------------
-- StepOrder with a fake straight-line router: seconds = yards, player and steps on a plane
-- ---------------------------------------------------------------------------
local playerAt = { 0, 0 }
local calls, slow = 0, 0
local function spin(ms) local t0 = os.clock() while (os.clock() - t0) * 1000 < ms do end end
local fake = {
    TravelSeconds = function(a, b)
        calls = calls + 1
        if slow > 0 then spin(slow) end
        return math.sqrt((a.px - b.px) ^ 2 + (a.py - b.py) ^ 2)
    end,
    TravelSecondsFromPlayer = function(b)
        calls = calls + 1
        if slow > 0 then spin(slow) end
        return math.sqrt((playerAt[1] - b.px) ^ 2 + (playerAt[2] - b.py) ^ 2)
    end,
}
local function st(i, action, qid, x, y, extra)
    local s = { index = i, guide = "t", action = action, title = action .. i, route = true, coords = { { x = 0.5, y = 0.5 } }, zone = 1429, px = x, py = y }
    if qid then s.qid = { qid } end
    for k, v in pairs(extra or {}) do s[k] = v end
    return s
end
local function ids(list) local o = {} for k, s in ipairs(list) do o[k] = s.index end return table.concat(o, ",") end
local function reset(x, y) playerAt = { x or 0, y or 0 } SO.Reset() end

-- 1) a saving under the margin keeps the baseline (10 s saved on a 110 s route)
reset()
local a = { st(1, "A", 1, 60, 0), st(2, "A", 2, 55, 0), st(3, "A", 3, 100, 0) }
t("gain under 15 s keeps the baked order", ids(SO.Order(a, fake)) == "1,2,3", ids(SO.Order(a, fake)))

-- 2) a big saving replaces it
reset()
local b = { st(1, "A", 1, 1000, 0), st(2, "A", 2, 10, 0), st(3, "A", 3, 20, 0), st(4, "A", 4, 1010, 0) }
t("large gain repairs the order", ids(SO.Order(b, fake)) == "2,3,1,4", ids(SO.Order(b, fake)))
t("large gain reports the change", SO.last and SO.last.changed == true)

-- 3) the 5% rule: over a 2,000 s window a 40 s saving (2%) is not enough
reset()
local c = { st(1, "A", 1, 1000, 0), st(2, "A", 2, 980, 0), st(3, "A", 3, 1020, 0), st(4, "A", 4, 2000, 0) }
t("gain under 5% of the window keeps the baked order", ids(SO.Order(c, fake)) == "1,2,3,4", ids(SO.Order(c, fake)))

-- 4) hysteresis: once repaired, the plan is what has to be beaten; a slightly better alternative does not flip it back
reset()
local d = { st(1, "A", 1, 1000, 0), st(2, "A", 2, 10, 0), st(3, "A", 3, 20, 0), st(4, "A", 4, 1010, 0) }
local r1 = SO.Plan(d, fake)
t("plan adopts the repair", ids(r1) == "2,3,1,4", ids(r1))
local r2 = SO.Plan(d, fake)
t("plan is stable on the next refresh", ids(r2) == ids(r1), ids(r2))
playerAt = { 900, 0 }          -- halfway along: the plan still stands while the alternatives are within the margin
SO.Reset() SO.plan = { guide = "t", steps = r1 }
local r3 = SO.Plan(d, fake)
t("off-route player: the plan yields when the first leg is far worse", r3[1].index == 1 or r3[1].index == 4, ids(r3))

-- 5) precedence on random windows
math.randomseed(7)
local bad, changed, overCap = 0, 0, 0
for _ = 1, 400 do
    reset(math.random(0, 1000), math.random(0, 1000))
    local w, i, seenA = {}, 0, {}
    local q = 0
    while i < 12 do
        i = i + 1
        local roll = math.random()
        local open = {}
        for k, v in pairs(seenA) do if v == "A" then open[#open + 1] = k end end
        local s
        if roll < 0.4 or #open == 0 then
            q = q + 1
            s = st(i, "A", q, math.random(0, 1000), math.random(0, 1000), q > 1 and math.random() < 0.3 and { pre = { q - 1 } } or nil)
            seenA[q] = "A"
        elseif roll < 0.7 then
            s = st(i, "C", open[math.random(#open)], math.random(0, 1000), math.random(0, 1000))
        else
            local tq = open[math.random(#open)]
            s = st(i, "T", tq, math.random(0, 1000), math.random(0, 1000))
            seenA[tq] = "T"
        end
        if math.random() < 0.08 then s.route = false end
        w[i] = s
    end
    local out = SO.Order(w, fake, { logStart = 0, logCap = 3 })
    if ids(out) ~= ids(w) then changed = changed + 1 end
    local pos = {}
    for k, s in ipairs(out) do pos[s.index] = k end
    if #out ~= 12 then bad = bad + 1 end
    for x = 1, 12 do
        for y = x + 1, 12 do
            local sx, sy = w[x], w[y]
            local inv = pos[x] > pos[y]
            if inv then
                local qx, qy = sx.qid and sx.qid[1], sy.qid and sy.qid[1]
                local rx = sx.action == "A" and 0 or sx.action == "C" and 1 or 2
                local ry = sy.action == "A" and 0 or sy.action == "C" and 1 or 2
                if qx == qy and rx < ry and sx.action == "A" then bad = bad + 1 end
                if qx == qy and sx.action == "C" and sy.action == "T" then bad = bad + 1 end
                if not sx.route or not sy.route then bad = bad + 1 end
                if sy.action == "A" and sy.pre and sx.action == "T" and sx.qid[1] == sy.pre[1] then bad = bad + 1 end
            end
        end
    end
    -- the log cap: a repair may not raise the peak above max(cap, the baseline's own peak)
    local function peak(list) local o, p = 0, 0 for _, s in ipairs(list) do if s.action == "A" then o = o + 1 elseif s.action == "T" then o = o - 1 end if o > p then p = o end end return p end
    if peak(out) > math.max(3, peak(w)) then overCap = overCap + 1 end
end
t("400 random windows: precedence and anchors hold", bad == 0, bad)
t("400 random windows: quest log cap holds", overCap == 0, overCap)
t("400 random windows: repairs do happen", changed > 50, changed)

-- 6) a step with no coordinates rides along with the located step before it
reset()
local e = { st(1, "A", 1, 1000, 0), st(2, "A", 2, 1010, 0), st(3, "A", 3, 10, 0), st(4, "A", 4, 20, 0) }
e[2].coords, e[2].zone = nil, nil
local eo = SO.Order(e, fake)
local epos = {}
for k, s in ipairs(eo) do epos[s.index] = k end
t("an unlocated step stays attached to the step before it", epos[2] == epos[1] + 1, ids(eo))

-- 7) the budget: every router call costs 2 ms, the call gets 3 ms and returns the baseline, later calls finish the work
reset()
local f = {}
for i = 1, 8 do f[i] = st(i, "A", i, (i % 2 == 0) and i * 5 or 2000 + i * 5, 0) end
slow = 2
local t0 = os.clock()
local out1 = SO.Plan(f, fake, { budget = 3 })
local spent = (os.clock() - t0) * 1000
t("out of budget: the baseline stands", ids(out1) == ids(f), ids(out1))
t("out of budget: asks for a retry", SO.needsMore == true)
t("out of budget: the call stayed near its budget (<= 3 ms + one router call + overhead)", spent <= 9, spent)
local guard = 0
repeat guard = guard + 1 local o = SO.Plan(f, fake, { budget = 3 }) until not SO.needsMore or guard > 200
slow = 0
t("retries finish the repair", not SO.needsMore and guard < 200, guard)
t("kept costs make a repeat call free of router work", (function()
    local before = calls
    SO.Plan(f, fake, { budget = 3 })
    return calls == before
end)())

-- 8) the player has gone off the route: the far first leg is replaced
reset(5000, 0)
local h = { st(1, "A", 1, 10, 0), st(2, "A", 2, 20, 0), st(3, "A", 3, 5010, 0), st(4, "A", 4, 5020, 0) }
local ho = SO.Order(h, fake)
t("off route: goes to the nearby block first", ho[1].index == 3 or ho[1].index == 4, ids(ho))
t("off route: reported", SO.last and SO.last.offRoute == true)

-- ---------------------------------------------------------------------------
-- Parked guides
-- ---------------------------------------------------------------------------
local LEVEL, DONE, ONLOG = 5, {}, {}
UnitLevel = function() return LEVEL end
UnitXP = function() return 0 end
UnitXPMax = function() return 100 end
C_QuestLog.IsQuestFlaggedCompleted = function(q) return DONE[q] == true end
C_QuestLog.GetAllCompletedQuestIDs = function() local o = {} for q in pairs(DONE) do o[#o + 1] = q end return o end
C_QuestLog.IsOnQuest = function(q) return ONLOG[q] == true end
C_QuestLog.GetLogIndexForQuestID = function(q) return ONLOG[q] and 1 or nil end
NS.db.char.done, NS.db.char.skipped, NS.db.char.reopened = {}, {}, {}
G.Register({ id = "p:wide", name = "Wide", type = "Leveling", zone = 1429, faction = "Alliance", minlevel = 1, maxlevel = 50, next = "p:b", text =
    "A Early|QID|101|M|40,40|Z|1429; Elwynn Forest|\nA Gated|QID|102|M|41,41|Z|1429; Elwynn Forest|LVL|10|\nA Beyond|QID|103|M|41,41|Z|1429; Elwynn Forest|LVL|300|" })
G.Register({ id = "p:b", name = "B", type = "Leveling", zone = 1429, faction = "Alliance", minlevel = 1, maxlevel = 50, next = "p:c", text = "A B|QID|201|M|42,42|Z|1429; Elwynn Forest|" })
G.Register({ id = "p:c", name = "C", type = "Leveling", zone = 1429, faction = "Alliance", minlevel = 1, maxlevel = 50, text = "A C|QID|301|M|43,43|Z|1429; Elwynn Forest|" })
G.SuggestNext = function() return nil end
SO.Reset()
P.Load("p:wide")
t("wide guide starts on its open step", P.current and P.current.qid[1] == 101)
ONLOG[101] = true
P.Refresh()
t("runs dry: the chain moves to its next guide", P.guide.id == "p:b", P.guide.id)
local rec = P.ParkedRecord("p:wide")
t("parked at the lowest gate, ignoring a level above the cap", rec and rec.level == 10, rec and rec.level)
t("waiting while below the gate", P.ParkedWaiting("p:wide") == true)
LEVEL = 10
t("no longer waiting at the gate", P.ParkedWaiting("p:wide") == false)
t("reaching the level does not pull the player off the guide in progress", P.guide.id == "p:b")
P.Refresh()
t("still on the guide in progress after a refresh", P.guide.id == "p:b", P.guide.id)
ONLOG[201] = true
P.Refresh()
t("guide in progress finished: the parked guide comes back first", P.guide.id == "p:wide", P.guide.id)
t("the gated step is current", P.current and P.current.qid[1] == 102)
ONLOG[102] = true
P.Refresh()
t("detour over: the chain goes where it was heading, not back to B", P.guide.id == "p:c", P.guide.id)
t("nothing parked once only steps above the cap remain", P.ParkedRecord("p:wide") == nil)

-- below the gate the chain does not come back (no bouncing), and a player's own pick ends a detour
LEVEL, DONE, ONLOG = 5, {}, {}
NS.db.char.done, NS.db.char.skipped, NS.db.char.reopened, NS.db.char.parked, NS.db.char.parkReturn = {}, {}, {}, {}, nil
if NS.Account.me then NS.Account.me.done, NS.Account.me.skipped = {}, {} end
P.Load("p:wide")
local loads = 0
local realLoad = P.Load
P.Load = function(...) loads = loads + 1 return realLoad(...) end
ONLOG[101] = true
P.Refresh()
ONLOG[201] = true
P.Refresh()
t("below the gate: the chain passes on to the following guide", P.guide.id == "p:c", P.guide.id)
ONLOG[301] = true
for _ = 1, 5 do P.Refresh() end
t("no bouncing: refreshing with nothing left loads nothing more", loads == 2, loads)
P.Load = realLoad
NS.db.char.parkReturn = "p:c"
P.Load("p:b")
t("a guide the player picks ends any detour", NS.db.char.parkReturn == nil)

-- Back reopens a step the live plan has already dropped: it must become current again, not go to the end of the plan
G.Register({ id = "p:u", name = "U", type = "Leveling", zone = 1429, text = "A U1|QID|501|M|40,40|Z|1429; Elwynn Forest|\nA U2|QID|502|M|40.2,40|Z|1429; Elwynn Forest|\nA U3|QID|503|M|40.4,40|Z|1429; Elwynn Forest|\nA U4|QID|504|M|40.6,40|Z|1429; Elwynn Forest|" })
LEVEL, DONE, ONLOG = 5, {}, {}
P.Load("p:u")
ONLOG[501] = true
P.Refresh()
t("the plan moved past the first step", P.current and P.current.qid[1] == 502, P.current and P.current.qid[1])
P.Undo()
t("Back makes the reopened step current", P.current and P.current.qid[1] == 501, P.current and P.current.qid[1])

-- two finished guides naming each other must not recurse forever
G.Register({ id = "p:x", name = "X", type = "Leveling", zone = 1429, next = "p:y", text = "A X|QID|401|M|44,44|Z|1429; Elwynn Forest|" })
G.Register({ id = "p:y", name = "Y", type = "Leveling", zone = 1429, next = "p:x", text = "A Y|QID|402|M|45,45|Z|1429; Elwynn Forest|" })
ONLOG[401], ONLOG[402] = true, true
local ok, err = pcall(P.Load, "p:x")
t("a cycle of finished guides stops at the depth limit", ok, err)
t("depth counter returns to zero", (P.chainDepth or 0) == 0, P.chainDepth)

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
print("ALL LIVE ROUTE TESTS PASSED")
