-- CompletionRoute :: tools/audit_quest_locations.lua
-- Audit every A/T/C step that carries a QID against the (corrected) Questie database:
--   A -> quest starter spawns (creature / object / item drop or vendor source)
--   T -> quest ender spawns
--   C -> objective spawns (creatures, objects, item drop sources, triggerEnd areas)
-- A coord point is "ok" when it lies within 40 yd of a reference spawn on the SAME uiMap
-- (map sizes from tools/maps_<flavor>.lua; when the map has no size: 2.0 map-%).
--
--   luajit tools/audit_quest_locations.lua <questie_dir> <flavor> <maps.lua|-> <out.tsv> <guide.lua> [guide.lua ...]
--
-- TSV columns: flavor guide_file guide_id qid action status old_coords old_zone new_coords new_zone distance_yd note
-- status: ok | wrong | wrong_zone | missing_coords | bad_coords | bad_zone | no_reference | no_coords_no_ref

local QUESTIE, FLAVOR, MAPS, OUT = arg[1], arg[2], arg[3], arg[4]
assert(QUESTIE and FLAVOR and MAPS and OUT and arg[5], "usage: see header")
local here = (arg[0]:match("^(.*)/[^/]*$") or ".")
local QE = dofile(here .. "/questie_env.lua")
local db = QE.load(QUESTIE, FLAVOR)
for _, l in ipairs(db.log) do io.stderr:write("[questie] ", l, "\n") end
local quests, npcs, objects, items, areaToUi = db.quests, db.npcs, db.objects, db.items, db.areaToUi

local maps = {}
if MAPS ~= "-" then   -- comma list allowed (wotlk = tbc ids + Northrend ids from the mop table)
    for mf in MAPS:gmatch("[^,]+") do for id, m in pairs(dofile(mf)) do if not maps[id] then maps[id] = m end end end
end
local TOL_YD, TOL_PCT = 40, 2.0
-- classic-numbered |Z| (e.g. 1429 Elwynn) on a Cata/MoP client: the addon resolves it by NAME
-- (Data/ZoneAliases.lua); mirror that so hand-written classic guides are audited on the right map
local aliasByName = {}
do
    local byName = {}
    for id, m in pairs(maps) do if m[8] == 3 or not byName[m[1]] then byName[m[1]] = id end end
    for _, f in ipairs({ "maps_era.lua", "maps_tbc.lua" }) do
        local ok, t = pcall(dofile, here .. "/" .. f)
        if ok then for id, m in pairs(t) do if not maps[id] and byName[m[1]] then aliasByName[id] = byName[m[1]] end end end
    end
end

-- reference points: list of { ui, x, y, src }
local function addSpawns(out, spawns, src)
    if type(spawns) ~= "table" then return end
    for zid, list in pairs(spawns) do
        local ui = areaToUi[zid]
        if ui and type(list) == "table" then
            for _, c in ipairs(list) do
                if type(c) == "table" and type(c[1]) == "number" and type(c[2]) == "number" and c[1] > 0 and c[2] > 0 then
                    out[#out + 1] = { ui = ui, x = c[1], y = c[2], src = src }
                end
            end
        end
    end
end
local function addNpc(out, id) local n = npcs[id] if n then addSpawns(out, n[7], "npc " .. id) end end
local function addObj(out, id) local o = objects[id] if o then addSpawns(out, o[4], "obj " .. id) end end
local function addItemSources(out, iid)
    local it = items[iid]
    if type(it) ~= "table" then return end
    if type(it[2]) == "table" then for _, id in ipairs(it[2]) do addNpc(out, id) end end
    if type(it[3]) == "table" then for _, id in ipairs(it[3]) do addObj(out, id) end end
    if type(it[14]) == "table" then for _, id in ipairs(it[14]) do addNpc(out, id) end end
end

local refCache = {}
local function refs(qid, action)
    local key = qid .. action
    if refCache[key] then return refCache[key] end
    local q, out = quests[qid], {}
    if q then
        if action == "A" and type(q[2]) == "table" then
            for _, id in ipairs(q[2][1] or {}) do addNpc(out, id) end
            for _, id in ipairs(q[2][2] or {}) do addObj(out, id) end
            for _, id in ipairs(q[2][3] or {}) do addItemSources(out, id) end
        elseif action == "T" and type(q[3]) == "table" then
            for _, id in ipairs(q[3][1] or {}) do addNpc(out, id) end
            for _, id in ipairs(q[3][2] or {}) do addObj(out, id) end
        elseif action == "C" then
            local o = q[10]
            if type(o) == "table" then
                for _, e in ipairs(type(o[1]) == "table" and o[1] or {}) do if type(e) == "table" then addNpc(out, e[1]) end end
                for _, e in ipairs(type(o[2]) == "table" and o[2] or {}) do if type(e) == "table" then addObj(out, e[1]) end end
                for _, e in ipairs(type(o[3]) == "table" and o[3] or {}) do if type(e) == "table" then addItemSources(out, e[1]) end end
                if type(o[5]) == "table" then   -- killCredit {{npcIds...}, creditNpc, text}
                    for _, e in ipairs(o[5]) do if type(e) == "table" and type(e[1]) == "table" then
                        for _, id in ipairs(e[1]) do addNpc(out, id) end end end
                end
            end
            if type(q[9]) == "table" and type(q[9][2]) == "table" then addSpawns(out, q[9][2], "triggerEnd") end
            if type(q[29]) == "table" then for _, e in ipairs(q[29]) do if type(e) == "table" then addSpawns(out, e[1], "extraObjective") end end end
        end
    end
    refCache[key] = out
    return out
end

local function distYd(ui, x1, y1, x2, y2)
    local m = maps[ui]
    if m and m[5] and m[6] and m[5] > 0 then
        local dx, dy = (x1 - x2) / 100 * m[5], (y1 - y2) / 100 * m[6]
        return math.sqrt(dx * dx + dy * dy), true
    end
    local dx, dy = x1 - x2, y1 - y2
    return math.sqrt(dx * dx + dy * dy), false
end

local rows, counts = {}, {}
local function emit(file, gid, qid, act, status, oc, oz, nc, nz, d, note)
    rows[#rows + 1] = table.concat({ FLAVOR, file, gid or "", qid, act, status, oc or "", oz or "", nc or "", nz or "",
        d and ("%.1f"):format(d) or "", note or "" }, "\t")
    counts[file] = counts[file] or {}
    counts[file][status] = (counts[file][status] or 0) + 1
end

for i = 5, #arg do
    local path = arg[i]
    local f = assert(io.open(path, "r")) local text = f:read("*a") f:close()
    local file = path:match("([^/]+)$")
    if path:find("/Leveling/") then file = "Leveling/" .. file end
    local gid
    for line in text:gmatch("[^\r\n]+") do
        local g = line:match('id%s*=%s*"([^"]+)"') if g and line:find("R%(") or (g and line:find("Register")) then gid = g end
        local act = line:match("^%s*([ATC]) ")
        local qid = act and tonumber(line:match("|QID|(%d+)"))
        if qid then
            local m = line:match("|M|([^|]*)")
            local zs = line:match("|Z|([^|]*)")
            local zone = zs and tonumber(zs:match("^%s*(%d+)"))
            local aliasNote
            if zone and MAPS ~= "-" and not maps[zone] and aliasByName[zone] then
                aliasNote = ("|Z|%d resolved by name to %d"):format(zone, aliasByName[zone]) zone = aliasByName[zone]
            end
            local R = refs(qid, act)
            local refPts = R
            if not m or m == "" then
                if #R > 0 then
                    local r = R[1]
                    emit(file, gid, qid, act, "missing_coords", "", zs and tostring(zone) or "", ("%.1f,%.1f"):format(r.x, r.y), tostring(r.ui), nil, r.src)
                else
                    emit(file, gid, qid, act, "no_coords_no_ref")
                end
            elseif #R == 0 then
                emit(file, gid, qid, act, "no_reference", m, tostring(zone or ""), nil, nil, nil, quests[qid] and "quest has no mappable spawn" or "qid not in Questie DB")
            else
                local status, worst, best, note = "ok", 0, nil, aliasNote
                local snapped = {}   -- per point: kept as-is when within tolerance, else nearest same-map spawn
                if not zone then status, note = "bad_zone", "no |Z| uiMap"
                elseif MAPS ~= "-" and not maps[zone] then note = "uiMap " .. zone .. " not in maps file" end
                for xs, ys in m:gmatch("([%-%d%.]+),([%-%d%.]+)") do
                    local x, y = tonumber(xs), tonumber(ys)
                    if not x or not y or x < 0 or x > 100 or y < 0 or y > 100 then
                        status = "bad_coords"
                        snapped[#snapped + 1] = false
                    elseif zone then
                        local bd, bp, sized
                        for _, r in ipairs(refPts) do
                            if r.ui == zone then
                                local d, s = distYd(zone, x, y, r.x, r.y)
                                if not bd or d < bd then bd, bp, sized = d, r, s end
                            end
                        end
                        if not bd then
                            if status == "ok" then status = "wrong_zone" end
                            snapped[#snapped + 1] = false
                        else
                            local tol = sized and TOL_YD or TOL_PCT
                            snapped[#snapped + 1] = bd > tol and ("%.1f,%.1f"):format(bp.x, bp.y) or (xs .. "," .. ys)
                            if bd > tol and status == "ok" then status = "wrong" end
                            if bd > worst then worst = bd end
                            if bd > tol then best = best or bp end
                            if not sized then note = (note and note .. "; " or "") .. "distance in map-%" end
                        end
                    end
                end
                if status == "ok" then
                    emit(file, gid, qid, act, "ok", m, tostring(zone), nil, nil, worst, note)
                else
                    local r = best or refPts[1]
                    local nc, nz = ("%.1f,%.1f"):format(r.x, r.y), tostring(r.ui)
                    if status == "wrong" then
                        local keep, seen = {}, {}
                        for _, p in ipairs(snapped) do if p and not seen[p] then seen[p] = true keep[#keep + 1] = p end end
                        nc, nz = table.concat(keep, ";"), tostring(zone)
                    end
                    emit(file, gid, qid, act, status, m, tostring(zone or ""), nc, nz,
                        status == "wrong" and worst or nil, (note and note .. "; " or "") .. r.src)
                end
            end
        end
    end
end

local out = assert(io.open(OUT, "w"))
out:write("flavor\tguide_file\tguide_id\tqid\taction\tstatus\told_coords\told_zone\tnew_coords\tnew_zone\tdistance_yd\tnote\n")
out:write(table.concat(rows, "\n"), "\n")
out:close()
for file, c in pairs(counts) do
    local parts = {}
    for k, v in pairs(c) do parts[#parts + 1] = k .. "=" .. v end
    table.sort(parts)
    print(FLAVOR .. "\t" .. file .. "\t" .. table.concat(parts, " "))
end
