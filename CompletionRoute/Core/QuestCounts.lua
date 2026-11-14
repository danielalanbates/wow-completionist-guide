-- CompletionRoute :: Core/QuestCounts.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC.  All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- How many quests a route has and how many of them are done, for the routes list (UI/GuideMenu.lua): "12 / 40 quests"
-- on a route, "312 / 1,040 quests" on a folder, "Quests done: 312 of 4,268" at the top.
--
-- What counts (docs/QUEST_COUNTS.md):
--   * A route's quests are the quests it TURNS IN (the QID of its turn-in steps), each id once.  A quest the route only
--     accepts or works on, with no turn-in step, is not counted: on Retail 88 routes hold 346 such quests (auto-accepted
--     area tasks, many of them weekly), which the client may never keep as completed, so a route holding one could
--     never read "completed".  The other four clients have none.  Steps marked optional (|O|) are left out, and so
--     are steps this character can never take (a FACTION, C or R tag for another faction, class or race).  A quest
--     this character dropped (/cr skip) is left out too.
--   * Only QUEST ROUTES are counted: routes that turn at least one quest in, other than gold and profession routes.
--     An achievement list names quests as criteria (many are hidden tracking flags) and a profession route may hold one
--     trainer quest; those keep their own right-hand text and add nothing to a folder or to the total.
--   * A quest is done when a character in scope has completed it: this character's completed quests
--     (Core/Account.lua, harvested from the client), plus, in the wider scopes, the other characters' saved lists.
--     The other characters count only while the option "also match by quest ID across different routes"
--     (profile.accountQuests, on by default) is on, exactly as their quests tick steps (A.OtherDidQuest): a row that
--     reads "completed" is then always a route that opens with no quest step left.
--   * A folder and the total count each quest id once, however many routes list it (a leveling chain entry and the
--     zone route it is made from share every quest).  Quest ids no route names (the client's hidden tracking quests)
--     are never counted, done or not.
--
-- Where the ids come from: Data/QuestIndex_<flavor>.lua (tools/gen_quest_index.lua), one short string per route, so
-- no route is parsed for its count.  The index also names the routes that turn no quest in (only their ticks can
-- finish them), so the routes list need not parse a route nobody has a tick in to learn that it is not finished.  An entry carries the length of the route text it was made from; when that does
-- not match (the routes were regenerated without the index) or a route is not listed (hand-written, live, made in
-- game), the ids are read from the route's parsed steps instead, by the same function the generator uses (QC.Groups).
local ADDON, NS = ...
local G, Cond = NS.Guide, NS.Cond
local QC = {}
NS.QuestCounts = QC

local TURNIN = { T = true, t = true }
-- The index format this file reads (NS.QuestIndex.v).  2: only quests the route turns in.  An index of another
-- version is ignored as a whole (every route is then read from its steps), so old numbers cannot survive a rule change.
QC.INDEX_V = 2

-- ---------------------------------------------------------------------------
-- From parsed steps (the generator and the fallback)
-- ---------------------------------------------------------------------------
-- Who may take a step, as one string: "" for everyone, else faction, class and race lists separated by tabs
local function sigOf(s)
    if not (s.faction or s.class or s.race) then return "" end
    return (s.faction or "") .. "\t" .. (s.class or "") .. "\t" .. (s.race or "")
end
QC.SigOf = sigOf

-- { quest = the route turns a quest in, sigs = { "", sig, ... } sorted, by = { [sig] = { quest id, ... } } }
-- A quest some step offers to everyone is listed under "" only; otherwise under every restriction it is offered with.
function QC.Groups(steps)
    local sigsOf, order, quest, turned = {}, {}, false, {}
    for i = 1, #steps do
        local s = steps[i]
        local q = s.qid
        if q and #q > 0 and not s.optional and (s.index or 1) > 0 then
            if TURNIN[s.action] then
                quest = true
                for k = 1, #q do turned[q[k]] = true end
            end
            local sig = sigOf(s)
            for k = 1, #q do
                local id = q[k]
                local t = sigsOf[id]
                if not t then t = {} sigsOf[id] = t order[#order + 1] = id end
                t[sig] = true
            end
        end
    end
    local by, sigs = {}, {}
    local function add(sig, id)
        local l = by[sig]
        if not l then l = {} by[sig] = l sigs[#sigs + 1] = sig end
        l[#l + 1] = id
    end
    for _, id in ipairs(order) do
        -- only the quests the route turns in (see the top of this file)
        if turned[id] then
            local t = sigsOf[id]
            if t[""] then add("", id) else for sig in pairs(t) do add(sig, id) end end
        end
    end
    table.sort(sigs)
    return { quest = quest, sigs = sigs, by = by }
end

-- Does a restriction apply to the character logged in?
local sigCache, sigWho = {}, nil
local function sigApplies(sig)
    if sig == "" then return true end
    local p = NS.player
    local who = p and (tostring(p.faction) .. "/" .. tostring(p.class) .. "/" .. tostring(p.race)) or ""
    if who ~= sigWho then sigCache, sigWho = {}, who end
    local v = sigCache[sig]
    if v == nil then
        local f, c, r = sig:match("^([^\t]*)\t([^\t]*)\t(.*)$")
        v = (f == "" or Cond.FactionMatch(f)) and (c == "" or Cond.ClassMatch(c)) and (r == "" or Cond.RaceMatch(r)) and true or false
        sigCache[sig] = v
    end
    return v
end
QC.SigApplies = sigApplies

-- The quest ids of QC.Groups this character can take, each once
function QC.Resolve(groups)
    local list, seen = {}, {}
    for _, sig in ipairs(groups.sigs) do
        if sigApplies(sig) then
            for _, id in ipairs(groups.by[sig]) do
                if not seen[id] then seen[id] = true list[#list + 1] = id end
            end
        end
    end
    return list
end

-- ---------------------------------------------------------------------------
-- From the generated index
-- ---------------------------------------------------------------------------
-- Entry of a quest route: "<text length>|<ids for everyone>|<restriction number>:<ids>|..." (NS.QuestIndex.conds
-- holds the restrictions).  Entry of a route that turns no quest in: "<text length>".
-- Returns the ids for this character and true, or {} and false for a route without turn-ins; nil when the index has
-- nothing (current) to say about the route.
local function fromIndex(src)
    local QI = NS.QuestIndex
    if not QI or QI.v ~= QC.INDEX_V then return nil end
    local e = QI.r and QI.r[src.id]
    if not e then return nil end
    local text = src.text
    if type(text) ~= "string" then return nil end
    local len, rest = e:match("^(%d+)|(.*)$")
    if not len then
        if tonumber(e) == #text then return {}, false end
        return nil
    end
    if tonumber(len) ~= #text then return nil end        -- made from another version of this route: read the steps
    local list, seen = {}, nil
    local first = true
    for part in (rest .. "|"):gmatch("([^|]*)|") do
        local ids = part
        local use = true
        if first then first = false
        else
            local ci
            ci, ids = part:match("^(%d+):(.*)$")
            local sig = ci and QI.conds and QI.conds[tonumber(ci)]
            use = sig ~= nil and sigApplies(sig)
            if use and not seen then
                seen = {}
                for i = 1, #list do seen[list[i]] = true end
            end
        end
        if use then
            for n in ids:gmatch("%d+") do
                local q = tonumber(n)
                if not seen then list[#list + 1] = q
                elseif not seen[q] then seen[q] = true list[#list + 1] = q end
            end
        end
    end
    return list, true
end

-- ---------------------------------------------------------------------------
-- A route's quests
-- ---------------------------------------------------------------------------
local entries = {}      -- [route id whose text it is] = { list = { quest id, ... }, quest = bool, who = , text = }
local function whoKey()
    local p = NS.player
    return p and (tostring(p.faction) .. "/" .. tostring(p.class) .. "/" .. tostring(p.race)) or ""
end
-- The record of route g (nil when it is not known without parsing and force is not set).  force parses the route
-- (G.Steps); the caller lets go of the steps it did not have before, as the routes list's scan does.
local function entryOf(g, force)
    if not g then return nil end
    -- a leveling chain entry reads its zone route's text: one record for both
    local src = g
    if g.part then src = G.registry[g.part] or g end
    local who = whoKey()
    local e = entries[src.id]
    if e and e.who == who and e.text == src.text and not src.dynamic then return e end
    local list, quest
    if not src.dynamic then list, quest = fromIndex(src) end
    if not list then
        local steps = g.steps
        if not steps then
            if not force then return nil end
            local ok, st = pcall(G.Steps, g.id)
            steps = ok and st or nil
        end
        if not steps then return nil end
        local groups = QC.Groups(steps)
        list, quest = QC.Resolve(groups), groups.quest
    end
    -- turnsIn: a quest route by its text; quest: ...that has at least one quest this character can take
    e = { list = list, quest = quest and #list > 0, turnsIn = quest and true or false, who = who, text = src.text }
    if not src.dynamic then entries[src.id] = e end
    return e
end

-- Is g counted by its quests?  nil when that is not known yet (see entryOf).
function QC.IsQuestRoute(g, force)
    if not g or g.loop or G.IsSideGuide(g) then return false end
    local e = entryOf(g, force)
    if not e then return nil end
    return e.quest
end
-- Does route g turn no quest in at all (so only its ticks can finish it)?  Asked of any route, gold and profession
-- routes included; nil when that is not known without parsing it.
function QC.TicksOnly(g)
    local e = entryOf(g, false)
    if not e then return nil end
    return not e.turnsIn
end
-- The quest ids of route g for this character and whether it is a quest route; nil when not known yet.
function QC.Quests(g, force)
    if not g then return nil end
    if g.loop or G.IsSideGuide(g) then return {}, false end
    local e = entryOf(g, force)
    if not e then return nil end
    return e.list, e.quest
end

-- ---------------------------------------------------------------------------
-- Done, by scope
-- ---------------------------------------------------------------------------
local gen = 0                   -- goes up whenever an answer may have changed
local counts = {}               -- [scope] = { [route id] = { done, total } }
local tablesOf = {}             -- [scope] = { completed-quest table of every character in scope }
function QC.Invalidate() gen = gen + 1 counts = {} tablesOf = {} end
function QC.Gen() return gen end

-- Do the other characters' completed quests count in the wider scopes?  Only while they also tick steps
-- (profile.accountQuests, Core/Account.lua A.OtherDidQuest); the option's check box clears the stored answers.
function QC.OthersCount()
    local p = NS.db and NS.db.profile
    return not p or p.accountQuests ~= false
end
local function questTables(scope)
    local A = NS.Account
    local others = QC.OthersCount()
    local t = tablesOf[scope]
    if t and t.me == (A.me and A.me.quests) and t.others == others then return t end
    t = { me = A.me and A.me.quests, others = others }
    if t.me then t[1] = t.me end
    if scope ~= "char" and others and NS.db and NS.db.global and NS.db.global.chars then
        for k, c in pairs(NS.db.global.chars) do
            if k ~= A.key and type(c) == "table" and type(c.quests) == "table" and A.CharInScope(k, c, scope) then t[#t + 1] = c.quests end
        end
    end
    tablesOf[scope] = t
    return t
end
-- quests this character dropped, or nil
local function removedSet()
    local Sk = NS.Skip
    if Sk and Sk.Any and Sk.Any() then return Sk.Removed() end
    return nil
end

-- done, total of route g in a scope.  nil = not known yet; 0, 0 = not a quest route.  A third result, true, comes with
-- 0, 0 when the route does turn quests in but none of them is for this character (so it can never be finished by it).
function QC.Count(g, scope, force)
    local A = NS.Account
    if not (g and A and A.me) then return nil end
    scope = scope or A.Scope()
    local c = counts[scope]
    if not c then c = {} counts[scope] = c end
    local hit = c[g.id]
    if hit then return hit[1], hit[2], hit[3] end
    if g.loop or G.IsSideGuide(g) then return 0, 0 end
    local e = entryOf(g, force)
    if not e then return nil end
    if not e.quest then
        local none = e.turnsIn or nil
        if not g.dynamic then c[g.id] = { 0, 0, none } end
        return 0, 0, none
    end
    local tabs, gone = questTables(scope), removedSet()
    local list, nt = e.list, #tabs
    local done, total = 0, 0
    for i = 1, #list do
        local q = list[i]
        if not (gone and gone[q]) then
            total = total + 1
            for k = 1, nt do if tabs[k][q] then done = done + 1 break end end
        end
    end
    if not g.dynamic then c[g.id] = { done, total } end
    return done, total
end

-- QC.Count's stored answer and nothing else: nil until something (the routes list's scan) has counted the route.
-- For code that runs on every redraw.
function QC.Peek(g, scope)
    local A = NS.Account
    if not (g and A and A.me) then return nil end
    local c = counts[scope or A.Scope()]
    local hit = c and c[g.id]
    if hit then return hit[1], hit[2] end
    return nil
end

-- Has one character (record ch) completed every quest of route g?  nil when g is not a quest route (or not known).
function QC.FinishedBy(g, ch, force)
    local e = (not g.loop and not G.IsSideGuide(g)) and entryOf(g, force) or nil
    if not (e and e.quest) then return nil end
    local qs = ch and ch.quests
    if type(qs) ~= "table" then return false end
    local gone = (ch == (NS.Account and NS.Account.me)) and removedSet() or nil
    local list = e.list
    for i = 1, #list do
        local q = list[i]
        if not qs[q] and not (gone and gone[q]) then return false end
    end
    return true
end

-- A running total over several routes, each quest id once: t = QC.Tally(scope); QC.TallyAdd(t, g); t.done, t.total.
-- TallyAdd parses nothing: a route whose quests are not known yet is skipped and counted in t.unknown.
function QC.Tally(scope)
    local A = NS.Account
    return { scope = scope or (A and A.Scope()) or "char", seen = {}, done = 0, total = 0, routes = 0, unknown = 0 }
end
function QC.TallyAdd(t, g)
    if g.loop or G.IsSideGuide(g) then return end
    local e = entryOf(g, false)
    if not e then t.unknown = t.unknown + 1 return end
    if not e.quest then return end
    t.routes = t.routes + 1
    local tabs, gone, seen = questTables(t.scope), removedSet(), t.seen
    local list, nt = e.list, #tabs
    local done, total = t.done, t.total
    for i = 1, #list do
        local q = list[i]
        if not seen[q] then
            seen[q] = true
            if not (gone and gone[q]) then
                total = total + 1
                for k = 1, nt do if tabs[k][q] then done = done + 1 break end end
            end
        end
    end
    t.done, t.total = done, total
end

-- 4268 -> "4,268"
function QC.Fmt(n)
    local s = tostring(math.floor(n or 0))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

-- tools and tests
QC._test = { entries = function() return entries end, fromIndex = fromIndex, reset = function() entries = {} QC.Invalidate() end }
