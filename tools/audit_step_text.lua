-- Step text audit: does every step of every shipped guide fit the step window at its default size?
-- Run from the repo root:  luajit -joff tools/audit_step_text.lua [flavor ...] [--top N] [--examples]
--
-- Walks every guide each of the five flavor TOCs loads (tools/guide_walk.lua, the same walk as tools/test_load_all.lua),
-- parses every step with the addon's parser, builds the three texts the window shows (UI/GuideFrame.lua):
--   title   "<Action>  <step title><count, trainer, skill>"       Large font, at most GF.L.titleLines lines
--   note    the step's note as the card shows it (NS.Guide.CardNote)  Body font, at most GF.L.noteLines lines
--   travel  the route summary under the card                         Small font, at most GF.L.pathLines lines
-- and estimates how many lines each needs at the default window width.
--
-- THE ASSUMPTION.  No client is involved, so text width is estimated from character counts: each character gets a
-- width in em by class (see EM below; Friz Quadrata, the client's default Latin font, is close to these), times the
-- font size the window uses at the default text-size setting (Large 17 pt, Body 13 pt, Small 12 pt = the client's
-- 16/12/10 pt plus profile.textSize 2, Core/Util.lua).  Words wrap greedily.  The estimate is good to about one word
-- per line, so every count is also given with widths 10% larger ("pessimistic").  It says whether TEXT IS CUT (more
-- lines than the cap); it cannot see pixels, so it cannot prove that nothing overlaps: that is the layout code's job
-- (tools/test_step_window.lua checks the rules it follows) and a look in the client.
local W = dofile("tools/guide_walk.lua")

local TOP, EXAMPLES, want = 5, false, {}
do
    local i = 1
    while arg and arg[i] do
        if arg[i] == "--top" then TOP = tonumber(arg[i + 1]) or TOP i = i + 1
        elseif arg[i] == "--examples" then EXAMPLES = true
        else want[arg[i]] = true end
        i = i + 1
    end
end

-- layout numbers straight from the window's source, so the audit cannot drift from it
local src = assert(io.open("CompletionRoute/UI/GuideFrame.lua")):read("*a")
local BASE_W = tonumber(src:match("GF%.BASE_W, GF%.BASE_H = (%d+)"))
local Ltext = src:match("GF%.L = (%b{})")
assert(BASE_W and Ltext, "UI/GuideFrame.lua: GF.BASE_W / GF.L not found")
local L = assert(loadstring("return " .. Ltext))()
local cardW = BASE_W - 2 * L.side
local WIDTH = { title = cardW - (2 * L.pad + L.icon + L.gap), note = cardW - 2 * L.pad, path = BASE_W - L.pathInset }
local PT = { title = 17, note = 13, path = 12 }
local CAP = { title = L.titleLines, note = L.noteLines, path = L.pathLines }

-- the text model (character widths, greedy wrap) is shared with tools/test_step_window.lua
local plain, lines = W.Plain, W.Lines

local MARKUP = { "%[%[", "{{", "}}", "'''", "''", "<%a", "&%a+;", "http", "%[color", "|c%x%x%x%x%x%x%x%x", "\\n" }
local function hasMarkup(t)
    for _, p in ipairs(MARKUP) do if t:find(p) then return p end end
    return nil
end

local function bucket(tbl, k) tbl[k] = (tbl[k] or 0) + 1 end
local function keep(top, n, rec)
    top[#top + 1] = rec
    table.sort(top, function(a, b) return a.len > b.len end)
    if #top > n then top[#top] = nil end
end

local anyOver = 0
for _, fl in ipairs(W.FLAVORS) do
    if not next(want) or want[fl.name] then
        local S = { steps = 0, guides = 0, reused = 0,
                    titleLines = {}, noteLines = {}, rawNoteLines = {},
                    titleOver = 0, titleOverP = 0, noteOver = 0, noteOverP = 0, rawNoteOver = 0,
                    tails = 0, tailKinds = {}, markup = 0, markupKinds = {}, markupEx = {}, shortened = 0,
                    topTitle = {}, topNote = {}, topRaw = {}, tallest = 0, tallestRec = nil }
        local NS, missing, errors = W.Walk(fl, function(s, g, _, ns)
            local G = ns.Guide
            S.steps = S.steps + 1
            -- title, as GF.Update builds it; the worst case of the live suffixes is assumed
            local title = (G.ACTION_LABEL[s.action] or s.action) .. "  " .. G.StepTitle(s)
            if s.skill then title = title .. (" (open %s so the addon can read this skill)"):format(s.skill.name)
            elseif (s.action == "C" or s.action == "K") and s.qid then title = title .. " (10/10)" end
            local tl = lines(title, WIDTH.title, PT.title)
            bucket(S.titleLines, math.min(tl, CAP.title + 1))
            if tl > CAP.title then S.titleOver = S.titleOver + 1 end
            if lines(title, WIDTH.title, PT.title, 1.1) > CAP.title then S.titleOverP = S.titleOverP + 1 end
            keep(S.topTitle, TOP, { len = #plain(title), lines = tl, id = g.id, text = title })
            -- note: raw (what the window showed before the card note) and as the card shows it
            local raw = s.note or ""
            if s.optional then raw = "(optional) " .. raw end
            local card, tail = raw, nil
            if G.CardNote then
                card, tail = G.CardNote(s)
                if s.optional then card = "(optional) " .. card end
            end
            if tail and tail ~= "" then
                S.tails = S.tails + 1
                bucket(S.tailKinds, (tail:match("^%((%a[%a ]-)[:;%)]") or tail:match("^%((%a+)") or "other"))
            end
            if card ~= raw then S.shortened = S.shortened + 1 end
            local mk = hasMarkup(s.note or "")
            if mk then
                S.markup = S.markup + 1
                bucket(S.markupKinds, mk)
                if #S.markupEx < 3 then S.markupEx[#S.markupEx + 1] = g.id .. ": " .. (s.note or ""):sub(1, 160) end
            end
            local rl, nl = lines(raw, WIDTH.note, PT.note), lines(card, WIDTH.note, PT.note)
            local function band(n) return n == 0 and "0" or n <= 2 and "1-2" or n <= 4 and "3-4" or n <= CAP.note and ("5-" .. CAP.note) or ("over " .. CAP.note) end
            bucket(S.rawNoteLines, band(rl))
            bucket(S.noteLines, band(nl))
            if rl > CAP.note then S.rawNoteOver = S.rawNoteOver + 1 end
            if nl > CAP.note then S.noteOver = S.noteOver + 1 end
            if lines(card, WIDTH.note, PT.note, 1.1) > CAP.note then S.noteOverP = S.noteOverP + 1 end
            keep(S.topNote, TOP, { len = #plain(card), lines = nl, id = g.id, text = card })
            keep(S.topRaw, TOP, { len = #plain(raw), lines = rl, id = g.id, text = raw })
            -- the window's height for this step (GF.FitHeight's sum), in window units, with a full travel line
            local head = math.max(L.icon, math.min(tl, CAP.title) * PT.title + 2)
            local nh = math.min(nl, CAP.note) * (PT.note + 1)
            local h = L.top + (L.pad + head + (nh > 0 and (L.gap + nh) or 0) + (10 + PT.path) + 8) + (CAP.path * PT.path + 14)
            if h > S.tallest then S.tallest, S.tallestRec = h, g.id .. ": " .. title:sub(1, 80) end
        end, function(_, _, _, reused)
            if reused then S.reused = S.reused + 1 else S.guides = S.guides + 1 end
        end)
        -- travel line: the text comes from live routing (Routing/TravelGraph.lua Summary), so only its shapes can be
        -- sized: with a flight-master name of typical length (the median) and a long one (longer than 9 in 10)
        local data = NS.TaxiData and (NS.TaxiData[fl.name] or NS.TaxiData[NS.dataFlavor or ""])
        local names = {}
        for _, n in pairs(data and data.nodes or {}) do
            if type(n[1]) == "string" then names[#names + 1] = n[1] end
        end
        table.sort(names, function(x, y) if #x ~= #y then return #x < #y end return x < y end)
        local typical = names[math.max(1, math.floor(#names * 0.5))] or "Stormwind, Elwynn"
        local long = names[math.max(1, math.floor(#names * 0.9))] or "Thorium Point, Searing Gorge"
        local function shapesFor(nm)
            return {
                { "one flight", ("Fly to %s  (~12m 30s)"):format(nm) },
                { "pick up a flight path, then fly", ("Pick up the flight path at %s, then fly to %s  (~12m 30s)"):format(nm, nm) },
                { "hearth, flight, boat", ("Hearth to %s, then fly to %s, then boat to %s  (~1h 12m)"):format(nm, nm, nm) },
            }
        end
        local shapes = {}
        for _, sh in ipairs(shapesFor(typical)) do shapes[#shapes + 1] = { sh[1] .. ", typical name", sh[2] } end
        for _, sh in ipairs(shapesFor(long)) do shapes[#shapes + 1] = { sh[1] .. ", long name", sh[2] } end

        print(("== %s (%s): %d guides (+%d spine entries that reuse them), %d steps =="):format(fl.name, fl.toc, S.guides, S.reused, S.steps))
        for _, m in ipairs(missing) do print("   not generated here: " .. m) end
        for _, e in ipairs(errors) do print("   LOAD ERROR " .. e) end
        print(("   window %d wide: title %d px at %d pt (cap %d lines), note %d px at %d pt (cap %d), travel %d px at %d pt (cap %d)"):format(
            BASE_W, WIDTH.title, PT.title, CAP.title, WIDTH.note, PT.note, CAP.note, WIDTH.path, PT.path, CAP.path))
        local function dist(tbl, order)
            local out = {}
            for _, k in ipairs(order) do if tbl[k] then out[#out + 1] = k .. ": " .. tbl[k] end end
            return table.concat(out, "   ")
        end
        print("   TITLE lines     " .. dist(S.titleLines, { 1, 2, 3, 4 }) .. "   (4 = more than the cap)")
        print(("   TITLE cut       %d steps (%d with 10%% wider text)"):format(S.titleOver, S.titleOverP))
        local order = { "0", "1-2", "3-4", "5-" .. CAP.note, "over " .. CAP.note }
        print("   NOTE on card    " .. dist(S.noteLines, order))
        print(("   NOTE cut        %d steps (%d with 10%% wider text); before the card note: %d"):format(S.noteOver, S.noteOverP, S.rawNoteOver))
        print("   NOTE as written " .. dist(S.rawNoteLines, order))
        local tk = {}
        for k, v in pairs(S.tailKinds) do tk[#tk + 1] = ("%s %d"):format(k, v) end
        table.sort(tk)
        print(("   source notes    %d notes end in a source note moved off the card%s"):format(S.tails, #tk > 0 and (" (" .. table.concat(tk, ", ") .. ")") or ""))
        local mk = {}
        for k, v in pairs(S.markupKinds) do mk[#mk + 1] = ("%s %d"):format(k, v) end
        table.sort(mk)
        print(("   raw markup      %d notes%s"):format(S.markup, #mk > 0 and (" (" .. table.concat(mk, ", ") .. ")") or ""))
        for _, e in ipairs(S.markupEx) do print("       e.g. " .. e) end
        print(("   tallest window  about %d units (%s)"):format(S.tallest, tostring(S.tallestRec)))
        for _, sh in ipairs(shapes) do
            print(("   travel line     %-46s %d line(s)%s"):format(sh[1], lines(sh[2], WIDTH.path, PT.path),
                lines(sh[2], WIDTH.path, PT.path) > CAP.path and "  -> cut at " .. CAP.path .. " (the Details panel lists every leg)" or ""))
        end
        local function top(name, list)
            print("   longest " .. name .. ":")
            for _, r in ipairs(list) do
                print(("     %4d chars, %2d lines  %s"):format(r.len, r.lines, r.id))
                if EXAMPLES then print("         " .. plain(r.text):gsub("\n", " / "):sub(1, 400)) end
            end
        end
        top("titles", S.topTitle)
        top("notes on the card", S.topNote)
        top("notes as written", S.topRaw)
        print()
        anyOver = anyOver + S.titleOver + S.noteOver
        collectgarbage()
    end
end
print(("Steps whose title or card note is cut at the default size, all flavors: %d"):format(anyOver))
print("Cut text is never lost: the tooltip and the Details panel (click the card) show the whole title and note.")
print("Pixel overlap cannot be measured offline; see the header of this file.")
