-- CompletionRoute :: Core/Guide.lua
-- Guide registry + parser.  Native format = WoW-Pro compatible line syntax (community standard):
--   <ACTION> <Title>|QID|123|M|48.15,42.95|Z|1429; Elwynn Forest|N|note|...
-- Actions: A accept, C complete, T turn-in, K kill, R run to, h set hearth, H hearth, F fly, f get flight path,
--          N note, B buy, b boat/zeppelin, U use item, L level, r repair/sell, D dungeon, J jump/portal, $ treasure, = misc, ! daily
-- Extensions (CompletionRoute-only, ignored by WoWPro): |ROUTE| step may be reordered by optimizer (default for A/C/T/K/r/B/$)
--   |FIXED| never reorder; |ITEM|id (also WoWPro |U|id) drives the arrow's item button.
local ADDON, NS = ...
local U, Cond = NS.Util, NS.Cond

local G = {}
NS.Guide = G
G.registry = {}      -- id -> guide record
G.list = {}          -- ordered ids

local ACTIONS = { A=1, a=1, C=1, T=1, t=1, K=1, R=1, H=1, h=1, F=1, f=1, N=1, B=1, b=1, U=1, L=1, l=1, r=1, D=1, J=1, M=1, ["!"]=1, ["$"]=1, ["="]=1, G=1,
    P=1, ["*"]=1, d=1, s=1 } -- WoW-Pro extras: P portal/teleport, * destroy-item, d death-step, s speak-with
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

-- Generated quest guides (tools/gen_quest_guides_retail.py) cannot know quest names: Blizzard keeps
-- quest text on the server, so the client data only gives ids and coordinates.  The title is written
-- as "Quest 12345" and swapped for the real one the moment the client can answer for that id.
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

-- Imported sources spell their categories differently (e.g. "GOLD", WoW-Pro "Professions",
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

-- Audited location corrections (Data/QuestCoordFixes_<flavor>.lua, generated by
-- tools/audit_quest_locations_retail.py): keyed by the step's own wrong location, so only that step moves.
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
function G.RouteChecksum(steps)
    local c = 0
    for _, s in ipairs(steps) do c = (c * 31 + s.action:byte() + ((s.qid and s.qid[1]) or 0)) % 2147483647 end
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
