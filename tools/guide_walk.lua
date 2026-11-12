-- Shared by tools/audit_step_text.lua and tools/census_step_kinds.lua: walks a flavor TOC the way
-- tools/test_load_all.lua does (auto-stubbing WoW mock), but loads only what a guide needs to register and parse
-- (Core/Init, Util, Conditions, Guide, the zone aliases, the taxi names and every Guides/ file the TOC lists), then
-- hands every step of every guide to a callback, one guide at a time, so nothing is kept (8 GB Mac).
--   local W = dofile("tools/guide_walk.lua")
--   W.Walk(flavorRecord, function(step, guide, family, NS) ... end, function(guide, family, NS, reused) ... end)
-- Spine entries reuse their zone guide's text (`part`): they are reported to the second callback with reused = true
-- and their steps are not parsed a second time.
local W = {}

W.FLAVORS = {
    { toc = "CompletionRoute_Vanilla.toc", tocver = 11507,  name = "era" },
    { toc = "CompletionRoute_TBC.toc",     tocver = 20504,  name = "tbc" },
    { toc = "CompletionRoute_Mists.toc",   tocver = 50501,  name = "mop" },
    { toc = "CompletionRoute.toc",         tocver = 121500, name = "retail" },
    { toc = "CompletionRoute_Forever.toc", tocver = 16001,  name = "forever" },
}

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
    env.strsplit = function(sep, s)
        local out = {}
        for piece in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = piece end
        return unpack(out)
    end
    env.strtrim = function(s) return (s:match("^%s*(.-)%s*$")) end
    env.strjoin = function(sep, ...) return table.concat({ ... }, sep) end
    env.tinsert, env.tremove = table.insert, table.remove
    env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    env.format = string.format
    env.GetBuildInfo = function() return "x", "0", "d", tocver end
    env.GetTime = function() return os.clock() end
    env.GetLocale = function() return "enUS" end
    env.select = select
    -- every map id "exists" (one shared record, no table per call): a step keeps the zone and the ALT places its line
    -- names, which is all the audit and the census need to know; names are not resolved to ids
    local anyMap = { name = "", mapType = 3, parentMapID = 0 }
    env.C_Map = { GetMapInfo = function() return anyMap end }
    env.LibStub = function() return { GetAllMapIDs = function() return {} end } end
    setmetatable(env, { __index = function(t, k) local v = mkstub(); rawset(t, k, v); return v end })
    env._G = env
    return env
end

local FAMILY = {
    { "^Guides/Imported_Wiki_",         "wiki quest guides" },
    { "^Guides/Imported_Spine_",        "spine (leveling path)" },
    { "^Guides/Imported_Gold_",         "gold" },
    { "^Guides/Imported_Professions_",  "professions" },
    { "^Guides/Imported_Achievements_", "achievements" },
    { "^Guides/Imported_QuestLines_",   "quest lines" },
    { "^Guides/Imported_Missions_",     "missions" },
    { "^Guides/Leveling/",              "hand-written leveling" },
}
W.FAMILY_ORDER = {}
for i, f in ipairs(FAMILY) do W.FAMILY_ORDER[i] = f[2] end
local function familyOf(rel)
    for _, f in ipairs(FAMILY) do if rel:match(f[1]) then return f[2] end end
    return "other"
end

local WANT = { ["Core/Init.lua"] = true, ["Core/Util.lua"] = true, ["Core/Conditions.lua"] = true, ["Core/Guide.lua"] = true,
               ["Data/ZoneAliases.lua"] = true }

-- Returns the flavor's NS (after the walk), the files that were missing, and load errors.
function W.Walk(fl, onStep, onGuide)
    local env = freshEnv(fl.tocver)
    local NS = {}
    local files = {}
    local fh = assert(io.open("CompletionRoute/" .. fl.toc, "r"))
    for line in fh:lines() do
        line = line:gsub("\r$", "")
        if line ~= "" and not line:match("^#") then files[#files + 1] = (line:gsub("\\", "/")) end
    end
    fh:close()
    -- Guides.xml lists the hand-written guides
    local expanded = {}
    for _, rel in ipairs(files) do
        if rel:match("^Guides/.*%.xml$") then
            local x = io.open("CompletionRoute/" .. rel, "r")
            if x then
                for script in x:read("*a"):gmatch('<Script%s+file="([^"]+)"') do
                    expanded[#expanded + 1] = "Guides/" .. script:gsub("\\", "/")
                end
                x:close()
            end
        else expanded[#expanded + 1] = rel end
    end
    local missing, errors, current = {}, {}, nil
    local fileOf = {}
    local hooked = false
    for _, rel in ipairs(expanded) do
        local isGuide = rel:match("^Guides/.*%.lua$")
        if WANT[rel] or isGuide or rel:match("^Data/Taxi_") then
            local chunk, err = loadfile("CompletionRoute/" .. rel)
            if not chunk then
                if io.open("CompletionRoute/" .. rel, "r") then errors[#errors + 1] = rel .. ": " .. tostring(err)
                else missing[#missing + 1] = rel end
            else
                current = rel
                setfenv(chunk, env)
                local ok, rerr = pcall(chunk, "CompletionRoute", NS)
                if not ok then errors[#errors + 1] = rel .. ": " .. tostring(rerr) end
                if not hooked and NS.On and NS.Guide then
                    hooked = true
                    NS:On("GUIDE_REGISTERED", function(def) fileOf[def.id] = current end)
                end
            end
        end
    end
    local G = NS.Guide
    if not G then return NS, missing, errors end
    -- no client: a "Quest 12345" title stays as written, and no skill is read
    NS.Util.QuestTitle = function() return nil end
    for _, id in ipairs(G.list) do
        local g = G.registry[id]
        local family = familyOf(fileOf[id] or "")
        if g.part then
            if onGuide then onGuide(g, family, NS, true) end
        else
            if onGuide then onGuide(g, family, NS, false) end
            local text = g.text
            if type(text) == "function" then local ok, t = pcall(text) text = ok and t or "" end
            if type(text) == "string" then
                local n = 0
                for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
                    n = n + 1
                    local ok, s = pcall(G.ParseLine, line, n, nil)
                    if ok and s then onStep(s, g, family, NS) end
                end
            end
        end
    end
    return NS, missing, errors
end

-- ---------------------------------------------------------------------------
-- Text model: how many lines a text needs, without a client
-- ---------------------------------------------------------------------------
-- Each character gets a width in em by class (close to Friz Quadrata, the client's default Latin font), times the font
-- size in points; words wrap greedily.  Good to about one word per line: callers that count overflows also ask with
-- grow = 1.1.  W.Lines(text, width in px, font size in pt[, grow]) -> lines; W.Plain strips colour codes and textures.
local EM = {}
local function class(chars, w) for c in chars:gmatch(".") do EM[c] = w end end
class(" ", 0.26)
class("ilI.,:;'!|", 0.27)
class("jtfr()[]-/\"", 0.36)
class("mwMW@%", 0.84)
class("ABCDEFGHJKLNOPQRSTUVXYZ&", 0.66)
class("0123456789", 0.54)
local function em(c) return EM[c] or 0.51 end

-- what the client draws: colour codes and textures take no (or icon) width
function W.Plain(t)
    t = t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", "#")
    return t
end
function W.Lines(text, width, pt, grow)
    if not text or text == "" then return 0 end
    local scale = pt * (grow or 1)
    local total = 0
    for para in (W.Plain(text) .. "\n"):gmatch("([^\n]*)\n") do
        local n, cur = 1, 0
        for word, space in para:gmatch("(%S+)(%s*)") do
            local w = 0
            for c in word:gmatch(".") do w = w + em(c) end
            w = w * scale
            local sp = #space > 0 and em(" ") * scale or 0
            if cur > 0 and cur + w > width then n = n + 1 cur = 0 end
            while w > width do n = n + 1 w = w - width end     -- a word wider than the line is broken
            cur = cur + w + sp
        end
        total = total + n
    end
    return total
end

return W
