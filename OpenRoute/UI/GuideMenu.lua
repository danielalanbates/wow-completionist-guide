-- OpenRoute :: UI/GuideMenu.lua
-- Scrollable list of available guides (native + imported from WoW-Pro / Zygor when those addons are installed).
local ADDON, NS = ...
local U, G, P = NS.Util, NS.Guide, NS.Progress
local M = {}
NS.GuideMenu = M

local f = CreateFrame("Frame", "OpenRouteGuideMenu", UIParent, "BackdropTemplate")
f:SetSize(420, 420)
f:SetPoint("CENTER")
f:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
f:SetBackdropColor(0.05, 0.05, 0.08, 0.95)
f:SetBackdropBorderColor(0.3, 0.6, 0.9, 0.9)
f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton"); f:SetClampedToScreen(true)
f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
f:SetFrameStrata("DIALOG")
f:Hide()
tinsert(UISpecialFrames, "OpenRouteGuideMenu")

local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", 0, -10); title:SetText("OpenRoute Guides")
local close = CreateFrame("Button", nil, f, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", -2, -2)

local search = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
search:SetSize(200, 20); search:SetPoint("TOPLEFT", 16, -36); search:SetAutoFocus(false)
search:SetScript("OnTextChanged", function() M.Refresh() end)
local searchLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
searchLabel:SetPoint("LEFT", search, "RIGHT", 6, 0); searchLabel:SetText("filter")

local scroll = CreateFrame("ScrollFrame", "OpenRouteGuideMenuScroll", f, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 12, -62); scroll:SetPoint("BOTTOMRIGHT", -30, 12)
local content = CreateFrame("Frame", nil, scroll)
content:SetSize(360, 10)
scroll:SetScrollChild(content)

local buttons = {}
local function srcColor(src)
    if src == "OpenRoute" then return "|cff3ec6ff" end
    if src == "WoWPro" then return "|cffff9900" end
    if src == "Zygor" then return "|cffffd200" end
    return "|cffaaaaaa"
end

function M.Refresh()
    local filter = (search:GetText() or ""):lower()
    local list = G.Available()
    local y, n = 0, 0
    for _, g in ipairs(list) do
        local label = ("%s%s|r  |cff888888[%s%s]|r"):format(srcColor(g.source), g.name or g.id, g.type or "", (g.minlevel and (" %d-%d"):format(g.minlevel, g.maxlevel or g.minlevel) or ""))
        if filter == "" or (g.name or g.id):lower():find(filter, 1, true) or (g.source or ""):lower():find(filter, 1, true) or (g.zone or ""):lower():find(filter, 1, true) then
            n = n + 1
            local b = buttons[n]
            if not b then
                b = CreateFrame("Button", nil, content)
                b:SetHeight(20); b:SetPoint("LEFT", 0, 0); b:SetPoint("RIGHT", 0, 0)
                b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                b.text:SetPoint("LEFT", 4, 0); b.text:SetJustifyH("LEFT")
                b.hl = b:CreateTexture(nil, "HIGHLIGHT"); b.hl:SetAllPoints(); b.hl:SetColorTexture(1, 1, 1, 0.1)
                b:SetScript("OnClick", function(self) P.Load(self.gid) f:Hide() end)
                b:SetScript("OnEnter", function(self)
                    local gg = G.registry[self.gid]
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText(gg.name or gg.id)
                    GameTooltip:AddLine("Source: " .. (gg.source or "?") .. "   Author: " .. (gg.author or "?"), 1, 1, 1)
                    if gg.zone then GameTooltip:AddLine("Zone: " .. tostring(gg.zone), 1, 1, 1) end
                    if gg.faction then GameTooltip:AddLine("Faction: " .. gg.faction, 1, 1, 1) end
                    if gg.next then GameTooltip:AddLine("Next: " .. gg.next, 0.7, 0.7, 0.7) end
                    GameTooltip:Show()
                end)
                b:SetScript("OnLeave", function() GameTooltip:Hide() end)
                buttons[n] = b
            end
            b.gid = g.id
            b.text:SetText(label .. (P.guide and P.guide.id == g.id and "  |cff00ff00(active)|r" or ""))
            b:ClearAllPoints(); b:SetPoint("TOPLEFT", 0, -y); b:SetPoint("RIGHT", 0, 0)
            b:Show()
            y = y + 20
        end
    end
    for i = n + 1, #buttons do buttons[i]:Hide() end
    content:SetHeight(math.max(y, 10))
    if #list == 0 then title:SetText("OpenRoute Guides (none registered)") else title:SetText(("OpenRoute Guides (%d)"):format(#list)) end
end
function M.Toggle() if f:IsShown() then f:Hide() else M.Refresh() f:Show() end end
function M.Show() M.Refresh() f:Show() end
