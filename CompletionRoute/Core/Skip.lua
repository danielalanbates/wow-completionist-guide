-- CompletionRoute :: Core/Skip.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- Quest-level skipping (docs/ROUTING.md "Skipping quests").
--   * A dropped quest leaves EVERY guide (quest ids are global): its accept, objectives and turn-in, and the steps that
--     only existed for it.  The guide the player sees is REBUILT from the guide's own steps.  It is a projection: done
--     and skipped ticks stay keyed by the author step index, so nothing is lost, and bringing the quest back gives the
--     identical list again.
--   * Before a quest with dependents goes, the player is warned with the quests that need it, transitively
--     (Data/QuestDeps_<flavor>.lua from tools/gen_quest_deps.py; the loaded guide's own |PRE| tags where that file cannot
--     speak).  Confirming drops them too ("locked": they can no longer be accepted); cancelling changes nothing.
--   * After every change the loaded guide is rebuilt at once and then re-planned for travel time in the background
--     (Routing/Replan.lua); other guides are rebuilt when they are opened.
-- Stored per character (Core/Account.lua A.me.questSkip) and never shared with other characters, whatever the progress
-- scope: like a step skip, dropping a quest is one character's choice (Account.OtherDid never counts skips either).
--   roots[q] = guide id the quest was dropped from     locks[q] = the dropped quest that blocks q
--   plans[guide id] = { k = rebuild key, o = saved re-planned order | false }
local ADDON, NS = ...
local U, G = NS.Util, NS.Guide
local S = {}
NS.Skip = S
S.version = 0            -- bumped on every change; caches key on it

local ACCEPT = { A = true, a = true, ["!"] = true }
local TURNIN = { T = true, t = true }

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------
-- store(true) when about to write; a character that never skipped anything gets no table in its saved variables
local EMPTY = { roots = {}, locks = {}, plans = {} }
local function store(write)
    local holder
    local me = NS.Account and NS.Account.me
    if me then holder = me
    elseif NS.db and NS.db.char then holder = NS.db.char
    else return write and { roots = {}, locks = {}, plans = {} } or EMPTY end
    local t = holder.questSkip
    if not t then
        if not write then return EMPTY end
        t = {}
        holder.questSkip = t
    end
    t.roots, t.locks, t.plans = t.roots or {}, t.locks or {}, t.plans or {}
    return t
end
S.Store = store

local removedCache, removedVer, removedStore
-- every quest that is gone for this character: dropped (roots) and locked (their dependents)
function S.Removed()
    local t = store()
    if removedCache and removedVer == S.version and removedStore == t then return removedCache end
    local r = {}
    for q in pairs(t.roots) do r[q] = true end
    for q in pairs(t.locks) do r[q] = true end
    removedCache, removedVer, removedStore = r, S.version, t
    return r
end
function S.Any() return next(S.Removed()) ~= nil end
function S.IsRemoved(q) return q ~= nil and S.Removed()[q] == true end
function S.IsRoot(q) return q ~= nil and store().roots[q] ~= nil end
function S.LockedBy(q) return q and store().locks[q] end

-- ---------------------------------------------------------------------------
-- Dependency index: who needs whom
-- ---------------------------------------------------------------------------
-- Guide families tools/gen_quest_deps.py reads (wiki zone guides, the gaps guides, the spine that reuses them, retail
-- storylines).  For any other guide (WoW-Pro, native) the loaded guide's own PRE tags fill in quests the file lacks.
local INDEXED = { wiki = true, qdb = true, qpoi = true, spine = true, story = true }
local fileIdx
local function fileIndex()
    if fileIdx and fileIdx.src == NS.QuestDeps then return fileIdx end
    local D = NS.QuestDeps
    fileIdx = { pre = {}, rev = {}, src = D, present = D ~= nil and type(D.pre) == "string" }
    if fileIdx.present then
        for q, rest in D.pre:gmatch("(%d+):([^\n]+)") do
            q = tonumber(q)
            local list = G.intlist(rest)
            if list then
                fileIdx.pre[q] = list
                for _, p in ipairs(list) do
                    local r = fileIdx.rev[p]
                    if not r then r = {} fileIdx.rev[p] = r end
                    r[#r + 1] = q
                end
            end
        end
    end
    return fileIdx
end
S.FileIndex = fileIndex

local guideIdx = setmetatable({}, { __mode = "k" })
local function guideIndex(steps)
    local gi = guideIdx[steps]
    if gi then return gi end
    gi = { pre = {}, rev = {} }
    for _, s in ipairs(steps) do
        if s.qid and s.pre and #s.pre > 0 then
            for _, q in ipairs(s.qid) do
                local cur = gi.pre[q]
                if not cur then cur = { andor = s.pre.andor } gi.pre[q] = cur end
                for _, p in ipairs(s.pre) do
                    local dup = (p == q)
                    for i = 1, #cur do if cur[i] == p then dup = true break end end
                    if not dup then
                        cur[#cur + 1] = p
                        local r = gi.rev[p]
                        if not r then r = {} gi.rev[p] = r end
                        r[#r + 1] = q
                    end
                end
            end
        end
    end
    guideIdx[steps] = gi
    return gi
end

-- The view one decision uses: the shipped index, plus the PRE tags of the given guides for quests the index cannot
-- speak for (no index file on this client, or a guide from a family the index is not built from).
-- guides = list of { id = guide id, steps = parsed steps }.
function S.Index(guides)
    local F = fileIndex()
    local extra = {}
    for _, g in ipairs(guides or {}) do
        local fam = g.id and tostring(g.id):match("^(%a+):")
        if g.steps and (not F.present or not (fam and INDEXED[fam])) then extra[#extra + 1] = guideIndex(g.steps) end
    end
    local idx = { file = F.present }
    function idx.pre(q)
        local p = F.pre[q]
        if p then return p end
        for i = 1, #extra do local x = extra[i].pre[q] if x then return x end end
    end
    -- calls fn(q) for every quest that lists x as a prerequisite
    function idx.each(x, fn)
        local r = F.rev[x]
        if r then for i = 1, #r do fn(r[i]) end end
        for i = 1, #extra do
            local r2 = extra[i].rev[x]
            if r2 then for k = 1, #r2 do if not F.pre[r2[k]] then fn(r2[k]) end end end
        end
    end
    return idx
end

-- the guides whose own PRE tags take part: the loaded guide, plus the guides quests were dropped from
local function decisionGuides()
    local out, seen = {}, {}
    local P = NS.Progress
    if P and P.guide and P.baseSteps then out[1] = { id = P.guide.id, steps = P.baseSteps } seen[P.guide.id] = true end
    for _, gid in pairs(store().roots) do
        if type(gid) == "string" and not seen[gid] and G.registry[gid] then
            seen[gid] = true
            local ok, st = pcall(G.Steps, gid)
            if ok and st then out[#out + 1] = { id = gid, steps = st } end
        end
    end
    return out
end

-- Quests that can no longer be accepted once the quests in `removed` are gone, found from `seeds` outward through
-- dependents.  A prerequisite list "p1;p2" (any one opens the quest) blocks only when every one is gone; "p1&p2" blocks
-- when any is.  A quest the character has done, or has on the log, is past its prerequisites and never blocked, and a
-- dropped quest that is already turned in blocks nothing.  `removed` gets the blocked quests added; `label` (optional)
-- maps each to the seed it came from.  Returns them nearest first.
function S.Closure(idx, seeds, removed, label)
    local out, queue, head = {}, {}, 1
    for i = 1, #seeds do queue[i] = seeds[i] end
    local function gone(p) return removed[p] and not U.IsQuestComplete(p) end
    local x
    local function visit(q)
        if removed[q] or U.IsQuestComplete(q) or U.IsOnQuest(q) then return end
        local list = idx.pre(q)
        if not list or #list == 0 then return end
        local blocked
        if list.andor == "and" then
            blocked = false
            for i = 1, #list do if gone(list[i]) then blocked = true break end end
        else
            blocked = true
            for i = 1, #list do if not gone(list[i]) then blocked = false break end end
        end
        if blocked then
            removed[q] = true
            if label then label[q] = label[x] or x end
            out[#out + 1] = q
            queue[#queue + 1] = q
        end
    end
    while head <= #queue do
        x = queue[head]
        head = head + 1
        idx.each(x, visit)
    end
    return out
end

-- What dropping q would lock now (nothing is changed)
function S.Dependents(q)
    local removed = {}
    for k in pairs(S.Removed()) do removed[k] = true end
    removed[q] = true
    return S.Closure(S.Index(decisionGuides()), { q }, removed)
end

-- Locks from scratch for the current roots (after a drop, an unskip, or a change of what the character has done)
function S.Recompute()
    local t = store(true)
    local roots, removed, label = {}, {}, {}
    for q in pairs(t.roots) do roots[#roots + 1] = q removed[q] = true label[q] = q end
    table.sort(roots)
    local locked = S.Closure(S.Index(decisionGuides()), roots, removed, label)
    local locks = {}
    for _, q in ipairs(locked) do locks[q] = label[q] end
    t.locks = locks
    S.version = S.version + 1
    return locked
end

-- ---------------------------------------------------------------------------
-- Rebuilding a guide (a projection of its own steps)
-- ---------------------------------------------------------------------------
-- Steps that go with a dropped quest even though they carry no quest id of their own:
--   * RIDER: an unlocated note / use-item / kill / loot step rides with the located step before it (the optimizer's
--     block rule); when that step goes, so does the rider
--   * TRAVEL: a run / fly / boat / portal / hearth / dungeon-entry step whose stretch of guide (up to the next travel
--     step that stays) only had steps of removed quests in it
-- A step that still serves any remaining quest is always kept.  Flight paths (f) and hearth binds (h) always stay.
local RIDER = { N = true, U = true, K = true, l = true, C = true }
local TRAVEL = { R = true, F = true, b = true, J = true, H = true, D = true }
local function located(s) return s.coords ~= nil and s.zone ~= nil end

-- steps: a guide's own steps in its baked order.  Returns the rebuilt list (or `steps` itself when nothing goes) and
-- how many steps were taken out.
function S.Project(steps, removed)
    removed = removed or S.Removed()
    if not steps or not next(removed) then return steps, 0 end
    local n, drop, any = #steps, {}, false
    for i = 1, n do
        local s = steps[i]
        if (s.index or 0) > 0 then
            if s.qid then
                local keep = false
                for _, q in ipairs(s.qid) do if not removed[q] then keep = true break end end
                if not keep then drop[i] = true any = true end
            end
            -- shown only while on a removed quest
            if not drop[i] and s.active and s.active > 0 and removed[s.active] then drop[i] = true any = true end
            -- a quest-less step waiting for removed prerequisites never opens
            if not drop[i] and not s.qid and s.pre and #s.pre > 0 then
                local blocked
                if s.pre.andor == "and" then
                    blocked = false
                    for _, p in ipairs(s.pre) do if removed[p] then blocked = true break end end
                else
                    blocked = true
                    for _, p in ipairs(s.pre) do if not removed[p] then blocked = false break end end
                end
                if blocked then drop[i] = true any = true end
            end
        end
    end
    if not any then return steps, 0 end
    -- riders belong to the nearest step before them that has a place or a quest of its own
    local headGone = false
    for i = 1, n do
        local s = steps[i]
        if located(s) or s.qid then headGone = drop[i] or false
        elseif headGone and (s.index or 0) > 0 and RIDER[s.action] then drop[i] = true end
    end
    local nextKept = n + 1
    for i = n, 1, -1 do
        local s = steps[i]
        if TRAVEL[s.action] and not s.qid and not drop[i] and (s.index or 0) > 0 then
            local served, cut = false, false
            for k = i + 1, nextKept - 1 do
                if steps[k].qid then
                    if drop[k] then cut = true else served = true break end
                end
            end
            if cut and not served then drop[i] = true else nextKept = i end
        elseif TRAVEL[s.action] and not drop[i] then
            nextKept = i
        end
    end
    local out = {}
    for i = 1, n do if not drop[i] then out[#out + 1] = steps[i] end end
    return out, n - #out
end

-- Rebuild key: the guide's own steps (count + route checksum) and which of its quests are gone.  A saved re-plan is
-- only applied under the key it was made for.
function S.PlanKey(base, removed)
    removed = removed or S.Removed()
    local qs, seen = {}, {}
    for _, s in ipairs(base) do
        if s.qid then
            for _, q in ipairs(s.qid) do
                if removed[q] and not seen[q] then seen[q] = true qs[#qs + 1] = q end
            end
        end
    end
    table.sort(qs)
    return ("%d:%d:%s"):format(#base, G.RouteChecksum(base), table.concat(qs, ","))
end

local function encodeOrder(list)
    local idx = {}
    for _, s in ipairs(list) do if (s.index or 0) > 0 then idx[#idx + 1] = s.index end end
    local out, i = {}, 1
    while i <= #idx do
        local j = i
        while j < #idx and idx[j + 1] == idx[j] + 1 do j = j + 1 end
        out[#out + 1] = (j > i) and (idx[i] .. "-" .. idx[j]) or tostring(idx[i])
        i = j + 1
    end
    return table.concat(out, ",")
end
S.EncodeOrder = encodeOrder

-- list in a saved order (author indices); nil when the order does not cover exactly the list's steps
local function applyOrder(list, o)
    if type(o) ~= "string" then return nil end
    local byIndex, front, n = {}, {}, 0
    for _, s in ipairs(list) do
        if (s.index or 0) > 0 then byIndex[s.index] = s n = n + 1 else front[#front + 1] = s end
    end
    local out, used = front, {}
    local count = 0
    for part in o:gmatch("[^,]+") do
        local a, b = part:match("^(%d+)%-(%d+)$")
        a, b = tonumber(a or part), tonumber(b or a or part)
        if not a or not b or b < a then return nil end
        for i = a, b do
            local s = byIndex[i]
            if not s or used[i] then return nil end
            used[i] = true
            out[#out + 1] = s
            count = count + 1
        end
    end
    if count ~= n then return nil end
    return out
end
S.ApplyOrder = applyOrder

-- The guide as this character sees it: its own steps minus every removed quest, in the re-planned order saved for
-- exactly this set of removed quests (if one was saved).  Returns list, steps taken out, rebuild key.
function S.Rebuild(base, guideId)
    if not base then return base, 0 end
    local removed = S.Removed()
    local list, cut = S.Project(base, removed)
    local plan = guideId and store().plans[guideId]
    local key
    if plan or cut > 0 then key = S.PlanKey(base, removed) end
    if plan and plan.o and plan.k == key then
        local re = applyOrder(list, plan.o)
        if re then list = re end
    end
    return list, cut, key
end

-- A re-plan decision is already saved for this rebuild (accepted or not): do not run it again on every load
function S.HasPlan(guideId, key)
    local plan = guideId and store().plans[guideId]
    return plan ~= nil and plan.k == key
end

-- (steps, kept author indices or nil) of a guide whose steps are parsed, for counts and progress in the guide list
local viewCache = {}
function S.ViewOf(g)
    if not (g and g.steps) then return nil end
    if not S.Any() then return #g.steps, nil end
    local c = viewCache[g.id]
    if c and c.v == S.version and c.steps == g.steps then return c.n, c.keep end
    local list, cut = S.Project(g.steps)
    local keep
    if cut > 0 then
        keep = {}
        for _, s in ipairs(list) do keep[s.index] = true end
    end
    viewCache[g.id] = { v = S.version, steps = g.steps, n = #list, keep = keep }
    return #list, keep
end

-- ---------------------------------------------------------------------------
-- Names
-- ---------------------------------------------------------------------------
function S.QuestName(q)
    local t = U.QuestTitle(q)
    if t then return t end
    local D = NS.QuestDeps
    if D and type(D.name) == "string" then
        local key = q .. "="
        local at
        if D.name:sub(1, #key) == key then at = 1
        else
            local p = D.name:find("\n" .. key, 1, true)
            if p then at = p + 1 end
        end
        if at then
            local name = D.name:match("^[^=]+=([^\n]*)", at)
            if name and name ~= "" then return name end
        end
    end
    local P = NS.Progress
    for _, s in ipairs((P and P.baseSteps) or {}) do
        if s.qid and s.qid[1] == q and ACCEPT[s.action] and s.title and not s.title:match("^Quest %d+") then return s.title end
    end
    return "quest " .. q
end

-- ---------------------------------------------------------------------------
-- Dropping and bringing back
-- ---------------------------------------------------------------------------
local function guideQuestSet(steps)
    local set = {}
    for _, s in ipairs(steps or {}) do
        if s.qid then for _, q in ipairs(s.qid) do set[q] = true end end
    end
    return set
end

local function afterChange()
    if NS.Account and NS.Account.ClearCompletionCaches then NS.Account.ClearCompletionCaches() end
    local P = NS.Progress
    if P and P.Rebuild then P.Rebuild() end
    if NS.GuideMenu and NS.GuideMenu.RescanCompletion then pcall(NS.GuideMenu.RescanCompletion) end
    NS:Fire("QUESTS_SKIPPED")
end

-- What dropping q means, for the warning: the quests it locks (split this guide / other guides), how many steps leave
-- the loaded guide, and whether the loaded guide has level gates still ahead.
function S.Describe(q)
    local P = NS.Progress
    local locked = S.Dependents(q)
    local here = guideQuestSet(P and P.baseSteps)
    local info = { q = q, name = S.QuestName(q), locked = locked, inGuide = {}, other = {}, steps = 0, gated = false }
    for _, d in ipairs(locked) do
        if here[d] then info.inGuide[#info.inGuide + 1] = d else info.other[#info.other + 1] = d end
    end
    info.quests = 1 + #locked
    info.questsHere = (here[q] and 1 or 0) + #info.inGuide
    if P and P.steps then
        local removed = {}
        for k in pairs(S.Removed()) do removed[k] = true end
        removed[q] = true
        for _, d in ipairs(locked) do removed[d] = true end
        local after = S.Project(P.baseSteps or P.steps, removed)
        local nowCount = #P.steps
        info.steps = math.max(0, nowCount - #after)
        local lvl = U.PlayerLevel()
        for _, s in ipairs(after) do
            if s.minlevel and s.minlevel > lvl and s.action ~= "L" and not (P.IsDone and P.IsDone(s)) then info.gated = true break end
        end
    end
    return info
end

local function nameList(list, max)
    local out = {}
    for i = 1, math.min(#list, max) do out[i] = S.QuestName(list[i]) end
    local s = table.concat(out, ", ")
    if #list > max then s = s .. (" and %d more"):format(#list - max) end
    return s
end
S.NameList = nameList

function S.WarningText(info, viaStep)
    local lines = {}
    if viaStep then
        lines[#lines + 1] = ("Skipping this step means you will not do |cffffd200%s|r."):format(info.name)
    else
        lines[#lines + 1] = ("Skip |cffffd200%s|r?"):format(info.name)
    end
    local n = #info.locked
    lines[#lines + 1] = ("%d quest%s need%s it and can no longer be done: %s."):format(n, n == 1 and "" or "s", n == 1 and "s" or "",
        nameList(info.locked, 4))
    lines[#lines + 1] = ("(%d in this guide, %d in other guides)"):format(#info.inGuide, #info.other)
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("Dropping the chain removes %d quest%s from this guide (%d step%s) and %d from other guides."):format(
        info.questsHere, info.questsHere == 1 and "" or "s", info.steps, info.steps == 1 and "" or "s", #info.other)
    if info.gated then
        lines[#lines + 1] = "Fewer quests means less experience: level-gated steps later in the guide may open later."
    end
    lines[#lines + 1] = ("Bring it all back with /cr unskip %d."):format(info.q)
    return table.concat(lines, "\n")
end

-- Ask before a drop that locks other quests.  Tests replace S.Prompt.
function S.Prompt(text, onAccept)
    if StaticPopupDialogs and StaticPopup_Show then
        StaticPopupDialogs.COMPLETIONROUTE_SKIP_QUEST = StaticPopupDialogs.COMPLETIONROUTE_SKIP_QUEST or {
            text = "%s", button1 = "Drop chain", button2 = CANCEL or "Cancel",
            OnAccept = function(_, data) if data and data.fn then data.fn() end end,
            timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
        }
        local ok = pcall(StaticPopup_Show, "COMPLETIONROUTE_SKIP_QUEST", text, nil, { fn = onAccept })
        if ok then return true end
    end
    NS:Print((text:gsub("\n+", " ")))
    NS:Print("Nothing was skipped. To drop the chain, type: /cr skip <questID> confirm")
    return false
end

-- Drop quest q (root) and recompute what it locks; rebuilds and re-plans the loaded guide.
function S.Commit(q, guideId)
    local t = store(true)
    local P = NS.Progress
    t.roots[q] = guideId or (P and P.guide and P.guide.id) or true
    local locked = S.Recompute()
    afterChange()
    return locked
end

-- Entry point for "Skip quest" (detail panel, step context menu, /cr skip [questID]).
-- opts.confirm skips the question (typed confirmation); opts.viaStep = the step whose Skip asked for it.
-- Returns "skipped", "asked", or nil plus a reason.
function S.SkipQuest(q, opts)
    opts = opts or {}
    q = tonumber(q)
    if not q then return nil, "no quest" end
    if S.IsRoot(q) then NS:Print(("%s (%d) is already skipped. /cr unskip %d brings it back."):format(S.QuestName(q), q, q)) return nil, "already" end
    local by = S.LockedBy(q)
    if by then NS:Print(("%s (%d) is already out: it needs %s, which you skipped."):format(S.QuestName(q), q, S.QuestName(by))) return nil, "locked" end
    if U.IsQuestComplete(q) then NS:Print(("%s (%d) is already turned in; nothing to skip."):format(S.QuestName(q), q)) return nil, "done" end
    local info = S.Describe(q)
    local function go()
        local before = NS.Progress and NS.Progress.steps and #NS.Progress.steps or 0
        S.Commit(q, opts.guide)
        local after = NS.Progress and NS.Progress.steps and #NS.Progress.steps or 0
        local n = #info.locked
        if n == 0 then
            NS:Print(("Skipped %s (%d): %d step%s left this guide. /cr unskip %d brings it back."):format(info.name, q,
                math.max(0, before - after), (before - after) == 1 and "" or "s", q))
        else
            NS:Print(("Dropped %s (%d) and %d quest%s that need it (%d step%s left this guide). /cr unskip %d brings them back."):format(
                info.name, q, n, n == 1 and "" or "s", math.max(0, before - after), (before - after) == 1 and "" or "s", q))
        end
        if U.IsOnQuest(q) then NS:Print("It is still in your quest log; abandon it there if you want the slot back.") end
    end
    if #info.locked == 0 or opts.confirm then
        go()
        return "skipped", info
    end
    S.Prompt(S.WarningText(info, opts.viaStep), go)
    return "asked", info
end

-- The per-step Skip: an accept or turn-in of a quest that others need is a quest drop, so it gets the same warning.
function S.SkipStep(step, opts)
    local P = NS.Progress
    if not step then return nil end
    local q = step.qid and step.qid[1]
    if q and (ACCEPT[step.action] or TURNIN[step.action]) and not S.IsRemoved(q) and not U.IsQuestComplete(q) then
        local deps = S.Dependents(q)
        if #deps > 0 then
            opts = opts or {}
            opts.viaStep = step
            return S.SkipQuest(q, opts)
        end
    end
    P.Skip(step)
    return "step"
end

-- Bring a dropped quest back (or all of them).  Locks are recomputed from the roots that remain.
function S.Unskip(q)
    local t = store(true)
    if q == "all" then
        local n = 0
        for _ in pairs(t.roots) do n = n + 1 end
        t.roots, t.locks = {}, {}
        S.version = S.version + 1
        afterChange()
        NS:Print(("Brought back every skipped quest (%d)."):format(n))
        return n
    end
    q = tonumber(q)
    if not q then NS:Print("Usage: /cr unskip <questID|all>") return nil end
    if not t.roots[q] then
        local by = t.locks[q]
        if by then NS:Print(("%s (%d) is out because it needs %s (%d). /cr unskip %d brings both back."):format(S.QuestName(q), q, S.QuestName(by), by, by))
        else NS:Print(("Quest %d is not skipped."):format(q)) end
        return nil
    end
    local before = {}
    for k in pairs(t.locks) do before[k] = true end
    t.roots[q] = nil
    S.Recompute()
    local back = 0
    for k in pairs(before) do if not t.locks[k] then back = back + 1 end end
    afterChange()
    if t.locks[q] then
        NS:Print(("%s (%d) is no longer skipped, but it still needs %s, which you skipped."):format(S.QuestName(q), q, S.QuestName(t.locks[q])))
    else
        NS:Print(("Brought back %s (%d)%s."):format(S.QuestName(q), q, back > 0 and (" and %d quest%s that need it"):format(back, back == 1 and "" or "s") or ""))
    end
    return back
end

function S.List()
    local t = store()
    local roots = {}
    for q in pairs(t.roots) do roots[#roots + 1] = q end
    table.sort(roots)
    if #roots == 0 then NS:Print("No skipped quests. /cr skip [questID] drops one (default: the current step's quest).") return end
    NS:Print(("Skipped quests (%d):"):format(#roots))
    for _, q in ipairs(roots) do
        local mine = {}
        for d, r in pairs(t.locks) do if r == q then mine[#mine + 1] = d end end
        table.sort(mine)
        local gid = t.roots[q]
        local g = type(gid) == "string" and G.registry[gid]
        NS:Print(("  %s (%d)%s%s"):format(S.QuestName(q), q, g and (" - from " .. (g.name or g.id)) or "",
            #mine > 0 and ("; locks %d: %s"):format(#mine, nameList(mine, 3)) or ""))
    end
    NS:Print("/cr unskip <questID> | all")
end
