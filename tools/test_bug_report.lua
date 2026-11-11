-- CompletionRoute :: tools/test_bug_report.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- Offline tests of the beta bug report (Core/BugReport.lua, /cr bug), against stubs (no client):
--   * a report holds the client, character, guide, step (with its raw line), upcoming steps, progress, quest log,
--     position, route legs, options, the last 30 log lines and the last addon Lua error, and never a character
--     or realm name
--   * the error hook chains the previous handler and never swallows an error; only this addon's errors are kept (an
--     error that merely names CompletionRouteDB, or another addon called CompletionRoute*, is not)
--   * quests that only gate a step (PRE, ACTIVE, AVAILABLE) and profession skill (|P|, SKILL) are in the report, with
--     the open steps; the replay restores the skill; a click makes no path search for the upcoming list
--   * 2-letter character names and names typed in any case in the note are scrubbed, as whole words
--   * the store keeps 50 reports newest first and stays under its size bound; an oversize report is trimmed
--   * a section that fails is named and the rest of the report still saves
--   * the SavedVariables -> JSON helper (tools/sv_to_json.lua) reads a WoW-style file back without changing it
--   * round trip: vplayer --capture makes a report in the fake world, vplayer --repro --check replays it and must give
--     the same step and route (needs Guides/Imported_Wiki_era.lua; skipped without it); a step gated on a quest the
--     guide never names replays as open, and a report missing that quest is a DIFF of the open steps
-- Run: luajit tools/test_bug_report.lua   (from repo root)
-- CR_WRITE_FIXTURE=path writes the SavedVariables fixture used by tools/test_ingest_beta_reports.py.
package.path = "./?.lua;" .. package.path
local realPrint = print
local printed = {}
print = function(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end printed[#printed + 1] = table.concat(t, " ") end
local ADDON, NS = "CompletionRoute", {}
dofile("tools/stubs.lua")
local J = dofile("tools/json.lua")
local REPRO = dofile("tools/vplayer_repro.lua")
local z2w = z2w
PLAYER = { map = 1429, x = 0.40, y = 0.60 }
PLAYER.wx, PLAYER.wy, PLAYER.inst = z2w(PLAYER.x, PLAYER.y, PLAYER.map)

local passed, failed = 0, 0
local function t(name, cond, detail)
    if cond then passed = passed + 1 realPrint("ok   " .. name)
    else failed = failed + 1 realPrint("FAIL " .. name .. (detail and (" :: " .. tostring(detail)) or "")) end
end
local function sh(cmd) local r = os.execute(cmd) return r == 0 or r == true end
local TMP = (os.getenv("CR_TEST_TMP") or "/private/tmp/claude-501") .. "/cr_test_bug_report_" .. tostring(os.time())
if not sh("mkdir -p '" .. TMP .. "'") then TMP = "/tmp/cr_test_bug_report_" .. tostring(os.time()) sh("mkdir -p '" .. TMP .. "'") end

-- client bits the stubs leave out
local CHAR_NAME, REALM = "Zorbulon", "Quelthar"
function UnitName() return CHAR_NAME end
function GetRealmName() return REALM end
function GetLocale() return "enUS" end
function GetZoneText() return "Elwynn Forest" end
function GetSubZoneText() return "Goldshire" end
function IsInInstance() return false, "none" end
time = os.time
-- a client error handler to chain onto (the real one prints the error frame)
local handlerCalls = {}
local prevHandler = function(err, ...) handlerCalls[#handlerCalls + 1] = { err = err, n = select("#", ...) } return "prev-result" end
local currentHandler = prevHandler
function geterrorhandler() return currentHandler end
function seterrorhandler(fn) currentHandler = fn end
local STACK = ""
function debugstack() return STACK end

local function load(path) assert(loadfile("CompletionRoute/" .. path))(ADDON, NS) end
-- TOC order: Core/BugReport.lua right after Core/Init.lua (its error hook goes in before the rest of the addon)
for _, f in ipairs({ "Core/Init.lua", "Core/BugReport.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", "Data/Taxi_tbc.lua", "Data/Transit.lua",
    "Data/Access.lua", "Data/Inns.lua", "Data/ZoneAliases.lua", "Data/Roads_ek.lua", "Data/Roads_kalimdor.lua", "Routing/TravelGraph.lua",
    "Routing/Roads.lua", "Routing/StepOrder.lua", "Routing/Router.lua", "Core/Account.lua", "Core/Professions.lua", "Core/Progress.lua",
    "Core/Recommend.lua", "Core/Instances.lua", "UI/Log.lua" }) do load(f) end
CompletionRouteDB, CompletionRouteCharDB = nil, nil
for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", "CompletionRoute") end
NS.Account.Init()
NS.TravelGraph.Build()
local BR, P, G, R = NS.BugReport, NS.Progress, NS.Guide, NS.Router
NS.HEARTH_ITEM = NS.HEARTH_ITEM or 6948

-- ---------------------------------------------------------------------------
-- 1. Error hook
-- ---------------------------------------------------------------------------
t("error hook installed over the client's handler", currentHandler == BR.errorHook and BR.errorHook ~= nil)
STACK = "[string \"@Interface/AddOns/CompletionRoute/Core/BugReport.lua\"]:120: in function <...>\n[C]: in function `error'"
local res = currentHandler("Interface/AddOns/CompletionRoute/Core/Progress.lua:200: attempt to index nil", "extra")
t("an addon error reaches the previous handler unchanged", #handlerCalls == 1 and handlerCalls[1].err:find("Progress.lua:200", 1, true) ~= nil)
t("the previous handler's result is returned", res == "prev-result", res)
t("an error whose message names the addon is kept", BR.lastError and BR.lastError.msg:find("attempt to index nil", 1, true) ~= nil)
t("the hook's own frames are dropped from the stack", BR.lastError and not BR.lastError.stack:find("BugReport.lua", 1, true), BR.lastError and BR.lastError.stack)
t("the error is saved account-wide", CompletionRouteDB.lastError and CompletionRouteDB.lastError.msg == BR.lastError.msg)
local before = BR.lastError
STACK = "Interface/AddOns/OtherAddon/Main.lua:5: in function <...>"
currentHandler("Interface/AddOns/OtherAddon/Main.lua:5: boom")
t("another addon's error is not kept", BR.lastError == before and BR.lastError.msg:find("index nil", 1, true))
t("another addon's error still reaches the previous handler", #handlerCalls == 2)
STACK = "Interface/FrameXML/ChatFrame.lua:10: in function <...>\nInterface/AddOns/CompletionRoute/UI/GuideFrame.lua:42: in function `Update'"
currentHandler("Interface/FrameXML/ChatFrame.lua:10: bad argument #1")
t("an error raised in Blizzard code under this addon (stack) is kept", BR.lastError.msg:find("bad argument", 1, true) ~= nil)
STACK = "[string \"@Interface/AddOns/CompletionRoute/Core/BugReport.lua\"]:130: in function <...>"
local held = BR.lastError
currentHandler("Interface/FrameXML/Foo.lua:1: unrelated")
t("only the hook's own frame naming the addon does not count", BR.lastError == held)
debugstack = function() error("debugstack exploded") end
local okCall, r2 = pcall(currentHandler, "Interface/AddOns/CompletionRoute/Core/Guide.lua:9: x")
t("a failure inside the hook never stops the chain", okCall and r2 == "prev-result" and #handlerCalls == 5, tostring(r2) .. " calls=" .. #handlerCalls)
debugstack = function() return STACK end
-- the same error twice in one frame (a second copy of the hook in the chain) is one record
local t0 = GetTime
GetTime = function() return 100 end
currentHandler("Interface/AddOns/CompletionRoute/Core/Farm.lua:1: repeated")
local c1 = BR.lastError.count
currentHandler("Interface/AddOns/CompletionRoute/Core/Farm.lua:1: repeated")
GetTime = function() return 101 end
currentHandler("Interface/AddOns/CompletionRoute/Core/Farm.lua:1: repeated")
t("a repeated error is counted, not duplicated", c1 == 1 and BR.lastError.count == 2, tostring(c1) .. " -> " .. tostring(BR.lastError.count))
GetTime = t0
-- another addon's error that only names this addon's globals, or comes from an addon whose folder starts the same
local kept0, persisted0 = BR.lastError, CompletionRouteDB.lastError
STACK = "Interface/AddOns/OtherAddon/Main.lua:5: in function <Interface/AddOns/OtherAddon/Main.lua:3>"
currentHandler("Interface/AddOns/OtherAddon/Main.lua:5: attempt to index global 'CompletionRouteDB' (a nil value)")
t("another addon's error that names CompletionRouteDB is not kept", BR.lastError == kept0, BR.lastError and BR.lastError.msg)
STACK = "Interface/AddOns/CompletionRouteExtras/Core.lua:9: in function <Interface/AddOns/CompletionRouteExtras/Core.lua:3>"
currentHandler("Interface/AddOns/CompletionRouteExtras/Core.lua:9: boom")
t("an error from an addon named CompletionRoute* is not kept", BR.lastError == kept0, BR.lastError and BR.lastError.msg)
-- the client shortens a long source name from the front: "...dOns/CompletionRoute/..." is still this addon
STACK = ""
currentHandler("...dOns\\CompletionRoute\\Guides\\Imported_WoWPro_retail.lua:9: shortened")
t("an error whose shortened source names this addon's folder is kept", BR.lastError ~= kept0 and BR.lastError.msg:find("shortened", 1, true) ~= nil)
BR.lastError, CompletionRouteDB.lastError = kept0, persisted0
-- PLAYER_LOGIN: something replaced the handler; the hook wraps it again
local intruder = function(err) return "intruder" end
currentHandler = intruder
BR.Rewrap()   -- what the PLAYER_LOGIN handler runs
t("at login a replaced handler is wrapped again", currentHandler ~= intruder and currentHandler("x") == "intruder")
currentHandler = BR.errorHook

-- ---------------------------------------------------------------------------
-- 2. A report of a loaded guide
-- ---------------------------------------------------------------------------
local Z = "|Z|1429; Elwynn Forest|"
local lines = {
    "A Bounty on Murlocs|QID|46|M|42.1,65.9" .. Z,
    "A Lost Necklace|QID|85|M|43.3,65.7" .. Z,
    "C Bounty on Murlocs|QID|46|M|38.4,81.3;39.0,82.0" .. Z,
    "T Bounty on Murlocs|QID|46|M|42.1,65.9" .. Z,
    "T A Lost Necklace|QID|85|M|79.4,68.8" .. Z,
    "A Westfall Stew|QID|36|M|56.0,31.0|Z|1436; Westfall|",
    "C Westfall Stew|QID|36|M|45.0,40.0|Z|1436; Westfall|",
}
G.Register({ id = "t:elwynn", name = "Elwynn sample", type = "Leveling", faction = "Alliance", minlevel = 5, maxlevel = 10,
             source = "test", text = table.concat(lines, "\n") })
-- the world: 46 accepted, 85 done
local quests = { [46] = "log", [85] = "done" }
C_QuestLog.IsOnQuest = function(q) return quests[q] == "log" or quests[q] == "complete" end
C_QuestLog.IsQuestFlaggedCompleted = function(q) return quests[q] == "done" end
C_QuestLog.IsComplete = function(q) return quests[q] == "complete" end
C_QuestLog.GetLogIndexForQuestID = function(q) return (quests[q] == "log" or quests[q] == "complete") and 1 or nil end
C_QuestLog.GetQuestObjectives = function(q) if q == 46 then return { { numFulfilled = 3, numRequired = 8, finished = false, text = "x" } } end return {} end
NS.db.char.knownTaxi = { [2] = true, [4] = true, [5] = true, [6] = true }
P.Load("t:elwynn")
-- a log line that carries the character and realm names (as /cr chars output does)
NS:Print("  " .. CHAR_NAME .. "-" .. REALM .. "  Alliance WARRIOR lvl 5")
NS:Print("Scope: This server (" .. REALM .. ")")
local tc0 = os.clock()
local r = BR.Capture("arrow points at " .. CHAR_NAME .. " on " .. REALM)
local captureMs = (os.clock() - tc0) * 1000
t("capture returns a report", type(r) == "table" and type(r.id) == "string")
t("the id is flavor-date-time-hex", r.id:match("^tbc%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%x%x%x%x$") ~= nil, r.id)
t("the chat line names the id", printed[#printed]:find(r.id, 1, true) ~= nil, printed[#printed])
t("stored newest first", CompletionRouteDB.bugReports[1] == r)
t("no section failed", r.errors == nil, r.errors and J.encode(r.errors))
t("client: flavor, build, interface, locale", r.client.flavor == "tbc" and r.client.dataFlavor == "tbc" and r.client.interface == 20506
    and r.client.build == "2.5.6" and r.client.buildNum == "69110" and r.client.locale == "enUS", J.encode(r.client))
t("addon version", r.addon.version == tostring(NS.version))
t("character: class, race, level, faction", r.char.class == "WARRIOR" and r.char.race == "Human" and r.char.level == 5 and r.char.faction == "Alliance",
    J.encode(r.char))
t("character: speed and flying", type(r.char.speed) == "number" and r.char.canFly == false)
t("guide: id, name, steps, checksum", r.guide.id == "t:elwynn" and r.guide.name == "Elwynn sample" and r.guide.steps == 7 and r.guide.authored == 7
    and type(r.guide.sum) == "number", J.encode(r.guide))
t("step is the current step", r.step and r.step.index == P.current.index and r.step.action == P.current.action, r.step and r.step.index)
t("step: raw guide line", r.step.raw == lines[r.step.index], r.step.raw)
t("step: quest ids, zone, points, location source", r.step.qid == table.concat(P.current.qid, ",") and r.step.zone == 1429
    and r.step.coords and r.step.coords[1][1] and r.step.locSource ~= nil, J.encode(r.step))
t("upcoming: the visible steps, first = current, with travel seconds", #r.upcoming >= 3 and r.upcoming[1].index == r.step.index
    and type(r.upcoming[1].secs) == "number", #r.upcoming)
t("window order recorded", type(r.order) == "string" and r.order:match("^" .. r.step.index) ~= nil, r.order)
t("progress: done step indices", r.progress and r.progress.done ~= nil and r.progress.pending > 0, r.progress and J.encode(r.progress))
t("quest log: 46 in log, 85 done", r.quests.log == "46" and r.quests.done == "85", J.encode(r.quests))
t("objectives of quests in the log", r.objectives["46"] and r.objectives["46"][1][1] == 3 and r.objectives["46"][1][2] == 8)
t("items: hearthstone count", r.items[tostring(NS.HEARTH_ITEM)] == 1, J.encode(r.items))
t("position: map, x, y, world, instance", r.player.map == 1429 and math.abs(r.player.x - 40) < 0.01 and math.abs(r.player.y - 60) < 0.01
    and r.player.wx and r.player.inst == 0 and r.player.inInstance == false, J.encode(r.player))
t("route: legs with mode and seconds", r.route and r.route.found and #r.route.legs >= 1 and r.route.legs[1].mode
    and type(r.route.legs[1].secs) == "number" and type(r.route.secs) == "number" and r.route.desc, r.route and J.encode(r.route))
t("arrow advice", r.arrow and r.arrow.mode ~= nil, r.arrow and J.encode(r.arrow))
-- the report records the policy in force: "known" is the default since routing-graph (IDEAS #2), "faction" when the
-- profile assumes every flight path (routing.assumeAllTaxi) or picked the old rule
t("travel: taxi policy and known flight paths", r.travel.taxiPolicy == NS.TravelGraph.TaxiPolicy() and r.travel.taxiPolicy == "known" and r.travel.knownTaxi == "2,4..6" and r.travel.knownTaxiCount == 4,
    J.encode(r.travel))
t("travel: hearth", r.travel.hasHearthstone == true and r.travel.bindName == "Goldshire")
t("options: routing settings", r.options.routing.window == 24 and r.options.routing.reorder == true and r.options.scope ~= nil)
t("log: the last lines, at most 30", #r.log >= 2 and #r.log <= 30 and r.log[#r.log]:find("Scope", 1, true) ~= nil, #r.log)
t("last addon error", r.lastError and r.lastError.msg:find("repeated", 1, true) and r.lastError.count == 2 and r.lastError.source == "hook",
    r.lastError and J.encode(r.lastError))
local blob = J.encode(r)
t("no character name anywhere in the report", not blob:find(CHAR_NAME, 1, true))
t("no realm name anywhere in the report", not blob:find(REALM, 1, true))
t("names in free text are replaced", r.note == "arrow points at <char> on <realm>" and r.log[#r.log - 1]:find("<char>", 1, true) ~= nil, r.note)
t("report fits one report's bound", BR.Size(r) <= BR.MAX_REPORT_BYTES and not r.trimmed, BR.Size(r))
t("capture time recorded", type(r.captureMs) == "number")
realPrint(("     capture took %.2f ms here (stub world, %s)"):format(captureMs, jit and (jit.status() and "JIT on" or "JIT off") or "plain Lua"))

-- the note box path: snapshot first, note afterwards
t("a note can be added to a saved report", BR.SetNote(r.id, "  later note about " .. CHAR_NAME .. "  ") and BR.Find(r.id).note == "later note about <char>")
t("an empty note is ignored", BR.SetNote(r.id, "   ") == false and BR.Find(r.id).note == "later note about <char>")
local nPrinted = #printed
BR.Command("list")
t("/cr bug list prints the stored reports", #printed > nPrinted and printed[nPrinted + 2] and printed[nPrinted + 2]:find(r.id, 1, true) ~= nil)
BR.Command("second report from the slash command")
t("/cr bug <note> saves with the note", CompletionRouteDB.bugReports[1].note == "second report from the slash command" and CompletionRouteDB.bugReports[2] == r)

-- a click makes no path search for the upcoming list: the planner's kept costs, or nothing
local TGs = NS.TravelGraph.stats
local calls0 = TGs.calls
local rw = BR.Snapshot("")
t("a snapshot with the arrow's path fresh makes no path search", TGs.calls == calls0, TGs.calls - calls0)
NS.TravelGraph.PathCacheWipe()   -- what a graph rebuild (a turn-in) does: the planner's kept costs are stale until it runs
calls0 = TGs.calls
local rc0 = BR.Snapshot("")
local later = 0 for i = 2, #rc0.upcoming do if rc0.upcoming[i].secs ~= nil then later = later + 1 end end
t("after a graph rebuild the upcoming list is left unpriced, not searched", TGs.calls == calls0 and later == 0 and type(rc0.upcoming[1].secs) == "number",
    ("searches %d, priced %d"):format(TGs.calls - calls0, later))
t("with the planner's costs in place the upcoming steps carry seconds", #rw.upcoming >= 2 and type(rw.upcoming[2].secs) == "number",
    rw.upcoming[2] and tostring(rw.upcoming[2].secs))

-- quests that only gate a step, and profession skill (verifier finding 2026-11-10: a replay hid a PRE-gated step and
-- still said MATCH)
local gatedLines = {
    "A Gated Quest|QID|47|PRE|6623|M|42.1,65.9" .. Z,             -- PRE done: open
    "A Gated Not Yet|QID|52|PRE|6629|M|42.5,65.0" .. Z,           -- PRE not done: hidden
    "C While On|QID|48|ACTIVE|6624|M|43.3,65.7" .. Z,            -- on 6624: open
    "A Until Done|QID|49|AVAILABLE|6625|M|44.0,66.0" .. Z,        -- 6625 done: hidden
    "C Herb run|QID|50|P|Herbalism;75|M|45.0,67.0" .. Z,          -- Herbalism 50: hidden
    "M Cook up|SKILL|Cooking;50|M|46.0,67.0" .. Z,                -- Cooking unknown to the client: open
}
G.Register({ id = "t:gated", name = "Gated sample", type = "Leveling", faction = "Alliance", minlevel = 5, maxlevel = 10,
             source = "test", text = table.concat(gatedLines, "\n") })
quests[6623], quests[6624], quests[6625] = "done", "log", "done"
local Prof = NS.Professions
local skill0, knows0 = Prof.Skill, Prof.KnowsSpell
Prof.Skill = function(name) if name == "Herbalism" then return 50, 75 end return nil end
P.Load("t:gated")
local rg = BR.Snapshot("")
t("gated guide: no section failed", rg.errors == nil, rg.errors and J.encode(rg.errors))
t("the open steps are listed (PRE, ACTIVE, AVAILABLE, |P| gates applied)", rg.progress.open == "1,3,6" and rg.progress.pending == 3, rg.progress.open)
t("quests that only gate a step are in the quest states", rg.quests.done == "6623,6625" and rg.quests.log == "6624" and rg.quests.named == 9,
    J.encode(rg.quests))
t("profession skill for |P| and SKILL steps: rank/max, false when unknown", rg.profs and rg.profs.Herbalism and rg.profs.Herbalism[1] == 50
    and rg.profs.Herbalism[2] == 75 and rg.profs.Cooking == false, rg.profs and J.encode(rg.profs))
-- the replay's side: the skill as the client read it
Prof.Skill = skill0
local Cond = NS.Cond
t("replay restores a skill below the gate", REPRO.RestoreProfs({ profs = { Herbalism = { 50, 75 } } }, NS) and Cond.ProfMatch("Herbalism;75") == false)
REPRO.RestoreProfs({ profs = { Herbalism = { 80, 150 } } }, NS)
t("replay restores a skill at the gate", Cond.ProfMatch("Herbalism;75") == true)
REPRO.RestoreProfs({ profs = { Herbalism = false, ["Cooking#2545"] = { 10, 100 } } }, NS)
t("a skill the client could not read stays unknown; a tier skill is found by tier", Cond.ProfMatch("Herbalism;75") == true
    and select(1, Prof.Skill("Cooking", 2545)) == 10 and Prof.Skill("Cooking") == nil)
t("no profession skill in a report: nothing restored", REPRO.RestoreProfs({}, NS) == false)
Prof.Skill, Prof.KnowsSpell = skill0, knows0
quests[6623], quests[6624], quests[6625] = nil, nil, nil
P.Load("t:elwynn")

-- names: 2 letters, whole words only, any case in the note (verifier finding 2026-11-10)
local name0 = NS.player.name
NS.player.name = "Al"
t("a 2-letter name is scrubbed as a whole word", BR.Scrub("Scope: Al only; Alliance, Halls and Kal stay") == "Scope: <char> only; Alliance, Halls and Kal stay",
    BR.Scrub("Scope: Al only; Alliance, Halls and Kal stay"))
t("the note is scrubbed in any letter case", BR.Scrub("Al got stuck; my main al too, AL!", true) == "<char> got stuck; my main <char> too, <char>!",
    BR.Scrub("Al got stuck; my main al too, AL!", true))
NS:Print("Scope: Al only")
local ra = BR.Snapshot("Al got stuck here; my main al too")
t("a report with a 2-letter name carries it nowhere in free text", ra.note == "<char> got stuck here; my main <char> too"
    and ra.log[#ra.log]:find("Scope: <char> only", 1, true) ~= nil, ra.note .. " | " .. tostring(ra.log[#ra.log]))
NS.player.name = "Andrè"
t("a name ending in a non-ASCII letter is still scrubbed", BR.Scrub("Andrè was here") == "<char> was here", BR.Scrub("Andrè was here"))
NS.player.name = name0

-- ---------------------------------------------------------------------------
-- 3. Failing sections, no guide, caps and size
-- ---------------------------------------------------------------------------
local hw = NS.TravelGraph.HearthWorld
NS.TravelGraph.HearthWorld = function() error("hearth exploded") end
local rf = BR.Snapshot("section failure")
NS.TravelGraph.HearthWorld = hw
t("a failing section is named and the rest still saves", rf.errors and rf.errors.travel and rf.errors.travel:find("hearth exploded", 1, true)
    and rf.step and rf.route and rf.client, rf.errors and J.encode(rf.errors))

local savedGuide, savedCur = P.guide, P.current
P.guide, P.current, P.steps, P.order = nil, nil, nil, nil
local rn = BR.Snapshot("")
t("no guide loaded: client, character and position still saved", rn.guide == nil and rn.step == nil and rn.client and rn.player and rn.errors == nil,
    rn.errors and J.encode(rn.errors))
P.Load("t:elwynn")

CompletionRouteDB.bugReports = {}
local ids = {}
for i = 1, 60 do local x = BR.Snapshot("n" .. i) BR.Save(x) ids[i] = x.id end
local store = CompletionRouteDB.bugReports
t("at most 50 reports kept", #store == 50, #store)
t("newest first, oldest dropped", store[1].note == "n60" and store[50].note == "n11", store[1].note .. " / " .. store[50].note)
local uniq = {} for _, x in ipairs(store) do uniq[x.id] = true end
local nu = 0 for _ in pairs(uniq) do nu = nu + 1 end
t("ids stay unique within a second", nu == 50, nu)

-- an oversize report: a huge log and stack
for i = 1, 300 do NS.Log.lines[#NS.Log.lines + 1] = ("12:00:00 filler line %d %s"):format(i, string.rep("x", 250)) end
BR.lastError = { msg = "Interface/AddOns/CompletionRoute/x.lua:1: big", stack = string.rep("frame\n", 600), count = 1 }
local big = BR.Snapshot(string.rep("n", 2000))
t("an oversize report is trimmed under the bound", BR.Size(big) <= BR.MAX_REPORT_BYTES and big.trimmed == true, BR.Size(big))
t("the note is capped", #big.note <= BR.NOTE_MAX + 3, #big.note)
CompletionRouteDB.bugReports = {}
local oldMax = BR.MAX_REPORT_BYTES
BR.MAX_REPORT_BYTES = 60 * 1024   -- let big reports through to test the store bound
for i = 1, 50 do
    local x = BR.Snapshot("big " .. i)
    x.padding = string.rep("p", 20000)
    BR.Save(x)
end
BR.MAX_REPORT_BYTES = oldMax
local total = 0 for _, x in ipairs(CompletionRouteDB.bugReports) do total = total + BR.Size(x) end
t("the store stays under its size bound", total <= BR.MAX_BYTES and #CompletionRouteDB.bugReports < 50 and CompletionRouteDB.bugReports[1].note == "big 50",
    ("%d bytes in %d reports"):format(total, #CompletionRouteDB.bugReports))

-- ---------------------------------------------------------------------------
-- 4. JSON and the SavedVariables helper
-- ---------------------------------------------------------------------------
local tricky = { s = "quote \" back \\ tab \t nl \n ctrl \1 é ✓", n = 1.25, i = -3, b = false, list = { 1, 2, 3 }, empty = {}, nested = { a = { b = "c" } } }
local back = J.decode(J.encode(tricky))
t("json round trip", back.s == tricky.s and back.n == 1.25 and back.i == -3 and back.b == false and #back.list == 3 and back.nested.a.b == "c")
t("json: NaN and infinity become null", J.encode({ 1, 0 / 0, math.huge }) == "[1,null,null]", J.encode({ 1, 0 / 0, math.huge }))
t("json: unicode escapes decode to UTF-8", J.decode('"\\u00e9\\u2713\\ud83d\\ude00"') == "é✓😀")

-- a WoW-style SavedVariables file (the client writes `["key"] = value,` lines, arrays with -- [n] comments)
local function ser(v, ind, out)
    if type(v) == "table" then
        out[#out + 1] = "{\n"
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) if type(a) ~= type(b) then return type(a) == "number" end return a < b end)
        for _, k in ipairs(keys) do
            out[#out + 1] = ind .. "\t"
            if type(k) == "number" then out[#out + 1] = "[" .. k .. "] = " else out[#out + 1] = ("[%q] = "):format(k) end
            ser(v[k], ind .. "\t", out)
            out[#out + 1] = type(k) == "number" and (", -- [" .. k .. "]\n") or ",\n"
        end
        out[#out + 1] = ind .. "}"
    elseif type(v) == "string" then out[#out + 1] = ("%q"):format(v):gsub("\\\n", "\\n")
    else out[#out + 1] = tostring(v) end
end
local function writeSV(path, db)
    local o = { "\nCompletionRouteDB = " }
    ser(db, "", o)
    o[#o + 1] = "\n"
    local f = assert(io.open(path, "w")) f:write(table.concat(o)) f:close()
end
CompletionRouteDB.bugReports = { r, rf }
local svPath = TMP .. "/CompletionRoute.lua"
writeSV(svPath, CompletionRouteDB)
local f0 = io.open(svPath) local before0 = f0:read("*a") f0:close()
local p = io.popen("luajit tools/sv_to_json.lua '" .. svPath .. "'")
local jtext = p:read("*a") p:close()
local f1 = io.open(svPath) local after0 = f1:read("*a") f1:close()
local okj, dec = pcall(J.decode, jtext)
t("sv_to_json reads the reports back", okj and dec.bugReports and #dec.bugReports == 2 and dec.bugReports[1].id == r.id, okj and "" or dec)
t("sv_to_json: fields survive (step, route legs, upcoming)", okj and dec.bugReports[1].step.raw == r.step.raw
    and dec.bugReports[1].route.legs[1].mode == r.route.legs[1].mode and #dec.bugReports[1].upcoming == #r.upcoming)
t("sv_to_json: lastError comes along", okj and dec.lastError and dec.lastError.msg == CompletionRouteDB.lastError.msg)
t("sv_to_json never changes the file", before0 == after0)
local evil = TMP .. "/evil.lua"
local fe = assert(io.open(evil, "w")) fe:write("os.execute('touch " .. TMP .. "/pwned') CompletionRouteDB = {}\n") fe:close()
local pe = io.popen("luajit tools/sv_to_json.lua '" .. evil .. "' 2>&1; echo EXIT=$?")
local etext = pe:read("*a") pe:close()
t("sv_to_json runs the file without os/io", etext:find("EXIT=2", 1, true) ~= nil and not io.open(TMP .. "/pwned"), etext)
local loop = TMP .. "/loop.lua"
local fl = assert(io.open(loop, "w")) fl:write("while true do end\n") fl:close()
local pl = io.popen("luajit tools/sv_to_json.lua '" .. loop .. "' 2>&1; echo EXIT=$?")
local ltext = pl:read("*a") pl:close()
t("sv_to_json stops a file that never finishes", ltext:find("budget", 1, true) ~= nil and ltext:find("EXIT=2", 1, true) ~= nil, ltext)

local fixture = os.getenv("CR_WRITE_FIXTURE")
if fixture then
    CompletionRouteDB.bugReports = { r, rn }
    CompletionRouteDB.chars = { [CHAR_NAME .. "-" .. REALM] = { done = {}, level = 5 } }   -- what the real file also holds
    writeSV(fixture, CompletionRouteDB)
    realPrint("     wrote fixture " .. fixture)
end

-- ---------------------------------------------------------------------------
-- 5. Round trip in the virtual player: capture in the fake world, replay, same step and route
-- ---------------------------------------------------------------------------
local wiki = io.open("CompletionRoute/Guides/Imported_Wiki_era.lua", "r")
if not wiki then
    realPrint("skip round trip: CompletionRoute/Guides/Imported_Wiki_era.lua is not generated here")
else
    wiki:close()
    local cap = TMP .. "/capture.json"
    local pc = io.popen(("luajit tools/vplayer.lua era --capture auto --capture-steps 7 --capture-out '%s' 2>&1"):format(cap))
    local ctext = pc:read("*a") pc:close()
    t("vplayer --capture writes a report", ctext:find("CAPTURED", 1, true) ~= nil, ctext:sub(-400))
    local fc = io.open(cap)
    local rc = fc and J.decode(fc:read("*a"))
    if fc then fc:close() end
    t("the captured report has a guide, a step and a route of several legs", rc and rc.guide and rc.step and rc.route and rc.route.found
        and #rc.route.legs >= 2, rc and (rc.errors and J.encode(rc.errors) or (rc.route and rc.route.desc)))
    local pr = io.popen(("luajit tools/vplayer.lua --repro '%s' --check 2>&1; echo EXIT=$?"):format(cap))
    local rtext = pr:read("*a") pr:close()
    t("vplayer --repro --check gives the same step and route", rtext:find("RESULT MATCH", 1, true) ~= nil and rtext:find("EXIT=0", 1, true) ~= nil,
        rtext:sub(-1500))
    t("the replay prints the recorded route and the offline route", rtext:find("route (client):", 1, true) ~= nil and rtext:find("route (offline):", 1, true) ~= nil)
    -- a report that disagrees with the world must say so (and fail --check)
    if rc and rc.step then
        rc.step.index = rc.step.index + 1000
        local bad = TMP .. "/bad.json"
        local fb = assert(io.open(bad, "w")) fb:write(J.encode(rc)) fb:close()
        local pb = io.popen(("luajit tools/vplayer.lua --repro '%s' --check 2>&1; echo EXIT=$?"):format(bad))
        local btext = pb:read("*a") pb:close()
        t("a report that does not match is reported as a DIFF and fails --check", btext:find("RESULT DIFF", 1, true) ~= nil and btext:find("EXIT=1", 1, true) ~= nil,
            btext:sub(-600))
    end
    -- a step gated on a quest the guide never names (PRE): the report must carry that quest, the replay must show the
    -- step open, and a report without that quest must be a DIFF of the open steps (not an ordering note and MATCH)
    local GATED, GATE = "wiki:era:1417:Horde", 6623
    local gcap = TMP .. "/gated.json"
    local pg = io.popen(("luajit tools/vplayer.lua era --capture %s --capture-steps 0 --capture-done %d --capture-out '%s' 2>&1"):format(GATED, GATE, gcap))
    local gtext = pg:read("*a") pg:close()
    if gtext:find("capture: no guide", 1, true) then
        realPrint("skip gated round trip: " .. GATED .. " is not in this Imported_Wiki_era.lua")
    else
        local fg = io.open(gcap)
        local rgc = fg and J.decode(fg:read("*a"))
        if fg then fg:close() end
        local doneQ = {}
        for _, q in ipairs(REPRO.Expand(rgc and rgc.quests and rgc.quests.done)) do if q ~= GATE then doneQ[#doneQ + 1] = q end end
        t("the gate quest (PRE only, never a step's quest) is in the captured quest states",
            rgc and #REPRO.Expand(rgc.quests.done) == #doneQ + 1, rgc and J.encode(rgc.quests) or gtext:sub(-400))
        local pq = io.popen(("luajit tools/vplayer.lua --repro '%s' --check 2>&1; echo EXIT=$?"):format(gcap))
        local qtext = pq:read("*a") pq:close()
        t("the gated report replays with the same open steps and MATCH", qtext:find("open steps: same as the client", 1, true) ~= nil
            and qtext:find("RESULT MATCH", 1, true) ~= nil and qtext:find("EXIT=0", 1, true) ~= nil, qtext:sub(-1200))
        if rgc then
            rgc.quests.done = table.concat(doneQ, ",")
            local old = TMP .. "/gated_old.json"
            local fo = assert(io.open(old, "w")) fo:write(J.encode(rgc)) fo:close()
            local po = io.popen(("luajit tools/vplayer.lua --repro '%s' --check 2>&1; echo EXIT=$?"):format(old))
            local otext = po:read("*a") po:close()
            t("a report without the gate quest is a DIFF of the open steps and fails --check", otext:find("RESULT DIFF", 1, true) ~= nil
                and otext:find("open steps", 1, true) ~= nil and otext:find("open in the client, not offline", 1, true) ~= nil
                and otext:find("EXIT=1", 1, true) ~= nil, otext:sub(-900))
        end
    end
    local ps = io.popen(("luajit tools/vplayer.lua --repro '%s' --show 2>&1; echo EXIT=$?"):format(cap))
    local stext = ps:read("*a") ps:close()
    t("--show prints the report without loading a world", stext:find("REPORT", 1, true) ~= nil and not stext:find("REPLAY", 1, true)
        and stext:find("EXIT=0", 1, true) ~= nil, stext:sub(-400))
end

os.execute("rm -rf '" .. TMP .. "'")
realPrint(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
realPrint("ALL BUG REPORT TESTS PASSED")
