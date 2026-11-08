-- CompletionRoute :: tools/test_wiki.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org
--
-- Offline test of the Warcraft Wiki guides (tools/wiki/gen_wiki_guides.py -> Guides/Imported_Wiki_<flavor>.lua):
--   * every flavor's wiki file loads under its own client, registers guides, and every step line parses;
--   * the file is flavor-gated (another client registers nothing from it);
--   * a known quest has accept / objective / turn-in steps with map coordinates:
--     era 7 "Kobold Camp Cleanup" (Marshal McBride -> Kobold Vermin slain -> Marshal McBride, Elwynn Forest).
-- Generated files are gitignored, so a fresh clone SKIPS (like the other Imported_* checks).
-- Run: luajit tools/test_wiki.lua   (from repo root)
package.path = "./?.lua;" .. package.path
local TOC = { era = 11508, tbc = 20506, mop = 50504, retail = 121500 }
local fail = 0
local function check(ok, msg) if not ok then print("FAIL " .. msg) fail = fail + 1 end end

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

local ran = 0
for _, flavor in ipairs({ "era", "tbc", "mop", "retail" }) do
    local path = "Guides/Imported_Wiki_" .. flavor .. ".lua"
    local fh = io.open("CompletionRoute/" .. path, "r")
    if not fh then
        print("skip " .. path .. " (generated locally, gitignored: tools/wiki/gen_wiki_guides.py)")
    else
        local head = fh:read(4000) fh:close()
        check(head:find("CC BY%-SA 4%.0") and head:find("warcraft%.wiki%.gg"), flavor .. ": CC BY-SA 4.0 attribution header missing")
        ran = ran + 1
        local NS, load = harness(flavor)
        check(NS.flavor == flavor, ("harness flavor %s ~= %s"):format(tostring(NS.flavor), flavor))
        load(path)
        local guides, steps, located, bad = 0, 0, 0, 0
        local byQ = {}
        for _, id in ipairs(NS.Guide.list) do
            if id:find("^wiki:" .. flavor .. ":") then
                guides = guides + 1
                local g = NS.Guide.registry[id]
                local lines = 0
                for ln in g.text:gmatch("[^\n]+") do
                    lines = lines + 1
                    local st, err = NS.Guide.ParseLine(ln, lines)
                    if not st then bad = bad + 1 if bad <= 3 then print("  unparsable: " .. ln .. " (" .. tostring(err) .. ")") end
                    else
                        steps = steps + 1
                        if st.coords and #st.coords > 0 and st.zone then located = located + 1 end
                        local q = st.qid and st.qid[1]
                        if q then byQ[q] = byQ[q] or {} byQ[q][#byQ[q] + 1] = st end
                    end
                end
            end
        end
        check(guides > 50, flavor .. ": expected > 50 wiki guides, got " .. guides)
        check(bad == 0, flavor .. ": " .. bad .. " step lines did not parse")
        check(located > steps * 0.3, ("%s: only %d of %d steps located"):format(flavor, located, steps))
        print(("%-6s wiki guides %d, steps %d (%d with map coords), unparsable %d"):format(flavor, guides, steps, located, bad))
        if flavor == "era" then
            local q = byQ[7] or {}
            local seen = {}
            for _, st in ipairs(q) do
                seen[st.action] = st
                check(st.coords and #st.coords > 0 and st.zone, "era quest 7 " .. st.action .. " step has no coordinates")
            end
            check(seen.A and seen.C and seen.T, "era quest 7 Kobold Camp Cleanup lacks an A, C or T step")
            if seen.A then
                check(seen.A.title == "Kobold Camp Cleanup", "era quest 7 title: " .. tostring(seen.A.title))
                check(seen.A.faction == "Alliance", "era quest 7 should be Alliance-gated")
                check(seen.A.zone == 1429, "era quest 7 accept should be on Elwynn Forest (1429), got " .. tostring(seen.A.zone))
                check(seen.A.pre and seen.A.pre[1] == 783, "era quest 7 should require 783 A Threat Within (wiki 'previous')")
            end
            if seen.C then check(seen.C.target == "Kobold Vermin", "era quest 7 C target: " .. tostring(seen.C.target)) end
            print("era    quest 7 Kobold Camp Cleanup: A/C/T with coords OK")
        end
        -- flavor gate: another client loading this file registers nothing
        local other = flavor == "era" and "tbc" or "era"
        local NS2, load2 = harness(other)
        load2(path)
        local leaked = 0
        for _, id in ipairs(NS2.Guide.list) do if id:find("^wiki:" .. flavor .. ":") then leaked = leaked + 1 end end
        check(leaked == 0, ("%s wiki guides registered on a %s client (%d)"):format(flavor, other, leaked))
    end
end
if fail > 0 then print(fail .. " wiki guide check(s) failed") os.exit(1) end
print(ran > 0 and "ALL WIKI GUIDE TESTS PASSED" or "wiki guide tests SKIPPED (no Imported_Wiki_*.lua generated)")
