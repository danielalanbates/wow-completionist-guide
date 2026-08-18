-- OpenRoute :: UI/GuideFrame.lua
-- The guide viewer window: current + upcoming steps (in optimized order), route summary, controls.
local ADDON, NS = ...
local U, G, P = NS.Util, NS.Guide, NS.Progress
local GF = {}
NS.GuideFrame = GF

local ROWS = 8
local ROW_H = 34

local f = CreateFrame("Frame", "OpenRouteFrame", UIParent, "BackdropTemplate")
GF.frame = f
f:SetSize(330, 60 + ROWS * ROW_H)
f:SetPoint("CENTER")
f:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
f:SetBackdropColor(0.05, 0.05, 0.08, 0.85)
f:SetBackdropBorderColor(0.3, 0.6, 0.9, 0.9)
f:SetMovable(true); f:EnableMouse(true); f:SetClampedToScreen(true); f:SetResizable(true)
if f.SetResizeBounds then f:SetResizeBounds(240, 120) elseif f.SetMinResize then f:SetMinResize(240, 120) end
f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", function(self) if not NS.db.profile.frame.lock then self:StartMoving() end end)
f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, _, x, y = self:GetPoint()
    NS.db.profile.frame.point, NS.db.profile.frame.x, NS.db.profile.frame.y = p, x, y
end)
f:SetFrameStrata("MEDIUM")

-- title bar
local titleText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
titleText:SetPoint("TOPLEFT", 10, -8); titleText:SetPoint("RIGHT", -70, 0); titleText:SetJustifyH("LEFT")
titleText:SetText("|cff3ec6ffOpen|r|cffffd200Route|r")

local function smallButton(text, w, tip, onClick)
    local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    b:SetSize(w, 18); b:SetText(text)
    b:SetScript("OnClick", onClick)
    b:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_TOP") GameTooltip:SetText(tip) GameTooltip:Show() end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end
local bClose = smallButton("x", 20, "Hide (/or show)", function() f:Hide() end)
bClose:SetPoint("TOPRIGHT", -6, -6)
local bMenu = smallButton("Guides", 48, "Choose a guide", function() NS.GuideMenu.Toggle() end)
bMenu:SetPoint("RIGHT", bClose, "LEFT", -2, 0)
local bUndo = smallButton("<", 20, "Undo last completed step", function() P.Undo() end)
bUndo:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -28)
local bSkip = smallButton(">", 20, "Skip current step", function() if P.current then P.Skip(P.current) end end)
bSkip:SetPoint("LEFT", bUndo, "RIGHT", 2, 0)
local bRoute = smallButton("Route", 44, "Toggle route optimizer (reordering)", function()
    NS.db.profile.routing.reorder = not NS.db.profile.routing.reorder
    NS:Print("Step reordering " .. (NS.db.profile.routing.reorder and "ON" or "OFF"))
    P.Refresh()
end)
bRoute:SetPoint("LEFT", bSkip, "RIGHT", 2, 0)
local bOpt = smallButton("Opts", 40, "Options", function() NS.Options.Open() end)
bOpt:SetPoint("LEFT", bRoute, "RIGHT", 2, 0)

local pathText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
pathText:SetPoint("LEFT", bOpt, "RIGHT", 6, 0); pathText:SetPoint("RIGHT", -8, 0)
pathText:SetJustifyH("LEFT"); pathText:SetTextColor(0.6, 0.85, 1)
pathText:SetWordWrap(false)

-- rows
local rows = {}
local function makeRow(i)
    local r = CreateFrame("Button", nil, f)
    r:SetHeight(ROW_H)
    r:SetPoint("TOPLEFT", 8, -50 - (i - 1) * ROW_H)
    r:SetPoint("RIGHT", -8, 0)
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints(); r.bg:SetColorTexture(1, 1, 1, 0.04)
    r.check = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate")
    r.check:SetSize(22, 22); r.check:SetPoint("LEFT", 0, 0)
    r.check:SetScript("OnClick", function(self) if r.step then P.MarkDone(r.step, true) end end)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(18, 18); r.icon:SetPoint("LEFT", r.check, "RIGHT", 2, 0)
    r.title = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    r.title:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 4, 1); r.title:SetPoint("RIGHT", -4, 0)
    r.title:SetJustifyH("LEFT"); r.title:SetWordWrap(false)
    r.note = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.note:SetPoint("TOPLEFT", r.title, "BOTTOMLEFT", 0, -1); r.note:SetPoint("RIGHT", -4, 0)
    r.note:SetJustifyH("LEFT"); r.note:SetWordWrap(false); r.note:SetTextColor(0.75, 0.75, 0.75)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r:SetScript("OnClick", function(self, button)
        if not self.step then return end
        if button == "RightButton" then P.Skip(self.step)
        elseif IsShiftKeyDown() then P.MarkDone(self.step, true) end
    end)
    r:SetScript("OnEnter", function(self)
        if not self.step then return end
        local s = self.step
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText((G.ACTION_LABEL[s.action] or s.action) .. ": " .. s.title, 1, 0.82, 0, true)
        if s.note then GameTooltip:AddLine(s.note, 1, 1, 1, true) end
        if s.qid then GameTooltip:AddLine("Quest ID: " .. table.concat(s.qid, ", "), 0.6, 0.6, 0.6) end
        if s.zone then GameTooltip:AddLine("Zone: " .. U.MapName(s.zone) .. (s.coords and (" " .. string.format("%.1f, %.1f", s.coords[1].x * 100, s.coords[1].y * 100)) or ""), 0.6, 0.6, 0.6) end
        local secs = NS.Router and NS.Router.TravelSecondsFromPlayer(s)
        if secs then GameTooltip:AddLine("Travel from you: ~" .. U.FmtTime(secs), 0.6, 0.85, 1) end
        if s.item then GameTooltip:AddLine("Uses item: " .. U.ItemName(s.item), 0.6, 1, 0.6) end
        GameTooltip:AddLine("|cff888888Click checkbox / Shift-click: complete   Right-click: skip|r")
        GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    rows[i] = r
    return r
end
for i = 1, ROWS do makeRow(i) end

local function stepColor(step)
    local a = step.action
    if a == "A" or a == "a" or a == "!" then return 1, 0.9, 0.4 end
    if a == "T" or a == "t" then return 0.5, 1, 0.5 end
    if a == "C" or a == "K" then return 1, 0.6, 0.6 end
    if a == "R" or a == "F" or a == "H" or a == "b" or a == "J" then return 0.6, 0.85, 1 end
    return 1, 1, 1
end

function GF.Update()
    if not P.guide then titleText:SetText("|cff3ec6ffOpen|r|cffffd200Route|r - no guide (/or guides)") for i = 1, ROWS do rows[i]:Hide() end return end
    local done, total = 0, #P.steps
    for _ in pairs(NS.db.char.done[P.guide.id] or {}) do done = done + 1 end
    titleText:SetText(("|cff3ec6ff%s|r  |cff888888%d/%d|r"):format(P.guide.name or P.guide.id, done, total))
    local list = P.Upcoming(ROWS)
    for i = 1, ROWS do
        local r, s = rows[i], list[i]
        if s then
            r.step = s
            r:Show()
            r.icon:SetTexture(G.ACTION_ICON[s.action] or "Interface\\Icons\\INV_Misc_QuestionMark")
            local label = (G.ACTION_LABEL[s.action] or s.action)
            local extra = ""
            if (s.action == "C" or s.action == "K") and s.qid and U.IsOnQuest(s.qid[1]) then
                local fu, req = U.QuestObjective(s.qid[1], tonumber(s.qo) or 1)
                if req and req > 0 then extra = (" |cffaaaaaa(%d/%d)|r"):format(fu, req) end
            end
            r.title:SetText(label .. ": " .. s.title .. extra)
            r.title:SetTextColor(stepColor(s))
            local note = s.note or ""
            if s.optional then note = "|cff888888(optional)|r " .. note end
            r.note:SetText(note)
            r.check:SetChecked(false)
            if i == 1 then r.bg:SetColorTexture(0.3, 0.6, 0.9, 0.25) else r.bg:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.03 or 0.06) end
        else r.step = nil r:Hide() end
    end
    -- route summary
    local path = NS.Router and NS.Router.CurrentPath()
    if path then pathText:SetText(NS.TravelGraph.Describe(path)) else pathText:SetText("") end
end

local acc = 0
f:SetScript("OnUpdate", function(_, el)
    acc = acc + el
    if acc < 1 then return end
    acc = 0
    pcall(GF.Update)
end)
NS:On("PROGRESS_REFRESHED", function() pcall(GF.Update) end)
NS:On("GUIDE_LOADED", function() pcall(GF.Update) end)

function GF.ApplySettings()
    local p = NS.db.profile.frame
    f:ClearAllPoints(); f:SetPoint(p.point or "CENTER", UIParent, p.point or "CENTER", p.x or 0, p.y or 0)
    f:SetScale(p.scale or 1); f:SetAlpha(p.alpha or 1)
end
function GF.Toggle() if f:IsShown() then f:Hide() else f:Show() GF.Update() end end
NS:On("PLAYER_READY", GF.ApplySettings)
