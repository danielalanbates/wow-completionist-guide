-- CompletionRoute :: tools/questie_quest_index.lua
-- Dump quest id -> name / faction / class / level from a Questie installation (or checkout) so the
-- retail generator can put real names and faction gating on quests Blizzard's client data only gives
-- coordinates for.
--
--   luajit tools/questie_quest_index.lua "<questie_dir>" [out.tsv]
-- Also emits the quest GIVER's zone + coordinates from Questie's NPC/object spawns.  That matters:
-- measured over 4,851 WoW-Pro quests that carry both, the giver is within 50 yd of the turn-in only
-- 58.6% of the time (p75 633 yd, p90 1,628 yd), so anchoring an accept step on the turn-in pin - all
-- Blizzard's client data gives us - is materially wrong for ~40% of quests.
--   questie_dir = the folder containing Database/ (an installed Questie addon is fine)
--   default out: tools/db2/questie_index.tsv
--
-- Questie is GPL-licensed community data: the index is generated locally and gitignored, like every
-- other Imported_*/derived file here.  Covers Classic + TBC + Wotlk + MoP quests, which between them
-- are most of retail's old world; anything newer keeps its "Quest <id>" placeholder and is named live
-- by the client (Core/Guide.lua StepTitle).

local QUESTIE = arg[1] or error("usage: luajit tools/questie_quest_index.lua <questie_dir> [out.tsv]")
local OUT = arg[2] or "tools/db2/questie_index.tsv"

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

local index, sources = {}, {}
for _, spec in ipairs({ { "Classic", "classic" }, { "TBC", "tbc" }, { "Wotlk", "wotlk" }, { "Cata", "cata" }, { "MoP", "mop" } }) do
    local path = ("%s/Database/%s/%sQuestDB.lua"):format(QUESTIE, spec[1], spec[2])
    local text = slurp(path)
    if text then
        local mod = { private = {} }
        modules.QuestieDB = mod
        QuestieDB = mod
        loadchunk(text)
        local data = mod.questData
        if data then
            local quests = loadbig(data)
            -- NPC / object spawns for this same flavor, so a quest giver can be located
            local npcs, objects = {}, {}
            for kind, tbl in pairs({ Npc = "npcData", Object = "objectData" }) do
                local t = slurp(("%s/Database/%s/%s%sDB.lua"):format(QUESTIE, spec[1], spec[2], kind))
                if t then
                    local m2 = { private = {} }
                    modules.QuestieDB = m2
                    QuestieDB = m2
                    loadchunk(t)
                    if m2[tbl] then
                        local loaded = loadbig(m2[tbl])
                        if kind == "Npc" then npcs = loaded else objects = loaded end
                    end
                end
            end
            local n, located = 0, 0
            for qid, q in pairs(quests) do
                -- Questie npc row: [7] = spawns; object row: [4] = spawns
                local zname, sx, sy
                local started = q[2]
                if type(started) == "table" then
                    for _, id in ipairs(started[1] or {}) do
                        local npc = npcs[id]
                        if npc then zname, sx, sy = firstSpawn(npc[7]) if zname then break end end
                    end
                    if not zname then
                        for _, id in ipairs(started[2] or {}) do
                            local o = objects[id]
                            if o then zname, sx, sy = firstSpawn(o[4]) if zname then break end end
                        end
                    end
                end
                if zname then located = located + 1 end
                -- later expansions win: they carry the current name for a re-used id
                index[qid] = { name = clean(q[1]), faction = factionOf(q[6]), classes = classTag(q[7]),
                               minlevel = tonumber(q[4]) or 0,
                               zone = zname or "", x = sx or 0, y = sy or 0 }
                n = n + 1
            end
            sources[#sources + 1] = ("%s=%d(%d located)"):format(spec[2], n, located)
        end
    end
end
assert(#sources > 0, "no Questie quest databases found under " .. QUESTIE .. "/Database")

local ids = {}
for qid in pairs(index) do ids[#ids + 1] = qid end
table.sort(ids)
local f = assert(io.open(OUT, "w"))
f:write("qid\tname\tfaction\tclasses\tminlevel\tgiver_zone\tgiver_x\tgiver_y\n")
for _, qid in ipairs(ids) do
    local e = index[qid]
    f:write(("%d\t%s\t%s\t%s\t%d\t%s\t%.2f\t%.2f\n"):format(qid, e.name, e.faction, e.classes, e.minlevel,
        e.zone or "", e.x or 0, e.y or 0))
end
f:close()
io.stderr:write(("wrote %s: %d quests (%s)\n"):format(OUT, #ids, table.concat(sources, " ")))
