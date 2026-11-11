-- CompletionRoute :: Routing/CostModel.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- ONE cost model for the offline bake (tools/cost_matrix.lua -> tools/optimize_routes.py), the live window
-- (Routing/StepOrder.lua), the quest-skip re-plan (Routing/Replan.lua), the virtual player (tools/vplayer.lua) and the
-- arrow's point for a step without |M| (Routing/Router.lua StepWorld).  docs/ROUTING.md "One cost model".
--
-- 1. Where a step is (CM.Locate, once per guide in author order; the result is a kind on the step):
--      own   its own |M| point (the first one)
--      npc   no |M|, but the NPC its note names ("From X." / "To X.") has an |M| on another step of the guide: that point
--      ride  no |M|, no NPC point, and no zone or the zone of the last priced point before it: the step is done where the
--            player already is.  It rides with the step before it: it costs nothing and moves no one
--      zone  no |M|, no NPC point, and a zone the route is not in yet: the zone's centre
--      none  no zone and nothing before it to ride with (a leading note)
--    own, npc and zone are "located": each one starts a block of the bake and of the live window, and is priced at its
--    point.  ride and none join the block before them.  Measured on real guides (tools/cost_holdout.lua, 3,000 steps per
--    client): hide the point of a located quest step and predict the detour through it.  This rule has the smallest
--    error on every client (mean 22-50 s per step; the zone centre alone 117-194 s, riding along alone 27-110 s).
-- 2. One no-route cost: a leg the router cannot path costs CM.NOROUTE seconds, everywhere.
-- 3. Speed and walking factor: by level band (CM.GroundSpeed, the bands U.TravelSpeed always used).  Offline, a guide is
--    played at each step's planning level: the guide's start level raised by every |LVL| up to that step in author
--    order.  A leg is priced at the level of the step it leaves from.  Classic clients never fly offline; retail flies
--    from level 10 (U.CanFly's rule).  Off-road walking costs CM.TERRAIN (the Options slider in game), flying
--    CM.FLY_TERRAIN; short walks below CM.WALK_ONLY_BELOW yards use the same factor as the graph's walks.
-- 4. Offline flight paths (CM.OFFLINE_TAXI): which flight masters the bake and vplayer assume.  "faction" (every one
--    the faction can use) was measured against "band" (the ones a character at that level plausibly has) on 100 sample
--    guides: both bakes save time when vplayer flies only to discovered flight paths, faction by 0.4% more overall.
--    The client itself always uses the character's discovered ones (routing.taxiPolicy "known").
-- 5. No hearth and no teleports offline: they are one-shot legs from where the player stands, never pairwise costs.
--    Only a step that says to use the hearthstone (H) costs CM.HEARTH instead of the trip to its point.
-- 6. The planning character (CM.Persona, CM.Takes, CM.PlanSteps): one baked order serves everyone who plays the guide, so
--    it is planned for the character most of the guide's located steps are written for: the guide's faction (in a guide
--    for both factions: the faction at least half of its located steps are tagged for, else none), then the class, the
--    race and the profession at least half of the located steps it takes so far name (else none).  A race's starting
--    zone is planned for that race, a class guide for that class; a guide split between many classes keeps the steps
--    every character takes.  The bake walks to the steps that character takes; a step it does not take, or one that
--    ticks by itself (a second accept or turn-in, an objective already done), rides along.  vplayer --who plan plays
--    exactly that character, and tools/test_cost_parity.lua requires the optimizer's predicted seconds and vplayer's to
--    agree within 2% per guide.  The bake gate plays a real character of that faction, class and race (--who gate).
-- 7. The bake gate (tools/optimize_routes.py --gate): a baked order is kept only when vplayer finds baked order + live
--    window not slower than author order + live window by more than max(CM.GATE_FRAC, CM.GATE_ABS seconds).
-- Changing any rule here changes baked costs: bump CM.VERSION, which makes every baked row stale (tools/bake_resume.py).
local ADDON, NS = ...
local CM = {}
NS.CostModel = CM

CM.VERSION = 2             -- stamped into every cost_matrix row and optimizer result row (2: the planning character)
CM.NOROUTE = 1800          -- seconds for a leg the router cannot path (the same in every order, so it never wins a bake)
CM.HEARTH = 60             -- seconds an H step (use the hearthstone) costs offline: routing.hearthCost's default
CM.WALK_ONLY_BELOW = 700   -- yards: below this a leg is a straight walk, never a graph search
CM.TERRAIN = 1.25          -- off-road walking factor (routing.terrainFactor, the Options slider, overrides it in game)
CM.FLY_TERRAIN = 1.05      -- flying: terrain hardly matters
CM.RUN_SPEED = 7           -- yd/s on foot (routing.runSpeed)
CM.FLY_SPEED = 45          -- yd/s, retail flying (U.FlySpeed's retail value)
-- ground speed by level (yd/s): the first band whose level the character has reached
CM.BANDS = {
    classic = { { 60, 14 }, { 40, 11.2 } },   -- Classic Era, TBC Anniversary, MoP Classic, WoW Forever: 60% at 40, 100% at 60
    modern = { { 10, 14 } },                  -- retail: riding at 10
}
-- Offline flight-path rule (tools/cost_matrix.lua, tools/vplayer.lua --taxi model):
--   "faction"  every flight master the faction can use (the rule every bake so far used)
--   "band"     only flight masters in zones whose lowest guide level is at or below the leg's planning level (rounded
--              down to CM.LEVEL_BIN): the ones a character levelling through the guides plausibly has.  Capitals and
--              starting-zone flight masters sit in level-1 zones, so they are always in.
CM.OFFLINE_TAXI = "faction"
CM.LEVEL_BIN = 5
-- the bake gate: baked order + live window may be slower than author order + live window by at most
-- max(GATE_FRAC of it, GATE_ABS seconds) (tools/optimize_routes.py reads both from the rows, tools/test_route_order.lua here)
CM.GATE_FRAC = 0.01
CM.GATE_ABS = 30
CM.NPC_PATTERNS = { "^From (.-)%.", "^To (.-)%." }

local floor = math.floor

-- ---------------------------------------------------------------------------
-- Speed
-- ---------------------------------------------------------------------------
local function isClassic() return NS.isClassic and true or false end
function CM.GroundSpeed(level, classic, runSpeed)
    if classic == nil then classic = isClassic() end
    for _, b in ipairs(classic and CM.BANDS.classic or CM.BANDS.modern) do
        if (level or 1) >= b[1] then return b[2] end
    end
    return runSpeed or CM.RUN_SPEED
end
-- the offline character's travel at a level: speed (yd/s) and whether it flies
function CM.PlanTravel(level, classic)
    if classic == nil then classic = isClassic() end
    if not classic and (level or 1) >= 10 then return CM.FLY_SPEED, true end
    return CM.GroundSpeed(level, classic), false
end
function CM.WalkFactor(canFly, terrain) return canFly and CM.FLY_TERRAIN or (terrain or CM.TERRAIN) end
-- the level a guide starts at (where vplayer starts a character, and the bake's first leg)
function CM.StartLevel(g) return math.max(1, floor(tonumber(g and g.minlevel) or 1)) end
-- the key that groups levels with the same offline costs: the speed band, or (taxi "band") the level bin
function CM.LevelKey(level, policy)
    level = level or 1
    if (policy or CM.OFFLINE_TAXI) == "band" then return math.max(1, floor(level / CM.LEVEL_BIN) * CM.LEVEL_BIN) end
    local classic = isClassic()
    local best = 1
    for _, b in ipairs(classic and CM.BANDS.classic or CM.BANDS.modern) do
        if level >= b[1] and b[1] > best then best = b[1] end
    end
    if not classic and level >= 10 then best = math.max(best, 10) end
    return best
end

-- ---------------------------------------------------------------------------
-- Where a step is
-- ---------------------------------------------------------------------------
local function npcName(s)
    local n = s.note
    if not n or n == "" then return nil end
    for _, p in ipairs(CM.NPC_PATTERNS) do
        local who = n:match(p)
        if who then
            who = who:match("^%s*(.-)%s*$")
            if #who >= 3 and not who:find("[%(%)]") then return who end
        end
    end
    return nil
end
CM.NpcName = npcName

local function ownOK(s)
    local c = s.coords and s.coords[1]
    if not (c and s.zone and c.x) then return false end
    local HBD = NS.HBD
    if not HBD then return true end
    return HBD:GetWorldCoordinatesFromZone(c.x, c.y, s.zone) ~= nil
end

-- Annotate `steps` (any order; author order is s.index) with the cost model's kind (s._cmk), the step it borrows from
-- or rides with (s._cmr) and the planning level (s._cml).  g = the guide (for its start level), optional.
function CM.Locate(steps, g)
    if not steps or #steps == 0 then return steps end
    local list = steps
    local sorted = true
    for i = 2, #steps do if (steps[i].index or 0) < (steps[i - 1].index or 0) then sorted = false break end end
    if not sorted then
        list = {}
        for i, s in ipairs(steps) do list[i] = s end
        table.sort(list, function(a, b) return (a.index or 0) < (b.index or 0) end)
    end
    -- NPC name -> positions (in `list`) of steps with their own point that name it
    local own, npcAt = {}, {}
    for k, s in ipairs(list) do
        own[k] = ownOK(s)
        if own[k] then
            local who = npcName(s)
            if who then local l = npcAt[who] if not l then l = {} npcAt[who] = l end l[#l + 1] = k end
        end
    end
    local level = CM.StartLevel(g)
    local prev, prevZone
    for k, s in ipairs(list) do
        if s.minlevel and s.minlevel > level then level = floor(s.minlevel) end
        s._cml = level
        local kind, ref
        if own[k] then
            kind = "own"
        else
            local who = npcName(s)
            local l = who and npcAt[who]
            if l then
                local best, bd
                for _, j in ipairs(l) do
                    local d = math.abs(j - k)
                    if not bd or d < bd then best, bd = j, d end
                end
                kind, ref = "npc", list[best]
            elseif prev and (not s.zone or s.zone == prevZone) then
                kind, ref = "ride", prev
            elseif s.zone then
                kind = "zone"
            else
                kind = "none"
            end
        end
        s._cmk, s._cmr = kind, ref
        if kind == "own" or kind == "zone" then prev, prevZone = s, s.zone
        elseif kind == "npc" then prev, prevZone = s, ref.zone end
    end
    return steps
end

-- kind of a step; one Locate never ran over (a hand-built or injected step) gets the old rule: |M| -> own, a zone ->
-- its centre, nothing -> rides along
function CM.Kind(s)
    local k = s._cmk
    if k then return k end
    if s.coords and s.zone then return "own" end
    if s.zone then return "zone" end
    return "none"
end
CM.LOCATED = { own = true, npc = true, zone = true }
local LOCATED = CM.LOCATED
function CM.Located(s) return LOCATED[CM.Kind(s)] or false end
-- a point taken from guide data (own or an NPC's), not a stand-in
function CM.Firm(s) local k = CM.Kind(s) return k == "own" or k == "npc" end
function CM.Level(s, default) return s._cml or default end

local function zoneCentre(s)
    if s._zwx then return s._zwx, s._zwy, s._zwinst end
    local HBD = NS.HBD
    if not (HBD and s.zone) then return nil end
    local wx, wy, inst = HBD:GetWorldCoordinatesFromZone(0.5, 0.5, s.zone)
    if wx then s._zwx, s._zwy, s._zwinst = wx, wy, inst end
    return wx, wy, inst
end

-- The cost model's point for a step with no live information: wx, wy, inst, source ("guide" | "entrance" | "npc" | "ride"
-- | "zone"), or nil.  ownWorld(step) is Router's |M| -> world (with the dungeon door rule).
function CM.World(s, ownWorld)
    ownWorld = ownWorld or (NS.Router and NS.Router.OwnWorld)
    local k = CM.Kind(s)
    if k == "own" then
        local wx, wy, inst, src = ownWorld(s)
        if wx then return wx, wy, inst, src end
        if s.zone then local x, y, i = zoneCentre(s) if x then return x, y, i, "zone" end end
        return nil
    elseif k == "npc" then
        local wx, wy, inst = ownWorld(s._cmr)
        if wx then return wx, wy, inst, "npc" end
        return nil
    elseif k == "ride" then
        local h = s._cmr
        if h and h ~= s and h._cmk ~= "ride" then
            local wx, wy, inst = CM.World(h, ownWorld)
            if wx then return wx, wy, inst, "ride" end
        end
        return nil
    elseif k == "zone" then
        local wx, wy, inst = zoneCentre(s)
        if wx then return wx, wy, inst, "zone" end
    end
    return nil
end

-- The same point as a map position (zone, x, y in 0..1) - where tools/vplayer.lua puts its character.  nil for a step
-- that rides along (the character stays where it is) or has no place.
function CM.MapPoint(s)
    local k = CM.Kind(s)
    if k == "own" then local c = s.coords[1] return s.zone, c.x, c.y
    elseif k == "npc" then local r = s._cmr local c = r.coords[1] return r.zone, c.x, c.y
    elseif k == "zone" then return s.zone, 0.5, 0.5 end
    return nil
end

-- ---------------------------------------------------------------------------
-- The planning character (the bake, vplayer --who plan / gate; the client always plays its real character)
-- ---------------------------------------------------------------------------
-- One baked order serves every character that plays the guide, so it is planned for ONE character (rule 6 above):
-- who = { faction = "Alliance" | "Horde" | nil, class = UnitClass token | nil, race = UnitRace token | nil,
--         prof = profession name (lower case) | nil }; nil = none, it takes only the steps without that condition.
-- Class and race names become tokens the way Core/Conditions.lua matches them (Cond.ClassToken / Cond.RaceToken).
local DIMS = { "class", "race", "prof" }
local function trim(v) return (v:gsub("^%s+", ""):gsub("%s+$", "")) end
local function token(dim, v)
    if dim == "prof" then return v:lower() end
    local C = NS.Cond
    if dim == "class" then return C and C.ClassToken and C.ClassToken(v) or (v:gsub("%s", ""):upper()) end
    return C and C.RaceToken and C.RaceToken(v) or v
end
-- the values a condition names, as tokens (nil: no condition, or an "all but" list).  A profession spec is "Name;rank".
local function named(list, dim)
    if not list or list == "" then return nil end
    if dim == "prof" then
        local n = trim(list:match("^([^;]*)") or "")
        return n ~= "" and { [n:lower()] = true } or nil
    end
    if list:sub(1, 1) == "-" then return nil end
    local out
    for v in list:gmatch("[^;,/]+") do
        v = trim(v)
        if v ~= "" then out = out or {} out[token(dim, v)] = true end
    end
    return out
end
-- does a character whose value in `dim` is `mine` (a token, nil = none) take a step with condition `list`?
-- "X" takes only X; "-X" (all but X) takes everyone but X, so a character with no value takes it.
function CM.ListTakes(list, dim, mine)
    if not list or list == "" then return true end
    if dim == "prof" then
        local t = named(list, dim)
        return mine ~= nil and t ~= nil and t[mine] == true
    end
    local neg = list:sub(1, 1) == "-"
    if not mine then return neg end
    local hit = false
    for v in (neg and list:sub(2) or list):gmatch("[^;,/]+") do
        v = trim(v)
        if v ~= "" and token(dim, v) == mine then hit = true break end
    end
    if neg then return not hit end
    return hit
end
local function forAll(list) return not list or list == "" or list:sub(1, 1) == "-" end
function CM.FactionTakes(tag, faction)
    if not tag or tag == "" or tag == "Neutral" then return true end
    if not faction or faction == "" or faction == "Both" then return false end
    return tag:lower():sub(1, 1) == faction:lower():sub(1, 1)
end
-- who: the planning character (CM.Persona), or a faction name (a character with no class, race or profession)
function CM.Takes(s, who)
    if type(who) ~= "table" then who = { faction = who } end
    for _, d in ipairs(DIMS) do
        if not CM.ListTakes(s[d], d, who[d]) then return false end
    end
    return CM.FactionTakes(s.faction, who.faction)
end
CM.ForAll = forAll

-- The planning character of a guide (steps after CM.Locate; g = the guide): the faction, then the class, race and
-- profession that at least half of the located steps it takes so far are written for (ties: the first name).
function CM.Persona(steps, g)
    local who = {}
    local gf = g and g.faction
    if gf == "Alliance" or gf == "Horde" then who.faction = gf end
    local loc = {}
    for _, s in ipairs(steps or {}) do if CM.Located(s) then loc[#loc + 1] = s end end
    if not who.faction then
        local a, h = 0, 0
        for _, s in ipairs(loc) do
            local f = s.faction and s.faction:lower():sub(1, 1)
            if f == "a" then a = a + 1 elseif f == "h" then h = h + 1 end
        end
        local n = math.max(a, h)
        if n > 0 and 2 * n >= #loc then who.faction = (a >= h) and "Alliance" or "Horde" end
    end
    for di, d in ipairs(DIMS) do
        local pool, cnt = 0, {}
        for _, s in ipairs(loc) do
            local ok = CM.FactionTakes(s.faction, who.faction)
            for e = 1, di - 1 do
                if ok and not CM.ListTakes(s[DIMS[e]], DIMS[e], who[DIMS[e]]) then ok = false end
            end
            if ok then
                pool = pool + 1
                local t = named(s[d], d)
                if t then for v in pairs(t) do cnt[v] = (cnt[v] or 0) + 1 end end
            end
        end
        local best, bn
        for v, c in pairs(cnt) do
            if not bn or c > bn or (c == bn and v < best) then best, bn = v, c end
        end
        if best and 2 * bn >= pool then who[d] = best end
    end
    return who
end
-- "Horde Goblin", "Alliance WARRIOR", "any" - for logs and reports
function CM.PersonaText(who)
    local t = {}
    for _, k in ipairs({ "faction", "race", "class", "prof" }) do if who and who[k] then t[#t + 1] = who[k] end end
    return #t > 0 and table.concat(t, " ") or "any"
end

local ACCEPT = { A = true, a = true, ["!"] = true }
local TURNIN = { T = true, t = true }
local OBJECTIVE = { C = true, K = true, l = true, U = true }
-- CM.PlanSteps(steps, who) -> walk, keepObj.  For the planning character (who: CM.Persona's table, or a faction name),
-- in author order:
--   walk[i] = true when it walks to step i: it takes the step (CM.Takes) and the step does not tick by itself.  A step
--             ticks by itself (the client does it, and tools/vplayer.lua's world does the same) when it is a second
--             accept or turn-in of a quest it took, or an objective step whose objective is already done: the same
--             |QO| index again, any objective once a step without an index (the whole quest) is done, or any objective
--             once every index the guide names for that quest is done;
--   keepObj[q] = true for a quest with such an objective step: its objective steps keep their author order (the step
--             that does the objective must come first, or the one that ticks by itself would be walked to instead).
-- Accepts and turn-ins of one quest keep their author order anyway (tools/optimize_routes.py precedence).
function CM.PlanSteps(steps, who)
    if type(who) ~= "table" then who = { faction = who } end
    local walk, keepObj = {}, {}
    local need = {}        -- quest -> { [qo] = true } numbered objectives the guide names for it (taken steps)
    for i, s in ipairs(steps) do
        local q = s.qid and s.qid[1]
        walk[i] = CM.Takes(s, who)
        if walk[i] and q and OBJECTIVE[s.action] then
            local n = tonumber(s.qo)
            if n then local t = need[q] if not t then t = {} need[q] = t end t[n] = true end
        end
    end
    local acc, tin, done, all = {}, {}, {}, {}
    for i, s in ipairs(steps) do
        local q = s.qid and s.qid[1]
        if walk[i] and q then
            local a = s.action
            if ACCEPT[a] then
                if acc[q] then walk[i] = false end
                acc[q] = true
            elseif TURNIN[a] then
                if tin[q] then walk[i] = false end
                tin[q] = true
            elseif OBJECTIVE[a] then
                local n = tonumber(s.qo)
                local d = done[q]
                if all[q] or (n and d and d[n]) then
                    walk[i] = false keepObj[q] = true
                elseif n then
                    if not d then d = {} done[q] = d end
                    d[n] = true
                    local full = true
                    for k in pairs(need[q]) do if not d[k] then full = false break end end
                    if full then all[q] = true end
                else
                    all[q] = true
                end
            end
        end
    end
    return walk, keepObj
end

-- ---------------------------------------------------------------------------
-- Offline flight-path rule "band" (tools only; the client never calls these)
-- ---------------------------------------------------------------------------
-- nodeLevel[taxiID] = the lowest guide level of the zone the flight master stands in (nil = unknown: allowed)
function CM.TaxiPlausible(nodeLevel, taxiID, level)
    local nl = nodeLevel and taxiID and nodeLevel[taxiID]
    if not nl then return true end
    return nl <= math.max(1, floor((level or 1) / CM.LEVEL_BIN) * CM.LEVEL_BIN)
end

-- The constants the Python optimizer reads (tools/cost_matrix.lua writes them into every row as "cm")
function CM.Export(policy)
    return { version = CM.VERSION, noroute = CM.NOROUTE, hearth = CM.HEARTH, walk_only_below = CM.WALK_ONLY_BELOW, terrain = CM.TERRAIN,
             fly_terrain = CM.FLY_TERRAIN, run_speed = CM.RUN_SPEED, fly_speed = CM.FLY_SPEED, taxi = policy or CM.OFFLINE_TAXI,
             level_bin = CM.LEVEL_BIN, gate_frac = CM.GATE_FRAC, gate_abs = CM.GATE_ABS }
end

-- defaults the Options slider and the speed guess start from
if NS.defaults and NS.defaults.profile and NS.defaults.profile.routing then
    NS.defaults.profile.routing.terrainFactor = CM.TERRAIN
    NS.defaults.profile.routing.runSpeed = CM.RUN_SPEED
end
