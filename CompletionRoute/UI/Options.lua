-- CompletionRoute :: UI/Options.lua
-- Minimal options panel (Interface Options / Settings API), no Ace dependency.
local ADDON, NS = ...
local O = {}
NS.Options = O

local panel = CreateFrame("Frame", "CompletionRouteOptionsPanel")
panel.name = "CompletionRoute"
local t = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
t:SetPoint("TOPLEFT", 16, -16); t:SetText("CompletionRoute")
local d = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
d:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, -6); d:SetWidth(560); d:SetJustifyH("LEFT")
d:SetText("The completionist's guide: community-driven guides for every quest, with open travel routing.\nSlash: /cr   Routes: /cr routes   What can I do now: /cr routes -> For level N   Debug route: /cr route")

-- The step window can be closed with its x, and then nothing on screen brings it back; the owner does not type slash
-- commands.  These two buttons are the click path: Esc > Options > AddOns > CompletionRoute.
local function topButton(text, w, onClick)
    local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    b:SetSize(w, 22); b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end
O.showWindow = topButton("Show step window", 140, function()
    local GF = NS.GuideFrame
    if GF and GF.frame then GF.frame:Show() GF.SafeUpdate() end
end)
O.showWindow:SetPoint("LEFT", t, "RIGHT", 16, 0)
O.showRoutes = topButton("Routes", 80, function() if NS.GuideMenu and NS.GuideMenu.Show then NS.GuideMenu.Show() end end)
O.showRoutes:SetPoint("LEFT", O.showWindow, "RIGHT", 6, 0)

-- The main page is taller than the Settings canvas (about 600 px; 22 checkboxes and 6 sliders need about 830), so its
-- controls sit in a scroll frame.  The template exists on all five clients.
local scroll = CreateFrame("ScrollFrame", "CompletionRouteOptionsScroll", panel, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 0, -64); scroll:SetPoint("BOTTOMRIGHT", -30, 8)
local content = CreateFrame("Frame", nil, scroll)
content:SetSize(620, 10)
scroll:SetScrollChild(content)

local y = -4
local host = content   -- the page check() and slider() add to (the "Auto quests" page below switches it)
local function check(label, get, set, tip)
    local tmpl = (C_XMLUtil and C_XMLUtil.GetTemplateInfo and C_XMLUtil.GetTemplateInfo("InterfaceOptionsCheckButtonTemplate")) and "InterfaceOptionsCheckButtonTemplate" or "SettingsCheckBoxTemplate"
    local okcb, cb = pcall(CreateFrame, "CheckButton", nil, host, tmpl)
    if not okcb or not cb then cb = CreateFrame("CheckButton", nil, host, "UICheckButtonTemplate") end
    cb:SetPoint("TOPLEFT", 16, y); y = y - 26
    if cb.Text then cb.Text:SetText(label) else local fs = host:CreateFontString(nil, "OVERLAY", "GameFontHighlight") fs:SetPoint("LEFT", cb, "RIGHT", 4, 0) fs:SetText(label) end
    cb.tooltipText = tip
    cb:SetScript("OnShow", function(self) self:SetChecked(get()) end)
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    return cb
end
local function slider(label, min, max, step, get, set)
    local s = CreateFrame("Slider", nil, host, "OptionsSliderTemplate")
    s:SetPoint("TOPLEFT", 24, y - 10); y = y - 46
    s:SetMinMaxValues(min, max); s:SetValueStep(step); s:SetObeyStepOnDrag(true); s:SetWidth(200)
    s.Low:SetText(min); s.High:SetText(max)
    s:SetScript("OnShow", function(self) self:SetValue(get()) self.Text:SetText(label .. ": " .. get()) end)
    s:SetScript("OnValueChanged", function(self, v) v = math.floor(v / step + 0.5) * step set(v) self.Text:SetText(label .. ": " .. v) end)
    return s
end
local function P() return NS.db.profile end

check("Show arrow", function() return P().arrow.enabled end, function(v) P().arrow.enabled = v NS.Arrow.ApplySettings() end)
check("Lock arrow position", function() return P().arrow.lock end, function(v) P().arrow.lock = v end)
check("Lock guide window", function() return P().frame.lock end, function(v) P().frame.lock = v end)
check("Route optimizer: reorder upcoming steps by travel time", function() return P().routing.reorder end, function(v) P().routing.reorder = v NS.Progress.Refresh() end)
check("Route optimizer: use the pre-computed fastest order for quest guides", function() return P().routing.baked ~= false end, function(v)
    P().routing.baked = v
    -- the order is applied when a guide is parsed: drop the parses it changes and reload the open guide
    for _, id in ipairs(NS.Guide.list) do
        local g = NS.Guide.registry[id]
        if g and g.steps and (g.baked or (NS.RouteOrder and (NS.RouteOrder[id] or (g.part and NS.RouteOrder[g.part])))) then g.steps = nil end
    end
    if NS.Progress.guide then NS.Progress.Load(NS.Progress.guide.id) end
end, "Data/RouteOrder: each quest guide's steps solved offline for the least travel time (A before C before T, prerequisites, quest log size and level kept). Off = the guide's own order.")
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
check("Account-wide progress: count steps ANY of my characters finished (finer control: the up/down scope selector at the top of the guide list)", function() return P().accountWide end, function(v) NS.Account.SetScope(v and "account" or "char") NS.Progress.Refresh() NS.GuideMenu.UpdateScopeLabel() NS.GuideMenu.RescanCompletion() NS.GuideMenu.Refresh() end, "Completionists: leave this OFF to do every guide on every character. Turn it ON to skip content the account has already cleared.")
check("Account-wide: also match by quest ID across different guides", function() return P().accountQuests end, function(v) P().accountQuests = v NS.Progress.Refresh() end, "A quest an alt turned in clears the matching step in any guide that covers it, not just the same guide.")
check("Debug messages", function() return P().debug end, function(v) P().debug = v end)
slider("Reorder window (steps)", 3, 24, 1, function() return P().routing.window end, function(v) P().routing.window = v NS.Progress.Refresh() end)
slider("Terrain detour factor x100", 100, 200, 5, function() return math.floor((P().routing.terrainFactor or NS.CostModel.TERRAIN) * 100 + 0.5) end, function(v)
    -- OnShow's SetValue lands here too: drop the cached paths only when the factor really changed
    if P().routing.terrainFactor ~= v / 100 then P().routing.terrainFactor = v / 100 NS.TravelGraph.PathCacheWipe() end
    NS.Router.Invalidate()
end)
slider("Hearth base cost (seconds)", 10, 300, 10, function() return P().routing.hearthCost or NS.CostModel.HEARTH end, function(v)
    if (P().routing.hearthCost or NS.CostModel.HEARTH) ~= v then P().routing.hearthCost = v NS.TravelGraph.OneShotChanged() end
end)
slider("Text size: extra points", 0, 6, 1, function() return P().textSize or 2 end, function(v) P().textSize = v NS.Util.ApplyTextSize(v) end)
slider("Beacon scale x100", 50, 200, 5, function() return math.floor((P().beacon.scale or 1) * 100 + 0.5) end, function(v) P().beacon.scale = v / 100 NS.Beacon.RescanPlates() end)
slider("Arrow scale x100", 50, 200, 5, function() return math.floor((P().arrow.scale or 1) * 100 + 0.5) end, function(v) P().arrow.scale = v / 100 NS.Arrow.ApplySettings() end)
slider("Guide window scale x100", 50, 200, 5, function() return math.floor((P().frame.scale or 1) * 100 + 0.5) end, function(v) P().frame.scale = v / 100 NS.GuideFrame.ApplySettings() end)

content:SetHeight(-y + 24)

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
local at = auto:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
at:SetPoint("TOPLEFT", 16, -16); at:SetText("Auto quests")
local ad = auto:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
ad:SetPoint("TOPLEFT", at, "BOTTOMLEFT", 0, -6); ad:SetWidth(560); ad:SetJustifyH("LEFT")
ad:SetText("Accepts and turns in only the quests of the guide's next steps: never a quest you skipped, never the rest of the guide.\n"
    .. "Quests that cost gold, repeatable quests the guide does not ask for, and turn-ins with a reward choice are left to you.\n"
    .. "Slash: /cr auto [accept|turnin|reward|on|off|key shift|ctrl|alt|none]")
host, y = auto, -84
check("Auto accept the guide's quests", function() return P().autoAccept end, function(v) P().autoAccept = v end,
    "Only a quest that belongs to one of the guide's next steps, from a quest giver you are talking to.")
check("Auto turn in the guide's quests", function() return P().autoTurnin end, function(v) P().autoTurnin = v end,
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
    local fs = host:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("TOPLEFT", 20, y - 6); fs:SetText(label)
    local made, dd
    if MenuUtil and C_XMLUtil and C_XMLUtil.GetTemplateInfo and C_XMLUtil.GetTemplateInfo("WowStyle1DropdownTemplate") then
        local ok = pcall(function()
            dd = CreateFrame("DropdownButton", nil, host, "WowStyle1DropdownTemplate")
            dd:SetPoint("TOPLEFT", 260, y); dd:SetWidth(140)
            dd:SetupMenu(function(_, root)
                for _, k in ipairs(keys) do root:CreateRadio(text(k), function() return current() == k end, function() set(k) end) end
            end)
        end)
        if ok then made = dd elseif dd and dd.Hide then dd:Hide() end
    end
    if not made and UIDropDownMenu_Initialize and UIDropDownMenu_CreateInfo and UIDropDownMenu_AddButton and UIDropDownMenu_SetText then
        dd = nil
        local ok = pcall(function()
            dd = CreateFrame("Frame", "CompletionRouteAutoKeyDropDown", host, "UIDropDownMenuTemplate")
            dd:SetPoint("TOPLEFT", 244, y + 2)
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
        if ok then made = dd elseif dd and dd.Hide then dd:Hide() end
    end
    if not made then
        local b = CreateFrame("Button", nil, host, "UIPanelButtonTemplate")
        b:SetPoint("TOPLEFT", 260, y); b:SetSize(120, 22)
        local function show() b:SetText(text(current())) end
        b:SetScript("OnShow", show)
        b:SetScript("OnClick", function()
            local cur, nxt = current(), keys[1]
            for i, k in ipairs(keys) do if k == cur then nxt = keys[i % #keys + 1] end end
            set(nxt) show()
        end)
        made = b
    end
    y = y - 34
    return made
end
keyChoice("Hold to do a quest giver yourself:")

if Settings and Settings.RegisterCanvasLayoutSubcategory and category then
    O.autoCategory = Settings.RegisterCanvasLayoutSubcategory(category, auto, "Auto quests")
elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(auto)
end
