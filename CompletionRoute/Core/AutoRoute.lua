-- CompletionRoute :: Core/AutoRoute.lua
-- Category routing (owner spec 2026-11-27): the player picks a CATEGORY (Quests, Dungeons, Items, Professions,
-- Achievements, Legacy Points on WoW Forever) and the add-on routes to the closest thing this character has not done,
-- choosing again after every completion.  The registered guides are only data for the categories.
--
--   Quests        one quest at a time: its accept, objectives and turn-in, then the next closest quest.  Every quest of
--                 every quest/storyline/mission/leveling route counts (each quest id once); nothing is dropped for XP.
--   Dungeons      the closest level-fitting dungeon not done: every quest for it (lead-up chains included) one at a
--                 time, then the entrance and what is done inside, then the turn-ins.
--   Professions   the closest profession route that fits the character's skill (or an apprentice route).
--   Achievements  the closest undone achievement / criterion step (quest-based criteria one quest at a time).
--   Legacy Points the closest undone WoW Forever Legacy challenge.
--   Items         (owner 2026-11-28, replaces Gold) the closest item this character does not own yet, one item id per
--                 unit, from every route step that names an item (loot, buy, treasure, quest objective items, mount and
--                 pet routes).  Owned = in bags/bank, or the step that gets it is done.  Coverage is the items our
--                 community data gives a source for, not literally every item id in the game (docs/ITEMS.md).
--
-- Batch mode (owner 2026-11-28, A.BatchOn, the "Batch" box on the routes list, /cr batch): Quests / Achievements /
-- Legacy Points load the closest unit plus every other open unit in the player's zone or that unit's zone (up to
-- A.BATCH_MAX) as one route; accepts first, then objectives, then turn-ins, and the step optimizer orders them.
-- Dungeons always gather every quest first, batch or not.
--
-- Mechanism: one synthetic route per category ("auto:<cat>", in G.registry but not in G.list, so the advanced list never
-- shows it) whose steps are the steps of ONE unit.  When the unit has nothing left, Progress.Refresh calls A.Advance,
-- which picks the next unit and swaps the steps in.  Closest = Router.TravelSecondsFromPlayer (TravelGraph: walking,
-- flight paths, portals) to the unit's next step, after a straight-line shortlist.  Gating: faction / class / race /
-- profession / level and prerequisites through Cond.StepApplies (a quest is never offered before its prerequisite);
-- a quest already in the log and the follow-up of the quest just finished are preferred when close.
-- Per character: NS.db.char.auto (category, finished units, current dungeon).
-- Copyright (c) 2026 Daniel Bates / Bates LLC.  All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
local ADDON, NS = ...
local U, G, Cond = NS.Util, NS.Guide, NS.Cond
local A = {}
NS.Auto = A

A.ORDER = { "Quests", "Dungeons", "Items", "Professions", "Achievements", "Legacy Points" }
A.BATCH_MAX = 15
-- guide types that feed each category (Core/Guide.lua G.NormalizeType names)
A.SOURCES = {
    Quests = { Quests = true, Storylines = true, Missions = true, Leveling = true, Dailies = true, Reputation = true },
    Achievements = { Achievements = true },
    ["Legacy Points"] = { ["Legacy Points"] = true },
}
A.SHORTLIST = 6          -- units priced with the travel graph per pick
A.OTHER_INST = 2         -- of those, at most this many from other continents / instances
A.INLOG_BONUS = 60       -- seconds: a quest already accepted
A.FOLLOWUP_BONUS = 45    -- seconds: the follow-up of the quest just turned in
A.OFFSPINE_PENALTY = 900 -- seconds: a quest the leveling spine leaves out (events, raid drops) waits behind spine quests

local CAT_ALIAS = { quest = "Quests", quests = "Quests", q = "Quests", dungeon = "Dungeons", dungeons = "Dungeons", d = "Dungeons",
    items = "Items", item = "Items", i = "Items", prof = "Professions", profs = "Professions", profession = "Professions", professions = "Professions",
    ach = "Achievements", achievement = "Achievements", achievements = "Achievements", legacy = "Legacy Points",
    ["legacy points"] = "Legacy Points", lp = "Legacy Points" }
function A.Canon(s) return s and CAT_ALIAS[U.trim(tostring(s)):lower()] or nil end
local function autoId(cat) return "auto:" .. cat:lower():gsub("%s+", "-") end
A.AutoId = autoId

-- ---------------------------------------------------------------------------
-- Per-character state
-- ---------------------------------------------------------------------------
function A.Store()
    local c = NS.db.char
    c.auto = c.auto or {}
    local s = c.auto
    s.done = s.done or {}
    return s
end
local function doneSet(cat)
    local s = A.Store()
    s.done[cat] = s.done[cat] or {}
    return s.done[cat]
end
A.gen = 0                -- bumped on every unit finished (the "nothing to do" memo below keys on it)

-- ---------------------------------------------------------------------------
-- Units
-- ---------------------------------------------------------------------------
-- A unit: { key, cat, steps = { source step tables }, q = quest id or nil, guide = source guide, pre = { ids } }.
local QUEST_ACTION = { A = true, a = true, ["!"] = true, C = true, K = true, l = true, U = true, T = true, t = true }
local function guideApplies(g)
    return Cond.FactionMatch(g.faction) and (not g.class or Cond.ClassMatch(g.class)) and (not g.race or Cond.RaceMatch(g.race))
end
-- Group a step list into units: quest steps by their first quest id (each id once over the whole pool, `seen`), the other
-- steps one unit each when keepOther (achievement criteria, legacy challenges).
local function addUnits(out, seen, steps, g, cat, keepOther, keyPrefix)
    local byQ = {}
    for _, s in ipairs(steps) do
        local q = s.qid and s.qid[1]
        if q and QUEST_ACTION[s.action] then
            local u = byQ[q]
            if not u and not seen[q] then
                u = { key = (keyPrefix or "q") .. q, cat = cat, q = q, steps = {}, guide = g, pre = {} }
                byQ[q], seen[q] = u, true
                out[#out + 1] = u
            end
            if u then
                u.steps[#u.steps + 1] = s
                for _, p in ipairs(s.pre or {}) do u.pre[#u.pre + 1] = p end
            end
        elseif keepOther and s.action ~= "h" and (s.ach or s.coords or s.zone or s.title) then
            -- an achievement criterion is one item however many routes list it
            local k = s.ach and ("a" .. s.ach .. "/" .. tostring(s.achCrit or 0))
                or ((keyPrefix or "s") .. tostring(g.id) .. "/" .. tostring(s.key or s.index))
            if not seen[k] then
                seen[k] = true
                out[#out + 1] = { key = k, cat = cat, steps = { s }, guide = g, pre = {} }
            end
        end
    end
end

local pools = {}         -- [cat] = { units, who }
NS:On("GUIDE_REGISTERED", function() pools = {} end)
function A.Invalidate() pools = {} end
local function who() return tostring(NS.player and NS.player.faction) .. tostring(NS.player and NS.player.class) .. tostring(NS.player and NS.player.race) end

-- The quest / achievement / legacy pool, built once per session and character (parses every source guide once).
function A.Pool(cat)
    local p = pools[cat]
    if p and p.who == who() then return p.units end
    if cat == "Items" then
        local units = A.ItemUnits()
        pools[cat] = { units = units, who = who() }
        return units
    end
    local src = A.SOURCES[cat]
    if not src then return {} end
    local units, seen = {}, {}
    -- quest-route guides first (they are where a quest's own points live), the leveling spine after (same quests)
    local list = {}
    for _, id in ipairs(G.list) do
        local g = G.registry[id]
        if g and not g.auto and src[g.type] and guideApplies(g) then list[#list + 1] = g end
    end
    local rank = { Quests = 1, Storylines = 2, Missions = 3, Dailies = 4, Reputation = 5, Leveling = 6 }
    table.sort(list, function(a, b)
        local ra, rb = rank[a.type] or 0, rank[b.type] or 0
        if ra ~= rb then return ra < rb end
        return tostring(a.id) < tostring(b.id)
    end)
    -- the leveling spine places each quest at a level band: the planning level of quests the wiki gives no level for
    local spineLvl = {}
    for _, g in ipairs(list) do
        if g.type == "Leveling" and g.minlevel then
            local ok, steps = pcall(G.Steps, g.id)
            for _, s in ipairs(ok and steps or {}) do
                local q = s.qid and s.qid[1]
                if q and (not spineLvl[q] or g.minlevel < spineLvl[q]) then spineLvl[q] = g.minlevel end
            end
        end
    end
    local hasSpine = next(spineLvl) ~= nil
    for _, g in ipairs(list) do
        local ok, steps = pcall(G.Steps, g.id)
        if ok and steps then addUnits(units, seen, steps, g, cat, cat ~= "Quests") end
    end
    for _, u in ipairs(units) do
        local lvl, located = nil, false
        for _, s in ipairs(u.steps) do
            if s.minlevel and (not lvl or s.minlevel > lvl) then lvl = s.minlevel end
            if s.coords and not s.zoneInherited then located = true end
        end
        u.lvlExact = lvl ~= nil
        if u.q and not lvl then lvl = spineLvl[u.q] end
        if not lvl then
            -- no level anywhere: a quest with no point of its own (item drops in raids, events) at the top of its
            -- route's range, else the bottom of it
            lvl = located and tonumber(u.guide.minlevel) or tonumber(u.guide.maxlevel) or tonumber(u.guide.minlevel)
        end
        u.lvl = lvl
        -- quests the leveling spine leaves out (holiday events, raid drops, odd one-offs) come after the spine's
        -- quests at the same distance: they are still offered, never dropped
        if hasSpine and u.q and not spineLvl[u.q] then u.offSpine = true end
    end
    pools[cat] = { units = units, who = who() }
    return units
end

-- ---------------------------------------------------------------------------
-- State of a unit for this character
-- ---------------------------------------------------------------------------
local P
local function stepDone(s)
    if P.IsDone(s) then return true end
    local ok, v = pcall(P.CheckStep, s)
    return ok and v or false
end
-- "done" | "blocked" (something left, nothing this character can do now) | first pending step
function A.UnitState(u)
    if u.batch then
        for _, b in ipairs(u.batch) do
            local st = A.UnitState(b)
            if st ~= "done" and st ~= "blocked" then
                for _, s in ipairs(u.steps) do if not stepDone(s) and Cond.StepApplies(s) then return s end end
                return st
            end
        end
        return "done"
    end
    if u.item and U.ItemCount(u.item) > 0 then return "done" end
    if u.q and U.IsQuestComplete(u.q) then return "done" end
    if NS.Skip and u.q and NS.Skip.IsRemoved(u.q) then return "done" end
    if doneSet(u.cat)[u.key] then return "done" end
    -- cheap level gate first (most of a big pool waits for level): an estimated level is coarse, two levels early is fine
    if u.lvl and U.PlayerLevel() < u.lvl - (u.lvlExact and 0 or 2) and not (u.q and U.IsOnQuest(u.q)) then return "blocked" end
    local left = false
    for _, s in ipairs(u.steps) do
        if not stepDone(s) then
            left = true
            if not Cond.StepApplies(s) then return "blocked" end
            return s
        end
    end
    if not left then return "done" end
    return "blocked"
end

-- straight-line yards from the player (same continent / instance), or nil
local function lineYards(s, pinst, pwx, pwy)
    local w = s._aw
    if w == nil and s.zoneInherited and not s.coords then w = false s._aw = w end
    if w == nil then
        local ok, wx, wy, wi = pcall(NS.Router.StepWorld, s)
        w = (ok and wx) and { wx, wy, wi } or false
        s._aw = w
    end
    if not w then return nil, nil end
    if w[3] ~= pinst or not pwx then return nil, true end
    return math.sqrt((w[1] - pwx) ^ 2 + (w[2] - pwy) ^ 2), true
end

-- Pick the closest available unit of a list.  Returns unit, first pending step, travel seconds, counts.
function A.PickClosest(units, opts)
    opts = opts or {}
    local _, _, _, pinst, pwx, pwy = U.PlayerPos()
    local near, far, unlocated = {}, {}, {}
    local nAvail, nBlocked, nDone = 0, 0, 0
    local last = A.Store().lastQuest
    local dead = 0
    for _, u in ipairs(units) do
        local st = u.dead and "done" or A.UnitState(u)
        if st == "done" then
            nDone = nDone + 1
            if not u.dead and not opts.keep then u.dead = true end
            dead = dead + 1
        elseif st == "blocked" then nBlocked = nBlocked + 1
        else
            nAvail = nAvail + 1
            local d, located = lineYards(st, pinst, pwx, pwy)
            local bonus = u.offSpine and -A.OFFSPINE_PENALTY or 0
            if u.q and U.IsOnQuest(u.q) then bonus = bonus + A.INLOG_BONUS end
            if last then for _, p in ipairs(u.pre) do if p == last then bonus = bonus + A.FOLLOWUP_BONUS break end end end
            local e = { u = u, s = st, d = d, bonus = bonus }
            if d then near[#near + 1] = e elseif located then far[#far + 1] = e else unlocated[#unlocated + 1] = e end
        end
    end
    local counts = { available = nAvail, blocked = nBlocked, done = nDone, total = #units }
    -- finished units leave the list for good (done never comes undone for a character in a session): later picks
    -- scan only what is left
    if dead > 64 and not opts.keep then
        local j = 0
        for i = 1, #units do local u = units[i] if not u.dead then j = j + 1 units[j] = u end end
        for i = #units, j + 1, -1 do units[i] = nil end
        A.prunedDone = (A.prunedDone or 0) + dead
        counts.total = counts.total     -- totals of this pick are unchanged
    end
    if nAvail == 0 then return nil, nil, nil, counts end
    table.sort(near, function(a, b) return a.d - a.bonus * 7 < b.d - b.bonus * 7 end)   -- ~7 yd per second of travel
    local short = {}
    for i = 1, math.min(#near, A.SHORTLIST) do short[#short + 1] = near[i] end
    -- other continents: the lowest-level ones (the closest the straight line cannot tell), a few only
    table.sort(far, function(a, b)
        local la, lb = a.s.minlevel or 0, b.s.minlevel or 0
        if la ~= lb then return la < lb end
        return a.u.key < b.u.key
    end)
    for i = 1, math.min(#far, #short >= A.SHORTLIST and A.OTHER_INST or (A.SHORTLIST - #short + A.OTHER_INST)) do short[#short + 1] = far[i] end
    local best, bestScore, bestSecs
    for _, e in ipairs(short) do
        local ok, secs = pcall(NS.Router.TravelSecondsFromPlayer, e.s)
        if not (ok and secs) then secs = e.d and (e.d / 7) or 1e6 end
        local score = secs - e.bonus
        if not bestScore or score < bestScore then best, bestScore, bestSecs = e, score, secs end
    end
    if not best then
        -- nothing located: the first one in data order (a counter, a note the player does where they stand)
        table.sort(unlocated, function(a, b) return a.u.key < b.u.key end)
        best = unlocated[1]
    end
    return best.u, best.s, bestSecs, counts
end

-- ---------------------------------------------------------------------------
-- Guide-level categories (Dungeons, Professions)
-- ---------------------------------------------------------------------------
local function guideCands(cat, filter)
    local R = NS.Recommend
    local out = {}
    local done = doneSet(cat)
    for _, e in ipairs(R.ForLevel(U.PlayerLevel(), { category = cat, fitOnly = true })) do
        if not done[e.g.id] and not e.g.empty and (not filter or filter(e)) then out[#out + 1] = e end
    end
    return out
end
local function guideStartStep(g)
    for _, s in ipairs(G.Steps(g.id) or {}) do if (s.coords or s.zone) and s.action ~= "h" then return s end end
end
local function travelTo(s)
    if not s then return nil end
    local ok, v = pcall(NS.Router.TravelSecondsFromPlayer, s)
    return ok and v or nil
end

-- A dungeon's units: its quests before the entrance, one unit each, then everything from the entrance on as one unit.
local dungeonUnits = {}
function A.DungeonUnits(g)
    local c = dungeonUnits[g.id]
    if c then return c end
    local steps = G.Steps(g.id) or {}
    local enter
    for _, s in ipairs(steps) do if s.action == "D" and (not enter or s.index < enter) then enter = s.index end end
    local pre, rest = {}, {}
    local byIndex = {}
    for _, s in ipairs(steps) do byIndex[#byIndex + 1] = s end
    table.sort(byIndex, function(a, b) return a.index < b.index end)
    for _, s in ipairs(byIndex) do
        if enter and s.index >= enter then rest[#rest + 1] = s else pre[#pre + 1] = s end
    end
    local units = {}
    addUnits(units, {}, pre, g, "Dungeons", false, "d" .. g.id .. "/q")
    local inside
    if #rest > 0 then inside = { key = "d" .. g.id .. "/run", cat = "Dungeons", steps = rest, guide = g, pre = {}, inside = true } end
    c = { gather = units, inside = inside }
    dungeonUnits[g.id] = c
    return c
end

-- the next dungeon unit: the current dungeon's quests, closest first, then its run; then the next dungeon
local function nextDungeon()
    local st = A.Store()
    for _ = 1, 50 do
        local g = st.dungeon and G.registry[st.dungeon]
        if not g then
            -- choose: level-fitting, undone, 5-player before raids, closest entrance (shortlist by the level centre)
            local cands = guideCands("Dungeons")
            local lv = U.PlayerLevel()
            table.sort(cands, function(a, b)
                local ra, rb = a.g.instance == "Raid" and 1 or 0, b.g.instance == "Raid" and 1 or 0
                if ra ~= rb then return ra < rb end
                local ma = math.abs(((a.g.minlevel or lv) + (a.g.maxlevel or a.g.minlevel or lv)) / 2 - lv)
                local mb = math.abs(((b.g.minlevel or lv) + (b.g.maxlevel or b.g.minlevel or lv)) / 2 - lv)
                if ma ~= mb then return ma < mb end
                return tostring(a.g.id) < tostring(b.g.id)
            end)
            local best, bestSecs
            for i = 1, math.min(#cands, 6) do
                local e = cands[i]
                local du = A.DungeonUnits(e.g)
                local s = du.inside and du.inside.steps[1] or guideStartStep(e.g)
                local secs = travelTo(s) or 1e6
                if e.g.instance == "Raid" then secs = secs + 1e7 end
                if not bestSecs or secs < bestSecs then best, bestSecs = e.g, secs end
            end
            if not best then return nil end
            st.dungeon = best.id
            g = best
            NS:Print(("Dungeons: %s next - collecting its quests first."):format(G.DisplayName(g)))
        end
        local du = A.DungeonUnits(g)
        local u, s = A.PickClosest(du.gather)
        if u then return u, s end
        if du.inside then
            local ist = A.UnitState(du.inside)
            if ist ~= "done" and ist ~= "blocked" then return du.inside, ist end
            if ist == "blocked" then
                -- what is left inside is gated (level): move on for this sitting, the dungeon comes back later
                -- (a "blocked" mark is cleared by the next A.Start; it must never be recorded as done)
                doneSet("Dungeons")[g.id] = "blocked"
                st.dungeon = nil
            else
                doneSet("Dungeons")[g.id] = true
                st.dungeon = nil
            end
        else
            doneSet("Dungeons")[g.id] = true
            st.dungeon = nil
        end
    end
end

local function guideUnit(cat, g)
    return { key = "g" .. g.id, cat = cat, steps = G.Steps(g.id) or {}, guide = g, pre = {}, whole = true }
end
local function nextProfession()
    local cands = guideCands("Professions", function(e) return e.reqRank ~= 0 end)
    -- learned professions first (their next band), apprentice bands of unlearned ones after
    table.sort(cands, function(a, b) return a.score > b.score end)
    local best, bestSecs
    for i = 1, math.min(#cands, A.SHORTLIST) do
        local u = guideUnit("Professions", cands[i].g)
        local st = A.UnitState(u)
        if st == "done" then doneSet("Professions")[u.key] = true
        elseif st ~= "blocked" then
            local secs = (travelTo(st) or 1e6) - (cands[i].learned and 600 or 0)
            if not bestSecs or secs < bestSecs then best, bestSecs = { u, st }, secs end
        end
    end
    if best then return best[1], best[2] end
end

-- ---------------------------------------------------------------------------
-- Items
-- ---------------------------------------------------------------------------
local ITEM_ACTION = { l = true, B = true, ["$"] = true, K = true, C = true, U = true, A = true, T = true, t = true }
local function stepItems(s)
    local out = {}
    for _, l in ipairs(s.loot or s.L or {}) do local id = tonumber(type(l) == "table" and (l.id or l[1]) or l) if id then out[#out + 1] = id end end
    local u = tonumber(s.item or s.useItem or s.U)
    if u and s.action == "B" then out[#out + 1] = u end
    return out
end
A.StepItems = stepItems
-- one unit per item id over every applicable route; a quest-bound item brings its whole quest (accept .. turn-in)
function A.ItemUnits()
    local units, seen = {}, {}
    for _, id in ipairs(G.list) do
        local g = G.registry[id]
        if g and not g.auto and g.type ~= "Gold" and guideApplies(g) then
            local ok, steps = pcall(G.Steps, g.id)
            if ok and steps then
                local byQ
                for _, s in ipairs(steps) do
                    if ITEM_ACTION[s.action] then
                        for _, item in ipairs(stepItems(s)) do
                            if not seen[item] then
                                seen[item] = true
                                local q = s.qid and s.qid[1]
                                local us = { s }
                                if q then
                                    if not byQ then
                                        byQ = {}
                                        for _, t in ipairs(steps) do
                                            local tq = t.qid and t.qid[1]
                                            if tq and QUEST_ACTION[t.action] then byQ[tq] = byQ[tq] or {} table.insert(byQ[tq], t) end
                                        end
                                    end
                                    us = byQ[q] or us
                                end
                                units[#units + 1] = { key = "i" .. item, cat = "Items", item = item, q = q, steps = us, guide = g, pre = {},
                                    lvl = s.minlevel or tonumber(g.minlevel) }
                            end
                        end
                    end
                end
            end
        end
    end
    return units
end

-- ---------------------------------------------------------------------------
-- Batch mode
-- ---------------------------------------------------------------------------
function A.BatchOn() return NS.db and NS.db.profile and NS.db.profile.autoBatch == true or false end
function A.SetBatch(on)
    NS.db.profile.autoBatch = on and true or false
    NS:Print("Batch mode " .. (on and "on: nearby quests in your zone are taken together." or "off: one at a time."))
    local g = NS.Progress and NS.Progress.guide
    if g and g.auto and g.unit then A.current, g.unit = nil, nil A.Advance() end
end
local PHASE = { A = 1, a = 1, ["!"] = 1, T = 3, t = 3 }
-- the picked unit plus the other open units of the same zone (the player's, or the picked step's destination)
function A.MakeBatch(units, first, firstStep)
    local pzone = U.PlayerPos()
    local zones = { [firstStep.zone or -1] = true }
    if pzone then zones[pzone] = true end
    local members = { first }
    for _, u in ipairs(units) do
        if #members >= A.BATCH_MAX then break end
        if u ~= first and not u.dead and not u.batch then
            local st = A.UnitState(u)
            if type(st) == "table" and st.zone and zones[st.zone] then members[#members + 1] = u end
        end
    end
    if #members == 1 then return first end
    local steps = {}
    for _, u in ipairs(members) do for _, s in ipairs(u.steps) do steps[#steps + 1] = { s = s, ph = PHASE[s.action] or 2, n = #steps } end end
    table.sort(steps, function(a, b) if a.ph ~= b.ph then return a.ph < b.ph end return a.n < b.n end)
    local flat = {}
    for i, e in ipairs(steps) do flat[i] = e.s end
    return { key = "batch:" .. first.key, cat = first.cat, steps = flat, guide = first.guide, pre = {}, batch = members }
end

-- ---------------------------------------------------------------------------
-- The synthetic routes and the swap
-- ---------------------------------------------------------------------------
function A.Categories()
    local out = {}
    for _, cat in ipairs(A.ORDER) do
        local have = false
        if cat == "Legacy Points" then have = NS.isForever and A.HasType("Legacy Points")
        elseif cat == "Achievements" then have = A.HasType("Achievements")
        elseif cat == "Quests" or cat == "Items" then have = true
        else have = A.HasType(cat) end
        if have then out[#out + 1] = cat end
    end
    return out
end
function A.HasType(t)
    for _, id in ipairs(G.list) do local g = G.registry[id] if g and g.type == t and not g.empty then return true end end
    return false
end

local function ensureGuide(cat)
    local id = autoId(cat)
    local g = G.registry[id]
    if not g then
        g = { id = id, name = cat, type = cat, auto = cat, source = "CompletionRoute", author = "Completionist's Guide", steps = {} }
        G.registry[id] = g      -- not in G.list: the routes list never shows it
    end
    return g
end
for _, cat in ipairs(A.ORDER) do ensureGuide(cat) end

local function copySteps(u, g)
    local out = {}
    for _, s in ipairs(u.steps) do
        local c = {}
        for k, v in pairs(s) do c[k] = v end
        c.guide, c.index, c._aw = g.id, #out + 1, nil
        c.srcGuide = s.guide
        out[#out + 1] = c
    end
    return out
end

local function setUnit(g, u)
    A.current = u
    local steps = u and copySteps(u, g) or {}
    g.steps = steps
    g.unit = u
    if P.guide == g then
        P.steps, P.baseSteps = steps, steps
        P.cursor, P.prefilled, P.current, P.order = nil, nil, nil, nil
        if NS.StepOrder and NS.StepOrder.Reset then NS.StepOrder.Reset() end
    end
end

local exhausted = {}
local function finishUnit(u)
    if not u then return end
    if u.batch then for _, b in ipairs(u.batch) do if A.UnitState(b) == "done" then finishUnit(b) end end A.gen = A.gen + 1 return end
    doneSet(u.cat)[u.key] = true
    if u.q then A.Store().lastQuest = u.q end
    A.gen = A.gen + 1
    NS:Fire("AUTO_UNIT_DONE", u)
end

-- Pick and load the next unit of the loaded category.  Called by Progress.Refresh when the loaded unit has no step.
-- Returns true when a unit with a step is loaded.
function A.Advance()
    P = P or NS.Progress
    local g = P.guide
    if not (g and g.auto) then return false end
    local cat = g.auto
    local memo = U.PlayerLevel() .. ":" .. tostring(NS.Account and NS.Account.questGen or 0) .. ":" .. A.gen
    if g.unit and A.UnitState(g.unit) == "done" then finishUnit(g.unit) memo = nil end
    if memo and exhausted[cat] == memo then return false end
    for _ = 1, 200 do
        local u, s, secs, counts
        if cat == "Dungeons" then u, s = nextDungeon()
        elseif cat == "Professions" then u, s = nextProfession()
        else
            local pool = A.Pool(cat)
            u, s, secs, counts = A.PickClosest(pool)
            if u and cat ~= "Items" and A.BatchOn() then u = A.MakeBatch(pool, u, s) end
        end
        A.lastCounts = counts
        if not u then
            setUnit(g, nil)
            exhausted[cat] = U.PlayerLevel() .. ":" .. tostring(NS.Account and NS.Account.questGen or 0) .. ":" .. A.gen
            local wait = counts and counts.blocked or 0
            NS:Print(("%s: nothing left you can do right now%s."):format(cat,
                wait > 0 and (" (%d more open up with level or prerequisites)"):format(wait) or ""))
            return false
        end
        setUnit(g, u)
        P.inAuto = true
        local ok, err = pcall(P.Refresh)
        P.inAuto = nil
        if not ok then NS:Error("category route: " .. tostring(err)) return false end
        if P.current then
            NS:Fire("AUTO_UNIT", u, secs)
            return true
        end
        -- everything in it was already done (or not doable after all): note it and pick again
        if A.UnitState(u) == "done" then finishUnit(u)
        elseif u.batch then for _, b in ipairs(u.batch) do doneSet(cat)[b.key] = "blocked" end A.gen = A.gen + 1
        else doneSet(cat)[u.key] = "blocked" A.gen = A.gen + 1 end
    end
    return false
end

-- Start a category for this character (the routes list, /cr category, the login).
function A.Start(cat)
    P = P or NS.Progress
    cat = A.Canon(cat) or cat
    local known = false
    for _, c in ipairs(A.Categories()) do if c == cat then known = true end end
    if not known then NS:Error("No such category here: " .. tostring(cat)) return false end
    local st = A.Store()
    st.cat = cat
    -- blocked marks are only for one sitting: a new start looks at everything again
    for k, v in pairs(doneSet(cat)) do if v == "blocked" then doneSet(cat)[k] = nil end end
    exhausted[cat] = nil
    local g = ensureGuide(cat)
    setUnit(g, nil)
    return P.Load(g.id, { picked = true })
end

-- What the UI shows under the category name
function A.Describe(cat)
    if cat == "Items" then return "closest item you do not own" end
    if cat == "Dungeons" then local d = A.Store().dungeon return d and G.registry[d] and ("now: " .. G.DisplayName(G.registry[d])) or "closest level-fitting dungeon" end
    if cat == "Professions" then return "next band of your professions" end
    return A.BatchOn() and "batch: nearby together" or "closest undone first"
end
function A.Active() local g = NS.Progress and NS.Progress.guide return g and g.auto or nil end
