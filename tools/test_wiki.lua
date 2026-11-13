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
        -- 2026-11-11, where a step's point came from (tools/wiki/gen_wiki_guides.py): a zone-level step names the quest's
        -- zone and has no point; a place-page or quest-POI step has one; retail no longer puts a wiki point on map 41 (a
        -- Deadwind Pass micro map called "Dalaran" that the lowest-id rule used to pick for the city)
        do
            local zoneOnly, place, poi, bad41, contrib, detail = 0, 0, 0, 0, 0, 0
            for _, id in ipairs(NS.Guide.list) do
                if id:find("^wiki:" .. flavor .. ":") then
                    for ln in NS.Guide.registry[id].text:gmatch("[^\n]+") do
                        if ln:find("No coordinates on the wiki; the quest is in", 1, true) then
                            zoneOnly = zoneOnly + 1
                            check(ln:find("|Z|%d+") and not ln:find("|M|", 1, true), flavor .. ": zone-level step without a zone or with a point: " .. ln:sub(1, 90))
                        end
                        -- 2026-11-12: a step with no point says what the wiki knows about where (tools/wiki/step_detail.py):
                        -- only such a step, in whole sentences of at most 220 characters, with no markup
                        if ln:find("No exact spot on the wiki.", 1, true) then
                            detail = detail + 1
                            local d = ln:match("No exact spot on the wiki%. ([^|]*)|$")
                            check(not ln:find("|M|", 1, true), flavor .. ": a step with a point says it has no exact spot: " .. ln:sub(1, 90))
                            check(d and #d >= 12 and #d <= 220 and d:find("[%.!%?]$") and not d:find("[%[%]{}<>=]") and not d:find("''", 1, true),
                                flavor .. ": the detail of a step with no point is not clean text: " .. tostring(d))
                        end
                        if ln:find("(location: the wiki's", 1, true) then
                            place = place + 1
                            check(ln:find("|M|[%d.]+,[%d.]+") and ln:find("|Z|%d+"), flavor .. ": place-page step without a point: " .. ln:sub(1, 90))
                        end
                        if ln:find("(location: Blizzard quest POI", 1, true) then
                            poi = poi + 1
                            check(flavor == "retail" and ln:find("|M|[%d.]+,[%d.]+|Z|%d+"), flavor .. ": quest-POI step off retail or without a point: " .. ln:sub(1, 90))
                        end
                        -- 2026-11-12: a point players contributed (docs/CONTRIBUTE.md) says so and how many players
                        if ln:find("(location: player contributions", 1, true) then
                            contrib = contrib + 1
                            check(ln:find("|M|[%d.]+,[%d.]+") and ln:find("|Z|%d+") and ln:find("%(location: player contributions, %d+ players?[,)]"),
                                flavor .. ": player-contributed step without a point or a player count: " .. ln:sub(1, 90))
                        end
                        -- the client's own quest pins do use map 41 for a few Legion quests; only wiki points must not
                        if flavor == "retail" and ln:find("|Z|41;", 1, true) and not ln:find("(location: Blizzard", 1, true) then bad41 = bad41 + 1 end
                    end
                end
            end
            check(bad41 == 0, ("retail: %d steps on map 41 (Deadwind Pass 'Dalaran')"):format(bad41))
            -- such steps ship only under a header that names the data repository and the commit of the merged areas
            check(contrib == 0 or (head:find("merged player contributions, wow-completionist-data", 1, true) and head:find("CC BY%-SA 4%.0%), commit %x+")),
                flavor .. ": " .. contrib .. " player-contributed steps but the file header does not name the data repository and its commit")
            print(("%-6s zone-level steps (old wording) %d, steps with the wiki's words about where %d, wiki place-page points %d, client quest-POI points %d, player-contributed points %d"):format(flavor, zoneOnly, detail, place, poi, contrib))
        end
        -- 2026-11-11 review: a zone-level step names the map the NPC's own page names, not the quest-log category; a
        -- WoD quest's zone is Draenor's; a place page gives only its own point (not a portal, quest or note listed on it,
        -- not a WoW Forever coordinate), and on the Classic clients not a place made or moved at the Cataclysm
        local function first(q, act)
            for _, st in ipairs(byQ[q] or {}) do if st.action == act then return st end end
        end
        local function near(st, x, y)
            local c = st and st.coords and st.coords[1]
            return c and math.abs(c.x * 100 - x) < 1 and math.abs(c.y * 100 - y) < 1
        end
        if flavor == "era" or flavor == "tbc" or flavor == "forever" then
            local orgr = { era = 1454, tbc = 1454, forever = 1454 }
            local a = first(7241, "A")    -- In Defense of Frostwolf: filed under the battleground, given in Orgrimmar
            check(a and a.zone == orgr[flavor], ("%s quest 7241 accept on map %s, want Orgrimmar (Rokhstrom's page)"):format(flavor, tostring(a and a.zone)))
            local t = first(510, "T")     -- Foreboding Plans: filed under Alterac Mountains, Henry Maleb is in Southshore
            check(t and t.zone == 1424, ("%s quest 510 turn-in on map %s, want Hillsbrad Foothills 1424"):format(flavor, tostring(t and t.zone)))
            a = first(1518, "A")          -- Call of Earth: Zephras Isle's portal point exists only on WoW Forever's maps
            check(a and a.zone ~= 1416, ("%s quest 1518 accept on Alterac Mountains (a Forever-only coordinate)"):format(flavor))
            a = first(953, "A")           -- The Fall of Ameth'Aran: not a point from the Ruins of Mathystra page's NPC list
            check(a and not near(a, 59.3, 22.8), ("%s quest 953 accept uses the Ruins of Mathystra page's section point"):format(flavor))
            a = first(1920, "A")          -- Investigate the Blue Recluse: not the Wizard's Sanctum page's portal list
            check(a and not near(a, 38.0, 87.3), ("%s quest 1920 accept uses the Wizard's Sanctum portal list"):format(flavor))
            -- Vivian Lagrave: Shadowmage Vivian Lagrave stands in the Undercity since the Cataclysm; her page says she
            -- "was located at [[Kargath]], [[Badlands]]" before it, which is where she is on these clients
            t = first(4133, "T")
            check(t and t.zone == 1418, ("%s quest 4133 turn-in on map %s, want the Badlands 1418 (pre-Cataclysm place)"):format(flavor, tostring(t and t.zone)))
            local lordanel, raven = 0, 0  -- Lor'danel replaced Auberdine at patch 4.0.3
            for _, id in ipairs(NS.Guide.list) do
                local text = id:find("^wiki:" .. flavor .. ":") and NS.Guide.registry[id].text or ""
                if text:find("(location: the wiki's Lor'danel page", 1, true) then lordanel = lordanel + 1 end
                -- Duke Hydraxis stood "on an island northeast of the [[Ravencrest Monument]]": a landmark, not his place
                if text:find("(location: the wiki's Ravencrest Monument page", 1, true) then raven = raven + 1 end
            end
            check(lordanel == 0, ("%s: %d steps placed at Lor'danel, a Cataclysm town"):format(flavor, lordanel))
            check(raven == 0, ("%s: %d steps placed at the Ravencrest Monument, a landmark Duke Hydraxis stood northeast of"):format(flavor, raven))
        end
        if flavor == "tbc" or flavor == "mop" then
            local t = first(11371, "T")   -- WANTED: Coilfang Myrmidons: not the Lower City page's rewards/quests list
            check(t and not near(t, 62.0, 68.8) and not near(t, 48.0, 18.0), ("%s quest 11371 turn-in uses the Lower City page's section points"):format(flavor))
        end
        if flavor == "retail" then
            local wod = 0
            for _, id in ipairs(NS.Guide.list) do
                if id:find("^wiki:retail:") then
                    for ln in NS.Guide.registry[id].text:gmatch("[^\n]+") do
                        local q = tonumber(ln:match("|QID|(%d+)|"))
                        if q and q >= 33000 and q < 37000 and ln:find("|Z|104;", 1, true) and ln:find("the quest is in", 1, true) then wod = wod + 1 end
                    end
                end
            end
            check(wod == 0, ("retail: %d Warlords quest steps sent to Outland's Shadowmoon Valley (104)"):format(wod))
            local c = first(33786, "C")   -- Crippled Caravan, filed under "Shadowmoon Valley (alternate universe)"
            check(c and c.zone == 539, ("retail quest 33786 objective on map %s, want Draenor's Shadowmoon Valley 539"):format(tostring(c and c.zone)))
        end
        -- Blasted Lands (2026-11-11): Daio the Decrepit's and Kum'isha's wiki numbers predate patch 4.0.3, so they are
        -- Classic-map numbers and stay as written on the Classic clients (they used to move 5.5 units through the retail
        -- map).  Needs the page history (tools/wiki/fetch_coord_history.py): without it the check says SKIP, loudly,
        -- because the guide files were then built without the Classic marks.
        local hist = io.open("tools/wiki/cache/coord_history.sqlite", "rb")
        if hist then hist:close() end
        if (flavor == "era" or flavor == "tbc") and not hist then
            print(("  SKIP %s Blasted Lands Classic-map check: tools/wiki/cache/coord_history.sqlite is missing "
                .. "(run tools/wiki/fetch_coord_history.py, then gen_wiki_guides.py)"):format(flavor))
        elseif flavor == "era" or flavor == "tbc" then
            for q, want in pairs({ [7581] = { 34.0, 50.0 }, [2521] = { 52.0, 36.0 } }) do
                local a
                for _, st in ipairs(byQ[q] or {}) do if st.action == "A" then a = st end end
                local c = a and a.coords and a.coords[1]
                check(a and a.zone == 1419 and c and math.abs(c.x * 100 - want[1]) < 0.2 and math.abs(c.y * 100 - want[2]) < 0.2,
                    ("%s quest %d accept at %s %s, want Blasted Lands %.1f,%.1f"):format(flavor, q, tostring(a and a.zone),
                        c and ("%.1f,%.1f"):format(c.x * 100, c.y * 100) or "-", want[1], want[2]))
            end
        end
        if flavor == "retail" then
            local ok = 0
            for _, st in ipairs(byQ[25172] or {}) do
                if st.coords and (st.action == "A" or st.action == "T") then
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
            -- quest 697 Malin's Request turn-in: the wiki has no point for it, so the step names Stormwind City (1453),
            -- where Archmage Malin's own page puts him, not the quest's Arathi Highlands category.
            local t
            for _, st in ipairs(byQ[697] or {}) do if st.action == "T" then t = st end end
            check(t and t.zone == 1453 and not t.coords, "forever quest 697 turn-in should be a Stormwind City zone-level step")
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
