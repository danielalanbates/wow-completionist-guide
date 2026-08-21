-- CompletionRoute :: UI/Arrow.lua
-- The waypoint arrow.  Points at the router's recommended next target (walk / flight master / boat).
-- When the recommendation is "use an item" or "hearth", the arrow is replaced by a clickable secure
-- item button (Zygor-style) — quest items when you're at the spot, Hearthstone when hearthing is faster.
local ADDON, NS = ...
local U = NS.Util
local A = {}
NS.Arrow = A

local TEX = "Interface\\AddOns\\" .. ADDON .. "\\Textures\\"

local f = CreateFrame("Frame", "CompletionRouteArrow", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
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
local btn = CreateFrame("Button", "CompletionRouteArrowItemButton", f, "SecureActionButtonTemplate")
btn:SetSize(48, 48)
btn:SetPoint("CENTER", f, "TOP", 0, -32)  -- NOTE: protected frames cannot anchor to regions (textures)
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
    GameTooltip:AddLine("|cff3ec6ffCompletionRoute:|r " .. (self.reason or ""), 1, 1, 1, true)
    GameTooltip:Show()
end)
btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- pending secure changes while in combat
local pending
local function applyButton(mode, itemID, spellID, reason)
    if InCombatLockdown() then pending = { mode, itemID, spellID, reason } return end
    pending = nil
    -- "show" with neither an item nor a spell used to leave the empty ring painted on screen
    if mode == "hide" or (not itemID and not spellID) then
        btn:Hide(); btn.itemID, btn.spellID = nil, nil
        return
    end
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

-- Pointer styles: "hand" (default) is a pointing hand tinted to the player's class colour, "arrow"
-- is the original three-colour chevron.  The hand texture is white, so SetVertexColor tints it and
-- its dark outline stays a darker shade of the same colour.
local function classRGB()
    local c = (CUSTOM_CLASS_COLORS and CUSTOM_CLASS_COLORS[NS.player.class]) or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[NS.player.class])
    if c then return c.r, c.g, c.b end
    return 1, 0.82, 0
end
-- distance still has to read at a glance, so the class colour is dimmed when the target is far and
-- brightened when you are on top of it
local function distFactor(dist)
    if not dist then return 1 end
    if dist < 60 then return 1.25 end
    if dist < 400 then return 1 end
    return 0.72
end
local function setPointer(dist, forceStyle)
    local style = forceStyle or (NS.db.profile.arrow.style or "hand")
    if style == "arrow" then
        arrow:SetTexture(colorFor(dist))
        arrow:SetVertexColor(1, 1, 1)
        return
    end
    arrow:SetTexture(TEX .. "hand")
    local r, g, b = classRGB()
    local k = distFactor(dist)
    arrow:SetVertexColor(math.min(1, r * k), math.min(1, g * k), math.min(1, b * k))
end
A.SetPointer = setPointer

function A.Update()
    if not NS.db or not NS.db.profile.arrow.enabled then f:Hide() return end
    -- while dead the pointer still has a job (get back to the body) even with no step loaded
    local dead = NS.Router and NS.Router.IsDead()
    if not NS.Progress.current and not dead then f:Hide() return end
    f:Show()
    local rec = NS.Router and NS.Router.Recommendation()
    if not rec then arrow:Hide() applyButton("hide") title:SetText("") sub:SetText("") eta:SetText("") return end
    title:SetText(rec.text or "")
    if rec.dead then
        -- no Hearthstone, no quest item, no turn-in: hide the secure button outright
        if btn:IsShown() or pending then applyButton("hide") end
        title:SetTextColor(1, 0.55, 0.55)
        if rec.mode == "release" or not rec.wx then
            arrow:Hide()
            sub:SetText(rec.why and ("|cffff9900" .. rec.why .. "|r") or "")
            eta:SetText("")
            lastMode = rec.mode
            return
        end
        local map, x, y, inst, pwx, pwy = U.PlayerPos()
        if not pwx or inst ~= rec.inst then
            arrow:Hide() sub:SetText("|cffff9900corpse is on another continent|r") eta:SetText("")
            return
        end
        arrow:Show()
        setPointer(rec.dist)
        arrow:SetRotation(math.atan2(rec.wx - pwx, rec.wy - pwy) - (GetPlayerFacing() or 0))
        sub:SetText(U.FmtDist(rec.dist) .. "  |cffff9900(your corpse)|r")
        eta:SetText(rec.eta and ("ETA ~" .. U.FmtTime(rec.eta)) or "")
        lastMode = rec.mode
        return
    end
    title:SetTextColor(1, 0.82, 0)
    if (rec.mode == "item" or rec.mode == "hearth") and (rec.item or rec.spell) then
        arrow:Hide()
        applyButton("show", rec.item, rec.spell, rec.text)
        updateCooldown()
        if rec.mode == "hearth" and rec.eta then eta:SetText("ETA ~" .. U.FmtTime(rec.eta)) else eta:SetText("") end
        sub:SetText(rec.mode == "item" and "Click to use" or "Click to hearth")
        lastMode = rec.mode
        return
    end
    if btn:IsShown() or pending then applyButton("hide") end
    if not rec.wx then
        arrow:Hide()
        sub:SetText("|cffff9900no location - /cr why|r")
        eta:SetText("")
        return
    end
    -- rotate arrow
    local map, x, y, inst, pwx, pwy = U.PlayerPos()
    if not pwx or inst ~= rec.inst then
        arrow:Show()
        if (NS.db.profile.arrow.style or "hand") == "hand" then setPointer(nil) else arrow:SetTexture(TEX .. "arrow_blue") arrow:SetVertexColor(1, 1, 1) end
        arrow:SetRotation(0)
        sub:SetText("Different continent - follow the guide"); eta:SetText(rec.eta and ("ETA ~" .. U.FmtTime(rec.eta)) or "")
        return
    end
    local dx, dy = rec.wx - pwx, rec.wy - pwy
    local dist = math.sqrt(dx * dx + dy * dy)
    -- HereBeDragons world axes: x grows WEST, y grows NORTH (GetXY() returns top, left). Bearing measured like
    -- GetPlayerFacing(): 0 = north, counter-clockwise positive -> atan2(west, north). With the arguments the
    -- other way round the arrow was a compass rose (rotated/mirrored), not "up = you are facing the target".
    local bearing = math.atan2(dx, dy)
    local facing = GetPlayerFacing() or 0
    arrow:Show()
    setPointer(dist)
    arrow:SetRotation(bearing - facing)
    local speed = U.TravelSpeed()
    local tag = ""
    if rec.locSource == "quest" then tag = "  |cff6ac9ff(quest objective)|r"
    elseif rec.locSource == "zone" then tag = "  |cffff9900(zone only)|r"
    elseif rec.locSource == "borrowed" then tag = "  |cffff9900(next known step)|r" end
    sub:SetText(U.FmtDist(dist) .. tag)
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
