-- CompletionRoute :: Core/Init.lua
-- Addon namespace, flavor detection, saved variables, event bus.
local ADDON, NS = ...
_G.CompletionRoute = NS
NS.name = ADDON
NS.version = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version") or (GetAddOnMetadata and GetAddOnMetadata(ADDON, "Version")) or "dev"

-- ---------------------------------------------------------------------------
-- Flavor detection
-- ---------------------------------------------------------------------------
local toc = select(4, GetBuildInfo())
NS.tocversion = toc
if toc >= 100000 then NS.flavor = "retail"
elseif toc >= 50000 then NS.flavor = "mop"
elseif toc >= 40000 then NS.flavor = "cata"
elseif toc >= 30000 then NS.flavor = "wrath"
elseif toc >= 20000 then NS.flavor = "tbc"
else NS.flavor = "era" end
NS.isClassic = toc < 100000
-- WoW Forever (product wowf, client 1.60.x, Interface 16001): Era content on the modern client.  It runs the era
-- code path (NS.flavor == "era": era guides, no flying, Classic speeds) with its own data where Forever differs:
-- QuestV2 (+1,811 quest ids), taxi nodes (Mount Hyjal, Riverglades, Zephras Isle) and four reshaped zone maps
-- (Data/MapFix_forever.lua).  NS.dataFlavor names the data set ("forever"); NS.flavor stays "era".
-- WOW_PROJECT_ID alone cannot tell (Forever reports its own WOW_PROJECT_CAMELOT on newer builds, and Questie notes
-- builds that share Retail's id), so the interface range decides, with the constant as a second signal.
NS.isForever = (toc >= 16000 and toc < 17000) or (WOW_PROJECT_CAMELOT ~= nil and WOW_PROJECT_ID == WOW_PROJECT_CAMELOT)
if NS.isForever then NS.flavor = "era" end
NS.dataFlavor = NS.isForever and "forever" or NS.flavor

-- ---------------------------------------------------------------------------
-- Defaults
-- ---------------------------------------------------------------------------
NS.defaults = {
    profile = {
        arrow = { enabled = true, scale = 1.0, alpha = 1.0, lock = false, x = 0, y = -180, point = "TOP",
                  style = "hand" },   -- "hand": pointing hand in your class colour; "arrow": the old chevron
        frame = { scale = 1.0, alpha = 0.95, width = 320, height = 300, showSteps = 6, lock = false, x = 0, y = 0, point = "CENTER" },
        routing = { enabled = true, reorder = true, baked = true, hearth = true, taxi = true, transit = true, window = 24,
                    teleports = true,         -- class teleports, hearth toys, engineering transporters (Data/Teleports.lua)
                    runSpeed = 7, mountSpeed = nil, terrainFactor = 1.25, taxiSpeed = 32,
                    -- "known": fly only INTO flight paths this character has discovered (account-wide on retail and
                    -- WoW Forever, where the client shares them); walking to a new flight master to pick it up is fine.
                    -- "faction": every flight master your faction can use, discovered or not (the old default).
                    taxiPolicy = "known",
                    preferTaxi = false,       -- comfort mode: favors flight paths when available
                    roads = true, roadFactor = 1.0, recordRoads = true },
        beacon = { enabled = true, scale = 1.0, pins = true, targetButton = true, bounce = true, icon = "action",
                   highlightTaxi = true },   -- mark where to fly on the flight map / taxi frame
        accountWide = false,     -- legacy mirror of scope ~= "char"; kept so old saved variables still read
        scope = "char",          -- "char" | "realm" | "flavor" | "account" (see Core/Account.lua)
        accountQuests = true,    -- when accountWide is on, also union by quest ID across guides
        farm = { record = true,          -- remember every world-object node you loot (account-wide)
                 recordUnknown = false,  -- also remember loots whose source the client will not name
                 autoImport = true,      -- pull GatherMate2 / Routes data at login if those addons are present
                 radius = 40,            -- yards: how close counts as "reached this waypoint"
                 seeds = true,           -- register the shipped coarse circuits (Data/Farm_routes.lua)
                 circuitizeGold = true }, -- fold imported gold guides into a loop instead of a click-through list
        -- guide list (UI/GuideMenu.lua): level is nil while the list follows your own level
        guideList = { onlyLevel = false, groupByLevel = false },
        autoAccept = false, autoTurnin = false, autoAdvance = true, minimapButton = true, debug = false,
    },
    char = {
        guide = nil,          -- currently selected guide id
        step = 1,             -- current step index (in original guide order)
        done = {},            -- [guideid] = { [stepindex] = true }
        skipped = {},         -- [guideid] = { [stepindex] = true }
        knownTaxi = {},       -- [taxiNodeID] = true: flight masters THIS character has discovered (CompletionRouteDB.knownTaxi
                              -- is the account-wide union, used for routing only where the client shares flight paths)
        bind = nil,           -- { map=, x=, y=, name= } learned hearth location
        laps = {},            -- [guideid] = laps walked on this character
    },
}

local function deepcopy(t) local n = {} for k, v in pairs(t) do n[k] = type(v) == "table" and deepcopy(v) or v end return n end
local function fill(dst, src) for k, v in pairs(src) do
    if type(v) == "table" then if type(dst[k]) ~= "table" then dst[k] = {} end fill(dst[k], v)
    elseif dst[k] == nil then dst[k] = v end end end
NS.deepcopy, NS.filldefaults = deepcopy, fill

-- ---------------------------------------------------------------------------
-- Tiny event bus + WoW event frame
-- ---------------------------------------------------------------------------
NS.callbacks = {}
function NS:On(evt, fn) self.callbacks[evt] = self.callbacks[evt] or {}; tinsert(self.callbacks[evt], fn) end
function NS:Fire(evt, ...) local l = self.callbacks[evt]; if not l then return end for _, fn in ipairs(l) do fn(...) end end

local f = CreateFrame("Frame")
NS.eventFrame = f
NS.wowHandlers = {}
function NS:RegisterEvent(evt, fn)
    if not self.wowHandlers[evt] then self.wowHandlers[evt] = {}; pcall(f.RegisterEvent, f, evt) end
    tinsert(self.wowHandlers[evt], fn)
end
f:SetScript("OnEvent", function(_, evt, ...)
    local l = NS.wowHandlers[evt]; if not l then return end
    for _, fn in ipairs(l) do local ok, err = pcall(fn, evt, ...) if not ok then NS:Debug("event " .. evt .. ": " .. tostring(err)) end end
end)

-- ---------------------------------------------------------------------------
-- Output helpers
-- ---------------------------------------------------------------------------
local PREFIX = "|cff7ddf8fCompletion|r|cffffd200Route|r: "
function NS:Print(...) print(PREFIX .. strjoin(" ", tostringall(...))) end
function NS:Debug(...) if self.db and self.db.profile.debug then print(PREFIX .. "|cff888888" .. strjoin(" ", tostringall(...)) .. "|r") end end
function NS:Error(...) print(PREFIX .. "|cffff4040" .. strjoin(" ", tostringall(...)) .. "|r") end

-- ---------------------------------------------------------------------------
-- Timers
-- ---------------------------------------------------------------------------
function NS:After(sec, fn) C_Timer.After(sec, fn) end
NS.throttles = {}
-- Coalesce many calls into one within `sec`
function NS:Throttle(key, sec, fn)
    if self.throttles[key] then return end
    self.throttles[key] = true
    C_Timer.After(sec, function() self.throttles[key] = nil; fn() end)
end

-- ---------------------------------------------------------------------------
-- Load
-- ---------------------------------------------------------------------------
NS:RegisterEvent("ADDON_LOADED", function(_, name)
    if name ~= ADDON then return end
    -- migrate from the addon's former name (OpenRoute) on first load after the rename
    if not CompletionRouteDB and _G.OpenRouteDB then CompletionRouteDB = _G.OpenRouteDB end
    if not CompletionRouteCharDB and _G.OpenRouteCharDB then CompletionRouteCharDB = _G.OpenRouteCharDB end
    CompletionRouteDB = CompletionRouteDB or {}
    CompletionRouteCharDB = CompletionRouteCharDB or {}
    fill(CompletionRouteDB, { profile = deepcopy(NS.defaults.profile) })
    -- the live window grew from 12 to 24 steps (routing tier B); a saved profile still on the old default follows it,
    -- once, so a player who later sets 12 on the Options slider keeps it
    local routing = CompletionRouteDB.profile.routing
    if routing and not routing.window24 then
        if routing.window == 12 then routing.window = 24 end
        routing.window24 = true
    end
    -- Flight paths: the route now flies only into flight paths this character has discovered (docs/ROUTING.md). A profile
    -- saved under the old "faction" default moves to "known" once; Options still offers the old rule.
    if routing and not routing.taxiKnown1 then
        if routing.taxiPolicy == "faction" or routing.taxiPolicy == nil then routing.taxiPolicy = "known" end
        routing.assumeAllTaxi = nil
        routing.taxiKnown1 = true
    end
    -- Only retail and WoW Forever share discovered flight paths between characters. Older builds copied the account-wide
    -- set into every character on every client, so a Classic character's own set is not known: it starts empty once (the
    -- merged set is kept as knownTaxiMerged, unused) and the next login harvest or flight-master visit fills it.
    NS.taxiShared = (NS.flavor == "retail") or NS.isForever or false
    CompletionRouteDB.knownTaxi = CompletionRouteDB.knownTaxi or {}
    CompletionRouteCharDB.knownTaxi = CompletionRouteCharDB.knownTaxi or {}
    for id in pairs(CompletionRouteCharDB.knownTaxi) do CompletionRouteDB.knownTaxi[id] = true end
    if not NS.taxiShared and not CompletionRouteCharDB.taxiOwn then
        if next(CompletionRouteCharDB.knownTaxi) then CompletionRouteCharDB.knownTaxiMerged = CompletionRouteCharDB.knownTaxi end
        CompletionRouteCharDB.knownTaxi = {}
    end
    CompletionRouteCharDB.taxiOwn = true
    NS.db = { profile = CompletionRouteDB.profile, char = CompletionRouteCharDB, global = CompletionRouteDB }
    NS.player = {
        faction = UnitFactionGroup("player"),
        class = select(2, UnitClass("player")),
        race = select(2, UnitRace("player")),
        name = UnitName("player"),
        realm = GetRealmName(),
    }
    NS.loaded = true
    NS:Fire("ADDON_READY")
end)

-- capture our own Lua errors for offline diagnosis (kept in SavedVariables, max 20)
do
    local orig = geterrorhandler and geterrorhandler()
    local pending = {}
    local function record(err)
        local entry = err .. "\n" .. (debugstack and debugstack(3, 5, 5) or "")
        if NS.db then
            NS.db.char.luaErrors = NS.db.char.luaErrors or {}
            if #NS.db.char.luaErrors < 20 then tinsert(NS.db.char.luaErrors, entry) end
        elseif #pending < 20 then tinsert(pending, entry) end
    end
    if seterrorhandler then
        seterrorhandler(function(err)
            if type(err) == "string" and err:find("CompletionRoute") then pcall(record, err) end
            if orig then return orig(err) end
        end)
    end
    NS:On("ADDON_READY", function()
        -- errors recorded by an older build are stale once the addon is updated: keep the log per version
        local ver = tostring(NS.version or (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version")) or (GetAddOnMetadata and GetAddOnMetadata(ADDON, "Version")) or "?")
        if NS.db.char.luaErrorsVersion ~= ver then NS.db.char.luaErrors, NS.db.char.luaErrorsVersion = {}, ver end
        if #pending > 0 then
            NS.db.char.luaErrors = NS.db.char.luaErrors or {}
            for _, e in ipairs(pending) do if #NS.db.char.luaErrors < 20 then tinsert(NS.db.char.luaErrors, e) end end
        end
        NS.db.char.luaErrors = NS.db.char.luaErrors or {}
    end)
end

NS:RegisterEvent("PLAYER_LOGIN", function()
    NS:Fire("PLAYER_READY")
    NS:Print("v" .. NS.version .. " loaded (" .. (NS.isForever and "forever" or NS.flavor) .. "). Type /cr for help (/or still works).")
end)
