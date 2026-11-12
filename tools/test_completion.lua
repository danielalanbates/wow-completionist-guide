-- CompletionRoute :: tools/test_completion.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org
--
-- Offline test of the completionist place rules (tools/gen_completion_guides.py) and of the generated achievement,
-- quest-line and item-quest steps they produce.  Each check is a defect the 2026-11-11 review of branch coverage-ach
-- found in a generated file:
--   * the place rules on synthetic rows (python3 tools/gen_completion_guides.py --selfcheck; runs on a fresh clone):
--     a zone's wiki page gives only the zone, a topic page (profession, holiday, expansion) gives nothing, a name-matched
--     page's point must lie in the achievement's zone, Dalaran / Eversong Woods / Shadowmoon Valley resolve for the
--     achievement's expansion, glyphs take the wiki's {{co}}, an overlay that covers several areas names none of them;
--   * the generated files, when present (gitignored, so a fresh clone SKIPS): every located achievement step names its
--     source; no step on uiMap 41 (Dalaran over Karazhan) unless Blizzard's own quest pin puts it there; no Midnight
--     achievement step on the old Eversong Woods / Silvermoon City maps (94 / 110); Dragon Glyphs: Windsong Rise at the
--     wiki's 61.5, 64.4; Dragon Glyphs: Brackenhide Hollow outdoors, not in the dungeon; Local Pet Mauler's Hellfire
--     Peninsula criterion is that zone, not the Exodar; the Salt of Shards accept is not in Un'Goro Crater; the header
--     says the wiki steps come from Imported_Wiki_<flavor>.lua and nothing in the file credits another addon's data
--     (there is one build: tools/gen_completion_guides.py refuses a wiki file that holds such points).
--   * (2026-11-12) a criterion that takes a quest's point the wiki file got from the client's quest pin credits the
--     pin ("Blizzard QuestPOI, quest N, ..."), never "wiki: <page>" (866 retail criteria did); no step names an
--     internal achievement's marker ([HIDDEN], <Tracking Achievement>, (DNT), <Hidden> ...); no step holds a wiki
--     template brace ("on <Normal/Heroic/Mythic}} difficulty").
-- Run: luajit tools/test_completion.lua   (from repo root)
local fail, ran = 0, 0
local function check(ok, msg) if not ok then print("FAIL " .. msg) fail = fail + 1 end end

do
    local rc = os.execute("python3 tools/gen_completion_guides.py --selfcheck")
    check(rc == 0 or rc == true, "tools/gen_completion_guides.py --selfcheck failed")
end

local function lines(path)
    local fh = io.open(path, "r")
    if not fh then
        print("skip " .. path .. " (generated locally, gitignored: tools/gen_completion_guides.py)")
        return nil
    end
    local out = {}
    for ln in fh:lines() do out[#out + 1] = ln end
    fh:close()
    ran = ran + 1
    return out
end

-- a located step's note ends with its source: "(wiki: <page>)", "(Blizzard ...)", "(zone only; <source>)" (a page
-- title may hold its own parentheses: "(wiki: Charlga Razorflank (Classic))")
local SOURCE = { "%(wiki: [^|]*%)|$", "%(Blizzard [^|]*%)|$", "%(zone only; [^|]*%)|$" }
local function credited(ln)
    for _, p in ipairs(SOURCE) do if ln:find(p) then return true end end
    return false
end

local function header_says_build(ls, name)
    local head = table.concat(ls, "\n", 1, math.min(#ls, 14))
    check(head:find("Wiki steps: from Imported_Wiki_", 1, true),
          name .. ": header does not say its wiki steps come from Imported_Wiki_<flavor>.lua")
    check(not head:find("LOCAL BUILD", 1, true), name .. ": a file of the dev build retired on 2026-11-11 (LOCAL BUILD header)")
    local bad = 0
    for _, ln in ipairs(ls) do
        if ln:find("Questie", 1, true) or ln:find("(location: Blizzard data", 1, true) then bad = bad + 1 end
    end
    check(bad == 0, name .. ": " .. bad .. " line(s) credit another addon's data or a fallback point")
end

-- quest id -> is the point the wiki file gives that quest (its first located T, then A, then C step: the same choice as
-- tools/gen_completion_guides.py located()) a Blizzard quest pin?  nil when the file is missing.
local function pinned_quests(fl)
    local fh = io.open("CompletionRoute/Guides/Imported_Wiki_" .. fl .. ".lua", "r")
    if not fh then return nil end
    local best = {}     -- qid -> { rank, pinned }
    local RANK = { T = 1, A = 2, C = 3 }
    for ln in fh:lines() do
        local act, q = ln:match("^([ACT]) [^|]*|QID|(%d+)|")
        if act and ln:find("|M|[^|]+|Z|[^|]+|") then
            local b = best[q]
            if not b or RANK[act] < b[1] then best[q] = { RANK[act], ln:find("(location: Blizzard quest POI", 1, true) ~= nil } end
        end
    end
    fh:close()
    local out = {}
    for q, b in pairs(best) do out[tonumber(q)] = b[2] end
    return out
end

-- an internal achievement's marker or a wiki template brace in a step line (not in the file header)
local MARKS = { "[HIDDEN]", "[Hidden]", "[DNT]", "<DNT>", "(DNT)", "<DND>", "<Hidden>", "<Tracking Achievement>", "[DO NOT USE]",
    "{{", "}}" }
local function marked(ln)
    if ln:sub(1, 2) == "--" then return nil end
    for _, m in ipairs(MARKS) do if ln:find(m, 1, true) then return m end end
    return nil
end

for _, fl in ipairs({ "retail", "mop" }) do
    local name = "Guides/Imported_Achievements_" .. fl .. ".lua"
    local ls = lines("CompletionRoute/" .. name)
    if ls then
        header_says_build(ls, name)
        local pinned = pinned_quests(fl)
        local wikiPin, marks = 0, 0
        for _, ln in ipairs(ls) do
            local q = ln:match("^C [^|]*|QID|(%d+)|")
            if q and pinned and pinned[tonumber(q)] and ln:find("%(wiki: [^|]*%)|$") and not ln:find("%(wiki: [^|]*%->") then
                wikiPin = wikiPin + 1
                if wikiPin <= 3 then print("  quest pin credited to the wiki: " .. ln:sub(1, 200)) end
            end
            local m = marked(ln)
            if m then
                marks = marks + 1
                if marks <= 3 then print("  " .. m .. ": " .. ln:sub(1, 200)) end
            end
        end
        if pinned then
            check(wikiPin == 0, ("%s: %d criterion step(s) credit the wiki for a point the wiki file took from a Blizzard quest pin"):format(name, wikiPin))
        else
            print("skip the quest-pin credit check of " .. name .. " (no Imported_Wiki_" .. fl .. ".lua)")
        end
        check(marks == 0, ("%s: %d step(s) show an internal marker or a wiki template brace"):format(name, marks))
        local guide, uncredited, on41, legacy, located = "", 0, 0, 0, 0
        local glyph, brack, hellfire = nil, nil, nil
        for _, ln in ipairs(ls) do
            local g = ln:match('^R%({ id="[^"]*", name="([^"]*)"')
            if g then guide = g end
            if ln:sub(1, 2) == "C " and ln:find("|Z|%d+;") then
                located = located + 1
                if not credited(ln) then
                    uncredited = uncredited + 1
                    if uncredited <= 3 then print("  no source: " .. ln:sub(1, 200)) end
                end
                if ln:find("|Z|41;", 1, true) and not ln:find("Blizzard QuestPOI", 1, true) then on41 = on41 + 1 end
                if guide:find("Midnight", 1, true) and (ln:find("|Z|94;", 1, true) or ln:find("|Z|110;", 1, true)) then
                    legacy = legacy + 1
                end
            end
            if ln:find("^C Dragon Glyphs: Windsong Rise|ACH|16063|FIXED|") then glyph = ln end
            if ln:find("^C Dragon Glyphs: Brackenhide Hollow|ACH|16068|FIXED|") then brack = ln end
            if ln:find("^C Hellfire Peninsula|ACH|6558;") then hellfire = ln end
        end
        check(located > 0, name .. ": no located step")
        check(uncredited == 0, ("%s: %d located step(s) do not name their source"):format(name, uncredited))
        check(on41 == 0, ("%s: %d step(s) on uiMap 41 (Dalaran over Karazhan) not from a Blizzard quest pin"):format(name, on41))
        check(legacy == 0, ("%s: %d Midnight step(s) on the old Eversong Woods / Silvermoon City maps"):format(name, legacy))
        if fl == "retail" then
            check(glyph and glyph:find("|M|61.5,64.4|Z|2023;", 1, true), "Dragon Glyphs: Windsong Rise not at the wiki's point: " .. tostring(glyph))
            check(brack and not brack:find("|Z|2096;", 1, true) and brack:find("|Z|2024;", 1, true),
                  "Dragon Glyphs: Brackenhide Hollow not in the Azure Span: " .. tostring(brack))
            check(hellfire and hellfire:find("|Z|100; Hellfire Peninsula|", 1, true) and not hellfire:find("|M|", 1, true),
                  "Local Pet Mauler's Hellfire Peninsula criterion: " .. tostring(hellfire))
        end
    end
end

do
    local ls = lines("CompletionRoute/Guides/Imported_QuestLines_retail.lua")
    if ls then
        header_says_build(ls, "Guides/Imported_QuestLines_retail.lua")
        local braces = 0
        for _, ln in ipairs(ls) do
            if ln:sub(1, 2) ~= "--" and (ln:find("{{", 1, true) or ln:find("}}", 1, true)) then
                braces = braces + 1
                if braces <= 3 then print("  wiki brace: " .. ln:sub(1, 200)) end
            end
        end
        check(braces == 0, ("Guides/Imported_QuestLines_retail.lua: %d step(s) hold a wiki template brace"):format(braces))
    end
end

do
    local ls = lines("CompletionRoute/Guides/Imported_Wiki_retail.lua")
    if ls then
        local n = 0
        for _, ln in ipairs(ls) do
            if ln:find("^A Salt of Shards|QID|4575[79]|") then
                n = n + 1
                check(not ln:find("|Z|78;", 1, true), "Salt of Shards accept placed in Un'Goro Crater (Silithus page's geography row): " .. ln)
            end
        end
        check(n > 0, "Salt of Shards accept (quests 45749 / 45757) missing from Imported_Wiki_retail.lua")
    end
end

print(("test_completion: %d generated file(s) checked, %d failure(s)"):format(ran, fail))
if fail > 0 then os.exit(1) end
print("ALL COMPLETION TESTS PASSED")
