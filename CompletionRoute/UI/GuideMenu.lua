-- CompletionRoute :: UI/GuideMenu.lua
-- Zygor-style guide browser: collapsible tree of Category (type) -> area/sub-folder -> guide.
-- Zygor guides use their original folder paths (from the title); WoW-Pro guides group by zone.
-- Typing in the filter box switches to a flat search across all guides.
local ADDON, NS = ...
local U, G, P = NS.Util, NS.Guide, NS.Progress
local M = {}
NS.GuideMenu = M

local f = CreateFrame("Frame", "CompletionRouteGuideMenu", UIParent, "BackdropTemplate")
f:SetSize(460, 480)
f:SetPoint("CENTER")
f:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
f:SetBackdropColor(0.05, 0.05, 0.08, 0.95)
f:SetBackdropBorderColor(0.3, 0.6, 0.9, 0.9)
f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton"); f:SetClampedToScreen(true)
f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
f:SetFrameStrata("DIALOG")
f:Hide()
tinsert(UISpecialFrames, "CompletionRouteGuideMenu")

local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", 0, -10); title:SetText("CompletionRoute Guides")
local close = CreateFrame("Button", nil, f, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", -2, -2)

-- Scope selector: whose progress the numbers below are about.  Four settings, narrow to wide
-- (this character -> this server -> this game type -> all characters), stepped with an up/down
-- pair rather than a tick box, because it is no longer a yes/no.
local scope = CreateFrame("Frame", "CompletionRouteGuideMenuScope", f)
scope:SetSize(300, 34); scope:SetPoint("TOPLEFT", 14, -30)
scope:EnableMouse(true)
local scopeLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
scopeLabel:SetPoint("LEFT", scope, "LEFT", 34, 5)
local scopeHint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
scopeHint:SetPoint("TOPLEFT", scopeLabel, "BOTTOMLEFT", 0, -1); scopeHint:SetTextColor(0.6, 0.6, 0.6)

local function scopeIndex()
    local cur = NS.Account and NS.Account.Scope() or "char"
    for i, sc in ipairs(NS.Account.SCOPES) do if sc == cur then return i end end
    return 1
end
local function stepScope(delta)
    local list = NS.Account.SCOPES
    local i = math.min(#list, math.max(1, scopeIndex() + delta))
    NS.Account.SetScope(list[i])
    M.UpdateScopeLabel()
    M.RescanCompletion()
    if NS.Progress and NS.Progress.guide then NS.Progress.Refresh(true) end
    M.Refresh()
end

local function spinner(dir, y)
    local b = CreateFrame("Button", nil, scope)
    b:SetSize(18, 16); b:SetPoint("TOPLEFT", scope, "TOPLEFT", 2, y)
    local up = dir > 0
    b:SetNormalTexture(up and "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Up" or "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up")
    b:SetPushedTexture(up and "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Down" or "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Down")
    b:SetDisabledTexture(up and "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Disabled" or "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Disabled")
    b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    b:SetScript("OnClick", function() stepScope(dir) end)
    return b
end
-- up = wider (more characters count), down = narrower
local scopeUp = spinner(1, -1)
local scopeDown = spinner(-1, -17)

function M.UpdateScopeLabel()
    if not (NS.Account and NS.Account.SCOPES) then return end
    local sc = NS.Account.Scope()
    local colors = { char = "ffd200", realm = "7ddf8f", flavor = "ff9e3d", account = "3ec6ff" }
    scopeLabel:SetText(("|cff%s%s|r"):format(colors[sc] or "ffffff", NS.Account.ScopeLabel(sc)))
    scopeHint:SetText(NS.Account.ScopeDetail(sc))
    local i = scopeIndex()
    scopeUp:SetEnabled(i < #NS.Account.SCOPES)
    scopeDown:SetEnabled(i > 1)
end
scope:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Whose progress counts?")
    for _, sc in ipairs(NS.Account.SCOPES) do
        local cur = sc == NS.Account.Scope()
        GameTooltip:AddLine(("%s%s|r - %s"):format(cur and "|cff00ff00" or "|cffaaaaaa", NS.Account.ScopeLabel(sc), NS.Account.ScopeDetail(sc)), 1, 1, 1, true)
    end
    GameTooltip:AddLine("Widens or narrows both the counts on the right and which steps are skipped as already done.", 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
end)
scope:SetScript("OnLeave", function() GameTooltip:Hide() end)
scope:SetScript("OnMouseWheel", function(_, delta) stepScope(delta) end)
scope:EnableMouseWheel(true)

local search = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
search:SetSize(220, 20); search:SetPoint("TOPLEFT", 16, -72); search:SetAutoFocus(false)
search:SetScript("OnTextChanged", function() M.Refresh() end)
local searchLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
searchLabel:SetPoint("LEFT", search, "RIGHT", 6, 0); searchLabel:SetText("search")

local scroll = CreateFrame("ScrollFrame", "CompletionRouteGuideMenuScroll", f, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 12, -98); scroll:SetPoint("BOTTOMRIGHT", -30, 12)
local content = CreateFrame("Frame", nil, scroll)
content:SetSize(400, 10)
scroll:SetScrollChild(content)

local buttons = {}
local expanded = {}   -- [nodePath] = true

local function srcColor(src)
    if src == "CompletionRoute" then return "|cff3ec6ff" end
    if src == "WoWPro" then return "|cffff9900" end
    if src == "Zygor" then return "|cffffd200" end
    return "|cffaaaaaa"
end

-- Normalize a category segment: "LEVELING" / "Leveling Guides" -> "Leveling"; merge singular/plural
local CAT_ALIAS = { Quest = "Quests", Dungeon = "Dungeons", Reputations = "Reputation", Daily = "Dailies",
    Professions = "Profession", Title = "Titles", Event = "Events", Achievement = "Achievements" }
local function normCat(s)
    s = (s or "Other"):gsub("%s+Guides$", "")
    s = s:lower():gsub("^%l", string.upper):gsub("%s%l", string.upper)
    return CAT_ALIAS[s] or s
end

-- Category display order (Zygor-like); anything else lands after, alphabetical
local NEXT_CAT = "Next Step"
local CAT_ORDER = { [NEXT_CAT] = 0, Leveling = 1, Quests = 2, Dungeons = 3, Dailies = 4, Daily = 4, Gold = 5, Professions = 6, Profession = 6,
    Reputation = 7, Reputations = 7, Achievements = 8, Achievement = 8, Titles = 9, ["Pets & Mounts"] = 10, Events = 11 }

-- Per-category icon + tint (TBC-era icons only). Rendered inline via |T escapes.
local CAT_STYLE = {
    [NEXT_CAT] = { icon = "Interface\\Icons\\Ability_Tracking",           color = "7ddf8f" },
    Leveling   = { icon = "Interface\\Icons\\INV_Misc_Map_01",           color = "ffd200" },
    Quests     = { icon = "Interface\\GossipFrame\\AvailableQuestIcon",   color = "ffee66" },
    Dungeons   = { icon = "Interface\\Icons\\INV_Misc_Head_Dragon_01",   color = "ff6a5a" },
    Dailies    = { icon = "Interface\\Icons\\INV_Misc_Note_01",          color = "6ac9ff" },
    Gold       = { icon = "Interface\\Icons\\INV_Misc_Coin_02",          color = "ffe14d" },
    Profession = { icon = "Interface\\Icons\\Trade_BlackSmithing",       color = "ff9e3d" },
    Reputation = { icon = "Interface\\Icons\\INV_BannerPVP_02",          color = "b48cff" },
    Achievements = { icon = "Interface\\Icons\\INV_Crown_02",            color = "ffc94d" },
    Titles     = { icon = "Interface\\Icons\\INV_Crown_02",              color = "ffc94d" },
    ["Pets & Mounts"] = { icon = "Interface\\Icons\\Ability_Mount_RidingHorse", color = "7ddf8f" },
    Events     = { icon = "Interface\\Icons\\INV_Misc_Gift_01",          color = "5ad9c9" },
}
local DEFAULT_STYLE = { icon = "Interface\\Icons\\INV_Misc_QuestionMark", color = "cccccc" }
local FOLDER_ICON = "Interface\\Icons\\INV_Misc_Bag_08"
local function catStyle(name) return CAT_STYLE[name] or DEFAULT_STYLE end
local function tex(path, size) return ("|T%s:%d:%d:0:-1|t"):format(path, size or 16, size or 16) end

-- Path of a guide inside the tree: { "Leveling", "Starter Guides (1-12)" } (leaf shown separately)
local function guidePath(g)
    if (g.id or ""):find("^zygor:") then
        local segs = {}
        for seg in g.id:sub(7):gmatch("[^\\]+") do segs[#segs + 1] = seg end
        segs[#segs] = nil -- last segment is the guide itself
        if segs[1] then segs[1] = normCat(segs[1]) else segs[1] = normCat(g.type) end
        return segs
    end
    local cat = normCat(g.type)
    local area = g.zone
    if type(area) == "number" then local mi = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(area) area = mi and mi.name end
    return { cat, tostring(area or (g.source == "CompletionRoute" and "CompletionRoute" or "Other")) }
end

-- ---------------------------------------------------------------------------
-- "Next Step": everything you could do RIGHT NOW at exactly your current level.
-- A guide qualifies when its level bracket contains your level (not merely overlaps a range you
-- have outgrown), it is not already finished, and its faction/class conditions pass.  Sorted by
-- how long it takes to get there, so the top entry is the cheapest thing to do next.
-- ---------------------------------------------------------------------------
local nextCache, nextCacheLevel, nextCacheAt = nil, nil, 0
function M.NextStepGuides(force)
    local lvl = U.PlayerLevel()
    local now = GetTime and GetTime() or 0
    if not force and nextCache and nextCacheLevel == math.floor(lvl) and (now - nextCacheAt) < 30 then
        return nextCache
    end
    local out = {}
    for _, g in ipairs(G.Available()) do
        local mn, mx = g.minlevel, g.maxlevel
        -- Exact level match only: the guide must declare a bracket and that bracket must contain
        -- us. Level-agnostic guides (professions, most dungeon/reputation entries) are things you
        -- "could do" at any level, which would drown the bucket - they stay in their own category.
        -- circuits never finish, so they would sit in "Next Step" forever: they live in Gold
        local fits = not g.loop and (mn or mx) and (not mn or lvl >= mn) and (not mx or lvl <= mx + 0.99)
        if fits then
            local total = g.steps and #g.steps or nil
            local pct = 0
            if total and total > 0 and NS.Account and NS.Account.me then
                _, pct = NS.Account.GuideProgress(g.id, total, NS.Account.Scope())
            end
            if pct < 100 then out[#out + 1] = { g = g, pct = pct } end
        end
    end
    -- Cheap ordering first: tightest bracket that contains us, least-finished, our own guides
    -- first.  Only then price the top slice by travel time - G.GuideETA parses the guide, and the
    -- quest DB has thousands of them.
    local function tightness(g)
        if g.minlevel and g.maxlevel then return g.maxlevel - g.minlevel end
        return 100
    end
    table.sort(out, function(a, b)
        local ta, tb = tightness(a.g), tightness(b.g)
        if ta ~= tb then return ta < tb end
        if a.pct ~= b.pct then return a.pct > b.pct end            -- finish what you started
        local sa = a.g.source == "CompletionRoute" and 0 or 1
        local sb = b.g.source == "CompletionRoute" and 0 or 1
        if sa ~= sb then return sa < sb end
        return (a.g.name or a.g.id) < (b.g.name or b.g.id)
    end)
    local PRICED = 12
    for i = 1, math.min(PRICED, #out) do
        local ok, eta = pcall(G.GuideETA, out[i].g)
        out[i].eta = ok and eta or nil
    end
    -- re-sort only the priced head, so the cheapest thing to reach floats to the top
    local head = {}
    for i = 1, math.min(PRICED, #out) do head[i] = table.remove(out, 1) end
    table.sort(head, function(a, b)
        if (a.eta or math.huge) ~= (b.eta or math.huge) then return (a.eta or math.huge) < (b.eta or math.huge) end
        return (a.g.name or a.g.id) < (b.g.name or b.g.id)
    end)
    for i = #head, 1, -1 do table.insert(out, 1, head[i]) end
    local guides = {}
    for i, e in ipairs(out) do guides[i] = e.g e.g.__nextETA = e.eta end
    nextCache, nextCacheLevel, nextCacheAt = guides, math.floor(lvl), now
    return guides
end

-- Build tree: node = { name, path, kids = {ordered}, kidByName = {}, guides = {}, count }
local function buildTree()
    local root = { kids = {}, kidByName = {}, guides = {}, count = 0 }
    -- synthetic first category, level-matched to right now
    do
        local matched = M.NextStepGuides()
        if #matched > 0 then
            local node = { name = NEXT_CAT, path = "\\" .. NEXT_CAT, kids = {}, kidByName = {},
                           guides = matched, count = #matched, synthetic = true }
            root.kidByName[NEXT_CAT] = node
            root.kids[#root.kids + 1] = node
            root.count = root.count + #matched
        end
    end
    for _, g in ipairs(G.Available()) do
        local segs = guidePath(g)
        local node = root
        local path = ""
        for _, seg in ipairs(segs) do
            path = path .. "\\" .. seg
            local kid = node.kidByName[seg]
            if not kid then
                kid = { name = seg, path = path, kids = {}, kidByName = {}, guides = {}, count = 0 }
                node.kidByName[seg] = kid
                node.kids[#node.kids + 1] = kid
            end
            node = kid
            node.count = node.count + 1
        end
        node.guides[#node.guides + 1] = g
        root.count = root.count + 1
    end
    local function sortNode(n)
        table.sort(n.kids, function(a, b)
            local oa, ob = CAT_ORDER[a.name], CAT_ORDER[b.name]
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
local PER_FRAME = 40        -- guides per frame; ~4s for a full retail catalogue, once
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
    if finished then self:Hide() end
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
    local _, pct = NS.Account.GuideProgress(g.id, #g.steps, NS.Account.Scope())
    if not pct or pct <= 0 then return "" end
    local color = pct >= 100 and "00ff00" or "ffd200"
    return ("  |cff%s%d%%|r"):format(color, pct)
end

local function guideLabel(g, inNext)
    local eta = inNext and g.__nextETA and ("  |cff6ac9ff~%dm|r"):format(math.max(1, math.floor(g.__nextETA / 60 + 0.5))) or ""
    return ("%s%s|r%s%s%s"):format(srcColor(g.source), g.name or g.id,
        g.minlevel and ("  |cff888888[%d-%d]|r"):format(g.minlevel, g.maxlevel or g.minlevel) or "",
        pctBadge(g), eta)
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
            rows[#rows + 1] = { kind = "guide", depth = depth, guide = g, inNext = n.synthetic }
        end
    end
    walk(buildTree(), 0)
    return rows
end

local function searchRows(filter)
    local rows = {}
    for _, g in ipairs(G.Available()) do
        local hay = ((g.name or g.id) .. " " .. (g.type or "") .. " " .. tostring(g.zone or "") .. " " .. (g.source or "")):lower()
        if hay:find(filter, 1, true) then rows[#rows + 1] = { kind = "guide", depth = 0, guide = g } end
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
            b:SetHeight(20); b:SetPoint("LEFT", 0, 0); b:SetPoint("RIGHT", 0, 0)
            b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            b.text:SetPoint("LEFT", 4, 0); b.text:SetJustifyH("LEFT")
            -- right-hand completion column: "12 completed" on a category, a tick or % on a guide
            b.right = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
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
                GameTooltip:SetText(gg.name or gg.id)
                GameTooltip:AddLine("Source: " .. (gg.source or "?") .. "   Author: " .. (gg.author or "?"), 1, 1, 1)
                if gg.zone then GameTooltip:AddLine("Zone: " .. tostring(gg.zone), 1, 1, 1) end
                if gg.faction then GameTooltip:AddLine("Faction: " .. gg.faction, 1, 1, 1) end
                if gg.next then GameTooltip:AddLine("Next: " .. gg.next, 0.7, 0.7, 0.7) end
                if NS.Account and NS.Account.me then
                    local okS, st = pcall(G.Steps, gg.id)
                    local total = okS and st and #st or 0
                    if total > 0 then
                        local cn, cp = NS.Account.GuideProgress(gg.id, total, "char")
                        local an, ap = NS.Account.GuideProgress(gg.id, total, "account")
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
            if row.depth == 0 then
                local st = catStyle(row.node.name)
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
                local total = g.steps and #g.steps or nil
                local pct = 0
                if total and total > 0 and NS.Account and NS.Account.me then
                    _, pct = NS.Account.GuideProgress(g.id, total, scopeKey())
                end
                b.right:SetText(pct > 0 and ("|cffffd200%d%%|r"):format(pct) or "")
            end
        end
        b:ClearAllPoints(); b:SetPoint("TOPLEFT", 0, -y); b:SetPoint("RIGHT", 0, 0)
        b:Show()
        y = y + 20
    end
    for i = n + 1, #buttons do buttons[i]:Hide() end
    content:SetHeight(math.max(y, 10))
    local total = #G.Available()
    title:SetText(total == 0 and "CompletionRoute Guides (none registered)" or ("CompletionRoute Guides (%d)"):format(total))
end
local function openMenu()
    M.UpdateScopeLabel()
    M.Refresh()
    f:Show()
    scanFrame:Show()   -- fills in the completion column in the background
end
function M.Toggle() if f:IsShown() then f:Hide() else openMenu() end end
function M.Show() openMenu() end
-- exposed for tools/test_offline.lua (headless tree checks); not used in-game
M._test = { buildTree = buildTree, guidePath = guidePath, visibleRows = visibleRows, searchRows = searchRows, expanded = expanded,
            nodeCompletion = nodeCompletion, scanSlice = scanSlice, scanned = function() return scanned end }
