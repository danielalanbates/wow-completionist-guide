-- CompletionRoute :: Core/Slash.lua
local ADDON, NS = ...
local U, G, P, Cond = NS.Util, NS.Guide, NS.Progress, NS.Cond

SLASH_COMPLETIONROUTE1 = "/completionroute"
SLASH_COMPLETIONROUTE2 = "/cr"
SLASH_COMPLETIONROUTE3 = "/openroute"   -- former name, kept so old macros keep working
SLASH_COMPLETIONROUTE4 = "/or"
SlashCmdList.COMPLETIONROUTE = function(msg)
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
        NS:Print("No guide matches '" .. rest .. "'. /cr guides")
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
    elseif cmd == "next" then
        local nxt, eta = G.SuggestNext(NS.Progress.guide and NS.Progress.guide.id)
        if nxt then
            local msg = ("Next recommended guide: %s [%s-%s]%s"):format(nxt.name, tostring(nxt.minlevel), tostring(nxt.maxlevel), eta and (" ~%dm travel"):format(math.max(1, math.floor(eta / 60 + 0.5))) or "")
            NS:Print(msg)
            NS.db.char.lastNext = nxt.id .. " | " .. msg
        else NS:Print("No leveling guide fits your level/faction.") NS.db.char.lastNext = "none" end
    elseif cmd == "switch" then
        local nxt = G.SuggestNext(NS.Progress.guide and NS.Progress.guide.id)
        if nxt then NS.Progress.Load(nxt.id) NS:Print("Switched to: " .. nxt.name)
        else NS:Print("No better guide found.") end
    elseif cmd == "scan" then
        if NS.DynamicQuests then NS.DynamicQuests.Scan() NS:Print("Rescanned this zone's live quests.")
        else NS:Print("Live quest scan is retail-only (classic flavors use the baked quest DB).") end
    elseif cmd == "verify" then
        NS.RunVerify()
    elseif cmd == "verifyall" then
        NS.RunVerifyAll()
    elseif cmd == "autoverify" then
        CompletionRouteDB.autoVerifyAll = not CompletionRouteDB.autoVerifyAll
        NS:Print("Run verifyall automatically at next login: " .. tostring(CompletionRouteDB.autoVerifyAll))
    elseif cmd == "log" then NS.Log.Toggle()
    elseif cmd == "stats" then
        local bySrc = {}
        for _, id in ipairs(G.list) do local g = G.registry[id] bySrc[g.source or "?"] = (bySrc[g.source or "?"] or 0) + 1 end
        for src, n in pairs(bySrc) do NS:Print(("guides from %s: %d"):format(src, n)) end
        NS:Print(("player: %s %s %s lvl %.1f; suggest = %s"):format(NS.player.faction, NS.player.race, NS.player.class, U.PlayerLevel(), tostring(G.Suggest() and G.Suggest().id)))
        for _, id in ipairs(G.list) do local g = G.registry[id] if g.source == "CompletionRoute" then NS:Print(("  native: %s [%s] %s-%s %s"):format(id, g.faction or "?", tostring(g.minlevel), tostring(g.maxlevel), Cond and NS.Cond.FactionMatch(g.faction) and "ok" or "faction-mismatch")) end end
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
        NS:Print("Commands: show | guides | load <name> | next | skip | undo | reset | arrow | beacon | chars | accountwide | forget <char> | options | route | order | taxi | hearth | import | test | debug")
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
    chk("native guides", function() local n = 0 for _, id in ipairs(G.list) do if G.registry[id].source == "CompletionRoute" then n = n + 1 end end return n > 0, n end)
    chk("Zygor imported", function() local n = 0 for _, id in ipairs(G.list) do if G.registry[id].source == "Zygor" then n = n + 1 end end return true, n end)
    chk("WoWPro imported", function() local n = 0 for _, id in ipairs(G.list) do if G.registry[id].source == "WoWPro" then n = n + 1 end end return true, n end)
    chk("player info", function() return true, NS.player.faction .. " " .. NS.player.race .. " " .. NS.player.class .. " " .. string.format("%.2f", U.PlayerLevel()) end)
    chk("beacon targets", function() local t = {} for _, n in pairs(NS.Beacon.WantedNames()) do t[#t + 1] = n end return true, #t > 0 and table.concat(t, ", ") or "none" end)
    chk("beacon pins lib", function() return LibStub("HereBeDragons-Pins-2.0", true) ~= nil end)
    chk("account store", function() return NS.Account and NS.Account.me ~= nil, NS.Account and NS.Account.key end)
    chk("account characters", function() return true, #NS.Account.Characters() .. " known, accountWide=" .. tostring(NS.db.profile.accountWide) end)
    chk("autoload error", function() return NS.db.char.lastAutoloadError == nil, NS.db.char.lastAutoloadError end)
    NS.db.char.lastVerify = { at = date("%Y-%m-%d %H:%M:%S"), lines = out }
    return out
end


-- ---------------------------------------------------------------------------
-- Feature verifier: one named PASS/FAIL row per feature, written to
-- CompletionRouteDB.featureVerify so tools/collect_verify.py can chart it in SQL.
-- ---------------------------------------------------------------------------
-- Bulk verifier: parse + fully load EVERY registered guide (all factions), chunked across frames.
-- Results land in CompletionRouteDB.verifyAll for tools/collect_verify.py.
-- Callable without typing in the client: set CompletionRouteDB.autoVerifyAll = true in the
-- SavedVariables file before launching (see tools/queue_verify.py) - typing long slash commands
-- through synthetic keystrokes is unreliable, this pathway is not.
function NS.RunVerifyAll(onDone)
    local G = NS.Guide
    local ids = {}
    for _, id in ipairs(G.list) do ids[#ids + 1] = id end
    local res = { flavor = NS.flavor, total = #ids, done = 0, failed = 0, errors = {}, startedAt = date("%Y-%m-%d %H:%M:%S") }
    CompletionRouteDB.verifyAll = res
    local prevGuide = NS.Progress.guide and NS.Progress.guide.id
    local i, fr = 1, CreateFrame("Frame")
    NS:Print(("verifyall: checking %d guides..."):format(#ids))
    fr:SetScript("OnUpdate", function()
        local budget = debugprofilestop() + 25
        while i <= #ids and debugprofilestop() < budget do
            local id = ids[i]
            local okS, steps = pcall(G.Steps, id)
            local err
            if not okS then err = "parse crash: " .. tostring(steps)
            elseif not steps or #steps == 0 then
                local g = G.registry[id]
                if not (g.empty or g.dynamic or (g.type or "") == "Quests" and NS.DynamicQuests) then
                    local t = type(g.text) == "function" and g.text() or g.text
                    err = ("0 steps (text=%s len=%s head=%q)"):format(type(t), t and #tostring(t) or "-", tostring(t):sub(1, 60))
                end
            elseif (G.registry[id].parseErrors or 0) > 0 then
                local g = G.registry[id]
                local t = type(g.text) == "function" and g.text() or g.text
                local msgs, n = {}, 0
                for line in (tostring(t) .. "\n"):gmatch("([^\r\n]*)\r?\n") do
                    n = n + 1
                    local _, lerr = G.ParseLine(line, n, g.zone)
                    if lerr and #msgs < 3 then msgs[#msgs + 1] = ("L%d %s | %s"):format(n, lerr, line:sub(1, 80)) end
                end
                err = g.parseErrors .. " line errors: " .. table.concat(msgs, " ;; ")
            else
                local okL, lerr = pcall(NS.Progress.Load, id)
                if not okL then err = "load crash: " .. tostring(lerr) end
            end
            if err then res.failed = res.failed + 1 res.errors[#res.errors + 1] = id .. " :: " .. err end
            res.done = i
            i = i + 1
            if i % 1000 == 0 then NS:Print(("verifyall: %d/%d (%d failed)"):format(i, #ids, res.failed)) end
        end
        if i > #ids then
            fr:SetScript("OnUpdate", nil)
            res.finishedAt = date("%Y-%m-%d %H:%M:%S")
            if prevGuide then pcall(NS.Progress.Load, prevGuide) end
            NS:Print(("verifyall DONE: %d/%d guides OK, %d failed"):format(res.total - res.failed, res.total, res.failed))
            for k = 1, math.min(10, #res.errors) do NS:Print("  FAIL " .. res.errors[k]) end
            if onDone then pcall(onDone) end
        end
    end)
end

function NS.RunFeatureVerify(quiet)
    local res = { flavor = NS.flavor, build = tostring(NS.tocversion), at = date("%Y-%m-%d %H:%M:%S"),
                  addon = NS.version, checks = {} }
    local function chk(feature, name, fn)
        local ok, pass, detail = pcall(fn)
        if not ok then detail = tostring(pass) pass = false end
        res.checks[#res.checks + 1] = { feature = feature, name = name,
            pass = (pass and true or false), detail = tostring(detail or "") }
        if not quiet then
            NS:Print(("%s [%s] %s%s"):format(pass and "|cff00ff00PASS|r" or "|cffff4040FAIL|r",
                feature, name, detail and ("  - " .. tostring(detail)) or ""))
        end
    end
    local B, A = NS.Beacon, NS.Account

    chk("beacon", "module loaded", function() return B ~= nil end)
    chk("beacon", "names mined from current step", function()
        local t = {} for _, n in pairs(B.WantedNames()) do t[#t + 1] = n end
        return true, (#t > 0 and table.concat(t, ", ") or "none on this step")
    end)
    chk("beacon", "nameplate API present", function()
        return C_NamePlate and C_NamePlate.GetNamePlates ~= nil, "plates visible: " ..
            tostring(C_NamePlate and #(C_NamePlate.GetNamePlates(true) or {}) or 0)
    end)
    chk("beacon", "nameplate rescan runs", function() B.RescanPlates() return true, tostring(B.count) .. " tracked names" end)
    chk("beacon", "map pin library", function() return LibStub("HereBeDragons-Pins-2.0", true) ~= nil end)
    chk("beacon", "pins placed for step coords", function()
        B.UpdatePins()
        local s = P.current
        if not s or not s.coords then return true, "current step has no coords (nothing to pin)" end
        return true, #s.coords .. " coord(s) on map " .. tostring(s.zone)
    end)
    chk("beacon", "target button secure macro", function()
        B.UpdateTargetButton()
        if not B.targetButton.targetName then return true, "no named target on this step" end
        return B.targetButton:GetAttribute("macrotext") ~= nil, B.targetButton.targetName
    end)

    chk("account", "store initialised", function() return A and A.me ~= nil, A and A.key end)
    chk("account", "opt-in flag", function() return true, "accountWide=" .. tostring(NS.db.profile.accountWide) end)
    chk("account", "character roster", function()
        local c = A.Characters()
        return #c > 0, #c .. " character(s): " .. (function()
            local t = {} for i, x in ipairs(c) do if i <= 6 then t[#t + 1] = x.key .. "(" .. tostring(x.steps) .. ")" end end
            return table.concat(t, ", ") end)()
    end)
    chk("account", "per-guide progress math", function()
        if not P.guide or not P.steps then return false, "no guide loaded" end
        local cn, cp = A.GuideProgress(P.guide.id, #P.steps, "char")
        local an, ap = A.GuideProgress(P.guide.id, #P.steps, "account")
        return an >= cn, ("char %d/%d (%d%%), account %d/%d (%d%%)"):format(cn, #P.steps, cp, an, #P.steps, ap)
    end)
    chk("account", "opt-in gate honoured", function()
        -- with the opt-in OFF, another character's completion must never mark a step done
        local was = NS.db.profile.accountWide
        NS.db.profile.accountWide = false
        local leaked = A.OtherDid(P.guide and P.guide.id or "none", 1)
        NS.db.profile.accountWide = was
        return leaked == false, "off => other characters ignored"
    end)

    chk("account", "quest-level union", function()
        local q = 0 for _ in pairs(A.me.quests or {}) do q = q + 1 end
        return true, ("%d quests recorded, accountQuests=%s"):format(q, tostring(NS.db.profile.accountQuests))
    end)
    chk("core", "guides registered", function() return #NS.Guide.list > 0, #NS.Guide.list end)
    chk("core", "guide loaded + routed", function()
        return P.current ~= nil, P.guide and (P.guide.id .. " -> " .. P.current.action .. " " .. P.current.title) or "none"
    end)
    chk("core", "arrow shown", function()
        -- the arrow only paints on its own OnUpdate tick; drive one so this is not a race
        pcall(NS.Arrow.Update)
        return NS.Arrow.frame:IsShown(), NS.Arrow.frame:IsShown() and "visible" or
            ("enabled=" .. tostring(NS.db.profile.arrow.enabled) .. " step=" .. tostring(NS.Progress.current ~= nil))
    end)

    CompletionRouteDB.featureVerify = res
    local pass, fail = 0, 0
    for _, c in ipairs(res.checks) do if c.pass then pass = pass + 1 else fail = fail + 1 end end
    res.passed, res.failed = pass, fail
    NS:Print(("feature verify: %d passed, %d failed (%s) - saved to CompletionRouteDB.featureVerify"):format(pass, fail, NS.flavor))
    return res
end
