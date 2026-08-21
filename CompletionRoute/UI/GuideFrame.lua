-- CompletionRoute :: UI/GuideFrame.lua
-- The guide viewer window: current + upcoming steps (in optimized order), route summary, controls.
local ADDON, NS = ...
local U, G, P = NS.Util, NS.Guide, NS.Progress
local GF = {}
NS.GuideFrame = GF


local f = CreateFrame("Frame", "CompletionRouteFrame", UIParent, "BackdropTemplate")
GF.frame = f
f:SetSize(400, 170)
f:SetPoint("CENTER")
f:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
f:SetBackdropColor(0.03, 0.03, 0.05, 0.93)
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
titleText:SetText("|cff7ddf8fCompletion|r|cffffd200Route|r")

local function smallButton(text, w, tip, onClick, parent)
    local b = CreateFrame("Button", nil, parent or f, "UIPanelButtonTemplate")
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
local bRoute = smallButton("Route", 44, "Toggle route optimizer (reordering)", function()
    NS.db.profile.routing.reorder = not NS.db.profile.routing.reorder
    NS:Print("Step reordering " .. (NS.db.profile.routing.reorder and "ON" or "OFF"))
    P.Refresh()
end)
bRoute:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -28)
local bOpt = smallButton("Opts", 40, "Options", function() NS.Options.Open() end)
bOpt:SetPoint("LEFT", bRoute, "RIGHT", 2, 0)

local pathText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
pathText:SetPoint("BOTTOMLEFT", 10, 8); pathText:SetPoint("RIGHT", -24, 0)
pathText:SetJustifyH("LEFT"); pathText:SetTextColor(0.6, 0.85, 1)
pathText:SetWordWrap(false)

-- resize grip (bottom-right): drag to scale the whole window
local grip = CreateFrame("Button", nil, f)
grip:SetSize(20, 20); grip:SetPoint("BOTTOMRIGHT", -2, 2)
grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
grip:SetScript("OnMouseDown", function()
    grip.drag = true
    grip.y0 = select(2, GetCursorPosition())
    grip.s0 = f:GetScale()
end)
grip:SetScript("OnMouseUp", function() grip.drag = nil NS.db.profile.frame.scale = f:GetScale() end)
grip:SetScript("OnUpdate", function()
    if not grip.drag then return end
    local y = select(2, GetCursorPosition())
    local s = math.max(0.6, math.min(2.0, grip.s0 + (grip.y0 - y) / 400))
    f:SetScale(s)
end)

-- shown instead of an empty list, so finishing the last step never looks like the addon died
local empty = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
empty:SetPoint("TOPLEFT", 36, -56); empty:SetPoint("RIGHT", -36, 0)
empty:SetJustifyH("LEFT"); empty:SetWordWrap(true); empty:Hide()

-- ---------------------------------------------------------------------------
-- ONE step at a time (Zygor-style). Nothing to tick: steps complete themselves from quest log,
-- inventory, position and taxi/bind events (Progress.CheckStep). The arrows move by hand.
-- ---------------------------------------------------------------------------
local card = CreateFrame("Button", nil, f)
card:SetPoint("TOPLEFT", 34, -50); card:SetPoint("BOTTOMRIGHT", -34, 26)
card.bg = card:CreateTexture(nil, "BACKGROUND"); card.bg:SetAllPoints(); card.bg:SetColorTexture(0.3, 0.6, 0.9, 0.10)
card.icon = card:CreateTexture(nil, "ARTWORK"); card.icon:SetSize(30, 30); card.icon:SetPoint("TOPLEFT", 6, -6)
card.title = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
card.title:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", 8, -2); card.title:SetPoint("RIGHT", -6, 0)
card.title:SetJustifyH("LEFT"); card.title:SetWordWrap(true); card.title:SetMaxLines(2)
card.note = card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
card.note:SetPoint("TOPLEFT", card.icon, "BOTTOMLEFT", 0, -8); card.note:SetPoint("RIGHT", -6, 0)
card.note:SetJustifyH("LEFT"); card.note:SetWordWrap(true); card.note:SetMaxLines(4); card.note:SetTextColor(0.85, 0.85, 0.85)
card.where = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
card.where:SetPoint("BOTTOMLEFT", 6, 6); card.where:SetPoint("RIGHT", -6, 0)
card.where:SetJustifyH("LEFT"); card.where:SetWordWrap(false); card.where:SetTextColor(0.6, 0.85, 1)
card:RegisterForClicks("LeftButtonUp")
card:SetScript("OnClick", function(self)
    if not self.step then return end
    GF.ShowDetail(self.step)
end)
card:SetScript("OnEnter", function(self)
    if not self.step then return end
    local s = self.step
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText((G.ACTION_LABEL[s.action] or s.action) .. ": " .. s.title, 1, 0.82, 0, 1, true)
    if s.note then GameTooltip:AddLine(s.note, 1, 1, 1, true) end
    if s.qid then GameTooltip:AddLine("Quest ID: " .. table.concat(s.qid, ", "), 0.6, 0.6, 0.6) end
    if s.zone then GameTooltip:AddLine("Zone: " .. U.MapName(s.zone) .. (s.coords and (" " .. string.format("%.1f, %.1f", s.coords[1].x * 100, s.coords[1].y * 100)) or ""), 0.6, 0.6, 0.6) end
    if s.item then GameTooltip:AddLine("Uses item: " .. U.ItemName(s.item), 0.6, 1, 0.6) end
    GameTooltip:AddLine("|cff888888Click for details. Steps complete themselves; use the arrows to move by hand.|r", 1, 1, 1, true)
    GameTooltip:Show()
end)
card:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- the two arrows: back = un-complete the last step, forward = mark this one done and move on
local function arrow(dir, tip, fn)
    local b = CreateFrame("Button", nil, f)
    b:SetSize(26, 40)
    b:SetNormalTexture(dir == "L" and "Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Up" or "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up")
    b:SetPushedTexture(dir == "L" and "Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Down" or "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Down")
    b:SetDisabledTexture(dir == "L" and "Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Disabled" or "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Disabled")
    b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    b:SetScript("OnClick", fn)
    b:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_TOP") GameTooltip:SetText(tip) GameTooltip:Show() end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end
local bBack = arrow("L", "Back one step (un-complete the last step)", function() P.Undo() end)
bBack:SetPoint("LEFT", f, "LEFT", 4, -6)
local bFwd = arrow("R", "Forward one step (mark this one done)", function() if P.current then P.MarkDone(P.current, true) end end)
bFwd:SetPoint("RIGHT", f, "RIGHT", -4, -6)
GF.card, GF.back, GF.forward = card, bBack, bFwd

local function stepColor(step)
    local a = step.action
    if a == "A" or a == "a" then return 1, 0.82, 0 end
    if a == "C" or a == "K" then return 1, 1, 1 end
    if a == "T" or a == "t" then return 0.4, 1, 0.4 end
    if a == "R" or a == "F" or a == "b" or a == "H" or a == "h" then return 0.5, 0.8, 1 end
    return 1, 1, 1
end

function GF.Update()
    if not P.guide then
        titleText:SetText("|cff7ddf8fCompletion|r|cffffd200Route|r - no guide (/cr guides)")
        card:Hide()
        empty:SetText("No guide loaded.\nClick |cffffd200Guides|r above, or type /cr guides.")
        empty:Show()
        bBack:Disable() bFwd:Disable()
        return
    end
    local done, total = 0, #P.steps
    for _ in pairs(NS.db.char.done[P.guide.id] or {}) do done = done + 1 end
    local s = P.current
    local pos = total
    if s then   -- position in the loaded list (access-chain steps carry negative indices and sit in front)
        for i, st in ipairs(P.steps) do if st == s then pos = i break end end
    end
    local label = (s and s.access) and "unlock step" or "step"
    titleText:SetText(("|cff3ec6ff%s|r  |cff888888%s %d of %d|r"):format(P.guide.name or P.guide.id, label, math.min(pos, total), total))
    bBack:SetEnabled(done > 0 or next(NS.db.char.skipped[P.guide.id] or {}) ~= nil)
    bFwd:SetEnabled(s ~= nil)
    if not s then
        card:Hide()
        local applicable = #P.Pending(1)
        if done >= total and total > 0 then
            empty:SetText(("|cff00ff00Guide complete|r - all %d steps done.\nClick |cffffd200Guides|r for the next one (the |cff7ddf8fNext Step|r category lists everything matched to your level)."):format(total))
        elseif applicable == 0 then
            empty:SetText("No steps in this guide apply to you right now.\nThey may be for the other faction, another class, or a level you have passed.\nTry |cffffd200Guides|r -> |cff7ddf8fNext Step|r, or /cr why.")
        else
            empty:SetText("Nothing to show - type /cr why for the reason.")
        end
        empty:Show()
        pathText:SetText("")
        return
    end
    empty:Hide()
    card.step = s
    card:Show()
    card.icon:SetTexture(G.ACTION_ICON[s.action] or "Interface\\Icons\\INV_Misc_QuestionMark")
    local label = (G.ACTION_LABEL[s.action] or s.action)
    local extra = ""
    if (s.action == "C" or s.action == "K") and s.qid and U.IsOnQuest(s.qid[1]) then
        local fu, req = U.QuestObjective(s.qid[1], tonumber(s.qo) or 1)
        if req and req > 0 then extra = (" |cffaaaaaa(%d/%d)|r"):format(fu, req) end
    end
    card.title:SetText(("|cffffd200%s|r  %s%s"):format(label, s.title, extra))
    card.title:SetTextColor(stepColor(s))
    local note = s.note or ""
    if s.optional then note = "|cff888888(optional)|r " .. note end
    card.note:SetText(note)
    -- where: distance if we can measure it, else the zone name; blank rather than a guess
    local where = ""
    if NS.Router then
        local _, _, _, pinst, pwx, pwy = U.PlayerPos()
        local tx, ty, ti = NS.Router.StepWorld(s)
        if tx and pwx then
            if ti == pinst then where = U.FmtDist(math.sqrt((tx - pwx) ^ 2 + (ty - pwy) ^ 2)) .. (s.zone and ("  -  " .. U.MapName(s.zone)) or "")
            elseif s.zone then where = U.MapName(s.zone) end
        elseif s.zone then where = U.MapName(s.zone) end
    end
    card.where:SetText(where)
    local path = NS.Router and NS.Router.CurrentPath()
    if path then pathText:SetText(NS.TravelGraph.Describe(path)) else pathText:SetText("") end
end

function GF.RowsShown() return (P.guide and P.current and card:IsShown()) and 1 or 0 end

local acc = 0
f:SetScript("OnUpdate", function(_, el)
    acc = acc + el
    if acc < 1 then return end
    acc = 0
    GF.SafeUpdate()
end)
function GF.SafeUpdate()
    local ok, err = pcall(GF.Update)
    if not ok and not GF.errShown then
        GF.errShown = true
        NS:Print("|cffff4040Guide window error:|r " .. tostring(err))
        NS.db.char.luaErrors = NS.db.char.luaErrors or {}
        tinsert(NS.db.char.luaErrors, "GuideFrame.Update: " .. tostring(err))
    end
end
NS:On("PROGRESS_REFRESHED", function() GF.SafeUpdate() end)
NS:On("GUIDE_LOADED", function()
    -- Selecting a guide in the browser used to close the browser and, if this window happened to
    -- be hidden, show nothing at all - it read as "the guide was deleted".
    if not f:IsShown() then f:Show() end
    GF.SafeUpdate()
end)

-- ---------------------------------------------------------------------------
-- Step detail popup: everything known about one step, including live quest objectives.
-- ---------------------------------------------------------------------------
local detail = CreateFrame("Frame", "CompletionRouteStepDetail", UIParent, "BackdropTemplate")
GF.detail = detail
detail:SetSize(360, 260)
detail:SetPoint("LEFT", f, "RIGHT", 8, 0)
detail:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
detail:SetBackdropColor(0.03, 0.03, 0.05, 0.96)
detail:SetBackdropBorderColor(0.3, 0.6, 0.9, 0.9)
detail:SetFrameStrata("DIALOG")
detail:SetMovable(true); detail:EnableMouse(true); detail:RegisterForDrag("LeftButton")
detail:SetScript("OnDragStart", detail.StartMoving); detail:SetScript("OnDragStop", detail.StopMovingOrSizing)
detail:Hide()
tinsert(UISpecialFrames, "CompletionRouteStepDetail")

local dTitle = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
dTitle:SetPoint("TOPLEFT", 12, -10); dTitle:SetPoint("RIGHT", -30, 0)
dTitle:SetJustifyH("LEFT"); dTitle:SetWordWrap(true)
local dClose = CreateFrame("Button", nil, detail, "UIPanelCloseButton")
dClose:SetPoint("TOPRIGHT", -2, -2)
local dBody = detail:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
dBody:SetPoint("TOPLEFT", dTitle, "BOTTOMLEFT", 0, -8); dBody:SetPoint("RIGHT", -12, 0)
dBody:SetJustifyH("LEFT"); dBody:SetWordWrap(true)

local dDone = smallButton("Complete", 76, "Mark this step done", function()
    if detail.step then P.MarkDone(detail.step, true) detail:Hide() end
end, detail)
dDone:SetPoint("BOTTOMLEFT", 12, 10)
local dSkip = smallButton("Skip", 50, "Skip this step", function()
    if detail.step then P.Skip(detail.step) detail:Hide() end
end, detail)
dSkip:SetPoint("LEFT", dDone, "RIGHT", 4, 0)
local dTrack = smallButton("Show on map", 96, "Open the world map at this step", function()
    local s2 = detail.step
    if s2 and s2.zone and OpenWorldMap then pcall(OpenWorldMap, s2.zone)
    elseif s2 and s2.zone and WorldMapFrame then pcall(function() WorldMapFrame:SetMapID(s2.zone) ShowUIPanel(WorldMapFrame) end) end
end, detail)
dTrack:SetPoint("LEFT", dSkip, "RIGHT", 4, 0)

function GF.ShowDetail(step)
    if not step then return end
    detail.step = step
    dTitle:SetText(("|cffffd200%s|r: %s"):format(G.ACTION_LABEL[step.action] or step.action, step.title))
    local lines = {}
    if step.note and step.note ~= "" then lines[#lines + 1] = step.note end
    if step.target then lines[#lines + 1] = "|cff7ddf8fWho / what:|r " .. tostring(step.target) end
    if step.qid then
        for _, q in ipairs(step.qid) do
            local title = U.QuestTitle and U.QuestTitle(q)
            lines[#lines + 1] = ("|cff7ddf8fQuest %d|r%s"):format(q, title and (" - " .. title) or "")
            if U.IsOnQuest(q) then
                local objs = C_QuestLog and C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(q)
                if objs and #objs > 0 then
                    for _, o in ipairs(objs) do
                        lines[#lines + 1] = ("   %s %s"):format(o.finished and "|cff00ff00[x]|r" or "|cffff9900[ ]|r", o.text or "?")
                    end
                else
                    lines[#lines + 1] = "   on this quest"
                end
            elseif U.IsQuestComplete(q) then lines[#lines + 1] = "   |cff00ff00already completed|r"
            else lines[#lines + 1] = "   |cff888888not picked up yet|r" end
        end
    end
    if step.item then lines[#lines + 1] = "|cff7ddf8fItem:|r " .. U.ItemName(step.item) end
    if step.loot then
        for _, l in ipairs(step.loot) do
            lines[#lines + 1] = ("|cff7ddf8fNeeds:|r %s x%d (have %d)"):format(U.ItemName(l.id), l.qty, U.ItemCount(l.id))
        end
    end
    if step.zone then
        lines[#lines + 1] = ("|cff7ddf8fWhere:|r %s%s"):format(U.MapName(step.zone),
            step.coords and (" " .. string.format("%.1f, %.1f", step.coords[1].x * 100, step.coords[1].y * 100)) or " (no exact spot in this guide)")
    end
    local secs = NS.Router and NS.Router.TravelSecondsFromPlayer(step)
    if secs then
        local path = NS.Router.CurrentPath and select(1, NS.Router.CurrentPath())
        lines[#lines + 1] = ("|cff7ddf8fTravel:|r ~%s%s"):format(U.FmtTime(secs),
            (step == P.current and path) and ("\n   " .. NS.TravelGraph.Describe(path)) or "")
    end
    dBody:SetText(table.concat(lines, "\n"))
    detail:Show()
end

function GF.ApplySettings()
    local p = NS.db.profile.frame
    f:ClearAllPoints(); f:SetPoint(p.point or "CENTER", UIParent, p.point or "CENTER", p.x or 0, p.y or 0)
    f:SetScale(p.scale or 1); f:SetAlpha(p.alpha or 1)
    f:SetSize(400, 170)   -- one-step window: fixed height (old profiles carry the multi-row height)
end
function GF.Toggle() if f:IsShown() then f:Hide() else f:Show() GF.Update() end end
NS:On("PLAYER_READY", GF.ApplySettings)
