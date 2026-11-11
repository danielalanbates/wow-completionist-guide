-- Offline smoke test for CompletionRoute's parser + routing, run with: luajit tools/test_offline.lua
-- Stubs just enough of the WoW API + HereBeDragons to exercise Guide.ParseLine, TravelGraph.FindPath, StepOrder.
package.path = "./?.lua;" .. package.path
local ADDON, NS = "CompletionRoute", {}
dofile("tools/stubs.lua")
local z2w, MAPS = z2w, MAPS
PLAYER = { map = 1429, x = 0.487, y = 0.42 } PLAYER.wx, PLAYER.wy, PLAYER.inst = z2w(PLAYER.x, PLAYER.y, PLAYER.map)
-- ---- load addon files ----
local function load(path)
    if path:match("^Guides/Imported_") and not io.open("CompletionRoute/" .. path, "r") then
        print("skip " .. path .. " (baked locally, gitignored)") return
    end
    local fn = assert(loadfile("CompletionRoute/" .. path)) fn(ADDON, NS)
end
for _, f in ipairs({ "Core/Init.lua", "Core/Util.lua", "Core/Conditions.lua", "Core/Guide.lua", "Data/Taxi_tbc.lua", "Data/Transit.lua", "Data/Access.lua", "Data/Inns.lua", "Data/ZoneAliases.lua", "Data/Roads_ek.lua", "Data/Roads_kalimdor.lua", "Routing/TravelGraph.lua", "Routing/Roads.lua", "Routing/StepOrder.lua", "Routing/Router.lua", "Core/Account.lua", "Core/Professions.lua", "Core/Progress.lua", "Core/Recommend.lua", "Core/Sweep.lua", "Adapters/WoWPro.lua", "Guides/Imported_WoWPro_tbc.lua", "Guides/Imported_WoWPro.lua" }) do load(f) end
-- fake ADDON_LOADED
CompletionRouteDB, CompletionRouteCharDB = nil, nil
for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", "CompletionRoute") end
NS.db.profile.debug = true
NS.db.profile.routing.assumeAllTaxi = true
-- 1) parser
local s = NS.Guide.ParseLine("C Wolves Across the Border|QID|33|M|46.89,39.05;51.6,40.9|Z|1429; Elwynn Forest|L|750 8|N|Diseased Young Wolves.|S|", 1)
assert(s.action == "C" and s.qid[1] == 33 and #s.coords == 2 and s.zone == 1429 and s.loot[1].id == 750 and s.loot[1].qty == 8 and s.sticky, "parse failed")
print("parser OK:", s.title, s.zone, s.coords[1].x, s.note)
-- 2) travel graph
NS.TravelGraph.Build()
print("graph nodes:", #NS.TravelGraph.nodes)
local sx, sy, si = z2w(0.487, 0.42, 1429)     -- Northshire
local gx, gy, gi = z2w(0.526, 0.657, 1453)    -- Stormwind
local p = NS.TravelGraph.FindPath(sx, sy, si, gx, gy, gi, {})
print("Northshire->Stormwind:", NS.TravelGraph.Describe(p))
gx, gy, gi = z2w(0.30, 0.44, 1439)            -- Darkshore (other continent -> needs boat)
p = NS.TravelGraph.FindPath(sx, sy, si, gx, gy, gi, {})
print("Northshire->Darkshore:", NS.TravelGraph.Describe(p))
assert(p, "no cross-continent path")
gx, gy, gi = z2w(0.4, 0.5, 1436)              -- Westfall, hearth is Goldshire (seed inn) - far walk vs hearth
local wx1, wy1, wi1 = z2w(0.5, 0.5, 1437) p = NS.TravelGraph.FindPath(wx1, wy1, wi1, gx, gy, gi, {}) assert(p and p.legs[1].mode == "hearth", "expected hearth-first path") -- from Wetlands to Westfall
print("Wetlands->Westfall:", NS.TravelGraph.Describe(p))
-- 3) step ordering
local steps = {}
for i, line in ipairs({
 "A Q1|QID|1|M|48,42|Z|1429; Elwynn Forest|",
 "C Q1|QID|1|M|48,36|Z|1429; Elwynn Forest|",
 "A Q2|QID|2|M|48,42|Z|1429; Elwynn Forest|",
 "C Q2|QID|2|M|53,45|Z|1429; Elwynn Forest|",
 "T Q1|QID|1|M|48,42|Z|1429; Elwynn Forest|",
 "T Q2|QID|2|M|48,42|Z|1429; Elwynn Forest|",
 "R Goldshire|M|43,65|Z|1429; Elwynn Forest|",
 "A Q3|QID|3|M|42,66|Z|1429; Elwynn Forest|",
}) do steps[i] = NS.Guide.ParseLine(line, i) steps[i].index = i end
local ordered = NS.StepOrder.Order(steps, NS.Router)
for i, st in ipairs(ordered) do io.write(("%d:%s%s "):format(st.index, st.action, st.title)) end print()
-- constraints: A1 before C1 before T1; A2 before C2 before T2; R(7) after all of 1-6, A3 after R
local pos = {} for i, st in ipairs(ordered) do pos[st.index] = i end
assert(pos[1] < pos[2] and pos[2] < pos[5] and pos[3] < pos[4] and pos[4] < pos[6] and pos[7] > pos[6] and pos[7] > pos[5] and pos[8] > pos[7], "constraint violated")
print("StepOrder OK (Q1 accept ->", pos[1], " both accepts adjacent:", math.abs(pos[1]-pos[3]) == 1, ")")
-- 4) SuggestNext: level fit + travel-time tiebreak from player position (lvl 5, standing in Elwynn)
local function regGuide(id, name, minl, maxl, zone, x, y, src)
    NS.Guide.Register({ id = id, name = name, type = "Leveling", faction = "Alliance", minlevel = minl, maxlevel = maxl, source = src or "test",
        text = ("R %s|M|%.1f,%.1f|Z|%d; %s|"):format(name, x, y, zone, (MAPS[zone] or {})[1] or "?") })
end
regGuide("t:elwynn", "Elwynn 5-10", 5, 10, 1429, 48, 42)
regGuide("t:darkshore", "Darkshore 5-10", 5, 10, 1439, 30, 44)   -- same fit, other continent
regGuide("t:westfall", "Westfall 10-20", 10, 20, 1436, 40, 50)   -- out of level range
local nxt, eta = NS.Guide.SuggestNext(nil)
assert(nxt and nxt.id == "t:elwynn", "SuggestNext picked " .. tostring(nxt and nxt.id) .. " (want nearby t:elwynn)")
print(("SuggestNext OK: %s eta %s s"):format(nxt.id, tostring(eta and math.floor(eta))))
local nxt2 = NS.Guide.SuggestNext("t:elwynn")                     -- just finished elwynn -> excluded
assert(nxt2 and nxt2.id == "t:darkshore", "exclude failed: " .. tostring(nxt2 and nxt2.id))
UnitLevel = function() return 11 end                              -- ding: only Westfall fits now
local nxt3 = NS.Guide.SuggestNext("t:elwynn")
assert(nxt3 and nxt3.id == "t:westfall", "level refilter failed: " .. tostring(nxt3 and nxt3.id))
UnitLevel = function() return 21 end                              -- above all ranges -> nearest bracket above = none
assert(NS.Guide.SuggestNext(nil) == nil or true)                  -- must not error
UnitLevel = function() return 8 end                               -- gap: 8 not in 10-20, elwynn/darkshore 5-10 still fit
print("SuggestNext exclude/refit OK")
-- 5) baked guide import (standalone, no external addons)
local BAKED = io.open("CompletionRoute/Guides/Imported_WoWPro.lua", "r") ~= nil or io.open("CompletionRoute/Guides/Imported_WoWPro_tbc.lua", "r") ~= nil
local nw = NS.Adapters.WoWPro and NS.Adapters.WoWPro.ImportStatic() or 0
print(("baked import: %d wowpro"):format(nw))
if BAKED then
    assert(nw > 0, "expected baked WoW-Pro guides, got " .. nw)
else
    print("baked-count assertions SKIPPED (guides not baked; run tools/install.sh)")
end
-- 5b) generated quest DB guides (flavor-gated: harness reports TBC 2.5.6 -> only _tbc loads)
-- Since the wiki pipeline the clients load Imported_Wiki_<fl> + Imported_Quests_<fl>_gaps (tools/wiki/gen_wiki_guides.py);
-- the era files are loaded too, to prove the flavor gate keeps them out of a TBC client.
local QFILES = { "Guides/Imported_Wiki_era.lua", "Guides/Imported_Quests_era_gaps.lua",
                 "Guides/Imported_Wiki_tbc.lua", "Guides/Imported_Quests_tbc_gaps.lua" }
local fq = io.open("CompletionRoute/Guides/Imported_Wiki_tbc.lua")
if not fq then
    QFILES = { "Guides/Imported_Quests_era.lua", "Guides/Imported_Quests_tbc.lua" }
    fq = io.open("CompletionRoute/Guides/Imported_Quests_tbc.lua")
end
if fq then
    fq:close()
    for _, qf in ipairs(QFILES) do load(qf) end
    local qGuides, qSteps = 0, 0
    for _, id in ipairs(NS.Guide.list) do
        local g = NS.Guide.registry[id]
        if (g.type or "") == "Quests" then
            qGuides = qGuides + 1
            if qSteps <= 10 then local st = NS.Guide.Steps(id) qSteps = math.max(qSteps, st and #st or 0) end
            assert(not id:find("^qdb:era") and not id:find("^wiki:era"), "era quest guides leaked into tbc flavor: " .. id)
        end
    end
    assert(qGuides > 150, "expected >150 tbc quest guides, got " .. qGuides)
    assert(qSteps > 10, "quest guide steps did not parse")
    print(("quest DB guides OK: %d zone guides (tbc), sample parsed %d steps"):format(qGuides, qSteps))
else
    print("quest DB guides SKIPPED (Imported_Wiki_tbc.lua / Imported_Quests_tbc.lua not generated)")
end
-- 6) guide menu tree (organization): categories ordered, every guide reachable, search works
GameTooltip = CreateFrame()
local fn = assert(loadfile("CompletionRoute/UI/GuideMenu.lua")) fn(ADDON, NS)
local T = NS.GuideMenu._test
local root = T.buildTree()
assert(#root.kids >= 1, "tree has no top-level categories")
if BAKED then assert(#root.kids > 1, "tree has only " .. #root.kids .. " top-level categories") end
-- "For level N" is the synthetic section of per-category picks and always sorts first when non-empty;
-- Leveling is the first real category after it.
local firstReal = root.kids[1].forLevel and root.kids[2] or root.kids[1]
assert(firstReal and firstReal.name == "Leveling", "first real category is " .. tostring(firstReal and firstReal.name))
local total = #NS.Guide.Available()
local nextN = #NS.GuideMenu.NextStepGuides(true)
assert(root.count == total + nextN, ("tree count %d ~= available %d + picks %d"):format(root.count, total, nextN))
assert(root.kids[1].forLevel or nextN == 0, "For level section is not the first category")
-- every pick must actually fit the level (or be level-agnostic)
UnitLevel = function() return 8 end
for _, g in ipairs(NS.GuideMenu.NextStepGuides(true)) do
    if g.minlevel or g.maxlevel then
        assert((not g.minlevel or 8 >= g.minlevel) and (not g.maxlevel or 8 <= g.maxlevel),
            ("For level picked %s [%s-%s] at level 8"):format(g.id, tostring(g.minlevel), tostring(g.maxlevel)))
    end
end
print(("For level section OK: %d picks at level 8"):format(#NS.GuideMenu.NextStepGuides(true)))
-- expand everything: every guide must appear exactly once as a row
local function expandAll(n) for _, k in ipairs(n.kids) do T.expanded[k.path] = true expandAll(k) end end
expandAll(root)
local rows = T.visibleRows()
local guideRows = 0 for _, r in ipairs(rows) do if r.kind == "guide" then guideRows = guideRows + 1 end end
assert(guideRows == total + nextN, ("expanded rows %d ~= available %d + next %d"):format(guideRows, total, nextN))
for k in pairs(T.expanded) do T.expanded[k] = nil end
-- collapsed: only top-level category rows, no guides
local collapsed = T.visibleRows()
for _, r in ipairs(collapsed) do assert(r.kind == "node" and r.depth == 0, "collapsed view leaked a non-root row") end
assert(#collapsed == #root.kids, "collapsed row count")
-- search returns only matching guide rows
local sr = T.searchRows("elwynn")
if BAKED then assert(#sr > 0, "search 'elwynn' found nothing") end
for _, r in ipairs(sr) do assert(r.kind == "guide") end
print(("menu tree OK: %d categories, %d guides reachable, %d search hits for 'elwynn'"):format(#root.kids, guideRows, #sr))

-- ---------------------------------------------------------------------------
-- Guide menu header + the completion column on the right of every row
-- ---------------------------------------------------------------------------
do
    local src = (function() local h = assert(io.open("CompletionRoute/UI/GuideMenu.lua")) local t = h:read("*a") h:close() return t end)()
    assert(src:find('"CompletionRouteGuideMenuScope"'), "no scope selector at the top of the guide menu")
    assert(src:find("stepScope") and src:find("ScrollUpButton") and src:find("ScrollDownButton"), "scope must step with up/down arrows")
    assert(src:find("b.right"), "no right-hand completion column")
    assert(src:find("completed"), "completion count text missing")

    -- the four scopes, narrow to wide, each with a label and an explanation
    local A2 = NS.Account
    assert(#A2.SCOPES == 4 and A2.SCOPES[1] == "char" and A2.SCOPES[4] == "account", "scope order")
    for _, sc in ipairs(A2.SCOPES) do
        A2.SetScope(sc)
        assert(A2.Scope() == sc, "scope did not stick: " .. sc)
        assert(A2.ScopeLabel(sc) ~= "?" and #A2.ScopeDetail(sc) > 0, "scope " .. sc .. " has no label/detail")
        assert(NS.db.profile.accountWide == (sc ~= "char"), "legacy accountWide mirror out of step for " .. sc)
        NS.GuideMenu.UpdateScopeLabel()
    end
    assert(A2.ScopeLabel("realm") == "This server" and A2.ScopeLabel("flavor") == "This game type", "scope labels")
    assert(A2.GameTypeName("tbc"):find("Anniversary") and A2.GameTypeName("retail"):find("Modern")
           and A2.GameTypeName("era-hardcore"):find("Hardcore"), "game type names")

    -- scope actually filters other characters: same realm counts under "realm", a foreign realm does not
    NS.db.global.chars["Sameserver-Test"] = { name = "Sameserver", realm = NS.Account.me.realm, flavor = NS.flavor,
        gametype = NS.Account.GameType(), faction = "Alliance", quests = { [4243] = true }, done = {} }
    NS.db.global.chars["Otherserver-Elsewhere"] = { name = "Otherserver", realm = "Elsewhere", flavor = "retail",
        gametype = "retail", faction = "Alliance", quests = { [4244] = true }, done = {} }
    A2.SetScope("realm")
    assert(A2.CharInScope("Sameserver-Test", NS.db.global.chars["Sameserver-Test"]) == true, "same-realm alt excluded")
    assert(A2.CharInScope("Otherserver-Elsewhere", NS.db.global.chars["Otherserver-Elsewhere"]) == false, "foreign-realm alt included")
    A2.SetScope("flavor")
    assert(A2.CharInScope("Otherserver-Elsewhere", NS.db.global.chars["Otherserver-Elsewhere"]) == false, "other game type included")
    A2.SetScope("account")
    assert(A2.CharInScope("Otherserver-Elsewhere", NS.db.global.chars["Otherserver-Elsewhere"]) == true, "account scope excluded someone")
    A2.SetScope("char")
    NS.db.global.chars["Sameserver-Test"], NS.db.global.chars["Otherserver-Elsewhere"] = nil, nil

    -- the background scan fills in per-guide answers and the node roll-up counts them
    NS.Guide.Register({ id = "t:menu:done", name = "Menu Done", type = "Events", faction = "Alliance", source = "test",
        text = "T Finished Thing|QID|4242|M|48,42|Z|1429; Elwynn Forest|" })
    NS.Guide.Register({ id = "t:menu:open", name = "Menu Open", type = "Events", faction = "Alliance", source = "test",
        text = "T Unfinished Thing|QID|4243|M|48,42|Z|1429; Elwynn Forest|" })
    NS.Account.me.quests[4242] = true
    NS.Account.ClearCompletionCaches()
    NS.GuideMenu.RescanCompletion()
    local guard = 0
    repeat guard = guard + 1 until T.scanSlice() or guard > 500
    local sc = T.scanned()
    assert(sc["t:menu:done"] == true, "a guide whose quest is done did not scan as complete")
    assert(sc["t:menu:open"] == false, "an unfinished guide scanned as complete")
    local events = T.buildTree().kidByName["Events"]
    assert(events, "no Events category")
    local d, tot, pending = T.nodeCompletion(events)
    assert(pending == 0, "scan left rows unresolved: " .. pending)
    assert(d >= 1 and tot >= 2, ("Events roll-up wrong: %d/%d"):format(d, tot))
end
print("guide menu OK: four-way scope selector, per-guide scan, category completion counts")

-- 7) account-wide progression
NS.Account.Init()
local AK = NS.Account.key
assert(AK == "Tester-Test", "account key " .. tostring(AK))
NS.Guide.Register({ id = "t:acct", name = "Acct Test", faction = "Alliance", minlevel = 1, maxlevel = 5, source = "test",
    text = "A One|QID|901|M|48,42|Z|1429; Elwynn Forest|\nA Two|QID|902|M|49,42|Z|1429; Elwynn Forest|\nA Three|QID|903|M|50,42|Z|1429; Elwynn Forest|\nA Four|QID|904|M|51,42|Z|1429; Elwynn Forest|" })
local ast = NS.Guide.Steps("t:acct")
assert(#ast == 4, "acct guide steps " .. #ast)
NS.Progress.Load("t:acct")
NS.Progress.MarkDone(ast[1])
local cn, cp = NS.Account.GuideProgress("t:acct", 4, "char")
assert(cn == 1 and cp == 25, ("char progress %d/%d%%"):format(cn, cp))
-- a second character on the account finished steps 2 and 3
NS.db.global.chars["Alt-Test"] = { name = "Alt", realm = "Test", class = "MAGE", faction = "Alliance",
    done = { ["t:acct"] = { [2] = true, [3] = true } }, skipped = {} }
local an, ap = NS.Account.GuideProgress("t:acct", 4, "account")
assert(an == 3 and ap == 75, ("account progress %d/%d%%"):format(an, ap))
-- opt-in OFF: the alt's work must not affect this character
NS.db.profile.accountWide = false
assert(NS.Progress.IsDone(ast[2]) == false, "accountWide OFF leaked the alt's progress")
assert(NS.Account.OtherDid("t:acct", 2) == false, "OtherDid must respect the opt-in")
-- opt-in ON: it does
NS.db.profile.accountWide = true
assert(NS.Progress.IsDone(ast[2]) == true, "accountWide ON did not honour the alt's progress")
assert(NS.Account.OtherDid("t:acct", 2) == "Alt-Test")
assert(NS.Progress.IsDone(ast[4]) == false, "step nobody did came back done")
-- pending list shrinks to the one step no character has done
NS.Progress.Refresh()
local pend = NS.Progress.Pending(10)
assert(#pend == 1 and pend[1].index == 4, "pending = " .. #pend)
assert(#NS.Account.Characters() == 2, "character roster")
-- quest-level union: an alt that turned in a quest clears the matching step in ANOTHER guide
NS.Guide.Register({ id = "t:acct2", name = "Acct Test B", faction = "Alliance", minlevel = 1, maxlevel = 5, source = "test",
    text = "T One|QID|901|M|48,42|Z|1429; Elwynn Forest|\nT Nine|QID|909|M|48,42|Z|1429; Elwynn Forest|" })
local bst = NS.Guide.Steps("t:acct2")
NS.db.global.chars["Alt-Test"].quests = { [901] = true }
NS.db.profile.accountWide = true
NS.Progress.Load("t:acct2")
assert(NS.Progress.IsDone(bst[1]) == true, "quest 901 done on an alt did not clear the step in another guide")
assert(NS.Progress.IsDone(bst[2]) == false, "quest nobody did came back done")
NS.db.profile.accountQuests = false
assert(NS.Progress.IsDone(bst[1]) == false, "accountQuests=false still unioned by quest id")
NS.db.profile.accountQuests = true
NS.db.profile.accountWide = false
assert(NS.Progress.IsDone(bst[1]) == false, "accountWide=false still unioned by quest id")
NS.db.profile.accountWide = true
NS.Progress.Load("t:acct")
assert(NS.Account.Forget("Alt-Test") == true and NS.Account.Forget(AK) == false, "forget rules")
NS.db.global.chars["Alt-Test"] = { name = "Alt", done = { ["t:acct"] = { [2] = true, [3] = true } } }
NS.db.profile.accountWide = false
-- a bulk sweep must not write into the character's real progress
do
    local before = 0
    for _ in pairs(NS.Account.me.done) do before = before + 1 end
    NS.Account.BeginScratch()
    NS.Progress.Load("t:acct")
    NS.Progress.MarkDone(NS.Guide.Steps("t:acct")[2])
    NS.Account.Done("t:sweep-noise")[99] = true
    NS.Account.EndScratch()
    local after = 0
    for _ in pairs(NS.Account.me.done) do after = after + 1 end
    assert(after == before, ("sweep polluted progress: %d -> %d guides"):format(before, after))
    assert(NS.Account.me.done["t:sweep-noise"] == nil, "scratch write leaked")
end
print("account-wide progression OK: char 25%, account 75%, opt-in gate honoured both ways")

-- ---------------------------------------------------------------------------
-- Manual step navigation: Back must reopen the previous step and KEEP it open even though the
-- game still reports its quest as complete (that re-tick is what made the Back arrow a no-op).
-- ---------------------------------------------------------------------------
do
    NS.db.profile.accountWide = false
    NS.Guide.Register({ id = "t:nav", name = "Nav Test", faction = "Alliance", minlevel = 1, maxlevel = 5, source = "test",
        text = "T One|QID|801|M|48,42|Z|1429; Elwynn Forest|\nT Two|QID|802|M|48,42|Z|1429; Elwynn Forest|\nT Three|QID|803|M|48,42|Z|1429; Elwynn Forest|" })
    COMPLETED_QUESTS = { 801, 802 }   -- the game says these two are already finished
    NS.Progress.Load("t:nav")
    local st = NS.Progress.steps
    NS.Progress.Refresh()
    assert(NS.Progress.current == st[3], "autofill should land on step 3")
    NS.Progress.Undo()
    assert(NS.Progress.current == st[2], "Back did not move to step 2")
    NS.Progress.Refresh()
    assert(NS.Progress.current == st[2], "Back was undone by the auto-completer")
    NS.Progress.Undo()
    assert(NS.Progress.current == st[1], "second Back did not reach step 1")
    NS.Progress.Forward()
    assert(NS.Progress.current == st[2], "Forward did not advance")
    -- a done step far AHEAD of the current one must not be what Back picks
    NS.Progress.MarkDone(st[3])
    NS.Progress.Undo()
    assert(NS.Progress.current ~= st[3], "Back jumped forward to a look-ahead step")
    NS.Progress.Reset()
    COMPLETED_QUESTS = {}
end
print("manual step navigation OK: Back reopens and pins, Forward advances")

-- PRE lists: ";" = any one prerequisite, "&" = all of them
do
    local one = NS.Guide.ParseLine("A Vengeful|QID|10842|PRE|10849;10852|M|37,50|Z|1952; Terokkar Forest|", 1)
    local all = NS.Guide.ParseLine("A Vengeful|QID|10842|PRE|10849&10852|M|37,50|Z|1952; Terokkar Forest|", 1)
    assert(one.pre.andor == "or" and all.pre.andor == "and", "PRE and/or parse")
    COMPLETED_QUESTS = { 10849 }
    assert(NS.Cond.StepApplies(one) == true, "any-of prereq with one done should apply")
    assert(NS.Cond.StepApplies(all) == false, "all-of prereq with one missing should not apply")
    COMPLETED_QUESTS = { 10849, 10852 }
    assert(NS.Cond.StepApplies(all) == true, "all-of prereq fully done should apply")
    COMPLETED_QUESTS = {}
end
print("prereq gating OK: any-of vs all-of PRE lists")

-- ---------------------------------------------------------------------------
-- Death: the pointer stops offering the Hearthstone / quest items (unusable as a corpse) and points
-- at the body instead.  Works with a guide loaded or not.
-- ---------------------------------------------------------------------------
do
    NS.Guide.Register({ id = "t:dead", name = "Dead Test", faction = "Alliance", minlevel = 1, maxlevel = 5, source = "test",
        text = "H Hearth to Sentinel Hill|M|20,20|Z|1436; Westfall|" })
    NS.Progress.Load("t:dead")
    local alive = NS.Router.Recommendation()
    assert(alive.mode == "hearth", "alive: hearth step should offer the Hearthstone, got " .. tostring(alive.mode))

    PLAYER_DEAD = true
    local justdied = NS.Router.Recommendation()
    assert(justdied.dead and justdied.mode == "release", "dead-but-not-released should ask for a release, got " .. tostring(justdied.mode))
    assert(not justdied.item and not justdied.spell, "no usable item while dead")

    PLAYER_DEAD, PLAYER_GHOST = false, true
    CORPSE_POS = { 1429, 0.60, 0.30 }
    local ghost = NS.Router.Recommendation()
    assert(ghost.mode == "corpse" and ghost.wx, "ghost should be pointed at the corpse")
    assert(not ghost.item and not ghost.spell, "no Hearthstone while dead")
    local cwx, cwy = z2w(0.60, 0.30, 1429)
    assert(math.abs(ghost.wx - cwx) < 1 and math.abs(ghost.wy - cwy) < 1, "corpse world coords wrong")
    assert(ghost.dist and ghost.dist > 0, "corpse distance")

    CORPSE_POS = nil
    local nopos = NS.Router.Recommendation()
    assert(nopos.mode == "corpse" and not nopos.wx and nopos.why, "unknown corpse position must still say something useful")

    PLAYER_GHOST = false
    assert(NS.Router.IsDead() == false, "alive again")
    NS.Progress.Reset()
end
print("death handling OK: no hearth as a corpse, pointer aims at the body")

-- pointer style: hand tinted to the class colour, arrow chevron still selectable
do
    local f = assert(io.open("CompletionRoute/UI/Arrow.lua"))
    local src = f:read("*a") f:close()
    assert(src:find('TEX %.%. "hand"'), "hand texture not used")
    assert(src:find("RAID_CLASS_COLORS"), "hand is not tinted to the class colour")
    assert(src:find("SetVertexColor"), "no vertex colouring")
    assert(src:find("rec.dead"), "arrow has no dead branch")
    local h = assert(io.open("CompletionRoute/Textures/hand.tga")) h:close()
    local o = assert(io.open("CompletionRoute/UI/Options.lua"))
    local osrc = o:read("*a") o:close()
    assert(osrc:find("arrow.style"), "no pointer style option")
end
print("pointer style OK: class-coloured hand default, chevron still available")

-- 8) target beacon
local Bfn = assert(loadfile("CompletionRoute/UI/Beacon.lua")) Bfn(ADDON, NS)
local BT = NS.Beacon
assert(BT._test.cleanName("Marshal McBride ") == "Marshal McBride")
assert(BT._test.cleanName("Kobold Vermin (x8)") == "Kobold Vermin")
assert(BT._test.cleanName("12") == nil, "numeric fragment accepted as a name")
local function wantsFor(line)
    local st = NS.Guide.ParseLine(line, 1) st.index = 1
    NS.Progress.current = st
    NS.Progress.order = { st }
    return NS.Beacon.WantedNames()
end
local w = wantsFor("A Kobold Camp Cleanup|QID|11|M|48,42|Z|1429; Elwynn Forest|N|from Marshal McBride|T|Marshal McBride|")
assert(w["marshal mcbride"] == "Marshal McBride", "|T| target not picked up")
w = wantsFor("T A Threat Within|QID|12|M|48,42|Z|1429; Elwynn Forest|")
assert(w["a threat within"] == nil, "turn-in with no 'to' should not invent a name")
w = wantsFor("T Report to Goldshire to Marshal Dughan|QID|13|M|43,65|Z|1429; Elwynn Forest|")
assert(w["marshal dughan"] == "Marshal Dughan", "turn-in NPC not mined from title: " .. tostring(next(w)))
w = wantsFor("K Kill Hogger|QID|14|M|30,50|Z|1429; Elwynn Forest|")
assert(w["hogger"] == "Hogger", "kill target not mined")
w = wantsFor("N Talk to Shadow Hunter Denjai|M|48,42|Z|1429; Elwynn Forest|")
assert(w["shadow hunter denjai"] == "Shadow Hunter Denjai", "note 'Talk to X' not mined: " .. tostring(next(w)))
w = wantsFor("C Kill 6 Cavern Crawler|QID|16|M|48,42|Z|1429; Elwynn Forest|")
assert(next(w) == nil or w["cavern crawler"] ~= nil, "C step invented a bad name: " .. tostring(next(w)))
w = wantsFor("A Bounty on Murlocs from Guard Thomas|QID|15|M|43,65|Z|1429; Elwynn Forest|")
assert(w["guard thomas"] == "Guard Thomas", "accept NPC not mined")
-- nameplate marker attaches only for wanted units, and clears when the step moves on
NAMEPLATES = { { namePlateUnitToken = "nameplate1" }, { namePlateUnitToken = "nameplate2" } }
UnitName = function(u) return u == "nameplate1" and "Guard Thomas" or "Random Critter" end
NS.Beacon.RescanPlates()
assert(NS.Beacon.count == 1, "wanted-name count " .. tostring(NS.Beacon.count))
-- a corpse cannot talk to anyone: markers and the target macro go away while dead
do
    PLAYER_GHOST = true
    local _, n = NS.Beacon.WantedNames()
    assert(n == 0, "over-head markers still wanted while dead: " .. tostring(n))
    PLAYER_GHOST = false
    local _, n2 = NS.Beacon.WantedNames()
    assert(n2 > 0, "markers did not come back after resurrecting")
end
-- the marker must actually attach to the wanted plate (and only that one)
do
    local shown = 0
    for _, m in pairs(NS.Beacon._test.plateMarks) do if m.__shown then shown = shown + 1 end end
    assert(shown == 1, "expected exactly 1 nameplate marker, got " .. shown)
end
-- classic clients return an EMPTY C_NamePlate list even with nameplates on screen; the
-- WorldFrame fallback has to pick them up or the over-head marker never appears there
do
    NAMEPLATES = {}
    local function mkplate(nm)
        local f = CreateFrame()
        f.__name = nm
        function f:IsObjectType(t) return t == "Frame" end
        function f:IsShown() return true end
        function f:GetName() return nil end
        function f:GetRegions()
            local fs = CreateFrame()
            function fs:GetObjectType() return "FontString" end
            function fs:GetText() return nm end
            return fs
        end
        function f:GetChildren() return end
        return f
    end
    WORLDFRAME_KIDS = { mkplate("Guard Thomas"), mkplate("Random Critter") }
    NS.Beacon.RescanPlates()
    assert(NS.Beacon.legacyPlateCount == 2, "legacy scan found " .. tostring(NS.Beacon.legacyPlateCount))
    assert(NS.Beacon.legacyMarked == 1, "legacy marked " .. tostring(NS.Beacon.legacyMarked) .. " (want 1)")
    -- re-anchoring on every rescan is what made the marker stutter; parking must be idempotent
    WORLDFRAME_KIDS = { mkplate("Guard Thomas") }
    NS.Beacon.RescanPlates()
    local mark
    for _, m in pairs(NS.Beacon._test.plateMarks) do if m.__shown then mark = m end end
    assert(mark and mark.__parked, "marker not parked")
    local parked = mark.__parked
    mark.__setpoints = 0
    local realSetPoint = mark.SetPoint
    mark.SetPoint = function(self, ...) self.__setpoints = self.__setpoints + 1 return realSetPoint(self, ...) end
    for _ = 1, 5 do NS.Beacon.RescanPlates() end
    assert(mark.__setpoints == 0, "marker re-anchored " .. mark.__setpoints .. " times while already parked")
    assert(mark.__parked == parked, "marker changed anchor without moving plates")
    WORLDFRAME_KIDS = {}
end
-- an unplaced HereBeDragons pin that we Show() ourselves floats in the middle of the screen
do
    local f = assert(io.open("CompletionRoute/UI/Beacon.lua"))
    local src = f:read("*a") f:close()
    assert(not src:find("pins%[i%]:Show%(%)"), "Beacon shows pin frames itself; let HereBeDragons place them")
end
-- C_NamePlate.GetNamePlates(isSecure=true) returns nothing for insecure addon code; passing it
-- silently disabled the over-head marker on live clients. Never pass it.
do
    local f = assert(io.open("CompletionRoute/UI/Beacon.lua"))
    local src = f:read("*a") f:close()
    assert(not src:find("GetNamePlates%(true%)"), "Beacon passes isSecure to GetNamePlates")
    assert(not src:find("GetNamePlateForUnit%([%w_]+,%s*true%)"), "Beacon passes isSecure to GetNamePlateForUnit")
end
NS.db.profile.beacon.enabled = false
NS.Beacon.RescanPlates()
NS.db.profile.beacon.enabled = true
NS.Beacon.UpdateTargetButton()
assert(NS.Beacon.targetButton.targetName == "Guard Thomas", "target button macro name = " .. tostring(NS.Beacon.targetButton.targetName))
UnitName = function() return "Tester" end
-- the over-head icon must come from the game's own art, and follow the step's action
do
    NS.db.profile.beacon.icon = "action"
    NS.Progress.current = { action = "A", title = "x", index = 1 }
    local t = NS.Beacon.MarkerTexture(NS.Progress.current)
    assert(t == NS.Guide.ACTION_ICON.A, "accept step icon = " .. tostring(t))
    NS.Progress.current = { action = "K", title = "x", index = 1 }
    assert(NS.Beacon.MarkerTexture(NS.Progress.current):find("RaidTargetingIcon"), "kill step should use the raid skull")
    NS.Progress.current = { action = "T", title = "x", index = 1 }
    assert(NS.Beacon.MarkerTexture(NS.Progress.current) == NS.Guide.ACTION_ICON.T, "turn-in icon")
    NS.db.profile.beacon.icon = "arrow"
    local t2, rot = NS.Beacon.MarkerTexture(NS.Progress.current)
    assert(t2:find("arrow_green") and rot, "arrow style should rotate the arrow")
    NS.db.profile.beacon.icon = "action"
    print("over-head icon OK: uses Blizzard step art, skull for kill steps, arrow style still available")
end
-- the arrow's item button must never paint an empty ring
do
    local f = assert(io.open("CompletionRoute/UI/Arrow.lua"))
    local src = f:read("*a") f:close()
    assert(src:find('mode == "hide" or %(not itemID and not spellID%)'),
        "Arrow.applyButton must hide when there is no item and no spell")
    assert(src:find('and %(rec%.item or rec%.spell%)'),
        "Arrow.Update must not enter item/hearth mode without an item or spell")
end
print("target beacon OK: names mined from |T| and titles, nameplate marker + /target button wired")


-- a step with no |M| coords must still resolve a location (quest objective, else zone centre)
do
    local noloc = NS.Guide.ParseLine("C Kill things|QID|55|Z|1429; Elwynn Forest|", 1)
    noloc.index = 1
    assert(not noloc.coords, "test step should have no coords")
    local wx = NS.Router.StepWorld(noloc)
    assert(wx, "step with a zone but no coords resolved nowhere")
    assert(noloc._locSource == "zone", "expected zone fallback, got " .. tostring(noloc._locSource))
    local nozone = NS.Guide.ParseLine("C Kill things|QID|55|", 1)
    nozone.index = 1
    assert(NS.Router.StepWorld(nozone) == nil, "step with nothing should resolve nowhere")
    print("location fallback OK: zone centre used when a guide line has no coordinates")
end

-- flight paths must be learnable without visiting a flight master, and by name on classic
do
    NS.db.char.knownTaxi = {}
    local named = 0
    for _, n in ipairs(NS.TravelGraph.nodes) do if n.taxiID and n.name then named = named + 1 end end
    assert(named > 0, "graph has no named taxi nodes to learn")
    local sample
    for _, n in ipairs(NS.TravelGraph.nodes) do if n.taxiID and n.name then sample = n break end end
    local byname = NS.TravelGraph.NodeByName(sample.name)
    assert(byname and byname.taxiID == sample.taxiID, "NodeByName failed for " .. tostring(sample.name))
    assert(NS.TravelGraph.NodeByName(sample.name:match("^([^,]+)")), "NodeByName failed on the short name")
    -- with nothing known, a known-only route must not claim a flight
    NS.db.profile.routing.assumeAllTaxi = false
    assert(NS.TravelGraph.IsTaxiKnown(sample) == false, "unknown node reported as known")
    NS.db.char.knownTaxi[sample.taxiID] = true
    assert(NS.TravelGraph.IsTaxiKnown(sample) == true, "learned node not reported as known")
    NS.db.profile.routing.assumeAllTaxi = true
    print("taxi learning OK: NodeByName resolves classic flight-master names")
end

-- faction policy: with ZERO learned flight paths the route must still fly (walk to the flight master first)
do
    NS.db.char.knownTaxi = {}
    NS.db.profile.routing.assumeAllTaxi = nil
    NS.db.profile.routing.taxiPolicy = "faction"
    assert(NS.TravelGraph.TaxiPolicy() == "faction")
    local sx, sy, si = z2w(0.42, 0.65, 1429)      -- Goldshire
    local gx, gy, gi = z2w(0.5, 0.5, 1437)        -- Wetlands (far: flying should win)
    local p = NS.TravelGraph.FindPath(sx, sy, si, gx, gy, gi, { hearth = false })
    assert(p, "no path Goldshire->Wetlands")
    local flew, discover = false, false
    for _, l in ipairs(p.legs) do if l.mode == "taxi" then flew = true if l.discover then discover = true end end end
    assert(flew, "faction policy did not use a flight: " .. NS.TravelGraph.Describe(p))
    assert(discover, "unlearned flight not labelled as discover")
    print("faction taxi OK:", NS.TravelGraph.Describe(p))
    NS.db.profile.routing.taxiPolicy = "known"
    local p2 = NS.TravelGraph.FindPath(sx, sy, si, gx, gy, gi, { hearth = false })
    for _, l in ipairs(p2.legs) do assert(l.mode ~= "taxi", "known policy flew with nothing learned") end
    print("known taxi OK: walks when nothing is learned")
    NS.db.profile.routing.taxiPolicy = "faction"
end

-- discovered flight paths (docs/ROUTING.md): a flight may only LAND at a discovered flight master; it may take off from
-- one the character has not discovered yet, because walking there discovers it - that walk is labelled.
do
    local TG = NS.TravelGraph
    local savedShared = NS.taxiShared
    NS.taxiShared = false                          -- tbc: every character has its own flight paths
    NS.db.profile.routing.assumeAllTaxi = nil
    NS.db.profile.routing.taxiPolicy = "known"
    -- Lakeshire, Morgan's Vigil, Thorium Point, Thelsamar; NOT Darkshire (12), where the faction route above takes off
    NS.db.char.knownTaxi = { [5] = true, [71] = true, [74] = true, [8] = true }
    NS.db.global.knownTaxi = {}
    TG.PathCacheWipe()
    local sx, sy, si = z2w(0.42, 0.65, 1429)                    -- Goldshire
    local gx, gy, gi = z2w(0.5, 0.5, 1437)                      -- Wetlands
    local p = TG.FindPath(sx, sy, si, gx, gy, gi, { hearth = false })
    assert(p, "no path Goldshire->Wetlands with the Redridge-Loch Modan flight paths known")
    local firstTaxi, prevWalk
    for i, l in ipairs(p.legs) do
        if l.mode == "taxi" then
            assert(TG.IsTaxiKnown(l.to), "known policy landed at an undiscovered flight master: " .. tostring(l.to.name))
            if not firstTaxi then firstTaxi, prevWalk = l, p.legs[i - 1] end
        end
    end
    assert(firstTaxi, "known policy did not fly although the landing nodes are known: " .. TG.Describe(p))
    assert(firstTaxi.from.taxiID == 12 and not TG.IsTaxiKnown(firstTaxi.from), "expected to take off from undiscovered Darkshire: " .. TG.Describe(p))
    assert(prevWalk and prevWalk.mode == "walk" and prevWalk.pickup, "the walk to Darkshire is not marked as the flight-path pickup")
    assert(TG.Describe(p):find("pick up the flight path", 1, true), "Describe does not say where to pick up the flight path: " .. TG.Describe(p))
    -- with Lakeshire undiscovered no flight may land there (Darkshire -> Morgan's Vigil has no direct flight)
    NS.db.char.knownTaxi = { [71] = true, [74] = true, [8] = true }
    TG.PathCacheWipe()
    local p2 = TG.FindPath(sx, sy, si, gx, gy, gi, { hearth = false })
    for _, l in ipairs(p2 and p2.legs or {}) do
        if l.mode == "taxi" then assert(TG.IsTaxiKnown(l.to), "landed at undiscovered " .. tostring(l.to.name)) end
    end
    -- Classic clients do not share flight paths: the account-wide set is kept but not routed on; retail/Forever share it
    NS.db.char.knownTaxi = {}
    NS.db.global.knownTaxi = { [5] = true, [71] = true, [74] = true, [8] = true }
    TG.PathCacheWipe()
    assert(not TG.IsTaxiKnownID(5), "tbc routed on another character's flight path")
    NS.taxiShared = true
    assert(TG.IsTaxiKnownID(5), "shared client ignored the account-wide flight paths")
    local p3 = TG.FindPath(sx, sy, si, gx, gy, gi, { hearth = false })
    local flew3 = false
    for _, l in ipairs(p3 and p3.legs or {}) do if l.mode == "taxi" then flew3 = true end end
    assert(flew3, "shared client did not fly on the account's flight paths")
    -- learning marks both the character and the account
    NS.taxiShared = false
    NS.db.global.knownTaxi = {}
    assert(TG.MarkTaxiKnown(4) == true and NS.db.char.knownTaxi[4] and NS.db.global.knownTaxi[4], "MarkTaxiKnown did not record char + account")
    assert(TG.MarkTaxiKnown(4) == false, "MarkTaxiKnown reported an old node as new")
    -- the harvest counts only nodes the client says this character has (state on the flight map, or isUndiscovered == false)
    local savedTM = C_TaxiMap
    C_TaxiMap = { GetTaxiNodesForMap = function() return { { nodeID = 5, isUndiscovered = false }, { nodeID = 2, isUndiscovered = true }, { nodeID = 8 } } end }
    NS.db.char.knownTaxi = {}
    TG.LearnTaxi(true)
    C_TaxiMap = savedTM
    assert(NS.db.char.knownTaxi[5] and not NS.db.char.knownTaxi[2] and not NS.db.char.knownTaxi[8], "harvest trusted a node the client did not mark as discovered")
    NS.taxiShared = savedShared
    NS.db.char.knownTaxi, NS.db.global.knownTaxi = {}, {}
    NS.db.profile.routing.taxiPolicy = "faction"
    NS.db.profile.routing.assumeAllTaxi = true
    TG.PathCacheWipe()
    print("discovered taxi OK: lands only on discovered flight masters, walks to pick a new one up, shares only on retail/Forever")
end

-- Core/Init.lua migration: the client default is now "known" (once, for a profile on the old default), and a Classic
-- character's flight paths start empty once (older builds copied the whole account's set into every character)
do
    local savedDB, savedChar, savedNS = CompletionRouteDB, CompletionRouteCharDB, NS.db
    CompletionRouteDB = { profile = { routing = { taxiPolicy = "faction" } }, knownTaxi = { [2] = true, [6] = true } }
    CompletionRouteCharDB = { knownTaxi = { [2] = true, [6] = true, [99] = true } }
    for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", "CompletionRoute") end
    assert(NS.taxiShared == false, "tbc should not share flight paths")
    assert(NS.db.profile.routing.taxiPolicy == "known" and NS.db.profile.routing.taxiKnown1, "old faction default not moved to known")
    assert(next(NS.db.char.knownTaxi) == nil and NS.db.char.knownTaxiMerged and NS.db.char.knownTaxiMerged[99], "classic char flight paths not reset once")
    assert(NS.db.global.knownTaxi[99], "account union lost the character's nodes")
    -- second load: a player who picked "faction" in Options keeps it, and the character's own nodes stay
    NS.db.profile.routing.taxiPolicy = "faction"
    NS.db.char.knownTaxi[7] = true
    for _, h in ipairs(NS.wowHandlers.ADDON_LOADED) do h("ADDON_LOADED", "CompletionRoute") end
    assert(NS.db.profile.routing.taxiPolicy == "faction", "migration ran twice and overrode the player's choice")
    assert(NS.db.char.knownTaxi[7], "a later load wiped the character's own flight paths")
    CompletionRouteDB, CompletionRouteCharDB, NS.db = savedDB, savedChar, savedNS
    NS.db.profile.routing.assumeAllTaxi = true
    print("taxi migration OK: once to known, classic characters keep only their own flight paths")
end

-- roads: authored polylines become graph vertices; a detour road beats the straight line only when cheaper,
-- and the path keeps its via points so the arrow can follow it
do
    assert((NS.TravelGraph.roadCount or 0) > 0, "no road vertices built from Data/Roads_*.lua")
    -- synthetic road on EK: a gentle arc between A and B (shorter in cost than off-road straight line x1.25)
    local A = { -9000, 300 } local B = { -9000, 1200 }
    local old = NS.RoadData
    NS.RoadData = { { inst = 0, name = "test arc", w = { A, { -8990, 600 }, { -8990, 900 }, B } } }
    NS.TravelGraph.RebuildRoads()
    local p = NS.TravelGraph.FindPath(A[1], A[2] - 10, 0, B[1], B[2] + 10, 0, { hearth = false, taxi = false, transit = false })
    assert(p and p.legs[1] and p.legs[1].road, "router did not take the road: " .. NS.TravelGraph.Describe(p))
    assert(p.legs[1].via and #p.legs[1].via >= 2, "road via points missing")
    print("roads OK:", NS.TravelGraph.Describe(p))
    -- a big detour road must NOT be taken
    NS.RoadData = { { inst = 0, name = "test detour", w = { A, { -7000, 600 }, { -7000, 900 }, B } } }
    NS.TravelGraph.RebuildRoads()
    p = NS.TravelGraph.FindPath(A[1], A[2] - 10, 0, B[1], B[2] + 10, 0, { hearth = false, taxi = false, transit = false })
    assert(p and not p.legs[1].road, "router took a 4000-yd detour road")
    print("roads OK: detour rejected")
    NS.RoadData = old
    NS.TravelGraph.RebuildRoads()
    -- recorder: decimation + segment break + feeding back into the graph
    NS.db.global = NS.db.global or {}
    NS.db.global.roadTrace = { [0] = { { { -20000, 20000 }, { -20025, 20000 }, { -20050, 20000 }, { -20075, 20000 }, { -20100, 20000 } } } }
    local before = NS.TravelGraph.roadCount
    NS.TravelGraph.RebuildRoads()
    assert(NS.TravelGraph.roadCount == before + 5, "recorded trace did not enter the graph")
    local segs, pts = NS.Roads.Stats()
    assert(segs == 1 and pts == 5)
    NS.db.global.roadTrace = {}
    NS.TravelGraph.RebuildRoads()
    print("road recorder OK: traces feed the graph")
end

-- picking a guide must SHOW the guide window (it read as "the guide was deleted" when hidden)
do
    local f = assert(io.open("CompletionRoute/UI/GuideFrame.lua"))
    local src = f:read("*a") f:close()
    assert(src:find('NS:On%("GUIDE_LOADED", function%(%)%s*\n%s*%-%-'), "GUIDE_LOADED handler shape changed")
    assert(src:find("if not f:IsShown%(%) then f:Show%(%) end"), "loading a guide must show the guide window")
    assert(src:find("function GF.ShowDetail"), "no step detail popup")
    assert(src:find("GF.ShowDetail%(self.step%)"), "clicking the step card must open its details")
    assert(not src:find("UICheckButtonTemplate"), "the guide window must not have a tick box - steps complete themselves")
    assert(src:find("P.Undo%(%)") and src:find("P.Forward%(%)"), "back/forward arrows missing")
    print("guide selection UX OK: window opens on load, one step at a time, arrows, no checkbox")
end

-- login sync: completed quests come from the client, and a guide is "(Character)" only when WHOLLY done
do
    local A = NS.Account
    NS.Guide.Register({ id = "t:sync", name = "Sync Test", text = "A One|QID|5001|\nT One|QID|5001|\nA Two|QID|5002|\nT Two|QID|5002|" })
    local g = NS.Guide.registry["t:sync"]
    COMPLETED_QUESTS = { 5001 }
    A.me.quests = {}
    assert(A.HarvestCompleted(true) == 1, "harvest did not pick up the completed quest")
    assert(A.me.quests[5001], "harvested quest not stored on the character")
    assert(A.GuideCompletedBy(g) == nil, "half-finished guide reported as complete")
    COMPLETED_QUESTS = { 5001, 5002 }
    A.HarvestCompleted(true)
    local key, who = A.GuideCompletedBy(g)
    assert(key == A.key and who, "wholly finished guide not credited to this character")
    -- another character finished a different guide wholly
    NS.Guide.Register({ id = "t:sync2", name = "Sync Test 2", text = "A Three|QID|5003|\nT Three|QID|5003|" })
    NS.db.global.chars["Alt-Test"] = { name = "Alt", faction = "Alliance", quests = { [5003] = true } }
    A.completedCache = {}
    local _, who2 = A.GuideCompletedBy(NS.Guide.registry["t:sync2"])
    assert(who2 == "Alt", "alt's wholly finished guide not credited: " .. tostring(who2))
    -- autofill: loading the half-done guide auto-completes the finished quest's steps
    COMPLETED_QUESTS = { 5001 }
    A.me.quests = {} A.completedCache = {}
    NS.Progress.Load("t:sync")
    assert(NS.Progress.current and NS.Progress.current.qid[1] == 5002, "autofill did not skip past the completed quest: " .. tostring(NS.Progress.current and NS.Progress.current.title))
    COMPLETED_QUESTS = {}
    NS.db.global.chars["Alt-Test"] = nil
    print("login sync OK: harvest, autofill, (Character) only when wholly complete")
end

-- 9) every documented slash subcommand is actually handled.
-- A refactor once deleted a whole run of elseif branches (chars/accountwide/forget/beacon/
-- verifyfeatures) and nothing caught it, because those commands are only reachable by typing.
do
    local f = assert(io.open("CompletionRoute/Core/Slash.lua"))
    local src = f:read("*a") f:close()
    local handled = {}
    for name in src:gmatch('cmd%s*==%s*"([%w_]+)"') do handled[name] = true end
    local required = { "guides", "load", "icon", "why", "next", "skip", "undo", "reset", "arrow", "beacon", "demo",
                       "chars", "accountwide", "forget", "options", "route", "order", "taxi",
                       "hearth", "import", "switch", "scan", "verify", "verifyfeatures",
                       "verifyall", "autoverify", "log", "stats", "debug", "test", "list", "gold", "prof" }
    local missing = {}
    for _, c in ipairs(required) do if not handled[c] then missing[#missing + 1] = c end end
    assert(#missing == 0, "slash commands not handled: " .. table.concat(missing, ", "))
    -- and the help line must advertise them
    local help = src:match('NS:Print%("Commands: ([^"]+)"%)')
    assert(help, "no help line")
    local advertised = {}
    for w in help:gmatch("[%w_]+") do advertised[w] = true end
    local unlisted = {}
    for _, c in ipairs(required) do if not advertised[c] then unlisted[#unlisted + 1] = c end end
    assert(#unlisted == 0, "commands missing from the help line: " .. table.concat(unlisted, ", "))
    print(("slash commands OK: %d handled and advertised"):format(#required))
end

print("ALL OFFLINE TESTS PASSED")
