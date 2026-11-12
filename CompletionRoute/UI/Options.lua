-- CompletionRoute :: UI/Options.lua
-- Minimal options panel (Interface Options / Settings API), no Ace dependency.
-- Every text on these pages is in the addon's own fonts (Core/Util.lua U.Font), so the "Text size" slider covers them
-- too.  Text that grows can wrap, so the rows are not on a fixed grid: O.Layout places them from the measured heights
-- of their labels, when a page is shown and again when the text size changes.
local ADDON, NS = ...
local U = NS.Util
local O = {}
NS.Options = O

local function P() return NS.db.profile end
-- the widget calls below are guarded: the offline harnesses hand this file frames that have only some methods
local function call(obj, method, ...) local fn = obj and obj[method] if fn then return fn(obj, ...) end end
local function setFont(fs, kind) if fs and fs.SetFontObject then pcall(fs.SetFontObject, fs, U.Font(kind)) end end
local function measured(v, default) return (type(v) == "number" and v > 0) and v or default end
local function textH(fs, default) return measured(call(fs, "GetStringHeight"), default) end
local function textW(fs, default) return measured(call(fs, "GetStringWidth"), default) end
local function buttonFonts(b) local GF = NS.GuideFrame if GF and GF.ButtonFonts then GF.ButtonFonts(b) end end
local function fitButton(b) local GF = NS.GuideFrame if GF and GF.FitButton then GF.FitButton(b) end end
local LABEL_W = 540     -- check box labels wrap at this width (the page is about 600 px wide)

local panel = CreateFrame("Frame", "CompletionRouteOptionsPanel")
panel.name = "CompletionRoute"
local t = panel:CreateFontString(nil, "ARTWORK", U.Font("Large"))
t:SetPoint("TOPLEFT", 16, -16); t:SetText("CompletionRoute")
local d = panel:CreateFontString(nil, "ARTWORK", U.Font("Small"))
d:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, -6); d:SetWidth(560); d:SetJustifyH("LEFT")
d:SetText("Completionist's Guide: community-driven routes for every quest, with open travel routing.\nSlash: /cr   Routes: /cr routes   What can I do now: /cr routes -> Recommended   Debug route: /cr route")

-- The step window can be closed with its x, and then nothing on screen brings it back but the minimap button (which
-- can be turned off); the owner does not type slash commands.  These two buttons are the click path: Esc > Options >
-- AddOns > CompletionRoute.
local topButtons = {}
local function topButton(text, w, onClick)
    local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    b:SetSize(w, 22); b:SetText(text)
    b.minW = w
    buttonFonts(b)
    b:SetScript("OnClick", onClick)
    topButtons[#topButtons + 1] = b
    return b
end
O.showWindow = topButton("Show step window", 140, function()
    local GF = NS.GuideFrame
    if GF and GF.frame then GF.frame:Show() GF.SafeUpdate() end
end)
O.showWindow:SetPoint("LEFT", t, "RIGHT", 16, 0)
O.showRoutes = topButton("Routes", 80, function() if NS.GuideMenu and NS.GuideMenu.Show then NS.GuideMenu.Show() end end)
O.showRoutes:SetPoint("LEFT", O.showWindow, "RIGHT", 6, 0)

-- The main page is taller than the Settings canvas (about 600 px; 23 check boxes and 6 sliders need about 900), so its
-- controls sit in a scroll frame, hung under the description (which grows with the text size).  The template exists
-- on all five clients.
local scroll = CreateFrame("ScrollFrame", "CompletionRouteOptionsScroll", panel, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", d, "BOTTOMLEFT", -16, -10); scroll:SetPoint("BOTTOMRIGHT", -30, 8)
local content = CreateFrame("Frame", nil, scroll)
content:SetSize(600, 10)
scroll:SetScrollChild(content)

-- ---------------------------------------------------------------------------
-- Rows.  check(), slider() and keyChoice() add a row to the current page; each row has place(y), which anchors its
-- widgets with their top at y and returns the height it took.
-- ---------------------------------------------------------------------------
local pages = {}
local host, page        -- the frame the rows are made in, and the page they belong to
local function newPage(frame, done)
    host = frame
    page = { rows = {}, done = done }
    pages[#pages + 1] = page
end
newPage(content, function(y) content:SetHeight(-y + 24) end)

local function check(label, get, set, tip)
    local tmpl = (C_XMLUtil and C_XMLUtil.GetTemplateInfo and C_XMLUtil.GetTemplateInfo("InterfaceOptionsCheckButtonTemplate")) and "InterfaceOptionsCheckButtonTemplate" or "SettingsCheckBoxTemplate"
    local okcb, cb = pcall(CreateFrame, "CheckButton", nil, host, tmpl)
    if not okcb or not cb then cb = CreateFrame("CheckButton", nil, host, "UICheckButtonTemplate") end
    local fs = cb.Text
    if not fs then fs = host:CreateFontString(nil, "OVERLAY", U.Font("Body")) fs:SetPoint("LEFT", cb, "RIGHT", 4, 0) end
    setFont(fs, "Body")
    call(fs, "SetWidth", LABEL_W); call(fs, "SetJustifyH", "LEFT"); call(fs, "SetWordWrap", true)
    fs:SetText(label)
    cb.tooltipText = tip
    cb:SetScript("OnShow", function(self) self:SetChecked(get()) end)
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    page.rows[#page.rows + 1] = { kind = "check", f = cb, label = fs, place = function(y)
        -- the label is centred on the box: a row is as tall as the box or the (wrapped) label, whichever is more
        local ch = measured(call(cb, "GetHeight"), 26)
        local rowH = math.max(26, textH(fs, 14) + 8)
        cb:ClearAllPoints(); cb:SetPoint("TOPLEFT", 16, y - (rowH - ch) / 2)
        return rowH
    end }
    return cb
end
-- A slider reports its value when the page opens (OnShow's SetValue): that report changes nothing (`showing`).  The
-- value shown is the setting's own, so a step window scaled by its grip to 1.37 reads 137, not 135.
local function slider(label, min, max, step, get, set)
    local s = CreateFrame("Slider", nil, host, "OptionsSliderTemplate")
    s:SetMinMaxValues(min, max); s:SetValueStep(step); s:SetObeyStepOnDrag(true); s:SetWidth(200)
    setFont(s.Text, "Body"); setFont(s.Low, "Small"); setFont(s.High, "Small")
    s.Low:SetText(min); s.High:SetText(max)
    s:SetScript("OnShow", function(self)
        local v = get()
        self.showing = true
        self:SetValue(v)
        self.showing = nil
        self.Text:SetText(label .. ": " .. v)
    end)
    s:SetScript("OnValueChanged", function(self, v)
        if self.showing then return end
        v = math.floor(v / step + 0.5) * step
        self.Text:SetText(label .. ": " .. v)
        set(v)
    end)
    page.rows[#page.rows + 1] = { kind = "slider", f = s, place = function(y)
        -- its label sits above the bar, the low and high values under it
        local th, lh = textH(s.Text, 14), textH(s.Low, 12)
        local sh = measured(call(s, "GetHeight"), 17)
        s:ClearAllPoints(); s:SetPoint("TOPLEFT", 24, y - th - 4)
        return th + 4 + sh + lh + 4
    end }
    return s
end

check("Show arrow", function() return P().arrow.enabled end, function(v) P().arrow.enabled = v NS.Arrow.ApplySettings() end)
check("Lock arrow position", function() return P().arrow.lock end, function(v) P().arrow.lock = v end)
check("Lock step window", function() return P().frame.lock end, function(v) P().frame.lock = v end)
O.minimap = check("Minimap button", function() return P().minimapButton ~= false end, function(v)
    P().minimapButton = v
    if NS.MinimapButton then NS.MinimapButton.Apply() end
end, "A round button on the edge of the minimap: left click shows or hides the step window, right click opens Routes. Drag it to move it around the edge.")
check("Route optimizer: reorder upcoming steps by travel time", function() return P().routing.reorder end, function(v) P().routing.reorder = v NS.Progress.Refresh() end)
check("Route optimizer: use the pre-computed fastest order for quest routes", function() return P().routing.baked ~= false end, function(v)
    P().routing.baked = v
    -- the order is applied when a guide is parsed: drop the parses it changes and reload the open guide
    for _, id in ipairs(NS.Guide.list) do
        local g = NS.Guide.registry[id]
        if g and g.steps and (g.baked or (NS.RouteOrder and (NS.RouteOrder[id] or (g.part and NS.RouteOrder[g.part])))) then g.steps = nil end
    end
    if NS.Progress.guide then NS.Progress.Load(NS.Progress.guide.id) end
end, "Data/RouteOrder: each quest route's steps solved offline for the least travel time (A before C before T, prerequisites, quest log size and level kept). Off = the route's own order.")
check("Routing: use flight paths", function() return P().routing.taxi end, function(v) P().routing.taxi = v NS.TravelGraph.PathCacheWipe() NS.Router.Invalidate() end)
check("Routing: prefer flight paths (comfort mode)", function() return P().routing.preferTaxi end, function(v) P().routing.preferTaxi = v NS.TravelGraph.PathCacheWipe() NS.Router.Invalidate() end, "Favors comfortable automated flight paths over manual flying.")
check("Routing: fly to every flight master your faction can use, discovered or not (off = only flight paths this character has discovered)", function() return NS.TravelGraph.TaxiPolicy() == "faction" end, function(v) P().routing.taxiPolicy = v and "faction" or "known" P().routing.assumeAllTaxi = nil NS.TravelGraph.TaxiChanged() end, "Off (default): a flight only lands at a flight master you have discovered - on Retail and WoW Forever any character of the account counts, on Classic only this one. The route may walk you to a new flight master to pick it up. On: the old rule; an undiscovered landing is labelled (new flight path).")
check("Flight map: highlight destination when talking to a flight master", function() return P().beacon.highlightTaxi ~= false end, function(v) P().beacon.highlightTaxi = v end, "Shows a pulsing beacon and name over the exact destination pin/button on the flight master map.")
check("Routing: follow roads through zones (authored + recorded paths)", function() return P().routing.roads ~= false end, function(v) P().routing.roads = v NS.TravelGraph.RebuildRoads() NS.Router.Invalidate() end)
check("Routing: record the roads I walk to improve pathing (stored in SavedVariables, shareable)", function() return P().routing.recordRoads ~= false end, function(v) P().routing.recordRoads = v end)
check("Routing: use boats / zeppelins / portals / tram", function() return P().routing.transit end, function(v) P().routing.transit = v NS.TravelGraph.PathCacheWipe() NS.Router.Invalidate() end)
check("Routing: suggest Hearthstone when it is faster", function() return P().routing.hearth end, function(v) P().routing.hearth = v NS.TravelGraph.OneShotChanged() end)
check("Routing: suggest class teleports, transporters and hub hearthstones when faster", function() return P().routing.teleports ~= false end, function(v) P().routing.teleports = v NS.TravelGraph.OneShotChanged() end, "Mage teleports, Teleport: Moonglade, Death Gate (MoP Classic), engineering transporters, the Dalaran and Garrison hearthstones (Data/Teleports.lua). Only what this character knows or owns, with at most 15 minutes of cooldown left. /cr teleports lists them.")
check("Target beacon: marker over the head of the step's NPC / mob", function() return P().beacon.enabled end, function(v) P().beacon.enabled = v NS.Beacon.ApplySettings() end)
check("Target beacon: bob the marker up and down", function() return P().beacon.bounce end, function(v) P().beacon.bounce = v NS.Beacon.RescanPlates() end, "Turn this off for a completely still marker.")
check("Target beacon: minimap + world map pins for the step location", function() return P().beacon.pins end, function(v) P().beacon.pins = v NS.Beacon.UpdatePins() end)
check("Target beacon: one-click target button on the arrow", function() return P().beacon.targetButton end, function(v) P().beacon.targetButton = v NS.Beacon.UpdateTargetButton() end)
check("Account-wide progress: count steps ANY of my characters finished (finer control: the Character / Server / Game type / Account buttons at the top of the Routes window)", function() return P().accountWide end, function(v) NS.Account.SetScope(v and "account" or "char") NS.Progress.Refresh() NS.GuideMenu.UpdateScopeLabel() NS.GuideMenu.RescanCompletion() NS.GuideMenu.Refresh() end, "Completionists: leave this OFF to do every route on every character. Turn it ON to skip content the account has already cleared.")
check("Account-wide: also match by quest ID across different routes", function() return P().accountQuests end, function(v) P().accountQuests = v NS.Progress.Refresh() end, "A quest an alt turned in clears the matching step in any route that covers it, not just the same route.")
check("Debug messages", function() return P().debug end, function(v) P().debug = v end)
slider("Reorder window (steps)", 3, 24, 1, function() return P().routing.window end, function(v) P().routing.window = v NS.Progress.Refresh() end)
slider("Terrain detour factor x100", 100, 200, 5, function() return math.floor((P().routing.terrainFactor or NS.CostModel.TERRAIN) * 100 + 0.5) end, function(v)
    -- drop the cached paths only when the factor really changed
    if P().routing.terrainFactor ~= v / 100 then P().routing.terrainFactor = v / 100 NS.TravelGraph.PathCacheWipe() end
    NS.Router.Invalidate()
end)
slider("Hearth base cost (seconds)", 10, 300, 10, function() return P().routing.hearthCost or NS.CostModel.HEARTH end, function(v)
    if (P().routing.hearthCost or NS.CostModel.HEARTH) ~= v then P().routing.hearthCost = v NS.TravelGraph.OneShotChanged() end
end)
O.textSize = slider("Text size: extra points", 0, 6, 1, function() return P().textSize or 2 end, function(v)
    if (P().textSize or 2) == v then return end
    P().textSize = v
    NS.Util.ApplyTextSize(v)
    if NS.GuideFrame and NS.GuideFrame.SyncFonts then NS.GuideFrame.SyncFonts() end
    O.Layout()      -- labels on these pages may now wrap onto more lines (or fewer)
end)
slider("Beacon scale x100", 50, 200, 5, function() return math.floor((P().beacon.scale or 1) * 100 + 0.5) end, function(v) P().beacon.scale = v / 100 NS.Beacon.RescanPlates() end)
slider("Arrow scale x100", 50, 200, 5, function() return math.floor((P().arrow.scale or 1) * 100 + 0.5) end, function(v) P().arrow.scale = v / 100 NS.Arrow.ApplySettings() end)
-- the step window's grip and this slider have the same limits (UI/GuideFrame.lua GF.SCALE_MIN / SCALE_MAX), and both
-- keep the window's top-left corner where it is (GF.SetScale)
do
    local GF = NS.GuideFrame
    local lo, hi = math.floor(((GF and GF.SCALE_MIN) or 0.6) * 100 + 0.5), math.floor(((GF and GF.SCALE_MAX) or 2.5) * 100 + 0.5)
    O.frameScale = slider("Step window scale x100", lo, hi, 5, function() return math.floor((P().frame.scale or 1) * 100 + 0.5) end, function(v)
        if NS.GuideFrame and NS.GuideFrame.SetScale then NS.GuideFrame.SetScale(v / 100) end
    end)
end

local category
if Settings and Settings.RegisterCanvasLayoutCategory then
    category = Settings.RegisterCanvasLayoutCategory(panel, "CompletionRoute")
    Settings.RegisterAddOnCategory(category)
elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(panel)
end
function O.Open()
    if Settings and Settings.OpenToCategory and category then Settings.OpenToCategory(category:GetID())
    elseif InterfaceOptionsFrame_OpenToCategory then InterfaceOptionsFrame_OpenToCategory(panel) InterfaceOptionsFrame_OpenToCategory(panel) end
end

-- ---------------------------------------------------------------------------
-- Auto quests (Core/QuestAuto.lua, docs/QUEST_AUTO.md): a page of its own under the addon's entry
-- ---------------------------------------------------------------------------
local auto = CreateFrame("Frame", "CompletionRouteOptionsAutoPanel")
auto.name, auto.parent = "Auto quests", panel.name
local at = auto:CreateFontString(nil, "ARTWORK", U.Font("Large"))
at:SetPoint("TOPLEFT", 16, -16); at:SetText("Auto quests")
local ad = auto:CreateFontString(nil, "ARTWORK", U.Font("Small"))
ad:SetPoint("TOPLEFT", at, "BOTTOMLEFT", 0, -6); ad:SetWidth(560); ad:SetJustifyH("LEFT")
ad:SetText("Accepts and turns in only the quests of the route's next steps: never a quest you skipped, never the rest of the route.\n"
    .. "Quests that cost gold, repeatable quests the route does not ask for, and turn-ins with a reward choice are left to you.\n"
    .. "Slash: /cr auto [accept|turnin|reward|on|off|key shift|ctrl|alt|none]")
-- the page's controls hang under the description, which grows with the text size
local autoBody = CreateFrame("Frame", nil, auto)
autoBody:SetPoint("TOPLEFT", ad, "BOTTOMLEFT", -16, -10); autoBody:SetSize(600, 200)
newPage(autoBody, function(y) autoBody:SetHeight(math.max(10, -y)) end)
check("Auto accept the route's quests", function() return P().autoAccept end, function(v) P().autoAccept = v end,
    "Only a quest that belongs to one of the route's next steps, from a quest giver you are talking to.")
check("Auto turn in the route's quests", function() return P().autoTurnin end, function(v) P().autoTurnin = v end,
    "Completes the quest when the game says it can be completed. A turn-in with a reward choice stays open for you.")
check("Auto choose the reward (only a clear upgrade by the gear score)", function() return P().autoChooseReward end, function(v) P().autoChooseReward = v end,
    "Off: every reward choice is yours. On: only when one usable item beats what you wear by 10% or more and clearly beats the others.")

-- the pause key: the client's menu dropdown (Retail 11.0+), the classic UIDropDownMenu, or a button that cycles the keys
local function keyChoice(label)
    local QA = NS.QuestAuto
    local keys = QA and QA.KEYS or { "SHIFT", "CTRL", "ALT", "NONE" }
    local function current() return QA and QA.Key() or (P().autoModifier or "SHIFT") end
    local function text(k) return (QA and QA.KEY_LABEL[k]) or k end
    local function set(k) P().autoModifier = k end
    local fs = host:CreateFontString(nil, "ARTWORK", U.Font("Body"))
    fs:SetText(label)
    local made, dd, kind
    if MenuUtil and C_XMLUtil and C_XMLUtil.GetTemplateInfo and C_XMLUtil.GetTemplateInfo("WowStyle1DropdownTemplate") then
        local ok = pcall(function()
            dd = CreateFrame("DropdownButton", nil, host, "WowStyle1DropdownTemplate")
            dd:SetWidth(140)
            dd:SetupMenu(function(_, root)
                for _, k in ipairs(keys) do root:CreateRadio(text(k), function() return current() == k end, function() set(k) end) end
            end)
        end)
        if ok then made, kind = dd, "menu" elseif dd and dd.Hide then dd:Hide() end
    end
    if not made and UIDropDownMenu_Initialize and UIDropDownMenu_CreateInfo and UIDropDownMenu_AddButton and UIDropDownMenu_SetText then
        dd = nil
        local ok = pcall(function()
            dd = CreateFrame("Frame", "CompletionRouteAutoKeyDropDown", host, "UIDropDownMenuTemplate")
            if UIDropDownMenu_SetWidth then UIDropDownMenu_SetWidth(dd, 120) end
            UIDropDownMenu_Initialize(dd, function()
                for _, k in ipairs(keys) do
                    local info = UIDropDownMenu_CreateInfo()
                    info.text, info.checked = text(k), current() == k
                    info.func = function() set(k) UIDropDownMenu_SetText(dd, text(k)) end
                    UIDropDownMenu_AddButton(info)
                end
            end)
            dd:SetScript("OnShow", function() UIDropDownMenu_SetText(dd, text(current())) end)
        end)
        if ok then made, kind = dd, "uidd" elseif dd and dd.Hide then dd:Hide() end
    end
    if not made then
        local b = CreateFrame("Button", nil, host, "UIPanelButtonTemplate")
        b:SetSize(120, 22)
        b.minW = 120
        buttonFonts(b)
        local function show() b:SetText(text(current())) fitButton(b) end
        b:SetScript("OnShow", show)
        b:SetScript("OnClick", function()
            local cur, nxt = current(), keys[1]
            for i, k in ipairs(keys) do if k == cur then nxt = keys[i % #keys + 1] end end
            set(nxt) show()
        end)
        made, kind = b, "button"
    end
    page.rows[#page.rows + 1] = { kind = "key", f = made, label = fs, place = function(y)
        -- the choice sits right of the label, at 260 or further when the label is wider than the room it had
        local x = math.max(260, math.ceil(20 + textW(fs, 200) + 16))
        fs:ClearAllPoints(); fs:SetPoint("TOPLEFT", 20, y - 6)
        made:ClearAllPoints()
        if kind == "uidd" then made:SetPoint("TOPLEFT", x - 16, y + 2)    -- the template's left edge is 16 px of padding
        else made:SetPoint("TOPLEFT", x, y) end
        return math.max(34, textH(fs, 14) + 20)
    end }
    return made
end
O.autoKey = keyChoice("Hold to do a quest giver yourself:")

-- ---------------------------------------------------------------------------
-- Layout: every page's rows, top to bottom, from the heights measured now
-- ---------------------------------------------------------------------------
function O.Layout()
    for _, pg in ipairs(pages) do
        local y = -4
        for _, r in ipairs(pg.rows) do y = y - r.place(y) end
        if pg.done then pg.done(y) end
    end
    for _, b in ipairs(topButtons) do fitButton(b) end
end
O.Layout()
O._pages, O._content, O._scroll, O._description = pages, content, scroll, d     -- for tools/test_ui.lua
local function onShow() O.Layout() end
for _, fr in ipairs({ panel, auto }) do
    if fr.HookScript then fr:HookScript("OnShow", onShow) else fr:SetScript("OnShow", onShow) end
end

if Settings and Settings.RegisterCanvasLayoutSubcategory and category then
    O.autoCategory = Settings.RegisterCanvasLayoutSubcategory(category, auto, "Auto quests")
elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(auto)
end
