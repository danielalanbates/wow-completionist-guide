-- CompletionRoute :: UI/ItemScore.lua
-- Gear advisor: scores any item by class stat weights, compares it to what
-- you have equipped in that slot, and annotates tooltips: "CompletionRoute: 124 (+18% upgrade over Worn Axe)".
-- Weights are leveling-oriented defaults per class (TBC/Classic era); /or weights to inspect.
local ADDON, NS = ...
local U = NS.Util
local IS = {}
NS.ItemScore = IS

-- stat keys from C_Item.GetItemStats / GetItemStats
local W = {
    WARRIOR = { ITEM_MOD_STRENGTH_SHORT = 1.0, ITEM_MOD_AGILITY_SHORT = 0.5, ITEM_MOD_STAMINA_SHORT = 0.6, ITEM_MOD_CRIT_RATING_SHORT = 0.9, ITEM_MOD_HIT_RATING_SHORT = 1.0, ITEM_MOD_ATTACK_POWER_SHORT = 0.45, ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 3.2 },
    PALADIN = { ITEM_MOD_STRENGTH_SHORT = 1.0, ITEM_MOD_STAMINA_SHORT = 0.55, ITEM_MOD_INTELLECT_SHORT = 0.35, ITEM_MOD_CRIT_RATING_SHORT = 0.8, ITEM_MOD_HIT_RATING_SHORT = 0.9, ITEM_MOD_ATTACK_POWER_SHORT = 0.45, ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 3.0, ITEM_MOD_SPELL_POWER_SHORT = 0.25 },
    HUNTER = { ITEM_MOD_AGILITY_SHORT = 1.0, ITEM_MOD_INTELLECT_SHORT = 0.35, ITEM_MOD_STAMINA_SHORT = 0.4, ITEM_MOD_CRIT_RATING_SHORT = 0.8, ITEM_MOD_HIT_RATING_SHORT = 1.0, ITEM_MOD_ATTACK_POWER_SHORT = 0.5, ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 2.6 },
    ROGUE = { ITEM_MOD_AGILITY_SHORT = 1.0, ITEM_MOD_STRENGTH_SHORT = 0.55, ITEM_MOD_STAMINA_SHORT = 0.4, ITEM_MOD_CRIT_RATING_SHORT = 0.85, ITEM_MOD_HIT_RATING_SHORT = 1.05, ITEM_MOD_ATTACK_POWER_SHORT = 0.5, ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 2.8 },
    PRIEST = { ITEM_MOD_INTELLECT_SHORT = 0.8, ITEM_MOD_SPIRIT_SHORT = 0.9, ITEM_MOD_STAMINA_SHORT = 0.35, ITEM_MOD_SPELL_POWER_SHORT = 1.0, ITEM_MOD_SPELL_HEALING_DONE_SHORT = 0.9, ITEM_MOD_SPELL_DAMAGE_DONE_SHORT = 1.0, ITEM_MOD_MANA_REGENERATION_SHORT = 1.1 },
    SHAMAN = { ITEM_MOD_INTELLECT_SHORT = 0.8, ITEM_MOD_STAMINA_SHORT = 0.4, ITEM_MOD_SPELL_POWER_SHORT = 1.0, ITEM_MOD_SPELL_DAMAGE_DONE_SHORT = 1.0, ITEM_MOD_CRIT_RATING_SHORT = 0.7, ITEM_MOD_AGILITY_SHORT = 0.4, ITEM_MOD_STRENGTH_SHORT = 0.5, ITEM_MOD_ATTACK_POWER_SHORT = 0.3, ITEM_MOD_MANA_REGENERATION_SHORT = 1.0 },
    MAGE = { ITEM_MOD_INTELLECT_SHORT = 0.9, ITEM_MOD_SPIRIT_SHORT = 0.45, ITEM_MOD_STAMINA_SHORT = 0.35, ITEM_MOD_SPELL_POWER_SHORT = 1.0, ITEM_MOD_SPELL_DAMAGE_DONE_SHORT = 1.0, ITEM_MOD_CRIT_RATING_SHORT = 0.75, ITEM_MOD_HIT_RATING_SHORT = 0.9 },
    WARLOCK = { ITEM_MOD_INTELLECT_SHORT = 0.75, ITEM_MOD_STAMINA_SHORT = 0.55, ITEM_MOD_SPELL_POWER_SHORT = 1.0, ITEM_MOD_SPELL_DAMAGE_DONE_SHORT = 1.0, ITEM_MOD_CRIT_RATING_SHORT = 0.7, ITEM_MOD_HIT_RATING_SHORT = 0.9 },
    DRUID = { ITEM_MOD_STRENGTH_SHORT = 0.6, ITEM_MOD_AGILITY_SHORT = 0.7, ITEM_MOD_INTELLECT_SHORT = 0.6, ITEM_MOD_SPIRIT_SHORT = 0.5, ITEM_MOD_STAMINA_SHORT = 0.45, ITEM_MOD_SPELL_POWER_SHORT = 0.7, ITEM_MOD_ATTACK_POWER_SHORT = 0.35, ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 1.8 },
}
W.DEATHKNIGHT = W.WARRIOR; W.MONK = W.ROGUE; W.DEMONHUNTER = W.ROGUE; W.EVOKER = W.MAGE
-- armor is a small bonus for everyone
local ARMOR_W = 0.03

-- equip location -> inventory slot ids to compare against
local SLOTS = {
    INVTYPE_HEAD = {1}, INVTYPE_NECK = {2}, INVTYPE_SHOULDER = {3}, INVTYPE_CLOAK = {15}, INVTYPE_CHEST = {5}, INVTYPE_ROBE = {5},
    INVTYPE_WRIST = {9}, INVTYPE_HAND = {10}, INVTYPE_WAIST = {6}, INVTYPE_LEGS = {7}, INVTYPE_FEET = {8},
    INVTYPE_FINGER = {11, 12}, INVTYPE_TRINKET = {13, 14}, INVTYPE_WEAPON = {16, 17}, INVTYPE_2HWEAPON = {16},
    INVTYPE_WEAPONMAINHAND = {16}, INVTYPE_WEAPONOFFHAND = {17}, INVTYPE_SHIELD = {17}, INVTYPE_HOLDABLE = {17},
    INVTYPE_RANGED = {18}, INVTYPE_RANGEDRIGHT = {18}, INVTYPE_THROWN = {18}, INVTYPE_RELIC = {18},
}

local function getStats(link)
    local ok, stats
    if C_Item and C_Item.GetItemStats then ok, stats = pcall(C_Item.GetItemStats, link)
    elseif GetItemStats then ok, stats = pcall(GetItemStats, link) end
    return ok and stats or nil
end

function IS.Score(link)
    if not link then return nil end
    local stats = getStats(link)
    if not stats then return nil end
    local w = W[NS.player and NS.player.class or "WARRIOR"] or W.WARRIOR
    local s = 0
    for stat, val in pairs(stats) do
        local wt = w[stat]
        if wt then s = s + val * wt
        elseif stat == "RESISTANCE0_NAME" then s = s + val * ARMOR_W end
    end
    return s > 0 and s or nil
end

-- Compare an item to what is equipped in its slot.  Returns score, equippedScore, pct, equippedName
function IS.Compare(link)
    local score = IS.Score(link)
    if not score then return nil end
    local equipLoc = select(9, (C_Item and C_Item.GetItemInfo or GetItemInfo)(link))
    local slots = equipLoc and SLOTS[equipLoc]
    if not slots then return score end
    local worst, worstLink
    for _, slot in ipairs(slots) do
        local el = GetInventoryItemLink("player", slot)
        if not el then worst, worstLink = 0, nil break end  -- empty slot: pure upgrade
        local es = IS.Score(el) or 0
        if not worst or es < worst then worst, worstLink = es, el end
    end
    if not worst then return score end
    local pct = worst > 0 and ((score - worst) / worst * 100) or 100
    local ename = worstLink and ((C_Item and C_Item.GetItemInfo or GetItemInfo)(worstLink)) or nil
    return score, worst, pct, ename
end

-- What wearing a quest reward would gain, for IS.ClearWinner.  Unlike IS.Compare (tooltips), it does not treat every
-- empty slot as a pure upgrade, because the hands are not independent slots:
--   * armor, rings, trinkets, cloak: weighed against the worst item of its slots; an empty slot there is a real gain;
--   * a two-hand weapon takes off the main hand AND the off hand;
--   * a one-hand weapon goes in the main hand; it is weighed against the off hand too (the weaker of the two) only when
--     CanDualWield() (all five clients have it, warcraft.wiki.gg API_CanDualWield), the main hand holds a one-hand weapon
--     and the off hand holds a weapon; a dual wielder's empty off hand cannot be weighed;
--   * a shield, off-hand weapon or held-in-off-hand item worn with a two-hand weapon takes the two-hand weapon off, so
--     it is weighed against it (an off-hand weapon needs CanDualWield(), else it is no contender);
--   * ranged items (bow, gun, crossbow, wand, thrown, relic): weighed against slot 18 only when something is worn there.
--     Patch 5.0.4 removed that slot (warcraft.wiki.gg Patch_5.0.4: ranged weapons and wands go in the main hand), so on
--     MoP Classic and Retail a ranged reward cannot be weighed.
-- When the gain cannot be told (nothing in the main hand, an empty off hand, a ranged item or a main hand that is not a
-- melee weapon, a worn item whose stats cannot be read) the answer is "unknown", and ClearWinner then picks nothing:
-- guessing low would make this choice win wrongly, guessing high would make another one win wrongly.  Titan's Grip (a
-- two-hander in each hand) is not modelled; it can only make a reward look worse than it is, so nothing is picked then.
-- Returns gain, pct;  or nil, why, unknown (true: a usable item could not be weighed; false: it is no contender).
local HAND = { INVTYPE_WEAPON = true, INVTYPE_2HWEAPON = true, INVTYPE_WEAPONMAINHAND = true, INVTYPE_WEAPONOFFHAND = true,
               INVTYPE_SHIELD = true, INVTYPE_HOLDABLE = true }
local RANGED = { INVTYPE_RANGED = true, INVTYPE_RANGEDRIGHT = true, INVTYPE_THROWN = true, INVTYPE_RELIC = true }
local ONE_HAND = { INVTYPE_WEAPON = true, INVTYPE_WEAPONMAINHAND = true }
local OFF_WEAPON = { INVTYPE_WEAPON = true, INVTYPE_WEAPONOFFHAND = true }
local function itemLoc(link)
    local fn = C_Item and C_Item.GetItemInfo or GetItemInfo
    if not (link and fn) then return nil end
    local ok, loc = pcall(function() return select(9, fn(link)) end)
    return ok and loc or nil
end
local function worn(slot)
    if not GetInventoryItemLink then return nil end
    local ok, l = pcall(GetInventoryItemLink, "player", slot)
    return ok and l or nil
end
-- a worn item's score: 0 for an empty slot or an item with nothing this class weighs; nil when its stats cannot be read
local function wornScore(l)
    if not l then return 0 end
    if not getStats(l) then return nil end
    return IS.Score(l) or 0
end
local function dualWield()
    if type(CanDualWield) ~= "function" then return false end
    local ok, v = pcall(CanDualWield)
    return ok and v and true or false
end
local MISSING = "a worn item's stats cannot be read"
-- the score of what equipping an item of this kind takes off; nil, why, unknown when that cannot be told
local function replaced(loc)
    if RANGED[loc] then
        local r = worn(18)
        if not r then return nil, "no ranged item worn to compare with", true end
        local s = wornScore(r)
        if not s then return nil, MISSING, true end
        return s
    end
    if not HAND[loc] then
        local worst
        for _, slot in ipairs(SLOTS[loc]) do
            local es = wornScore(worn(slot))
            if not es then return nil, MISSING, true end
            if not worst or es < worst then worst = es end
        end
        return worst or 0
    end
    if loc == "INVTYPE_WEAPONOFFHAND" and not dualWield() then return nil, "cannot dual wield", false end
    local mh, oh = worn(16), worn(17)
    if not mh then return nil, "nothing in the main hand", true end
    local mhLoc = itemLoc(mh)
    if not mhLoc then return nil, MISSING, true end
    local twoHand, oneHand = mhLoc == "INVTYPE_2HWEAPON", ONE_HAND[mhLoc]
    if not (twoHand or oneHand) then return nil, "main hand is not a melee weapon", true end
    local mhs, ohs = wornScore(mh), wornScore(oh)
    if not (mhs and ohs) then return nil, MISSING, true end
    if loc == "INVTYPE_2HWEAPON" then return mhs + ohs end
    if loc == "INVTYPE_WEAPONMAINHAND" then return mhs end
    if loc == "INVTYPE_WEAPON" then
        if oneHand and dualWield() then
            if not oh then return nil, "empty off hand", true end
            -- a second weapon may take the weaker hand's place; a shield or held item stays, the main hand goes
            if OFF_WEAPON[itemLoc(oh)] then return math.min(mhs, ohs) end
        end
        return mhs
    end
    -- shield, off-hand weapon, held in off hand
    if twoHand then return mhs + ohs end
    if not oh then return nil, "empty off hand", true end
    return ohs
end
function IS.ChoiceGain(link)
    local score = IS.Score(link)
    if not score then return nil, "no score", false end
    local loc = itemLoc(link)
    if not (loc and SLOTS[loc]) then return nil, "not gear", false end
    local rep, why, unknown = replaced(loc)
    if not rep then return nil, why, unknown end
    return score - rep, rep > 0 and ((score - rep) / rep * 100) or 100
end

-- Quest reward choice (Core/QuestAuto.lua, option autoChooseReward): the index of the ONE choice that is a clear upgrade
-- for this character, or nil and why.  choices[i] = { link = item link, usable = GetQuestItemInfo's isUsable }.
-- Clear means: every choice's item data has arrived; every usable choice can be weighed (IS.ChoiceGain); the best one
-- beats what it would replace by IS.CLEAR_PCT or more; and it gains at least IS.CLEAR_RATIO times as much score as any
-- other choice.  Items the class cannot use (isUsable false) and items with no equip slot never win.  The weights are per
-- class, not per spec (see the file header), which is why anything less than clear is left to the player.
IS.CLEAR_PCT = 10
IS.CLEAR_RATIO = 1.5
function IS.ClearWinner(choices)
    if type(choices) ~= "table" or #choices < 2 then return nil, "fewer than two choices" end
    for _, c in ipairs(choices) do
        if not c.link or c.usable == nil then return nil, "item data not loaded yet" end
    end
    local best, bestGain, bestPct, second = nil, nil, nil, 0
    for i, c in ipairs(choices) do
        local gain, pct
        if c.usable then
            local ok, g, p, unknown = pcall(IS.ChoiceGain, c.link)
            if not ok then return nil, ("choice %d cannot be weighed"):format(i) end
            if g then gain, pct = g, p
            elseif unknown then return nil, ("choice %d cannot be weighed: %s"):format(i, tostring(p)) end
        end
        if gain then
            if not bestGain or gain > bestGain then
                if bestGain and bestGain > second then second = bestGain end
                best, bestGain, bestPct = i, gain, pct
            elseif gain > second then second = gain end
        end
    end
    if not best or bestGain <= 0 or bestPct < IS.CLEAR_PCT then return nil, "no clear upgrade" end
    if second > 0 and bestGain < second * IS.CLEAR_RATIO then return nil, "two upgrades too close to call" end
    return best, bestPct
end

local function annotate(tooltip, link)
    if not link or not NS.db or NS.db.profile.itemScore == false then return end
    local score, eq, pct, ename = IS.Compare(link)
    if not score then return end
    local line = ("|cff3ec6ffCompletionRoute score:|r %.0f"):format(score)
    if pct then
        if pct >= 1 then line = line .. (" |cff00ff00(+%.0f%% upgrade%s)|r"):format(pct, ename and (" over " .. ename) or "")
        elseif pct <= -1 then line = line .. (" |cffff6060(%.0f%% vs equipped)|r"):format(pct)
        else line = line .. " |cffaaaaaa(~equal to equipped)|r" end
    end
    tooltip:AddLine(line)
end

local function hookTip(tip)
    if not tip then return end
    if tip.HookScript then
        tip:HookScript("OnTooltipSetItem", function(self)
            if not self.GetItem then return end
            local _, link = self:GetItem()
            annotate(self, link)
        end)
    end
end
-- Choose by what the tooltip itself supports, not by the global: TBC Anniversary and MoP Classic define
-- TooltipDataProcessor but their tooltips still fire OnTooltipSetItem and never run the processor.
local classicTip = GameTooltip and GameTooltip.HasScript and GameTooltip:HasScript("OnTooltipSetItem")
if not classicTip and TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip)
        if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip and tooltip ~= ShoppingTooltip1 and tooltip ~= ShoppingTooltip2 then return end
        if not tooltip.GetItem then return end
        local _, link = tooltip:GetItem()
        annotate(tooltip, link)
    end)
else
    hookTip(GameTooltip); hookTip(ItemRefTooltip); hookTip(ShoppingTooltip1); hookTip(ShoppingTooltip2)
end
