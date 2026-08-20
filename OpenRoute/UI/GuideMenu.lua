-- OpenRoute :: UI/GuideMenu.lua
-- Zygor-style guide browser: collapsible tree of Category (type) -> area/sub-folder -> guide.
-- Zygor guides use their original folder paths (from the title); WoW-Pro guides group by zone.
-- Typing in the filter box switches to a flat search across all guides.
local ADDON, NS = ...
local U, G, P = NS.Util, NS.Guide, NS.Progress
local M = {}
NS.GuideMenu = M

local f = CreateFrame("Frame", "OpenRouteGuideMenu", UIParent, "BackdropTemplate")
f:SetSize(460, 480)
f:SetPoint("CENTER")
f:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
f:SetBackdropColor(0.05, 0.05, 0.08, 0.95)
f:SetBackdropBorderColor(0.3, 0.6, 0.9, 0.9)
f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton"); f:SetClampedToScreen(true)
f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
f:SetFrameStrata("DIALOG")
f:Hide()
tinsert(UISpecialFrames, "OpenRouteGuideMenu")

local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", 0, -10); title:SetText("OpenRoute Guides")
local close = CreateFrame("Button", nil, f, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", -2, -2)

local search = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
search:SetSize(220, 20); search:SetPoint("TOPLEFT", 16, -36); search:SetAutoFocus(false)
search:SetScript("OnTextChanged", function() M.Refresh() end)
local searchLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
searchLabel:SetPoint("LEFT", search, "RIGHT", 6, 0); searchLabel:SetText("search")

local scroll = CreateFrame("ScrollFrame", "OpenRouteGuideMenuScroll", f, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 12, -62); scroll:SetPoint("BOTTOMRIGHT", -30, 12)
local content = CreateFrame("Frame", nil, scroll)
content:SetSize(400, 10)
scroll:SetScrollChild(content)

local buttons = {}
local expanded = {}   -- [nodePath] = true

local function srcColor(src)
    if src == "OpenRoute" then return "|cff3ec6ff" end
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
local CAT_ORDER = { Leveling = 1, Quests = 2, Dungeons = 3, Dailies = 4, Daily = 4, Gold = 5, Professions = 6, Profession = 6,
    Reputation = 7, Reputations = 7, Achievements = 8, Achievement = 8, Titles = 9, ["Pets & Mounts"] = 10, Events = 11 }

-- Per-category icon + tint (TBC-era icons only). Rendered inline via |T escapes.
local CAT_STYLE = {
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
    return { cat, tostring(area or (g.source == "OpenRoute" and "OpenRoute" or "Other")) }
end

-- Build tree: node = { name, path, kids = {ordered}, kidByName = {}, guides = {}, count }
local function buildTree()
    local root = { kids = {}, kidByName = {}, guides = {}, count = 0 }
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
        table.sort(n.guides, function(a, b)
            if (a.minlevel or 999) ~= (b.minlevel or 999) then return (a.minlevel or 999) < (b.minlevel or 999) end
            return (a.name or a.id) < (b.name or b.id)
        end)
        for _, k in ipairs(n.kids) do sortNode(k) end
    end
    sortNode(root)
    return root
end

-- completion badge, but only for guides whose steps are already parsed (never force a parse here:
-- the quest DB has thousands of guides and the list refreshes on every keystroke)
local function pctBadge(g)
    if not (NS.Account and NS.Account.me) or not g.steps then return "" end
    local scope = NS.db.profile.accountWide and "account" or "char"
    local _, pct = NS.Account.GuideProgress(g.id, #g.steps, scope)
    if not pct or pct <= 0 then return "" end
    local color = pct >= 100 and "00ff00" or "ffd200"
    return ("  |cff%s%d%%|r"):format(color, pct)
end

local function guideLabel(g)
    return ("%s%s|r%s%s"):format(srcColor(g.source), g.name or g.id,
        g.minlevel and ("  |cff888888[%d-%d]|r"):format(g.minlevel, g.maxlevel or g.minlevel) or "",
        pctBadge(g))
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
            rows[#rows + 1] = { kind = "guide", depth = depth, guide = g }
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
                        if not NS.db.profile.accountWide then
                            GameTooltip:AddLine("Account-wide skipping is OFF (/or accountwide)", 0.6, 0.6, 0.6)
                        end
                    end
                end
                GameTooltip:Show()
            end)
            b:SetScript("OnLeave", function() GameTooltip:Hide() end)
            buttons[n] = b
        end
        local indent = 4 + row.depth * 14
        b.text:SetPoint("LEFT", indent, 0)
        if row.kind == "node" then
            b.nodePath, b.gid = row.node.path, nil
            local mark = expanded[row.node.path] and "|cffaaaaaa[-]|r " or "|cffaaaaaa[+]|r "
            if row.depth == 0 then
                local st = catStyle(row.node.name)
                b.text:SetText(("%s%s |cff%s%s|r  |cff666666(%d)|r"):format(mark, tex(st.icon, 16), st.color, row.node.name, row.node.count))
            else
                b.text:SetText(("%s%s |cffffffff%s|r  |cff666666(%d)|r"):format(mark, tex(FOLDER_ICON, 14), row.node.name, row.node.count))
            end
        else
            local g = row.guide
            b.nodePath, b.gid = nil, g.id
            -- in flat search results the tree context is gone, so show the category icon per guide
            local prefix = filter ~= "" and (tex(catStyle(normCat(g.type)).icon, 14) .. " ") or ""
            b.text:SetText(prefix .. guideLabel(g) .. (P.guide and P.guide.id == g.id and "  |cff00ff00(active)|r" or ""))
        end
        b:ClearAllPoints(); b:SetPoint("TOPLEFT", 0, -y); b:SetPoint("RIGHT", 0, 0)
        b:Show()
        y = y + 20
    end
    for i = n + 1, #buttons do buttons[i]:Hide() end
    content:SetHeight(math.max(y, 10))
    local total = #G.Available()
    title:SetText(total == 0 and "OpenRoute Guides (none registered)" or ("OpenRoute Guides (%d)"):format(total))
end
function M.Toggle() if f:IsShown() then f:Hide() else M.Refresh() f:Show() end end
function M.Show() M.Refresh() f:Show() end
-- exposed for tools/test_offline.lua (headless tree checks); not used in-game
M._test = { buildTree = buildTree, guidePath = guidePath, visibleRows = visibleRows, searchRows = searchRows, expanded = expanded }
