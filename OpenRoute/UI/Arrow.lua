-- OpenRoute :: UI/Arrow.lua
-- The waypoint arrow.  Points at the router's recommended next target (walk / flight master / boat).
-- When the recommendation is "use an item" or "hearth", the arrow is replaced by a clickable secure
-- item button (Zygor-style) — quest items when you're at the spot, Hearthstone when hearthing is faster.
local ADDON, NS = ...
local U = NS.Util
local A = {}
NS.Arrow = A

local TEX = "Interface\\AddOns\\" .. ADDON .. "\\Textures\\"

local f = CreateFrame("Frame", "OpenRouteArrow", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
A.frame = f
f:SetSize(160, 110)
f:SetPoint("TOP", UIParent, "TOP", 0, -180)
f:SetMovable(true); f:EnableMouse(true); f:SetClampedToScreen(true)
f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", function(self) if not NS.db.profile.arrow.lock then self:StartMoving() end end)
f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, _, x, y = self:GetPoint()
    NS.db.profile.arrow.point, NS.db.profile.arrow.x, NS.db.profile.arrow.y = p, x, y
end)
f:SetFrameStrata("MEDIUM")

local arrow = f:CreateTexture(nil, "ARTWORK")
arrow:SetTexture(TEX .. "arrow")
arrow:SetSize(56, 56)
arrow:SetPoint("TOP", f, "TOP", 0, -4)
A.tex = arrow

local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOP", arrow, "BOTTOM", 0, -2)
title:SetWidth(220); title:SetJustifyH("CENTER"); title:SetWordWrap(true); title:SetMaxLines(2)
title:SetTextColor(1, 0.82, 0)
local sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
sub:SetPoint("TOP", title, "BOTTOM", 0, -1)
sub:SetWidth(220); sub:SetJustifyH("CENTER")
local eta = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
eta:SetPoint("TOP", sub, "BOTTOM", 0, -1)
eta:SetTextColor(0.6, 0.85, 1)

-- Secure item/spell button that takes the arrow's place
local btn = CreateFrame("Button", "OpenRouteArrowItemButton", f, "SecureActionButtonTemplate")
btn:SetSize(48, 48)
btn:SetPoint("CENTER", arrow, "CENTER", 0, 0)
btn:RegisterForClicks("AnyUp", "AnyDown")
btn:SetAttribute("type", "item")
local ring = btn:CreateTexture(nil, "BACKGROUND")
ring:SetTexture(TEX .. "ring"); ring:SetAllPoints(); ring:SetSize(56, 56)
local icon = btn:CreateTexture(nil, "ARTWORK")
icon:SetPoint("TOPLEFT", 5, -5); icon:SetPoint("BOTTOMRIGHT", -5, 5)
icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
btn.icon = icon
local cd = CreateFrame("Cooldown", nil, btn, "CooldownFrameTemplate")
cd:SetAllPoints(icon)
btn.cd = cd
btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
btn:Hide()
A.button = btn
btn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    if self.itemID then GameTooltip:SetItemByID(self.itemID) elseif self.spellID then GameTooltip:SetSpellByID(self.spellID) end
    GameTooltip:AddLine("|cff3ec6ffOpenRoute:|r " .. (self.reason or ""), 1, 1, 1, true)
    GameTooltip:Show()
end)
btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- pending secure changes while in combat
local pending
local function applyButton(mode, itemID, spellID, reason)
    if InCombatLockdown() then pending = { mode, itemID, spellID, reason } return end
    pending = nil
    if mode == "hide" then btn:Hide() btn.itemID, btn.spellID = nil, nil return end
    if itemID then
        btn:SetAttribute("type", "item"); btn:SetAttribute("item", "item:" .. itemID)
        icon:SetTexture(U.ItemIcon(itemID))
        btn.itemID, btn.spellID = itemID, nil
    elseif spellID then
        btn:SetAttribute("type", "spell"); btn:SetAttribute("spell", spellID)
        local tex = (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(spellID)) or (GetSpellTexture and GetSpellTexture(spellID))
        icon:SetTexture(tex)
        btn.itemID, btn.spellID = nil, spellID
    end
    btn.reason = reason
    btn:Show()
end
NS:RegisterEvent("PLAYER_REGEN_ENABLED", function() if pending then applyButton(unpack(pending)) end end)

local function updateCooldown()
    if not btn:IsShown() then return end
    if btn.itemID then
        local start, dur
        if C_Container and C_Container.GetItemCooldown then start, dur = C_Container.GetItemCooldown(btn.itemID)
        elseif C_Item and C_Item.GetItemCooldown then start, dur = C_Item.GetItemCooldown(btn.itemID)
        elseif GetItemCooldown then start, dur = GetItemCooldown(btn.itemID) end
        if start and dur then cd:SetCooldown(start, dur) end
    elseif btn.spellID then
        local start, dur
        if C_Spell and C_Spell.GetSpellCooldown then local c = C_Spell.GetSpellCooldown(btn.spellID) start, dur = c and c.startTime, c and c.duration
        elseif GetSpellCooldown then start, dur = GetSpellCooldown(btn.spellID) end
        if start and dur then cd:SetCooldown(start, dur) end
    end
end

-- ---------------------------------------------------------------------------
-- Update loop
-- ---------------------------------------------------------------------------
local lastMode
local acc, slow = 0, 0
local function colorFor(dist)
    if not dist then return TEX .. "arrow" end
    if dist < 60 then return TEX .. "arrow_green" end
    if dist < 400 then return TEX .. "arrow" end
    return TEX .. "arrow_red"
end

function A.Update()
    if not NS.db or not NS.db.profile.arrow.enabled or not NS.Progress.current then f:Hide() return end
    f:Show()
    local rec = NS.Router and NS.Router.Recommendation()
    if not rec then arrow:Hide() applyButton("hide") title:SetText("") sub:SetText("") eta:SetText("") return end
    title:SetText(rec.text or "")
    if rec.mode == "item" or rec.mode == "hearth" then
        arrow:Hide()
        applyButton("show", rec.item, rec.spell, rec.text)
        updateCooldown()
        if rec.mode == "hearth" and rec.eta then eta:SetText("ETA ~" .. U.FmtTime(rec.eta)) else eta:SetText("") end
        sub:SetText(rec.mode == "item" and "Click to use" or "Click to hearth")
        lastMode = rec.mode
        return
    end
    if btn:IsShown() or pending then applyButton("hide") end
    if not rec.wx then arrow:Hide() sub:SetText("(no location for this step)") eta:SetText("") return end
    -- rotate arrow
    local map, x, y, inst, pwx, pwy = U.PlayerPos()
    if not pwx or inst ~= rec.inst then
        arrow:Show(); arrow:SetTexture(TEX .. "arrow_blue"); arrow:SetRotation(0)
        sub:SetText("Different continent - follow the guide"); eta:SetText(rec.eta and ("ETA ~" .. U.FmtTime(rec.eta)) or "")
        return
    end
    local dx, dy = rec.wx - pwx, rec.wy - pwy
    local dist = math.sqrt(dx * dx + dy * dy)
    local bearing = math.atan2(dy, dx)             -- 0 = north, CCW positive (world y = west)
    local facing = GetPlayerFacing() or 0
    arrow:Show()
    arrow:SetTexture(colorFor(dist))
    arrow:SetRotation(bearing - facing)
    local speed = U.TravelSpeed()
    sub:SetText(("%s"):format(U.FmtDist(dist)))
    if rec.eta then eta:SetText("ETA ~" .. U.FmtTime(rec.eta)) else eta:SetText("ETA ~" .. U.FmtTime(dist / speed)) end
    lastMode = rec.mode
end

f:SetScript("OnUpdate", function(_, el)
    acc = acc + el
    if acc < 0.05 then return end
    acc = 0
    local ok, err = pcall(A.Update)
    if not ok then NS:Debug("Arrow: " .. tostring(err)) end
end)

function A.ApplySettings()
    local p = NS.db.profile.arrow
    f:ClearAllPoints(); f:SetPoint(p.point or "TOP", UIParent, p.point or "TOP", p.x or 0, p.y or -180)
    f:SetScale(p.scale or 1); f:SetAlpha(p.alpha or 1)
    if p.enabled then f:Show() else f:Hide() end
end
NS:On("PLAYER_READY", A.ApplySettings)
NS:On("STEP_CHANGED", function() acc = 1 end)
