-- Offline tests of the three play-flow features of 2026-11-12:
--   1. Recent        the routes list's top section (Core/Progress.lua P.RecentList, UI/GuideMenu.lua)
--   2. Start over    P.StartOver / P.Reset from a finished route, and circuits that keep lapping
--   3. Auto-advance  the completion rules new on that day (Core/Guide.lua NS.StepSignal, Core/Progress.lua):
--                    talking to the step's NPC, a merchant on a repair/sell step, L items on every action, a bought
--                    item, any ALT place, loot at a treasure's spot, a mission's success
-- Run from the repo root:  luajit -joff tools/test_flow.lua
-- Stubs only: nothing here has run in a client.
package.path = "./?.lua;" .. package.path
local ADDON = "CompletionRoute"
dofile("tools/stubs.lua")
local z2w = z2w
PLAYER = { map = 1429, x = 0.487, y = 0.42 } PLAYER.wx, PLAYER.wy, PLAYER.inst = z2w(PLAYER.x, PLAYER.y, PLAYER.map)
local function standAt(map, x, y) PLAYER.map, PLAYER.x, PLAYER.y = map, x, y PLAYER.wx, PLAYER.wy, PLAYER.inst = z2w(x, y, map) end

local fails, checks = 0, 0
local function check(ok, what)
    checks = checks + 1
    if not ok then fails = fails + 1 print("FAIL " .. what) end
end

-- ---- client state the rules read ----
local BAGS, ON_QUEST, NPC, SECRET, NPC_READS = {}, {}, nil, false, 0
C_Item.GetItemCount = function(id) return BAGS[id] or 0 end
C_QuestLog.IsOnQuest = function(q) return ON_QUEST[q] or false end
local QUESTNPC = nil
UnitName = function(unit)
    if unit == "npc" then NPC_READS = NPC_READS + 1 return NPC end
    if unit == "questnpc" then return QUESTNPC end
    return "Tester"
end
-- a clock the test moves (the conversation lock reads GetTime); it creeps so nothing sees the same instant twice
local NOW = 1000
GetTime = function() NOW = NOW + 0.001 return NOW end
local function wait(sec) NOW = NOW + sec end
-- what the loot window holds, and what the merchant can do
local LOOT, FISHING, CAN_REPAIR = { "GameObject-0-3299-0-1-2843-0000001234" }, false, false
GetNumLootItems = function() return #LOOT end
GetLootSourceInfo = function(slot) return LOOT[slot], 1 end
IsFishingLoot = function() return FISHING end
CanMerchantRepair = function() return CAN_REPAIR end
issecretvalue = function(v) return SECRET and v == NPC end
-- events this fake client does not have: registering them must not break the load (NS:RegisterEvent is pcall-guarded)
UNKNOWN_EVENTS = { AUCTION_HOUSE_SHOW = true, PLAYER_INTERACTION_MANAGER_FRAME_SHOW = true, GARRISON_MISSION_COMPLETE_RESPONSE = true, LOOT_READY = true }
GameTooltip = CreateFrame()

local FILES = { "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", "Data/Taxi_tbc.lua", "Data/Transit.lua", "Data/Access.lua",
    "Data/Inns.lua", "Data/ZoneAliases.lua", "Routing/CostModel.lua", "Routing/TravelGraph.lua", "Routing/Roads.lua", "Routing/StepOrder.lua",
    "Routing/Router.lua", "Core/Account.lua", "Core/Professions.lua", "Core/Progress.lua", "Core/Recommend.lua", "UI/GuideMenu.lua" }

local GUIDES = {
    { id = "f:a", name = "Route A", type = "Professions", text = "N One|\nN Two|\nN Three|\nN Four|" },
    { id = "f:b", name = "Route B", type = "Professions", text = "N One|\nN Two|" },
    { id = "f:c", name = "Route C", type = "Professions", text = "N One|\nN Two|" },
    -- auto-advance samples: one step per rule
    { id = "f:talk", name = "Talk", type = "Professions", text = table.concat({
        "N Talk to Innkeeper Farley|",
        "N Ask about the road|T|Marshal Dughan|",
        "N Report in|N|Speak with Guard Thomas at the bridge.|",
        "R Sell your junk|ALT|1453,52.6,65.7,Innkeeper Allison (Stormwind City);1455,18.1,51.5,Innkeeper Firebrew (Ironforge)|",
        "N Deliver the note|N|To Smith Argus.|",
        "N Last|" }, "\n") },
    { id = "f:notalk", name = "No talk", type = "Professions", text = table.concat({
        "A A Threat Within|QID|9001|N|From Deputy Willem.|",
        "C Speak up|QID|9002|N|Speak with Deputy Willem.|",
        "K Kill the kobold|T|Kobold Vermin|",
        "B Buy a pick|T|Deputy Willem|",
        "N Last|" }, "\n") },
    { id = "f:items", name = "Items", type = "Professions", text = table.concat({
        "N Bring linen|L|2589 10|",
        "B Buy a mining pick|U|2901|",
        "B Buy thread|ITEM|2320|COUNT|5|",
        "C Rings|QID|9003|L|3505 7|",
        "A Needs a key|QID|9004|L|5000 1|",
        "N Odd count|L|6000 0|",
        "N Last|" }, "\n") },
    { id = "f:world", name = "World", type = "Professions", text = table.concat({
        "r Sell junk|M|47.7,41.4|Z|1429; Elwynn Forest|N|Godric Rothgar, west side of the Abbey.|",
        "R Visit the bank|ALT|1453,57.0,73.0,Stormwind City bank;1455,35.0,60.0,Ironforge bank|",
        "$ Hidden chest|M|40.0,60.0|Z|1429; Elwynn Forest|",
        "N Table mission|MISSION|753|",
        "N Other mission|MISSION|754|",
        "N Last|" }, "\n") },
    -- what a wrong rule would skip (the skeptic's cases)
    { id = "f:twice", name = "Twice", type = "Professions", text = table.concat({
        "N Talk to Innkeeper Farley|",
        "N Ask him again|T|Innkeeper Farley|",
        "N And once more|N|Speak with Innkeeper Farley.|",
        "N Then his neighbour|T|Smith Argus|",
        "N Last|" }, "\n") },
    { id = "f:shop", name = "Shop", type = "Professions", text = table.concat({
        "r Sell junk|",
        "N Talk to Godric Rothgar|",
        "r Repair|",
        "r Repair and sell|",
        "N Last|" }, "\n") },
    { id = "f:quest", name = "Quest pane", type = "Professions", text = "N Report to the marshal|T|Marshal Dughan|\nN Last|" },
    { id = "f:chest", name = "Chest", type = "Professions", text = "$ Hidden chest|M|40.0,60.0|Z|1429; Elwynn Forest|\nN Last|" },
    { id = "f:loop", name = "Loop", type = "Gold", loop = true, text = "G Stop 1|M|10,10|Z|1429; Elwynn Forest|RAD|60|\nG Stop 2|M|60,60|Z|1429; Elwynn Forest|RAD|60|\nG Stop 3|M|90,20|Z|1429; Elwynn Forest|RAD|60|" },
    { id = "f:hearth", name = "Hearth", type = "Professions", text = "h Goldshire|M|43.7,65.8|Z|1429; Elwynn Forest|\nN After|" },
}

-- a fresh addon over whatever CompletionRouteDB / CompletionRouteCharDB hold: boot() again is a /reload
local function boot()
    local NS = {}
    for _, f in ipairs(FILES) do assert(loadfile("CompletionRoute/" .. f))(ADDON, NS) end
    for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", ADDON) end
    for _, g in ipairs(GUIDES) do
        local def = {}
        for k, v in pairs(g) do def[k] = v end
        NS.Guide.Register(def)
    end
    return NS
end
local function fire(NS, evt, ...)
    for _, h in ipairs(NS.wowHandlers[evt] or {}) do h(evt, ...) end
end

CompletionRouteDB, CompletionRouteCharDB = nil, nil
local NS = boot()
local P, G, Sig = NS.Progress, NS.Guide, NS.StepSignal
local T = NS.GuideMenu._test
local function recentIds()
    local out = {}
    for i, r in ipairs(P.RecentList()) do out[i] = r.g.id end
    return table.concat(out, ",")
end
local function topNode() return T.buildTree().kids[1] end

-- ---------------------------------------------------------------------------
-- 0. the new events are registered through the guarded NS:RegisterEvent, known to the client or not
-- ---------------------------------------------------------------------------
for _, e in ipairs({ "GOSSIP_SHOW", "QUEST_GREETING", "QUEST_DETAIL", "QUEST_PROGRESS", "QUEST_COMPLETE", "MERCHANT_SHOW", "TRAINER_SHOW",
    "TAXIMAP_OPENED", "BANKFRAME_OPENED", "AUCTION_HOUSE_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "LOOT_OPENED", "LOOT_READY",
    "GARRISON_MISSION_COMPLETE_RESPONSE", "GOSSIP_CLOSED", "QUEST_FINISHED", "MERCHANT_CLOSED", "TRAINER_CLOSED", "TAXIMAP_CLOSED",
    "BANKFRAME_CLOSED", "AUCTION_HOUSE_CLOSED", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" }) do
    check(NS.wowHandlers[e] ~= nil and #NS.wowHandlers[e] > 0, "event " .. e .. " has a handler registered through NS:RegisterEvent")
end
do
    local src = assert(io.open("CompletionRoute/Core/Progress.lua")):read("*a")
    check(not src:find("[^%w_:]RegisterEvent%(") or not src:find("eventFrame:RegisterEvent"), "Progress.lua registers no event on the frame directly")
end

-- ---------------------------------------------------------------------------
-- 1. Recent
-- ---------------------------------------------------------------------------
check(#P.RecentList() == 0, "Recent starts empty")
check(not (topNode() and topNode().recent), "an empty Recent section is hidden")
P.Load("f:a")
check(#P.RecentList() == 0, "a route with no finished step is not listed")
P.Forward()
check(recentIds() == "f:a", "one finished step puts the route in Recent: " .. recentIds())
do
    local node = topNode()
    check(node and node.recent and node.name == "Recent", "Recent is the first section of the list")
    local second = T.buildTree().kids[2]
    check(not second or second.recommended or not second.recent, "Recommended comes after Recent")
    check(T.expanded[T.RECENT_PATH], "Recent starts open")
    local rows = T.visibleRows()
    check(rows[1].kind == "node" and rows[1].node.recent and rows[2].kind == "guide" and rows[2].guide.id == "f:a", "the first rows are Recent and its route")
end
P.Load("f:b") P.Forward()
check(recentIds() == "f:b,f:a", "most recently used first: " .. recentIds())
P.Load("f:a") P.Forward()
check(recentIds() == "f:a,f:b", "progress in an older route brings it back to the top: " .. recentIds())
-- the chain walking into a route is not the player using it
P.chainLoading = true P.Load("f:c") P.chainLoading = nil
check(recentIds() == "f:a,f:b", "a chain load does not enter Recent: " .. recentIds())
P.Forward()
check(recentIds() == "f:c,f:a,f:b", "its first finished step does: " .. recentIds())
-- progress the way other rows show it, from the saved step total (no parse)
do
    local a = G.registry["f:a"]
    check(T.savedPct(a) == 50, "Route A reads 2 of 4 = 50%, got " .. tostring(T.savedPct(a)))
    check(P.RecentRecord("f:a").n == 4 and P.RecentRecord("f:a").s and P.RecentRecord("f:a").t, "the record holds the step total, a sequence and a time")
    check(NS.db.char == CompletionRouteCharDB and CompletionRouteCharDB.recent ~= nil, "the record lives in the character's saved variables")
end
-- clicking a Recent row loads the route
do
    NS.GuideMenu.Refresh()
    local hit
    for _, b in ipairs(T.buttons) do if b.gid == "f:b" then hit = b break end end
    check(hit ~= nil, "Recent row for Route B exists")
    if hit then hit.scripts.OnClick(hit) end
    check(P.guide and P.guide.id == "f:b", "clicking the row loads the route")
    check(recentIds():sub(1, 3) == "f:b", "and a picked route moves to the top: " .. recentIds())
    check(T.title:GetText():find("^Routes"), "the list window is titled Routes: " .. tostring(T.title:GetText()))
end
-- at most 12 rows, at most 30 records
do
    for i = 1, 40 do
        local id = ("f:many%02d"):format(i)
        G.Register({ id = id, name = "Many " .. i, type = "Professions", text = "N One|\nN Two|" })
        P.Load(id) P.Forward()
    end
    check(#P.RecentList() == 12, "Recent shows at most 12 rows, got " .. #P.RecentList())
    check(P.RecentList()[1].g.id == "f:many40", "newest first after many")
    local n = 0
    for _ in pairs(NS.db.char.recent) do n = n + 1 end
    check(n <= 30, "at most 30 records are kept, got " .. n)
end
-- /reload: a fresh addon over the same saved variables shows the same list, without parsing a guide
do
    local before = recentIds()
    P.Load("f:a")      -- so the reloaded session has a saved guide; picking it moves it to the top
    before = recentIds()
    NS = boot()
    P, G, Sig = NS.Progress, NS.Guide, NS.StepSignal
    T = NS.GuideMenu._test
    for i = 1, 40 do G.Register({ id = ("f:many%02d"):format(i), name = "Many " .. i, type = "Professions", text = "N One|\nN Two|" }) end
    check(recentIds() == before, "Recent survives /reload:\n   " .. before .. "\n   " .. recentIds())
    local parsed = 0
    for _, r in ipairs(P.RecentList()) do
        T.savedPct(r.g)
        if r.g.steps then parsed = parsed + 1 end
    end
    check(parsed == 0, "building Recent and its progress parses no guide (" .. parsed .. " parsed)")
    check(topNode().recent and #topNode().guides == 12, "the reloaded list has the Recent section on top")
end
-- a record whose route is gone from this version of the data (a renamed or dropped guide) does not break the section
do
    local before = recentIds()
    CompletionRouteCharDB.recent["gone:route"] = { s = (CompletionRouteCharDB.recentSeq or 0) + 50, t = 0, n = 9 }
    NS.Account.me.stepDone["gone:route"] = { k1 = true }
    local ok, err = pcall(function() return recentIds() end)
    check(ok and err == before, "a record of a route that no longer exists is passed over: " .. tostring(err))
    local okT, node = pcall(topNode)
    check(okT and node and node.recent and #node.guides == 12, "and the list still builds with it in the saved table")
    local okR = pcall(NS.GuideMenu.Refresh)
    check(okR, "and the list window still draws")
    -- the table stays bounded with the stale record in it
    for i = 1, 40 do P.Load(("f:many%02d"):format(i)) P.Forward() end
    local n = 0
    for _ in pairs(NS.db.char.recent) do n = n + 1 end
    check(n <= 30, "the saved table stays at 30 records at most with a stale record in it, got " .. n)
    CompletionRouteCharDB.recent["gone:route"] = nil
    NS.Account.me.stepDone["gone:route"] = nil
end
-- building the list counts no marks: a route with thousands of finished steps costs the same as one with two
do
    local id = P.RecentList()[1].g.id
    local set = NS.Account.me.stepDone[id]
    local keep = {}
    for k, v in pairs(set) do keep[k] = v end
    for i = 1, 5000 do set["big" .. i] = true end
    local realPairs, walked = pairs, false
    pairs = function(t) if t == set then walked = true end return realPairs(t) end
    local list = P.RecentList()
    local okT = pcall(T.buildTree)
    pairs = realPairs
    check(list[1] and list[1].g.id == id and okT and not walked, "Recent (and the tree with it) is built without walking a route's marks")
    for k in pairs(set) do if not keep[k] then set[k] = nil end end
end
-- first run of the feature on a character that already has progress: seeded from its marks
do
    CompletionRouteCharDB.recent, CompletionRouteCharDB.recentSeq = nil, nil
    NS.Account.me.stepDone = { ["f:b"] = { k1 = true }, ["f:a"] = { k1 = true, k2 = true, k3 = true }, ["f:c"] = {} }
    check(recentIds() == "f:a,f:b", "first run lists the routes that have finished steps, most steps first: " .. recentIds())
    CompletionRouteCharDB.recent, CompletionRouteCharDB.recentSeq = nil, nil
    CompletionRouteCharDB.guide = "f:b"
    check(recentIds() == "f:b,f:a", "with the route that is loaded on top: " .. recentIds())
end

-- ---------------------------------------------------------------------------
-- 2. Start over
-- ---------------------------------------------------------------------------
CompletionRouteDB, CompletionRouteCharDB = nil, nil
NS = boot()
P, G, Sig = NS.Progress, NS.Guide, NS.StepSignal
P.Load("f:a")
for _ = 1, 4 do P.Forward() end
check(P.current == nil and P.guide.id == "f:a", "a finished profession route stays loaded with no step left")
check(P.VisibleDone() == 4, "all four steps are marked")
check(P.StartOver() == true, "P.StartOver reports that it reset")
check(P.guide.id == "f:a" and P.current and P.current.title == "One", "Start over is back at the first step: " .. tostring(P.current and P.current.title))
check(P.VisibleDone() == 0, "and the marks are gone")
check(P.RecentRecord("f:a") ~= nil, "the route stays in the saved record")
-- only this route, only this character
do
    P.Load("f:b") P.Forward()
    local A = NS.Account
    local otherKey = "Otherchar-" .. tostring(A.key)
    NS.db.global.chars[otherKey] = { stepDone = { ["f:a"] = { x1 = true, x2 = true } }, stepSkipped = { ["f:a"] = { x3 = true } }, done = {}, skipped = {} }
    local bDone = 0
    for _ in pairs(A.me.stepDone["f:b"] or {}) do bDone = bDone + 1 end
    P.Load("f:a") P.Forward() P.Forward()
    check(P.StartOver() == true and P.VisibleDone() == 0, "Start over clears the loaded route")
    local bAfter = 0
    for _ in pairs(A.me.stepDone["f:b"] or {}) do bAfter = bAfter + 1 end
    check(bDone == 1 and bAfter == 1, "another route's marks are untouched (" .. bDone .. " -> " .. bAfter .. ")")
    local o = NS.db.global.chars[otherKey]
    check(o.stepDone["f:a"].x1 and o.stepDone["f:a"].x2 and o.stepSkipped["f:a"].x3, "another character's marks in the same route are untouched")
    NS.db.global.chars[otherKey] = nil
end
-- a step finished by an event flag does not finish itself again
P.Load("f:hearth")
fire(NS, "HEARTHSTONE_BOUND")
check(P.current and P.current.title == "After", "hearth bound finishes the set-hearth step")
P.StartOver()
check(P.current and P.current.action == "h", "after Start over the set-hearth step is open again: " .. tostring(P.current and P.current.title))
-- /cr reset is the same code
P.Forward() P.Reset()
check(P.current and P.current.action == "h" and P.VisibleDone() == 0, "/cr reset (P.Reset) does the same")
-- circuits keep lapping: reaching the last waypoint starts the next lap, there is never an end state
P.Load("f:loop")
check(P.current ~= nil, "a circuit loads with a waypoint")
local lap0 = P.Lap("f:loop")
for _ = 1, 12 do
    local s = P.current
    if not s then break end
    standAt(1429, s.coords[1].x, s.coords[1].y)
    P.Refresh()
end
check(P.current ~= nil, "a circuit always has a current waypoint")
check(P.Lap("f:loop") > lap0, "and its laps count up (" .. lap0 .. " -> " .. P.Lap("f:loop") .. ")")
standAt(1429, 0.487, 0.42)

-- ---------------------------------------------------------------------------
-- 3. Auto-advance
-- ---------------------------------------------------------------------------
local function titleNow() return P.current and P.current.title or "(none)" end
-- 3a. talking to the NPC the step names
P.Load("f:talk")
NPC = "Marshal Dughan"                       -- a LATER step's NPC
fire(NS, "GOSSIP_SHOW")
check(titleNow() == "Talk to Innkeeper Farley", "only the step on screen: a later step's NPC does nothing")
NPC = "Innkeeper Farleyson"
fire(NS, "GOSSIP_SHOW")
check(titleNow() == "Talk to Innkeeper Farley", "the name is compared whole, not as a prefix")
NPC = "innkeeper FARLEY"
SECRET = true
fire(NS, "GOSSIP_SHOW")
check(titleNow() == "Talk to Innkeeper Farley", "a secret NPC name (Retail, in combat) is not compared")
SECRET = false
fire(NS, "GOSSIP_SHOW")
check(titleNow() == "Ask about the road", "gossip with the NPC in the step's title finishes it, any letter case: " .. titleNow())
NPC = "Marshal Dughan"
fire(NS, "QUEST_GREETING")
check(titleNow() == "Report in", "the T tag names the NPC (quest greeting window): " .. titleNow())
NPC = "Guard Thomas"
fire(NS, "TRAINER_SHOW")
check(titleNow() == "Sell your junk", "\"Speak with X at the bridge.\" names X: " .. titleNow())
NPC = "Innkeeper Firebrew"                   -- not the alternative the engine chose
fire(NS, "MERCHANT_SHOW")
check(titleNow() == "Deliver the note", "any ALT name counts, without its \"(place)\": " .. titleNow())
NPC = "Smith Argus"
fire(NS, "BANKFRAME_OPENED")
check(titleNow() == "Last", "\"To X.\" on a note step names X: " .. titleNow())
NPC = "Smith Argus"
fire(NS, "GOSSIP_SHOW")
check(titleNow() == "Last", "a step that names nobody is left alone")
-- what talking must NOT finish
P.Load("f:notalk")
NPC = "Deputy Willem"
fire(NS, "GOSSIP_SHOW") fire(NS, "QUEST_DETAIL")
check(titleNow() == "A Threat Within", "an accept step is not finished by talking (the quest log does that)")
P.Forward()
fire(NS, "GOSSIP_SHOW")
check(titleNow() == "Speak up", "a quest step is the quest log's to finish, even when its note says Speak with")
P.Forward()
NPC = "Kobold Vermin"
fire(NS, "GOSSIP_SHOW")
check(titleNow() == "Kill the kobold", "a kill step's T tag is the thing to kill, not someone to talk to")
P.Forward()
NPC = "Deputy Willem"
fire(NS, "MERCHANT_SHOW")
check(titleNow() == "Buy a pick", "a buy step needs the item, not the vendor's window")
-- cheap: a step with nothing to match never reads the NPC
P.Forward()
NPC_READS = 0
for _ = 1, 50 do fire(NS, "GOSSIP_SHOW") end
check(NPC_READS == 0, "a step that names nobody costs no UnitName read (" .. NPC_READS .. ")")

-- 3b. items
P.Load("f:items")
check(titleNow() == "Bring linen", "items route starts at its first step")
BAGS[2589] = 9 P.Refresh()
check(titleNow() == "Bring linen", "9 of 10 is not enough")
BAGS[2589] = 10 P.Refresh()
check(titleNow() == "Buy a mining pick", "a note step with L is done when the bags hold the count: " .. titleNow())
BAGS[2901] = 1 P.Refresh()
check(titleNow() == "Buy thread", "a buy step naming its item with U is done when the item is in the bags: " .. titleNow())
BAGS[2320] = 4 P.Refresh()
check(titleNow() == "Buy thread", "COUNT 5 needs five")
BAGS[2320] = 5 P.Refresh()
check(titleNow() == "Rings", "and is done at five: " .. titleNow())
BAGS[3505] = 7 P.Refresh()
check(titleNow() == "Rings", "a quest step's L count says nothing while the character is not on the quest")
ON_QUEST[9003] = true P.Refresh()
check(titleNow() == "Needs a key", "on the quest, the bags holding the count finish it: " .. titleNow())
BAGS[5000] = 1 P.Refresh()
check(titleNow() == "Needs a key", "an accept step is never finished by its L item")
P.Forward()
BAGS[6000] = 3 P.Refresh()
check(titleNow() == "Odd count", "a count under 1 is not a bag rule")

-- 3c. merchant, any ALT place, treasure, mission
P.Load("f:world")
NPC = "Somebody Else"
fire(NS, "GOSSIP_SHOW")
check(titleNow() == "Sell junk", "gossip does not finish a repair/sell step")
fire(NS, "MERCHANT_SHOW")
check(titleNow() == "Visit the bank", "a merchant window does: " .. titleNow())
do
    local s = P.current
    check(s.alts and #s.alts == 2, "the bank step has two places")
    local other
    for _, a in ipairs(s.alts) do if a ~= s.altChosen then other = a end end
    check(other ~= nil, "one of them is not the chosen one")
    if other then
        standAt(other.map, other.x, other.y)
        check(P.CheckStep(s) == true, "standing at the place the engine did not choose is having arrived")
        P.Refresh()
    end
    check(titleNow() == "Hidden chest", "the R step with ALT places is finished at any of them: " .. titleNow())
end
standAt(1429, 0.487, 0.42)
fire(NS, "LOOT_OPENED")
check(titleNow() == "Hidden chest", "loot far from the treasure's spot does nothing")
standAt(1429, 0.40, 0.60)
P.Refresh()
check(titleNow() == "Hidden chest", "arriving at a treasure is not looting it")
fire(NS, "LOOT_OPENED")
check(titleNow() == "Table mission", "loot taken at the spot finishes the treasure step: " .. titleNow())
standAt(1429, 0.487, 0.42)
fire(NS, "GARRISON_MISSION_COMPLETE_RESPONSE", 754, true, false)
check(not P.IsDone(P.steps[5]), "a failed mission finishes nothing")
fire(NS, "GARRISON_MISSION_COMPLETE_RESPONSE", 754, true, true)
check(P.IsDone(P.steps[5]) and titleNow() == "Table mission", "a mission's success finishes the step that names it, wherever it is")
fire(NS, "GARRISON_MISSION_COMPLETE_RESPONSE", 753, true, true)
check(titleNow() == "Last", "and the one on screen: " .. titleNow())

-- 3c2. what a wrong rule would skip
-- one conversation finishes one step, even when two steps in a row name the same NPC
P.Load("f:twice")
NPC = "Innkeeper Farley"
fire(NS, "GOSSIP_SHOW")
fire(NS, "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 3)       -- the same window, reported by the modern event too
check(titleNow() == "Ask him again", "the second event of one window does not finish the next step naming the same NPC: " .. titleNow())
fire(NS, "GOSSIP_CLOSED") fire(NS, "MERCHANT_SHOW")        -- from the gossip pane to his goods
check(titleNow() == "Ask him again", "going from pane to pane of the same NPC is still the same conversation")
wait(30)
fire(NS, "MERCHANT_CLOSED") fire(NS, "QUEST_DETAIL")       -- a long look at the goods, then one of his quests
check(titleNow() == "Ask him again", "however long a pane stayed open")
fire(NS, "QUEST_FINISHED")
wait(1)
fire(NS, "GOSSIP_SHOW")
check(titleNow() == "Ask him again", "a window reopened within two seconds of closing is not a new conversation")
wait(30)
fire(NS, "QUEST_PROGRESS")                                  -- another pane without a close in between
check(titleNow() == "Ask him again", "and a reopened window has to close again before anything counts")
fire(NS, "GOSSIP_CLOSED")
wait(3)
fire(NS, "GOSSIP_SHOW")
check(titleNow() == "And once more", "talking to him again later finishes the second step: " .. titleNow())
fire(NS, "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 3)
check(titleNow() == "And once more", "and again only one step per conversation")
fire(NS, "GOSSIP_CLOSED") wait(3) fire(NS, "GOSSIP_SHOW")
check(titleNow() == "Then his neighbour", "third conversation, third step: " .. titleNow())
NPC = "Smith Argus"                                          -- another NPC needs no wait
fire(NS, "GOSSIP_SHOW")
check(titleNow() == "Last", "a different NPC is a different conversation at once: " .. titleNow())
-- a merchant window that finished a sell step does not also finish "talk to" that merchant
P.Load("f:shop")
wait(10)
NPC = "Godric Rothgar"
fire(NS, "MERCHANT_SHOW")
fire(NS, "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 5)
check(titleNow() == "Talk to Godric Rothgar", "one merchant window: the sell step, not the talk step after it: " .. titleNow())
fire(NS, "MERCHANT_CLOSED") wait(3) fire(NS, "GOSSIP_SHOW")
check(titleNow() == "Repair", "talking to him afterwards finishes it: " .. titleNow())
-- a step that is only about repairing needs a merchant who repairs
NPC = "Brog Hamfist"
CAN_REPAIR = false
fire(NS, "MERCHANT_SHOW")
check(titleNow() == "Repair", "a merchant who cannot repair does not finish a repair step")
fire(NS, "MERCHANT_CLOSED") wait(3)
CAN_REPAIR = true
NPC = "Kurran Steele"
fire(NS, "MERCHANT_SHOW")
check(titleNow() == "Repair and sell", "one who repairs does: " .. titleNow())
CAN_REPAIR = false
NPC = "Brog Hamfist"
fire(NS, "MERCHANT_SHOW")
check(titleNow() == "Last", "\"Repair and sell\" is done at any merchant: " .. titleNow())
-- the quest panes name their NPC as "questnpc" when "npc" answers nothing
P.Load("f:quest")
NPC, QUESTNPC = nil, "Marshal Dughan"
fire(NS, "GOSSIP_SHOW")
check(titleNow() == "Report to the marshal", "a gossip window with no readable NPC finishes nothing")
fire(NS, "QUEST_DETAIL")
check(titleNow() == "Last", "a quest pane reads questnpc when npc is empty: " .. titleNow())
QUESTNPC = nil
-- treasure: only a chest (a game object) looted at the spot
P.Load("f:chest")
standAt(1429, 0.40, 0.60)
LOOT = { "Creature-0-3299-0-1-299-0000001234" }
fire(NS, "LOOT_READY") fire(NS, "LOOT_OPENED")
check(titleNow() == "Hidden chest", "a corpse looted beside the chest is not the treasure")
LOOT, FISHING = { "GameObject-0-3299-0-1-35591-0000001234" }, true
fire(NS, "LOOT_OPENED")
check(titleNow() == "Hidden chest", "nor is a fish caught there")
FISHING, LOOT = false, {}
fire(NS, "LOOT_OPENED")
check(titleNow() == "Hidden chest", "nor an empty loot window")
do
    local keep = GetLootSourceInfo
    GetLootSourceInfo = nil
    LOOT = { "GameObject-0-3299-0-1-2843-0000001234" }
    fire(NS, "LOOT_OPENED")
    check(titleNow() == "Hidden chest", "a client that cannot say where loot came from leaves the step manual")
    GetLootSourceInfo = keep
end
LOOT = { "Creature-0-3299-0-1-299-0000001234", "GameObject-0-3299-0-1-2843-0000001234" }
fire(NS, "LOOT_READY")
check(titleNow() == "Last", "the chest's loot finishes it: " .. titleNow())
standAt(1429, 0.487, 0.42)
LOOT = { "GameObject-0-3299-0-1-2843-0000001234" }
-- words that are not the step itself name nobody
do
    local function names(line) local s = G.ParseLine(line, 1) return Sig.TalkNames(s), s end
    for _, line in ipairs({
        "N Wolves|N|After you talk to Marshal Dughan, kill ten wolves.|",
        "N Flasks|N|Talk to Marshal Dughan and buy five flasks.|",
        "N Ride|N|Speak with Marshal Dughan, then ride to Lakeshire.|",
        "N Two things|N|Speak with Marshal Dughan. Kill ten wolves on the way back.|",
        "N Kill ten wolves, then talk to Marshal Dughan|",
        "N Errand|N|From Marshal Dughan. Then kill ten wolves.|",
    }) do
        local set, s = names(line)
        check(not Sig.TalkMatches(s, "Marshal Dughan"), "no talk rule for a step that asks for more than the talk: " .. line)
        check(set == nil and (Sig.Of(s)) == nil, "and it is counted as manual: " .. line)
    end
    local _, s = names("N Report|N|Speak with Marshal Dughan about the missing shipment (location: the wiki's Goldshire page)|")
    check(Sig.TalkMatches(s, "Marshal Dughan"), "\"Speak with X about ...\" with a source note still names X")
end

-- 3d. the rule table (census, docs) agrees with what just happened
do
    local function sig(line) local s = G.ParseLine(line, 1) return (Sig.Of(s)) end
    local want = {
        { "A Q|QID|1|", "quest accepted (quest log)" }, { "T Q|QID|1|", "quest turned in" }, { "C Q|QID|1|QO|1|", "quest objectives (quest log)" },
        { "C Rings|L|3505 7|", "items in the bags" }, { "N Bring linen|L|2589 10|", "items in the bags" },
        { "B Buy a mining pick|U|2901|", "bought item in the bags" }, { "B Buy|L|1 2|", "items in the bags" },
        { "N Talk to Innkeeper Farley|", "talk to the named NPC" }, { "N Ask|T|Marshal Dughan|", "talk to the named NPC" },
        { "r Sell junk|", "merchant window opened" }, { "$ Chest|M|1,1|Z|1429; Elwynn Forest|", "loot taken at the spot" },
        { "N Table mission|MISSION|753|", "mission success (client event)" }, { "R Visit the bank|ALT|1453,57.0,73.0,Stormwind City bank|", "arrival" },
        { "G Stop|M|1,1|Z|1429; Elwynn Forest|", "arrival at the waypoint" }, { "h Goldshire|", "hearth bound" }, { "f Sentinel Hill|", "flight map opened" },
        { "M Bandage|SKILL|First Aid;40|", "profession skill reached" }, { "= Train|RECIPE|3273|", "recipe or rank learned" },
        { "C Crit|ACH|6;2050|", "achievement or criterion earned" }, { "L Level 10|", "level reached" },
        -- manual: nothing the client reports
        { "N Sell in bulk runs|N|Farm until your bags are full.|", nil }, { "K Kill the kobold|T|Kobold Vermin|", nil },
        { "B Buy a pick|T|Deputy Willem|", nil }, { "$ Chest somewhere|", nil }, { "N Odd count|L|6000 0|", nil },
    }
    for _, w in ipairs(want) do
        check(sig(w[1]) == w[2], ("rule for %q: %s (want %s)"):format(w[1], tostring(sig(w[1])), tostring(w[2])))
    end
    -- names offered for a hand-written note
    local s = G.ParseLine("N Report|N|Speak with Marshal Dughan in Goldshire.|", 1)
    check(Sig.TalkMatches(s, "Marshal Dughan") and not Sig.TalkMatches(s, "Goldshire") and not Sig.TalkMatches(s, "Marshal"), "\"Speak with X in Y.\" offers X only")
    s = G.ParseLine("N Visit|N|To Dr. Weavil.|", 1)
    check(Sig.TalkMatches(s, "Dr. Weavil"), "a name with a full stop in it still matches")
end

-- ---- a saved route that is gone from the data (2026-11-12: the guides made from another addon's database were
-- retired, so a character whose saved route was one of them logs in with an id nothing registers) ----
do
    CompletionRouteDB, CompletionRouteCharDB = nil, nil
    local NS = boot()
    local P, G = NS.Progress, NS.Guide
    local gone = "qdb:era:1431:Both"
    CompletionRouteCharDB.guide, CompletionRouteCharDB.welcomed = gone, true
    NS.Account.me.stepDone[gone] = { k1 = true, k2 = true }
    local said = {}
    local realPrint = NS.Print
    NS.Print = function(_, msg) said[#said + 1] = tostring(msg) end
    -- the login: PLAYER_READY, then the timers it starts.  The stub's timer runs its function at once, and a ticker
    -- that re-arms itself (Routing/Roads.lua) would never return: queue them and run four rounds (the autoload's
    -- three tries fit in them)
    local realAfter = C_Timer.After
    local function login()
        local queue = {}
        C_Timer.After = function(_, fn) queue[#queue + 1] = fn end
        local ok, err = pcall(function()
            NS:Fire("PLAYER_READY")
            for _ = 1, 4 do
                local run = queue
                queue = {}
                for _, fn in ipairs(run) do fn() end
            end
        end)
        C_Timer.After = realAfter
        return ok, err
    end
    -- no leveling route fits: the login says so and loads nothing
    local ok, err = login()
    check(ok, "login with a saved route that no longer exists raises nothing: " .. tostring(err))
    check(NS.db.char.lastAutoloadError == nil, "and the autoload reports no error: " .. tostring(NS.db.char.lastAutoloadError))
    check(P.guide == nil and table.concat(said, "\n"):find("No route matched", 1, true) ~= nil,
          "with nothing to suggest the player is told to open the list")
    check(#P.RecentList() == 0, "the gone route is not offered under Recent")
    check(NS.Account.me.stepDone[gone] and NS.Account.me.stepDone[gone].k1, "its saved marks are left alone")
    -- a leveling route fits: it is loaded in place of the gone one
    G.Register({ id = "f:level", name = "Level 1-10", type = "Leveling", minlevel = 1, maxlevel = 10, source = "CompletionRoute",
                 text = "N One|\nN Two|" })
    NS.db.char.guide = gone
    ok, err = login()
    check(ok and P.guide and P.guide.id == "f:level" and NS.db.char.guide == "f:level",
          "with a fitting route the login loads that one instead: " .. tostring(err or (P.guide and P.guide.id)))
    NS.Print = realPrint
end

print(("%s: %d checks, %d failed"):format(fails == 0 and "FLOW TESTS PASSED" or "FLOW TESTS FAILED", checks, fails))
os.exit(fails == 0 and 0 or 1)
