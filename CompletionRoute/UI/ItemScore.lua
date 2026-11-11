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

-- Quest reward choice (Core/QuestAuto.lua, option autoChooseReward): the index of the ONE choice that is a clear upgrade
-- for this character, or nil and why.  choices[i] = { link = item link, usable = GetQuestItemInfo's isUsable }.
-- Clear means: every choice's item data has arrived; the best choice the character can use beats what is equipped in
-- its slot by IS.CLEAR_PCT or more; and it gains at least IS.CLEAR_RATIO times as much score as any other choice.
-- Items the class cannot use (isUsable false) and items with no equip slot never win.  The weights are per class, not
-- per spec (see the file header), which is why anything less than clear is left to the player.
IS.CLEAR_PCT = 10
IS.CLEAR_RATIO = 1.5
function IS.ClearWinner(choices)
    if type(choices) ~= "table" or #choices < 2 then return nil, "fewer than two choices" end
    local best, bestGain, bestPct, second = nil, nil, nil, 0
    for i, c in ipairs(choices) do
        if not c.link or c.usable == nil then return nil, "item data not loaded yet" end
        local gain, pct
        if c.usable then
            local ok, score, eq, p = pcall(IS.Compare, c.link)
            if ok and score and eq and p then gain, pct = score - eq, p end
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
    if tip.HookScript and TooltipDataProcessor == nil then
        tip:HookScript("OnTooltipSetItem", function(self)
            if not self.GetItem then return end
            local _, link = self:GetItem()
            annotate(self, link)
        end)
    end
end
if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip)
        if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip and tooltip ~= ShoppingTooltip1 and tooltip ~= ShoppingTooltip2 then return end
        if not tooltip.GetItem then return end
        local _, link = tooltip:GetItem()
        annotate(tooltip, link)
    end)
else
    hookTip(GameTooltip); hookTip(ItemRefTooltip); hookTip(ShoppingTooltip1); hookTip(ShoppingTooltip2)
end
