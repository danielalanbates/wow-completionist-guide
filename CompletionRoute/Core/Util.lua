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
-- Some guide formats disambiguate same-named maps with a trailing token: D = the Draenor copy, L = the
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
    -- punctuation / spacing variants: "Zul Aman" for Zul'Aman, CamelCase "TheWanderingIsle"
    local hit2 = normToMap[normName(t)]
    if hit2 then return hit2 end
    -- Trailing map disambiguators ("Shadowmoon Valley D", "Dalaran L", "Uldum New", "UBRS 2")
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

-- WoW Forever reshaped a few Era maps (Data/MapFix_forever.lua).  Era-sourced map percentages on those maps are
-- converted through world coordinates onto the Forever map; everywhere else (and on every other client) the point
-- is returned unchanged.  x, y in 0..1.
function U.EraToForever(mapID, x, y)
    local f = NS.isForever and NS.ForeverMapFix and mapID and NS.ForeverMapFix[mapID]
    if not f or not x or not y then return x, y end
    local wx = f[1] - y * f[4]
    local wy = f[2] - x * f[3]
    return (f[6] - wy) / f[7], (f[5] - wx) / f[8]
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
-- ---------------------------------------------------------------------------
-- Text sizes.  The client's "Small" font is 10 pt, which read as too small in the guide list, the step card and under
-- the arrow (beta feedback, 2026-11-11).  The addon's windows use four font objects of their own, copies of the
-- client's with a few points added: profile.textSize (default 2) on the small text, half of it on the rest.  A font
-- object's size can be changed while its text is on screen, so the Options slider applies at once.
-- ---------------------------------------------------------------------------
local FONT_BASE = { Small = "GameFontHighlightSmall", Body = "GameFontHighlight", Title = "GameFontNormal", Large = "GameFontNormalLarge" }
U.fonts = {}
function U.ApplyTextSize(extra)
    extra = tonumber(extra) or (NS.db and NS.db.profile and tonumber(NS.db.profile.textSize)) or 2
    for kind, fo in pairs(U.fonts) do
        local base = fo and _G[FONT_BASE[kind]]
        if base and base.GetFont then
            local okf, file, size, flags = pcall(base.GetFont, base)
            if okf and file and size then
                local add = (kind == "Small") and extra or math.floor(extra / 2)
                pcall(fo.SetFont, fo, file, size + add, flags)
            end
        end
    end
end
-- the name of the addon's font object for "Small" | "Body" | "Title" | "Large" (the client's own font where a font
-- object cannot be made, as in the offline harnesses)
function U.Font(kind)
    local name = "CompletionRouteFont" .. kind
    if U.fonts[kind] == nil then
        local ok, fo = pcall(function()
            local fnt = CreateFont(name)
            fnt:CopyFontObject(_G[FONT_BASE[kind]])
            return fnt
        end)
        U.fonts[kind] = (ok and fo) or false
        if U.fonts[kind] then U.ApplyTextSize() end
    end
    return U.fonts[kind] and name or FONT_BASE[kind]
end
if NS.On then NS:On("PLAYER_READY", function() U.ApplyTextSize() end) end

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
-- Achievement (or one of its criteria, by criteria-tree id) earned by this character/account?
-- GetAchievementInfo's 4th return is "completed"; GetAchievementCriteriaInfoByID's 3rd is "completed".
-- Era/TBC clients have no achievement API: returns false and the step stays a manual click.
function U.AchievementDone(ach, crit)
    if not ach or not GetAchievementInfo then return false end
    if crit and GetAchievementCriteriaInfoByID then
        local ok, _, _, done = pcall(GetAchievementCriteriaInfoByID, ach, crit)
        if ok and done then return true end
    end
    local ok, _, _, _, completed = pcall(GetAchievementInfo, ach)
    return ok and completed and true or false
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
-- Retail 12.x hands addons "secret" values for some reads while combat restrictions are on (cooldowns, NPC names and
-- GUIDs, unit speed).  Comparing, adding, indexing or using one as a table key is a Lua error, so every such read is
-- tested first.  issecretvalue does not exist on the Classic clients: nothing is ever secret there.
function U.IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) and true or false
end
-- Cooldowns: when the client hides the numbers, answer with what was last seen (the time each cooldown ends).
local cdEnds = { item = {}, spell = {} }
local function cooldownLeft(kind, id, start, dur)
    if U.IsSecret(start) or U.IsSecret(dur) then
        local ends = cdEnds[kind][id]
        return ends and math.max(ends - GetTime(), 0) or 0
    end
    local left = (start and start > 0 and dur) and (start + dur - GetTime()) or 0
    if left < 0 then left = 0 end
    cdEnds[kind][id] = left > 0 and (GetTime() + left) or nil
    return left
end
function U.ItemCooldown(itemID)
    local start, dur
    if C_Container and C_Container.GetItemCooldown then start, dur = C_Container.GetItemCooldown(itemID)
    elseif C_Item and C_Item.GetItemCooldown then start, dur = C_Item.GetItemCooldown(itemID)
    elseif GetItemCooldown then start, dur = GetItemCooldown(itemID) end
    return cooldownLeft("item", itemID, start, dur)
end
function U.ItemIcon(itemID)
    local tex = (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID)) or (GetItemIcon and GetItemIcon(itemID))
    return tex or "Interface\\Icons\\INV_Misc_QuestionMark"
end
function U.ItemName(itemID)
    local n = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)) or (GetItemInfo and GetItemInfo(itemID))
    return n or ("item:" .. tostring(itemID))
end

-- Toys (retail, and MoP Classic where the client has a toy box): owned, and usable here
function U.HasToy(itemID) return (PlayerHasToy and PlayerHasToy(itemID)) and true or false end
-- Equipped (Classic Era / TBC engineering transporters are trinkets: they work only while worn)
function U.IsEquipped(itemID)
    if C_Item and C_Item.IsEquippedItem then return C_Item.IsEquippedItem(itemID) and true or false end
    return (IsEquippedItem and IsEquippedItem(itemID)) and true or false
end
-- false only when the client says the item cannot be used (wrong profession, too low a skill); unknown = usable
function U.ItemUsable(itemID)
    local f = (C_Item and C_Item.IsUsableItem) or IsUsableItem
    if not f then return true end
    local ok, usable = pcall(f, itemID)
    if not ok then return true end
    return usable and true or false
end

-- Spells: known by this character, and the cooldown left in seconds (0 = ready).  The modern spell book API
-- moved several times; try every shape, newest last, and treat a missing API as "not known".
local function knows(fn, id)
    if not fn then return false end
    local ok, v = pcall(fn, id)
    return ok and v and true or false
end
function U.SpellKnown(spellID)
    return knows(IsPlayerSpell, spellID) or knows(IsSpellKnown, spellID)
        or (C_SpellBook and knows(C_SpellBook.IsSpellKnown, spellID)) or false
end
function U.SpellCooldown(spellID)
    local start, dur
    if C_Spell and C_Spell.GetSpellCooldown then local c = C_Spell.GetSpellCooldown(spellID); start, dur = c and c.startTime, c and c.duration
    elseif GetSpellCooldown then start, dur = GetSpellCooldown(spellID) end
    return cooldownLeft("spell", spellID, start, dur)
end

-- Hearthstone: item 6948; Astral Recall (shaman) spell 556.  Hearthstone stand-ins (Data/Teleports.lua, `hearth = true`) share
-- the Hearthstone's cooldown, so one of them stands in for the stone only when the stone is not in the bags.
NS.HEARTH_ITEM = 6948
NS.HEARTH_SPELL = 8690
NS.ASTRAL_RECALL = 556
-- returns ready, cooldown left, kind ("item"), item id, isToy
function U.HearthReady()
    if U.HasItem(NS.HEARTH_ITEM) then
        local cd = U.ItemCooldown(NS.HEARTH_ITEM)
        return cd == 0, cd, "item", NS.HEARTH_ITEM
    end
    local T = NS.Teleports
    local id, isToy
    if T and T.HearthToy then id, isToy = T.HearthToy() end
    if id then
        local cd = U.ItemCooldown(id)
        return cd == 0, cd, "item", id, isToy
    end
    return false, math.huge
end
function U.AstralRecallReady()
    if NS.player and NS.player.class == "SHAMAN" and U.SpellKnown(NS.ASTRAL_RECALL) then
        local left = U.SpellCooldown(NS.ASTRAL_RECALL)
        return left <= 0, left, "spell", NS.ASTRAL_RECALL
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

-- Can this character fly in the current area / context?
function U.CanFly()
    if IsFlying and IsFlying() then return true end
    local cur = GetUnitSpeed and GetUnitSpeed("player") or 0
    if U.IsSecret(cur) then cur = 0 end
    if cur > 15 then return true end
    -- Classic Era has no flying anywhere
    if NS.flavor == "era" then return false end
    -- Check outdoors
    if IsOutdoors and not IsOutdoors() then return false end
    -- Check flyable area API
    if IsFlyableArea and not IsFlyableArea() then return false end
    -- Druid check: flight form in flyable areas
    local class = NS.player and NS.player.class or select(2, UnitClass("player"))
    local lvl = UnitLevel("player")
    if class == "DRUID" then
        if not NS.isClassic then
            if lvl >= 10 then return true end
        else
            if IsSpellKnown and (IsSpellKnown(33943) or IsSpellKnown(40120) or IsSpellKnown(783)) then
                if lvl >= (NS.flavor == "tbc" and 68 or 30) then return true end
            end
        end
    end
    -- General flying mounts:
    if not NS.isClassic then
        -- In Retail (Dragonflight, War Within): Skyriding is baseline for all characters level 10+
        if lvl >= 10 then return true end
    else
        -- Classic clients: check riding spells
        if IsSpellKnown then
            if IsSpellKnown(90265) or IsSpellKnown(34091) or IsSpellKnown(34090) then return true end
        end
    end
    return false
end

-- Estimated flying travel speed (yd/s)
function U.FlySpeed()
    local p = NS.db and NS.db.profile.routing or {}
    if p.flySpeed then return p.flySpeed end
    if not NS.isClassic then
        -- Retail Skyriding is typically 705%-830% (~50-60 yd/s); steady flying is 310% (~30 yd/s).
        -- 45 yd/s gives a realistic average point-to-point travel speed (Routing/CostModel.lua FLY_SPEED).
        return NS.CostModel.FLY_SPEED
    else
        if IsSpellKnown and IsSpellKnown(90265) then return 29 end -- 310%
        if IsSpellKnown and IsSpellKnown(34091) then return 27 end -- 280%
        if IsSpellKnown and IsSpellKnown(34090) then return 18 end -- 150%
        return 20
    end
end

-- Approx current travel speed (yd/s) — actual if moving fast, else best capability guess.
-- Consistent whether on the ground or airborne so the travel graph does not flip routes.
function U.TravelSpeed()
    local p = NS.db and NS.db.profile.routing or {}
    local cur = GetUnitSpeed and GetUnitSpeed("player") or 0
    if U.IsSecret(cur) then cur = 0 end
    if cur and cur > 15 then return cur end
    if U.CanFly() then
        return U.FlySpeed()
    end
    if cur and cur > 8 then return cur end
    if IsMounted and IsMounted() and cur > 0 then return cur end
    if p.mountSpeed then return p.mountSpeed end
    local lvl = UnitLevel("player")
    -- the speed bands live in Routing/CostModel.lua (the offline bake and vplayer use the same ones)
    return NS.CostModel.GroundSpeed(lvl, NS.isClassic, p.runSpeed)
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
