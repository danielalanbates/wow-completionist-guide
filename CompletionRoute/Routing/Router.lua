-- CompletionRoute :: Routing/Router.lua
-- Facade between guide steps and the travel graph.  Provides:
--   Router.OrderSteps(steps)   -> reordered steps (optimizer)
--   Router.CurrentPath()       -> path from player to the current step (legs)
--   Router.Recommendation()    -> what the arrow should do right now (walk / hearth / item / taxi / transit)
local ADDON, NS = ...
local U, HBD, TG = NS.Util, NS.HBD, NS.TravelGraph
local R = {}
NS.Router = R

-- Many imported guide lines carry no |M| coordinates at all. Rather than showing nothing, ask the
-- GAME where the quest objective is - that is exactly what the built-in quest tracker points at.
-- Not cached on the step: the answer moves as objectives complete.
function R.QuestWorld(step)
    if not step or not step.qid or not C_QuestLog then return nil end
    local map = U.PlayerPos()
    for _, q in ipairs(step.qid) do
        if U.IsOnQuest(q) then
            local uiMapID, qx, qy
            if C_QuestLog.GetNextWaypoint then
                local ok, a, b, c = pcall(C_QuestLog.GetNextWaypoint, q)
                if ok and a and b and c then uiMapID, qx, qy = a, b, c end
            end
            if not uiMapID and map and C_QuestLog.GetNextWaypointForMap then
                local ok, a, b = pcall(C_QuestLog.GetNextWaypointForMap, q, map)
                if ok and a and b then uiMapID, qx, qy = map, a, b end
            end
            if uiMapID and qx and qy and (qx ~= 0 or qy ~= 0) then
                local wx, wy, inst = HBD:GetWorldCoordinatesFromZone(qx, qy, uiMapID)
                if wx then return wx, wy, inst, uiMapID, qx, qy end
            end
        end
    end
    return nil
end

-- world position of a step (first coordinate). returns wx, wy, inst
-- step._locSource records how we got it, so the UI can be honest about a fuzzy answer.
-- If `step` sits inside an instance map and the player is not in that instance, return the learned
-- (or journal-supplied) entrance in the outdoor world.  nil = no substitution.
function R.EntranceFor(step)
    local I = NS.Instances
    if not (I and step and step.zone and I.IsInstanceMap(step.zone)) then return nil end
    -- Inside any instance, the real in-instance coordinates are the useful ones (HBD instance ids are
    -- not a reliable "am I in this dungeon" test - several outdoor maps share instance 0 with them).
    if IsInInstance and IsInInstance() then return nil end
    local ex, ey, ei, rec = I.Entrance(step.zone)
    if not ex then return nil end
    step._entrance = rec
    step._locSource = "entrance"
    return ex, ey, ei
end

function R.StepWorld(step)
    if not step then return nil end
    if step.coords and step.zone then
        if step._wx and step._winst then return step._wx, step._wy, step._winst end
        local c = step.coords[1]
        local wx, wy, inst = HBD:GetWorldCoordinatesFromZone(c.x, c.y, step.zone)
        if wx then
            -- Target inside a dungeon/raid we are not standing in? Route to the DOOR (Core/Instances.lua)
            -- instead of reporting "no route": the player's job is to get there, the boss is inside.
            local ex, ey, ei = R.EntranceFor(step)
            if ex then return ex, ey, ei end
            step._wx, step._wy, step._winst, step._locSource = wx, wy, inst, "guide"
            return wx, wy, inst
        end
    end
    -- no coordinates in the guide: fall back to the live quest objective
    local qx, qy, qi = R.QuestWorld(step)
    if qx then step._locSource = "quest" return qx, qy, qi end
    if step.zone then
        if step._zwx then step._locSource = "zone" return step._zwx, step._zwy, step._zwinst end
        local wx, wy, inst = HBD:GetWorldCoordinatesFromZone(0.5, 0.5, step.zone)
        if wx then
            step._zwx, step._zwy, step._zwinst, step._locSource = wx, wy, inst, "zone"
            return wx, wy, inst
        end
    end
    step._locSource = nil
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

-- ---------------------------------------------------------------------------
-- Death: nothing in the guide is doable as a corpse.  The Hearthstone, quest items and vendors are
-- all unusable while dead, so the pointer stops advertising them and points at the body instead.
-- ---------------------------------------------------------------------------
function R.IsDead() return UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") or false end

-- Where is the corpse, in world coordinates?  C_DeathInfo answers per-map and only for the map the
-- corpse is actually on, so ask the current map first and then its parent (the continent).
function R.CorpseWorld()
    if not (C_DeathInfo and C_DeathInfo.GetCorpseMapPosition) then return nil end
    local map = U.PlayerPos()
    if not map then return nil end
    local tries = { map }
    local info = C_Map.GetMapInfo(map)
    if info and info.parentMapID and info.parentMapID > 0 then tries[#tries + 1] = info.parentMapID end
    for _, m in ipairs(tries) do
        local ok, pos = pcall(C_DeathInfo.GetCorpseMapPosition, m)
        if ok and pos then
            local cx, cy
            if pos.GetXY then cx, cy = pos:GetXY() else cx, cy = pos.x, pos.y end
            if cx and cy and (cx ~= 0 or cy ~= 0) then
                local wx, wy, inst = HBD:GetWorldCoordinatesFromZone(cx, cy, m)
                if wx then return wx, wy, inst, m, cx, cy end
            end
        end
    end
    return nil
end

function R.CorpseRecommendation()
    local rec = { mode = "corpse", dead = true }
    if UnitIsGhost and not UnitIsGhost("player") then
        rec.mode = "release"
        rec.text = "You are dead - release your spirit"
        rec.why = "the Hearthstone, quest items and turn-ins cannot be used while dead"
        return rec
    end
    rec.text = "Run to your corpse"
    local cwx, cwy, cinst = R.CorpseWorld()
    if not cwx then
        rec.why = "the client will not say where your corpse is - follow the minimap corpse marker"
        return rec
    end
    rec.wx, rec.wy, rec.inst = cwx, cwy, cinst
    local _, _, _, inst, wx, wy = U.PlayerPos()
    if wx and inst == cinst then
        rec.dist = math.sqrt((wx - cwx) ^ 2 + (wy - cwy) ^ 2)
        -- ghosts move faster than the living; do not promise a walking ETA off the live speed
        rec.eta = rec.dist / ((NS.db.profile.routing.runSpeed or 7) * 1.5)
    end
    local delay = GetCorpseRecoveryDelay and GetCorpseRecoveryDelay() or 0
    if delay and delay > 0 then rec.why = ("resurrection sickness timer: %ds"):format(delay) end
    return rec
end

-- What should the arrow show?
-- returns rec = { mode, wx, wy, inst, text, item, spell, eta, dist, step }
function R.Recommendation()
    -- dead first: this overrides the guide entirely, and works even with no guide loaded
    if R.IsDead() then return R.CorpseRecommendation() end
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
    -- Still nothing to aim at? Borrow the location of the nearest upcoming step that does have
    -- one, so the player is at least walking the right way instead of staring at a dead arrow.
    if not target then
        for _, s2 in ipairs(NS.Progress.Upcoming(8)) do
            if s2 ~= step then
                local bx, by, bi = R.StepWorld(s2)
                if bx then
                    rec.borrowedFrom = s2
                    target = { wx = bx, wy = by, inst = bi }
                    if wx then
                        local ok, p2 = pcall(TG.FindPath, wx, wy, inst, bx, by, bi, {})
                        path = ok and p2 or nil
                    end
                    break
                end
            end
        end
    end
    if not target then rec.mode = "none" rec.why = "no coordinates, no quest objective and no zone on this step" return rec end
    rec.locSource = rec.borrowedFrom and "borrowed" or step._locSource
    rec.wx, rec.wy, rec.inst = target.wx, target.wy, target.inst
    if rec.borrowedFrom then
        rec.text = "Toward: " .. (rec.borrowedFrom.title or "the next known spot")
    end
    if not path or not path.legs[1] then
        rec.mode = "walk"
        if not rec.borrowedFrom then rec.text = "Go to " .. step.title end
        return rec
    end
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
        -- following a road: aim at the next road vertex that is still ahead of us, not the far end
        if leg.via and wx then
            for _, v in ipairs(leg.via) do
                if math.sqrt((v.wx - wx) ^ 2 + (v.wy - wy) ^ 2) > 25 then rec.wx, rec.wy, rec.via = v.wx, v.wy, true break end
            end
        end
        local nxt = path.legs[2]
        if nxt then
            if nxt.mode == "taxi" then rec.text = "Flight master: " .. (leg.to.name or "") .. " -> fly to " .. (nxt.to.name or "") .. (nxt.discover and " (new path)" or "")
            else rec.text = nxt.title or ("Go to " .. (leg.to.name or "transport")) end
        elseif not rec.borrowedFrom then rec.text = step.title end
        rec.dist = leg.dist
    elseif leg.mode == "taxi" then
        rec.mode = "taxi"; rec.text = "Fly to " .. (leg.to.name or "?") .. (leg.discover and " (new flight path)" or "")
        rec.wx, rec.wy, rec.inst = leg.from.wx, leg.from.wy, leg.from.inst
    else
        rec.mode = "transit"; rec.text = leg.title or leg.mode
        rec.wx, rec.wy, rec.inst = leg.from.wx, leg.from.wy, leg.from.inst
    end
    return rec
end
