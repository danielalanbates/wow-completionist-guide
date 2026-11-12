-- CompletionRoute :: Core/BugReport.lua
-- Beta bug reports: /cr bug [note] (or the Report button on the guide window) saves a snapshot of everything an
-- offline replay needs into CompletionRouteDB.bugReports (SavedVariables, newest first, at most 50, size-bounded).
-- Copyright (c) 2026 Daniel Bates / Bates LLC.  All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- A report holds: client flavor and build, addon version, class/race/level/faction (never the character or realm
-- name), the guide and step (index, action, quest ids, raw guide line, how its location was found), the visible
-- upcoming steps, the window order, done/skipped/open steps, the state of the guide's quests and of the quests that
-- only gate a step (PRE, ACTIVE, AVAILABLE), profession skill for |P| and SKILL steps, player map/x/y and world
-- position, the current route (legs, modes, seconds), the arrow's advice, travel settings (flight paths known, hearth),
-- relevant options, the last 30 log lines and the last Lua error raised inside this addon.
-- A click never starts a path search for the upcoming list (it reads the planner's kept costs); only the route to the
-- current step is searched again, and only when the arrow's own path is stale.
-- Offline: tools/ingest_beta_reports.py loads reports into SQL, `luajit tools/vplayer.lua --repro <id>` replays one.
-- See docs/BETA_REPORTS.md.
--
-- This file loads right after Core/Init.lua so its error hook is in place before the rest of the addon runs.
-- Everything else is looked up at call time.
local ADDON, NS = ...
local BR = {}
NS.BugReport = BR

BR.SCHEMA = 1
BR.MAX_REPORTS = 50
BR.MAX_BYTES = 400 * 1024         -- whole store, estimated serialized size
BR.MAX_REPORT_BYTES = 16 * 1024   -- one report; larger ones are trimmed (log, lists, stack) and marked `trimmed`
BR.LOG_LINES = 30
BR.UPCOMING = 8
BR.NOTE_MAX = 500
BR.QUEST_IDS_MAX = 600

-- ---------------------------------------------------------------------------
-- Small helpers (plain Lua 5.1; nothing here may store a function, NaN or infinity in SavedVariables)
-- ---------------------------------------------------------------------------
local function now() if time then return time() end if os and os.time then return os.time() end return 0 end
local function stamp(fmt) if date then return date(fmt) end if os and os.date then return os.date(fmt) end return "?" end
local function num(v, places)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return nil end
    if places then local m = 10 ^ places v = math.floor(v * m + 0.5) / m end
    return v
end
local function trunc(s, n)
    if s == nil then return nil end
    s = tostring(s)
    if #s > n then return s:sub(1, n) .. "..." end
    return s
end
-- "1,2,3,7,9,10,11" -> "1..3,7,9..11" (indices may be negative: access-chain steps)
local function ranges(list)
    table.sort(list)
    local out, i = {}, 1
    while i <= #list do
        local j = i
        while j < #list and list[j + 1] == list[j] + 1 do j = j + 1 end
        if j - i >= 2 then out[#out + 1] = list[i] .. ".." .. list[j]
        else for k = i, j do out[#out + 1] = tostring(list[k]) end end
        i = j + 1
    end
    return table.concat(out, ",")
end
BR.Ranges = ranges
local function escapePattern(s) return (s:gsub("%p", "%%%0")) end
-- this addon's folder in a file path: "AddOns/CompletionRoute/..." or, when the client shortened a long source name,
-- ".../CompletionRoute/...".  A bare "CompletionRoute" is not enough: another addon's error can name CompletionRouteDB.
local ADDON_PATH = "[/\\]" .. escapePattern(ADDON) .. "[/\\]"
local OWN_FILE = escapePattern(ADDON) .. "[/\\]Core[/\\]BugReport%.lua"

-- Estimated serialized size of a value (what it adds to the SavedVariables file).
function BR.Size(v, depth)
    depth = depth or 0
    local t = type(v)
    if t == "string" then return #v + 4 end
    if t == "number" then return 12 end
    if t == "boolean" then return 6 end
    if t ~= "table" or depth > 12 then return 4 end
    local n = 4
    for k, x in pairs(v) do n = n + BR.Size(k, depth + 1) + BR.Size(x, depth + 1) + 4 end
    return n
end

-- Character and realm names must never reach a report.  The snapshot never reads them, but free text (log lines,
-- error text, the note) can carry them, e.g. the /cr chars listing.  Every name this account knows is replaced.
-- WoW names can be 2 letters long, so a name matches as a whole word only (%f frontiers; a side that starts or ends in
-- a non-ASCII letter has no frontier there).  The addon writes names as the client spells them; the note is typed by
-- the player, so it is matched in any letter case.
local function namePattern(s, anyCase)
    local p = escapePattern(s)
    if anyCase then p = p:gsub("%a", function(c) return "[" .. c:lower() .. c:upper() .. "]" end) end
    if s:sub(1, 1):find("^%w") then p = "%f[%w]" .. p end
    if s:sub(-1):find("^%w") then p = p .. "%f[%W]" end
    return p
end
local function scrubList()
    local names, seen = {}, {}
    local function add(s, tag)
        if type(s) == "string" and #s >= 2 and not seen[s] then
            seen[s] = true
            names[#names + 1] = { s, tag, namePattern(s), namePattern(s, true) }
        end
    end
    local p = NS.player or {}
    if p.name and p.realm then add(p.name .. "-" .. p.realm, "<char>") end
    add(p.name, "<char>")
    add(p.realm, "<realm>")
    local chars = NS.db and NS.db.global and NS.db.global.chars
    if type(chars) == "table" then
        for k in pairs(chars) do
            if type(k) == "string" then
                add(k, "<char>")
                local n, r = k:match("^([^%-]+)%-(.+)$")
                add(n, "<char>") add(r, "<realm>")
            end
        end
    end
    table.sort(names, function(a, b) return #a[1] > #b[1] end)   -- "Name-Realm" before "Name" before "Realm"
    return names
end
local function scrub(s, names, anyCase)
    if type(s) ~= "string" then return s end
    for _, n in ipairs(names) do s = s:gsub(anyCase and n[4] or n[3], n[2]) end
    return s
end
BR.Scrub = function(s, anyCase) return scrub(s, scrubList(), anyCase) end

-- ---------------------------------------------------------------------------
-- Lua errors raised inside this addon.  The hook chains the previous handler and always returns what it returns:
-- an error is never swallowed.  Only errors whose message or stack mentions this addon's folder are kept.
-- ---------------------------------------------------------------------------
local function ownStack(stack)
    local keep = {}
    for line in (stack .. "\n"):gmatch("([^\n]*)\n") do
        if line ~= "" and not line:find(OWN_FILE) then keep[#keep + 1] = line end
    end
    return table.concat(keep, "\n")
end
function BR.NoteError(err, stack)
    local msg = tostring(err)
    stack = ownStack(tostring(stack or ""))
    if not (msg:find(ADDON_PATH) or stack:find(ADDON_PATH)) then return false end
    local last = BR.lastError
    local t = GetTime and GetTime() or 0
    -- the same error raised again (or seen twice through a chained copy of this hook): count it, do not re-record
    if last and last.msg == trunc(msg, 600) then
        if last.t ~= t then last.count = (last.count or 1) + 1 last.t = t end
        last.at, last.epoch = stamp("%Y-%m-%d %H:%M:%S"), now()
    else
        BR.lastError = { msg = trunc(msg, 600), stack = trunc(stack, 1500), at = stamp("%Y-%m-%d %H:%M:%S"), epoch = now(),
                         version = tostring(NS.version), flavor = NS.dataFlavor or NS.flavor, count = 1, t = t }
    end
    BR.PersistError()
    return true
end
-- kept account-wide so a report made after a /reload still has it (with its age)
function BR.PersistError()
    local e = BR.lastError
    if not (e and CompletionRouteDB and NS.db) then return end
    CompletionRouteDB.lastError = { msg = e.msg, stack = e.stack, at = e.at, epoch = e.epoch, version = e.version,
                                    flavor = e.flavor, count = e.count }
end
NS:On("ADDON_READY", function() pcall(BR.PersistError) end)   -- an error raised while the addon was still loading
function BR.InstallErrorHook()
    if not (geterrorhandler and seterrorhandler) then return false end
    local prev = geterrorhandler()
    local hook
    hook = function(err, ...)
        pcall(function()
            local stack = debugstack and debugstack(2, 14, 8) or ""
            BR.NoteError(err, stack)
        end)
        if prev then return prev(err, ...) end
    end
    seterrorhandler(hook)
    BR.errorHook = hook
    return true
end
BR.InstallErrorHook()
-- another addon may have replaced the handler since; wrap whatever is there now (the dedupe above keeps one record)
function BR.Rewrap()
    if geterrorhandler and geterrorhandler() ~= BR.errorHook then BR.InstallErrorHook() end
end
NS:RegisterEvent("PLAYER_LOGIN", BR.Rewrap)

-- An error display addon that grabbed the handler first and never chains (it keeps its own list) still knows the error.
local function grabberError()
    local BG = rawget(_G, "BugGrabber")
    if type(BG) ~= "table" or type(BG.GetDB) ~= "function" then return nil end
    local ok, db = pcall(BG.GetDB, BG)
    if not ok or type(db) ~= "table" then return nil end
    for i = #db, math.max(1, #db - 200), -1 do
        local e = db[i]
        if type(e) == "table" then
            local m, s = tostring(e.message or ""), tostring(e.stack or "")
            if m:find(ADDON_PATH) or s:find(ADDON_PATH) then
                return { msg = trunc(m, 600), stack = trunc(ownStack(s), 1500), at = tostring(e.time or "?"),
                         count = tonumber(e.counter), source = "BugGrabber" }
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Snapshot sections.  Each runs under pcall: a section that fails is named in `errors`, the rest still saves.
-- ---------------------------------------------------------------------------
local function stepLoc(s)
    local c = s.coords and s.coords[1]
    return c and num(c.x * 100, 2), c and num(c.y * 100, 2)
end
local function rawLine(g, lineNo)
    if not (g and lineNo) then return nil end
    local text = type(g.text) == "function" and g.text() or g.text
    if type(text) ~= "string" then return nil end
    local n = 0
    for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        n = n + 1
        if n == lineNo then return trunc(line, 400) end
    end
    return nil
end
local function qids(s) if s.qid then local t = {} for i, q in ipairs(s.qid) do t[i] = q end return table.concat(t, ",") end end

local function secClient(r)
    local version, build, bdate, iface = GetBuildInfo()
    r.client = { flavor = NS.flavor, dataFlavor = NS.dataFlavor or NS.flavor, isForever = NS.isForever and true or false,
                 build = tostring(version), buildNum = tostring(build), buildDate = tostring(bdate), interface = num(iface),
                 locale = GetLocale and GetLocale() or nil }
    r.addon = { version = tostring(NS.version), toc = num(NS.tocversion) }
end
local function secChar(r)
    local U = NS.Util
    local p = NS.player or {}
    local c = { class = p.class, race = p.race, faction = p.faction, level = num(UnitLevel("player")),
                levelFrac = num(U.PlayerLevel(), 3) }
    c.dead = (UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")) and true or false
    c.mounted = (IsMounted and IsMounted()) and true or false
    c.flying = (IsFlying and IsFlying()) and true or false
    c.speed = num(U.TravelSpeed(), 2)
    c.canFly = U.CanFly() and true or false
    c.hardcore = NS.Account and NS.Account.IsHardcore and NS.Account.IsHardcore() or false
    r.char = c
end
local function secPlayer(r)
    local U = NS.Util
    local map, x, y, inst, wx, wy = U.PlayerPos()
    local inInst, instType
    if IsInInstance then inInst, instType = IsInInstance() end
    r.player = { map = map, mapName = map and U.MapName(map) or nil, x = x and num(x * 100, 2), y = y and num(y * 100, 2),
                 wx = num(wx, 1), wy = num(wy, 1), inst = inst, inInstance = inInst and true or false, instanceType = instType,
                 zoneText = GetZoneText and GetZoneText() or nil, subzone = GetSubZoneText and GetSubZoneText() or nil }
end
local function secGuide(r)
    local P, G = NS.Progress, NS.Guide
    local g = P.guide
    if not g then r.guide = nil return end
    -- the guide's own (author) order: the same data the offline replay parses, so a changed guide is noticed
    local authored = {}
    for _, s in ipairs(G.Steps(g.id) or {}) do authored[#authored + 1] = s end
    table.sort(authored, function(a, b) return a.index < b.index end)
    r.guide = { id = g.id, name = g.name, type = g.type, source = g.source, zone = g.zone, faction = g.faction,
                minlevel = num(g.minlevel), maxlevel = num(g.maxlevel), next = g.next, loop = g.loop and true or nil,
                baked = g.baked and true or false, steps = #(P.steps or {}), authored = #authored,
                sum = G.RouteChecksum(authored), keySum = G.GuideSum and G.GuideSum(g.id) or nil, sumv = G.ROUTE_CHECKSUM_VERSION, parseErrors = g.parseErrors }
end
local function secStep(r)
    local P, G = NS.Progress, NS.Guide
    local s = P.current
    if not s then return end
    local pos
    for i, st in ipairs(P.steps or {}) do if st == s then pos = i break end end
    local coords
    if s.coords then
        coords = {}
        for i, c in ipairs(s.coords) do
            if i > 12 then break end
            coords[i] = { num(c.x * 100, 2), num(c.y * 100, 2) }
        end
    end
    r.step = { index = s.index, key = s.key, pos = pos, action = s.action, title = trunc(G.StepTitle and G.StepTitle(s) or s.title, 200),
               line = s.line, raw = (not s.access) and rawLine(P.guide, s.line) or nil, qid = qids(s), qo = s.qo,
               zone = s.zone, zoneName = s.zoneName, zoneInherited = s.zoneInherited or nil, coords = coords,
               locSource = s._locSource, access = s.access and true or nil, accessTitle = s.accessTitle,
               optional = s.optional or nil, route = s.route and true or false, item = s.item, minlevel = num(s.minlevel),
               note = trunc(s.note, 300), pre = s.pre and table.concat(s.pre, ",") or nil, coordFixed = s.coordFixed or nil,
               eraMapFixed = s.eraMapFixed or nil }
end
-- secs: travel from the step before (the first: from the player, the route's own cost).  Step-to-step costs are the
-- live planner's kept pairs (StepOrder.KeptCost); a pair it has not priced, or priced before a graph rebuild or a
-- speed change, is left out (nil) rather than searched: a search costs 20-50 ms of plain Lua on a big continent.
local function secUpcoming(r)
    local P, SO = NS.Progress, NS.StepOrder
    local list, prev = {}, nil
    for i, s in ipairs(P.Upcoming(BR.UPCOMING)) do
        local x, y = stepLoc(s)
        local secs
        if i == 1 then secs = r.route and r.route.secs
        elseif SO and SO.KeptCost then
            local ok, v = pcall(SO.KeptCost, prev, s)
            secs = ok and num(v, 1) or nil
        end
        list[i] = { index = s.index, key = s.key, action = s.action, title = trunc(s.title, 120), qid = qids(s), zone = s.zone,
                    x = x, y = y, locSource = s._locSource, secs = secs }
        prev = s
    end
    r.upcoming = list
    local order = {}
    for i, s in ipairs(P.order or {}) do if i > 40 then break end order[i] = s.index end
    r.order = table.concat(order, ",")
    -- the live planner's kept plan: the baseline its next refresh must beat (the replay restores it)
    if SO and type(SO.plan) == "table" and P.guide and SO.plan.guide == P.guide.id then
        local plan = {}
        for i, s in ipairs(SO.plan.steps or {}) do if i > 40 then break end plan[i] = s.index end
        r.plan = table.concat(plan, ",")
    end
end
local function secProgress(r)
    local P = NS.Progress
    if not (P.guide and P.steps) then return end
    -- marks are stored by step key (Core/Guide.lua); the report lists them as author indices of the guide it names
    -- (guide.sum / guide.keySum say which version), which keeps a long guide's lists short
    local done, skipped, reopened, closed = {}, {}, {}, {}
    local _, sk, ro = P.MarkSets()
    for _, s in ipairs(P.steps) do
        if s.key and sk[s.key] then skipped[#skipped + 1] = s.index closed[s] = true
        elseif P.IsDone(s) then done[#done + 1] = s.index closed[s] = true end
        if s.key and ro[s.key] then reopened[#reopened + 1] = s.index end
    end
    -- open: the steps the guide would show now (not done, and Conditions.StepApplies says yes).  The replay compares
    -- its own open set with this one, so a gate the report did not carry shows up as a difference, not as "order".
    local open = {}
    for _, s in ipairs(P.Pending(9999)) do open[#open + 1] = s.index end
    r.progress = { done = ranges(done), skipped = ranges(skipped), reopened = ranges(reopened), doneCount = #done,
                   skippedCount = #skipped, pending = #open, open = ranges(open), scope = NS.db.profile.scope }
    -- quest state for every quest the guide names, and for every quest that only gates a step (PRE, ACTIVE, AVAILABLE
    -- in Core/Conditions.lua): the replay rebuilds the quest log from it.  Steps still to do come first under the cap.
    local U = NS.Util
    local seen, ids = {}, {}
    local function add(q)
        q = tonumber(q)
        if q and q > 0 and not seen[q] and #ids < BR.QUEST_IDS_MAX then seen[q] = true ids[#ids + 1] = q end
    end
    for pass = 1, 2 do
        for _, s in ipairs(P.steps) do
            if (pass == 1) ~= (closed[s] == true) then
                for _, q in ipairs(s.qid or {}) do add(q) end
                for _, q in ipairs(s.pre or {}) do add(q) end
                if s.active then add(math.abs(s.active)) end
                add(s.available)
            end
        end
    end
    local st = { done = {}, log = {}, complete = {} }
    for _, q in ipairs(ids) do
        if U.IsQuestComplete(q) then st.done[#st.done + 1] = q
        elseif U.IsOnQuest(q) then
            local _, complete = U.QuestLogState(q)
            if complete then st.complete[#st.complete + 1] = q else st.log[#st.log + 1] = q end
        end
    end
    r.quests = { done = ranges(st.done), log = ranges(st.log), complete = ranges(st.complete), named = #ids }
    -- objective counts of the guide's quests in the log: { fulfilled, required, finished } per objective
    local objectives, nObj = {}, 0
    local inLog = {}
    for _, q in ipairs(st.log) do inLog[#inLog + 1] = q end
    for _, q in ipairs(st.complete) do inLog[#inLog + 1] = q end
    for _, q in ipairs(inLog) do
        if nObj >= 40 or not (C_QuestLog and C_QuestLog.GetQuestObjectives) then break end
        local ok, objs = pcall(C_QuestLog.GetQuestObjectives, q)
        if ok and type(objs) == "table" and #objs > 0 then
            local o = {}
            for i, ob in ipairs(objs) do
                if i > 8 then break end
                o[i] = { num(ob.numFulfilled) or 0, num(ob.numRequired) or 0, ob.finished and true or false }
            end
            objectives[tostring(q)] = o
            nObj = nObj + 1
        end
    end
    -- bag counts of the items the steps on screen use or collect, and the hearthstone
    local items = {}
    local function noteItem(id) if id and not items[tostring(id)] then items[tostring(id)] = num(U.ItemCount(id)) end end
    noteItem(NS.HEARTH_ITEM)
    for _, s in ipairs(P.Upcoming(BR.UPCOMING)) do
        noteItem(s.item)
        for _, l in ipairs(s.loot or {}) do noteItem(l.id) end
    end
    r.objectives, r.items = objectives, items
    -- profession skill as the client reads it, for steps gated on one (|P|, Conditions.ProfMatch) or finished by one
    -- (SKILL, Progress.SkillMet): { rank, max }, or false when the client could not tell
    local Prof = NS.Professions
    if Prof and Prof.Skill then
        local profs, n = {}, 0
        local function noteProf(name, tier)
            if type(name) ~= "string" or name == "" or n >= 24 then return end
            local key = tier and (name .. "#" .. tier) or name
            if profs[key] ~= nil then return end
            local rank, max = Prof.Skill(name, tier)
            profs[key] = rank and { num(rank) or 0, num(max) or 0 } or false
            n = n + 1
        end
        for _, s in ipairs(P.steps) do
            if s.prof and Prof.ParseSpec then noteProf((Prof.ParseSpec(s.prof))) end
            if type(s.skill) == "table" then noteProf(s.skill.name, s.skill.tier) end
        end
        if n > 0 then r.profs = profs end
    end
end
local function legOut(l)
    return { mode = l.mode, title = trunc(l.title, 120), from = trunc(l.from and l.from.name, 80), to = trunc(l.to and l.to.name, 80),
             fwx = l.from and num(l.from.wx, 1), fwy = l.from and num(l.from.wy, 1), finst = l.from and l.from.inst,
             twx = l.to and num(l.to.wx, 1), twy = l.to and num(l.to.wy, 1), tinst = l.to and l.to.inst,
             secs = num(l.cost, 1), yards = num(l.dist, 1), discover = l.discover or nil, road = l.road or nil,
             kind = (l.mode == "hearth" and l.data) and l.data.kind or nil }
end
local function secRoute(r)
    local R, TG = NS.Router, NS.TravelGraph
    if not (R and NS.Progress.current) then return end
    -- the path the arrow is following now (Router's cache: at most 20 s old and 40 yd away, else it searches again)
    local path, target = R.CurrentPath()
    local route = { found = path ~= nil }
    if target then route.target = { wx = num(target.wx, 1), wy = num(target.wy, 1), inst = target.inst } end
    if path then
        route.secs = num(path.cost, 1)
        route.desc = trunc(TG.Describe(path), 400)
        route.legs = {}
        for i, l in ipairs(path.legs or {}) do if i > 12 then break end route.legs[i] = legOut(l) end
    end
    r.route = route
    local rec = R.Recommendation()
    if rec then
        r.arrow = { mode = rec.mode, text = trunc(rec.text, 160), why = trunc(rec.why, 200), locSource = rec.locSource,
                    eta = num(rec.eta, 1), dist = num(rec.dist, 1), item = rec.item, spell = rec.spell,
                    borrowed = rec.borrowedFrom and rec.borrowedFrom.index or nil }
    end
    local SO = NS.StepOrder
    if SO and type(SO.last) == "table" then
        local info = {}
        for k, v in pairs(SO.last) do
            local t = type(v)
            if (t == "number" or t == "boolean" or t == "string") and type(k) == "string" then info[k] = t == "number" and num(v, 2) or v end
        end
        r.stepOrder = info
    end
end
local function secTravel(r)
    local TG, U = NS.TravelGraph, NS.Util
    local known = {}
    for id in pairs(NS.db.char.knownTaxi or {}) do if type(id) == "number" then known[#known + 1] = id end end
    local hx, hy, hinst, hname = TG.HearthWorld()
    local b = NS.db.char.bind
    local ready, cd = U.HearthReady()
    r.travel = { taxiPolicy = TG.TaxiPolicy(), knownTaxi = ranges(known), knownTaxiCount = #known,
                 graphNodes = TG.nodes and #TG.nodes or 0, roadNodes = TG.roadCount or 0, built = TG.built and true or false,
                 bindName = GetBindLocation and GetBindLocation() or nil,
                 hearth = hx and { wx = num(hx, 1), wy = num(hy, 1), inst = hinst, name = hname,
                                   source = (b and b.wx) and "learned" or "seed" } or nil,
                 hearthReady = ready and true or false, hearthCooldown = num(cd, 0),
                 hasHearthstone = U.HasItem(NS.HEARTH_ITEM) and true or false }
    -- portal/boat spots learned by taking them (TravelGraph.LearnTransit) move transit nodes: keep them for the replay
    local fix = NS.db.global.transitFix
    if type(fix) == "table" then
        local out, n = {}, 0
        for title, f in pairs(fix) do
            n = n + 1
            if n <= 60 and type(f) == "table" and type(f.from) == "table" and type(f.to) == "table" then
                out[title] = { from = { num(f.from[1], 1), num(f.from[2], 1), f.from[3] }, to = { num(f.to[1], 1), num(f.to[2], 1), f.to[3] } }
            end
        end
        r.travel.transitFix = out
    end
    local s = NS.Progress.current
    local ent = NS.db.global.instanceEntrances
    if s and s.zone and type(ent) == "table" and type(ent["map:" .. s.zone]) == "table" then
        local e = ent["map:" .. s.zone]
        r.travel.entrance = { key = "map:" .. s.zone, map = e.map, x = num(e.x, 4), y = num(e.y, 4), name = e.name }
    end
end
local function secOptions(r)
    local p = NS.db.profile
    local routing = {}
    for k, v in pairs(p.routing or {}) do
        local t = type(v)
        if t == "number" or t == "boolean" or t == "string" then routing[k] = v end
    end
    r.options = { routing = routing, scope = p.scope, accountWide = p.accountWide and true or false,
                  accountQuests = p.accountQuests and true or false,
                  debug = p.debug and true or false, arrow = p.arrow and p.arrow.enabled and true or false,
                  beacon = p.beacon and p.beacon.enabled and true or false,
                  -- the text size and the step window's scale, for reports about text that runs over or is cut
                  textSize = tonumber(p.textSize), frameScale = p.frame and tonumber(p.frame.scale) and num(p.frame.scale, 2) or nil,
                  minimapButton = p.minimapButton ~= false,
                  circuitizeGold = p.farm and p.farm.circuitizeGold and true or false,
                  guideShown = NS.GuideFrame and NS.GuideFrame.frame and NS.GuideFrame.frame:IsShown() and true or false }
    -- auto accept / turn-in (Core/QuestAuto.lua): its settings and the last decisions ("why was this not accepted?")
    if NS.QuestAuto and NS.QuestAuto.Snapshot then r.options.questAuto = NS.QuestAuto.Snapshot() end
end
local function secLog(r)
    local lines = NS.Log and NS.Log.lines or {}
    local out = {}
    for i = math.max(1, #lines - BR.LOG_LINES + 1), #lines do out[#out + 1] = trunc(lines[i], 300) end
    r.log = out
    local e = BR.lastError
    if not e and CompletionRouteDB and type(CompletionRouteDB.lastError) == "table" then e = CompletionRouteDB.lastError end
    local g = grabberError()
    if g and not e then e = g end
    if e then
        r.lastError = { msg = e.msg, stack = e.stack, at = e.at, version = e.version, count = e.count, source = e.source or "hook",
                        ageSeconds = e.epoch and num(now() - e.epoch) or nil }
    end
    local le = NS.db.char.luaErrors
    r.luaErrorCount = type(le) == "table" and #le or 0
end

local SECTIONS = {
    { "client", secClient }, { "char", secChar }, { "player", secPlayer }, { "guide", secGuide }, { "step", secStep },
    { "route", secRoute }, { "upcoming", secUpcoming }, { "progress", secProgress }, { "travel", secTravel },
    { "options", secOptions }, { "log", secLog },
}

-- Keep one report under MAX_REPORT_BYTES: cut the bulkiest free text and lists first.
local function cutList(s, n)
    if type(s) ~= "string" or #s <= n then return s end
    local cut = s:sub(1, n):match("^(.*),") or s:sub(1, n)
    return cut .. ",..."
end
function BR.Trim(r)
    if BR.Size(r) <= BR.MAX_REPORT_BYTES then return r end
    r.trimmed = true
    local steps = {
        function() if r.log and #r.log > 10 then local keep = {} for i = #r.log - 9, #r.log do keep[#keep + 1] = r.log[i] end r.log = keep end end,
        function() if r.lastError then r.lastError.stack = trunc(r.lastError.stack, 400) end end,
        function() if r.quests then for k, v in pairs(r.quests) do if type(v) == "string" then r.quests[k] = cutList(v, 600) end end end end,
        function() if r.travel then r.travel.knownTaxi = cutList(r.travel.knownTaxi, 400) r.travel.transitFix = nil end end,
        function() if r.progress then for _, k in ipairs({ "done", "skipped", "reopened", "open" }) do r.progress[k] = cutList(r.progress[k], 600) end end end,
        function() r.note = trunc(r.note, 200) if r.step then r.step.raw = trunc(r.step.raw, 200) r.step.note = nil end end,
        function() for _, u in ipairs(r.upcoming or {}) do u.title = trunc(u.title, 40) end end,
        function() r.log = nil r.stepOrder = nil r.objectives = nil end,
    }
    for _, fn in ipairs(steps) do
        pcall(fn)
        if BR.Size(r) <= BR.MAX_REPORT_BYTES then break end
    end
    return r
end

local function scrubAll(v, names, depth)
    if depth > 8 then return v end
    if type(v) == "string" then return scrub(v, names) end
    if type(v) == "table" then for k, x in pairs(v) do v[k] = scrubAll(x, names, depth + 1) end end
    return v
end

function BR.NewId()
    local base = ("%s-%s-%04x"):format(NS.dataFlavor or NS.flavor or "wow", stamp("%Y%m%d-%H%M%S"), math.random(0, 65535))
    local id, n = base, 1
    for _, r in ipairs(BR.Store()) do
        if r.id == id then n = n + 1 id = base .. "-" .. n end
    end
    return id
end

function BR.Store()
    if not CompletionRouteDB then return {} end
    if type(CompletionRouteDB.bugReports) ~= "table" then CompletionRouteDB.bugReports = {} end
    return CompletionRouteDB.bugReports
end

-- Build a report (does not save it).  Returns the report table.
function BR.Snapshot(note)
    local t0 = debugprofilestop and debugprofilestop()
    local r = { schema = BR.SCHEMA, at = stamp("%Y-%m-%d %H:%M:%S"), epoch = now(), errors = {} }
    r.id = BR.NewId()
    if note and note ~= "" then r.note = trunc(note, BR.NOTE_MAX) end
    local ms = {}
    for _, sec in ipairs(SECTIONS) do
        local s0 = t0 and debugprofilestop()
        local ok, err = pcall(sec[2], r)
        if not ok then r.errors[sec[1]] = trunc(err, 300) end
        if s0 then ms[sec[1]] = num(debugprofilestop() - s0, 1) end
    end
    r.sectionMs = ms   -- where the capture spent its time (the client runs plain Lua: this is the cost of a click)
    if not next(r.errors) then r.errors = nil end
    -- free text only: titles, zone names and map names are game data and stay as they are
    local names = scrubList()
    r.note = scrub(r.note, names, true)
    if r.log then for i, l in ipairs(r.log) do r.log[i] = scrub(l, names) end end
    if r.lastError then r.lastError.msg = scrub(r.lastError.msg, names) r.lastError.stack = scrub(r.lastError.stack, names) end
    if r.errors then scrubAll(r.errors, names, 0) end
    if r.player then r.player.subzone = scrub(r.player.subzone, names) end
    if t0 then r.captureMs = num(debugprofilestop() - t0, 1) end
    return BR.Trim(r)
end

-- Insert newest first, then drop the oldest until the store fits both caps.
function BR.Save(r)
    local store = BR.Store()
    table.insert(store, 1, r)
    while #store > BR.MAX_REPORTS do table.remove(store) end
    local total = 0
    for i, x in ipairs(store) do
        total = total + BR.Size(x)
        if total > BR.MAX_BYTES and i > 1 then
            for j = #store, i, -1 do table.remove(store, j) end
            break
        end
    end
    return #store
end

function BR.Capture(note)
    local r = BR.Snapshot(note)
    local n = BR.Save(r)
    NS:Print(("Bug report %s saved (%d stored). It is written to disk at /reload or logout."):format(r.id, n))
    if r.errors then
        local parts = {}
        for k in pairs(r.errors) do parts[#parts + 1] = k end
        table.sort(parts)
        NS:Print("  (parts that could not be read: " .. table.concat(parts, ", ") .. ")")
    end
    return r
end

function BR.Find(id)
    for _, r in ipairs(BR.Store()) do if r.id == id then return r end end
    return nil
end
function BR.SetNote(id, note)
    local r = BR.Find(id)
    if not r then return false end
    note = note and note:match("^%s*(.-)%s*$") or ""
    if note == "" then return false end
    r.note = scrub(trunc(note, BR.NOTE_MAX), scrubList(), true)
    return true
end

-- /cr bug [note]  |  /cr bug list
function BR.Command(rest)
    rest = rest or ""
    if rest:lower() == "list" then
        local store = BR.Store()
        if #store == 0 then NS:Print("No bug reports stored. /cr bug [what went wrong]") return end
        NS:Print(("%d bug report(s), newest first:"):format(#store))
        for i, r in ipairs(store) do
            if i > 10 then break end
            NS:Print(("  %s  %s step %s%s"):format(r.id, r.guide and (r.guide.name or r.guide.id) or "no route",
                tostring(r.step and r.step.index or "-"), r.note and ("  \"" .. trunc(r.note, 50) .. "\"") or ""))
        end
        return
    end
    BR.Capture(rest)
end

-- ---------------------------------------------------------------------------
-- The guide window's Report button: snapshot first (the moment of the click is what matters), then ask for a note.
-- ---------------------------------------------------------------------------
local function noteBox()
    if BR.box then return BR.box end
    local f = CreateFrame("Frame", "CompletionRouteBugNote", UIParent, "BackdropTemplate")
    f:SetSize(380, 100); f:SetPoint("CENTER", 0, 160)
    f:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    f:SetBackdropColor(0.03, 0.03, 0.05, 0.95)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
    -- texts and button labels in the addon's own fonts, so the Options "Text size" slider covers them (Core/Util.lua
    -- U.Font, UI/GuideFrame.lua GF.ButtonFonts)
    local GF = NS.GuideFrame
    local t = f:CreateFontString(nil, "OVERLAY", NS.Util.Font("Title"))
    -- an explicit width, so its height can be read before the client has laid it out (see UI/GuideFrame.lua FitHeight)
    t:SetPoint("TOPLEFT", 12, -10); t:SetWidth(380 - 24); t:SetJustifyH("LEFT"); t:SetWordWrap(true)
    local eb = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    -- under the title, however many lines the title takes at the chosen text size
    eb:SetSize(340, 20); eb:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 8, -8); eb:SetAutoFocus(false); eb:SetMaxLetters(BR.NOTE_MAX)
    local function commit()
        local txt = eb:GetText()
        if f.id and BR.SetNote(f.id, txt) then NS:Print("Note added to " .. f.id .. ".") end
        eb:ClearFocus() f:Hide()
    end
    eb:SetScript("OnEnterPressed", commit)
    eb:SetScript("OnEscapePressed", function() eb:ClearFocus() f:Hide() end)
    local save = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    save:SetSize(90, 20); save:SetPoint("BOTTOMRIGHT", -12, 10); save:SetText("Save note")
    save:SetScript("OnClick", commit)
    local skip = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    skip:SetSize(70, 20); skip:SetPoint("RIGHT", save, "LEFT", -4, 0); skip:SetText("No note")
    skip:SetScript("OnClick", function() eb:ClearFocus() f:Hide() end)
    save.minW, skip.minW = 90, 70
    if GF and GF.ButtonFonts then GF.ButtonFonts(save) GF.ButtonFonts(skip) end
    tinsert(UISpecialFrames, "CompletionRouteBugNote")
    f.title, f.eb, f.save, f.skip = t, eb, save, skip
    f:Hide()
    BR.box = f
    return f
end
function BR.FromButton()
    local r = BR.Capture("")
    local ok, f = pcall(noteBox)
    if not ok or not f then return r end
    f.id = r.id
    f.title:SetText(("Saved %s. What went wrong? (optional)"):format(r.id))
    -- the button labels follow the text size: as wide as they need
    local GF = NS.GuideFrame
    if GF and GF.FitButton then GF.FitButton(f.save) GF.FitButton(f.skip) end
    -- title, edit box, buttons: as tall as the title's lines need
    local th = f.title.GetStringHeight and f.title:GetStringHeight()
    th = (type(th) == "number" and th > 0) and th or 14
    f:SetHeight(math.max(100, math.ceil(10 + th + 8 + 20 + 8 + 20 + 10)))
    f.eb:SetText("")
    f:Show()
    f.eb:SetFocus()
    return r
end
