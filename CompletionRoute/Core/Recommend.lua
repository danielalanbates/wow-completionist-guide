-- CompletionRoute :: Core/Recommend.lua
-- Smart guide recommendations and level-based listing.
-- Copyright (c) 2026 Daniel Bates / Bates LLC.  All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- Ranking runs on registration fields only (never on guide steps: a retail install has thousands of guides and the
-- menu rebuilds on every keystroke) and is cached per level.  The order, best first:
--   1. the guide fits this level (profession guides: fits the character's skill)
--   2. not finished yet (finished guides stay listed but sink)
--   3. the character has what the guide needs (Gold "requires", a learned profession) before those it lacks
--   4. a guide already started, then the tighter bracket, then the bracket entered most recently
-- Guides the character has outgrown or cannot do yet are left out; guides with no level data list after the fits.
local ADDON, NS = ...
local U, G, Cond = NS.Util, NS.Guide, NS.Cond
local R = {}
NS.Recommend = R

R.CATEGORIES = { "Leveling", "Quests", "Dungeons", "Gold", "Professions", "Dailies", "Reputation" }
R.PICKS = 6
local CACHED_LEVELS = 6       -- a full ranked list per level is not small: only keep the few the player is looking at

local CAT_ALIAS = { leveling = "Leveling", level = "Leveling", quest = "Quests", quests = "Quests", dungeon = "Dungeons", dungeons = "Dungeons",
    dun = "Dungeons", gold = "Gold", prof = "Professions", profs = "Professions", profession = "Professions", professions = "Professions",
    daily = "Dailies", dailies = "Dailies", rep = "Reputation", reputation = "Reputation", reputations = "Reputation" }
function R.CanonCategory(s) return s and CAT_ALIAS[U.trim(s):lower()] or nil end

-- ---------------------------------------------------------------------------
-- Levels and bands
-- ---------------------------------------------------------------------------
local FLAVOR_CAP = { era = 60, tbc = 70, wrath = 80, cata = 85, mop = 90 }
local function callNumber(fn)
    if type(fn) ~= "function" then return nil end
    local ok, v = pcall(fn)
    return ok and type(v) == "number" and v > 0 and v or nil
end
-- The client's cap.  Classic GetMaxPlayerLevel can lag an expansion behind, so it can raise the flavor's own cap but
-- not lower it; retail has no fixed table and asks the owned-expansion API first (wiki: GetMaxLevelForPlayerExpansion).
function R.LevelCap()
    local cap = FLAVOR_CAP[NS.flavor]
    local fromClient = callNumber(GetMaxLevelForPlayerExpansion) or callNumber(GetMaxPlayerLevel)
    if cap then return math.max(cap, fromClient or 0) end
    return fromClient or 90
end

local function clampLevel(level)
    level = math.floor(tonumber(level) or U.PlayerLevel() or 1)
    local cap = R.LevelCap()
    if level > cap then level = cap end
    if level < 1 then level = 1 end
    return level
end
R.ClampLevel = clampLevel

local function bandLabel(low, high) return low == high and tostring(low) or (low .. "-" .. high) end
-- low, high, label of the 1-9 / 10-19 / ... band holding this level
local function bandOf(level)
    local cap = R.LevelCap()
    if level > cap then level = cap end
    if level < 1 then level = 1 end
    local low = math.floor(level / 10) * 10
    local high
    if low < 1 then low, high = 1, math.min(9, cap) else high = math.min(low + 9, cap) end
    return low, high, bandLabel(low, high)
end
R.BandOf = bandOf

function R.Bands()
    local out, cap = {}, R.LevelCap()
    local lv = 1
    while lv <= cap do
        local low, high, label = bandOf(lv)
        out[#out + 1] = { min = low, max = high, label = label }
        lv = high + 1
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Per-guide facts, computed once from registration fields
-- ---------------------------------------------------------------------------
local infos = {}

-- Only where the guide's own name states a level range, and never for profession or gold guides (those numbers are skill).
local NAME_RANGE_TYPES = { Leveling = true, Quests = true, Dungeons = true, Reputation = true, Dailies = true }
local function nameRange(g)
    if not NAME_RANGE_TYPES[g.type or ""] then return nil end
    local name = g.name or ""
    local a, b = name:match("%(%s*(%d+)%s*%-%s*(%d+)%s*%)")
    if not a then a, b = name:match("(%d+)%s*%-%s*(%d+)%s*$") end
    a, b = tonumber(a), tonumber(b)
    if a and b and a >= 1 and b >= a and b <= 150 then return a, b end
    return nil
end

local function profFromName(g)
    local prefix = (g.name or ""):match("^[%a ]+")
    if not prefix then return nil end
    for _, n in ipairs(NS.Professions and NS.Professions.NAMES or {}) do
        if prefix:lower():sub(1, #n) == n:lower() then return n end
    end
    return nil
end

local function infoFor(g)
    local who = NS.player and (tostring(NS.player.faction) .. tostring(NS.player.class) .. tostring(NS.player.race)) or ""
    local inf = infos[g.id]
    if inf and inf.g == g and inf.who == who then return inf end
    inf = { g = g, who = who, cat = G.NormalizeType(g.type) }
    local mn, mx = tonumber(g.minlevel), tonumber(g.maxlevel)
    if not mn and not mx then mn, mx = nameRange(g) end
    inf.min, inf.max = mn, mx
    inf.prof = g.prof
    if not inf.prof and inf.cat == "Professions" then inf.prof = profFromName(g) end
    inf.skillMin, inf.skillMax = tonumber(g.skillMin), tonumber(g.skillMax)
    if g.requires and NS.Professions then inf.reqName, inf.reqNeed = NS.Professions.ParseSpec(g.requires) end
    if inf.prof and (inf.skillMin or inf.skillMax) then
        inf.label = ("[skill %d-%d]"):format(inf.skillMin or 1, inf.skillMax or (inf.skillMin or 1))
    elseif mn and mx then inf.label = "[" .. bandLabel(mn, mx) .. "]"
    elseif mn then inf.label = "[" .. mn .. "+]"
    elseif mx then inf.label = "[1-" .. mx .. "]"
    else inf.label = "" end
    inf.applies = Cond.FactionMatch(g.faction) and (not g.class or Cond.ClassMatch(g.class)) and (not g.race or Cond.RaceMatch(g.race))
    infos[g.id] = inf
    return inf
end

-- "[10-20]", "[skill 1-75]", "[15+]" or "" (no level data).  For rows.
function R.GuideLabel(g) return g and infoFor(g).label or "" end

-- ---------------------------------------------------------------------------
-- Scoring
-- ---------------------------------------------------------------------------
local function finishedFromCache(g)
    if g.loop or not (NS.Account and NS.Account.doneCache) then return false end
    local dc = NS.Account.doneCache[NS.Account.Scope()]
    return (dc and dc[g.id] == true) or false
end
local function started(g)
    local me = NS.Account and NS.Account.me
    local d = me and me.done and me.done[g.id]
    return d ~= nil and next(d) ~= nil
end

local function evaluate(g, inf, level)
    if inf.min and level < inf.min then return nil end   -- cannot do it yet
    if inf.max and level > inf.max then return nil end   -- outgrown
    local e = { g = g, cat = inf.cat }
    local Prof = NS.Professions
    if inf.prof and (inf.skillMin or inf.skillMax) then
        local firstBand = (inf.skillMin or 1) <= 1
        local rank, max
        if Prof then rank, max = Prof.Skill(inf.prof, g.tier) end
        if rank == nil then
            if not firstBand then return nil end   -- cannot read the skill: only the starting band is a safe offer
            e.fit, e.unknownSkill = true, true
        elseif rank < 1 then
            if not firstBand then return nil end   -- not learned: apprentice bands only
            e.fit, e.learned = true, false
        else
            if inf.skillMin and rank < inf.skillMin then return nil end
            if inf.skillMax and rank >= inf.skillMax then return nil end
            e.fit, e.learned, e.rank, e.rankMax = true, true, rank, max
        end
        e.width = (inf.skillMax or 1000) - (inf.skillMin or 1)
    elseif inf.min or inf.max then
        e.fit = true
        e.width = (inf.min and inf.max) and (inf.max - inf.min) or 120
    elseif inf.cat == "Gold" and g.loop then
        e.fit, e.width = true, 1000    -- a circuit nobody tagged with a level (a route you built yourself) is walkable at any level
    else
        e.fit, e.any = false, true
    end
    e.reqRank = 1
    if inf.reqName then
        local rank = Prof and Prof.Skill(inf.reqName)
        if rank and rank >= inf.reqNeed then e.reqRank = 2
        else
            e.reqRank = 0
            e.missing = ("%s %d"):format(inf.reqName, inf.reqNeed) .. (rank == nil and " (unknown)" or "")
        end
    end
    if e.learned then e.reqRank = 2 end
    e.finished = finishedFromCache(g)
    e.started = started(g)
    -- tiers, heaviest first: fit > unfinished > requirement > started > tight > recently entered
    local s = e.fit and 8000000 or 2000000
    if not e.finished then s = s + 1000000 end
    s = s + (e.reqRank == 2 and 400000 or e.reqRank == 1 and 200000 or 0)
    if e.started then s = s + 100000 end
    s = s + (1000 - math.min(e.width or 1000, 1000)) * 20
    if inf.min then s = s + math.max(0, 900 - (level - inf.min) * 9) end
    if g.source == "CompletionRoute" then s = s + 5 end
    e.score = s
    return e
end

-- ---------------------------------------------------------------------------
-- Per-level cache
-- ---------------------------------------------------------------------------
local byLevel, order, listN = {}, {}, -1
R.builds = 0     -- cache misses (tools/test_level_list.lua)

function R.Invalidate() byLevel, order = {}, {} end

local function byScore(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return (a.g.name or a.g.id) < (b.g.name or b.g.id)
end

local function ranked(level)
    if listN ~= #G.list then listN = #G.list R.Invalidate() end
    local c = byLevel[level]
    if c then return c end
    local list, fit, byId = {}, {}, {}
    for _, id in ipairs(G.list) do
        local g = G.registry[id]
        if g and not g.empty then
            local inf = infoFor(g)
            if inf.applies then
                local e = evaluate(g, inf, level)
                if e then
                    list[#list + 1] = e
                    byId[id] = e
                    if e.fit then fit[id] = true end
                end
            end
        end
    end
    table.sort(list, byScore)
    c = { list = list, fit = fit, byId = byId }
    byLevel[level] = c
    order[#order + 1] = level
    if #order > CACHED_LEVELS then byLevel[table.remove(order, 1)] = nil end
    R.builds = R.builds + 1
    return c
end

-- Ranked entries: { g, cat, fit, finished, score, missing = "Herbalism 75", any = no level data, learned, rank, unknownSkill ... }.
-- opts: { category = "Gold", fitOnly = true, unfinishedOnly = true, limit = n }.  With no opts the shared cached list comes
-- back: do not modify it.
function R.ForLevel(level, opts)
    local list = ranked(clampLevel(level)).list
    if not opts then return list end
    local out, cat = {}, opts.category and (R.CanonCategory(opts.category) or opts.category)
    for _, e in ipairs(list) do
        if (not cat or e.cat == cat) and (not opts.fitOnly or e.fit) and (not opts.unfinishedOnly or not e.finished) then
            out[#out + 1] = e
            if opts.limit and #out >= opts.limit then break end
        end
    end
    return out
end

-- [guide id] = true for everything that fits this level.  Shared table: read only.
function R.FitSet(level) return ranked(clampLevel(level)).fit end
function R.EntryFor(level, id) return ranked(clampLevel(level)).byId[id] end

-- Top guides per category for the "For level N" section: { { cat = "Leveling", entries = { ... } }, ... }.
function R.Picks(level, perCat)
    local c = ranked(clampLevel(level))
    perCat = perCat or R.PICKS
    if c.picks and c.picksN == perCat then return c.picks end
    local byCat = {}
    for _, e in ipairs(c.list) do
        if e.fit and not e.finished then
            local bucket = byCat[e.cat]
            if not bucket then bucket = {} byCat[e.cat] = bucket end
            if #bucket < perCat then bucket[#bucket + 1] = e end
        end
    end
    local out = {}
    for _, cat in ipairs(R.CATEGORIES) do
        if byCat[cat] then out[#out + 1] = { cat = cat, entries = byCat[cat] } end
    end
    c.picks, c.picksN = out, perCat
    return out
end

-- Which level band a guide is filed under when the list is grouped by level: a guide that fits the level being viewed is
-- filed under that level's band, so your band shows everything that fits you (that includes profession guides, which fit
-- by skill).  Anything else goes to the band it starts in, or nil = "Any level" when it has no level data.
function R.BandFor(g, level)
    local c = ranked(clampLevel(level))
    if c.fit[g.id] then return bandOf(clampLevel(level)) end
    local inf = infoFor(g)
    local start = inf.min or inf.max
    if not start or (inf.prof and (inf.skillMin or inf.skillMax)) then return nil end
    return bandOf(start)
end

-- Lines for the guide's tooltip.
function R.Describe(g, level)
    local inf, out = infoFor(g), {}
    level = clampLevel(level)
    if inf.prof and (inf.skillMin or inf.skillMax) then
        local rank, max
        if NS.Professions then rank, max = NS.Professions.Skill(inf.prof, g.tier) end
        out[#out + 1] = ("Skill: %s %d-%d"):format(inf.prof, inf.skillMin or 1, inf.skillMax or (inf.skillMin or 1))
        if rank == nil then out[#out + 1] = "Open the profession window so your skill can be read."
        elseif rank < 1 then out[#out + 1] = "You have not learned this profession yet."
        else out[#out + 1] = ("You: %d/%d"):format(rank, max or 0) end
    end
    if inf.min or inf.max then
        out[#out + 1] = "Level: " .. (inf.min and inf.max and bandLabel(inf.min, inf.max) or inf.min and (inf.min .. "+") or ("1-" .. inf.max))
    elseif not (inf.prof and (inf.skillMin or inf.skillMax)) then
        out[#out + 1] = "Level: any (this guide has no level data)"
    end
    if inf.reqName then
        local rank = NS.Professions and NS.Professions.Skill(inf.reqName)
        out[#out + 1] = ("Requires: %s %d (%s)"):format(inf.reqName, inf.reqNeed,
            rank == nil and "yours is unknown" or rank >= inf.reqNeed and "you have it" or ("you have " .. rank))
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Slash output (Core/Slash.lua dispatches)
-- ---------------------------------------------------------------------------
local function entryLine(e)
    local bits = { e.g.name or e.g.id }
    local label = infoFor(e.g).label
    if label ~= "" then bits[#bits + 1] = label end
    if e.g.loop then bits[#bits + 1] = "circuit" end
    if e.finished then bits[#bits + 1] = "finished" end
    if e.unknownSkill then bits[#bits + 1] = "open the profession window to read your skill" end
    if e.missing then bits[#bits + 1] = "needs " .. e.missing end
    return "  " .. table.concat(bits, "  ")
end

local function parseListArgs(rest)
    local level, words = nil, {}
    for w in tostring(rest or ""):gmatch("%S+") do
        if not level and tonumber(w) then level = tonumber(w) else words[#words + 1] = w end
    end
    return level, #words > 0 and table.concat(words, " ") or nil
end

function R.PrintList(rest)
    local level, word = parseListArgs(rest)
    level = clampLevel(level)
    local cat = word and R.CanonCategory(word)
    if word and not cat then
        NS:Print("Unknown category '" .. word .. "'. Use: " .. table.concat(R.CATEGORIES, ", ") .. ".")
        return
    end
    if cat then
        NS:Print(("%s for level %d:"):format(cat, level))
        local list = R.ForLevel(level, { category = cat, fitOnly = true, limit = 15 })
        if #list == 0 then NS:Print("  nothing for this level") end
        for _, e in ipairs(list) do NS:Print(entryLine(e)) end
        return
    end
    NS:Print(("Guides for level %d (/cr load <name>; /cr list %d <category> for more):"):format(level, level))
    local picks = R.Picks(level)
    if #picks == 0 then NS:Print("  nothing for this level") end
    for _, sec in ipairs(picks) do
        NS:Print(sec.cat .. ":")
        for _, e in ipairs(sec.entries) do NS:Print(entryLine(e)) end
    end
end

function R.PrintGold(rest)
    local level = clampLevel((parseListArgs(rest)))
    NS:Print(("Gold for level %d:"):format(level))
    local list = R.ForLevel(level, { category = "Gold", fitOnly = true, limit = 15 })
    if #list == 0 then NS:Print("  nothing for this level") end
    for _, e in ipairs(list) do NS:Print(entryLine(e)) end
end

function R.PrintProf()
    local Prof = NS.Professions
    if not Prof then NS:Print("Profession data is not available.") return end
    local list, partial = Prof.List()
    if #list == 0 then
        NS:Print(partial and "Expand the Skills pane so your professions can be read." or "No professions learned on this character.")
    end
    local level = clampLevel(nil)
    local entries = R.ForLevel(level, { category = "Professions", fitOnly = true })
    for _, p in ipairs(list) do
        local guide
        for _, e in ipairs(entries) do
            if infoFor(e.g).prof == p.key then guide = e break end
        end
        NS:Print(("%s %d/%d%s"):format(p.key, p.rank, p.max, guide and ("  ->  " .. (guide.g.name or guide.g.id)) or "  (no guide for this skill band)"))
    end
    if partial then NS:Print("Some skills are hidden: expand every header in the Skills pane to see them all.") end
end

-- a learned skill or recipe can change what fits; levels and the guide list key the cache on their own
NS:On("PROFESSIONS_CHANGED", R.Invalidate)
