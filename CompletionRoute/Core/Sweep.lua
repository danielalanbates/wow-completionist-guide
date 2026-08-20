-- CompletionRoute :: Core/Sweep.lua
-- In-client route sweep: load EVERY guide (optionally one zone), from where you stand, and check
--   * steps resolve to a location, * the optimizer's order respects A < C < T / PRE, * the optimized
--   window is not slower than author order, * a route exists to step 1, * the guide window shows rows.
-- /cr sweep [zone name]   -> runs over a few seconds, prints a summary, saves CompletionRouteDB.routeSweep
-- Same checks as tools/route_sweep.lua (offline), but with the live client's maps, quest log and position.
local ADDON, NS = ...
local U = NS.Util

local function qkey(s) return s.qid and s.qid[1] end
local function precedenceOK(order)
    local firstA, lastC = {}, {}
    for i, s in ipairs(order) do
        local q = qkey(s)
        if q then
            local a = s.action
            if (a == "A" or a == "a" or a == "!") and not firstA[q] then firstA[q] = i end
            if a == "C" or a == "K" or a == "l" or a == "U" then lastC[q] = i end
        end
    end
    for i, s in ipairs(order) do
        local q = qkey(s)
        if q then
            local a = s.action
            if (a == "C" or a == "K" or a == "l" or a == "U" or a == "T" or a == "t") and firstA[q] and firstA[q] > i and s.index > order[firstA[q]].index then
                return false, ("%s of %d before its accept"):format(a, q)
            end
            if (a == "T" or a == "t") and lastC[q] and lastC[q] > i and s.index > order[lastC[q]].index then
                return false, ("turn-in of %d before its complete"):format(q)
            end
            if (a == "A" or a == "a") and s.pre then
                for _, pq in ipairs(s.pre) do
                    for j, s2 in ipairs(order) do
                        if j > i and (s2.action == "T" or s2.action == "t") and qkey(s2) == pq and s2.index < s.index then
                            return false, ("accept of %d before PRE %d turn-in"):format(q, pq)
                        end
                    end
                end
            end
        end
    end
    return true
end
local function chainCost(list)
    local R = NS.Router
    local t, prev = 0, nil
    for _, s in ipairs(list) do
        local c = prev and R.TravelSeconds(prev, s) or R.TravelSecondsFromPlayer(s)
        t = t + (c or 600)
        prev = s
    end
    return t
end

function NS.RunRouteSweep(zoneFilter)
    local G, P, R = NS.Guide, NS.Progress, NS.Router
    local want = zoneFilter and zoneFilter ~= "" and zoneFilter:lower() or nil
    local ids = {}
    for _, id in ipairs(G.list) do
        local g = G.registry[id]
        if not g.empty and NS.Cond.FactionMatch(g.faction) then
            local zn = g.zone and U.MapName(tonumber(g.zone) or U.MapIDByName(g.zone)) or ""
            if not want or zn:lower():find(want, 1, true) or (g.name or ""):lower():find(want, 1, true) then ids[#ids + 1] = id end
        end
    end
    if #ids == 0 then NS:Print("sweep: no guides match '" .. tostring(zoneFilter) .. "'") return end
    local res = { flavor = NS.flavor, zoneFilter = zoneFilter, total = #ids, done = 0, loadFail = 0, precedence = 0, slower = 0, noRoute = 0,
                  steps = 0, located = 0, uiEmpty = 0, errors = {}, startedAt = date("%Y-%m-%d %H:%M:%S"), where = GetZoneText and GetZoneText() or "?" }
    CompletionRouteDB.routeSweep = res
    local prevGuide = P.guide and P.guide.id
    if NS.Account and NS.Account.BeginScratch then NS.Account.BeginScratch() end
    local window = NS.db.profile.routing.window or 10
    local i, fr = 1, CreateFrame("Frame")
    NS:Print(("sweep: %d guides from %s..."):format(#ids, res.where))
    fr:SetScript("OnUpdate", function()
        local budget = debugprofilestop() + 20
        while i <= #ids and debugprofilestop() < budget do
            local id = ids[i]
            local g = G.registry[id]
            local steps = G.Steps(id) or {}
            local err
            NS.db.char.done[id], NS.db.char.skipped[id] = {}, {}
            local okL, e = pcall(P.Load, id)
            if not okL then err = "load: " .. tostring(e) res.loadFail = res.loadFail + 1
            else
                local loc = 0
                for _, s in ipairs(steps) do if R.StepWorld(s) then loc = loc + 1 end end
                res.steps, res.located = res.steps + #steps, res.located + loc
                local order = P.order or {}
                local ok, why = precedenceOK(order)
                if not ok then res.precedence = res.precedence + 1 err = "order: " .. why end
                local author = P.Pending(#order)
                local head, ahead = {}, {}
                for k = 1, math.min(window, #order) do head[k] = order[k] ahead[k] = author[k] end
                local okC, a, b = pcall(function() return chainCost(head), chainCost(ahead) end)
                if okC and a > b + 1 then res.slower = res.slower + 1 err = (err and err .. "; " or "") .. ("slower %.0fs vs %.0fs"):format(a, b) end
                if order[1] and R.StepWorld(order[1]) then
                    local path = R.CurrentPath(true)
                    if not path then res.noRoute = res.noRoute + 1 err = (err and err .. "; " or "") .. "no route to step 1" end
                end
                if NS.GuideFrame and NS.GuideFrame.Update then
                    pcall(NS.GuideFrame.Update)
                    if #order > 0 and NS.GuideFrame.RowsShown and NS.GuideFrame.RowsShown() == 0 then res.uiEmpty = res.uiEmpty + 1 err = (err and err .. "; " or "") .. "guide window shows no rows" end
                end
            end
            if err then res.errors[#res.errors + 1] = id .. " :: " .. err end
            res.done = i
            i = i + 1
            if i % 250 == 0 then NS:Print(("sweep: %d/%d"):format(i, #ids)) end
        end
        if i > #ids then
            fr:SetScript("OnUpdate", nil)
            res.finishedAt = date("%Y-%m-%d %H:%M:%S")
            if NS.Account and NS.Account.EndScratch then NS.Account.EndScratch() end
            if prevGuide then pcall(P.Load, prevGuide) end
            NS:Print(("|cff00ff00sweep DONE|r %d guides: located %d/%d steps (%.1f%%), order violations %d, optimizer slower %d, no route %d, empty window %d, load fail %d"):format(
                res.total, res.located, res.steps, 100 * res.located / math.max(1, res.steps), res.precedence, res.slower, res.noRoute, res.uiEmpty, res.loadFail))
            for k = 1, math.min(8, #res.errors) do NS:Print("  " .. res.errors[k]) end
            if #res.errors > 8 then NS:Print(("  ... %d more in SavedVariables (CompletionRouteDB.routeSweep)"):format(#res.errors - 8)) end
        end
    end)
end
