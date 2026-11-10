-- CompletionRoute :: tools/test_wiki.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org
--
-- Offline test of the Warcraft Wiki guides (tools/wiki/gen_wiki_guides.py -> Guides/Imported_Wiki_<flavor>.lua):
--   * every flavor's wiki file loads under its own client, registers guides, and every step line parses;
--   * the file is flavor-gated (another client registers nothing from it);
--   * a known quest has accept / objective / turn-in steps with map coordinates:
--     era 7 "Kobold Camp Cleanup" (Marshal McBride -> Kobold Vermin slain -> Marshal McBride, Elwynn Forest);
--   * WoW Forever (Interface 16001, NS.flavor "era" + NS.isForever): its own file registers, the era file stays
--     silent there (and the Forever file on Era), Forever-only zones (Zephras Isle) have guides, and a point on a
--     reshaped map (Stormwind City) is converted from the Era map: quest 697 turn-in at Archmage Malin.
-- Generated files are gitignored, so a fresh clone SKIPS (like the other Imported_* checks).
-- Run: luajit tools/test_wiki.lua   (from repo root)
package.path = "./?.lua;" .. package.path
local TOC = { era = 11508, tbc = 20506, mop = 50504, retail = 121500, forever = 16001 }
local RUNS = { forever = "era" }   -- NS.flavor each client must report
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

-- map resolution regressions (tools/wiki/wikimaps.py, tools/maps_*.lua): runs on a fresh clone too.  A subzone map the
-- client lacks lands on its parent zone (Valley of Trials used to land in The Barrens), a zone only one client has is
-- read on that client's maps (Zephras Isle), a subzone row contradicted by its parent-zone row is seen as such (Gornek)
do
    local rc = os.execute("python3 tools/wiki/wikimaps.py")
    check(rc == 0 or rc == true, "tools/wiki/wikimaps.py regression checks failed")
end

local ran = 0
for _, flavor in ipairs({ "era", "tbc", "mop", "retail", "forever" }) do
    local path = "Guides/Imported_Wiki_" .. flavor .. ".lua"
    local fh = io.open("CompletionRoute/" .. path, "r")
    if not fh then
        print("skip " .. path .. " (generated locally, gitignored: tools/wiki/gen_wiki_guides.py)")
    else
        local head = fh:read(4000) fh:close()
        check(head:find("CC BY%-SA 4%.0") and head:find("warcraft%.wiki%.gg"), flavor .. ": CC BY-SA 4.0 attribution header missing")
        ran = ran + 1
        local NS, load = harness(flavor)
        check(NS.flavor == (RUNS[flavor] or flavor), ("harness flavor %s ~= %s"):format(tostring(NS.flavor), RUNS[flavor] or flavor))
        check((NS.isForever and true or false) == (flavor == "forever"), flavor .. ": NS.isForever is " .. tostring(NS.isForever))
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
        -- Gornek's quests, in the Valley of Trials: on the clients without that map they belong on Durotar near 43,68
        -- (the point used to land in The Barrens); with the map, on it, at the spot his Durotar row names, never at his
        -- later location in Spires of Arak
        if flavor == "era" or flavor == "tbc" or flavor == "forever" then
            local ok = 0
            for _, st in ipairs(byQ[787] or {}) do
                if st.action == "T" and st.coords then
                    ok = ok + 1
                    local c = st.coords[1]
                    check(st.zone == 1411, ("%s quest 787 turn-in on map %s, want Durotar 1411"):format(flavor, tostring(st.zone)))
                    check(math.abs(c.x * 100 - 43.2) < 2 and math.abs(c.y * 100 - 68.2) < 2,
                        ("%s quest 787 turn-in at %.1f,%.1f, want near 43.2,68.2"):format(flavor, c.x * 100, c.y * 100))
                end
            end
            check(ok >= 1, flavor .. ": quest 787 has no located turn-in")
            for _, q in ipairs({ 787, 804, 3065, 3082, 3083, 3084, 3085, 3086, 3087, 3089 }) do
                for _, st in ipairs(byQ[q] or {}) do
                    check(st.zone ~= 1413, ("%s starter quest %d %s is on The Barrens"):format(flavor, q, st.action))
                end
            end
        end
        if flavor == "retail" then
            local ok = 0
            for _, st in ipairs(byQ[25172] or {}) do
                if st.coords then
                    ok = ok + 1
                    local c = st.coords[1]
                    check(st.zone == 461, ("retail quest 25172 %s on map %s, want Valley of Trials 461"):format(st.action, tostring(st.zone)))
                    check(math.abs(c.x * 100 - 44.8) < 1 and math.abs(c.y * 100 - 66.2) < 1,
                        ("retail quest 25172 %s at %.1f,%.1f, want near 44.8,66.2"):format(st.action, c.x * 100, c.y * 100))
                end
            end
            check(ok >= 1, "retail: quest 25172 has no located step")
        end
        if flavor == "forever" then
            local zeph = 0
            for _, id in ipairs(NS.Guide.list) do
                local g = NS.Guide.registry[id]
                if id:find("^wiki:forever:") and (g.zone == 2521 or g.zone == 2665) then zeph = zeph + 1 end
                check(not id:find("^wiki:forever:") or g.forever == true, "forever guide " .. id .. " lacks forever=true")
            end
            check(zeph > 0, "forever: no Zephras Isle guide")
            -- Zephras Isle's points come from the wiki now: count steps there not tagged as coming from another source
            local onIsle, fromWiki = 0, 0
            for _, id in ipairs(NS.Guide.list) do
                local g = NS.Guide.registry[id]
                if id:find("^wiki:forever:") then
                    for ln in g.text:gmatch("[^\n]+") do
                        if ln:find("|Z|2521", 1, true) or ln:find("|Z|2665", 1, true) then
                            onIsle = onIsle + 1
                            if ln:find("|M|", 1, true) and not ln:find("(location:", 1, true) then fromWiki = fromWiki + 1 end
                        end
                    end
                end
            end
            check(fromWiki >= 50, ("forever: only %d of %d Zephras Isle steps have a wiki coordinate"):format(fromWiki, onIsle))
            print(("forever Zephras Isle: %d steps, %d with a wiki coordinate"):format(onIsle, fromWiki))
            -- quest 697 Malin's Request turn-in: Era map 39.8,81.5 on Stormwind City (1453) = the same spot on Forever's
            -- larger Stormwind map (Data/MapFix_forever.lua); the generator converts it (fallback point)
            local t
            for _, st in ipairs(byQ[697] or {}) do if st.action == "T" then t = st end end
            check(t and t.zone == 1453 and t.coords, "forever quest 697 turn-in has no Stormwind point")
            if t and t.coords then
                local c = t.coords[1]
                check(math.abs(c.x * 100 - 50.5) < 1 and math.abs(c.y * 100 - 87.5) < 1,
                    ("forever quest 697 turn-in at %.1f,%.1f, want ~50.5,87.5 (converted from Era 39.8,81.5)"):format(c.x * 100, c.y * 100))
            end
            -- the runtime converter (Core/Util.lua) does the same for Era-sourced guides on Forever
            load("Data/MapFix_forever.lua")
            local x, y = NS.Util.EraToForever(1453, 0.398, 0.815)
            check(math.abs(x * 100 - 50.5) < 0.2 and math.abs(y * 100 - 87.5) < 0.2,
                ("U.EraToForever(1453, 39.8, 81.5) = %.1f,%.1f, want ~50.5,87.5"):format(x * 100, y * 100))
            local x2, y2 = NS.Util.EraToForever(1429, 0.5, 0.5)
            check(x2 == 0.5 and y2 == 0.5, "U.EraToForever must leave an unchanged map (Elwynn) alone")
            print(("forever Zephras Isle guides %d; Stormwind 39.8,81.5 -> %.1f,%.1f OK"):format(zeph, x * 100, y * 100))
        end
        -- flavor gate: another client loading this file registers nothing (Forever and Era both run NS.flavor "era")
        local others = flavor == "era" and { "tbc", "forever" } or (flavor == "forever" and { "era", "tbc" } or { "era" })
        for _, other in ipairs(others) do
            local NS2, load2 = harness(other)
            load2(path)
            local leaked = 0
            for _, id in ipairs(NS2.Guide.list) do if id:find("^wiki:" .. flavor .. ":") then leaked = leaked + 1 end end
            check(leaked == 0, ("%s wiki guides registered on a %s client (%d)"):format(flavor, other, leaked))
        end
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Generated leveling spine (tools/wiki/gen_spine.py -> Guides/Imported_Spine_<flavor>.lua) and the guide split:
--   * every wiki guide has at most 250 steps (huge zone guides are split into level-band / storyline parts);
--   * inside every guide each quest reads A before its C steps before its T;
--   * per faction the spine is one chain (001 -> next -> ... -> nil) over existing wiki guides, and playing it in
--     order never reaches an accept whose prerequisites (wiki previous/next, "any one of") are all still ahead:
--     0 PRE violations;
--   * era: Kobold Camp Cleanup is still A -> C -> T, after A Threat Within's turn-in on the Alliance spine.
-- ---------------------------------------------------------------------------------------------------------------
local MAXSTEPS = 250
local spineRan = 0
for _, flavor in ipairs({ "era", "tbc", "mop", "retail", "forever" }) do
    local wpath, spath = "Guides/Imported_Wiki_" .. flavor .. ".lua", "Guides/Imported_Spine_" .. flavor .. ".lua"
    local fs = io.open("CompletionRoute/" .. spath, "r")
    local fw = io.open("CompletionRoute/" .. wpath, "r")
    if fw then fw:close() end
    if not (fs and fw) then
        if fs then fs:close() end
        -- a wiki file without its spine would skip the size / A<C<T checks below (Forever did, with 467-step guides)
        check(not fw, flavor .. ": " .. wpath .. " exists but " .. spath .. " is missing (re-run gen_wiki_guides.py)")
        if not fw then print("skip " .. spath .. " (generated locally, gitignored: tools/wiki/gen_spine.py)") end
    else
        fs:close()
        spineRan = spineRan + 1
        local NS, load = harness(flavor)
        load(wpath)
        load(spath)
        local G = NS.Guide
        if flavor == "forever" then
            -- spine entries copy Forever-map text: without forever=true Guide.lua converts their points a second time
            local bad = 0
            for _, id in ipairs(G.list) do
                if id:find("^spine:forever:") and not G.registry[id].forever then bad = bad + 1 end
            end
            check(bad == 0, ("forever: %d spine entries lack forever=true"):format(bad))
        end
        -- guide size + A/C/T order inside every wiki guide
        local big, badOrder, wiki, justified = 0, 0, 0, 0
        for _, id in ipairs(G.list) do
            if id:find("^wiki:" .. flavor .. ":") then
                wiki = wiki + 1
                local steps = G.Steps(id)
                if #steps > MAXSTEPS then
                    -- allowed only with the generator's written reason (a cross-zone PRE loop it could not cut)
                    if NS.Guide.registry[id].oversize then justified = justified + 1
                    else big = big + 1 if big <= 3 then print("  over " .. MAXSTEPS .. ": " .. id .. " " .. #steps) end end
                end
                local seen = {}
                for _, st in ipairs(steps) do
                    local q = st.qid and st.qid[1]
                    if q then
                        -- a quest may appear twice in one guide as two FACTION-gated copies
                        local k = q .. "@" .. tostring(st.faction or "")
                        local s = seen[k] or {}
                        seen[k] = s
                        if st.action == "A" then if s.C or s.T then badOrder = badOrder + 1 end s.A = true
                        elseif st.action == "C" then if s.T or not s.A then badOrder = badOrder + 1 end s.C = true
                        elseif st.action == "T" then if not s.A then badOrder = badOrder + 1 end s.T = true end
                    end
                end
            end
        end
        check(big == 0, ("%s: %d wiki guides over %d steps"):format(flavor, big, MAXSTEPS))
        check(badOrder == 0, ("%s: %d steps out of A < C < T order inside a guide"):format(flavor, badOrder))
        for _, fk in ipairs({ { "A", "Alliance" }, { "H", "Horde" } }) do
            local k, fac = fk[1], fk[2]
            local first = G.registry[("spine:%s:%s:001"):format(flavor, k)]
            check(first ~= nil, flavor .. " " .. fac .. ": spine has no first guide")
            -- walk the chain
            local chain, seenIds, g = {}, {}, first
            while g do
                check(not seenIds[g.id], flavor .. ": spine loops at " .. g.id)
                if seenIds[g.id] then break end
                seenIds[g.id] = true
                chain[#chain + 1] = g
                check(g.type == "Leveling" and g.folder == "Leveling (generated)" and g.faction == fac,
                    flavor .. ": spine guide " .. g.id .. " type/folder/faction wrong")
                check(G.registry[g.part] ~= nil, flavor .. ": spine guide " .. g.id .. " points at missing " .. tostring(g.part))
                g = g.next and G.registry[g.next] or nil
            end
            local count = 0
            for _, id in ipairs(G.list) do if id:find(("^spine:%s:%s:"):format(flavor, k)) then count = count + 1 end end
            check(#chain == count, ("%s %s: chain reaches %d of %d spine guides"):format(flavor, fac, #chain, count))
            -- play the chain: which quests does this faction's spine contain, and does every accept find a prerequisite done?
            local inSpine, hasT = {}, {}
            for _, sg in ipairs(chain) do
                for _, st in ipairs(G.Steps(sg.id)) do
                    local q = st.qid and st.qid[1]
                    if q and (not st.faction or st.faction == fac) then
                        inSpine[q] = true
                        if st.action == "T" then hasT[q] = true end
                    end
                end
            end
            local turned, accepted, viol, checked = {}, {}, 0, 0
            for _, sg in ipairs(chain) do
                for _, st in ipairs(G.Steps(sg.id)) do
                    local q = st.qid and st.qid[1]
                    if q and (not st.faction or st.faction == fac) then
                        if st.action == "A" then
                            if st.pre and #st.pre > 0 then
                                local any, ok = false, false
                                for _, p in ipairs(st.pre) do
                                    if inSpine[p] then
                                        any = true
                                        if turned[p] or (not hasT[p] and accepted[p]) then ok = true end
                                    end
                                end
                                if any then
                                    checked = checked + 1
                                    if not ok then
                                        viol = viol + 1
                                        if viol <= 3 then print(("  PRE violation %s %s: %s quest %d"):format(flavor, fac, sg.id, q)) end
                                    end
                                end
                            end
                            accepted[q] = true
                        elseif st.action == "T" then turned[q] = true end
                    end
                end
            end
            check(viol == 0, ("%s %s: %d PRE violations along the spine"):format(flavor, fac, viol))
            print(("%-6s spine %-8s %4d guides, %5d accepts with an in-spine prerequisite, %d PRE violations")
                :format(flavor, fac, #chain, checked, viol))
            if flavor == "era" and fac == "Alliance" then
                local pos, idx = {}, 0
                for _, sg in ipairs(chain) do
                    for _, st in ipairs(G.Steps(sg.id)) do
                        idx = idx + 1
                        local q = st.qid and st.qid[1]
                        if q == 7 or q == 783 then pos[q .. st.action] = pos[q .. st.action] or idx end
                    end
                end
                check(pos["7A"] and pos["7C"] and pos["7T"] and pos["7A"] < pos["7C"] and pos["7C"] < pos["7T"],
                    "era spine: Kobold Camp Cleanup is not A -> C -> T")
                check(pos["783T"] and pos["7A"] and pos["783T"] < pos["7A"], "era spine: Kobold Camp Cleanup accepted before A Threat Within turned in")
                print("era    spine: Kobold Camp Cleanup A/C/T in order, after A Threat Within OK")
            end
        end
        print(("%-6s %d wiki guides, none over %d steps without a reason (%d justified), A<C<T inside every guide")
            :format(flavor, wiki, MAXSTEPS, justified))
    end
end
if fail > 0 then print(fail .. " wiki guide check(s) failed") os.exit(1) end
print(ran > 0 and "ALL WIKI GUIDE TESTS PASSED" or "wiki guide tests SKIPPED (no Imported_Wiki_*.lua generated)")
