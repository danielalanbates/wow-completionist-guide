-- CompletionRoute :: tools/questie_env.lua
-- Load a local Questie checkout's flavor database AND its Corrections (the same *Fixes:Load()
-- tables Questie applies in-game via QuestieCorrections:Initialize), outside the game.
-- Shared by gen_quest_guides.lua and audit_quest_locations.lua so generated coords and the
-- audit reference are the corrected Questie data, not the raw base DB.
--
--   local QE = dofile("tools/questie_env.lua")
--   local db = QE.load(questieDir, flavor)   -- flavor: era | tbc | wotlk | cata | mop
--   db.quests, db.npcs, db.objects, db.items, db.areaToUi, db.areaName, db.log

local M = {}
local DBDIR = { era = "Classic/classic", tbc = "TBC/tbc", wotlk = "Wotlk/wotlk", cata = "Cata/cata", mop = "MoP/mop" }
local EXP = { era = 1, tbc = 2, wotlk = 3, cata = 4, mop = 5 }
M.DBDIR = DBDIR

local function slurp(path) local f = io.open(path, "r") if not f then return nil end local s = f:read("*a") f:close() return s end
local function loadchunk(s, name)
    local fn, err = (loadstring or load)(s, name)
    assert(fn, err)
    return fn()
end

-- permissive stand-in: any unknown field is another stand-in; arithmetic/concat yield 0/""
local stubMT
stubMT = {
    __index = function(t, k) local v = setmetatable({}, stubMT) rawset(t, k, v) return v end,
    __call = function() return setmetatable({}, stubMT) end,
    __add = function() return 0 end, __sub = function() return 0 end, __bor = function() return 0 end,
    __concat = function() return "" end, __unm = function() return 0 end,
}
local function stub() return setmetatable({}, stubMT) end

function M.load(QUESTIE, FLAVOR)
    assert(DBDIR[FLAVOR], "unknown flavor " .. tostring(FLAVOR))
    local log = {}
    local modules = {}
    local function mod(n)
        if not modules[n] then modules[n] = setmetatable({ private = {} }, stubMT) end
        return modules[n]
    end
    -- globals Questie's data/correction files touch at load time
    QuestieLoader = { ImportModule = function(_, n) return mod(n) end, CreateModule = function(_, n) return mod(n) end }
    UnitFactionGroup = function() return "Alliance" end
    Questie = setmetatable({ IsSoD = false, IsHardcore = false, IsTitanReforged = false, IsClassic = FLAVOR == "era",
        IsEra = FLAVOR == "era", IsTBC = FLAVOR == "tbc", IsWotlk = FLAVOR == "wotlk", IsCata = FLAVOR == "cata", IsMoP = FLAVOR == "mop",
        db = stub() }, stubMT)
    local X = mod("Expansions")
    rawset(X, "Era", 1) rawset(X, "Tbc", 2) rawset(X, "Wotlk", 3) rawset(X, "Cata", 4) rawset(X, "MoP", 5)
    rawset(X, "Current", EXP[FLAVOR])
    local D = QUESTIE .. "/Database"

    -- zone areaId -> uiMapId (+ English names from the comments)
    -- Cata/MoP clients number their maps post-Cataclysm style (Elwynn = 37, not 1429): Questie ships
    -- a separate table for them (Questie-Mists.toc loads Zones/data/MoP/areaIdToUiMapId.lua)
    local zfile = (FLAVOR == "mop" or FLAVOR == "cata") and "/Zones/data/MoP/areaIdToUiMapId.lua" or "/Zones/data/areaIdToUiMapId.lua"
    local zoneText = assert(slurp(D .. zfile), "areaIdToUiMapId missing: " .. zfile)
    local areaToUi, areaName = {}, {}
    local body = zoneText:match("areaIdToUiMapId = %[%[return {(.-)}%]%]")
    assert(body, "areaIdToUiMapId table not found")
    for aidS, uidS, name in body:gmatch("%[(%d+)%]%s*=%s*(%d+),%s*%-%-%s*([^\r\n]+)") do
        local aid, uid = tonumber(aidS), tonumber(uidS)
        if uid > 0 and not areaToUi[aid] then areaToUi[aid] = uid areaName[aid] = name:gsub("%s+$", "") end
    end
    local over = zoneText:match("areaIdToUiMapIdOverride = %[%[return {(.-)}%]%]") or ""
    for aidS, uidS, name in over:gmatch("%[(%d+)%]%s*=%s*(%d+),%s*%-%-%s*([^\r\n]+)") do
        local aid, uid = tonumber(aidS), tonumber(uidS)
        if uid > 0 then areaToUi[aid] = uid areaName[aid] = areaName[aid] or name:gsub("%s+$", "") end
    end

    -- flavor base databases
    local QDB = mod("QuestieDB")
    QuestieDB = QDB
    local function loadDB(kind)
        local path = ("%s/%s%sDB.lua"):format(D, DBDIR[FLAVOR], kind)
        local s = assert(slurp(path), "cannot read " .. path)
        loadchunk(s, kind .. "DB")
        local data = rawget(QDB, kind .. "Data")
        assert(type(data) == "string", kind .. "Data missing in " .. path)
        return loadchunk(data, kind .. "Data")
    end
    local db = { questData = loadDB("quest"), npcData = loadDB("npc"), objectData = loadDB("object") }
    local okI, items = pcall(loadDB, "item")
    db.itemData = okI and items or {}
    -- some fix files poke QuestieDB.<x>Data directly (e.g. wotlk InsertMissingItemIds)
    rawset(QDB, "questData", db.questData) rawset(QDB, "npcData", db.npcData)
    rawset(QDB, "objectData", db.objectData) rawset(QDB, "itemData", db.itemData)
    if not okI then log[#log + 1] = "itemDB not loaded: " .. tostring(items) end

    -- keys (root Database/*DB.lua, loaded AFTER the flavor DBs: the generated flavor files
    -- redefine e.g. objectKeys without `waypoints`, which the Cata fixes index) + zone ids
    if not bit then   -- Lua 5.3+: WoW's bit library via native integer ops (load() keeps 5.1 parsers happy)
        bit = load([[return { band = function(a, b) return math.tointeger(a) & math.tointeger(b) end,
            bor = function(a, ...) local r = math.tointeger(a) for _, v in ipairs({ ... }) do r = r | math.tointeger(v) end return r end,
            lshift = function(a, n) return math.tointeger(a) << n end, rshift = function(a, n) return math.tointeger(a) >> n end,
            bnot = function(a) return ~math.tointeger(a) end }]])()
    end
    _QuestieDB = stub()   -- QuestieDB.lua defines raceKeys/classKeys/specialFlags, then needs runtime bits we skip
    do   -- QuestieDB.lua: only its constant tables (the rest needs the game client)
        local s = slurp(D .. "/QuestieDB.lua") or ""
        for _, name in ipairs({ "raceKeys", "classKeys", "specialFlags" }) do
            local a = s:find("\nQuestieDB%." .. name .. " = {")
            local b = a and s:find("\n}", a, true)
            if a and b then
                local ok, err = pcall(loadchunk, "local QuestieDB = QuestieLoader:ImportModule('QuestieDB')\n" .. s:sub(a, b + 2), name)
                if not ok then log[#log + 1] = "QuestieDB." .. name .. ": " .. tostring(err) end
            else log[#log + 1] = "QuestieDB." .. name .. " not found" end
        end
    end
    for _, f in ipairs({ "questDB", "npcDB", "objectDB", "itemDB" }) do
        local s = assert(slurp(D .. "/" .. f .. ".lua"), "missing " .. f)
        local ok, err = pcall(loadchunk, s, f)
        if not ok then log[#log + 1] = f .. ".lua partial load: " .. tostring(err) end
    end
    do
        local s = slurp(D .. "/Zones/data/zoneIds.lua")
        if s then local ok, err = pcall(loadchunk, s, "zoneIds") if not ok then log[#log + 1] = "zoneIds: " .. tostring(err) end end
    end

    -- corrections, in QuestieCorrections:Initialize order
    local C = D .. "/Corrections/"
    local function run(file) local s = slurp(C .. file) if not s then log[#log + 1] = "no " .. file return end
        local ok, err = pcall(loadchunk, s, file) if not ok then log[#log + 1] = file .. ": " .. tostring(err) end end
    local applied = { questData = 0, npcData = 0, objectData = 0, itemData = 0 }
    local function apply(tbl, modName, fn, noNew)
        local m = rawget(modules, modName)
        local f = m and rawget(m, fn)
        if type(f) ~= "function" then log[#log + 1] = ("skip %s.%s (not defined)"):format(modName, fn) return end
        local ok, corr = pcall(f, m)
        if not ok or type(corr) ~= "table" then log[#log + 1] = ("%s.%s failed: %s"):format(modName, fn, tostring(corr)) return end
        for id, data in pairs(corr) do
            if type(data) == "table" then
                if not db[tbl][id] and ((not noNew) or data[1] ~= nil) then db[tbl][id] = {} end
                local row = db[tbl][id]
                if row then for k, v in pairs(data) do if type(k) == "number" then row[k] = v end end applied[tbl] = applied[tbl] + 1 end
            end
        end
    end
    local E = EXP[FLAVOR]
    local tiers = {
        { 1, { "classicQuestFixes.lua", "classicNPCFixes.lua", "classicItemFixes.lua", "classicObjectFixes.lua" },
          { { "questData", "QuestieQuestFixes", "Load" }, { "npcData", "QuestieNPCFixes", "Load" },
            { "itemData", "QuestieItemFixes", "Load" }, { "objectData", "QuestieObjectFixes", "Load" } } },
        { 2, { "tbcQuestFixes.lua", "tbcNPCFixes.lua", "tbcItemFixes.lua", "tbcObjectFixes.lua" },
          { { "questData", "QuestieTBCQuestFixes", "Load" }, { "npcData", "QuestieTBCNpcFixes", "Load" },
            { "itemData", "QuestieTBCItemFixes", "Load" }, { "objectData", "QuestieTBCObjectFixes", "Load" } } },
        { 3, { "wotlkQuestFixes.lua", "wotlkNPCFixes.lua", "wotlkItemFixes.lua", "wotlkObjectFixes.lua" },
          { { "questData", "QuestieWotlkQuestFixes", "Load" }, { "npcData", "QuestieWotlkNpcFixes", "LoadAutomatics" },
            { "npcData", "QuestieWotlkNpcFixes", "Load" },
            { "itemData", "QuestieWotlkItemFixes", "Load" }, { "objectData", "QuestieWotlkObjectFixes", "Load" } } },
        { 4, { "cataQuestFixes.lua", "cataNPCFixes.lua", "cataItemFixes.lua", "cataObjectFixes.lua" },
          { { "questData", "CataQuestFixes", "Load" }, { "npcData", "CataNpcFixes", "Load" },
            { "itemData", "CataItemFixes", "Load" }, { "objectData", "CataObjectFixes", "Load" } } },
        { 5, { "mopQuestFixes.lua", "mopNPCFixes.lua", "mopItemFixes.lua", "mopObjectFixes.lua" },
          { { "questData", "MopQuestFixes", "Load" }, { "npcData", "MopNpcFixes", "Load" },
            { "itemData", "MopItemFixes", "Load" }, { "objectData", "MopObjectFixes", "Load" } } },
    }
    for _, t in ipairs(tiers) do
        if E >= t[1] then
            for _, f in ipairs(t[2]) do run(f) end
            local noNew = E > t[1] or nil
            for _, a in ipairs(t[3]) do apply(a[1], a[2], a[3], noNew) end
        end
    end
    log[#log + 1] = ("corrections applied: quest=%d npc=%d object=%d item=%d"):format(applied.questData, applied.npcData, applied.objectData, applied.itemData)

    return { quests = db.questData, npcs = db.npcData, objects = db.objectData, items = db.itemData,
             areaToUi = areaToUi, areaName = areaName, log = log, applied = applied }
end

return M
