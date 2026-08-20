-- CompletionRoute :: UI/Beacon.lua
-- "Where is it?" overlay.  Puts a bouncing marker over the head of the NPC / mob / object the
-- current step wants (via nameplates), highlights it on the target + mouseover frames, offers a
-- secure /target button so one click selects it, and pins the step location on the minimap and
-- world map.  Works on every flavor: nameplates, HereBeDragons pins and secure macro buttons all
-- exist in Era/TBC/Wrath/Cata/MoP/retail.
local ADDON, NS = ...
local U = NS.Util
local B = {}
NS.Beacon = B

local TEX = "Interface\\AddOns\\" .. ADDON .. "\\Textures\\"
local HBDPins = LibStub("HereBeDragons-Pins-2.0", true)

-- ---------------------------------------------------------------------------
-- Which unit names does the current step care about?
-- ---------------------------------------------------------------------------
-- Guide lines carry |T|Name| when the author supplied one; otherwise we mine the step title,
-- which follows the community convention "Accept <Quest> from <NPC>" / "Turn in <Quest> to <NPC>"
-- / "Kill <Mob>".
local TALK = { ".*%f[%a][Tt]alk to%s+(.+)$", "^[Tt]alk to%s+(.+)$", ".*%f[%a][Ss]peak to%s+(.+)$", ".*%f[%a][Ss]peak with%s+(.+)$" }
local TITLE_PATTERNS = {
    A = { ".*%f[%a]from%s+(.+)$", ".*%f[%a][Tt]alk to%s+(.+)$" },
    a = { ".*%f[%a]from%s+(.+)$" },
    T = { ".*%f[%a][Tt]urn in .* to%s+(.+)$", ".*%f[%a]to%s+(.+)$" },
    t = { ".*%f[%a]to%s+(.+)$" },
    K = { "^[Kk]ill%s+(.+)$", "^(.+)$" },
    l = { ".*%f[%a]from%s+(.+)$" },
    C = { ".*%f[%a]from%s+(.+)$", ".*%f[%a][Tt]alk to%s+(.+)$", ".*%f[%a][Ss]peak to%s+(.+)$" },
    -- Note/misc steps are very often "Talk to <NPC>" (Zygor's most common note shape)
    N = TALK, M = TALK, ["="] = TALK, U = TALK, ["$"] = TALK,
    B = { ".*%f[%a]from%s+(.+)$" },
    f = { ".*%f[%a]from%s+(.+)$" },
    r = { ".*%f[%a]from%s+(.+)$" },
}
local STRIP = { "%s*%b()%s*$", "%s*<.->%s*", "%s*[%.,;:]%s*$" }

local function cleanName(n)
    if not n then return nil end
    n = U.trim(n)
    for _, p in ipairs(STRIP) do n = n:gsub(p, "") end
    n = U.trim(n)
    -- "x2", counts and objective fragments are not names
    if n == "" or #n > 48 or n:find("^%d") then return nil end
    return n
end

-- returns { [lowercased name] = displayName }
function B.WantedNames()
    local out, n = {}, 0
    local function add(name)
        name = cleanName(name)
        if name and not out[name:lower()] then out[name:lower()] = name n = n + 1 end
    end
    local steps = { NS.Progress.current }
    -- sticky steps that are still open also count (Zygor keeps those on-screen)
    for _, s in ipairs(NS.Progress.Upcoming(4)) do steps[#steps + 1] = s end
    for _, s in ipairs(steps) do
        if s then
            if s.target then for piece in tostring(s.target):gmatch("[^;]+") do add(piece) end end
            local pats = TITLE_PATTERNS[s.action]
            if pats then
                for _, p in ipairs(pats) do
                    local m = s.title and s.title:match(p)
                    if m then add(m) break end
                end
            end
        end
    end
    B.count = n
    return out
end

-- ---------------------------------------------------------------------------
-- Nameplate markers
-- ---------------------------------------------------------------------------
local plateMarks = {}      -- nameplate frame -> marker frame
local wanted = {}

-- The over-head icon uses the game's OWN artwork, so it reads instantly the way a quest giver's
-- "!" does. Which icon depends on what the step wants: Guide.ACTION_ICON already maps every step
-- action to a Blizzard texture (gossip "!"/"?", coin, bag, boot...), and kill steps get the
-- familiar raid-target skull. profile.beacon.icon = "arrow" restores the plain arrow.
local RAID_SKULL = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8"
local DEFAULT_ICON = "Interface\\GossipFrame\\AvailableQuestIcon"

function B.MarkerTexture(step)
    local style = (NS.db and NS.db.profile.beacon and NS.db.profile.beacon.icon) or "action"
    if style == "arrow" then return TEX .. "arrow_green", true end
    local a = step and step.action
    if a == "K" then return RAID_SKULL, false end
    local icon = a and NS.Guide and NS.Guide.ACTION_ICON and NS.Guide.ACTION_ICON[a]
    return icon or DEFAULT_ICON, false
end

function B.RefreshIcons()
    local tex, rotate = B.MarkerTexture(NS.Progress.current)
    local function apply(m)
        if not m or not m.tex then return end
        if m.__tex ~= tex then
            m.tex:SetTexture(tex)
            m.tex:SetRotation(rotate and math.pi or 0)
            m.__tex = tex
        end
        if m.glow then m.glow:SetShown(rotate) end
    end
    for _, m in pairs(plateMarks) do apply(m) end
    for _, m in pairs(B.frameMarks or {}) do apply(m) end
end

local function newMarker(parent)
    local m = CreateFrame("Frame", nil, parent)
    m:SetSize(30, 30)
    m:SetFrameStrata("HIGH")
    local t = m:CreateTexture(nil, "OVERLAY")
    t:SetAllPoints()
    local tex, rotate = B.MarkerTexture(NS.Progress.current)
    t:SetTexture(tex)
    if rotate then t:SetRotation(math.pi) end
    m.tex = t
    m.__tex = tex
    local glow = m:CreateTexture(nil, "ARTWORK")
    glow:SetTexture(TEX .. "ring")
    glow:SetPoint("CENTER", 0, -6)
    glow:SetSize(38, 38)
    glow:SetBlendMode("ADD")
    glow:SetAlpha(0.32)
    glow:SetShown(select(2, B.MarkerTexture(NS.Progress.current)) and true or false)
    m.glow = glow
    -- bob up and down so it reads at a glance in a crowd
    -- Motion is a gentle bob on the ARROW TEXTURE only. Animating the frame itself fought with
    -- re-anchoring on every rescan and made the marker stutter across the screen.
    local ag = m:CreateAnimationGroup()
    ag:SetLooping("BOUNCE")
    local tr = ag:CreateAnimation("Translation")
    tr:SetOffset(0, 5); tr:SetDuration(0.9); tr:SetSmoothing("IN_OUT")
    m.anim = ag
    m.bob = tr
    return m
end

local function markPlate(plate, unit)
    local name = UnitName(unit)
    if not name or not wanted[name:lower()] then
        local m = plateMarks[plate]
        if m then m:Hide() m.anim:Stop() m.__parked = nil end
        return
    end
    local m = plateMarks[plate]
    if not m then m = newMarker(plate) plateMarks[plate] = m end
    B.Park(m, plate)
end

-- Anchor once and leave it alone. Re-applying SetPoint every rescan while the bob animation is
-- mid-flight is what made the marker jitter.
function B.Park(m, parent)
    local scale = (NS.db and NS.db.profile.beacon and NS.db.profile.beacon.scale) or 1
    if m.__parked ~= parent or m.__scale ~= scale then
        m:ClearAllPoints()
        m:SetPoint("BOTTOM", parent, "TOP", 0, 6)
        m:SetScale(scale)
        m.__parked, m.__scale = parent, scale
    end
    if not m:IsShown() then m:Show() end
    local bob = NS.db and NS.db.profile.beacon and NS.db.profile.beacon.bounce
    if bob == nil then bob = true end
    if bob then
        if not m.anim:IsPlaying() then m.anim:Play() end
    elseif m.anim:IsPlaying() then
        m.anim:Stop()
    end
end

-- ---------------------------------------------------------------------------
-- Legacy nameplates (Era / TBC / MoP Classic).
-- Those clients render nameplates as anonymous WorldFrame children and C_NamePlate.GetNamePlates()
-- comes back EMPTY, so the modern path silently does nothing there. Scan WorldFrame instead and
-- read the unit name out of the plate's FontString, the way classic nameplate addons do.
-- ---------------------------------------------------------------------------
local function plateName(f)
    local function fromRegions(frame)
        if not frame.GetRegions then return nil end
        for _, r in ipairs({ frame:GetRegions() }) do
            if r.GetObjectType and r:GetObjectType() == "FontString" then
                local t = r:GetText()
                if t and t ~= "" then return t end
            end
        end
    end
    local n = fromRegions(f)
    if n then return n end
    if f.GetChildren then
        for _, kid in ipairs({ f:GetChildren() }) do
            n = fromRegions(kid)
            if n then return n end
        end
    end
end

local function legacyPlates()
    local out = {}
    if not WorldFrame or not WorldFrame.GetChildren then return out end
    for _, f in ipairs({ WorldFrame:GetChildren() }) do
        -- Depending on the client generation a nameplate is either an anonymous WorldFrame child
        -- or a named "NamePlate<N>" frame. Accept both; anything else must have no name.
        local fname = f.GetName and f:GetName()
        local looksLikePlate = (not fname) or fname:find("^NamePlate%d*$") ~= nil
        if f.IsObjectType and f:IsObjectType("Frame") and f:IsShown() and looksLikePlate then
            local n = plateName(f)
            if n then out[#out + 1] = { frame = f, name = n } end
        end
    end
    return out
end
B._legacyPlates = legacyPlates

local function markLegacy(entry)
    local f, name = entry.frame, entry.name
    if not wanted[name:lower()] then
        local m = plateMarks[f]
        if m then m:Hide() m.anim:Stop() m.__parked = nil end
        return false
    end
    local m = plateMarks[f]
    if not m then m = newMarker(f) plateMarks[f] = m end
    B.Park(m, f)
    return true
end

function B.RescanPlates()
    if not NS.db or not NS.db.profile.beacon.enabled then
        for _, m in pairs(plateMarks) do m:Hide() m.anim:Stop() m.__parked = nil end
        return
    end
    wanted = B.WantedNames()
    local modern = 0
    if C_NamePlate and C_NamePlate.GetNamePlates then
        for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
            local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
            if unit then markPlate(plate, unit) modern = modern + 1 end
        end
    end
    B.modernPlates = modern
    -- classic clients expose nothing through C_NamePlate; fall back to the WorldFrame scan
    if modern == 0 then
        local n, marked = 0, 0
        for _, e in ipairs(legacyPlates()) do
            n = n + 1
            if markLegacy(e) then marked = marked + 1 end
        end
        B.legacyPlateCount, B.legacyMarked = n, marked
    else
        B.legacyPlateCount, B.legacyMarked = 0, 0
    end
end

NS:RegisterEvent("NAME_PLATE_UNIT_ADDED", function(_, unit)
    if not NS.db or not NS.db.profile.beacon.enabled then return end
    local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit(unit)
    if plate then wanted = next(wanted) and wanted or B.WantedNames() markPlate(plate, unit) end
end)
NS:RegisterEvent("NAME_PLATE_UNIT_REMOVED", function(_, unit)
    local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit(unit)
    local m = plate and plateMarks[plate]
    if m then m:Hide() m.anim:Stop() end
end)
NS:On("STEP_CHANGED", function() B.RescanPlates() B.RefreshIcons() B.UpdatePins() B.UpdateTargetButton() end)
NS:On("PROGRESS_REFRESHED", function() NS:Throttle("beacon", 0.5, function() B.RescanPlates() B.UpdatePins() B.UpdateTargetButton() end) end)

-- ---------------------------------------------------------------------------
-- Target / mouseover frame highlight (the unit frame, so you can confirm the click landed)
-- ---------------------------------------------------------------------------
local function frameMark(anchor, key)
    B.frameMarks = B.frameMarks or {}
    local m = B.frameMarks[key]
    if not m and anchor then m = newMarker(UIParent) B.frameMarks[key] = m end
    return m
end
local function updateUnitFrame(unit, anchorName, key)
    local anchor = _G[anchorName]
    local m = frameMark(anchor, key)
    if not m then return end
    local name = UnitExists(unit) and UnitName(unit)
    if anchor and name and wanted[name:lower()] and NS.db.profile.beacon.enabled then
        if m.__parked ~= anchor then
            m:ClearAllPoints(); m:SetPoint("RIGHT", anchor, "LEFT", -2, 0); m:SetScale(0.7)
            m.__parked, m.__scale = anchor, 0.7
        end
        if not m:IsShown() then m:Show() end
        local bob = NS.db.profile.beacon.bounce
        if bob == nil then bob = true end
        if bob and not m.anim:IsPlaying() then m.anim:Play() elseif not bob and m.anim:IsPlaying() then m.anim:Stop() end
    elseif m then m:Hide() m.anim:Stop() m.__parked = nil end
end
NS:RegisterEvent("PLAYER_TARGET_CHANGED", function() updateUnitFrame("target", "TargetFrame", "target") end)
NS:RegisterEvent("UPDATE_MOUSEOVER_UNIT", function() updateUnitFrame("mouseover", "MouseoverFrame", "mouseover") end)

-- ---------------------------------------------------------------------------
-- One-click "select it" button (secure /target macro; only editable out of combat)
-- ---------------------------------------------------------------------------
local tbtn = CreateFrame("Button", "CompletionRouteTargetButton", NS.Arrow and NS.Arrow.frame or UIParent, "SecureActionButtonTemplate")
tbtn:SetSize(26, 26)
tbtn:SetPoint("TOPRIGHT", (NS.Arrow and NS.Arrow.frame) or UIParent, "TOPRIGHT", -2, -2)
tbtn:SetAttribute("type", "macro")
tbtn:RegisterForClicks("AnyUp", "AnyDown")
local ttex = tbtn:CreateTexture(nil, "ARTWORK")
ttex:SetAllPoints(); ttex:SetTexture("Interface\\Minimap\\Tracking\\Target")
tbtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
tbtn:Hide()
B.targetButton = tbtn
tbtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("|cff3ec6ffCompletionRoute|r")
    GameTooltip:AddLine("Target: " .. (self.targetName or "?"), 1, 1, 1)
    GameTooltip:AddLine("Click to select it; a marker sits over its head when it is nearby.", 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
end)
tbtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

local pendingMacro
local function applyMacro(name)
    if InCombatLockdown() then pendingMacro = name return end
    pendingMacro = nil
    if not name then tbtn:Hide() tbtn.targetName = nil return end
    tbtn:SetAttribute("macrotext", "/cleartarget\n/targetexact " .. name .. "\n/target " .. name)
    tbtn.targetName = name
    tbtn:Show()
end
NS:RegisterEvent("PLAYER_REGEN_ENABLED", function() if pendingMacro ~= nil then applyMacro(pendingMacro) end end)

function B.UpdateTargetButton()
    if not NS.db or not NS.db.profile.beacon.enabled or not NS.db.profile.beacon.targetButton then applyMacro(nil) return end
    local s = NS.Progress.current
    if not s then applyMacro(nil) return end
    local names = B.WantedNames()
    -- prefer the name that belongs to the *current* step
    local pick
    if s.target then pick = cleanName((tostring(s.target):match("[^;]+"))) end
    if not pick then
        local pats = TITLE_PATTERNS[s.action]
        if pats then for _, p in ipairs(pats) do local m = s.title and s.title:match(p) if m then pick = cleanName(m) break end end end
    end
    if not pick then local _, n = next(names) pick = n end
    applyMacro(pick)
end

-- ---------------------------------------------------------------------------
-- Location beacon: minimap + world map pins on the step's coordinates
-- ---------------------------------------------------------------------------
local pins = {}
local function releasePins()
    if not HBDPins then return end
    HBDPins:RemoveAllMinimapIcons(B)
    HBDPins:RemoveAllWorldMapIcons(B)
    for _, p in ipairs(pins) do p:Hide() end
end
-- Pin frames are created HIDDEN and are never shown by us: HereBeDragons reparents and shows
-- them once it has placed them. Showing one ourselves left an unplaced icon floating in the
-- middle of the screen whenever HBD declined the placement.
local function pin(i)
    pins[i] = pins[i] or (function()
        local p = CreateFrame("Frame", nil, UIParent)
        p:SetSize(16, 16)
        p:SetPoint("CENTER")
        local t = p:CreateTexture(nil, "OVERLAY")
        t:SetAllPoints()
        t:SetTexture("Interface\\Minimap\\ObjectIcons")
        t:SetTexCoord(0.125, 0.25, 0, 0.125)   -- the gold quest-objective blob
        p:Hide()
        return p
    end)()
    return pins[i]
end

function B.UpdatePins()
    B.pinState = "no lib"
    if not HBDPins then return end
    releasePins()
    B.pinCount, B.pinError = 0, nil
    if not NS.db or not NS.db.profile.beacon.enabled or not NS.db.profile.beacon.pins then
        B.pinState = "disabled" return
    end
    local s = NS.Progress.current
    if not s then B.pinState = "no step" return end
    if not s.zone or not s.coords then B.pinState = "step has no map coords" return end
    for i, c in ipairs(s.coords) do
        if i > 4 then break end
        local p = pin(i)
        local ok, err = pcall(HBDPins.AddMinimapIconMap, HBDPins, B, p, s.zone, c.x, c.y, true, true)
        if not ok then B.pinError = "minimap: " .. tostring(err) end
        local p2 = pin(i + 10)
        -- SHOW_PARENT (1) keeps the pin visible on the parent zone map too
        local ok2, err2 = pcall(HBDPins.AddWorldMapIconMap, HBDPins, B, p2, s.zone, c.x, c.y, 1)
        if not ok2 then B.pinError = (B.pinError and (B.pinError .. " | ") or "") .. "worldmap: " .. tostring(err2) end
        if ok or ok2 then B.pinCount = B.pinCount + 1 end
    end
    B.pinState = ("%d pin(s) on map %s"):format(B.pinCount, tostring(s.zone))
end

function B.ApplySettings()
    B.RescanPlates(); B.RefreshIcons(); B.UpdatePins(); B.UpdateTargetButton()
end
NS:On("PLAYER_READY", function() NS:After(3, B.ApplySettings) end)

-- offline test hook
B._test = { cleanName = cleanName, patterns = TITLE_PATTERNS, plateMarks = plateMarks }

-- ---------------------------------------------------------------------------
-- /cr demo — deterministic proof that the beacon works, on any client, anywhere.
-- Turns on nameplates, picks a real unit standing near you (your target, else the closest
-- nameplate), builds a one-step guide that wants exactly that unit, and loads it. The marker
-- should appear over that unit's head and the arrow's target button should target it.
-- Also armable from disk: CompletionRouteDB.autoDemo = true (see tools/queue_verify.py --demo).
-- ---------------------------------------------------------------------------
function B.Demo()
    if InCombatLockdown() then NS:Error("demo: not in combat, please") return end
    -- nameplate CVars differ by client generation; set every spelling we know and report what stuck
    for _, cv in ipairs({ "nameplateShowAll", "nameplateShowSelf", "nameplateShowFriends",
                          "nameplateShowEnemies", "nameplateShowFriendlyNPCs", "nameplateShowEnemyMinions",
                          "nameplateShowFriendlyMinions", "ShowClassColorInNameplate" }) do
        pcall(SetCVar, cv, "1")
    end
    local name, unit
    if UnitExists("target") then name, unit = UnitName("target"), "target" end
    if not name and C_NamePlate and C_NamePlate.GetNamePlates then
        for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
            local u = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
            if u and UnitExists(u) then name, unit = UnitName(u), u break end
        end
    end
    if not name then
        NS:Error("demo: no unit nearby. Target an NPC (or stand near one) and run /cr demo again.")
        NS.db.char.lastDemo = "no unit nearby"
        return
    end
    local map, x, y = NS.Util.PlayerPos()
    local zone = map and (C_Map.GetMapInfo(map) or {}).name or "?"
    -- an Accept step so the demo shows the icon players already know: the yellow quest "!"
    local line = ("A Talk to %s|M|%.2f,%.2f|Z|%d; %s|T|%s|N|Beacon demo: the marker should be over %s's head.|")
        :format(name, (x or 0.5) * 100, (y or 0.5) * 100, map or 0, zone, name, name)
    NS.Guide.registry["cr:demo"] = nil
    for i, id in ipairs(NS.Guide.list) do if id == "cr:demo" then table.remove(NS.Guide.list, i) break end end
    NS.Guide.Register({ id = "cr:demo", name = "Beacon demo", type = "Leveling", source = "CompletionRoute",
                        zone = map, minlevel = 1, maxlevel = 999, text = line })
    NS.Progress.Load("cr:demo")
    B.ApplySettings()
    B.RescanPlates()
    local tracked = 0
    for _ in pairs(B.WantedNames()) do tracked = tracked + 1 end
    local marked = 0
    for _, m in pairs(plateMarks) do if m:IsShown() then marked = marked + 1 end end
    B.RescanPlates()
    local plates = (C_NamePlate and C_NamePlate.GetNamePlates and #(C_NamePlate.GetNamePlates() or {})) or 0
    updateUnitFrame("target", "TargetFrame", "target")
    local tf = B.frameMarks and B.frameMarks.target
    marked = 0
    for _, m in pairs(plateMarks) do if m:IsShown() then marked = marked + 1 end end
    local msg = ("demo: unit=%q tracked=%d modernPlates=%d legacyPlates=%d overHeadMarkers=%d targetFrameMarker=%s targetButton=%s pins=%s")
        :format(name, tracked, plates, B.legacyPlateCount or 0, marked, tostring(tf and tf:IsShown()),
                tostring(tbtn.targetName), tostring(NS.db.profile.beacon.pins))
    NS:Print(msg)
    NS.db.char.lastDemo = msg
    -- plates can spawn a beat after the guide loads; report again once they have settled
    NS:After(1.5, function()
        B.RescanPlates()
        local n = 0
        for _, m in pairs(plateMarks) do if m:IsShown() then n = n + 1 end end
        B.UpdatePins()
        local m2 = ("demo (settled): modernPlates=%d legacyPlates=%d overHeadMarkers=%d pins=%s%s")
            :format(B.modernPlates or 0, B.legacyPlateCount or 0, n, tostring(B.pinState),
                    B.pinError and (" ERR " .. B.pinError) or "")
        NS:Print(m2)
        NS.db.char.lastDemo = msg .. " | " .. m2
    end)
    return msg
end
