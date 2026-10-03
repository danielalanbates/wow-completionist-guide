-- CompletionRoute :: Routing/Loop.lua
-- Closed-circuit builder for farm routes: turn a cloud of gather nodes into the shortest
-- repeatable loop around a zone.  Nearest-neighbour seed + 2-opt + Or-opt improvement, all in
-- world yards so the distances mean something (zone coords are not square).
--
-- Copyright (c) 2026 Daniel Bates / Bates LLC.  All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 (see LICENSE); 10% revenue share for commercial use.
local ADDON, NS = ...
local U = NS.Util
local L = {}
NS.Loop = L

local sqrt, floor = math.sqrt, math.floor

local function d2(a, b) local dx, dy = a.wx - b.wx, a.wy - b.wy return dx * dx + dy * dy end
local function dist(a, b) return sqrt(d2(a, b)) end

-- Collapse nodes that are effectively the same spot (a respawn cluster) into one weighted point.
-- cell = grid size in yards.  Keeps the count (how often we harvested there) as the weight.
function L.Cluster(points, cell)
    cell = cell or 30
    local buckets, out = {}, {}
    for _, p in ipairs(points) do
        if p.wx and p.wy then
            local key = ("%d:%d:%d"):format(p.inst or 0, floor(p.wx / cell), floor(p.wy / cell))
            local b = buckets[key]
            if b then
                local w = (p.weight or 1)
                b.wx = (b.wx * b.weight + p.wx * w) / (b.weight + w)
                b.wy = (b.wy * b.weight + p.wy * w) / (b.weight + w)
                b.weight = b.weight + w
                if p.kind and not b.kinds[p.kind] then b.kinds[p.kind] = true b.kindList[#b.kindList + 1] = p.kind end
            else
                b = { wx = p.wx, wy = p.wy, inst = p.inst, map = p.map, x = p.x, y = p.y,
                      weight = p.weight or 1, kinds = {}, kindList = {},
                      -- keep what the caller hung on the point (guide step, note, patrol flag): the
                      -- circuit is written from these, and dropping them silently loses the guide's text
                      step = p.step, note = p.note, patrol = p.patrol, kind = p.kind }
                if p.kind then b.kinds[p.kind] = true b.kindList[1] = p.kind end
                buckets[key] = b
                out[#out + 1] = b
            end
        end
    end
    return out
end

-- Total length of a closed tour (yards)
function L.Length(tour)
    if #tour < 2 then return 0 end
    local n, total = #tour, 0
    for i = 1, n do total = total + dist(tour[i], tour[i % n + 1]) end
    return total
end

local function nearestNeighbour(points, startIdx)
    local n = #points
    local used, tour = {}, {}
    local cur = startIdx or 1
    used[cur] = true tour[1] = points[cur]
    for _ = 2, n do
        local best, bestd
        for i = 1, n do
            if not used[i] then
                local d = d2(points[cur], points[i])
                if not bestd or d < bestd then best, bestd = i, d end
            end
        end
        if not best then break end
        used[best] = true cur = best tour[#tour + 1] = points[best]
    end
    return tour
end

-- 2-opt: uncross edges.  budget caps the work so a 400-node zone cannot hitch the client.
local function twoOpt(tour, budget)
    local n = #tour
    if n < 4 then return tour end
    local improved, spent = true, 0
    while improved and spent < budget do
        improved = false
        for i = 1, n - 2 do
            local a, b = tour[i], tour[i + 1]
            for k = i + 2, n do
                if not (i == 1 and k == n) then
                    local c, e = tour[k], tour[k % n + 1]
                    local delta = (dist(a, c) + dist(b, e)) - (dist(a, b) + dist(c, e))
                    spent = spent + 1
                    if delta < -0.5 then
                        for x = 0, floor((k - i - 1) / 2) do
                            tour[i + 1 + x], tour[k - x] = tour[k - x], tour[i + 1 + x]
                        end
                        improved = true
                    end
                end
                if spent >= budget then break end
            end
            if spent >= budget then break end
        end
    end
    return tour
end

-- Or-opt: move a run of 1-3 nodes somewhere cheaper (2-opt alone leaves these behind).
local function orOpt(tour, budget)
    local n = #tour
    if n < 6 then return tour end
    local spent = 0
    for seg = 1, 3 do
        local i = 1
        while i + seg - 1 <= n and spent < budget do
            local prev = tour[(i - 2) % n + 1]
            local first, last = tour[i], tour[i + seg - 1]
            local after = tour[(i + seg - 1) % n + 1]
            local removed = dist(prev, first) + dist(last, after) - dist(prev, after)
            local bestGain, bestAt = 0.5, nil
            for j = 1, n do
                if j < i - 1 or j > i + seg - 1 then
                    local a = tour[j]
                    local b = tour[j % n + 1]
                    local added = dist(a, first) + dist(last, b) - dist(a, b)
                    spent = spent + 1
                    if removed - added > bestGain then bestGain, bestAt = removed - added, j end
                end
            end
            if bestAt then
                local run = {}
                for k = 0, seg - 1 do run[#run + 1] = tour[i + k] end
                for k = seg - 1, 0, -1 do table.remove(tour, i + k) end
                local at = bestAt
                if at > i then at = at - seg end
                for k = seg, 1, -1 do table.insert(tour, at + 1, run[k]) end
            end
            i = i + 1
        end
    end
    return tour
end

-- Build the loop.  points = { {wx,wy,inst,map,x,y,kind,weight}, ... }
-- opts: cell (cluster yards), budget (improvement steps), minWeight (drop one-off sightings)
function L.Build(points, opts)
    opts = opts or {}
    local pts = {}
    for _, p in ipairs(points or {}) do
        if p.wx and p.wy and (p.weight or 1) >= (opts.minWeight or 1) then pts[#pts + 1] = p end
    end
    if #pts == 0 then return nil, "no located nodes" end
    pts = L.Cluster(pts, opts.cell or 30)
    if #pts == 1 then return pts, 0 end
    local tour = nearestNeighbour(pts, 1)
    local budget = opts.budget or 40000
    tour = twoOpt(tour, budget)
    tour = orOpt(tour, floor(budget / 4))
    tour = twoOpt(tour, floor(budget / 2))
    return tour, L.Length(tour)
end

-- Render a built tour as guide text (one G step per waypoint).
-- zoneName/mapID label the steps; kinds become the note ("Herbs: Peacebloom, Silverleaf").
function L.ToGuideText(tour, mapID, zoneName, opts)
    opts = opts or {}
    local lines = {}
    for i, p in ipairs(tour) do
        local x, y = p.x, p.y
        if (not x or not y) and U.ZoneFromWorld then x, y = U.ZoneFromWorld(p.wx, p.wy, p.inst, mapID) end
        if x and y then
            local note = opts.note
            if p.kindList and #p.kindList > 0 then note = table.concat(p.kindList, ", ") end
            lines[#lines + 1] = ("G %s|M|%.2f,%.2f|Z|%d; %s|RAD|%d|%s"):format(
                opts.label or ("Node " .. i), x * 100, y * 100, mapID, zoneName or U.MapName(mapID),
                opts.radius or 40, note and ("N|" .. note .. "|") or "")
        end
    end
    return table.concat(lines, "\n")
end

return L
