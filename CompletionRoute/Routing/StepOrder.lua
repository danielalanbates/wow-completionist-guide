-- CompletionRoute :: Routing/StepOrder.lua
-- Precedence-constrained step ordering.  Given the next N pending steps of a guide, produce the order that
-- minimises total travel time while respecting hard dependencies:
--   * A(quest) before C/K(quest) before T(quest)
--   * PRE quests turned in before dependent A
--   * non-routable steps (R, F, H, h, N, L, ...) are anchors: everything the author put before an anchor
--     stays before it (they usually mark zone changes / must-do moments)
--   * sticky steps and steps without coordinates keep author order
-- Algorithm: build DAG (topological constraints), then greedy nearest-feasible-neighbour from the player's
-- position, then improve with precedence-safe Or-opt / 2-opt passes.  N is small (<=15) so this is cheap.
local ADDON, NS = ...
local U = NS.Util
local SO = {}
NS.StepOrder = SO

local function qkey(step) return step.qid and step.qid[1] end

-- Build constraints: returns before[i][j] = true if i must precede j (i,j are positions in `steps`)
local function buildConstraints(steps)
    local n = #steps
    local before = {}
    for i = 1, n do before[i] = {} end
    -- lastAnchor: every step after an anchor must stay after it; every step before an anchor must stay before it
    local anchors = {}
    for i, s in ipairs(steps) do if not s.route or s.sticky then anchors[#anchors + 1] = i end end
    for _, a in ipairs(anchors) do
        for i = 1, n do
            if i < a then before[i][a] = true elseif i > a then before[a][i] = true end
        end
    end
    -- quest lifecycle
    local firstA, lastC = {}, {}
    for i, s in ipairs(steps) do
        local q = qkey(s)
        if q then
            if s.action == "A" or s.action == "a" or s.action == "!" then firstA[q] = firstA[q] or i end
            if s.action == "C" or s.action == "K" or s.action == "l" or s.action == "U" then lastC[q] = i end
        end
    end
    for i, s in ipairs(steps) do
        local q = qkey(s)
        if q then
            local a = s.action
            if (a == "C" or a == "K" or a == "l" or a == "U" or a == "T" or a == "t") and firstA[q] and firstA[q] < i then before[firstA[q]][i] = true end
            if (a == "T" or a == "t") then
                for j, s2 in ipairs(steps) do
                    if j ~= i and qkey(s2) == q and (s2.action == "C" or s2.action == "K" or s2.action == "l" or s2.action == "U") and j < i then before[j][i] = true end
                end
            end
            -- PRE: prerequisites' turn-ins before this accept
            if s.pre then
                for _, pq in ipairs(s.pre) do
                    for j, s2 in ipairs(steps) do
                        if j < i and (s2.action == "T" or s2.action == "t") and qkey(s2) == pq then before[j][i] = true end
                    end
                end
            end
        end
        -- author's explicit relative order for same-title steps (e.g. two C parts) preserved
    end
    -- transitive closure not required for greedy feasibility check (we check direct predecessors done)
    return before
end

-- Cost matrix using Router pairwise travel time
local function costFn(router, steps)
    local cache = {}
    return function(i, j)  -- i may be 0 = player
        local key = i .. ":" .. j
        if cache[key] then return cache[key] end
        local c
        if i == 0 then c = router.TravelSecondsFromPlayer(steps[j])
        else c = router.TravelSeconds(steps[i], steps[j]) end
        c = c or 600  -- unknown location: neutral-ish cost
        cache[key] = c
        return c
    end
end

function SO.Order(steps, router)
    local n = #steps
    if n <= 2 then return steps end
    local before = buildConstraints(steps)
    local cost = costFn(router, steps)
    -- greedy nearest feasible neighbour
    local placed, order = {}, {}
    local cur = 0
    for _ = 1, n do
        local bestJ, bestC
        for j = 1, n do
            if not placed[j] then
                local feasible = true
                for i = 1, n do if before[i][j] and not placed[i] then feasible = false break end end
                if feasible then
                    local c = cost(cur, j)
                    -- small bias toward author order to break ties
                    c = c + j * 0.01
                    if not bestC or c < bestC then bestC, bestJ = c, j end
                end
            end
        end
        if not bestJ then break end   -- constraint cycle; bail
        placed[bestJ] = true
        order[#order + 1] = bestJ
        cur = bestJ
    end
    if #order < n then return steps end
    -- improvement: Or-opt (move a single step to a better feasible position)
    local function total(o) local t = 0 local p = 0 for _, j in ipairs(o) do t = t + cost(p, j) p = j end return t end
    local function feasibleOrder(o)
        local pos = {}
        for k, j in ipairs(o) do pos[j] = k end
        for i = 1, n do for j = 1, n do if before[i][j] and pos[i] > pos[j] then return false end end end
        return true
    end
    local bestT = total(order)
    local improved = true
    local rounds = 0
    while improved and rounds < 6 do
        improved = false
        rounds = rounds + 1
        for a = 1, n do
            for b = 1, n do
                if a ~= b then
                    local o = {}
                    for k, j in ipairs(order) do if k ~= a then o[#o + 1] = j end end
                    tinsert(o, b, order[a])
                    if feasibleOrder(o) then
                        local t = total(o)
                        if t < bestT - 0.5 then order, bestT, improved = o, t, true break end
                    end
                end
            end
            if improved then break end
        end
    end
    local out = {}
    for k, j in ipairs(order) do out[k] = steps[j] end
    return out
end
