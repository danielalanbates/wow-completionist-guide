-- Luacheck config for CompletionRoute (WoW addon, all flavors).
std = "lua51"
max_line_length = false
self = false
exclude_files = {
    "CompletionRoute/Libs/**",
    "CompletionRoute/Guides/**",      -- generated/baked guide data (huge)
    "CompletionRoute/Data/Taxi_*.lua", -- generated taxi data
    "archive/**",
    "tools/db2/**",
}
ignore = {
    "211/_.*",   -- unused variable starting with _
    "211/ADDON", -- module header pattern: local ADDON, NS = ...
    "211/U",     -- module header alias for NS.Util
    "212",       -- unused argument
    "213",       -- unused loop variable
    "542",       -- empty if branch
}
-- Addon's own globals (SavedVariables + slash handlers)
globals = {
    "CompletionRouteDB", "CompletionRouteCharDB",
    "SLASH_OPENROUTE1", "SLASH_OPENROUTE2",
    "SlashCmdList", "StaticPopupDialogs", "UISpecialFrames",
    "CompletionRoute_ItemButton",
}
-- WoW API surface (read-only)
read_globals = {
    -- Lua/WoW string & table extensions
    "strsplit", "strjoin", "strtrim", "strlower", "strupper", "strmatch", "strfind", "strsub", "strrep", "strbyte", "strlen", "format", "gsub",
    "tinsert", "tremove", "wipe", "tContains", "tostringall", "unpack",
    "floor", "ceil", "abs", "min", "max", "sqrt", "mod", "random",
    "date", "time", "debugprofilestop",
    -- Frames & UI
    "CreateFrame", "UIParent", "GameTooltip", "GameFontNormal", "GameFontNormalSmall", "GameFontHighlight", "GameFontHighlightSmall", "GameFontNormalLarge",
    "BackdropTemplateMixin", "Settings", "InterfaceOptionsFrame_OpenToCategory", "InterfaceOptions_AddCategory",
    "PlaySound", "SOUNDKIT", "GameTime_GetTime", "ChatFontNormal",
    "CloseDropDownMenus", "ToggleDropDownMenu", "UIDropDownMenu_Initialize", "UIDropDownMenu_AddButton", "UIDropDownMenu_CreateInfo", "EasyMenu",
    "StaticPopup_Show", "GetMouseFocus", "GetMouseFoci", "IsShiftKeyDown", "IsControlKeyDown", "IsAltKeyDown", "IsModifierKeyDown",
    -- Client info & state
    "GetBuildInfo", "GetTime", "GetLocale", "GetRealmName",
    "UnitName", "UnitLevel", "UnitClass", "UnitRace", "UnitFactionGroup", "UnitXP", "UnitXPMax", "UnitPosition", "UnitAffectingCombat", "UnitIsGhost", "UnitIsDeadOrGhost", "UnitOnTaxi", "UnitInParty", "UnitInRaid",
    "GetUnitSpeed", "IsMounted", "IsFlying", "IsSwimming", "IsIndoors", "InCombatLockdown", "GetPlayerFacing", "GetBindLocation", "GetZoneText", "GetSubZoneText", "GetMinimapZoneText",
    "IsSpellKnown", "IsPlayerSpell", "GetSpellInfo", "GetSpellCooldown", "CastSpellByID", "GetShapeshiftForm",
    "GetItemCount", "GetItemInfo", "GetItemInfoInstant", "GetItemIcon", "GetContainerNumSlots", "GetContainerItemLink", "GetInventoryItemLink", "GetInventoryItemTexture", "GetItemStats", "GetAverageItemLevel", "GetDetailedItemLevelInfo", "EquipItemByName", "UseContainerItem", "UseInventoryItem",
    -- Quests
    "GetNumQuestLogEntries", "GetQuestLogTitle", "SelectQuestLogEntry", "GetQuestLogQuestText", "GetQuestObjectiveInfo", "IsQuestFlaggedCompleted", "GetQuestID", "AcceptQuest", "CompleteQuest", "GetQuestReward", "GetNumQuestChoices", "QuestFrame", "QuestGetAutoAccept", "AcknowledgeAutoAcceptQuest", "GetNumAutoQuestPopUps", "GetAutoQuestPopUp", "ShowQuestOffer", "ShowQuestComplete", "GetQuestLogIndexByID",
    "GossipFrame", "QuestFrameDetailPanel", "QuestFrameProgressPanel", "QuestFrameRewardPanel", "QuestFrameGreetingPanel",
    -- Namespaced C_ APIs
    "C_NamePlate", "UnitExists", "ShowUIPanel", "QuestUtils_GetQuestName", "OpenWorldMap", "WorldMapFrame", "NumTaxiNodes", "TaxiNodeGetType", "TaxiNodeName", "HBD_PINS_WORLDMAP_SHOW_PARENT",
    "C_AddOns", "C_Timer", "C_Map", "C_QuestLog", "C_QuestLine", "C_TaskQuest", "C_Item", "C_Container", "C_GossipInfo", "C_SuperTrack", "C_Spell", "C_UnitAuras", "C_PlayerInfo", "C_Minimap", "C_TaxiMap", "C_EventUtils", "C_SpecializationInfo",
    -- Misc
    "LibStub", "hooksecurefunc", "SetOverrideBindingClick", "ClearOverrideBindings", "GetBindingKey", "SetBinding",
    "TaxiFrame", "TaxiNodeName", "NumTaxiNodes", "TakeTaxiNode", "TaxiNodeGetType",
    "WorldMapFrame", "TomTom", "WoWPro", "SexyMap", "Minimap",
    "SendChatMessage", "DoEmote", "RunMacroText",
    "DEFAULT_CHAT_FRAME", "SELECTED_CHAT_FRAME", "ChatFrame1", "ERR_LEARN_RECIPE_S",
    "GetAddOnMetadata", "IsAddOnLoaded", "LoadAddOn", "EnableAddOn", "DisableAddOn",
    "geterrorhandler", "seterrorhandler", "securecall", "issecure", "debugstack",
    "bit",
    "Enum", "TooltipDataProcessor", "QuestUtils_GetQuestName", "GetItemCooldown", "C_XMLUtil",
    "ItemRefTooltip", "ShoppingTooltip1", "ShoppingTooltip2", "IsResting", "GetSpellTexture",
    "GetSkillLineInfo", "GetProfessions", "GetProfessionInfo", "GetNumSkillLines", "GetCursorPosition",
}
files["tools/**"] = {
    std = "+lua51",
    globals = { "*" },  -- test harnesses define the mock world
    ignore = { ".*" },  -- don't lint stub scaffolding hard
}
