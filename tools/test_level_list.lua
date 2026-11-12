-- CompletionRoute :: tools/test_level_list.lua
-- Offline test of Core/Recommend.lua and the level controls in UI/GuideMenu.lua, including a large synthetic list.
-- Copyright (c) 2026 Daniel Bates / Bates LLC.  All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
package.path = "./?.lua;" .. package.path
local ADDON, NS = "CompletionRoute", {}
dofile("tools/stubs.lua")
local z2w = z2w
PLAYER = { map = 1429, x = 0.487, y = 0.42 } PLAYER.wx, PLAYER.wy, PLAYER.inst = z2w(PLAYER.x, PLAYER.y, PLAYER.map)
local passed, failed = 0, 0
local function t(name, cond, detail)
    if cond then passed = passed + 1 print("ok   " .. name)
    else failed = failed + 1 print("FAIL " .. name .. (detail and (" :: " .. tostring(detail)) or "")) end
end
local function load(path) assert(loadfile("CompletionRoute/" .. path))(ADDON, NS) end
for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", "Data/Taxi_tbc.lua", "Data/Transit.lua", "Data/Access.lua",
    "Data/Inns.lua", "Data/ZoneAliases.lua", "Data/Roads_ek.lua", "Data/Roads_kalimdor.lua", "Routing/CostModel.lua", "Routing/TravelGraph.lua", "Routing/Roads.lua",
    "Routing/StepOrder.lua", "Routing/Router.lua", "Core/Account.lua", "Core/Professions.lua", "Core/Progress.lua", "Core/Recommend.lua", "Core/Farm.lua" }) do load(f) end
GameTooltip = CreateFrame()
SlashCmdList = SlashCmdList or {}
GameFontNormal = {}
assert(loadfile("CompletionRoute/UI/GuideMenu.lua"))(ADDON, NS)
assert(loadfile("CompletionRoute/Core/Slash.lua"))(ADDON, NS)
CompletionRouteDB, CompletionRouteCharDB = nil, nil
for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", "CompletionRoute") end
NS.Account.Init()
NS.db.profile.routing.assumeAllTaxi = true
NS.TravelGraph.Build()
InstallProfessionAPI("era")
local Prof, G, R, M = NS.Professions, NS.Guide, NS.Recommend, NS.GuideMenu
local T = M._test
UnitLevel = function() return 8 end

-- every guide's text is a function so a parse is visible
local PARSES = 0
local function text() PARSES = PARSES + 1 return "N step|M|48,42|Z|1429; Elwynn Forest|" end
local function reg(id, def)
    def.id, def.name, def.faction, def.source = id, def.name or id, def.faction or "Alliance", def.source or "test"
    def.text = text
    G.Register(def)
end
PROFS = { { name = "Cooking", rank = 80, max = 150 }, { name = "Mining", rank = 10, max = 75 } }
Prof.Invalidate()

reg("tight", { name = "Tight 5-10", type = "Leveling", minlevel = 5, maxlevel = 10 })
reg("wide", { name = "Wide 1-30", type = "Leveling", minlevel = 1, maxlevel = 30 })
reg("toohigh", { type = "Leveling", minlevel = 10, maxlevel = 20 })
reg("outgrown", { type = "Leveling", minlevel = 1, maxlevel = 4 })
reg("minonly", { type = "Quests", minlevel = 6 })
reg("dungeon", { type = "Dungeons", minlevel = 8, maxlevel = 15 })
reg("daily", { type = "Dailies", minlevel = 5, maxlevel = 12 })
reg("rep-named", { name = "Stormwind (5-20)", type = "Reputation" })                    -- level from its own name
reg("rep-none", { name = "Timbermaw", type = "Reputation" })                            -- no level data: Any level, not invented
reg("achv", { name = "Explore 1-60", type = "Achievements" })                           -- digits in an achievement name are not levels
reg("horde", { type = "Leveling", faction = "Horde", minlevel = 5, maxlevel = 10 })
reg("mage", { type = "Leveling", class = "MAGE", minlevel = 5, maxlevel = 10 })
reg("warrior", { type = "Leveling", class = "WARRIOR", minlevel = 5, maxlevel = 10 })
reg("gold-req-has", { name = "Mining circuit", type = "Gold", loop = true, minlevel = 5, requires = "Mining;1", goldKind = "Gathering" })
reg("gold-plain", { name = "Plain circuit", type = "Gold", loop = true, minlevel = 5, goldKind = "Gathering" })
reg("gold-req-miss", { name = "Herb circuit", type = "Gold", loop = true, minlevel = 5, requires = "Herbalism;75", goldKind = "Gathering" })
reg("gold-high", { name = "High gold", type = "Gold", loop = true, minlevel = 40 })
reg("cook1", { name = "Cooking 1-75", type = "Professions", prof = "Cooking", skillMin = 1, skillMax = 75, folder = "Cooking" })
reg("cook2", { name = "Cooking 75-150", type = "Professions", prof = "Cooking", skillMin = 75, skillMax = 150, folder = "Cooking" })
reg("cook3", { name = "Cooking 150-225", type = "Professions", prof = "Cooking", skillMin = 150, skillMax = 225, folder = "Cooking" })
reg("alch1", { name = "Alchemy 1-75", type = "Professions", prof = "Alchemy", skillMin = 1, skillMax = 75, folder = "Alchemy" })
reg("alch2", { name = "Alchemy 75-150", type = "Professions", prof = "Alchemy", skillMin = 75, skillMax = 150, folder = "Alchemy" })
reg("prof-nobands", { name = "Alchemy Guide Hub", type = "Professions" })

local function ids(list) local out = {} for i, e in ipairs(list) do out[i] = e.g.id end return out end
local function contains(list, id) for _, e in ipairs(list) do if e.g.id == id then return e end end end
local function pos(list, id) for i, e in ipairs(list) do if e.g.id == id then return i end end end

-- ---- scoring at level 8
local l8 = R.ForLevel(8)
t("no step parsing during ranking", PARSES == 0, PARSES)
t("a bracket containing the level ranks ahead of a guide with no level data", pos(l8, "tight") < pos(l8, "rep-none"))
t("tight bracket ahead of wide", pos(l8, "tight") < pos(l8, "wide"))
t("not-yet-reachable excluded", not contains(l8, "toohigh"))
t("outgrown excluded", not contains(l8, "outgrown"))
t("faction applies", not contains(l8, "horde"))
t("class applies", not contains(l8, "mage") and contains(l8, "warrior"))
t("min-only bracket fits", contains(l8, "minonly") and contains(l8, "minonly").fit)
t("level from the guide's own name", contains(l8, "rep-named") and contains(l8, "rep-named").fit)
t("no level data is listed but is not a fit", contains(l8, "rep-none") and contains(l8, "rep-none").fit == false and contains(l8, "rep-none").any)
t("digits in an achievement name do not become a level", contains(l8, "achv") and not contains(l8, "achv").fit)
t("a level the guide does not state is not invented", contains(R.ForLevel(55), "achv") ~= nil)
-- finished sinks below unfinished
NS.Account.doneCache[NS.Account.Scope()] = { tight = true }
R.Invalidate()
local fin = R.ForLevel(8)
t("unfinished ahead of finished (tight finished falls behind wide unfinished)", pos(fin, "wide") < pos(fin, "tight"))
t("a finished guide stays listed", contains(fin, "tight") and contains(fin, "tight").finished == true)
NS.Account.doneCache[NS.Account.Scope()] = {}
R.Invalidate()
-- a guide with progress ranks ahead of an equal untouched one
NS.Account.me.done["wide"] = { [1] = true }
R.Invalidate()
reg("wide2", { name = "Wide 1-30 B", type = "Leveling", minlevel = 1, maxlevel = 30 })
local st = R.ForLevel(8)
t("a started guide ranks ahead of an untouched one of the same width", pos(st, "wide") < pos(st, "wide2"))
NS.Account.me.done["wide"] = nil
R.Invalidate()
-- the same with a tick stored by step key (Core/Account.lua stepDone), and an index tick already migrated does not count
NS.Account.me.stepDone["wide"] = { ["A101"] = true }
R.Invalidate()
st = R.ForLevel(8)
t("a guide started under step keys ranks ahead too", pos(st, "wide") < pos(st, "wide2"))
NS.Account.me.stepDone["wide"] = nil
NS.Account.me.done["wide"] = { [1] = true }
t("an old index tick not migrated yet counts as started", NS.Account.Started("wide") == true)
NS.Account.me.stepMeta["wide"] = { v = 1, mig = 1 }
t("an old tick that was migrated (its keyed copy since cleared) does not", NS.Account.Started("wide") == false)
NS.Account.me.done["wide"], NS.Account.me.stepMeta["wide"] = nil, nil
R.Invalidate()

-- ---- other levels
t("level 20: Wide fits, Tight outgrown", contains(R.ForLevel(20), "wide") and not contains(R.ForLevel(20), "tight"))
t("level 3: a 5-10 guide cannot be done yet", not contains(R.ForLevel(3), "tight"))
t("level beyond the cap is clamped, not an error", #R.ForLevel(9999) >= 0)
t("level below 1 is clamped", #R.ForLevel(0) > 0)

-- ---- professions by skill
t("Cooking 80: band containing the skill offered", contains(l8, "cook2") and contains(l8, "cook2").fit)
t("Cooking 80: band below skipped", not contains(l8, "cook1"))
t("Cooking 80: band above skipped", not contains(l8, "cook3"))
t("Alchemy not learned: apprentice band offered", contains(l8, "alch1") and contains(l8, "alch1").learned == false)
t("Alchemy not learned: next band not offered", not contains(l8, "alch2"))
t("a learned profession ranks ahead of an unlearned offer", pos(l8, "cook2") < pos(l8, "alch1"))
t("profession guide with no bands is Any level", contains(l8, "prof-nobands") and contains(l8, "prof-nobands").any)
-- exactly at a band edge the next band takes over
PROFS[1].rank = 150
Prof.Invalidate() R.Invalidate()
local e150 = R.ForLevel(8)
t("at the top of a band the next band takes over", contains(e150, "cook3") and not contains(e150, "cook2"))
PROFS[1].rank = 80
Prof.Invalidate() R.Invalidate()
-- retail tier unknown: only the first band, flagged
do
    PROFS[3] = { name = "Tailoring", rank = 40, max = 75 }
    Prof.Invalidate() R.Invalidate()
    InstallProfessionAPI("retail")
    reg("tailor1", { name = "Tailoring Tier 1-75", type = "Professions", prof = "Tailoring", tier = 2531, skillMin = 1, skillMax = 75, folder = "Tailoring" })
    reg("tailor2", { name = "Tailoring Tier 75-100", type = "Professions", prof = "Tailoring", tier = 2531, skillMin = 75, skillMax = 100, folder = "Tailoring" })
    Prof.Invalidate() R.Invalidate()
    local le = R.ForLevel(8)
    t("retail tier unread: first band offered and flagged", contains(le, "tailor1") and contains(le, "tailor1").unknownSkill == true)
    t("retail tier unread: later bands withheld", not contains(le, "tailor2"))
    PROFS[3] = nil
    InstallProfessionAPI("era")
    Prof.Invalidate() R.Invalidate()
end

-- ---- gold: level band, then requires, with the missing skill named
local gold = R.ForLevel(8, { category = "gold" })
t("gold: requires the character has ranks first", pos(gold, "gold-req-has") < pos(gold, "gold-plain") and pos(gold, "gold-plain") < pos(gold, "gold-req-miss"))
t("gold: missing skill is named", contains(gold, "gold-req-miss").missing == "Herbalism 75", contains(gold, "gold-req-miss").missing)
t("gold: requirement met has nothing to name", contains(gold, "gold-req-has").missing == nil)
t("gold: level band applies", not contains(gold, "gold-high"))
t("gold circuits are fits, so they can be picked", contains(gold, "gold-req-has").fit)

-- ---- ForLevel options
t("opts.category and limit", #R.ForLevel(8, { category = "Leveling", limit = 2 }) == 2)
t("opts.fitOnly", (function() for _, e in ipairs(R.ForLevel(8, { fitOnly = true })) do if not e.fit then return false end end return true end)())
t("opts.unfinishedOnly", (function()
    NS.Account.doneCache[NS.Account.Scope()] = { tight = true }
    R.Invalidate()
    local ok = true
    for _, e in ipairs(R.ForLevel(8, { unfinishedOnly = true })) do if e.finished then ok = false end end
    NS.Account.doneCache[NS.Account.Scope()] = {}
    R.Invalidate()
    return ok
end)())

-- ---- bands, cap, labels
NS.flavor = "tbc"
t("LevelCap from the flavor table", R.LevelCap() == 70, R.LevelCap())
GetMaxPlayerLevel = function() return 60 end
t("a Classic GetMaxPlayerLevel that lags cannot lower the cap", R.LevelCap() == 70)
GetMaxPlayerLevel = nil
local bands = R.Bands()
t("bands run 1-9, 10-19, ... up to the cap", bands[1].label == "1-9" and bands[2].label == "10-19" and bands[#bands].label == "70" and #bands == 8)
t("GuideLabel shows the bracket", R.GuideLabel(G.registry["tight"]) == "[5-10]", R.GuideLabel(G.registry["tight"]))
t("GuideLabel shows a skill band", R.GuideLabel(G.registry["cook2"]) == "[skill 75-150]")
t("GuideLabel: a min-only guide", R.GuideLabel(G.registry["minonly"]) == "[6+]")
t("GuideLabel: nothing for no level data", R.GuideLabel(G.registry["rep-none"]) == "")
do
    local lines = R.Describe(G.registry["cook2"], 8)
    local joined = table.concat(lines, "|")
    t("Describe shows the skill and your rank", joined:find("Skill: Cooking 75-150", 1, true) and joined:find("You: 80/150", 1, true), joined)
    local j2 = table.concat(R.Describe(G.registry["gold-req-miss"], 8), "|")
    t("Describe names the unmet requirement", j2:find("Requires: Herbalism 75", 1, true), j2)
end

-- ---- picks
do
    local picks = R.Picks(8)
    local names, cats = {}, {}
    for i, s in ipairs(picks) do names[i] = s.cat cats[s.cat] = s end
    t("picks appear in category order", names[1] == "Leveling" and names[#names] == "Reputation", table.concat(names, ","))
    t("picks include gold circuits", cats.Gold ~= nil and contains(cats.Gold.entries, "gold-req-has") ~= nil)
    t("picks are fits only (Reputation holds the named-range guide, not the no-level one)", contains(cats.Reputation.entries, "rep-named") and not contains(cats.Reputation.entries, "rep-none"))
    t("picks have at most the per-category cap", #cats.Leveling.entries <= R.PICKS)
    t("picks never parse guides", PARSES == 0, PARSES)
end

-- ---- cache: per level, invalidated by the things that change the answer
do
    local b0 = R.builds
    R.Invalidate()
    R.ForLevel(8) R.ForLevel(8) R.Picks(8) R.FitSet(8) R.EntryFor(8, "tight")
    t("one level builds once", R.builds == b0 + 1, R.builds - b0)
    R.ForLevel(9)
    t("another level builds its own", R.builds == b0 + 2, R.builds - b0)
    reg("late", { type = "Leveling", minlevel = 8, maxlevel = 9 })
    R.ForLevel(8)
    t("a newly registered guide invalidates the cache", contains(R.ForLevel(8), "late"))
    NS:Fire("PROFESSIONS_CHANGED")
    local b1 = R.builds
    R.ForLevel(8)
    t("a skill change invalidates the cache", R.builds == b1 + 1)
    -- only a handful of levels are kept
    for lv = 10, 30 do R.ForLevel(lv) end
    local b2 = R.builds
    R.ForLevel(8)
    t("the cache is bounded (level 8 had to be rebuilt)", R.builds == b2 + 1)
end

-- ---- the menu
local prefs = T.prefs()
t("preferences live in the profile, defaults off", NS.db.profile.guideList == prefs and prefs.onlyLevel == false and prefs.groupByLevel == false)
t("level defaults to the character's", M.ViewLevel() == 8, M.ViewLevel())
do
    local root = T.buildTree()
    t("Recommended section is first", root.kids[1].recommended and root.kids[1].name == "Recommended", root.kids[1].name)
    local sec = root.kids[1]
    -- what it holds: unfinished quest routes (Leveling / Quests) that fit level 8, one per zone part, at most 10,
    -- closest first (owner's request 2026-11-12; it replaced the per-category "For level N" picks)
    local okType, okFit, okDup, okOrder, seenPart, lastEta = true, true, true, true, {}, -1
    for _, g in ipairs(sec.guides) do
        local cat = G.NormalizeType(g.type)
        if cat ~= "Leveling" and cat ~= "Quests" then okType = false end
        if (g.minlevel and 8 < g.minlevel) or (g.maxlevel and 8 > g.maxlevel) then okFit = false end
        local k = g.part or g.id
        if seenPart[k] then okDup = false end
        seenPart[k] = true
        local eta = g.__nextETA or math.huge
        if eta < lastEta then okOrder = false end
        lastEta = eta
    end
    t("Recommended holds quest routes only", okType)
    t("Recommended routes fit the level", okFit)
    t("Recommended lists a zone part once", okDup)
    t("Recommended is closest first", okOrder)
    t("Recommended shows at most 10", #sec.guides >= 1 and #sec.guides <= 10, #sec.guides)
    t("no sub-folders in Recommended", #sec.kids == 0)

    local total = #G.Available()
    t("the section plus the categories count every guide", root.count == total + sec.count, root.count .. " vs " .. total .. "+" .. sec.count)
end
-- Recommended asks the leveling chain where a zone route belongs (a "both factions" zone route can span 1-60 because of a
-- few low neutral quests; the chain puts it at 54-60), and leaves out a wide zone route the chain does not place
do
    reg("wide:placed", { name = "Wintery Quests 1-60", type = "Quests", minlevel = 1, maxlevel = 60, zone = 1452 })
    reg("spine:t:067", { name = "067. Wintery Quests 1-60", type = "Leveling", minlevel = 54, maxlevel = 60, part = "wide:placed" })
    reg("wide:loose", { name = "Loose Quests 1-60", type = "Quests", minlevel = 1, maxlevel = 60 })
    reg("near:ok", { name = "Nearby Quests 5-12", type = "Quests", minlevel = 5, maxlevel = 12 })
    R.Invalidate()
    local ids = {}
    for _, g in ipairs(M.Recommended(8, true)) do ids[g.id] = true end
    t("a zone route the chain places at 54-60 is not recommended at level 8", not ids["wide:placed"] and not ids["spine:t:067"])
    t("a 1-60 zone route the chain does not place is not recommended", not ids["wide:loose"])
    t("a narrow zone route that fits is recommended", ids["near:ok"] == true)
    t("Recommended names drop the level range and the chain number",
        M.RecName({ name = "002. Zephras Isle Quests 1-5" }) == "Zephras Isle Quests"
        and M.RecName({ name = "Durotar Quests 1-8 (Horde) - Part 1/2" }) == "Durotar Quests (Horde) - Part 1/2"
        and M.RecName({ name = "Elwynn Forest Quests 1" }) == "Elwynn Forest Quests", M.RecName({ name = "002. Zephras Isle Quests 1-5" }))
    -- a character's surname (WoW Forever: UnitNameUnmodified returns it second) is shown, never put in the key
    local A = NS.Account
    if A and A.DisplayName then
        t("display name with a surname", A.DisplayName({ name = "Meln", surname = "Ashford" }) == "Meln Ashford")
        t("display name without one", A.DisplayName({ name = "Meln" }) == "Meln" and A.DisplayName({ name = "Meln", surname = "" }) == "Meln")
    end
end
do
    local level8tree = T.buildTree()
    prefs.onlyLevel = true
    local root = T.buildTree()
    local count = 0
    for i = 2, #root.kids do count = count + root.kids[i].count end
    local fit = R.FitSet(8)
    local nfit = 0
    for _ in pairs(fit) do nfit = nfit + 1 end
    t("Only filter keeps exactly the fits in the tree", count == nfit, count .. " vs " .. nfit)
    local rows = T.searchRows("tight")
    t("Only filter applies to search", #rows == 1 and rows[1].guide.id == "tight", #rows)
    local rows2 = T.searchRows("outgrown")
    t("Only filter hides non-fits from search", #rows2 == 0, #rows2)
    prefs.onlyLevel = false
    local rows3 = T.searchRows("outgrown")
    t("without the filter search still finds it", #rows3 == 1, #rows3)
end
do
    prefs.groupByLevel = true
    local root = T.buildTree()
    local names = {}
    for i, k in ipairs(root.kids) do names[i] = k.name end
    t("grouped tree: section, then bands in level order, Any level last", root.kids[1].recommended and names[2] == "1-9" and names[#names] == "Any level", table.concat(names, ","))
    local b = root.kids[2]
    t("a band holds categories, category order Leveling first", b.kids[1].name == "Leveling", b.kids[1].name)
    local cat = b.kidByName.Leveling
    t("the category holds guides directly", #cat.kids == 0 and #cat.guides > 0)
    -- the 5-10 guide starts in 1-9 and level 8 is in 1-9: filed there
    t("a guide is filed in the viewed level's band when it fits", (function() for _, g in ipairs(cat.guides) do if g.id == "tight" then return true end end end)())
    -- "Any level" holds the level-less guides
    t("Any level bucket holds no-level guides", root.kidByName["Any level"].kidByName["Reputation"] ~= nil and root.kidByName["Any level"].kidByName["Achievements"] ~= nil)
    t("Only + Group: a single band remains", (function()
        prefs.onlyLevel = true
        local r2 = T.buildTree()
        prefs.onlyLevel = false
        return #r2.kids == 2 and r2.kids[2].name == "1-9"
    end)())
    t("a wide guide is filed under the band of the level viewed", (function()
        UnitLevel = function() return 25 end
        M.UpdateLevelControls()
        local r3 = T.buildTree()
        UnitLevel = function() return 8 end
        local band = r3.kidByName["20-29"]
        if not band then return false end
        for _, g in ipairs(band.kidByName.Leveling.guides) do if g.id == "wide" then return true end end
        return false
    end)())
    prefs.groupByLevel = false
end
do
    M.SetViewLevel(12)
    t("SetViewLevel changes the level", M.ViewLevel() == 12 and prefs.level == 12)
    local root = T.buildTree()
    t("the section follows the level box", root.kids[1].name == "Recommended for level 12", root.kids[1].name)
    t("Refresh is the same level everywhere", T.levelBox:GetText() == "12", T.levelBox:GetText())
    M.SetViewLevel(nil)
    t("Mine resets the level and clears the override", M.ViewLevel() == 8 and prefs.level == nil)
    -- typing
    T.levelBox.__text = "33"
    T.levelBox.scripts.OnTextChanged(T.levelBox, true)
    t("typing a level works", M.ViewLevel() == 33 and prefs.level == 33)
    T.levelBox.__text = ""
    T.levelBox.scripts.OnTextChanged(T.levelBox, true)
    t("clearing the box is ignored until a number is typed", prefs.level == 33)
    M.SetViewLevel(nil)
end
do
    -- the rows actually render through Refresh in every mode: normal, grouped, filtered, searching
    local function render()
        local ok, err = pcall(M.Refresh)
        return ok, err
    end
    T.expanded["\\Leveling"] = true
    local ok1, e1 = render()
    t("Refresh renders the normal tree", ok1, e1)
    prefs.groupByLevel = true
    T.expanded["\\Bands\\1-9"] = true
    T.expanded["\\Bands\\1-9\\Leveling"] = true
    local ok2, e2 = render()
    t("Refresh renders the grouped tree", ok2, e2)
    prefs.groupByLevel = false
    prefs.onlyLevel = true
    local ok3, e3 = render()
    t("Refresh renders the filtered tree", ok3, e3)
    prefs.onlyLevel = false
    local ok4, e4 = pcall(M.UpdateLevelControls)
    t("level controls update", ok4, e4)
end

-- ---- slash
do
    local out = {}
    local realPrint = print
    print = function(...) out[#out + 1] = table.concat({ ... }, " ") end
    SlashCmdList.COMPLETIONROUTE("list")
    local n1 = #out
    SlashCmdList.COMPLETIONROUTE("list 8 gold")
    SlashCmdList.COMPLETIONROUTE("gold 8")
    SlashCmdList.COMPLETIONROUTE("prof")
    SlashCmdList.COMPLETIONROUTE("list quests")
    SlashCmdList.COMPLETIONROUTE("list 8 nonsense")
    print = realPrint
    local joined = table.concat(out, "\n")
    t("/cr list prints sections", n1 > 2 and joined:find("Leveling:", 1, true) ~= nil)
    t("/cr gold prints circuits and the missing skill", joined:find("Herb circuit", 1, true) and joined:find("needs Herbalism 75", 1, true))
    t("/cr prof lists skills and the guide for each", joined:find("Cooking 80/150", 1, true) and joined:find("Cooking 75-150", 1, true), joined)
    t("/cr list with a bad category says so", joined:find("Unknown category 'nonsense'", 1, true))
end

-- ---- the slash test and the help line
do
    local fh = assert(io.open("CompletionRoute/Core/Slash.lua"))
    local src = fh:read("*a") fh:close()
    t("help line advertises list/gold/prof", src:find("list [level] [category] | gold [level] | prof", 1, true) ~= nil)
end

-- ---- performance: a retail-sized list
do
    print("performance: registering a large synthetic list")
    local n0, big = #G.list, 8000
    local cats = { "Leveling", "Quests", "Dungeons", "Gold", "Professions", "Dailies", "Reputation", "Achievements", "Storylines" }
    for i = 1, big do
        local c = cats[(i % #cats) + 1]
        local mn = (i * 7) % 80 + 1
        local def = { name = ("%s %d"):format(c, i), type = c }
        if i % 5 ~= 0 then def.minlevel, def.maxlevel = mn, mn + (i % 15) end
        if c == "Professions" then def.prof, def.skillMin, def.skillMax = "Cooking", (i % 5) * 75 + 1, (i % 5) * 75 + 75 end
        if c == "Gold" then def.requires = (i % 2 == 0) and "Herbalism;75" or nil def.loop = (i % 2 == 1) or nil end
        reg("big:" .. i, def)
    end
    NS.db.profile.farm.circuitizeGold = false
    PARSES = 0
    local clock = os.clock
    local t0 = clock()
    R.Invalidate()
    local list = R.ForLevel(40)
    local cold = (clock() - t0) * 1000
    t0 = clock()
    for _ = 1, 100 do R.ForLevel(40) R.Picks(40) R.FitSet(40) end
    local warm = (clock() - t0) * 10
    t(("%d guides ranked cold in %.1f ms (limit 200)"):format(#G.list, cold), cold < 200, cold)
    t(("warm reads %.3f ms per set (limit 1)"):format(warm), warm < 1, warm)
    t("no step parsing during ranking at this size", PARSES == 0, PARSES)
    t("rank returned guides", #list > 0)

    -- worst keystroke: filter and search on, cold cache
    t0 = clock()
    prefs.onlyLevel = true
    R.Invalidate()
    local rows = T.searchRows("alchemy")
    local coldSearch = (clock() - t0) * 1000
    prefs.onlyLevel = false
    t(("worst-case filtered search %.1f ms (limit 200)"):format(coldSearch), coldSearch < 200, coldSearch)
    t("search parsed nothing", PARSES == 0, PARSES)
    t0 = clock()
    prefs.groupByLevel = true
    T.visibleRows()
    local grouped = (clock() - t0) * 1000
    prefs.groupByLevel = false
    t(("grouped tree with %d guides built in %.1f ms (limit 200)"):format(#G.list, grouped), grouped < 200, grouped)
    t0 = clock()
    for _ = 1, 20 do M.ViewLevel() T.visibleRows() end
    local keystroke = (clock() - t0) * 50
    t(("list rebuild per keystroke %.1f ms (limit 50)"):format(keystroke), keystroke < 50, keystroke)
    t("the tree parses at most the priced leveling guides", PARSES <= 6, PARSES)
    print(("timing: cold=%.1fms warm=%.3fms worstSearch=%.1fms grouped=%.1fms perKeystroke=%.1fms (%d guides, luajit, no real client)"):format(cold, warm, coldSearch, grouped, keystroke, #G.list))
end

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
print("ALL LEVEL LIST TESTS PASSED")
