-- Shared WoW API + HereBeDragons stubs for the offline harnesses (tools/test_offline.lua, tools/route_sweep.lua).
-- Set STUB_MAPS (see tools/gen_maps.py output) before dofile-ing to use real zone bounds; otherwise a small fake set.
-- Globals exported: MAPS, z2w(x01,y01,mapID) -> wx, wy, inst, PLAYER (set by caller), HBD_STUB, all WoW API stubs.
-- ---- WoW API stubs ----
local frames = {}
-- UNKNOWN_EVENTS: events this fake client does not have; RegisterEvent raises for them exactly like the real Frame does
UNKNOWN_EVENTS = {}
function CreateFrame() local f = { scripts = {} } function f:RegisterEvent(evt) if UNKNOWN_EVENTS[evt] then error("Frame:RegisterEvent(): Attempt to register unknown event \"" .. tostring(evt) .. "\"") end end function f:SetScript(k, v) self.scripts[k] = v end
    function f:Show() self.__shown = true end function f:Hide() self.__shown = false end
    for _, m in ipairs({"SetSize","SetPoint","SetMovable","EnableMouse","SetClampedToScreen","RegisterForDrag","SetFrameStrata","SetScale","SetAlpha","ClearAllPoints","SetBackdrop","SetBackdropColor","SetBackdropBorderColor","SetResizable","SetResizeBounds","SetText","SetAttribute","SetHighlightTexture","RegisterForClicks","SetAllPoints","SetTexCoord","SetTexture","SetJustifyH","SetWidth","SetWordWrap","SetMaxLines","SetTextColor","SetHeight","SetAutoFocus","SetScrollChild","SetColorTexture","SetRotation","SetCooldown","SetMinMaxValues","SetValueStep","SetObeyStepOnDrag","SetValue","SetBlendMode","SetLooping","SetOffset","SetDuration","SetSmoothing","Play","Stop","IsPlaying","SetVertexColor","SetFrameLevel","SetParent","SetShown","SetDrawLayer","SetNormalTexture","SetPushedTexture","SetDisabledTexture","EnableMouseWheel","SetEnabled","Disable","Enable","SetJustifyV","SetIgnoreParentScale","SetMaxLetters","SetNumeric","ClearFocus","SetFocus","SetOwner","AddLine"}) do f[m] = function() end end
    function f:SetText(t) self.__text = t end function f:GetText() return self.__text or "" end function f:HasFocus() return false end
    function f:SetChecked(v) self.__checked = v and true or false end function f:GetChecked() return self.__checked end
    function f:CreateTexture() return CreateFrame() end function f:CreateAnimationGroup() local g = CreateFrame() g.__playing = false function g:Play() self.__playing = true end function g:Stop() self.__playing = false end function g:IsPlaying() return self.__playing end return g end function f:CreateAnimation() return CreateFrame() end function f:CreateFontString() return CreateFrame() end function f:IsShown() return false end function f:GetPoint() return "CENTER",nil,nil,0,0 end
    f.Text = CreateFrame and { SetText = function() end } or nil
    return f end
UIParent = {}; UISpecialFrames = {}
function GetBuildInfo() return "2.5.6", "69110", "2026", 20506 end
C_AddOns = { GetAddOnMetadata = function() return "test" end }
tinsert = table.insert; strjoin = function(sep, ...) return table.concat({...}, sep) end; tostringall = function(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end return unpack(t) end
strsplit = function(sep, s) local out = {} for piece in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = piece end return unpack(out) end
strtrim = function(s) return s:match("^%s*(.-)%s*$") end
C_Timer = { After = function(_, fn) fn() end }
function GetTime() return os.clock() end
date = os.date
function debugprofilestop() return os.clock() * 1000 end
function UnitFactionGroup() return "Alliance" end
function UnitClass() return "Warrior", "WARRIOR" end
function UnitRace() return "Human", "Human" end
function UnitName() return "Tester" end
function GetRealmName() return "Test" end
function UnitLevel() return 5 end
function UnitXP() return 0 end function UnitXPMax() return 100 end
function GetUnitSpeed() return 0 end
function IsMounted() return false end
function InCombatLockdown() return false end
function GetBindLocation() return "Goldshire" end
function GetPlayerFacing() return 0 end
function UnitExists(u) return u == "target" end
NAMEPLATES = {}
WORLDFRAME_KIDS = {}
WorldFrame = { GetChildren = function() return unpack(WORLDFRAME_KIDS) end }
C_NamePlate = { GetNamePlates = function() return NAMEPLATES end,
    GetNamePlateForUnit = function(u) for _, pl in ipairs(NAMEPLATES) do if pl.namePlateUnitToken == u then return pl end end end }
HBD_PINS_WORLDMAP_SHOW_PARENT = 1
-- death state (the pointer switches to a corpse run when these say the player is dead)
PLAYER_DEAD, PLAYER_GHOST, CORPSE_POS = false, false, nil   -- CORPSE_POS = { mapID, x, y }
UnitIsDeadOrGhost = function(u) return u == "player" and (PLAYER_DEAD or PLAYER_GHOST) or false end
UnitIsGhost = function(u) return u == "player" and PLAYER_GHOST or false end
GetCorpseRecoveryDelay = function() return 0 end
C_DeathInfo = { GetCorpseMapPosition = function(m)
    if CORPSE_POS and CORPSE_POS[1] == m then return { GetXY = function() return CORPSE_POS[2], CORPSE_POS[3] end } end
    return nil
end }
RAID_CLASS_COLORS = setmetatable({}, { __index = function() return { r = 0.25, g = 0.78, b = 0.92 } end })
COMPLETED_QUESTS = {}
C_QuestLog = { GetAllCompletedQuestIDs = function() return COMPLETED_QUESTS end, IsQuestFlaggedCompleted = function(q) for _, c in ipairs(COMPLETED_QUESTS) do if c == q then return true end end return false end, IsOnQuest = function() return false end, GetQuestObjectives = function() return {} end, GetLogIndexForQuestID = function() return nil end }
C_Item = { GetItemCount = function(id) return id == 6948 and 1 or 0 end, GetItemNameByID = function(id) return "item" .. id end, GetItemIconByID = function() return "" end }
C_Container = { GetItemCooldown = function() return 0, 0 end }
IsSpellKnown = function() return false end
-- fake maps: Elwynn 1429 (EK inst 0), Westfall 1436, Stormwind 1453, Ironforge 1455, Wetlands 1437, Darkshore 1414? use real ids
MAPS = STUB_MAPS or { [1429]={ "Elwynn Forest", 0, -9500, 300, 4000, 3000 }, [1436]={ "Westfall", 0, -10600, 1100, 4000, 3000 }, [1453]={ "Stormwind City", 0, -8900, 600, 1500, 1200 },
  [1455]={ "Ironforge", 0, -4800, -1100, 1000, 800 }, [1437]={ "Wetlands", 0, -3500, -2500, 5000, 3000 }, [1439]={ "Darkshore", 1, 6500, 500, 5000, 6000 }, [1438]={ "Teldrassil", 1, 9900, 900, 5000, 5000 },
  [1457]={ "Darnassus", 1, 9900, 2100, 1000, 1000 }, [1440]={ "Ashenvale", 1, 3500, 800, 6000, 4000 }, [1411]={ "Durotar", 1, 500, -4400, 5000, 5000 }, [1454]={ "Orgrimmar", 1, 1600, -4500, 1500, 1500 }, [1413]={ "The Barrens", 1, -1400, -2600, 10000, 6000 },
  [1434]={ "Stranglethorn Vale", 0, -12500, -400, 6000, 4000 }, [1435]={ "Swamp of Sorrows", 0, -10400, -3000, 4000, 3000 }, [1445]={ "Dustwallow Marsh", 1, -3800, -3200, 5000, 4000 }, [1441]={ "Thousand Needles", 1, -5500, -2500, 5000, 3000 } }
-- world coords of zone (x01,y01): wx = top - y01*h ; wy = left - x01*w  (roughly WoW: x north, y west)
function z2w(x, y, m) local d = MAPS[m] if not d or not d[3] then return nil end return d[3] - y * d[6], d[4] - x * d[5], d[2] end
C_Map = { GetMapInfo = function(id) local d = MAPS[id] return d and { name = d[1], mapType = d[8] or 3, mapID = id, parentMapID = d[7] or 0 } end }
HBD_STUB = { GetAllMapIDs = function() local t = {} for id in pairs(MAPS) do t[#t + 1] = id end return t end,
  GetWorldCoordinatesFromZone = function(_, x, y, m) return z2w(x, y, m) end,
  GetZoneDistance = function(_, m1, x1, y1, m2, x2, y2) local ax, ay, ai = z2w(x1, y1, m1) local bx, by, bi = z2w(x2, y2, m2) if not ax or not bx or ai ~= bi then return nil end return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) end,
  GetPlayerWorldPosition = function() return PLAYER.wx, PLAYER.wy, PLAYER.inst end,
  GetPlayerZonePosition = function() return PLAYER.x, PLAYER.y, PLAYER.map end }
LibStub = function(name) if name == "HereBeDragons-2.0" then return HBD_STUB end return { Fire = function() end, RemoveAllMinimapIcons = function() end, RemoveAllWorldMapIcons = function() end, AddMinimapIconMap = function() end, AddWorldMapIconMap = function() end } end

-- Fake professions for tools/test_professions_engine.lua and tools/test_level_list.lua.  Installs one client API shape:
--   "era"    GetNumSkillLines / GetSkillLineInfo (localized names, headers)
--   "mop"    GetProfessions / GetProfessionInfo (skillLine id, nil holes), six tabs
--   "retail" as mop, five tabs, plus C_TradeSkillUI tiers (tier readings exist only after OPEN_PROFESSION_WINDOW())
--   "none"   no skill API at all
-- PROFS = { { name=, key=skill line id, rank=, max=, lang= localized name } }, SPELLS_KNOWN[id] = true, SPELL_NAMES[id] = "name".
PROFS, SPELLS_KNOWN, SPELL_NAMES, TIERS, SKILL_HEADERS_COLLAPSED = {}, {}, {}, {}, false
local WINDOW_OPENED = false
function OPEN_PROFESSION_WINDOW() WINDOW_OPENED = true end
function InstallProfessionAPI(shape)
    GetNumSkillLines, GetSkillLineInfo, GetProfessions, GetProfessionInfo, IsPlayerSpell, GetSpellInfo = nil, nil, nil, nil, nil, nil
    GetNumTradeSkills, GetTradeSkillInfo, GetNumCrafts, GetCraftInfo = nil, nil, nil, nil
    if C_TradeSkillUI then C_TradeSkillUI = nil end
    WINDOW_OPENED = false
    IsSpellKnown = function(id) return SPELLS_KNOWN[id] or false end
    GetSpellInfo = function(id) return SPELL_NAMES[id] end
    if shape == "none" then IsSpellKnown = nil GetSpellInfo = nil return end
    if shape == "era" then
        GetNumSkillLines = function()
            if SKILL_HEADERS_COLLAPSED then return 1 end
            return #PROFS + 1
        end
        GetSkillLineInfo = function(i)
            if i == 1 then return "Professions", 1, (not SKILL_HEADERS_COLLAPSED) and 1 or nil, 0, 0, 0, 0 end
            local p = PROFS[i - 1]
            if not p then return nil end
            return p.lang or p.name, nil, nil, p.rank, 0, 0, p.max
        end
        return
    end
    local tabs = {}
    GetProfessions = function()
        for i = 1, 6 do tabs[i] = PROFS[i] and i or nil end
        -- a character with one profession: slot 1 is nil, the first entry lives in a later slot (this is why ipairs is wrong)
        local a, b, c, d, e, f = nil, tabs[1], tabs[2], tabs[3], tabs[4], tabs[5]
        return a, b, c, d, e, f
    end
    GetProfessionInfo = function(i)
        local p = PROFS[i]
        if not p then return nil end
        return p.lang or p.name, 0, p.rank, p.max, 0, 0, p.key
    end
    if shape == "retail" then
        C_TradeSkillUI = {
            GetProfessionInfoBySkillLineID = function(tier)
                if not WINDOW_OPENED then return { skillLevel = 0, maxSkillLevel = 0, professionID = tier } end
                local t = TIERS[tier]
                if not t then return nil end
                return { skillLevel = t.rank, maxSkillLevel = t.max, professionID = tier }
            end,
            GetChildProfessionInfos = function()
                if not WINDOW_OPENED then return {} end
                local out = {}
                for tier, t in pairs(TIERS) do out[#out + 1] = { skillLevel = t.rank, maxSkillLevel = t.max, professionID = tier, parentProfessionID = 185 } end
                return out
            end,
            GetRecipeInfo = function(id) return { learned = SPELLS_KNOWN[id] or false } end,
        }
    end
end
