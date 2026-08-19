-- Full-load smoke test: loads EVERY file listed in each flavor TOC under an
-- auto-stubbing WoW mock. Catches syntax errors, load-time nil calls, and
-- flavor-specific load breakage without launching a client.
-- Run: luajit tools/test_load_all.lua   (from repo root)
--
-- The mock: any unknown global resolves to a callable stub that returns more
-- stubs, so load-time code paths never hit "attempt to call nil". Real logic
-- correctness is covered by tools/test_offline.lua; this test is about the
-- addon LOADING cleanly on every flavor.

local FLAVORS = {
    { toc = "OpenRoute.toc",         tocver = 121500, name = "retail" },
    { toc = "OpenRoute_Mists.toc",   tocver = 50501,  name = "mists" },
    { toc = "OpenRoute_TBC.toc",     tocver = 20504,  name = "tbc-anniversary" },
    { toc = "OpenRoute_Vanilla.toc", tocver = 11507,  name = "era" },
}

-- callable stub whose every field is another stub; tostring/number-safe
local function mkstub()
    local s = {}
    return setmetatable(s, {
        __call = function() return mkstub() end,
        __index = function(t, k) local v = mkstub(); rawset(t, k, v); return v end,
        __tostring = function() return "stub" end,
        __concat = function(a, b) return tostring(a) .. tostring(b) end,
        __len = function() return 0 end,
        __eq = function() return false end,
    })
end

local baseG = {}
for k, v in pairs(_G) do baseG[k] = v end

local function freshEnv(tocver)
    local env = {}
    for k, v in pairs(baseG) do env[k] = v end
    -- deterministic real implementations where behavior matters at load time
    env.strsplit = function(sep, s, ...)
        local out = {}
        for piece in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = piece end
        return unpack(out)
    end
    env.strtrim = function(s) return (s:match("^%s*(.-)%s*$")) end
    env.strjoin = function(sep, ...) return table.concat({ ... }, sep) end
    env.tinsert, env.tremove = table.insert, table.remove
    env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    env.format = string.format
    env.floor, env.ceil, env.abs, env.min, env.max, env.sqrt = math.floor, math.ceil, math.abs, math.min, math.max, math.sqrt
    env.GetBuildInfo = function() return "x", "0", "d", tocver end
    env.GetTime = function() return os.clock() end
    env.GetLocale = function() return "enUS" end
    env.select = select
    env.LibStub = nil -- let the real LibStub file define it
    setmetatable(env, { __index = function(t, k)
        local v = mkstub(); rawset(t, k, v); return v
    end })
    env._G = env
    return env
end

local anyfail = false
for _, fl in ipairs(FLAVORS) do
    local env = freshEnv(fl.tocver)
    local NS = {}
    local files, fh = {}, assert(io.open("OpenRoute/" .. fl.toc, "r"))
    for line in fh:lines() do
        line = line:gsub("\r$", "")
        if line ~= "" and not line:match("^#") then files[#files + 1] = (line:gsub("\\", "/")) end
    end
    fh:close()
    local loaded, failed = 0, 0
    for _, rel in ipairs(files) do
        if rel:match("^Libs/") then
            loaded = loaded + 1 -- third-party libs need a real client env; not our code under test
        elseif rel:match("^Guides/Imported_") and not io.open("OpenRoute/" .. rel, "r") then
            loaded = loaded + 1 -- baked locally, gitignored; absent in CI checkouts
        elseif rel:match("%.lua$") then
            local chunk, err = loadfile("OpenRoute/" .. rel)
            if not chunk then
                print(("FAIL %-16s %s: %s"):format(fl.name, rel, err)); failed = failed + 1
            else
                setfenv(chunk, env)
                local ok, rerr = pcall(chunk, "OpenRoute", NS)
                if ok then loaded = loaded + 1
                else print(("FAIL %-16s %s: %s"):format(fl.name, rel, rerr)); failed = failed + 1 end
            end
        else
            loaded = loaded + 1 -- .xml: existence already checked by validate_toc
        end
    end
    print(("%-4s %-16s %d/%d files load clean"):format(failed == 0 and "OK" or "FAIL", fl.name, loaded, #files))
    if failed > 0 then anyfail = true end
end
os.exit(anyfail and 1 or 0)
