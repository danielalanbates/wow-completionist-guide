-- CompletionRoute :: Core/Guide.lua
-- Guide registry + parser.  Native format: one step per line (docs/GUIDE_FORMAT.md):
--   <ACTION> <Title>|QID|123|M|48.15,42.95|Z|1429; Elwynn Forest|N|note|...
-- Actions: A accept, C complete, T turn-in, K kill, R run to, h set hearth, H hearth, F fly, f get flight path,
--          N note, B buy, b boat/zeppelin, U use item, L level, r repair/sell, D dungeon, J jump/portal, $ treasure, = misc, ! daily
-- Routing tags: |ROUTE| step may be reordered by optimizer (default for A/C/T/K/r/B/$)
--   |FIXED| never reorder; |ITEM|id (also |U|id) drives the arrow's item button.
local ADDON, NS = ...
local U, Cond = NS.Util, NS.Cond

local G = {}
NS.Guide = G
G.registry = {}      -- id -> guide record
G.list = {}          -- ordered ids

local ACTIONS = { A=1, a=1, C=1, T=1, t=1, K=1, R=1, H=1, h=1, F=1, f=1, N=1, B=1, b=1, U=1, L=1, l=1, r=1, D=1, J=1, M=1, ["!"]=1, ["$"]=1, ["="]=1, G=1,
    P=1, ["*"]=1, d=1, s=1 } -- extras: P portal/teleport, * destroy-item, d death-step, s speak-with
-- non-native actions normalize to a note step (waypoint still honored via M/Z tags)
local ACTION_ALIAS = { P = "N", ["*"] = "N", d = "N", s = "N" }
G.ACTIONS = ACTIONS
G.ACTION_LABEL = { A="Accept", a="Accept", C="Complete", T="Turn in", t="Turn in", K="Kill", R="Run to", H="Hearth to", h="Set hearth",
    F="Fly to", f="Get flight path", N="Note", B="Buy", b="Boat/Zeppelin", U="Use", L="Level", l="Loot", r="Repair/Sell", D="Dungeon",
    J="Portal/Jump", M="Make", ["!"]="Daily", ["$"]="Treasure", ["="]="Train", G="Farm" }
G.ACTION_ICON = { A="Interface\\GossipFrame\\AvailableQuestIcon", a="Interface\\GossipFrame\\AvailableQuestIcon",
    C="Interface\\Icons\\Ability_DualWield", T="Interface\\GossipFrame\\ActiveQuestIcon", t="Interface\\GossipFrame\\ActiveQuestIcon",
    K="Interface\\Icons\\Ability_Creature_Cursed_02", R="Interface\\Icons\\Ability_Tracking", H="Interface\\Icons\\INV_Misc_Rune_01",
    h="Interface\\Icons\\INV_Misc_Rune_01", F="Interface\\Icons\\Ability_Druid_FlightForm", f="Interface\\Icons\\Ability_Hunter_EagleEye",
    N="Interface\\Icons\\INV_Misc_Note_01", B="Interface\\Icons\\INV_Misc_Coin_01", b="Interface\\Icons\\Spell_Frost_SummonWaterElemental",
    U="Interface\\Icons\\INV_Misc_Bag_08", L="Interface\\Icons\\Spell_ChargePositive", l="Interface\\Icons\\INV_Misc_Bag_08",
    r="Interface\\Icons\\Ability_Repair", D="Interface\\TAXIFRAME\\UI-Taxi-Icon-Green", J="Interface\\Icons\\spell_arcane_teleportironforge",
    M="Interface\\Icons\\Trade_BlackSmithing", ["!"]="Interface\\GossipFrame\\DailyQuestIcon", ["$"]="Interface\\Icons\\INV_Misc_Bag_10",
    ["="]="Interface\\Icons\\INV_Misc_Book_09", G="Interface\\Icons\\INV_Misc_Herb_07" }
-- Steps whose position is location-driven and may be reordered by the optimizer
local ROUTABLE = { A=true, C=true, T=true, K=true, r=true, B=true, ["$"]=true, l=true, ["!"]=true }

-- Parse "1^2^3" or "1&2" or "1;2" -> list of ints (semantics of ^ (or) vs & (and) kept in .andor)
local function intlist(v)
    if not v then return nil end
    local out, andor = {}, (v:find("&") and "and") or "or"
    for n in v:gmatch("%d+") do out[#out + 1] = tonumber(n) end
    if #out == 0 then return nil end
    out.andor = andor
    return out
end
G.intlist = intlist

-- Parse "|M|x,y;x2,y2|" -> list of {x,y} in 0..1
local function coords(v)
    if not v then return nil end
    if v == "PLAYER" then return { player = true } end
    local out = {}
    for pair in v:gmatch("[^;]+") do
        local x, y = pair:match("([%d%.%-]+)%s*,%s*([%d%.%-]+)")
        if x then out[#out + 1] = { x = tonumber(x) / 100, y = tonumber(y) / 100 } end
    end
    return #out > 0 and out or nil
end

-- Parse "|ALT|1453,63.7,73.3,Name;1455,60.1,36.4,Name|" -> list of { map, x, y (0..1), name } ("Same uiMapID convention as Z").
-- A place this client has no map for is dropped; the step keeps the others.
local function altList(v)
    if not v then return nil end
    local out = {}
    for entry in v:gmatch("[^;]+") do
        local mid, x, y, name = entry:match("^%s*(%d+)%s*,%s*([%d%.]+)%s*,%s*([%d%.]+)%s*,?%s*(.-)%s*$")
        local map = mid and U.MapIDByIDOrName(tonumber(mid), nil)
        if map then out[#out + 1] = { map = map, x = tonumber(x) / 100, y = tonumber(y) / 100, name = name } end
    end
    return #out > 0 and out or nil
end

-- Parse one guide line -> step table (or nil)
function G.ParseLine(text, lineno, defaultZone)
    text = U.trim(text or "")
    if text == "" or text:sub(1, 1) == ";" or text:sub(1, 2) == "--" then return nil end
    local action = text:sub(1, 1)
    if not ACTIONS[action] or text:sub(2, 2) ~= " " then return nil, "bad action '" .. action .. "'" end
    local parts = { strsplit("|", text) }
    local step = { action = ACTION_ALIAS[action] or action, title = U.trim(parts[1]:sub(3)):gsub("\\n", "\n"), line = lineno }
    local i = 2
    while i <= #parts do
        local tag = U.trim(parts[i]); local val = parts[i + 1]
        local consumed = 2
        if tag == "" then consumed = 1
        elseif tag == "QID" then step.qid = intlist(val)
        elseif tag == "PRE" then step.pre = intlist(val)
        elseif tag == "LEAD" then step.lead = intlist(val)
        elseif tag == "ACTIVE" then local n = val and val:match("%-?%d+") step.active = tonumber(n)
        elseif tag == "AVAILABLE" then step.available = tonumber(val and val:match("%d+"))
        elseif tag == "M" then step.coords = coords(val)
        elseif tag == "Z" then
            local id, name = val:match("^%s*(%d+)%s*;?%s*(.-)%s*$")
            local mid = tonumber(id)
            -- "1423; Eastern Plaguelands" or bare "1454": the number is a Classic-era uiMapID. MoP Classic and
            -- retail number their maps differently (23 / 85), so resolve by name (Data/ZoneAliases.lua) whenever
            -- the id is unknown on this client or the names disagree.
            if mid then mid = U.MapIDByIDOrName(mid, name) end
            step.zone = mid or U.MapIDByName(val)
            step.zoneName = (name ~= "" and name) or val
        elseif tag == "N" then step.note = (val or ""):gsub("\\n", "\n"):gsub("%[color=(%x%x%x%x%x%x)%]", "|cff%1"):gsub("%[/color%]", "|r")
            -- a wiki external link left in quest text, "[http://site/page Swine Bellies]", reads as its label
            if step.note:find("[http", 1, true) then step.note = step.note:gsub("%[https?://%S+%s+([^%]]-)%]", "%1") end
            -- "Head to X by any means possible." is filler; the arrow already shows the way
            step.note = step.note:gsub("%s+[Bb]y any means possible", ""):gsub("%s+[Bb]y any means([%.!,;])", "%1")
        elseif tag == "L" then step.loot = {} for pair in (val or ""):gmatch("[^;]+") do local id, q = pair:match("(%d+)%s*(%-?%d*)") if id then step.loot[#step.loot + 1] = { id = tonumber(id), qty = tonumber(q) or 1 } end end
        elseif tag == "QO" then step.qo = val
        elseif tag == "T" then step.target = val
        elseif tag == "U" or tag == "ITEM" then step.item = tonumber(val and val:match("%d+"))
        elseif tag == "C" then step.class = val
        elseif tag == "R" then step.race = val
        elseif tag == "P" then step.prof = val
        elseif tag == "LVL" then local n = tonumber(val and val:match("%-?[%d%.]+")) if n and n < 0 then step.maxlevel = -n else step.minlevel = n end
        elseif tag == "FACTION" then step.faction = val
        elseif tag == "SPELL" then step.spell = tonumber(val and val:match("%d+"))
        elseif tag == "BUFF" then step.buff = val
        elseif tag == "O" then step.optional = true consumed = 1
        elseif tag == "S" then step.sticky = true consumed = 1
        elseif tag == "US" then step.unsticky = true consumed = 1
        elseif tag == "S!US" then step.sticky = true step.unsticky = true consumed = 1
        elseif tag == "NC" then step.noncombat = true consumed = 1
        elseif tag == "NA" or tag == "NOAUTO" then step.noauto = true consumed = 1
        elseif tag == "CC" or tag == "CS" or tag == "CN" then step.waypcomplete = tag consumed = 1
        elseif tag == "RANK" then step.rank = tonumber(val)
        elseif tag == "ACH" then
            -- achievement (and optionally one criteria-tree node): "ACH|6|" or "ACH|6;2050|"
            local a, c = (val or ""):match("^%s*(%d+)%s*;?%s*(%d*)")
            step.ach = tonumber(a) step.achCrit = tonumber(c)
        elseif tag == "MISSION" then step.mission = tonumber(val and val:match("%d+"))
        elseif tag == "RAD" then step.radius = tonumber(val)
        elseif tag == "KIND" then step.kind = val
        elseif tag == "SKILL" then
            -- "Cooking;75" or "Cooking;75;2545" (retail expansion tier skill line)
            local pname, target, tier = (val or ""):match("^%s*([^;]-)%s*;%s*(%d+)%s*;?%s*(%d*)")
            if pname and pname ~= "" then step.skill = { name = pname, target = tonumber(target), tier = tonumber(tier) } end
        elseif tag == "RECIPE" then step.recipe = tonumber(val and val:match("%d+"))
        elseif tag == "COUNT" then step.count = tonumber(val and val:match("%d+"))
        elseif tag == "ALT" then step.alts = altList(val)
        elseif tag == "ROUTE" then step.route = true consumed = 1
        elseif tag == "FIXED" then step.route = false consumed = 1
        elseif tag == "RUNE" or tag == "ELITE" or tag == "RARE" or tag == "DUNGEON" or tag == "CHAT" or tag == "H" or tag == "I" or tag == "V" or tag == "FAIL" or tag == "AP" or tag == "CT" or tag == "MS" or tag == "TOF" or tag == "EAB" or tag == "NOCACHE" then step[tag:lower()] = true consumed = 1
        else
            -- unknown tag with a value (or boolean) — keep raw
            step.extra = step.extra or {}
            if val == nil or val == "" or (parts[i + 2] == nil and val:find("[^%w%s;,%.%-]")) then step.extra[tag] = true consumed = 1 else step.extra[tag] = val end
        end
        i = i + consumed
    end
    -- ALT: located from the start at its first alternative; Progress.ResolveAlts moves it to the cheapest one for this character
    if step.alts and not step.coords then
        local a = step.alts[1]
        step.coords, step.zone, step.zoneName, step.altChosen, step.altName = { { x = a.x, y = a.y } }, a.map, U.MapName(a.map), a, a.name
    end
    if not step.zone and defaultZone then step.zone = U.MapIDByName(defaultZone) step.zoneName = defaultZone end
    if step.route == nil then step.route = ROUTABLE[action] or false end
    -- steps with map coords: normalise
    if step.coords and step.coords.player then step.coords = nil step.atPlayer = true end
    if step.action == "L" then step.minlevel = tonumber(step.title:match("%d+")) or step.minlevel end
    return step
end

-- A generated quest-line step for a quest with no wiki page (tools/gen_completion_guides.py) cannot know the quest's
-- name: Blizzard keeps quest text on the server, so the client data only gives ids and coordinates.  The title is
-- written as "Quest 12345" and swapped for the real one the moment the client can answer for that id.
-- How many to make, which trainer the engine chose (ALT), and the skill so far: part of the title, not of step.title.
local function titleExtras(step)
    if not (step.count or step.altName or step.skill) then return "" end
    local out = ""
    if step.count then out = out .. " x" .. step.count end
    if step.altName and step.altName ~= "" then out = out .. " - " .. step.altName end
    if step.skill and NS.Professions then
        local rank = NS.Professions.Skill(step.skill.name, step.skill.tier)
        if rank then out = out .. (" (%d/%d)"):format(rank, step.skill.target)
        else out = out .. (" (open %s so the addon can read this skill)"):format(step.skill.name) end
    end
    return out
end

function G.StepTitle(step)
    if not step then return "" end
    local t = step.title or ""
    local qid = t:match("^Quest (%d+)")
    if qid and step.qid then
        local live = U.QuestTitle(tonumber(qid))
        if live then
            local suffix = t:match("^Quest %d+(.*)$") or ""
            step.title = live .. suffix          -- cache it: the client answers the same way next time
            t = step.title
        end
    end
    return t .. titleExtras(step)
end

-- The note as the step card shows it (UI/GuideFrame.lua).  Generated notes end with where the step's map point came
-- from: "(location: the wiki's Ratchet page)", "(zone only; wiki: Borean Frog)", "(point: Blizzard quest map pin)",
-- "(Blizzard WorldMapOverlay 123)".  That is provenance, not something to do, and it made one-line notes wrap to three.
-- The card leaves such a tail off; the step's tooltip and Details panel show the note whole, and the guide data is
-- untouched.  Returns the card text and what was cut ("" when nothing).  Cached on the step: the window asks
-- every second.  tools/audit_step_text.lua counts what this saves; tools/test_step_window.lua checks the cases.
G.ASIDE_MIN = 150
local SOURCE_TAIL = { "^%(location:", "^%(zone only", "^%(wiki:", "^%(point:", "^%(Blizzard " }
function G.CardNote(step)
    local note = step and step.note
    if not note or note == "" then return "", "" end
    if step._cardNoteOf == note then return step._cardNote, step._cardTail end
    local short, tail = note, ""
    for _ = 1, 3 do
        local head, group, dot = short:match("^(.-)%s*(%b())(%.?)%s*$")
        if not group then break end
        local hit = false
        for _, p in ipairs(SOURCE_TAIL) do if group:find(p) then hit = true break end end
        if not hit then break end
        -- "Objective area (Blizzard quest map pin)." keeps its full stop: "Objective area."
        short = head .. ((dot ~= "" and head ~= "" and not head:find("[%.!%?:]$")) and "." or "")
        tail = group .. (tail ~= "" and (" " .. tail) or "")
    end
    -- An aside that is a sentence of its own, "(This item drops from most wolves under level 20.)": the wiki's
    -- words on where a reagent comes from.  Profession notes carry one per reagent and ran to ten lines; the card
    -- keeps the list and says there is more.
    -- Only a long note is shortened this way (ASIDE_MIN characters is about two lines of the card): in a short one a
    -- sentence in brackets may be the instruction itself ("Kill wolves. (Leave the alpha alone.)") and it fits anyway.
    if #short > G.ASIDE_MIN then
        local cut, asides = short:gsub("%s*%(%u[^()]-%.+%)", "")
        if asides > 0 then
            short = cut:gsub("%s+([;,%.])", "%1") .. "  |cff888888(click for more)|r"
            tail = (tail ~= "" and (tail .. " ") or "") .. "(asides)"
        end
    end
    step._cardNote, step._cardNoteOf, step._cardTail = short, note, tail
    return short, tail
end

-- Guide files spell their categories differently (e.g. "GOLD", "Professions",
-- our own "Profession"): fold them so the guide menu has one row per category, not three.
local TYPE_CANON = { gold = "Gold", leveling = "Leveling", quests = "Quests", dungeon = "Dungeons", dungeons = "Dungeons",
    profession = "Professions", professions = "Professions", daily = "Dailies", dailies = "Dailies",
    reputation = "Reputation", reputations = "Reputation", title = "Titles", titles = "Titles",
    event = "Events", events = "Events", achievement = "Achievements", achievements = "Achievements",
    pet = "Pets", pets = "Pets", storyline = "Storylines", storylines = "Storylines", mission = "Missions", missions = "Missions", mount = "Mounts", mounts = "Mounts", raid = "Raids", raids = "Raids" }
function G.NormalizeType(t)
    if not t or t == "" then return "Leveling" end
    return TYPE_CANON[tostring(t):lower()] or t
end

-- Gold and profession guides are always picked by the player, never as the "next" guide (see Progress.Refresh).
function G.IsSideGuide(g) return g ~= nil and (g.type == "Gold" or g.type == "Professions") end

-- Cached unfiltered G.Available(): the guide list asks on every keystroke and it is a full sort.
local availableAll
function G.InvalidateAvailable() availableAll = nil end

-- Register a guide.  def = { id, name, type ('Leveling'), zone, faction, minlevel, maxlevel, next, author, source, text (string) or fn () -> string }
-- Optional: prof, skillMin, skillMax, tier, requires ("Herbalism;75"), goldKind, folder, loop, farm (see docs/GUIDE_FORMAT.md).
function G.Register(def)
    if not def or not def.id then return end
    if G.registry[def.id] then return G.registry[def.id] end
    -- some imported sources ship empty placeholder guides (WIP dungeon guides, umbrella
    -- achievement entries); registering them gives unloadable 0-step guides
    if type(def.text) == "string" and not def.text:find("%S") then
        NS:Debug("skip empty guide " .. def.id)
        return
    end
    def.type = G.NormalizeType(def.type)
    def.source = def.source or "CompletionRoute"
    G.registry[def.id] = def
    tinsert(G.list, def.id)
    G.InvalidateAvailable()
    NS:Fire("GUIDE_REGISTERED", def)
    return def
end

-- Location corrections (NS.QuestCoordFixes): keyed by the step's own wrong location, so only that step moves.  No
-- such table ships today (no TOC loads one), so G.Steps applies nothing; the hook stays for corrections learned from
-- play (docs/IDEAS.md).
function G.CoordFixKey(s)
    if not (s.qid and #s.qid == 1 and (s.action == "A" or s.action == "C" or s.action == "T")) then return nil end
    local c = s.coords and s.coords[1]
    return ("%s|%d|%s|%s|%s"):format(s.action, s.qid[1], s.action == "C" and tostring(s.qo or "") or "",
        tostring(s.zone or ""), c and ("%.1f,%.1f"):format(c.x * 100, c.y * 100) or "")
end
function G.ApplyCoordFix(s)
    local k = G.CoordFixKey(s)
    local f = k and NS.QuestCoordFixes[k]
    if not f then return end
    s.coords = { { x = f[2] / 100, y = f[3] / 100 } }
    if s.zone ~= f[1] then s.zone, s.zoneName, s.zoneInherited = f[1], U.MapName(f[1]), nil end
    s.coordFixed = true
end

-- ---------------------------------------------------------------------------
-- Stable step keys (docs/STEP_KEYS.md)
-- ---------------------------------------------------------------------------
-- Progress marks (done, skipped, reopened: Core/Account.lua, Core/Progress.lua) are stored by a key that survives a
-- regenerated guide: an inserted or deleted line, a moved coordinate or a reordered block leave every other step's key
-- as it was, except the repeat number of identical steps behind an inserted or deleted identical step.
--   quest step     <action><quest ids, sorted, "+" between>[.<objective>]        "A123", "C123.2", "T123+124"
--   other step     <action>~<hash of the title's words + achievement/recipe/skill/mission ids>   "N~2bq9z0k1f"
--   repeats        "#2", "#3"... on the 2nd, 3rd step with the same key above, counted in the guide's own order
--   access chain   "@<chain>/" in front (Access.ParseSteps, Core/Progress.lua)
-- Coordinates, zones, notes and flags never take part, so a data fix that moves a point keeps the key.  Keys are made
-- once per parse, in author order, before a baked route order is applied (nothing is hashed per frame); they are a new
-- field only, so parsing results and G.RouteChecksum are unchanged.  G.KEY_VERSION goes up if the recipe ever changes.
G.KEY_VERSION = 1
-- 45-bit polynomial hash: (P - 1) * B + 255 < 2^53, so every step is exact in a Lua 5.1 double (no bit library needed)
local HASH_P, HASH_B = 68757246219383, 131
local byte, lower, gsub = string.byte, string.lower, string.gsub
local function hash45(str, h)
    h = h or 0
    for i = 1, #str do h = (h * HASH_B + byte(str, i)) % HASH_P end
    return h
end
G.Hash45 = hash45
-- Nine base-36 digits (P < 36^9), built with one string.char: a loop of concatenations cost four times as much
local DIG = {}
for d = 0, 35 do DIG[d] = ("0123456789abcdefghijklmnopqrstuvwxyz"):byte(d + 1) end
local char = string.char
local function base36(n)
    local d1 = n % 36 n = (n - d1) / 36
    local d2 = n % 36 n = (n - d2) / 36
    local d3 = n % 36 n = (n - d3) / 36
    local d4 = n % 36 n = (n - d4) / 36
    local d5 = n % 36 n = (n - d5) / 36
    local d6 = n % 36 n = (n - d6) / 36
    local d7 = n % 36 n = (n - d7) / 36
    local d8 = n % 36 n = (n - d8) / 36
    return char(DIG[n % 36], DIG[d8], DIG[d7], DIG[d6], DIG[d5], DIG[d4], DIG[d3], DIG[d2], DIG[d1])
end
G.Base36 = base36
-- The words of a title: case, punctuation and coordinates written into the text ("48.1, 42.9") folded away.  A title
-- never holds "|" (ParseLine splits the line on it), so there are no colour codes or links to strip.
function G.NormText(t)
    t = lower(t or "")
    t = gsub(t, "%d+%.%d+%s*,%s*%d+%.%d+", " ")
    t = gsub(t, "[%c%p%s]+", " ")
    return (t:match("^ ?(.-) ?$"))
end
-- The key of one step before repeats are counted, and the text that was hashed for it (nil when nothing was)
function G.StepBase(s)
    local a = s.action or "?"
    local q = s.qid
    if q and #q > 0 then
        local ids
        if #q == 1 then ids = tostring(q[1])
        else
            local c = {}
            for i = 1, #q do c[i] = q[i] end
            table.sort(c)
            ids = table.concat(c, "+")
        end
        local qo = s.qo
        if qo and qo ~= "" then
            local n = tostring(qo):match("^%s*(%d+)%s*$")
            if n then return a .. ids .. "." .. n end
            local t = G.NormText(tostring(qo))
            return a .. ids .. "." .. base36(hash45(t)), t
        end
        return a .. ids
    end
    local t = G.NormText(s.title)
    if s.ach then t = t .. "|a" .. s.ach .. "." .. (s.achCrit or "") end
    if s.recipe then t = t .. "|r" .. s.recipe end
    if s.skill then t = t .. "|s" .. lower(s.skill.name or "") .. "." .. (s.skill.target or "") .. "." .. (s.skill.tier or "") end
    if s.mission then t = t .. "|m" .. s.mission end
    return a .. "~" .. base36(hash45(t)), t
end
-- Give every step of a list (in the guide's own order) its key; prefix marks steps that are not the guide's own
function G.AssignKeys(steps, prefix)
    local seen, stepBase = {}, G.StepBase
    for i = 1, #steps do
        local s = steps[i]
        local base = stepBase(s)
        local n = (seen[base] or 0) + 1
        seen[base] = n
        local k = (n == 1) and base or (base .. "#" .. n)
        s.key = prefix and (prefix .. k) or k
    end
end
-- Checksum of a list's keys in list order: "<count>:<hash>".  withIndex also binds each step's author index (a saved
-- order written as author indices is only valid under that).
function G.KeySum(list, withIndex)
    local h = 0
    for i = 1, #list do
        local s = list[i]
        h = (hash45(s.key or "?", h) * HASH_B + 10) % HASH_P
        if withIndex then h = (hash45(tostring(s.index or 0), h) * HASH_B + 10) % HASH_P end
    end
    return #list .. ":" .. base36(h)
end
-- The guide's own steps in author order, summed: stored next to progress marks (Core/Account.lua) so a later release
-- can tell which version of the guide they were made on.  Cached per parsed list (weak: a list the menu drops goes).
local sumCache = setmetatable({}, { __mode = "k" })
local keySetCache = setmetatable({}, { __mode = "k" })
function G.GuideSum(id)
    local steps = G.Steps(id)
    if not steps then return nil end
    local v = sumCache[steps]
    if not v then
        local auth = {}
        for _, s in ipairs(steps) do if (s.index or 0) > 0 then auth[s.index] = s end end
        v = G.KeySum(auth)
        sumCache[steps] = v
    end
    return v
end
-- set of the keys in a parsed list (cached per list)
function G.KeySet(steps)
    local set = keySetCache[steps]
    if not set then
        set = {}
        for _, s in ipairs(steps) do if s.key then set[s.key] = true end end
        keySetCache[steps] = set
    end
    return set
end

-- Baked route order (Data/RouteOrder_<flavor>.lua, written offline by tools/optimize_routes.py from the
-- addon's own travel graph). Same checksum as the generator: a guide regenerated since the bake no longer
-- matches and simply keeps its author order. Spine entries reuse their zone guide's text, so they look up
-- `part`. The live window (Router.OrderSteps) still reorders the next steps on top of this order.
-- Checksum version 2 (2026-11-10): per step the action, the first quest id, the zone id and the first map point rounded
-- to 0.5 map percent, so a guide whose points moved (or whose step changed zone) no longer matches an old bake.
-- tools/cost_matrix.lua writes these parts into every row and tools/optimize_routes.py folds them the same way
-- (tools/test_route_order.lua checks that all three agree on real guides of every client).
G.ROUTE_CHECKSUM_VERSION = 2
local function half(v) return math.floor(v * 200 + 0.5) + 1 end    -- 0.5 % steps; 0 = no point
function G.RouteChecksumParts(s)
    local p = s.coords and s.coords[1]
    local hx, hy = 0, 0
    if p and p.x and p.y then hx, hy = half(p.x), half(p.y) end
    return s.action:byte(), (s.qid and s.qid[1]) or 0, tonumber(s.zone) or 0, hx, hy
end
function G.RouteChecksum(steps)
    local c, M = 0, 2147483647
    for _, s in ipairs(steps) do
        local a, q, z, hx, hy = G.RouteChecksumParts(s)
        c = (c * 31 + a + q) % M
        c = (c * 31 + z) % M
        c = (c * 31 + hx) % M
        c = (c * 31 + hy) % M
    end
    return c
end
local function decodeOrder(str, n)
    local out, used = {}, {}
    for part in str:gmatch("[^,]+") do
        local a, b = part:match("^(%d+)%-(%d+)$")
        a, b = tonumber(a or part), tonumber(b or a or part)
        if not a or not b or b < a then return nil end
        for i = a, b do
            if i < 1 or i > n or used[i] then return nil end
            used[i] = true out[#out + 1] = i
        end
    end
    if #out ~= n then return nil end
    return out
end
function G.BakedOrder(g, steps)
    local RO = NS.RouteOrder
    if not RO or not g or #steps < 2 then return nil end
    local r = NS.db and NS.db.profile and NS.db.profile.routing
    if r and r.baked == false then return nil end
    local e = RO[g.id] or (g.part and RO[g.part])
    if not e or e.n ~= #steps or e.sum ~= G.RouteChecksum(steps) then return nil end
    if not e.order then e.order = decodeOrder(e.o or "", e.n) or false end
    return e.order or nil
end

-- Parse (lazily) a guide's steps
function G.Steps(id)
    local g = G.registry[id]
    if not g then return nil end
    if g.steps then return g.steps end
    local text = type(g.text) == "function" and g.text() or g.text
    if type(text) ~= "string" or not text:find("%S") then
        -- placeholder entry (some imported sources ship empty WIP/umbrella guides, sometimes
        -- behind a lazy function so Register cannot see it). Hide it instead of offering a
        -- guide that loads zero steps.
        g.steps, g.empty = {}, true
        G.InvalidateAvailable()
        return g.steps
    end
    local steps, errors = {}, 0
    local n = 0
    local lastZone, lastZoneName
    for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        n = n + 1
        local s, err = G.ParseLine(line, n, g.zone)
        if s then
            -- Guide semantics: a zone stays in force until the guide names another one (an ALT step's zone is
            -- only its current choice among several, so it does not carry over to the lines after it)
            if s.alts then -- located by its own alternatives
            elseif s.zone then lastZone, lastZoneName = s.zone, s.zoneName
            elseif lastZone then s.zone, s.zoneName, s.zoneInherited = lastZone, lastZoneName, true end
            if NS.QuestCoordFixes then G.ApplyCoordFix(s) end
            -- Forever: every guide except the Forever-native files (def.forever) is written on Era maps
            if NS.isForever and not g.forever and s.coords and s.zone and NS.ForeverMapFix and NS.ForeverMapFix[s.zone] then
                for _, c in ipairs(s.coords) do c.x, c.y = U.EraToForever(s.zone, c.x, c.y) end
                s.eraMapFixed = true
            end
            if NS.isForever and not g.forever and s.alts and NS.ForeverMapFix then
                for _, a in ipairs(s.alts) do
                    if NS.ForeverMapFix[a.map] then a.x, a.y = U.EraToForever(a.map, a.x, a.y) end
                end
            end
            s.index = #steps + 1 s.guide = id steps[#steps + 1] = s
        elseif err then errors = errors + 1 NS:Debug("guide " .. id .. " line " .. n .. ": " .. err) end
    end
    -- stable keys for progress marks, in author order (see "Stable step keys" above)
    G.AssignKeys(steps)
    -- where each step is priced and its planning level (Routing/CostModel.lua), once, in author order
    if NS.CostModel then NS.CostModel.Locate(steps, g) end
    -- baked order: same step tables (s.index stays the author index and s.key the step key, so neither moves)
    local order = G.BakedOrder(g, steps)
    if order then
        local baked = {}
        for k, i in ipairs(order) do baked[k] = steps[i] end
        steps = baked
        g.baked = true
    else
        g.baked = nil
    end
    g.steps = steps
    g.parseErrors = errors
    return steps
end

-- Guides applicable to this character (faction), sorted by minlevel
function G.Available(filterType)
    if not filterType and availableAll then return availableAll end
    local out = {}
    for _, id in ipairs(G.list) do
        local g = G.registry[id]
        if not g.empty and (not filterType or (g.type or ""):lower() == filterType:lower()) and Cond.FactionMatch(g.faction) then out[#out + 1] = g end
    end
    table.sort(out, function(a, b)
        if (a.minlevel or 0) ~= (b.minlevel or 0) then return (a.minlevel or 0) < (b.minlevel or 0) end
        return (a.name or a.id) < (b.name or b.id)
    end)
    if not filterType then availableAll = out end
    return out
end

-- Best guess guide for current level (used on first run).
-- Prefer guides with an explicit level range containing the player, tightest range, native first.
function G.Suggest()
    local lvl = U.PlayerLevel()
    local best, bestScore
    for _, g in ipairs(G.Available("Leveling")) do
        local minl, maxl = g.minlevel, g.maxlevel
        if (minl or 0) <= lvl and (maxl or 999) >= lvl then
            local score = 0
            if minl and maxl then score = score + 1000 - (maxl - minl) end  -- explicit, tight ranges first
            if minl then score = score + minl * 2 end                       -- closest start below our level
            if g.source == "CompletionRoute" then score = score + 50 end
            if bestScore == nil or score > bestScore then best, bestScore = g, score end
        end
    end
    return best
end

-- First located step of a guide (lazy-parses; call only on shortlisted candidates)
local function guideStart(g)
    for _, s in ipairs(G.Steps(g.id) or {}) do
        if (s.coords or s.zone) and s.action ~= "h" then return s end
    end
end
G.GuideStart = guideStart     -- the first located step (parses the guide); UI/GuideMenu.lua prices a few of them

-- Next most optimal leveling guide after finishing one: level fit first,
-- then actual travel time from the player's position to the guide's start.
-- excludeId keeps us from re-suggesting the guide we just finished.
-- Travel seconds from the player to a guide's first located step (parses the guide - callers
-- must cap how many they ask for; the quest DB has thousands).
function G.GuideETA(g)
    local s0 = guideStart(g)
    if not s0 or not NS.Router then return nil end
    local ok, v = pcall(NS.Router.TravelSecondsFromPlayer, s0)
    return ok and v or nil
end

function G.SuggestNext(excludeId)
    local lvl = U.PlayerLevel()
    local cands = {}
    -- a guide parked on a level gate has nothing to offer until the gate opens (Core/Progress.lua); offering it
    -- anyway makes the chain load it, find it empty and move on
    local Prog = NS.Progress
    local function waiting(g) return Prog and Prog.ParkedWaiting and Prog.ParkedWaiting(g.id) end
    for _, g in ipairs(G.Available("Leveling")) do
        if g.id ~= excludeId and (g.minlevel or 0) <= lvl + 0.5 and (g.maxlevel or 999) >= lvl and not waiting(g) then
            cands[#cands + 1] = g
        end
    end
    if #cands == 0 then
        -- nothing spans our level (just dinged out of a bracket): take the nearest bracket above
        local bestMin
        for _, g in ipairs(G.Available("Leveling")) do
            if g.id ~= excludeId and (g.minlevel or 0) > lvl and (not bestMin or g.minlevel < bestMin) and not waiting(g) then bestMin = g.minlevel end
        end
        if not bestMin then return nil end
        for _, g in ipairs(G.Available("Leveling")) do
            if g.id ~= excludeId and g.minlevel == bestMin and not waiting(g) then cands[#cands + 1] = g end
        end
    end
    -- level-fit score, used both to shortlist and as the travel tiebreak base
    local function fit(g)
        local f = 0
        if g.minlevel and g.maxlevel then f = f + 20 - math.min(20, g.maxlevel - g.minlevel) end -- tight ranges know what they're for
        if g.minlevel then f = f + math.max(0, 10 - (lvl - g.minlevel)) end                      -- prefer ranges we just entered
        if g.source == "CompletionRoute" then f = f + 5 end
        return f
    end
    table.sort(cands, function(a, b) return fit(a) > fit(b) end)
    -- travel ETA only for the shortlist (parsing 700 guides would hitch the client)
    local best, bestScore, bestEta
    for i = 1, math.min(#cands, 8) do
        local g = cands[i]
        local eta
        local s0 = guideStart(g)
        if s0 and NS.Router then
            local ok, v = pcall(NS.Router.TravelSecondsFromPlayer, s0)
            if ok then eta = v end
        end
        local score = fit(g) - (eta and eta / 60 * 4 or 12) -- 4 pts/min of travel; unknown start ~ 3 min
        if not bestScore or score > bestScore then best, bestScore, bestEta = g, score, eta end
    end
    return best, bestEta
end

-- ---------------------------------------------------------------------------
-- Step signals: what completes a step by itself, as data (NS.StepSignal)
-- ---------------------------------------------------------------------------
-- Which NPC a step names, whether its items are in the bags, and (for the docs, the census and the tests) the name of
-- the rule that will finish it.  Core/Progress.lua does the completing (P.CheckStep and its event handlers) and calls
-- the predicates here, so the rule table cannot drift far from the code: tools/test_flow.lua runs both on the same
-- steps, and tools/census_step_kinds.lua counts the shipped guides with Sig.Of.  It lives in this file because every
-- offline harness that loads Progress.lua loads Guide.lua first.
--
-- The principle (owner's rule, 2026-11-12): a step completes by itself only on something the client reports.  A step
-- nothing reports on stays manual (the forward arrow); no rule here guesses.
local Sig = {}
NS.StepSignal = Sig

local ACCEPT = { A = true, a = true, ["!"] = true }
local TURNIN = { T = true, t = true }
Sig.ACCEPT, Sig.TURNIN = ACCEPT, TURNIN

-- ---------------------------------------------------------------------------
-- Items: the step's L items are all in the bags
-- ---------------------------------------------------------------------------
-- A quantity under 1 is not a count to reach (some guide formats write "until you have none" that way): such a step
-- has no bag rule.  count(itemID) is the client read (Core/Util.lua U.ItemCount).
function Sig.HasCounts(step)
    local loot = step.loot
    if not loot or #loot == 0 then return false end
    for i = 1, #loot do if (loot[i].qty or 0) < 1 then return false end end
    return true
end
function Sig.BagsHold(step, count)
    if not Sig.HasCounts(step) then return false end
    local loot = step.loot
    for i = 1, #loot do if (count(loot[i].id) or 0) < loot[i].qty then return false end end
    return true
end
-- A buy step that names its item with U/ITEM instead of L: the item, COUNT times (once without COUNT)
function Sig.BuyHeld(step, count)
    if step.action ~= "B" or step.loot or not step.item then return false end
    return (count(step.item) or 0) >= math.max(1, step.count or 1)
end

-- ---------------------------------------------------------------------------
-- Talking: the NPC a step names
-- ---------------------------------------------------------------------------
-- Only a step nothing else reports on can be finished by a conversation: a quest step is the quest log's to finish
-- (opening a gossip window is not having done the objective), a train or buy step needs the recipe or the item, a
-- hearth step needs the bind, and a kill step's T tag is the thing to kill.
--   N note, R run to     the T tag, the ALT names, "From X." / "To X." / "Talk to X" / "Speak with X" in the note,
--                        "Talk to X" / "Speak with X" as the title
--   C complete, l loot   (without a quest) only the words "Talk to X" / "Speak with X"
local TALK_FULL = { N = true, R = true }
local TALK_WORDS = { C = true, l = true }
function Sig.TalkEligible(step)
    if not (TALK_FULL[step.action] or TALK_WORDS[step.action]) then return false end
    return not (step.qid or step.ach or step.skill or step.recipe or step.loot or step.mission)
end

local lower = string.lower
local function clean(name)
    if type(name) ~= "string" then return nil end
    name = name:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    name = name:gsub("^%s+", ""):gsub("[%s%.!,;:]+$", "")
    if #name < 2 then return nil end
    return lower(name)
end
local function add(set, name)
    name = clean(name)
    if name then set[name] = true end
end
-- "Talk to X" / "Speak with X" (and "From X." / "To X.") count only when they ARE the step: the words open the title
-- or the note, and what follows is one name, optionally with where the NPC stands ("Marshal Dughan in Goldshire",
-- "Guard Thomas at the bridge").  A second sentence or clause is a second thing to do that no window reports
-- ("Talk to Bob and buy five flasks", "Speak with Bob, then ride to Lakeshire", "Talk to Bob. Kill ten wolves."), and
-- words in the middle of a note are not an instruction for now ("After you talk to Bob, ..."): such a step offers no
-- name and stays manual.  A cut that is not a name matches no NPC (names are compared whole).
local PLACE = { " in ", " at ", " inside ", " outside ", " near ", " behind ", " on ", " by ", " about ", " again" }
local function addPhrase(set, text)
    if not text or text == "" then return end
    text = text:gsub("%s*%b()", "")                      -- "(the innkeeper)", a trailing source note
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    local low = lower(text)
    if text:find("[%.!%?;:]%s") or text:find(",", 1, true) or low:find(" and ", 1, true) or low:find(" then ", 1, true) then
        -- more than one clause: only a short text can still be one name ("Dr. Weavil.", "Tooga and Torta")
        local _, words = text:gsub("%S+", "")
        if words <= 3 then add(set, text) end
        return
    end
    add(set, text)                                        -- the whole text, then each cut at where the NPC stands
    for _, j in ipairs(PLACE) do
        local at = low:find(j, 1, true)
        if at and at > 1 then add(set, text:sub(1, at - 1)) end
    end
end
local WORDS = { "talk to ", "talk with ", "speak with ", "speak to " }
local function addWords(set, text)
    if not text then return end
    text = text:gsub("^%s+", "")
    local low = lower(text)
    for _, w in ipairs(WORDS) do
        if low:sub(1, #w) == w then addPhrase(set, text:sub(#w + 1)) return end
    end
end
-- The lower-case names of the NPCs whose window finishes this step (a set), or nil.  Cached on the step.
function Sig.TalkNames(step)
    local c = step._talk
    if c ~= nil then return c or nil end
    local set = {}
    if Sig.TalkEligible(step) then
        addWords(set, step.note)
        addWords(set, step.title)
        if TALK_FULL[step.action] then
            if step.target then for name in step.target:gmatch("[^;]+") do add(set, name) end end
            if step.alts then
                for _, a in ipairs(step.alts) do add(set, (a.name or ""):gsub("%s*%b()%s*$", "")) end   -- "Innkeeper Allison (Stormwind City)"
            end
            local note = step.note
            if note then
                local who = note:match("^From (.+)$") or note:match("^To (.+)$")
                if who then addPhrase(set, who) end
            end
        end
    end
    step._talk = next(set) and set or false
    return step._talk or nil
end
-- Does the NPC whose window just opened finish this step?  name: UnitName("npc"), already checked for secrecy.
function Sig.TalkMatches(step, name)
    if type(name) ~= "string" or name == "" then return false end
    local set = Sig.TalkNames(step)
    return set ~= nil and set[lower(name)] == true
end

-- Repair / sell: any merchant window is the step being done (it is about selling, not about one vendor)
function Sig.MerchantCompletes(step)
    return step.action == "r" and not (step.qid or step.ach or step.loot)
end
-- ...unless the step is about repairing only ("Repair", not "Repair and sell"): then the merchant has to be one who
-- repairs (CanMerchantRepair), or a grocer's window would tick a repair that did not happen
function Sig.NeedsRepairer(step)
    local t = lower(step.title or "")
    return t:find("repair", 1, true) ~= nil and not t:find("sell", 1, true)
end
-- Treasure with a spot and nothing else to read: finished by looting a chest (a game object, not a corpse and not a
-- fishing bobber) while standing at the spot
function Sig.LootAtSpot(step)
    return step.action == "$" and step.coords ~= nil and not (step.qid or step.ach or step.loot)
end

-- ---------------------------------------------------------------------------
-- The rule that finishes a step, by name.  Mirrors P.CheckStep's order.  Returns
--   rule, nil, isNew     the step completes by itself; isNew marks the rules added on 2026-11-12
--   nil, hint            it stays manual; hint says what it does carry
-- guide (optional) is only used for hints.
-- ---------------------------------------------------------------------------
local ARRIVE = { F = true, b = true, J = true, D = true }
function Sig.Of(step, guide)
    local a = step.action
    if step.skill then return "profession skill reached" end
    if step.recipe then return "recipe or rank learned" end
    if ACCEPT[a] then
        if step.qid then return "quest accepted (quest log)" end
        return nil, "accept without a quest id"
    end
    if TURNIN[a] then
        if step.qid then return "quest turned in" end
        return nil, "turn-in without a quest id"
    end
    if a == "C" or a == "K" or a == "l" then
        if step.qid then return "quest objectives (quest log)" end
        if Sig.HasCounts(step) then return "items in the bags" end
    elseif a == "G" then
        if step.coords or step.zone then return "arrival at the waypoint" end
    elseif a == "R" then
        if step.coords or step.zone or step.alts then return "arrival" end
    elseif ARRIVE[a] then
        if step.coords or step.zone then return "arrival" end
    elseif a == "H" then
        return "Hearthstone cast"
    elseif a == "L" then
        if step.minlevel then return "level reached" end
    elseif a == "U" then
        if step.item then return "item used up" end
        if step.qid then return "quest objectives (quest log)" end
        if Sig.HasCounts(step) then return "items in the bags" end
    elseif a == "B" then
        if Sig.HasCounts(step) then return "items in the bags" end
        if step.item then return "bought item in the bags", nil, true end
    elseif a == "h" then
        return "hearth bound"
    elseif a == "f" then
        return "flight map opened"
    end
    if step.ach then return "achievement or criterion earned" end
    if step.qid then return "quest complete" end
    if Sig.HasCounts(step) then return "items in the bags", nil, true end
    if step.mission then return "mission success (client event)", nil, true end
    if Sig.MerchantCompletes(step) then return "merchant window opened", nil, true end
    if Sig.LootAtSpot(step) then return "loot taken at the spot", nil, true end
    if Sig.TalkNames(step) then return "talk to the named NPC", nil, true end
    -- manual: say what it has, so the next rule to write is visible
    local has = {}
    if step.target then has[#has + 1] = "target tag" end
    if step.item then has[#has + 1] = "item tag" end
    if step.coords then has[#has + 1] = "map point" elseif step.zone then has[#has + 1] = "zone" end
    if step.note and step.note ~= "" then has[#has + 1] = "note" end
    return nil, (#has > 0 and ("only " .. table.concat(has, ", ")) or "title only")
end
