-- OpenRoute :: Core/Init.lua
-- Addon namespace, flavor detection, saved variables, event bus.
local ADDON, NS = ...
_G.OpenRoute = NS
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

-- ---------------------------------------------------------------------------
-- Defaults
-- ---------------------------------------------------------------------------
NS.defaults = {
    profile = {
        arrow = { enabled = true, scale = 1.0, alpha = 1.0, lock = false, x = 0, y = -180, point = "TOP" },
        frame = { scale = 1.0, alpha = 0.95, width = 320, height = 300, showSteps = 6, lock = false, x = 0, y = 0, point = "CENTER" },
        routing = { enabled = true, reorder = true, hearth = true, taxi = true, transit = true, window = 10,
                    runSpeed = 7, mountSpeed = nil, terrainFactor = 1.25, taxiSpeed = 32 },
        autoAccept = false, autoTurnin = false, autoAdvance = true, minimapButton = true, debug = false,
    },
    char = {
        guide = nil,          -- currently selected guide id
        step = 1,             -- current step index (in original guide order)
        done = {},            -- [guideid] = { [stepindex] = true }
        skipped = {},         -- [guideid] = { [stepindex] = true }
        knownTaxi = {},       -- [taxiNodeID] = true (learned flight masters)
        bind = nil,           -- { map=, x=, y=, name= } learned hearth location
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
local PREFIX = "|cff3ec6ffOpen|r|cffffd200Route|r: "
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
    OpenRouteDB = OpenRouteDB or {}
    OpenRouteCharDB = OpenRouteCharDB or {}
    fill(OpenRouteDB, { profile = deepcopy(NS.defaults.profile) })
    fill(OpenRouteCharDB, deepcopy(NS.defaults.char))
    NS.db = { profile = OpenRouteDB.profile, char = OpenRouteCharDB, global = OpenRouteDB }
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

NS:RegisterEvent("PLAYER_LOGIN", function()
    NS:Fire("PLAYER_READY")
    NS:Print("v" .. NS.version .. " loaded (" .. NS.flavor .. "). Type /openroute or /or for help.")
end)
