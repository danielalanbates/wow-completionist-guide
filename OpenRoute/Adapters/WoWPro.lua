-- OpenRoute :: Adapters/WoWPro.lua
-- If the WoW-Pro addon is installed and enabled, expose its guides inside OpenRoute at runtime.
-- Nothing is copied or redistributed: we read WoWPro.Guides from the user's own installation
-- (WoW-Pro guides are CC BY-NC-ND; this adapter is interoperability, guides stay in their addon).
-- The line syntax is identical to OpenRoute's native format, so no conversion is needed.
local ADDON, NS = ...
local G = NS.Guide
NS.Adapters = NS.Adapters or {}
local A = {}
NS.Adapters.WoWPro = A

local imported = 0
function A.Import(verbose)
    if not _G.WoWPro or not WoWPro.Guides then if verbose then NS:Print("WoW-Pro not loaded; nothing to import.") end return 0 end
    local n = 0
    for gid, g in pairs(WoWPro.Guides) do
        if type(g) == "table" and g.sequence and not G.registry["wowpro:" .. gid] then
            local ok = G.Register({
                id = "wowpro:" .. gid,
                name = (g.name or g.zone or gid),
                type = g.guidetype or "Leveling",
                zone = g.zone,
                faction = g.faction,
                minlevel = g.startlevel, maxlevel = g.endlevel,
                next = g.nextGID and ("wowpro:" .. g.nextGID) or nil,
                author = g.author,
                source = "WoWPro",
                text = g.sequence,
            })
            if ok then n = n + 1 end
        end
    end
    imported = imported + n
    if verbose or n > 0 then NS:Print(("Imported %d WoW-Pro guide(s) (%d total)."):format(n, imported)) end
    return n
end

-- WoW-Pro registers guides at load; some modules load later (LoadOnDemand). Import at login and again shortly after.
NS:On("PLAYER_READY", function()
    A.Import(false)
    NS:After(5, function() A.Import(false) end)
end)
NS:RegisterEvent("ADDON_LOADED", function(_, name)
    if name and name:find("^WoWPro") then NS:After(1, function() A.Import(false) end) end
end)
