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
    me.level = UnitLevel("player")
    me.updated = date("%Y-%m-%d %H:%M:%S")
    A.me = me
    -- the character SV keeps settings only from here on
    NS.db.char.done, NS.db.char.skipped = me.done, me.skipped
end

function A.Enabled() return NS.db and NS.db.profile.accountWide and true or false end

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
        if k ~= A.key then
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
        if k ~= A.key and c.quests then
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
    if scope == "account" then
        for _, c in pairs(NS.db.global.chars) do eat(c.done and c.done[guideid]) end
    else
        eat(A.me.done[guideid]); eat(A.me.skipped[guideid])
    end
    local n = 0
    for _ in pairs(seen) do n = n + 1 end
    if n > total then n = total end
    return n, math.floor(n / total * 100 + 0.5)
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
NS:RegisterEvent("QUEST_TURNED_IN", function(_, qid) A.RecordQuest(qid) end)
NS:RegisterEvent("PLAYER_LEVEL_UP", function(_, lvl) if A.me then A.me.level = lvl or UnitLevel("player") end end)
NS:RegisterEvent("PLAYER_LOGOUT", function() if A.me then A.me.updated = date("%Y-%m-%d %H:%M:%S") A.me.level = UnitLevel("player") end end)
