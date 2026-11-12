-- CompletionRoute :: Data/Farm_routes.lua
-- Fallback seed farm circuits, one per zone per gathering profession.
--
-- The real gold guides are generated (tools/wiki/gen_gold.py -> Guides/Imported_Gold_<flavor>.lua, from Warcraft Wiki
-- node, zone and mob data).  This table is only used for a zone + profession those files do not cover, for example when
-- the generated data has not been built.  RegisterSeeds skips a seed as soon as a generated Gathering guide exists for
-- the same zone and profession, so there are never two circuits for one zone.
--
-- HONESTY NOTE (read before "fixing" these): these are COARSE rings, not surveyed node routes.  No third-party node
-- database ships with CompletionRoute or is read by it (none is free to redistribute).  Each seed is
-- an ellipse of waypoints over the gatherable body of a zone: it gets you circling the right ground, and every node you
-- actually loot is recorded (Core/Farm.lua) so `/cr farm build` replaces the ring with the real harvest route.  Seeds are
-- labelled "(coarse)" in the guide list for exactly this reason.
--
-- Copyright (c) 2026 Daniel Bates / Bates LLC.  All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 (see LICENSE); 10% revenue share for commercial use.
local ADDON, NS = ...
local U, G = NS.Util, NS.Guide
local F = NS.Farm

-- zone name, ellipse centre + radii in zone coords, the gathering professions that have nodes there, level band, flavors
-- Zone NAMES (not ids) so the same table works on era / tbc / mop / retail, which number maps differently.
NS.FarmSeeds = {
    -- Eastern Kingdoms
    { zone = "Elwynn Forest",        cx = 0.50, cy = 0.55, rx = 0.24, ry = 0.20, kinds = { "Herbalism", "Mining" }, lvl = 1,  faction = "Alliance" },
    { zone = "Westfall",             cx = 0.47, cy = 0.55, rx = 0.22, ry = 0.22, kinds = { "Herbalism", "Mining" }, lvl = 10, faction = "Alliance" },
    { zone = "Redridge Mountains",   cx = 0.45, cy = 0.55, rx = 0.22, ry = 0.18, kinds = { "Herbalism", "Mining" }, lvl = 15 },
    { zone = "Duskwood",             cx = 0.50, cy = 0.55, rx = 0.26, ry = 0.16, kinds = { "Herbalism" },        lvl = 18 },
    { zone = "Hillsbrad Foothills",  cx = 0.50, cy = 0.50, rx = 0.24, ry = 0.20, kinds = { "Herbalism", "Mining" }, lvl = 20 },
    { zone = "Arathi Highlands",     cx = 0.50, cy = 0.50, rx = 0.26, ry = 0.22, kinds = { "Mining" },           lvl = 30 },
    { zone = "Badlands",             cx = 0.50, cy = 0.50, rx = 0.24, ry = 0.20, kinds = { "Mining" },           lvl = 35 },
    { zone = "The Hinterlands",      cx = 0.52, cy = 0.50, rx = 0.24, ry = 0.20, kinds = { "Herbalism" },        lvl = 40 },
    { zone = "Western Plaguelands",  cx = 0.50, cy = 0.50, rx = 0.24, ry = 0.22, kinds = { "Herbalism" },        lvl = 50 },
    { zone = "Eastern Plaguelands",  cx = 0.50, cy = 0.52, rx = 0.26, ry = 0.20, kinds = { "Herbalism" },        lvl = 53 },
    -- Kalimdor
    { zone = "Durotar",              cx = 0.52, cy = 0.55, rx = 0.20, ry = 0.24, kinds = { "Herbalism", "Mining" }, lvl = 1,  faction = "Horde" },
    { zone = "The Barrens",          cx = 0.50, cy = 0.50, rx = 0.22, ry = 0.28, kinds = { "Herbalism", "Mining" }, lvl = 10 },
    { zone = "Stonetalon Mountains", cx = 0.50, cy = 0.50, rx = 0.22, ry = 0.22, kinds = { "Mining" },           lvl = 18 },
    { zone = "Desolace",             cx = 0.50, cy = 0.50, rx = 0.22, ry = 0.24, kinds = { "Herbalism", "Mining" }, lvl = 30 },
    { zone = "Feralas",              cx = 0.50, cy = 0.50, rx = 0.26, ry = 0.20, kinds = { "Herbalism" },        lvl = 40 },
    { zone = "Tanaris",              cx = 0.50, cy = 0.50, rx = 0.26, ry = 0.20, kinds = { "Mining" },           lvl = 45 },
    { zone = "Un'Goro Crater",       cx = 0.50, cy = 0.50, rx = 0.22, ry = 0.20, kinds = { "Herbalism" },        lvl = 48 },
    { zone = "Felwood",              cx = 0.50, cy = 0.50, rx = 0.18, ry = 0.28, kinds = { "Herbalism" },        lvl = 48 },
    { zone = "Winterspring",         cx = 0.50, cy = 0.50, rx = 0.26, ry = 0.20, kinds = { "Herbalism", "Mining" }, lvl = 53 },
    { zone = "Silithus",             cx = 0.50, cy = 0.50, rx = 0.24, ry = 0.20, kinds = { "Herbalism" },        lvl = 55 },
    -- Outland (tbc / retail)
    { zone = "Hellfire Peninsula",   cx = 0.50, cy = 0.50, rx = 0.24, ry = 0.22, kinds = { "Herbalism", "Mining" }, lvl = 58 },
    { zone = "Zangarmarsh",          cx = 0.50, cy = 0.50, rx = 0.24, ry = 0.22, kinds = { "Herbalism" },        lvl = 60 },
    { zone = "Nagrand",              cx = 0.50, cy = 0.50, rx = 0.24, ry = 0.22, kinds = { "Herbalism", "Mining" }, lvl = 64 },
    { zone = "Terokkar Forest",      cx = 0.50, cy = 0.50, rx = 0.24, ry = 0.22, kinds = { "Herbalism" },        lvl = 62 },
    { zone = "Blade's Edge Mountains", cx = 0.50, cy = 0.50, rx = 0.22, ry = 0.24, kinds = { "Mining" },         lvl = 65 },
    { zone = "Netherstorm",          cx = 0.50, cy = 0.50, rx = 0.24, ry = 0.22, kinds = { "Mining" },           lvl = 67 },
    -- Pandaria (mop / retail)
    { zone = "Valley of the Four Winds", cx = 0.50, cy = 0.50, rx = 0.28, ry = 0.18, kinds = { "Herbalism" },    lvl = 86 },
    { zone = "Kun-Lai Summit",       cx = 0.50, cy = 0.50, rx = 0.24, ry = 0.22, kinds = { "Mining" },           lvl = 87 },
    { zone = "Townlong Steppes",     cx = 0.50, cy = 0.50, rx = 0.24, ry = 0.20, kinds = { "Herbalism", "Mining" }, lvl = 88 },
    { zone = "Dread Wastes",         cx = 0.50, cy = 0.50, rx = 0.24, ry = 0.20, kinds = { "Herbalism", "Mining" }, lvl = 89 },
    { zone = "The Jade Forest",      cx = 0.50, cy = 0.50, rx = 0.24, ry = 0.22, kinds = { "Herbalism" },        lvl = 85 },
}

local WAYPOINTS = 14

-- One ellipse of G waypoints. Walking a ring beats a there-and-back line: you are always moving onto
-- ground whose nodes respawned while you were on the far side.
local function ringText(seed, mapID, kind)
    local lines = {}
    for i = 1, WAYPOINTS do
        local a = (i - 1) / WAYPOINTS * math.pi * 2
        local x = seed.cx + seed.rx * math.cos(a)
        local y = seed.cy + seed.ry * math.sin(a)
        x = math.max(0.03, math.min(0.97, x))
        y = math.max(0.03, math.min(0.97, y))
        lines[#lines + 1] = ("G %s %d|M|%.2f,%.2f|Z|%d; %s|RAD|60|N|Gather everything on the way: %s. The circuit repeats - this ring is coarse until you have farmed here (/cr farm build).|"):format(
            seed.zone, i, x * 100, y * 100, mapID, seed.zone, kind)
    end
    return table.concat(lines, "\n")
end

-- a generated Gathering guide for this zone and profession already exists: the seed would only duplicate it
local function generatedCoverage()
    local have = {}
    for _, id in ipairs(G.list or {}) do
        local g = G.registry[id]
        local f = g and g.goldKind == "Gathering" and g.farm
        if f and f.map and f.kind then have[f.map .. ":" .. f.kind] = true end
    end
    return have
end

function F.RegisterSeeds()
    if not (NS.db and NS.db.profile.farm and NS.db.profile.farm.seeds) then return 0 end
    local n, have = 0, generatedCoverage()
    for _, seed in ipairs(NS.FarmSeeds) do
        local mapID = U.MapIDByName(seed.zone)
        if mapID then
            for _, kind in ipairs(seed.kinds) do
                local id = ("%sSeed_%d_%s"):format(F.GUIDE_PREFIX, mapID, kind)
                if not G.registry[id] and not have[mapID .. ":" .. kind] then
                    G.Register({
                        id = id, name = ("%s %s circuit (coarse)"):format(seed.zone, kind),
                        type = "Gold", folder = "Gathering", goldKind = "Gathering", loop = true, zone = seed.zone, faction = seed.faction,
                        minlevel = seed.lvl, maxlevel = seed.lvl + 9, requires = kind .. ";1",
                        source = "CompletionRoute", author = "CompletionRoute seed ring",
                        text = ringText(seed, mapID, kind),
                        farm = { map = mapID, kind = kind, nodes = WAYPOINTS, coarse = true },
                    })
                    n = n + 1
                end
            end
        end
    end
    if n > 0 then NS:Debug(("farm seeds: %d circuits registered"):format(n)) end
    return n
end
