-- CompletionRoute :: tools/gen_quest_guides.lua
-- Generate per-zone "Quests" guides covering EVERY quest in a game version, using a local
-- Questie checkout (https://github.com/Questie/Questie) as the data reference.
-- Output is gitignored (Questie is GPL; baked locally into Guides/).
--
--   luajit tools/gen_quest_guides.lua <questie_dir> <flavor>
--   flavor: era | tbc | wotlk | cata | mop      (writes CompletionRoute/Guides/Imported_Quests_<flavor>.lua)
--   Run with Lua 5.3+ (`lua`): the npc DB exceeds LuaJIT's 65536-constant limit. Corrections are applied
--   (tools/questie_env.lua). Installed Questie packages omit Database/Cata/; for cata fetch
--   Database/Cata/cata{Quest,Npc,Object,Item}DB.lua from the same Questie tag into a copy of the checkout.
--   Verify output with tools/audit_quest_locations.lua.
--
-- Guides land in the browser tree as: Quests -> <Zone> -> "<Zone> Quests (Faction)".
-- Steps use the WoW-Pro syntax (A/C/T + QID/M/Z/PRE/N) so the router can optimize order.

local QUESTIE, FLAVOR, OUTPATH = arg[1], arg[2], arg[3]
assert(QUESTIE and FLAVOR, "usage: luajit tools/gen_quest_guides.lua <questie_dir> <flavor> [out.lua]")
local DBDIR = { era = "Classic/classic", tbc = "TBC/tbc", wotlk = "Wotlk/wotlk", cata = "Cata/cata", mop = "MoP/mop" }
assert(DBDIR[FLAVOR], "unknown flavor " .. FLAVOR)

-- ---- Questie database + its Corrections (tools/questie_env.lua) ------------------------------
-- Corrections matter: Questie's raw DB has stale/moved spawns that the in-game addon patches via
-- Database/Corrections/*Fixes.lua; without them ~2% of steps pointed at the wrong spot or zone
-- (see docs/quest_location_audit_classic.tsv).
local here = (arg[0]:match("^(.*)/[^/]*$") or ".")
local QDB = dofile(here .. "/questie_env.lua").load(QUESTIE, FLAVOR)
for _, l in ipairs(QDB.log) do io.stderr:write("[questie] ", l, "\n") end
local quests, npcs, objects, items = QDB.quests, QDB.npcs, QDB.objects, QDB.items
local areaToUi, areaName = QDB.areaToUi, QDB.areaName

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
    if type(mask) ~= "number" or mask == 0 then return "Both" end
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
    if type(mask) ~= "number" or mask == 0 then return nil end
    local out = {}
    for bit_, name in pairs(CLASSNAME) do if mask % (bit_ * 2) >= bit_ then out[#out + 1] = name end end
    return #out > 0 and table.concat(out, ";") or nil
end
local function clean(s) return (tostring(s or ""):gsub("[|\r\n]", " "):gsub("%s+", " ")) end
local function firstSpawn(spawns)   -- prefer an outdoor zone we can map; returns areaId, {coords}
    if type(spawns) ~= "table" then return nil end
    local best
    local zids = {}
    for zid in pairs(spawns) do if type(zid) == "number" then zids[#zids + 1] = zid end end
    table.sort(zids)
    for _, zid in ipairs(zids) do
        local list = spawns[zid]
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
    local function tryObj(zi, pts) if zi and not objZid then objZid, objCoords = zi, table.concat(pts, ";") end end
    local function tryNpc(id) local n = npcs[id] if n and not objZid then tryObj(firstSpawn(n[7])) end end
    local function tryObject(id) local ob = objects[id] if ob and not objZid then tryObj(firstSpawn(ob[4])) end end
    if type(q[10]) == "table" then
        local o = q[10]
        for _, e in ipairs(type(o[1]) == "table" and o[1] or {}) do if type(e) == "table" then tryNpc(e[1]) end end
        for _, e in ipairs(type(o[2]) == "table" and o[2] or {}) do if type(e) == "table" then tryObject(e[1]) end end
        for _, e in ipairs(type(o[5]) == "table" and o[5] or {}) do   -- killCredit {{npcIds}, base, text}
            if type(e) == "table" and type(e[1]) == "table" then for _, id in ipairs(e[1]) do tryNpc(id) end end
        end
        for _, e in ipairs(type(o[3]) == "table" and o[3] or {}) do   -- item objectives -> who drops / sells it
            local it = type(e) == "table" and items[e[1]]
            if type(it) == "table" then
                for _, id in ipairs(type(it[2]) == "table" and it[2] or {}) do tryNpc(id) end
                for _, id in ipairs(type(it[3]) == "table" and it[3] or {}) do tryObject(id) end
                for _, id in ipairs(type(it[14]) == "table" and it[14] or {}) do tryNpc(id) end
            end
        end
    end
    if not objZid and type(q[9]) == "table" and type(q[9][2]) == "table" then tryObj(firstSpawn(q[9][2])) end   -- triggerEnd area
    if not objZid and type(q[29]) == "table" then
        for _, e in ipairs(q[29]) do if type(e) == "table" and not objZid then tryObj(firstSpawn(e[1])) end end
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
            hasObjectives = type(q[10]) == "table" or objZid ~= nil,
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
