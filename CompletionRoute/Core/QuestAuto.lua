-- CompletionRoute :: Core/QuestAuto.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- Auto accept and turn-in, limited to the guide's own quests (docs/QUEST_AUTO.md).  Off by default (autoAccept,
-- autoTurnin in the profile; Options > Auto quests; /cr auto).
--   * A quest is touched only when it belongs to a step of the active guide's LIVE WINDOW: Progress P.order, the next
--     routing.window + 5 pending steps that the guide frame and the arrow follow.  Never the rest of the guide.
--   * Never a quest Core/Skip.lua dropped or locked, never a quest whose accept (or turn-in) step the player skipped,
--     and never while the pause key is held (autoModifier, Shift by default): holding it pauses the conversation with
--     that NPC, also for the dialogs that follow while it goes on (QA.PAUSE_GAP).
--   * Accept: not a quest that costs gold, not a daily / weekly / repeatable unless its window step is that daily (a "!"
--     step, or a Dailies or Daily Gold guide), not when the quest log is full (one chat line says so).
--   * Turn in: QUEST_PROGRESS completes only when IsQuestCompletable(); QUEST_COMPLETE takes the reward when there are
--     0 or 1 choices.  With more it stops and leaves the dialog open with one chat line, unless autoChooseReward is on
--     AND UI/ItemScore.lua finds a clear upgrade for this character.
--   * Only dialogs with a quest giver (or a quest started from an item): never a popup another addon or Blizzard opened
--     (the game's own auto-accepted and area offers, world quests, popup turn-ins without a quest giver).
--   * One action per dialog event.  A quest is picked from an NPC's list once per QA.MEMORY_S, so a quest that was
--     declined, or that the checks refused when its text came up, never loops.
-- The gossip and greeting APIs differ between clients; each call looks for the functions this client has (matrix in
-- docs/QUEST_AUTO.md).  Nothing here has run in a real client yet.
local ADDON, NS = ...
local U = NS.Util
local QA = {}
NS.QuestAuto = QA

QA.PAUSE_GAP = 10       -- seconds: a paused conversation stays paused while its dialogs keep coming at most this far apart
QA.MEMORY_S = 60        -- seconds: a quest picked or acted on at an NPC is not picked / acted on again within this time
QA.BUSY_S = 2           -- seconds: a repeated list event of the same NPC waits for the dialog to move on
QA.RECENT = 20          -- decisions kept for /cr auto and /cr bug
QA.recent = {}
QA.KEYS = { "SHIFT", "CTRL", "ALT", "NONE" }
QA.KEY_LABEL = { SHIFT = "Shift", CTRL = "Ctrl", ALT = "Alt", NONE = "no key" }
local KEY_FN = { SHIFT = "IsShiftKeyDown", CTRL = "IsControlKeyDown", ALT = "IsAltKeyDown" }

local ACCEPT = { A = true, a = true, ["!"] = true }
local TURNIN = { T = true, t = true }

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------
local function prof() return NS.db and NS.db.profile end
local function now() return GetTime and GetTime() or 0 end
-- call a client function that may not exist on this client (or may error): its results, or nothing
local function pass(ok, ...) if ok then return ... end return nil end
local function safe(fn, ...)
    if type(fn) ~= "function" then return nil end
    return pass(pcall(fn, ...))
end
local function api(name) return _G[name] end
local function posId(v) v = tonumber(v) return (v and v > 0) and v or nil end

local function note(evt, q, act, why, title)
    local r = QA.recent
    local e = { at = now(), evt = evt, q = q, act = act, why = why, title = title }
    r[#r + 1] = e
    if #r > QA.RECENT then table.remove(r, 1) end
    QA.last = e
    if NS.Debug then NS:Debug(("auto %s: %s %s%s"):format(evt, tostring(q or title or "-"), act or "left alone",
        why and (" (" .. why .. ")") or "")) end
    return act ~= nil
end

local hinted = {}
local function hint(key, text)
    local t = now()
    if hinted[key] and t - hinted[key] < QA.MEMORY_S then return end
    hinted[key] = t
    NS:Print(text)
end

-- quests picked / acted on recently: "kind:npc:quest" -> time
local acted, actedN = {}, 0
local function seen(key) local t = acted[key] return t ~= nil and now() - t < QA.MEMORY_S end
local function remember(key)
    if actedN > 200 then
        local t = now()
        for k, v in pairs(acted) do if t - v >= QA.MEMORY_S then acted[k] = nil actedN = actedN - 1 end end
    end
    if not acted[key] then actedN = actedN + 1 end
    acted[key] = now()
end

-- ---------------------------------------------------------------------------
-- Options
-- ---------------------------------------------------------------------------
function QA.Enabled(kind)
    local p = prof()
    if not p then return false end
    if kind == "accept" then return p.autoAccept and true or false end
    if kind == "turnin" then return p.autoTurnin and true or false end
    return (p.autoAccept or p.autoTurnin) and true or false
end
function QA.Key()
    local k = prof() and prof().autoModifier
    if k == "NONE" or KEY_FN[k] then return k end
    return "SHIFT"
end
function QA.KeyDown()
    local fn = KEY_FN[QA.Key()]
    fn = fn and api(fn)
    return type(fn) == "function" and fn() and true or false
end

-- Holding the key on any dialog pauses the whole conversation with that quest giver: the dialogs that follow it (the
-- quest text after a gossip pick, the reward after the progress page) stay paused while they keep coming.
local pause = {}
function QA.Paused(guid)
    local t = now()
    guid = guid or "?"
    if QA.KeyDown() then pause.guid, pause.at = guid, t return true end
    if pause.guid == guid and t - pause.at <= QA.PAUSE_GAP then pause.at = t return true end
    pause.guid = nil
    return false
end

-- ---------------------------------------------------------------------------
-- The live window
-- ---------------------------------------------------------------------------
-- skip marks are stored by stable step key (Core/Guide.lua G.AssignKeys, docs/STEP_KEYS.md), not by author index
local byKeyCache = setmetatable({}, { __mode = "k" })
local function byKey(list)
    local m = byKeyCache[list]
    if not m then
        m = {}
        for _, s in ipairs(list) do if s.key then m[s.key] = s end end
        byKeyCache[list] = m
    end
    return m
end
local function dailyGuide(g)
    local G = NS.Guide
    local ty = (G and G.NormalizeType) and G.NormalizeType(g.type) or g.type
    return ty == "Dailies" or g.goldKind == "Daily Gold" or g.folder == "Daily Gold"
end
QA.DailyGuide = dailyGuide

-- Progress rebuilds its list a moment after a quest is accepted or turned in (its event throttle, 0.3 s).  A follow-up
-- quest the same NPC offers at once (its |PRE| is the quest just taken or handed in) must already count, so until that
-- refresh the window is read straight from Progress's pending steps: the same routing.window + 5 steps P.order holds
-- (the live reorder only permutes them), except that a step the refresh would tick (the accept of the quest just
-- taken) still holds a place.  That costs 0.06-0.34 ms; a full P.Refresh() here measured up to about 20 ms.
local stale = false

-- The quests of the live window:
--   quests[q] = { step = first window step of q, accept = its accept step, turnin = its turn-in step, daily = true when
--                 a window step of q is a daily step }
--   noAccept[q] / noTurnin[q]: the player skipped an accept / turn-in step of q in this guide (any position)
-- Quests Core/Skip.lua removed never enter it.  nil when no guide is loaded.
function QA.Window()
    local P = NS.Progress
    local g = P and P.guide
    if not g then return nil end
    local list = P.order
    if stale and P.Pending then
        local r = prof() and prof().routing
        local ok, pend = pcall(P.Pending, math.max(P.order and #P.order or 0, ((r and r.window) or 10) + 5))
        if ok and pend then list = pend end
    end
    if not list then return nil end
    local Sk = NS.Skip
    local w = { quests = {}, noAccept = {}, noTurnin = {}, guide = g, n = 0, fresh = list ~= P.order }
    local dg = dailyGuide(g)
    for _, s in ipairs(list) do
        if s.qid then
            for _, q in ipairs(s.qid) do
                if not (Sk and Sk.IsRemoved and Sk.IsRemoved(q)) then
                    local e = w.quests[q]
                    if not e then e = { step = s } w.quests[q] = e w.n = w.n + 1 end
                    if ACCEPT[s.action] and not e.accept then e.accept = s end
                    if TURNIN[s.action] and not e.turnin then e.turnin = s end
                    if dg or s.action == "!" then e.daily = true end
                end
            end
        end
    end
    local marks = P.SkippedMarks and P.SkippedMarks()
    if marks and next(marks) then
        local idx = byKey(P.baseSteps or P.steps or {})
        for k, on in pairs(marks) do
            local s = on and idx[k]
            if s and s.qid then
                for _, q in ipairs(s.qid) do
                    if ACCEPT[s.action] then w.noAccept[q] = true end
                    if TURNIN[s.action] then w.noTurnin[q] = true end
                end
            end
        end
    end
    return w
end

-- A dialog that gave no quest id: the window quest with exactly this title (the client's own name for it when the
-- client knows it, else the guide's).  Ambiguous or unknown -> nil.
local function norm(t) return t and (tostring(t):lower():gsub("[^%w]", "")) or "" end
function QA.QuestByTitle(w, title)
    local key = norm(title)
    if key == "" or not w then return nil end
    local found
    for q, e in pairs(w.quests) do
        local hit = norm(U.QuestTitle and U.QuestTitle(q)) == key or norm(e.step.title) == key
            or (e.accept and norm(e.accept.title) == key) or (e.turnin and norm(e.turnin.title) == key)
        if hit then
            if found and found ~= q then return nil end
            found = q
        end
    end
    return found
end

local function removedWhy(q)
    local Sk = NS.Skip
    if Sk and Sk.IsRemoved and Sk.IsRemoved(q) then return (Sk.IsRoot and Sk.IsRoot(q)) and "dropped" or "locked" end
    return nil
end

function QA.QuestLog()
    local R = NS.Router
    if R and R.QuestLog then
        local ok, n, cap = pcall(R.QuestLog)
        if ok then return n or 0, cap end
    end
    return 0, nil
end

-- May this quest be accepted?  offer = what the dialog says about it: { daily, weekly, repeatable, money (copper) }.
function QA.CanAccept(q, offer, w)
    if not QA.Enabled("accept") then return false, "off" end
    w = w or QA.Window()
    if not w then return false, "no guide" end
    if not q then return false, "unknown quest" end
    local why = removedWhy(q)
    if why then return false, why end
    local e = w.quests[q]
    if not e then return false, "not in window" end
    if w.noAccept[q] then return false, "step skipped" end
    offer = offer or {}
    if (tonumber(offer.money) or 0) > 0 then return false, "costs gold" end
    if (offer.daily or offer.weekly or offer.repeatable) and not e.daily then return false, "repeatable" end
    local n, cap = QA.QuestLog()
    if cap and n >= cap then return false, "log full" end
    return true
end

function QA.CanTurnIn(q, w)
    if not QA.Enabled("turnin") then return false, "off" end
    w = w or QA.Window()
    if not w then return false, "no guide" end
    if not q then return false, "unknown quest" end
    local why = removedWhy(q)
    if why then return false, why end
    if not w.quests[q] then return false, "not in window" end
    if w.noTurnin[q] then return false, "step skipped" end
    return true
end

-- ---------------------------------------------------------------------------
-- Reading the quest giver
-- ---------------------------------------------------------------------------
local function npcGUID() return safe(api("UnitGUID"), "npc") or safe(api("UnitGUID"), "questnpc") end

-- Daily or weekly by the client's own frequency constants (C_GossipInfo and the greeting frame use Enum.QuestFrequency
-- where it exists; the old gossip API used LE_QUEST_FREQUENCY_*).  QUEST_DETAIL's QuestIsDaily() decides in the end.
local function freqDaily(f)
    if type(f) ~= "number" then return false end
    local E = type(Enum) == "table" and Enum.QuestFrequency
    if type(E) == "table" and E.Daily ~= nil then
        return f == E.Daily or f == E.Weekly or (E.ResetByScheduler ~= nil and f == E.ResetByScheduler)
    end
    if LE_QUEST_FREQUENCY_DAILY ~= nil then return f == LE_QUEST_FREQUENCY_DAILY or f == LE_QUEST_FREQUENCY_WEEKLY end
    return false
end

-- Old gossip API (removed from every current client, see docs/QUEST_AUTO.md): flat values, one group per quest.
-- The group is 7 values for available quests and 6 for active ones, plus a quest id on builds that appended one.
local function groups(n, base, ...)
    local total = select("#", ...)
    if total == 0 then return {} end
    local v = { ... }
    local stride
    if n and n > 0 and total % n == 0 then stride = total / n end
    if not stride then
        for _, s in ipairs({ base + 1, base }) do
            if total % s == 0 then
                local ok = true
                for k = 1, total, s do if type(v[k]) ~= "string" then ok = false break end end
                if ok then stride = s break end
            end
        end
    end
    if not stride then return {} end
    local out = {}
    for k = 1, total, stride do
        local g = {}
        for j = 0, stride - 1 do g[j + 1] = v[k + j] end
        g.q = stride > base and posId(g[stride]) or nil
        out[#out + 1] = g
    end
    return out
end

-- The quest giver's lists, read through whichever API this client has.  { api =, active = { { q, title, complete, sel } },
-- available = { { q, title, daily, repeatable, ignored, sel } }, selectActive = fn, selectAvailable = fn } or nil.
function QA.ReadGossip()
    local C = C_GossipInfo
    if type(C) == "table" and C.GetAvailableQuests and C.GetActiveQuests and C.SelectAvailableQuest and C.SelectActiveQuest then
        local out = { api = "C_GossipInfo", active = {}, available = {}, selectActive = C.SelectActiveQuest, selectAvailable = C.SelectAvailableQuest }
        for _, i in ipairs(safe(C.GetActiveQuests) or {}) do
            out.active[#out.active + 1] = { q = posId(i.questID), title = i.title, complete = i.isComplete and true or false, sel = i.questID }
        end
        for _, i in ipairs(safe(C.GetAvailableQuests) or {}) do
            out.available[#out.available + 1] = { q = posId(i.questID), title = i.title, daily = freqDaily(i.frequency),
                repeatable = i.repeatable and true or false, ignored = i.isIgnored and true or false, sel = i.questID }
        end
        return out
    end
    local getAv, getAc = api("GetGossipAvailableQuests"), api("GetGossipActiveQuests")
    local selAv, selAc = api("SelectGossipAvailableQuest"), api("SelectGossipActiveQuest")
    if getAv and getAc and selAv and selAc then
        local out = { api = "GetGossipAvailableQuests", active = {}, available = {}, selectActive = selAc, selectAvailable = selAv }
        for k, g in ipairs(groups(safe(api("GetNumGossipActiveQuests")), 6, safe(getAc))) do
            out.active[#out.active + 1] = { q = g.q, title = g[1], complete = (g[4] == true or g[4] == 1), sel = k }
        end
        for k, g in ipairs(groups(safe(api("GetNumGossipAvailableQuests")), 7, safe(getAv))) do
            out.available[#out.available + 1] = { q = g.q, title = g[1], daily = freqDaily(g[4]), repeatable = (g[5] == true or g[5] == 1),
                ignored = (g[7] == true or g[7] == 1), sel = k }
        end
        return out
    end
    return nil
end

-- QUEST_GREETING: a quest giver with several quests and no gossip text.  Quest ids come from GetAvailableQuestInfo's
-- 5th return and GetActiveQuestID where the client has them; otherwise the title is matched against the window.
function QA.ReadGreeting()
    local nAv, nAc = api("GetNumAvailableQuests"), api("GetNumActiveQuests")
    local selAv, selAc = api("SelectAvailableQuest"), api("SelectActiveQuest")
    if not (nAv and nAc and selAv and selAc) then return nil end
    local out = { api = "QUEST_GREETING", active = {}, available = {}, selectActive = selAc, selectAvailable = selAv }
    for i = 1, tonumber(safe(nAc)) or 0 do
        local title, complete = safe(api("GetActiveTitle"), i)
        local c = nil
        if complete ~= nil then c = (complete == true or complete == 1) end
        out.active[#out.active + 1] = { q = posId(safe(api("GetActiveQuestID"), i)), title = title, complete = c, sel = i }
    end
    for i = 1, tonumber(safe(nAv)) or 0 do
        local _, frequency, isRepeatable, _, q = safe(api("GetAvailableQuestInfo"), i)
        out.available[#out.available + 1] = { q = posId(q), title = safe(api("GetAvailableTitle"), i), daily = freqDaily(frequency),
            repeatable = (isRepeatable == true or isRepeatable == 1), sel = i }
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Dialog handlers (each makes at most one call that changes anything)
-- ---------------------------------------------------------------------------
local offered = {}      -- q -> { daily, repeatable } as the list showed it (QUEST_DETAIL may not say "repeatable")
local busy = {}         -- the list event that last acted: { key, at }
local function clearBusy() busy.key = nil end
local function isBusy(key) return busy.key == key and now() - busy.at < QA.BUSY_S end
local function markBusy(key) busy.key, busy.at = key, now() end

-- A full quest log is said once per conversation (quest giver, or "item" for a quest started from an item), however
-- many window quests it keeps out: the list names the first and counts the rest, the quest text does not repeat it.
local function fullHint(guid, title, more)
    local n, cap = QA.QuestLog()
    hint("full:" .. tostring(guid or "item"), ("Auto accept: quest log full (%d/%d), %s%s not accepted."):format(n, cap or n,
        tostring(title), (more or 0) > 0 and (" and %d more"):format(more) or ""))
end

local function onList(evt, list, guid, w)
    -- turn-ins first: one may unlock the next accept at the same quest giver
    if QA.Enabled("turnin") then
        for _, e in ipairs(list.active) do
            local q = e.q or QA.QuestByTitle(w, e.title)
            local complete = e.complete
            if complete == nil and q then complete = select(2, U.QuestLogState(q)) and true or false end
            if complete then
                local ok, why = QA.CanTurnIn(q, w)
                local key = "pick:" .. guid .. ":" .. tostring(q or e.title)
                if ok and not seen(key) then
                    remember(key)
                    markBusy(evt .. ":" .. guid)
                    safe(list.selectActive, e.sel)
                    return note(evt, q, "pick turn-in", nil, e.title)
                end
                if not ok and why ~= "not in window" and why ~= "off" then note(evt, q, nil, why, e.title) end
            end
        end
    end
    if QA.Enabled("accept") then
        local full = {}     -- window quests a full log kept out: one chat line for all of them
        for _, e in ipairs(list.available) do
            local q = e.q or QA.QuestByTitle(w, e.title)
            if q then offered[q] = { daily = e.daily, repeatable = e.repeatable } end
            if not e.ignored then
                local ok, why = QA.CanAccept(q, { daily = e.daily, repeatable = e.repeatable }, w)
                local key = "pick:" .. guid .. ":" .. tostring(q or e.title)
                if ok and not seen(key) then
                    remember(key)
                    markBusy(evt .. ":" .. guid)
                    safe(list.selectAvailable, e.sel)
                    return note(evt, q, "pick accept", nil, e.title)
                end
                if why == "log full" then full[#full + 1] = e.title or tostring(q) end
                if not ok and why ~= "not in window" and why ~= "off" then note(evt, q, nil, why, e.title) end
            end
        end
        if #full > 0 then fullHint(guid, full[1], #full - 1) end
    end
    return note(evt, nil, nil, "nothing of the window here")
end

function QA.OnList(evt)
    if not QA.Enabled() then return false end
    local guid = npcGUID() or "?"
    if QA.Paused(guid) then return note(evt, nil, nil, "paused") end
    if isBusy(evt .. ":" .. guid) then return note(evt, nil, nil, "busy") end
    local list
    if evt == "QUEST_GREETING" then list = QA.ReadGreeting() else list = QA.ReadGossip() end
    if not list then return note(evt, nil, nil, "no quest list API on this client") end
    local w = QA.Window()
    if not w then return note(evt, nil, nil, "no guide") end
    return onList(evt, list, guid, w)
end

-- QUEST_DETAIL: the quest text of an offered quest.  Payload: questStartItemID (documented; may be nil).
function QA.OnDetail(evt, startItem)
    clearBusy()
    if not QA.Enabled("accept") then return false end
    local guid = npcGUID()
    if QA.Paused(guid) then return note(evt, nil, nil, "paused") end
    if safe(api("QuestGetAutoAccept")) then return note(evt, nil, nil, "accepted by the game") end
    if safe(api("QuestIsFromAreaTrigger")) then return note(evt, nil, nil, "area offer") end
    if not guid and not posId(startItem) then return note(evt, nil, nil, "no quest giver (popup)") end
    local w = QA.Window()
    local title = safe(api("GetTitleText"))
    local q = posId(safe(api("GetQuestID"))) or QA.QuestByTitle(w, title)
    local CQ = type(C_QuestLog) == "table" and C_QuestLog or {}
    if q and (safe(CQ.IsWorldQuest, q) or safe(CQ.IsQuestTask, q)) then return note(evt, q, nil, "world quest", title) end
    local seenOffer = q and offered[q] or {}
    local offer = { daily = safe(api("QuestIsDaily")) and true or seenOffer.daily, weekly = safe(api("QuestIsWeekly")) and true or false,
                    repeatable = (q and safe(CQ.IsRepeatableQuest, q)) and true or seenOffer.repeatable,
                    money = tonumber(safe(api("GetQuestMoneyToGet"))) or 0 }
    local ok, why = QA.CanAccept(q, offer, w)
    if not ok then
        if why == "log full" then
            fullHint(guid, title or tostring(q), 0)
        elseif why == "costs gold" then
            hint("gold:" .. tostring(q), ("Auto accept: %s costs %s; accept it yourself if you want it."):format(title or tostring(q), U.FmtMoney(offer.money)))
        end
        return note(evt, q, nil, why, title)
    end
    local key = "accept:" .. q
    if seen(key) then return note(evt, q, nil, "already accepted", title) end
    remember(key)
    safe(api("AcceptQuest"))
    return note(evt, q, "accept", nil, title)
end

local function turnInQuest(evt)
    local guid = npcGUID()
    if QA.Paused(guid) then return nil, note(evt, nil, nil, "paused") end
    if not guid then return nil, note(evt, nil, nil, "no quest giver (popup)") end
    local w = QA.Window()
    local title = safe(api("GetTitleText"))
    local q = posId(safe(api("GetQuestID"))) or QA.QuestByTitle(w, title)
    local ok, why = QA.CanTurnIn(q, w)
    if not ok then return nil, note(evt, q, nil, why, title) end
    return q, title
end

-- QUEST_PROGRESS: the "do you have it?" page.  Complete only when the client says the quest can be completed.
function QA.OnProgress(evt)
    clearBusy()
    if not QA.Enabled("turnin") then return false end
    local q, title = turnInQuest(evt)
    if not q then return false end
    local money = tonumber(safe(api("GetQuestMoneyToGet"))) or 0
    if money > 0 then
        hint("pay:" .. q, ("Auto turn-in: %s costs %s; turn it in yourself."):format(title or tostring(q), U.FmtMoney(money)))
        return note(evt, q, nil, "costs gold", title)
    end
    if not safe(api("IsQuestCompletable")) then return note(evt, q, nil, "not completable", title) end
    local key = "progress:" .. q
    if seen(key) then return note(evt, q, nil, "already completed", title) end
    remember(key)
    safe(api("CompleteQuest"))
    return note(evt, q, "complete", nil, title)
end

-- QUEST_COMPLETE: the reward page.
function QA.OnComplete(evt)
    clearBusy()
    if not QA.Enabled("turnin") then return false end
    local q, title = turnInQuest(evt)
    if not q then return false end
    local key = "reward:" .. q
    if seen(key) then return note(evt, q, nil, "already turned in", title) end
    local n = tonumber(safe(api("GetNumQuestChoices"))) or 0
    if n > 1 then
        local why, reason = "reward choice", nil
        if prof().autoChooseReward and NS.ItemScore and NS.ItemScore.ClearWinner then
            local choices = {}
            for i = 1, n do
                local _, _, _, _, usable = safe(api("GetQuestItemInfo"), "choice", i)
                choices[i] = { link = safe(api("GetQuestItemLink"), "choice", i), usable = usable }
            end
            local pick, res = NS.ItemScore.ClearWinner(choices)
            if pick then
                remember(key)
                safe(api("GetQuestReward"), pick)
                NS:Print(("Auto turn-in: took %s, a clear upgrade (+%.0f%%)."):format(tostring(choices[pick].link), res or 0))
                return note(evt, q, "turn in, reward " .. pick, nil, title)
            end
            reason = tostring(res)
            why = "reward choice: " .. reason
        end
        -- the dialog stays open: one line says why nothing was clicked
        hint("choice:" .. q, ("Auto turn-in: choose your reward for %s (%d choices%s)."):format(title or tostring(q), n,
            reason and (", " .. reason) or ""))
        return note(evt, q, nil, why, title)
    end
    remember(key)
    -- the quest frame passes 0 when there is nothing to choose and 1 when the single choice is preselected
    safe(api("GetQuestReward"), n == 1 and 1 or 0)
    return note(evt, q, "turn in", nil, title)
end

-- QUEST_ACCEPT_CONFIRM: a party member started an escort quest.  Payload: name, questTitle (+ questID on newer builds).
function QA.OnConfirm(evt, _, title, q)
    if not QA.Enabled("accept") then return false end
    if QA.KeyDown() then return note(evt, nil, nil, "paused", title) end
    local w = QA.Window()
    q = posId(q) or QA.QuestByTitle(w, title)
    local ok, why = QA.CanAccept(q, nil, w)
    if not ok then return note(evt, q, nil, why, title) end
    local key = "escort:" .. q
    if seen(key) then return note(evt, q, nil, "already accepted", title) end
    remember(key)
    safe(api("ConfirmAcceptQuest"))
    safe(api("StaticPopup_Hide"), "QUEST_ACCEPT")
    return note(evt, q, "accept shared", nil, title)
end

NS:RegisterEvent("GOSSIP_SHOW", function(evt) QA.OnList(evt) end)
NS:RegisterEvent("QUEST_GREETING", function(evt) QA.OnList(evt) end)
NS:RegisterEvent("QUEST_DETAIL", function(evt, item) QA.OnDetail(evt, item) end)
NS:RegisterEvent("QUEST_PROGRESS", function(evt) QA.OnProgress(evt) end)
NS:RegisterEvent("QUEST_COMPLETE", function(evt) QA.OnComplete(evt) end)
NS:RegisterEvent("QUEST_ACCEPT_CONFIRM", function(evt, who, title, q) QA.OnConfirm(evt, who, title, q) end)
for _, e in ipairs({ "GOSSIP_CLOSED", "QUEST_FINISHED" }) do NS:RegisterEvent(e, clearBusy) end
for _, e in ipairs({ "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_REMOVED" }) do
    NS:RegisterEvent(e, function() stale = true clearBusy() end)
end
NS:On("PROGRESS_REFRESHED", function() stale = false end)

-- ---------------------------------------------------------------------------
-- /cr auto, options and the bug report
-- ---------------------------------------------------------------------------
local function onoff(v) return v and "|cff00ff00on|r" or "|cff888888off|r" end
function QA.PrintStatus()
    local p = prof()
    NS:Print(("Auto accept %s, auto turn in %s, choose reward %s. Only quests in the guide's next steps; %s"):format(
        onoff(p.autoAccept), onoff(p.autoTurnin), onoff(p.autoChooseReward),
        QA.Key() == "NONE" and "no pause key." or ("hold " .. QA.KEY_LABEL[QA.Key()] .. " to do a quest giver yourself.")))
    local e = QA.last
    if e then
        NS:Print(("Last: %s %s - %s"):format(e.evt, tostring(e.title or e.q or ""), e.act or ("left alone: " .. tostring(e.why))))
    end
end
local KEY_WORD = { shift = "SHIFT", ctrl = "CTRL", control = "CTRL", alt = "ALT", none = "NONE", off = "NONE" }
function QA.Command(rest)
    local p = prof()
    local w1, w2 = (rest or ""):lower():match("^%s*(%S*)%s*(%S*)")
    if w1 == "accept" then p.autoAccept = not p.autoAccept
    elseif w1 == "turnin" or w1 == "turn-in" then p.autoTurnin = not p.autoTurnin
    elseif w1 == "reward" then p.autoChooseReward = not p.autoChooseReward
    elseif w1 == "on" then p.autoAccept, p.autoTurnin = true, true
    elseif w1 == "off" then p.autoAccept, p.autoTurnin = false, false
    elseif w1 == "key" then
        if not KEY_WORD[w2] then NS:Print("Usage: /cr auto key shift|ctrl|alt|none") return end
        p.autoModifier = KEY_WORD[w2]
    elseif w1 ~= "" and w1 ~= "status" then
        NS:Print("Usage: /cr auto [accept|turnin|reward|on|off|key <shift|ctrl|alt|none>]")
        return
    end
    QA.PrintStatus()
end

-- for Core/BugReport.lua: settings and the last decisions, short
function QA.Snapshot()
    local p = prof() or {}
    local out = { accept = p.autoAccept and true or false, turnin = p.autoTurnin and true or false,
                  reward = p.autoChooseReward and true or false, key = QA.Key(), recent = {} }
    for i = math.max(1, #QA.recent - 7), #QA.recent do
        local e = QA.recent[i]
        out.recent[#out.recent + 1] = ("%s q=%s %s"):format(e.evt, tostring(e.q), e.act or ("no: " .. tostring(e.why)))
    end
    return out
end

-- for tools/test_quest_auto.lua: forget every conversation (memory, pause, busy, hints)
function QA.ResetState()
    acted, actedN, hinted, offered = {}, 0, {}, {}
    pause.guid, busy.key, stale = nil, nil, false
    QA.recent, QA.last = {}, nil
end
function QA.MarkStale() stale = true end
