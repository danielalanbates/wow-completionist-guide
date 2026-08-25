-- CompletionRoute :: Core/Util.lua
-- Map / coordinate helpers on top of HereBeDragons, quest-log helpers, item helpers.
local ADDON, NS = ...
local HBD = LibStub("HereBeDragons-2.0")
NS.HBD = HBD

local U = {}
NS.Util = U

-- Zone name -> uiMapID (built lazily from HBD's map list; localized names)
local nameToMap
local normToMap   -- normalized (lowercase, alphanumeric only) -> canonical uiMapID
local normToAll   -- normalized -> every uiMapID sharing the name (across punctuation variants)
local function normName(s) return (s:lower():gsub("[^%w]", "")) end
local function buildNameIndex()
    nameToMap = {} normToMap = {} normToAll = {}
    for _, id in ipairs(HBD:GetAllMapIDs()) do
        local info = C_Map.GetMapInfo(id)
        if info and info.name then
            local k = normName(info.name)
            normToAll[k] = normToAll[k] or {}
            normToAll[k][#normToAll[k] + 1] = id
            -- Same name, several maps (retail: 7 "Arathi Highlands" - zone, warfront, scenarios; 6 "Isle of
            -- Quel'Danas"). Prefer zone-level maps (mapType 3), then the LOWEST uiMapID: the canonical zone always
            -- has the oldest/lowest id, the copies are phased instances no transit leads to. Iteration order of
            -- GetAllMapIDs is arbitrary, so without this the answer changed between sessions.
            local prev = nameToMap[info.name]
            if not prev then nameToMap[info.name] = id
            else
                local pt = (C_Map.GetMapInfo(prev) or {}).mapType
                local better = (info.mapType == 3 and pt ~= 3) or ((info.mapType == 3) == (pt == 3) and id < prev)
                if better then nameToMap[info.name] = id end
            end
        end
    end
    for n, id in pairs(nameToMap) do
        local k = normName(n)
        local prev = normToMap[k]
        if not prev then normToMap[k] = id
        else
            local pt = (C_Map.GetMapInfo(prev) or {}).mapType
            local it = (C_Map.GetMapInfo(id) or {}).mapType
            if (it == 3 and pt ~= 3) or ((it == 3) == (pt == 3) and id < prev) then normToMap[k] = id end
        end
    end
end
-- Zygor disambiguates same-named maps with a trailing token: D = the Draenor copy, L = the
-- Legion/Broken Isles copy, M/New = the newest remake, a digit = a floor of the same place.
local VARIANT_CONTINENT = { D = 572, L = 619 }
local function resolveVariant(name)
    local base, tag = name:match("^(.-)%s+(%u)$")
    if not base then base, tag = name:match("^(.-)%s+(%d+)$") end
    if not base then base = name:match("^(.-)%s+New$") if base then tag = "New" end end
    if not base or base == "" then return nil end
    local ids = normToAll[normName(base)]
    if not ids then return nil end
    local cont = VARIANT_CONTINENT[tag]
    if cont then
        for _, id in ipairs(ids) do
            local p = id
            for _ = 1, 8 do
                local i2 = C_Map.GetMapInfo(p)
                p = i2 and i2.parentMapID
                if not p or p == 0 then break end
                if p == cont then return id end
            end
        end
    end
    if tag == "M" or tag == "New" then
        local best for _, id in ipairs(ids) do if not best or id > best then best = id end end
        return best
    end
    return nameToMap[base] or normToMap[normName(base)] or ids[1]
end
function U.MapIDByName(name)
    if not name then return nil end
    -- a number the client does not know is NOT a usable map: poisoning step.zone with it makes the
    -- step permanently untickable (the "map 1130" bug)
    if tonumber(name) then return U.MapIDByIDOrName(tonumber(name), nil) end
    if not nameToMap then buildNameIndex() end
    local t = strtrim(name)
    local hit = nameToMap[name] or nameToMap[t]
    if hit then return hit end
    -- old guide text: a zone this client renamed or split (The Barrens -> Northern Barrens)
    local alts = NS.ZoneNameAliases and NS.ZoneNameAliases[t]
    if alts then for _, alt in ipairs(alts) do if nameToMap[alt] then return nameToMap[alt] end end end
    -- punctuation / spacing variants: "Zul Aman" for Zul'Aman, WoW-Pro's CamelCase "TheWanderingIsle"
    local hit2 = normToMap[normName(t)]
    if hit2 then return hit2 end
    -- Zygor's trailing disambiguators ("Shadowmoon Valley D", "Dalaran L", "Uldum New", "UBRS 2")
    local v = resolveVariant(t)
    if v then return v end
    -- last resort, a unique prefix ("Antorus" -> "Antorus, the Burning Throne")
    local k, found, many = normName(t), nil, false
    if #k >= 5 then
        for nk, id in pairs(normToMap) do
            if nk:sub(1, #k) == k then
                if found and found ~= id then many = true break end
                found = id
            end
        end
    end
    if found and not many then return found end
    return nil
end
-- Resolve a zone given as a number that may be a Classic-era uiMapID on a differently numbered client.
function U.MapIDByIDOrName(mid, name)
    local info = mid and C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mid)
    if info and (not name or name == "" or info.name == name) then return mid end
    local byName = (name and name ~= "") and U.MapIDByName(name)
    if byName then return byName end
    local alias = mid and NS.ZoneIDNames and NS.ZoneIDNames[mid]
    if alias then byName = U.MapIDByName(alias) if byName then return byName end end
    return info and mid or nil
end
function U.MapName(id) local i = id and C_Map.GetMapInfo(id) return i and i.name or ("map " .. tostring(id)) end

-- Continent instance for a uiMapID (HBD data)
function U.InstanceOfMap(mapID)
    local x, y, inst = HBD:GetWorldCoordinatesFromZone(0.5, 0.5, mapID)
    return inst, x, y
end

-- Player position: returns mapID, x, y (0..1), instanceID, worldX, worldY
function U.PlayerPos()
    local wx, wy, inst = HBD:GetPlayerWorldPosition()
    local x, y, map = HBD:GetPlayerZonePosition()
    return map, x, y, inst, wx, wy
end

-- World coords for (mapID, x01, y01)
function U.World(mapID, x, y)
    if not mapID then return end
    return HBD:GetWorldCoordinatesFromZone(x, y, mapID)  -- wx, wy, instance
end

-- Zone coords (0..1) for a world point, as seen on `mapID`
function U.ZoneFromWorld(wx, wy, instance, mapID)
    if not (wx and mapID) then return end
    if HBD.GetZoneCoordinatesFromWorldInstance and instance then
        return HBD:GetZoneCoordinatesFromWorldInstance(wx, wy, instance, mapID, true)
    end
    return HBD:GetZoneCoordinatesFromWorld(wx, wy, mapID, true)
end

-- Distance in yards between two zone points; nil if different instances
function U.ZoneDistance(m1, x1, y1, m2, x2, y2)
    return HBD:GetZoneDistance(m1, x1, y1, m2, x2, y2)
end

-- Format seconds -> "1m 20s"
function U.FmtTime(s)
    if not s then return "?" end
    s = math.floor(s + 0.5)
    if s < 60 then return s .. "s" end
    local m = math.floor(s / 60); s = s - m * 60
    if m < 60 then return m .. "m " .. s .. "s" end
    local h = math.floor(m / 60); m = m - h * 60
    return h .. "h " .. m .. "m"
end
function U.FmtDist(d)
    if not d then return "?" end
    if d < 1000 then return math.floor(d + 0.5) .. " yd" end
    return string.format("%.1fk yd", d / 1000)
end
function U.FmtMoney(c)
    c = tonumber(c) or 0
    local g, s, cp = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
    if g > 0 then return string.format("%dg %ds", g, s) end
    if s > 0 then return string.format("%ds %dc", s, cp) end
    return cp .. "c"
end

-- ---------------------------------------------------------------------------
-- Quest helpers (Classic + Retail compatible)
-- ---------------------------------------------------------------------------
function U.IsQuestComplete(qid)
    if not qid then return false end
    -- Classic-era clients (Era / TBC Anniversary / MoP Classic) answer IsQuestFlaggedCompleted from a cache that
    -- is empty for quests done before this session until the server list arrives; the account harvest
    -- (GetQuestsCompleted after QueryQuestsCompleted) has the full list, so ask both.
    local me = NS.Account and NS.Account.me
    if me and me.quests and me.quests[qid] then return true end
    if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then return C_QuestLog.IsQuestFlaggedCompleted(qid) or false end
    return IsQuestFlaggedCompleted and IsQuestFlaggedCompleted(qid) or false
end
function U.IsOnQuest(qid)
    if not qid then return false end
    if C_QuestLog and C_QuestLog.IsOnQuest then return C_QuestLog.IsOnQuest(qid) end
    return false
end
-- returns logIndex or nil, and isComplete flag ("ready to turn in")
function U.QuestLogState(qid)
    if not qid then return nil end
    if C_QuestLog.GetLogIndexForQuestID then
        local idx = C_QuestLog.GetLogIndexForQuestID(qid)
        if not idx then return nil end
        if C_QuestLog.IsComplete then return idx, C_QuestLog.IsComplete(qid) end
        local info = C_QuestLog.GetInfo and C_QuestLog.GetInfo(idx)
        return idx, info and info.isComplete
    end
    -- very old API fallback
    for i = 1, GetNumQuestLogEntries() do
        local title, _, _, isHeader, _, isComplete, _, id = GetQuestLogTitle(i)
        if not isHeader and id == qid then return i, isComplete == 1 or isComplete == true end
    end
end
-- Objective progress: returns fulfilled, required for objective index (or first)
function U.QuestObjective(qid, objIndex)
    local ok, objs = pcall(C_QuestLog.GetQuestObjectives, qid)
    if not ok or not objs then return nil end
    local o = objs[objIndex or 1]
    if not o then return nil end
    return o.numFulfilled or 0, o.numRequired or 0, o.finished, o.text
end
function U.AllObjectivesDone(qid)
    local ok, objs = pcall(C_QuestLog.GetQuestObjectives, qid)
    if not ok or not objs or #objs == 0 then return nil end
    for _, o in ipairs(objs) do if not o.finished then return false end end
    return true
end

-- ---------------------------------------------------------------------------
-- Items
-- ---------------------------------------------------------------------------
function U.ItemCount(itemID) return (C_Item and C_Item.GetItemCount and C_Item.GetItemCount(itemID)) or (GetItemCount and GetItemCount(itemID)) or 0 end
function U.HasItem(itemID) return U.ItemCount(itemID) > 0 end
function U.ItemCooldown(itemID)
    local start, dur
    if C_Container and C_Container.GetItemCooldown then start, dur = C_Container.GetItemCooldown(itemID)
    elseif C_Item and C_Item.GetItemCooldown then start, dur = C_Item.GetItemCooldown(itemID)
    elseif GetItemCooldown then start, dur = GetItemCooldown(itemID) end
    if not start or start == 0 or not dur then return 0 end
    local left = start + dur - GetTime()
    return left > 0 and left or 0
end
function U.ItemIcon(itemID)
    local tex = (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID)) or (GetItemIcon and GetItemIcon(itemID))
    return tex or "Interface\\Icons\\INV_Misc_QuestionMark"
end
function U.ItemName(itemID)
    local n = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)) or (GetItemInfo and GetItemInfo(itemID))
    return n or ("item:" .. tostring(itemID))
end

-- Hearthstone: item 6948; Astral Recall (shaman) spell 556; retail alternates ignored for now
NS.HEARTH_ITEM = 6948
NS.HEARTH_SPELL = 8690
NS.ASTRAL_RECALL = 556
function U.HearthReady()
    if U.HasItem(NS.HEARTH_ITEM) then
        local cd = U.ItemCooldown(NS.HEARTH_ITEM)
        return cd == 0, cd, "item", NS.HEARTH_ITEM
    end
    return false, math.huge
end
function U.AstralRecallReady()
    if NS.player and NS.player.class == "SHAMAN" and IsSpellKnown and IsSpellKnown(NS.ASTRAL_RECALL) then
        local start, dur
        if C_Spell and C_Spell.GetSpellCooldown then local c = C_Spell.GetSpellCooldown(NS.ASTRAL_RECALL); start, dur = c and c.startTime, c and c.duration
        elseif GetSpellCooldown then start, dur = GetSpellCooldown(NS.ASTRAL_RECALL) end
        local left = (start and start > 0 and dur) and (start + dur - GetTime()) or 0
        return left <= 0, math.max(left, 0), "spell", NS.ASTRAL_RECALL
    end
    return false, math.huge
end

function U.InCombat() return InCombatLockdown() end

-- Player level with XP fraction (used by guide level gating)
function U.PlayerLevel()
    local l = UnitLevel("player")
    local xp, mx = UnitXP("player"), UnitXPMax("player")
    if mx and mx > 0 then return l + xp / mx end
    return l
end

-- Approx current travel speed (yd/s) — actual if moving, else best guess from level/mounts
function U.TravelSpeed()
    local p = NS.db and NS.db.profile.routing or {}
    local cur = GetUnitSpeed and GetUnitSpeed("player") or 0
    if cur and cur > 8 then return cur end
    if IsMounted and IsMounted() and cur > 0 then return cur end
    if p.mountSpeed then return p.mountSpeed end
    local lvl = UnitLevel("player")
    if NS.isClassic then
        if lvl >= 60 then return 14 end   -- assume 100% ground / can't assume epic
        if lvl >= 40 then return 11.2 end -- 60% mount
        return p.runSpeed or 7
    end
    if lvl >= 10 then return 14 end
    return p.runSpeed or 7
end

function U.tcount(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
function U.trim(s) return s and s:match("^%s*(.-)%s*$") end
function U.split(s, sep) local out = {} for piece in string.gmatch(s, "([^" .. sep .. "]+)") do out[#out + 1] = U.trim(piece) end return out end

-- Quest name for an ID, when the client can tell us (used by the step detail popup)
function U.QuestTitle(qid)
    if not qid then return nil end
    if C_QuestLog and C_QuestLog.GetTitleForQuestID then
        local ok, t = pcall(C_QuestLog.GetTitleForQuestID, qid)
        if ok and t and t ~= "" then return t end
    end
    if QuestUtils_GetQuestName then
        local ok, t = pcall(QuestUtils_GetQuestName, qid)
        if ok and t and t ~= "" then return t end
    end
    return nil
end
