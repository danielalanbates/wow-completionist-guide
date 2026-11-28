-- CompletionRoute :: tools/att/extract_att.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
-- https://batesai.org  help@batesai.org
--
-- One version folder of the MIT community collection database's compiled db/ (docs/EMU_DATA.md) -> TSV rows of facts
-- (ids and uiMap coordinates only):
--   lua tools/att/extract_att.lua <clone>/db/<Version> OUT.tsv
-- Rows:  rel  quest  start  kind entry 0      giver: qgs / providers / the npc or object the quest sits under
--        obj  quest  idx    kind entry 0      objective idx (0-based): its crs / providers; kind a = its own coords
--        spawn kind  entry  map  x  y         kind c npc, g object, q quest start coords (entry = quest),
--                                             a objective coords (entry = quest*100+idx)
--        ach  ach    map    x    y            achievement / criterion coords, criterion npc/object providers
-- No text is read; categories that never shipped (NeverImplemented, Hidden*Triggers) are skipped.
local dir, out = arg[1], arg[2]
local SKIP = { NeverImplemented = true, HiddenQuestTriggers = true, HiddenAchievementTriggers = true,
               HiddenCurrencyTriggers = true }
local KIND = { CreateQuest = "q", CreateNPC = "n", CreateObject = "o", CreateQuestObjective = "qo",
               CreateAchievement = "ach", CreateAchievementCriteria = "crit", CreateMap = "m" }

local roots = {}
local DUMMY
local function no() return false end
DUMMY = setmetatable({}, { __index = function() return DUMMY end, __newindex = function() end, __lt = no, __le = no,
  __call = function(_, ...)
    for i = 1, select("#", ...) do local a = select(i, ...); if type(a) == "table" and a ~= DUMMY then return a end end
    return DUMMY
  end })
local function ctor(name)
  return function(...)
    local args, t, ids = { ... }, nil, {}
    for i = 1, select("#", ...) do
      local v = args[i]
      if type(v) == "table" then t = v else ids[#ids + 1] = v end
    end
    t = t or {}
    t.__k, t.__id = KIND[name] or name, ids[1]
    return t
  end
end
local ns = setmetatable({}, { __index = function(self, k)
  if type(k) == "string" and k:match("^Create") then local f = ctor(k); rawset(self, k, f); return f end
  if k == "AddEventHandler" then
    return function(_, fn) local cats = {}; fn(cats); for _, v in pairs(cats) do roots[#roots + 1] = v end end
  end
  -- any other helper (ResolveQuestData merges per-faction data, lookup tables such as OnTooltipDB, client API calls
  -- inside handlers): a stand-in that can be indexed and called; a call returns its first table argument as is, so
  -- per-faction fields (aqd/hqd) are not read and a quest whose giver differs by faction gets no point from here
  return DUMMY
end })
local env = setmetatable({}, { __index = function(_, k) local v = _G[k]; if v == nil then return DUMMY end; return v end })

local files = {}
local xml = io.open(dir .. "/Database.xml"):read("a")
for f in xml:gmatch('file="Categories/([^"]+)%.lua"') do
  if not SKIP[f] then files[#files + 1] = dir .. "/Categories/" .. f .. ".lua" end
end
for _, f in ipairs(files) do
  local src = io.open(f):read("a"):gsub("^\239\187\191", "")
  local chunk = assert(load(src, "@" .. f, "t", env))
  local ok, err = pcall(chunk, "AllTheThings", ns)
  if not ok then error(f .. ": " .. tostring(err)) end
end

local rows, seen = {}, {}
local function emit(s) if not seen[s] then seen[s] = true; rows[#rows + 1] = s end end
local function coords(t, fn)
  if type(t.coords) == "table" then
    for map, list in pairs(t.coords) do
      if type(map) == "number" and type(list) == "table" then
        for _, p in ipairs(list) do
          if type(p[1]) == "number" and type(p[2]) == "number" then fn(map, p[1], p[2]) end
        end
      end
    end
  end
end
local function kindof(c) return c == "n" and "c" or c == "o" and "g" or nil end
local function relations(t, fn)
  for _, id in ipairs(type(t.qgs) == "table" and t.qgs or {}) do fn("c", id) end
  if type(t.qg) == "number" then fn("c", t.qg) end
  for _, id in ipairs(type(t.crs) == "table" and t.crs or {}) do fn("c", id) end
  for _, p in ipairs(type(t.providers) == "table" and t.providers or {}) do
    local k = kindof(p[1]); if k and type(p[2]) == "number" then fn(k, p[2]) end
  end
  if type(t.provider) == "table" then
    local k = kindof(t.provider[1]); if k and type(t.provider[2]) == "number" then fn(k, t.provider[2]) end
  end
end
local fmt = string.format
local achpts = {}     -- ach -> list of {kind, entry} providers to resolve after spawns are known

local function walk(t, parent, quest, ach)
  if type(t) ~= "table" then return end
  local k, id = t.__k, t.__id
  if (k == "n" or k == "o") and type(id) == "number" and id > 0 then
    local kk = kindof(k)
    coords(t, function(m, x, y) emit(fmt("spawn\t%s\t%d\t%d\t%.2f\t%.2f", kk, id, m, x, y)) end)
  elseif k == "q" and type(id) == "number" then
    quest = id
    local any = false
    if type(t.qgs) == "table" or type(t.qg) == "number" or t.providers or t.provider then
      local u = { qgs = t.qgs, qg = t.qg, providers = t.providers, provider = t.provider }
      relations(u, function(kk, e) any = true; emit(fmt("rel\t%d\tstart\t%s\t%d\t0", id, kk, e)) end)
    end
    if not any and parent and (parent.__k == "n" or parent.__k == "o") and type(parent.__id) == "number"
      and parent.__id > 0 then
      emit(fmt("rel\t%d\tstart\t%s\t%d\t0", id, kindof(parent.__k), parent.__id))
    end
    local has = false
    coords(t, function(m, x, y) has = true; emit(fmt("spawn\tq\t%d\t%d\t%.2f\t%.2f", id, m, x, y)) end)
    if has then emit(fmt("rel\t%d\tstart\tq\t%d\t0", id, id)) end
  elseif k == "qo" and quest and type(id) == "number" and id >= 1 then
    local idx = id - 1
    relations(t, function(kk, e) emit(fmt("obj\t%d\t%d\t%s\t%d\t0", quest, idx, kk, e)) end)
    local has = false
    coords(t, function(m, x, y) has = true; emit(fmt("spawn\ta\t%d\t%d\t%.2f\t%.2f", quest * 100 + idx, m, x, y)) end)
    if has then emit(fmt("obj\t%d\t%d\ta\t%d\t0", quest, idx, quest * 100 + idx)) end
  elseif k == "ach" and type(id) == "number" then
    ach = id
    coords(t, function(m, x, y) emit(fmt("ach\t%d\t%d\t%.2f\t%.2f", id, m, x, y)) end)
  elseif k == "crit" then
    local a = type(t.achID) == "number" and t.achID or ach
    if a then
      coords(t, function(m, x, y) emit(fmt("ach\t%d\t%d\t%.2f\t%.2f", a, m, x, y)) end)
      local has = false
      coords(t, function() has = true end)
      if not has then
        relations({ providers = t.providers, provider = t.provider, crs = t.crs }, function(kk, e)
          achpts[#achpts + 1] = { a, kk, e }
        end)
      end
    end
  end
  if type(t.g) == "table" then
    for _, c in ipairs(t.g) do walk(c, t, quest, ach) end
  end
  for _, c in ipairs(t) do walk(c, t, quest, ach) end    -- compact form: the children are the table's array part
end
for _, r in ipairs(roots) do
  if type(r) == "table" and r.__k then walk(r, nil, nil, nil)
  elseif type(r) == "table" then for _, c in ipairs(r) do walk(c, nil, nil, nil) end end
end
local f = assert(io.open(out, "w"))
for _, s in ipairs(rows) do f:write(s, "\n") end
for _, p in ipairs(achpts) do f:write(fmt("achvia\t%d\t%s\t%d\n", p[1], p[2], p[3])) end
f:close()
io.stderr:write(fmt("%s: %d rows, %d criterion providers, %d files\n", dir, #rows, #achpts, #files))
