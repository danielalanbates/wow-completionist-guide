-- CompletionRoute :: Routing/StepOrder.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- The live window over the guide's baked order (routing tier B, docs/FINISH_PLAN.md W4).
-- The window arrives in baked order (Data/RouteOrder_<flavor>.lua, or author order when there is no bake) and that
-- order is the BASELINE: the player follows it unless a local repair beats it by a real margin (SO.MIN_GAIN seconds or
-- SO.GAIN_FRAC of the window, whichever is larger).  A repair that wins becomes the plan, and the plan is what a later
-- refresh has to beat, so the route does not flip back and forth as the player walks.
--
-- Precedence (hard, never traded for time):
--   * A(quest) before C/K/l/U(quest) before T(quest), PRE quests turned in before the dependent A
--   * non-routable steps (R, F, H, h, N, L...) and sticky steps are anchors: everything before an anchor stays before it
--   * a step with no location at all stays attached to the located step before it
--   * a repair may not push the quest log above the cap, or above what the baseline order already needs
-- The repair is segment Or-opt (1-3 blocks) and precedence-safe 2-opt, run from the baseline and from a greedy
-- nearest-feasible route seeded at the player's position; the greedy start is what catches a player who has wandered
-- off the route (the first leg then dominates the baseline's cost).  Costs include the leg from the end of the
-- window to the step after it, so a repair cannot win by stranding the rest of the route.
-- CPU: pair costs are kept between refreshes, and a call stops at its budget (SO.FRAME_MS) and returns the
-- baseline; the caller retries a moment later and the kept costs make the retry cheaper.
local ADDON, NS = ...
local U = NS.Util
local SO = {}
NS.StepOrder = SO

SO.MIN_GAIN = 15        -- seconds a repair must save over the current order to replace it...
SO.GAIN_FRAC = 0.05     -- ...or this share of the current order's cost, whichever is larger
SO.FRAME_MS = 3         -- CPU budget per call in the client, milliseconds
SO.OFF_ROUTE_S = 45     -- the first leg of the current order is this long and the greedy route starts elsewhere: off route
SO.FIRST_LEGS = 5       -- from-player searches per call: the baseline's first block plus the nearest blocks that may go first

local ACCEPT = { A = true, a = true, ["!"] = true }
local OBJECTIVE = { C = true, K = true, l = true, U = true }
local TURNIN = { T = true, t = true }

local function qkey(step) return step.qid and step.qid[1] end

-- Precedence over `steps` in its baseline order: before[i][j] = true when i must stay ahead of j.
local function buildConstraints(steps)
    local n = #steps
    local before = {}
    for i = 1, n do before[i] = {} end
    for a, s in ipairs(steps) do
        if not s.route or s.sticky then
            for i = 1, n do
                if i < a then before[i][a] = true elseif i > a then before[a][i] = true end
            end
        end
    end
    local firstA = {}
    for i, s in ipairs(steps) do
        local q = qkey(s)
        if q and ACCEPT[s.action] then firstA[q] = firstA[q] or i end
    end
    for i, s in ipairs(steps) do
        local q = qkey(s)
        if q then
            local a = s.action
            if (OBJECTIVE[a] or TURNIN[a]) and firstA[q] and firstA[q] < i then before[firstA[q]][i] = true end
            if TURNIN[a] then
                for j = 1, i - 1 do
                    local s2 = steps[j]
                    if qkey(s2) == q and OBJECTIVE[s2.action] then before[j][i] = true end
                end
            end
            if s.pre then
                for _, pq in ipairs(s.pre) do
                    for j = 1, i - 1 do
                        local s2 = steps[j]
                        if TURNIN[s2.action] and qkey(s2) == pq then before[j][i] = true end
                    end
                end
            end
        end
    end
    return before
end

-- Costs kept between refreshes, keyed by the step tables themselves (no string keys in a hot path).
-- Router.TravelSeconds is hearth-free and stable; the graph's own path cache table is replaced on a rebuild, which
-- tells us to drop ours.  Costs from the player are kept until the player has moved a little.
local kept = { pair = {}, from = {}, guide = nil, speed = nil, tgCache = nil, px = nil, py = nil, pinst = nil }

local function dropKept()
    kept.pair, kept.from = {}, {}
    kept.px, kept.py, kept.pinst = nil, nil, nil
end

function SO.Reset()
    dropKept()
    kept.guide, kept.speed, kept.tgCache = nil, nil, nil
    SO.plan = nil
end

-- Read-only: the kept travel seconds a -> b, or nil when the planner has not priced that pair, or priced it before the
-- graph was rebuilt or the speed changed (its next refresh drops those).  Never searches: Core/BugReport.lua uses it
-- so that a report costs no path search for its upcoming list.
function SO.KeptCost(a, b)
    if not (a and b) or kept.tgCache ~= (NS.TravelGraph and NS.TravelGraph.pathCache) or kept.speed ~= U.TravelSpeed() then return nil end
    local ca = kept.pair[a]
    return ca and ca[b] or nil
end

local now = debugprofilestop or function() return 0 end

-- located: anywhere Router.StepWorld can point, which includes the zone fallback for a step with no |M| (the arrow goes
-- there too, so the plan has to pay for that trip).  A step with no place at all rides along with the block before it.
local function located(s) return s.zone ~= nil end

-- Collapse steps into blocks.  A block is { list of positions in `steps`, in order }.  Returns blocks and block-level
-- precedence.  A leading step with no location is its own block and is pinned first (nothing else can jump it).
local function makeBlocks(steps, before)
    local blocks, blockOf = {}, {}
    for i, s in ipairs(steps) do
        if located(s) or #blocks == 0 then
            blocks[#blocks + 1] = { i }
        else
            local b = blocks[#blocks]
            b[#b + 1] = i
        end
        blockOf[i] = #blocks
    end
    local nb = #blocks
    local bb = {}
    for a = 1, nb do bb[a] = {} end
    local n = #steps
    for i = 1, n do
        for j = 1, n do
            if before[i][j] then
                local a, b = blockOf[i], blockOf[j]
                if a ~= b then bb[a][b] = true end
            end
        end
    end
    if not located(steps[blocks[1][1]]) then
        for b = 2, nb do bb[1][b] = true end
    end
    return blocks, bb, blockOf
end

-- first/last located step of a block (nil for a leading unlocated block)
local function blockEnds(block, steps)
    local first, last
    for _, i in ipairs(block) do
        if located(steps[i]) then
            first = first or i
            last = i
        end
    end
    return first, last
end

-- Which blocks get a real from-player search.  Only a block with no predecessor can ever be first, and a from-player
-- search can be a full Dijkstra with the hearth (uncached), so keep the nearest few of those plus the baseline's first
-- block and the baked first block.  Every other block is simply not offered as the first stop.
local function firstLegs(steps, firstOf, bb, nb, baseFirst, router)
    local free = {}
    for v = 1, nb do
        local ok = true
        for u = 1, nb do if bb[u][v] then ok = false break end end
        if ok then free[#free + 1] = v end
    end
    local allowed = { [baseFirst] = true, [1] = true }
    if #free > SO.FIRST_LEGS then
        local _, _, _, pinst, pwx, pwy = U.PlayerPos()
        local dist = {}
        for _, v in ipairs(free) do
            local d = math.huge
            local s = firstOf[v] and steps[firstOf[v]]
            if not s then d = -1
            elseif pwx and router.StepWorld then
                local x, y, i = router.StepWorld(s)
                if x and i == pinst then d = (x - pwx) ^ 2 + (y - pwy) ^ 2 end
            end
            dist[v] = d
        end
        table.sort(free, function(a, b) if dist[a] ~= dist[b] then return dist[a] < dist[b] end return a < b end)
    end
    for k = 1, math.min(#free, SO.FIRST_LEGS) do allowed[free[k]] = true end
    return allowed
end

-- Fill the block-to-block cost table; returns nil when the budget ran out (the caller keeps its baseline)
local function buildMatrix(steps, blocks, after, router, deadline, bb, baseFirst)
    local nb = #blocks
    local E = nb + 1
    local firstOf, lastOf = {}, {}
    for b = 1, nb do firstOf[b], lastOf[b] = blockEnds(blocks[b], steps) end
    local allowedFirst = firstLegs(steps, firstOf, bb, nb, baseFirst, router)
    local afterStep = after and located(after) and after or nil
    local m = {}
    for u = 0, nb do m[u] = {} end
    local UNKNOWN = 600
    local spent = false
    local function over()
        if not spent and now() > deadline then spent = true end
        return spent
    end
    local pair, from = kept.pair, kept.from
    -- returns seconds, or nil when the budget ran out before this one could be computed
    local function pairCost(a, b)
        local ca = pair[a]
        if not ca then ca = {} pair[a] = ca end
        local v = ca[b]
        if v == nil then
            if over() then return nil end
            v = router.TravelSeconds(a, b)
            ca[b] = v or false
        end
        return v or UNKNOWN
    end
    local function fromCost(s)
        local v = from[s]
        if v == nil then
            if over() then return nil end
            v = router.TravelSecondsFromPlayer(s)
            from[s] = v or false
        end
        return v or UNKNOWN
    end
    for v = 1, nb do
        local fv = firstOf[v]
        if not allowedFirst[v] then
            m[0][v] = math.huge
        elseif fv then
            local c = fromCost(steps[fv])
            if c == nil then return nil end
            m[0][v] = c
        else
            m[0][v] = 0
        end
    end
    m[0][E] = 0
    for u = 1, nb do
        local lu = lastOf[u]
        local fromStep = lu and steps[lu]
        for v = 1, nb do
            if u ~= v then
                local fv = firstOf[v]
                local c
                if not fv then c = 0
                elseif not fromStep then c = 0     -- a leading step with no location: where it ends is unknown
                else
                    c = pairCost(fromStep, steps[fv])
                    if c == nil then return nil end
                end
                m[u][v] = c
            end
        end
        local afterCost = 0
        if afterStep and fromStep then
            local c = pairCost(fromStep, afterStep)
            if c == nil then return nil end
            afterCost = c
        end
        m[u][E] = afterCost
    end
    return m
end

-- Route cost over a block order (order[1..nb]); m[0] is the player, m[..][nb+1] the leg after the window
local function routeCost(m, order)
    local nb = #order
    local t = m[0][order[1]]
    for k = 2, nb do t = t + m[order[k - 1]][order[k]] end
    return t + m[order[nb]][nb + 1]
end

-- Quest log check: peak number of quests on the log along this block order (counting accepts minus turn-ins inside it)
local function logPeak(steps, blocks, order, start)
    local open, peak = start, start
    for _, b in ipairs(order) do
        for _, i in ipairs(blocks[b]) do
            local s = steps[i]
            if ACCEPT[s.action] then open = open + 1
            elseif TURNIN[s.action] then open = open - 1 end
            if open > peak then peak = open end
        end
    end
    return peak
end

-- Local search: best-improvement Or-opt (segments of 1-3 blocks) and 2-opt, precedence-safe.
local function improve(m, bb, start, deadline)
    local nb = #start
    local E = nb + 1
    local cur = {}
    for k = 1, nb do cur[k] = start[k] end
    cur[0] = 0
    cur[E] = E
    local rounds = 0
    while rounds < 8 do
        rounds = rounds + 1
        if now() > deadline then break end
        local bestDelta, bestKind, bestI, bestJ, bestG = -0.05, nil, nil, nil, nil
        for L = 1, 3 do
            for i = 1, nb - L + 1 do
                local j = i + L - 1
                local a, f, l, b = cur[i - 1], cur[i], cur[j], cur[j + 1]
                local remove = m[a][b] - m[a][f] - m[l][b]
                for g = 0, nb do
                    if g < i - 1 or g > j then
                        local p, q = cur[g], cur[g + 1]
                        local delta = remove + m[p][f] + m[l][q] - m[p][q]
                        if delta < bestDelta then
                            -- feasibility: nothing in the jumped range may be ordered against the segment
                            local ok = true
                            if g < i - 1 then
                                for k = g + 1, i - 1 do
                                    local e = cur[k]
                                    for x = i, j do if bb[e][cur[x]] then ok = false break end end
                                    if not ok then break end
                                end
                            else
                                for k = j + 1, g do
                                    local e = cur[k]
                                    for x = i, j do if bb[cur[x]][e] then ok = false break end end
                                    if not ok then break end
                                end
                            end
                            if ok then bestDelta, bestKind, bestI, bestJ, bestG = delta, "move", i, j, g end
                        end
                    end
                end
            end
        end
        for i = 1, nb - 1 do
            local pre = cur[i - 1]
            for j = i + 1, nb do
                local post = cur[j + 1]
                local delta = m[pre][cur[j]] + m[cur[i]][post] - m[pre][cur[i]] - m[cur[j]][post]
                for k = i, j - 1 do delta = delta + m[cur[k + 1]][cur[k]] - m[cur[k]][cur[k + 1]] end
                if delta < bestDelta then
                    local ok = true
                    for x = i, j do
                        for y = x + 1, j do
                            if bb[cur[x]][cur[y]] then ok = false break end
                        end
                        if not ok then break end
                    end
                    if ok then bestDelta, bestKind, bestI, bestJ, bestG = delta, "rev", i, j, nil end
                end
            end
        end
        if not bestKind then break end
        if bestKind == "move" then
            local seg = {}
            for k = bestI, bestJ do seg[#seg + 1] = cur[k] end
            local rest = {}
            for k = 1, nb do if k < bestI or k > bestJ then rest[#rest + 1] = cur[k] end end
            local insertAfter = bestG
            -- bestG is a gap index in the original array; shift it for the removed segment
            if bestG >= bestJ then insertAfter = bestG - (bestJ - bestI + 1) end
            local out, placed = {}, false
            for k = 0, #rest do
                if k >= 1 then out[#out + 1] = rest[k] end
                if k == insertAfter then
                    for _, s in ipairs(seg) do out[#out + 1] = s end
                    placed = true
                end
            end
            if not placed then for _, s in ipairs(seg) do out[#out + 1] = s end end
            for k = 1, nb do cur[k] = out[k] end
        else
            local i, j = bestI, bestJ
            while i < j do cur[i], cur[j] = cur[j], cur[i] i, j = i + 1, j - 1 end
        end
    end
    local o = {}
    for k = 1, nb do o[k] = cur[k] end
    return o
end

-- Greedy nearest feasible route from the player, over blocks.
local function greedy(m, bb, nb)
    local placed, order, cur = {}, {}, 0
    for _ = 1, nb do
        local best, bestC
        for v = 1, nb do
            if not placed[v] then
                local ready = true
                for u = 1, nb do if bb[u][v] and not placed[u] then ready = false break end end
                if ready then
                    local c = m[cur][v] + v * 0.01   -- ties go to the baseline order
                    if not bestC or c < bestC then best, bestC = v, c end
                end
            end
        end
        if not best then return nil end
        placed[best] = true
        order[#order + 1] = best
        cur = best
    end
    return order
end

local function sameOrder(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

-- Core: `steps` = window in baked order (precedence source); `base` = order the player is on, as block positions
-- (nil = the baked order itself).  Returns the chosen list of step tables and a small report.
local function solve(steps, router, baseBlocks, after, budget, logStart, logCap)
    local info = { partial = false, changed = false, baseCost = nil, bestCost = nil, offRoute = false }
    local n = #steps
    local before = buildConstraints(steps)
    local blocks, bb = makeBlocks(steps, before)
    local nb = #blocks
    local identity = {}
    for b = 1, nb do identity[b] = b end
    if nb < 2 then return steps, identity, info end
    -- a baseline from an earlier plan must still respect every precedence edge
    local base = identity
    if baseBlocks and #baseBlocks == nb then
        local pos = {}
        for k, b in ipairs(baseBlocks) do pos[b] = k end
        local ok = true
        for u = 1, nb do
            for v = 1, nb do
                if bb[u][v] and pos[u] > pos[v] then ok = false break end
            end
            if not ok then break end
        end
        if ok then base = baseBlocks end
    end
    local function expand(order)
        local out = {}
        for _, b in ipairs(order) do
            for _, i in ipairs(blocks[b]) do out[#out + 1] = steps[i] end
        end
        return out
    end
    local deadline = now() + (budget or math.huge)
    local m = buildMatrix(steps, blocks, after, router, deadline, bb, base[1])
    if not m then
        info.partial = true
        return expand(base), base, info
    end
    local baseCost = routeCost(m, base)
    info.baseCost = baseCost
    local bestOrder, bestCost = base, baseCost
    local function consider(o)
        if o then
            local c = routeCost(m, o)
            if c < bestCost - 0.01 then bestOrder, bestCost = o, c end
        end
    end
    consider(improve(m, bb, base, deadline))
    local gr = greedy(m, bb, nb)
    if gr then consider(improve(m, bb, gr, deadline)) end
    if base ~= identity then consider(improve(m, bb, identity, deadline)) consider(identity) end
    if gr and m[0][base[1]] >= SO.OFF_ROUTE_S and gr[1] ~= base[1] then info.offRoute = true end
    info.bestCost = bestCost
    local margin = math.max(SO.MIN_GAIN, baseCost * SO.GAIN_FRAC)
    if bestOrder ~= base and not sameOrder(bestOrder, base) and baseCost - bestCost >= margin then
        -- never let a repair push the quest log over the cap (or over what the baseline already needs)
        local start = logStart or 0
        local capNow = logCap or math.huge
        local basePeak = logPeak(steps, blocks, base, start)
        if logPeak(steps, blocks, bestOrder, start) <= math.max(capNow, basePeak) then
            info.changed = true
            return expand(bestOrder), bestOrder, info
        end
    end
    return expand(base), base, info
end

-- One-shot: the window `steps` in baseline order -> reordered list (or `steps` itself when nothing beats it by the
-- margin).  opts = { after = step following the window, budget = ms, logStart, logCap }.
function SO.Order(steps, router, opts)
    if #steps <= 2 then return steps end
    opts = opts or {}
    kept.from = {}
    local chosen, _, info = solve(steps, router, nil, opts.after, opts.budget, opts.logStart, opts.logCap)
    SO.last = info
    return chosen
end

-- Stateful: keep following the plan until something beats it by the margin.
-- head = the next steps in baked order (precedence source), after = the step following them.
function SO.Plan(head, router, opts)
    opts = opts or {}
    SO.needsMore = false
    if #head <= 2 then SO.plan = nil return head end
    local guide = head[1].guide
    local speed = U.TravelSpeed()
    local _, _, _, pinst, pwx, pwy = U.PlayerPos()
    local tg = NS.TravelGraph and NS.TravelGraph.pathCache
    if kept.guide ~= guide or kept.speed ~= speed or kept.tgCache ~= tg then
        dropKept()
        kept.guide, kept.speed, kept.tgCache = guide, speed, tg
        if SO.plan and SO.plan.guide ~= guide then SO.plan = nil end
    end
    -- Costs from the player live until the player has moved 40 yd (the walk-time error is then at most a few seconds).
    if not (kept.px and kept.pinst == pinst and pwx and math.abs(kept.px - pwx) + math.abs(kept.py - pwy) < 40) then
        kept.from = {}
        kept.px, kept.py, kept.pinst = pwx, pwy, pinst
    end
    -- the baseline: the current plan's steps that are still pending, in plan order; steps new to the window after them
    local baseBlocks
    local plan = SO.plan
    if plan and plan.guide == guide then
        local before = buildConstraints(head)
        local blocks, _, blockOf = makeBlocks(head, before)
        local posInHead = {}
        for i, s in ipairs(head) do posInHead[s] = i end
        local seen, order = {}, {}
        for _, s in ipairs(plan.steps) do
            local i = posInHead[s]
            if i then
                local b = blockOf[i]
                if not seen[b] then seen[b] = true order[#order + 1] = b end
            end
        end
        for b = 1, #blocks do
            if not seen[b] then order[#order + 1] = b end
        end
        baseBlocks = order
    end
    local chosen, _, info = solve(head, router, baseBlocks, opts.after, opts.budget, opts.logStart, opts.logCap)
    SO.last = info
    SO.needsMore = info.partial
    if not info.partial then
        local keep = {}
        for i, s in ipairs(chosen) do keep[i] = s end
        SO.plan = { guide = guide, steps = keep }
    end
    return chosen, info
end
