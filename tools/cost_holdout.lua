-- CompletionRoute :: tools/cost_holdout.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- Hold-out measurement behind the cost model's "located" rule (CompletionRoute/Routing/CostModel.lua, docs/ROUTING.md
-- "One cost model").  A step with no |M| point has to be priced somewhere.  Which stand-in predicts the real detour
-- best?  Take quest steps whose point IS known (accept, objective, turn-in, with a known point before and after them),
-- hide the point, and price the detour prev -> step -> next with each candidate rule against the truth:
--   ride          the step is done where the player already is: prev -> next
--   centre        the centre of the step's zone
--   npc>ride      the NPC the note names ("From X." / "To X.") where another step of the guide has that NPC's |M|; else ride
--   npc>centre    the NPC's point; else the zone centre
--   model         the cost model: the NPC's point; else ride in the zone the route is already in; else the zone centre
-- Prints the mean absolute error and the mean signed error (bias) per action and in all, and how the guides' steps
-- split over the cost model's kinds (own point, NPC point, ride, zone centre, no place).
-- Costs: Router.TravelSeconds with the offline character at the guide's start level (tools/cm_offline.lua, the flight
-- rule CostModel.OFFLINE_TAXI), no hearth.  A leg with no route costs CostModel.NOROUTE.
-- Usage: luajit tools/cost_holdout.lua <era|tbc|mop|retail|forever> [--every K] [--max N]
--        (default every 3rd quest guide, at most 3000 samples)
package.path = "./?.lua;" .. package.path
local flavor = arg[1] or "era"
local EVERY, MAXS = 3, 3000
for i = 2, #arg do
    if arg[i] == "--every" then EVERY = tonumber(arg[i + 1])
    elseif arg[i] == "--max" then MAXS = tonumber(arg[i + 1]) end
end
local TOC = { era = 11507, tbc = 20506, mop = 50504, retail = 120100, forever = 16001 }
local TAXI = "Data/Taxi_" .. flavor .. ".lua"
local EXTRA = { forever = "Data/MapFix_forever.lua" }
STUB_MAPS = dofile("tools/maps_" .. flavor .. ".lua")
local ADDON, NS = "CompletionRoute", {}
dofile("tools/stubs.lua")
function GetBuildInfo() return "x", "0", "2026", TOC[flavor] end
local FACTION = "Alliance"
function UnitFactionGroup() return FACTION end
function UnitLevel() return 1 end
PLAYER = { map = next(MAPS), x = 0.5, y = 0.5 }
local function load(path)
    local f = io.open("CompletionRoute/" .. path, "r") if not f then return end f:close()
    assert(loadfile("CompletionRoute/" .. path))(ADDON, NS)
end
for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", TAXI, EXTRA[flavor] or TAXI,
    "Data/Transit.lua", "Data/Imported_Entrances.lua", "Data/Access.lua", "Data/Inns.lua", "Data/ZoneAliases.lua",
    "Data/Roads_ek.lua", "Data/Roads_kalimdor.lua", "Routing/CostModel.lua", "Routing/TravelGraph.lua", "Routing/Roads.lua",
    "Routing/StepOrder.lua", "Routing/Router.lua", "Core/Account.lua", "Core/Progress.lua", "Core/Instances.lua",
    "Guides/Imported_Wiki_" .. flavor .. ".lua", "Guides/Imported_Quests_" .. flavor .. "_gaps.lua" }) do load(f) end
CompletionRouteDB, CompletionRouteCharDB = nil, nil
for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", "CompletionRoute") end
NS.Print, NS.Debug, NS.Error = function() end, function() end, function() end
NS.db.profile.routing.baked = false
local G, R, TG, CM = NS.Guide, NS.Router, NS.TravelGraph, NS.CostModel
local ctl = dofile("tools/cm_offline.lua").Install(NS, MAPS, {})

local function kind(a)
    if a == "A" or a == "a" or a == "!" then return "A" elseif a == "C" or a == "K" or a == "l" or a == "U" then return "C"
    elseif a == "T" or a == "t" then return "T" end
    return "O"
end
local function pt(wx, wy, inst, zone) return { wx = wx, wy = wy, inst = inst, zone = zone } end
local function ptStep(p) return { coords = { { x = 0.5, y = 0.5 } }, zone = p.zone, _wx = p.wx, _wy = p.wy, _winst = p.inst, _cmk = "own" } end
local memo = {}
local function T(a, b)
    if a == b then return 0 end
    local k = ("%d:%.0f:%.0f>%d:%.0f:%.0f:%d"):format(a.inst, a.wx, a.wy, b.inst, b.wx, b.wy, ctl.level)
    local v = memo[k]
    if v == nil then v = R.TravelSeconds(ptStep(a), ptStep(b)) or false memo[k] = v end
    return v or CM.NOROUTE
end

local RULES = { "ride", "centre", "npc>ride", "npc>centre", "model" }
local acc = {}
for _, r in ipairs(RULES) do acc[r] = { A = { n = 0, abs = 0, sgn = 0 }, C = { n = 0, abs = 0, sgn = 0 }, T = { n = 0, abs = 0, sgn = 0 } } end
local kinds = { own = 0, npc = 0, ride = 0, zone = 0, none = 0 }
local samples, guides, seen = 0, 0, 0
for _, id in ipairs(G.list) do
    if id:sub(1, 5) == "wiki:" or id:sub(1, 4) == "qdb:" or id:sub(1, 5) == "qpoi:" then
        seen = seen + 1
        if (seen - 1) % EVERY == 0 and samples < MAXS then
            local g = G.registry[id]
            local steps = G.Steps(id)
            if steps and #steps > 1 and not g.empty then
                guides = guides + 1
                FACTION = (g.faction == "Horde") and "Horde" or "Alliance"
                NS.player.faction = FACTION
                ctl.SetLevel(CM.StartLevel(g))
                R.Invalidate() TG.Build()
                for _, s in ipairs(steps) do local k = CM.Kind(s) kinds[k] = (kinds[k] or 0) + 1 end
                -- the known points and the NPCs they belong to
                local P, npcPts = {}, {}
                for i, s in ipairs(steps) do
                    if CM.Kind(s) == "own" then
                        local wx, wy, inst = R.StepWorld(s)
                        if wx then
                            P[i] = pt(wx, wy, inst, s.zone)
                            local who = CM.NpcName(s)
                            if who then local l = npcPts[who] or {} l[#l + 1] = i npcPts[who] = l end
                        end
                    end
                end
                local idx = {}
                for i = 1, #steps do if P[i] then idx[#idx + 1] = i end end
                for kk = 2, #idx - 1 do
                    local i = idx[kk]
                    local s = steps[i]
                    local k = kind(s.action)
                    if k ~= "O" and s.route and not s.sticky and samples < MAXS then
                        local p, n, me = P[idx[kk - 1]], P[idx[kk + 1]], P[i]
                        local truth = T(p, me) + T(me, n)
                        local ride = T(p, n)
                        local cx, cy, ci = NS.HBD:GetWorldCoordinatesFromZone(0.5, 0.5, s.zone)
                        local Z = cx and pt(cx, cy, ci, s.zone)
                        local centre = Z and (T(p, Z) + T(Z, n)) or ride
                        local B
                        local who = CM.NpcName(s)
                        for _, j in ipairs(who and npcPts[who] or {}) do
                            if j ~= i then B = P[j] break end
                        end
                        local npc = B and (T(p, B) + T(B, n))
                        local vals = { ride = ride, centre = centre, ["npc>ride"] = npc or ride, ["npc>centre"] = npc or centre,
                                       model = npc or ((p.zone == s.zone) and ride or centre) }
                        samples = samples + 1
                        for _, r in ipairs(RULES) do
                            local a = acc[r][k]
                            local e = vals[r] - truth
                            a.n, a.abs, a.sgn = a.n + 1, a.abs + math.abs(e), a.sgn + e
                        end
                    end
                end
                g.steps = nil
            end
        end
    end
end
local total = 0
for _, v in pairs(kinds) do total = total + v end
print(("HOLDOUT %s: %d guides (every %d), %d held-out quest steps"):format(flavor, guides, EVERY, samples))
print(("  steps by cost-model kind: own %d, npc %d, ride %d, zone %d, none %d (of %d)"):format(kinds.own, kinds.npc, kinds.ride,
    kinds.zone, kinds.none, total))
for _, r in ipairs(RULES) do
    local line = ("  %-11s"):format(r)
    local tn, ta, ts = 0, 0, 0
    for _, k in ipairs({ "A", "C", "T" }) do
        local a = acc[r][k]
        tn, ta, ts = tn + a.n, ta + a.abs, ts + a.sgn
        line = line .. ("  %s n=%d mae %.1fs bias %+.1fs"):format(k, a.n, a.n > 0 and a.abs / a.n or 0, a.n > 0 and a.sgn / a.n or 0)
    end
    print(line .. ("  ALL mae %.1fs bias %+.1fs"):format(tn > 0 and ta / tn or 0, tn > 0 and ts / tn or 0))
end
