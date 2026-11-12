-- CompletionRoute :: Routing/Teleports.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- Teleports as router edges (Data/Teleports.lua).  Like the Hearthstone they are one-shot first legs: TG.FindPath adds
-- an edge from the player to each teleport this character can use right now, and never to a pairwise (hearth = false)
-- query, so the step-order costs and the offline bake do not change.
--   usable    a spell this character knows (and its reagent is in the bags), or an item or toy it owns (a Classic
--             trinket only while worn) that the client says it can use; its `cond` must hold
--   offered   usable and the cooldown has at most T.MAX_COOLDOWN (15 min) left - the Hearthstone's rule; the edge then
--             costs the hearth overhead + cast time + the cooldown still to wait
-- What is usable is worked out on the client events that can change it and kept; cooldowns are read live.  A change in
-- what is offered bumps TG.oneShotGen (TG.OneShotChanged), which drops only the costs FROM the player.
local ADDON, NS = ...
local U = NS.Util
local T = {}
NS.Teleports = T

T.MAX_COOLDOWN = 15 * 60

local function dataFlavor() return NS.dataFlavor or NS.flavor end
local function dist(ax, ay, bx, by) local dx, dy = ax - bx, ay - by return math.sqrt(dx * dx + dy * dy) end

-- Entries for this client, faction and class (static for a character; the key notices a harness switching them).
local cand, candKey
function T.Candidates()
    local p = NS.player or {}
    local key = tostring(NS.flavor) .. "|" .. tostring(p.faction) .. "|" .. tostring(p.class)
    if cand and candKey == key then return cand end
    local fac = (p.faction == "Alliance" and "A") or (p.faction == "Horde" and "H") or nil
    cand, candKey = { move = {}, hearth = {}, bySpell = {} }, key
    for _, e in ipairs(NS.TeleportData or {}) do
        if ((not e.flavors) or e.flavors[NS.flavor]) and ((not e.fac) or e.fac == fac) and ((not e.class) or e.class == p.class) then
            if e.hearth then cand.hearth[#cand.hearth + 1] = e else cand.move[#cand.move + 1] = e end
            local sp = (e.kind == "spell") and e.id or e.spell
            if sp then cand.bySpell[sp] = e end
        end
    end
    T.state = nil
    return cand
end

local function spellName(id)
    if C_Spell and C_Spell.GetSpellName then local ok, n = pcall(C_Spell.GetSpellName, id) if ok and n then return n end end
    if GetSpellInfo then local ok, n = pcall(GetSpellInfo, id) if ok and n then return n end end
    return nil
end
local function displayName(e)
    local n = (e.kind == "spell") and spellName(e.id) or nil
    if not n and e.kind == "item" then
        local i = U.ItemName(e.id)
        if i and not i:find("^item:") then n = i end
    end
    return n or (e.names and e.names[NS.flavor]) or e.name
end

-- `profession` = a SkillLine id (Core/Professions.lua Prof.SKILL_LINE, e.g. 202 Engineering).  Only a definite "this
-- character does not have it" blocks the entry; "cannot tell" (no API, a collapsed skill header) leaves it to the
-- client's own IsUsableItem / C_ToyBox.IsToyUsable answer, which also covers the Gnomish / Goblin specialisations.
local function professionOK(e)
    if not e.profession then return true end
    local P = NS.Professions
    local name = P and P.SKILL_LINE and P.SKILL_LINE[e.profession]
    if not (name and P.Knows) then return true end
    return P.Knows(name) ~= false
end
T.ProfessionOK = professionOK

-- How this character can use an entry right now: "spell", "toy" or "item"; nil = it cannot.
function T.Usable(e)
    if e.cond ~= nil then
        local TG = NS.TravelGraph
        if not (TG and TG.CondOK and TG.CondOK(e.cond)) then return nil end
    end
    if not professionOK(e) then return nil end
    if e.kind == "spell" then
        if not U.SpellKnown(e.id) then return nil end
        local rg = e.reagent and e.reagent[dataFlavor()]
        if rg and not U.HasItem(rg) then return nil end
        return "spell"
    end
    if U.HasToy(e.id) then
        if C_ToyBox and C_ToyBox.IsToyUsable then
            local ok, v = pcall(C_ToyBox.IsToyUsable, e.id)
            if ok and v == false then return nil end
        end
        return "toy"
    end
    if e.equip and e.equip[dataFlavor()] then
        if not U.IsEquipped(e.id) then return nil end
    elseif not U.HasItem(e.id) then return nil end
    if not U.ItemUsable(e.id) then return nil end
    return "item"
end
function T.Cooldown(e, how)
    if how == "spell" then return U.SpellCooldown(e.id) end
    return U.ItemCooldown(e.id)
end

-- The usable set, worked out once per change (T.Recheck) instead of on every search.
local function compute()
    local c = T.Candidates()
    local st = { move = {}, hearthId = nil, hearthToy = false }
    for _, e in ipairs(c.move) do
        local how = T.Usable(e)
        if how then st.move[#st.move + 1] = { e = e, how = how } end
    end
    for _, e in ipairs(c.hearth) do
        local how = T.Usable(e)
        if how then st.hearthId, st.hearthToy = e.id, (how == "toy") break end
    end
    return st
end
local function state()
    T.Candidates()
    if not T.state then T.state = compute() end
    return T.state
end

-- where an entry lands: the spot learned from an actual arrival when there is one, else the data point
function T.Dest(e)
    local fix = NS.db and NS.db.global and NS.db.global.teleportFix and NS.db.global.teleportFix[e.key]
    if fix and fix[1] == e.to[1] then return fix[1], fix[2], fix[3] end
    return e.to[1], e.to[2], e.to[3]
end

-- Every teleport offered right now: { key, kind = "spell"|"item"|"toy", id, inst, wx, wy, dest, title, cast, cd }
function T.Available()
    local c = NS.db and NS.db.profile and NS.db.profile.routing
    if c and c.teleports == false then return {} end
    local out = {}
    for _, u in ipairs(state().move) do
        local e = u.e
        local cd = T.Cooldown(e, u.how)
        if cd <= T.MAX_COOLDOWN then
            local inst, wx, wy = T.Dest(e)
            out[#out + 1] = { key = e.key, kind = u.how, id = e.id, inst = inst, wx = wx, wy = wy, dest = e.to[4], cast = e.cast or 10,
                              cd = cd, title = displayName(e) .. " (" .. (e.to[4] or "?") .. ")" }
        end
    end
    return out
end

-- A Hearthstone stand-in the character owns (Util.HearthReady uses it only when no Hearthstone is in the bags):
-- returns itemID, isToy
function T.HearthToy()
    local st = state()
    return st.hearthId, st.hearthToy
end

-- the spell a Hearthstone stand-in casts (hearth-step completion and the bind-location recorder listen for it)
function T.IsHearthSpell(spellID)
    local e = spellID and T.Candidates().bySpell[spellID]
    return (e and e.hearth) and true or false
end

-- does a teleport's or hearth stand-in's `cond` read this quest (its turn-in can change what is offered)?
-- TG.OnQuestTurnedIn then calls T.Recheck at once.
function T.QuestMatters(q)
    local c = T.Candidates()
    for _, list in ipairs({ c.move, c.hearth }) do
        for _, e in ipairs(list) do
            local cd = type(e.cond) == "table" and e.cond or nil
            if cd then
                for _, k in ipairs({ "quest", "notQuest" }) do
                    local v = cd[k]
                    if v == q then return true end
                    if type(v) == "table" then for _, id in ipairs(v) do if id == q then return true end end end
                end
            end
        end
    end
    return false
end

-- What is offered, as a string: when it changes, the costs from the player are stale.
local function signature(st)
    local parts = { tostring(st.hearthId) }
    for _, u in ipairs(st.move) do
        parts[#parts + 1] = u.e.key .. (T.Cooldown(u.e, u.how) <= T.MAX_COOLDOWN and "+" or "-")
    end
    return table.concat(parts, ",")
end
T.lastSig = nil
function T.Recheck()
    T.state = nil
    local sig = signature(state())
    if sig ~= T.lastSig then
        local TG = NS.TravelGraph
        if TG and TG.OneShotChanged then TG.OneShotChanged() end
    end
    T.lastSig = sig
    return sig
end
if NS.RegisterEvent then
    -- Cooldown events fire on every global cooldown in a fight, and the numbers may be hidden then (U.IsSecret): the
    -- usable set is not re-read in combat, once when it ends instead.
    local function recheck() if InCombatLockdown and InCombatLockdown() then return end T.Recheck() end
    local function soon() if NS.Throttle then NS:Throttle("teleports", 1, recheck) else recheck() end end
    NS:RegisterEvent("PLAYER_REGEN_ENABLED", soon)
    for _, ev in ipairs({ "SPELLS_CHANGED", "LEARNED_SPELL_IN_TAB", "BAG_UPDATE_DELAYED", "PLAYER_EQUIPMENT_CHANGED", "NEW_TOY_ADDED",
                          "TOYS_UPDATED", "SPELL_UPDATE_COOLDOWN", "BAG_UPDATE_COOLDOWN", "PLAYER_LEVEL_UP", "SKILL_LINES_CHANGED" }) do
        NS:RegisterEvent(ev, soon)
    end
    -- Core/Professions.lua fires this once its snapshot is fresh (a profession learned or dropped: `profession` entries)
    if NS.On then NS:On("PROFESSIONS_CHANGED", soon) end
end

-- Learn where a teleport really lands: after the player casts one, the first big jump (Routing/TravelGraph.lua's jump
-- detector calls T.OnJump) that lands within 500 yd of the data point on its continent is stored and used from then on.
local pending
if NS.RegisterEvent then
    NS:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spellID)
        if unit ~= "player" or not spellID then return end
        local e = T.Candidates().bySpell[spellID]
        if e and not e.hearth then pending = { e = e, at = GetTime() } end
    end)
end
function T.OnJump(pos)
    local p = pending
    pending = nil
    if not (p and pos and pos.wx and GetTime() - p.at < 30 and NS.db and NS.db.global) then return false end
    local e = p.e
    if pos.inst ~= e.to[1] or dist(pos.wx, pos.wy, e.to[2], e.to[3]) > 500 then return false end
    NS.db.global.teleportFix = NS.db.global.teleportFix or {}
    NS.db.global.teleportFix[e.key] = { pos.inst, pos.wx, pos.wy }
    NS:Debug("Learned teleport landing: " .. e.key)
    return true
end

-- /cr teleports: what the router can use, and why not
function T.Report()
    local lines = {}
    local c = T.Candidates()
    local st = state()
    local usable = {}
    for _, u in ipairs(st.move) do usable[u.e.key] = u.how end
    for _, e in ipairs(c.move) do
        local how = usable[e.key]
        local s
        if not how then
            s = (e.kind == "spell") and "not known (or no reagent)"
                or (not professionOK(e) and ("needs " .. tostring(NS.Professions.SKILL_LINE[e.profession])))
                or "not owned / not usable"
        else
            local cd = T.Cooldown(e, how)
            s = how .. (cd > 0 and (", cooldown " .. U.FmtTime(cd)) or ", ready") .. (cd > T.MAX_COOLDOWN and " - not offered (over 15 min)" or "")
        end
        lines[#lines + 1] = ("%s -> %s: %s"):format(displayName(e), e.to[4] or "?", s)
    end
    lines[#lines + 1] = "Hearthstone stand-in: " .. (st.hearthId and (U.ItemName(st.hearthId) .. (st.hearthToy and " (toy)" or "")) or "none")
    return lines
end
