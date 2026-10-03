-- CompletionRoute :: tools/gen_quest_guides.lua
-- Generate per-zone "Quests" guides covering EVERY quest in a game version, using a local
-- Questie checkout (https://github.com/Questie/Questie) as the data reference.
-- Output is gitignored (Questie is GPL; we bake locally like Imported_Zygor.lua).
--
--   luajit tools/gen_quest_guides.lua <questie_dir> <flavor>
--   flavor: era | tbc | wotlk | cata | mop      (writes CompletionRoute/Guides/Imported_Quests_<flavor>.lua)
--
-- Guides land in the browser tree as: Quests -> <Zone> -> "<Zone> Quests (Faction)".
-- Steps use the WoW-Pro syntax (A/C/T + QID/M/Z/PRE/N) so the router can optimize order.

local QUESTIE, FLAVOR, OUTPATH = arg[1], arg[2], arg[3]
assert(QUESTIE and FLAVOR, "usage: luajit tools/gen_quest_guides.lua <questie_dir> <flavor> [out.lua]")
local DBDIR = { era = "Classic/classic", tbc = "TBC/tbc", wotlk = "Wotlk/wotlk", cata = "Cata/cata", mop = "MoP/mop" }
assert(DBDIR[FLAVOR], "unknown flavor " .. FLAVOR)

-- ---- minimal Questie environment ----------------------------------------------------------
local modules = {}
QuestieLoader = { ImportModule = function(_, n) modules[n] = modules[n] or { private = {} } return modules[n] end }
UnitFactionGroup = function() return "Alliance" end
local function slurp(path) local f = assert(io.open(path, "r"), "cannot read " .. path) local s = f:read("*a") f:close() return s end
local function loadchunk(s)
    local fn, err = (loadstring or load)(s)
    assert(fn, err)
    return fn()
end

-- zone areaId -> uiMapId, and English names from the table's comments
local zoneText = slurp(QUESTIE .. "/Database/Zones/data/areaIdToUiMapId.lua")
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

-- flavor databases
local function loadDB(kind)
    local path = ("%s/Database/%s%sDB.lua"):format(QUESTIE, DBDIR[FLAVOR], kind)
    local env_mod = { private = {} }
    modules.QuestieDB = env_mod
    QuestieDB = env_mod
    loadchunk(slurp(path))
    local data = env_mod[kind .. "Data"]
    assert(data, kind .. "Data missing in " .. path)
    return loadchunk(data)
end
local quests = loadDB("quest")
local npcs   = loadDB("npc")
local objects = loadDB("object")
local okItems, items = pcall(loadDB, "item")   -- item-started quests: where does the starter item drop?
if not okItems then io.stderr:write("itemDB not loaded (" .. tostring(items) .. "); item starters stay unlocated\n") items = {} end

-- ---- helpers -------------------------------------------------------------------------------
local ALLIANCE = { [1]=true, [4]=true, [8]=true, [64]=true, [1024]=true, [2097152]=true }  -- human dwarf nelf gnome draenei worgen
local HORDE    = { [2]=true, [16]=true, [32]=true, [128]=true, [512]=true, [256]=true }    -- orc undead tauren troll belf goblin
-- join a Questie prerequisite list into a WoW-Pro PRE tag value
local function prelist(t, sep)
    if type(t) ~= "table" or #t == 0 then return nil end
    local out = {}
    for _, v in ipairs(t) do if type(v) == "number" and v > 0 then out[#out + 1] = tostring(v) end end
    if #out == 0 then return nil end
    return table.concat(out, sep)
end

local function factionOf(mask)
    if not mask or mask == 0 then return "Both" end
    local a, h = false, false
    for bit_, side in pairs({ [1]="A",[4]="A",[8]="A",[64]="A",[1024]="A",[2097152]="A",
                              [2]="H",[16]="H",[32]="H",[128]="H",[512]="H",[256]="H" }) do
        if mask % (bit_ * 2) >= bit_ then if side == "A" then a = true else h = true end end
    end
    if a and h then return "Both" elseif a then return "Alliance" elseif h then return "Horde" else return "Both" end
end
local CLASSNAME = { [1]="Warrior",[2]="Paladin",[4]="Hunter",[8]="Rogue",[16]="Priest",[32]="DeathKnight",
    [64]="Shaman",[128]="Mage",[256]="Warlock",[512]="Monk",[1024]="Druid" }
local function classTag(mask)
    if not mask or mask == 0 then return nil end
    local out = {}
    for bit_, name in pairs(CLASSNAME) do if mask % (bit_ * 2) >= bit_ then out[#out + 1] = name end end
    return #out > 0 and table.concat(out, ";") or nil
end
local function clean(s) return (tostring(s or ""):gsub("[|\r\n]", " "):gsub("%s+", " ")) end
local function firstSpawn(spawns)   -- prefer an outdoor zone we can map; returns areaId, {coords}
    if type(spawns) ~= "table" then return nil end
    local best
    for zid, list in pairs(spawns) do
        if areaToUi[zid] and type(list) == "table" then
            local pts = {}
            for _, c in ipairs(list) do
                if type(c) == "table" and (c[1] or 0) > 0 and (c[2] or 0) > 0 then
                    pts[#pts + 1] = ("%.1f,%.1f"):format(c[1], c[2])
                    if #pts == 2 then break end
                end
            end
            if #pts > 0 then
                if not best then best = { zid, pts } end
            end
        end
    end
    if best then return best[1], best[2] end
end
local function entitySpawn(startedBy, finish)
    -- returns areaId, coordsString, npcName for the first mappable spawn
    local lists = finish and { creatures = startedBy and startedBy[1], objects = startedBy and startedBy[2] }
                        or { creatures = startedBy and startedBy[1], objects = startedBy and startedBy[2], items = startedBy and startedBy[3] }
    if lists.creatures then
        for _, id in ipairs(lists.creatures) do
            local n = npcs[id]
            if n then local zid, pts = firstSpawn(n[7]) if zid then return zid, table.concat(pts, ";"), clean(n[1]) end end
        end
    end
    if lists.objects then
        for _, id in ipairs(lists.objects) do
            local o = objects[id]
            if o then local zid, pts = firstSpawn(o[4]) if zid then return zid, table.concat(pts, ";"), clean(o[1]) end end
        end
    end
    if lists.items and lists.items[1] then
        -- item-started: follow the item to whoever drops / sells it (Questie itemDB: 2 npcDrops,
        -- 3 objectDrops, 14 vendors) so the accept step has a place to go instead of "somewhere"
        for _, iid in ipairs(lists.items) do
            local it = items[iid]
            if type(it) == "table" then
                local iname = clean(it[1])
                for _, src in ipairs({ { it[2], "npc", "Loot" }, { it[3], "obj", "Loot" }, { it[14], "npc", "Buy" } }) do
                    if type(src[1]) == "table" then
                        for _, id in ipairs(src[1]) do
                            local ent = src[2] == "npc" and npcs[id] or objects[id]
                            local zid, pts
                            if ent then zid, pts = firstSpawn(src[2] == "npc" and ent[7] or ent[4]) end
                            if zid then
                                return zid, table.concat(pts, ";"), clean(ent[1]), true,
                                       ("%s %s from %s - it starts this quest."):format(src[3], iname ~= "" and iname or ("item " .. iid), clean(ent[1])), iid
                            end
                        end
                    end
                end
            end
        end
        return nil, nil, nil, true, nil, lists.items[1]
    end
end

-- ---- bucket quests by zone + faction --------------------------------------------------------
local zones = {}   -- [areaId] = { Alliance = {quests}, Horde = {}, Both = {} }
local skipped, total = 0, 0
local itemRows = {}   -- qid, starter item, located? -> tools/db2/<flavor>/item_quests.tsv (coverage.py)
for qid, q in pairs(quests) do
    total = total + 1
    local name = clean(q[1])
    local startZid, startCoords, startNpc, itemStart, itemNote, itemId = entitySpawn(q[2], false)
    if itemStart then itemRows[#itemRows + 1] = ("%d\t%s\t%s"):format(qid, tostring(itemId or ""), startCoords and "1" or "0") end
    local endZid, endCoords, endNpc = entitySpawn(q[3], true)
    local objZid, objCoords
    if type(q[10]) == "table" then
        local oc = q[10][1]   -- creature objectives
        if type(oc) == "table" then for _, o in ipairs(oc) do
            local n = type(o) == "table" and npcs[o[1]]
            if n then local zi, pts = firstSpawn(n[7]) if zi then objZid, objCoords = zi, table.concat(pts, ";") break end end
        end end
        if not objZid and type(q[10][2]) == "table" then for _, o in ipairs(q[10][2]) do
            local ob = type(o) == "table" and objects[o[1]]
            if ob then local zi, pts = firstSpawn(ob[4]) if zi then objZid, objCoords = zi, table.concat(pts, ";") break end end
        end end
    end
    local zid = startZid or endZid or (type(q[17]) == "number" and q[17] > 0 and areaToUi[q[17]] and q[17]) or "OTHER"
    if name == "" then skipped = skipped + 1 else
        local fac = factionOf(q[6])
        zones[zid] = zones[zid] or {}
        zones[zid][fac] = zones[zid][fac] or {}
        table.insert(zones[zid][fac], {
            qid = qid, name = name, lvl = q[5] or 0, req = q[4] or 0,
            startCoords = startCoords, startZid = startZid, startNpc = startNpc, itemStart = itemStart, itemNote = itemNote,
            endCoords = endCoords, endZid = endZid, endNpc = endNpc,
            -- preQuestSingle (q[13]) = any ONE of these opens the quest -> ";" list (OR)
            -- preQuestGroup  (q[12]) = ALL of them are needed          -> "&" list (AND)
            pre = prelist(q[13], ";") or prelist(q[12], "&"),
            objText = type(q[8]) == "table" and clean(q[8][1]) or nil,
            objZid = objZid, objCoords = objCoords,
            hasObjectives = type(q[10]) == "table",
            classes = classTag(q[7]),
        })
    end
end

-- ---- emit ------------------------------------------------------------------------------------
local function stepLines(e, zoneUi, zoneNm)
    local out = {}
    local function z(zid) return ("%d; %s"):format(areaToUi[zid] or zoneUi, areaName[zid] or zoneNm) end
    local ctag = e.classes and ("|C|" .. e.classes) or ""
    if e.startCoords then
        out[#out + 1] = ("A %s|QID|%d%s|M|%s|Z|%s|%sN|%s|"):format(e.name, e.qid,
            e.pre and ("|PRE|" .. e.pre) or "", e.startCoords, z(e.startZid), ctag ~= "" and (ctag .. "|") or "",
            e.itemNote or ("From " .. (e.startNpc or "?") .. "."))
    else
        out[#out + 1] = ("A %s|QID|%d%s|%sN|%s|"):format(e.name, e.qid, e.pre and ("|PRE|" .. e.pre) or "",
            ctag ~= "" and (ctag .. "|") or "", e.itemStart and "Started by an item drop." or "Starter location unknown.")
    end
    if e.hasObjectives then
        if e.objCoords then
            out[#out + 1] = ("C %s|QID|%d|M|%s|Z|%s|N|%s|"):format(e.name, e.qid, e.objCoords, z(e.objZid), e.objText or "Complete the objectives.")
        else
            out[#out + 1] = ("C %s|QID|%d|N|%s|"):format(e.name, e.qid, e.objText or "Complete the objectives.")
        end
    end
    if e.endCoords then
        out[#out + 1] = ("T %s|QID|%d|M|%s|Z|%s|N|To %s.|"):format(e.name, e.qid, e.endCoords, z(e.endZid), e.endNpc or "?")
    else
        out[#out + 1] = ("T %s|QID|%d|"):format(e.name, e.qid)
    end
    return table.concat(out, "\n")
end

local outPath = OUTPATH or ("CompletionRoute/Guides/Imported_Quests_" .. FLAVOR .. ".lua")
do
    local tsvDir = "tools/db2/" .. (FLAVOR == "wotlk" and "wotlk" or FLAVOR)
    os.execute(("mkdir -p %q"):format(tsvDir))
    local tf = io.open(tsvDir .. "/item_quests.tsv", "w")
    if tf then tf:write("qid\titem\tlocated\n", table.concat(itemRows, "\n"), "\n") tf:close() end
end
local f = assert(io.open(outPath, "w"))
f:write(("-- AUTO-GENERATED by tools/gen_quest_guides.lua from a local Questie checkout (%s DB).\n"):format(FLAVOR))
f:write("-- Questie is GPL-licensed: this file is for local use and is gitignored - do not redistribute.\n")
f:write("local _, NS = ...\n")
f:write(('if NS.flavor ~= "%s" then return end\n'):format(FLAVOR == "era" and "era" or FLAVOR == "tbc" and "tbc" or FLAVOR == "wotlk" and "wrath" or FLAVOR))
f:write("local R = NS.Guide.Register\n")

local zoneIds = {}
for zid in pairs(zones) do if zid ~= "OTHER" then zoneIds[#zoneIds + 1] = zid end end
table.sort(zoneIds)
if zones.OTHER then zoneIds[#zoneIds + 1] = "OTHER" end
local guideCount, questCount = 0, 0
for _, zid in ipairs(zoneIds) do
    local zoneNm = zid == "OTHER" and "Instances & Other" or areaName[zid]
    local zoneUi = zid == "OTHER" and 0 or areaToUi[zid]
    for fac, list in pairs(zones[zid]) do
        table.sort(list, function(a, b) if a.lvl ~= b.lvl then return a.lvl < b.lvl end return a.name < b.name end)
        local minl, maxl = 99, 1
        local lines = {}
        for _, e in ipairs(list) do
            lines[#lines + 1] = stepLines(e, zoneUi, zoneNm)
            if e.req and e.req > 0 and e.req < minl then minl = e.req end
            if e.lvl and e.lvl > maxl then maxl = e.lvl end
            questCount = questCount + 1
        end
        if minl == 99 then minl = 1 end
        local facLabel = fac == "Both" and "" or (" (" .. fac .. ")")
        guideCount = guideCount + 1
        local zoneField = zoneUi > 0 and tostring(zoneUi) or ("%q"):format(zoneNm)
        f:write(("R({ id=%q, name=%q, type=\"Quests\", zone=%s, %sminlevel=%d, maxlevel=%d, author=\"Questie data\", source=\"CompletionRoute\", text=[==[\n"):format(
            ("qdb:%s:%s:%s"):format(FLAVOR, tostring(zid), fac), ("%s Quests%s"):format(zoneNm, facLabel),
            zoneField, fac ~= "Both" and ("faction=%q, "):format(fac) or "", minl, maxl))
        f:write(table.concat(lines, "\n"))
        f:write("\n]==] })\n")
    end
end
f:close()
print(("%s: %d quests -> %d zone guides (%d skipped of %d total) -> %s"):format(FLAVOR, questCount, guideCount, skipped, total, outPath))
