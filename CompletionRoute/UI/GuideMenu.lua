-- CompletionRoute :: UI/GuideMenu.lua
-- Guide browser: collapsible tree of Category (type) -> area/sub-folder -> guide.
-- Guides whose title carries a folder path use it; the rest group by zone.
-- Typing in the filter box switches to a flat search across all guides.
-- On top of the tree sits "Recent": the routes this character has finished steps in, most recently used first
-- (Core/Progress.lua P.RecentList, a small saved table: no guide is parsed for it).
-- The level box under the search field drives Core/Recommend.lua: the "Recommended" section, the "Only routes for this
-- level" filter and the "Group by level" tree all read the same cached per-level ranking, which never parses guide steps.
local ADDON, NS = ...
local U, G, P, Rec = NS.Util, NS.Guide, NS.Progress, NS.Recommend
local M = {}
NS.GuideMenu = M

local f = CreateFrame("Frame", "CompletionRouteGuideMenu", UIParent, "BackdropTemplate")
f:SetSize(480, 560)
f:SetPoint("CENTER")
f:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
f:SetBackdropColor(0.05, 0.05, 0.08, 0.95)
f:SetBackdropBorderColor(0.3, 0.6, 0.9, 0.9)
f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton"); f:SetClampedToScreen(true)
f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
f:SetFrameStrata("DIALOG")
f:Hide()
tinsert(UISpecialFrames, "CompletionRouteGuideMenu")

local title = f:CreateFontString(nil, "OVERLAY", U.Font("Large"))
title:SetPoint("TOP", 0, -10); title:SetText("Routes")
local close = CreateFrame("Button", nil, f, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", -2, -2)

-- Scope selector: whose progress the numbers below are about.  Four settings, narrow to wide (this character, this
-- server, this game type, all characters), as a row of four buttons with the chosen one lit and one line under it
-- that says in words whose progress counts.  (Until 2026-11-11 this was a coloured label with two small arrows and a
-- grey 10 pt hint; in play it read as a title, not as a setting.)
local scope = CreateFrame("Frame", "CompletionRouteGuideMenuScope", f)
scope:SetSize(452, 42); scope:SetPoint("TOPLEFT", 14, -34)
scope:EnableMouse(true)
local SCOPE_SHORT = { char = "Character", realm = "Server", flavor = "Game type", account = "Account" }
local SCOPE_RGB = { char = { 1, 0.82, 0 }, realm = { 0.49, 0.87, 0.56 }, flavor = { 1, 0.62, 0.24 }, account = { 0.24, 0.78, 1 } }
local scopeHint = f:CreateFontString(nil, "OVERLAY", U.Font("Small"))
scopeHint:SetPoint("TOPLEFT", scope, "TOPLEFT", 2, -27); scopeHint:SetPoint("RIGHT", scope, "RIGHT", -2, 0)
scopeHint:SetJustifyH("LEFT"); scopeHint:SetWordWrap(false); scopeHint:SetTextColor(0.8, 0.8, 0.8)

local function scopeIndex()
    local cur = NS.Account and NS.Account.Scope() or "char"
    for i, sc in ipairs(NS.Account.SCOPES) do if sc == cur then return i end end
    return 1
end
local function setScope(sc)
    if NS.Account.Scope() == sc then return end
    NS.Account.SetScope(sc)
    M.UpdateScopeLabel()
    M.RescanCompletion()
    if NS.Progress and NS.Progress.guide then NS.Progress.Refresh(true) end
    M.Refresh()
end
local function stepScope(delta)
    local list = NS.Account.SCOPES
    setScope(list[math.min(#list, math.max(1, scopeIndex() + delta))])
end
local function scopeTip(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Whose progress counts?")
    for _, sc in ipairs(NS.Account.SCOPES) do
        local cur = sc == NS.Account.Scope()
        GameTooltip:AddLine(("%s%s|r - %s"):format(cur and "|cff00ff00" or "|cffaaaaaa", NS.Account.ScopeLabel(sc), NS.Account.ScopeDetail(sc)), 1, 1, 1, true)
    end
    GameTooltip:AddLine("Widens or narrows both the counts on the right and which steps are skipped as already done.", 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
end

local scopeButtons = {}
local SCOPE_ORDER = { "char", "realm", "flavor", "account" }
for i, sc in ipairs(SCOPE_ORDER) do
    local b = CreateFrame("Button", nil, scope)
    b:SetSize(110, 22); b:SetPoint("TOPLEFT", scope, "TOPLEFT", (i - 1) * 114, 0)
    b.bg = b:CreateTexture(nil, "BACKGROUND"); b.bg:SetAllPoints()
    b.line = b:CreateTexture(nil, "BORDER"); b.line:SetPoint("BOTTOMLEFT"); b.line:SetPoint("BOTTOMRIGHT"); b.line:SetHeight(2)
    b.label = b:CreateFontString(nil, "OVERLAY", U.Font("Title"))
    b.label:SetPoint("CENTER", 0, 1); b.label:SetText(SCOPE_SHORT[sc])
    local hl = b:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.08)
    b.scope = sc
    b:SetScript("OnClick", function(self) setScope(self.scope) end)
    b:SetScript("OnEnter", scopeTip)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    scopeButtons[sc] = b
end

function M.UpdateScopeLabel()
    if not (NS.Account and NS.Account.SCOPES) then return end
    local cur = NS.Account.Scope()
    for sc, b in pairs(scopeButtons) do
        local c = SCOPE_RGB[sc]
        if sc == cur then
            b.bg:SetColorTexture(c[1], c[2], c[3], 0.28); b.line:SetColorTexture(c[1], c[2], c[3], 1)
            b.label:SetTextColor(1, 1, 1)
        else
            b.bg:SetColorTexture(1, 1, 1, 0.05); b.line:SetColorTexture(1, 1, 1, 0.12)
            b.label:SetTextColor(0.62, 0.62, 0.62)
        end
    end
    -- owner's wording (2026-11-12): "Includes all progress from ..." rather than "Progress counts for ..."
    local who = (cur == "char") and ((NS.Account.me and NS.Account.DisplayName(NS.Account.me)) or "this character") or NS.Account.ScopeDetail(cur)
    scopeHint:SetText("Includes all progress from " .. who .. ".")
end
scope:SetScript("OnEnter", scopeTip)
scope:SetScript("OnLeave", function() GameTooltip:Hide() end)
scope:SetScript("OnMouseWheel", function(_, delta) stepScope(delta) end)
scope:EnableMouseWheel(true)

local search = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
search:SetSize(220, 20); search:SetPoint("TOPLEFT", 18, -84); search:SetAutoFocus(false)
search:SetScript("OnTextChanged", function() M.Refresh() end)
local searchLabel = f:CreateFontString(nil, "OVERLAY", U.Font("Small"))
searchLabel:SetPoint("LEFT", search, "RIGHT", 6, 0); searchLabel:SetText("search")

-- ---------------------------------------------------------------------------
-- Level control: the level the whole list is about.  Follows your own level until you pick another; profile.guideList.
-- ---------------------------------------------------------------------------
local function listPrefs()
    local p = NS.db.profile
    p.guideList = p.guideList or { onlyLevel = false, groupByLevel = false }
    return p.guideList
end
local function myLevel() return math.floor(UnitLevel("player") or 1) end
-- the level being viewed: the typed/stepped one, or your own
function M.ViewLevel()
    local v = tonumber(listPrefs().level)
    return Rec.ClampLevel(v or myLevel())
end
-- nil (or your own level) = follow the character as it levels up
function M.SetViewLevel(v)
    local p = listPrefs()
    v = tonumber(v)
    if v then v = Rec.ClampLevel(v) end
    p.level = (v and v ~= myLevel()) and v or nil
    M.UpdateLevelControls()
    M.Refresh()
end

local levelLabel = f:CreateFontString(nil, "OVERLAY", U.Font("Small"))
levelLabel:SetPoint("TOPLEFT", 18, -113); levelLabel:SetText("Level")
local function levelStep(delta) M.SetViewLevel(M.ViewLevel() + delta) end
-- the button labels are in the addon's fonts (UI/GuideFrame.lua GF.ButtonFonts), so they follow the Text size option
local levelButtons = {}
local function smallButton(text, width, x, onClick, tip)
    local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    b:SetSize(width, 22); b:SetPoint("TOPLEFT", x, -108); b:SetText(text)
    b.minW = width
    if NS.GuideFrame and NS.GuideFrame.ButtonFonts then NS.GuideFrame.ButtonFonts(b) end
    levelButtons[#levelButtons + 1] = b
    b:SetScript("OnClick", onClick)
    if tip then
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT") GameTooltip:SetText(tip, 1, 1, 1, 1, true) GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    return b
end
smallButton("-", 24, 62, function() levelStep(-1) end, "One level lower")
local levelBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
levelBox:SetSize(36, 22); levelBox:SetPoint("TOPLEFT", 92, -108); levelBox:SetAutoFocus(false)
levelBox:SetMaxLetters(3)
if levelBox.SetNumeric then levelBox:SetNumeric(true) end
levelBox:SetScript("OnTextChanged", function(self, userInput)
    if not userInput then return end
    local n = tonumber(self:GetText())
    if n and n >= 1 then M.SetViewLevel(n) end
end)
levelBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
levelBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
levelBox:SetScript("OnEditFocusLost", function() M.UpdateLevelControls() end)
smallButton("+", 24, 134, function() levelStep(1) end, "One level higher")
local current = smallButton("Current", 70, 162, function() M.SetViewLevel(nil) end, "Back to your character's current level")
-- hung from the Current button (8 px right of it, where it always sat), so a wider label pushes it along
local levelHint = f:CreateFontString(nil, "OVERLAY", U.Font("Small"))
levelHint:SetPoint("LEFT", current, "RIGHT", 8, 0); levelHint:SetTextColor(0.75, 0.75, 0.75)

local function viewCheck(name, x, label, tip, getKey)
    local cb = CreateFrame("CheckButton", name, f, "UICheckButtonTemplate")
    cb:SetSize(24, 24); cb:SetPoint("TOPLEFT", x, -133)
    local fs = f:CreateFontString(nil, "OVERLAY", U.Font("Small"))
    fs:SetPoint("LEFT", cb, "RIGHT", 2, 0); fs:SetText(label)
    cb.label = fs
    cb:SetScript("OnClick", function(self)
        listPrefs()[getKey] = self:GetChecked() and true or false
        M.Refresh()
    end)
    cb:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT") GameTooltip:SetText(tip, 1, 1, 1, 1, true) GameTooltip:Show()
    end)
    cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return cb
end
local onlyLevel = viewCheck("CompletionRouteGuideMenuOnlyLevel", 14, "Only routes for this level",
    "Hide every route that does not fit the level in the box: its bracket contains that level, or (professions) its skill band contains your skill. Routes with no level data are hidden too.", "onlyLevel")
local GROUP_X = 262
local groupLevel = viewCheck("CompletionRouteGuideMenuGroupLevel", GROUP_X, "Group by level",
    "Show the list as level bands, then category, then route. Routes with no level data go under Any level.", "groupByLevel")

function M.UpdateLevelControls()
    if not NS.db then return end
    local v = M.ViewLevel()
    if not (levelBox.HasFocus and levelBox:HasFocus()) then levelBox:SetText(tostring(v)) end
    levelHint:SetText(v == myLevel() and "your level" or ("your level: " .. myLevel()))
    local prefs = listPrefs()
    onlyLevel:SetChecked(prefs.onlyLevel and true or false)
    groupLevel:SetChecked(prefs.groupByLevel and true or false)
    -- the labels grow with the text size: the buttons fit their labels, and the second tick box moves right of the
    -- first one's label when that runs past where it sits
    if NS.GuideFrame and NS.GuideFrame.FitButton then for _, b in ipairs(levelButtons) do NS.GuideFrame.FitButton(b) end end
    local lw = onlyLevel.label.GetStringWidth and onlyLevel.label:GetStringWidth()
    if type(lw) == "number" then
        groupLevel:ClearAllPoints()
        groupLevel:SetPoint("TOPLEFT", math.max(GROUP_X, math.ceil(14 + 24 + 2 + lw + 16)), -133)
    end
end

local scroll = CreateFrame("ScrollFrame", "CompletionRouteGuideMenuScroll", f, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 12, -162); scroll:SetPoint("BOTTOMRIGHT", -30, 12)
local content = CreateFrame("Frame", nil, scroll)
content:SetSize(420, 10)
scroll:SetScrollChild(content)

local buttons = {}
local ROW_H = 22      -- 20 px until the list text grew from 10 pt to 12 pt
local expanded = {}   -- [nodePath] = true
-- "Recommended" starts open: the closest routes that fit your level
local REC_PATH = "\\Recommended"
expanded[REC_PATH] = true
-- "Recent" starts open too: it is what the player came back for
local RECENT_PATH = "\\Recent"
expanded[RECENT_PATH] = true

local function srcColor(src)
    if src == "CompletionRoute" then return "|cff3ec6ff" end
    return "|cffaaaaaa"
end

-- Normalize a category segment: "LEVELING" / "Leveling Guides" -> "Leveling"; merge singular/plural
local CAT_ALIAS = { Quest = "Quests", Dungeon = "Dungeons", Reputations = "Reputation", Daily = "Dailies",
    Profession = "Professions", Title = "Titles", Event = "Events", Achievement = "Achievements" }
local function normCat(s)
    s = (s or "Other"):gsub("%s+Guides$", "")
    s = s:lower():gsub("^%l", string.upper):gsub("%s%l", string.upper)
    return CAT_ALIAS[s] or s
end

-- Category display order; anything else lands after, alphabetical
local REC_CAT = "Recommended"     -- style key; the row reads "Recommended" (or "Recommended for level N")
local RECENT_CAT = "Recent"
local CAT_ORDER = { [RECENT_CAT] = -2, [REC_CAT] = 0, Leveling = 1, Quests = 2, Dungeons = 3, Dailies = 4, Daily = 4, Gold = 5, Professions = 6, Profession = 6,
    Reputation = 7, Reputations = 7, Achievements = 8, Achievement = 8, Titles = 9, ["Pets & Mounts"] = 10, Events = 11 }

-- Per-category icon + tint (TBC-era icons only). Rendered inline via |T escapes.
local CAT_STYLE = {
    [RECENT_CAT] = { icon = "Interface\\Icons\\INV_Misc_PocketWatch_01", color = "9fd0ff" },
    [REC_CAT]  = { icon = "Interface\\Icons\\Ability_Tracking",           color = "7ddf8f" },
    Leveling   = { icon = "Interface\\Icons\\INV_Misc_Map_01",           color = "ffd200" },
    Quests     = { icon = "Interface\\GossipFrame\\AvailableQuestIcon",   color = "ffee66" },
    Dungeons   = { icon = "Interface\\Icons\\INV_Misc_Head_Dragon_01",   color = "ff6a5a" },
    Dailies    = { icon = "Interface\\Icons\\INV_Misc_Note_01",          color = "6ac9ff" },
    Gold       = { icon = "Interface\\Icons\\INV_Misc_Coin_02",          color = "ffe14d" },
    Professions = { icon = "Interface\\Icons\\Trade_BlackSmithing",       color = "ff9e3d" },
    Reputation = { icon = "Interface\\Icons\\INV_BannerPVP_02",          color = "b48cff" },
    Achievements = { icon = "Interface\\Icons\\INV_Crown_02",            color = "ffc94d" },
    Titles     = { icon = "Interface\\Icons\\INV_Crown_02",              color = "ffc94d" },
    ["Pets & Mounts"] = { icon = "Interface\\Icons\\Ability_Mount_RidingHorse", color = "7ddf8f" },
    Events     = { icon = "Interface\\Icons\\INV_Misc_Gift_01",          color = "5ad9c9" },
    Band       = { icon = "Interface\\Icons\\INV_Misc_Map_01",           color = "cfe3ff" },
}
local DEFAULT_STYLE = { icon = "Interface\\Icons\\INV_Misc_QuestionMark", color = "cccccc" }
local FOLDER_ICON = "Interface\\Icons\\INV_Misc_Bag_08"
local function catStyle(name) return CAT_STYLE[name] or DEFAULT_STYLE end
local function tex(path, size) return ("|T%s:%d:%d:0:-1|t"):format(path, size or 16, size or 16) end

-- Path of a guide inside the tree: { "Leveling", "Starter Guides (1-12)" } (leaf shown separately)
local function guidePath(g)
    local cat = normCat(g.type)
    -- g.folder overrides the zone folder (the generated leveling spine lists its guides under "Leveling (generated)")
    local area = g.folder or g.goldKind or g.prof or g.zone
    if type(area) == "number" then local mi = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(area) area = mi and mi.name end
    return { cat, tostring(area or (g.source == "CompletionRoute" and "CompletionRoute" or "Other")) }
end

-- ---------------------------------------------------------------------------
-- "Recommended" (owner's request, 2026-11-12; it replaced the "For level N" section of per-category picks): the quest
-- routes that fit the level in the box and that this character has not finished, CLOSEST FIRST.  Closeness is the
-- travel time from where you stand to the route's zone, all of them priced by one graph search (Router.TravelRow); a
-- route in the zone you are in, or in a zone that contains it, counts as 0, and the first REC_PRICED are priced again
-- to their first step (that parses those guides).  A spine part and the zone guide it is made from are one entry (the
-- spine one: it chains on to the next route).  Gold, profession, dungeon and other routes stay in their own folders.
-- Cached for 30 s and until the level, your zone or the guide list changes.
-- ---------------------------------------------------------------------------
local REC_SHOWN, REC_PRICED = 10, 6
local REC_TYPES = { Leveling = true, Quests = true }
local REC_WIDE = 20       -- a zone route the leveling chain does not place, wider than this many levels, is not a pick
local recCache = { key = nil, at = -1e9, list = {} }

-- [zone guide id] = { spine guide, ... } of the leveling chain(s) this character can follow.  The chain places every
-- zone part in a level band.  A zone route's own range can be misleading: a "both factions" zone route spans every
-- level its neutral quests have ("Winterspring Quests 1-60", which the chain puts at 54-60), so Recommended asks the
-- chain (owner's report, 2026-11-12: a new character was offered Winterspring and Duskwood).
local spineOf, spineN = {}, -1
local function spineParts()
    if spineN == #G.list then return spineOf end
    spineOf, spineN = {}, #G.list
    local Cond = NS.Cond
    for _, id in ipairs(G.list) do
        local g = G.registry[id]
        if g and g.part and (not Cond or not Cond.FactionMatch or Cond.FactionMatch(g.faction)) then
            local l = spineOf[g.part]
            if not l then l = {} spineOf[g.part] = l end
            l[#l + 1] = g
        end
    end
    return spineOf
end
local function placedFor(g, level)
    local sp = spineParts()[g.id]
    if sp then
        for _, s in ipairs(sp) do
            if (s.minlevel or 0) <= level and level <= (s.maxlevel or 999) then return true end
        end
        return false
    end
    return ((g.maxlevel or level) - (g.minlevel or level)) <= REC_WIDE
end

-- the name a Recommended row shows: no level range and no chain number ("002. Zephras Isle Quests 1-5" ->
-- "Zephras Isle Quests"); the tooltip still has the full name
local function recName(g)
    local n = G.DisplayName(g)
    n = (n:gsub("^%d+%.%s+", ""))
    n = (n:gsub("%s+%d+%s*%-%s*%d+", ""))
    n = (n:gsub("(Quests)%s+%d+", "%1"))
    return n
end
M.RecName = recName

local function zoneWorld(mid)
    local HBD = NS.HBD
    if not (mid and HBD) then return nil end
    local x, y = 0.5, 0.5
    if U.EraToForever then x, y = U.EraToForever(mid, 0.5, 0.5) end
    local ok, wx, wy, inst = pcall(HBD.GetWorldCoordinatesFromZone, HBD, x, y, mid)
    if ok and wx then return { wx = wx, wy = wy, inst = inst } end
end

-- the player's map and every map that contains it: a route in any of them is "here"
local function hereMaps(map)
    local out, guard = {}, 0
    while map and map ~= 0 and guard < 6 do
        out[map] = true
        local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(map)
        map = info and info.parentMapID
        guard = guard + 1
    end
    return out
end

-- where a route stands in the leveling chain (spine ids end in its number), else after every chain route
local function chainIndex(g) return tonumber(tostring(g.id):match("^spine:.-:(%d+)$")) or math.huge end
local function byCloseness(x, y)
    local ex, ey = x.eta or math.huge, y.eta or math.huge
    if ex ~= ey then return ex < ey end
    local cx, cy = chainIndex(x.g), chainIndex(y.g)
    if cx ~= cy then return cx < cy end
    if x.score ~= y.score then return x.score > y.score end
    return (x.g.name or x.g.id) < (y.g.name or y.g.id)
end

-- { guide, ... }, closest first (each guide's g.__nextETA = its travel seconds, nil when unknown)
function M.Recommended(level, force)
    level = level or M.ViewLevel()
    local map = U.PlayerPos()
    local now = GetTime and GetTime() or 0
    local key = table.concat({ level, tostring(map), #G.list, (NS.Account and NS.Account.Scope and NS.Account.Scope()) or "" }, "|")
    if not force and recCache.key == key and (now - recCache.at) < 30 then return recCache.list end
    local cands, seen = {}, {}
    local parked = P and P.ParkedWaiting
    for _, e in ipairs(Rec.ForLevel(level)) do
        local g = e.g
        if e.fit and not e.finished and REC_TYPES[e.cat] and not (parked and parked(g.id))
            and (e.cat ~= "Quests" or placedFor(g, level)) then
            local k = g.part or g.id
            local at = seen[k]
            if not at then
                seen[k] = #cands + 1
                cands[#cands + 1] = { g = g, score = e.score }
            elseif e.cat == "Leveling" and cands[at].g.type ~= "Leveling" then
                cands[at].g = g
            end
        end
    end
    -- closeness by zone, one search for all
    local here = hereMaps(map)
    local R = NS.Router
    local a = R and R.PlayerPoint and R.PlayerPoint()
    local goals, goalOf, byZone = {}, {}, {}
    for i, c in ipairs(cands) do
        local z = tonumber(c.g.zone)
        if z and here[z] then
            c.eta = 0
        elseif z then
            local gi = byZone[z]
            if gi == nil then
                local w = zoneWorld(z)
                if w then goals[#goals + 1] = w gi = #goals else gi = false end
                byZone[z] = gi
            end
            if gi then goalOf[i] = gi end
        end
    end
    if a and #goals > 0 and R.TravelRow then
        local ok, res = pcall(R.TravelRow, a, goals)
        if ok and res then for i, gi in pairs(goalOf) do cands[i].eta = res[gi] end end
    end
    table.sort(cands, byCloseness)
    -- the first few, priced again to their first step (one more search for all of them): inside one zone that decides
    -- which part is nearest
    if a and R.TravelRow and R.StepWorld and G.GuideStart then
        local pts, at = {}, {}
        for i = 1, math.min(REC_PRICED, #cands) do
            local ok, s0 = pcall(G.GuideStart, cands[i].g)
            if ok and s0 then
                local wx, wy, inst = R.StepWorld(s0)
                if wx then pts[#pts + 1] = { wx = wx, wy = wy, inst = inst } at[#at + 1] = i end
            end
        end
        if #pts > 0 then
            local ok, res = pcall(R.TravelRow, a, pts)
            if ok and res then for j, i in ipairs(at) do if res[j] then cands[i].eta = res[j] end end end
        end
    end
    table.sort(cands, byCloseness)
    -- one row per shown name: without its range and faction tag, a zone's neutral part and its faction part read the
    -- same ("Zephras Isle Quests"); the one the chain does first stays, the other follows when it is done
    local list, shown = {}, {}
    for _, c in ipairs(cands) do
        if #list >= REC_SHOWN then break end
        local nm = recName(c.g)
        if not shown[nm] then
            shown[nm] = true
            list[#list + 1] = c.g
            c.g.__nextETA = c.eta
        end
    end
    recCache.key, recCache.at, recCache.list = key, now, list
    return list
end
-- the old name (tools and tests): the recommended routes for the level in the box
function M.NextStepGuides(force) return M.Recommended(M.ViewLevel(), force) end

-- Build tree: node = { name, path, kids = {ordered}, kidByName = {}, guides = {}, count }
local function buildTree()
    local root = { kids = {}, kidByName = {}, guides = {}, count = 0 }
    local level, prefs = M.ViewLevel(), listPrefs()
    local fit = prefs.onlyLevel and Rec.FitSet(level) or nil
    -- synthetic top section: the routes this character has finished steps in, most recently used first.  Hidden when
    -- there are none; never filtered by level (it is a way back, not a recommendation).
    do
        local recent = P.RecentList and P.RecentList() or {}
        if #recent > 0 then
            local node = { name = RECENT_CAT, path = RECENT_PATH, kids = {}, kidByName = {}, guides = {}, count = #recent,
                           synthetic = true, recent = true, styleKey = RECENT_CAT, order = -2 }
            for i, r in ipairs(recent) do node.guides[i] = r.g end
            root.kidByName[RECENT_CAT] = node
            root.kids[#root.kids + 1] = node
            root.count = root.count + node.count
        end
    end
    -- synthetic second category: the closest routes that fit the level in the box
    do
        local recs = M.Recommended(level)
        if #recs > 0 then
            local label = (level == myLevel()) and REC_CAT or (REC_CAT .. " for level " .. level)
            local node = { name = label, path = REC_PATH, kids = {}, kidByName = {}, guides = recs, count = #recs,
                           synthetic = true, recommended = true, styleKey = REC_CAT, order = -1 }
            root.kidByName[label] = node
            root.kids[#root.kids + 1] = node
            root.count = root.count + node.count
        end
    end
    local grouped = prefs.groupByLevel
    for _, g in ipairs(G.Available()) do
        if not fit or fit[g.id] then
            local segs, order
            if grouped then
                -- band, then category, then the guide itself (no zone folder: the band is what you came for)
                local low, _, label = Rec.BandFor(g, level)
                segs, order = { label or "Any level", normCat(g.type) }, { low or 100000 }
            else
                segs = guidePath(g)
            end
            local node = root
            local path = grouped and "\\Bands" or ""
            for i, seg in ipairs(segs) do
                path = path .. "\\" .. seg
                local kid = node.kidByName[seg]
                if not kid then
                    kid = { name = seg, path = path, kids = {}, kidByName = {}, guides = {}, count = 0,
                            order = order and order[i], styleKey = grouped and (i == 1 and "Band" or seg) or nil }
                    node.kidByName[seg] = kid
                    node.kids[#node.kids + 1] = kid
                end
                node = kid
                node.count = node.count + 1
            end
            node.guides[#node.guides + 1] = g
            root.count = root.count + 1
        end
    end
    local function sortNode(n)
        table.sort(n.kids, function(a, b)
            local oa, ob = a.order or CAT_ORDER[a.name], b.order or CAT_ORDER[b.name]
            if oa or ob then return (oa or 99) < (ob or 99) end
            -- sort "X (10-20)" style folders by their level, else alphabetically
            local la = tonumber(a.name:match("%((%d+)%-")) local lb = tonumber(b.name:match("%((%d+)%-"))
            if la and lb and la ~= lb then return la < lb end
            return a.name < b.name
        end)
        if n.synthetic then for _, k in ipairs(n.kids) do sortNode(k) end return end
        table.sort(n.guides, function(a, b)
            if (a.minlevel or 999) ~= (b.minlevel or 999) then return (a.minlevel or 999) < (b.minlevel or 999) end
            return (a.name or a.id) < (b.name or b.id)
        end)
        for _, k in ipairs(n.kids) do sortNode(k) end
    end
    sortNode(root)
    return root
end

-- ---------------------------------------------------------------------------
-- Completion counts on the right of every row.
-- Deciding whether a guide is finished means parsing its steps and comparing the quests it turns in
-- against what has been done — far too slow to do for thousands of guides inside a Refresh (the list
-- rebuilds on every keystroke). So it runs as a background scan, a slice per frame, while the menu
-- is open; rows show "..." until their guide has been scanned, and the answers are cached.
-- ---------------------------------------------------------------------------
local scanned = {}          -- [guideid] = true|false (complete for the CURRENT scope)
local scanQueue, scanPos = nil, 1
local scanFrame = CreateFrame("Frame")
local PER_FRAME = 40        -- most guides per frame
-- ...and a time budget: under the client's plain Lua 5.1 forty guides cost 30-60 ms a frame (measured 2026-11-11, p95
-- 127 ms on MoP and 211 ms on Retail), a visible stutter for as long as the list scans.  A slice now stops after
-- SCAN_MS; one guide is always done, so a single huge guide can still overrun it.
local SCAN_MS = 4
local clock = debugprofilestop or function() return os.clock() * 1000 end
local scanDirty = false

local function scopeKey() return (NS.Account and NS.Account.Scope()) or "char" end

function M.RescanCompletion()
    scanned = {}
    scanQueue, scanPos = nil, 1
    scanFrame:Show()
end

local function scanSlice()
    if not (NS.Account and NS.Account.me) then return true end
    if not scanQueue then scanQueue, scanPos = G.Available(), 1 end
    local sk = scopeKey()
    local active = P.guide and P.guide.id
    local t0 = clock()
    for _ = 1, PER_FRAME do
        local g = scanQueue[scanPos]
        if not g then scanQueue = nil return true end
        scanPos = scanPos + 1
        if scanned[g.id] == nil then
            local hadSteps = g.steps ~= nil
            local ok, res = pcall(NS.Account.GuideIsComplete, g, sk)
            scanned[g.id] = ok and res or false
            -- do not hold on to step tables we only parsed to answer this question
            if not hadSteps and g.id ~= active and g.steps then g.steps = nil end
            scanDirty = true
            if clock() - t0 >= SCAN_MS then break end
        end
    end
    return false
end

scanFrame:SetScript("OnUpdate", function(self)
    if not f:IsShown() then self:Hide() return end
    local finished = scanSlice()
    if scanDirty then
        scanDirty = false
        NS:Throttle("guidemenu-scan", 0.25, function() if f:IsShown() then M.Refresh() end end)
    end
    if finished then
        self:Hide()
        Rec.Invalidate()   -- finished guides rank last, and the ranking reads the answers this scan just produced
    end
end)
scanFrame:Hide()

-- how many guides under this node are finished, and how many are still unscanned
local function nodeCompletion(node)
    local done, total, pending = 0, 0, 0
    local function walk(n)
        for _, g in ipairs(n.guides) do
            total = total + 1
            local v = scanned[g.id]
            if v == nil then pending = pending + 1 elseif v then done = done + 1 end
        end
        for _, k in ipairs(n.kids) do walk(k) end
    end
    walk(node)
    return done, total, pending
end

-- steps of a parsed guide as this character sees it (rebuilt without skipped quests, Core/Skip.lua), and the author
-- indices it keeps (nil = all of them)
local function viewOf(g)
    if NS.Skip then return NS.Skip.ViewOf(g) end
    return g.steps and #g.steps or nil, nil
end

-- completion badge, but only for guides whose steps are already parsed (never force a parse here:
-- the quest DB has thousands of guides and the list refreshes on every keystroke)
local function pctBadge(g)
    -- a circuit is never "83% complete": show the laps you have walked and what they were worth
    if g.loop then
        local laps = (NS.Progress and NS.Progress.Lap and NS.Progress.Lap(g.id)) or 0
        local st = NS.Farm and NS.Farm.Stats and NS.Farm.Stats(g.id)
        if st then return ("  |cffffd200%d lap%s, %s/hr|r"):format(laps, laps == 1 and "" or "s", NS.Util.FmtMoney(st.perHour)) end
        return laps > 0 and ("  |cffffd200%d lap%s|r"):format(laps, laps == 1 and "" or "s") or "  |cff6ac9ffcircuit|r"
    end
    if not (NS.Account and NS.Account.me) then return "" end
    local _, who = NS.Account.GuideCompletedBy(g)
    if who then return ("  |cff00ff00(%s)|r"):format(who) end
    if not g.steps then return "" end
    -- a guide rebuilt without skipped quests (Core/Skip.lua) counts only the steps it still has
    local total, keep = viewOf(g)
    local _, pct = NS.Account.GuideProgress(g.id, total, NS.Account.Scope(), keep)
    if not pct or pct <= 0 then return "" end
    local color = pct >= 100 and "00ff00" or "ffd200"
    return ("  |cff%s%d%%|r"):format(color, pct)
end

-- Percent done of a route that is not parsed, from what was saved when it was last loaded (P.RecentRecord: its step
-- total) and this character's marks.  nil when the route was never loaded on this character.
local function savedPct(g)
    local rec = P.RecentRecord and P.RecentRecord(g.id)
    if not (rec and rec.n and rec.n > 0) then return nil end
    local done = math.min(P.MarkCount(g.id), rec.n)
    return math.floor(done / rec.n * 100 + 0.5)
end

local function guideLabel(g, inNext)
    local eta = ""
    if inNext and g.__nextETA then
        eta = g.__nextETA < 45 and "  |cff6ac9ffnearby|r" or ("  |cff6ac9ff~%dm|r"):format(math.max(1, math.floor(g.__nextETA / 60 + 0.5)))
    end
    -- Recommended rows (inNext) show no level range: the owner asked for that (2026-11-12)
    local band = inNext and "" or Rec.GuideLabel(g)
    local entry = Rec.EntryFor(M.ViewLevel(), g.id)
    local needs = (entry and entry.missing) and ("  |cffff9900needs %s|r"):format(entry.missing) or ""
    return ("%s%s|r%s%s%s%s"):format(srcColor(g.source), inNext and recName(g) or G.DisplayName(g),
        band ~= "" and ("  |cff888888%s|r"):format(band) or "", needs, pctBadge(g), eta)
end

-- Flatten visible tree into rows: { kind = "node"|"guide", depth, node|guide }
local function visibleRows()
    local rows = {}
    local function walk(n, depth)
        for _, k in ipairs(n.kids) do
            rows[#rows + 1] = { kind = "node", depth = depth, node = k }
            if expanded[k.path] then walk(k, depth + 1) end
        end
        for _, g in ipairs(n.guides) do
            rows[#rows + 1] = { kind = "guide", depth = depth, guide = g, inNext = n.synthetic and not n.recent }
        end
    end
    walk(buildTree(), 0)
    return rows
end

local function searchRows(filter)
    local rows = {}
    local fit = listPrefs().onlyLevel and Rec.FitSet(M.ViewLevel()) or nil
    for _, g in ipairs(G.Available()) do
        if not fit or fit[g.id] then
            local hay = ((g.name or g.id) .. " " .. (g.type or "") .. " " .. tostring(g.zone or "") .. " " .. (g.source or "")):lower()
            if hay:find(filter, 1, true) then rows[#rows + 1] = { kind = "guide", depth = 0, guide = g } end
        end
    end
    table.sort(rows, function(a, b)
        if (a.guide.minlevel or 999) ~= (b.guide.minlevel or 999) then return (a.guide.minlevel or 999) < (b.guide.minlevel or 999) end
        return (a.guide.name or a.guide.id) < (b.guide.name or b.guide.id)
    end)
    return rows
end

function M.Refresh()
    local filter = (search:GetText() or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local rows = filter ~= "" and searchRows(filter) or visibleRows()
    local y, n = 0, 0
    for _, row in ipairs(rows) do
        n = n + 1
        local b = buttons[n]
        if not b then
            b = CreateFrame("Button", nil, content)
            b:SetHeight(ROW_H); b:SetPoint("LEFT", 0, 0); b:SetPoint("RIGHT", 0, 0)
            b.text = b:CreateFontString(nil, "OVERLAY", U.Font("Small"))
            b.text:SetPoint("LEFT", 4, 0); b.text:SetJustifyH("LEFT")
            b.text:SetWordWrap(false)   -- a long name plus its band and "needs" tags must not wrap onto the next 20 px row
            -- right-hand completion column: "12 completed" on a category, a tick or % on a guide
            b.right = b:CreateFontString(nil, "OVERLAY", U.Font("Small"))
            b.right:SetPoint("RIGHT", -6, 0); b.right:SetJustifyH("RIGHT")
            b.hl = b:CreateTexture(nil, "HIGHLIGHT"); b.hl:SetAllPoints(); b.hl:SetColorTexture(1, 1, 1, 0.1)
            b:SetScript("OnClick", function(self)
                if self.nodePath then
                    expanded[self.nodePath] = not expanded[self.nodePath] or nil
                    M.Refresh()
                elseif self.gid then P.Load(self.gid) f:Hide() end
            end)
            b:SetScript("OnEnter", function(self)
                if not self.gid then return end
                local gg = G.registry[self.gid]
                if not gg then return end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(G.DisplayName(gg))
                GameTooltip:AddLine("Source: " .. (gg.source or "?") .. "   Author: " .. (gg.author or "?"), 1, 1, 1)
                for _, line in ipairs(Rec.Describe(gg, M.ViewLevel())) do GameTooltip:AddLine(line, 1, 0.82, 0, true) end
                if gg.zone then GameTooltip:AddLine("Zone: " .. tostring(gg.zone), 1, 1, 1) end
                if gg.faction then GameTooltip:AddLine("Faction: " .. gg.faction, 1, 1, 1) end
                if gg.next then GameTooltip:AddLine("Next: " .. gg.next, 0.7, 0.7, 0.7) end
                if NS.Account and NS.Account.me then
                    local okS, st = pcall(G.Steps, gg.id)
                    local total = okS and st and #st or 0
                    local keep
                    if total > 0 then total, keep = viewOf(gg) end
                    if total > 0 then
                        local cn, cp = NS.Account.GuideProgress(gg.id, total, "char", keep)
                        local an, ap = NS.Account.GuideProgress(gg.id, total, "account", keep)
                        GameTooltip:AddLine(("This character: %d/%d (%d%%)"):format(cn, total, cp), 1, 0.82, 0)
                        GameTooltip:AddLine(("Whole account: %d/%d (%d%%)"):format(an, total, ap), 0.25, 0.78, 1)
                        GameTooltip:AddLine("Counting: " .. NS.Account.ScopeLabel() .. " (" .. NS.Account.ScopeDetail() .. ")", 0.6, 0.6, 0.6, true)
                    end
                end
                GameTooltip:Show()
            end)
            b:SetScript("OnLeave", function() GameTooltip:Hide() end)
            buttons[n] = b
        end
        local indent = 4 + row.depth * 14
        -- re-anchor from scratch: SetPoint stacks, and the label has to end where the count begins
        b.text:ClearAllPoints()
        b.text:SetPoint("LEFT", indent, 0)
        b.text:SetPoint("RIGHT", b.right, "LEFT", -8, 0)
        if row.kind == "node" then
            b.nodePath, b.gid = row.node.path, nil
            local mark = expanded[row.node.path] and "|cffaaaaaa[-]|r " or "|cffaaaaaa[+]|r "
            if row.depth == 0 or row.node.styleKey then
                local st = catStyle(row.node.styleKey or row.node.name)
                b.text:SetText(("%s%s |cff%s%s|r  |cff666666(%d)|r"):format(mark, tex(st.icon, 16), st.color, row.node.name, row.node.count))
            else
                b.text:SetText(("%s%s |cffffffff%s|r  |cff666666(%d)|r"):format(mark, tex(FOLDER_ICON, 14), row.node.name, row.node.count))
            end
            local cdone, ctotal, cpending = nodeCompletion(row.node)
            if cpending > 0 and cdone == 0 then
                b.right:SetText("|cff666666...|r")
            elseif cdone == 0 then
                b.right:SetText("|cff6666660 completed|r")
            else
                b.right:SetText(("|cff%s%d completed|r%s"):format(cdone >= ctotal and "00ff00" or "ffd200",
                    cdone, cpending > 0 and " |cff666666+|r" or ""))
            end
        else
            local g = row.guide
            b.nodePath, b.gid = nil, g.id
            -- in flat search results the tree context is gone, so show the category icon per guide
            local prefix = filter ~= "" and (tex(catStyle(normCat(g.type)).icon, 14) .. " ") or ""
            b.text:SetText(prefix .. guideLabel(g, row.inNext) .. (P.guide and P.guide.id == g.id and "  |cff00ff00(active)|r" or ""))
            local v = scanned[g.id]
            if g.loop then b.right:SetText((g.farm and g.farm.nodes) and ("|cff6ac9ff%d stops|r"):format(g.farm.nodes) or "|cff6ac9ffloop|r")
            elseif v == nil then b.right:SetText("|cff666666...|r")
            elseif v then b.right:SetText("|cff00ff00completed|r")
            else
                local total, keep = viewOf(g)
                local pct = 0
                if total and total > 0 and NS.Account and NS.Account.me then
                    _, pct = NS.Account.GuideProgress(g.id, total, scopeKey(), keep)
                elseif not total then
                    -- not parsed (the scan lets go of the steps it read): a route this character has played still
                    -- shows how far it got, from its saved step total
                    pct = savedPct(g) or 0
                end
                b.right:SetText(pct > 0 and ("|cffffd200%d%%|r"):format(pct) or "")
            end
        end
        b:ClearAllPoints(); b:SetPoint("TOPLEFT", 0, -y); b:SetPoint("RIGHT", 0, 0)
        b:Show()
        y = y + ROW_H
    end
    for i = n + 1, #buttons do buttons[i]:Hide() end
    content:SetHeight(math.max(y, 10))
    local total = #G.Available()
    title:SetText(total == 0 and "Routes (none registered)" or ("Routes (%d)"):format(total))
end
local function openMenu()
    M.UpdateScopeLabel()
    M.UpdateLevelControls()
    M.Refresh()
    f:Show()
    scanFrame:Show()   -- fills in the completion column in the background
end
function M.Toggle() if f:IsShown() then f:Hide() else openMenu() end end
function M.Show() openMenu() end
-- exposed for tools/test_offline.lua (headless tree checks); not used in-game
M._test = { buildTree = buildTree, guidePath = guidePath, visibleRows = visibleRows, searchRows = searchRows, expanded = expanded,
            nodeCompletion = nodeCompletion, scanSlice = scanSlice, scanned = function() return scanned end,
            prefs = listPrefs, levelBox = levelBox, onlyLevel = onlyLevel, groupLevel = groupLevel, REC_PATH = REC_PATH,
            RECENT_PATH = RECENT_PATH, savedPct = savedPct, title = title, buttons = buttons }
