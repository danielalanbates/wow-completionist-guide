-- Cross-game progress sync for CompletionRoute.
-- WoW keeps SavedVariables per client folder (_retail_/WTF, _classic_/WTF, ...), so a guide finished on retail
-- is invisible to Classic until something merges the files. This does that: it loads CompletionRouteDB from
-- every flavor, unions the per-character account records (chars[key].done / skipped / quests, newest scalars),
-- and writes the merged `chars` table back into each file. Idempotent; safe to run any time (a client that is
-- running will overwrite its file at logout with its own newer data, and the next run re-merges it).
--   luajit tools/sync_progress.lua [--dry] [--wow "/path/to/World of Warcraft"]
-- Backups: <file>.presync.bak (last pre-write copy). Run automatically by the launchd WatchPaths agent
-- installed by tools/install_sync_agent.sh, and once by tools/install.sh.
local WOW = "/Volumes/x10/Video Games/Mac/World of Warcraft"
local dry = false
for i = 1, #arg do if arg[i] == "--dry" then dry = true elseif arg[i] == "--wow" then WOW = arg[i + 1] end end
local FLAVORS = { "_retail_", "_classic_", "_classic_era_", "_anniversary_" }

local function files()
    local out = {}
    local p = io.popen(('ls "%s"/*/WTF/Account/*/SavedVariables/CompletionRoute.lua 2>/dev/null'):format(WOW))
    for line in p:lines() do out[#out + 1] = line end
    p:close()
    return out
end
local function loadSV(path)
    local env = {}
    local fn, err = loadfile(path, "t", env)
    if not fn then
        -- LuaJIT: loadfile has no env param
        fn, err = loadfile(path)
        if not fn then return nil, err end
        setfenv(fn, env)
    end
    local ok, e = pcall(fn)
    if not ok then return nil, e end
    return env
end
-- WoW-style serializer (stable key order so diffs stay readable)
local function ser(v, ind, out)
    local t = type(v)
    if t == "table" then
        out[#out + 1] = "{\n"
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b)
            local ta, tb = type(a), type(b)
            if ta ~= tb then return ta == "number" end
            return a < b
        end)
        for _, k in ipairs(keys) do
            out[#out + 1] = ind .. "\t"
            if type(k) == "number" then out[#out + 1] = ("[%s] = "):format(tostring(k))
            else out[#out + 1] = ("[%q] = "):format(k) end
            ser(v[k], ind .. "\t", out)
            out[#out + 1] = ",\n"
        end
        out[#out + 1] = ind .. "}"
    elseif t == "string" then out[#out + 1] = ("%q"):format(v)
    else out[#out + 1] = tostring(v) end
end
local function dump(name, v)
    local out = { name, " = " }
    ser(v, "", out)
    out[#out + 1] = "\n"
    return table.concat(out)
end

local function unionInto(dst, src)
    for k, v in pairs(src or {}) do if type(v) == "table" then dst[k] = dst[k] or {} unionInto(dst[k], v) else dst[k] = dst[k] or v end end
end
local function newer(a, b) return (a.updated or "") >= (b.updated or "") and a or b end

local svs = {}
for _, path in ipairs(files()) do
    local env, err = loadSV(path)
    if env and env.CompletionRouteDB then svs[#svs + 1] = { path = path, db = env.CompletionRouteDB }
    else io.stderr:write("skip " .. path .. ": " .. tostring(err) .. "\n") end
end
if #svs < 2 then print("sync: fewer than two SavedVariables files, nothing to merge") return end

-- merge chars
local merged = {}
for _, sv in ipairs(svs) do
    for key, c in pairs(sv.db.chars or {}) do
        local m = merged[key]
        if not m then m = { done = {}, skipped = {}, quests = {} } merged[key] = m end
        unionInto(m.done, c.done) unionInto(m.skipped, c.skipped) unionInto(m.quests, c.quests)
        local pick = newer(c, m)
        for f, v in pairs(c) do if type(v) ~= "table" and (pick == c or m[f] == nil) then m[f] = v end end
    end
end
-- also union the recorded road traces (one road network for the account)
local roads = {}
for _, sv in ipairs(svs) do for inst, segs in pairs(sv.db.roadTrace or {}) do roads[inst] = roads[inst] or {} for _, s in ipairs(segs) do roads[inst][#roads[inst] + 1] = s end end end

local nChars, nQuests = 0, 0
for _, m in pairs(merged) do nChars = nChars + 1 for _ in pairs(m.quests) do nQuests = nQuests + 1 end end
for _, sv in ipairs(svs) do
    local before = 0 for _ in pairs(sv.db.chars or {}) do before = before + 1 end
    sv.db.chars = merged
    sv.db.roadTrace = roads
    sv.db.lastSync = os.date("%Y-%m-%d %H:%M:%S")
    local text = dump("CompletionRouteDB", sv.db)
    if dry then print(("would write %s (%d -> %d chars)"):format(sv.path, before, nChars))
    else
        local f = io.open(sv.path, "r") local old = f and f:read("*a") if f then f:close() end
        if old then local b = io.open(sv.path .. ".presync.bak", "w") b:write(old) b:close() end
        local w = assert(io.open(sv.path, "w")) w:write(text) w:close()
        print(("synced %s (%d -> %d chars)"):format(sv.path:match("World of Warcraft/(.-)/WTF") or sv.path, before, nChars))
    end
end
print(("sync: %d characters, %d completed-quest records unioned across %d clients"):format(nChars, nQuests, #svs))
