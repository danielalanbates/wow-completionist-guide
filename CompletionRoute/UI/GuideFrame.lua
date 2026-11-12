-- CompletionRoute :: UI/GuideFrame.lua
-- The guide viewer window: current + upcoming steps (in optimized order), route summary, controls.
local ADDON, NS = ...
local U, G, P = NS.Util, NS.Guide, NS.Progress
local GF = {}
NS.GuideFrame = GF


local f = CreateFrame("Frame", "CompletionRouteFrame", UIParent, "BackdropTemplate")
GF.frame = f
-- The window, top to bottom (one hierarchy, nothing shares a line with anything it could run into):
--   title line   route name (cut with "..." when long) . "step N of M" (never cut) . Contribute, Routes, "...", x
--   card         icon + "<Action>  <title>" (up to L.titleLines lines), the note (up to L.noteLines), one distance line
--   travel line  how to get there (up to L.pathLines lines)
-- with the back and forward arrows left and right of the card.  Everything used rarely lives behind the "..." button.
-- GF.L holds the layout numbers; tools/audit_step_text.lua reads this table from the source to size the texts and
-- tools/test_step_window.lua checks the rules FitHeight follows, so keep it one literal table of numbers.
GF.BASE_W, GF.BASE_H = 460, 120      -- width; the least height (FitHeight grows it to fit the text)
GF.L = { side = 34, top = 30, pad = 6, icon = 30, gap = 8, titleLines = 3, noteLines = 8, pathLines = 3, pathInset = 34, nameMin = 48 }
local L = GF.L
-- the title line's gaps, right to left (fitHeader adds the same numbers up to know how much room the texts have)
local HG = { edge = 6, gap = 2, box = 4, word = 1, text = 8, left = 10 }
f:SetSize(GF.BASE_W, GF.BASE_H)
f:SetPoint("CENTER")
f:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
f:SetBackdropColor(0.03, 0.03, 0.05, 0.93)
f:SetBackdropBorderColor(0.3, 0.6, 0.9, 0.9)
f:SetMovable(true); f:EnableMouse(true); f:SetClampedToScreen(true); f:SetResizable(true)
if f.SetResizeBounds then f:SetResizeBounds(240, 100) elseif f.SetMinResize then f:SetMinResize(240, 100) end
f:RegisterForDrag("LeftButton")
local function dragStart() if not NS.db.profile.frame.lock then f:StartMoving() end end
local function dragStop()
    f:StopMovingOrSizing()
    if not (NS.GuideFrame.AnchorTopLeft and NS.GuideFrame.AnchorTopLeft()) then
        local p, _, _, x, y = f:GetPoint()
        NS.db.profile.frame.point, NS.db.profile.frame.x, NS.db.profile.frame.y = p, x, y
    end
end
f:SetScript("OnDragStart", dragStart)
f:SetScript("OnDragStop", dragStop)
f:SetFrameStrata("MEDIUM")

-- ---------------------------------------------------------------------------
-- Button labels in the addon's own fonts (Core/Util.lua U.Font), so the Options "Text size" slider covers them too.
-- UIPanelButtonTemplate draws its label in the client's GameFontNormal / GameFontHighlight / GameFontDisable.  The
-- addon has no grey font object of its own, so the disabled label is a copy of the Title font in grey, copied again
-- whenever the text size changes (GF.SyncFonts: at PLAYER_READY and from the Options slider).  The routes list, the
-- options page and the bug-report window use the same two functions.
-- ---------------------------------------------------------------------------
local disabledFont      -- nil = not made yet, false = cannot be made here (the offline harnesses)
local function fontObj(kind) local n = U.Font(kind) return _G[n] or n end
function GF.SyncFonts()
    if disabledFont == nil then
        local ok, fo = pcall(function() return CreateFont("CompletionRouteFontDisabled") end)
        disabledFont = (ok and fo) or false
    end
    if not disabledFont then return end
    local base = _G[U.Font("Title")]
    if base then pcall(disabledFont.CopyFontObject, disabledFont, base) end
    pcall(disabledFont.SetTextColor, disabledFont, 0.5, 0.5, 0.5)
end
function GF.ButtonFonts(b)
    if not b then return end
    if disabledFont == nil then GF.SyncFonts() end
    if b.SetNormalFontObject then pcall(b.SetNormalFontObject, b, fontObj("Title")) end
    if b.SetHighlightFontObject then pcall(b.SetHighlightFontObject, b, fontObj("Body")) end
    if b.SetDisabledFontObject then pcall(b.SetDisabledFontObject, b, disabledFont or fontObj("Title")) end
end
-- the width a button's label needs (nil where the client cannot say)
function GF.LabelWidth(b)
    local w = b and b.GetTextWidth and b:GetTextWidth()
    return (type(w) == "number" and w > 0) and w or nil
end
-- as wide as its label plus `pad`, never narrower than the width it was made with (b.minW); returns the width
function GF.FitButton(b, pad)
    if not b then return 0 end
    local w = type(b.minW) == "number" and b.minW or 0
    local tw = GF.LabelWidth(b)
    if tw then w = math.max(w, math.ceil(tw + (pad or 10))) end
    if w > 0 and (not b.GetWidth or b:GetWidth() ~= w) then b:SetWidth(w) end     -- the title line refits every second
    return w
end

local function smallButton(text, w, tip, onClick, parent)
    local b = CreateFrame("Button", nil, parent or f, "UIPanelButtonTemplate")
    b:SetSize(w, 18); b:SetText(text)
    b.minW = w
    GF.ButtonFonts(b)
    b:SetScript("OnClick", onClick)
    b:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_TOP") GameTooltip:SetText(tip, 1, 1, 1, 1, true) GameTooltip:Show() end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

-- title line, right to left: close, "..." (the rarely used things), Routes, the Contribute box and its word
-- closing prints where the way back is, once a session: the window has no other button once it is hidden, and the
-- owner does not type commands (UI/Options.lua puts "Show step window" and "Routes" on the addon's options page)
local bClose = smallButton("x", 20, "Hide this window (a left click on the minimap button, or Options > AddOns > CompletionRoute, shows it again)", function()
    f:Hide()
    if not GF.closeHintShown then
        GF.closeHintShown = true
        local mm = NS.db and NS.db.profile.minimapButton ~= false
        NS:Print("Step window hidden. To show it again: " .. (mm and "left-click the minimap button, or " or "")
            .. "Esc > Options > AddOns > CompletionRoute > Show step window (or type /cr). Picking a route shows it too.")
    end
end)
bClose:SetPoint("TOPRIGHT", -HG.edge, -6)
local bMore = smallButton("...", 24, "More: step order, options, report a bug, start this route over", function(self) GF.ToggleMore(self) end)
bMore:SetPoint("RIGHT", bClose, "LEFT", -HG.gap, 0)
local bMenu = smallButton("Routes", 52, "Choose a route", function() NS.GuideMenu.Toggle() end)
bMenu:SetPoint("RIGHT", bMore, "LEFT", -HG.gap, 0)
-- Contribute (Core/Contribute.lua): while ticked, the addon notes where steps are done to build the location database
local cbContrib = CreateFrame("CheckButton", "CompletionRouteContributeCheck", f, "UICheckButtonTemplate")
cbContrib:SetSize(20, 20); cbContrib:SetPoint("RIGHT", bMenu, "LEFT", -HG.box, 0)
-- the word is a button: a click opens the text to share (the owner does not type /cr contribute export)
local cbLabel = CreateFrame("Button", "CompletionRouteContributeLabel", f)
cbLabel:SetSize(62, 18); cbLabel:SetPoint("RIGHT", cbContrib, "LEFT", -HG.word, 0)
cbLabel.text = cbLabel:CreateFontString(nil, "OVERLAY", U.Font("Small"))
cbLabel.text:SetPoint("RIGHT", 0, 0); cbLabel.text:SetText("Contribute")
cbLabel.line = cbLabel:CreateTexture(nil, "HIGHLIGHT")
cbLabel.line:SetPoint("BOTTOMLEFT", 0, 1); cbLabel.line:SetPoint("BOTTOMRIGHT", 0, 1); cbLabel.line:SetHeight(1)
cbLabel.line:SetColorTexture(0.6, 0.85, 1, 0.9)
cbLabel:SetScript("OnClick", function() if NS.Contribute and NS.Contribute.ShowExport then NS.Contribute.ShowExport() end end)
cbLabel:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Contribute: share what you collected")
    GameTooltip:AddLine("Click to open the places this client has collected as a text you can copy and send to the open quest database.", 1, 1, 1, true)
    GameTooltip:AddLine("Tick the box on the right to collect.", 0.6, 0.85, 1, true)
    GameTooltip:Show()
end)
cbLabel:SetScript("OnLeave", function() GameTooltip:Hide() end)
cbContrib:SetScript("OnClick", function(self) NS.Contribute.SetEnabled(self:GetChecked() and true or false) end)
cbContrib:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Contribute locations")
    GameTooltip:AddLine("While this is ticked, the addon notes where you are standing when you accept or turn in a quest, when a quest objective ticks up, and when you click the forward arrow.", 1, 1, 1, true)
    GameTooltip:AddLine("It builds the most likely spot for every step, uses it for steps that have no location, and draws the areas on your map.", 1, 1, 1, true)
    GameTooltip:AddLine("Only map positions and quest ids are kept, on this computer. Click the word Contribute for a text you can share.", 0.6, 0.85, 1, true)
    GameTooltip:Show()
end)
cbContrib:SetScript("OnLeave", function() GameTooltip:Hide() end)
local function syncContrib() cbContrib:SetChecked(NS.Contribute and NS.Contribute.Enabled() or false) end
NS:On("PLAYER_READY", syncContrib)
NS:On("CONTRIBUTE_CHANGED", syncContrib)
GF.contribute, GF.contributeLabel, GF.more, GF.close, GF.routes = cbContrib, cbLabel, bMore, bClose, bMenu

-- "step N of M": its own string so a long route name can never push it off the line
local stepText = f:CreateFontString(nil, "OVERLAY", U.Font("Small"))
stepText:SetPoint("RIGHT", cbLabel, "LEFT", -HG.text, 0)
stepText:SetJustifyH("RIGHT"); stepText:SetWordWrap(false); stepText:SetTextColor(0.62, 0.62, 0.62)
-- route name: one line between the window's left edge and the step count, cut with "..." (a wrapped title ran over
-- whatever was under it); the whole name is in the tooltip of the title line
local titleText = f:CreateFontString(nil, "OVERLAY", U.Font("Title"))
titleText:SetPoint("LEFT", f, "TOPLEFT", HG.left, -15); titleText:SetPoint("RIGHT", stepText, "LEFT", -HG.text, 0)
titleText:SetJustifyH("LEFT"); titleText:SetWordWrap(false)
titleText:SetText("|cff7ddf8fCompletion|r|cffffd200Route|r")
GF.titleText, GF.stepText = titleText, stepText
local titleHit = CreateFrame("Frame", nil, f)
titleHit:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -5); titleHit:SetPoint("RIGHT", stepText, "RIGHT", 0, 0); titleHit:SetHeight(20)
titleHit:EnableMouse(true); titleHit:RegisterForDrag("LeftButton")
titleHit:SetScript("OnDragStart", dragStart)
titleHit:SetScript("OnDragStop", dragStop)
titleHit:SetScript("OnEnter", function(self)
    if not P.guide then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(P.guide.name or P.guide.id, 0.24, 0.78, 1, 1, true)
    if GF.stepLine and GF.stepLine ~= "" then GameTooltip:AddLine(GF.stepLine, 1, 1, 1, true) end
    GameTooltip:AddLine("Drag to move the window.", 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
end)
titleHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

local pathText = f:CreateFontString(nil, "OVERLAY", U.Font("Small"))
pathText:SetPoint("BOTTOMLEFT", 10, 8); pathText:SetWidth(GF.BASE_W - L.pathInset)
pathText:SetJustifyH("LEFT"); pathText:SetTextColor(0.6, 0.85, 1)
pathText:SetWordWrap(true); if pathText.SetMaxLines then pathText:SetMaxLines(L.pathLines) end
GF.pathText = pathText

-- Keep the window hung from its top-left corner: it then grows down and to the right, both when the grip scales it
-- and when its height follows the text (fitHeight below).  Anchored by its centre (the old default) it grew in every
-- direction at once, which read as "bigger the opposite way from the drag".
local function anchorTopLeft()
    local l, t = f.GetLeft and f:GetLeft(), f.GetTop and f:GetTop()
    local ph = UIParent and UIParent.GetHeight and UIParent:GetHeight()
    local sc = (f.GetScale and f:GetScale()) or 1
    if not (l and t and ph and sc and sc > 0) then return false end
    local x, y = l, t - ph / sc
    f:ClearAllPoints(); f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", x, y)
    local p = NS.db and NS.db.profile.frame
    if p then p.point, p.x, p.y = "TOPLEFT", x, y end
    return true
end
GF.AnchorTopLeft = anchorTopLeft

-- The window's scale: the grip below and the Options slider ("Step window scale") share the limits and the rule that
-- the top-left corner stays where it is on screen.  hangAt puts the corner at (left, top), given in UIParent units.
GF.SCALE_MIN, GF.SCALE_MAX = 0.6, 2.5
local function clampScale(s) return math.max(GF.SCALE_MIN, math.min(GF.SCALE_MAX, tonumber(s) or 1)) end
local function hangAt(left, top, s)
    f:SetScale(s)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", left / s, (top - UIParent:GetHeight()) / s)
end
-- Options slider: a new scale, the corner kept.  Nothing happens when the scale is already this one (the slider
-- reports its value when the options page opens).  Returns true when it changed the window.
function GF.SetScale(s)
    s = clampScale(s)
    local cur = (f.GetScale and f:GetScale()) or 1
    if math.abs(cur - s) < 0.001 then return false end
    local p = NS.db.profile.frame
    local l, t = f.GetLeft and f:GetLeft(), f.GetTop and f:GetTop()
    local ph = UIParent.GetHeight and UIParent:GetHeight()
    if type(l) == "number" and type(t) == "number" then
        hangAt(l * cur, t * cur, s)
    elseif p.point == "TOPLEFT" and type(p.x) == "number" and type(p.y) == "number" and type(ph) == "number" then
        -- not laid out (hidden since login): the saved corner, which is in the old scale's units
        hangAt(p.x * cur, ph + p.y * cur, s)
        p.x, p.y = p.x * cur / s, p.y * cur / s
    else
        f:SetScale(s)
    end
    p.scale = s
    anchorTopLeft()
    return true
end

-- resize grip (bottom-right): drag away from the window to make it bigger, toward it to make it smaller.  The whole
-- window scales; its top-left corner stays where it is and the grip follows the mouse.
local grip = CreateFrame("Button", nil, f)
grip:SetSize(20, 20); grip:SetPoint("BOTTOMRIGHT", -2, 2)
grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
grip:SetScript("OnMouseDown", function()
    local us = (UIParent.GetEffectiveScale and UIParent:GetEffectiveScale()) or 1
    local cx, cy = GetCursorPosition()
    local s0 = f:GetScale()
    local l, t = f:GetLeft(), f:GetTop()
    if not (cx and cy and l and t and us > 0) then return end
    grip.drag = { cx = cx / us, cy = cy / us, s0 = s0, left = l * s0, top = t * s0, w = f:GetWidth() * s0, h = f:GetHeight() * s0 }
end)
local function gripApply()
    local d = grip.drag
    if not d then return end
    local us = (UIParent.GetEffectiveScale and UIParent:GetEffectiveScale()) or 1
    local cx, cy = GetCursorPosition()
    if not (cx and cy) then return end
    local dx, dy = cx / us - d.cx, d.cy - cy / us            -- right and down are positive
    local grow = (dx / d.w + dy / d.h) / 2                   -- the corner follows the mouse along the diagonal
    hangAt(d.left, d.top, clampScale(d.s0 * (1 + grow)))
end
grip:SetScript("OnMouseUp", function()
    if not grip.drag then return end
    gripApply()
    grip.drag = nil
    local p = NS.db.profile.frame
    p.scale = f:GetScale()
    anchorTopLeft()
end)
grip:SetScript("OnUpdate", function() if grip.drag then gripApply() end end)

-- shown instead of an empty list, so finishing the last step never looks like the addon died; a route with marks
-- gets a Start over button under the text (GF.StartOver)
local empty = f:CreateFontString(nil, "OVERLAY", U.Font("Body"))
empty:SetPoint("TOPLEFT", L.side + 2, -(L.top + 6)); empty:SetWidth(GF.BASE_W - 2 * (L.side + 2))
empty:SetJustifyH("LEFT"); empty:SetWordWrap(true); empty:Hide()
local bRestart = smallButton("Start over", 96, "Clear this route's finished steps for this character and begin again at its first step", function() GF.StartOver() end)
bRestart:SetHeight(22)
bRestart:SetPoint("TOPLEFT", empty, "BOTTOMLEFT", 0, -8)
bRestart:Hide()
GF.empty, GF.restart = empty, bRestart

-- ---------------------------------------------------------------------------
-- ONE step at a time. Nothing to tick: steps complete themselves from quest log,
-- inventory, position and taxi/bind events (Progress.CheckStep). The arrows move by hand.
-- ---------------------------------------------------------------------------
local card = CreateFrame("Button", nil, f)
card:SetPoint("TOPLEFT", L.side, -L.top); card:SetPoint("BOTTOMRIGHT", -L.side, 26)
card.bg = card:CreateTexture(nil, "BACKGROUND"); card.bg:SetAllPoints(); card.bg:SetColorTexture(0.3, 0.6, 0.9, 0.10)
card.icon = card:CreateTexture(nil, "ARTWORK"); card.icon:SetSize(L.icon, L.icon); card.icon:SetPoint("TOPLEFT", L.pad, -L.pad)
card.title = card:CreateFontString(nil, "OVERLAY", U.Font("Large"))
card.title:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", L.gap, -2)
card.title:SetJustifyH("LEFT"); card.title:SetWordWrap(true); card.title:SetMaxLines(L.titleLines)
card.note = card:CreateFontString(nil, "OVERLAY", U.Font("Body"))
card.note:SetPoint("TOPLEFT", card.icon, "BOTTOMLEFT", 0, -L.gap)
card.note:SetJustifyH("LEFT"); card.note:SetWordWrap(true); card.note:SetMaxLines(L.noteLines); card.note:SetTextColor(0.85, 0.85, 0.85)
card.where = card:CreateFontString(nil, "OVERLAY", U.Font("Small"))
card.where:SetPoint("BOTTOMLEFT", L.pad, 6)
card.where:SetJustifyH("LEFT"); card.where:SetWordWrap(false); card.where:SetTextColor(0.6, 0.85, 1)
card:RegisterForClicks("LeftButtonUp", "RightButtonUp")
card:SetScript("OnClick", function(self, button)
    if not self.step then return end
    if button == "RightButton" then GF.ShowStepMenu(self.step, self) return end
    GF.ShowDetail(self.step)
end)
card:SetScript("OnEnter", function(self)
    if not self.step then return end
    local s = self.step
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText((G.ACTION_LABEL[s.action] or s.action) .. ": " .. G.StepTitle(s), 1, 0.82, 0, 1, true)
    if s.note then GameTooltip:AddLine(s.note, 1, 1, 1, true) end
    if s.qid then GameTooltip:AddLine("Quest ID: " .. table.concat(s.qid, ", "), 0.6, 0.6, 0.6) end
    if s.zone then GameTooltip:AddLine("Zone: " .. U.MapName(s.zone) .. (s.coords and (" " .. string.format("%.1f, %.1f", s.coords[1].x * 100, s.coords[1].y * 100)) or ""), 0.6, 0.6, 0.6) end
    if s.item then GameTooltip:AddLine("Uses item: " .. U.ItemName(s.item), 0.6, 1, 0.6) end
    GameTooltip:AddLine("|cff888888Click for details, right-click to skip or to start the route over. Steps complete themselves; use the arrows to move by hand.|r", 1, 1, 1, true)
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
local bBack = arrow("L", "Back one step (reopens the previous step and keeps it open)", function() P.Undo() end)
bBack:SetPoint("RIGHT", card, "LEFT", -4, 0)     -- beside the card, so neither arrow can reach the title or travel line
local bFwd = arrow("R", "Forward one step (mark this one done)", function() P.Forward() end)
bFwd:SetPoint("LEFT", card, "RIGHT", 4, 0)
GF.card, GF.back, GF.forward = card, bBack, bFwd

local function stepColor(step)
    local a = step.action
    if a == "A" or a == "a" then return 1, 0.82, 0 end
    if a == "C" or a == "K" then return 1, 1, 1 end
    if a == "T" or a == "t" then return 0.4, 1, 0.4 end
    if a == "R" or a == "F" or a == "b" or a == "H" or a == "h" then return 0.5, 0.8, 1 end
    return 1, 1, 1
end

-- title line: the route's name on the left, where you are in it on the right (GF.stepLine is the plain text, for the tooltip)
local function setTitle(name, stepLine, extra)
    titleText:SetText(name)
    GF.stepLine, GF.stepExtra = stepLine or "", extra or ""
    stepText:SetText(GF.stepLine .. GF.stepExtra)      -- fitHeader (every FitHeight) decides what of it has room
end
local function showEmpty(text, restart)
    card:Hide()
    -- the arrows hang from the card, shown or not: give it back its plain place (a tall travel line had moved its foot)
    card:ClearAllPoints()
    card:SetPoint("TOPLEFT", L.side, -L.top); card:SetPoint("BOTTOMRIGHT", -L.side, 26)
    empty:SetText(text)
    empty:Show()
    GF.restartShown = restart and true or false
    if GF.restartShown then GF.FitButton(bRestart) bRestart:Show() else bRestart:Hide() end
    pathText:SetText("")
    GF.FitHeight()
end

function GF.Update()
    if not P.guide then
        setTitle("|cff7ddf8fCompletion|r|cffffd200Route|r", "")
        showEmpty("No route loaded.\nClick |cffffd200Routes|r above to pick one.", false)
        bBack:Disable() bFwd:Disable()
        return
    end
    -- counts over the list on screen: a guide rebuilt without skipped quests (Core/Skip.lua) counts only what is left
    local done, total = P.VisibleDone(), #P.steps
    local s = P.current
    local pos = total
    if s then   -- position in the loaded list (access-chain steps carry negative indices and sit in front)
        for i, st in ipairs(P.steps) do if st == s then pos = i break end end
    end
    local name = ("|cff3ec6ff%s|r"):format(P.guide.name or P.guide.id)
    local worth = ""
    if P.guide.loop then
        -- a circuit has no end: show which lap you are on; what it has been worth goes on the card's distance line
        local st = NS.Farm and NS.Farm.Stats(P.guide.id)
        worth = st and ("%s/hr"):format(U.FmtMoney(st.perHour)) or ""
        setTitle(name, ("lap %d, stop %d of %d"):format((P.Lap and P.Lap(P.guide.id) or 0) + 1, math.min(pos, total), total))
    else
        setTitle(name, ("%s %d of %d"):format((s and s.access) and "unlock step" or "step", math.min(pos, total), total),
            (NS.Replan and NS.Replan.running) and "  |cff6ac9ffre-planning...|r" or "")
    end
    local _, skippedSet = P.MarkSets()
    local marks = done > 0 or next(skippedSet) ~= nil
    bBack:SetEnabled(marks)
    bFwd:SetEnabled(s ~= nil)
    if not s then
        local applicable = #P.Pending(1)
        if done >= total and total > 0 then
            showEmpty(("|cff00ff00Route complete|r - all %d steps done.\n|cffffd200Start over|r runs it again from the first step; |cffffd200Routes|r has the next one (|cff7ddf8fFor level|r lists what fits you now)."):format(total), true)
        elseif applicable == 0 then
            showEmpty("No steps left in this route apply to you right now.\nThey may be for the other faction, another class, or a level you have passed.\n"
                .. (marks and "|cffffd200Start over|r runs it again from the first step; " or "") .. "|cffffd200Routes|r has others (|cff7ddf8fFor level|r lists what fits you now).", marks)
        else
            showEmpty("Nothing to show for this route right now.\nClick |cffffd200Routes|r to pick another.", marks)
        end
        return
    end
    empty:Hide()
    bRestart:Hide()
    GF.restartShown = false
    card.step = s
    card:Show()
    card.icon:SetTexture(G.ACTION_ICON[s.action] or "Interface\\Icons\\INV_Misc_QuestionMark")
    local label = (G.ACTION_LABEL[s.action] or s.action)
    local extra = ""
    if (s.action == "C" or s.action == "K") and s.qid and U.IsOnQuest(s.qid[1]) then
        local fu, req = U.QuestObjective(s.qid[1], tonumber(s.qo) or 1)
        if req and req > 0 then extra = (" |cffaaaaaa(%d/%d)|r"):format(fu, req) end
    end
    card.title:SetText(("|cffffd200%s|r  %s%s"):format(label, G.StepTitle(s), extra))
    card.title:SetTextColor(stepColor(s))
    -- the card shows what to do; where a map point came from ("(location: ...)", "(zone only ...)") stays in the
    -- tooltip and the Details panel, which show the note whole (Core/Guide.lua G.CardNote)
    local note = G.CardNote(s)
    if s.optional then note = "|cff888888(optional)|r " .. note end
    card.note:SetText(note)
    -- one distance line: how far if we can measure it, and the zone; blank rather than a guess
    local where = ""
    if NS.Router then
        local _, _, _, pinst, pwx, pwy = U.PlayerPos()
        local tx, ty, ti = NS.Router.StepWorld(s)
        if tx and pwx then
            if ti == pinst then where = U.FmtDist(math.sqrt((tx - pwx) ^ 2 + (ty - pwy) ^ 2)) .. (s.zone and ("  -  " .. U.MapName(s.zone)) or "")
            elseif s.zone then where = U.MapName(s.zone) end
        elseif s.zone then where = U.MapName(s.zone) end
    end
    if worth ~= "" then where = (where ~= "" and (where .. "  -  ") or "") .. "|cffffd200" .. worth .. "|r" end
    card.where:SetText(where)
    local path = NS.Router and NS.Router.CurrentPath()
    pathText:SetText(path and NS.TravelGraph.Summary(path) or "")
    GF.FitHeight()
end

-- The window is as tall as its text: the step's title (up to L.titleLines lines), its note (up to L.noteLines), the
-- distance line and the travel line.  A fixed 170 px cut long notes off once the text grew (beta feedback, 2026-11-11).
-- Rules (tools/test_step_window.lua holds the code to them):
--   1. every text gets an explicit width BEFORE its height is read: a string anchored by two points reports a
--      one-line height until the client has laid it out, and a height read too small is how the note ended up
--      printed over a wrapped title;
--   2. no text gets a fixed height: heights are only ever read;
--   3. the note hangs under whichever is taller, the icon or the (possibly wrapped) title;
--   4. the card ends above the travel line, and the window is the sum of the three.
-- The whole window scales (the grip, Options), so one layout holds at every scale from 0.6 to 2.5.
local function sh(fs) local h = fs.GetStringHeight and fs:GetStringHeight() return (type(h) == "number" and h > 0) and h or 0 end
local function strW(fs) local w = fs.GetStringWidth and fs:GetStringWidth() return (type(w) == "number" and w > 0) and w or 0 end
local function fitHeader()
    -- the word Contribute grows with the text-size setting: keep its button as wide as the word, so the step count
    -- (anchored to it) moves left instead of being covered
    local w = strW(cbLabel.text)
    if w > 0 then cbLabel:SetWidth(w + 2) end
    -- the same for the three buttons: their labels follow the text size too (GF.ButtonFonts)
    GF.FitButton(bClose) GF.FitButton(bMore) GF.FitButton(bMenu)
    -- What is left of the line for "step N of M" and the route name.  The name is anchored between the window's left
    -- edge and the step count; with the largest text size and "re-planning..." showing, that room came out NEGATIVE,
    -- and a string with its right anchor left of its left one is drawn over the step count.  So: "re-planning..."
    -- goes first, then the name (it is whole in the tooltip of the line), and the step count is cut last.
    local W = f:GetWidth()
    if type(W) ~= "number" or W <= 0 then W = GF.BASE_W end
    local room = W - (HG.edge + bClose:GetWidth() + HG.gap + bMore:GetWidth() + HG.gap + bMenu:GetWidth() + HG.box + cbContrib:GetWidth()
        + HG.word + cbLabel:GetWidth() + HG.text) - HG.left
    local line, extra = GF.stepLine or "", GF.stepExtra or ""
    stepText:SetText(line .. extra)
    if extra ~= "" and room - strW(stepText) - HG.text < L.nameMin then stepText:SetText(line) end
    local stepW = strW(stepText)
    if stepW > room then stepText:SetWidth(room) GF.stepCut = true
    elseif GF.stepCut then stepText:SetWidth(0) GF.stepCut = nil end     -- 0 = as wide as its text again
    GF.nameRoom = room - math.min(stepW, room) - HG.text
    if GF.nameRoom >= L.nameMin then titleText:Show() else titleText:Hide() end
end
function GF.FitHeight()
    fitHeader()
    local W = f:GetWidth()
    if type(W) ~= "number" or W <= 0 then W = GF.BASE_W end
    if not card:IsShown() then
        empty:SetWidth(math.max(160, W - 2 * (L.side + 2)))
        local eh = (empty:IsShown() and sh(empty) or 0)
        f:SetHeight(math.max(GF.BASE_H, L.top + 6 + eh + (GF.restartShown and 30 or 0) + 14))
        return
    end
    local cardW = math.max(160, W - 2 * L.side)
    card.title:SetWidth(cardW - (2 * L.pad + L.icon + L.gap))       -- pad, icon, gap ... pad
    card.note:SetWidth(cardW - 2 * L.pad)
    card.where:SetWidth(cardW - 2 * L.pad)
    pathText:SetWidth(math.max(120, W - L.pathInset))
    local head = math.max(L.icon, sh(card.title) + 2)
    local note = sh(card.note)
    local where = sh(card.where)
    card.note:ClearAllPoints()
    card.note:SetPoint("TOPLEFT", card, "TOPLEFT", L.pad, -(L.pad + head + L.gap))
    local cardH = L.pad + head + (note > 0 and (L.gap + note) or 0) + (where > 0 and (10 + where) or 0) + 8
    local foot = math.max(26, sh(pathText) + 14)
    card:ClearAllPoints()
    card:SetPoint("TOPLEFT", L.side, -L.top); card:SetPoint("BOTTOMRIGHT", -L.side, foot)
    f:SetHeight(math.max(GF.BASE_H, L.top + cardH + foot))
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
detail:SetSize(360, 160)
detail:SetPoint("LEFT", f, "RIGHT", 8, 0)
detail:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
detail:SetBackdropColor(0.03, 0.03, 0.05, 0.96)
detail:SetBackdropBorderColor(0.3, 0.6, 0.9, 0.9)
detail:SetFrameStrata("DIALOG")
detail:SetMovable(true); detail:EnableMouse(true); detail:RegisterForDrag("LeftButton")
detail:SetScript("OnDragStart", detail.StartMoving); detail:SetScript("OnDragStop", detail.StopMovingOrSizing)
detail:Hide()
tinsert(UISpecialFrames, "CompletionRouteStepDetail")

GF.DETAIL_W, GF.DETAIL_H = 360, 160      -- width; the least height (the panel grows to fit its text, like the window)
local dTitle = detail:CreateFontString(nil, "OVERLAY", U.Font("Large"))
dTitle:SetPoint("TOPLEFT", 12, -10); dTitle:SetWidth(GF.DETAIL_W - 42)
dTitle:SetJustifyH("LEFT"); dTitle:SetWordWrap(true)
local dClose = CreateFrame("Button", nil, detail, "UIPanelCloseButton")
dClose:SetPoint("TOPRIGHT", -2, -2)
local dBody = detail:CreateFontString(nil, "OVERLAY", U.Font("Body"))
dBody:SetPoint("TOPLEFT", dTitle, "BOTTOMLEFT", 0, -8); dBody:SetWidth(GF.DETAIL_W - 24)
dBody:SetJustifyH("LEFT"); dBody:SetWordWrap(true)
GF.detailTitle, GF.detailBody = dTitle, dBody

local dDone = smallButton("Complete", 76, "Mark this step done", function()
    if detail.step then P.MarkDone(detail.step, true) detail:Hide() end
end, detail)
dDone:SetPoint("BOTTOMLEFT", 12, 10)
-- Skip on an accept or turn-in of a quest that other quests need warns first (Core/Skip.lua SkipStep)
local dSkip = smallButton("Skip", 50, "Skip this step (on an accept: the whole quest, so its turn-in is not left behind)", function()
    if detail.step then local st = detail.step detail:Hide() NS.Skip.SkipStep(st) end
end, detail)
dSkip:SetPoint("LEFT", dDone, "RIGHT", 4, 0)
local dSkipQ = smallButton("Skip quest", 76, "Skip this whole quest in every guide (you are warned first if other quests need it). /cr unskip brings it back.", function()
    local st = detail.step
    if st and st.qid then detail:Hide() NS.Skip.SkipQuest(st.qid[1]) end
end, detail)
dSkipQ:SetPoint("LEFT", dSkip, "RIGHT", 4, 0)
local dTrack = smallButton("Show on map", 96, "Open the world map at this step", function()
    local s2 = detail.step
    if s2 and s2.zone and OpenWorldMap then pcall(OpenWorldMap, s2.zone)
    elseif s2 and s2.zone and WorldMapFrame then pcall(function() WorldMapFrame:SetMapID(s2.zone) ShowUIPanel(WorldMapFrame) end) end
end, detail)
dTrack:SetPoint("LEFT", dSkipQ, "RIGHT", 4, 0)
GF._detailButtons = { dDone, dSkip, dSkipQ, dTrack }      -- for tools/test_step_window.lua

function GF.ShowDetail(step)
    if not step then return end
    detail.step = step
    dSkipQ:SetEnabled(step.qid ~= nil)
    -- the button labels follow the text size: the panel is as wide as their row needs, and the texts take that width
    -- before their heights are read
    local row = 12 + GF.FitButton(dDone) + 4 + GF.FitButton(dSkip) + 4 + GF.FitButton(dSkipQ) + 4 + GF.FitButton(dTrack) + 12
    local W = math.max(GF.DETAIL_W, row)
    detail:SetWidth(W)
    dTitle:SetWidth(W - 42); dBody:SetWidth(W - 24)
    dTitle:SetText(("|cffffd200%s|r: %s"):format(G.ACTION_LABEL[step.action] or step.action, G.StepTitle(step)))
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
    -- as tall as its text (both strings have explicit widths): a fixed 260 let a long note run over the buttons
    local th, bh = dTitle.GetStringHeight and dTitle:GetStringHeight(), dBody.GetStringHeight and dBody:GetStringHeight()
    th = (type(th) == "number" and th > 0) and th or 18
    bh = (type(bh) == "number" and bh > 0) and bh or 0
    detail:SetHeight(math.max(GF.DETAIL_H, 10 + th + 8 + bh + 14 + 18 + 10))
    detail:Show()
end

-- ---------------------------------------------------------------------------
-- Menus.  Plain frames of buttons (the dropdown APIs differ between the five clients).
--   right-click on the step card: skip the step, skip its quest, details, start the route over
--   the "..." button of the title line: everything used rarely (step order, options, bug report, start over)
-- ---------------------------------------------------------------------------
local BACKDROP = { bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } }
local function popup(name, rows)
    local m = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    m:SetSize(170, 12 + rows * 20)
    m:SetBackdrop(BACKDROP)
    m:SetBackdropColor(0.03, 0.03, 0.05, 0.96)
    m:SetBackdropBorderColor(0.3, 0.6, 0.9, 0.9)
    m:SetFrameStrata("DIALOG")
    m:EnableMouse(true)
    m:SetClampedToScreen(true)      -- a step window at the bottom of the screen opened its menu below the screen edge
    m:Hide()
    tinsert(UISpecialFrames, name)
    m.rows, m.buttons = 0, {}
    -- fn gets the menu's step (nil for the "..." menu)
    function m.Add(text, tip, fn)
        local b = smallButton(text, 154, tip, function() local st = m.step m.open = false m:Hide() fn(st) end, m)
        b:SetPoint("TOP", m, "TOP", 0, -8 - m.rows * 20)
        m.rows = m.rows + 1
        m.buttons[m.rows] = b
        return b
    end
    -- every row as wide as the widest label needs (they grow with the text size), the menu 16 px wider
    function m.Fit()
        local w = 154
        for _, b in ipairs(m.buttons) do local tw = GF.LabelWidth(b) if tw then w = math.max(w, math.ceil(tw + 16)) end end
        for _, b in ipairs(m.buttons) do b:SetWidth(w) end
        m:SetWidth(w + 16)
    end
    return m
end

local menu = popup("CompletionRouteStepMenu", 5)
GF.stepMenu = menu
menu.skipStep = menu.Add("Skip this step", "Skip this step. On the accept of a quest you do not have, that skips the quest (its objectives and turn-in go too); you are warned first when other quests need it", function(st) if st then NS.Skip.SkipStep(st) end end)
menu.skipQuest = menu.Add("Skip this quest", "Drop the whole quest from every route; quests that need it are listed before anything changes", function(st)
    if st and st.qid then NS.Skip.SkipQuest(st.qid[1]) end
end)
menu.details = menu.Add("Details", "Everything known about this step", function(st) if st then GF.ShowDetail(st) end end)
menu.startOver = menu.Add("Start over", "Clear this route's finished steps for this character and begin again at its first step (asks first)", function() GF.StartOver() end)
menu.close = menu.Add("Cancel", "Close this menu", function() end)
function GF.ShowStepMenu(step, anchor)
    if not step then return end
    menu.step = step
    menu.skipQuest:SetEnabled(step.qid ~= nil)
    menu.Fit()
    menu:ClearAllPoints()
    menu:SetPoint("TOPLEFT", anchor or f, "BOTTOMLEFT", 0, -2)
    menu:Show()
end

local more = popup("CompletionRouteMoreMenu", 5)
GF.moreMenu = more
local function reorderText() return "Reorder steps: " .. ((NS.db and NS.db.profile.routing.reorder) and "ON" or "OFF") end
more.reorder = more.Add("Reorder steps", "The route optimizer reorders the next steps by travel time. Click to turn it on or off.", function()
    NS.db.profile.routing.reorder = not NS.db.profile.routing.reorder
    NS:Print("Step reordering " .. (NS.db.profile.routing.reorder and "ON" or "OFF"))
    P.Refresh()
end)
more.options = more.Add("Options", "Open the options", function() NS.Options.Open() end)
more.report = more.Add("Report a bug", "Save a bug report: route, step, position, travel route and recent log", function() NS.BugReport.FromButton() end)
more.startOver = more.Add("Start over", "Clear this route's finished steps for this character and begin again at its first step (asks first unless the route is finished)", function() GF.StartOver() end)
more.close = more.Add("Cancel", "Close this menu", function() end)
function GF.ToggleMore(anchor)
    if more.open then more.open = false more:Hide() return end
    more.reorder:SetText(reorderText())
    more.startOver:SetEnabled(P.guide ~= nil)
    more.Fit()
    more:ClearAllPoints()
    more:SetPoint("TOPRIGHT", anchor or bMore, "BOTTOMRIGHT", 0, -2)
    more.open = true
    more:Show()
end
more:SetScript("OnHide", function() more.open = false end)

-- ---------------------------------------------------------------------------
-- Start over: clear the loaded route's marks for this character and go back to its first step (Progress.StartOver,
-- the code behind /cr reset).  A finished route starts over at once; a route with steps left asks first.
-- ---------------------------------------------------------------------------
local confirm = CreateFrame("Frame", "CompletionRouteStartOver", UIParent, "BackdropTemplate")
GF.confirm = confirm
confirm:SetSize(320, 120)
confirm:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
confirm:SetBackdrop(BACKDROP)
confirm:SetBackdropColor(0.03, 0.03, 0.05, 0.97)
confirm:SetBackdropBorderColor(0.3, 0.6, 0.9, 0.9)
confirm:SetFrameStrata("DIALOG")
confirm:EnableMouse(true)
confirm:SetClampedToScreen(true)
confirm:Hide()
tinsert(UISpecialFrames, "CompletionRouteStartOver")
confirm.text = confirm:CreateFontString(nil, "OVERLAY", U.Font("Body"))
confirm.text:SetPoint("TOPLEFT", 14, -12); confirm.text:SetWidth(320 - 28)
confirm.text:SetJustifyH("LEFT"); confirm.text:SetWordWrap(true)
confirm.yes = smallButton("Start over", 100, "Clear the finished steps and go back to the first step", function()
    local id = confirm.guide
    confirm:Hide()
    if id and P.guide and P.guide.id == id then P.StartOver() end
end, confirm)
confirm.yes:SetHeight(22); confirm.yes:SetPoint("BOTTOMLEFT", 14, 12)
confirm.no = smallButton("Cancel", 80, "Keep the route as it is", function() confirm:Hide() end, confirm)
confirm.no:SetHeight(22); confirm.no:SetPoint("LEFT", confirm.yes, "RIGHT", 6, 0)
function GF.StartOver()
    if not P.guide then return end
    if not P.current then P.StartOver() return end      -- nothing left to do in it: no question to ask
    local done = P.VisibleDone()
    confirm.guide = P.guide.id
    confirm.text:SetText(("Start |cff3ec6ff%s|r over?\n%d finished step%s will be cleared for this character. Steps the game itself reports as done (quests, skills, items in your bags) tick again by themselves."):format(
        P.guide.name or P.guide.id, done, done == 1 and "" or "s"))
    local h = confirm.text.GetStringHeight and confirm.text:GetStringHeight()
    GF.FitButton(confirm.yes) GF.FitButton(confirm.no)
    confirm:SetHeight(12 + ((type(h) == "number" and h > 0) and h or 60) + 12 + 22 + 12)
    confirm:Show()
end

NS:On("REPLAN_STATE", function() GF.SafeUpdate() end)

-- at login: the saved place and scale (the Options slider changes the scale through GF.SetScale, which keeps the corner)
function GF.ApplySettings()
    local p = NS.db.profile.frame
    p.scale = clampScale(p.scale or 1)
    f:ClearAllPoints(); f:SetPoint(p.point or "CENTER", UIParent, p.point or "CENTER", p.x or 0, p.y or 0)
    f:SetScale(p.scale); f:SetAlpha(p.alpha or 1)
    f:SetSize(GF.BASE_W, GF.BASE_H)   -- one-step window: the height then follows the text (GF.FitHeight)
    anchorTopLeft()                   -- old profiles are anchored by their centre: re-hang from the top-left corner
end
function GF.Toggle() if f:IsShown() then f:Hide() else f:Show() GF.Update() end end
NS:On("PLAYER_READY", function() GF.SyncFonts() GF.ApplySettings() end)
