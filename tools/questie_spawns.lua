-- CompletionRoute :: tools/questie_spawns.lua
-- Dump EVERY spawn of each quest's starters (A) and finishers (T) from a Questie installation, so the
-- quest-location audit (tools/audit_quest_locations_retail.py) can compare guide coordinates against
-- all real positions, not just the first one questie_quest_index.lua keeps.
--   luajit tools/questie_spawns.lua "<questie_dir>" [out.tsv]     (default out: tools/db2/questie_spawns.tsv)
-- Later expansions win per quest id (MoP data reflects the post-Cataclysm world retail still has).
-- Output is derived from GPL Questie data: generated locally, gitignored.

local QUESTIE = arg[1] or error("usage: luajit tools/questie_quest_index.lua <questie_dir> [out.tsv]")
local OUT = arg[2] or "tools/db2/questie_spawns.tsv"

local modules = {}
QuestieLoader = { ImportModule = function(_, n) modules[n] = modules[n] or { private = {} } return modules[n] end }
UnitFactionGroup = function() return "Alliance" end

local function slurp(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a") f:close() return s
end
local function loadchunk(s) local fn, err = (loadstring or load)(s) assert(fn, err) return fn() end
-- Questie's questData is one enormous `return { [id] = {...}, ... }` literal - a single chunk blows
-- LuaJIT's 65,536-constant limit, so it is loaded a few thousand entries at a time (one per line).
local function loadbig(data)
    local out, batch, n = {}, {}, 0
    local function flush()
        if n == 0 then return end
        for k, v in pairs(loadchunk("return {" .. table.concat(batch) .. "}")) do out[k] = v end
        batch, n = {}, 0
    end
    for line in data:gmatch("[^\r\n]+") do
        if line:sub(1, 1) == "[" then
            batch[#batch + 1] = line
            n = n + 1
            if n >= 2000 then flush() end
        end
    end
    flush()
    return out
end

-- Questie field indices (same as tools/gen_quest_guides.lua): 1 name, 4 requiredLevel,
-- 5 questLevel, 6 requiredRaces, 7 requiredClasses
local ALLIANCE = { [1]=1, [4]=1, [8]=1, [64]=1, [1024]=1, [2097152]=1 }
local HORDE    = { [2]=1, [16]=1, [32]=1, [128]=1, [512]=1, [256]=1 }
local function factionOf(mask)
    if not mask or mask == 0 then return "Both" end
    local a, h = false, false
    for bit_ in pairs(ALLIANCE) do if mask % (bit_ * 2) >= bit_ then a = true end end
    for bit_ in pairs(HORDE)    do if mask % (bit_ * 2) >= bit_ then h = true end end
    if a and h then return "Both" elseif a then return "Alliance" elseif h then return "Horde" end
    return "Both"
end
local CLASSNAME = { [1]="Warrior",[2]="Paladin",[4]="Hunter",[8]="Rogue",[16]="Priest",[32]="DeathKnight",
    [64]="Shaman",[128]="Mage",[256]="Warlock",[512]="Monk",[1024]="Druid" }
local function classTag(mask)
    if not mask or mask == 0 then return "" end
    local out = {}
    for bit_, name in pairs(CLASSNAME) do if mask % (bit_ * 2) >= bit_ then out[#out + 1] = name end end
    table.sort(out)
    return table.concat(out, ";")
end
local function clean(s) return (tostring(s or ""):gsub("[|\r\n\t]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")) end

-- areaId -> uiMapId + English zone name (from the table's trailing comments)
local areaName = {}
do
    local zt = slurp(QUESTIE .. "/Database/Zones/data/areaIdToUiMapId.lua") or ""
    for body in zt:gmatch("%[%[return {(.-)}%]%]") do
        for aid, _uid, name in body:gmatch("%[(%d+)%]%s*=%s*(%d+),%s*%-%-%s*([^\r\n]+)") do
            areaName[tonumber(aid)] = areaName[tonumber(aid)] or (name:gsub("%s+$", ""))
        end
    end
end

-- first mappable spawn of an NPC/object: Questie spawns are [areaId] = { {x, y}, ... }
local function firstSpawn(spawns)
    if type(spawns) ~= "table" then return nil end
    for zid, list in pairs(spawns) do
        local zname = areaName[zid]
        if zname and type(list) == "table" then
            for _, c in ipairs(list) do
                if type(c) == "table" and (c[1] or 0) > 0 and (c[2] or 0) > 0 then return zname, c[1], c[2] end
            end
        end
    end
end


local rows, sources = {}, {}
local function spawnsOf(sp, out)
    if type(sp) ~= "table" then return end
    for zid, list in pairs(sp) do
        local zname = areaName[zid]
        if zname and type(list) == "table" then
            for _, c in ipairs(list) do
                if type(c) == "table" and (c[1] or 0) > 0 and (c[2] or 0) > 0 then out[#out + 1] = { zname, c[1], c[2] } end
            end
        end
    end
end
for _, spec in ipairs({ { "Classic", "classic" }, { "TBC", "tbc" }, { "Wotlk", "wotlk" }, { "Cata", "cata" }, { "MoP", "mop" } }) do
    local text = slurp(("%s/Database/%s/%sQuestDB.lua"):format(QUESTIE, spec[1], spec[2]))
    if text then
        local mod = { private = {} }
        modules.QuestieDB = mod QuestieDB = mod
        loadchunk(text)
        local quests = mod.questData and loadbig(mod.questData) or {}
        local npcs, objects = {}, {}
        for kind, tbl in pairs({ Npc = "npcData", Object = "objectData" }) do
            local t = slurp(("%s/Database/%s/%s%sDB.lua"):format(QUESTIE, spec[1], spec[2], kind))
            if t then
                local m2 = { private = {} }
                modules.QuestieDB = m2 QuestieDB = m2
                loadchunk(t)
                if m2[tbl] then if kind == "Npc" then npcs = loadbig(m2[tbl]) else objects = loadbig(m2[tbl]) end end
            end
        end
        local n = 0
        for qid, q in pairs(quests) do
            local r = { A = {}, T = {} }
            for role, field in pairs({ A = 2, T = 3 }) do
                local by = q[field]
                if type(by) == "table" then
                    for _, id in ipairs(by[1] or {}) do local npc = npcs[id] if npc then spawnsOf(npc[7], r[role]) end end
                    for _, id in ipairs(by[2] or {}) do local o = objects[id] if o then spawnsOf(o[4], r[role]) end end
                end
            end
            if #r.A > 0 or #r.T > 0 or not rows[qid] then rows[qid] = r end
            n = n + 1
        end
        sources[#sources + 1] = ("%s=%d"):format(spec[2], n)
    end
end
assert(#sources > 0, "no Questie quest databases found")
local ids = {}
for qid in pairs(rows) do ids[#ids + 1] = qid end
table.sort(ids)
local f = assert(io.open(OUT, "w"))
f:write("qid\trole\tzone\tx\ty\n")
local nrows = 0
for _, qid in ipairs(ids) do
    for _, role in ipairs({ "A", "T" }) do
        local list = rows[qid][role]
        table.sort(list, function(a, b) if a[1] ~= b[1] then return a[1] < b[1] end if a[2] ~= b[2] then return a[2] < b[2] end return a[3] < b[3] end)
        for _, s in ipairs(list) do f:write(("%d\t%s\t%s\t%.2f\t%.2f\n"):format(qid, role, s[1], s[2], s[3])) nrows = nrows + 1 end
    end
end
f:close()
io.stderr:write(("wrote %s: %d quests, %d spawn rows (%s)\n"):format(OUT, #ids, nrows, table.concat(sources, " ")))
