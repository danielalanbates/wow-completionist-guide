-- OpenRoute :: UI/Beacon.lua
-- "Where is it?" overlay.  Puts a bouncing marker over the head of the NPC / mob / object the
-- current step wants (via nameplates), highlights it on the target + mouseover frames, offers a
-- secure /target button so one click selects it, and pins the step location on the minimap and
-- world map.  Works on every flavor: nameplates, HereBeDragons pins and secure macro buttons all
-- exist in Era/TBC/Wrath/Cata/MoP/retail.
local ADDON, NS = ...
local U = NS.Util
local B = {}
NS.Beacon = B

local TEX = "Interface\\AddOns\\" .. ADDON .. "\\Textures\\"
local HBDPins = LibStub("HereBeDragons-Pins-2.0", true)

-- ---------------------------------------------------------------------------
-- Which unit names does the current step care about?
-- ---------------------------------------------------------------------------
-- Guide lines carry |T|Name| when the author supplied one; otherwise we mine the step title,
-- which follows the community convention "Accept <Quest> from <NPC>" / "Turn in <Quest> to <NPC>"
-- / "Kill <Mob>".
local TITLE_PATTERNS = {
    A = { ".*%f[%a]from%s+(.+)$" },
    a = { ".*%f[%a]from%s+(.+)$" },
    T = { ".*%f[%a]to%s+(.+)$" },
    t = { ".*%f[%a]to%s+(.+)$" },
    K = { "^[Kk]ill%s+(.+)$", "^(.+)$" },
    l = { ".*%f[%a]from%s+(.+)$" },
    C = { ".*%f[%a]from%s+(.+)$", ".*%f[%a][Tt]alk to%s+(.+)$" },
    B = { ".*%f[%a]from%s+(.+)$" },
    f = { ".*%f[%a]from%s+(.+)$" },
    r = { ".*%f[%a]from%s+(.+)$" },
}
local STRIP = { "%s*%b()%s*$", "%s*<.->%s*", "%s*[%.,;:]%s*$" }

local function cleanName(n)
    if not n then return nil end
    n = U.trim(n)
    for _, p in ipairs(STRIP) do n = n:gsub(p, "") end
    n = U.trim(n)
    -- "x2", counts and objective fragments are not names
    if n == "" or #n > 48 or n:find("^%d") then return nil end
    return n
end

-- returns { [lowercased name] = displayName }
function B.WantedNames()
    local out, n = {}, 0
    local function add(name)
        name = cleanName(name)
        if name and not out[name:lower()] then out[name:lower()] = name n = n + 1 end
    end
    local steps = { NS.Progress.current }
    -- sticky steps that are still open also count (Zygor keeps those on-screen)
    for _, s in ipairs(NS.Progress.Upcoming(4)) do steps[#steps + 1] = s end
    for _, s in ipairs(steps) do
        if s then
            if s.target then for piece in tostring(s.target):gmatch("[^;]+") do add(piece) end end
            local pats = TITLE_PATTERNS[s.action]
            if pats then
                for _, p in ipairs(pats) do
                    local m = s.title and s.title:match(p)
                    if m then add(m) break end
                end
            end
        end
    end
    B.count = n
    return out
end

-- ---------------------------------------------------------------------------
-- Nameplate markers
-- ---------------------------------------------------------------------------
local plateMarks = {}      -- nameplate frame -> marker frame
local wanted = {}

local function newMarker(parent)
    local m = CreateFrame("Frame", nil, parent)
    m:SetSize(38, 38)
    m:SetFrameStrata("HIGH")
    local t = m:CreateTexture(nil, "OVERLAY")
    t:SetAllPoints()
    t:SetTexture(TEX .. "arrow_green")
    t:SetRotation(math.pi)          -- point down at the head
    m.tex = t
    local glow = m:CreateTexture(nil, "ARTWORK")
    glow:SetTexture(TEX .. "ring")
    glow:SetPoint("CENTER", 0, -6)
    glow:SetSize(46, 46)
    glow:SetBlendMode("ADD")
    glow:SetAlpha(0.55)
    m.glow = glow
    -- bob up and down so it reads at a glance in a crowd
    local ag = m:CreateAnimationGroup()
    ag:SetLooping("BOUNCE")
    local tr = ag:CreateAnimation("Translation")
    tr:SetOffset(0, 10); tr:SetDuration(0.6); tr:SetSmoothing("IN_OUT")
    m.anim = ag
    return m
end

local function markPlate(plate, unit)
    local name = UnitName(unit)
    if not name or not wanted[name:lower()] then
        local m = plateMarks[plate]
        if m then m:Hide() m.anim:Stop() end
        return
    end
    local m = plateMarks[plate]
    if not m then m = newMarker(plate) plateMarks[plate] = m end
    m:ClearAllPoints()
    m:SetPoint("BOTTOM", plate, "TOP", 0, 6)
    m:SetScale(NS.db and NS.db.profile.beacon and NS.db.profile.beacon.scale or 1)
    m:Show()
    m.anim:Play()
end

function B.RescanPlates()
    if not NS.db or not NS.db.profile.beacon.enabled then
        for _, m in pairs(plateMarks) do m:Hide() m.anim:Stop() end
        return
    end
    wanted = B.WantedNames()
    if C_NamePlate and C_NamePlate.GetNamePlates then
        for _, plate in ipairs(C_NamePlate.GetNamePlates(true) or {}) do
            local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
            if unit then markPlate(plate, unit) end
        end
    end
end

NS:RegisterEvent("NAME_PLATE_UNIT_ADDED", function(_, unit)
    if not NS.db or not NS.db.profile.beacon.enabled then return end
    local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit(unit, true)
    if plate then wanted = next(wanted) and wanted or B.WantedNames() markPlate(plate, unit) end
end)
NS:RegisterEvent("NAME_PLATE_UNIT_REMOVED", function(_, unit)
    local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit(unit, true)
    local m = plate and plateMarks[plate]
    if m then m:Hide() m.anim:Stop() end
end)
NS:On("STEP_CHANGED", function() B.RescanPlates() B.UpdatePins() B.UpdateTargetButton() end)
NS:On("PROGRESS_REFRESHED", function() NS:Throttle("beacon", 0.5, function() B.RescanPlates() B.UpdatePins() B.UpdateTargetButton() end) end)

-- ---------------------------------------------------------------------------
-- Target / mouseover frame highlight (the unit frame, so you can confirm the click landed)
-- ---------------------------------------------------------------------------
local function frameMark(anchor, key)
    B.frameMarks = B.frameMarks or {}
    local m = B.frameMarks[key]
    if not m and anchor then m = newMarker(UIParent) B.frameMarks[key] = m end
    return m
end
local function updateUnitFrame(unit, anchorName, key)
    local anchor = _G[anchorName]
    local m = frameMark(anchor, key)
    if not m then return end
    local name = UnitExists(unit) and UnitName(unit)
    if anchor and name and wanted[name:lower()] and NS.db.profile.beacon.enabled then
        m:ClearAllPoints(); m:SetPoint("RIGHT", anchor, "LEFT", -2, 0); m:SetScale(0.7); m:Show(); m.anim:Play()
    elseif m then m:Hide() m.anim:Stop() end
end
NS:RegisterEvent("PLAYER_TARGET_CHANGED", function() updateUnitFrame("target", "TargetFrame", "target") end)
NS:RegisterEvent("UPDATE_MOUSEOVER_UNIT", function() updateUnitFrame("mouseover", "MouseoverFrame", "mouseover") end)

-- ---------------------------------------------------------------------------
-- One-click "select it" button (secure /target macro; only editable out of combat)
-- ---------------------------------------------------------------------------
local tbtn = CreateFrame("Button", "OpenRouteTargetButton", NS.Arrow and NS.Arrow.frame or UIParent, "SecureActionButtonTemplate")
tbtn:SetSize(26, 26)
tbtn:SetPoint("TOPRIGHT", (NS.Arrow and NS.Arrow.frame) or UIParent, "TOPRIGHT", -2, -2)
tbtn:SetAttribute("type", "macro")
tbtn:RegisterForClicks("AnyUp", "AnyDown")
local ttex = tbtn:CreateTexture(nil, "ARTWORK")
ttex:SetAllPoints(); ttex:SetTexture("Interface\\Minimap\\Tracking\\Target")
tbtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
tbtn:Hide()
B.targetButton = tbtn
tbtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("|cff3ec6ffOpenRoute|r")
    GameTooltip:AddLine("Target: " .. (self.targetName or "?"), 1, 1, 1)
    GameTooltip:AddLine("Click to select it; a marker sits over its head when it is nearby.", 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
end)
tbtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

local pendingMacro
local function applyMacro(name)
    if InCombatLockdown() then pendingMacro = name return end
    pendingMacro = nil
    if not name then tbtn:Hide() tbtn.targetName = nil return end
    tbtn:SetAttribute("macrotext", "/cleartarget\n/targetexact " .. name .. "\n/target " .. name)
    tbtn.targetName = name
    tbtn:Show()
end
NS:RegisterEvent("PLAYER_REGEN_ENABLED", function() if pendingMacro ~= nil then applyMacro(pendingMacro) end end)

function B.UpdateTargetButton()
    if not NS.db or not NS.db.profile.beacon.enabled or not NS.db.profile.beacon.targetButton then applyMacro(nil) return end
    local s = NS.Progress.current
    if not s then applyMacro(nil) return end
    local names = B.WantedNames()
    -- prefer the name that belongs to the *current* step
    local pick
    if s.target then pick = cleanName((tostring(s.target):match("[^;]+"))) end
    if not pick then
        local pats = TITLE_PATTERNS[s.action]
        if pats then for _, p in ipairs(pats) do local m = s.title and s.title:match(p) if m then pick = cleanName(m) break end end end
    end
    if not pick then local _, n = next(names) pick = n end
    applyMacro(pick)
end

-- ---------------------------------------------------------------------------
-- Location beacon: minimap + world map pins on the step's coordinates
-- ---------------------------------------------------------------------------
local pins = {}
local function releasePins()
    if not HBDPins then return end
    HBDPins:RemoveAllMinimapIcons(B)
    HBDPins:RemoveAllWorldMapIcons(B)
    for _, p in ipairs(pins) do p:Hide() end
end
local function pin(i)
    pins[i] = pins[i] or (function()
        local p = CreateFrame("Frame", nil, UIParent)
        p:SetSize(18, 18)
        local t = p:CreateTexture(nil, "OVERLAY")
        t:SetAllPoints(); t:SetTexture(TEX .. "ring"); t:SetVertexColor(0.25, 0.78, 1)
        local dot = p:CreateTexture(nil, "OVERLAY")
        dot:SetSize(7, 7); dot:SetPoint("CENTER"); dot:SetColorTexture(1, 0.82, 0)
        return p
    end)()
    pins[i]:Show()
    return pins[i]
end

function B.UpdatePins()
    if not HBDPins then return end
    releasePins()
    if not NS.db or not NS.db.profile.beacon.enabled or not NS.db.profile.beacon.pins then return end
    local s = NS.Progress.current
    if not s or not s.zone or not s.coords then return end
    for i, c in ipairs(s.coords) do
        if i > 4 then break end
        local p = pin(i)
        pcall(HBDPins.AddMinimapIconMap, HBDPins, B, p, s.zone, c.x, c.y, true, true)
        local p2 = pin(i + 10)
        pcall(HBDPins.AddWorldMapIconMap, HBDPins, B, p2, s.zone, c.x, c.y, HBD_PINS_WORLDMAP_SHOW_PARENT)
    end
end

function B.ApplySettings()
    B.RescanPlates(); B.UpdatePins(); B.UpdateTargetButton()
end
NS:On("PLAYER_READY", function() NS:After(3, B.ApplySettings) end)

-- offline test hook
B._test = { cleanName = cleanName, patterns = TITLE_PATTERNS }
