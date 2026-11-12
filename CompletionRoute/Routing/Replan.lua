-- CompletionRoute :: Routing/Replan.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- Whole-guide re-plan for travel time after quests were dropped or brought back (Core/Skip.lua, docs/ROUTING.md
-- "Skipping quests").  The baseline is the rebuilt guide: its baked order minus the removed steps.  The live window
-- (Routing/StepOrder.lua) keeps working on top of whatever this settles on.
--
-- Model (the offline optimizer's, tools/optimize_routes.py, so a re-plan never breaks a rule the bake keeps):
--   * only steps still to do that this character can ever see are planned; done steps, and steps for another class,
--     race, faction or profession, keep their places in the list and bind nothing
--   * anchors (non-routable, sticky, or not an accept / objective / turn-in) stay where they are and cut the guide into
--     segments that are solved one after the other
--   * a block = a located step + the steps after it that ride with it (the cost model's rule, Routing/CostModel.lua:
--     the bake's and the live window's block rule)
--   * every step the arrow can point at is priced: its |M| point, or with no |M| the live quest objective or the cost
--     model's point (an NPC's point from elsewhere in the guide, the step it rides with, a new zone's centre), exactly as
--     Router.StepWorld and the live window see it.  A leg runs from the last priced step of one block to the first of the
--     next; the legs inside a block are the same in every order
--   * inside a segment: A < C < T per quest, a PRE quest's turn-in before the step that needs it (only edges the
--     baseline keeps), the quest log never above max(cap, the baseline's own peak) - removed quests no longer use log
--     space - and a step above the character's level only after as many turn-ins as the baseline does before its first
--     step of that level
-- Costs: a job prices everything at ONE travel speed, walking factor, player position and travel graph, all fixed when
-- it starts (the player mounting, flying or learning a flight path mid-job cannot mix two cost sets).  A block's costs
-- to every block of its segment come from one graph search (Router.TravelRow), kept for the whole job.
-- Search per segment, from two starts - the baseline, and a greedy nearest-feasible order from where the segment starts -
-- keeping the cheaper: first-improvement Or-opt (move 1-3 blocks next to one of their nearest blocks by travel time,
-- or next to any block when the segment has at most RP.ALL_BELOW) and 2-opt (reverse up to RP.REV_MAX blocks), with
-- don't-look bits.
-- Acceptance: the new order replaces the baseline only when the whole remaining route (from the player) saves
-- max(StepOrder.MIN_GAIN, StepOrder.GAIN_FRAC of it), the margin the live window uses, AND the route through the steps
-- with a firm point (their own |M|, or an NPC's: Routing/CostModel.lua) is no longer than before - any other step is
-- priced at a stand-in (the zone, the live objective), and a saving must not come from that alone.  So it never costs
-- more, by either measure.
-- CPU: everything runs in a coroutine resumed from an OnUpdate with RP.FRAME_MS per frame; the graph search yields
-- after every node and every 64 walking links (TravelGraph.FindPaths opts.tick), so no frame waits for a search.
local ADDON, NS = ...
local U, Cond = NS.Util, NS.Cond
local RP = {}
NS.Replan = RP

RP.FRAME_MS = 0.8       -- CPU per frame (the hard limit is 2 ms: a check runs every graph node and every 64 links)
RP.NEIGHBORS = 8        -- nearest blocks (by travel time) a block may be moved next to...
RP.ALL_BELOW = 60       -- ...or every block of a segment that has at most this many
RP.REV_MAX = 40         -- longest 2-opt reversal, in blocks
local CM = assert(NS.CostModel, "Routing/CostModel.lua must load before Routing/Replan.lua")
RP.NOROUTE = CM.NOROUTE  -- a leg the router cannot path (Routing/CostModel.lua)

local ACCEPT = { A = true, a = true, ["!"] = true }
local OBJECTIVE = { C = true, K = true, l = true, U = true }
local TURNIN = { T = true, t = true }
local EPS = 0.5
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
-- Costs, fixed for the whole job: pair[a][b] seconds between two points (false = no route)
-- ---------------------------------------------------------------------------
local function newCosts(ctx, stats)
    local R = ctx.router
    local opts = { speed = ctx.speed, walkFactor = ctx.walkFactor, graph = ctx.graph, tick = ctx.tick, scratch = {} }
    local pair = {}
    local C = {}
    local function rowOf(a) local r = pair[a] if not r then r = {} pair[a] = r end return r end
    function C.get(a, b)
        if a == b then return 0 end
        local r = rowOf(a)
        local v = r[b]
        if v == nil then
            v = R.TravelRow(a, { b }, opts)[1] or false
            r[b] = v
            stats.searches, stats.pairs = stats.searches + 1, stats.pairs + 1
        end
        return v or RP.NOROUTE
    end
    -- every cost from a to the points in list, from one search
    function C.row(a, list)
        local r = rowOf(a)
        local need = {}
        for i = 1, #list do local b = list[i] if b ~= a and r[b] == nil then need[#need + 1] = b end end
        if #need == 0 then return end
        local res = R.TravelRow(a, need, opts)
        for i = 1, #need do r[need[i]] = res[i] or false end
        stats.searches, stats.pairs = stats.searches + 1, stats.pairs + #need
    end
    return C
end

-- ---------------------------------------------------------------------------
-- Model
-- ---------------------------------------------------------------------------
local function build(list, ctx)
    local R, tick = ctx.router, ctx.tick
    local M = { items = {}, slot = {}, pt = {}, seq = {} }
    local items, slot, pt = M.items, M.slot, M.pt
    for i, s in ipairs(list) do
        if (s.index or 0) > 0 and not ctx.isDone(s) and everApplies(s) then items[#items + 1] = s slot[#slot + 1] = i end
    end
    local head, firm = {}, {}
    for k, s in ipairs(items) do
        local wx, wy, inst = R.StepWorld(s)
        if wx then
            pt[k] = { wx = wx, wy = wy, inst = inst }
            head[k], firm[k] = CM.Located(s), CM.Firm(s)
        end
        if k % 32 == 0 then tick() end
    end
    M.firm = firm
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
            if head[k] then
                lead[#lead + 1] = k
                cur.blocks[#cur.blocks + 1] = { items = lead }
                lead = {}
            elseif #cur.blocks == 0 then lead[#lead + 1] = k
            else local b = cur.blocks[#cur.blocks] b.items[#b.items + 1] = k end
        end
    end
    closeSeg()
    -- a block's way in and way out: its first and last priced step (entryX / exitX: the first and last with a firm point)
    for _, e in ipairs(seq) do
        if e.seg then
            for _, blk in ipairs(e.seg.blocks) do
                for _, k in ipairs(blk.items) do
                    if pt[k] then
                        blk.entry = blk.entry or pt[k] blk.exit = pt[k]
                        if firm[k] then blk.entryX = blk.entryX or pt[k] blk.exitX = pt[k] end
                    end
                end
            end
        end
    end
    tick()
    -- level map over the whole baseline: K(L) = turn-ins before the first step of level >= L
    local levels = {}
    for k, s in ipairs(items) do levels[k] = s.action ~= "L" and s.minlevel or 0 end
    local function kmap(L)
        local t = 0
        for k, s in ipairs(items) do
            if levels[k] >= L then return t end
            if TURNIN[s.action] then t = t + 1 end
        end
        return 0
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
-- exact: price only the steps with a firm point (own |M| or an NPC's) instead of every step the arrow points at
local function solveSeg(seg, C, ctx, stats, startPt, endPt, exact)
    local tick = ctx.tick
    local blocks = seg.blocks
    local nb = #blocks
    local E = nb + 1
    local pred, succ, delta, tcnt, kmin, cap = seg.pred, seg.succ, seg.delta, seg.tcnt, seg.kmin, seg.cap
    local IN, OUT = exact and "entryX" or "entry", exact and "exitX" or "exit"
    -- every leg this segment can use, one search per source
    local targets = {}
    for b = 1, nb do if blocks[b][IN] then targets[#targets + 1] = blocks[b][IN] end end
    if endPt then targets[#targets + 1] = endPt end
    if startPt then C.row(startPt, targets) end
    for b = 1, nb do if blocks[b][OUT] then C.row(blocks[b][OUT], targets) end end
    -- c(u, v): u = 0 is where the segment starts, v = E is the anchor after it (0 when either end has no place)
    local function c(u, v)
        local a, b
        if u == 0 then a = startPt else a = blocks[u][OUT] end
        if v == E then b = endPt else b = blocks[v][IN] end
        if not a or not b then return 0 end
        return C.get(a, b)
    end
    -- nearest blocks by travel time (the shorter of the two legs); every block in a small segment
    local K = (nb <= RP.ALL_BELOW) and (nb - 1) or RP.NEIGHBORS
    local nbrs = {}
    for b = 1, nb do
        local ids, ds = {}, {}
        for o = 1, nb do
            if o ~= b then
                local d = math.min(c(b, o), c(o, b))
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
        if b % 4 == 0 then tick() end
    end
    local function segCost(ord)
        local t, prev = 0, 0
        for i = 1, nb do t = t + c(prev, ord[i]) prev = ord[i] end
        return t + c(prev, E)
    end

    -- local search from one starting order (a permutation of 1..nb that keeps every rule)
    local function search(init)
        local ord, pos = {}, {}
        for i = 1, nb do ord[i] = init[i] pos[init[i]] = i end
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
                        for n = 1, #list do
                            local pu = pos[list[n]]
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
                            if n % 8 == 0 then tick() end
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
            local list = nbrs[p]
            for n = 1, #list do
                local y = list[n]
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
                if n % 8 == 0 then tick() end
            end
            return false
        end
        -- don't-look bits: a block is looked at again only when something next to it changed
        local queue, inq, head = {}, {}, 1
        local function push(b) if b and b >= 1 and b <= nb and not inq[b] then inq[b] = true queue[#queue + 1] = b end end
        for b = 1, nb do push(ord[b]) end
        local limit, made = 30 * nb, 0
        while head <= #queue and made < limit do
            local f = queue[head]
            head = head + 1
            inq[f] = nil
            if tryMove(f) or try2opt(f) then
                made = made + 1
                push(f)
                local nl = nbrs[f]
                for n = 1, math.min(#nl, RP.NEIGHBORS) do push(nl[n]) end
                for k = 1, 4 do push(touched[k]) end
                local i = pos[f]
                push(at(i - 1)) push(at(i + 1))
            end
            tick()
        end
        return ord, segCost(ord)
    end

    -- greedy nearest-feasible order from the segment's start (nil when the rules leave it stuck)
    local function greedy()
        local placed, npred = {}, {}
        for b = 1, nb do npred[b] = #pred[b] end
        local ord, log, tb, last = {}, seg.log0, 0, 0
        for n = 1, nb do
            local best, bestC
            for b = 1, nb do
                if not placed[b] and npred[b] == 0 and tb >= kmin[b] and log + delta[b] <= cap then
                    local cc = c(last, b)
                    if not bestC or cc < bestC then best, bestC = b, cc end
                end
            end
            if not best then return nil end
            placed[best] = true
            ord[n] = best
            log, tb, last = log + delta[best], tb + tcnt[best], best
            for _, s2 in ipairs(succ[best]) do npred[s2] = npred[s2] - 1 end
            if n % 8 == 0 then tick() end
        end
        return ord
    end

    local ident = {}
    for b = 1, nb do ident[b] = b end
    local ord, cost = search(ident)
    local g = greedy()
    if g then
        local ord2, cost2 = search(g)
        if cost2 < cost - EPS then stats.greedy = stats.greedy + 1 return ord2 end
    end
    return ord
end

-- ---------------------------------------------------------------------------
-- One whole re-plan (runs inside the job's coroutine)
-- ---------------------------------------------------------------------------
local function plan(list, ctx)
    local tick = ctx.tick
    local stats = { moves = 0, rev = 0, segments = 0, blocks = 0, pairs = 0, searches = 0, greedy = 0 }
    ctx.graph = ctx.graph or NS.TravelGraph.Snapshot()
    local C = newCosts(ctx, stats)
    local M = build(list, ctx)
    local items, pt, seq, firm = M.items, M.pt, M.seq, M.firm
    local PLAYER = ctx.player
    -- the remaining route from the player along an item order: every priced step, as the arrow walks it (exact = only
    -- the steps with a firm point)
    -- The leg that starts at the player is priced as the arrow prices it (Router.TravelSecondsFromPlayer): the
    -- hearthstone and the other one-shot legs count there and nowhere else.  Every other leg is the hearth-free row.
    -- (Without this a baked order whose first step is one hearth away looked 800 s dearer than it is, and a slower
    -- re-plan was accepted against it.)  Never dearer than the hearth-free row; at the job's speed and walking factor.
    local fromPlayer = {}
    local function playerCost(p)
        local v = fromPlayer[p]
        if v == nil then
            v = C.get(PLAYER, p)
            local src, extra = PLAYER, 0
            if PLAYER.exit and PLAYER.inst ~= p.inst then src, extra = PLAYER.exit, ctx.router.EXIT_INSTANCE_SECONDS or 30 end
            local short = false
            if src.inst == p.inst then
                local dx, dy = src.wx - p.wx, src.wy - p.wy
                short = math.sqrt(dx * dx + dy * dy) < CM.WALK_ONLY_BELOW
            end
            if not short or src ~= PLAYER then
                local path = NS.TravelGraph.FindPath(src.wx, src.wy, src.inst, p.wx, p.wy, p.inst, { speed = ctx.speed, walkFactor = ctx.walkFactor, tick = tick })
                local c = path and path.cost
                if c and c + extra < v then v = c + extra end
            end
            fromPlayer[p] = v
        end
        return v
    end
    local function routeCost(order, exact)
        local t, prev = 0, PLAYER
        for n, k in ipairs(order) do
            local p = pt[k]
            if p and (not exact or firm[k]) then
                if prev == PLAYER and prev then t = t + playerCost(p)
                elseif prev then t = t + C.get(prev, p) end
                prev = p
            end
            if n % 16 == 0 then tick() end
        end
        return t
    end
    -- one whole order, segment by segment (each starts where the one before ended)
    local function solveAll(exact)
        local order, lastPt = {}, PLAYER
        local OUT = exact and "exitX" or "exit"
        local function anchorPt(k) return pt[k] and (not exact or firm[k]) and pt[k] or nil end
        for si, e in ipairs(seq) do
            if e.anchor then
                order[#order + 1] = e.anchor
                lastPt = anchorPt(e.anchor) or lastPt
            else
                local seg = e.seg
                local nb = #seg.blocks
                local nxt = seq[si + 1]
                local ord
                if nb >= 2 then
                    if not exact then stats.segments, stats.blocks = stats.segments + 1, stats.blocks + nb end
                    ord = solveSeg(seg, C, ctx, stats, lastPt, nxt and nxt.anchor and anchorPt(nxt.anchor) or nil, exact)
                else
                    ord = { 1 }
                end
                for _, b in ipairs(ord) do
                    for _, k in ipairs(seg.blocks[b].items) do order[#order + 1] = k end
                end
                for x = #ord, 1, -1 do
                    local p = seg.blocks[ord[x]][OUT]
                    if p then lastPt = p break end
                end
            end
        end
        return order
    end
    local base = {}
    for k = 1, #items do base[k] = k end
    local baseCost, exactBase = routeCost(base), routeCost(base, true)
    local SO = NS.StepOrder or {}
    local function marginOf(cost) return math.max(SO.MIN_GAIN or 15, cost * (SO.GAIN_FRAC or 0.05)) end
    local margin = marginOf(baseCost)
    -- A step with no firm point is priced where the arrow points before its quest is taken: a new zone's centre, a rough
    -- stand-in for the objective.  So a saving must not come from that stand-in alone: the legs between steps with a
    -- firm point (own |M| or an NPC's) may not get longer either.  The search runs on every step the arrow visits; when
    -- its order fails either test, a second search on the firm steps only gets its chance.
    local res = { baseCost = baseCost, exactBase = exactBase, margin = margin, steps = #items, stats = stats, speed = ctx.speed,
                  accepted = false, passes = {} }
    local order
    for pass = 1, 2 do
        local o = solveAll(pass == 2)
        -- the legs from the player are priced again here, for both orders together: a hearthstone cooldown runs down
        -- while a job works, and the order priced later must not look cheaper for that
        fromPlayer = {}
        baseCost, exactBase = routeCost(base), routeCost(base, true)
        margin = marginOf(baseCost)
        res.baseCost, res.exactBase, res.margin = baseCost, exactBase, margin
        local a, x = routeCost(o), routeCost(o, true)
        res.passes[pass] = { a, x }
        local ok = (baseCost - a >= margin) and x <= exactBase + EPS
        if ok or pass == 1 or a < res.newCost then order, res.newCost, res.exactNew, res.accepted, res.pass = o, a, x, ok, pass end
        if ok then break end
    end
    res.exactWorse = (not res.accepted and (baseCost - res.newCost >= margin) and res.exactNew > exactBase + EPS) or nil
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
        exactBase = J.result.exactBase, exactNew = J.result.exactNew, exactWorse = J.result.exactWorse, passes = J.result.passes, pass = J.result.pass,
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
    local R = opts.router or NS.Router
    local logStart, logCap = 0, nil
    if R.QuestLog then logStart, logCap = R.QuestLog() end
    -- one cost set for the whole job: speed, walking factor and position as they are now (the graph is fixed on the
    -- job's first frame, TravelGraph.Snapshot)
    J.ctx = { router = R, tick = J.tick, level = U.PlayerLevel(), logStart = logStart, logCap = logCap,
              speed = opts.speed or U.TravelSpeed(), walkFactor = opts.walkFactor or NS.TravelGraph.WalkFactor(),
              player = opts.player or (R.PlayerPoint and R.PlayerPoint()) or nil,
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
