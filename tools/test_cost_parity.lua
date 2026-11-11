-- CompletionRoute :: tools/test_cost_parity.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- One cost model (CompletionRoute/Routing/CostModel.lua, docs/ROUTING.md "One cost model"): the offline optimizer and
-- the virtual player must price the same order the same way.  For sample quest guides of every client:
--   1. tools/cost_matrix.lua writes the guides' rows (travel matrix + the cost model's constants, "cm");
--   2. tools/optimize_routes.py bakes them and predicts the seconds of the author order (author_s) and of the baked
--      order (baked_s);
--   3. tools/vplayer.lua plays both orders with the planning character (--who plan: the character the bake plans for)
--      and no live window (--live off), so it walks exactly the order it was given;
--   4. per guide, prediction and measurement agree within 2% (and 1 s), for both orders.  The one exception is a guide
--      whose author order breaks its own rules (an accept listed before the in-guide turn-in of its prerequisite: the
--      optimizer's dropped_edges, seen only in the Questie-derived qdb: gaps guides): the client cannot play that order as
--      written (it shows the hidden step later, or never), so "the same order" does not exist.  Such a guide is listed
--      with that reason when it misses, and does not fail the test.
-- Also: every row carries the cost model's version and no-route cost (the optimizer holds no copy of its own), and the
-- optimizer refuses a row without them.
-- Every file goes to a work folder under /private/tmp/claude-501 (CR_TEST_TMP); the RouteOrder file the test bakes is
-- the work folder's own (--lua-out), never Data/RouteOrder_<flavor>.lua.  The generated guides are gitignored: a client
-- without them is skipped.  The optimizer runs with short limits (--limit-s 3 --dp-time 1): this checks the arithmetic,
-- not the solver.
-- Run: luajit tools/test_cost_parity.lua [--flavors era,tbc,mop,retail,forever] [--per N] [--keep]
--      (CR_PARITY_PER sets --per too; default 6 guides per client, spread evenly over the quest guides with >= 10 steps)
package.path = "./?.lua;" .. package.path
local J = dofile("tools/json.lua")

local flavors, per, keep = { "era", "tbc", "mop", "retail", "forever" }, tonumber(os.getenv("CR_PARITY_PER") or "") or 6, false
for i = 1, #arg do
    if arg[i] == "--flavors" then flavors = {} for f in arg[i + 1]:gmatch("[^,]+") do flavors[#flavors + 1] = f end
    elseif arg[i] == "--per" then per = tonumber(arg[i + 1])
    elseif arg[i] == "--keep" then keep = true end
end
local TOL_FRAC, TOL_ABS = 0.02, 1.0

local passed, failed = 0, 0
local function t(name, cond, detail)
    if cond then passed = passed + 1 print("ok   " .. name)
    else failed = failed + 1 print("FAIL " .. name .. (detail and (" :: " .. tostring(detail)) or "")) end
end
local function sh(cmd) local r = os.execute(cmd) return r == 0 or r == true end
local function exists(p) local f = io.open(p, "r") if f then f:close() return true end return false end
local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local TMP = (os.getenv("CR_TEST_TMP") or "/private/tmp/claude-501") .. "/cr_test_cost_parity_" .. tostring(os.time())
if not sh("mkdir -p " .. q(TMP)) then TMP = "/tmp/cr_test_cost_parity_" .. tostring(os.time()) sh("mkdir -p " .. q(TMP)) end
local PY = exists("../venv/bin/python") and "../venv/bin/python" or "python3"

-- the cost model's constants, read from the addon file itself
local CMNS = {}
assert(loadfile("CompletionRoute/Routing/CostModel.lua"))("CompletionRoute", CMNS)
local CM = CMNS.CostModel

local function readLines(p)
    local out = {}
    local f = io.open(p, "r")
    if not f then return out end
    for l in f:lines() do if l ~= "" then out[#out + 1] = l end end
    f:close()
    return out
end
local function readTsv(p)
    local rows, head = {}, nil
    for _, l in ipairs(readLines(p)) do
        local cols = {}
        for c in (l .. "\t"):gmatch("([^\t]*)\t") do cols[#cols + 1] = c end
        if not head then head = cols
        else local r = {} for k, h in ipairs(head) do r[h] = cols[k] end rows[r.guide] = r end
    end
    return rows
end

local total, outside = 0, {}
for _, fl in ipairs(flavors) do
    if not exists("CompletionRoute/Guides/Imported_Wiki_" .. fl .. ".lua") then
        print("skip " .. fl .. " (generated guides missing: they are gitignored)")
    else
        local W = TMP .. "/" .. fl
        sh("mkdir -p " .. q(W))
        -- 1. the sample: evenly spread over the quest guides with at least 10 steps
        assert(sh(("luajit tools/cost_matrix.lua %s --list --out %s 2>/dev/null"):format(fl, q(W .. "/list.jsonl"))), "cost_matrix --list failed")
        local list = {}
        for _, l in ipairs(readLines(W .. "/list.jsonl")) do local r = J.decode(l) if r.n >= 10 then list[#list + 1] = r end end
        table.sort(list, function(a, b) return a.id < b.id end)
        local ids = {}
        for k = 1, math.min(per, #list) do ids[#ids + 1] = list[math.floor((k - 0.5) * #list / math.min(per, #list)) + 1].id end
        local gf = W .. "/sample.txt"
        local f = io.open(gf, "w") f:write(table.concat(ids, "\n") .. "\n") f:close()
        -- 2. matrices and the bake (work-folder outputs only)
        local cmOut, opt, ro = W .. "/cm.jsonl", W .. "/opt.jsonl", W .. "/RouteOrder_" .. fl .. ".lua"
        t(fl .. ": cost_matrix writes the sample", sh(("luajit tools/cost_matrix.lua %s --guides-file %s --out %s --verify 20 2>%s"):format(
            fl, q(gf), q(cmOut), q(W .. "/cm.log"))))
        local rows, cmOK = {}, true
        for _, l in ipairs(readLines(cmOut)) do
            local r = J.decode(l)
            rows[#rows + 1] = r
            if not (r.cm and r.cm.version == CM.VERSION and r.cm.noroute == CM.NOROUTE) then cmOK = false end
        end
        t(fl .. ": every row carries the cost model (version " .. CM.VERSION .. ", no-route " .. CM.NOROUTE .. " s)", #rows > 0 and cmOK)
        t(fl .. ": the optimizer bakes the sample", sh(("CR_TMP=%s %s tools/optimize_routes.py %s --in %s --out %s --lua-out %s --limit-s 3 --dp-time 1 2>%s"):format(
            q(W), PY, fl, q(cmOut), q(opt), q(ro), q(W .. "/opt.log"))))
        -- 3. vplayer plays both orders with the planning character and no live window
        for _, ord in ipairs({ "author", "baked" }) do
            local extra = (ord == "baked") and (" --route-order " .. q(ro)) or ""
            t(fl .. ": vplayer plays the " .. ord .. " order", sh(("luajit tools/vplayer.lua %s --guides-file %s --order %s%s --live off --who plan --guidecap 300 --out %s 2>%s"):format(
                fl, q(gf), ord, extra, q(W .. "/vp_" .. ord .. ".tsv"), q(W .. "/vp_" .. ord .. ".log"))))
        end
        -- 4. prediction against measurement
        local baked = {}
        for _, l in ipairs(readLines(ro)) do local id = l:match('^O%["([^"]+)"%]') if id then baked[id] = true end end
        local va, vb = readTsv(W .. "/vp_author.tsv"), readTsv(W .. "/vp_baked.tsv")
        local n, bad, excused = 0, 0, 0
        for _, l in ipairs(readLines(opt)) do
            local r = J.decode(l)
            local pa = r.author_s
            local pb = baked[r.id] and r.baked_s or r.author_s
            local a, b = va[r.id], vb[r.id]
            n = n + 1
            if not (a and b) then
                bad = bad + 1 outside[#outside + 1] = ("%s %s: no vplayer row"):format(fl, r.id)
            else
                local ma, mb = tonumber(a.seconds), tonumber(b.seconds)
                local okA = math.abs(ma - pa) <= math.max(TOL_FRAC * pa, TOL_ABS)
                local okB = math.abs(mb - pb) <= math.max(TOL_FRAC * pb, TOL_ABS)
                local line = ("%-7s %-30s steps %4d  author: predicted %8.0f s, vplayer %8.0f s (%+5.1f%%)  %s: predicted %8.0f s, vplayer %8.0f s (%+5.1f%%)"):format(
                    fl, r.id, r.steps, pa, ma, 100 * (ma - pa) / math.max(pa, 1), baked[r.id] and "baked" or "baked (= author)", pb, mb, 100 * (mb - pb) / math.max(pb, 1))
                local broken = (r.dropped_edges or 0) > 0
                print((okA and okB) and ("     " .. line) or ((broken and "SKIP " or "OUT  ") .. line))
                if not (okA and okB) then
                    if broken then
                        excused = excused + 1
                        outside[#outside + 1] = line .. ("  [author order breaks %d of its own precedence edges: not playable as written]"):format(r.dropped_edges)
                    else
                        bad = bad + 1 outside[#outside + 1] = line
                    end
                end
                if a.finished ~= "1" or b.finished ~= "1" then
                    bad = bad + 1 outside[#outside + 1] = ("%s %s: vplayer did not finish (author %s, baked %s)"):format(fl, r.id, a.finished, b.finished)
                end
            end
        end
        total = total + n
        t(("%s: %d guides, predicted and measured seconds agree within 2%% for both orders (%d excused: author order not playable)"):format(
            fl, n, excused), n > 0 and bad == 0, bad .. " outside")
        -- a row without the cost model is refused (no second copy of its constants in the optimizer)
        if #rows > 0 then
            local r = rows[1]
            r.cm = nil
            local bad1 = W .. "/nocm.jsonl"
            local fb = io.open(bad1, "w") fb:write(J.encode(r) .. "\n") fb:close()
            local p = io.popen(("CR_TMP=%s %s tools/optimize_routes.py %s --in %s --out %s --no-write 2>&1; echo EXIT=$?"):format(
                q(W), PY, fl, q(bad1), q(W .. "/nocm_out.jsonl")))
            local txt = p:read("*a") p:close()
            t(fl .. ": the optimizer refuses a row without the cost model", txt:find("EXIT=0", 1, true) == nil and txt:find("no cost model", 1, true) ~= nil,
                txt:sub(-300))
        end
    end
end
if #outside > 0 then
    print("Guides outside 2%:")
    for _, l in ipairs(outside) do print("  " .. l) end
end
if not keep and failed == 0 then sh("rm -rf " .. q(TMP)) else print("work folder kept: " .. TMP) end
print(("%d passed, %d failed (%d guides)"):format(passed, failed, total))
if failed > 0 then os.exit(1) end
print("ALL COST PARITY TESTS PASSED")
