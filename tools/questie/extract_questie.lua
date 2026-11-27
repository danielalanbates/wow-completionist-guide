-- CompletionRoute :: tools/questie/extract_questie.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
-- https://batesai.org  help@batesai.org
--
-- Read one expansion of the GPLv3 community quest database (github.com/Questie/QuestieDB: data/<Exp>/*DB.lua,
-- src/corrections/<Exp>/*Fixes.lua, support/Zones) and print the facts the guides need as tab-separated rows:
--   rel  <quest> <start|end> <c|g> <entry> <via item or 0>     quest givers / enders (an item-started quest: the item's
--                                                             drop sources, with the item in the last column)
--   obj  <quest> <idx> <c|g|t> <entry> <via item or 0>       objective targets in Blizzard order creature, object,
--                                                             item (its drop sources), kill credit; t = explore area
--   spawn <c|g|t> <entry> <uiMap> <x> <y>                    spawn / area points, already zone % on that uiMap
-- Only ids and coordinates (facts) are read; no text.  Needs Lua 5.4+ (the data literals exceed LuaJIT's constant
-- limit).  Usage: lua tools/questie/extract_questie.lua QUESTIEDB_DIR EXP OUT.tsv
--   EXP: Classic | TBC | Wotlk | Cata | MoP | Forever
local dir, exp, out = arg[1], arg[2], arg[3]
assert(dir and exp and out, "usage: lua extract_questie.lua QUESTIEDB_DIR EXP OUT.tsv")

-- a permissive stand-in for every module the correction files touch that is not data (Phasing, l10n, icons...)
local magic
local mt = {}
mt.__index = function() return magic end
mt.__call = function() return magic end
for _, op in ipairs({"__add", "__sub", "__mul", "__div", "__mod", "__unm", "__concat", "__band", "__bor", "__bxor",
                     "__shl", "__shr", "__bnot", "__idiv", "__pow"}) do
    mt[op] = function() return 0 end
end
mt.__newindex = function() end
magic = setmetatable({}, mt)

local Enum = {}
local modules = {}
local function module(name)
    if not modules[name] then
        modules[name] = setmetatable({}, {__index = function(t, k)
            local v = setmetatable({}, mt)      -- spellObjectiveFirst[...] = true and similar side tables
            rawset(t, k, v)
            return v
        end, __call = function() return magic end})
    end
    return modules[name]
end
local QuestieLoader = {}
function QuestieLoader:ImportModule(n) return module(n) end
function QuestieLoader:CreateModule(n) return module(n) end

local env = setmetatable({QuestieLoader = QuestieLoader, Questie = magic, UnitFactionGroup = function() return "Alliance" end,
                          bit = {band = function(a, b) return a & b end, bor = function(a, b) return a | b end}},
                         {__index = function(_, k) local g = _G[k]; if g ~= nil then return g end; return magic end})

local function run(path, ...)
    local f = io.open(path, "rb")
    if not f then return false, "missing" end
    local src = f:read("a"); f:close()
    local chunk, err = load(src, "@" .. path, "t", env)
    if not chunk then return false, err end
    return pcall(chunk, ...)
end

-- enums (zoneIDs ...) used by the correction files
local lib = {Enum = Enum}
for _, e in ipairs({"constants", "expansions", "factions", "icons", "items", "npcs", "phases", "professions", "quests",
                    "waypoints", "zones"}) do
    local ok, err = run(dir .. "/src/corrections/enum/" .. e .. ".lua", "QuestieDB", lib)
    if not ok then io.stderr:write("enum " .. e .. ": " .. tostring(err) .. "\n") end
end
Enum = lib.Enum
assert(Enum.zoneIDs, "zone enum missing")
module("ZoneDB").zoneIDs = Enum.zoneIDs

-- data
local Q = module("QuestieDB")
local lower = {Classic = "classic", TBC = "tbc", Wotlk = "wotlk", Cata = "cata", MoP = "mop", Forever = "forever"}
local data = {}
for _, kind in ipairs({"Quest", "Npc", "Object", "Item"}) do
    local ok, err = run(string.format("%s/data/%s/%s%sDB.lua", dir, exp, lower[exp], kind))
    assert(ok, err)
    local key = kind:sub(1, 1):lower() .. kind:sub(2)
    data[key] = assert(load(Q[key .. "Data"]))()
    Q[key .. "Data"] = nil
    collectgarbage()
end
local qk, nk, ok_, ik = Q.questKeys, Q.npcKeys, Q.objectKeys, Q.itemKeys
-- table operations: <field>_add / <field>_remove merge into / remove from the field instead of replacing it
for _, keys in ipairs({qk, nk, ok_, ik}) do
    setmetatable(keys, {__index = function(t, k)
        local base, op = tostring(k):match("^(.-)_(%a+)$")
        if base and rawget(t, base) and (op == "add" or op == "remove") then return op .. ":" .. rawget(t, base) end
        return magic
    end})
end
module("ZoneDB").zoneIDs = Enum.zoneIDs
local function same(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    return a[1] == b[1] and a[2] == b[2]
end
local function merge(dst, v, add)
    dst = type(dst) == "table" and dst or {}
    if type(v) ~= "table" then return dst end
    for k, x in pairs(v) do
        if type(k) == "number" and k >= 1 and k <= #v and type(x) ~= "table" then
            -- array element (scalar): append or drop
            if add then dst[#dst + 1] = x else for i = #dst, 1, -1 do if dst[i] == x then table.remove(dst, i) end end end
        elseif type(x) == "table" and type(x[1]) == "number" and type(x[2]) == "number" and k <= #v then
            if add then dst[#dst + 1] = x else for i = #dst, 1, -1 do if same(dst[i], x) then table.remove(dst, i) end end end
        else
            dst[k] = merge(dst[k], x, add)
        end
    end
    return dst
end

-- corrections, oldest expansion first (a later one wins), whole-field replacement as the client does
local chain = {Classic = {"Era"}, TBC = {"Era", "Tbc"}, Wotlk = {"Era", "Tbc", "Wotlk"}, Cata = {"Era", "Tbc", "Wotlk", "Cata"},
               MoP = {"Era", "Tbc", "Wotlk", "Cata", "MoP"}, Forever = {"Forever/legacy", "Forever"}}
local prefix = {Era = "classic", Tbc = "tbc", Wotlk = "wotlk", Cata = "cata", MoP = "mop", Forever = "forever",
                ["Forever/legacy"] = "classic"}
local applied, failed = 0, {}
for _, c in ipairs(chain[exp]) do
    for _, what in ipairs({{"Quest", data.quest}, {"NPC", data.npc}, {"Object", data.object}, {"Item", data.item}}) do
        local path = string.format("%s/src/corrections/%s/%s%sFixes.lua", dir, c, prefix[c], what[1])
        local before = {}
        for k in pairs(modules) do before[k] = true end
        local ok, err = run(path)
        if not ok then
            if err ~= "missing" then failed[#failed + 1] = path:match("corrections/(.*)") .. ": " .. tostring(err) end
        else
            for name, m in pairs(modules) do
                local load_ = not before[name] and rawget(m, "Load")
                if type(load_) == "function" then
                    local ok2, fixes = pcall(load_, m)
                    if ok2 and type(fixes) == "table" then
                        for id, fields in pairs(fixes) do
                            if type(id) == "number" and type(fields) == "table" then
                                local row = what[2][id]
                                if not row then row = {}; what[2][id] = row end
                                for f, v in pairs(fields) do
                                    if type(f) == "number" then
                                        row[f] = v; applied = applied + 1
                                    elseif type(f) == "string" then
                                        local op, idx = f:match("^(%a+):(%d+)$")
                                        if op then row[tonumber(idx)] = merge(row[tonumber(idx)], v, op == "add"); applied = applied + 1 end
                                    end
                                end
                            end
                        end
                    elseif not ok2 then
                        failed[#failed + 1] = path:match("corrections/(.*)") .. " Load: " .. tostring(fixes)
                    end
                end
            end
        end
    end
end

-- zones: areaId -> uiMap (base table + override, Questie's own lookup)
local zdir = exp == "Forever" and "/support/Forever/Zones/" or (exp == "MoP" and "/support/Zones/MoP/" or "/support/Zones/")
local Z = module("ZoneDB")
Z.private = {}
assert(run(dir .. zdir .. "areaIdToUiMapId.lua"))
local a2u = assert(load(Z.private.areaIdToUiMapId))()
for a, u in pairs(assert(load(Z.private.areaIdToUiMapIdOverride))()) do a2u[a] = u end

local fh = assert(io.open(out, "w"))
local function w(...) fh:write(table.concat({...}, "\t"), "\n") end
local nspawn, nskip = 0, 0
local function spawns(kind, entry, sp)
    if type(sp) ~= "table" then return end
    for area, pts in pairs(sp) do
        local u = type(area) == "number" and a2u[area]
        if u and u > 0 and type(pts) == "table" then
            for _, p in ipairs(pts) do
                if type(p) == "table" and type(p[1]) == "number" and type(p[2]) == "number" and p[1] >= 0 and p[2] >= 0 then
                    w("spawn", kind, entry, u, string.format("%.2f", p[1]), string.format("%.2f", p[2]))
                    nspawn = nspawn + 1
                end
            end
        else
            nskip = nskip + 1
        end
    end
end
for id, r in pairs(data.npc) do spawns("c", id, r[nk.spawns]) end
for id, r in pairs(data.object) do spawns("g", id, r[ok_.spawns]) end

local function list(t) return type(t) == "table" and t or {} end
local function drops(q, role, idx, item)
    local it = data.item[item]
    if not it then return end
    for _, n in ipairs(list(it[ik.npcDrops])) do
        if role then w("rel", q, role, "c", n, item) else w("obj", q, idx, "c", n, item) end
    end
    for _, o in ipairs(list(it[ik.objectDrops])) do
        if role then w("rel", q, role, "g", o, item) else w("obj", q, idx, "g", o, item) end
    end
end
local nq = 0
for q, r in pairs(data.quest) do
    nq = nq + 1
    local s, e = list(r[qk.startedBy]), list(r[qk.finishedBy])
    for _, n in ipairs(list(s[1])) do w("rel", q, "start", "c", n, 0) end
    for _, o in ipairs(list(s[2])) do w("rel", q, "start", "g", o, 0) end
    for _, i in ipairs(list(s[3])) do drops(q, "start", nil, i) end
    for _, n in ipairs(list(e[1])) do w("rel", q, "end", "c", n, 0) end
    for _, o in ipairs(list(e[2])) do w("rel", q, "end", "g", o, 0) end
    local ob, idx = list(r[qk.objectives]), 0
    for _, x in ipairs(list(ob[1])) do if type(x) == "table" and x[1] then w("obj", q, idx, "c", x[1], 0) end; idx = idx + 1 end
    for _, x in ipairs(list(ob[2])) do if type(x) == "table" and x[1] then w("obj", q, idx, "g", x[1], 0) end; idx = idx + 1 end
    for _, x in ipairs(list(ob[3])) do if type(x) == "table" and x[1] then drops(q, nil, idx, x[1]) end; idx = idx + 1 end
    for _, x in ipairs(list(ob[5])) do
        if type(x) == "table" then
            for _, n in ipairs(list(x[1])) do w("obj", q, idx, "c", n, 0) end
            if x[2] then w("obj", q, idx, "c", x[2], 0) end
        end
        idx = idx + 1
    end
    local te = r[qk.triggerEnd]
    if type(te) == "table" and type(te[2]) == "table" then
        w("obj", q, idx, "t", q, 0)
        spawns("t", q, te[2])
    end
end
fh:close()
io.stderr:write(string.format("%s: %d quests, %d spawn points (%d areas without a uiMap), %d correction fields, %d correction files failed\n",
    exp, nq, nspawn, nskip, applied, #failed))
for _, f in ipairs(failed) do io.stderr:write("  " .. f .. "\n") end
