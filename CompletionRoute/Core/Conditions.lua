-- CompletionRoute :: Core/Conditions.lua
-- Evaluates step applicability: class, race, faction, level, profession, quest state.
local ADDON, NS = ...
local U = NS.Util
local C = {}
NS.Cond = C

local classAliases = { warrior="WARRIOR", paladin="PALADIN", hunter="HUNTER", rogue="ROGUE", priest="PRIEST", shaman="SHAMAN",
    mage="MAGE", warlock="WARLOCK", druid="DRUID", deathknight="DEATHKNIGHT", ["death knight"]="DEATHKNIGHT", monk="MONK",
    demonhunter="DEMONHUNTER", ["demon hunter"]="DEMONHUNTER", evoker="EVOKER" }
local raceAliases = { human="Human", dwarf="Dwarf", gnome="Gnome", nightelf="NightElf", ["night elf"]="NightElf", draenei="Draenei",
    worgen="Worgen", orc="Orc", troll="Troll", tauren="Tauren", undead="Scourge", scourge="Scourge", forsaken="Scourge",
    bloodelf="BloodElf", ["blood elf"]="BloodElf", goblin="Goblin", pandaren="Pandaren", ["void elf"]="VoidElf", voidelf="VoidElf",
    ["lightforged draenei"]="LightforgedDraenei", ["dark iron dwarf"]="DarkIronDwarf", kultiran="KulTiran", ["kul tiran"]="KulTiran",
    mechagnome="Mechagnome", nightborne="Nightborne", ["highmountain tauren"]="HighmountainTauren", ["mag'har orc"]="MagharOrc",
    ["zandalari troll"]="ZandalariTroll", vulpera="Vulpera", dracthyr="Dracthyr", earthen="EarthenDwarf" }

local function norm(s) return (s or ""):lower():gsub("^%s+", ""):gsub("%s+$", "") end

-- list may be "Warrior;Paladin" or "Warrior,Paladin"; leading '-' means NOT
function C.ClassMatch(list)
    if not list or list == "" then return true end
    local mine = NS.player.class
    local neg = list:sub(1, 1) == "-"
    if neg then list = list:sub(2) end
    for _, c in ipairs(U.split(list, ";,/")) do
        local k = classAliases[norm(c)] or norm(c):upper()
        if k == mine then return not neg end
    end
    return neg
end
function C.RaceMatch(list)
    if not list or list == "" then return true end
    local mine = NS.player.race
    local neg = list:sub(1, 1) == "-"
    if neg then list = list:sub(2) end
    for _, r in ipairs(U.split(list, ";,/")) do
        local k = raceAliases[norm(r)] or r
        if k == mine or norm(r) == norm(mine) then return not neg end
    end
    return neg
end
function C.FactionMatch(f)
    if not f or f == "" or f == "Neutral" then return true end
    return norm(f):sub(1, 1) == norm(NS.player.faction):sub(1, 1)
end
function C.LevelMatch(minl, maxl)
    local l = U.PlayerLevel()
    if minl and l < minl then return false end
    if maxl and l > maxl then return false end
    return true
end
-- Profession check: "Herbalism;75" means skill >= 75 (best-effort; classic API is limited)
function C.ProfMatch(spec)
    if not spec or spec == "" then return true end
    local name, need = spec:match("^([^;]+);?(%d*)")
    need = tonumber(need) or 1
    if GetSkillLineInfo then
        for i = 1, GetNumSkillLines() do
            local sname, isHeader, _, rank = GetSkillLineInfo(i)
            if not isHeader and sname and norm(sname) == norm(name) then return rank >= need end
        end
        return false
    end
    if GetProfessions then
        for _, idx in ipairs({ GetProfessions() }) do
            if idx then local pname, _, rank = GetProfessionInfo(idx) if pname and norm(pname) == norm(name) then return rank >= need end end
        end
        return false
    end
    return true
end

-- Whether a step should be shown at all for this character
function C.StepApplies(step)
    if step.class and not C.ClassMatch(step.class) then return false end
    if step.race and not C.RaceMatch(step.race) then return false end
    if step.faction and not C.FactionMatch(step.faction) then return false end
    if step.prof and not C.ProfMatch(step.prof) then return false end
    if step.minlevel and U.PlayerLevel() < step.minlevel and step.action ~= "L" then return false end
    -- PRE: prerequisite quest(s) must be complete (or on quest) — WoWPro semantic: hide until pre done
    -- PRE: prerequisite quest(s).  A list built from Questie's preQuestSingle is an OR set (any one of them
    -- opens the quest); a "&" list (preQuestGroup) needs all of them.  Requiring all of an OR set hid steps
    -- the player could actually take.
    if step.pre and #step.pre > 0 then
        local function pre_ok(q) return U.IsQuestComplete(q) or U.IsOnQuest(q) end
        if step.pre.andor == "and" then
            for _, q in ipairs(step.pre) do if not pre_ok(q) then return false end end
        else
            local any = false
            for _, q in ipairs(step.pre) do if pre_ok(q) then any = true break end end
            if not any then return false end
        end
    end
    -- ACTIVE: only while on quest
    if step.active then
        local neg = step.active < 0
        local q = math.abs(step.active)
        local on = U.IsOnQuest(q)
        if neg and on then return false end
        if not neg and not on then return false end
    end
    -- AVAILABLE: hide once quest done
    if step.available and U.IsQuestComplete(step.available) then return false end
    -- QO / other tags ignored for applicability
    return true
end
