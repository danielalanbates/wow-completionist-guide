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
-- regenerated with lines added, removed or moved keeps every tick and skip on its step:
--   chars[k].stepDone[guide][key] = true       ticked (by hand or by the auto-completer)
--   chars[k].stepSkipped[guide][key] = true    skipped as a step (quest-level skips: Core/Skip.lua questSkip)
--   CompletionRouteCharDB.stepReopened[guide][key] = true   stepped back to (Progress.Undo)
--   chars[k].stepMeta[guide] = { v = key version, sum = Guide.GuideSum when last loaded or migrated,
--                                mig = old marks imported, lost = old marks that matched no step }
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
local SCRATCH = { "done", "skipped", "stepDone", "stepSkipped", "stepMeta" }
function A.BeginScratch()
    if A.scratch then return end
    A.scratch = {}
    for _, f in ipairs(SCRATCH) do A.scratch[f], A.me[f] = A.me[f], {} end
end
function A.EndScratch()
    if not A.scratch then return end
    for _, f in ipairs(SCRATCH) do A.me[f] = A.scratch[f] end
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
-- because the guide data has not been re-ordered since those marks were written (this is the first release with keys);
-- from here on keys carry the marks across data changes.  stepMeta[guide] records that it ran, so it never runs again:
-- marks a downgraded client later writes into the old tables, maybe on different data, are never mapped.
-- Characters other than the one logged in are migrated too (their marks count for account-wide progress), but only
-- those of this client's game type: a record copied in from another client by tools/sync_progress.lua was written
-- against that client's guide data, and its own client migrates it.  Access-chain steps (negative indices) are not
-- carried over: their numbers depended on which chains were locked at each load; their quests re-tick from the log.
local function baseType(t) return t and (t:gsub("%-hardcore$", "")) or nil end
local function migratable(c, k)
    if c == A.me or k == A.key then return true end
    if c.gametype then return baseType(c.gametype) == baseType(A.GameType()) end
    -- a record from before game types: its flavor, except "era", which Classic Era and WoW Forever both report
    return c.flavor ~= nil and c.flavor ~= "era" and c.flavor == NS.flavor and not NS.isForever
end
A.Migratable = migratable
-- author index -> key for the guide's own steps
local function indexMap(steps)
    local m = {}
    for _, s in ipairs(steps) do if (s.index or 0) > 0 and s.key then m[s.index] = s.key end end
    return m
end
-- Copy one old index-keyed set into a key set; returns copied, lost
local function importSet(old, dst, map)
    local n, lost = 0, 0
    for i, v in pairs(old) do
        local k = v and map[i]
        if k then
            if not dst[k] then dst[k] = true end
            n = n + 1
        elseif v then lost = lost + 1 end
    end
    return n, lost
end
local function nonEmpty(t) return t ~= nil and next(t) ~= nil end
-- c: one character record; me: it is the logged-in character (its reopened set lives in the character file)
local function migrateOne(c, gid, steps, me, touch, ctx)
    local meta = c.stepMeta and c.stepMeta[gid]
    if meta then
        if me and touch then
            local sum = ctx.sum()
            if sum and meta.sum ~= sum then meta.sum = sum end
        end
        return false
    end
    local od, osk = c.done and c.done[gid], c.skipped and c.skipped[gid]
    local ro = me and NS.db.char.reopened and NS.db.char.reopened[gid] or nil
    local has = nonEmpty(od) or nonEmpty(osk) or nonEmpty(ro)
    if not has and not (me and touch) then return false end
    c.stepDone, c.stepSkipped, c.stepMeta = c.stepDone or {}, c.stepSkipped or {}, c.stepMeta or {}
    meta = { v = NS.Guide.KEY_VERSION, sum = ctx.sum(), mig = 0 }
    if has then
        ctx.map = ctx.map or indexMap(steps)
        local lost = 0
        local function into(old, all)
            if not nonEmpty(old) then return end
            local dst = all[gid] or {}
            local n, l = importSet(old, dst, ctx.map)
            meta.mig, lost = meta.mig + n, lost + l
            if next(dst) then all[gid] = dst end
        end
        into(od, c.stepDone)
        into(osk, c.stepSkipped)
        if ro then
            NS.db.char.stepReopened = NS.db.char.stepReopened or {}
            into(ro, NS.db.char.stepReopened)
        end
        if lost > 0 then meta.lost = lost end
    end
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
    if migrateOne(A.me, gid, steps, true, touch, ctx) then n = n + 1 end
    for k, c in pairs(NS.db.global.chars or {}) do
        if c ~= A.me and k ~= A.key and type(c) == "table" and migratable(c, k) then
            if migrateOne(c, gid, steps, false, false, ctx) then n = n + 1 end
        end
    end
    return n
end
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
function A.OtherDid(guideid, key)
    if not A.Enabled() or key == nil then return false end
    for k, c in pairs(NS.db.global.chars) do
        if k ~= A.key and A.CharInScope(k, c) then
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
end)
NS:RegisterEvent("QUEST_TURNED_IN", function(_, qid) if qid and A.me then A.me.quests[qid] = true A.completedCache = {} end end)
NS:RegisterEvent("QUEST_TURNED_IN", function(_, qid) A.RecordQuest(qid) end)
-- the server's completed-quest list arrived (classic): harvest it and let the loaded guide autofill
NS:RegisterEvent("QUEST_QUERY_COMPLETE", function() pcall(A.HarvestCompleted, true) if NS.Progress and NS.Progress.guide then NS.Progress.Refresh(true) end end)
NS:RegisterEvent("PLAYER_LEVEL_UP", function(_, lvl) if A.me then A.me.level = lvl or UnitLevel("player") end end)
NS:RegisterEvent("PLAYER_LOGOUT", function() if A.me then A.me.updated = date("%Y-%m-%d %H:%M:%S") A.me.level = UnitLevel("player") end end)
