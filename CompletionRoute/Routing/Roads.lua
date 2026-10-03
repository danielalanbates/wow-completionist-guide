-- CompletionRoute :: Routing/Roads.lua
-- Passive road recorder: while you travel on the ground, the path you actually take is stored as a
-- decimated polyline (one point per 25 yd) in CompletionRouteDB.roadTrace[instance][]. Those traces
-- feed straight back into the travel graph as "road" edges (TravelGraph.BuildRoads), so the arrow
-- learns the real way through a zone - around cliffs, over the right bridge, through the right gate -
-- from play, with no hand authoring. tools/roads_from_trace.py turns the SavedVariables file into a
-- Data/Roads_*.lua entry that can be shared with everyone.
local ADDON, NS = ...
local U = NS.Util
local R = {}
NS.Roads = R

local STEP = 25          -- yards between stored points
local BREAK = 200        -- a jump bigger than this starts a new segment (hearth, portal, loading screen)
local MAX_POINTS = 40000 -- SavedVariables budget (~1 MB); oldest segments are dropped first
local MIN_SEG = 4        -- segments shorter than this many points are discarded

local function store()
    local g = NS.db.global
    g.roadTrace = g.roadTrace or {}
    return g.roadTrace
end
local function cfg() return NS.db and NS.db.profile.routing or {} end

local seg, segInst, lastX, lastY, total = nil, nil, nil, nil, nil
local function countPoints()
    local n = 0
    for _, segs in pairs(store()) do for _, s in ipairs(segs) do n = n + #s end end
    return n
end
local function trimBudget()
    total = total or countPoints()
    while total > MAX_POINTS do
        local oldestInst, oldest
        for inst, segs in pairs(store()) do if segs[1] then oldestInst = inst oldest = segs[1] break end end
        if not oldest then return end
        table.remove(store()[oldestInst], 1)
        total = total - #oldest
    end
end
local function endSegment()
    if seg and #seg >= MIN_SEG then
        local segs = store()
        segs[segInst] = segs[segInst] or {}
        segs[segInst][#segs[segInst] + 1] = seg
        total = (total or countPoints()) + #seg
        trimBudget()
        R.dirty = true
    end
    seg, segInst, lastX, lastY = nil, nil, nil, nil
end

local function onGround()
    if UnitOnTaxi and UnitOnTaxi("player") then return false end
    if IsFlying and IsFlying() then return false end
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return false end
    return true
end

local acc = 0
local function tick(_, elapsed)
    acc = acc + elapsed
    if acc < 0.5 then return end
    acc = 0
    if cfg().recordRoads == false or not NS.db then return end
    if not onGround() then endSegment() return end
    local map, x, y, inst, wx, wy = U.PlayerPos()
    if not wx then endSegment() return end
    -- skip indoor / instance maps: nothing useful to route through
    if seg and inst ~= segInst then endSegment() end
    if not seg then
        seg, segInst, lastX, lastY = { { math.floor(wx + 0.5), math.floor(wy + 0.5) } }, inst, wx, wy
        return
    end
    local d = math.sqrt((wx - lastX) ^ 2 + (wy - lastY) ^ 2)
    if d >= BREAK then endSegment() return end
    if d >= STEP then
        seg[#seg + 1] = { math.floor(wx + 0.5), math.floor(wy + 0.5) }
        lastX, lastY = wx, wy
    end
end

-- entries for TravelGraph.AddRoadEntries (world-coordinate form)
function R.TraceEntries()
    local out = {}
    for inst, segs in pairs(store()) do
        for i, s in ipairs(segs) do out[#out + 1] = { inst = inst, name = "your path", w = s } end
    end
    return out
end

function R.Stats()
    local segs, pts, insts = 0, 0, 0
    for _, list in pairs(store()) do insts = insts + 1 for _, s in ipairs(list) do segs = segs + 1 pts = pts + #s end end
    return segs, pts, insts
end

function R.Command(rest)
    rest = (rest or ""):lower()
    if rest == "clear" then
        NS.db.global.roadTrace = {} total = 0 seg = nil
        NS.TravelGraph.RebuildRoads() NS.Router.Invalidate()
        NS:Print("Recorded roads cleared.")
    elseif rest == "rebuild" then
        endSegment() NS.TravelGraph.RebuildRoads() NS.Router.Invalidate()
        NS:Print(("Roads rebuilt: %d vertices in the graph."):format(NS.TravelGraph.roadCount or 0))
    elseif rest == "off" then cfg().recordRoads = false NS:Print("Road recording off.")
    elseif rest == "on" then cfg().recordRoads = true NS:Print("Road recording on.")
    else
        local segs, pts = R.Stats()
        NS:Print(("Roads: recording %s. %d recorded segments / %d points on this account; %d road vertices in the graph (authored + recorded)."):format(
            cfg().recordRoads == false and "OFF" or "on", segs, pts, NS.TravelGraph.roadCount or 0))
        NS:Print("  /cr road rebuild | clear | on | off.  Share: python3 tools/roads_from_trace.py <SavedVariables/CompletionRoute.lua>")
    end
end

-- fold new traces into the live graph every few minutes (cheap: a few hundred vertices)
local function periodic()
    if R.dirty and not (InCombatLockdown and InCombatLockdown()) then
        R.dirty = false
        pcall(NS.TravelGraph.RebuildRoads)
        NS.Router.Invalidate()
    end
    NS:After(180, periodic)
end

NS:On("PLAYER_READY", function()
    local f = CreateFrame("Frame")
    f:SetScript("OnUpdate", tick)
    R.frame = f
    NS:After(180, periodic)
end)
NS:RegisterEvent("PLAYER_LOGOUT", function() endSegment() end)
NS:RegisterEvent("PLAYER_ENTERING_WORLD", function() endSegment() end)
