-- CompletionRoute :: Core/Account.lua
-- Account-wide progression.
--
-- Every character's guide progress is stored in ONE account-level table
-- (CompletionRouteDB.chars["Name-Realm"]), so any character can see what the others have finished.
-- The per-character saved-variable file keeps only that character's settings + a pointer.
--
-- Opt-in: profile.accountWide.  When ON, a step counts as done if ANY character on the account
-- did it (completionists chasing "all content once"); when OFF you get classic per-character
-- behaviour and other characters' data is left untouched.
--
-- Step marks are stored by stable step key (Core/Guide.lua "Stable step keys", docs/STEP_KEYS.md), so a guide
-- regenerated with lines added, removed or moved keeps ticks and skips on their steps (STEP_KEYS.md: what still moves one):
--   chars[k].stepDone[guide][key] = true       ticked (by hand or by the auto-completer)
--   chars[k].stepSkipped[guide][key] = true    skipped as a step (quest-level skips: Core/Skip.lua questSkip)
--   CompletionRouteCharDB.stepReopened[guide][key] = true   stepped back to (Progress.Undo)
--   chars[k].stepMeta[guide] = { v = key version, sum = Guide.GuideSum when last loaded or migrated,
--                                mig = old marks imported, lost = old marks that matched no step,
--                                ro = the character's own stepped-back marks imported (false: not yet, see A.Migrate) }
-- The tables of earlier releases, chars[k].done / skipped and CompletionRouteCharDB.reopened, keyed by author step
-- index, are read once per character and guide (A.Migrate) and then left alone, so the previous release still finds
-- the progress made before the update if the addon is downgraded.  Reset clears both.
local ADDON, NS = ...
local A = {}
NS.Account = A

local function key() return (NS.player.name or UnitName("player")) .. "-" .. (NS.player.realm or GetRealmName() or "?") end

function A.Init()
    local db = NS.db.global
    db.chars = db.chars or {}
    A.key = key()
    local me = db.chars[A.key]
    if not me then
        me = { done = {}, skipped = {} }
        db.chars[A.key] = me
        -- migrate a pre-account-store character (progress used to live in CompletionRouteCharDB)
        local c = NS.db.char
        if c.done and next(c.done) then me.done = c.done end
        if c.skipped and next(c.skipped) then me.skipped = c.skipped end
        me.migrated = true
    end
    me.done = me.done or {}
    me.skipped = me.skipped or {}
    me.stepDone = me.stepDone or {}
    me.stepSkipped = me.stepSkipped or {}
    me.stepMeta = me.stepMeta or {}
    NS.db.char.stepReopened = NS.db.char.stepReopened or {}
    me.quests = me.quests or {}   -- [questID] = true, quests this character turned in
    me.name = NS.player.name
    me.realm = NS.player.realm
    me.class = NS.player.class
    me.faction = NS.player.faction
    me.race = NS.player.race
    me.flavor = NS.flavor
    me.hardcore = A.IsHardcore()
    me.gametype = A.GameType()
    me.level = UnitLevel("player")
    me.updated = date("%Y-%m-%d %H:%M:%S")
    A.me = me
    -- the character SV keeps settings only from here on
    NS.db.char.done, NS.db.char.skipped = me.done, me.skipped
end

-- ---------------------------------------------------------------------------
-- Scope: whose progress counts.  Four settings, narrow to wide:
--   "char"    only this character
--   "realm"   every character on this realm (server)
--   "flavor"  every character in this game type (Anniversary / Classic Era / Hardcore / Modern...)
--   "account" every character, everywhere
-- profile.accountWide is kept in step with it so older code and saved variables keep working.
-- ---------------------------------------------------------------------------
A.SCOPES = { "char", "realm", "flavor", "account" }
A.SCOPE_LABEL = { char = "This character", realm = "This server", flavor = "This game type", account = "All characters" }

function A.IsHardcore()
    if C_GameRules and C_GameRules.IsHardcoreActive then
        local ok, v = pcall(C_GameRules.IsHardcoreActive)
        if ok then return v and true or false end
    end
    if C_Seasons and C_Seasons.GetActiveSeason then
        local ok, v = pcall(C_Seasons.GetActiveSeason)
        if ok and v == 3 then return true end   -- 3 = Hardcore season
    end
    return false
end
-- A game type is the client flavor plus the rules that make progress non-transferable.  An
-- Anniversary Hardcore character has nothing in common with an Anniversary normal one.
function A.GameType()
    local base = (NS.isForever and "forever") or NS.flavor or "?"
    return A.IsHardcore() and (base .. "-hardcore") or base
end
local GAMETYPE_NAME = { era = "Classic Era", tbc = "Anniversary (TBC)", wrath = "Wrath Classic", cata = "Cataclysm Classic",
                        mop = "Mists Classic", retail = "Modern (retail)", forever = "WoW Forever" }
function A.GameTypeName(t)
    t = t or A.GameType()
    local base, hc = t:match("^(.-)%-hardcore$"), true
    if not base then base, hc = t, false end
    return (GAMETYPE_NAME[base] or base) .. (hc and " Hardcore" or "")
end

function A.Scope()
    local p = NS.db and NS.db.profile
    if not p then return "char" end
    if not p.scope then p.scope = p.accountWide and "account" or "char" end   -- migrate the old boolean
    -- Anything that still flips the accountWide boolean directly (the options check box, the
    -- verifier's temporary override, an old saved-variable file) wins: adopt it and re-sync.
    if p.accountWide ~= (p.scope ~= "char") then
        p.scope = p.accountWide and "account" or "char"
        A.ClearCompletionCaches()
    end
    return p.scope
end
function A.SetScope(sc)
    local p = NS.db.profile
    p.scope = sc
    p.accountWide = (sc ~= "char")
    A.ClearCompletionCaches()
end
function A.ScopeLabel(sc) return A.SCOPE_LABEL[sc or A.Scope()] or "?" end
-- What the current scope means, in words, for the character we are on
function A.ScopeDetail(sc)
    sc = sc or A.Scope()
    if sc == "char" then return (A.me and A.me.name or "this character") .. " only" end
    if sc == "realm" then return "every character on " .. ((A.me and A.me.realm) or "this realm") end
    if sc == "flavor" then return "every character in " .. A.GameTypeName() end
    return "every character on the account"
end
-- Does another character's record count under the current scope?
function A.CharInScope(k, c, sc)
    sc = sc or A.Scope()
    if sc == "char" then return k == A.key end
    if not c then return false end
    if sc == "realm" then return c.realm == (A.me and A.me.realm) end
    if sc == "flavor" then return (c.gametype or c.flavor) == A.GameType() end
    return true
end

function A.Enabled() return A.Scope() ~= "char" end

-- Sandbox: while a bulk sweep is loading every guide in the catalogue, progress writes must not
-- land in the character's real record (otherwise /cr verifyall marks thousands of steps "done").
-- Loading a guide also writes the character file: the saved guide, parked guides and where a detour returns to (the
-- end-of-guide chain runs for every guide the sweep finds finished), the finished route held on screen
-- (Core/Progress.lua P.Load), farm laps.  Those are kept aside as well.
-- Begin / End are counted, so the store stays in place until the last sweep ends, and a logout or /reload in the middle
-- of a sweep puts everything back before the client writes the saved variables (PLAYER_LOGOUT below).
local SCRATCH = { "done", "skipped", "stepDone", "stepSkipped", "stepMeta" }
local SCRATCH_CHAR = { "guide", "parked", "parkReturn", "held", "laps" }
local function shallow(v)
    if type(v) ~= "table" then return v end
    local c = {}
    for k, x in pairs(v) do c[k] = x end
    return c
end
function A.BeginScratch()
    if not A.me then return false end
    A.scratchDepth = (A.scratchDepth or 0) + 1
    if A.scratch then return true end
    A.scratch = { char = {} }
    for _, f in ipairs(SCRATCH) do A.scratch[f], A.me[f] = A.me[f], {} end
    local c = NS.db.char
    for _, f in ipairs(SCRATCH_CHAR) do A.scratch.char[f] = c[f] c[f] = shallow(c[f]) end
    return true
end
-- force: put the real tables back whatever the count (logout)
function A.EndScratch(force)
    if not A.scratch then A.scratchDepth = 0 return end
    A.scratchDepth = force and 0 or math.max(0, (A.scratchDepth or 1) - 1)
    if A.scratchDepth > 0 then return end
    for _, f in ipairs(SCRATCH) do A.me[f] = A.scratch[f] end
    local c = NS.db.char
    for _, f in ipairs(SCRATCH_CHAR) do c[f] = A.scratch.char[f] end
    A.scratch = nil
end

-- This character's marks for one guide, by step key (created on first use: callers write to them)
function A.Done(guideid)
    local t = A.me.stepDone[guideid]
    if not t then t = {} A.me.stepDone[guideid] = t end
    return t
end
function A.Skipped(guideid)
    local t = A.me.stepSkipped[guideid]
    if not t then t = {} A.me.stepSkipped[guideid] = t end
    return t
end
function A.Reopened(guideid)
    local c = NS.db.char
    c.stepReopened = c.stepReopened or {}
    local t = c.stepReopened[guideid]
    if not t then t = {} c.stepReopened[guideid] = t end
    return t
end

-- ---------------------------------------------------------------------------
-- Migration of index-keyed marks (earlier releases) to step keys
-- ---------------------------------------------------------------------------
-- Once per character and guide: the old marks are mapped index -> key with the guide as it is NOW.  That is right only
-- where the guide data has not been re-ordered since those marks were written, which nothing stored can prove, so two
-- checks drop marks that cannot be right (indexMap below); from here on keys carry the marks across data changes.
-- stepMeta[guide] records that it ran, so it never runs again:
-- marks a downgraded client later writes into the old tables, maybe on different data, are never mapped.
-- Characters other than the one logged in are migrated too (their marks count for account-wide progress), but only
-- those of this client's game type: a record copied in from another client by tools/sync_progress.lua was written
-- against that client's guide data, and its own client migrates it.  Access-chain steps (negative indices) are not
-- carried over: their numbers depended on which chains were locked at each load; their quests re-tick from the log.
-- Stepped-back marks (CompletionRouteCharDB.reopened) live in the character's own file, so only that character can import
-- them: a record another character migrated gets ro = false, and its owner imports its set on its own next load.
-- During a bulk sweep (A.BeginScratch) the logged-in character is not migrated: its record's marks are swapped for empty
-- ones but its character file is not, so the sweep would re-import old stepped-back marks the player has since moved on.
local function baseType(t) return t and (t:gsub("%-hardcore$", "")) or nil end
local function migratable(c, k)
    if c == A.me or k == A.key then return true end
    if c.gametype then return baseType(c.gametype) == baseType(A.GameType()) end
    -- a record from before game types: its flavor, except "era", which Classic Era and WoW Forever both report
    return c.flavor ~= nil and c.flavor ~= "era" and c.flavor == NS.flavor and not NS.isForever
end
A.Migratable = migratable
-- author index -> key and -> step for the guide's own steps; n = the highest author index (the guide's length)
local function indexMap(steps)
    local m, st, n = {}, {}, 0
    for _, s in ipairs(steps) do
        local i = s.index or 0
        if i > 0 and s.key then
            m[i], st[i] = s.key, s
            if i > n then n = i end
        end
    end
    return { key = m, step = st, n = n }
end
-- Position alone is not trusted (the gap guides were regenerated and shortened between the marks and this release):
--   * a set with an index above the guide's length was written on another version of the guide: nothing of that
--     character's marks for the guide is carried over (stale())
--   * a done mark lands on a quest step only when the character's completed quests agree (its record's list; for the
--     logged-in character also the client).  Nothing real is lost: a quest step re-ticks itself from the quest log.
-- Marks on steps without a quest, skips and stepped-back marks have nothing to be checked against beyond the first rule.
local function stale(map, ...)
    for n = 1, select("#", ...) do
        local set = select(n, ...)
        if set then for i, v in pairs(set) do if v and type(i) == "number" and i > map.n then return true end end end
    end
    return false
end
local function count(set) local n = 0 if set then for _, v in pairs(set) do if v then n = n + 1 end end end return n end
local function questAgrees(step, c, me)
    local q = step.qid
    if not q or #q == 0 then return true end
    for i = 1, #q do
        if (c.quests and c.quests[q[i]]) or (me and NS.Util.IsQuestComplete(q[i])) then return true end
    end
    return false
end
-- Copy one old index-keyed set into a key set; returns copied, lost.  c (optional): the record whose completed quests
-- a mark on a quest step must agree with (done marks only).
local function importSet(old, dst, map, c, me)
    local n, lost = 0, 0
    for i, v in pairs(old) do
        local k = v and map.key[i]
        if k and (not c or questAgrees(map.step[i], c, me)) then
            if not dst[k] then dst[k] = true end
            n = n + 1
        elseif v then lost = lost + 1 end
    end
    return n, lost
end
-- (a saved entry that is not a table, from a damaged file, counts as empty)
local function nonEmpty(t) return type(t) == "table" and next(t) ~= nil end
-- This character's old stepped-back set (character file) into its keyed one; sets meta.ro.  Returns whether it had any.
local function importReopened(meta, gid, steps, ctx)
    local c = NS.db.char
    local ro = c.reopened and c.reopened[gid]
    meta.ro = true
    if not nonEmpty(ro) then return false end
    ctx.map = ctx.map or indexMap(steps)
    if meta.stale or stale(ctx.map, ro) then
        meta.lost = (meta.lost or 0) + count(ro)
        return true
    end
    c.stepReopened = c.stepReopened or {}
    local dst = c.stepReopened[gid] or {}
    local n, lost = importSet(ro, dst, ctx.map)
    if next(dst) then c.stepReopened[gid] = dst end
    meta.mig = (meta.mig or 0) + n
    if lost > 0 then meta.lost = (meta.lost or 0) + lost end
    return true
end
-- c: one character record; me: it is the logged-in character (its reopened set lives in the character file)
local function migrateOne(c, gid, steps, me, touch, ctx)
    local meta = c.stepMeta and c.stepMeta[gid]
    if meta then
        if not me then return false end
        -- migrated by another character of this client, which could not see this character's stepped-back marks
        local now = meta.ro == false and importReopened(meta, gid, steps, ctx)
        if touch then
            local sum = ctx.sum()
            if sum and meta.sum ~= sum then meta.sum = sum end
        end
        return now
    end
    local od, osk = c.done and c.done[gid], c.skipped and c.skipped[gid]
    local ro = me and NS.db.char.reopened and NS.db.char.reopened[gid] or nil
    -- an entry that is not a table (a damaged file) holds no marks
    if type(od) ~= "table" then od = nil end
    if type(osk) ~= "table" then osk = nil end
    if type(ro) ~= "table" then ro = nil end
    local has = nonEmpty(od) or nonEmpty(osk) or nonEmpty(ro)
    if not has and not (me and touch) then return false end
    c.stepDone, c.stepSkipped, c.stepMeta = c.stepDone or {}, c.stepSkipped or {}, c.stepMeta or {}
    meta = { v = NS.Guide.KEY_VERSION, sum = ctx.sum(), mig = 0 }
    if has then
        ctx.map = ctx.map or indexMap(steps)
        -- a guide with no steps yet (a live guide before its first scan) is not the guide the marks were made on: wait
        if ctx.map.n == 0 then return false end
        if stale(ctx.map, od, osk, ro) then
            -- not the guide these marks were made on: none is placed (stale = 1 keeps the reason in the record)
            meta.stale = 1
            local lost = count(od) + count(osk)
            if lost > 0 then meta.lost = lost end
        else
            local lost = 0
            local function into(old, all, rec)
                if not nonEmpty(old) then return end
                local dst = all[gid] or {}
                local n, l = importSet(old, dst, ctx.map, rec, me)
                meta.mig, lost = meta.mig + n, lost + l
                if next(dst) then all[gid] = dst end
            end
            into(od, c.stepDone, c)
            into(osk, c.stepSkipped)
            if lost > 0 then meta.lost = lost end
        end
    end
    if me then importReopened(meta, gid, steps, ctx) else meta.ro = false end
    c.stepMeta[gid] = meta
    return true
end
-- Migrate every character this client may migrate, for one guide.  steps = the guide's parsed steps (any order; the
-- loaded list with its access prefix is fine).  touch: record stepMeta for the logged-in character even when it had no
-- old marks (Progress.Load does: a guide played on this release never imports old marks later).  Returns how many
-- records were migrated now.
function A.Migrate(gid, steps, touch)
    if not (A.me and gid and steps) then return 0 end
    local G = NS.Guide
    local sum
    local ctx, n = {}, 0
    function ctx.sum()
        if sum == nil then sum = (G and G.registry[gid] and G.GuideSum(gid)) or false end
        return sum or nil
    end
    -- not the logged-in character during a sweep (A.BeginScratch): it migrates on its first load after the sweep
    if not A.scratch and migrateOne(A.me, gid, steps, true, touch, ctx) then n = n + 1 end
    for k, c in pairs(NS.db.global.chars or {}) do
        if c ~= A.me and k ~= A.key and type(c) == "table" and migratable(c, k) then
            if migrateOne(c, gid, steps, false, false, ctx) then n = n + 1 end
        end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- Every guide's old marks at once, after login (2026-11-12)
-- ---------------------------------------------------------------------------
-- A.Migrate ran for one guide when it was loaded (Progress.Load) or counted with its steps parsed (the routes list).  A
-- guide the character did not open kept its old marks unconverted, so they were mapped later, onto the guide data as it
-- is THEN: a data update in between that re-orders a guide without making it shorter puts a mark on a step without a
-- quest in the wrong place (indexMap's length check cannot see that), and the routes list counted only keyed marks.
-- Now, once per character, A.IMPORT_DELAY seconds after login, every registered guide that still holds old marks of a
-- character this client migrates is converted through the same path as a load: Progress.ReadSteps (the gold circuit
-- fold, then the parsed steps).  The access-chain prefix a load puts in front is left out on purpose: it holds only
-- steps with negative indices, and indexMap maps no old mark to those, so the result is the same without it (and
-- pricing it would cost a graph search per guide).  The work is time-sliced: guides one after another until
-- A.IMPORT_MS of CPU are spent in a frame (at least one guide per frame), parsed steps are not kept (the routes list's
-- rule).  At the end CompletionRouteCharDB.marksImported is set and it never runs again for that character.  A bulk
-- sweep (A.BeginScratch) pauses it; a logout in the middle leaves the flag unset and the next login finishes the rest
-- (A.Migrate never converts a guide twice).  Guides marked dynamic (live dig sites) are left to their load.
-- One guide is one parse and cannot be split, so a guide whose text is longer than A.IMPORT_MAX_TEXT (the huge
-- achievement lists of MoP and Retail: tens of ms each, up to about 90) is not converted here: its old marks stay
-- for the lazy path (A.Migrate when the guide is loaded, or parsed by the routes list), as before this import existed.
-- An error in a slice ends the job for this session (A.ImportTick): the flag stays unset, the next login tries again.
A.IMPORT_MS = 4
A.IMPORT_MAX_TEXT = 40 * 1024
A.IMPORT_DELAY = 10     -- after the saved route has loaded (2 s) and the completed quests were read (3 s)

-- guides of one record with old marks still to convert (me: the logged-in character, whose stepped-back marks live in
-- the character file)
local function pendingOf(c, me, out)
    local meta = c.stepMeta
    for _, f in ipairs({ "done", "skipped" }) do
        for gid, set in pairs(c[f] or {}) do
            if type(gid) == "string" and not (meta and meta[gid]) and nonEmpty(set) then out[gid] = true end
        end
    end
    if me then
        for gid, set in pairs(NS.db.char.reopened or {}) do
            local m = meta and meta[gid]
            if type(gid) == "string" and (not m or m.ro == false) and nonEmpty(set) then out[gid] = true end
        end
    end
end
-- The registered guides that still hold old marks to convert, sorted by id
function A.PendingImports()
    local out = {}
    if not A.me then return out end
    local want = {}
    pendingOf(A.me, true, want)
    for k, c in pairs(NS.db.global.chars or {}) do
        if c ~= A.me and k ~= A.key and type(c) == "table" and migratable(c, k) then pendingOf(c, false, want) end
    end
    local G = NS.Guide
    for gid in pairs(want) do
        local g = G and G.registry[gid]
        if g and not g.empty and not g.dynamic then out[#out + 1] = gid end
    end
    table.sort(out)
    return out
end

local imp               -- the running import: { list, pos, guides, records, slices, cpu, maxSlice, sliceLog }
local importFrame = CreateFrame("Frame")
importFrame:Hide()
local clock = debugprofilestop or function() return os.clock() * 1000 end
local function finishImport(J)
    if imp == J then imp = nil end
    importFrame:Hide()
    NS.db.char.marksImported = NS.Guide and NS.Guide.KEY_VERSION or 1
    A.lastImport = { guides = J.list and #J.list or 0, converted = J.guides, records = J.records, slices = J.slices, cpu = J.cpu,
                     maxSlice = J.maxSlice, left = J.left }
    if J.records > 0 then
        A.ClearCompletionCaches()
        local P = NS.Progress
        if J.loaded and P and P.guide then P.Refresh() end
    end
end
-- One slice: convert guides until `budget` ms (default A.IMPORT_MS) are spent, at least one.  Returns true while work
-- is left.  Tests and tools call it directly; in game the frame's OnUpdate does.
function A.ImportStep(budget)
    local J = imp
    if not J then importFrame:Hide() return false end
    if A.scratch or not A.me then return true end         -- a bulk sweep holds the store: wait for it to end
    local t0 = clock()
    local G, P = NS.Guide, NS.Progress
    -- the list is read here, not when the job is armed: during a sweep the record's old tables are swapped out
    if not J.list then J.list, J.pos = A.PendingImports(), 1 end
    budget = budget or A.IMPORT_MS
    local done = 0
    while true do
        local gid = J.list[J.pos]
        if not gid then break end
        local g = G.registry[gid]
        -- most of a guide's cost is parsing its text: a guide that would not fit in what is left of the budget (its
        -- length at the rate measured so far; a spine entry reads its zone guide's text; else the mean cost of a guide)
        -- waits for the next frame, unless it is the first of this slice
        local len = 0
        if g and not g.steps then
            local text = g.text
            if type(text) ~= "string" and g.part and G.registry[g.part] then text = G.registry[g.part].text end
            if type(text) == "string" then len = #text end
        end
        local guess = (len > 0 and J.rate) and len * J.rate or (J.avg or 0)
        local big = len > A.IMPORT_MAX_TEXT
        if not big and done > 0 and clock() - t0 + guess > budget then break end
        J.pos = J.pos + 1
        if big then
            J.left = J.left + 1                 -- too long for one frame: left to the lazy path
        elseif g then
            done = done + 1
            local had = g.steps ~= nil
            local g0 = clock()
            local ok, steps
            if P and P.ReadSteps then ok, steps = pcall(P.ReadSteps, g, true) else ok, steps = pcall(G.Steps, gid) end
            if ok and type(steps) == "table" and #steps > 0 then
                local okM, n = pcall(A.Migrate, gid, steps)
                if okM and n > 0 then
                    J.records, J.guides = J.records + n, J.guides + 1
                    if P and P.guide == g then J.loaded = true end
                end
            end
            -- keep no step tables that were parsed only for this
            if not had and g.steps and not (P and P.guide == g) then g.steps = nil end
            local cost = clock() - g0
            J.avg = J.avg and (J.avg * 0.8 + cost * 0.2) or cost
            if len > 1000 then
                local r = cost / len
                J.rate = J.rate and (J.rate * 0.7 + r * 0.3) or r
            end
        end
        if clock() - t0 >= budget then break end
    end
    local spent = clock() - t0
    J.slices, J.cpu = J.slices + 1, J.cpu + spent
    if spent > J.maxSlice then J.maxSlice = spent end
    if J.sliceLog then J.sliceLog[#J.sliceLog + 1] = { spent, done, J.list[J.pos - 1] } end
    if J.pos > #J.list then finishImport(J) return false end
    return true
end
-- The frame's tick.  A slice that throws (damaged saved data) must not throw again every frame: the job is dropped
-- and the frame hidden; the flag stays unset, and loading or listing a guide still converts its marks.
function A.ImportTick()
    local ok, err = pcall(A.ImportStep)
    if ok then return true end
    imp = nil
    importFrame:Hide()
    A.importError = tostring(err)
    return false
end
importFrame:SetScript("OnUpdate", A.ImportTick)
-- Arm the import (once per character; opts.force: again, for tests).  opts.sliceLog: keep every slice's CPU.
function A.StartImport(opts)
    if imp then return imp end
    if not (A.me and NS.db and NS.db.char) then return nil end
    if NS.db.char.marksImported and not (opts and opts.force) then return nil end
    imp = { pos = 1, guides = 0, records = 0, slices = 0, cpu = 0, maxSlice = 0, left = 0, sliceLog = (opts and opts.sliceLog) and {} or nil }
    importFrame:Show()
    return imp
end
function A.ImportJob() return imp end
-- A character's done set for a guide, read only (nil when it has none)
local function doneSet(c, gid) return c.stepDone and c.stepDone[gid] or nil end
A.DoneSetOf = doneSet

-- Has this character any progress in the guide (keyed marks, or old marks not migrated yet)?
function A.Started(gid, c)
    c = c or A.me
    if not c then return false end
    if nonEmpty(doneSet(c, gid)) then return true end
    return not (c.stepMeta and c.stepMeta[gid]) and nonEmpty(c.done and c.done[gid])
end

-- Clear one guide's marks for this character (Progress.Reset, a new farm lap).  legacy: the old index-keyed tables
-- too (a reset the player asked for must not come back after a downgrade).
-- (CompletionRouteCharDB.done / skipped are the same tables as the record's since A.Init, and stay the real ones during
-- a scratch sweep, so they are only ever cleared through the record.  The reopened sets live in the character file and
-- are not part of the scratch store: a sweep leaves them alone.)
function A.ClearMarks(gid, legacy)
    if not A.me then return end
    A.me.stepDone[gid], A.me.stepSkipped[gid] = nil, nil
    local c = NS.db.char
    if c.stepReopened and not A.scratch then c.stepReopened[gid] = nil end
    if legacy then
        if A.me.done[gid] then A.me.done[gid] = {} end
        if A.me.skipped[gid] then A.me.skipped[gid] = {} end
        if c.reopened and c.reopened[gid] and not A.scratch then c.reopened[gid] = {} end
    end
end

-- Did ANY *other* character finish this step?  (never counts skips — a skip is a personal choice)
-- key: the step's stable key (step.key).
-- sc (optional): ask for one scope instead of the saved one (the self-test does; it must not touch the setting).
function A.OtherDid(guideid, key, sc)
    sc = sc or A.Scope()
    if sc == "char" or key == nil then return false end
    for k, c in pairs(NS.db.global.chars) do
        if k ~= A.key and A.CharInScope(k, c, sc) then
            local g = doneSet(c, guideid)
            if g and g[key] then return k end
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Quest-level union.  Step indices only line up inside one guide; quest IDs line up across
-- every guide and every source, so a quest an alt finished also clears the equivalent step in
-- a different guide covering the same content.
-- ---------------------------------------------------------------------------
function A.RecordQuest(qid)
    if qid and A.me then A.me.quests[qid] = true end
end

-- true if some OTHER character completed the quest(s) this step is for.
-- Honours the step's and/or semantics (|QID|1&2| = all, |QID|1^2| = any).
function A.OtherDidQuest(qids)
    if not A.Enabled() or not qids or not NS.db.profile.accountQuests then return false end
    local wantAll = qids.andor == "and"
    for k, c in pairs(NS.db.global.chars) do
        if k ~= A.key and c.quests and A.CharInScope(k, c) then
            local hit, all = false, true
            for _, q in ipairs(qids) do
                if c.quests[q] then hit = true else all = false end
            end
            if (wantAll and all) or (not wantAll and hit) then return k end
        end
    end
    return false
end

-- Per-guide completion, for the guide list / tooltips.
-- scope "char" = this character, "account" = union across the account.
-- keep (optional): the step keys still in the guide after quests were skipped (Core/Skip.lua ViewOf); ticks of steps
-- left out do not count, so the numbers match the rebuilt guide.  Without it, when the guide is parsed, only keys the
-- guide still has count (a tick of a step a data update removed does not).
function A.GuideProgress(guideid, total, scope, keep)
    if not total or total == 0 then return 0, 0 end
    local g = NS.Guide and NS.Guide.registry[guideid]
    if g and g.steps then
        A.Migrate(guideid, g.steps)
        keep = keep or NS.Guide.KeySet(g.steps)
    end
    local seen = {}
    local function eat(t) if t then for k in pairs(t) do if not keep or keep[k] then seen[k] = true end end end end
    if scope and scope ~= "char" then
        for k, c in pairs(NS.db.global.chars) do
            if A.CharInScope(k, c, scope) then eat(doneSet(c, guideid)) end
        end
    end
    eat(A.me.stepDone[guideid]); eat(A.me.stepSkipped[guideid])
    local n = 0
    for _ in pairs(seen) do n = n + 1 end
    if n > total then n = total end
    return n, math.floor(n / total * 100 + 0.5)
end

-- ---------------------------------------------------------------------------
-- Login sync: everything the game already knows this character has finished.
-- Completed quest IDs come straight from the client, so a guide picked up mid-way autofills, and
-- every other character on the account sees them too (their harvest happens when they log in).
-- ---------------------------------------------------------------------------
function A.HarvestCompleted(quiet)
    if not A.me then return 0 end
    local list
    if C_QuestLog and C_QuestLog.GetAllCompletedQuestIDs then
        local ok, r = pcall(C_QuestLog.GetAllCompletedQuestIDs) if ok then list = r end
    end
    if not list and GetQuestsCompleted then
        local ok, r = pcall(GetQuestsCompleted) if ok and type(r) == "table" then list = {} for q in pairs(r) do list[#list + 1] = q end end
    end
    local added = 0
    for _, q in ipairs(list or {}) do if not A.me.quests[q] then A.me.quests[q] = true added = added + 1 end end
    A.me.questCount = 0 for _ in pairs(A.me.quests) do A.me.questCount = A.me.questCount + 1 end
    A.me.harvested = date("%Y-%m-%d %H:%M:%S")
    A.ClearCompletionCaches()
    if added > 0 and not quiet then NS:Print(("Synced %d completed quest(s) from the game (%d known for this character)."):format(added, A.me.questCount)) end
    return added
end

-- Which character (if any) finished the WHOLE guide?  Whole = every quest the guide turns in is
-- complete for that character (or, for guides without quests, every step ticked). Partial progress
-- is never reported as complete.  Returns charkey, displayName or nil.
A.completedCache = {}

-- the quests a guide turns in (non-optional) — the yardstick for "finished"
local function guideQuests(steps)
    local qids, nq = {}, 0
    for _, s in ipairs(steps) do
        if (s.action == "T" or s.action == "t") and s.qid and not s.optional then
            for _, q in ipairs(s.qid) do if not qids[q] then qids[q] = true nq = nq + 1 end end
        end
    end
    return qids, nq
end
local function charFinished(ch, g, steps, qids, nq)
    if not ch or (ch.faction and g.faction and g.faction ~= "Both" and ch.faction ~= g.faction) then return false end
    if nq > 0 then
        if not ch.quests then return false end
        -- quests this character dropped (Core/Skip.lua) are not part of its guide any more, nor what this guide then
        -- can no longer offer
        local gone = (ch == A.me and NS.Skip and NS.Skip.Any()) and select(3, NS.Skip.Project(steps, nil, g.id)) or nil
        for q in pairs(qids) do if not ch.quests[q] and not (gone and gone[q]) then return false end end
        return true
    end
    local d = doneSet(ch, g.id)
    if not d then return false end
    local have, n = NS.Guide.KeySet(steps), 0
    for k in pairs(d) do if have[k] then n = n + 1 end end
    return n >= #steps
end

function A.GuideCompletedBy(g)
    if not g or not NS.db or not NS.db.global.chars then return nil end
    local c = A.completedCache[g.id]
    if c ~= nil then return c ~= false and c.key or nil, c ~= false and c.name or nil end
    local steps = g.steps or (NS.Guide and NS.Guide.Steps(g.id))
    if not steps or #steps == 0 then A.completedCache[g.id] = false return nil end
    local qids, nq = guideQuests(steps)
    if nq == 0 then A.Migrate(g.id, steps) end   -- a guide without quests is finished by its ticks
    -- this character first, then the others
    if charFinished(A.me, g, steps, qids, nq) then
        A.completedCache[g.id] = { key = A.key, name = A.me.name or A.key }
        return A.key, A.completedCache[g.id].name
    end
    for k, ch in pairs(NS.db.global.chars) do
        if k ~= A.key and charFinished(ch, g, steps, qids, nq) then
            A.completedCache[g.id] = { key = k, name = ch.name or k }
            return k, ch.name or k
        end
    end
    A.completedCache[g.id] = false
    return nil
end

-- Scope-aware "is this guide finished?" — by anyone the current scope covers.
A.doneCache = {}
function A.GuideIsComplete(g, scope)
    if not g or not A.me then return false end
    scope = scope or A.Scope()
    A.doneCache[scope] = A.doneCache[scope] or {}
    local cache = A.doneCache[scope]
    local hit = cache[g.id]
    if hit ~= nil then return hit end
    local steps = g.steps or (NS.Guide and NS.Guide.Steps(g.id))
    if not steps or #steps == 0 then cache[g.id] = false return false end
    local qids, nq = guideQuests(steps)
    if nq == 0 then A.Migrate(g.id, steps) end
    local ok = charFinished(A.me, g, steps, qids, nq)
    if not ok and scope ~= "char" then
        for k, ch in pairs(NS.db.global.chars) do
            if k ~= A.key and A.CharInScope(k, ch, scope) and charFinished(ch, g, steps, qids, nq) then ok = true break end
        end
    end
    cache[g.id] = ok
    return ok
end
function A.ClearCompletionCaches()
    A.completedCache = {}
    A.doneCache = {}
end

function A.Characters()
    local out = {}
    for k, c in pairs(NS.db.global.chars or {}) do
        -- keyed marks, plus old index-keyed ones of guides not migrated yet
        local steps, guides = 0, 0
        local function count(set) local n = 0 for _ in pairs(set) do n = n + 1 end return n end
        for _, set in pairs(c.stepDone or {}) do local n = count(set) steps = steps + n if n > 0 then guides = guides + 1 end end
        for gid, set in pairs(c.done or {}) do
            if not (c.stepMeta and c.stepMeta[gid]) then local n = count(set) steps = steps + n if n > 0 then guides = guides + 1 end end
        end
        out[#out + 1] = { key = k, name = c.name, realm = c.realm, class = c.class, faction = c.faction,
                          level = c.level, flavor = c.flavor, steps = steps, updated = c.updated, guides = guides }
    end
    table.sort(out, function(a, b) return (a.steps or 0) > (b.steps or 0) end)
    return out
end

function A.Forget(charkey)
    if NS.db.global.chars[charkey] and charkey ~= A.key then NS.db.global.chars[charkey] = nil return true end
    return false
end

NS:On("ADDON_READY", function() pcall(A.Init) end)
-- the completed-quest list is not always populated the instant we log in: harvest twice
NS:On("PLAYER_READY", function()
    -- Classic clients only fill GetQuestsCompleted() after QueryQuestsCompleted(); retail has neither
    if QueryQuestsCompleted then pcall(QueryQuestsCompleted) end
    NS:After(3, function() pcall(A.HarvestCompleted, true) if NS.Progress and NS.Progress.guide then NS.Progress.Refresh(true) end end)
    NS:After(20, function() pcall(A.HarvestCompleted, true) if NS.Progress and NS.Progress.guide then NS.Progress.Refresh(true) end end)
    -- every guide's old index marks, once per character (see "Every guide's old marks at once")
    NS:After(A.IMPORT_DELAY, function() pcall(A.StartImport) end)
end)
NS:RegisterEvent("QUEST_TURNED_IN", function(_, qid) if qid and A.me then A.me.quests[qid] = true A.completedCache = {} end end)
NS:RegisterEvent("QUEST_TURNED_IN", function(_, qid) A.RecordQuest(qid) end)
-- the server's completed-quest list arrived (classic): harvest it and let the loaded guide autofill
NS:RegisterEvent("QUEST_QUERY_COMPLETE", function() pcall(A.HarvestCompleted, true) if NS.Progress and NS.Progress.guide then NS.Progress.Refresh(true) end end)
NS:RegisterEvent("PLAYER_LEVEL_UP", function(_, lvl) if A.me then A.me.level = lvl or UnitLevel("player") end end)
-- a logout or /reload during a bulk sweep: the saved variables must hold the character's own marks, not the sweep's
NS:RegisterEvent("PLAYER_LOGOUT", function() A.EndScratch(true) end)
NS:RegisterEvent("PLAYER_LOGOUT", function() if A.me then A.me.updated = date("%Y-%m-%d %H:%M:%S") A.me.level = UnitLevel("player") end end)
