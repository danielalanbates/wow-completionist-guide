-- CompletionRoute :: tools/cm_offline.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- The offline character of the cost model (CompletionRoute/Routing/CostModel.lua), shared by tools/cost_matrix.lua,
-- tools/vplayer.lua, tools/test_cost_parity.lua and tools/cost_holdout.lua so the bake and the virtual player price a
-- leg the same way:
--   * travel speed and flying from the planning level of the step a leg leaves from (CostModel.PlanTravel), installed
--     over U.TravelSpeed / U.CanFly (the client's live speed is never used offline);
--   * the offline flight-path rule (CostModel.OFFLINE_TAXI, or --taxi): "faction", or "band" (flight masters in zones at
--     or below the planning level), installed over TravelGraph.TaxiPolicy / TaxiUsable;
--   * where a guide starts: its zone's centre (CostModel.StartLevel for the level).
-- Usage: local OFF = dofile("tools/cm_offline.lua"); local ctl = OFF.Install(NS, MAPS, { taxi = "faction" })
--        ctl.SetLevel(lvl) before each leg; ctl.policy; OFF.StartPoint(NS, g, steps) -> map, wx, wy, inst
local OFF = {}

-- the zone map a world point lies in (offline map rectangles, tools/maps_<flavor>.lua): the smallest zone-type map
local function zoneAt(MAPS, inst, wx, wy)
    local best, area
    for id, d in pairs(MAPS) do
        if d[2] == inst and d[3] and (d[8] or 3) == 3 then
            local y, x = (d[3] - wx) / d[6], (d[4] - wy) / d[5]
            if x >= 0 and x <= 1 and y >= 0 and y <= 1 then
                local a = d[5] * d[6]
                if not area or a < area then best, area = id, a end
            end
        end
    end
    return best
end
OFF.ZoneAt = zoneAt

-- taxiID -> the lowest minlevel of the wiki guides for the zone the flight master stands in (nil = no guide: allowed)
function OFF.TaxiNodeLevels(NS, MAPS)
    local G = NS.Guide
    local zoneLevel = {}
    for _, id in ipairs(G.list) do
        local g = G.registry[id]
        if id:sub(1, 5) == "wiki:" and g.zone and tonumber(g.minlevel) then
            local z, l = tonumber(g.zone), tonumber(g.minlevel)
            if z and (not zoneLevel[z] or l < zoneLevel[z]) then zoneLevel[z] = l end
        end
    end
    local out = {}
    local taxi = NS.TaxiData and (NS.TaxiData[NS.dataFlavor or NS.flavor] or NS.TaxiData[NS.flavor])
    for id, n in pairs(taxi and taxi.nodes or {}) do
        local z = zoneAt(MAPS, n[2], n[3], n[4])
        out[id] = z and zoneLevel[z] or nil
    end
    return out
end

-- Install the offline character.  opts.taxi = "faction" | "band" | "known" (vplayer --taxi learn: the client's rule)
function OFF.Install(NS, MAPS, opts)
    opts = opts or {}
    local CM, U, TG = NS.CostModel, NS.Util, NS.TravelGraph
    local ctl = { level = 1, policy = opts.taxi or CM.OFFLINE_TAXI }
    function ctl.SetLevel(l) ctl.level = math.max(1, math.floor(l or 1)) end
    U.TravelSpeed = function() return (CM.PlanTravel(ctl.level)) end
    U.CanFly = function() local _, fly = CM.PlanTravel(ctl.level) return fly end
    local r = NS.db.profile.routing
    r.hearth, r.teleports = false, false          -- one-shot legs from where the player stands: never offline
    if ctl.policy == "known" then
        r.taxiPolicy = "known"
    else
        r.taxiPolicy = "faction"
        if ctl.policy == "band" then
            local levels = OFF.TaxiNodeLevels(NS, MAPS)
            ctl.nodeLevels = levels
            -- the path cache keys on the policy: make it differ per level bin
            TG.TaxiPolicy = function() return "band" .. CM.LevelKey(ctl.level, "band") end
            TG.TaxiUsable = function(node) return CM.TaxiPlausible(levels, node and node.taxiID, ctl.level) end
        elseif ctl.policy ~= "faction" then
            error("offline taxi policy must be faction, band or known: " .. tostring(ctl.policy))
        end
    end
    return ctl
end

-- where a guide starts (vplayer puts its character there; the bake's first leg leaves from there): the guide zone's centre
function OFF.StartPoint(NS, g, steps)
    local zone = g.zone
    if not zone then for _, s in ipairs(steps or {}) do if s.zone then zone = s.zone break end end end
    zone = tonumber(zone) or zone
    if not zone then return nil end
    local wx, wy, inst = NS.HBD:GetWorldCoordinatesFromZone(0.5, 0.5, zone)
    if not wx then return nil end
    return zone, wx, wy, inst
end

return OFF
