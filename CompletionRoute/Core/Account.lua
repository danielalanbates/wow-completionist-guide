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
    local base = NS.flavor or "?"
    return A.IsHardcore() and (base .. "-hardcore") or base
end
local GAMETYPE_NAME = { era = "Classic Era", tbc = "Anniversary (TBC)", wrath = "Wrath Classic", cata = "Cataclysm Classic",
                        mop = "Mists Classic", retail = "Modern (retail)" }
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
function A.BeginScratch()
    if A.scratch then return end
    A.scratch = { done = A.me.done, skipped = A.me.skipped }
    A.me.done, A.me.skipped = {}, {}
end
function A.EndScratch()
    if not A.scratch then return end
    A.me.done, A.me.skipped = A.scratch.done, A.scratch.skipped
    A.scratch = nil
end

function A.Done(guideid)
    A.me.done[guideid] = A.me.done[guideid] or {}
    return A.me.done[guideid]
end
function A.Skipped(guideid)
    A.me.skipped[guideid] = A.me.skipped[guideid] or {}
    return A.me.skipped[guideid]
end

-- Did ANY *other* character finish this step?  (never counts skips — a skip is a personal choice)
function A.OtherDid(guideid, index)
    if not A.Enabled() then return false end
    for k, c in pairs(NS.db.global.chars) do
        if k ~= A.key and A.CharInScope(k, c) then
            local g = c.done and c.done[guideid]
            if g and g[index] then return k end
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
function A.GuideProgress(guideid, total, scope)
    if not total or total == 0 then return 0, 0 end
    local seen = {}
    local function eat(t) if t then for i in pairs(t) do seen[i] = true end end end
    if scope and scope ~= "char" then
        for k, c in pairs(NS.db.global.chars) do
            if A.CharInScope(k, c, scope) then eat(c.done and c.done[guideid]) end
        end
        eat(A.me.done[guideid]); eat(A.me.skipped[guideid])
    else
        eat(A.me.done[guideid]); eat(A.me.skipped[guideid])
    end
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
        for q in pairs(qids) do if not ch.quests[q] then return false end end
        return true
    end
    local d = ch.done and ch.done[g.id]
    if not d then return false end
    local n = 0 for _ in pairs(d) do n = n + 1 end
    return n >= #steps
end

function A.GuideCompletedBy(g)
    if not g or not NS.db or not NS.db.global.chars then return nil end
    local c = A.completedCache[g.id]
    if c ~= nil then return c ~= false and c.key or nil, c ~= false and c.name or nil end
    local steps = g.steps or (NS.Guide and NS.Guide.Steps(g.id))
    if not steps or #steps == 0 then A.completedCache[g.id] = false return nil end
    local qids, nq = guideQuests(steps)
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
        local steps = 0
        for _, g in pairs(c.done or {}) do for _ in pairs(g) do steps = steps + 1 end end
        out[#out + 1] = { key = k, name = c.name, realm = c.realm, class = c.class, faction = c.faction,
                          level = c.level, flavor = c.flavor, steps = steps, updated = c.updated,
                          guides = (function() local n = 0 for _ in pairs(c.done or {}) do n = n + 1 end return n end)() }
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
