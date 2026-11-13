-- CompletionRoute :: tools/gen_quest_index.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
-- https://batesai.org  help@batesai.org
--
-- Quest index per client, for the quest counts in the routes list (Core/QuestCounts.lua, docs/QUEST_COUNTS.md).
--
--   luajit -joff tools/gen_quest_index.lua [era tbc mop retail forever] [--out DIR] [--check]
--
-- Input : every route file the client's TOC loads (Guides/Imported_*_<fl>.lua and the hand-written ones), parsed with
--         the addon's own parser (tools/guide_walk.lua).  Run it AFTER the route files are regenerated: an entry
--         carries the length of the route text it was made from, and the addon ignores an entry whose length does not
--         match (it then parses that route instead, which is slower but gives the same numbers).
-- Output: CompletionRoute/Data/QuestIndex_<fl>.lua (generated, gitignored; a client loads only its own, by its TOC).
--         --out DIR writes there instead.  --check writes nothing: it compares what it would write with the file
--         that is there and exits 1 when they differ (the first line, which holds the date, is not compared).
--
-- One line per QUEST ROUTE (a route that turns a quest in, other than gold and profession routes, whose text is its
-- own: a leveling chain entry reads its zone route's line):
--   ["route id"]="<text length>|<quest ids for everyone>|<n>:<quest ids for restriction n>|..."
-- and one per route that turns NO quest in (gold circuits, most profession routes, achievement lists, missions):
--   ["route id"]="<text length>"
-- so the routes list knows without parsing it that such a route is finished by its ticks alone.  A gold or
-- profession route that does turn a quest in is not listed (the addon parses it, as it always did).
-- conds[n] is a restriction, "faction<TAB>class list<TAB>race list" as the steps' FACTION, C and R tags spell them.
-- The ids are worked out by Core/QuestCounts.lua QC.Groups, the function the addon itself uses for a route this file
-- does not list, so the two cannot disagree (tools/test_quest_counts.lua compares them on every route of every client).
local W = dofile("tools/guide_walk.lua")

local want, outDir, check = {}, "CompletionRoute/Data", false
do
    local i = 1
    while arg and arg[i] do
        local a = arg[i]
        if a == "--out" then i = i + 1 outDir = assert(arg[i], "--out needs a folder")
        elseif a == "--check" then check = true
        elseif a:sub(1, 2) == "--" then error("unknown option " .. a)
        else want[a] = true end
        i = i + 1
    end
end

local function generate(fl)
    local routes, conds, condIndex, plain = {}, {}, {}, 0
    local allQuests, nQuests = {}, 0
    local cur, curSteps
    local NSref
    local function flush()
        if not cur then return end
        local g, steps = cur, curSteps
        cur, curSteps = nil, nil
        local NS = NSref
        local G, QC = NS.Guide, NS.QuestCounts
        if type(g.text) ~= "string" then return end
        local groups = QC.Groups(steps)
        if not groups.quest then
            plain = plain + 1
            routes[#routes + 1] = { id = g.id, line = tostring(#g.text) }
            return
        end
        if g.loop or G.IsSideGuide(g) then return end
        local parts = { tostring(#g.text), table.concat(groups.by[""] or {}, ",") }
        for _, sig in ipairs(groups.sigs) do
            if sig ~= "" then
                local ci = condIndex[sig]
                if not ci then conds[#conds + 1] = sig ci = #conds condIndex[sig] = ci end
                parts[#parts + 1] = ci .. ":" .. table.concat(groups.by[sig], ",")
            end
            for _, q in ipairs(groups.by[sig]) do
                if not allQuests[q] then allQuests[q] = true nQuests = nQuests + 1 end
            end
        end
        routes[#routes + 1] = { id = g.id, line = table.concat(parts, "|") }
    end
    local _, missing, errors = W.Walk(fl, function(s, g, _, NS)
        if cur == g then curSteps[#curSteps + 1] = s end
    end, function(g, _, NS, reused)
        NSref = NS
        flush()
        if not reused then cur, curSteps = g, {} end
    end)
    flush()
    for _, e in ipairs(errors) do io.stderr:write("LOAD ERROR " .. fl.name .. ": " .. e .. "\n") end
    if #errors > 0 then os.exit(1) end
    local out = {}
    local function w(str) out[#out + 1] = str end
    w(("-- Completionist's Guide :: QuestIndex_%s.lua - GENERATED %s by tools/gen_quest_index.lua"):format(fl.name, os.date("%Y-%m-%d")))
    w("-- The quest ids each quest route names, for the quest counts in the routes list (Core/QuestCounts.lua).  Made from")
    w(("-- the route files this client loads: Imported_Wiki_%s.lua and what is built on it (Warcraft Wiki,"):format(fl.name))
    w("-- https://warcraft.wiki.gg, CC BY-SA 4.0, see Guides/WIKI_DATA_LICENSE.md; quest membership: Blizzard client data).")
    w("-- r: [\"route id\"]=\"<route text length>|<ids for everyone>|<n>:<ids for conds[n]>|...\"; conds[n]:")
    w("-- \"faction<TAB>class list<TAB>race list\".  A route that turns no quest in has its text length only.")
    w("-- Generated, gitignored.  Re-run after the route files change.")
    w("local _, NS = ...")
    w(("if (NS.dataFlavor or NS.flavor) ~= %q then return end"):format(fl.name))
    w(("NS.QuestIndex = { flavor = %q, v = 1, routes = %d, quests = %d, noquest = %d,"):format(fl.name, #routes - plain, nQuests, plain))
    w("conds = {")
    for _, sig in ipairs(conds) do w(("%q,"):format(sig)) end
    w("},")
    w("r = {")
    for _, r in ipairs(routes) do w(("[%q]=%q,"):format(r.id, r.line)) end
    w("} }")
    return table.concat(out, "\n") .. "\n", #routes - plain, nQuests, missing, plain
end

local function body(text) return (text:gsub("^[^\n]*\n", "", 1)) end

local bad = 0
for _, fl in ipairs(W.FLAVORS) do
    if not next(want) or want[fl.name] then
        local text, nr, nq, missing, plain = generate(fl)
        for _, m in ipairs(missing) do
            if not m:match("QuestIndex_") then print("   not generated here: " .. m) end
        end
        local path = outDir .. "/QuestIndex_" .. fl.name .. ".lua"
        if check then
            local fh = io.open(path, "r")
            local have = fh and fh:read("*a")
            if fh then fh:close() end
            if not have then print(("STALE %s: missing"):format(path)) bad = bad + 1
            elseif body(have) ~= body(text) then print(("STALE %s: differs from the route files (re-run tools/gen_quest_index.lua %s)"):format(path, fl.name)) bad = bad + 1
            else print(("ok    %s: %d quest routes, %d quests"):format(path, nr, nq)) end
        else
            local fh = assert(io.open(path, "w"))
            fh:write(text)
            fh:close()
            print(("%s: %d quest routes, %d quests, %d routes without turn-ins, %d KB"):format(path, nr, nq, plain, math.floor(#text / 1024 + 0.5)))
        end
        collectgarbage()
    end
end
if bad > 0 then os.exit(1) end
