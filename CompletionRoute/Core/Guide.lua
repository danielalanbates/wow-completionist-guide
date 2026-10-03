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
    J="Portal/Jump", M="Misc", ["!"]="Daily", ["$"]="Treasure", ["="]="Misc", G="Farm" }
G.ACTION_ICON = { A="Interface\\GossipFrame\\AvailableQuestIcon", a="Interface\\GossipFrame\\AvailableQuestIcon",
    C="Interface\\Icons\\Ability_DualWield", T="Interface\\GossipFrame\\ActiveQuestIcon", t="Interface\\GossipFrame\\ActiveQuestIcon",
    K="Interface\\Icons\\Ability_Creature_Cursed_02", R="Interface\\Icons\\Ability_Tracking", H="Interface\\Icons\\INV_Misc_Rune_01",
    h="Interface\\Icons\\INV_Misc_Rune_01", F="Interface\\Icons\\Ability_Druid_FlightForm", f="Interface\\Icons\\Ability_Hunter_EagleEye",
    N="Interface\\Icons\\INV_Misc_Note_01", B="Interface\\Icons\\INV_Misc_Coin_01", b="Interface\\Icons\\Spell_Frost_SummonWaterElemental",
    U="Interface\\Icons\\INV_Misc_Bag_08", L="Interface\\Icons\\Spell_ChargePositive", l="Interface\\Icons\\INV_Misc_Bag_08",
    r="Interface\\Icons\\Ability_Repair", D="Interface\\TAXIFRAME\\UI-Taxi-Icon-Green", J="Interface\\Icons\\spell_arcane_teleportironforge",
    M="Interface\\Icons\\INV_Misc_QuestionMark", ["!"]="Interface\\GossipFrame\\DailyQuestIcon", ["$"]="Interface\\Icons\\INV_Misc_Bag_10",
    ["="]="Interface\\Icons\\INV_Misc_QuestionMark", G="Interface\\Icons\\INV_Misc_Herb_07" }
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
function G.StepTitle(step)
    if not step then return "" end
    local t = step.title or ""
    local qid = t:match("^Quest (%d+)")
    if qid and step.qid then
        local live = U.QuestTitle(tonumber(qid))
        if live then
            local suffix = t:match("^Quest %d+(.*)$") or ""
            step.title = live .. suffix          -- cache it: the client answers the same way next time
            return step.title
        end
    end
    return t
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

-- Register a guide.  def = { id, name, type ('Leveling'), zone, faction, minlevel, maxlevel, next, author, source, text (string) or fn () -> string }
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
    NS:Fire("GUIDE_REGISTERED", def)
    return def
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
        return g.steps
    end
    local steps, errors = {}, 0
    local n = 0
    local lastZone, lastZoneName
    for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        n = n + 1
        local s, err = G.ParseLine(line, n, g.zone)
        if s then
            -- Guide semantics: a zone stays in force until the guide names another one
            if s.zone then lastZone, lastZoneName = s.zone, s.zoneName
            elseif lastZone then s.zone, s.zoneName, s.zoneInherited = lastZone, lastZoneName, true end
            s.index = #steps + 1 s.guide = id steps[#steps + 1] = s
        elseif err then errors = errors + 1 NS:Debug("guide " .. id .. " line " .. n .. ": " .. err) end
    end
    g.steps = steps
    g.parseErrors = errors
    return steps
end

-- Guides applicable to this character (faction), sorted by minlevel
function G.Available(filterType)
    local out = {}
    for _, id in ipairs(G.list) do
        local g = G.registry[id]
        if not g.empty and (not filterType or (g.type or ""):lower() == filterType:lower()) and Cond.FactionMatch(g.faction) then out[#out + 1] = g end
    end
    table.sort(out, function(a, b)
        if (a.minlevel or 0) ~= (b.minlevel or 0) then return (a.minlevel or 0) < (b.minlevel or 0) end
        return (a.name or a.id) < (b.name or b.id)
    end)
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
    for _, g in ipairs(G.Available("Leveling")) do
        if g.id ~= excludeId and (g.minlevel or 0) <= lvl + 0.5 and (g.maxlevel or 999) >= lvl then
            cands[#cands + 1] = g
        end
    end
    if #cands == 0 then
        -- nothing spans our level (just dinged out of a bracket): take the nearest bracket above
        local bestMin
        for _, g in ipairs(G.Available("Leveling")) do
            if g.id ~= excludeId and (g.minlevel or 0) > lvl and (not bestMin or g.minlevel < bestMin) then bestMin = g.minlevel end
        end
        if not bestMin then return nil end
        for _, g in ipairs(G.Available("Leveling")) do
            if g.id ~= excludeId and g.minlevel == bestMin then cands[#cands + 1] = g end
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
