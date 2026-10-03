-- CompletionRoute :: UI/Log.lua
-- In-game log window (/or log): every CompletionRoute chat message is also kept here, selectable/copyable,
-- so users can paste bug reports and testers can read output without fighting Trade chat.
local ADDON, NS = ...
local L = { lines = {}, max = 300 }
NS.Log = L

local origPrint, origErr = NS.Print, NS.Error
local function push(kind, msg)
    L.lines[#L.lines + 1] = ("%s %s%s"):format(date("%H:%M:%S"), kind, msg)
    if #L.lines > L.max then table.remove(L.lines, 1) end
    if L.frame and L.frame:IsShown() then L.Refresh() end
end
function NS:Print(...) local m = strjoin(" ", tostringall(...)) push("", m:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) origPrint(self, m) end
function NS:Error(...) local m = strjoin(" ", tostringall(...)) push("[ERR] ", m) origErr(self, m) end
local origDebug = NS.Debug
function NS:Debug(...) local m = strjoin(" ", tostringall(...)) push("[dbg] ", m) if self.db and self.db.profile.debug then origDebug(self, m) end end

local function build()
    local f = CreateFrame("Frame", "CompletionRouteLog", UIParent, "BackdropTemplate")
    f:SetSize(620, 380); f:SetPoint("CENTER", 0, 100)
    f:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    f:SetBackdropColor(0, 0, 0, 0.92)
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("DIALOG")
    local t = f:CreateFontString(nil, "OVERLAY", "GameFontNormal"); t:SetPoint("TOP", 0, -8); t:SetText("CompletionRoute log  (Ctrl-A, Ctrl-C to copy)")
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", -2, -2)
    local sf = CreateFrame("ScrollFrame", "CompletionRouteLogScroll", f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 10, -28); sf:SetPoint("BOTTOMRIGHT", -30, 10)
    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true); eb:SetFontObject(ChatFontNormal); eb:SetWidth(570); eb:SetAutoFocus(false)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    sf:SetScrollChild(eb)
    f.eb, f.sf = eb, sf
    tinsert(UISpecialFrames, "CompletionRouteLog")
    L.frame = f
end
function L.Refresh()
    if not L.frame then build() end
    L.frame.eb:SetText(table.concat(L.lines, "\n"))
    C_Timer.After(0.05, function() L.frame.sf:SetVerticalScroll(L.frame.sf:GetVerticalScrollRange()) end)
end
function L.Toggle() if not L.frame then build() end if L.frame:IsShown() then L.frame:Hide() else L.Refresh() L.frame:Show() end end
function L.Clear() L.lines = {} L.Refresh() end
