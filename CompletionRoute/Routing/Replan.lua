-- CompletionRoute :: Routing/Replan.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- Whole-guide re-plan for travel time after quests were dropped or brought back (Core/Skip.lua, docs/ROUTING.md
-- "Skipping quests").  The baseline is the rebuilt guide: its baked order minus the removed steps.  The live window
-- (Routing/StepOrder.lua) keeps working on top of whatever this settles on.
--
-- Model (the offline optimizer's, tools/optimize_routes.py, so a re-plan never breaks a rule the bake keeps):
--   * only steps still to do are planned; done steps keep their places in the list
--   * anchors (non-routable, sticky, or not an accept / objective / turn-in) stay where they are and cut the guide into
--     segments that are solved one after the other
--   * a block = a step with its own map point + the steps after it without one (or that never apply to this character)
--   * inside a segment: A < C < T per quest, a PRE quest's turn-in before the step that needs it (only edges the
--     baseline keeps), the quest log never above max(cap, the baseline's own peak) - removed quests no longer use log
--     space - and a step above the character's level only after as many turn-ins as the baseline does before its first
--     step of that level
-- Search per segment, from the baseline: first-improvement Or-opt (move 1-3 blocks next to one of their nearest
-- blocks) and 2-opt (reverse up to RP.REV_MAX blocks), with don't-look bits.  Travel costs are Router.TravelSeconds,
-- cached per pair and only computed for pairs a move needs; neighbour lists keep most of those short walks.
-- Acceptance: the new order replaces the baseline only when the whole remaining route (from the player) saves
-- max(StepOrder.MIN_GAIN, StepOrder.GAIN_FRAC of it), the margin the live window uses.  So it never costs more.
-- CPU: everything runs in a coroutine resumed from an OnUpdate with RP.FRAME_MS per frame; the router's Dijkstra yields
-- between nodes (TravelGraph.FindPath opts.tick), so no frame waits for a whole search.
local ADDON, NS = ...
local U, Cond = NS.Util, NS.Cond
local RP = {}
NS.Replan = RP

RP.FRAME_MS = 1.0       -- CPU per frame; a check runs at least every graph node, and the Lua collector can add ~0.7 ms
RP.NEIGHBORS = 8        -- nearest blocks a block may be moved next to
RP.REV_MAX = 40         -- longest 2-opt reversal, in blocks
RP.NOROUTE = 1800       -- seconds charged for a leg the router cannot path (the bake's value; same in both orders)

local ACCEPT = { A = true, a = true, ["!"] = true }
local OBJECTIVE = { C = true, K = true, l = true, U = true }
local TURNIN = { T = true, t = true }
local EPS = 0.5
local PLAYER = {}       -- sentinel: the route starts at the player
local function now() return debugprofilestop() end

-- class / race / faction / profession: a step that fails these is never visited by this character (level and quest
-- state are not checked: those steps open later and are planned)
local function everApplies(s)
    if s.class and not Cond.ClassMatch(s.class) then return false end
    if s.race and not Cond.RaceMatch(s.race) then return false end
    if s.faction and not Cond.FactionMatch(s.faction) then return false end
    if s.prof and not Cond.ProfMatch(s.prof) then return false end
    return true
end
RP.EverApplies = everApplies
local function isAnchor(s)
    return (not s.route) or s.sticky or not (ACCEPT[s.action] or OBJECTIVE[s.action] or TURNIN[s.action])
end
RP.IsAnchor = isAnchor

-- ---------------------------------------------------------------------------
-- Model
-- ---------------------------------------------------------------------------
local function build(list, ctx)
    local R, tick = ctx.router, ctx.tick
    local M = { items = {}, slot = {}, pt = {}, seq = {} }
    local items, slot, pt = M.items, M.slot, M.pt
    for i, s in ipairs(list) do
        if (s.index or 0) > 0 and not ctx.isDone(s) then items[#items + 1] = s slot[#slot + 1] = i end
    end
    for k, s in ipairs(items) do
        if s.coords and s.zone and everApplies(s) and R.StepWorld(s) then pt[k] = true end
        if k % 32 == 0 then tick() end
    end
    -- segments between anchors; blocks inside them
    local seq, cur, lead = M.seq, nil, {}
    local function closeSeg()
        if #lead > 0 then
            if not cur then cur = { blocks = {} } seq[#seq + 1] = { seg = cur } end
            cur.blocks[#cur.blocks + 1] = { items = lead }
            lead = {}
        end
        cur = nil
    end
    for k, s in ipairs(items) do
        if isAnchor(s) then
            closeSeg()
            seq[#seq + 1] = { anchor = k }
        else
            if not cur then cur = { blocks = {} } seq[#seq + 1] = { seg = cur } end
            if pt[k] then
                lead[#lead + 1] = k
                cur.blocks[#cur.blocks + 1] = { items = lead, pt = s }
                lead = {}
            elseif #cur.blocks == 0 then lead[#lead + 1] = k
            else local b = cur.blocks[#cur.blocks] b.items[#b.items + 1] = k end
        end
    end
    closeSeg()
    tick()
    -- level map over the whole baseline: K(L) = turn-ins before the first step of level >= L
    local levels, tb = {}, 0
    for k, s in ipairs(items) do
        levels[k] = s.action ~= "L" and s.minlevel or 0
        if TURNIN[s.action] then tb = tb + 1 end
    end
    local function kmap(L)
        local t, best = 0, nil
        for k, s in ipairs(items) do
            if levels[k] >= L and (not best or t < best) then best = t break end
            if TURNIN[s.action] then t = t + 1 end
        end
        return best or 0
    end
    -- walk the baseline: quest log and turn-ins carried from segment to segment
    local open, log, tdone = {}, ctx.logStart or 0, 0
    for _, s in ipairs(items) do
        local q = s.qid and s.qid[1]
        if q and U.IsOnQuest(q) then open[q] = true end
    end
    local function stepEffect(s)
        local q = s.qid and s.qid[1]
        local d = 0
        if ACCEPT[s.action] and q and not open[q] then open[q] = true d = 1
        elseif TURNIN[s.action] and q and open[q] then open[q] = nil d = -1 end
        return d, TURNIN[s.action] and 1 or 0
    end
    local kcache = {}
    for _, e in ipairs(seq) do
        if e.anchor then
            local d, t = stepEffect(items[e.anchor])
            log, tdone = log + d, tdone + t
        else
            local seg = e.seg
            local blocks = seg.blocks
            local nb = #blocks
            seg.log0, seg.tBefore = log, tdone
            seg.delta, seg.tcnt, seg.kmin, seg.pred, seg.succ = {}, {}, {}, {}, {}
            local peak, tin = log, 0
            local blockOf = {}
            for b, blk in ipairs(blocks) do
                local d, t, gate = 0, 0, 0
                for _, k in ipairs(blk.items) do
                    blockOf[k] = b
                    local dd, tt = stepEffect(items[k])
                    d, t = d + dd, t + tt
                    if levels[k] > gate then gate = levels[k] end
                end
                seg.delta[b], seg.tcnt[b] = d, t
                local km = 0
                if gate > (ctx.level or 0) then
                    local K = kcache[gate]
                    if not K then K = kmap(gate) kcache[gate] = K end
                    km = math.max(0, math.min(K - seg.tBefore, tin))
                end
                seg.kmin[b] = km
                log = log + d
                if log > peak then peak = log end
                tin = tin + t
                seg.pred[b], seg.succ[b] = {}, {}
            end
            tdone = tdone + tin
            seg.cap = math.max(ctx.logCap or math.huge, peak)
            -- precedence between blocks (only edges the baseline keeps: earlier item before later item)
            local seen = {}
            local function edge(ki, kj)
                local a, c = blockOf[ki], blockOf[kj]
                if a and c and a ~= c and ki < kj then
                    local key = a * 65536 + c
                    if not seen[key] then
                        seen[key] = true
                        local sa, pc = seg.succ[a], seg.pred[c]
                        sa[#sa + 1] = c
                        pc[#pc + 1] = a
                    end
                end
            end
            local byQ, tinsQ = {}, {}
            for _, blk in ipairs(blocks) do
                for _, k in ipairs(blk.items) do
                    local s = items[k]
                    local q = s.qid and s.qid[1]
                    if q then
                        local l = byQ[q]
                        if not l then l = { a = {}, c = {}, t = {} } byQ[q] = l end
                        if ACCEPT[s.action] then l.a[#l.a + 1] = k
                        elseif OBJECTIVE[s.action] then l.c[#l.c + 1] = k
                        elseif TURNIN[s.action] then l.t[#l.t + 1] = k
                            local tl = tinsQ[q]
                            if not tl then tl = {} tinsQ[q] = tl end
                            tl[#tl + 1] = k
                        end
                    end
                end
            end
            for _, l in pairs(byQ) do
                for _, a in ipairs(l.a) do
                    for _, j in ipairs(l.c) do edge(a, j) end
                    for _, j in ipairs(l.t) do edge(a, j) end
                end
                for _, c in ipairs(l.c) do for _, t in ipairs(l.t) do edge(c, t) end end
                for i = 2, #l.a do edge(l.a[i - 1], l.a[i]) end
                for i = 2, #l.t do edge(l.t[i - 1], l.t[i]) end
            end
            for _, blk in ipairs(blocks) do
                for _, k in ipairs(blk.items) do
                    local s = items[k]
                    if s.pre then
                        for _, p in ipairs(s.pre) do
                            for _, t in ipairs(tinsQ[p] or {}) do edge(t, k) end
                        end
                    end
                end
            end
            tick()
        end
    end
    return M
end
RP.Build = build

-- ---------------------------------------------------------------------------
-- Search over one segment
-- ---------------------------------------------------------------------------
local function solveSeg(seg, cost, ctx, stats)
    local R, tick = ctx.router, ctx.tick
    local blocks = seg.blocks
    local nb = #blocks
    local E = nb + 1
    local pred, succ, delta, tcnt, kmin, cap = seg.pred, seg.succ, seg.delta, seg.tcnt, seg.kmin, seg.cap
    local startPt, endPt = seg.startPt, seg.endPt
    -- c(u, v): u = 0 is where the segment starts, v = E is the anchor after it (0 when it has no place)
    local function c(u, v)
        if u == 0 then
            if v == E then return 0 end
            return cost(startPt, blocks[v].pt)
        end
        if v == E then return endPt and cost(blocks[u].pt, endPt) or 0 end
        return cost(blocks[u].pt, blocks[v].pt)
    end
    -- nearest blocks (straight line, same continent)
    local wx, wy, wi = {}, {}, {}
    for b = 1, nb do wx[b], wy[b], wi[b] = R.StepWorld(blocks[b].pt) end
    local K = RP.NEIGHBORS
    local nbrs = {}
    for b = 1, nb do
        local ids, ds = {}, {}
        local x, y, inst = wx[b], wy[b], wi[b]
        for o = 1, nb do
            if o ~= b and wi[o] == inst and x then
                local d = (wx[o] - x) ^ 2 + (wy[o] - y) ^ 2
                if #ids < K or d < ds[#ids] then
                    local p = math.min(#ids + 1, K)
                    while p > 1 and ds[p - 1] > d do
                        if p <= K then ids[p], ds[p] = ids[p - 1], ds[p - 1] end
                        p = p - 1
                    end
                    ids[p], ds[p] = o, d
                end
            end
        end
        nbrs[b] = ids
        if b % 8 == 0 then tick() end
    end
    local ord, pos = {}, {}
    for b = 1, nb do ord[b] = b pos[b] = b end
    local logB, tbB = { [1] = seg.log0 }, { [1] = 0 }
    local function prefix(from)
        local log, tb = logB[from], tbB[from]
        for k = from, nb do
            logB[k], tbB[k] = log, tb
            local x = ord[k]
            log, tb = log + delta[x], tb + tcnt[x]
        end
        logB[nb + 1], tbB[nb + 1] = log, tb
    end
    prefix(1)
    local function at(k) if k < 1 then return 0 elseif k > nb then return E end return ord[k] end
    local function rangeOk(lo, seqList)
        local log, tb = logB[lo], tbB[lo]
        for i = 1, #seqList do
            local x = seqList[i]
            if tb < kmin[x] then return false end
            log = log + delta[x]
            if log > cap then return false end
            tb = tb + tcnt[x]
        end
        return true
    end
    local function commit(lo, seqList)
        for i = 1, #seqList do local x = seqList[i] ord[lo + i - 1] = x pos[x] = lo + i - 1 end
        prefix(lo)
    end
    local touched = {}
    local function tryMove(f)
        local i = pos[f]
        for L = 1, 3 do
            local j = i + L - 1
            if j > nb then break end
            local a, l, bq = at(i - 1), ord[j], at(j + 1)
            local gain = c(a, f) + c(l, bq) - c(a, bq)
            if gain > EPS then
                for side = 1, 2 do
                    local list = side == 1 and nbrs[f] or nbrs[l]
                    for _, u in ipairs(list) do
                        local pu = pos[u]
                        for back = 0, 1 do
                            local g = pu - back          -- insert after position g
                            if g < i - 1 or g > j then
                                local p, q = at(g), at(g + 1)
                                local add = c(p, f) + c(l, q) - c(p, q)
                                if add - gain < -EPS then
                                    local ok, lo, seqList = true, nil, {}
                                    if g < i - 1 then
                                        for x = i, j do
                                            for _, pp in ipairs(pred[ord[x]]) do local pp2 = pos[pp] if pp2 > g and pp2 < i then ok = false break end end
                                            if not ok then break end
                                        end
                                        if ok then
                                            lo = g + 1
                                            for x = i, j do seqList[#seqList + 1] = ord[x] end
                                            for x = g + 1, i - 1 do seqList[#seqList + 1] = ord[x] end
                                        end
                                    else
                                        for x = i, j do
                                            for _, ss in ipairs(succ[ord[x]]) do local sp = pos[ss] if sp > j and sp <= g then ok = false break end end
                                            if not ok then break end
                                        end
                                        if ok then
                                            lo = i
                                            for x = j + 1, g do seqList[#seqList + 1] = ord[x] end
                                            for x = i, j do seqList[#seqList + 1] = ord[x] end
                                        end
                                    end
                                    if ok and rangeOk(lo, seqList) then
                                        touched[1], touched[2], touched[3], touched[4] = a, bq, p, q
                                        commit(lo, seqList)
                                        stats.moves = stats.moves + 1
                                        return true
                                    end
                                end
                            end
                        end
                        tick()
                    end
                end
            end
        end
        return false
    end
    local function try2opt(f)
        local i = pos[f]
        if i < 2 then return false end
        local p = ord[i - 1]
        for _, y in ipairs(nbrs[p]) do
            local j = pos[y]
            if j > i and j - i < RP.REV_MAX then
                local nx = at(j + 1)
                local d1 = c(p, y) + c(f, nx) - c(p, f) - c(y, nx)
                if d1 < -EPS then
                    local inner = 0
                    for k = i, j - 1 do inner = inner + c(ord[k + 1], ord[k]) - c(ord[k], ord[k + 1]) end
                    if d1 + inner < -EPS then
                        local ok = true
                        for k = i, j do
                            for _, ss in ipairs(succ[ord[k]]) do local sp = pos[ss] if sp > k and sp <= j then ok = false break end end
                            if not ok then break end
                        end
                        if ok then
                            local seqList = {}
                            for k = j, i, -1 do seqList[#seqList + 1] = ord[k] end
                            if rangeOk(i, seqList) then
                                touched[1], touched[2], touched[3], touched[4] = p, nx, y, f
                                commit(i, seqList)
                                stats.rev = stats.rev + 1
                                return true
                            end
                        end
                    end
                end
            end
            tick()
        end
        return false
    end
    -- don't-look bits: a block is looked at again only when something next to it changed
    local queue, inq, head = {}, {}, 1
    local function push(b) if b and b >= 1 and b <= nb and not inq[b] then inq[b] = true queue[#queue + 1] = b end end
    for b = 1, nb do push(b) end
    local limit = 30 * nb
    while head <= #queue and stats.moves + stats.rev < limit do
        local f = queue[head]
        head = head + 1
        inq[f] = nil
        if tryMove(f) or try2opt(f) then
            push(f)
            for _, u in ipairs(nbrs[f]) do push(u) end
            for k = 1, 4 do push(touched[k]) end
            local i = pos[f]
            push(at(i - 1)) push(at(i + 1))
        end
        tick()
    end
    return ord
end

-- ---------------------------------------------------------------------------
-- One whole re-plan (runs inside the job's coroutine)
-- ---------------------------------------------------------------------------
local function plan(list, ctx)
    local R, tick = ctx.router, ctx.tick
    local stats = { moves = 0, rev = 0, segments = 0, blocks = 0, pairs = 0 }
    local pair, from = {}, {}
    local function cost(a, b)
        if a == PLAYER then
            local v = from[b]
            if v == nil then v = R.TravelSecondsFromPlayer(b, tick) or false from[b] = v stats.pairs = stats.pairs + 1 end
            return v or RP.NOROUTE
        end
        if a == b then return 0 end
        local r = pair[a]
        if not r then r = {} pair[a] = r end
        local v = r[b]
        if v == nil then v = R.TravelSeconds(a, b, tick) or false r[b] = v stats.pairs = stats.pairs + 1 end
        return v or RP.NOROUTE
    end
    local M = build(list, ctx)
    local items, pt, seq = M.items, M.pt, M.seq
    -- the remaining route from the player along an item order: only steps with a place cost travel
    local function routeCost(order)
        local t, prev = 0, PLAYER
        for n, k in ipairs(order) do
            if pt[k] then
                t = t + cost(prev, items[k])
                prev = items[k]
            end
            if n % 16 == 0 then tick() end
        end
        return t
    end
    local order, lastPt = {}, PLAYER
    for si, e in ipairs(seq) do
        if e.anchor then
            order[#order + 1] = e.anchor
            if pt[e.anchor] then lastPt = items[e.anchor] end
        else
            local seg = e.seg
            local nb = #seg.blocks
            local nxt = seq[si + 1]
            seg.startPt = lastPt
            seg.endPt = (nxt and nxt.anchor and pt[nxt.anchor]) and items[nxt.anchor] or nil
            local ord
            if nb >= 2 then
                stats.segments, stats.blocks = stats.segments + 1, stats.blocks + nb
                ord = solveSeg(seg, cost, ctx, stats)
            else
                ord = { 1 }
            end
            for _, b in ipairs(ord) do
                for _, k in ipairs(seg.blocks[b].items) do order[#order + 1] = k end
            end
            for x = #ord, 1, -1 do
                local p = seg.blocks[ord[x]].pt
                if p then lastPt = p break end
            end
        end
    end
    local base = {}
    for k = 1, #items do base[k] = k end
    local baseCost = routeCost(base)
    local newCost = routeCost(order)
    local SO = NS.StepOrder or {}
    local margin = math.max(SO.MIN_GAIN or 15, baseCost * (SO.GAIN_FRAC or 0.05))
    local res = { baseCost = baseCost, newCost = newCost, margin = margin, steps = #items, stats = stats }
    res.accepted = (baseCost - newCost) >= margin
    if res.accepted then
        local out = {}
        for i, s in ipairs(list) do out[i] = s end
        for n, k in ipairs(order) do out[M.slot[n]] = items[k] end
        res.list = out
    end
    return res
end

-- ---------------------------------------------------------------------------
-- The job: a coroutine stepped from an OnUpdate
-- ---------------------------------------------------------------------------
local job
RP.running = false

local driver = CreateFrame("Frame")
driver:Hide()

local function finish(J)
    if job == J then job = nil end
    RP.running = job ~= nil
    if not job then driver:Hide() end
    RP.last = J.result and {
        guide = J.guide, accepted = J.result.accepted, baseCost = J.result.baseCost, newCost = J.result.newCost,
        margin = J.result.margin, steps = J.result.steps, frames = J.frames, cpu = J.cpu, maxFrame = J.maxFrame,
        stats = J.result.stats } or { guide = J.guide, error = J.error, frames = J.frames, cpu = J.cpu, maxFrame = J.maxFrame }
    NS:Fire("REPLAN_STATE", false, RP.last)
    -- applying the result means a full Progress.Refresh: give it its own frame, not the end of this slice
    if J.onDone then NS:After(0, function() J.onDone(J.result, J) end) end
end

-- Run the job for one frame's budget (ms).  Returns true while it still has work.
function RP.Step(budget)
    local J = job
    if not J then driver:Hide() return false end
    local t0 = now()
    J.deadline = t0 + (budget or RP.FRAME_MS)
    local ok, err = coroutine.resume(J.co)
    local spent = now() - t0
    J.frames, J.cpu = J.frames + 1, J.cpu + spent
    if spent > J.maxFrame then J.maxFrame = spent end
    if J.frameLog then J.frameLog[#J.frameLog + 1] = spent end
    if not ok then
        J.error = tostring(err)
        NS:Debug("re-plan failed: " .. J.error)
        finish(J)
        return false
    end
    if coroutine.status(J.co) == "dead" then finish(J) return false end
    return true
end
driver:SetScript("OnUpdate", function() RP.Step() end)

-- opts = { guide = id, list = steps (display order), onDone = fn(result, job), isDone = fn(step), frameLog = true }
function RP.Start(opts)
    RP.Cancel()
    if not (NS.Router and opts and opts.list) then return nil end
    local J = { guide = opts.guide, list = opts.list, key = opts.key, onDone = opts.onDone, frames = 0, cpu = 0, maxFrame = 0,
                frameLog = opts.frameLog and {} or nil }
    J.tick = function() if now() >= J.deadline then coroutine.yield() end end
    local logStart, logCap = 0, nil
    if NS.Router.QuestLog then logStart, logCap = NS.Router.QuestLog() end
    J.ctx = { router = opts.router or NS.Router, tick = J.tick, level = U.PlayerLevel(), logStart = logStart, logCap = logCap,
              isDone = opts.isDone or function(s) return NS.Progress.IsDone(s) end }
    J.co = coroutine.create(function() J.result = plan(J.list, J.ctx) end)
    job = J
    RP.running = true
    driver:Show()
    NS:Fire("REPLAN_STATE", true)
    return J
end

function RP.Cancel()
    local J = job
    if not J then return end
    job = nil
    RP.running = false
    driver:Hide()
    NS:Fire("REPLAN_STATE", false)
end

function RP.Job() return job end

-- Offline use (tests, tools): run a whole re-plan now, in frames of `budget` ms; returns the result and the job.
function RP.RunNow(opts, budget)
    local J = RP.Start(opts)
    if not J then return nil end
    local guard = 0
    while RP.Step(budget or 1e9) do
        guard = guard + 1
        if guard > 5e6 then RP.Cancel() break end
    end
    return J.result, J
end
