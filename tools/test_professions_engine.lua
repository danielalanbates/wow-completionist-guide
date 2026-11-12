-- CompletionRoute :: tools/test_professions_engine.lua
-- Offline test of Core/Professions.lua and the SKILL / RECIPE / ALT / COUNT grammar in Guide + Progress.
-- Stubs the WoW API (tools/stubs.lua); nothing here is proof about a live client.
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
-- ---- missing events: this fake client does not have these, and Frame:RegisterEvent raises for them
UNKNOWN_EVENTS = { LEARNED_SPELL_IN_TAB = true, NEW_RECIPE_LEARNED = true, TRADE_SKILL_LIST_UPDATE = true,
    LEARNED_SPELL_IN_SKILL_LINE = true, CRAFT_SHOW = true, CRAFT_UPDATE = true, TRADE_SKILL_DATA_SOURCE_CHANGED = true }
local loadOK, loadErr = pcall(function()
    local function load(path) assert(loadfile("CompletionRoute/" .. path))(ADDON, NS) end
    for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", "Data/Taxi_tbc.lua", "Data/Transit.lua", "Data/Access.lua",
        "Data/Inns.lua", "Data/ZoneAliases.lua", "Data/Roads_ek.lua", "Data/Roads_kalimdor.lua", "Routing/CostModel.lua", "Routing/TravelGraph.lua", "Routing/Roads.lua",
        "Routing/StepOrder.lua", "Routing/Router.lua", "Core/Account.lua", "Core/Professions.lua", "Core/Progress.lua", "Core/Recommend.lua" }) do load(f) end
end)
t("addon loads when the client lacks several profession events", loadOK, loadErr)
CompletionRouteDB, CompletionRouteCharDB = nil, nil
for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", "CompletionRoute") end
NS.db.profile.routing.assumeAllTaxi = true
local Prof, G, Pr, Cond = NS.Professions, NS.Guide, NS.Progress, NS.Cond
t("every profession event has a handler even where the frame refused it", NS.wowHandlers.LEARNED_SPELL_IN_TAB and #NS.wowHandlers.LEARNED_SPELL_IN_TAB > 0)
local function fire(evt) for _, h in ipairs(NS.wowHandlers[evt] or {}) do assert(pcall(h, evt)) end end
fire("LEARNED_SPELL_IN_TAB") fire("CRAFT_UPDATE") fire("TRADE_SKILL_UPDATE")
t("firing the handlers of missing and present events raises nothing", true)

-- ---- era: GetSkillLineInfo, names matched through the spell name in the client's language
local function setProfs(list) PROFS = list Prof.Invalidate() end
InstallProfessionAPI("era")
SPELL_NAMES = { [2550] = "Kochkunst", [9134] = "Kräuterkunde", [7620] = "Angeln", [2259] = "Alchemie" }
-- the localized name table is built lazily once: built here with our stub spell names
setProfs({ { name = "Cooking", lang = "Kochkunst", rank = 45, max = 75 }, { name = "Herbalism", lang = "Kräuterkunde", rank = 120, max = 150 },
           { name = "Herbalism2", lang = "Botánica", rank = 33, max = 75 }, { name = "Defense", lang = "Verteidigung", rank = 100, max = 150 } })
local r, m = Prof.Skill("Cooking")
t("era: Cooking read through the localized spell name", r == 45 and m == 75, r)
r, m = Prof.Skill("Herbalism")
t("era: Herbalism (base spell is not named Herbalism on era/tbc)", r == 120 and m == 150, r)
t("era: Knows true for a learned skill", Prof.Knows("Cooking") == true)
t("era: not-learned profession is 0,0 and Knows false", (function() local a, b = Prof.Skill("Mining") return a == 0 and b == 0 end)() and Prof.Knows("Mining") == false)
t("era: skill lines that are not professions are still readable by name", (Prof.Skill("Verteidigung")) == 100)

SKILL_HEADERS_COLLAPSED = true
Prof.Invalidate()
t("era: collapsed Skills pane = unknown, not zero", Prof.Skill("Cooking") == nil and Prof.Knows("Cooking") == nil)
t("era: an unknown skill does not hide a P-tagged step", Cond.ProfMatch("Cooking;10") == true)
SKILL_HEADERS_COLLAPSED = false
Prof.Invalidate()

-- ---- the P tag (Cond.ProfMatch, on Core/Professions now)
setProfs({ { name = "Tailoring", rank = 40, max = 75 }, { name = "Herbalism", rank = 80, max = 150 } })
t("ProfMatch Herbalism;75 passes", Cond.ProfMatch("Herbalism;75") == true)
t("ProfMatch Herbalism;90 fails", Cond.ProfMatch("Herbalism;90") == false)
t("ProfMatch long form Tailoring;197 means learned, not skill 197", Cond.ProfMatch("Tailoring;197") == true)
t("ProfMatch long form Tailoring;197;0+1;true needs skill 1", Cond.ProfMatch("Tailoring;197;0+1;true") == true)
t("ProfMatch not learned fails", Cond.ProfMatch("Mining;1") == false)
t("ProfMatch empty spec passes", Cond.ProfMatch(nil) == true and Cond.ProfMatch("") == true)
local _, need = Prof.ParseSpec("Leatherworking;165;6;1")
t("ParseSpec third field wins over the skill line id", need == 6, need)

-- ---- mop: GetProfessions with holes, skillLine decides the name
InstallProfessionAPI("mop")
setProfs({ { name = "Fishing", lang = "Pesca", key = 356, rank = 12, max = 75 }, { name = "Cooking", lang = "Cocina", key = 185, rank = 200, max = 300 } })
r, m = Prof.Skill("Fishing")
t("mop: read by skillLine id (first GetProfessions slot is nil)", r == 12 and m == 75, r)
t("mop: second tab found too", (Prof.Skill("Cooking")) == 200)
t("mop: Knows through the same data", Prof.Knows("Fishing") == true and Prof.Knows("Mining") == false)

-- ---- retail: base levels from GetProfessions, tiers only when the client can answer
InstallProfessionAPI("retail")
TIERS = { [2545] = { rank = 40, max = 75 } }
setProfs({ { name = "Cooking", key = 185, rank = 50, max = 100 } })
r, m = Prof.Skill("Cooking")
t("retail: base skill without a tier", r == 50 and m == 100, r)
r = Prof.Skill("Cooking", 2545)
t("retail: tier unknown until the window has been opened (API answers maxSkillLevel 0)", r == nil, r)
do
    local s = G.ParseLine("M Cook|SKILL|Cooking;30;2545|")
    t("retail: an unknown tier does not complete a SKILL step", Pr.CheckStep(s) == false)
end
OPEN_PROFESSION_WINDOW()
fire("TRADE_SKILL_SHOW")
r, m = Prof.Skill("Cooking", 2545)
t("retail: tier readable once the window has data", r == 40 and m == 75, r)
do
    local s = G.ParseLine("M Cook|SKILL|Cooking;30;2545|")
    t("retail: a known tier completes the SKILL step", Pr.CheckStep(s) == true)
    local s2 = G.ParseLine("M Cook|SKILL|Cooking;60;2545|")
    t("retail: below target stays open", Pr.CheckStep(s2) == false)
end
setProfs({})
Prof.Invalidate()
do
    local s = G.ParseLine("M Cook|SKILL|Cooking;30;2545|")
    t("retail: profession dropped, a remembered tier no longer completes the step", Pr.CheckStep(s) == false)
end
InstallProfessionAPI("retail")

-- ---- no skill API at all
InstallProfessionAPI("none")
setProfs({})
t("no API: Skill is nil, Knows nil, no error", Prof.Skill("Cooking") == nil and Prof.Knows("Cooking") == nil)
t("no API: KnowsSpell false", Prof.KnowsSpell(2550) == false)
t("no API: P-tagged step still shows", Cond.ProfMatch("Cooking;10") == true)

-- ---- spell and recipe knowledge
InstallProfessionAPI("era")
setProfs({ { name = "Cooking", rank = 200, max = 225 } })
SPELLS_KNOWN = { [12345] = true }
t("KnowsSpell through IsSpellKnown", Prof.KnowsSpell(12345) == true)
IsPlayerSpell = function(id) return id == 777 end
t("KnowsSpell through IsPlayerSpell", Prof.KnowsSpell(777) == true)
t("unknown spell is false", Prof.KnowsSpell(9999) == false)
t("rank spell true once the skill cap reaches that rank (rank spells replace each other)", Prof.KnowsSpell(3102) == true)   -- Journeyman Cooking
t("rank spell above the cap is false", Prof.KnowsSpell(18260) == false)                                                     -- Artisan Cooking
NS.flavor = "retail"
t("rank ladder is not used on retail", Prof.KnowsSpell(3102) == false)
NS.flavor = "tbc"
-- recipes the trade skill window listed
GetNumTradeSkills = function() return 3 end
GetTradeSkillInfo = function(i) return ({ "Meals", "Roast Quail", "Herb Baked Egg" })[i], (i == 1) and "header" or "easy" end
SPELL_NAMES[50000] = "Roast Quail"
SPELL_NAMES[50001] = "Grilled Quail"
fire("TRADE_SKILL_UPDATE")
t("recipe known after the window listed it", Prof.KnowsSpell(50000) == true)
t("recipe not listed stays unknown", Prof.KnowsSpell(50001) == false)
t("headers in the window are not recipes", (NS.db.char.recipes or {})["Meals"] == nil)

-- ---- grammar
InstallProfessionAPI("era")
setProfs({ { name = "Cooking", rank = 30, max = 75 } })
do
    local s = G.ParseLine("M Spiced Wolf Meat|SKILL|Cooking;40|COUNT|12|M|40,50|Z|1429; Elwynn Forest|")
    t("SKILL parses name and target", s.skill and s.skill.name == "Cooking" and s.skill.target == 40 and s.skill.tier == nil)
    t("COUNT parses", s.count == 12)
    local s2 = G.ParseLine("M Thing|SKILL|Cooking;40;2545|")
    t("SKILL parses the tier field", s2.skill.tier == 2545)
    local s3 = G.ParseLine("= Train|RECIPE|3102|")
    t("RECIPE parses", s3.recipe == 3102)
    t("M is labelled Make and = Train", G.ACTION_LABEL.M == "Make" and G.ACTION_LABEL["="] == "Train")
    local bad = G.ParseLine("M Thing|SKILL|Cooking|")
    t("a SKILL with no target is ignored rather than fatal", bad and bad.skill == nil)
    local a = G.ParseLine("= Train|ALT|1453,70,60,Ali Baba;1455,50,10,Grom|")
    t("ALT parses every location, x/y 0..1", a.alts and #a.alts == 2 and a.alts[1].map == 1453 and a.alts[1].x == 0.7 and a.alts[2].name == "Grom")
    t("ALT is located at once at the first alternative", a.zone == 1453 and a.coords and a.coords[1].x == 0.7 and a.altName == "Ali Baba")
    local b = G.ParseLine("= Train|ALT|99999,10,10,Nowhere;1453,20,30,Name, with comma|")
    t("ALT drops a map this client lacks, keeps a comma in the name", #b.alts == 1 and b.alts[1].name == "Name, with comma")
    -- the zone of an ALT step does not leak onto the next line
    G.Register({ id = "t:altzone", name = "AltZone", type = "Professions", faction = "Alliance", source = "test",
        text = "R Start|M|10,10|Z|1429; Elwynn Forest|\n= Train|ALT|1453,70,60,A;1455,50,10,B|\nN Afterwards|\n" })
    local st = G.Steps("t:altzone")
    t("a line after an ALT step inherits the last Z, not the ALT choice", st[3].zone == 1429, st[3].zone)
end

-- ---- SKILL / RECIPE steps complete by themselves inside a loaded guide
NS.TravelGraph.Build()
do
    InstallProfessionAPI("era")
    SPELLS_KNOWN = {}
    setProfs({ { name = "Cooking", rank = 10, max = 75 } })
    G.Register({ id = "t:skill", name = "Skill", type = "Professions", faction = "Alliance", source = "test",
        text = "M Practice|SKILL|Cooking;20|\n= Learn|RECIPE|4242|\nM Practice more|SKILL|Cooking;30|COUNT|5|" })
    Pr.Load("t:skill")
    t("SKILL step open below target", Pr.current and Pr.current.title == "Practice", Pr.current and Pr.current.title)
    t("title shows the skill so far", G.StepTitle(Pr.current):find("10/20", 1, true) ~= nil, G.StepTitle(Pr.current))
    PROFS[1].rank = 20
    fire("CHAT_MSG_SKILL")
    t("CHAT_MSG_SKILL completes the SKILL step without a click", Pr.current and Pr.current.title == "Learn", Pr.current and Pr.current.title)
    SPELLS_KNOWN[4242] = true
    fire("SPELLS_CHANGED")
    t("learning the spell completes the RECIPE step", Pr.current and Pr.current.title == "Practice more", Pr.current and Pr.current.title)
    t("title shows COUNT", G.StepTitle(Pr.current):find("x5", 1, true) ~= nil, G.StepTitle(Pr.current))
    Pr.Reset()
end

-- ---- an unknown tier never completes (Pending stays on it)
do
    InstallProfessionAPI("retail")
    setProfs({ { name = "Cooking", key = 185, rank = 50, max = 100 } })
    NS.db.char.profTiers = nil    -- a reading kept from an earlier window would (rightly) count
    G.Register({ id = "t:tier", name = "Tier", type = "Professions", faction = "Alliance", source = "test", text = "M Tier work|SKILL|Cooking;5;2545|\nN After|" })
    Pr.Load("t:tier")
    t("unknown tier: the step stays current", Pr.current and Pr.current.title == "Tier work")
    t("unknown tier: the title tells the player what to do", G.StepTitle(Pr.current):find("open Cooking", 1, true) ~= nil, G.StepTitle(Pr.current))
    OPEN_PROFESSION_WINDOW()
    TIERS = { [2545] = { rank = 10, max = 75 } }
    fire("TRADE_SKILL_SHOW")
    t("window opened: the step completes", Pr.current and Pr.current.title == "After", Pr.current and Pr.current.title)
end

-- ---- ALT: cheapest for this character, re-resolved on a continent change
do
    InstallProfessionAPI("era")
    local gid = "t:alt"
    G.Register({ id = gid, name = "Alt", type = "Professions", faction = "Alliance", source = "test",
        text = "= Train|ALT|1457,40,50,Darnassus Trainer;1453,50,50,Stormwind Trainer;1455,60,40,Ironforge Trainer|\nN Done|" })
    local function setPlayer(map, x, y)
        PLAYER.map, PLAYER.x, PLAYER.y = map, x, y
        PLAYER.wx, PLAYER.wy, PLAYER.inst = z2w(x, y, map)
    end
    setPlayer(1429, 0.487, 0.42)     -- Elwynn: Stormwind is next door
    Pr.Load(gid)
    local s = Pr.current
    t("ALT picks the cheapest place on load", s and s.altName == "Stormwind Trainer" and s.zone == 1453, s and s.altName)
    t("the chosen name is in the title", G.StepTitle(s):find("Stormwind Trainer", 1, true) ~= nil, G.StepTitle(s))
    local wx1 = NS.Router.StepWorld(s)
    t("the Router sees it as a normal located step", wx1 ~= nil and s._locSource == "guide")
    -- to Kalimdor: Darnassus is now the cheap one
    setPlayer(1457, 0.5, 0.5)
    Pr.Refresh(true)
    t("ALT re-resolves when the player changes continent", s.altName == "Darnassus Trainer" and s.zone == 1457, s.altName)
    local _, _, inst = NS.Router.StepWorld(s)
    t("the step's world position moved to Kalimdor", inst == 1, inst)
    setPlayer(1429, 0.487, 0.42)
end

-- ---- Forever: ALT coordinates are written on Era maps like every other coordinate
do
    NS.isForever, NS.ForeverMapFix = true, { [1429] = { 1000, 1000, 100, 100, 1010, 1010, 100, 100 } }
    G.Register({ id = "t:fix", name = "Fix", type = "Professions", faction = "Alliance", source = "test",
        text = "= Train|ALT|1429,20,30,A;1453,20,30,B|" })
    G.Register({ id = "t:fix2", name = "Fix2", forever = true, type = "Professions", faction = "Alliance", source = "test",
        text = "= Train|ALT|1429,20,30,A|" })
    local st = G.Steps("t:fix")
    t("Forever: an ALT point on a reshaped map is converted", math.abs(st[1].alts[1].x - 0.3) < 1e-6 and math.abs(st[1].alts[1].y - 0.4) < 1e-6, st[1].alts[1].x)
    t("Forever: an ALT point on an unchanged map is left alone", st[1].alts[2].x == 0.2)
    local st2 = G.Steps("t:fix2")
    t("Forever: guides written on Forever maps are not converted", st2[1].alts[1].x == 0.2)
    NS.isForever, NS.ForeverMapFix = false, nil
end

-- ---- Gold and profession guides are never the automatic next guide
do
    InstallProfessionAPI("era")
    setProfs({})
    UnitLevel = function() return 5 end
    G.Register({ id = "t:lev", name = "Lev", type = "Leveling", faction = "Alliance", minlevel = 5, maxlevel = 10, source = "test", text = "N a|" })
    G.Register({ id = "t:gold", name = "Gold", type = "Gold", loop = false, noCircuit = true, faction = "Alliance", minlevel = 5, maxlevel = 6, source = "CompletionRoute", text = "N b|" })
    G.Register({ id = "t:p", name = "Prof", type = "Professions", prof = "Cooking", faction = "Alliance", minlevel = 5, maxlevel = 6, source = "CompletionRoute", text = "N c|" })
    local nxt = G.SuggestNext(nil)
    t("SuggestNext never returns a Gold or Professions guide", nxt and nxt.type == "Leveling", nxt and nxt.id)
    local sg = G.Suggest()
    t("Suggest never returns a Gold or Professions guide", sg and sg.type == "Leveling", sg and sg.id)
    t("G.Available(type) filter still works for Gold", #G.Available("Gold") >= 1)

    -- a guide ending whose authored next is a Gold guide: nothing Gold gets loaded
    G.Register({ id = "t:chain", name = "Chain", type = "Leveling", faction = "Alliance", minlevel = 1, maxlevel = 10, next = "t:gold", source = "test", text = "N only|" })
    Pr.Load("t:chain")
    Pr.Forward()
    t("authored next pointing at a Gold guide is not auto-loaded", Pr.guide and Pr.guide.id ~= "t:gold", Pr.guide and Pr.guide.id)
    -- a Professions guide that ends stays put instead of jumping to a leveling guide
    G.Register({ id = "t:pend", name = "ProfEnd", type = "Professions", prof = "Cooking", faction = "Alliance", source = "test", text = "N only|" })
    Pr.Load("t:pend")
    Pr.Forward()
    t("a finished Professions guide does not auto-load anything", Pr.guide and Pr.guide.id == "t:pend", Pr.guide and Pr.guide.id)
end

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
print("ALL PROFESSION ENGINE TESTS PASSED")
