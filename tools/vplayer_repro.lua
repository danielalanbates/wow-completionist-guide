-- CompletionRoute :: tools/vplayer_repro.lua
-- Replay a beta bug report (Core/BugReport.lua) in the virtual player's fake world, or make one there.
-- Copyright (c) 2026 Daniel Bates / Bates LLC.  All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- Loaded by tools/vplayer.lua; not run on its own.
--   luajit tools/vplayer.lua --repro <report id | latest | report.json> [--db docs/verification.sqlite] [--check] [--show]
--   luajit tools/vplayer.lua <flavor> --capture [guide id | auto] [--capture-steps N] [--capture-from "Zone"] [--capture-out report.json]
--                                        [--capture-done 6623,6624]   (quests already done in the fake world before playing)
--
-- --repro loads the report's flavor and guide, puts the virtual character where the report says (map/x/y, level,
-- faction, class, race, quest log, done/skipped steps, flight paths known, hearth, speed, options), and prints the
-- route and the next steps the addon gives offline next to what the client recorded.  --check exits 1 when the
-- current step, the set of open steps or the route differ.  --show only prints the report (no world is loaded).
-- --capture plays N steps of a guide in the fake world, moves to --capture-from (auto: the faction capital, so the route
-- has several legs) and saves a report with the real Core/BugReport.lua: the
-- round trip (capture, then --repro --check) is the self-test in tools/test_bug_report.lua.
-- A report id is looked up in the beta_reports table that tools/ingest_beta_reports.py fills (sqlite3 CLI, read-only).
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or "tools")
local J = dofile(here .. "/json.lua")
local RP = {}
local FLAVORS = { era = true, tbc = true, mop = true, retail = true, forever = true }

local function out(fmt, ...) io.write((select("#", ...) > 0 and fmt:format(...) or fmt) .. "\n") end
local function shq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function fmtTime(s)
    if not s then return "?" end
    s = math.floor(s + 0.5)
    if s < 60 then return s .. "s" end
    local m = math.floor(s / 60)
    if m < 60 then return ("%dm %ds"):format(m, s - m * 60) end
    return ("%dh %dm"):format(math.floor(m / 60), m % 60)
end
-- "1..3,7,-2" -> { 1, 2, 3, 7, -2 }
function RP.Expand(s)
    local list = {}
    if type(s) ~= "string" then return list end
    for part in s:gmatch("[^,]+") do
        local a, b = part:match("^(%-?%d+)%.%.(%-?%d+)$")
        if a then for i = tonumber(a), tonumber(b) do list[#list + 1] = i end
        elseif tonumber(part) then list[#list + 1] = tonumber(part) end
    end
    return list
end
local function set(s) local t = {} for _, i in ipairs(RP.Expand(s)) do t[i] = true end return t end

function RP.ParseArgs(argv)
    local o = {}
    for i = 1, #argv do
        local a, nxt = argv[i], argv[i + 1]
        if a == "--repro" then o.spec = nxt
        elseif a == "--capture" then o.capture = (nxt and not nxt:match("^%-%-")) and nxt or "auto"
        elseif a == "--capture-steps" then o.steps = tonumber(nxt)
        elseif a == "--capture-out" then o.out = nxt
        elseif a == "--capture-from" then o.from = nxt
        elseif a == "--capture-done" then o.done = RP.Expand(nxt)
        elseif a == "--note" then o.note = nxt
        elseif a == "--db" then o.db = nxt
        elseif a == "--check" then o.check = true
        elseif a == "--show" then o.show = true end
    end
    return o
end

-- ---------------------------------------------------------------------------
-- Loading a report
-- ---------------------------------------------------------------------------
local function pick(v)
    if type(v) == "table" and v.bugReports then v = v.bugReports end   -- tools/sv_to_json.lua output
    if type(v) == "table" and not v.id and type(v[1]) == "table" then v = v[1] end   -- a list: newest first
    return v
end
function RP.Load(spec, db)
    if not spec then error("--repro needs a report id, 'latest' or a .json file", 0) end
    local text
    local f = io.open(spec, "r")
    if f then
        text = f:read("*a") f:close()
    else
        if not (spec == "latest" or spec:match("^[%w][%w%-_]*$")) then error("--repro: not a file and not a report id: " .. spec, 0) end
        db = db or "docs/verification.sqlite"
        local fh = io.open(db, "r")
        if not fh then error("--repro: no database at " .. db .. " (run tools/ingest_beta_reports.py, or pass --db)", 0) end
        fh:close()
        local q = spec == "latest" and "SELECT json FROM beta_reports ORDER BY epoch DESC, id DESC LIMIT 1;"
            or ("SELECT json FROM beta_reports WHERE id = '%s';"):format(spec)
        local p = assert(io.popen(("sqlite3 -readonly -batch -noheader %s %s 2>&1"):format(shq(db), shq(q))))
        text = p:read("*a") p:close()
        if not text:find("%S") then error("--repro: no report " .. spec .. " in " .. db, 0) end
        if not text:match("^%s*[%[{]") then error("--repro: sqlite3 said: " .. text, 0) end
    end
    local ok, v = pcall(J.decode, text)
    if not ok then error("--repro: " .. spec .. " is not a JSON report (" .. tostring(v) .. ")", 0) end
    v = pick(v)
    if type(v) ~= "table" or not v.id or type(v.client) ~= "table" then error("--repro: " .. spec .. " does not hold a bug report", 0) end
    return v
end

function RP.Flavor(r)
    local c = r.client or {}
    local fl = c.dataFlavor or (c.isForever and "forever") or c.flavor
    if not FLAVORS[fl] then error(("--repro: report %s is from flavor %s, which vplayer does not model"):format(r.id, tostring(fl)), 0) end
    return fl
end

-- flavor, order mode, live window and spine flag for vplayer's own loader, from the report
function RP.Settings(r, withSpine)
    local fl = RP.Flavor(r)
    local routing = (r.options or {}).routing or {}
    local order = "author"
    if r.guide and r.guide.baked and routing.baked ~= false then
        local f = io.open("CompletionRoute/Data/RouteOrder_" .. fl .. ".lua", "r")
        if f then f:close() order = "baked"
        else out("note: the client used a baked order, but CompletionRoute/Data/RouteOrder_%s.lua is missing; replaying author order", fl) end
    end
    local live = routing.reorder ~= false
    local spine = withSpine or (r.guide and type(r.guide.id) == "string" and r.guide.id:match("^spine:") ~= nil) or false
    return fl, order, live, spine
end

-- ---------------------------------------------------------------------------
-- Printing a report as recorded
-- ---------------------------------------------------------------------------
local function legLine(l)
    return ("%-7s %s -> %s  %s  %s%s"):format(tostring(l.mode), tostring(l.from or "?"), tostring(l.to or "?"),
        l.secs and (fmtTime(l.secs)) or "?", l.yards and (("%.0f yd"):format(l.yards)) or "",
        l.discover and "  (new flight path)" or "")
end
function RP.Show(r)
    local c, ch, g, s, p = r.client or {}, r.char or {}, r.guide, r.step, r.player or {}
    out("REPORT %s  (%s, schema %s)", r.id, tostring(r.at), tostring(r.schema))
    out("  client %s%s %s (%s) interface %s, addon %s, %s", tostring(c.flavor), c.isForever and " [forever]" or "",
        tostring(c.build), tostring(c.buildNum), tostring(c.interface), tostring((r.addon or {}).version), tostring(c.locale))
    out("  character %s %s level %s %s, speed %s yd/s, can fly: %s%s", tostring(ch.race), tostring(ch.class),
        tostring(ch.levelFrac or ch.level), tostring(ch.faction), tostring(ch.speed), ch.canFly and "yes" or "no",
        ch.dead and ", DEAD" or "")
    if r.note then out("  note: %q", r.note) end
    if r.errors then
        local parts = {} for k, v in pairs(r.errors) do parts[#parts + 1] = k .. ": " .. tostring(v) end
        table.sort(parts)
        out("  sections the client could not read: %s", table.concat(parts, "; "))
    end
    if r.trimmed then out("  (report was trimmed to fit the size limit)") end
    out("  at %s (%s) %.2f, %.2f  world %s, %s inst %s%s", tostring(p.mapName), tostring(p.map), p.x or -1, p.y or -1,
        tostring(p.wx), tostring(p.wy), tostring(p.inst), p.inInstance and (" in instance (" .. tostring(p.instanceType) .. ")") or "")
    if not g then out("  no guide was loaded") else
        out("  guide %s %q (%s, %s steps, baked order: %s, checksum %s)", tostring(g.id), tostring(g.name), tostring(g.type),
            tostring(g.steps), g.baked and "yes" or "no", tostring(g.sum))
    end
    if s then
        out("  step %s [%s] %s%s", tostring(s.index), tostring(s.action), tostring(s.title), s.qid and ("  quest " .. s.qid) or "")
        if s.raw then out("    line %s: %s", tostring(s.line), s.raw) end
        out("    location from: %s%s", tostring(s.locSource), s.coords and ("  (" .. #s.coords .. " point(s), first "
            .. tostring(s.coords[1][1]) .. ", " .. tostring(s.coords[1][2]) .. " on map " .. tostring(s.zone) .. ")") or "")
    elseif g then out("  no current step") end
    local rt = r.route
    if rt then
        out("  route (client): %s", rt.found and tostring(rt.desc) or "no route")
        for i, l in ipairs(rt.legs or {}) do out("    %d. %s", i, legLine(l)) end
    end
    local a = r.arrow
    if a then out("  arrow (client): %s %q%s%s", tostring(a.mode), tostring(a.text), a.eta and ("  eta " .. fmtTime(a.eta)) or "",
        a.why and ("  why: " .. a.why) or "") end
    if r.upcoming and #r.upcoming > 0 then
        out("  upcoming (client; travel from the step before, the first from the player; ? = not priced by the planner yet):")
        for i, u in ipairs(r.upcoming) do
            out("    %d. %s [%s] %s  ~%s", i, tostring(u.index), tostring(u.action), tostring(u.title), fmtTime(u.secs))
        end
    end
    local t = r.travel
    if t then out("  travel: taxi policy %s, %s flight paths known, hearth %s (%s, %s)%s", tostring(t.taxiPolicy), tostring(t.knownTaxiCount),
        tostring(t.hearth and t.hearth.name or t.bindName), t.hearth and t.hearth.source or "unknown",
        t.hearthReady and "ready" or ("cooldown " .. fmtTime(t.hearthCooldown)), t.hasHearthstone and "" or ", no hearthstone") end
    local e = r.lastError
    if e then
        out("  last addon error (%s, x%s, %s): %s", tostring(e.source), tostring(e.count),
            e.ageSeconds and (fmtTime(e.ageSeconds) .. " before the report") or tostring(e.at), tostring(e.msg))
        if e.stack and e.stack ~= "" then for l in (e.stack .. "\n"):gmatch("([^\n]*)\n") do if l ~= "" then out("      %s", l) end end end
    end
    if r.log and #r.log > 0 then
        out("  log (last %d lines):", #r.log)
        for _, l in ipairs(r.log) do out("    %s", l) end
    end
end

-- ---------------------------------------------------------------------------
-- Replaying
-- ---------------------------------------------------------------------------
-- Profession skill exactly as the client read it (|P| gates and SKILL steps); a skill the client could not read stays
-- unknown (nil), as it was there.  Recipes count as not known: a known one had already finished its step (done).
function RP.RestoreProfs(r, NS, load)
    if type(r.profs) ~= "table" or not next(r.profs) then return false end
    if not NS.Professions and load then pcall(load, "Core/Professions.lua") end
    local Prof = NS.Professions
    if not Prof then return false end
    local profs = r.profs
    Prof.Skill = function(name, tier)
        local e = profs[tier and (tostring(name) .. "#" .. tostring(tier)) or tostring(name)]
        if e == nil and tier then e = profs[tostring(name)] end
        if type(e) == "table" then return e[1] or 0, e[2] or 0 end
        return nil
    end
    Prof.KnowsSpell = function() return false end
    return true
end

local function tryLoadGuide(ctx, gid, fl)
    local G = ctx.NS.Guide
    if G.registry[gid] then return true end
    -- vplayer loads quest guides only; gold, profession and spine guides live in their own files
    for _, f in ipairs({ "Core/Professions.lua", "Core/Archaeology.lua", "Guides/Imported_Gold_" .. fl .. ".lua",
                         "Guides/Imported_Professions_" .. fl .. ".lua", "Guides/Imported_Spine_" .. fl .. ".lua" }) do
        local fh = io.open("CompletionRoute/" .. f, "r")
        if fh then fh:close() pcall(ctx.load, f) end
        if G.registry[gid] then return true end
    end
    return G.registry[gid] ~= nil
end

function RP.Restore(r, ctx)
    local NS, W = ctx.NS, ctx.W
    local U, TG, P, R, G = NS.Util, NS.TravelGraph, NS.Progress, NS.Router, NS.Guide
    local ch, pl, tr = r.char or {}, r.player or {}, r.travel or {}
    local notes = {}
    -- character
    local faction = ch.faction == "Horde" and "Horde" or "Alliance"
    ctx.setChar(faction, ch.class or "WARRIOR", ch.race or (faction == "Horde" and "Orc" or "Human"))
    NS.player.faction, NS.player.class, NS.player.race = faction, ch.class or "WARRIOR", ch.race or "Human"
    local lvl = tonumber(ch.levelFrac) or tonumber(ch.level) or 1
    ctx.wipeWorld(math.floor(lvl))
    W.xp = math.floor((lvl - math.floor(lvl)) * W.xpmax + 0.5)
    PLAYER_DEAD = ch.dead and true or false
    -- speed and flying exactly as the client measured them (they set every walking cost)
    if ch.speed then U.TravelSpeed = function() return ch.speed end end
    U.CanFly = function() return ch.canFly and true or false end
    IsInInstance = function() return pl.inInstance and true or false, pl.instanceType end
    -- options
    local routing = (r.options or {}).routing or {}
    for k, v in pairs(routing) do if k ~= "liveBudgetMs" then NS.db.profile.routing[k] = v end end
    NS.db.profile.routing.baked = (orderMode == "baked")
    NS.db.profile.routing.liveBudgetMs = 1e9   -- the client had 3 ms per call; offline every repair finishes
    if r.options and r.options.scope then NS.db.profile.scope = r.options.scope end
    -- quest log, objectives, bags
    local q = r.quests or {}
    for _, id in ipairs(RP.Expand(q.done)) do W.quests[id] = "done" end
    for _, id in ipairs(RP.Expand(q.log)) do W.quests[id] = "log" end
    for _, id in ipairs(RP.Expand(q.complete)) do W.quests[id] = "complete" end
    for qid, objs in pairs(r.objectives or {}) do
        local list = {}
        for i, o in ipairs(objs) do list[i] = { numFulfilled = o[1] or 0, numRequired = o[2] or 0, finished = o[3] and true or false, text = "obj" } end
        W.objectives[tonumber(qid)] = list
    end
    for id, n in pairs(r.items or {}) do if tonumber(id) and (tonumber(n) or 0) > 0 then W.bags[tonumber(id)] = tonumber(n) end end
    if RP.RestoreProfs(r, NS, ctx.load) then notes.profs = true end
    -- hearth
    local cd = tonumber(tr.hearthCooldown) or 0
    U.HearthReady = function()
        if (W.bags[NS.HEARTH_ITEM] or 0) > 0 then return cd <= 0, math.max(0, cd), "item", NS.HEARTH_ITEM end
        return false, math.huge
    end
    W.bind = tr.bindName or W.bind
    if tr.hearth and tr.hearth.source == "learned" then
        NS.db.char.bind = { wx = tr.hearth.wx, wy = tr.hearth.wy, inst = tr.hearth.inst, name = tr.hearth.name }
    else NS.db.char.bind = nil end
    -- flight paths and learned spots
    NS.db.char.knownTaxi = set(tr.knownTaxi)
    NS.db.global.knownTaxi = {}
    NS.db.global.transitFix = {}
    for title, f in pairs(tr.transitFix or {}) do NS.db.global.transitFix[title] = { from = f.from, to = f.to } end
    NS.db.global.instanceEntrances = {}
    if tr.entrance and tr.entrance.key then
        local e = tr.entrance
        NS.db.global.instanceEntrances[e.key] = { map = e.map, x = e.x, y = e.y, name = e.name }
    end
    -- position: the offline map transform is used when it knows the map (and its distance from the client's world
    -- position is reported, a check of the map data); otherwise the client's world position is used as it is
    local placed = false
    if pl.map and pl.x and MAPS[pl.map] and MAPS[pl.map][3] then
        placed = ctx.place(pl.map, pl.x / 100, pl.y / 100)
    end
    if placed then
        if pl.wx and PLAYER.inst == pl.inst then
            notes.posDelta = math.sqrt((PLAYER.wx - pl.wx) ^ 2 + (PLAYER.wy - pl.wy) ^ 2)
        elseif pl.wx then notes.posDelta = "different continent" end
    elseif pl.wx then
        PLAYER.map, PLAYER.x, PLAYER.y = pl.map, (pl.x or 50) / 100, (pl.y or 50) / 100
        PLAYER.wx, PLAYER.wy, PLAYER.inst = pl.wx, pl.wy, pl.inst
        notes.posDelta = "map " .. tostring(pl.map) .. " unknown offline: client world position used"
    else
        notes.posDelta = "no position in the report"
    end
    -- progress
    local gid = r.guide and r.guide.id
    if gid then
        local pr = r.progress or {}
        local done, skipped, reopened = set(pr.done), set(pr.skipped), set(pr.reopened)
        NS.db.char.done, NS.db.char.skipped, NS.db.char.reopened = { [gid] = done }, { [gid] = skipped }, { [gid] = reopened }
        NS.db.char.laps, NS.db.char.parked, NS.db.char.parkReturn, NS.db.char.guide = {}, {}, nil, nil
        local A = NS.Account
        if A and A.me then A.me.done, A.me.skipped = { [gid] = done }, { [gid] = skipped } end
    end
    TG.built = false
    TG.Build()
    if TG.PathCacheWipe then TG.PathCacheWipe() end
    R.Invalidate()
    if NS.StepOrder and NS.StepOrder.Reset then NS.StepOrder.Reset() end
    return notes
end

local function legsOf(path)
    local list = {}
    for i, l in ipairs(path and path.legs or {}) do
        list[i] = { mode = l.mode, from = l.from and l.from.name, to = l.to and l.to.name, secs = l.cost, yards = l.dist, discover = l.discover }
    end
    return list
end
local function modes(legs) local t = {} for i, l in ipairs(legs or {}) do t[i] = tostring(l.mode) end return table.concat(t, ",") end

function RP.Run(r, ctx, opts)
    local NS = ctx.NS
    local P, R, G, TG, U = NS.Progress, NS.Router, NS.Guide, NS.TravelGraph, NS.Util
    RP.Show(r)
    out("")
    out("REPLAY (offline: %s world, %s order, live window %s)", ctx.flavor, tostring(orderMode), liveWindow and "on" or "off")
    local gid = r.guide and r.guide.id
    if not gid then out("  nothing to replay: no guide was loaded in the client") return 0 end
    if not tryLoadGuide(ctx, gid, ctx.flavor) then
        out("  guide %s is not in the offline data for %s (a guide built at runtime, or data that changed since the report)", gid, ctx.flavor)
        local name, hits = r.guide.name and r.guide.name:lower(), 0
        for _, id in ipairs(G.list) do
            local g = G.registry[id]
            if name and (g.name or ""):lower() == name and hits < 5 then hits = hits + 1 out("    same name: %s", id) end
        end
        return 2
    end
    local g = G.registry[gid]
    g.steps = nil   -- parse now, after the order mode is set
    local notes = RP.Restore(r, ctx)
    -- the guide's text as the replay sees it, against the checksum the client computed
    local authored = {}
    for _, s in ipairs(G.Steps(gid) or {}) do authored[#authored + 1] = s end
    table.sort(authored, function(a, b) return a.index < b.index end)
    local sum = G.RouteChecksum(authored)
    -- a report from a build with another checksum version (none recorded = version 1, before 2026-11-10) can only be
    -- compared by its step count
    local sumv, mySumv = r.guide.sumv or 1, G.ROUTE_CHECKSUM_VERSION or 1
    local sameGuide
    if sumv == mySumv then
        sameGuide = (sum == r.guide.sum and #authored == r.guide.authored)
        out("  guide text: %s", sameGuide and ("same as the client (%d steps, checksum %s)"):format(#authored, tostring(sum))
            or ("|DIFFERS| offline %d steps checksum %s, client %s steps checksum %s: step indices may not line up"):format(
                #authored, tostring(sum), tostring(r.guide.authored), tostring(r.guide.sum)))
    else
        sameGuide = (#authored == r.guide.authored)
        out("  guide text: %s", sameGuide and ("%d steps as in the client (its checksum is version %d, this build's %d: not compared)"):format(
            #authored, sumv, mySumv) or ("|DIFFERS| offline %d steps, client %s steps (checksum version %d vs %d): step indices may not line up"):format(
            #authored, tostring(r.guide.authored), sumv, mySumv))
    end
    if (g.baked and true or false) ~= (r.guide.baked and true or false) then
        out("  baked order: client %s, offline %s", r.guide.baked and "yes" or "no", g.baked and "yes" or "no")
    end
    out("  position: %s", type(notes.posDelta) == "number" and ("offline map puts the player %.1f yd from the client's world position"):format(notes.posDelta)
        or tostring(notes.posDelta))
    if notes.profs then out("  profession skill: as the client read it (%d skill(s) in the report)", (function() local n = 0 for _ in pairs(r.profs) do n = n + 1 end return n end)()) end
    if not P.Load(gid) then out("  P.Load(%s) failed", gid) return 2 end
    -- the live planner's kept plan from the client is the baseline of its next refresh: restore it and refresh once
    if r.plan and r.plan ~= "" and NS.StepOrder then
        local byIndex, list = {}, {}
        for _, s in ipairs(P.steps or {}) do byIndex[s.index] = s end
        for _, i in ipairs(RP.Expand(r.plan)) do if byIndex[i] then list[#list + 1] = byIndex[i] end end
        if #list > 0 then NS.StepOrder.plan = { guide = gid, steps = list } P.Refresh() end
    end
    -- the client's own step: compare by index
    local cur = P.current
    local want = r.step and r.step.index
    local diffs = {}
    if cur then
        out("  current step: %s [%s] %s%s", tostring(cur.index), cur.action, tostring(G.StepTitle and G.StepTitle(cur) or cur.title),
            (want == cur.index) and "  (same as the client)" or ("  |DIFFERS| client: " .. tostring(want)))
    else
        out("  current step: none%s", want and ("  |DIFFERS| client: " .. tostring(want)) or "  (same as the client)")
    end
    if (cur and cur.index) ~= want then diffs[#diffs + 1] = "step" end
    -- the steps open now (not done, and their PRE/ACTIVE/AVAILABLE/level/class/profession gates pass).  A step open in
    -- the client but not here (or the reverse) means the report did not carry some state: that is a DIFF, not "order".
    local offOpen, nOff = {}, 0
    for _, s in ipairs(P.Pending(9999)) do offOpen[s.index] = true nOff = nOff + 1 end
    local missing, extra = {}, {}
    local pr = r.progress or {}
    if type(pr.open) == "string" then
        local cut = pr.open:find("...", 1, true) ~= nil   -- trimmed in the client: only check what it does list
        local cOpen = set(pr.open)
        for i in pairs(cOpen) do if not offOpen[i] then missing[#missing + 1] = i end end
        if not cut then for i in pairs(offOpen) do if not cOpen[i] then extra[#extra + 1] = i end end end
    else
        -- an older report without the open list: its upcoming steps at least must be open here
        for _, u in ipairs(r.upcoming or {}) do if u.index and not offOpen[u.index] then missing[#missing + 1] = u.index end end
    end
    table.sort(missing) table.sort(extra)
    if #missing > 0 or #extra > 0 then
        diffs[#diffs + 1] = "open steps"
        local function list(t) local o = {} for i = 1, math.min(#t, 20) do o[i] = tostring(t[i]) end return table.concat(o, ",") .. (#t > 20 and ",..." or "") end
        out("  open steps |DIFFER|: %d open offline, %s in the client", nOff, tostring(pr.pending or "?"))
        if #missing > 0 then out("    open in the client, not offline: %s  (a quest, level, class or skill gate the replay sees differently)", list(missing)) end
        if #extra > 0 then out("    open offline, not in the client: %s", list(extra)) end
    else
        out("  open steps: same as the client (%d)", nOff)
    end
    -- route
    local path = cur and R.CurrentPath(true)
    local legs = legsOf(path)
    out("  route (offline): %s", path and TG.Describe(path) or "no route")
    for i, l in ipairs(legs) do out("    %d. %s", i, legLine(l)) end
    local rt = r.route
    if rt and cur and cur.index == want then
        local cm, om = modes(rt.legs), modes(legs)
        local found = (path ~= nil)
        if found ~= (rt.found and true or false) then diffs[#diffs + 1] = "route found"
        elseif found then
            if cm ~= om then diffs[#diffs + 1] = "route legs" end
            local a, b = path.cost, rt.secs or 0
            if math.abs(a - b) > math.max(5, 0.05 * math.max(a, b)) then diffs[#diffs + 1] = "route time" end
            out("  route vs client: legs %s / %s, %s / %s", om, cm, fmtTime(a), fmtTime(b))
        end
    end
    local rec = cur and R.Recommendation()
    if rec then out("  arrow (offline): %s %q%s", tostring(rec.mode), tostring(rec.text), rec.eta and ("  eta " .. fmtTime(rec.eta)) or "") end
    if rec and r.arrow and cur and cur.index == want and rec.mode ~= r.arrow.mode then diffs[#diffs + 1] = "arrow mode" end
    -- next steps
    out("  upcoming (offline; travel from the step before, the first from the player):")
    local clientIdx = {}
    for i, u in ipairs(r.upcoming or {}) do clientIdx[i] = u.index end
    local sameOrder, prev = true, nil
    for i, s in ipairs(P.Upcoming(#(r.upcoming or {}) > 0 and #r.upcoming or 8)) do
        local secs
        if i == 1 then secs = path and path.cost else secs = R.TravelSeconds(prev, s) end
        prev = s
        if clientIdx[i] ~= s.index then sameOrder = false end
        out("    %d. %s [%s] %s  ~%s%s", i, tostring(s.index), s.action, tostring(s.title), fmtTime(secs),
            clientIdx[i] and clientIdx[i] ~= s.index and ("   (client: " .. tostring(clientIdx[i]) .. ")") or "")
    end
    if not sameOrder then
        out("  note: the upcoming order differs%s", (#missing > 0 or #extra > 0) and " (see the open steps above)"
            or " (the open steps match; the replay restores the client's kept plan, but not its 3 ms per-call budget or kept costs)")
    end
    if #diffs == 0 then out("RESULT MATCH %s", r.id) else out("RESULT DIFF %s: %s", r.id, table.concat(diffs, ", ")) end
    return (#diffs == 0 or not opts.check) and 0 or 1
end

-- ---------------------------------------------------------------------------
-- Capture: play N steps of a guide in the fake world, then save a report with the real module
-- ---------------------------------------------------------------------------
-- Reset the fake character for guide `gid`, load it, play `n` steps and move to `from` (a zone name, optional).
-- Returns the current step afterwards.
local function playInto(ctx, gid, n, from)
    local NS, W = ctx.NS, ctx.W
    local P, R, G = NS.Progress, NS.Router, NS.Guide
    local g = G.registry[gid]
    local faction = g.faction == "Horde" and "Horde" or "Alliance"
    ctx.setChar(faction, "WARRIOR", faction == "Horde" and "Orc" or "Human")
    NS.player.faction, NS.player.class, NS.player.race = faction, "WARRIOR", faction == "Horde" and "Orc" or "Human"
    ctx.wipeWorld(math.max(1, tonumber(g.minlevel) or 1))
    for _, q in ipairs(ctx.captureDone or {}) do W.quests[q] = "done" end   -- --capture-done: history the guide does not play
    W.bags[NS.HEARTH_ITEM] = 1   -- a real character carries one; it puts the hearth leg in play
    NS.db.char.done, NS.db.char.skipped, NS.db.char.reopened, NS.db.char.laps, NS.db.char.guide = {}, {}, {}, {}, nil
    NS.db.char.parked, NS.db.char.parkReturn = {}, nil
    if NS.Account and NS.Account.me then NS.Account.me.done, NS.Account.me.skipped = {}, {} end
    R.Invalidate()
    NS.TravelGraph.Build()
    local zone = g.zone
    if not zone then for _, s in ipairs(G.Steps(gid)) do if s.zone then zone = s.zone break end end end
    if zone and MAPS[zone] then ctx.place(zone, 0.5, 0.5) end
    if not P.Load(gid) then return nil end
    for _ = 1, n do
        local step = P.current
        if not step then break end
        ctx.walkTo(step)
        ctx.act(step)
        P.Refresh()
        if P.current == step then P.MarkDone(step) end
    end
    -- then stand somewhere else (a capital by default), so the route to the next step has real legs
    if from then
        local map = NS.Util.MapIDByName(from)
        if map and MAPS[map] and ctx.place(map, 0.5, 0.5) then R.Invalidate() P.Refresh() end
    end
    return P.current
end

function RP.Capture(opts, ctx)
    local NS = ctx.NS
    local P, R, G = NS.Progress, NS.Router, NS.Guide
    local n = opts.steps or 6
    local gid = opts.capture
    ctx.captureDone = opts.done
    local from = opts.from
    if gid == "auto" then
        -- the first Alliance-usable quest guide (wiki guides first, registry order: deterministic) that, after n steps,
        -- still has a located current step with a route to it
        gid = nil
        local tried = 0
        for pass = 1, 2 do
            for _, id in ipairs(G.list) do
                local g = G.registry[id]
                local ty = G.NormalizeType(g.type)
                if tried < 40 and (pass == 2 or id:match("^wiki:")) and (ty == "Quests" or ty == "Leveling") and g.faction ~= "Horde" and not g.loop then
                    local ok, steps = pcall(G.Steps, id)
                    local located = 0
                    for _, s in ipairs(ok and steps or {}) do if s.coords and s.zone and MAPS[s.zone] then located = located + 1 end end
                    if located >= n + 12 then
                        tried = tried + 1
                        local capital = from or (g.faction == "Horde" and "Orgrimmar" or "Stormwind City")
                        local cur = playInto(ctx, id, n, capital)
                        local path = cur and cur.coords and R.StepWorld(cur) and R.CurrentPath(true)
                        if path and #path.legs >= 2 then gid = id break end
                    end
                end
            end
            if gid then break end
        end
        if not gid then out("capture: no guide still routed after %d steps (%d tried)", n, tried) return 2 end
    else
        if not G.registry[gid] then out("capture: no guide %s", tostring(gid)) return 2 end
        playInto(ctx, gid, n, from)
    end
    if not NS.BugReport then ctx.load("Core/BugReport.lua") end
    local r = NS.BugReport.Snapshot(opts.note or "vplayer capture")
    local text = J.encode(r)
    if opts.out then
        local f = assert(io.open(opts.out, "w"))
        f:write(text, "\n") f:close()
        out("CAPTURED %s guide %s step %s -> %s", r.id, gid, tostring(r.step and r.step.index), opts.out)
    else
        io.write(text, "\n")
    end
    return 0
end

function RP.Main(opts, report, ctx)
    if opts.capture then return RP.Capture(opts, ctx) end
    return RP.Run(report, ctx, opts)
end

return RP
