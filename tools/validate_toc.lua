-- Validates every CompletionRoute *.toc: listed files exist, Interface directive present,
-- no duplicate entries, SavedVariables consistent across flavors.
-- Run: luajit tools/validate_toc.lua   (from repo root)
local tocs = { "CompletionRoute.toc", "CompletionRoute_Mists.toc", "CompletionRoute_TBC.toc", "CompletionRoute_Vanilla.toc" }
local fail = 0
local savedvars = {}
for _, toc in ipairs(tocs) do
    local path = "CompletionRoute/" .. toc
    local fh = io.open(path, "r")
    if not fh then print("FAIL " .. toc .. ": missing"); fail = fail + 1 else
        local seen, hasInterface, n = {}, false, 0
        for line in fh:lines() do
            line = line:gsub("\r$", "")
            if line:match("^## Interface:") then hasInterface = true end
            local sv = line:match("^## SavedVariables: (.+)")
            if sv then savedvars[toc] = sv end
            if line ~= "" and not line:match("^##") and not line:match("^#") then
                local rel = line:gsub("\\", "/")
                n = n + 1
                if seen[rel] then print("FAIL " .. toc .. ": duplicate " .. rel); fail = fail + 1 end
                seen[rel] = true
                local f = io.open("CompletionRoute/" .. rel, "r")
                if f then f:close()
                elseif rel:match("^Guides/Imported_") or rel:match("^Data/Imported_") then
                    print("skip " .. toc .. ": " .. rel .. " (baked locally, gitignored)")
                else print("FAIL " .. toc .. ": missing file " .. rel); fail = fail + 1 end
            end
        end
        fh:close()
        if not hasInterface then print("FAIL " .. toc .. ": no ## Interface"); fail = fail + 1 end
        print(("OK   %-24s %d files"):format(toc, n))
    end
end
local ref = savedvars[tocs[1]]
for t, sv in pairs(savedvars) do
    if sv ~= ref then print("FAIL " .. t .. ": SavedVariables differ: " .. sv .. " vs " .. tostring(ref)); fail = fail + 1 end
end
if fail > 0 then print(fail .. " TOC problem(s)"); os.exit(1) end
print("All TOCs valid.")
