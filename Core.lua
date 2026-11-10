-- QuestieGuide: zone-bucketed quest browser sourced from QuestieDB. This file holds the shared constants, saved-variable defaults and the QuestieDB check.
local addonName, ns = ...

-- The toc Title, the spaced name every player-facing surface shows: window title, launcher, addon menu and chat prefix.
ns.title = C_AddOns.GetAddOnMetadata(addonName, "Title")

-- Every chat line: the bracketed title in the gold of Blizzard's own chat links, the message in the chat frame's colour.
function ns.Print(message)
    print(NORMAL_FONT_COLOR:WrapTextInColorCode("[" .. ns.title .. "]") .. ": " .. message)
end

-- A value another addon or restricted content hands over may be secret. canaccessvalue is SecretArguments = "AllowedWhenUntainted" (FrameScriptDocumentation.lua:68), so addon code handing it a secret may raise instead of answering; the pcall counts a raise as secret. nil is never secret and the argument is not nilable, so nil is answered without the call, tested through type() because == on a secret raises.
function ns.CanAccess(value)
    if type(value) == "nil" then return true end
    local ok, accessible = pcall(canaccessvalue, value)
    return ok and accessible == true
end

-- Rounds a length derived from text up to the 4 px grid.
function ns.Snap(length)
    return math.ceil(length / 4) * 4
end

-- A GameTooltip owned by the hovered frame, filled with Blizzard's GameTooltip_* line helpers, for a frame whose
-- template already sets OnEnter and OnLeave, such as UIPanelButtonTemplate
-- (Mainline/SharedUIPanelTemplates.xml:316-318), InputBoxInstructionsTemplate or a filter dropdown: hooked, so the
-- template keeps its own handlers.
function ns.HookTooltip(frame, fill, anchor)
    frame:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, anchor or "ANCHOR_RIGHT")
        fill(GameTooltip, self)
        GameTooltip:Show()
    end)
    frame:HookScript("OnLeave", GameTooltip_Hide)
end

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
    levelBelow = 5,
    levelAbove = 5,
    showCompleted = true,
}

-- Bounds of the levels below / above band.
local RANGE_LIMIT = { MIN = 0, MAX = 10 }

-- Colour roles on Blizzard's colour objects: muted, heading, good and links from the shared roles, other colour objects for the quest states they have no role for.
local COLOR = {
    MUTED = GRAY_FONT_COLOR,
    ACCENT = NORMAL_FONT_COLOR,
    IN_LOG = LIGHTBLUE_FONT_COLOR,
    READY = GREEN_FONT_COLOR,
    BLOCKED = ORANGE_FONT_COLOR,

    -- Grey for a quest the player is too low to accept.
    LOCKED = GRAY_FONT_COLOR,
    REPEATABLE = LIGHTBLUE_FONT_COLOR,

    -- The gold of Blizzard's own chat links, for the addon's links in chat.
    LINK = NORMAL_FONT_COLOR,
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
    -- Fixed size, the window does not resize.
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

-- The QuestieDB contract this guide is written against; RequireContract accepts a range, so additive QuestieDB releases keep working.
local QUESTIE_DB_CONTRACT = 4

local QUESTIE_DB_MISSING = "QuestieDB is not loaded, so the quest list can't open. Enable QuestieDB in the AddOns list and reload."
local QUESTIE_DB_UNSUPPORTED = "This QuestieDB version is not supported, so the quest list can't open. Update QuestieDB and Questie Guide."

-- QuestieDB is a toc dependency, so it has loaded and applied its own corrections before this file runs. Returns the library, or nil and why the window stays closed.
local function loadQuestDB()
    local lib = _G.LibQuestieDB
    if type(lib) ~= "table" then
        return nil, QUESTIE_DB_MISSING
    end
    if type(lib.RequireContract) ~= "function" or not lib.RequireContract(QUESTIE_DB_CONTRACT) or type(lib.Support) ~= "table" then
        return nil, QUESTIE_DB_UNSUPPORTED
    end
    for _, name in ipairs({ "Quest", "Npc", "Object", "Item" }) do
        local entity = lib[name]
        if type(entity) ~= "table" or type(entity.Get) ~= "function" or type(entity.GetAllIds) ~= "function" then
            return nil, QUESTIE_DB_UNSUPPORTED
        end
    end
    return lib
end

-- The library every data file reads, or nil with ns.questDBProblem as the line every launcher prints.
ns.questDB, ns.questDBProblem = loadQuestDB()

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
ns.clampRange = clampRange
