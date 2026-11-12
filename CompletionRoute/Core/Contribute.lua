-- CompletionRoute :: Core/Contribute.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- "Contribute": the player's own play builds the location database (docs/CONTRIBUTE.md).
--
-- With the Contribute box on the guide window ticked, and only then, the addon notes WHERE the player stands when:
--   * the forward arrow is clicked on the current step          (kind m, weight 1: the player may be anywhere near)
--   * a quest is accepted or turned in (the client's own events) (kind a, weight 3: the player stands at the NPC)
--   * a quest objective of a step in the guide's next steps ticks up (kind o, weight 2: where the mob, item or
--     object was)
--   * a creature the player (or the pet) hurt dies               (kind k, weight 1, key N:<npc id>; combat log, Classic
--     clients only; the player may be at range)
--   * a creature's corpse is looted                              (kind l, weight 2, key N:<npc id>)
--   * a game object is looted: chest, treasure, herb, ore        (kind g, weight 3, key O:<object id>)
--   * the loot holds an item one of the guide's next steps names (its L or U tag): key I:<item id>, weight of the
--     loot it came from
-- A rare creature (UnitClassification "rare" or "rareelite") gets a flag in its record (rare = true), not a key of
-- its own.  Creatures, objects and items are never noted inside an instance, and each such key takes at most one
-- sample every C.THROTTLE seconds.
-- Nothing else is stored: a map id, a position on it, the quest, creature, object or item id or the step key, a
-- weight.  No character, realm, account or creature name, no time stamps.  Nothing is sent anywhere; the data sits in
-- the account's saved variables until the player exports it (/cr contribute export) to share with the open quest
-- database.
--
-- From those samples the most likely places are worked out (C.Areas): the densest cluster first, each with a centre
-- and a radius.  They are used at once on this machine: a step the guide has no point for is routed to its learned
-- spot (Router.StepWorld, source "learned"), and the current step's areas are drawn on the world map as circles,
-- together with the learned areas of the creature, object and items the step names (C.MapKeys).
local ADDON, NS = ...
local U = NS.Util
local C = {}
NS.Contribute = C

local HBD = LibStub and LibStub("HereBeDragons-2.0", true)
local HBDPins = LibStub and LibStub("HereBeDragons-Pins-2.0", true)

C.CELL = 0.2            -- map-% grid the samples are merged on (positions are stored as 0..100)
C.MAX_CELLS = 80        -- per key: the lightest cell goes when a new one would exceed this
C.RADIUS = 1.5          -- map-% : cells closer than this to a cluster's centre belong to it
C.MIN_R = 0.3           -- smallest circle drawn / reported
C.WEIGHT = { m = 1, o = 2, a = 3, k = 1, l = 2, g = 3 }
C.THROTTLE = 5          -- seconds: one sample per creature, object or item key at most this often
C.MAX_LINKS = 6         -- per step key: creatures and objects learned to belong to that step
local ACCEPT = { A = true, a = true }
local TURNIN = { T = true, t = true }
local QUEST_KIND = { A = true, T = true, C = true, G = true }   -- the step keys; N, O and I are what steps name
local RARE = { rare = true, rareelite = true }
local lower = string.lower

local function flavor() return NS.dataFlavor or NS.flavor or "?" end
local function enabled() return NS.db and NS.db.profile and NS.db.profile.contribute and true or false end
C.Enabled = enabled
local function inInstance() return (IsInInstance and IsInInstance()) and true or false end
local function wipe(t) for k in pairs(t) do t[k] = nil end return t end

-- account-wide store: contrib.spots[flavor][key][cell] = weight ; cell = "<map>,<x*5>,<y*5>" on the CELL grid.
-- A record may also hold rare = true (a creature key); every reader skips entries whose value is not a number.
local function store(create)
    if not NS.db then return nil end
    local g = NS.db.global
    if not g.contrib then
        if not create then return nil end
        g.contrib = { v = 1, spots = {} }
    end
    local t = g.contrib.spots[flavor()]
    if not t and create then t = {} g.contrib.spots[flavor()] = t end
    return t
end
-- contrib.links[flavor][step key][N:<id> or O:<id>] = true: the creature or object a step was seen to be about
-- (killed or looted while it was one of the next steps and its name or item matched).  Ids only; never exported.
local function linkStore(create)
    if not NS.db then return nil end
    local g = NS.db.global
    if not g.contrib then
        if not create then return nil end
        g.contrib = { v = 1, spots = {} }
    end
    if not g.contrib.links then
        if not create then return nil end
        g.contrib.links = {}
    end
    local t = g.contrib.links[flavor()]
    if not t and create then t = {} g.contrib.links[flavor()] = t end
    return t
end

-- The database key of a step.  Quest steps are keyed by quest, not by guide, so every guide that has the quest
-- shares what was learned; anything else is keyed by its guide and stable step key (Core/Guide.lua AssignKeys).
function C.KeyFor(step)
    if not step then return nil end
    local q = step.qid and step.qid[1]
    if q then
        if ACCEPT[step.action] then return "A:" .. q end
        if TURNIN[step.action] then return "T:" .. q end
        return "C:" .. q .. ":" .. (tonumber(step.qo) or 0)
    end
    if step.guide and step.key then return "G:" .. tostring(step.guide) .. "#" .. tostring(step.key) end
    return nil
end

local areasCache, worldCache = {}, {}
local function forget(key) areasCache[key] = nil worldCache[key] = nil end

-- one sample at the player's position; rare = true flags the record (a rare creature)
function C.Record(key, kind, rare)
    if not key or not enabled() then return false end
    if (UnitOnTaxi and UnitOnTaxi("player")) or (UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")) then return false end
    local map, x, y = U.PlayerPos()
    if not map or not x or not y or x <= 0 or y <= 0 or x >= 1 or y >= 1 then return false end
    local t = store(true)
    if not t then return false end
    local cells = t[key]
    if not cells then cells = {} t[key] = cells end
    local q = 1 / C.CELL
    local cell = ("%d,%d,%d"):format(map, math.floor(x * 100 * q + 0.5), math.floor(y * 100 * q + 0.5))
    if not cells[cell] then
        local n, lightest, lw = 0, nil, nil
        for c, w in pairs(cells) do
            if type(w) == "number" then
                n = n + 1
                if not lw or w < lw then lightest, lw = c, w end
            end
        end
        if n >= C.MAX_CELLS and lightest then cells[lightest] = nil end
    end
    cells[cell] = (cells[cell] or 0) + (C.WEIGHT[kind] or 1)
    if rare then cells.rare = true end
    forget(key)
    C.lastKey, C.lastKind = key, kind
    NS:Fire("CONTRIBUTE_SAMPLE", key, kind)
    return true
end

-- a creature, object or item sample: never in an instance, one per key every C.THROTTLE seconds.  The time stamps are
-- this session's only (memory), never saved.
local lastAt = {}
function C.RecordSeen(key, kind, rare)
    if not key or not enabled() or inInstance() then return false end
    local now = (GetTime and GetTime()) or 0
    local last = lastAt[key]
    if last and now - last < C.THROTTLE then
        if rare then
            local t = store(false)
            local rec = t and t[key]
            if rec then rec.rare = true end
        end
        return false
    end
    if not C.Record(key, kind, rare) then return false end
    lastAt[key] = now
    return true
end

function C.IsRare(key)
    local t = store(false)
    local rec = key and t and t[key]
    return rec and rec.rare == true or false
end

local function parse(cells)
    local out = {}
    for c, w in pairs(cells) do
        if type(w) == "number" then
            local m, x, y = c:match("^(%d+),(%-?%d+),(%-?%d+)$")
            if m then out[#out + 1] = { m = tonumber(m), x = tonumber(x) * C.CELL, y = tonumber(y) * C.CELL, w = w } end
        end
    end
    -- a fixed order, so the same samples always give the same areas
    table.sort(out, function(a, b)
        if a.m ~= b.m then return a.m < b.m end
        if a.x ~= b.x then return a.x < b.x end
        return a.y < b.y
    end)
    return out
end

-- The most likely places for a key, heaviest first: { m = map, x = , y = (0..100), r = radius in map %, w = weight,
-- n = cells }.  Greedy: the cell with the most weight around it seeds a cluster, the cluster's weighted centre is
-- taken once more, its cells are removed, and the rest is searched again.  A leftover lighter than 15% of all the
-- weight (and lighter than 2) is noise and gives no area.  At most four areas.
function C.Areas(key)
    if not key then return {} end
    local hit = areasCache[key]
    if hit then return hit end
    local out = {}
    local t = store(false)
    local cells = t and t[key]
    if cells then
        local pts = parse(cells)
        local total = 0
        for _, p in ipairs(pts) do total = total + p.w end
        local R2 = C.RADIUS * C.RADIUS
        while #pts > 0 and #out < 4 do
            local best, bw
            for i, p in ipairs(pts) do
                local w = 0
                for _, o in ipairs(pts) do
                    if o.m == p.m then
                        local dx, dy = o.x - p.x, o.y - p.y
                        if dx * dx + dy * dy <= R2 then w = w + o.w end
                    end
                end
                if not bw or w > bw then best, bw = i, w end
            end
            if #out > 0 and (bw < 2 or bw < total * 0.15) then break end
            local seed = pts[best]
            local cx, cy = seed.x, seed.y
            for _ = 1, 2 do
                local sx, sy, sw = 0, 0, 0
                for _, o in ipairs(pts) do
                    if o.m == seed.m then
                        local dx, dy = o.x - cx, o.y - cy
                        if dx * dx + dy * dy <= R2 then sx, sy, sw = sx + o.x * o.w, sy + o.y * o.w, sw + o.w end
                    end
                end
                if sw > 0 then cx, cy = sx / sw, sy / sw end
            end
            local keep, mine, w, far = {}, 0, 0, 0
            for _, o in ipairs(pts) do
                local dx, dy = o.x - cx, o.y - cy
                local d2 = dx * dx + dy * dy
                if o.m == seed.m and d2 <= R2 then
                    mine, w = mine + 1, w + o.w
                    if d2 > far then far = d2 end
                else
                    keep[#keep + 1] = o
                end
            end
            if mine == 0 then break end
            out[#out + 1] = { m = seed.m, x = cx, y = cy, r = math.max(C.MIN_R, math.sqrt(far)), w = w, n = mine }
            pts = keep
        end
    end
    areasCache[key] = out
    return out
end

-- the learned world position of a step (nil when nothing was learned for it): Routing/Router.lua StepWorld asks
-- this for a step the guide gives no point for
function C.StepWorld(step)
    local key = C.KeyFor(step)
    if not key then return nil end
    local w = worldCache[key]
    if w == nil then
        w = false
        local a = C.Areas(key)[1]
        if a and HBD then
            local ok, wx, wy, inst = pcall(HBD.GetWorldCoordinatesFromZone, HBD, a.x / 100, a.y / 100, a.m)
            if ok and wx then w = { wx, wy, inst } end
        end
        worldCache[key] = w
    end
    if w then return w[1], w[2], w[3] end
    return nil
end

function C.Stats()
    local keys, cells, weight = 0, 0, 0
    local t = store(false)
    for _, cs in pairs(t or {}) do
        keys = keys + 1
        for _, w in pairs(cs) do
            if type(w) == "number" then cells, weight = cells + 1, weight + w end
        end
    end
    return keys, cells, weight
end

-- keys by what they are: quest = A/T/C/G step keys, N creatures (rare: of them flagged rare), O objects, I items
function C.StatsByKind()
    local out = { quest = 0, N = 0, O = 0, I = 0, rare = 0 }
    for k, cs in pairs(store(false) or {}) do
        local p = k:sub(1, 1)
        if out[p] then out[p] = out[p] + 1 else out.quest = out.quest + 1 end
        if cs.rare == true then out.rare = out.rare + 1 end
    end
    return out
end

-- this session only (memory, never saved): creature names seen with the box ticked -> npc id, rares seen as the
-- target, the steps the guide is about to do (rebuilt when the step changes)
local seenNPC, rares = {}, {}
local want = { dirty = true, names = {}, items = {} }
local mapKeySet, mapNameSet = {}, {}

function C.Clear()
    if NS.db and NS.db.global.contrib then
        NS.db.global.contrib.spots[flavor()] = nil
        if NS.db.global.contrib.links then NS.db.global.contrib.links[flavor()] = nil end
    end
    areasCache, worldCache = {}, {}
    wipe(lastAt)
    NS:Fire("CONTRIBUTE_SAMPLE")
end

function C.SetEnabled(on)
    NS.db.profile.contribute = on and true or false
    if on and not NS.db.global.contribSeen then
        NS.db.global.contribSeen = true
        NS:Print("Contribute is on: the addon notes where you stand when you accept or turn in a quest, when an objective "
            .. "ticks, when you click the forward arrow, and when you kill or loot a creature, open a treasure or gather "
            .. "a node (not in dungeons). Only map positions and game ids are kept, in your saved variables. "
            .. "/cr contribute shows what was collected; /cr contribute export gives a text to share.")
    end
    NS:Fire("CONTRIBUTE_CHANGED", NS.db.profile.contribute)
end

-- Text for sharing: one line per key, "flavor|client build|key|map,x,y,weight;...".  No names of any kind; the rare
-- flag is not in it (the format stays four fields: the data repository can tell rares from Blizzard's creature data).
function C.Export()
    local lines = {}
    local build = (GetBuildInfo and select(1, GetBuildInfo())) or "?"
    local t = store(false) or {}
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local parts = {}
        for _, p in ipairs(parse(t[k])) do parts[#parts + 1] = ("%d,%.1f,%.1f,%d"):format(p.m, p.x, p.y, p.w) end
        if #parts > 0 then lines[#lines + 1] = ("%s|%s|%s|%s"):format(flavor(), build, k, table.concat(parts, ";")) end
    end
    return table.concat(lines, "\n"), #lines
end

-- ---------------------------------------------------------------------------
-- What is recorded: quest steps
-- ---------------------------------------------------------------------------
-- 1. the forward arrow on the current step (Core/Progress.lua MarkDone fires STEP_DONE with manual and wasCurrent)
NS:On("STEP_DONE", function(step, manual, wasCurrent)
    if manual and wasCurrent and enabled() then C.Record(C.KeyFor(step), "m") end
end)

-- 2. accept and turn-in, straight from the client: the player is standing at the giver or the ender
NS:RegisterEvent("QUEST_ACCEPTED", function(_, a, b)
    local q = tonumber(b) or tonumber(a)      -- (questID) on Retail, (log index, questID) on the Classic clients
    if q and enabled() then C.Record("A:" .. q, "a") end
end)
NS:RegisterEvent("QUEST_TURNED_IN", function(_, q)
    q = tonumber(q)
    if q and enabled() then C.Record("T:" .. q, "a") end
end)

-- 3. objective progress on the quests of the guide's next steps: where the count went up is where the thing is
local seen = {}      -- [key] = fulfilled count last seen
local function pollObjectives()
    if not enabled() or not (NS.Progress and NS.Progress.Pending) then return end
    local ok, pending = pcall(NS.Progress.Pending, 20)
    if not ok or not pending then return end
    for _, s in ipairs(pending) do
        local q = s.qid and s.qid[1]
        if q and not ACCEPT[s.action] and not TURNIN[s.action] and U.IsOnQuest(q) then
            local key = C.KeyFor(s)
            local okq, have = pcall(U.QuestObjective, q, tonumber(s.qo) or 1)
            have = okq and tonumber(have) or nil
            if have then
                if seen[key] and have > seen[key] then C.Record(key, "o") end
                seen[key] = have
            end
        end
    end
end
C.PollObjectives = pollObjectives
NS:RegisterEvent("QUEST_LOG_UPDATE", function() NS:Throttle("contribute-objectives", 0.3, pollObjectives) end)

-- ---------------------------------------------------------------------------
-- What is recorded: creatures, objects and the items the next steps name
-- ---------------------------------------------------------------------------
-- A GUID is "<type>-0-<server>-<instance>-<zone>-<id>-<spawn>" on every client: the id is the creature's (Creature,
-- Vehicle) or the object's (GameObject).  Anything else (a player, a pet, an item opened in the bags) is no place.
local SOURCE = { Creature = "N", Vehicle = "N", GameObject = "O" }
local function sourceOf(guid)
    if type(guid) ~= "string" then return nil end
    local kind, id = guid:match("^(%a+)%-[^%-]*%-[^%-]*%-[^%-]*%-[^%-]*%-(%d+)")
    kind, id = SOURCE[kind], tonumber(id)
    if kind and id and id > 0 then return kind, id end
    return nil
end
C.SourceOf = sourceOf

-- the steps the guide is about to do: the current one, the routed next ones and the next 20 not done
-- names[lower-case creature name] = { step, ... } (Beacon.StepNames: the T tag, "Kill X", "from X"),
-- items[item id] = { step, ... } (the L items and the U item)
local function push(t, k, s)
    local l = t[k]
    if not l then l = {} t[k] = l end
    for i = 1, #l do if l[i] == s then return end end
    l[#l + 1] = s
end
local function wantSets()
    if not want.dirty then return want end
    want.dirty = false
    want.names, want.items = {}, {}
    local P = NS.Progress
    if not P then return want end
    local B = NS.Beacon
    local done = {}
    local function add(s)
        if not s or done[s] then return end
        done[s] = true
        if s.loot then for _, l in ipairs(s.loot) do if l.id then push(want.items, l.id, s) end end end
        if s.item then push(want.items, s.item, s) end
        if B and B.StepNames then for _, n in ipairs(B.StepNames(s)) do push(want.names, n, s) end end
    end
    add(P.current)
    if P.Upcoming then
        local ok, up = pcall(P.Upcoming, 6)
        if ok and up then for _, s in ipairs(up) do add(s) end end
    end
    if P.Pending then
        local ok, pend = pcall(P.Pending, 20)
        if ok and pend then for _, s in ipairs(pend) do add(s) end end
    end
    return want
end
local function wantDirty() want.dirty = true end
for _, e in ipairs({ "STEP_CHANGED", "PROGRESS_REFRESHED", "GUIDE_LOADED", "GUIDE_REBUILT" }) do NS:On(e, wantDirty) end
C._want = wantSets

local function mapSoon() NS:Throttle("contribute-map", 0.5, function() pcall(C.UpdateMap) end) end

-- a step is about this creature or object: remembered by step key (ids only), at most C.MAX_LINKS per step
local function link(stepKey, key)
    if not stepKey or not key then return end
    local t = linkStore(true)
    if not t then return end
    local l = t[stepKey]
    if l and l[key] then return end
    local n = 0
    for _ in pairs(l or {}) do n = n + 1 end
    if n >= C.MAX_LINKS then return end
    if not l then l = {} t[stepKey] = l end
    l[key] = true
    local cur = NS.Progress and NS.Progress.current
    if cur and C.KeyFor(cur) == stepKey then mapSoon() end
end
function C.LinksFor(stepKey)
    local t = linkStore(false)
    return stepKey and t and t[stepKey] or nil
end

-- a creature's name, seen with the box ticked: the steps that name it now know its id
local function learnName(name, id)
    if U.IsSecret(name) or type(name) ~= "string" or name == "" then return nil end
    local low = lower(name)
    if seenNPC[low] ~= id then
        seenNPC[low] = id
        if mapNameSet[low] then mapSoon() end
    end
    return low
end

local function targetGUID()
    local g = UnitGUID and UnitGUID("target")
    if U.IsSecret(g) or type(g) ~= "string" then return nil end
    return g
end
local function targetRare(guid)
    if not UnitClassification or targetGUID() ~= guid then return false end
    local c = UnitClassification("target")
    return not U.IsSecret(c) and RARE[c] == true
end
local function isRare(guid, id) return rares[id] == true or targetRare(guid) end

-- the target tells a rare and a name before the kill (the corpse may not be the target any more by then)
NS:RegisterEvent("PLAYER_TARGET_CHANGED", function()
    if not enabled() then return end
    local guid = targetGUID()
    local kind, id = sourceOf(guid)
    if kind ~= "N" then return end
    if targetRare(guid) then rares[id] = true end
    learnName(UnitName and UnitName("target"), id)
end)

-- a creature died: a sample, and the next steps that name it are linked to it
local function killed(guid, name)
    if not enabled() or inInstance() then return end
    local kind, id = sourceOf(guid)
    if kind ~= "N" then return end
    local key = "N:" .. id
    local low = learnName(name, id)
    local steps = low and wantSets().names[low]
    if steps then for i = 1, #steps do link(C.KeyFor(steps[i]), key) end end
    C.RecordSeen(key, "k", isRare(guid, id))
end
C.Killed = killed

-- Combat log (Classic Era, TBC Anniversary, MoP Classic, WoW Forever): the creatures the player or the pet hurt are
-- kept in a ring of eight GUIDs (no table is made per event); UNIT_DIED of one of them, or PARTY_KILL by the player,
-- is a kill.  The log is listened to only while the box is ticked and outside instances.  Retail 12.x hides combat
-- information from addons (secret values) and its combat log rules could not be checked offline, so it is not
-- registered there: on Retail the loot window is the creature's only signal.
local DAMAGE = { SWING_DAMAGE = true, RANGE_DAMAGE = true, SPELL_DAMAGE = true, SPELL_PERIODIC_DAMAGE = true,
                 DAMAGE_SHIELD = true, DAMAGE_SPLIT = true }
local TAGS = 8
local tags, tagAt = {}, 1
for i = 1, TAGS do tags[i] = false end
local me, pet, clInfo
local function untag(guid) for i = 1, TAGS do if tags[i] == guid then tags[i] = false end end end
local function onCombatLog()
    local _, sub, _, src, _, _, _, dst, dname = clInfo()
    if DAMAGE[sub] then
        if (src == me or (pet and src == pet)) and type(dst) == "string" and dst ~= tags[tagAt]
            and (dst:find("^Creature%-") or dst:find("^Vehicle%-")) then
            tagAt = tagAt % TAGS + 1
            tags[tagAt] = dst
        end
    elseif sub == "UNIT_DIED" then
        for i = 1, TAGS do
            if tags[i] == dst then untag(dst) killed(dst, dname) return end
        end
    elseif sub == "PARTY_KILL" then
        if src == me or (pet and src == pet) then untag(dst) killed(dst, dname) end
    end
end
C._onCombatLog = onCombatLog
local clFrame = CreateFrame("Frame")
clFrame:SetScript("OnEvent", function() onCombatLog() end)
C.combatLogOn = false
function C.SyncCombatLog()
    local on = enabled() and not inInstance() and (NS.tocversion or 0) < 120000
        and type(CombatLogGetCurrentEventInfo) == "function"
    if on then
        me = UnitGUID and UnitGUID("player") or nil
        pet = UnitGUID and UnitGUID("pet") or nil
        clInfo = CombatLogGetCurrentEventInfo
    end
    if on == C.combatLogOn then return end
    if on then
        C.combatLogOn = pcall(clFrame.RegisterEvent, clFrame, "COMBAT_LOG_EVENT_UNFILTERED") and true or false
    else
        pcall(clFrame.UnregisterEvent, clFrame, "COMBAT_LOG_EVENT_UNFILTERED")
        C.combatLogOn = false
        for i = 1, TAGS do tags[i] = false end
    end
end
NS:On("CONTRIBUTE_CHANGED", function() C.SyncCombatLog() end)
NS:On("PLAYER_READY", function() C.SyncCombatLog() end)
NS:RegisterEvent("PLAYER_ENTERING_WORLD", function() C.SyncCombatLog() end)
NS:RegisterEvent("ZONE_CHANGED_NEW_AREA", function() C.SyncCombatLog() end)
NS:RegisterEvent("UNIT_PET", function(_, unit)
    if unit == "player" and C.combatLogOn then pet = UnitGUID and UnitGUID("pet") or nil end
end)

-- The loot window: the corpse or object it came from (GetLootSourceInfo, as Core/Progress.lua and Core/Farm.lua read
-- it), and the items in it.  A fishing catch is no object's place; an item opened in the bags is no place at all.
local function nearStep(s)
    if not (s.coords and s.zone) then return false end
    local map, x, y = U.PlayerPos()
    if not map then return false end
    for _, c in ipairs(s.coords) do
        local d = U.ZoneDistance(map, x, y, s.zone, c.x, c.y)
        if d and d < (s.radius or 25) then return true end
    end
    return false
end
local looted = {}       -- reused: source GUIDs already noted in this loot window
local function onLoot()
    if not enabled() or inInstance() then return end
    if not (GetNumLootItems and GetLootSourceInfo) then return end
    local fishing = IsFishingLoot and IsFishingLoot() and true or false
    local cur = NS.Progress and NS.Progress.current
    local Sig = NS.StepSignal
    local treasure            -- the step on screen is a treasure at a spot and the player stands there (lazy)
    wipe(looted)
    for slot = 1, GetNumLootItems() or 0 do
        local guid = GetLootSourceInfo(slot)
        if U.IsSecret(guid) then return end
        local kind, id = sourceOf(guid)
        if kind == "O" and fishing then kind = nil end
        local skey = kind and (kind .. ":" .. id)
        if skey and not looted[guid] then
            looted[guid] = true
            if kind == "N" then
                local tg = targetGUID()
                local low = tg == guid and learnName(UnitName and UnitName("target"), id) or nil
                local steps = low and wantSets().names[low]
                if steps then for i = 1, #steps do link(C.KeyFor(steps[i]), skey) end end
                C.RecordSeen(skey, "l", isRare(guid, id))
            else
                if treasure == nil then
                    treasure = (cur and Sig and Sig.LootAtSpot and Sig.LootAtSpot(cur) and nearStep(cur)) and true or false
                end
                if treasure then link(C.KeyFor(cur), skey) end
                C.RecordSeen(skey, "g")
            end
        end
        local itemLink = GetLootSlotLink and GetLootSlotLink(slot)
        local item = type(itemLink) == "string" and not U.IsSecret(itemLink) and tonumber(itemLink:match("item:(%d+)")) or nil
        local steps = item and wantSets().items[item]
        if steps and (skey or fishing) then
            if skey then for i = 1, #steps do link(C.KeyFor(steps[i]), skey) end end
            C.RecordSeen("I:" .. item, kind == "O" and "g" or "l")
        end
    end
end
C.OnLoot = onLoot
NS:RegisterEvent("LOOT_OPENED", onLoot)

-- ---------------------------------------------------------------------------
-- Circles on the world map: the current step's learned areas, and those of what it names
-- ---------------------------------------------------------------------------
-- The step's own key keeps its colour (yellow accept, green turn-in, orange objective, blue other); a creature it
-- names is red, an object (treasure, node) gold, an item purple.  A rare creature's circles get a silver outline.
-- The frames are made once and reused; HereBeDragons places and shows them.
local TEX = "Interface\\AddOns\\" .. ADDON .. "\\Textures\\circle"
local RING = "Interface\\AddOns\\" .. ADDON .. "\\Textures\\ring"
C.RGB = { A = { 1, 0.82, 0 }, T = { 0.4, 1, 0.4 }, C = { 1, 0.45, 0.25 }, G = { 0.24, 0.78, 1 },
          N = { 0.95, 0.18, 0.18 }, O = { 0.85, 0.65, 0.13 }, I = { 0.64, 0.21, 0.93 } }
C.RARE_RGB = { 0.85, 0.9, 1 }
C.MAX_CIRCLES = 16      -- circles on the map at once
C.OWN_AREAS = 4         -- areas drawn for the step's own key
C.EXTRA_AREAS = 2       -- areas drawn for each creature, object or item the step names
local circles = {}
local function circle(i)
    local f = circles[i]
    if not f then
        f = CreateFrame("Frame", nil, UIParent)
        f:SetSize(24, 24)
        f:Hide()
        f.tex = f:CreateTexture(nil, "OVERLAY")
        f.tex:SetAllPoints()
        f.tex:SetTexture(TEX)
        f.ring = f:CreateTexture(nil, "OVERLAY", nil, 1)
        f.ring:SetPoint("TOPLEFT", f, "TOPLEFT", -3, 3)
        f.ring:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 3, -3)
        f.ring:SetTexture(RING)
        f.ring:SetVertexColor(C.RARE_RGB[1], C.RARE_RGB[2], C.RARE_RGB[3], 1)
        f.ring:Hide()
        circles[i] = f
    end
    return f
end
C._circles = circles

-- The keys whose areas belong on the map for a step: its own key, then I:<item> for its L and U items, then the
-- creature its name points at (this session's names), then the creatures and objects linked to it.
function C.MapKeys(step)
    local out, has = {}, {}
    local function add(k) if k and not has[k] then has[k] = true out[#out + 1] = k end end
    local own = C.KeyFor(step)
    add(own)
    if not step then return out end
    if step.loot then for _, l in ipairs(step.loot) do if l.id then add("I:" .. l.id) end end end
    if step.item then add("I:" .. step.item) end
    local B = NS.Beacon
    if B and B.StepNames then
        for _, n in ipairs(B.StepNames(step)) do
            local id = seenNPC[n]
            if id then add("N:" .. id) end
        end
    end
    local l = own and C.LinksFor(own)
    if l then
        local ks = {}
        for k in pairs(l) do ks[#ks + 1] = k end
        table.sort(ks)
        for _, k in ipairs(ks) do add(k) end
    end
    return out
end

function C.UpdateMap()
    C.mapState, C.drawn = "no lib", 0
    if not HBDPins then return end
    pcall(HBDPins.RemoveAllWorldMapIcons, HBDPins, C)
    for _, f in pairs(circles) do f:Hide() f.key, f.rgb, f.rare = nil, nil, nil end
    wipe(mapKeySet) wipe(mapNameSet)
    if not NS.db or not NS.db.profile.beacon or not NS.db.profile.beacon.pins then C.mapState = "pins off" return end
    local s = NS.Progress and NS.Progress.current
    if s and NS.Beacon and NS.Beacon.StepNames then
        for _, n in ipairs(NS.Beacon.StepNames(s)) do mapNameSet[n] = true end
    end
    local own = C.KeyFor(s)
    local keys = C.MapKeys(s)
    for _, k in ipairs(keys) do mapKeySet[k] = true end
    -- a circle's size on the map: its radius is in map %, the canvas is the whole map
    local canvas = WorldMapFrame and WorldMapFrame.GetCanvas and WorldMapFrame:GetCanvas()
    local width = (canvas and canvas.GetWidth and canvas:GetWidth()) or 1000
    if not width or width <= 0 then width = 1000 end
    local n, drawn = 0, 0
    for _, key in ipairs(keys) do
        if n >= C.MAX_CIRCLES then break end
        local mine = key == own
        local c = C.RGB[key:sub(1, 1)] or C.RGB.G
        local rare = C.IsRare(key)
        for i, a in ipairs(C.Areas(key)) do
            if i > (mine and C.OWN_AREAS or C.EXTRA_AREAS) or n >= C.MAX_CIRCLES then break end
            n = n + 1
            local f = circle(n)
            local d = math.max(18, math.min(260, 2 * a.r / 100 * width))
            f:SetSize(d, d)
            f.tex:SetVertexColor(c[1], c[2], c[3], (i == 1 and 0.9 or 0.55) * (mine and 1 or 0.85))
            if rare then f.ring:Show() else f.ring:Hide() end
            f.key, f.rgb, f.rare = key, c, rare
            local ok = pcall(HBDPins.AddWorldMapIconMap, HBDPins, C, f, a.m, a.x / 100, a.y / 100, 1)
            if ok then drawn = drawn + 1 end
        end
    end
    C.drawn = drawn
    C.mapState = drawn == 0 and "nothing learned for this step" or ("%d learned area(s) drawn"):format(drawn)
end
NS:On("STEP_CHANGED", function() mapSoon() end)
NS:On("CONTRIBUTE_SAMPLE", function(key)
    -- routing reads the step keys only; the map only what the step on screen names
    if (not key or QUEST_KIND[key:sub(1, 1)]) and NS.Router and NS.Router.Invalidate then pcall(NS.Router.Invalidate) end
    if not key or mapKeySet[key] then mapSoon() end
end)
NS:On("PLAYER_READY", function() NS:After(4, function() pcall(C.UpdateMap) end) end)

-- ---------------------------------------------------------------------------
-- /cr contribute [on|off|clear|export]
-- ---------------------------------------------------------------------------
local exportFrame
local function showExport()
    local text, n = C.Export()
    if n == 0 then NS:Print("Contribute: nothing collected on this client yet.") return end
    if not exportFrame then
        local f = CreateFrame("Frame", "CompletionRouteContributeExport", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
        f:SetSize(560, 360); f:SetPoint("CENTER"); f:SetFrameStrata("DIALOG")
        if f.SetBackdrop then
            f:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                            tile = true, tileSize = 16, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
            f:SetBackdropColor(0.05, 0.05, 0.08, 0.97)
        end
        f.title = f:CreateFontString(nil, "OVERLAY", U.Font("Title"))
        f.title:SetPoint("TOPLEFT", 12, -10)
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", -2, -2)
        local scroll = CreateFrame("ScrollFrame", "CompletionRouteContributeExportScroll", f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 12, -34); scroll:SetPoint("BOTTOMRIGHT", -32, 12)
        local eb = CreateFrame("EditBox", nil, scroll)
        eb:SetMultiLine(true); eb:SetAutoFocus(false); eb:SetWidth(500)
        eb:SetFontObject(U.Font("Small"))
        eb:SetScript("OnEscapePressed", function() f:Hide() end)
        scroll:SetScrollChild(eb)
        f.eb = eb
        tinsert(UISpecialFrames, "CompletionRouteContributeExport")
        exportFrame = f
    end
    exportFrame.title:SetText(("Contribute: %d places. Select all (Ctrl+A), copy, and send it to the open quest database."):format(n))
    exportFrame.eb:SetText(text)
    exportFrame:Show()
    exportFrame.eb:HighlightText()
    exportFrame.eb:SetFocus()
end
C.ShowExport = showExport

function C.Slash(arg)
    arg = (arg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if arg == "on" or arg == "off" then C.SetEnabled(arg == "on")
    elseif arg == "clear" then C.Clear() NS:Print("Contribute: this client's collected places were cleared.") return
    elseif arg == "export" then showExport() return end
    local _, cells, weight = C.Stats()
    local k = C.StatsByKind()
    NS:Print(("Contribute is %s. Collected on this client: %d quest steps, %d creatures (%d rare), %d objects, %d items; "
        .. "%d spots (weight %d). /cr contribute on|off|export|clear"):format(enabled() and "ON" or "off", k.quest, k.N,
        k.rare, k.O, k.I, cells, weight))
    local s = NS.Progress and NS.Progress.current
    local key = C.KeyFor(s)
    if key then
        local areas = C.Areas(key)
        if #areas > 0 then
            local a = areas[1]
            NS:Print(("  current step: %d learned area(s); best %.1f, %.1f on map %d (radius %.1f, weight %d)"):format(
                #areas, a.x, a.y, a.m, a.r, a.w))
        end
    end
    if s then NS:Print("  map: " .. tostring(C.mapState)) end
end
