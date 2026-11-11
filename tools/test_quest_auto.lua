-- CompletionRoute :: tools/test_quest_auto.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- Offline tests of auto accept and turn-in (Core/QuestAuto.lua, docs/QUEST_AUTO.md): the real addon on stubs, plus a
-- fake quest-dialog client for each API family, on all five flavors (era, tbc, mop, retail, forever):
--   "gossip"    C_GossipInfo lists and selects by quest id (what all five current clients have)
--   "old"       GetGossipAvailableQuests / SelectGossipAvailableQuest by index (removed from every current client; kept
--               for older builds), with and without the quest id appended and with and without the count functions
--   "greeting"  QUEST_GREETING: GetNumAvailableQuests / GetAvailableTitle / GetAvailableQuestInfo / SelectAvailableQuest,
--               with and without quest ids (then the title is matched against the window)
-- Optional APIs follow the real clients: QuestGetAutoAccept, QuestIsFromAreaTrigger, C_QuestLog.IsWorldQuest and
-- C_QuestLog.IsRepeatableQuest only on retail and forever; QUEST_ACCEPT_CONFIRM's quest id only on retail.
-- Covered: in-window quest accepted, out-of-window ignored, dropped / locked / step-skipped quests ignored, the pause key
-- (and the conversation it pauses, key choice, no key), reward choice stops (and the clear-winner path when on), a
-- reward weighing in the hands (two-hander vs shield / one-hand / off-hand, sword and board, dual wield, staff, empty
-- off hand, ranged slot, worn stats unreadable), ignored gossip quests, a quest that costs gold, dailies (a "!" step, a
-- Daily Gold guide, a plain step refuses), log full (one line per NPC), the completable check, turn-ins before accepts,
-- popups and world quests left alone, escort shares, the follow-up a refresh lets in, no second action for one event or
-- a repeated one, no loop after a decline, /cr auto, the options defaults, TOC order, and the
-- CPU of one dialog decision on each flavor's biggest real guide (when Guides/Imported_Wiki_<flavor>.lua exists).
-- Run under the interpreter mode that matches the client:  luajit -joff tools/test_quest_auto.lua [flavors...]
package.path = "./?.lua;" .. package.path
local FLAVORS = {}
for i = 1, #arg do FLAVORS[#FLAVORS + 1] = arg[i] end
if #FLAVORS == 0 then FLAVORS = { "era", "tbc", "mop", "retail", "forever" } end
local FAMILIES = { "gossip", "old", "greeting" }
local passed, failed = 0, 0
local function t(name, cond, detail)
    if cond then passed = passed + 1
    else failed = failed + 1 print("FAIL " .. name .. (detail ~= nil and (" :: " .. tostring(detail)) or "")) end
    return cond
end
local function exists(p) local f = io.open(p, "r") if f then f:close() return true end return false end

local TOC = { era = 11507, tbc = 20506, mop = 50504, retail = 120100, forever = 16001 }
local TAXI = { era = "Data/Taxi_era.lua", tbc = "Data/Taxi_tbc.lua", mop = "Data/Taxi_mop.lua", retail = "Data/Taxi_retail.lua",
               forever = "Data/Taxi_forever.lua" }
local MODERN = { retail = true, forever = true }     -- warcraft.wiki.gg: QuestGetAutoAccept & co. list only these two
local CONFIRM_ID = { retail = true }                 -- QUEST_ACCEPT_CONFIRM questID payload: patch 12.0.5

-- ---------------------------------------------------------------------------
-- Harness: the addon on stubs + the fake dialog client (D)
-- ---------------------------------------------------------------------------
local W, D, NS
local function log(s) D.calls[#D.calls + 1] = s end
local ITEMS = {   -- fake item data for UI/ItemScore.lua: link -> stats, equip slot
    ["item:900"] = { stats = { ITEM_MOD_STRENGTH_SHORT = 5 }, loc = "INVTYPE_HEAD" },    -- worn on the head
    ["item:1001"] = { stats = { ITEM_MOD_STRENGTH_SHORT = 20 }, loc = "INVTYPE_HEAD" },  -- big upgrade
    ["item:1002"] = { stats = { ITEM_MOD_INTELLECT_SHORT = 20 }, loc = "INVTYPE_HEAD" }, -- worthless to a warrior
    ["item:1003"] = { stats = { ITEM_MOD_STRENGTH_SHORT = 18 }, loc = "INVTYPE_HEAD" },  -- almost as good as 1001
    ["item:1004"] = { stats = { ITEM_MOD_STRENGTH_SHORT = 40 }, loc = "INVTYPE_HEAD" },  -- best, but the class cannot use it
    ["item:1005"] = { stats = { ITEM_MOD_STRENGTH_SHORT = 21 }, loc = "INVTYPE_HEAD" },  -- 5% over item:1001
    -- the hands (warrior scores in brackets: STR 1.0, STA 0.6, DPS 3.2, armor 0.03; mage: INT 0.9, STA 0.35)
    ["item:2001"] = { stats = { ITEM_MOD_STRENGTH_SHORT = 30, ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 15 }, loc = "INVTYPE_2HWEAPON" },  -- two-hand sword [78]
    ["item:2002"] = { stats = { ITEM_MOD_STRENGTH_SHORT = 4, ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 6 }, loc = "INVTYPE_WEAPON" },     -- one-hand sword [23.2]
    ["item:2003"] = { stats = { ITEM_MOD_STAMINA_SHORT = 4, RESISTANCE0_NAME = 300 }, loc = "INVTYPE_SHIELD" },                   -- shield [11.4]
    ["item:2004"] = { stats = { ITEM_MOD_INTELLECT_SHORT = 10, ITEM_MOD_STAMINA_SHORT = 2 }, loc = "INVTYPE_HOLDABLE" },          -- off-hand orb [mage 9.7]
    ["item:2005"] = { stats = { ITEM_MOD_STRENGTH_SHORT = 3, ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 5 }, loc = "INVTYPE_WEAPONOFFHAND" }, -- off-hand weapon [19]
    ["item:2006"] = { stats = { ITEM_MOD_STRENGTH_SHORT = 34, ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 16 }, loc = "INVTYPE_2HWEAPON" },  -- two-hand axe [85.2]
    ["item:2007"] = { stats = { ITEM_MOD_STRENGTH_SHORT = 8, ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 7 }, loc = "INVTYPE_2HWEAPON" },    -- weak two-hander [30.4]
    ["item:2008"] = { stats = { ITEM_MOD_AGILITY_SHORT = 5, ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 10 }, loc = "INVTYPE_RANGED" },     -- bow [34.5]
    ["item:2009"] = { stats = { ITEM_MOD_AGILITY_SHORT = 2, ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 5 }, loc = "INVTYPE_RANGED" },      -- worn bow [17]
    ["item:2010"] = { stats = { ITEM_MOD_STRENGTH_SHORT = 2 }, loc = "INVTYPE_HAND" },                                             -- worn gloves [2]
    ["item:2011"] = { stats = { ITEM_MOD_STRENGTH_SHORT = 4 }, loc = "INVTYPE_HAND" },                                             -- better gloves [4, +100%]
    ["item:2012"] = { stats = { ITEM_MOD_INTELLECT_SHORT = 20, ITEM_MOD_STAMINA_SHORT = 5 }, loc = "INVTYPE_2HWEAPON" },          -- staff [mage 19.75]
    ["item:2013"] = { stats = { ITEM_MOD_STRENGTH_SHORT = 1, ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 3 }, loc = "INVTYPE_WEAPON" },     -- weak one-hand [10.6]
    ["item:2014"] = { stats = { ITEM_MOD_STRENGTH_SHORT = 6, ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 6 }, loc = "INVTYPE_WEAPON" },     -- one-hand [25.2]
    ["item:2015"] = { stats = { ITEM_MOD_STRENGTH_SHORT = 3 }, loc = "INVTYPE_FINGER" },                                           -- ring [3]
}
-- what the character wears: slot -> item link (D.worn); CanDualWield() answers D.dualWield
local function wear(slots)
    D.worn = slots
    GetInventoryItemLink = function(_, slot) return D.worn[slot] end
end
local function installClient(flavor, family)
    D = { calls = {}, npc = "Creature-0-1-2-3-100-0001", mods = {}, offers = {}, active = {}, cur = nil, log = 3, cap = 20,
          timers = {}, now = 1000, oldIds = true, oldCounts = true, greetIds = true, greetComplete = true, popups = {} }
    C_Timer = { After = function(_, fn) D.timers[#D.timers + 1] = fn end }   -- Progress's 0.3 s refresh waits for flush()
    GetTime = function() return D.now end
    IsShiftKeyDown = function() return D.mods.SHIFT and true or false end
    IsControlKeyDown = function() return D.mods.CTRL and true or false end
    IsAltKeyDown = function() return D.mods.ALT and true or false end
    UnitGUID = function(u) if u == "npc" or u == "questnpc" then return D.npc end return nil end
    -- quest frame
    GetQuestID = function() return D.cur and D.cur.q or 0 end
    GetTitleText = function() return D.cur and D.cur.title end
    QuestIsDaily = function() return D.cur and D.cur.daily or nil end
    QuestIsWeekly = function() return D.cur and D.cur.weekly or nil end
    GetQuestMoneyToGet = function() return D.cur and D.cur.money or 0 end
    IsQuestCompletable = function() return D.cur and D.cur.completable or false end
    GetNumQuestChoices = function() return D.cur and D.cur.choices and #D.cur.choices or 0 end
    GetQuestItemLink = function(kind, i) local c = kind == "choice" and D.cur.choices[i] return c and c.link end
    GetQuestItemInfo = function(kind, i)
        local c = kind == "choice" and D.cur.choices[i]
        if not c then return nil end
        return c.link or "?", 134400, 1, 2, c.usable
    end
    AcceptQuest = function() log("AcceptQuest " .. tostring(D.cur and D.cur.q)) end
    CompleteQuest = function() log("CompleteQuest " .. tostring(D.cur and D.cur.q)) end
    GetQuestReward = function(i) log("GetQuestReward " .. tostring(i)) end
    ConfirmAcceptQuest = function() log("ConfirmAcceptQuest") end
    StaticPopup_Hide = function(which) D.popups[#D.popups + 1] = which end
    if MODERN[flavor] then
        QuestGetAutoAccept = function() return D.cur and D.cur.autoAccepted or false end
        QuestIsFromAreaTrigger = function() return D.cur and D.cur.area or false end
    else
        QuestGetAutoAccept, QuestIsFromAreaTrigger = nil, nil
    end
    -- items (UI/ItemScore.lua) and the head slot
    C_Item = C_Item or {}
    C_Item.GetItemStats = function(link) local it = ITEMS[link] return it and it.stats end
    C_Item.GetItemInfo = function(link) local it = ITEMS[link] if not it then return nil end return link, link, 2, 10, 1, "Armor", "Plate", 1, it.loc end
    wear({ [1] = "item:900" })
    CanDualWield = function() return D.dualWield and true or false end   -- all five clients (warcraft.wiki.gg API_CanDualWield)
    -- gossip API family
    C_GossipInfo, GetGossipAvailableQuests, GetGossipActiveQuests, SelectGossipAvailableQuest, SelectGossipActiveQuest = nil, nil, nil, nil, nil
    GetNumGossipAvailableQuests, GetNumGossipActiveQuests = nil, nil
    LE_QUEST_FREQUENCY_DEFAULT, LE_QUEST_FREQUENCY_DAILY, LE_QUEST_FREQUENCY_WEEKLY = nil, nil, nil
    if family == "old" then
        Enum = nil
        LE_QUEST_FREQUENCY_DEFAULT, LE_QUEST_FREQUENCY_DAILY, LE_QUEST_FREQUENCY_WEEKLY = 1, 2, 3
        GetGossipAvailableQuests = function()
            local v = {}
            for _, x in ipairs(D.offers) do
                for _, y in ipairs({ x.title, 10, false, x.daily and 2 or 1, x.repeatable or false, false, x.ignored or false }) do v[#v + 1] = y end
                if D.oldIds then v[#v + 1] = x.q end
            end
            return unpack(v)
        end
        GetGossipActiveQuests = function()
            local v = {}
            for _, x in ipairs(D.active) do
                for _, y in ipairs({ x.title, 10, false, x.complete or false, false, false }) do v[#v + 1] = y end
                if D.oldIds then v[#v + 1] = x.q end
            end
            return unpack(v)
        end
        if D.oldCounts then
            GetNumGossipAvailableQuests = function() return #D.offers end
            GetNumGossipActiveQuests = function() return #D.active end
        end
        SelectGossipAvailableQuest = function(i) log("SelectGossipAvailableQuest #" .. i) end
        SelectGossipActiveQuest = function(i) log("SelectGossipActiveQuest #" .. i) end
    else
        Enum = { QuestFrequency = { Default = 0, Daily = 1, Weekly = 2, ResetByScheduler = 3 } }
        C_GossipInfo = {
            GetAvailableQuests = function()
                local o = {}
                for _, x in ipairs(D.offers) do
                    o[#o + 1] = { title = x.title, questID = x.q, questLevel = 10, isTrivial = false, isLegendary = false,
                                  frequency = x.daily and 1 or 0, repeatable = x.repeatable or false, isIgnored = x.ignored or false }
                end
                return o
            end,
            GetActiveQuests = function()
                local o = {}
                for _, x in ipairs(D.active) do o[#o + 1] = { title = x.title, questID = x.q, isComplete = x.complete or false } end
                return o
            end,
            SelectAvailableQuest = function(id) log("C_GossipInfo.SelectAvailableQuest " .. id) end,
            SelectActiveQuest = function(id) log("C_GossipInfo.SelectActiveQuest " .. id) end,
        }
    end
    -- QUEST_GREETING (every client has it; the fake can withhold the quest ids and the "complete" flag)
    GetNumAvailableQuests = function() return #D.offers end
    GetAvailableTitle = function(i) return D.offers[i] and D.offers[i].title end
    GetAvailableQuestInfo = function(i)
        local x = D.offers[i]
        if not x then return nil end
        return false, x.daily and (Enum and 1 or 2) or (Enum and 0 or 1), x.repeatable or false, false, D.greetIds and x.q or nil
    end
    SelectAvailableQuest = function(i) log("SelectAvailableQuest #" .. i) end
    GetNumActiveQuests = function() return #D.active end
    GetActiveTitle = function(i)
        local x = D.active[i]
        if not x then return nil end
        if D.greetComplete then return x.title, x.complete or false end
        return x.title
    end
    GetActiveQuestID = D.greetIds and function(i) return D.active[i] and D.active[i].q end or nil
    SelectActiveQuest = function(i) log("SelectActiveQuest #" .. i) end
end

local function harness(flavor, family)
    W = { quests = {}, level = 10 }
    STUB_MAPS = dofile("tools/maps_" .. flavor .. ".lua")
    dofile("tools/stubs.lua")
    GetBuildInfo = function() return "x", "0", "2026", TOC[flavor] end
    UnitLevel = function() return W.level end
    installClient(flavor, family)
    C_QuestLog = {
        IsOnQuest = function(q) local s = W.quests[q] return s == "log" or s == "complete" end,
        IsQuestFlaggedCompleted = function(q) return W.quests[q] == "done" end,
        IsComplete = function(q) return W.quests[q] == "complete" end,
        GetLogIndexForQuestID = function(q) local s = W.quests[q] return (s == "log" or s == "complete") and 1 or nil end,
        GetQuestObjectives = function() return {} end,
        GetAllCompletedQuestIDs = function() local o = {} for q, s in pairs(W.quests) do if s == "done" then o[#o + 1] = q end end return o end,
        GetNumQuestLogEntries = function() return D.log, D.log end,
        GetMaxNumQuestsCanAccept = function() return D.cap end,
    }
    if MODERN[flavor] then
        C_QuestLog.IsWorldQuest = function(q) return D.worldQuests and D.worldQuests[q] or false end
        C_QuestLog.IsRepeatableQuest = function(q) return D.repeatables and D.repeatables[q] or false end
    end
    SlashCmdList = {}
    PLAYER = { map = 1429, x = 0.5, y = 0.5 }
    local ADDON
    ADDON, NS = "CompletionRoute", {}
    local function load(p, optional)
        if optional and not exists("CompletionRoute/" .. p) then return false end
        assert(loadfile("CompletionRoute/" .. p))(ADDON, NS)
        return true
    end
    local files = { "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", TAXI[flavor] }
    if flavor == "forever" then files[#files + 1] = "Data/MapFix_forever.lua" end
    -- TOC order: Core/QuestAuto.lua right after Core/Skip.lua; UI/ItemScore.lua later (looked up at turn-in time)
    for _, f in ipairs({ "Data/Transit.lua", "Data/Access.lua", "Data/Inns.lua", "Data/ZoneAliases.lua", "Data/Roads_ek.lua",
        "Data/Roads_kalimdor.lua", "Routing/CostModel.lua", "Routing/TravelGraph.lua", "Routing/Roads.lua", "Routing/StepOrder.lua", "Routing/Router.lua",
        "Routing/Replan.lua", "Core/Account.lua", "Core/Professions.lua", "Core/Progress.lua", "Core/Skip.lua", "Core/QuestAuto.lua",
        "Core/Recommend.lua", "UI/ItemScore.lua", "Core/Slash.lua" }) do
        files[#files + 1] = f
    end
    for _, f in ipairs(files) do load(f) end
    load("Data/Imported_Entrances.lua", true)
    CompletionRouteDB, CompletionRouteCharDB = nil, nil
    for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", "CompletionRoute") end
    NS.printed = {}
    NS.Print = function(_, ...) local p = {} for i = 1, select("#", ...) do p[#p + 1] = tostring(select(i, ...)) end NS.printed[#NS.printed + 1] = table.concat(p, " ") end
    NS.Debug, NS.Error = function() end, function() end
    NS.db.profile.routing.liveBudgetMs = 1e9    -- the live window has its own budget test (tools/test_live_route.lua)
    NS.Guide.SuggestNext = function() return nil end
    NS.Guide.Suggest = function() return nil end
    NS.TravelGraph.Build()
    return NS
end
local function place(map, x, y)
    local wx, wy, inst = z2w(x, y, map)
    if not wx then return false end
    PLAYER.map, PLAYER.x, PLAYER.y, PLAYER.wx, PLAYER.wy, PLAYER.inst = map, x, y, wx, wy, inst
    return true
end
local function flush() local q = D.timers D.timers = {} for _, fn in ipairs(q) do fn() end end

-- fire a client event at every handler, as the addon's event frame does; returns the calls that changed something
local overActions = 0
local function fire(evt, ...)
    local n0 = #D.calls
    for _, h in ipairs(NS.wowHandlers[evt] or {}) do
        local ok, err = pcall(h, evt, ...)
        if not ok then t("no Lua error in " .. evt, false, err) end
    end
    local out = {}
    for i = n0 + 1, #D.calls do out[#out + 1] = D.calls[i] end
    if #out > 1 then overActions = overActions + 1 end
    return out
end
local function one(calls, want) return #calls == 1 and calls[1] == want end
local function none(calls) return #calls == 0 end
local function show(calls) return #calls == 0 and "(nothing)" or table.concat(calls, "; ") end
local function why() return NS.QuestAuto.last and NS.QuestAuto.last.why end
local function printedSince(n0, pat)
    for i = n0 + 1, #NS.printed do if NS.printed[i]:find(pat, 1, true) then return NS.printed[i] end end
    return nil
end
-- open a quest dialog of quest q (the fields the quest frame API reads)
local function dialog(q, title, extra)
    D.cur = { q = q, title = title }
    for k, v in pairs(extra or {}) do D.cur[k] = v end
end
-- a fresh conversation: new quest giver, nothing remembered, keys up
local npcN = 0
local function newNPC()
    npcN = npcN + 1
    D.npc = ("Creature-0-1-2-3-%d-0001"):format(100 + npcN)
    D.mods = {}
    D.now = D.now + 120
end

local Z = "|Z|1429; Elwynn Forest|"
local LINES = {
    "A Alpha|QID|201|M|40,40" .. Z,                   -- 1
    "A Bravo|QID|202|M|40,41" .. Z,                   -- 2
    "A Charlie|QID|203|M|40,42" .. Z,                 -- 3
    "C Alpha|QID|201|M|45,45" .. Z,                   -- 4
    "T Alpha|QID|201|M|40,40" .. Z,                   -- 5
    "C Bravo|QID|202|M|45,46" .. Z,                   -- 6
    "T Bravo|QID|202|M|40,41" .. Z,                   -- 7
    "! Delta|QID|204|M|41,40" .. Z,                   -- 8  a daily step
    "A Echo|QID|205|M|41,41" .. Z,                    -- 9  a plain step for a quest the game offers as a daily
    "A Foxtrot|QID|206|M|41,42" .. Z,                 -- 10 costs gold
    "A Hotel|QID|208|M|42,40" .. Z,                   -- 11
    "T Hotel|QID|208|M|42,40" .. Z,                   -- 12
    "A India|QID|209|PRE|208|M|42,40" .. Z,           -- 13 opens once 208 is in the log
    "T India|QID|209|PRE|208|M|42,40" .. Z,           -- 14
    "A Root|QID|220|M|43,40" .. Z,                    -- 15
    "A Leaf|QID|221|PRE|220|M|43,40" .. Z,            -- 16 dropping 220 locks it
    "T Charlie|QID|203|M|40,42" .. Z,                 -- 17
}
for k = 1, 10 do LINES[#LINES + 1] = ("A Filler %d|QID|%d|M|%d,60"):format(k, 230 + k, 30 + k) .. Z end
LINES[#LINES + 1] = "A Far|QID|299|M|50,50" .. Z       -- 28: far past the window
local GUIDE = table.concat(LINES, "\n")

local function setup(flavor, family)
    harness(flavor, family)
    local G = NS.Guide
    G.Register({ id = "t:auto:a", name = "Auto A", type = "Quests", zone = 1429, faction = "Alliance", minlevel = 1, maxlevel = 20, text = GUIDE })
    G.Register({ id = "gold:test:daily", name = "Daily Gold: test", type = "Gold", folder = "Daily Gold", goldKind = "Daily Gold", noCircuit = true,
                 zone = 1429, faction = "Alliance", minlevel = 1, maxlevel = 20,
                 text = "A Golf|QID|240|M|44,44" .. Z .. "\nT Golf|QID|240|M|44,44" .. Z })
    local elwynn = NS.Util.MapIDByName("Elwynn Forest")
    place(elwynn, 0.4, 0.4)
    NS.db.profile.routing.window = 10        -- live window = the next 10 + 5 pending steps
    NS.db.profile.autoAccept, NS.db.profile.autoTurnin = true, true
    NS.Progress.Load("t:auto:a")
    NS.QuestAuto.ResetState()
end
local function inWindow(q) local w = NS.QuestAuto.Window() return w and w.quests[q] ~= nil end

-- ---------------------------------------------------------------------------
-- 1) Every flavor x API family
-- ---------------------------------------------------------------------------
local function listEvent(family) return family == "greeting" and "QUEST_GREETING" or "GOSSIP_SHOW" end
local function pickAvail(family, q, index)
    if family == "gossip" then return "C_GossipInfo.SelectAvailableQuest " .. q end
    if family == "old" then return "SelectGossipAvailableQuest #" .. index end
    return "SelectAvailableQuest #" .. index
end
local function pickActive(family, q, index)
    if family == "gossip" then return "C_GossipInfo.SelectActiveQuest " .. q end
    if family == "old" then return "SelectGossipActiveQuest #" .. index end
    return "SelectActiveQuest #" .. index
end

local function scenario(flavor, family)
    local tag = flavor .. "/" .. family .. ": "
    setup(flavor, family)
    local QA, P, S = NS.QuestAuto, NS.Progress, NS.Skip
    local LE = listEvent(family)
    t(tag .. "defaults: pause key Shift, reward choice off", QA.Key() == "SHIFT" and NS.defaults.profile.autoChooseReward == false
        and NS.defaults.profile.autoAccept == false and NS.defaults.profile.autoTurnin == false)
    t(tag .. "setup: the guide's next quests are in the window", inWindow(201) and inWindow(202) and inWindow(203) and inWindow(204))
    t(tag .. "setup: 299 is outside the window, 209 is not open yet", not inWindow(299) and not inWindow(209))

    -- the list: an in-window quest is picked, an out-of-window one never
    newNPC()
    D.offers = { { q = 299, title = "Far" }, { q = 202, title = "Bravo" }, { q = 203, title = "Charlie" } }
    D.active = {}
    local c = fire(LE)
    t(tag .. "list: picks the in-window quest (not the far one listed first)", one(c, pickAvail(family, 202, 2)), show(c))
    c = fire(LE)
    t(tag .. "list: the same event again before the dialog moved on does nothing", none(c), show(c))
    fire("GOSSIP_CLOSED")
    c = fire(LE)
    t(tag .. "list: after the close, the next in-window quest (202 is not picked twice)", one(c, pickAvail(family, 203, 3)), show(c))
    fire("GOSSIP_CLOSED")
    D.offers = { { q = 299, title = "Far" } }
    c = fire(LE)
    t(tag .. "list: only an out-of-window quest: nothing", none(c), show(c))
    -- a quest the player told the client to ignore (C_GossipInfo isIgnored; the old API's 7th value) is never picked
    if family ~= "greeting" then
        newNPC()
        D.offers = { { q = 202, title = "Bravo", ignored = true }, { q = 203, title = "Charlie" } }
        c = fire(LE)
        t(tag .. "list: an ignored in-window quest is passed over for the next one", one(c, pickAvail(family, 203, 2)), show(c))
        newNPC()
        D.offers = { { q = 202, title = "Bravo", ignored = true } }
        c = fire(LE)
        t(tag .. "list: only an ignored in-window quest: nothing", none(c), show(c))
    end

    -- the quest text: accept in-window, refuse out-of-window, once per event
    newNPC()
    dialog(202, "Bravo")
    c = fire("QUEST_DETAIL")
    t(tag .. "detail: in-window quest accepted", one(c, "AcceptQuest 202"), show(c))
    c = fire("QUEST_DETAIL")
    t(tag .. "detail: the same quest text again is not accepted twice", none(c), show(c))
    dialog(299, "Far")
    c = fire("QUEST_DETAIL")
    t(tag .. "detail: out-of-window quest left alone", none(c) and why() == "not in window", show(c) .. " " .. tostring(why()))
    -- the window moves with the guide: the quest after the accepted one is not suddenly "in"
    t(tag .. "detail: nothing past the window got in", not inWindow(299))

    -- no quest id from the dialog: matched by title against the window
    dialog(nil, "Charlie")
    D.cur.q = nil
    c = fire("QUEST_DETAIL")
    t(tag .. "detail: no quest id, the title of a window quest is enough", one(c, "AcceptQuest nil"), show(c))

    -- dropped and locked quests (Core/Skip.lua)
    newNPC()
    S.SkipQuest(220, { confirm = true })
    t(tag .. "skip: 220 dropped, 221 locked", S.IsRoot(220) and S.LockedBy(221) == 220)
    dialog(220, "Root")
    c = fire("QUEST_DETAIL")
    t(tag .. "dropped quest not accepted", none(c) and why() == "dropped", show(c) .. " " .. tostring(why()))
    dialog(221, "Leaf")
    c = fire("QUEST_DETAIL")
    t(tag .. "locked quest not accepted", none(c) and why() == "locked", show(c) .. " " .. tostring(why()))
    D.offers = { { q = 220, title = "Root" }, { q = 221, title = "Leaf" } }
    c = fire(LE)
    t(tag .. "list: dropped and locked quests are not picked", none(c), show(c))
    S.Unskip(220)
    t(tag .. "unskip: 220 is back in the window", inWindow(220))

    -- steps the player skipped: a turn-in step (nothing depends on it, so it is a plain step skip) and an accept step;
    -- both quests keep other steps in the window, and are still left alone
    newNPC()
    W.quests[202] = "log"
    P.Refresh()
    local t202, a203
    for _, s in ipairs(P.steps) do
        if s.action == "T" and s.qid[1] == 202 then t202 = s end
        if s.action == "A" and s.qid[1] == 203 then a203 = s end
    end
    P.Skip(t202)
    P.Skip(a203)
    t(tag .. "skipped steps: their quests still have steps in the window", inWindow(202) and inWindow(203))
    dialog(202, "Bravo", { completable = true })
    c = fire("QUEST_PROGRESS")
    t(tag .. "skipped turn-in step: not completed", none(c) and why() == "step skipped", show(c) .. " " .. tostring(why()))
    D.active = { { q = 202, title = "Bravo", complete = true } }
    D.offers = {}
    c = fire(LE)
    t(tag .. "skipped turn-in step: not picked from the list either", none(c), show(c))
    dialog(203, "Charlie")
    c = fire("QUEST_DETAIL")
    t(tag .. "skipped accept step: not accepted", none(c) and why() == "step skipped", show(c) .. " " .. tostring(why()))
    D.active = {}
    D.offers = { { q = 203, title = "Charlie" } }
    c = fire(LE)
    t(tag .. "skipped accept step: not picked from the list either", none(c), show(c))
    local marks = P.SkippedMarks()
    marks[t202.key], marks[a203.key] = nil, nil      -- skip marks are keyed by stable step key
    W.quests[202] = nil
    P.cursor = nil
    P.Refresh()

    -- turn-ins come before accepts at the same quest giver
    newNPC()
    W.quests[201] = "complete"
    P.Refresh()
    D.active = { { q = 201, title = "Alpha", complete = true } }
    D.offers = { { q = 204, title = "Delta", daily = true } }
    c = fire(LE)
    t(tag .. "list: the turn-in first", one(c, pickActive(family, 201, 1)), show(c))
    -- an active quest that is not complete is never picked
    newNPC()
    W.quests[203] = "log"
    D.active = { { q = 203, title = "Charlie", complete = false } }
    D.offers = {}
    c = fire(LE)
    t(tag .. "list: an unfinished active quest is not picked", none(c), show(c))

    -- QUEST_PROGRESS: only when completable
    newNPC()
    dialog(201, "Alpha", { completable = false })
    c = fire("QUEST_PROGRESS")
    t(tag .. "progress: not completable -> nothing", none(c) and why() == "not completable", show(c) .. " " .. tostring(why()))
    dialog(201, "Alpha", { completable = true })
    c = fire("QUEST_PROGRESS")
    t(tag .. "progress: completable -> CompleteQuest once", one(c, "CompleteQuest 201"), show(c))
    c = fire("QUEST_PROGRESS")
    t(tag .. "progress: the same page again does nothing", none(c), show(c))
    dialog(201, "Alpha", { completable = true, money = 10000 })
    NS.QuestAuto.ResetState()
    local n0 = #NS.printed
    c = fire("QUEST_PROGRESS")
    t(tag .. "progress: a turn-in that costs gold is left to the player, with a hint", none(c) and why() == "costs gold" and printedSince(n0, "costs 1g"),
        show(c) .. " " .. tostring(why()))

    -- QUEST_COMPLETE: rewards
    newNPC()
    dialog(201, "Alpha", { choices = {} })
    c = fire("QUEST_COMPLETE")
    t(tag .. "complete: no choice -> GetQuestReward(0)", one(c, "GetQuestReward 0"), show(c))
    NS.QuestAuto.ResetState()
    dialog(201, "Alpha", { choices = { { link = "item:1001", usable = true } } })
    c = fire("QUEST_COMPLETE")
    t(tag .. "complete: one choice -> GetQuestReward(1)", one(c, "GetQuestReward 1"), show(c))
    NS.QuestAuto.ResetState()
    dialog(201, "Alpha", { choices = { { link = "item:1001", usable = true }, { link = "item:1002", usable = true } } })
    n0 = #NS.printed
    c = fire("QUEST_COMPLETE")
    local hintLine = printedSince(n0, "choose your reward")
    t(tag .. "complete: a reward choice stops, dialog left open, one chat line", none(c) and hintLine ~= nil and #NS.printed == n0 + 1, show(c) .. " " .. tostring(hintLine))
    c = fire("QUEST_COMPLETE")
    t(tag .. "complete: the same reward page again: no second hint", none(c) and #NS.printed == n0 + 1, #NS.printed - n0)
    NS.db.profile.autoChooseReward = true
    NS.QuestAuto.ResetState()
    c = fire("QUEST_COMPLETE")
    t(tag .. "complete (auto choose on): a clear upgrade is taken", one(c, "GetQuestReward 1"), show(c))
    NS.QuestAuto.ResetState()
    dialog(201, "Alpha", { choices = { { link = "item:1001", usable = true }, { link = "item:1003", usable = true } } })
    c = fire("QUEST_COMPLETE")
    t(tag .. "complete (auto choose on): two close upgrades -> stops", none(c), show(c))
    NS.QuestAuto.ResetState()
    dialog(201, "Alpha", { choices = { { link = "item:1004", usable = false }, { link = "item:1001", usable = true } } })
    c = fire("QUEST_COMPLETE")
    t(tag .. "complete (auto choose on): an item the class cannot use never wins", one(c, "GetQuestReward 2"), show(c))
    NS.QuestAuto.ResetState()
    dialog(201, "Alpha", { choices = { { link = nil, usable = true }, { link = "item:1001", usable = true } } })
    c = fire("QUEST_COMPLETE")
    t(tag .. "complete (auto choose on): item data not loaded -> stops", none(c), show(c))
    -- the hands: an empty off hand next to a two-hand weapon is not a free slot (it once counted as a +100% upgrade and
    -- took a shield over better gloves)
    wear({ [1] = "item:900", [16] = "item:2001", [10] = "item:2010" })
    NS.QuestAuto.ResetState()
    dialog(201, "Alpha", { choices = { { link = "item:2003", usable = true }, { link = "item:2011", usable = true } } })
    c = fire("QUEST_COMPLETE")
    t(tag .. "complete (auto choose on): two-hand user, shield or better gloves -> the gloves, never the shield", one(c, "GetQuestReward 2"), show(c))
    NS.QuestAuto.ResetState()
    dialog(201, "Alpha", { choices = { { link = "item:2003", usable = true }, { link = "item:2002", usable = true } } })
    c = fire("QUEST_COMPLETE")
    t(tag .. "complete (auto choose on): two-hand user, shield or one-hand sword (both below the two-hander) -> stops", none(c), show(c))
    wear({ [1] = "item:900", [16] = "item:2002", [10] = "item:2010" })
    NS.QuestAuto.ResetState()
    dialog(201, "Alpha", { choices = { { link = "item:2003", usable = true }, { link = "item:2011", usable = true } } })
    n0 = #NS.printed
    c = fire("QUEST_COMPLETE")
    t(tag .. "complete (auto choose on): one-hand weapon, empty off hand: the shield cannot be weighed -> stops with a hint",
        none(c) and printedSince(n0, "cannot be weighed: empty off hand") ~= nil, show(c) .. " " .. tostring(NS.printed[n0 + 1]))
    wear({ [1] = "item:900" })
    NS.db.profile.autoChooseReward = false

    -- the pause key
    newNPC()
    D.mods.SHIFT = true
    D.offers = { { q = 202, title = "Bravo" } }
    D.active = {}
    W.quests[202] = nil
    c = fire(LE)
    t(tag .. "Shift held: the list is left alone", none(c) and why() == "paused", show(c))
    D.mods.SHIFT = false
    D.now = D.now + 3
    dialog(202, "Bravo")
    c = fire("QUEST_DETAIL")
    t(tag .. "...the rest of that conversation stays paused after the key is let go", none(c) and why() == "paused", show(c))
    D.now = D.now + NS.QuestAuto.PAUSE_GAP + 1
    c = fire("QUEST_DETAIL")
    t(tag .. "...and resumes once the conversation has gone quiet", one(c, "AcceptQuest 202"), show(c))
    newNPC()
    D.mods.SHIFT = true
    dialog(203, "Charlie")
    W.quests[203] = nil
    c = fire("QUEST_DETAIL")
    t(tag .. "Shift held on the quest text: not accepted", none(c), show(c))
    newNPC()
    NS.db.profile.autoModifier = "CTRL"
    D.mods.SHIFT = true
    c = fire("QUEST_DETAIL")
    t(tag .. "pause key Ctrl: Shift no longer pauses", one(c, "AcceptQuest 203"), show(c))
    newNPC()
    D.mods.CTRL = true
    dialog(202, "Bravo")
    c = fire("QUEST_DETAIL")
    t(tag .. "pause key Ctrl: Ctrl pauses", none(c), show(c))
    newNPC()
    NS.db.profile.autoModifier = "NONE"
    D.mods.SHIFT, D.mods.CTRL, D.mods.ALT = true, true, true
    c = fire("QUEST_DETAIL")
    t(tag .. "no pause key: nothing pauses", one(c, "AcceptQuest 202"), show(c))
    NS.db.profile.autoModifier = "SHIFT"

    -- gold, dailies, log full
    newNPC()
    dialog(206, "Foxtrot", { money = 5000 })
    n0 = #NS.printed
    c = fire("QUEST_DETAIL")
    t(tag .. "a quest that costs gold is not accepted (hint in chat)", none(c) and why() == "costs gold" and printedSince(n0, "costs 50s"), show(c) .. " " .. tostring(why()))
    dialog(204, "Delta", { daily = true })
    c = fire("QUEST_DETAIL")
    t(tag .. "daily: accepted when the guide step is that daily ('!')", one(c, "AcceptQuest 204"), show(c))
    dialog(205, "Echo", { daily = true })
    c = fire("QUEST_DETAIL")
    t(tag .. "daily: a plain guide step does not take a daily", none(c) and why() == "repeatable", show(c) .. " " .. tostring(why()))
    dialog(205, "Echo", { weekly = true })
    c = fire("QUEST_DETAIL")
    t(tag .. "weekly: same", none(c) and why() == "repeatable", show(c))
    D.offers = { { q = 205, title = "Echo", daily = true }, { q = 206, title = "Foxtrot" } }
    c = fire(LE)
    t(tag .. "list: a daily the step does not ask for is passed over", one(c, pickAvail(family, 206, 2)), show(c))
    if MODERN[flavor] then
        newNPC()
        D.repeatables = { [205] = true }
        dialog(205, "Echo")
        c = fire("QUEST_DETAIL")
        t(tag .. "repeatable (C_QuestLog.IsRepeatableQuest): not taken by a plain step", none(c) and why() == "repeatable", show(c))
        D.repeatables = nil
    end
    newNPC()
    D.log = D.cap
    dialog(202, "Bravo")
    W.quests[202] = nil
    n0 = #NS.printed
    c = fire("QUEST_DETAIL")
    t(tag .. "log full: not accepted, and chat says so", none(c) and why() == "log full" and printedSince(n0, "quest log full"), show(c) .. " " .. tostring(why()))
    D.offers = { { q = 202, title = "Bravo" } }
    c = fire(LE)
    t(tag .. "log full: not picked from the list either", none(c), show(c))
    -- three window quests at one quest giver with a full log: one chat line for all three, not one each
    newNPC()
    W.quests[203], W.quests[208] = nil, nil
    D.offers = { { q = 202, title = "Bravo" }, { q = 203, title = "Charlie" }, { q = 208, title = "Hotel" } }
    D.active = {}
    n0 = #NS.printed
    c = fire(LE)
    local fullLine = printedSince(n0, "quest log full")
    t(tag .. "log full, three window quests at one NPC: one chat line naming the first and the count",
        none(c) and #NS.printed == n0 + 1 and fullLine and fullLine:find("Bravo and 2 more", 1, true) ~= nil,
        show(c) .. " lines " .. (#NS.printed - n0) .. " " .. tostring(fullLine))
    fire("GOSSIP_CLOSED")
    dialog(203, "Charlie")
    c = fire("QUEST_DETAIL")
    t(tag .. "log full: the quest text that follows in the same conversation adds no second line", none(c) and #NS.printed == n0 + 1,
        #NS.printed - n0)
    D.log = 3

    -- popups: no quest giver, the game's own auto-accept and area offers, world quests
    newNPC()
    D.npc = nil
    dialog(202, "Bravo")
    c = fire("QUEST_DETAIL")
    t(tag .. "no quest giver (a popup another addon or the game opened): left alone", none(c) and why() == "no quest giver (popup)", show(c))
    c = fire("QUEST_DETAIL", 5000)
    t(tag .. "a quest started from an item (questStartItemID) is accepted", one(c, "AcceptQuest 202"), show(c))
    dialog(201, "Alpha", { completable = true })
    c = fire("QUEST_PROGRESS")
    t(tag .. "popup turn-in without a quest giver: left alone", none(c), show(c))
    c = fire("QUEST_COMPLETE")
    t(tag .. "popup reward page without a quest giver: left alone", none(c), show(c))
    newNPC()
    if MODERN[flavor] then
        dialog(203, "Charlie", { autoAccepted = true })
        c = fire("QUEST_DETAIL")
        t(tag .. "QuestGetAutoAccept: already taken by the game, left alone", none(c), show(c))
        dialog(203, "Charlie", { area = true })
        c = fire("QUEST_DETAIL")
        t(tag .. "QuestIsFromAreaTrigger: left alone", none(c), show(c))
        D.worldQuests = { [203] = true }
        dialog(203, "Charlie")
        c = fire("QUEST_DETAIL")
        t(tag .. "world quest: left alone", none(c) and why() == "world quest", show(c))
        D.worldQuests = nil
    else
        t(tag .. "this client has no QuestGetAutoAccept (classic): nothing to guard", QuestGetAutoAccept == nil)
    end

    -- escort shares (QUEST_ACCEPT_CONFIRM)
    newNPC()
    W.quests[203] = nil
    c = fire("QUEST_ACCEPT_CONFIRM", "Partymate", "Charlie", CONFIRM_ID[flavor] and 203 or nil)
    t(tag .. "escort share of a window quest: confirmed", one(c, "ConfirmAcceptQuest") and D.popups[#D.popups] == "QUEST_ACCEPT", show(c))
    c = fire("QUEST_ACCEPT_CONFIRM", "Partymate", "Far", CONFIRM_ID[flavor] and 299 or nil)
    t(tag .. "escort share of a quest outside the window: left alone", none(c), show(c))
    D.mods.SHIFT = true
    c = fire("QUEST_ACCEPT_CONFIRM", "Partymate", "Bravo", CONFIRM_ID[flavor] and 202 or nil)
    t(tag .. "escort share with Shift held: left alone", none(c), show(c))

    -- the window refreshes first after a quest change: the follow-up the same NPC offers at once is already in it
    newNPC()
    t(tag .. "follow-up: 209 is not open before 208", not inWindow(209))
    W.quests[208] = "log"
    fire("QUEST_ACCEPTED", 208)
    local inOrder = false
    for _, s in ipairs(P.order) do if s.qid and s.qid[1] == 209 then inOrder = true end end
    t(tag .. "follow-up: Progress's own refresh (a timer) has not run yet: its list still lacks 209", not inOrder)
    dialog(209, "India")
    c = fire("QUEST_DETAIL")
    t(tag .. "follow-up: accepted at once (the window reads the pending steps until Progress refreshes)", one(c, "AcceptQuest 209"), show(c) .. " " .. tostring(why()))
    flush()
    t(tag .. "follow-up: Progress's refresh clears the stale window", NS.QuestAuto.Window().fresh == false)

    -- no loop after a decline: a picked quest is not picked again at that NPC
    newNPC()
    W.quests[205] = nil
    D.offers = { { q = 202, title = "Bravo" } }
    W.quests[202] = nil
    c = fire(LE)
    t(tag .. "decline loop: picked once", one(c, pickAvail(family, 202, 1)), show(c))
    fire("GOSSIP_CLOSED")
    dialog(202, "Bravo", { money = 100 })            -- refused when its text showed (costs gold)
    c = fire("QUEST_DETAIL")
    fire("QUEST_FINISHED")
    c = fire(LE)
    t(tag .. "decline loop: the list shows again and the quest is not picked again", none(c), show(c))
    D.now = D.now + NS.QuestAuto.MEMORY_S + 1
    c = fire(LE)
    t(tag .. "decline loop: a minute later it may be picked again", one(c, pickAvail(family, 202, 1)), show(c))

    -- options off
    newNPC()
    NS.db.profile.autoAccept = false
    dialog(202, "Bravo")
    c = fire("QUEST_DETAIL")
    t(tag .. "auto accept off: nothing", none(c), show(c))
    NS.db.profile.autoTurnin = false
    dialog(201, "Alpha", { completable = true, choices = {} })
    c = fire("QUEST_PROGRESS")
    local c2 = fire("QUEST_COMPLETE")
    t(tag .. "auto turn-in off: nothing", none(c) and none(c2), show(c) .. show(c2))
    D.offers = { { q = 202, title = "Bravo" } }
    D.active = { { q = 201, title = "Alpha", complete = true } }
    c = fire(LE)
    t(tag .. "both off: the list is left alone", none(c), show(c))
    NS.db.profile.autoAccept, NS.db.profile.autoTurnin = true, true

    -- a Daily Gold guide takes its dailies from plain steps
    newNPC()
    NS.Progress.Load("gold:test:daily")
    NS.QuestAuto.ResetState()
    dialog(240, "Golf", { daily = true })
    c = fire("QUEST_DETAIL")
    t(tag .. "Daily Gold guide: its daily is accepted", one(c, "AcceptQuest 240"), show(c))
    NS.Progress.Load("t:auto:a")

    t(tag .. "never two actions for one event", overActions == 0, overActions)
end

-- API-family specifics: the old gossip API without quest ids / counts, the greeting frame without ids or "complete"
local function variants(flavor)
    local tag = flavor .. "/old: "
    setup(flavor, "old")
    D.oldIds, D.oldCounts = false, true
    newNPC()
    D.offers = { { q = 299, title = "Far" }, { q = 202, title = "Bravo" } }
    D.active = {}
    local c = fire("GOSSIP_SHOW")
    t(tag .. "no quest ids: matched by title", one(c, "SelectGossipAvailableQuest #2"), show(c))
    setup(flavor, "old")
    D.oldIds, D.oldCounts = true, false
    GetNumGossipAvailableQuests, GetNumGossipActiveQuests = nil, nil
    newNPC()
    D.offers = { { q = 299, title = "Far" }, { q = 202, title = "Bravo" }, { q = 203, title = "Charlie" } }
    D.active = { { q = 201, title = "Alpha", complete = false } }
    c = fire("GOSSIP_SHOW")
    t(tag .. "no count functions, quest ids appended: groups found by their titles", one(c, "SelectGossipAvailableQuest #2"), show(c))
    D.oldIds = false
    fire("GOSSIP_CLOSED")
    newNPC()
    c = fire("GOSSIP_SHOW")
    t(tag .. "no count functions, no ids: groups of 7", one(c, "SelectGossipAvailableQuest #2"), show(c))

    tag = flavor .. "/greeting: "
    setup(flavor, "greeting")
    D.greetIds, D.greetComplete = false, false
    GetActiveQuestID = nil
    newNPC()
    W.quests[201] = "complete"
    NS.Progress.Refresh()
    D.active = { { q = 201, title = "Alpha" } }
    D.offers = { { q = 202, title = "Bravo" } }
    c = fire("QUEST_GREETING")
    t(tag .. "no ids and no 'complete' flag: title + the quest log decide, turn-in first", one(c, "SelectActiveQuest #1"), show(c))
    W.quests[201] = "log"
    fire("QUEST_FINISHED")
    newNPC()
    c = fire("QUEST_GREETING")
    t(tag .. "...an unfinished one is passed over for the accept", one(c, "SelectAvailableQuest #1"), show(c))
end

for _, fl in ipairs(FLAVORS) do
    for _, fam in ipairs(FAMILIES) do
        local ok, err = pcall(scenario, fl, fam)
        t(fl .. "/" .. fam .. ": scenario ran", ok, err)
        overActions = 0
    end
    local ok, err = pcall(variants, fl)
    t(fl .. ": API variants ran", ok, err)
    print(("%-8s %d passed, %d failed so far"):format(fl, passed, failed))
end

-- ---------------------------------------------------------------------------
-- 2) Pieces: the clear-winner rule, title matching, /cr auto, TOCs
-- ---------------------------------------------------------------------------
do
    setup("era", "gossip")
    local IS, QA = NS.ItemScore, NS.QuestAuto
    local pick, pct = IS.ClearWinner({ { link = "item:1001", usable = true }, { link = "item:1002", usable = true } })
    t("ClearWinner: strength helm for a warrior over an intellect one", pick == 1 and pct and pct >= IS.CLEAR_PCT, tostring(pick) .. " " .. tostring(pct))
    t("ClearWinner: two close upgrades -> none", IS.ClearWinner({ { link = "item:1001", usable = true }, { link = "item:1003", usable = true } }) == nil)
    t("ClearWinner: unusable never wins", IS.ClearWinner({ { link = "item:1004", usable = false }, { link = "item:1002", usable = true } }) == nil)
    t("ClearWinner: not loaded -> none", IS.ClearWinner({ { link = "item:1001", usable = true }, { link = nil, usable = nil } }) == nil)
    t("ClearWinner: one choice is not a choice", IS.ClearWinner({ { link = "item:1001", usable = true } }) == nil)
    GetInventoryItemLink = function() return "item:1001" end   -- already wearing the 20-strength helm
    t("ClearWinner: an upgrade under CLEAR_PCT over what is worn -> none", IS.ClearWinner({ { link = "item:1005", usable = true }, { link = "item:1002", usable = true } }) == nil)
    t("ClearWinner: only downgrades -> none", IS.ClearWinner({ { link = "item:1003", usable = true }, { link = "item:1002", usable = true } }) == nil)
    -- the hands and the ranged slot (IS.ChoiceGain); a warrior unless said otherwise
    local function cw(a, b) return IS.ClearWinner({ { link = a, usable = true }, { link = b, usable = true } }) end
    local function cwWhy(a, b) return select(2, cw(a, b)) end
    local function near(x, y) return type(x) == "number" and math.abs(x - y) < 1e-9 end
    wear({ [16] = "item:2001", [10] = "item:2010" })                 -- two-hand sword, weak gloves, off hand empty
    D.dualWield = false
    t("hands, two-hander: a shield is weighed against the two-hand weapon it would take off", near(IS.ChoiceGain("item:2003"), 11.4 - 78))
    t("hands, two-hander: shield or better gloves -> gloves", cw("item:2003", "item:2011") == 2, tostring(cw("item:2003", "item:2011")))
    t("hands, two-hander: one-hand sword or better gloves -> gloves", cw("item:2002", "item:2011") == 2)
    t("hands, two-hander: an off-hand item never beats the two-hander", cw("item:2003", "item:1002") == nil)
    D.dualWield = true
    t("hands, two-hander, can dual wield: an off-hand weapon still takes the two-hander off", cw("item:2005", "item:1002") == nil)
    D.dualWield = false
    t("hands: no dual wield -> an off-hand weapon is no contender", select(3, IS.ChoiceGain("item:2005")) == false and cw("item:2005", "item:2011") == 2)
    wear({ [16] = "item:2002", [17] = "item:2003" })                 -- one-hand sword and shield [34.6]
    t("hands, sword and board: a two-hander must beat both hands (weak one: 30.4 < 34.6)", cw("item:2007", "item:1002") == nil,
        tostring(cw("item:2007", "item:1002")))
    t("hands, sword and board: a big two-hander does (85.2)", cw("item:2006", "item:1002") == 1)
    t("hands, sword and board: a shield is weighed against the shield", near(IS.ChoiceGain("item:2003"), 0))
    wear({ [16] = "item:2013" })                                     -- weak one-hand weapon, off hand empty
    t("hands, no dual wield: a one-hand weapon goes in the main hand only", cw("item:2002", "item:1002") == 1)
    t("hands, empty off hand: a shield cannot be weighed -> none, even with better gloves",
        cw("item:2003", "item:2011") == nil and cwWhy("item:2003", "item:2011"):find("empty off hand", 1, true) ~= nil)
    D.dualWield = true
    t("hands, dual wielder with an empty off hand: a one-hand weapon cannot be weighed -> none", cw("item:2002", "item:1002") == nil)
    wear({ [16] = "item:2002", [17] = "item:2013" })                 -- dual wielding 23.2 + 10.6
    t("hands, dual wielder: a one-hand weapon is weighed against the weaker hand", near(IS.ChoiceGain("item:2014"), 25.2 - 10.6)
        and cw("item:2014", "item:1002") == 1)
    t("hands, dual wielder: an off-hand weapon is weighed against the off hand", cw("item:2005", "item:1002") == 1)
    wear({ [16] = "item:2002", [17] = "item:2003" })                 -- can dual wield, but holds sword and shield
    t("hands, sword and board that could dual wield: a one-hand weapon is weighed against the sword, not the shield",
        near(IS.ChoiceGain("item:2014"), 25.2 - 23.2) and cw("item:2014", "item:1002") == nil, tostring(IS.ChoiceGain("item:2014")))
    D.dualWield = false
    wear({ [10] = "item:unknown" })                                  -- gloves worn whose stats the client does not return
    t("armor: a worn item whose stats cannot be read -> the reward cannot be weighed -> none",
        cw("item:2011", "item:1002") == nil and (cwWhy("item:2011", "item:1002") or ""):find("cannot be read", 1, true) ~= nil,
        tostring(cwWhy("item:2011", "item:1002")))
    wear({ [16] = "item:2001", [17] = "item:unknown" })
    t("hands: a worn off-hand item whose stats cannot be read -> a two-hander cannot be weighed", cw("item:2006", "item:1002") == nil)
    wear({})                                                         -- nothing in the hands
    t("hands: nothing in the main hand -> a weapon cannot be weighed", cw("item:2002", "item:1002") == nil)
    wear({ [16] = "item:unknown" })
    t("hands: the worn weapon's data is missing -> cannot be weighed", cw("item:2002", "item:1002") == nil)
    wear({ [16] = "item:2001" })
    t("ranged: nothing in slot 18 (always so on MoP and Retail) -> a bow cannot be weighed, even with better gloves",
        cw("item:2008", "item:2011") == nil)
    wear({ [16] = "item:2001", [18] = "item:2009", [10] = "item:2010" })
    t("ranged: a bow worn in slot 18 -> weighed against it", cw("item:2008", "item:2011") == 1)
    wear({ [10] = "item:2010" })
    t("armor: an empty ring slot is a real gain (only the hands and ranged are special)", cw("item:2015", "item:1002") == 1)
    NS.player.class = "MAGE"
    wear({ [16] = "item:2012" })                                     -- a staff
    t("hands, staff caster: a held-in-off-hand item never beats the staff", cw("item:2004", "item:1003") == nil,
        tostring(cw("item:2004", "item:1003")))
    NS.player.class = "WARRIOR"
    wear({ [1] = "item:900" })
    local w = { quests = { [1] = { step = { title = "Same Name" } }, [2] = { step = { title = "Same name!" } }, [3] = { step = { title = "Other" } } } }
    t("title match: ambiguous -> nil", QA.QuestByTitle(w, "Same Name") == nil)
    t("title match: unique, case and punctuation ignored", QA.QuestByTitle(w, "other") == 3)
    -- /cr auto
    local p = NS.db.profile
    p.autoAccept, p.autoTurnin = false, false
    SlashCmdList.COMPLETIONROUTE("auto accept")
    t("/cr auto accept toggles accept only", p.autoAccept == true and p.autoTurnin == false)
    SlashCmdList.COMPLETIONROUTE("auto turnin")
    t("/cr auto turnin toggles turn-in", p.autoTurnin == true)
    SlashCmdList.COMPLETIONROUTE("auto off")
    t("/cr auto off turns both off", p.autoAccept == false and p.autoTurnin == false)
    SlashCmdList.COMPLETIONROUTE("auto on")
    t("/cr auto on turns both on", p.autoAccept == true and p.autoTurnin == true)
    SlashCmdList.COMPLETIONROUTE("auto key ctrl")
    t("/cr auto key ctrl", p.autoModifier == "CTRL" and QA.Key() == "CTRL")
    SlashCmdList.COMPLETIONROUTE("auto reward")
    t("/cr auto reward toggles the reward choice", p.autoChooseReward == true)
    local n0 = #NS.printed
    SlashCmdList.COMPLETIONROUTE("auto")
    t("/cr auto prints the settings", NS.printed[n0 + 1] and NS.printed[n0 + 1]:find("Auto accept", 1, true) ~= nil, NS.printed[n0 + 1])
    p.autoModifier = "BOGUS"
    t("an unknown saved key falls back to Shift", QA.Key() == "SHIFT")
    local snap = QA.Snapshot()
    t("bug report snapshot carries the settings", snap.accept == true and snap.turnin == true and snap.reward == true and snap.key == "SHIFT")
    -- /cr bug (Core/BugReport.lua) carries the settings and the last decisions
    QA.OnDetail("QUEST_DETAIL")
    assert(loadfile("CompletionRoute/Core/BugReport.lua"))("CompletionRoute", NS)
    local okr, rep = pcall(NS.BugReport.Snapshot, "")
    local qa = okr and rep and rep.options and rep.options.questAuto
    t("bug report: options.questAuto has the settings and the last decision", qa and qa.key == "SHIFT" and qa.accept == true and #qa.recent >= 1,
        okr and (qa and table.concat(qa.recent, " | ")) or rep)
    local f = assert(io.open("CompletionRoute/Core/Slash.lua"))
    local src = f:read("*a") f:close()
    t("help line advertises /cr auto", src:find("auto %[accept|turnin|off%]") ~= nil)
    -- every TOC loads it right after Core/Skip.lua
    for _, toc in ipairs({ "CompletionRoute.toc", "CompletionRoute_Mists.toc", "CompletionRoute_TBC.toc", "CompletionRoute_Vanilla.toc",
                           "CompletionRoute_Forever.toc", "CompletionRoute_Camelot.toc" }) do
        local fh = assert(io.open("CompletionRoute/" .. toc))
        local body = fh:read("*a") fh:close()
        t(toc .. " loads Core\\QuestAuto.lua after Core\\Skip.lua", body:find("Core\\Skip.lua\nCore\\QuestAuto.lua\n", 1, true) ~= nil)
    end
end

-- ---------------------------------------------------------------------------
-- 3) CPU of one dialog decision on each flavor's biggest real guide: the window from P.order plus the checks, and the
--    same right after a quest change (window read from the pending steps).  Real client budget proxy: luajit -joff.
-- ---------------------------------------------------------------------------
local cpu = {}
for _, fl in ipairs(FLAVORS) do
    local path = "Guides/Imported_Wiki_" .. fl .. ".lua"
    if exists("CompletionRoute/" .. path) then
        local ok, err = pcall(function()
            harness(fl, "gossip")
            assert(loadfile("CompletionRoute/" .. path))("CompletionRoute", NS)
            -- the biggest guides first; the first one that leaves an Alliance character at its level a window
            local G, cands = NS.Guide, {}
            for _, id in ipairs(G.list) do
                local g = G.registry[id]
                if g.text and not g.loop and g.faction ~= "Horde" then cands[#cands + 1] = g end
            end
            table.sort(cands, function(a, b) return #a.text > #b.text end)
            NS.db.profile.autoAccept, NS.db.profile.autoTurnin = true, true
            NS.db.profile.routing.liveBudgetMs = nil      -- the client's own budget (StepOrder.FRAME_MS)
            local QA, best, steps, w = NS.QuestAuto, nil, nil, nil
            for k = 1, math.min(#cands, 8) do
                local g = cands[k]
                steps = G.Steps(g.id)
                local s1
                for _, s in ipairs(steps) do if s.coords and s.zone then s1 = s break end end
                if s1 then place(s1.zone, s1.coords[1].x, s1.coords[1].y) end
                W.level = math.max(1, math.floor(g.minlevel or 1))
                NS.Progress.Load(g.id)
                w = QA.Window()
                if w and next(w.quests) then best = g.id break end
            end
            assert(best, "no guide with a window")
            local q = next(w.quests)
            local acc = NS.Progress.order[1] and NS.Progress.order[1].qid and NS.Progress.order[1].qid[1] or q
            dialog(acc, "x")
            local N = 300
            local t0 = os.clock()
            for _ = 1, N do QA.ResetState() QA.OnDetail("QUEST_DETAIL") end
            local plain = (os.clock() - t0) * 1000 / N
            local times = {}
            for k = 1, 30 do
                QA.ResetState() QA.MarkStale()
                local t1 = os.clock()
                QA.OnDetail("QUEST_DETAIL")
                times[k] = (os.clock() - t1) * 1000
            end
            local first = times[1]
            table.sort(times)
            local worst, median = times[#times], times[15]
            if os.getenv("CR_QA_TRACE") then print(fl .. " refresh ms first " .. first .. " all " .. table.concat(times, " ")) end
            cpu[#cpu + 1] = ("%-7s %-30s %4d steps  decision %.3f ms; right after a quest change: first %.3f, median %.3f, max %.3f ms"):format(
                fl, best:sub(1, 30), #steps, plain, first, median, worst)
            t(fl .. ": a dialog decision costs under 1 ms on the biggest guide", plain < 1.0, plain)
            -- the median: one cold call (first trace, GC step) can cost more on a loaded machine; the line above prints all three
            t(fl .. ": right after a quest change too (median)", median < 1.0, median)
        end)
        t(fl .. ": CPU run", ok, err)
    else
        cpu[#cpu + 1] = fl .. ": no " .. path .. " (generated, gitignored) - CPU not measured"
    end
end
for _, line in ipairs(cpu) do print("cpu  " .. line) end

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
