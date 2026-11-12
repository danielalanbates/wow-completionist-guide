-- CompletionRoute :: Core/Progress.lua
-- Tracks the active guide: which steps are done/skipped, auto-completion from game events,
-- and exposes the ordered list of upcoming steps (after the route optimizer has its say).
local ADDON, NS = ...
local U, Cond, G = NS.Util, NS.Cond, NS.Guide
local Sig = NS.StepSignal       -- Core/Guide.lua: what a step names (NPC, items) and which rule finishes it
local P = {}
NS.Progress = P

P.guide = nil        -- guide record
P.steps = nil        -- parsed steps (original order)
P.order = nil        -- array of step indices in display order (optimizer output)
P.current = nil      -- current step table
local dirty = true

-- Marks are sets keyed by the step's stable key, step.key (Core/Guide.lua "Stable step keys"; stored by
-- Core/Account.lua, which also migrates the author-index tables of earlier releases).  Without the account store (a
-- harness that does not load it) they live in the character file under the same names.
local function localSet(field, id)
    local c = NS.db.char
    c[field] = c[field] or {}
    c[field][id] = c[field][id] or {}
    return c[field][id]
end
local function charDone()
    if NS.Account and NS.Account.me then return NS.Account.Done(P.guide.id) end
    return localSet("stepDone", P.guide.id)
end
-- Steps the player manually stepped BACK to. Auto-completion must not immediately re-tick them,
-- otherwise the Back arrow looks like it does nothing (the quest is still complete in the game).
local function charReopened()
    if NS.Account and NS.Account.Reopened then return NS.Account.Reopened(P.guide.id) end
    return localSet("stepReopened", P.guide.id)
end
local function charSkipped()
    if NS.Account and NS.Account.me then return NS.Account.Skipped(P.guide.id) end
    return localSet("stepSkipped", P.guide.id)
end
-- The loaded guide's mark sets (read them, or write a step's key into them): done, skipped, reopened
function P.MarkSets()
    if not P.guide then return {}, {}, {} end
    return charDone(), charSkipped(), charReopened()
end
-- /cr marks: how the loaded guide's progress is stored, in words (for a beta report after a data update)
function P.MarksReport()
    if not (P.guide and P.steps) then return { "No guide loaded." } end
    local d, s, r = P.MarkSets()
    local have = {}
    for _, st in ipairs(P.baseSteps or P.steps) do if st.key then have[st.key] = true end end
    local function split(set)
        local n, gone = 0, 0
        for k in pairs(set) do if have[k] then n = n + 1 else gone = gone + 1 end end
        return n, gone
    end
    local nd, gd = split(d)
    local ns, gs = split(s)
    local nr = split(r)
    local out = { ("%s: %d done, %d skipped, %d stepped back to, stored by step key (version %d)."):format(P.guide.name or P.guide.id, nd, ns, nr,
        G.KEY_VERSION) }
    if gd + gs > 0 then
        out[#out + 1] = ("%d mark%s to steps this version of the guide no longer has; %s nowhere."):format(gd + gs,
            gd + gs == 1 and " belongs" or "s belong", gd + gs == 1 and "it counts" or "they count")
    end
    local meta = NS.Account and NS.Account.me and NS.Account.me.stepMeta and NS.Account.me.stepMeta[P.guide.id]
    if meta and (meta.mig or 0) > 0 then
        out[#out + 1] = ("Carried over from the previous release (by step position): %d mark%s%s."):format(meta.mig, meta.mig == 1 and "" or "s",
            (meta.lost or 0) > 0 and (", %d without a matching step"):format(meta.lost) or "")
    elseif meta then
        out[#out + 1] = "No marks from the previous release for this guide."
    end
    out[#out + 1] = "Guide version (step key checksum): " .. tostring(G.GuideSum(P.guide.id))
    return out
end

-- ---------------------------------------------------------------------------
-- Recently used routes (the "Recent" section on top of the routes list, UI/GuideMenu.lua)
-- ---------------------------------------------------------------------------
-- CompletionRouteCharDB.recent[guide id] = { s = sequence number (larger = more recent), t = wall time, n = steps in
-- the route when it was last loaded }.  Written when the player picks a route and whenever a step of the loaded route
-- is finished; never by the chain walking through finished routes at login, and never by a bulk sweep.  The list is
-- built from this table alone (no guide is parsed for it), and it is in the character's saved variables, so it
-- survives /reload.  At most RECENT_KEEP records are kept; the list shows RECENT_SHOWN.
local RECENT_KEEP, RECENT_SHOWN = 30, 12
P.RECENT_SHOWN = RECENT_SHOWN
local function wallTime() if time then return time() end if os and os.time then return os.time() end return 0 end
local function recentStore()
    local c = NS.db.char
    if c.recent then return c.recent end
    local A = NS.Account
    -- the character's record is not open yet, or a bulk sweep has swapped it for an empty one: nothing to seed from,
    -- try again later
    if A and (not A.me or A.scratch) then return {} end
    c.recent, c.recentSeq = {}, 0
    -- First run of this feature: the routes this character already has finished steps in start the list, the ones
    -- with the most finished steps on top (when they were played is not known).
    local sets = A and A.me and A.me.stepDone
    if sets then
        local ids = {}
        for gid, set in pairs(sets) do
            local n = 0
            for _ in pairs(set) do n = n + 1 end
            if n > 0 and type(gid) == "string" then ids[#ids + 1] = { gid, n } end
        end
        table.sort(ids, function(a, b) if a[2] ~= b[2] then return a[2] < b[2] end return a[1] > b[1] end)
        for i = math.max(1, #ids - RECENT_KEEP + 1), #ids do
            c.recentSeq = c.recentSeq + 1
            c.recent[ids[i][1]] = { s = c.recentSeq, t = 0 }
        end
        -- the route that is loaded right now is the one in use: on top
        local cur = c.guide and c.recent[c.guide]
        if cur then c.recentSeq = c.recentSeq + 1 cur.s = c.recentSeq end
    end
    return c.recent
end
function P.TouchRecent(id, total)
    if not (NS.db and NS.db.char and id) then return end
    if NS.Account and NS.Account.scratch then return end
    local store = recentStore()
    local c = NS.db.char
    if store ~= c.recent then return end
    local r = store[id]
    -- already the newest record: nothing to write (every finished step of the route being played lands here)
    if r and r.s == c.recentSeq and (not total or total <= 0 or r.n == total) then return end
    if not r then r = {} store[id] = r end
    c.recentSeq = (c.recentSeq or 0) + 1
    r.s, r.t = c.recentSeq, wallTime()
    if total and total > 0 then r.n = total end
    -- keep the table small: drop the oldest records beyond RECENT_KEEP
    local count = 0
    for _ in pairs(store) do count = count + 1 end
    while count > RECENT_KEEP do
        local oldest, at
        for gid, rec in pairs(store) do if not at or (rec.s or 0) < at then oldest, at = gid, rec.s or 0 end end
        if not oldest then break end
        store[oldest] = nil
        count = count - 1
    end
end
-- Finished-step count of a route for this character without parsing it: its done and skipped marks (a circuit's
-- marks are wiped every lap, so its laps count as progress too)
local function markCount(id)
    local A = NS.Account
    local n = 0
    if A and A.me then
        for _, set in ipairs({ A.me.stepDone[id] or false, A.me.stepSkipped[id] or false }) do
            if set then for _ in pairs(set) do n = n + 1 end end
        end
    else
        local c = NS.db.char
        for _, f in ipairs({ "stepDone", "stepSkipped" }) do
            if c[f] and c[f][id] then for _ in pairs(c[f][id]) do n = n + 1 end end
        end
    end
    return n
end
P.MarkCount = markCount
-- Does this character have any mark in the route?  One table read, nothing counted (the list asks for every record).
local function hasMarks(id)
    local A = NS.Account
    if A and A.me then
        local d, s = A.me.stepDone[id], A.me.stepSkipped[id]
        return (d ~= nil and next(d) ~= nil) or (s ~= nil and next(s) ~= nil)
    end
    local c = NS.db.char
    for _, f in ipairs({ "stepDone", "stepSkipped" }) do
        if c[f] and c[f][id] and next(c[f][id]) ~= nil then return true end
    end
    return false
end
-- The routes this character has finished at least one step in, most recently used first: { { g = guide, total = } }.
-- Costs one pass over the saved records (at most RECENT_KEEP) and a sort of them: no guide is parsed and no mark is
-- counted, so the list opens as fast as it did without the section.  A record whose route is gone from this version
-- of the data is passed over (and ages out of the table).
function P.RecentList(limit)
    local out = {}
    if not (NS.db and NS.db.char) then return out end
    local store = recentStore()
    local rows = {}
    for id, rec in pairs(store) do
        local g = type(rec) == "table" and G.registry[id]
        if g and not g.empty and (hasMarks(id) or P.Lap(id) > 0) then rows[#rows + 1] = { g = g, total = rec.n, s = rec.s or 0 } end
    end
    table.sort(rows, function(a, b) if a.s ~= b.s then return a.s > b.s end return a.g.id < b.g.id end)
    for i = 1, math.min(limit or RECENT_SHOWN, #rows) do out[i] = rows[i] end
    return out
end
-- The saved record of one route (its step total when last loaded), for the list's progress column
function P.RecentRecord(id) local c = NS.db and NS.db.char return c and c.recent and c.recent[id] or nil end

function P.Load(id)
    local g = G.registry[id]
    if not g then NS:Error("Unknown guide: " .. tostring(id)) return false end
    -- the player picked this guide (the chain sets P.chainLoading): any detour back to a parked guide is over
    if not P.chainLoading then NS.db.char.parkReturn = nil end
    P.guide = g
    -- Gold guides are routes, not checklists: fold one into a circuit before its steps are read
    -- (Core/Farm.lua Circuitize). Turn it off with /cr farm circuit, or per guide with /cr farm uncircuit.
    if g.type == "Gold" and not g.loop and not g.noCircuit and NS.db.profile.farm and NS.db.profile.farm.circuitizeGold then
        local ok, res, n = pcall(NS.Farm.Circuitize, g)
        if ok and res then NS:Print(("Gold guide folded into a %d-stop circuit - just follow it, nothing to click."):format(n))
        else g.noCircuit = true NS:Debug("circuitize " .. id .. ": " .. tostring(res or n)) end
    end
    P.steps = G.Steps(id)
    P.finishedNotice = nil
    P.altInst = nil
    P.ResolveAlts()
    -- Behind a locked access chain (Siren Isle, Argus, Zereth Mortis...)? Put the unlock steps first, the way
    -- comprehensive zone guides open with the zone intro. Negative indices and "@chain/" step keys keep the guide's own apart.
    local prefix = NS.Access and NS.Access.PrefixFor(P.steps, id)
    if prefix and #prefix > 0 then
        local merged = {}
        for _, s in ipairs(prefix) do merged[#merged + 1] = s end
        for _, s in ipairs(P.steps) do merged[#merged + 1] = s end
        P.steps = merged
        NS:Print(("Access: %d steps to unlock %s first"):format(#prefix, prefix[1].accessTitle or "the area"))
    end
    -- progress of earlier releases is keyed by author index: carry it over to step keys, once per guide (Core/Account.lua)
    if NS.Account and NS.Account.me and NS.Account.Migrate then NS.Account.Migrate(id, P.steps, true) end
    -- Quests this character dropped (/cr skip, Core/Skip.lua) leave every guide: show the guide rebuilt without them.
    -- P.baseSteps keeps the guide's own list; progress stays keyed by step key either way.
    if NS.Replan then NS.Replan.Cancel() end
    P.baseSteps = P.steps
    local cut, key
    P.steps, cut, key = P.Rebuilt(P.baseSteps)
    NS.db.char.guide = id
    dirty = true
    P.cursor = nil
    if NS.StepOrder and NS.StepOrder.Reset then NS.StepOrder.Reset() end
    NS:Print("Guide: " .. (g.name or g.id) .. " (" .. #P.steps .. " steps, from " .. (g.source or "?") .. ")"
        .. ((cut or 0) > 0 and (", %d left out for skipped quests"):format(cut) or ""))
    -- Recent: a route the player picked goes to the top; one the chain walked into only keeps its step total current
    if not P.chainLoading then P.TouchRecent(id, #P.steps)
    else local rec = P.RecentRecord(id) if rec then rec.n = #P.steps end end
    P.fresh = true      -- the refresh below is the catch-up of a fresh load, not progress (see P.Refresh)
    P.Refresh()
    -- opened for the first time since quests were dropped from it: re-plan it once (the decision is saved)
    if (cut or 0) > 0 and P.guide == g and NS.Skip and not NS.Skip.HasPlan(g.id, key) then P.StartReplan(key) end
    if g.loop then
        if NS.Farm and NS.Farm.OnLoad then pcall(NS.Farm.OnLoad, g) end
        P.StartAtNearest()
    end
    NS:Fire("GUIDE_LOADED", g)
    return true
end

-- ---------------------------------------------------------------------------
-- Rebuilt guides (quest-level skips, Core/Skip.lua)
-- ---------------------------------------------------------------------------
-- The guide as this character sees it: its own steps minus every dropped or locked quest, in the re-planned order
-- saved for exactly that set (if any).  Returns list, steps left out, rebuild key.
function P.Rebuilt(base)
    local Sk = NS.Skip
    if not (Sk and base) or (P.guide and P.guide.loop) then return base, 0, nil end
    return Sk.Rebuild(base, P.guide and P.guide.id)
end

-- Rebuild the loaded guide after quests were dropped or brought back: same steps minus the removed quests, the current
-- step re-chosen by the route at once (the arrow follows), then a whole-guide re-plan in the background.
function P.Rebuild(noReplan)
    if not (P.guide and P.baseSteps) then return end
    local g, old = P.guide, P.steps
    if NS.Replan then NS.Replan.Cancel() end
    local list, cut, key = P.Rebuilt(P.baseSteps)
    P.steps = list
    P.cursor = nil
    dirty = true
    if NS.StepOrder and NS.StepOrder.Reset then NS.StepOrder.Reset() end
    if NS.Router and NS.Router.Invalidate then NS.Router.Invalidate() end
    -- the step set changed (a drop, or an unskip giving steps back): re-plan, unless this exact rebuild was decided before
    local changed = #old ~= #list
    if not changed then
        local was = {}
        for _, s in ipairs(old) do was[s] = true end
        for _, s in ipairs(list) do if not was[s] then changed = true break end end
    end
    NS:Fire("GUIDE_REBUILT", g, cut)
    P.Refresh()
    if not noReplan and changed and P.guide == g and P.steps == list and not (g.loop or (NS.Skip and NS.Skip.HasPlan(g.id, key))) then
        P.StartReplan(key or (NS.Skip and NS.Skip.PlanKey(P.baseSteps, nil, g.id)))
    end
end

-- Whole-guide travel-time re-plan (Routing/Replan.lua), time-sliced; the result is saved under the rebuild key so a
-- /reload shows the same order without re-planning.
function P.StartReplan(key)
    local RPn = NS.Replan
    if not (RPn and P.guide and P.steps and NS.Router) or P.guide.loop then return end
    -- a bulk sweep (/cr verifyall) loads every guide in a row: nothing to plan for
    if NS.Account and NS.Account.scratch then return end
    local g, list = P.guide, P.steps
    return RPn.Start({ guide = g.id, list = list, key = key, onDone = function(res)
        if not res then return end
        local Sk = NS.Skip
        local t = Sk and Sk.Store(true)
        if t and key then t.plans[g.id] = { k = key, o = res.accepted and Sk.EncodeOrder(res.list) or false } end
        if res.accepted and P.guide == g and P.steps == list then
            P.steps = res.list
            P.cursor = nil
            dirty = true
            -- the live window starts over from the new order; its kept travel costs (same steps) stay valid
            if NS.StepOrder then NS.StepOrder.plan = nil end
            NS:Debug(("re-plan: %s %.0fs -> %.0fs"):format(g.id, res.baseCost, res.newCost))
            P.Refresh()
        end
    end })
end

-- How many steps of the list on screen are ticked done (ticks of steps left out for skipped quests do not count)
function P.VisibleDone()
    if not (P.guide and P.steps) then return 0 end
    local d = charDone()
    local n = 0
    for _, s in ipairs(P.steps) do if d[s.key] then n = n + 1 end end
    return n
end

function P.IsDone(step)
    local k = step.key
    if k == nil then return false end   -- not a parsed guide step
    if charReopened()[k] then return false end
    if charDone()[k] or charSkipped()[k] then return true end
    -- opt-in: a step another character already finished counts as done for this one
    if NS.Account and NS.Account.Enabled() and P.guide then
        if NS.Account.OtherDid(P.guide.id, k) then return true end
        -- quest IDs line up across guides; step keys only line up inside one guide
        if step.qid and NS.Account.OtherDidQuest(step.qid) then return true end
    end
    return false
end
function P.MarkDone(step, manual)
    if not (step and step.key) then return end
    charReopened()[step.key] = nil
    charDone()[step.key] = true
    if (step.action == "T" or step.action == "t") and step.qid and NS.Account then
        for _, q in ipairs(step.qid) do NS.Account.RecordQuest(q) end
    end
    dirty = true
    NS:Debug("done: " .. step.action .. " " .. step.title)
    -- manual = the forward arrow (or a menu click); wasCurrent = it was the step on screen (Core/Contribute.lua)
    NS:Fire("STEP_DONE", step, manual and true or false, step == P.current)
    if P.guide then P.TouchRecent(P.guide.id, P.steps and #P.steps) end
    P.Refresh()
end
function P.Skip(step) if step and step.key then charReopened()[step.key] = nil charSkipped()[step.key] = true dirty = true P.Refresh() end end
-- The loaded guide's per-step skip marks ([step key] = true, Core/Guide.lua G.AssignKeys), in the store the progress
-- scope reads (Core/QuestAuto.lua: a quest whose accept or turn-in step the player skipped is never done for them).
function P.SkippedMarks() if not P.guide then return nil end return charSkipped() end
-- Back one step: reopen the newest done/skipped step that sits BEFORE the current one.  The look-ahead
-- auto-completer ticks steps up to 40 ahead, so "the highest done index" is often a future step; using it
-- made Back appear to do nothing.  Reopened steps are pinned (see charReopened) until ticked forward again.
function P.Undo()
    local d, s = charDone(), charSkipped()
    -- "before" = earlier in the displayed step list, which is not author order once a baked route order
    -- (Data/RouteOrder_<flavor>.lua) has permuted the guide; keys only identify the step.  A mark whose step is not on
    -- screen (left out of a guide rebuilt without skipped quests, Core/Skip.lua, or gone from the guide in a data
    -- update) is never reopened.
    local pos = {}
    for k, st in ipairs(P.steps or {}) do if st.key then pos[st.key] = k end end
    local limit = P.current and pos[P.current.key] or math.huge
    local best, bestAt
    local function consider(key, below)
        local at = pos[key]
        if at and (not below or at < limit) and (not bestAt or at > bestAt) then best, bestAt = key, at end
    end
    for key in pairs(d) do consider(key, true) end
    for key in pairs(s) do consider(key, true) end
    if not best then   -- nothing before the current step: fall back to the newest done step anywhere
        for key in pairs(d) do consider(key, false) end
        for key in pairs(s) do consider(key, false) end
    end
    if not best then return end
    charReopened()[best] = true
    P.cursor = nil
    -- the live plan does not know the reopened step: back to the baked order, where it is the earliest pending step
    if NS.StepOrder and NS.StepOrder.Reset then NS.StepOrder.Reset() end
    d[best] = nil s[best] = nil
    dirty = true
    P.Refresh()
end
-- Forward one step by hand (same as the arrow): tick the current step done.
function P.Forward() if P.current then P.MarkDone(P.current, true) end end
-- Forget one guide's marks, the old index-keyed tables included (a reset must not come back after a downgrade)
local function clearMarks(id)
    if NS.Account and NS.Account.me then NS.Account.ClearMarks(id, true)
    else
        local c = NS.db.char
        for _, f in ipairs({ "stepDone", "stepSkipped", "stepReopened" }) do if c[f] then c[f][id] = nil end end
        if c.done then c.done[id] = {} end
        if c.skipped then c.skipped[id] = {} end
        if c.reopened then c.reopened[id] = {} end
    end
end
P.ClearMarks = clearMarks
-- /cr reset and Start over: forget the loaded route's marks for this character and go back to its first step.  What
-- the game itself reports as done (a finished quest, a reached skill, items in the bags) ticks again at once.
function P.Reset()
    if not P.guide then return end
    clearMarks(P.guide.id)
    if NS.db.char.parked then NS.db.char.parked[P.guide.id] = nil end
    -- what events left on the step tables (hearth bound, flight map seen, item held) is progress too: without this a
    -- "set hearth" step finished itself again the moment the route started over
    for _, st in ipairs(P.baseSteps or P.steps or {}) do
        st.bindDone, st.taxiDone, st.hadItem = nil, nil, nil
    end
    P.finishedNotice = nil
    dirty = true
    P.cursor = nil
    if NS.StepOrder and NS.StepOrder.Reset then NS.StepOrder.Reset() end
    if NS.Router and NS.Router.Invalidate then NS.Router.Invalidate() end
    P.Refresh()
end
-- The Start over button (step window, its menus): P.Reset plus a line of chat.  Returns true when a route was reset.
function P.StartOver()
    if not P.guide then return false end
    local g = P.guide
    P.Reset()
    if P.guide == g then
        P.TouchRecent(g.id, P.steps and #P.steps)
        NS:Print(("Started over: %s. Steps the game reports as done tick again by themselves."):format(g.name or g.id))
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Auto-completion logic per action
-- ---------------------------------------------------------------------------
local function anyQuestDone(qids, fn)
    if not qids then return false end
    if qids.andor == "and" then for _, q in ipairs(qids) do if not fn(q) then return false end end return true end
    for _, q in ipairs(qids) do if fn(q) then return true end end
    return false
end
P.anyQuestDone = anyQuestDone

local function nearCoords(step, radius)
    if not step.coords or not step.zone then return false end
    local map, x, y = U.PlayerPos()
    if not map then return false end
    for _, c in ipairs(step.coords) do
        local d = U.ZoneDistance(map, x, y, step.zone, c.x, c.y)
        if d and d < (radius or 40) then return true end
    end
    return false
end
-- R step with alternatives ("Visit the bank": six banks): standing at ANY of them is having arrived, not only at the
-- one the engine chose as cheapest
local function nearAnyAlt(step, radius)
    local map, x, y = U.PlayerPos()
    if not map then return false end
    for _, a in ipairs(step.alts) do
        local d = U.ZoneDistance(map, x, y, a.map, a.x, a.y)
        if d and d < (radius or 30) then return true end
    end
    return false
end
local function inZone(step)
    if not step.zone then return false end
    local map = U.PlayerPos()
    if map == step.zone then return true end
    -- allow parent (e.g. city inside continent) equality
    local info = map and C_Map.GetMapInfo(map)
    return info and info.parentMapID == step.zone
end

-- SKILL|Cooking;75| reached?  An unknown skill (Core/Professions.lua returns nil) is never "reached".
function P.SkillMet(sk)
    local Prof = NS.Professions
    if not Prof then return false end
    local rank = Prof.Skill(sk.name, sk.tier)
    return rank ~= nil and rank >= sk.target
end

-- returns true if step is (now) complete or obsolete
function P.CheckStep(step)
    -- Profession steps finish on what the character can do, whatever their action letter (either tag is enough)
    if step.skill and P.SkillMet(step.skill) then return true end
    if step.recipe and NS.Professions and NS.Professions.KnowsSpell(step.recipe) then return true end
    local a = step.action
    if a == "A" or a == "a" or a == "!" then
        if step.qid and anyQuestDone(step.qid, function(q) return U.IsOnQuest(q) or U.IsQuestComplete(q) end) then return true end
    elseif a == "T" or a == "t" then
        if step.qid and anyQuestDone(step.qid, U.IsQuestComplete) then return true end
    elseif a == "C" or a == "K" or a == "l" then
        if step.qid then
            if anyQuestDone(step.qid, U.IsQuestComplete) then return true end
            -- on quest & objectives done
            local allon = true
            for _, q in ipairs(step.qid) do
                if U.IsOnQuest(q) then
                    local idx, complete = U.QuestLogState(q)
                    if complete then return true end
                    if step.qo then
                        -- specific objective index e.g. "1" or "Kill x"
                        local oi = tonumber(step.qo)
                        if oi then local f, r, fin = U.QuestObjective(q, oi) if fin or (r and r > 0 and f >= r) then return true end end
                    else
                        if U.AllObjectivesDone(q) then return true end
                    end
                else allon = false end
            end
        end
        if step.loot and not step.qid then
            local ok = true
            for _, l in ipairs(step.loot) do if U.ItemCount(l.id) < l.qty then ok = false end end
            if ok then return true end
        end
    elseif a == "G" then
        -- farm waypoint: nothing to click, you complete it by standing there
        if step.coords then if nearCoords(step, step.radius or (NS.db.profile.farm and NS.db.profile.farm.radius) or 40) then return true end
        elseif inZone(step) then return true end
    elseif a == "R" then
        -- "R Stormwind City" means reach the zone, not the author's sample coordinate inside it
        local dest = step.title and U.MapIDByName(step.title)
        if dest and inZone({ zone = dest }) then return true end
        if step.coords then if nearCoords(step, 30) then return true end
        elseif inZone(step) then return true end
        -- only for the step on screen: a list of twenty banks is not worth pricing for every step of the look-ahead
        if step.alts and step == P.current and nearAnyAlt(step, 30) then return true end
    elseif a == "P" then
        -- Portal step: completed if the player has entered the destination zone, OR is within portal range
        local map = U.PlayerPos()
        if step.zone and map and map ~= step.zone then
            local targetMap = step.title and U.MapIDByName(step.title)
            if not targetMap or map == targetMap or inZone({ zone = targetMap }) then
                return true
            end
        end
        if step.coords and nearCoords(step, 30) then return true end
    elseif a == "F" or a == "b" or a == "J" or a == "H" or a == "D" then
        if step.coords then if nearCoords(step, 60) then return true end
        elseif step.zone and inZone(step) then return true end
    elseif a == "L" then
        if step.minlevel and U.PlayerLevel() >= step.minlevel then return true end
    elseif a == "U" then
        if step.item and step.hadItem and U.ItemCount(step.item) == 0 then return true end
        if step.item and U.ItemCount(step.item) > 0 then step.hadItem = true end
        if step.qid then
            if anyQuestDone(step.qid, U.IsQuestComplete) then return true end
            -- Imported "use" lines complete on quest objective progress (their |q qid/obj goal),
            -- not on turn-in: mirror the C branch
            for _, q in ipairs(step.qid) do
                if U.IsOnQuest(q) then
                    local _, complete = U.QuestLogState(q)
                    if complete then return true end
                    local oi = tonumber(step.qo)
                    if oi then
                        local f, r, fin = U.QuestObjective(q, oi)
                        if fin or (r and r > 0 and f >= r) then return true end
                    elseif U.AllObjectivesDone(q) then return true end
                end
            end
        end
        if step.loot then
            local ok = true
            for _, l in ipairs(step.loot) do if U.ItemCount(l.id) < l.qty then ok = false end end
            if ok then return true end
        end
    elseif a == "B" then
        if step.loot then local ok = true for _, l in ipairs(step.loot) do if U.ItemCount(l.id) < l.qty then ok = false end end if ok then return true end end
        -- a buy step that names its item with U / ITEM instead of L: the item is in the bags (COUNT of them)
        if Sig.BuyHeld(step, U.ItemCount) then return true end
    elseif a == "h" then
        if step.bindDone then return true end
    elseif a == "f" then
        if step.taxiDone then return true end
    end
    -- achievement steps (tools/gen_completion_guides.py): done when the client says the achievement,
    -- or the named criteria-tree node, is earned.  Clients without achievements answer nil -> manual.
    if step.ach and U.AchievementDone(step.ach, step.achCrit) then return true end
    -- generic: quest already complete => step obsolete
    if step.qid and (a ~= "A" and a ~= "a") and anyQuestDone(step.qid, U.IsQuestComplete) then return true end
    -- Items (2026-11-12): any step but an accept or a turn-in that carries L counts is done when the bags hold them
    -- (C / K / l without a quest, U and B had this already).  With a quest id the count only speaks while the
    -- character is on that quest: before that the quest log has nothing to say and the accept comes first anyway.
    if step.loot and not Sig.ACCEPT[a] and not Sig.TURNIN[a] and Sig.BagsHold(step, U.ItemCount)
        and (not step.qid or anyQuestDone(step.qid, U.IsOnQuest)) then return true end
    -- (talking to the step's NPC, a merchant on a repair/sell step, loot at a treasure's spot and a mission's
    -- success are events, not states: their handlers are under "Events that can complete steps")
    return false
end

-- ---------------------------------------------------------------------------
-- ALT steps (every usable trainer...): keep the step pointing at the cheapest alternative for this character
-- ---------------------------------------------------------------------------
-- Runs when a guide loads and whenever the player's continent changes.  The same place often appears in many steps
-- (one trainer per rank), so each location is priced once per pass.  A place the graph cannot reach is left out; when
-- nothing can be priced at all (no position yet) the step keeps its current choice.
function P.ResolveAlts()
    P.hasAlts = false
    if not (P.steps and NS.Router) then return end
    local _, _, _, inst = U.PlayerPos()
    local price, changed = {}, false
    for _, s in ipairs(P.steps) do
        if s.alts then
            P.hasAlts = true
            local best, bestCost
            for _, a in ipairs(s.alts) do
                local key = a.map .. ":" .. a.x .. ":" .. a.y
                local cost = price[key]
                if cost == nil then
                    local ok, secs = pcall(NS.Router.TravelSecondsFromPlayer, { coords = { { x = a.x, y = a.y } }, zone = a.map })
                    cost = (ok and secs) or false
                    price[key] = cost
                end
                if cost and (not bestCost or cost < bestCost) then best, bestCost = a, cost end
            end
            if best and best ~= s.altChosen then
                s.altChosen, s.altName = best, best.name
                s.coords = { { x = best.x, y = best.y } }
                s.zone, s.zoneName, s.zoneInherited = best.map, U.MapName(best.map), nil
                s._wx, s._wy, s._winst, s._zwx, s._zwy, s._zwinst, s._locSource, s._entrance = nil
                if NS.StepOrder and NS.StepOrder.Reset then NS.StepOrder.Reset() end   -- kept travel costs moved with it
                if s == P.current then changed = true end
            end
        end
    end
    if inst then P.altInst = inst end
    if changed then
        if NS.Router.Invalidate then NS.Router.Invalidate() end
        NS:Fire("STEP_CHANGED", P.current)
    end
end

-- ---------------------------------------------------------------------------
-- Ordering / current step
-- ---------------------------------------------------------------------------
-- pending = applicable, not done steps in guide order
-- The leading run of finished steps is skipped with a cursor.  Refresh calls this up to 25 times per
-- pass, and a retail zone guide is ~1,800 steps: without the cursor every call re-walks the whole
-- completed prefix, which is quadratic in the guide and hitches the client late in a long guide.
-- Only DONE steps advance the cursor - a step can be inapplicable now (level gate, PRE quest) and
-- applicable later, so those must stay in front of it.  Anything that un-completes a step resets it.
function P.Pending(limit)
    local out = {}
    if not P.steps then return out end
    local i = P.cursor or 1
    while i <= #P.steps and P.IsDone(P.steps[i]) do i = i + 1 end
    P.cursor = i
    for k = i, #P.steps do
        local s = P.steps[k]
        if not P.IsDone(s) and Cond.StepApplies(s) then
            out[#out + 1] = s
            if limit and #out >= limit then break end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Parked guides: steps held back by a level gate
-- ---------------------------------------------------------------------------
-- A wide-band guide (the spine's "Darnassus Quests 1-50") holds quests from level 10 to 54.  Early on, most of them
-- are behind their |LVL| gate, the pending list runs dry and the chain moves on, and nothing ever came back for the
-- rest.  Now such a guide is PARKED with the lowest level that opens one of its remaining steps.  It comes back only
-- at a natural transition: when the guide in progress has finished (or a level-up finds the player with nothing to
-- do).  It never pulls the player off a guide being played, so two guides cannot bounce.  When the detour ends, the
-- chain continues from where it was going (char.parkReturn), not from the parked guide's own `next`.
-- A step that needs a level above the client's cap can never open and does not park anything.
local function levelCap()
    local Rec = NS.Recommend
    if Rec and Rec.LevelCap then
        local ok, v = pcall(Rec.LevelCap)
        if ok and v then return v end
    end
    return math.huge
end
local function parkedSet()
    NS.db.char.parked = NS.db.char.parked or {}
    return NS.db.char.parked
end
-- The lowest level above the character's at which a not-done step of the loaded guide would open, and how many open there.
function P.NextGate()
    if not P.steps then return nil end
    local lvl, cap, best, count = U.PlayerLevel(), levelCap(), nil, 0
    for _, s in ipairs(P.steps) do
        local gate = s.minlevel
        if gate and s.action ~= "L" and gate > lvl and gate <= cap and not P.IsDone(s) and Cond.StepApplies(s, gate) then
            if not best or gate < best then best, count = gate, 1
            elseif gate == best then count = count + 1 end
        end
    end
    return best, count
end
-- Parked and the gate is still above us: nothing in it is doable yet.
function P.ParkedWaiting(id)
    local rec = NS.db.char.parked and NS.db.char.parked[id]
    return rec ~= nil and U.PlayerLevel() < rec.level
end
function P.ParkedRecord(id) return NS.db.char.parked and NS.db.char.parked[id] end
-- The parked guide to go back to now, if any: lowest gate first, then guide id, so the choice is stable.
local function parkedReady(exceptId)
    local set = NS.db.char.parked
    if not set then return nil end
    local lvl, best, bestRec = U.PlayerLevel(), nil, nil
    local keys = {}
    for id in pairs(set) do keys[#keys + 1] = id end
    table.sort(keys)
    for _, id in ipairs(keys) do
        -- a guide not registered yet keeps its record: live guides (Adapters/DynamicQuests.lua) register seconds after this can first be asked
        local rec, g = set[id], G.registry[id]
        if g and id ~= exceptId and lvl >= rec.level and (not bestRec or rec.level < bestRec.level) then
            best, bestRec = g, rec
        end
    end
    return best, bestRec
end
-- Load a guide because the chain says so (as opposed to the player picking it).
local function chainLoad(id)
    P.chainDepth = (P.chainDepth or 0) + 1
    P.chainLoading = true
    local ok, err = pcall(P.Load, id)
    P.chainLoading = nil
    P.chainDepth = P.chainDepth - 1     -- counts nesting only, so a pass that hit the limit resumes on the next refresh
    if not ok then error(err, 0) end
end
-- Bring a parked guide back now (used by the end-of-guide path below and by tools/vplayer.lua).
function P.ResumeParked(id)
    local rec = NS.db.char.parked and NS.db.char.parked[id]
    if not (rec and G.registry[id]) then return false end
    chainLoad(id)
    return true
end
-- A guide ran dry: park it if a level gate still holds steps back, otherwise forget it.
local function parkGuide(g)
    local gate, n = P.NextGate()
    if not gate then
        if NS.db.char.parked then NS.db.char.parked[g.id] = nil end
        return nil
    end
    local set = parkedSet()
    if not (set[g.id] and set[g.id].level == gate) then
        NS:Print(("%s parked: %d more step%s at level %d. It comes back when you get there."):format(g.name or g.id, n, n == 1 and "" or "s", gate))
    end
    set[g.id] = { level = gate }
    return gate
end
local function fitsLevel(g) return not (g.maxlevel and U.PlayerLevel() > g.maxlevel + 0.9) end

function P.Refresh(force)
    if not P.guide then return end
    -- Pending's cursor assumes a step never un-completes without one of the paths below clearing it.
    -- Changing the completion scope (Options: character/realm/flavor/account) can un-complete steps
    -- anywhere in the guide, so notice that here rather than trust every caller to remember.
    local scope, acc = NS.db.profile.scope, NS.db.profile.accountWide
    if P.scopeSeen ~= scope or P.accSeen ~= acc then
        P.scopeSeen, P.accSeen, P.cursor = scope, acc, nil
    end
    local fresh = P.fresh       -- first refresh after a load: what it ticks was done before, it is not progress made now
    P.fresh = nil
    if P.hasAlts then
        local _, _, _, inst = U.PlayerPos()
        if inst and inst ~= P.altInst then P.ResolveAlts() end
    end
    -- 1) auto-complete anything already satisfied (scan a window ahead so obsolete steps vanish)
    local changed, passes, wp = false, 0, 0
    repeat
        local any = false
        local reopened = charReopened()
        for i, s in ipairs(P.Pending(40)) do
            -- Farm waypoints only tick when they are the step you are actually walking to, and only ONE
            -- per refresh: a circuit loops back on itself, so waypoints inside the radius would otherwise
            -- cascade and swallow the whole lap (leaving the player with no current step at all).
            local skip = (s.action == "G") and (i > 1 or wp > 0)
            if not reopened[s.key] and not skip and P.CheckStep(s) then
                charDone()[s.key] = true any = true
                if s.action == "G" then wp = wp + 1 end
            end
        end
        changed = changed or any
        passes = passes + 1
    until not any or passes >= 25   -- a guide picked up mid-way can have hundreds of already-done steps
    if changed then
        NS:Fire("STEPS_AUTOCOMPLETED")
        if not fresh and P.guide then P.TouchRecent(P.guide.id, #P.steps) end
    end
    -- 2) let optimizer order the upcoming window
    local window = NS.db.profile.routing.window or 10
    local upcoming = P.Pending(window + 5)
    if NS.Router and NS.db.profile.routing.enabled and NS.db.profile.routing.reorder then
        upcoming = NS.Router.OrderSteps(upcoming) or upcoming
    end
    P.order = upcoming
    local newcur = upcoming[1]
    if newcur ~= P.current then
        P.current = newcur
        NS:Fire("STEP_CHANGED", newcur)
    end
    NS:Fire("PROGRESS_REFRESHED")
    if not newcur and P.guide and P.guide.loop then
        -- Farm circuits never "finish": wipe the lap and start the loop again from the nearest waypoint.
        if not P.inLap then
            P.inLap = true
            local ok, err = pcall(P.NewLap)
            P.inLap = nil
            if not ok then NS:Error("lap restart failed: " .. tostring(err)) end
        end
        return
    end
    if not newcur and P.guide then
        -- Gold and profession guides are chosen on purpose: never drop into one automatically, and never pull
        -- the player out of one into a leveling guide when it ends
        if G.IsSideGuide(P.guide) then
            if P.finishedNotice ~= P.guide.id then
                P.finishedNotice = P.guide.id
                NS:Print("Route finished: " .. (P.guide.name or P.guide.id) .. ". Start over runs it again; Routes has the next one.")
            end
            return
        end
        -- a chain of guides that are all finished must not recurse forever (each Load refreshes)
        if (P.chainDepth or 0) > 40 then return end
        local me = P.guide
        parkGuide(me)
        -- pick what to run next: the authored chain if it still fits our level,
        -- else the most optimal leveling guide for our level + position
        local nxt = me.next and G.registry[me.next]
        if nxt and G.IsSideGuide(nxt) then nxt = nil end
        -- a chain guide we have outleveled is passed over; the chain goes on from the next one that fits
        local hops = 0
        while nxt and not fitsLevel(nxt) and hops < 1000 do
            hops = hops + 1
            nxt = nxt.next and G.registry[nxt.next] or nil
            if nxt and G.IsSideGuide(nxt) then nxt = nil end
        end
        -- A detour back to a parked guide returns to where the chain was going, never to that guide's own `next`.
        local ret = NS.db.char.parkReturn
        local retGuide = ret and ret ~= me.id and G.registry[ret]
        -- a parked guide whose level has come goes first; the chain target waits for it
        local back, rec = parkedReady(me.id)
        if back and back.id ~= (nxt and nxt.id) then
            if not ret and nxt then NS.db.char.parkReturn = nxt.id end
            NS:Print(("Back to %s: level %d reached."):format(back.name or back.id, rec.level))
            chainLoad(back.id)
            return
        end
        if ret then
            NS.db.char.parkReturn = nil
            if retGuide and not G.IsSideGuide(retGuide) and fitsLevel(retGuide) then nxt = retGuide end
        end
        local eta
        if not nxt then nxt, eta = G.SuggestNext(me.id) end
        if nxt and nxt.id ~= me.id then
            local where = eta and (" (~%dm away)"):format(math.max(1, math.floor(eta / 60 + 0.5))) or ""
            NS:Print("Guide finished. Loading next: " .. nxt.name .. where)
            chainLoad(nxt.id)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Farm circuits (guide.loop): the route repeats forever, no clicking, no completion screen
-- ---------------------------------------------------------------------------
-- Clear the lap and hand the lap to Farm for its stats, then start again at the nearest waypoint.
function P.NewLap()
    if not P.guide then return end
    local id = P.guide.id
    NS.db.char.laps = NS.db.char.laps or {}
    NS.db.char.laps[id] = (NS.db.char.laps[id] or 0) + 1
    if NS.Farm and NS.Farm.OnLapComplete then pcall(NS.Farm.OnLapComplete, P.guide) end
    clearMarks(id)
    dirty = true
    P.cursor = nil
    P.TouchRecent(id, P.steps and #P.steps)
    NS:Fire("LAP_COMPLETE", P.guide, NS.db.char.laps[id])
    P.Refresh()
    P.StartAtNearest()
end

-- A circuit is a closed loop, so any waypoint is a legal start: tick off the ones behind us so the
-- player walks the shortest way onto the ring instead of back to the author's first node.
function P.StartAtNearest()
    if not (P.guide and P.guide.loop and P.steps and #P.steps > 0 and NS.Router) then return end
    local _, _, _, pinst, pwx, pwy = U.PlayerPos()
    if not pwx then return end
    local best, bestd
    for i, s in ipairs(P.steps) do
        local tx, ty, ti = NS.Router.StepWorld(s)
        if tx and ti == pinst then
            local d = math.sqrt((tx - pwx) ^ 2 + (ty - pwy) ^ 2)
            if not bestd or d < bestd then best, bestd = i, d end
        end
    end
    if not best then return end
    -- Standing on the nearest waypoint (which is what happens the instant a lap closes) would tick it,
    -- then the next, and the ring would eat itself: aim at the one AFTER it instead.
    local radius = (P.steps[best].radius) or (NS.db.profile.farm and NS.db.profile.farm.radius) or 40
    if bestd <= radius then best = best % #P.steps + 1 end
    local done = charDone()
    for i = 1, #P.steps do done[P.steps[i].key] = (i < best) or nil end
    dirty = true
    P.cursor = nil
    P.Refresh()
end

function P.Lap(id) return (NS.db.char.laps or {})[id or (P.guide and P.guide.id)] or 0 end

function P.Upcoming(n) local out = {} for i = 1, math.min(n or 6, P.order and #P.order or 0) do out[i] = P.order[i] end return out end

-- ---------------------------------------------------------------------------
-- Events that can complete steps
-- ---------------------------------------------------------------------------
local function refreshSoon() NS:Throttle("progress", 0.3, function() P.Refresh() end) end
for _, e in ipairs({ "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_REMOVED", "UNIT_QUEST_LOG_CHANGED", "BAG_UPDATE_DELAYED",
    "ZONE_CHANGED", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED_INDOORS", "PLAYER_LEVEL_UP", "PLAYER_ENTERING_WORLD", "PLAYER_CONTROL_GAINED", "MERCHANT_SHOW", "PLAYER_REGEN_ENABLED" }) do
    NS:RegisterEvent(e, refreshSoon)
end
NS:On("PROFESSIONS_CHANGED", refreshSoon)   -- Core/Professions.lua: a skill went up, or a recipe or rank was learned
NS:RegisterEvent("HEARTHSTONE_BOUND", function()
    for _, s in ipairs(P.Pending(15)) do if s.action == "h" then s.bindDone = true break end end
    refreshSoon()
end)
NS:RegisterEvent("CONFIRM_BINDER", function() end)
NS:RegisterEvent("TAXIMAP_OPENED", function()
    for _, s in ipairs(P.Pending(15)) do if s.action == "f" then s.taxiDone = true break end end
    refreshSoon()
end)
NS:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spellID)
    if unit ~= "player" then return end
    if spellID == NS.HEARTH_SPELL or spellID == NS.ASTRAL_RECALL or (NS.Teleports and NS.Teleports.IsHearthSpell(spellID)) then
        for _, s in ipairs(P.Pending(15)) do if s.action == "H" then charDone()[s.key] = true break end end
        refreshSoon()
    end
end)
-- ---------------------------------------------------------------------------
-- Talking, vendors, treasure, missions: completion straight from a client event (2026-11-12)
-- ---------------------------------------------------------------------------
-- Every handler looks at the step on screen only (never a later one), does a table read or two, and leaves when the
-- step has nothing for it, so it costs nothing on the common events it listens to.
--
-- An NPC's window opened.  UnitName("npc") is the NPC being talked to (the gossip and merchant frames of all four
-- Blizzard UI sources title themselves with it); the quest panes use "questnpc", read when "npc" answers nothing.
-- Retail hands out a secret value for the name under combat restrictions, which must not be compared (U.IsSecret).
local QUEST_WINDOW = { QUEST_GREETING = true, QUEST_DETAIL = true, QUEST_PROGRESS = true, QUEST_COMPLETE = true }
local function npcName(evt)
    if not UnitName then return nil end
    local name = UnitName("npc")
    if U.IsSecret(name) then return nil end
    if name == nil and QUEST_WINDOW[evt] then
        name = UnitName("questnpc")
        if U.IsSecret(name) then return nil end
    end
    return type(name) == "string" and name or nil
end
-- One conversation finishes one step.  A single click on an NPC fires several of these events (GOSSIP_SHOW and
-- PLAYER_INTERACTION_MANAGER_FRAME_SHOW for the same window; then MERCHANT_SHOW or QUEST_DETAIL as the player goes
-- from the gossip pane to the vendor or a quest), and two steps in a row can name the same NPC ("Talk to Bob", then
-- "Talk to Bob" again after an errand): without this the second step went with the first.  After a step is finished
-- here, the same NPC (any NPC, when the name could not be read) finishes nothing more until its windows have been
-- closed for TALK_GAP seconds; a pane-to-pane change closes and opens in the same moment.
local TALK_GAP = 2
local talk = {}     -- who: lower-case name of the NPC that finished a step (true = unreadable); closed: when its window closed
local function clock() return GetTime and GetTime() or 0 end
local function sameConversation(name)
    if talk.who == nil then return false end
    if talk.who ~= true and name and talk.who ~= name:lower() then return false end
    if talk.closed and clock() - talk.closed >= TALK_GAP then return false end
    talk.closed = nil       -- a window of that NPC is open again: it has to close again before anything counts
    return true
end
local function talked(name) talk.who, talk.closed = name and name:lower() or true, nil end
P._talk = talk          -- tools/test_flow.lua
local function npcWindow(evt)
    local s = P.current
    if not s then return end
    local merchant = evt == "MERCHANT_SHOW" and Sig.MerchantCompletes(s)
    if not merchant and not Sig.TalkNames(s) then return end
    local name = npcName(evt)
    if merchant then
        -- a step that is only about repairing needs a merchant who repairs
        if Sig.NeedsRepairer(s) and not (CanMerchantRepair and CanMerchantRepair()) then return end
        if sameConversation(name) then return end
        talked(name)
        P.MarkDone(s)
        return
    end
    if not Sig.TalkMatches(s, name) or sameConversation(name) then return end
    talked(name)
    P.MarkDone(s)
end
P.OnNpcWindow = npcWindow
-- The windows an NPC opens: gossip, the quest greeting and the three quest panes (a giver with one quest opens
-- straight into it), merchant, trainer, flight master, bank, auctioneer.  PLAYER_INTERACTION_MANAGER_FRAME_SHOW is the
-- one event for all of them and the older names still fire beside it.  All of these are in the generated API
-- documentation of the four Blizzard UI sources (live 12.1.5, 1.15.9, 2.5.6, 5.5.4); NS:RegisterEvent is
-- pcall-guarded, so a name a client does not have is simply not listened to.
for _, e in ipairs({ "GOSSIP_SHOW", "QUEST_GREETING", "QUEST_DETAIL", "QUEST_PROGRESS", "QUEST_COMPLETE", "MERCHANT_SHOW", "TRAINER_SHOW",
    "TAXIMAP_OPENED", "BANKFRAME_OPENED", "AUCTION_HOUSE_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" }) do
    NS:RegisterEvent(e, npcWindow)
end
local function npcClosed() if talk.who ~= nil then talk.closed = clock() end end
for _, e in ipairs({ "GOSSIP_CLOSED", "QUEST_FINISHED", "MERCHANT_CLOSED", "TRAINER_CLOSED", "TAXIMAP_CLOSED", "BANKFRAME_CLOSED",
    "AUCTION_HOUSE_CLOSED", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" }) do
    NS:RegisterEvent(e, npcClosed)
end
-- A treasure step with a spot: a chest was looted while standing there.  The loot has to come from a game object
-- (GetLootSourceInfo's GUID starts with "GameObject-"): a corpse looted beside the chest, or a fish, is not the
-- treasure.  A client that cannot say where the loot came from leaves the step manual.
local function lootFromObject()
    if IsFishingLoot and IsFishingLoot() then return false end
    if not (GetNumLootItems and GetLootSourceInfo) then return false end
    for slot = 1, GetNumLootItems() or 0 do
        local guid = GetLootSourceInfo(slot)
        if U.IsSecret(guid) then return false end
        if type(guid) == "string" and guid:sub(1, 11) == "GameObject-" then return true end
    end
    return false
end
local function lootWindow()
    local s = P.current
    if not (s and Sig.LootAtSpot(s)) then return end
    if nearCoords(s, s.radius or 25) and lootFromObject() then P.MarkDone(s) end
end
P.OnLootWindow = lootWindow
NS:RegisterEvent("LOOT_OPENED", lootWindow)
NS:RegisterEvent("LOOT_READY", lootWindow)
-- A mission table mission came back a success (Retail): the step that names that mission id is done, wherever it is
-- in the list (the id is exact, and missions are done in whatever order the table offers them)
NS:RegisterEvent("GARRISON_MISSION_COMPLETE_RESPONSE", function(_, missionID, canComplete, success)
    if not (P.steps and type(missionID) == "number" and canComplete and success) then return end
    for _, s in ipairs(P.steps) do
        if s.mission == missionID and not P.IsDone(s) then P.MarkDone(s) return end
    end
end)

-- position-based checks (R steps) — light poll
local acc = 0
NS.eventFrame:SetScript("OnUpdate", function(_, el)
    acc = acc + el
    if acc < 1.0 then return end
    acc = 0
    if not P.current then return end
    local a = P.current.action
    if a == "G" or a == "R" or a == "F" or a == "b" or a == "J" or a == "H" or a == "D" then if P.CheckStep(P.current) then P.MarkDone(P.current) end end
    NS:Fire("TICK")
end)

local function autoload(attempt)
    local ok, err = pcall(function()
        local id = NS.db.char.guide
        if id and G.registry[id] then
            NS.db.char.welcomed = true
            P.chainLoading = true
            P.Load(id)
            P.chainLoading = nil
            return
        end
        -- First launch on this character (no guide was ever loaded): do not pick a guide and open it unasked.  Show
        -- the guide list instead, whose "For level N" section starts open with the best picks (beta feedback,
        -- 2026-11-11).  Once per character; a character whose saved guide no longer exists still gets a suggestion.
        if id == nil and not NS.db.char.welcomed then
            NS.db.char.welcomed = true
            if NS.GuideMenu and NS.GuideMenu.Show then
                NS.GuideMenu.Show()
                NS:Print("Pick a route to start: the list is open (/cr routes opens it again).")
                return
            end
        end
        NS.db.char.welcomed = true
        local s = G.SuggestNext(nil) or G.Suggest()  -- location-aware pick at login too
        if s then P.Load(s.id)
        elseif attempt < 3 then NS:After(6, function() autoload(attempt + 1) end)  -- adapters may still be importing
        else NS:Print("No route matched your level/faction. /cr routes") end
    end)
    if not ok then
        P.chainLoading = nil     -- the failed Load never reached the line that clears it
        NS.db.char.lastAutoloadError = tostring(err)
        NS:Error("autoload failed: " .. tostring(err))
        if attempt < 3 then NS:After(6, function() autoload(attempt + 1) end) end
    end
end
NS:On("PLAYER_READY", function()
    NS:After(2, function() autoload(1) end)
    NS:After(25, function() if NS.RunVerify then pcall(NS.RunVerify, true) end end)
    -- feature matrix for the SQL chart; silent, results live in CompletionRouteDB.featureVerify
    NS:After(30, function() if NS.RunFeatureVerify then pcall(NS.RunFeatureVerify, true) end end)
    -- File-driven verification pathway: set CompletionRouteDB.autoVerifyAll = true in the
    -- SavedVariables before launching and the client sweeps every guide by itself, then clears
    -- the flag. Far more reliable than typing a slash command through synthetic keystrokes.
    NS:After(40, function()
        if CompletionRouteDB and CompletionRouteDB.autoDemo and NS.Beacon then
            CompletionRouteDB.autoDemo = nil
            pcall(NS.Beacon.Demo)
        end
    end)
    -- Probe: the client's truth about map instances and which transit edges resolved, written to
    -- CompletionRouteDB.probe so an offline reader can compare with tools/maps_<flavor>.lua (no typing needed).
    NS:After(42, function()
        if not (CompletionRouteDB and NS.TravelGraph and NS.TravelGraph.Build) then return end
        local ok, err = pcall(function()
            local HBD = LibStub("HereBeDragons-2.0")
            local TG = NS.TravelGraph
            if not TG.built then TG.Build() end
            local probe = { at = date("%Y-%m-%d %H:%M:%S"), flavor = NS.flavor, nodes = #TG.nodes, unresolved = {}, maps = {} }
            for _, u in ipairs(TG.unresolved or {}) do probe.unresolved[#probe.unresolved + 1] = u end
            local ids = { 85, 84, 1, 18, 590, 582, 588, 622, 624, 1533, 1536, 1565, 1525, 1670, 2248, 2339, 2022, 2112, 862, 895, 1161, 1409,
                          627, 125, 630, 371, 390, 114, 117, 198, 201, 207, 249, 241, 245, 71, 81, 2354, 2432, 2424, 122, 1270, 14, 1244, 2257 }
            for _, id in ipairs(ids) do
                local info = C_Map.GetMapInfo(id)
                local wx, wy, inst = HBD:GetWorldCoordinatesFromZone(0.5, 0.5, id)
                probe.maps[#probe.maps + 1] = ("%d|%s|type %s|inst %s|%s"):format(id, info and info.name or "?", tostring(info and info.mapType), tostring(inst), wx and "ok" or "NO WORLD COORDS")
            end
            for _, t in ipairs(NS.TransitData or {}) do
                for _, side in ipairs({ t.from, t.to }) do
                    local m = NS.Util.MapIDByName(side[1])
                    if not m then probe.unresolved[#probe.unresolved + 1] = "zone name unknown: " .. tostring(side[1]) end
                end
            end
            CompletionRouteDB.probe = probe
        end)
        if not ok then CompletionRouteDB.probe = { error = tostring(err) } end
    end)
    -- same file-driven pathway for the route sweep and for a clean self-quit (flushes SavedVariables)
    -- file-driven circuit self test (arm CompletionRouteDB.autoFarmTest = true before launching)
    NS:After(50, function()
        if CompletionRouteDB and CompletionRouteDB.autoFarmTest and NS.Farm and NS.Farm.SelfTest then
            CompletionRouteDB.autoFarmTest = nil
            pcall(NS.Farm.SelfTest)
        end
    end)
    NS:After(45, function()
        if CompletionRouteDB and CompletionRouteDB.autoSweep and NS.RunRouteSweep then
            local resume = CompletionRouteDB.autoSweep == "resume"
            CompletionRouteDB.autoSweep = nil
            pcall(NS.RunRouteSweep, nil, resume)
        end
    end)
    if CompletionRouteDB and tonumber(CompletionRouteDB.autoQuitAfter) then
        local secs = tonumber(CompletionRouteDB.autoQuitAfter)
        CompletionRouteDB.autoQuitAfter = nil
        -- Quit()/ForceQuit()/Logout() are protected in the world (taint popup), so only mark the run as
        -- finished; the driver (tools/verify_ingame.py) quits the client from outside.
        NS:After(secs, function() CompletionRouteDB.verifyRunDone = date("%Y-%m-%d %H:%M:%S") NS:Print("verification run complete - safe to quit") end)
    end
    NS:After(35, function()
        if CompletionRouteDB and CompletionRouteDB.autoVerifyAll and NS.RunVerifyAll then
            local resume = CompletionRouteDB.autoVerifyAll == "resume"
            CompletionRouteDB.autoVerifyAll = nil
            pcall(NS.RunVerifyAll, function()
                if CompletionRouteDB.autoVerifyQuit then
                    if ForceQuit then ForceQuit() elseif Quit then Quit() end
                end
            end, resume)
        end
    end)
end)


-- ---------------------------------------------------------------------------
-- Access chains (Data/Access.lua): steps that unlock a place, injected before a guide that starts there
-- ---------------------------------------------------------------------------
NS.Access = {}
local Access = NS.Access
-- Which locked chain (if any) does the route from the player to `step` go through?
function Access.LockedChainTo(step)
    local R, TG = NS.Router, NS.TravelGraph
    if not (R and TG and step) then return nil end
    local tx, ty, ti = R.StepWorld(step)
    if not tx then return nil end
    local _, _, _, inst, wx, wy = NS.Util.PlayerPos()
    if not wx then return nil end
    if inst == ti then return nil end   -- already on that continent: nothing to unlock
    local ok, path = pcall(TG.FindPath, wx, wy, inst, tx, ty, ti, {})
    if not ok or not path then return nil end
    local chains = {}
    for _, leg in ipairs(path.legs or {}) do   -- chains stack (Midnight intro -> Silvermoon -> Eversong -> Harandar): keep route order
        if leg.mode == "access" and leg.data and leg.data.locked then chains[#chains + 1] = leg.data.access end
    end
    return chains[1], chains
end
function Access.ParseSteps(a, guideId)
    local out, n = {}, 0
    for line in ((a.steps or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        n = n + 1
        local s = NS.Guide.ParseLine(line, n, nil)
        if s then out[#out + 1] = s end
    end
    for i, s in ipairs(out) do
        s.index = i - #out - 1          -- -k .. -1
        s.guide, s.access, s.accessTitle = guideId, a.key, a.title
    end
    -- progress keys (Core/Guide.lua "Stable step keys"): the chain's own, so they do not depend on what else is in front
    NS.Guide.AssignKeys(out, "@" .. tostring(a.key) .. "/")
    if NS.CostModel then NS.CostModel.Locate(out) end
    return out
end
function Access.PrefixFor(steps, guideId)
    if not steps or #steps == 0 or not NS.AccessData then return nil end
    local first
    for _, s in ipairs(steps) do if NS.Router.StepWorld(s) then first = s break end end
    local _, chains = Access.LockedChainTo(first)
    if not chains or #chains == 0 then return nil end
    local out = {}
    for _, a in ipairs(chains) do for _, st in ipairs(Access.ParseSteps(a, guideId)) do out[#out + 1] = st end end
    local seen = {}
    for i, st in ipairs(out) do
        st.index = i - #out - 1     -- renumber the whole prefix -k .. -1
        -- a chain named twice on one route would repeat its keys: number the repeats
        local n = (seen[st.key] or 0) + 1
        seen[st.key] = n
        if n > 1 then st.key = st.key .. "#r" .. n end
    end
    return out
end
