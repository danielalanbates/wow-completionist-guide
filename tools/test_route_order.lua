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
--     Only rules the author order itself keeps are checked - the same rule the optimizer is given;
--   * the route checksum (version 2: action, first quest id, zone, first point in 0.5 map % steps) has one definition
--     in three copies - Core/Guide.lua G.RouteChecksum, tools/cost_matrix.lua (which calls it and writes the parts) and
--     tools/optimize_routes.py (which folds the parts) - and all three agree on every quest guide of every client; a
--     moved point or a changed zone changes it, a re-parse or a note change does not;
--   * a STALE entry fails the test: an entry whose step count or checksum no longer matches its guide, or that names no
--     guide at all.  G.Steps still plays such a guide in author order (checked for each one), but the bake is out of
--     date: re-bake with tools/bake_resume.py.  A gated entry's measured times (va, vb) must pass the gate.
-- Generated files are gitignored, so a fresh clone runs only the mechanics part.
-- Run: luajit tools/test_route_order.lua   (from repo root)
--      CR_ROUTE_ORDER_DIR=<folder> checks the RouteOrder_<flavor>.lua files in that folder instead of CompletionRoute/Data
--      (a fresh bake before it is installed); CR_TEST_TMP is where the checksum cross-check writes its files.
package.path = "./?.lua;" .. package.path
local TOC = { era = 11508, tbc = 20506, mop = 50504, retail = 121500, forever = 16001 }
local fail = 0
local function check(ok, msg) if not ok then print("FAIL " .. msg) fail = fail + 1 end return ok end

local function harness(flavor)
    local ADDON, NS = "CompletionRoute", {}
    STUB_MAPS = dofile("tools/maps_" .. flavor .. ".lua")
    dofile("tools/stubs.lua")
    GetBuildInfo = function() return "x", "0", "2026", TOC[flavor] end
    local function load(path)
        local full = path:sub(1, 1) == "/" and path or ("CompletionRoute/" .. path)
        assert(loadfile(full))(ADDON, NS)
    end
    -- Forever moves Era-map points onto its own maps at parse time (Data/MapFix_forever.lua), as its TOC does
    for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", "Data/ZoneAliases.lua",
                         flavor == "forever" and "Data/MapFix_forever.lua" or nil }) do load(f) end
    NS.Print, NS.Debug = function() end, function() end
    return NS, load
end
local function exists(path) local f = io.open(path:sub(1, 1) == "/" and path or ("CompletionRoute/" .. path), "r") if f then f:close() return true end return false end
local function sh(cmd) local r = os.execute(cmd) return r == 0 or r == true end
local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local TMP = (os.getenv("CR_TEST_TMP") or "/private/tmp/claude-501") .. "/cr_test_route_order_" .. tostring(os.time())
if not sh("mkdir -p " .. q(TMP) .. " 2>/dev/null") then TMP = "/tmp/cr_test_route_order_" .. tostring(os.time()) sh("mkdir -p " .. q(TMP)) end
local f0 = io.open("../venv/bin/python", "r")
local PY = f0 and "../venv/bin/python" or "python3"
if f0 then f0:close() end
-- the Python fold (tools/optimize_routes.py --check-sums) over rows of checksum parts: true when it gives `sums`
local function pythonAgrees(rows, file)
    local f = assert(io.open(file, "w"))
    for _, r in ipairs(rows) do
        local parts = {}
        for i, p in ipairs(r.parts) do
            parts[i] = ("[%q,\"O\",%d,[],0,-1,0,%d,%d,%d]"):format(string.char(p[1]), p[2], p[3], p[4], p[5])
        end
        f:write(("{\"id\":%q,\"n\":%d,\"sum\":%d,\"steps\":[%s]}\n"):format(r.id, #parts, r.sum, table.concat(parts, ",")))
    end
    f:close()
    local p = io.popen(PY .. " tools/optimize_routes.py era --check-sums " .. q(file) .. " 2>&1; echo EXIT=$?")
    local out = p:read("*a") p:close()
    return out:find("EXIT=0", 1, true) ~= nil, out
end
local function partsOf(G, steps)
    local out = {}
    for i, s in ipairs(steps) do out[i] = { G.RouteChecksumParts(s) } end
    return out
end

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

    -- a gated entry carries vplayer's measured times (va, vb) and may carry fields a later bake adds: all ignored
    NS.RouteOrder["t:ro:1"] = { n = 6, sum = sum, o = "1,3,5,2,4,6", va = 1200, vb = 1100, gate = "keep", future = { 1, 2 } }
    fresh()
    check(idx(G.Steps("t:ro:1")) == "1,3,5,2,4,6", "an entry with extra fields (va, vb, unknown) applies normally")

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
    print(fail == 0 and "ok   mechanics (apply, index kept, spine part, extra fields, 5 fallbacks, option)" or "mechanics failed")

    -- the checksum (version 2): pinned value, what changes it and what does not, and the Python fold of its parts
    local f1 = fail
    local nv = 0
    local function sumOf(t)
        nv = nv + 1
        local id = "t:ro:sum" .. nv
        G.Register({ id = id, name = "RO sum " .. nv, zone = 1429, text = t })
        local st = G.Steps(id)
        return G.RouteChecksum(st), st
    end
    check(G.ROUTE_CHECKSUM_VERSION == 2, "checksum version 2")
    local base, bst = sumOf(text)
    check(base == sum, "checksum: same text, same value")
    check(base == 1799800159, "checksum: pinned value for the test guide (a changed formula must update all three copies) - got " .. base)
    local function variant(from, to) local v = text:gsub(from, to, 1) assert(v ~= text, from) return v end
    check(sumOf(variant("M|60.0,60.0", "M|61.0,60.0")) ~= base, "checksum: a point moved by 1 map % changes it")
    check(sumOf(variant("M|60.0,60.0", "M|60.0,59.4")) ~= base, "checksum: a point moved by 0.6 map % changes it")
    check(sumOf(variant("M|60.0,60.0", "M|60.1,60.0")) == base, "checksum: a move inside the same 0.5 % step keeps it")
    check(sumOf(variant("Z|1429; Elwynn Forest|", "Z|1436; Westfall|")) ~= base, "checksum: a step moved to another zone changes it")
    check(sumOf(variant("C One|QID|101|M|41.0,41.0|", "C One|QID|101|")) ~= base, "checksum: a step that lost its point changes it")
    check(sumOf(variant("A Two|", "A Two (renamed)|")) == base, "checksum: a title change keeps it")
    local okPy, outPy = pythonAgrees({ { id = "t:ro:1", sum = base, parts = partsOf(G, bst) },
                                       { id = "t:ro:moved", sum = (sumOf(variant("M|60.0,60.0", "M|61.0,60.0"))),
                                         parts = partsOf(G, select(2, sumOf(variant("M|60.0,60.0", "M|61.0,60.0")))) } },
                                     TMP .. "/mechanics_sums.jsonl")
    check(okPy, "checksum: tools/optimize_routes.py folds the parts to the same value :: " .. outPy:sub(-200))
    print(fail == f1 and "ok   checksum v2 (pinned value, moved point and zone change it, title and in-step moves do not, Python fold agrees)"
          or "checksum mechanics failed")
end

-- ---------------------------------------------------------------------------
-- 1b) the three checksum copies agree on every real quest guide (generated guides only)
-- ---------------------------------------------------------------------------
for _, flavor in ipairs({ "era", "tbc", "mop", "retail", "forever" }) do
    if not exists("Guides/Imported_Wiki_" .. flavor .. ".lua") then
        print("skip checksum cross-check " .. flavor .. " (generated guides missing: they are gitignored)")
    else
        local f1 = fail
        local NS, load = harness(flavor)
        for _, f in ipairs({ "Guides/Imported_Wiki_" .. flavor .. ".lua", "Guides/Imported_Quests_" .. flavor .. "_gaps.lua" }) do
            if exists(f) then load(f) end
        end
        local G = NS.Guide
        local mine, unstable, n = {}, 0, 0
        for _, id in ipairs(G.list) do
            if id:sub(1, 5) == "wiki:" or id:sub(1, 4) == "qdb:" or id:sub(1, 5) == "qpoi:" then
                local st = G.Steps(id)
                if st and #st > 0 and not G.registry[id].empty then
                    local a = G.RouteChecksum(st)
                    G.registry[id].steps = nil
                    if G.RouteChecksum(G.Steps(id)) ~= a then unstable = unstable + 1 end
                    G.registry[id].steps = nil
                    mine[id] = { n = #st, sum = a }
                    n = n + 1
                end
            end
        end
        check(unstable == 0, ("%s: %d guides give another checksum when parsed again"):format(flavor, unstable))
        local list = TMP .. "/list_" .. flavor .. ".jsonl"
        local okList = sh(("luajit tools/cost_matrix.lua %s --list --steps --out %s 2>/dev/null"):format(flavor, q(list)))
        check(okList, flavor .. ": tools/cost_matrix.lua --list --steps ran")
        local seen, differ, extra, firstBad = 0, 0, 0, nil
        for line in io.lines(list) do
            local id, nn, sm = line:match('^{"id":"(.-)","n":(%d+),"sum":(%d+)')
            if id then
                local m = mine[id]
                if not m then extra = extra + 1
                else
                    seen = seen + 1
                    if m.n ~= tonumber(nn) or m.sum ~= tonumber(sm) then differ = differ + 1 firstBad = firstBad or id end
                end
            end
        end
        check(seen == n and extra == 0, ("%s: cost_matrix lists the same quest guides (%d of %d, %d unknown)"):format(flavor, seen, n, extra))
        check(differ == 0, ("%s: Core/Guide.lua and tools/cost_matrix.lua checksums differ on %d guides, first %s"):format(flavor, differ, tostring(firstBad)))
        local p = io.popen(PY .. " tools/optimize_routes.py " .. flavor .. " --check-sums " .. q(list) .. " 2>&1; echo EXIT=$?")
        local out = p:read("*a") p:close()
        check(out:find("EXIT=0", 1, true) ~= nil and out:find(" 0 mismatches", 1, true) ~= nil,
            flavor .. ": tools/optimize_routes.py folds cost_matrix's parts to the same checksums :: " .. out:sub(-200))
        if fail == f1 then print(("ok   %-7s checksum: %d quest guides, Core/Guide.lua = cost_matrix.lua = optimize_routes.py, stable on re-parse"):format(flavor, n)) end
    end
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
local RO_DIR = os.getenv("CR_ROUTE_ORDER_DIR")
local staleTotal = {}
for _, flavor in ipairs({ "era", "tbc", "mop", "retail", "forever" }) do
    local ro = RO_DIR and (RO_DIR .. "/RouteOrder_" .. flavor .. ".lua") or ("Data/RouteOrder_" .. flavor .. ".lua")
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
        local missingIds, staleIds, broken, gateBad = {}, {}, {}, {}
        for id, e in pairs(NS.RouteOrder or {}) do
            entries = entries + 1
            if not G.registry[id] then missing = missing + 1 missingIds[#missingIds + 1] = id end
            -- a gated entry's measured times must pass the gate: baked + live no slower than author + live by more
            -- than max(1%, 30 s) (tools/optimize_routes.py --gate)
            if e.va or e.vb then
                if not (tonumber(e.va) and tonumber(e.vb) and e.vb <= e.va + math.max(0.01 * e.va, 30) + 0.5) then gateBad[#gateBad + 1] = id end
            end
        end
        local spines = 0
        for _, id in ipairs(G.list) do
            local g = G.registry[id]
            local e = NS.RouteOrder[id] or (g.part and NS.RouteOrder[g.part])
            if e then
                local s = G.Steps(id)
                if not g.baked then
                    -- the fallback: G.Steps plays it in author order (the live window then works on that order)
                    local author = true
                    for k, st in ipairs(s) do if st.index ~= k then author = false break end end
                    check(author, id .. ": an entry that does not apply must leave the author order")
                    if NS.RouteOrder[id] then
                        if e.n ~= #s or e.sum ~= G.RouteChecksum(s) then stale = stale + 1 staleIds[#staleIds + 1] = id
                        else broken[#broken + 1] = id end
                    end
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
        -- stale entries: G.Steps already plays those guides in author order (checked above), but the bake is out of date
        table.sort(staleIds) table.sort(missingIds)
        check(stale == 0, ("%s: %d STALE RouteOrder entries (step count or checksum no longer matches the guide; the game plays them in "
            .. "author order): %s%s - re-bake: python3 tools/bake_resume.py --flavors %s"):format(flavor, stale,
            table.concat(staleIds, ", ", 1, math.min(3, #staleIds)), #staleIds > 3 and ", ..." or "", flavor))
        check(missing == 0, ("%s: %d RouteOrder entries name no guide (deleted or renamed since the bake): %s%s - re-bake: "
            .. "python3 tools/bake_resume.py --flavors %s"):format(flavor, missing, table.concat(missingIds, ", ", 1, math.min(3, #missingIds)),
            #missingIds > 3 and ", ..." or "", flavor))
        check(#broken == 0, ("%s: %d RouteOrder entries match their guide but their order does not decode: %s"):format(flavor, #broken,
            table.concat(broken, ", ", 1, math.min(3, #broken))))
        check(#gateBad == 0, ("%s: %d gated entries whose measured times (va, vb) fail the gate: %s"):format(flavor, #gateBad,
            table.concat(gateBad, ", ", 1, math.min(3, #gateBad))))
        if stale + missing > 0 then staleTotal[#staleTotal + 1] = ("%s %d"):format(flavor, stale + missing) end
        print(("%s %-7s %d entries, %d guides baked (%d spine), %d steps, %d moved, %d violations, %d stale, %d orphan"):format(
            (stale + missing + #broken + #gateBad + bad) == 0 and "ok  " or "BAD ", flavor, entries, baked, spines, steps, moved, bad, stale, missing))
    end
end
sh("rm -rf " .. q(TMP))
if #staleTotal > 0 then
    print("STALE BAKE (" .. table.concat(staleTotal, ", ") .. "): these guides play in author order with the live window until "
        .. "the next bake (tools/bake_resume.py, docs/ROUTING.md \"Bake gate\")")
end
if fail > 0 then print(fail .. " route order check(s) failed") os.exit(1) end
print("All route order checks passed (" .. files .. " generated files).")
