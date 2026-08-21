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
d:SetText("The completionist's guide: community-driven guides for every quest, with open travel routing.\nSlash: /cr   Guides: /cr guides   What can I do now: /cr guides -> Next Step   Debug route: /cr route")

local y = -70
local function check(label, get, set, tip)
    local tmpl = (C_XMLUtil and C_XMLUtil.GetTemplateInfo and C_XMLUtil.GetTemplateInfo("InterfaceOptionsCheckButtonTemplate")) and "InterfaceOptionsCheckButtonTemplate" or "SettingsCheckBoxTemplate"
    local okcb, cb = pcall(CreateFrame, "CheckButton", nil, panel, tmpl)
    if not okcb or not cb then cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate") end
    cb:SetPoint("TOPLEFT", 16, y); y = y - 26
    if cb.Text then cb.Text:SetText(label) else local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight") fs:SetPoint("LEFT", cb, "RIGHT", 4, 0) fs:SetText(label) end
    cb.tooltipText = tip
    cb:SetScript("OnShow", function(self) self:SetChecked(get()) end)
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    return cb
end
local function slider(label, min, max, step, get, set)
    local s = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
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
check("Pointer: hand in your class colour (off = chevron arrow)",
    function() return (P().arrow.style or "hand") == "hand" end,
    function(v) P().arrow.style = v and "hand" or "arrow" end)
check("Lock guide window", function() return P().frame.lock end, function(v) P().frame.lock = v end)
check("Route optimizer: reorder upcoming steps by travel time", function() return P().routing.reorder end, function(v) P().routing.reorder = v NS.Progress.Refresh() end)
check("Routing: use flight paths", function() return P().routing.taxi end, function(v) P().routing.taxi = v NS.Router.Invalidate() end)
check("Routing: route by every flight path your faction can use (off = only ones you have learned)", function() return NS.TravelGraph.TaxiPolicy() == "faction" end, function(v) P().routing.taxiPolicy = v and "faction" or "known" P().routing.assumeAllTaxi = nil NS.Router.Invalidate() end, "A flight you have not learned yet is labelled (new flight path); the route still walks you to the right flight master.")
check("Routing: follow roads through zones (authored + recorded paths)", function() return P().routing.roads ~= false end, function(v) P().routing.roads = v NS.TravelGraph.RebuildRoads() NS.Router.Invalidate() end)
check("Routing: record the roads I walk to improve pathing (stored in SavedVariables, shareable)", function() return P().routing.recordRoads ~= false end, function(v) P().routing.recordRoads = v end)
check("Routing: use boats / zeppelins / portals / tram", function() return P().routing.transit end, function(v) P().routing.transit = v NS.Router.Invalidate() end)
check("Routing: suggest Hearthstone when it is faster", function() return P().routing.hearth end, function(v) P().routing.hearth = v NS.Router.Invalidate() end)
check("Target beacon: marker over the head of the step's NPC / mob", function() return P().beacon.enabled end, function(v) P().beacon.enabled = v NS.Beacon.ApplySettings() end)
check("Target beacon: bob the marker up and down", function() return P().beacon.bounce end, function(v) P().beacon.bounce = v NS.Beacon.RescanPlates() end, "Turn this off for a completely still marker.")
check("Target beacon: minimap + world map pins for the step location", function() return P().beacon.pins end, function(v) P().beacon.pins = v NS.Beacon.UpdatePins() end)
check("Target beacon: one-click target button on the arrow", function() return P().beacon.targetButton end, function(v) P().beacon.targetButton = v NS.Beacon.UpdateTargetButton() end)
check("Account-wide progress: count steps ANY of my characters finished", function() return P().accountWide end, function(v) P().accountWide = v NS.Progress.Refresh() NS.GuideMenu.Refresh() end, "Completionists: leave this OFF to do every guide on every character. Turn it ON to skip content the account has already cleared.")
check("Account-wide: also match by quest ID across different guides", function() return P().accountQuests end, function(v) P().accountQuests = v NS.Progress.Refresh() end, "A quest an alt turned in clears the matching step in any guide that covers it, not just the same guide.")
check("Debug messages", function() return P().debug end, function(v) P().debug = v end)
slider("Reorder window (steps)", 3, 15, 1, function() return P().routing.window end, function(v) P().routing.window = v NS.Progress.Refresh() end)
slider("Terrain detour factor x100", 100, 200, 5, function() return math.floor((P().routing.terrainFactor or 1.25) * 100 + 0.5) end, function(v) P().routing.terrainFactor = v / 100 NS.Router.Invalidate() end)
slider("Hearth base cost (seconds)", 10, 300, 10, function() return P().routing.hearthCost or 60 end, function(v) P().routing.hearthCost = v NS.Router.Invalidate() end)
slider("Beacon scale x100", 50, 200, 5, function() return math.floor((P().beacon.scale or 1) * 100 + 0.5) end, function(v) P().beacon.scale = v / 100 NS.Beacon.RescanPlates() end)
slider("Arrow scale x100", 50, 200, 5, function() return math.floor((P().arrow.scale or 1) * 100 + 0.5) end, function(v) P().arrow.scale = v / 100 NS.Arrow.ApplySettings() end)
slider("Guide window scale x100", 50, 200, 5, function() return math.floor((P().frame.scale or 1) * 100 + 0.5) end, function(v) P().frame.scale = v / 100 NS.GuideFrame.ApplySettings() end)

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
