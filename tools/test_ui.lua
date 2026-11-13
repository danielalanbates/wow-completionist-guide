-- CompletionRoute :: tools/test_ui.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- Offline checks of the minimap button (UI/Minimap.lua), the options pages (UI/Options.lua: the addon's fonts, rows
-- placed from measured text, the step window scale slider), "/cr next" and "/cr suggest" (Core/Slash.lua) and the
-- profile defaults (Core/Init.lua).  Run from the repo root:  luajit -joff tools/test_ui.lua
--
-- WHAT THIS CAN AND CANNOT SHOW.  There is no client: nothing is drawn, no mouse moves, and the fonts are a model
-- (character count x point size, wrapped by tools/guide_walk.lua's text model).  What is checked is the code's
-- arithmetic and wiring on a widget mock: positions, which font object each text and button label uses, what is saved.
-- The minimap button's looks, the drag under a real mouse and the options page in the client's Settings frame are for
-- the owner's eyes in game.
package.path = "./?.lua;" .. package.path
local ADDON, NS = "CompletionRoute", {}
dofile("tools/stubs.lua")
local W = dofile("tools/guide_walk.lua")
PLAYER = { map = 1429, x = 0.487, y = 0.42 } PLAYER.wx, PLAYER.wy, PLAYER.inst = z2w(PLAYER.x, PLAYER.y, PLAYER.map)

local fails, checks = 0, 0
local function check(ok, what, detail)
    checks = checks + 1
    if not ok then fails = fails + 1 print("FAIL " .. what .. (detail and ("  [" .. tostring(detail) .. "]") or "")) end
end

-- ---------------------------------------------------------------------------
-- Font objects: the client's, and CreateFont for the addon's own (Core/Util.lua U.Font copies the client's)
-- ---------------------------------------------------------------------------
local Font = {}
Font.__index = Font
local function newFont(name, size, r, g, b)
    local fo = setmetatable({ name = name, file = "Fonts\\FRIZQT__.TTF", size = size or 12, flags = "", color = { r or 1, g or 1, b or 1 } }, Font)
    if name then _G[name] = fo end
    return fo
end
function Font:GetFont() return self.file, self.size, self.flags end
function Font:SetFont(file, size, flags) self.file, self.size, self.flags = file, size, flags end
function Font:CopyFontObject(o)
    if type(o) == "string" then o = _G[o] end
    self.file, self.size, self.flags, self.color = o.file, o.size, o.flags, { o.color[1], o.color[2], o.color[3] }
end
function Font:SetTextColor(r, g, b) self.color = { r, g, b } end
function CreateFont(name) return newFont(name) end
newFont("GameFontHighlightSmall", 10) newFont("GameFontHighlight", 12) newFont("GameFontNormal", 12, 1, 0.82, 0)
newFont("GameFontNormalLarge", 16, 1, 0.82, 0) newFont("GameFontDisable", 12, 0.5, 0.5, 0.5) newFont("ChatFontNormal", 14)
local function fontOf(f) if type(f) == "string" then return _G[f] end return f end
local function addonFont(f) local fo = fontOf(f) return fo ~= nil and type(fo.name) == "string" and fo.name:find("^CompletionRouteFont") ~= nil end

-- ---------------------------------------------------------------------------
-- Widget mock: anchors, sizes, text, fonts, scripts; strings measure themselves by the text model
-- ---------------------------------------------------------------------------
local made = {}          -- every widget, in the order it was made
local Widget = {}
Widget.__index = function(t, k)
    local v = rawget(Widget, k)
    if v ~= nil then return v end
    if type(k) ~= "string" or not k:match("^%u") then return nil end     -- data fields stay nil
    local f = function() end
    rawset(t, k, f)
    return f
end
local function new(kind, name, parent, font)
    local w = setmetatable({ kind = kind, name = name, parent = parent, font = font, points = {}, scripts = {}, shown = true, text = "" }, Widget)
    made[#made + 1] = w
    if name then _G[name] = w end
    return w
end
local function plain(t) return W.Plain(tostring(t or "")) end
local function pt(f) local fo = fontOf(f) return fo and fo.size or 12 end
function Widget:SetPoint(point, a, b, c, d)
    local rel, relPoint, x, y
    if type(a) == "table" then rel, relPoint, x, y = a, b, c, d
        if type(relPoint) ~= "string" then relPoint, x, y = point, b, c end
    else rel, relPoint, x, y = self.parent, point, a, b end
    self.points[#self.points + 1] = { point = point, rel = rel, relPoint = relPoint, x = x or 0, y = y or 0 }
end
function Widget:ClearAllPoints() self.points = {} end
function Widget:SetWidth(w) self.width = w end
function Widget:SetHeight(h) self.height = h end
function Widget:SetSize(w, h) self.width, self.height = w, h end
function Widget:GetWidth() return self.width end
function Widget:GetHeight() return self.height end
function Widget:SetScale(s) self.scale = s end
function Widget:GetScale() return self.scale or 1 end
function Widget:SetText(t) self.text = t ~= nil and tostring(t) or "" end
function Widget:GetText() return self.text end
function Widget:Show() self.shown = true end
function Widget:Hide() self.shown = false end
function Widget:IsShown() return self.shown end
function Widget:SetScript(k, fn) self.scripts[k] = fn end
function Widget:GetScript(k) return self.scripts[k] end
function Widget:HookScript(k, fn)
    local prev = self.scripts[k]
    self.scripts[k] = prev and function(...) prev(...) fn(...) end or fn
end
function Widget:SetWordWrap(v) self.wrap = v end
function Widget:SetChecked(v) self.checked = v and true or false end
function Widget:GetChecked() return self.checked end
function Widget:SetEnabled(v) self.enabled = v and true or false end
function Widget:SetFontObject(fo) self.font = fo end
function Widget:SetNormalFontObject(fo) self.normalFont = fo end
function Widget:SetHighlightFontObject(fo) self.highlightFont = fo end
function Widget:SetDisabledFontObject(fo) self.disabledFont = fo end
function Widget:CreateFontString(_, _, font) return new("FontString", nil, self, font) end
function Widget:CreateTexture() return new("Texture", nil, self) end
function Widget:SetTexture(t) self.texture = t end
function Widget:GetStringWidth() return #plain(self.text) * pt(self.font) * 0.52 end
function Widget:GetStringHeight()
    if self.text == "" then return 0 end
    local p, n = pt(self.font), 1
    if self.wrap ~= false and self.width and self.width > 0 then n = math.max(1, W.Lines(self.text, self.width, p)) end
    return n * p + (n - 1) * 2
end
function Widget:GetTextWidth() return #plain(self.text) * pt(self.normalFont or "GameFontNormal") * 0.52 end
-- sliders: the value is clamped to the range and snapped to the step, and a change fires OnValueChanged (as in the
-- client); a stricter snap than the client may do, so the options page is tested against the worst case
function Widget:SetMinMaxValues(lo, hi) self.min, self.max = lo, hi end
function Widget:GetMinMaxValues() return self.min, self.max end
function Widget:SetValueStep(s) self.step = s end
function Widget:SetValue(v)
    if self.min then v = math.max(self.min, math.min(self.max, v)) end
    if self.step and self.min then v = self.min + math.floor((v - self.min) / self.step + 0.5) * self.step end
    if v ~= self.value then
        self.value = v
        if self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, v) end
    end
end
function Widget:GetValue() return self.value end
-- where a frame hung from UIParent sits (TOPLEFT or CENTER anchors), in its own units, as the client answers
function Widget:GetLeft()
    local p, s = self.points[1], self:GetScale()
    if not p or p.rel ~= UIParent then return nil end
    if p.point == "TOPLEFT" and p.relPoint == "TOPLEFT" then return p.x end
    if p.point == "CENTER" and p.relPoint == "CENTER" then return UIParent.width / 2 / s + p.x - (self.width or 0) / 2 end
end
function Widget:GetTop()
    local p, s = self.points[1], self:GetScale()
    if not p or p.rel ~= UIParent then return nil end
    if p.point == "TOPLEFT" and p.relPoint == "TOPLEFT" then return UIParent.height / s + p.y end
    if p.point == "CENTER" and p.relPoint == "CENTER" then return UIParent.height / 2 / s + p.y + (self.height or 0) / 2 end
end
-- templates: the parts the addon's code reads
local CHECK_TEMPLATES = { InterfaceOptionsCheckButtonTemplate = true, SettingsCheckBoxTemplate = true, UICheckButtonTemplate = true }
CreateFrame = function(kind, name, parent, template)
    local w = new(kind or "Frame", name, parent)
    w.template = template
    if kind == "Slider" then
        w.Text, w.Low, w.High = new("FontString", nil, w, "GameFontHighlight"), new("FontString", nil, w, "GameFontHighlightSmall"), new("FontString", nil, w, "GameFontHighlightSmall")
        w.height = 17
    elseif kind == "CheckButton" and CHECK_TEMPLATES[template] then
        w.Text = new("FontString", nil, w, "GameFontHighlight")
    elseif template == "UIPanelButtonTemplate" then
        w.normalFont, w.highlightFont, w.disabledFont = "GameFontNormal", "GameFontHighlight", "GameFontDisable"
    end
    return w
end
UIParent = new("Frame", "UIParent")
UIParent.width, UIParent.height = 1600, 900
GameTooltip = new("GameTooltip", "GameTooltip")
GameTooltip.lines = {}
function GameTooltip:SetOwner() self.lines = {} end
function GameTooltip:SetText(t) self.lines = { t } end
function GameTooltip:AddLine(t) self.lines[#self.lines + 1] = t end
Minimap = new("Frame", "Minimap")
Minimap.width, Minimap.height = 140, 140
function Minimap:GetCenter() return 500, 400 end
local MM_SCALE = 1
function Minimap:GetEffectiveScale() return MM_SCALE end
local CURSOR = { 0, 0 }
function GetCursorPosition() return CURSOR[1], CURSOR[2] end
SlashCmdList = {}

-- ---------------------------------------------------------------------------
-- Load: the step window's parts, then the options page, the minimap button and the slash commands (TOC order)
-- ---------------------------------------------------------------------------
for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", "Core/Progress.lua" }) do
    assert(loadfile("CompletionRoute/" .. f))(ADDON, NS)
end
-- a profile saved by an older build: autoAdvance (read by nothing), no minimap angle
CompletionRouteDB, CompletionRouteCharDB = { profile = { autoAdvance = true, textSize = 2 } }, nil
for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", ADDON) end
local calls = { frame = 0, menu = 0 }
NS.Contribute = { Enabled = function() return false end, SetEnabled = function() end, ShowExport = function() end }
NS.BugReport = { FromButton = function() end }
NS.GuideMenu = { Toggle = function() calls.menu = calls.menu + 1 end, Show = function() end }
NS.Router = { StepWorld = function() return nil end, CurrentPath = function() return nil end, TravelSecondsFromPlayer = function() return nil end,
              OrderSteps = function(list) return list end, Invalidate = function() end }
NS.TravelGraph = { Summary = function() return "" end, Describe = function() return "" end, TaxiPolicy = function() return "known" end }
assert(loadfile("CompletionRoute/UI/GuideFrame.lua"))(ADDON, NS)
local GF, U = NS.GuideFrame, NS.Util
local realToggle = GF.Toggle
GF.Toggle = function() calls.frame = calls.frame + 1 end
local firstOptions = #made + 1
assert(loadfile("CompletionRoute/UI/Options.lua"))(ADDON, NS)
local lastOptions = #made
assert(loadfile("CompletionRoute/UI/Minimap.lua"))(ADDON, NS)
assert(loadfile("CompletionRoute/Core/Slash.lua"))(ADDON, NS)
local O, MB = NS.Options, NS.MinimapButton
-- what PLAYER_READY does for these parts (the whole event would start the rest of the addon)
U.ApplyTextSize() GF.SyncFonts() GF.ApplySettings()

-- ---------------------------------------------------------------------------
-- A. Profile defaults (Core/Init.lua)
-- ---------------------------------------------------------------------------
local prof = NS.db.profile
check(NS.defaults.profile.autoAdvance == nil, "autoAdvance is no longer a default")
check(prof.autoAdvance == nil, "an old profile's autoAdvance is dropped at load")
check(NS.defaults.profile.minimapButton == true and prof.minimapButton == true, "the minimap button is on by default")
check(NS.defaults.profile.minimapAngle == 200 and prof.minimapAngle == 200, "an old profile gets the default minimap angle")

-- ---------------------------------------------------------------------------
-- B. The minimap button (UI/Minimap.lua)
-- ---------------------------------------------------------------------------
local b = MB.button
check(b ~= nil and b.name == "CompletionRouteMinimapButton" and b.parent == Minimap, "made: a named button on the minimap")
check(b and b.width == MB.SIZE and b.height == MB.SIZE, "the size of the client's own minimap buttons")
local hasIcon = false
for _, w in ipairs(made) do if w.parent == b and w.kind == "Texture" and w.texture == "Interface\\AddOns\\CompletionRoute\\Textures\\arrow" then hasIcon = true end end
check(hasIcon, "its icon is the addon's arrow texture")
local onReady = false
for _, fn in ipairs(NS.callbacks.PLAYER_READY or {}) do if fn == MB.Apply then onReady = true end end
check(onReady, "it is placed and shown at PLAYER_READY")
check(not b:IsShown(), "hidden until the saved settings are read")
MB.Apply()
local function centre()
    local p = b.points[#b.points]
    return p and p.rel == Minimap and p.point == "CENTER" and p.relPoint == "CENTER" and p.x, p and p.y
end
local R = 70 + MB.OFFSET
local x, y = centre()
check(b:IsShown() and x and math.abs(x - math.cos(math.rad(200)) * R) < 1e-6 and math.abs(y - math.sin(math.rad(200)) * R) < 1e-6,
    "shown at the default angle on a circle of the minimap's radius", ("%s, %s"):format(tostring(x), tostring(y)))
for _, a in ipairs({ 0, 33, 90, 145, 180, 271, 359 }) do
    local ox, oy = MB.Offsets(a)
    check(math.abs(math.sqrt(ox * ox + oy * oy) - R) < 1e-6, "round minimap: on the circle at " .. a .. " degrees")
end
-- square minimaps (a UI addon answers GetMinimapShape): the button sits on the square's edge
GetMinimapShape = function() return "SQUARE" end
for _, a in ipairs({ 0, 30, 45, 100, 200, 315 }) do
    local ox, oy = MB.Offsets(a)
    check(math.abs(math.max(math.abs(ox), math.abs(oy)) - R) < 1e-6, "square minimap: on the square's edge at " .. a .. " degrees", ("%.2f, %.2f"):format(ox, oy))
end
local cx, cy = MB.Offsets(45)
check(math.abs(cx - R) < 1e-6 and math.abs(cy - R) < 1e-6, "square minimap: 45 degrees is the top-right corner")
GetMinimapShape = function() return "CORNER-TOPRIGHT" end
local rx, ry = MB.Offsets(45)
local sx, sy = MB.Offsets(225)
check(math.abs(math.sqrt(rx * rx + ry * ry) - R) < 1e-6 and math.abs(sx + R) < 1e-6 and math.abs(sy + R) < 1e-6,
    "a corner shape: round in its own quarter, square in the others")
check(MB.RoundQuarter("SIDE-LEFT", "TOP", "LEFT") and MB.RoundQuarter("SIDE-LEFT", "BOTTOM", "LEFT") and not MB.RoundQuarter("SIDE-LEFT", "TOP", "RIGHT"),
    "a side shape: the two quarters on that side are round")
check(MB.RoundQuarter("TRICORNER-TOPLEFT", "TOP", "RIGHT") and MB.RoundQuarter("TRICORNER-TOPLEFT", "BOTTOM", "LEFT") and not MB.RoundQuarter("TRICORNER-TOPLEFT", "BOTTOM", "RIGHT"),
    "a three-corner shape: all but the opposite quarter are round")
GetMinimapShape = function() error("a broken shape function") end
local ex, ey = MB.Offsets(90)
check(math.abs(ex) < 1e-6 and math.abs(ey - R) < 1e-6, "a shape function that fails counts as round")
GetMinimapShape = nil
-- clicks
b.scripts.OnClick(b, "LeftButton")
b.scripts.OnClick(b, "RightButton")
check(calls.frame == 1 and calls.menu == 1, "left click toggles the step window, right click the Routes window", calls.frame .. "/" .. calls.menu)
b.scripts.OnEnter(b)
local tip = table.concat(GameTooltip.lines, " | ")
check(tip:find("Completionist's Guide", 1, true) and tip:find("Left click: step window", 1, true) and tip:find("Right click: routes", 1, true) and tip:find("Drag to move", 1, true),
    "tooltip: name, left click, right click, drag", tip)
-- drag: the angle from the minimap's centre to the mouse is saved and the button follows
b.scripts.OnDragStart(b)
check(b.scripts.OnUpdate ~= nil and b.dragging, "dragging follows the mouse every frame")
CURSOR[1], CURSOR[2] = 500, 400 + 100       -- straight above the centre
b.scripts.OnUpdate(b)
x, y = centre()
check(prof.minimapAngle == 90 and math.abs(x) < 1e-6 and math.abs(y - R) < 1e-6, "dragged above the minimap: angle 90 saved, button on top", prof.minimapAngle)
CURSOR[1], CURSOR[2] = 500 - 30, 400 - 30
b.scripts.OnDragStop(b)
x, y = centre()
check(prof.minimapAngle == 225 and b.scripts.OnUpdate == nil and not b.dragging, "let go below-left: angle 225 saved, following stops", prof.minimapAngle)
check(math.abs(x + R * math.sqrt(0.5)) < 1e-6 and math.abs(y + R * math.sqrt(0.5)) < 1e-6, "and the button sits there")
MM_SCALE = 2                                 -- the cursor is in screen pixels: divided by the minimap's effective scale
CURSOR[1], CURSOR[2] = 1000, 600             -- (500, 300) in the minimap's units: straight below the centre
check(math.abs(MB.CursorAngle() - 270) < 1e-6, "the cursor angle allows for the minimap's scale", MB.CursorAngle())
MM_SCALE = 1
MB.Apply()
x, y = centre()
check(math.abs(x + R * math.sqrt(0.5)) < 1e-6, "the saved angle is used again on the next login (Apply)")
-- hidden by the option: the Options check box
local mmBox = O.minimap
check(mmBox and mmBox.Text and mmBox.Text.text == "Minimap button", "the options page has a Minimap button check box", mmBox and mmBox.Text and mmBox.Text.text)
mmBox.scripts.OnShow(mmBox)
check(mmBox.checked == true, "it shows the setting (on)")
mmBox.checked = false
mmBox.scripts.OnClick(mmBox)
check(prof.minimapButton == false and not b:IsShown(), "unticked: the setting is saved and the button hidden")
MB.Apply()
check(not b:IsShown(), "and it stays hidden (next login)")
mmBox.checked = true
mmBox.scripts.OnClick(mmBox)
check(prof.minimapButton == true and b:IsShown(), "ticked again: shown")

-- ---------------------------------------------------------------------------
-- C. The options pages: the addon's fonts everywhere, rows placed from measured text
-- ---------------------------------------------------------------------------
local fsCount, fsAddon, buttons = 0, 0, {}
for i = firstOptions, lastOptions do
    local w = made[i]
    if w.kind == "FontString" then
        fsCount = fsCount + 1
        if addonFont(w.font) then fsAddon = fsAddon + 1 else print("     not the addon's font: " .. tostring(w.text):sub(1, 50) .. " (" .. tostring(fontOf(w.font) and fontOf(w.font).name or w.font) .. ")") end
    elseif w.template == "UIPanelButtonTemplate" then buttons[#buttons + 1] = w end
end
check(fsCount > 40 and fsAddon == fsCount, ("every text on the options pages uses the addon's fonts (%d of %d)"):format(fsAddon, fsCount))
check(#buttons == 3, "three buttons on the options pages (Show step window, Routes, the pause key)", #buttons)
for _, bt in ipairs(buttons) do
    check(fontOf(bt.normalFont) == _G.CompletionRouteFontTitle and fontOf(bt.highlightFont) == _G.CompletionRouteFontBody and fontOf(bt.disabledFont) == _G.CompletionRouteFontDisabled,
        "button '" .. bt.text .. "': its label is in the addon's fonts (normal, highlight, disabled)")
end
local dis = _G.CompletionRouteFontDisabled
check(dis and dis.size == _G.CompletionRouteFontTitle.size and dis.color[1] == 0.5 and dis.color[3] == 0.5, "the disabled label is the Title font in grey")
-- every label and tooltip on the pages: routes, not guides (the product name stays)
local texts = {}
for i = firstOptions, lastOptions do
    local w = made[i]
    if w.text ~= "" then texts[#texts + 1] = w.text end
    if w.tooltipText then texts[#texts + 1] = w.tooltipText end
end
local guideWord = nil
for _, s in ipairs(texts) do
    local rest = s:gsub("Completionist's Guide", "")
    if rest:lower():find("guide") then guideWord = s break end
end
check(guideWord == nil, "no label or tooltip on the options pages calls a route a guide", guideWord)
local function hasText(s) for _, t in ipairs(texts) do if t:find(s, 1, true) then return true end end return false end
for _, s in ipairs({ "Lock step window", "fastest order for quest routes", "Auto accept the route's quests", "Auto turn in the route's quests",
                     "Character / Server / Game type / Account buttons at the top of the Routes window", "/cr routes -> Recommended" }) do
    check(hasText(s), "options text: " .. s)
end
check(not hasText("up/down scope selector") and not hasText("For level N"), "the old scope selector and For level N wording are gone")

-- rows: no two overlap, at the default text size and at the largest
local function bandsOK(label)
    local ok, why = true, nil
    for _, pg in ipairs(O._pages) do
        local prevBottom
        for i, r in ipairs(pg.rows) do
            local p = r.f.points[#r.f.points]
            local top, bottom
            if r.kind == "check" then
                local ch = r.f.height or 26
                local lh = r.label:GetStringHeight()
                local mid = p.y - ch / 2
                top, bottom = math.max(p.y, mid + lh / 2), math.min(p.y - ch, mid - lh / 2)
                if r.label.width ~= 540 then ok, why = false, "label without its wrap width: " .. r.label.text end
            elseif r.kind == "slider" then
                top, bottom = p.y + r.f.Text:GetStringHeight(), p.y - r.f.height + 3 - r.f.Low:GetStringHeight()
            else
                local lp = r.label.points[#r.label.points]
                top, bottom = math.max(p.y, lp.y), math.min(p.y - 22, lp.y - r.label:GetStringHeight())
                local lx = lp.x + r.label:GetStringWidth()
                if p.x < lx + 8 then ok, why = false, "the pause key's choice overlaps its label" end
            end
            if prevBottom and top > prevBottom + 0.01 then ok, why = false, ("row %d runs into the row above (%.1f > %.1f)"):format(i, top, prevBottom) end
            prevBottom = bottom
        end
    end
    check(ok, label .. ": rows do not overlap", why)
end
O.Layout()
bandsOK("text size 2")
local contentH = O._content.height
local scrollTop = O._scroll.points[1]
check(scrollTop and scrollTop.rel == O._description and scrollTop.point == "TOPLEFT" and scrollTop.relPoint == "BOTTOMLEFT", "the scroll area hangs under the description, which grows with the text")
-- the Text size slider: fonts grow at once, the step window's disabled label with them, and the rows are placed again
local ts = O.textSize
ts.scripts.OnShow(ts)
check(prof.textSize == 2 and ts.Text.text == "Text size: extra points: 2", "the text size slider shows the setting without changing it")
ts.scripts.OnValueChanged(ts, 6)
check(prof.textSize == 6 and _G.CompletionRouteFontSmall.size == 16 and _G.CompletionRouteFontBody.size == 15 and _G.CompletionRouteFontTitle.size == 15,
    "text size 6: small text +6, the rest +3", _G.CompletionRouteFontSmall.size)
check(dis.size == 15, "the disabled button label follows (GF.SyncFonts)", dis.size)
bandsOK("text size 6")
check(O._content.height > contentH, ("the page grew with its text (%d -> %d px)"):format(contentH, O._content.height))
for _, bt in ipairs(buttons) do
    check(bt.width >= bt:GetTextWidth() + 10 - 1e-6 and bt.width >= bt.minW, ("button '%s' is as wide as its label (%d >= %.1f)"):format(bt.text, bt.width, bt:GetTextWidth() + 10))
end
ts.scripts.OnValueChanged(ts, 2)
check(_G.CompletionRouteFontSmall.size == 12, "back to the default size")

-- ---------------------------------------------------------------------------
-- D. Step window scale: the slider matches the grip, keeps the corner, and does nothing when nothing changed
-- ---------------------------------------------------------------------------
local sc = O.frameScale
local f = GF.frame
check(sc.min == math.floor(GF.SCALE_MIN * 100 + 0.5) and sc.max == math.floor(GF.SCALE_MAX * 100 + 0.5) and sc.min == 100 and sc.max == 250,
    "the scale slider's range is the grip's (100-250)", tostring(sc.min) .. "-" .. tostring(sc.max))
local function corner() return f:GetLeft() * f:GetScale(), f:GetTop() * f:GetScale() end
f:ClearAllPoints() f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 100, -50)
for _, grip in ipairs({ 2.5, 1.37 }) do
    f:SetScale(grip) prof.frame.scale = grip
    local l0, t0 = corner()
    sc.value = nil
    sc.scripts.OnShow(sc)
    local shown = math.floor(grip * 100 + 0.5)
    check(f:GetScale() == grip and prof.frame.scale == grip, ("opening the page leaves a grip-made scale of %.2f alone"):format(grip), f:GetScale())
    check(sc.Text.text == "Step window scale x100: " .. shown, "and the slider names it: " .. sc.Text.text)
    local l1, t1 = corner()
    check(l1 == l0 and t1 == t0, "and the window does not move")
end
f:SetScale(1) prof.frame.scale = 1
f:ClearAllPoints() f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 100, -50)
local l0, t0 = corner()
sc.scripts.OnValueChanged(sc, 150)
local l1, t1 = corner()
check(f:GetScale() == 1.5 and prof.frame.scale == 1.5, "the slider sets the scale", f:GetScale())
check(math.abs(l1 - l0) < 1e-6 and math.abs(t1 - t0) < 1e-6, ("the top-left corner stays where it was (%.1f, %.1f) -> (%.1f, %.1f)"):format(l0, t0, l1, t1))
check(prof.frame.point == "TOPLEFT" and math.abs(prof.frame.x - 100 / 1.5) < 1e-6 and math.abs(prof.frame.y + 50 / 1.5) < 1e-6, "and the saved place is the new corner")
local pts = f.points[1]
check(GF.SetScale(1.5) == false and f.points[1] == pts, "the same scale again does nothing")
sc.scripts.OnValueChanged(sc, 250)
l1, t1 = corner()
check(f:GetScale() == 2.5 and math.abs(l1 - l0) < 1e-6 and math.abs(t1 - t0) < 1e-6, "the grip's largest scale is reachable from the slider, corner kept")
check(GF.SetScale(9) == false and f:GetScale() == 2.5 and GF.SetScale(0.1) and f:GetScale() == 1, "GF.SetScale keeps to the grip's limits")
-- a window hidden since login (the client cannot say where it is): the saved corner is used
f.GetLeft, f.GetTop = function() return nil end, function() return nil end
f:SetScale(1) prof.frame.scale, prof.frame.point, prof.frame.x, prof.frame.y = 1, "TOPLEFT", 100, -50
GF.SetScale(2)
local p2 = f.points[1]
check(p2 and p2.point == "TOPLEFT" and math.abs(p2.x - 50) < 1e-6 and math.abs(p2.y + 25) < 1e-6 and prof.frame.x == 50 and prof.frame.y == -25,
    "hidden window: scaled about the saved corner", p2 and (p2.x .. ", " .. p2.y))
f.GetLeft, f.GetTop = nil, nil
-- the grip sets the WIDTH, never the scale: narrower keeps the text its size (owner's request 2026-11-12)
do
    f:SetScale(1) prof.frame.scale = 1
    local w = GF.SetWidth(300)
    check(w == 300 and f:GetWidth() == 300 and prof.frame.width == 300 and f:GetScale() == 1, "the grip's width: 300 wide, scale untouched", f:GetWidth())
    check(GF.SetWidth(10) == GF.WIDTH_MIN and GF.SetWidth(5000) == GF.WIDTH_MAX, "the width keeps to its limits")
    prof.frame.width = 320 GF.ApplySettings()
    check(f:GetWidth() == 320, "the saved width comes back at login", f:GetWidth())
    prof.frame.width = nil GF.ApplySettings()
    check(f:GetWidth() == GF.BASE_W, "a profile with no width gets the default", f:GetWidth())
    check(GF.grip:GetScript("OnMouseDown") ~= nil, "the grip is there")
    -- ... and a least HEIGHT (owner 2026-11-12: "i can't make the guide go any taller")
    GF.FitHeight()
    local fit = f:GetHeight()
    check(GF.SetMinHeight(fit + 150) == fit + 150 and f:GetHeight() == fit + 150 and prof.frame.minHeight == fit + 150, "the grip's height: dragged taller, kept", f:GetHeight())
    GF.FitHeight()
    check(f:GetHeight() == fit + 150, "a refit keeps the dragged height", f:GetHeight())
    check(GF.SetMinHeight(5000) == GF.HEIGHT_MAX, "the height keeps to its limit")
    check(GF.SetMinHeight(10) == nil and prof.frame.minHeight == nil and f:GetHeight() == fit, "dragged back up: the height follows the text again", f:GetHeight())
end

-- an old profile with a scale outside the limits is brought inside them at login
prof.frame.scale = 3
GF.ApplySettings()
check(prof.frame.scale == 2.5 and f:GetScale() == 2.5, "a saved scale above the grip's limit is clamped at login")
prof.frame.scale = 1 GF.ApplySettings()

-- ---------------------------------------------------------------------------
-- E. Slash: /cr next marks the step done, /cr suggest names the suggested route, /cr guides is still /cr routes
-- ---------------------------------------------------------------------------
local printed = {}
NS.Print = function(_, ...) printed[#printed + 1] = table.concat({ ... }, " ") end
local fwd = 0
local P = NS.Progress
local realForward = P.Forward
P.Forward = function() fwd = fwd + 1 end
SlashCmdList.COMPLETIONROUTE("next")
SlashCmdList.COMPLETIONROUTE("done")
check(fwd == 2 and #printed == 0, "/cr next and /cr done mark the step done (and print nothing else)")
P.Forward = realForward
local realSuggest = NS.Guide.SuggestNext
NS.Guide.SuggestNext = function() return { id = "t:elwynn", name = "Elwynn Forest", minlevel = 1, maxlevel = 10 }, 150 end
SlashCmdList.COMPLETIONROUTE("suggest")
check(printed[1] and printed[1]:find("^Suggested route: Elwynn Forest %[1%-10%] ~3m travel") and printed[1]:find("/cr switch", 1, true), "/cr suggest names the route", printed[1])
NS.Guide.SuggestNext = function() return nil end
SlashCmdList.COMPLETIONROUTE("suggest")
check(printed[2] == "No leveling route fits your level and faction.", "/cr suggest with nothing that fits", printed[2])
NS.Guide.SuggestNext = realSuggest
local m0 = calls.menu
SlashCmdList.COMPLETIONROUTE("guides")
SlashCmdList.COMPLETIONROUTE("routes")
check(calls.menu == m0 + 2, "/cr guides is still an alias of /cr routes")
printed = {}
SlashCmdList.COMPLETIONROUTE("help")
check(printed[1] and printed[1]:find("| suggest |", 1, true) and printed[1]:find("next (mark the step done)", 1, true), "the help line lists suggest and says what next does", printed[1])
local src = assert(io.open("CompletionRoute/Core/Slash.lua")):read("*a")
local _, nexts = src:gsub('cmd == "next"', "")
check(nexts == 1, "one branch handles \"next\" (the second one could never run)")

-- ---------------------------------------------------------------------------
-- F. Wording in the step window and the routes list
-- ---------------------------------------------------------------------------
local gfs = assert(io.open("CompletionRoute/UI/GuideFrame.lua")):read("*a")
local gms = assert(io.open("CompletionRoute/UI/GuideMenu.lua")):read("*a")
check(not gfs:find("every guide", 1, true) and gfs:find("every route", 1, true), "step window: skip quest says every route")
check(not gfs:find("For level", 1, true) and gfs:find("|cff7ddf8fRecommended|r lists what fits you now", 1, true), "step window: the end of a route points at Recommended")
check(gms:find('"Only routes for this level"', 1, true) and not gms:find('"Only guides for this level"', 1, true), "routes list: Only routes for this level")

-- ---------------------------------------------------------------------------
-- G. The gear in place of "..." and the character list (owner's request, 2026-11-12)
-- ---------------------------------------------------------------------------
check(GF.more and gfs:find('Textures', 1, true) and gfs:find('gear")', 1, true) ~= nil, "the step window's menu button uses the gear texture")
check(not gfs:find('smallButton("..."', 1, true), "no \"...\" button left")
check(io.open("CompletionRoute/Textures/gear.tga") ~= nil, "Textures/gear.tga ships")
check(gfs:find('more.Add("Character list"', 1, true) ~= nil, "the gear menu has Character list")
assert(loadfile("CompletionRoute/UI/Characters.lua"))(ADDON, NS)
local CL = NS.Characters
NS.Account = NS.Account or {}
local A = NS.Account
A.GameTypeName = A.GameTypeName or function(t) return ({ era = "Classic Era", tbc = "Anniversary (TBC)", forever = "WoW Forever" })[t] or t end
A.ScopeLabel = A.ScopeLabel or function() return "This character" end
A.ScopeDetail = A.ScopeDetail or function() return "Meln Ashford only" end
local realChars, realKey = A.Characters, A.key
A.key = "Meln-Realm"
-- the client's time() takes a date table like os.time (tools/stubs.lua's does not): use the real ones here
local stubTime, stubDate = time, date
time, date = os.time, os.date
local now = 1800000000
local function stamp(t) return date("%Y-%m-%d %H:%M:%S", t) end
A.Characters = function()
    return {
        { key = "Old-Realm", name = "Old", display = "Old", realm = "Realm", class = "MAGE", level = 12, gametype = "era", updated = stamp(now - 40 * 86400), steps = 3, guides = 1 },
        { key = "Meln-Realm", name = "Meln", surname = "Ashford", display = "Meln Ashford", realm = "Realm", class = "PRIEST", level = 7, gametype = "forever", updated = stamp(now - 100), steps = 20, guides = 2 },
        { key = "Recent-Realm", name = "Recent", display = "Recent", realm = "Realm", class = "WARRIOR", level = 30, gametype = "tbc", updated = stamp(now - 3 * 3600), steps = 9, guides = 1 },
        { key = "Never-Realm", name = "Never", display = "Never", realm = "Realm", class = "ROGUE", level = 1 },
    }
end
local rows = CL.Rows()
check(rows[1].key == "Meln-Realm" and rows[2].key == "Recent-Realm" and rows[3].key == "Old-Realm" and rows[4].key == "Never-Realm",
    "character list: you first, then the most recently synced", rows[1].key .. "," .. rows[2].key .. "," .. rows[3].key)
check(CL.SyncState(rows[1], now) == "this character", "the current character says so")
check(CL.SyncState(rows[2], now) == "synced 3 h ago", "a recent record shows when it synced", (CL.SyncState(rows[2], now)))
check(CL.SyncState(rows[3], now) == "not synced for 40 days", "a record older than 14 days is not synced", (CL.SyncState(rows[3], now)))
check(CL.SyncState(rows[4], now) == "never synced", "a record with no time was never synced")
check(CL.ParseStamp("2026-11-12 12:50:01") ~= nil and CL.ParseStamp("garbage") == nil, "sync times are read, junk is not")
CL.Show()
check(CL.frame and CL.frame.rows[1] and CL.frame.rows[1].name:GetText() == "Meln Ashford", "the window lists the surname", CL.frame and CL.frame.rows[1] and CL.frame.rows[1].name:GetText())
local shown = 0
for _, r in ipairs(CL.frame.rows) do if r:IsShown() then shown = shown + 1 end end
check(shown == 4, "one row per character", shown)
A.Characters, A.key = realChars, realKey
time, date = stubTime, stubDate

GF.Toggle = realToggle
print(("%s: %d checks, %d failed. Drawing, the real mouse and the client's Settings frame cannot be verified offline."):format(
    fails == 0 and "UI TESTS PASSED" or "UI TESTS FAILED", checks, fails))
os.exit(fails == 0 and 0 or 1)
