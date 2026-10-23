-- QuestieGuide: zone-bucketed quest browser sourced from Questie. This file holds the shared constants, saved-variable defaults and the Questie compatibility check.
local _, ns = ...

-- The shared native design system: tokens on the 4px grid, Blizzard font and colour roles, and the window, launcher and chat builders.
local UI = LibStub("LibNativeUI-1.0")

-- The spaced name every player-facing surface shows: window title, launcher, addon menu and chat prefix.
local ADDON_TITLE = "Questie Guide"

local DEFAULTS = {
    sortMode = "xp",
    sortDir = "desc",
    filters = {
        inLog = true,
        available = true,
        pickedUpElsewhere = true,
        missingPre = true,
        dungeons = true,
        elite = true,
        repeatable = true,
    },
    zoneCollapsed = {},
    groupCollapsed = {},
    minimap = { hide = false, minimapPos = 215 },

    -- The window reads and writes its position in this table in place, so it always exists.
    position = {},
    useQuestieLevelRange = false,
    levelBelow = 5,
    levelAbove = 5,
    showCompleted = true,
}

-- Bounds of the levels below / above band.
local RANGE_LIMIT = { MIN = 0, MAX = 10 }

-- Colour roles: the shared UI.Color roles where one fits, other Blizzard colour objects for the quest states it has no role for.
local COLOR = {
    MUTED = UI.Color.muted,
    ACCENT = UI.Color.heading,
    IN_LOG = LIGHTBLUE_FONT_COLOR,
    READY = UI.Color.good,
    BLOCKED = ORANGE_FONT_COLOR,

    -- Grey like the "!" Questie pins a quest with before its required level is reached.
    LOCKED = UI.Color.muted,
    REPEATABLE = LIGHTBLUE_FONT_COLOR,
    LINK = LINK_FONT_COLOR,
}

local SORT_BY_OPTIONS = {
    { value = "xp",       label = "Total XP" },
    { value = "count",    label = "Total Quest Count" },
    { value = "avgLevel", label = "Average Quest Level" },
    { value = "name",     label = "Alphabetical by Zone" },
}
local SORT_DIR_OPTIONS = {
    { value = "asc",  label = WHO_SORT_ASCENDING_LABEL },
    { value = "desc", label = WHO_SORT_DESCENDING_LABEL },
}

-- Two sections per zone, split by where the quest is picked up. Rows carry a status label only for the exceptions (in log, level-locked, missing pre-quest): in-log and blocked rows live inside these buckets, toggled by the inLog and missingPre filters.
local SUBCAT_ORDER = { "available", "pickedUpElsewhere" }
local SUBCAT_LABEL = {
    available = "Starts Here",
    pickedUpElsewhere = "Starts Elsewhere",
}

-- Window metrics on the 4px grid beyond Blizzard's PANEL_INSET_* offsets: the quest list fills the template's own inset.
local LAYOUT = {
    -- Fixed size (owner decision).
    FRAME_W = 680,
    FRAME_H = 624,

    -- Wide enough for the "Quest, zone or NPC name" placeholder.
    SEARCH_W = 200,

    -- Native geometry: AddonList.xml anchors its attic search box 10px in from the frame's right edge.
    SEARCH_RIGHT = 10,

    -- Native geometry: WowStyle1FilterDropdownTemplate draws its background 4px past each side of its frame (Blizzard_Menu/Mainline/MenuTemplates.xml).
    FILTER_ART = 4,
}

-- The toc's IconTexture, shared by the portrait and the minimap button.
local ADDON_ICON = "Interface\\Icons\\INV_Misc_Map02"

local MAX_CHAIN_DEPTH = 12

-- Every Questie internal the guide reads, checked once when Questie.API reports ready. The check is per field because QuestieLoader:ImportModule hands back an empty table for an unknown module; one gap keeps the window closed and names the field instead of erroring mid-scan.
local QUESTIE_FIELDS = {
    { module = "QuestieDB", fields = { "QuestPointers", "QueryQuestSingle", "QueryQuest", "QueryNPCSingle", "QueryObjectSingle", "QueryItemSingle", "GetNPC", "GetQuest", "IsDoable", "IsPreQuestSingleFulfilled", "IsPreQuestGroupFulfilled", "IsRepeatable", "IsComplete", "IsTrivial", "GetQuestTagInfo", "autoBlacklist", "RefreshAfterCorrectionApply" } },
    { module = "QuestieLib", fields = { "GetEffectiveQuestLevel", "GetColoredQuestName", "GetDifficultyColorPercent" } },
    { module = "QuestiePlayer", fields = { "currentQuestlog", "HasRequiredRace", "HasRequiredClass", "GetCurrentZoneId" } },
    { module = "ZoneDB", fields = { "GetUiMapIdByAreaId", "GetLocalizedDungeonName" } },
    { module = "QuestXP", fields = { "GetQuestLogRewardXP" } },
    { module = "QuestieMap", fields = { "GetFramesForQuest" } },
    { module = "QuestieCorrections", fields = { "hiddenQuests" } },
    { module = "QuestieTooltips", fields = { "lookupByKey" } },
    { module = "QuestieFrame", fields = { "CreateIconFrame" } },
    { module = "QuestieCompat", fields = { "GetQuestGreenRange" } },
    { module = "AvailableQuests", fields = { "ResetLevelRequirementCache" } },
    { module = "QuestieEvent", fields = { "activeQuests" } },
    { module = "QuestieDB.questKeys", fields = { "parentQuest", "availableUntilCompleted" } },
    { module = "Questie", fields = { "Colorize", "db", "LOWLEVEL_ALL", "LOWLEVEL_OFFSET", "LOWLEVEL_RANGE" } },
    { module = "Questie.db.char", fields = { "complete", "hidden" } },
    { module = "Questie.db.profile", fields = { "lowLevelStyle", "manualLevelOffset", "minLevelFilter", "maxLevelFilter", "enableTooltips", "enableTooltipsQuestLevel", "showQuestsInNpcTooltip" } },
}

-- True once Questie.API reported ready and every field checked out; every launcher waits for it. Events.lua sets it, and ns.missingQuestieField to the first Questie field or API the running Questie lacks, which keeps the window closed for the session.
ns.questieReady = false

-- Walks a dotted owner such as "Questie.db.profile" or "QuestieDB.questKeys" from the Questie global or a QuestieLoader module. It resolves at check time because Questie.db is a placeholder until Questie's init.
local function getFieldOwner(path)
    local root, rest = path:match("^([^.]+)%.?(.*)$")
    local owner = root == "Questie" and Questie or QuestieLoader:ImportModule(root)
    for key in rest:gmatch("[^.]+") do
        if type(owner) ~= "table" then
            return nil
        end
        owner = owner[key]
    end
    return owner
end

local function findMissingField()
    for _, entry in ipairs(QUESTIE_FIELDS) do
        local owner = getFieldOwner(entry.module)
        for _, field in ipairs(entry.fields) do
            if type(owner) ~= "table" or owner[field] == nil then
                return entry.module .. "." .. field
            end
        end
    end
    return nil
end

-- Why the window can't open yet, printed by every launcher.
local function describeQuestieState()
    if ns.missingQuestieField then
        return "This Questie version has no " .. ns.missingQuestieField .. ", which the quest list needs. Update Questie and QuestieDB."
    end
    return "Questie has not finished loading yet. Try again in a moment; if this stays, check Questie for errors."
end

local function clampRange(value)
    if type(value) ~= "number" then
        return nil
    end
    value = math.floor(value + 0.5)
    if value < RANGE_LIMIT.MIN then return RANGE_LIMIT.MIN end
    if value > RANGE_LIMIT.MAX then return RANGE_LIMIT.MAX end
    return value
end

-- Shared with the other files through the addon namespace.
ns.ADDON_TITLE = ADDON_TITLE
ns.ADDON_ICON = ADDON_ICON
ns.DEFAULTS = DEFAULTS
ns.RANGE_LIMIT = RANGE_LIMIT
ns.COLOR = COLOR
ns.SORT_BY_OPTIONS = SORT_BY_OPTIONS
ns.SORT_DIR_OPTIONS = SORT_DIR_OPTIONS
ns.SUBCAT_ORDER = SUBCAT_ORDER
ns.SUBCAT_LABEL = SUBCAT_LABEL
ns.LAYOUT = LAYOUT
ns.MAX_CHAIN_DEPTH = MAX_CHAIN_DEPTH
ns.findMissingField = findMissingField
ns.describeQuestieState = describeQuestieState
ns.clampRange = clampRange
