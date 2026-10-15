-- Dump every A/C/T step carrying a QID, as the addon itself parses it (zone resolution included).
--   luajit tools/dump_quest_steps.lua [flavor] > out.tsv
-- Columns: file  guide_id  line  action  qids  qo  map  x  y  zoneName  ncoords  fixed  fixkey
-- Used by tools/audit_quest_locations_retail.py.  Loads the real Core/Guide.lua + adapters with stubs.
package.path = "./?.lua;" .. package.path
local ADDON, NS = "CompletionRoute", {}
local flavor, mode = ...
flavor = flavor or "retail"   -- mode "nofix": report the raw guide locations (fix keys are built from these)
local TOC = { era = 11507, tbc = 20506, mop = 50504, retail = 120100 }
STUB_MAPS = dofile("tools/maps_" .. flavor .. ".lua")
dofile("tools/stubs.lua")
function GetBuildInfo() return "x", "0", "2026", TOC[flavor] end
NS.__quiet = true
local function load(path)
    local f = io.open("CompletionRoute/" .. path, "r")
    if not f then return end
    f:close()
    local fn = assert(loadfile("CompletionRoute/" .. path)) fn(ADDON, NS)
end
local SRC = {}
local function loadG(path, tag)
    local before = #(NS.Guide and NS.Guide.list or {})
    load(path)
    if NS.Guide then for i = before + 1, #NS.Guide.list do SRC[NS.Guide.list[i]] = tag end end
end
for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua",
    "Data/ZoneAliases.lua", "Data/QuestCoordFixes_" .. flavor .. ".lua", "Adapters/LegacyGuides.lua", "Adapters/WoWPro.lua" }) do load(f) end
local print0 = print
print = function() end
loadG("Guides/Imported_Legacy_" .. flavor .. ".lua", "x") loadG("Guides/Imported_WoWPro_" .. flavor .. ".lua", "x")
loadG("Guides/Imported_Quests_" .. flavor .. ".lua", "Imported_Quests_" .. flavor)
loadG("Guides/Imported_Achievements_" .. flavor .. ".lua", "Imported_Achievements_" .. flavor)
loadG("Guides/Imported_Storylines_" .. flavor .. ".lua", "Imported_Storylines_" .. flavor)
for _, lv in ipairs({ "Alliance_Human_01_06_Northshire", "Horde_Orc_Troll_01_06_ValleyOfTrials" }) do loadG("Guides/Leveling/" .. lv .. ".lua", "Leveling/" .. lv) end
CompletionRouteDB, CompletionRouteCharDB = nil, nil
for _, h in ipairs((NS.wowHandlers or {}).ADDON_LOADED or {}) do pcall(h, "ADDON_LOADED", "CompletionRoute") end
local nb = #NS.Guide.list
if NS.Adapters.LegacyGuides then pcall(NS.Adapters.LegacyGuides.ImportStatic) end
for i = nb + 1, #NS.Guide.list do SRC[NS.Guide.list[i]] = "Imported_Legacy_" .. flavor end
nb = #NS.Guide.list
pcall(NS.Adapters.WoWPro.ImportStatic)
for i = nb + 1, #NS.Guide.list do SRC[NS.Guide.list[i]] = "Imported_WoWPro_" .. flavor end
print = print0
if mode == "nofix" then NS.QuestCoordFixes = nil end
local G = NS.Guide
local out = io.stdout
for _, id in ipairs(G.list) do
    local src = SRC[id]
    if src and src ~= "x" then
        local ok, steps = pcall(G.Steps, id)
        if ok and steps then
            for _, s in ipairs(steps) do
                if (s.action == "A" or s.action == "C" or s.action == "T") and s.qid then
                    local c = s.coords and s.coords[1]
                    out:write(table.concat({ src, id, s.line or 0, s.action, table.concat(s.qid, ","), tostring(s.qo or ""),
                        s.zone or "", c and string.format("%.4f", c.x * 100) or "", c and string.format("%.4f", c.y * 100) or "",
                        tostring(s.zoneName or ""):gsub("[\t\n]", " "), s.coords and #s.coords or 0, s.coordFixed and "fixed" or "", G.CoordFixKey(s) or "" }, "\t"), "\n")
                end
            end
        end
    end
end
