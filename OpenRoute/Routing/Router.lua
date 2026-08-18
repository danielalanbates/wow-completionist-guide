-- OpenRoute :: Routing/Router.lua
-- Facade between guide steps and the travel graph.  Provides:
--   Router.OrderSteps(steps)   -> reordered steps (optimizer)
--   Router.CurrentPath()       -> path from player to the current step (legs)
--   Router.Recommendation()    -> what the arrow should do right now (walk / hearth / item / taxi / transit)
local ADDON, NS = ...
local U, HBD, TG = NS.Util, NS.HBD, NS.TravelGraph
local R = {}
NS.Router = R

-- world position of a step (first coordinate). returns wx, wy, inst
function R.StepWorld(step)
    if not step then return nil end
    if step._wx and step._winst then return step._wx, step._wy, step._winst end
    if step.coords and step.zone then
        local c = step.coords[1]
        local wx, wy, inst = HBD:GetWorldCoordinatesFromZone(c.x, c.y, step.zone)
        if wx then step._wx, step._wy, step._winst = wx, wy, inst return wx, wy, inst end
    elseif step.zone and not step.coords then
        -- zone-only step: zone centre
        local wx, wy, inst = HBD:GetWorldCoordinatesFromZone(0.5, 0.5, step.zone)
        if wx then step._wx, step._wy, step._winst = wx, wy, inst return wx, wy, inst end
    end
    return nil
end

-- Nearest coordinate of a multi-coord step to the player
function R.NearestCoord(step)
    if not step or not step.coords or not step.zone then return nil end
    local map, x, y, inst, pwx, pwy = U.PlayerPos()
    local best, bd
    for _, c in ipairs(step.coords) do
        local wx, wy, wi = HBD:GetWorldCoordinatesFromZone(c.x, c.y, step.zone)
        if wx then
            local d = (wi == inst and pwx) and math.sqrt((wx - pwx) ^ 2 + (wy - pwy) ^ 2) or 1e9
            if not bd or d < bd then bd, best = d, { wx = wx, wy = wy, inst = wi, x = c.x, y = c.y } end
        end
    end
    return best, bd
end

local WALK_ONLY_BELOW = 700  -- yards: below this, never bother with the full graph

-- pairwise: seconds between two steps (no hearth — hearth is a one-shot resource)
function R.TravelSeconds(a, b)
    local ax, ay, ai = R.StepWorld(a)
    local bx, by, bi = R.StepWorld(b)
    if not ax or not bx then return nil end
    local speed = U.TravelSpeed()
    if ai == bi then
        local d = math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
        if d < WALK_ONLY_BELOW then return d * (NS.db.profile.routing.terrainFactor or 1.25) / speed end
    end
    local p = TG.FindPath(ax, ay, ai, bx, by, bi, { hearth = false, speed = speed })
    return p and p.cost or nil
end
function R.TravelSecondsFromPlayer(b)
    local map, x, y, inst, wx, wy = U.PlayerPos()
    local bx, by, bi = R.StepWorld(b)
    if not wx or not bx then return nil end
    local speed = U.TravelSpeed()
    if inst == bi then
        local d = math.sqrt((wx - bx) ^ 2 + (wy - by) ^ 2)
        if d < WALK_ONLY_BELOW then return d * (NS.db.profile.routing.terrainFactor or 1.25) / speed end
    end
    local p = TG.FindPath(wx, wy, inst, bx, by, bi, { speed = speed })
    return p and p.cost or nil
end

-- Reorder the upcoming window.  Only steps with a location participate; the rest are anchors.
function R.OrderSteps(steps)
    if not steps or #steps < 3 or not NS.StepOrder then return steps end
    local window = math.min(#steps, NS.db.profile.routing.window or 10)
    local head = {}
    for i = 1, window do head[i] = steps[i] end
    local ok, ordered = pcall(NS.StepOrder.Order, head, R)
    if not ok then NS:Debug("StepOrder error: " .. tostring(ordered)) return steps end
    local out = {}
    for i = 1, #ordered do out[i] = ordered[i] end
    for i = window + 1, #steps do out[#out + 1] = steps[i] end
    return out
end

-- ---------------------------------------------------------------------------
-- Current path to the active step (cached, refreshed when player moves)
-- ---------------------------------------------------------------------------
local cache = { step = nil, path = nil, at = 0, wx = nil, wy = nil }
function R.CurrentPath(force)
    local step = NS.Progress.current
    if not step then cache.path = nil return nil end
    local map, x, y, inst, wx, wy = U.PlayerPos()
    if not wx then return cache.path end
    local target = R.NearestCoord(step)
    if not target then
        local tx, ty, ti = R.StepWorld(step)
        if not tx then cache.path = nil return nil end
        target = { wx = tx, wy = ty, inst = ti }
    end
    local now = GetTime()
    local moved = (not cache.wx) or math.abs(cache.wx - wx) + math.abs(cache.wy - wy) > 40
    if not force and cache.step == step and cache.path and (now - cache.at < 3 or not moved) and (now - cache.at < 20) then
        return cache.path, target
    end
    local ok, path = pcall(TG.FindPath, wx, wy, inst, target.wx, target.wy, target.inst, {})
    if not ok then NS:Debug("FindPath error: " .. tostring(path)) path = nil end
    cache.step, cache.path, cache.at, cache.wx, cache.wy = step, path, now, wx, wy
    return path, target
end
function R.Invalidate() cache.step = nil cache.path = nil end
NS:On("STEP_CHANGED", R.Invalidate)

-- What should the arrow show?
-- returns rec = { mode, wx, wy, inst, text, item, spell, eta, dist, step }
function R.Recommendation()
    local step = NS.Progress.current
    if not step then return nil end
    local rec = { step = step, mode = "none", text = step.title }
    local map, x, y, inst, wx, wy = U.PlayerPos()
    local path, target = R.CurrentPath()
    -- distance to target
    local dist
    if target and wx and target.inst == inst then dist = math.sqrt((wx - target.wx) ^ 2 + (wy - target.wy) ^ 2) end
    rec.dist = dist
    -- 1) item use: step wants an item and we're there (or step has no location)
    if step.item and U.HasItem(step.item) and (not target or (dist and dist < 40)) then
        rec.mode = "item"; rec.item = step.item; rec.text = "Use " .. U.ItemName(step.item)
        if target then rec.wx, rec.wy, rec.inst = target.wx, target.wy, target.inst end
        return rec
    end
    -- 2) hearth step itself
    if step.action == "H" then
        local ready, cd, kind, id = U.HearthReady()
        rec.mode = "hearth"; rec.item = NS.HEARTH_ITEM; rec.text = ready and "Use your Hearthstone" or ("Hearthstone ready in " .. U.FmtTime(cd))
        return rec
    end
    if not target then rec.mode = "none" return rec end
    rec.wx, rec.wy, rec.inst = target.wx, target.wy, target.inst
    if not path or not path.legs[1] then rec.mode = "walk" rec.text = "Go to " .. step.title return rec end
    rec.eta = path.cost
    local leg = path.legs[1]
    if leg.mode == "hearth" then
        rec.mode = "hearth"
        rec.item = leg.data and leg.data.kind == "item" and leg.data.id or nil
        rec.spell = leg.data and leg.data.kind == "spell" and leg.data.id or nil
        rec.text = leg.title .. " (saves time)"
        rec.wx, rec.wy, rec.inst = leg.to.wx, leg.to.wy, leg.to.inst
    elseif leg.mode == "walk" then
        rec.mode = "walk"
        rec.wx, rec.wy, rec.inst = leg.to.wx, leg.to.wy, leg.to.inst
        local nxt = path.legs[2]
        if nxt then
            if nxt.mode == "taxi" then rec.text = "Flight master: " .. (leg.to.name or "") .. " -> fly to " .. (nxt.to.name or "")
            else rec.text = nxt.title or ("Go to " .. (leg.to.name or "transport")) end
        else rec.text = step.title end
        rec.dist = leg.dist
    elseif leg.mode == "taxi" then
        rec.mode = "taxi"; rec.text = "Fly to " .. (leg.to.name or "?")
        rec.wx, rec.wy, rec.inst = leg.from.wx, leg.from.wy, leg.from.inst
    else
        rec.mode = "transit"; rec.text = leg.title or leg.mode
        rec.wx, rec.wy, rec.inst = leg.from.wx, leg.from.wy, leg.from.inst
    end
    return rec
end
