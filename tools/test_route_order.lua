-- CompletionRoute :: tools/test_route_order.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org
--
-- Offline test of the baked route orders (tools/optimize_routes.py -> Data/RouteOrder_<flavor>.lua):
--   * mechanics (always runs, synthetic guide): Core/Guide.lua G.Steps applies a matching order, keeps every
--     step's author index, and falls back to the author order on a checksum or step-count mismatch, a broken
--     order string, or routing.baked = false; a spine entry picks the order up through its `part`;
--   * every generated RouteOrder file loads on its own client only (flavor gate; forever != era);
--   * every baked guide (and every spine entry that reuses one) parses into a permutation of its steps that
--     never breaks precedence: accept before objective before turn-in per quest, a prerequisite's turn-in before
--     every step that names it, anchors (non-routable / sticky steps) with exactly the author's steps before them.
--     Only rules the author order itself keeps are checked - the same rule the optimizer is given.
-- Generated files are gitignored, so a fresh clone runs only the mechanics part.
-- Run: luajit tools/test_route_order.lua   (from repo root)
package.path = "./?.lua;" .. package.path
local TOC = { era = 11508, tbc = 20506, mop = 50504, retail = 121500, forever = 16001 }
local fail = 0
local function check(ok, msg) if not ok then print("FAIL " .. msg) fail = fail + 1 end return ok end

local function harness(flavor)
    local ADDON, NS = "CompletionRoute", {}
    STUB_MAPS = dofile("tools/maps_" .. flavor .. ".lua")
    dofile("tools/stubs.lua")
    GetBuildInfo = function() return "x", "0", "2026", TOC[flavor] end
    local function load(path) assert(loadfile("CompletionRoute/" .. path))(ADDON, NS) end
    for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", "Data/ZoneAliases.lua" }) do load(f) end
    NS.Print, NS.Debug = function() end, function() end
    return NS, load
end
local function exists(path) local f = io.open("CompletionRoute/" .. path, "r") if f then f:close() return true end return false end

-- ---------------------------------------------------------------------------
-- 1) mechanics
-- ---------------------------------------------------------------------------
do
    local NS = harness("era")
    local G = NS.Guide
    local text = table.concat({
        "A One|QID|101|M|40.0,40.0|Z|1429; Elwynn Forest|",
        "A Two|QID|102|M|60.0,60.0|Z|1429; Elwynn Forest|",
        "C One|QID|101|M|41.0,41.0|Z|1429; Elwynn Forest|",
        "C Two|QID|102|M|61.0,61.0|Z|1429; Elwynn Forest|",
        "T One|QID|101|M|40.0,40.0|Z|1429; Elwynn Forest|",
        "T Two|QID|102|M|60.0,60.0|Z|1429; Elwynn Forest|" }, "\n")
    G.Register({ id = "t:ro:1", name = "RO test", zone = 1429, text = text })
    G.Register({ id = "t:ro:spine", name = "RO spine", zone = 1429, part = "t:ro:1", text = function() return text end })
    local author = G.Steps("t:ro:1")
    local sum = G.RouteChecksum(author)
    local function fresh() for _, id in ipairs({ "t:ro:1", "t:ro:spine" }) do G.registry[id].steps = nil end end
    local function idx(steps) local t = {} for k, s in ipairs(steps) do t[k] = s.index end return table.concat(t, ",") end
    check(idx(author) == "1,2,3,4,5,6", "author parse order " .. idx(author))

    NS.RouteOrder = { ["t:ro:1"] = { n = 6, sum = sum, o = "1,3,5,2,4,6" } }
    fresh()
    local b = G.Steps("t:ro:1")
    check(idx(b) == "1,3,5,2,4,6", "baked order applied: " .. idx(b))
    check(G.registry["t:ro:1"].baked == true, "g.baked flag set")
    check(b[2].action == "C" and b[2].qid[1] == 101 and b[2].index == 3, "baked step keeps its author index")
    check(idx(G.Steps("t:ro:spine")) == "1,3,5,2,4,6", "spine entry uses its part's baked order")

    NS.RouteOrder["t:ro:1"].o, NS.RouteOrder["t:ro:1"].order = "1-6", nil
    fresh()
    check(idx(G.Steps("t:ro:1")) == "1,2,3,4,5,6", "run-length '1-6' decodes")

    for _, bad in ipairs({ { sum = sum + 1, o = "2,1,3,4,5,6", why = "checksum mismatch" }, { n = 5, sum = sum, o = "2,1,3,4,5", why = "step count mismatch" },
                           { sum = sum, o = "2,2,3,4,5,6", why = "duplicate index" }, { sum = sum, o = "1-5", why = "short order" },
                           { sum = sum, o = "x", why = "garbage" } }) do
        NS.RouteOrder["t:ro:1"] = { n = bad.n or 6, sum = bad.sum, o = bad.o }
        fresh()
        check(idx(G.Steps("t:ro:1")) == "1,2,3,4,5,6", "falls back to author order on " .. bad.why)
        check(not G.registry["t:ro:1"].baked, "no baked flag on " .. bad.why)
    end

    NS.RouteOrder["t:ro:1"] = { n = 6, sum = sum, o = "2,4,6,1,3,5" }
    NS.db = { profile = { routing = { baked = false } } }
    fresh()
    check(idx(G.Steps("t:ro:1")) == "1,2,3,4,5,6", "routing.baked = false keeps the author order")
    NS.db.profile.routing.baked = true
    fresh()
    check(idx(G.Steps("t:ro:1")) == "2,4,6,1,3,5", "routing.baked = true applies it again")
    print(fail == 0 and "ok   mechanics (apply, index kept, spine part, 5 fallbacks, option)" or "mechanics failed")
end

-- ---------------------------------------------------------------------------
-- 2) generated files
-- ---------------------------------------------------------------------------
local ACCEPT = { A = true, a = true, ["!"] = true }
local OBJ = { C = true, K = true, l = true, U = true }
local TURNIN = { T = true, t = true }
local function rank(a) return ACCEPT[a] and 0 or OBJ[a] and 1 or TURNIN[a] and 2 or nil end

-- violations of `baked` against the rules the author order keeps (author index = s.index)
local function violations(baked)
    local bad, why = 0, nil
    local pos = {}
    for k, s in ipairs(baked) do pos[s.index] = k end
    local byQ, tin = {}, {}
    for _, s in ipairs(baked) do
        local q = s.qid and s.qid[1]
        if q then
            byQ[q] = byQ[q] or {}
            table.insert(byQ[q], s)
            if TURNIN[s.action] then tin[q] = tin[q] or {} table.insert(tin[q], s) end
        end
    end
    for q, list in pairs(byQ) do
        for _, x in ipairs(list) do
            for _, y in ipairs(list) do
                local rx, ry = rank(x.action), rank(y.action)
                if rx and ry and x.index < y.index and rx < ry and pos[x.index] > pos[y.index] then
                    bad = bad + 1 why = why or ("%s of %d after %s"):format(x.action, q, y.action)
                end
            end
        end
    end
    for _, s in ipairs(baked) do
        if s.pre then
            for _, p in ipairs(s.pre) do
                for _, t in ipairs(tin[p] or {}) do
                    if t.index < s.index and pos[t.index] > pos[s.index] then
                        bad = bad + 1 why = why or ("%s %s before PRE %d turn-in"):format(s.action, tostring(s.qid and s.qid[1]), p)
                    end
                end
            end
        end
    end
    -- anchors: the set of steps placed before an anchor is exactly the author's
    local seenMax, seenN = 0, 0
    for k, s in ipairs(baked) do
        local anchor = (not s.route) or s.sticky or not rank(s.action)
        if anchor and not (seenN == s.index - 1 and seenMax <= s.index - 1) then
            bad = bad + 1 why = why or ("anchor step %d moved"):format(s.index)
        end
        seenN = seenN + 1
        if s.index > seenMax then seenMax = s.index end
    end
    return bad, why
end

local files = 0
for _, flavor in ipairs({ "era", "tbc", "mop", "retail", "forever" }) do
    local ro = "Data/RouteOrder_" .. flavor .. ".lua"
    if not exists(ro) then
        print("skip " .. ro .. " (generated locally, gitignored: tools/cost_matrix.lua + tools/optimize_routes.py)")
    else
        files = files + 1
        -- flavor gate: another client registers nothing from this file
        for _, other in ipairs({ "era", "tbc", "mop", "retail", "forever" }) do
            if other ~= flavor then
                local NSo, loado = harness(other)
                loado(ro)
                check(NSo.RouteOrder == nil or next(NSo.RouteOrder) == nil, ro .. " registers entries on " .. other)
            end
        end
        local NS, load = harness(flavor)
        for _, f in ipairs({ "Guides/Imported_Wiki_" .. flavor .. ".lua", "Guides/Imported_Quests_" .. flavor .. "_gaps.lua",
                             "Guides/Imported_Spine_" .. flavor .. ".lua" }) do
            if exists(f) then load(f) end
        end
        load(ro)
        local G = NS.Guide
        check(NS.RouteOrder and next(NS.RouteOrder), ro .. ": no entries")
        local entries, missing, stale, baked, moved, steps, bad = 0, 0, 0, 0, 0, 0, 0
        for id in pairs(NS.RouteOrder or {}) do
            entries = entries + 1
            if not G.registry[id] then missing = missing + 1 end
        end
        local spines = 0
        for _, id in ipairs(G.list) do
            local g = G.registry[id]
            local e = NS.RouteOrder[id] or (g.part and NS.RouteOrder[g.part])
            if e then
                local s = G.Steps(id)
                if not g.baked then stale = stale + 1
                else
                    baked = baked + 1
                    if g.part then spines = spines + 1 end
                    steps = steps + #s
                    local seen, perm = {}, true
                    for k, st in ipairs(s) do
                        if seen[st.index] then perm = false end
                        seen[st.index] = true
                        if st.index ~= k then moved = moved + 1 end
                    end
                    for i = 1, #s do if not seen[i] then perm = false end end
                    check(perm, id .. ": baked steps are not a permutation")
                    local v, why = violations(s)
                    if v > 0 then
                        bad = bad + v
                        check(false, ("%s: %d precedence violation(s), first: %s"):format(id, v, why))
                    end
                end
                g.steps = nil
            end
        end
        -- not failures: G.Steps falls back to the author order by design; they only mean the bake is out of date
        if stale > 0 then print(("warn %s: %d guides changed since the bake keep their author order - re-run tools/optimize_routes.py"):format(flavor, stale)) end
        if missing > 0 then print(("warn %s: %d RouteOrder entries name no registered guide (guides regenerated since the bake)"):format(flavor, missing)) end
        print(("ok   %-7s %d entries, %d guides baked (%d spine), %d steps, %d moved, %d violations"):format(
            flavor, entries, baked, spines, steps, moved, bad))
    end
end
if fail > 0 then print(fail .. " route order check(s) failed") os.exit(1) end
print("All route order checks passed (" .. files .. " generated files).")
