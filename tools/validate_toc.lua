-- Validates every CompletionRoute *.toc: listed files exist, Interface directive present,
-- no duplicate entries, SavedVariables consistent across flavors.
-- Run: luajit tools/validate_toc.lua   (from repo root)
local tocs = { "CompletionRoute.toc", "CompletionRoute_Mists.toc", "CompletionRoute_TBC.toc", "CompletionRoute_Vanilla.toc",
               "CompletionRoute_Forever.toc", "CompletionRoute_Camelot.toc" }
-- per-TOC must-haves: the Interface number the client reports, and data files the flavor depends on
local REQUIRE = {
    ["CompletionRoute_Vanilla.toc"] = { iface = "11508", files = { "Guides/Imported_Wiki_era.lua" } },
    ["CompletionRoute_Forever.toc"] = { iface = "16001", files = { "Data/Taxi_forever.lua", "Data/MapFix_forever.lua",
        "Guides/Imported_Wiki_forever.lua", "Guides/Imported_Quests_forever_gaps.lua" },
        forbid = { "Guides/Imported_Wiki_era.lua", "Guides/Imported_Quests_era_gaps.lua" } },
}
REQUIRE["CompletionRoute_Camelot.toc"] = REQUIRE["CompletionRoute_Forever.toc"]
-- every flavor loads its own baked route order (tools/optimize_routes.py; generated, gitignored) and no other
local ROUTE_ORDER = { ["CompletionRoute.toc"] = "retail", ["CompletionRoute_Mists.toc"] = "mop", ["CompletionRoute_TBC.toc"] = "tbc",
    ["CompletionRoute_Vanilla.toc"] = "era", ["CompletionRoute_Forever.toc"] = "forever", ["CompletionRoute_Camelot.toc"] = "forever" }
local bodies = {}
local fail = 0
local savedvars = {}
for _, toc in ipairs(tocs) do
    local path = "CompletionRoute/" .. toc
    local fh = io.open(path, "r")
    if not fh then print("FAIL " .. toc .. ": missing"); fail = fail + 1 else
        local seen, hasInterface, n = {}, false, 0
        local body, iface = {}, ""
        for line in fh:lines() do
            line = line:gsub("\r$", "")
            body[#body + 1] = line
            if line:match("^## Interface:") then hasInterface = true iface = line end
            local sv = line:match("^## SavedVariables: (.+)")
            if sv then savedvars[toc] = sv end
            if line ~= "" and not line:match("^##") and not line:match("^#") then
                local rel = line:gsub("\\", "/")
                n = n + 1
                if seen[rel] then print("FAIL " .. toc .. ": duplicate " .. rel); fail = fail + 1 end
                seen[rel] = true
                local f = io.open("CompletionRoute/" .. rel, "r")
                if f then f:close()
                elseif rel:match("^Guides/Imported_") or rel:match("^Data/Imported_") or rel:match("^Data/RouteOrder_") or rel:match("^Data/QuestDeps_") then
                    print("skip " .. toc .. ": " .. rel .. " (baked locally, gitignored)")
                else print("FAIL " .. toc .. ": missing file " .. rel); fail = fail + 1 end
            end
        end
        fh:close()
        bodies[toc] = table.concat(body, "\n")
        if not hasInterface then print("FAIL " .. toc .. ": no ## Interface"); fail = fail + 1 end
        local req = REQUIRE[toc]
        if req then
            local list = {}
            for v in iface:gmatch("%d+") do list[v] = true end
            if not list[req.iface] then print("FAIL " .. toc .. ": ## Interface lacks " .. req.iface); fail = fail + 1 end
            for _, f in ipairs(req.files or {}) do
                if not seen[f] then print("FAIL " .. toc .. ": does not load " .. f); fail = fail + 1 end
            end
            for _, f in ipairs(req.forbid or {}) do
                if seen[f] then print("FAIL " .. toc .. ": must not load " .. f); fail = fail + 1 end
            end
        end
        -- same rule for the quest prerequisite index (tools/gen_quest_deps.py; generated, gitignored)
        local ro = ROUTE_ORDER[toc]
        for _, fl in ipairs({ "era", "tbc", "mop", "retail", "forever" }) do
            for _, kind in ipairs({ "RouteOrder", "QuestDeps" }) do
                local f = "Data/" .. kind .. "_" .. fl .. ".lua"
                if fl == ro and not seen[f] then print("FAIL " .. toc .. ": does not load " .. f); fail = fail + 1 end
                if fl ~= ro and seen[f] then print("FAIL " .. toc .. ": must not load " .. f); fail = fail + 1 end
            end
        end
        -- quest-level skipping: the module comes after Progress (it rebuilds P.steps), the re-planner after the Router;
        -- the cost model (Routing/CostModel.lua) before the travel graph, the live window, the re-planner and the router that read it
        local order = {}
        local k = 0
        for line in bodies[toc]:gmatch("[^\n]+") do k = k + 1 order[line:gsub("\\", "/")] = k end
        for _, pair in ipairs({ { "Core/Progress.lua", "Core/Skip.lua" }, { "Routing/Router.lua", "Routing/Replan.lua" },
                                { "Routing/CostModel.lua", "Routing/TravelGraph.lua" }, { "Routing/CostModel.lua", "Routing/StepOrder.lua" },
                                { "Routing/CostModel.lua", "Routing/Replan.lua" }, { "Routing/CostModel.lua", "Routing/Router.lua" } }) do
            if not (order[pair[1]] and order[pair[2]] and order[pair[1]] < order[pair[2]]) then
                print("FAIL " .. toc .. ": " .. pair[2] .. " must load after " .. pair[1]); fail = fail + 1
            end
        end
        print(("OK   %-24s %d files"):format(toc, n))
    end
end
local ref = savedvars[tocs[1]]
for t, sv in pairs(savedvars) do
    if sv ~= ref then print("FAIL " .. t .. ": SavedVariables differ: " .. sv .. " vs " .. tostring(ref)); fail = fail + 1 end
end
if bodies["CompletionRoute_Forever.toc"] ~= bodies["CompletionRoute_Camelot.toc"] then
    print("FAIL CompletionRoute_Camelot.toc differs from CompletionRoute_Forever.toc (they must be identical)"); fail = fail + 1
end
if fail > 0 then print(fail .. " TOC problem(s)"); os.exit(1) end
print("All TOCs valid.")
