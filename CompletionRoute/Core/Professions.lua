-- CompletionRoute :: Core/Professions.lua
-- Profession skill reading (secondary and primary professions), locale-safe, all clients.
-- Copyright (c) 2026 Daniel Bates / Bates LLC.  All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- Three API shapes, read through one snapshot (API facts from warcraft.wiki.gg API pages):
--   era / tbc:     GetNumSkillLines + GetSkillLineInfo(i): localized names, so a name is matched through the
--                  localized spell name of the profession (GetSpellInfo / C_Spell.GetSpellName).
--   mop / retail:  GetProfessions + GetProfessionInfo(tab): the skillLine return is language-independent.
--   retail tiers:  C_TradeSkillUI.GetProfessionInfoBySkillLineID(tierSkillLine), when it returns real data.
-- Forever is an era client on the modern code base, so both of the first two are tried and merged.
--
-- The three answers Skill() can give, and what they mean:
--   rank, max   the client told us
--   0, 0        the client answered and this character does not have it
--   nil         we cannot tell (no API, a collapsed skill header, or a retail tier not loaded yet).
-- nil never completes a step: Progress treats unknown as "not done".
local ADDON, NS = ...
local U = NS.Util
local Prof = {}
NS.Professions = Prof

Prof.NAMES = { "Alchemy", "Archaeology", "Blacksmithing", "Cooking", "Enchanting", "Engineering", "First Aid", "Fishing",
    "Herbalism", "Inscription", "Jewelcrafting", "Leatherworking", "Mining", "Skinning", "Tailoring" }
local CANON = {}
for _, n in ipairs(Prof.NAMES) do CANON[n:lower()] = n end

-- SkillLine ids (wiki: TradeSkillLineID; the 29xx block is WoW Forever's own copy of the same lines, DB2 SkillLine).
local SKILL_LINE = { [171] = "Alchemy", [794] = "Archaeology", [164] = "Blacksmithing", [185] = "Cooking", [333] = "Enchanting",
    [202] = "Engineering", [129] = "First Aid", [356] = "Fishing", [182] = "Herbalism", [773] = "Inscription", [755] = "Jewelcrafting",
    [165] = "Leatherworking", [186] = "Mining", [393] = "Skinning", [197] = "Tailoring",
    [2937] = "Alchemy", [2938] = "Blacksmithing", [2939] = "Cooking", [2940] = "Enchanting", [2941] = "Engineering", [2942] = "First Aid",
    [2943] = "Fishing", [2944] = "Herbalism", [2945] = "Leatherworking", [2946] = "Mining", [2947] = "Skinning", [2948] = "Tailoring" }
Prof.SKILL_LINE = SKILL_LINE

-- A spell carrying exactly the profession's name in the client's language (DB2 SpellName on era/tbc/forever).
-- Herbalism's trainer spell is "Herb Gathering" on era and tbc, so it needs 9134 there; on Forever 2366 is the one.
local NAME_SPELLS = { Alchemy = { 2259 }, Archaeology = { 78670 }, Blacksmithing = { 2018 }, Cooking = { 2550 }, Enchanting = { 7411 },
    Engineering = { 4036 }, ["First Aid"] = { 3273 }, Fishing = { 7620 }, Herbalism = { 9134, 2366 }, Inscription = { 45357 },
    Jewelcrafting = { 25229 }, Leatherworking = { 2108 }, Mining = { 2575 }, Skinning = { 8613 }, Tailoring = { 3908 } }
-- The few places where the skill line and the spell disagree in the client's own language (DB2 SkillLine vs SpellName,
-- era and tbc builds, all ten locales: esES, frFR and koKR differ; every other pair matches).
local SKILL_LINE_NAMES = { ["botánica"] = "Herbalism", ["marroquinería"] = "Leatherworking", ["desollar"] = "Skinning", ["costura"] = "Tailoring",
    ["ingénierie"] = "Engineering", ["secourisme"] = "First Aid", ["가죽 세공"] = "Leatherworking" }

-- Apprentice to Zen Master rank spells (DB2 SpellName, mop build), cap = 75 * rank.  Learning the next rank replaces the
-- previous one in the spellbook, so "knows rank 2" must read true after rank 3 has been learned.  Retail has tiers, not ranks.
local RANKS = {
    Alchemy = { 2259, 3101, 3464, 11611, 28596, 51304, 80731, 105206 },
    Archaeology = { 78670, 88961, 89718, 89719, 89720, 89721, 89722, 110393 },
    Blacksmithing = { 2018, 3100, 3538, 9785, 29844, 51300, 76666, 110396 },
    Cooking = { 2550, 3102, 3413, 18260, 33359, 51296, 88053, 104381 },
    Enchanting = { 7411, 7412, 7413, 13920, 28029, 51313, 74258, 110400 },
    Engineering = { 4036, 4037, 4038, 12656, 30350, 51306, 82774, 110403 },
    ["First Aid"] = { 3273, 3274, 7924, 10846, 27028, 45542, 74559, 110406 },
    Fishing = { 7620, 7731, 7732, 18248, 33095, 51294, 88868, 110410 },
    Herbalism = { 2366, 2368, 3570, 11993, 28695, 50300, 74519, 110413 },
    Inscription = { 45357, 45358, 45359, 45360, 45361, 45363, 86008, 110417 },
    Jewelcrafting = { 25229, 25230, 28894, 28895, 28897, 51311, 73318, 110420 },
    Leatherworking = { 2108, 3104, 3811, 10662, 32549, 51302, 81199, 110423 },
    Mining = { 2575, 2576, 3564, 10248, 29354, 50310, 74517, 102161 },
    Skinning = { 8613, 8617, 8618, 10768, 32678, 50305, 74522, 102216 },
    Tailoring = { 3908, 3909, 3910, 12180, 26790, 51309, 75156, 110426 },
}
local RANK_OF = {}   -- [spellID] = { name, cap }
for name, ids in pairs(RANKS) do for i, id in ipairs(ids) do RANK_OF[id] = { name, i * 75 } end end

-- ---------------------------------------------------------------------------
-- Names
-- ---------------------------------------------------------------------------
local function spellName(id)
    if C_Spell and C_Spell.GetSpellName then     -- GetSpellInfo was removed from retail in 11.0.2
        local ok, n = pcall(C_Spell.GetSpellName, id)
        if ok and type(n) == "string" then return n end
    end
    if GetSpellInfo then
        local ok, n = pcall(GetSpellInfo, id)
        if ok and type(n) == "string" then return n end
    end
    return nil
end
Prof.SpellName = spellName

local localMap, localBuilt = {}, false
local function buildLocal()
    if localBuilt then return end
    local any = false
    for eng, ids in pairs(NAME_SPELLS) do
        for _, id in ipairs(ids) do
            local n = spellName(id)
            if n then any = true localMap[n:lower()] = eng end
        end
    end
    for loc, eng in pairs(SKILL_LINE_NAMES) do localMap[loc] = eng end
    localBuilt = any   -- spell data not ready yet: try again on the next read
end

-- Canonical key: the English profession name when we recognise it, else the lowercased name as given.
local function keyFor(name)
    if not name then return nil end
    local l = U.trim(tostring(name)):lower()
    if CANON[l] then return CANON[l] end
    buildLocal()
    return localMap[l] or l
end
Prof.KeyFor = keyFor

-- "Herbalism;75", or the longer forms "Cooking;185;0+1;true" and "Tailoring;197" (name;skill line[;exp+level]).
-- Returns name, level needed.  The old reader took the second field as the level, so 185 meant "skill 185".
function Prof.ParseSpec(spec)
    local parts = {}
    for piece in (tostring(spec or "") .. ";"):gmatch("(.-);") do parts[#parts + 1] = U.trim(piece) end
    local name = parts[1]
    local second = tonumber(parts[2])
    if second and parts[3] and parts[3] ~= "" then
        return name, tonumber(parts[3]:match("%+(%d+)")) or tonumber(parts[3]) or 1
    end
    if second and SKILL_LINE[second] and SKILL_LINE[second] == keyFor(name) then return name, 1 end
    return name, second or 1
end

-- ---------------------------------------------------------------------------
-- Snapshot of what the character knows
-- ---------------------------------------------------------------------------
local TTL = 5     -- seconds: the events below invalidate it; this is only the backstop for a change nothing announced
local snap, snapAt = nil, 0

local function scan()
    local s = { by = {}, partial = false, api = false }
    if type(GetProfessions) == "function" and type(GetProfessionInfo) == "function" then
        -- mop returns six values, retail five; any of them can be nil, so never ipairs this list
        local ok, a, b, c, d, e, f = pcall(GetProfessions)
        if ok then
            s.api = true
            local tabs = { a, b, c, d, e, f }
            for i = 1, 6 do
                if tabs[i] then
                    local ok2, name, _, rank, max, _, _, skillLine = pcall(GetProfessionInfo, tabs[i])
                    if ok2 and name then
                        local key = SKILL_LINE[skillLine or 0] or keyFor(name)
                        s.by[key] = { rank = rank or 0, max = max or 0, name = name, key = key, skillLine = skillLine }
                    end
                end
            end
        end
    end
    if type(GetNumSkillLines) == "function" and type(GetSkillLineInfo) == "function" then
        local ok, n = pcall(GetNumSkillLines)
        if ok and type(n) == "number" and n > 0 then
            s.api = true
            for i = 1, n do
                local ok2, name, isHeader, isExpanded, rank, _, _, max = pcall(GetSkillLineInfo, i)
                if ok2 and name then
                    if isHeader then
                        -- the skills under a collapsed header are not in the list at all
                        if not isExpanded then s.partial = true end
                    else
                        local key = keyFor(name)
                        s.by[key] = s.by[key] or { rank = rank or 0, max = max or 0, name = name, key = key }
                    end
                end
            end
        end
    end
    return s
end

local function snapshot()
    local now = GetTime and GetTime() or 0
    if not snap or now - snapAt > TTL then snap, snapAt = scan(), now end
    return snap
end

function Prof.Invalidate() snap = nil end

-- ---------------------------------------------------------------------------
-- Retail expansion tiers (SkillLine ids such as 2545, wiki: TradeSkillLineID)
-- ---------------------------------------------------------------------------
local function tierStore()
    local c = NS.db and NS.db.char
    if not c then return nil end
    c.profTiers = c.profTiers or {}
    return c.profTiers
end
-- An unopened profession answers with maxSkillLevel 0, so only a real cap counts as data.
local function usable(info)
    return type(info) == "table" and type(info.skillLevel) == "number" and type(info.maxSkillLevel) == "number" and info.maxSkillLevel > 0
end
local function hasTierAPI() return C_TradeSkillUI and C_TradeSkillUI.GetProfessionInfoBySkillLineID ~= nil end
local function remember(tier, info)
    local store = tierStore()
    if store then store[tier] = { rank = info.skillLevel, max = info.maxSkillLevel } end
end
local function tierSkill(tier)
    if C_TradeSkillUI and C_TradeSkillUI.GetProfessionInfoBySkillLineID then
        local ok, info = pcall(C_TradeSkillUI.GetProfessionInfoBySkillLineID, tier)
        if ok and usable(info) then
            remember(tier, info)
            return info.skillLevel, info.maxSkillLevel
        end
    end
    local store = tierStore()
    local c = store and store[tier]
    if c and c.max and c.max > 0 then return c.rank, c.max end
    return nil
end

-- The window is open: everything Blizzard will show about this profession's tiers is available now.
local function readTiersFromWindow()
    if not C_TradeSkillUI then return end
    local fn = C_TradeSkillUI.GetChildProfessionInfos
    if not fn then return end
    local ok, infos = pcall(fn)
    if not ok or type(infos) ~= "table" then return end
    for _, info in ipairs(infos) do
        -- professionID is the tier's own id here only when a different parent is named alongside it
        local id = info.professionID
        if id and info.parentProfessionID and info.parentProfessionID ~= id and usable(info) then remember(id, info) end
    end
end

-- Classic clients never report a recipe through a window-free API, so remember the names the trade skill window lists.
-- Merge only: this event also fires while the window is filtered or folded, so a short list is not a shorter recipe book.
local function readRecipesFromWindow()
    local c = NS.db and NS.db.char
    if not c then return end
    c.recipes = c.recipes or {}
    if GetNumTradeSkills and GetTradeSkillInfo then
        local ok, n = pcall(GetNumTradeSkills)
        if ok and type(n) == "number" then
            for i = 1, n do
                local ok2, name, kind = pcall(GetTradeSkillInfo, i)
                if ok2 and name and kind ~= "header" and kind ~= "subheader" then c.recipes[name] = true end
            end
        end
    end
    if GetNumCrafts and GetCraftInfo then   -- Enchanting and Beast Training on the older clients
        local ok, n = pcall(GetNumCrafts)
        if ok and type(n) == "number" then
            for i = 1, n do
                local ok2, name, _, kind = pcall(GetCraftInfo, i)
                if ok2 and name and kind ~= "header" and kind ~= "subheader" then c.recipes[name] = true end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------
-- rank, max | 0, 0 (does not have it) | nil (cannot tell).  name = English profession name.
function Prof.Skill(name, tier)
    if not name then return nil end
    local s = snapshot()
    local e = s.by[keyFor(name)]
    if tier and hasTierAPI() then
        if s.api and not s.partial and not e then return 0, 0 end   -- the profession itself is gone: an old tier reading is stale
        return tierSkill(tier)
    end
    if e then return e.rank, e.max end
    if not s.api or s.partial then return nil end
    return 0, 0
end

-- true | false | nil (cannot tell)
function Prof.Knows(name)
    local s = snapshot()
    if s.by[keyFor(name)] then return true end
    if not s.api or s.partial then return nil end
    return false
end

-- Every profession the character has, for /cr prof.
function Prof.List()
    local s, out = snapshot(), {}
    for key, e in pairs(s.by) do
        if CANON[key:lower()] then out[#out + 1] = { key = key, name = e.name, rank = e.rank, max = e.max } end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out, s.partial
end

local function apiKnows(fn, id, ...)
    if not fn then return false end
    local ok, v = pcall(fn, id, ...)
    return ok and v and true or false
end

function Prof.KnowsSpell(spellID)
    spellID = tonumber(spellID)
    if not spellID then return false end
    if apiKnows(IsPlayerSpell, spellID) then return true end
    if C_SpellBook and apiKnows(C_SpellBook.IsSpellKnown, spellID) then return true end
    if apiKnows(IsSpellKnown, spellID) then return true end
    if C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo then
        local ok, info = pcall(C_TradeSkillUI.GetRecipeInfo, spellID)
        if ok and type(info) == "table" and info.learned then return true end
    end
    if NS.flavor ~= "retail" then
        local r = RANK_OF[spellID]
        if r then
            local _, max = Prof.Skill(r[1])
            if max and max >= r[2] then return true end
        end
    end
    local recipes = NS.db and NS.db.char and NS.db.char.recipes
    if recipes then
        local n = spellName(spellID)
        if n and recipes[n] then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Events.  NS:RegisterEvent pcalls Frame:RegisterEvent, so a client without one of these simply never fires it.
-- ---------------------------------------------------------------------------
local WINDOW_EVENT = { TRADE_SKILL_SHOW = true, TRADE_SKILL_UPDATE = true, TRADE_SKILL_LIST_UPDATE = true, TRADE_SKILL_DATA_SOURCE_CHANGED = true,
    CRAFT_SHOW = true, CRAFT_UPDATE = true }
local windowDirty = false
local function onChange(evt)
    Prof.Invalidate()
    if WINDOW_EVENT[evt] then windowDirty = true end
    -- A burst of crafting fires this many times a second, so the real work is coalesced.  The second Invalidate is
    -- deliberate: CHAT_MSG_SKILL can arrive just before the client's own numbers change.
    NS:Throttle("professions", 0.5, function()
        Prof.Invalidate()
        if windowDirty then
            windowDirty = false
            pcall(readTiersFromWindow)
            pcall(readRecipesFromWindow)
        end
        NS:Fire("PROFESSIONS_CHANGED")
    end)
end
for _, evt in ipairs({ "CHAT_MSG_SKILL", "SKILL_LINES_CHANGED", "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "SPELLS_CHANGED",
    "LEARNED_SPELL_IN_TAB", "NEW_RECIPE_LEARNED",
    -- the newer names of the same signals on current clients, and the Classic crafting window
    "LEARNED_SPELL_IN_SKILL_LINE", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED", "CRAFT_SHOW", "CRAFT_UPDATE" }) do
    NS:RegisterEvent(evt, onChange)
end
