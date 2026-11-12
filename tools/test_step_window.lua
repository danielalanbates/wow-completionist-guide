-- Offline checks of the step window's layout rules (UI/GuideFrame.lua) and of what the card shows.
-- Run from the repo root:  luajit -joff tools/test_step_window.lua
--
-- WHAT THIS CAN AND CANNOT SHOW.  There is no client here, so nothing is drawn and PIXEL OVERLAP CANNOT BE VERIFIED.
-- What is checked is that the layout code follows the rules that keep texts apart:
--   1. every text gets an explicit width before its height is read (a string without one reports a one-line height,
--      which is how the note was once printed over a wrapped title);
--   2. no text is given a fixed height;
--   3. the note's anchor follows the title's height;
--   4. the card ends above the travel line and the window's height is the sum of its parts;
--   5. the title line is one chain (name, step count, Contribute, its box, Routes, "...", close), each hung from the next;
-- on a widget mock whose strings wrap by the same text model as tools/audit_step_text.lua (character widths by class,
-- see tools/guide_walk.lua).  With those rules held, the vertical bands of the mock are compared for the shortest and
-- the longest texts the shipped guides have, at scale 1, 0.6 and 2.5.  A real font can still differ from the model:
-- the owner's eyes in the client are the last check.
package.path = "./?.lua;" .. package.path
local ADDON, NS = "CompletionRoute", {}
dofile("tools/stubs.lua")
local W = dofile("tools/guide_walk.lua")
PLAYER = { map = 1429, x = 0.487, y = 0.42 } PLAYER.wx, PLAYER.wy, PLAYER.inst = z2w(PLAYER.x, PLAYER.y, PLAYER.map)

local fails, checks = 0, 0
local function check(ok, what)
    checks = checks + 1
    if not ok then fails = fails + 1 print("FAIL " .. what) end
end

-- ---------------------------------------------------------------------------
-- Widget mock: remembers anchors, sizes, text and visibility; strings measure themselves with the text model
-- ---------------------------------------------------------------------------
local FONT_PT = { GameFontNormalLarge = 17, GameFontHighlight = 13, GameFontHighlightSmall = 12, GameFontNormal = 13 }
local seq = 0
local violations = {}
local Widget = {}
Widget.__index = function(t, k)
    local v = rawget(Widget, k)
    if v ~= nil then return v end
    -- any other METHOD (capitalised, like every widget method) is accepted and ignored; data fields stay nil
    if type(k) ~= "string" or not k:match("^%u") then return nil end
    local f = function() end
    rawset(t, k, f)
    return f
end
local function new(kind, name, parent, font)
    local w = setmetatable({ kind = kind, name = name, parent = parent, font = font, points = {}, scripts = {}, shown = true, text = "" }, Widget)
    return w
end
function Widget:SetPoint(point, a, b, c, d)
    local rel, relPoint, x, y
    if type(a) == "table" then rel, relPoint, x, y = a, b, c, d
        if type(relPoint) ~= "string" then relPoint, x, y = point, b, c end
    else rel, relPoint, x, y = self.parent, point, a, b end
    self.points[#self.points + 1] = { point = point, rel = rel, relPoint = relPoint, x = x or 0, y = y or 0 }
end
function Widget:ClearAllPoints() self.points = {} end
function Widget:SetAllPoints() self.points = { { point = "ALL", rel = self.parent } } end
function Widget:SetWidth(w) seq = seq + 1 self.width, self.widthSeq = w, seq end
function Widget:SetHeight(h)
    self.height = h
    if self.kind == "FontString" then violations[#violations + 1] = "SetHeight on a text: " .. tostring(self.text):sub(1, 40) end
end
function Widget:SetSize(w, h) self:SetWidth(w) self.height = h end
function Widget:GetWidth() return self.width end
function Widget:GetHeight() return self.height end
function Widget:SetScale(s) self.scale = s end
function Widget:GetScale() return self.scale or 1 end
function Widget:SetText(t) self.text = t or "" end
function Widget:GetText() return self.text end
function Widget:Show() self.shown = true end
function Widget:Hide() self.shown = false if self.scripts.OnHide then self.scripts.OnHide(self) end end
function Widget:SetShown(v) if v then self:Show() else self:Hide() end end
function Widget:IsShown() return self.shown end
function Widget:SetScript(k, fn) self.scripts[k] = fn end
function Widget:GetScript(k) return self.scripts[k] end
function Widget:SetMaxLines(n) self.maxLines = n end
function Widget:SetWordWrap(v) self.wrap = v end
function Widget:SetEnabled(v) self.enabled = v and true or false end
function Widget:Enable() self.enabled = true end
function Widget:Disable() self.enabled = false end
function Widget:SetChecked(v) self.checked = v and true or false end
function Widget:GetChecked() return self.checked end
function Widget:CreateFontString(_, _, font) return new("FontString", nil, self, font) end
function Widget:CreateTexture() return new("Texture", nil, self) end
function Widget:GetStringWidth() return #W.Plain(self.text) * (FONT_PT[self.font] or 12) * 0.52 end
-- button labels: the font objects the addon gives them (GF.ButtonFonts), and the width of the label in the normal one
function Widget:SetNormalFontObject(fo) self.normalFont = fo end
function Widget:SetHighlightFontObject(fo) self.highlightFont = fo end
function Widget:SetDisabledFontObject(fo) self.disabledFont = fo end
function Widget:GetTextWidth() return #W.Plain(self.text) * (FONT_PT[self.normalFont or "GameFontNormal"] or 13) * 0.52 end
-- Like the client: a wrapped string with no width yet has not been laid out and answers with ONE line.
function Widget:GetStringHeight()
    seq = seq + 1
    self.heightReadSeq = seq
    local pt = FONT_PT[self.font] or 12
    if self.text == "" then return 0 end
    if self.wrap == false then return pt end
    if not self.width then
        violations[#violations + 1] = "height read before a width was set: " .. tostring(self.text):sub(1, 40)
        return pt
    end
    local n = W.Lines(self.text, self.width, pt)
    if self.maxLines and n > self.maxLines then n = self.maxLines end
    return n * pt + (n - 1) * 2
end
local named = {}
CreateFrame = function(kind, name, parent)
    local w = new(kind or "Frame", name, parent)
    if name then named[name] = w end
    return w
end
UIParent = new("Frame", "UIParent")
UIParent.width, UIParent.height = 1600, 900
GameTooltip = new("GameTooltip", "GameTooltip")

-- ---------------------------------------------------------------------------
-- Load the addon parts the window needs
-- ---------------------------------------------------------------------------
for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", "Core/Progress.lua" }) do
    assert(loadfile("CompletionRoute/" .. f))(ADDON, NS)
end
CompletionRouteDB, CompletionRouteCharDB = nil, nil
for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", ADDON) end
local called = {}
NS.Contribute = { Enabled = function() return false end, SetEnabled = function() end, ShowExport = function() called.export = (called.export or 0) + 1 end }
NS.Options = { Open = function() called.options = (called.options or 0) + 1 end }
NS.BugReport = { FromButton = function() called.report = (called.report or 0) + 1 end }
NS.GuideMenu = { Toggle = function() called.routes = (called.routes or 0) + 1 end }
local PATH_TEXT = ""
NS.Router = { StepWorld = function() return nil end, CurrentPath = function() return PATH_TEXT ~= "" and {} or nil end,
              TravelSecondsFromPlayer = function() return nil end, OrderSteps = function(list) return list end, Invalidate = function() end }
NS.TravelGraph = { Summary = function() return PATH_TEXT end, Describe = function() return PATH_TEXT end }
assert(loadfile("CompletionRoute/UI/GuideFrame.lua"))(ADDON, NS)
local GF, P, G = NS.GuideFrame, NS.Progress, NS.Guide
local L = GF.L
local f, card = GF.frame, GF.card

-- ---------------------------------------------------------------------------
-- A. The source keeps to the rules
-- ---------------------------------------------------------------------------
local src = assert(io.open("CompletionRoute/UI/GuideFrame.lua")):read("*a")
do
    local fit = src:match("function GF%.FitHeight%(%)(.-)\nend\n")
    check(fit ~= nil, "GF.FitHeight found in the source")
    fit = fit or ""
    local firstRead = fit:find("sh%(card%.")
    for _, w in ipairs({ "card%.title:SetWidth", "card%.note:SetWidth", "card%.where:SetWidth", "pathText:SetWidth" }) do
        local at = fit:find(w)
        check(at and firstRead and at < firstRead, "FitHeight sets " .. w:gsub("%%", "") .. " before it reads a height")
    end
    check(fit:find('card%.note:SetPoint%("TOPLEFT", card, "TOPLEFT", L%.pad, %-%(L%.pad %+ head %+ L%.gap%)%)'), "the note's anchor is computed from the title's height (head)")
    check(fit:find("local head = math%.max%(L%.icon, sh%(card%.title%) %+ 2%)"), "head is the taller of the icon and the measured title")
    check(fit:find("empty:SetWidth") and fit:find("empty:SetWidth") < fit:find("sh%(empty%)"), "the empty-state text gets its width before its height is read")
    for _, t in ipairs({ "card%.title", "card%.note", "card%.where", "pathText", "titleText", "stepText", "empty", "dTitle", "dBody", "confirm%.text" }) do
        check(not src:find(t .. ":SetHeight%("), "no fixed height on the text " .. t:gsub("%%", ""))
        check(not src:find(t .. ":SetSize%("), "no fixed size on the text " .. t:gsub("%%", ""))
    end
    -- one row of controls: the second button row is gone, its functions are in the "..." menu
    check(not src:find('smallButton%("Route",') and not src:find('smallButton%("Opts",') and not src:find('smallButton%("Report",'), "the Route, Opts and Report buttons are off the window")
    check(src:find("more%.reorder") and src:find("more%.options") and src:find("more%.report") and src:find("more%.startOver"), "the \"...\" menu holds reorder, options, report and start over")
    check(src:find("GF%.L = %b{}") and src:find("GF%.BASE_W, GF%.BASE_H = %d+, %d+"), "the layout numbers are one literal table (the audit reads it)")
    local _, boxes = src:gsub("UICheckButtonTemplate", "")
    check(boxes == 1, "one tick box on the window (Contribute)")
    -- menus and the confirmation stay on screen when the window sits at the screen's edge
    local _, clamps = src:gsub(":SetClampedToScreen%(true%)", "")
    check(clamps >= 3, "the window, its menus and the Start over question are clamped to the screen")
    -- the way back after the x: a printed hint, and two buttons on the options page
    check(src:find("Step window hidden%. To show it again"), "closing the window says how to show it again")
    local opt = assert(io.open("CompletionRoute/UI/Options.lua")):read("*a")
    check(opt:find('O%.showWindow = topButton%("Show step window"') and opt:find('O%.showRoutes = topButton%("Routes"'), "the options page has Show step window and Routes buttons (the click path back)")
end

-- ---------------------------------------------------------------------------
-- B. The title line is one chain; the arrows hang from the card
-- ---------------------------------------------------------------------------
local function anchoredTo(w, rel, point, relPoint)
    for _, p in ipairs(w.points) do
        if p.rel == rel and (not point or p.point == point) and (not relPoint or p.relPoint == relPoint) then return p end
    end
    return nil
end
do
    local label, box, more = GF.contributeLabel, GF.contribute, GF.more
    local chain = { { GF.titleText, GF.stepText, "name -> step count" }, { GF.stepText, label, "step count -> Contribute" }, { label, box, "Contribute -> its box" } }
    for _, c in ipairs(chain) do
        local p = anchoredTo(c[1], c[2], "RIGHT", "LEFT")
        check(p ~= nil and p.x <= 0, "title line: " .. c[3] .. " (RIGHT hung from the LEFT of the next, no overlap)")
    end
    check(anchoredTo(more, nil, "RIGHT", "LEFT") ~= nil or #more.points == 1, "the \"...\" button hangs from the close button")
    check(GF.titleText.wrap == false and GF.stepText.wrap == false, "route name and step count never wrap")
    check(anchoredTo(GF.back, card, "RIGHT", "LEFT") and anchoredTo(GF.forward, card, "LEFT", "RIGHT"), "the arrows hang beside the card, so they cannot reach the title or the travel line")
    check(anchoredTo(GF.restart, GF.empty, "TOPLEFT", "BOTTOMLEFT") ~= nil, "Start over hangs under the end-of-route text")
end

-- ---------------------------------------------------------------------------
-- C. Bands of the mock: title, note, distance line, travel line never share a row
-- ---------------------------------------------------------------------------
local LONG_TITLE = ("Defeat the Sire Denathrius encounter in Castle Nathria on Mythic difficulty after "):rep(3)
local LONG_NOTE = ("About 16 crafts (estimated from the skill colours). 16 Bear Flank, 12 Refreshing Spring Water, 8 Mild Spices; "):rep(7)
local LONG_PATH = "Hearth to Shattrath City, then fly to Cosmowrench, Netherstorm, then boat to Menethil Harbor, Wetlands, then fly to Thorium Point, Searing Gorge  (~1h 12m)"
G.Register({ id = "w:layout", name = "A route with a rather long name that cannot fit the title line (Alliance)", type = "Professions", text = table.concat({
    "N Short|",
    "N Short with note|N|One line.|",
    "N " .. LONG_TITLE .. "|N|" .. LONG_NOTE .. "|O|",
    "N Medium title that wraps onto a second line for sure, yes it does|N|" .. LONG_NOTE:sub(1, 200) .. "|Z|1429; Elwynn Forest|",
    "C Rings|L|3505 7|N|Alterac Signet Ring (7) (location: the wiki's Strahnbrad page)|",
}, "\n") })
local function bands(label)
    violations = {}
    GF.Update()
    for _, v in ipairs(violations) do check(false, label .. ": " .. v) end
    local H = f.height
    local top = anchoredTo(card, f, "TOPLEFT")
    local bottom = anchoredTo(card, f, "BOTTOMRIGHT")
    check(top and bottom and top.y == -L.top and bottom.y >= 26, label .. ": the card hangs under the title line and ends above the travel line")
    local foot = bottom and bottom.y or 0
    local cardH = H - L.top - foot
    local th, nh, wh, ph = card.title:GetStringHeight(), card.note:GetStringHeight(), card.where:GetStringHeight(), GF.pathText:GetStringHeight()
    local head = math.max(L.icon, th + 2)
    local notePoint = anchoredTo(card.note, card, "TOPLEFT", "TOPLEFT")
    check(notePoint and notePoint.y == -(L.pad + head + L.gap), label .. ": the note's anchor follows the title's height")
    -- distances down from the card's top edge
    local titleBottom = L.pad + 2 + th
    local noteTop = notePoint and -notePoint.y or 0
    local noteBottom = noteTop + nh
    local whereTop = cardH - 6 - wh
    check(noteTop >= titleBottom, ("%s: note starts under the title (%d >= %d)"):format(label, noteTop, titleBottom))
    check(noteTop >= L.pad + L.icon, label .. ": note starts under the icon")
    check(wh == 0 or whereTop >= noteBottom, ("%s: the distance line is under the note (%d >= %d)"):format(label, whereTop, noteBottom))
    check(foot >= 8 + ph, ("%s: the travel line fits under the card (%d >= %d)"):format(label, foot, 8 + ph))
    check(H >= GF.BASE_H and cardH >= L.pad + head, label .. ": the window is at least its least height and holds the card")
    check(card.title.width == f.width - 2 * L.side - (2 * L.pad + L.icon + L.gap) and card.note.width == f.width - 2 * L.side - 2 * L.pad, label .. ": title and note widths come from the window's width")
    -- title line: the route name shows only while it has room; it is never squeezed to nothing or to less than nothing
    check(type(GF.nameRoom) == "number" and GF.titleText:IsShown() == (GF.nameRoom >= L.nameMin), label .. ": the route name shows only with room for it (" .. tostring(GF.nameRoom) .. ")")
    return H
end
P.Load("w:layout")
local heights = {}
for i = 1, 5 do
    for _, path in ipairs({ "", "Fly to Stormwind, Elwynn  (~2m 10s)", LONG_PATH }) do
        PATH_TEXT = path
        heights[#heights + 1] = bands(("step %d, travel line %d chars"):format(i, #path))
    end
    if i == 3 then
        check(card.title:GetStringHeight() == L.titleLines * 17 + (L.titleLines - 1) * 2, "a title longer than " .. L.titleLines .. " lines is cut at the cap, not printed over the note")
        check(card.note:GetStringHeight() == L.noteLines * 13 + (L.noteLines - 1) * 2, "a note longer than " .. L.noteLines .. " lines is cut at the cap")
        check(card.note.text:find("%(optional%)"), "an optional step says so on the card")
    end
    if i == 5 then
        check(card.note.text == "Alterac Signet Ring (7)", "the card leaves the source note off: " .. card.note.text)
    end
    P.Forward()
end
check(heights[1] < heights[9], "a long step makes a taller window than a short one (" .. heights[1] .. " < " .. heights[9] .. ")")
-- the whole window scales, so the layout numbers are the same at every scale the grip allows
P.Load("w:layout") P.Reset()
P.Forward() P.Forward()
PATH_TEXT = LONG_PATH
local h1 = bands("scale 1.0")
f:SetScale(0.6) local h06 = bands("scale 0.6")
f:SetScale(2.5) local h25 = bands("scale 2.5")
f:SetScale(1)
check(h1 == h06 and h1 == h25, ("the layout is the same at scale 0.6, 1 and 2.5 (%d, %d, %d)"):format(h06, h1, h25))
-- title line text
check(GF.titleText.text:find("A route with a rather long name") and GF.stepText.text:find("^step 3 of 5"), "title line: route name, then \"step N of M\": " .. GF.stepText.text)
-- title line under pressure: larger text (the Options slider) and "re-planning..." beside the step count.  The room
-- for the name is what is left of the window's width; it must never go under the least, let alone negative.
do
    local function header(pt, replanning)
        FONT_PT.GameFontHighlightSmall = pt
        NS.Replan = replanning and { running = true } or nil
        violations = {}
        GF.Update()
        local word = GF.contributeLabel.text:GetStringWidth() + 2
        local room = f.width - (6 + GF.close.width + 2 + GF.more.width + 2 + GF.routes.width + 4 + 20 + 1 + word + 8) - 10
        return room, GF.stepText:GetStringWidth()
    end
    local room, stepW = header(12, true)
    check(GF.stepText.text:find("re%-planning") and GF.titleText:IsShown(), "default text size: step count, re-planning and the route name all fit")
    check(math.abs(GF.nameRoom - (room - stepW - 8)) < 0.01, ("the name's room is the window's width less everything right of it (%.1f, %.1f)"):format(GF.nameRoom, room - stepW - 8))
    room, stepW = header(18, true)
    check(not GF.stepText.text:find("re%-planning") and GF.stepText.text:find("^step 3 of 5"), "larger text: \"re-planning...\" gives way before the route name does: " .. GF.stepText.text)
    check(GF.titleText:IsShown() and GF.nameRoom >= L.nameMin, "and the name keeps its room")
    room, stepW = header(30, true)
    check(not GF.titleText:IsShown(), "no room at all: the route name is hidden (it is in the tooltip), not drawn over the step count")
    check(GF.stepText.width ~= nil and GF.stepText.width <= room + 0.01 and GF.stepText.text:find("^step 3 of 5"), "and the step count is cut to the room it has")
    room, stepW = header(12, false)
    check(GF.titleText:IsShown() and (GF.stepText.width == 0 or GF.stepText.width == nil) and stepW <= room, "back at the default size the line is whole again")
end

-- ---------------------------------------------------------------------------
-- D. End of a route: text, Start over button, window height; menus and the word Contribute
-- ---------------------------------------------------------------------------
P.Forward() P.Forward() P.Forward()      -- the long travel line is still showing: the card's foot is tall
check(P.current == nil, "the test route is finished")
PATH_TEXT = ""
violations = {}
GF.Update()
do
    local bottom = anchoredTo(card, f, "BOTTOMRIGHT")
    check(bottom and bottom.y == 26 and anchoredTo(card, f, "TOPLEFT").y == -L.top, "end of route: the hidden card (the arrows hang from it) is back at its plain place")
end
for _, v in ipairs(violations) do check(false, "end of route: " .. v) end
check(not card:IsShown() and GF.empty:IsShown() and GF.restart:IsShown(), "end of route: the text and the Start over button show, the card does not")
check(GF.empty.text:find("Route complete") and GF.empty.text:find("Start over"), "end of route text names Start over")
check(f.height >= L.top + 6 + GF.empty:GetStringHeight() + 30 + 14, "end of route: the window holds the text and the button")
GF.restart.scripts.OnClick(GF.restart)
check(P.current and P.current.title == "Short" and not GF.confirm:IsShown(), "Start over on a finished route goes straight back to step one")
GF.Update()
check(card:IsShown() and not GF.restart:IsShown(), "and the card is back, the button gone")
-- with steps left, it asks first
P.Forward()
GF.stepMenu.startOver.scripts.OnClick(GF.stepMenu.startOver)
check(GF.confirm:IsShown() and P.VisibleDone() == 1, "Start over from the card's right-click menu asks before clearing an unfinished route")
GF.confirm.no.scripts.OnClick(GF.confirm.no)
check(not GF.confirm:IsShown() and P.VisibleDone() == 1, "Cancel keeps the route as it is")
GF.moreMenu.startOver.scripts.OnClick(GF.moreMenu.startOver)
check(GF.confirm:IsShown(), "Start over from the \"...\" menu asks too")
GF.confirm.yes.scripts.OnClick(GF.confirm.yes)
check(P.VisibleDone() == 0 and P.current.title == "Short" and not GF.confirm:IsShown(), "confirming clears the marks and goes back to step one")
-- the "..." menu and the word Contribute
GF.more.scripts.OnClick(GF.more)
check(GF.moreMenu:IsShown() and GF.moreMenu.reorder.text:find("^Reorder steps: O"), "the \"...\" button opens its menu and shows the reorder state: " .. tostring(GF.moreMenu.reorder.text))
local before = NS.db.profile.routing.reorder
GF.moreMenu.reorder.scripts.OnClick(GF.moreMenu.reorder)
check(NS.db.profile.routing.reorder == (not before) and not GF.moreMenu:IsShown(), "Reorder steps toggles the optimizer and closes the menu")
GF.moreMenu.options.scripts.OnClick(GF.moreMenu.options)
GF.moreMenu.report.scripts.OnClick(GF.moreMenu.report)
check(called.options == 1 and called.report == 1, "Options and Report a bug are reachable from the menu")
GF.contributeLabel.scripts.OnClick(GF.contributeLabel)
check(called.export == 1, "clicking the word Contribute opens the export window (NS.Contribute.ShowExport)")
-- the Details panel grows with its text and shows the note whole
P.Load("w:layout") P.Reset()
for _ = 1, 4 do P.Forward() end
GF.ShowDetail(P.current)
check(GF.detailBody.text:find("(location: the wiki's Strahnbrad page)", 1, true), "the Details panel shows the note whole, source note included")
check(GF.detail.height >= GF.DETAIL_H and GF.detailBody.width == GF.DETAIL_W - 24, "the Details panel has explicit text widths and a height from its text")
P.Load("w:layout") P.Reset() P.Forward() P.Forward()
GF.ShowDetail(P.current)
check(GF.detail.height >= 10 + GF.detailTitle:GetStringHeight() + 8 + GF.detailBody:GetStringHeight() + 14 + 18 + 10, "a long step makes a taller Details panel instead of running over its buttons")

-- ---------------------------------------------------------------------------
-- E. What the card shows (G.CardNote): source notes and wiki asides go to the tooltip and the Details panel
-- ---------------------------------------------------------------------------
local function cardOf(note) local s = { note = note } local c, t = G.CardNote(s) return c, t end
local cases = {
    { "Alterac Signet Ring (7) (location: the wiki's Strahnbrad page)", "Alterac Signet Ring (7)" },
    { "To the Ground! criterion. (zone only; wiki: Commander Springvale)", "To the Ground! criterion." },
    { "Objective area (Blizzard quest map pin).", "Objective area." },
    { "Turn in. (location: Blizzard quest POI, the turn-in area)", "Turn in." },
    { "Crushridge Warmonger slain (15) (location: the wiki's Crushridge Hold page; Crushridge Warmonger)", "Crushridge Warmonger slain (15)" },
    { "No wiki page; the quest's map from Blizzard data (zone only).", "No wiki page; the quest's map from Blizzard data." },
    { "(zone only; Blizzard Map 123)", "" },
    { "Earn 1000 Valor Points. (10 pts)", "Earn 1000 Valor Points. (10 pts)" },
    { "Kill 10 boars (Optional)", "Kill 10 boars (Optional)" },
    { "From Deputy Willem.", "From Deputy Willem." },
    { "", "" },
    -- a short note keeps a sentence in brackets: it may be the instruction, and it fits
    { "Kill the wolves. (Leave the alpha alone.)", "Kill the wolves. (Leave the alpha alone.)" },
}
for _, c in ipairs(cases) do
    local got = cardOf(c[1])
    check(got == c[2], ("card note of %q: %q (want %q)"):format(c[1], tostring(got), c[2]))
end
do
    local got, cut = cardOf("About 12 crafts (estimated from the skill colours). 12 Clam Meat (This meat can be found in Giant Clams under the water.); 12 Refreshing Spring Water (This item can also be purchased from vendors...)")
    check(got == "About 12 crafts (estimated from the skill colours). 12 Clam Meat; 12 Refreshing Spring Water  |cff888888(click for more)|r", "wiki asides leave the card and it says there is more: " .. tostring(got))
    check(cut ~= "", "and CardNote reports that something was cut")
    local s = G.ParseLine("N Pigs|N|Bring 6 of their [http://www.example.com/item=57758 Swine Bellies].|", 1)
    check(s.note == "Bring 6 of their Swine Bellies.", "a wiki external link in a note reads as its label: " .. s.note)
    local step = { note = "A (location: X)" }
    G.CardNote(step) step.note = "B (location: Y)"
    check(G.CardNote(step) == "B", "the cached card note follows the note")
end

-- ---------------------------------------------------------------------------
-- F. Button labels: the addon's fonts (the Options "Text size" slider covers them), and buttons as wide as their labels
-- ---------------------------------------------------------------------------
do
    local U = NS.Util
    -- GF.more is the gear: an icon with no label, so no font to check
    for _, b in ipairs({ GF.close, GF.routes, GF.restart, GF.confirm.yes, GF.confirm.no, GF.moreMenu.reorder, GF.stepMenu.skipQuest }) do
        check(b.normalFont == U.Font("Title") and b.highlightFont == U.Font("Body") and b.disabledFont ~= nil,
            "button '" .. tostring(b.text) .. "': its label is in the addon's fonts")
    end
    local function wideEnough(b, pad) return b.width >= b:GetTextWidth() + pad - 1e-6 and b.width >= b.minW end
    FONT_PT.GameFontNormal = 19          -- the largest text size and then some
    P.Load("w:layout") P.Reset()
    violations = {}
    GF.Update()
    for _, v in ipairs(violations) do check(false, "large button labels: " .. v) end
    for _, b in ipairs({ GF.close, GF.more, GF.routes }) do
        check(wideEnough(b, 10), ("title line: '%s' is as wide as its label (%d >= %.1f)"):format(b.text, b.width, b:GetTextWidth() + 10))
    end
    check(GF.routes.width > 52, "the Routes button grew with its label: " .. GF.routes.width)
    local word = GF.contributeLabel.text:GetStringWidth() + 2
    local room = f.width - (6 + GF.close.width + 2 + GF.more.width + 2 + GF.routes.width + 4 + 20 + 1 + word + 8) - 10
    check(math.abs(GF.nameRoom - (room - GF.stepText:GetStringWidth() - 8)) < 0.01, "the title line's room allows for the wider buttons")
    check(GF.titleText:IsShown() == (GF.nameRoom >= L.nameMin), "and the route name shows only with room for it")
    GF.more.scripts.OnClick(GF.more)
    local mw = 0
    for _, b in ipairs(GF.moreMenu.buttons) do
        check(wideEnough(b, 16), ("\"...\" menu: '%s' fits its row"):format(b.text))
        mw = math.max(mw, b.width)
    end
    check(GF.moreMenu.width == mw + 16, "the \"...\" menu is as wide as its rows")
    GF.moreMenu:Hide()
    GF.ShowStepMenu(P.current, card)
    for _, b in ipairs(GF.stepMenu.buttons) do check(wideEnough(b, 16), ("step menu: '%s' fits its row"):format(b.text)) end
    GF.ShowDetail(P.current)
    local row = 12 + 4 * 3 + 12
    local dButtons = {}
    for _, w in ipairs(GF._detailButtons or {}) do dButtons[#dButtons + 1] = w row = row + w.width end
    check(#dButtons == 4, "the Details panel has its four buttons")
    for _, b in ipairs(dButtons) do check(wideEnough(b, 10), ("Details: '%s' is as wide as its label"):format(b.text)) end
    check(GF.detail.width >= row and GF.detail.width > GF.DETAIL_W, ("the Details panel widens to hold its button row (%d >= %d)"):format(GF.detail.width, row))
    check(GF.detailBody.width == GF.detail.width - 24 and GF.detailTitle.width == GF.detail.width - 42, "and its texts take the new width")
    GF.detail:Hide()
    GF.StartOver()
    check(GF.confirm:IsShown() and wideEnough(GF.confirm.yes, 10) and wideEnough(GF.confirm.no, 10), "Start over question: both buttons fit their labels")
    GF.confirm:Hide()
    FONT_PT.GameFontNormal = 13
    GF.Update()
    check(GF.routes.width == 52 and GF.close.width == 20, "back at the default size the buttons are their own width again")
end

print(("%s: %d checks, %d failed. Pixel overlap cannot be verified offline."):format(fails == 0 and "STEP WINDOW TESTS PASSED" or "STEP WINDOW TESTS FAILED", checks, fails))
os.exit(fails == 0 and 0 or 1)
