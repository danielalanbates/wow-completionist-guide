-- CompletionRoute :: Core/Skip.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- Quest-level skipping (docs/ROUTING.md "Skipping quests").
--   * A dropped quest leaves EVERY guide (quest ids are global): its accept, objectives and turn-in, and the steps that
--     only existed for it.  The guide the player sees is REBUILT from the guide's own steps.  It is a projection: done
--     and skipped ticks stay keyed by the stable step key (Core/Guide.lua), so nothing is lost, and bringing the quest
--     back gives the identical list again.
--   * Before a quest with dependents goes, the player is warned with the quests that need it, transitively
--     (Data/QuestDeps_<flavor>.lua from tools/gen_quest_deps.py; the loaded guide's own |PRE| tags where that file cannot
--     speak).  Confirming drops them too ("locked": they can no longer be accepted); cancelling changes nothing.
--   * A guide can also lose a quest on its own: when every accept step of it waits, through the guide's |PRE|, on a
--     removed quest, that guide never offers it (it stays in other guides).  Soft predecessors (breadcrumbs, optional
--     lead-ins) are never waited for once skipped (S.PreOpen, asked by Conditions.StepApplies).
--   * After every change the loaded guide is rebuilt at once and then re-planned for travel time in the background
--     (Routing/Replan.lua); other guides are rebuilt when they are opened.
-- Stored per character (Core/Account.lua A.me.questSkip) and never shared with other characters, whatever the progress
-- scope: like a step skip, dropping a quest is one character's choice (Account.OtherDid never counts skips either).
--   roots[q] = guide id the quest was dropped from     locks[q] = the dropped quest that blocks q
--   plans[guide id] = { k = rebuild key, o = saved re-planned order (author indices) | false }
-- Quest ids are the same in every data release, so roots and locks need no migration.  A rebuild key binds the guide's
-- step keys and author indices (S.PlanKey), so a saved order is never applied to a regenerated guide; a key in the
-- format of the release before step keys is converted once, under the same rule as the progress marks (Core/Account.lua
-- A.Migrate: the data has not changed since it was written).
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
-- Guide families tools/gen_quest_deps.py reads: the wiki zone guides, and the spine that reuses their text.  For any
-- other guide (quest lines, hand-written, live) the loaded guide's own PRE tags fill in quests the file lacks.
local INDEXED = { wiki = true, spine = true }
local function idSet(str)
    local set = {}
    if type(str) == "string" then for n in str:gmatch("%d+") do set[tonumber(n)] = true end end
    return set
end
local fileIdx
local function fileIndex()
    if fileIdx and fileIdx.src == NS.QuestDeps then return fileIdx end
    local D = NS.QuestDeps
    fileIdx = { pre = {}, rev = {}, free = {}, crumb = {}, never = {}, src = D, present = D ~= nil and type(D.pre) == "string" }
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
        if type(D.free) == "string" then
            for q, rest in D.free:gmatch("(%d+):([^\n]+)") do fileIdx.free[tonumber(q)] = idSet(rest) end
        end
        fileIdx.crumb, fileIdx.never = idSet(D.crumb), idSet(D.never)
    end
    return fileIdx
end
S.FileIndex = fileIndex

-- p is a soft predecessor of a step of quests qs: a breadcrumb, or an optional lead-in the wiki names for one of them
-- (tools/gen_quest_deps.py drops those from the hard set).  Skipping it never blocks the step.
local function soft(F, qs, p)
    if F.crumb[p] then return true end
    if qs then
        for i = 1, #qs do local f = F.free[qs[i]] if f and f[p] then return true end end
    end
    return false
end

-- class / race / faction: a step that fails these is never shown to this character (level, quest state and profession
-- can still change)
local function everApplies(s)
    local C = NS.Cond
    if s.class and not C.ClassMatch(s.class) then return false end
    if s.race and not C.RaceMatch(s.race) then return false end
    if s.faction and not C.FactionMatch(s.faction) then return false end
    return true
end
S.EverApplies = everApplies
local function charSig()
    local pl = NS.player or {}
    return tostring(pl.class) .. "/" .. tostring(pl.race) .. "/" .. tostring(pl.faction)
end

-- Per guide (cached on its parsed steps):
--   pre/rev  the PRE tags of every step, merged per quest (the fallback index for guides the file is not built from)
--   acc[q]   the PRE lists of q's accept steps that this character can see: the guide only offers q once one of them
--            opens, so a quest whose every accept waits on a removed quest is gone from this guide too (false when one
--            of q's accepts has no PRE)
--   accRev   p -> quests with an accept step that waits on p;  mine[q] / any[q]: q has an accept this character sees /
--            has an accept at all
local guideIdx = setmetatable({}, { __mode = "k" })
local function guideIndex(steps)
    local sig = charSig()
    local gi = guideIdx[steps]
    if gi and gi.sig == sig then return gi end
    gi = { pre = {}, rev = {}, acc = {}, accRev = {}, mine = {}, any = {}, sig = sig }
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
        if s.qid and ACCEPT[s.action] then
            local seen = everApplies(s)
            for _, q in ipairs(s.qid) do
                gi.any[q] = true
                if seen then
                    gi.mine[q] = true
                    if s.pre and #s.pre > 0 then
                        local l = gi.acc[q]
                        if l == nil then l = {} gi.acc[q] = l end
                        if l then
                            l[#l + 1] = s
                            for _, p in ipairs(s.pre) do
                                local r = gi.accRev[p]
                                if not r then r = {} gi.accRev[p] = r end
                                if r[#r] ~= q then r[#r + 1] = q end
                            end
                        end
                    else
                        gi.acc[q] = false
                    end
                end
            end
        end
    end
    guideIdx[steps] = gi
    return gi
end

-- The view one decision uses: the shipped index, plus the PRE tags of the given guides for quests the index cannot
-- speak for (no index file on this client, or a guide from a family the index is not built from).  withAcc: the given
-- guides' accept steps count too (idx.acc) - what one guide offers, so only for that guide's own rebuild (S.Project);
-- the locks every guide shares follow the index.  guides = list of { id = guide id, steps = parsed steps }.
function S.Index(guides, withAcc)
    local F = fileIndex()
    local extra, accs, seen = {}, {}, {}
    for _, g in ipairs(guides or {}) do
        if g.steps then
            local gi = guideIndex(g.steps)
            seen[#seen + 1] = gi
            if withAcc then accs[#accs + 1] = gi end
            local fam = g.id and tostring(g.id):match("^(%a+):")
            if not F.present or not (fam and INDEXED[fam]) then extra[#extra + 1] = gi end
        end
    end
    local idx = { file = F.present, F = F }
    function idx.pre(q)
        local p = F.pre[q]
        if p then return p end
        for i = 1, #extra do local x = extra[i].pre[q] if x then return x end end
    end
    -- the accept steps of q that this character sees in these guides (nil: no constraint - none of them carries a PRE,
    -- or q has no accept here)
    function idx.acc(q)
        local out, copied = nil, false
        for i = 1, #accs do
            local l = accs[i].acc[q]
            if l == false then return nil end
            if l then
                if not out then out = l
                else
                    if not copied then
                        local m = {}
                        for k = 1, #out do m[k] = out[k] end
                        out, copied = m, true
                    end
                    for k = 1, #l do out[#out + 1] = l[k] end
                end
            end
        end
        return out
    end
    -- calls fn(q) for every quest that lists x as a prerequisite (a quest may be named twice)
    function idx.each(x, fn)
        local r = F.rev[x]
        if r then for i = 1, #r do fn(r[i]) end end
        for i = 1, #extra do
            local r2 = extra[i].rev[x]
            if r2 then for k = 1, #r2 do if not F.pre[r2[k]] then fn(r2[k]) end end end
        end
        for i = 1, #accs do
            local r3 = accs[i].accRev[x]
            if r3 then for k = 1, #r3 do fn(r3[k]) end end
        end
    end
    -- some accept step this character sees / any accept step at all, in these guides
    function idx.seen(q)
        local any = false
        for i = 1, #seen do
            if seen[i].mine[q] then return true end
            if seen[i].any[q] then any = true end
        end
        return not any
    end
    return idx
end

-- the guides whose own steps take part: the loaded guide, plus the guides quests were dropped from
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

-- A PRE list once the quests in `gone` are out (qs = the quests of the step that carries it, for its soft
-- predecessors).  have(p) says whether p can still be had.  "p1;p2": any one opens it, "p1&p2": all of them; a soft
-- predecessor that is gone is not waited for, and a list of nothing but those is open.
local function listOpen(list, qs, have, gone, F)
    if list.andor == "and" then
        for i = 1, #list do
            local p = list[i]
            if not have(p) and not (gone[p] and soft(F, qs, p)) then return false end
        end
        return true
    end
    local counted = false
    for i = 1, #list do
        local p = list[i]
        if not (gone[p] and not U.IsQuestComplete(p) and soft(F, qs, p)) then
            if have(p) then return true end
            counted = true
        end
    end
    return not counted
end

-- Quests that can no longer be had once the quests in `removed` are gone.  A quest can be had when its prerequisites
-- (the index, see S.Index) open and, where these guides offer it, one of its accept steps opens; a quest done or on the
-- log is past all that.  Only the dependents of `seeds` can change: they are found first, then the ones that can still
-- be had are grown from what lies outside them (least fixpoint, so a prerequisite cycle whose only way in was removed
-- goes too).  A quest the data never made obtainable (QuestDeps never) is not this removal's doing.  `removed` gets the
-- quests added; `label` (optional) maps each to the seed it came from.  Returns them nearest first.
-- strict (one guide's own rebuild, strands()): a quest the index calls unobtainable goes too when its accept in this
-- guide waits on a removed quest.  The wiki's chains hold loops (retail 38649 <- 45260 <- 45271 ...), the guide still
-- lists the quest, and without this its accept step would wait for ever.
function S.Closure(idx, seeds, removed, label, strict)
    local F = idx.F or fileIndex()
    local D, order, queue, head = {}, {}, {}, 1
    for i = 1, #seeds do queue[i] = seeds[i] end
    local function discover(q)
        if D[q] or removed[q] or U.IsQuestComplete(q) or U.IsOnQuest(q) then return end
        D[q] = true
        order[#order + 1] = q
        queue[#queue + 1] = q
    end
    while head <= #queue do
        idx.each(queue[head], discover)
        head = head + 1
    end
    if #order == 0 then return order end
    local ok = {}
    local function have(p)
        if D[p] then return ok[p] == true end
        if removed[p] then return U.IsQuestComplete(p) end
        return not F.never[p] or U.IsQuestComplete(p)
    end
    local function open(q)
        local l = idx.pre(q)
        if l and #l > 0 and not listOpen(l, { q }, have, removed, F) then return false end
        local acc = idx.acc(q)
        if not acc then return true end
        for i = 1, #acc do if listOpen(acc[i].pre, acc[i].qid, have, removed, F) then return true end end
        return false
    end
    local work, inWork, wh = {}, {}, 1
    for i = 1, #order do work[i] = order[i] inWork[order[i]] = true end
    local function requeue(r) if D[r] and not ok[r] and not inWork[r] then inWork[r] = true work[#work + 1] = r end end
    while wh <= #work do
        local q = work[wh]
        wh = wh + 1
        inWork[q] = nil
        if not ok[q] and open(q) then
            ok[q] = true
            idx.each(q, requeue)
        end
    end
    local out = {}
    for _, q in ipairs(order) do
        if not ok[q] and (strict or not F.never[q]) then out[#out + 1] = q end
    end
    for _, q in ipairs(out) do removed[q] = true end
    if label then
        -- each lock is put down to a seed through locked quests (nearest first)
        local lq, lh, lset = {}, 1, {}
        for _, q in ipairs(out) do lset[q] = true end
        for i = 1, #seeds do lq[i] = seeds[i] if label[seeds[i]] == nil then label[seeds[i]] = seeds[i] end end
        while lh <= #lq do
            local x = lq[lh]
            lh = lh + 1
            idx.each(x, function(q)
                if lset[q] and label[q] == nil then label[q] = label[x] lq[#lq + 1] = q end
            end)
        end
        for _, q in ipairs(out) do if label[q] == nil then label[q] = seeds[1] end end
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

-- Conditions.StepApplies asks this for a step with PRE: true / false once a predecessor was removed (a soft one -
-- breadcrumb, optional lead-in - is then not waited for), nil when no predecessor is removed (the usual rule decides).
-- preOk(p) is the usual test (done, or on the log).
function S.PreOpen(step, preOk)
    local removed = S.Removed()
    local pre = step.pre
    local hit = false
    for i = 1, #pre do if removed[pre[i]] then hit = true break end end
    if not hit then return nil end
    local F = fileIndex()
    if pre.andor == "and" then
        for i = 1, #pre do
            local p = pre[i]
            if not preOk(p) and not (removed[p] and soft(F, step.qid, p)) then return false end
        end
        return true
    end
    local counted = false
    for i = 1, #pre do
        local p = pre[i]
        if preOk(p) then return true end
        if not (removed[p] and soft(F, step.qid, p)) then counted = true end
    end
    return not counted
end

-- ---------------------------------------------------------------------------
-- Rebuilding a guide (a projection of its own steps)
-- ---------------------------------------------------------------------------
-- Steps that go with a dropped quest even though they carry no quest id of their own:
--   * TRAVEL: a run / fly / boat / portal / hearth / dungeon-entry step whose stretch of guide (up to the next travel
--     step that stays) only had steps of removed quests in it
--   * RIDER: an unlocated note / use-item / kill / loot step rides with the located step before it (the optimizer's
--     block rule); when that step goes (a quest step or a travel step), so does the rider
-- A step that still serves any remaining quest is always kept.  Flight paths (f) and hearth binds (h) always stay.
-- Quests this guide alone would strand are out of it too: every accept step of the quest the character can see waits
-- on a removed quest (a guide's own |PRE| the shipped index does not have), and what needs those in turn.
local RIDER = { N = true, U = true, K = true, l = true, C = true }
local TRAVEL = { R = true, F = true, b = true, J = true, H = true, D = true }
local function located(s) return s.coords ~= nil and s.zone ~= nil end

-- removed plus the quests this guide's own steps strand (nil when there are none)
local function strands(steps, removed, gid)
    local gi = guideIndex(steps)
    local need = false
    for q in pairs(removed) do if gi.accRev[q] or gi.rev[q] then need = true break end end
    if not need then return nil end
    local seeds, gone = {}, {}
    for q in pairs(removed) do seeds[#seeds + 1] = q gone[q] = true end
    table.sort(seeds)
    local out = S.Closure(S.Index({ { id = gid, steps = steps } }, true), seeds, gone, nil, true)
    if #out == 0 then return nil end
    return gone
end

-- a PRE list on a step that carries no quest of its own, once the quests in `gone` are out: can it never open?
local function preBlocked(list, gone, F)
    local function have(p) return not gone[p] or U.IsQuestComplete(p) end
    return not listOpen(list, nil, have, gone, F)
end

-- steps: a guide's own steps in its baked order.  Returns the rebuilt list (or `steps` itself when nothing goes), how
-- many steps were taken out, and the quests that are out of this guide (removed plus what it strands).
function S.Project(steps, removed, gid)
    removed = removed or S.Removed()
    if not steps or not next(removed) then return steps, 0, removed end
    local gone = strands(steps, removed, gid) or removed
    local F = fileIndex()
    local gi = guideIndex(steps)
    local n, drop, any = #steps, {}, false
    for i = 1, n do
        local s = steps[i]
        if (s.index or 0) > 0 then
            -- a step of a removed quest goes unless it also serves a quest that stays (and that this character can
            -- take: a quest whose every accept here is for another faction, class or race does not hold a step up)
            if s.qid then
                local keep, hit = false, false
                for _, q in ipairs(s.qid) do
                    if gone[q] then hit = true
                    elseif gi.mine[q] or not gi.any[q] then keep = true break end
                end
                if hit and not keep then drop[i] = true any = true end
            end
            -- shown only while on a removed quest
            if not drop[i] and s.active and s.active > 0 and gone[s.active] then drop[i] = true any = true end
            -- a quest-less step waiting for removed prerequisites never opens
            if not drop[i] and not s.qid and s.pre and #s.pre > 0 and preBlocked(s.pre, gone, F) then drop[i] = true any = true end
        end
    end
    if not any then return steps, 0, gone end
    -- travel first: a dropped travel step takes its riders with it below
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
    -- riders belong to the nearest step before them that has a place or a quest of its own
    local headGone = false
    for i = 1, n do
        local s = steps[i]
        if located(s) or s.qid then headGone = drop[i] or false
        elseif headGone and (s.index or 0) > 0 and RIDER[s.action] then drop[i] = true end
    end
    local out = {}
    for i = 1, n do if not drop[i] then out[#out + 1] = steps[i] end end
    return out, n - #out, gone
end

-- Rebuild key: the guide's own steps (their step keys and author indices, in list order: G.KeySum) and which of its
-- quests are gone (S.Project's third result; by default worked out here).  A saved re-plan is only applied under the key
-- it was made for.  The checksum is cached per list (P.Rebuild asks on every change).
local function goneQuests(base, removed)
    local qs, seen = {}, {}
    for _, s in ipairs(base) do
        if s.qid then
            for _, q in ipairs(s.qid) do
                if removed[q] and not seen[q] then seen[q] = true qs[#qs + 1] = q end
            end
        end
    end
    table.sort(qs)
    return table.concat(qs, ",")
end
local planSums = setmetatable({}, { __mode = "k" })
function S.PlanKey(base, removed, gid)
    if not removed then removed = select(3, S.Project(base, nil, gid)) end
    local sum = planSums[base]
    if not sum then sum = G.KeySum(base, true) planSums[base] = sum end
    return ("k%d:%s:%s"):format(G.KEY_VERSION, sum, goneQuests(base, removed))
end
-- The rebuild key of the release before step keys: count + route checksum (S.Rebuild converts a saved plan under it)
function S.LegacyPlanKey(base, removed)
    return ("%d:%d:%s"):format(#base, G.RouteChecksum(base), goneQuests(base, removed))
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
    local list, cut, gone = S.Project(base, S.Removed(), guideId)
    local plan = guideId and store().plans[guideId]
    local key
    if plan or cut > 0 then key = S.PlanKey(base, gone) end
    -- a plan saved by the release before step keys: same guide, same quests gone -> the same decision, under the new key
    if plan and plan.k ~= key and type(plan.k) == "string" and plan.k:match("^%d+:%d+:") and plan.k == S.LegacyPlanKey(base, gone) then
        plan.k = key
    end
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

-- (steps, kept step keys or nil) of a guide whose steps are parsed, for counts and progress in the guide list
local viewCache = {}
function S.ViewOf(g)
    if not (g and g.steps) then return nil end
    if not S.Any() then return #g.steps, nil end
    local c = viewCache[g.id]
    if c and c.v == S.version and c.steps == g.steps then return c.n, c.keep end
    local list, cut = S.Project(g.steps, nil, g.id)
    local keep
    if cut > 0 then
        keep = {}
        for _, s in ipairs(list) do keep[s.key] = true end
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
-- the loaded guide, and whether the loaded guide has level gates still ahead.  Only what this character could take is
-- named and counted: a dependent whose every accept step is for another class, race or faction is locked as well, but
-- it was never in this character's guide.  info.all has every quest the drop locks.
function S.Describe(q)
    local P = NS.Progress
    local all = S.Dependents(q)
    local base = P and (P.baseSteps or P.steps)
    local gid = P and P.guide and P.guide.id
    local view = S.Index(decisionGuides())
    local here = guideQuestSet(base)
    local info = { q = q, name = S.QuestName(q), all = all, locked = {}, inGuide = {}, other = {}, guideOnly = {}, steps = 0, gated = false }
    local function add(d)
        info.locked[#info.locked + 1] = d
        if here[d] then info.inGuide[#info.inGuide + 1] = d else info.other[#info.other + 1] = d end
    end
    for _, d in ipairs(all) do if view.seen(d) then add(d) end end
    if base then
        local now, _, goneNow = S.Project(base, S.Removed(), gid)
        local removed = {}
        for k in pairs(goneNow) do removed[k] = true end
        removed[q] = true
        for _, d in ipairs(all) do removed[d] = true end
        local after, _, goneAfter = S.Project(base, removed, gid)
        -- quests this guide alone loses with it (its accepts for them wait on the dropped chain): in this guide only
        local extra = {}
        for d in pairs(goneAfter) do if not removed[d] and here[d] and view.seen(d) then extra[#extra + 1] = d end end
        table.sort(extra)
        for _, d in ipairs(extra) do add(d) info.guideOnly[#info.guideOnly + 1] = d end
        local still = {}
        for _, s in ipairs(after) do still[s] = true end
        for _, s in ipairs(now) do if not still[s] and (s.index or 0) > 0 and everApplies(s) then info.steps = info.steps + 1 end end
        local lvl = U.PlayerLevel()
        for _, s in ipairs(after) do
            if s.minlevel and s.minlevel > lvl and s.action ~= "L" and everApplies(s) and not (P.IsDone and P.IsDone(s)) then info.gated = true break end
        end
    end
    info.quests = 1 + #info.locked
    info.questsHere = ((here[q] and view.seen(q)) and 1 or 0) + #info.inGuide
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
    local g = #info.guideOnly
    if g > 0 then
        lines[#lines + 1] = ("%d of them only here: this guide offers %s after it (another guide may still have %s)."):format(g,
            g == 1 and "it" or "them", g == 1 and "it" or "them")
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("Dropping the chain removes %d of your quests from this guide (%d step%s) and %d from other guides."):format(
        info.questsHere, info.steps, info.steps == 1 and "" or "s", #info.other)
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

-- The per-step Skip.  Skipping the accept of a quest that is not in the quest log means not doing the quest (its
-- objectives and turn-in would be left with nothing to work on), so it drops the quest: at once when nothing needs it,
-- after the warning otherwise.  A turn-in of a quest that others need is a quest drop too and gets the same warning.
-- Anything else is a plain step skip.
function S.SkipStep(step, opts)
    local P = NS.Progress
    if not step then return nil end
    local q = step.qid and step.qid[1]
    if q and not S.IsRemoved(q) and not U.IsQuestComplete(q) then
        local drop = ACCEPT[step.action] and not U.IsOnQuest(q)
        if not drop and TURNIN[step.action] then drop = #S.Describe(q).locked > 0 end
        if drop then
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
        local P = NS.Progress
        local here = P and P.baseSteps and select(3, S.Project(P.baseSteps, nil, P.guide and P.guide.id))
        if by then NS:Print(("%s (%d) is out because it needs %s (%d). /cr unskip %d brings both back."):format(S.QuestName(q), q, S.QuestName(by), by, by))
        elseif here and here[q] then NS:Print(("%s (%d) is out of this guide: its accept here waits on a quest you skipped (/cr skipped)."):format(S.QuestName(q), q))
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
