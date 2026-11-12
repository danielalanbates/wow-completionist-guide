-- CompletionRoute :: UI/Minimap.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- The minimap button: a small round button on the minimap's edge.  Left click shows or hides the step window, right
-- click opens the Routes window, dragging moves it around the edge.  Where it sits is profile.minimapAngle (degrees,
-- 0 = east, counter-clockwise); profile.minimapButton = false hides it (Options: "Minimap button").
-- No library: a plain Button parented to Minimap, its centre on a circle a little outside the minimap's radius.  A UI
-- addon can make the minimap square and say so through GetMinimapShape(); on a square side the button is pushed out
-- along the same line to the square's edge instead.  The frame Minimap exists on all five clients.
local ADDON, NS = ...
local MB = {}
NS.MinimapButton = MB

MB.SIZE = 31            -- the client's own minimap buttons are this size
MB.OFFSET = 5           -- how far outside the minimap's edge the button's centre sits
MB.DEFAULT_ANGLE = 200  -- left of the minimap, a little below the middle
local ICON = "Interface\\AddOns\\" .. ADDON .. "\\Textures\\arrow"

local function num(v) return type(v) == "number" and v or nil end

-- Is this quarter of the minimap round?  GetMinimapShape answers "ROUND" (also when nothing answers), "SQUARE",
-- "CORNER-<quarter>" (only that quarter round), "SIDE-<side>" (the two quarters on that side round) or
-- "TRICORNER-<quarter>" (all but the opposite quarter round).  v is "TOP" or "BOTTOM", h is "LEFT" or "RIGHT".
local function roundQuarter(shape, v, h)
    if type(shape) ~= "string" or shape == "ROUND" then return true end
    if shape == "SQUARE" then return false end
    local kind, at = shape:match("^(%u+)%-(%u+)$")
    if kind == "CORNER" then return at == v .. h end
    if kind == "SIDE" then return at == v or at == h end
    if kind == "TRICORNER" then return at:sub(1, #v) == v or at:sub(-#h) == h end
    return true
end
MB.RoundQuarter = roundQuarter

-- the button's centre relative to the minimap's centre, for an angle in degrees
function MB.Offsets(angle)
    local rad = math.rad(tonumber(angle) or MB.DEFAULT_ANGLE)
    local c, s = math.cos(rad), math.sin(rad)
    local mm = Minimap
    local w = (num(mm and mm.GetWidth and mm:GetWidth()) or 140) / 2 + MB.OFFSET
    local h = (num(mm and mm.GetHeight and mm:GetHeight()) or 140) / 2 + MB.OFFSET
    local shape = "ROUND"
    if GetMinimapShape then
        local ok, sh = pcall(GetMinimapShape)
        if ok and type(sh) == "string" then shape = sh end
    end
    if roundQuarter(shape, s >= 0 and "TOP" or "BOTTOM", c >= 0 and "RIGHT" or "LEFT") then return c * w, s * h end
    local k = 1 / math.max(math.abs(c), math.abs(s))     -- out along the same line until it meets the square's edge
    return c * w * k, s * h * k
end

-- the angle from the minimap's centre to the mouse, in degrees 0..360 (nil when the client cannot say)
function MB.CursorAngle()
    local mm = Minimap
    if not (mm and mm.GetCenter and GetCursorPosition) then return nil end
    local mx, my = mm:GetCenter()
    local cx, cy = GetCursorPosition()
    local sc = mm.GetEffectiveScale and mm:GetEffectiveScale()
    if not (num(mx) and num(my) and num(cx) and num(cy) and num(sc) and sc > 0) then return nil end
    return math.deg(math.atan2(cy / sc - my, cx / sc - mx)) % 360
end

-- show or hide it by the option, and put it at the saved angle
function MB.Apply()
    local b = MB.button
    if not b then return end
    local p = NS.db and NS.db.profile
    if p and p.minimapButton == false then b:Hide() return end
    local x, y = MB.Offsets(p and p.minimapAngle or MB.DEFAULT_ANGLE)
    b:ClearAllPoints()
    b:SetPoint("CENTER", Minimap, "CENTER", x, y)
    b:Show()
end

-- move it to an angle and remember it (dragging)
function MB.MoveTo(angle)
    angle = tonumber(angle)
    if not angle then return end
    if NS.db then NS.db.profile.minimapAngle = math.floor((angle % 360) * 10 + 0.5) / 10 end
    MB.Apply()
end

if not Minimap then return end      -- a UI that removed the minimap: nothing to hang the button on

local b = CreateFrame("Button", "CompletionRouteMinimapButton", Minimap)
MB.button = b
b:SetSize(MB.SIZE, MB.SIZE)
b:SetFrameStrata("MEDIUM")
if b.SetFrameLevel then b:SetFrameLevel(8) end
b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
b:RegisterForDrag("LeftButton")
b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
-- the dark disc, the addon's arrow (tilted to point up and right) and the gold ring of the client's minimap buttons
local bg = b:CreateTexture(nil, "BACKGROUND")
bg:SetSize(20, 20); bg:SetPoint("TOPLEFT", 7, -5)
bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
local icon = b:CreateTexture(nil, "ARTWORK")
icon:SetSize(18, 18); icon:SetPoint("TOPLEFT", 8, -6)     -- centred on the disc
icon:SetTexture(ICON)
if icon.SetRotation then pcall(icon.SetRotation, icon, -math.pi / 4) end
local ring = b:CreateTexture(nil, "OVERLAY")
ring:SetSize(53, 53); ring:SetPoint("TOPLEFT")
ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
MB.icon = icon

b:SetScript("OnClick", function(_, button)
    if button == "RightButton" then
        if NS.GuideMenu and NS.GuideMenu.Toggle then NS.GuideMenu.Toggle() end
    elseif NS.GuideFrame and NS.GuideFrame.Toggle then
        NS.GuideFrame.Toggle()
    end
end)
b:SetScript("OnEnter", function(self)
    if self.dragging then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Completionist's Guide")
    GameTooltip:AddLine("Left click: step window", 1, 1, 1)
    GameTooltip:AddLine("Right click: routes", 1, 1, 1)
    GameTooltip:AddLine("Drag to move", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end)
b:SetScript("OnLeave", function() GameTooltip:Hide() end)
local function follow() MB.MoveTo(MB.CursorAngle()) end
b:SetScript("OnDragStart", function(self)
    self.dragging = true
    GameTooltip:Hide()
    if self.LockHighlight then self:LockHighlight() end
    self:SetScript("OnUpdate", follow)
end)
b:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
    self.dragging = nil
    if self.UnlockHighlight then self:UnlockHighlight() end
    follow()
end)
b:Hide()        -- until the saved settings are read

NS:On("PLAYER_READY", MB.Apply)
-- a UI addon that resizes the minimap: keep the button on its edge
if Minimap.HookScript then pcall(Minimap.HookScript, Minimap, "OnSizeChanged", function() MB.Apply() end) end
