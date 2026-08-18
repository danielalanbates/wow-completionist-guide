-- OpenRoute :: Core/Slash.lua
local ADDON, NS = ...
local U, G, P, Cond = NS.Util, NS.Guide, NS.Progress, NS.Cond

SLASH_OPENROUTE1 = "/openroute"
SLASH_OPENROUTE2 = "/or"
SlashCmdList.OPENROUTE = function(msg)
    msg = U.trim(msg or "")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    if cmd == "" or cmd == "show" or cmd == "toggle" then NS.GuideFrame.Toggle()
    elseif cmd == "guides" or cmd == "menu" then NS.GuideMenu.Toggle()
    elseif cmd == "load" then
        for _, id in ipairs(G.list) do
            local g = G.registry[id]
            if id:lower() == rest:lower() or (g.name or ""):lower() == rest:lower() or id:lower():find(rest:lower(), 1, true) or (g.name or ""):lower():find(rest:lower(), 1, true) then P.Load(id) return end
        end
        NS:Print("No guide matches '" .. rest .. "'. /or guides")
    elseif cmd == "next" or cmd == "done" then if P.current then P.MarkDone(P.current, true) end
    elseif cmd == "skip" then if P.current then P.Skip(P.current) end
    elseif cmd == "undo" or cmd == "back" then P.Undo()
    elseif cmd == "reset" then P.Reset() NS:Print("Guide progress reset.")
    elseif cmd == "arrow" then NS.db.profile.arrow.enabled = not NS.db.profile.arrow.enabled NS.Arrow.ApplySettings() NS:Print("Arrow " .. (NS.db.profile.arrow.enabled and "on" or "off"))
    elseif cmd == "options" or cmd == "opt" or cmd == "config" then NS.Options.Open()
    elseif cmd == "route" then
        local path = NS.Router.CurrentPath(true)
        if not P.current then NS:Print("No current step.") return end
        NS:Print("Current step: " .. P.current.action .. " " .. P.current.title)
        NS:Print("Route: " .. NS.TravelGraph.Describe(path))
        local rec = NS.Router.Recommendation()
        if rec then NS:Print(("Arrow mode: %s  %s  dist=%s eta=%s"):format(rec.mode, rec.text or "", U.FmtDist(rec.dist), U.FmtTime(rec.eta))) end
    elseif cmd == "order" then
        NS:Print("Upcoming (optimized order):")
        for i, s in ipairs(P.Upcoming(12)) do
            local secs = NS.Router.TravelSecondsFromPlayer(s)
            NS:Print(("  %d. [%s] %s  (%s, ~%s)"):format(i, s.action, s.title, s.zone and U.MapName(s.zone) or "?", U.FmtTime(secs)))
        end
    elseif cmd == "taxi" then
        local n = 0 for _ in pairs(NS.db.char.knownTaxi) do n = n + 1 end
        NS:Print(("Known flight paths: %d. Graph nodes: %d. Open a flight master's map to learn more."):format(n, #NS.TravelGraph.nodes))
    elseif cmd == "hearth" then
        local wx, wy, inst, name = NS.TravelGraph.HearthWorld()
        NS:Print(("Hearth: %s  (%s)"):format(tostring(GetBindLocation and GetBindLocation()), wx and ("known: " .. tostring(name)) or "location unknown - hearth once or bind at an inn to teach me"))
    elseif cmd == "import" then
        if NS.Adapters then for _, ad in pairs(NS.Adapters) do if ad.Import then ad.Import(true) end end end
        NS.GuideMenu.Refresh()
    elseif cmd == "verify" then
        NS.RunVerify()
    elseif cmd == "log" then NS.Log.Toggle()
    elseif cmd == "stats" then
        local bySrc = {}
        for _, id in ipairs(G.list) do local g = G.registry[id] bySrc[g.source or "?"] = (bySrc[g.source or "?"] or 0) + 1 end
        for src, n in pairs(bySrc) do NS:Print(("guides from %s: %d"):format(src, n)) end
        NS:Print(("player: %s %s %s lvl %.1f; suggest = %s"):format(NS.player.faction, NS.player.race, NS.player.class, U.PlayerLevel(), tostring(G.Suggest() and G.Suggest().id)))
        for _, id in ipairs(G.list) do local g = G.registry[id] if g.source == "OpenRoute" then NS:Print(("  native: %s [%s] %s-%s %s"):format(id, g.faction or "?", tostring(g.minlevel), tostring(g.maxlevel), Cond and NS.Cond.FactionMatch(g.faction) and "ok" or "faction-mismatch")) end end
    elseif cmd == "debug" then NS.db.profile.debug = not NS.db.profile.debug NS:Print("Debug " .. tostring(NS.db.profile.debug))
    elseif cmd == "test" then
        -- self-test: route from player to a few known destinations
        local map, x, y, inst, wx, wy = U.PlayerPos()
        NS:Print(("You: map %s (%.1f, %.1f) inst %s"):format(tostring(map), (x or 0) * 100, (y or 0) * 100, tostring(inst)))
        for _, dest in ipairs({ { "Stormwind City", 52.6, 65.7 }, { "Ironforge", 18.2, 51.7 }, { "Orgrimmar", 53.7, 74.9 }, { "The Barrens", 51.5, 30.3 }, { "Booty Bay", 27.0, 77.3 }, { "Shattrath City", 55.5, 42.7 } }) do
            local zone = dest[1] == "Booty Bay" and "Stranglethorn Vale" or dest[1]
            local dx, dy, di = NS.TravelGraph.zoneToWorld(zone, dest[2], dest[3])
            if dx then
                local t0 = debugprofilestop()
                local p = NS.TravelGraph.FindPath(wx, wy, inst, dx, dy, di, {})
                NS:Print(("-> %s: %s [%.0fms]"):format(dest[1], NS.TravelGraph.Describe(p), debugprofilestop() - t0))
            else NS:Print("-> " .. dest[1] .. ": zone not resolvable on this client") end
        end
    else
        NS:Print("Commands: show | guides | load <name> | next | skip | undo | reset | arrow | options | route | order | taxi | hearth | import | test | debug")
    end
end

function NS.RunVerify(quiet)
    local out = {}
    local function chk(name, fn)
        local ok, res, detail = pcall(fn)
        local pass = ok and res and true or false
        local line = ("%s %s%s"):format(pass and "PASS" or "FAIL", name, detail and (" - " .. tostring(detail)) or (not ok and (" - " .. tostring(res)) or ""))
        out[#out + 1] = line
        if not quiet then NS:Print((pass and "|cff00ff00PASS|r" or "|cffff4040FAIL|r") .. line:sub(5)) end
    end
    local P, G, U = NS.Progress, NS.Guide, NS.Util
    chk("guide loaded", function() return P.guide ~= nil, P.guide and P.guide.id end)
    chk("steps parsed", function() return P.steps and #P.steps > 0, P.steps and #P.steps end)
    chk("current step", function() return P.current ~= nil, P.current and (P.current.action .. " " .. P.current.title) end)
    chk("optimizer order", function() local u = P.Upcoming(10) return #u > 0, #u .. " upcoming" end)
    chk("travel graph", function() return #NS.TravelGraph.nodes > 50, #NS.TravelGraph.nodes .. " nodes" end)
    chk("taxi data flavor", function() return NS.TaxiData[NS.flavor] ~= nil, NS.flavor end)
    chk("known flight paths", function() return true, U.tcount(NS.db.char.knownTaxi) end)
    chk("hearth location", function() local wx, _, _, n = NS.TravelGraph.HearthWorld() return wx ~= nil, tostring(n or (GetBindLocation and GetBindLocation())) end)
    chk("player world pos", function() local _, _, _, _, wx = U.PlayerPos() return wx ~= nil end)
    chk("route to current step", function() local pth = NS.Router.CurrentPath(true) return pth ~= nil, pth and NS.TravelGraph.Describe(pth) end)
    chk("arrow recommendation", function() local r = NS.Router.Recommendation() return r ~= nil, r and (r.mode .. ": " .. (r.text or "")) end)
    chk("arrow frame shown", function() return NS.Arrow.frame:IsShown() end)
    chk("secure button type", function() return true, tostring(NS.Arrow.button:GetAttribute("type")) end)
    chk("guides registered", function() return #G.list > 0, #G.list end)
    chk("suggest", function() local g = G.Suggest() return g ~= nil, g and g.id end)
    chk("native guides", function() local n = 0 for _, id in ipairs(G.list) do if G.registry[id].source == "OpenRoute" then n = n + 1 end end return n > 0, n end)
    chk("Zygor imported", function() local n = 0 for _, id in ipairs(G.list) do if G.registry[id].source == "Zygor" then n = n + 1 end end return true, n end)
    chk("WoWPro imported", function() local n = 0 for _, id in ipairs(G.list) do if G.registry[id].source == "WoWPro" then n = n + 1 end end return true, n end)
    chk("player info", function() return true, NS.player.faction .. " " .. NS.player.race .. " " .. NS.player.class .. " " .. string.format("%.2f", U.PlayerLevel()) end)
    chk("autoload error", function() return NS.db.char.lastAutoloadError == nil, NS.db.char.lastAutoloadError end)
    NS.db.char.lastVerify = { at = date("%Y-%m-%d %H:%M:%S"), lines = out }
    return out
end
