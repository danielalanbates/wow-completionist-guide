-- Step census: which steps of the guides this checkout ships complete by themselves, and from what.
-- Run from the repo root:  luajit -joff tools/census_step_kinds.lua [flavor ...]
-- Walks every guide each flavor TOC loads (tools/guide_walk.lua), parses every step with the addon's own parser and
-- sorts it by the rule in Core/Progress.lua that completes it (NS.StepSignal.Of in Core/Guide.lua names the rule and
-- mirrors P.CheckStep: the harness tools/test_flow.lua runs both on the same steps).  Steps no rule covers are listed as MANUAL with what they do carry, so
-- the next rule to write is visible.  Offline, text only: nothing is read from a client.
local W = dofile("tools/guide_walk.lua")

local want = {}
for _, a in ipairs(arg or {}) do want[a] = true end

local grand = {}
for _, fl in ipairs(W.FLAVORS) do
    if not next(want) or want[fl.name] then
        local fam = {}        -- family -> { guides, reused, steps, auto, bySignal = {}, manual = {} }
        local Sig
        local function F(name)
            local t = fam[name]
            if not t then t = { guides = 0, reused = 0, steps = 0, auto = 0, new = 0, bySignal = {}, manual = {} } fam[name] = t end
            return t
        end
        local _, missing, errors = W.Walk(fl, function(s, g, family, NS)
            Sig = Sig or NS.StepSignal      -- the rule table lives in the addon (Core/Guide.lua), so the census cannot drift from it
            local t = F(family)
            t.steps = t.steps + 1
            local signal, hint, isNew = Sig.Of(s, g)
            if signal then
                t.auto = t.auto + 1
                if isNew then t.new = t.new + 1 end
                local k = s.action .. "  " .. signal .. (isNew and "   [new 2026-11-12]" or "")
                t.bySignal[k] = (t.bySignal[k] or 0) + 1
            else
                local k = s.action .. "  " .. (hint or "nothing to read")
                t.manual[k] = (t.manual[k] or 0) + 1
            end
        end, function(g, family, _, reused)
            local t = F(family)
            if reused then t.reused = t.reused + 1 else t.guides = t.guides + 1 end
        end)
        print(("== %s (%s) =="):format(fl.name, fl.toc))
        for _, m in ipairs(missing) do print("   not generated here: " .. m) end
        for _, e in ipairs(errors) do print("   LOAD ERROR " .. e) end
        local function dump(tbl, indent)
            local keys = {}
            for k in pairs(tbl) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) if tbl[a] ~= tbl[b] then return tbl[a] > tbl[b] end return a < b end)
            for _, k in ipairs(keys) do print(("%s%8d  %s"):format(indent, tbl[k], k)) end
        end
        for _, name in ipairs(W.FAMILY_ORDER) do
            local t = fam[name]
            if t then
                if t.steps == 0 then
                    print(("-- %s: %d entries that reuse their zone guide's steps (counted there)"):format(name, t.reused))
                else
                    print(("-- %s: %d guides, %d steps, %d complete by themselves (%.1f%%; %d of them by a rule new on 2026-11-12), %d manual"):format(
                        name, t.guides, t.steps, t.auto, t.steps > 0 and t.auto / t.steps * 100 or 0, t.new, t.steps - t.auto))
                    print("   completes by itself:")
                    dump(t.bySignal, "   ")
                    if next(t.manual) then
                        print("   MANUAL (click the forward arrow):")
                        dump(t.manual, "   ")
                    end
                end
                local g = grand[name] or { steps = 0, auto = 0, new = 0 }
                g.steps, g.auto, g.new = g.steps + t.steps, g.auto + t.auto, g.new + t.new
                grand[name] = g
            end
        end
        print()
        collectgarbage()
    end
end
print("== all flavors ==")
for _, name in ipairs(W.FAMILY_ORDER) do
    local g = grand[name]
    if g and g.steps > 0 then
        print(("%-38s %8d steps  %8d by themselves (%.1f%%), %d of them newly  %7d manual"):format(name, g.steps, g.auto, g.auto / g.steps * 100, g.new, g.steps - g.auto))
    end
end
