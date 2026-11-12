-- CompletionRoute :: UI/Characters.lua
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
--
-- The character list (owner's request, 2026-11-12): every character the addon knows on this account, and whether its
-- progress is synced, so account-wide activity and completion can be trusted.  Opened from the step window's gear menu
-- ("Character list") and by /cr chars.
--
-- What "synced" means here.  The addon keeps one record per character (Core/Account.lua NS.db.global.chars): written
-- at every login and as steps finish on that character, and copied between game clients by tools/sync_progress.lua.
-- A character the game has never logged in with the addon on has no record: the game gives addons no list of an
-- account's characters, so the window says so instead of guessing.
--   * this character          - the one you are playing; its record is current
--   * synced <when>           - its record was last updated then (on this client or copied in from another)
--   * not synced for N days   - more than SYNC_STALE days old: log in on it once to bring it up to date
local ADDON, NS = ...
local U = NS.Util
local C = {}
NS.Characters = C

C.SYNC_STALE = 14           -- days: an older record is shown as not synced
local ROW_H = 22
local SHOWN = 14            -- rows visible at once; the list scrolls past that

local BACKDROP = { bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                   tile = true, tileSize = 16, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } }

-- "2026-11-12 12:50:01" -> seconds since the epoch (local time), nil when it cannot be read
local function parseStamp(s)
    if type(s) ~= "string" then return nil end
    local y, mo, d, h, mi, se = s:match("^(%d+)%-(%d+)%-(%d+) (%d+):(%d+):(%d+)")
    if not y or not time then return nil end
    local ok, t = pcall(time, { year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h),
                                min = tonumber(mi), sec = tonumber(se) })
    return ok and t or nil
end
C.ParseStamp = parseStamp

local function ago(sec)
    if sec < 90 then return "just now" end
    if sec < 3600 then return ("%d min ago"):format(math.floor(sec / 60 + 0.5)) end
    if sec < 86400 * 2 then return ("%d h ago"):format(math.floor(sec / 3600 + 0.5)) end
    return ("%d days ago"):format(math.floor(sec / 86400 + 0.5))
end

-- { text, r, g, b } of a character's sync state; `now` for the tests
function C.SyncState(c, now)
    local A = NS.Account
    if A and c.key == A.key then return "this character", 0.49, 0.87, 0.56 end
    local t = parseStamp(c.updated)
    if not t then return "never synced", 1, 0.6, 0.2 end
    now = now or (time and time()) or t
    local age = math.max(0, now - t)
    if age > C.SYNC_STALE * 86400 then
        return ("not synced for %d days"):format(math.floor(age / 86400)), 1, 0.6, 0.2
    end
    return "synced " .. ago(age), 0.8, 0.8, 0.8
end

-- the rows: the current character first, then the most recently synced
function C.Rows()
    local A = NS.Account
    local rows = (A and A.Characters) and A.Characters() or {}
    local me = A and A.key
    table.sort(rows, function(a, b)
        if (a.key == me) ~= (b.key == me) then return a.key == me end
        local ta, tb = parseStamp(a.updated) or 0, parseStamp(b.updated) or 0
        if ta ~= tb then return ta > tb end
        return tostring(a.key) < tostring(b.key)
    end)
    return rows
end

local function classColor(class)
    local t = (CUSTOM_CLASS_COLORS and CUSTOM_CLASS_COLORS[class]) or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[class])
    if t then return t.r, t.g, t.b end
    return 1, 1, 1
end

local f
local function build()
    f = CreateFrame("Frame", "CompletionRouteCharacters", UIParent, "BackdropTemplate")
    C.frame = f
    f:SetSize(560, 120 + SHOWN * ROW_H)
    f:SetPoint("CENTER", 0, 60)
    f:SetBackdrop(BACKDROP)
    f:SetBackdropColor(0.03, 0.03, 0.05, 0.96)
    f:SetBackdropBorderColor(0.3, 0.6, 0.9, 0.9)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true); f:EnableMouse(true); f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    tinsert(UISpecialFrames, "CompletionRouteCharacters")

    local title = f:CreateFontString(nil, "OVERLAY", U.Font("Large"))
    title:SetPoint("TOP", 0, -10); title:SetText("Character list")
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", -2, -2)

    f.scope = f:CreateFontString(nil, "OVERLAY", U.Font("Small"))
    f.scope:SetPoint("TOPLEFT", 14, -34); f.scope:SetPoint("RIGHT", -14, 0)
    f.scope:SetJustifyH("LEFT"); f.scope:SetWordWrap(true); f.scope:SetTextColor(0.8, 0.8, 0.8)

    -- column heads
    local heads = { { "Character", 14 }, { "Level / class", 214 }, { "Game type", 320 }, { "Sync", 430 } }
    for _, h in ipairs(heads) do
        local fs = f:CreateFontString(nil, "OVERLAY", U.Font("Small"))
        fs:SetPoint("TOPLEFT", h[2], -70); fs:SetText(h[1]); fs:SetTextColor(1, 0.82, 0)
    end

    local scroll = CreateFrame("ScrollFrame", "CompletionRouteCharactersScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 8, -88); scroll:SetPoint("BOTTOMRIGHT", -30, 48)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(510, 10)
    scroll:SetScrollChild(content)
    f.content, f.rows = content, {}

    f.note = f:CreateFontString(nil, "OVERLAY", U.Font("Small"))
    f.note:SetPoint("BOTTOMLEFT", 14, 12); f.note:SetPoint("RIGHT", -14, 0)
    f.note:SetJustifyH("LEFT"); f.note:SetWordWrap(true); f.note:SetTextColor(0.6, 0.6, 0.6)
    f.note:SetText("A character appears here after you log in on it once with Completionist's Guide on; the game does "
        .. "not tell addons about the others. Log in on a character that is not synced to bring its progress up to date.")
end

local function row(i)
    local r = f.rows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, f.content)
    r:SetSize(510, ROW_H)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    r.bg = r:CreateTexture(nil, "BACKGROUND"); r.bg:SetAllPoints()
    local function col(x, w)
        local fs = r:CreateFontString(nil, "OVERLAY", U.Font("Body"))
        fs:SetPoint("LEFT", x, 0); fs:SetWidth(w); fs:SetJustifyH("LEFT"); fs:SetWordWrap(false)
        return fs
    end
    r.name, r.level, r.flavor, r.sync = col(6, 196), col(206, 104), col(312, 108), col(422, 88)
    r:EnableMouse(true)
    r:SetScript("OnEnter", function(self)
        local c = self.c
        if not c then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText((c.display or c.name or c.key or "?") .. (c.realm and (" - " .. c.realm) or ""), 1, 1, 1)
        GameTooltip:AddLine(("%d finished steps in %d routes"):format(c.steps or 0, c.guides or 0), 0.8, 0.8, 0.8)
        if c.updated then GameTooltip:AddLine("Last synced: " .. tostring(c.updated), 0.6, 0.6, 0.6) end
        if c.faction then GameTooltip:AddLine(tostring(c.faction), 0.6, 0.6, 0.6) end
        GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.rows[i] = r
    return r
end

function C.Refresh()
    if not f then build() end
    local A = NS.Account
    if A and A.ScopeLabel then
        f.scope:SetText(("Counting progress from: %s (%s). Change it with the buttons at the top of the Routes window.")
            :format(A.ScopeLabel(), A.ScopeDetail and A.ScopeDetail() or ""))
    end
    local rows = C.Rows()
    for i, c in ipairs(rows) do
        local r = row(i)
        r.c = c
        r.bg:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.04 or 0)
        r.name:SetText(c.display or c.name or c.key or "?")
        r.name:SetTextColor(classColor(c.class))
        r.level:SetText(("%s %s"):format(c.level and ("Level " .. c.level) or "", c.class and (tostring(c.class):sub(1, 1) .. tostring(c.class):sub(2):lower()) or ""))
        local gt = c.gametype or c.flavor
        r.flavor:SetText(gt and A and A.GameTypeName and A.GameTypeName(gt) or tostring(gt or "?"))
        local text, rr, gg, bb = C.SyncState(c)
        r.sync:SetText(text); r.sync:SetTextColor(rr, gg, bb)
        r:Show()
    end
    for i = #rows + 1, #f.rows do f.rows[i]:Hide() f.rows[i].c = nil end
    f.content:SetHeight(math.max(#rows * ROW_H, 10))
    if #rows == 0 then
        local r = row(1)
        r.c = nil
        r.name:SetText("No characters yet") r.name:SetTextColor(0.8, 0.8, 0.8)
        r.level:SetText("") r.flavor:SetText("") r.sync:SetText("")
        r:Show()
    end
end

function C.Show() C.Refresh() f:Show() end
function C.Toggle()
    if f and f:IsShown() then f:Hide() else C.Show() end
end
