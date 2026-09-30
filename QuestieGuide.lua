-- QuestieGuide: zone-bucketed quest browser sourced from Questie.
local ADDON_NAME = ...

local DEFAULTS = {
    sortMode = "xp",
    sortDir = "desc",
    filters = {
        inLog = true,
        available = true,
        pickedUpElsewhere = true,
        missingPre = true,
        dungeons = true,
        eliteGroup = true,
        repeatable = true,
    },
    frameSize = { w = 680, h = 620 },
    zoneCollapsed = {},
    groupCollapsed = {},
    minimap = { hide = false, minimapPos = 215 },
    useQuestieLevelRange = false,
    levelBelow = 5,
    levelAbove = 5,
    showCompleted = true,
}

-- Bounds of the below / above level sliders.
local LEVEL_RANGE = { MIN = 0, MAX = 10 }

-- Colour roles, each a Blizzard colour object so rows, badges and tooltips use the native palette.
local COLOR = {
    MUTED = GRAY_FONT_COLOR,
    ACCENT = NORMAL_FONT_COLOR,
    PREFIX = YELLOW_FONT_COLOR,
    IN_LOG = LIGHTBLUE_FONT_COLOR,
    READY = GREEN_FONT_COLOR,
    BLOCKED = ORANGE_FONT_COLOR,
    REPEATABLE = LIGHTBLUE_FONT_COLOR,
    LINK = LINK_FONT_COLOR,
}

-- Blizzard's quest log header grey; headers whiten to HIGHLIGHT_FONT_COLOR while hovered.
local HEADER_COLOR = QuestDifficultyColors.header

local INTRO_PREFIX = COLOR.PREFIX:WrapTextInColorCode("[Questie Guide]:") .. " "

local SORT_BY_OPTIONS = {
    { value = "xp",       label = "Total XP" },
    { value = "count",    label = "Total Quest Count" },
    { value = "avgLevel", label = "Average Quest Level" },
    { value = "name",     label = "Alphabetical by Zone" },
}
local SORT_DIR_OPTIONS = {
    { value = "asc",  label = "Ascending" },
    { value = "desc", label = "Descending" },
}

-- Two sections per zone, split by where the quest is picked up. Every row carries a bracket status label instead of sections per status: in-log and blocked rows live inside these buckets, toggled by the inLog and missingPre filters.
local SUBCAT_ORDER = { "available", "pickedUpElsewhere" }
local SUBCAT_LABEL = {
    available = "Picked Up in Zone",
    pickedUpElsewhere = "Picked Up Outside of Zone",
}

-- Completed-quests section: sentinel collapse key that can't collide with a real zone name ("||" never appears in area names).
local COMPLETED_KEY = "||completed"
local COMPLETED_LABEL = "Completed Quests"

-- Window metrics beyond Blizzard's PANEL_INSET_* offsets: the search box sits where AddonList's does, the settings column has a fixed width and the quest list takes the rest.
local LAYOUT = {
    MIN_W = 640,

    -- Tall enough for the settings column with its sliders shown.
    MIN_H = 480,
    MAX_W = 1200,
    MAX_H = 960,
    COLUMN_GAP = 2,

    -- PanelResizeButtonTemplate's corner offset in Blizzard's EventTrace.
    GRIP_PAD = 4,
    BUTTON_W = 120,
    BUTTON_H = 22,
    SEARCH_W = 200,
    SEARCH_H = 22,
    SEARCH_TOP = 31,
    SEARCH_RIGHT = 10,
    PANE_W = 260,
    PANE_PAD = 12,
    HEADING_H = 18,
    GROUP_GAP = 12,
    CONTROL_GAP = 6,
    CHECK_SIZE = 26,
    DROPDOWN_H = 25,

    -- WowStyle1DropdownTemplate's art bleeds past its frame, so dropdowns sit this far in from the column edges.
    DROPDOWN_INDENT = 6,
    SLIDER_H = 40,
    LIST_PAD = 4,
}

-- Quest list metrics: 16px title rows, the +/- toggle 3px in and header text 20px in, header grey that whitens on hover. Rows grow to fit their wrapped two-line text, and gaps loosen per nesting level so zones, buckets and quests read as separate tiers.
local LIST = {
    ROW_HEIGHT = 16,
    SUBHEADER_HEIGHT = 16,
    HEADER_HEIGHT = 20,
    ROW_GAP = 2,
    GROUP_GAP = 6,
    ZONE_GAP = 12,
    INDENT_STEP = 16,
    TEXT_PAD = 4,
    TEXT_INSET = 20,
    TOGGLE_INSET = 3,
    TOGGLE_SIZE = 16,

    -- Centers one 12px GameFontHighlight line in a 16px row.
    ROW_PAD = 2,
    LINE_GAP = 2,
}

-- The toc's IconTexture, shared by the portrait and the minimap button.
local ADDON_ICON = "Interface\\Icons\\INV_Misc_Map02"

-- Header expand/collapse art, the same textures Forever's Group Finder listing headers use.
local TOGGLE_ART = {
    PLUS = "Interface\\Buttons\\UI-PlusButton-Up",
    MINUS = "Interface\\Buttons\\UI-MinusButton-Up",
    HILIGHT = "Interface\\Buttons\\UI-PlusButton-Hilight",
}

local MAX_CHAIN_DEPTH = 12

-- Questie modules. `## RequiredDeps: Questie` loads Questie's files first, so the module tables exist now; their data is only complete once Questie.API reports ready.
local QuestieDB = QuestieLoader:ImportModule("QuestieDB")
local QuestieLib = QuestieLoader:ImportModule("QuestieLib")
local ZoneDB = QuestieLoader:ImportModule("ZoneDB")
local QuestiePlayer = QuestieLoader:ImportModule("QuestiePlayer")
local QuestXP = QuestieLoader:ImportModule("QuestXP")
local QuestieMap = QuestieLoader:ImportModule("QuestieMap")
local QuestieCorrections = QuestieLoader:ImportModule("QuestieCorrections")
local QuestieTooltips = QuestieLoader:ImportModule("QuestieTooltips")
local QuestieFrame = QuestieLoader:ImportModule("QuestieFrame")

local mainFrame
local scrollChild
local rowPool = {}
local lastZoneOrder = {}

-- Turn-in zones rendered by the completed section on the last pass; drives Collapse All parity.
local lastCompletedZones = {}

-- questId -> { row, top } for pickable and in-log rows, rebuilt every render; powers the jump-to-prerequisite scroll.
local rowTargets = {}

-- zoneName -> header top offset, rebuilt every render; powers the banner's jump-to-zone scroll.
local zoneHeaderTops = {}
local renderList
local expandAndScrollToZone
local searchText = ""

-- Quest carrying the selection glow; moved by row left-clicks, list jumps, and Questie map icon clicks.
local selectedQuestId

-- Enum.QuestTag ids as Forever names them: 1 is Group (Blizzard_FrameXMLBase/Constants.lua gives it the group icon), elites are a separate flag.
local QUEST_TAG_LABELS = {
    [1] = "Group",
    [41] = "PvP",
    [62] = "Raid",
    [81] = "Dungeon",
}

local QUEST_TAG_COLORS = {
    Group = ORANGE_FONT_COLOR,
    Dungeon = EPIC_PURPLE_COLOR,
    Raid = RED_FONT_COLOR,
    PvP = NORMAL_FONT_COLOR,
}

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
    { module = "Questie", fields = { "Colorize", "db" } },
    { module = "Questie.db.char", fields = { "complete", "hidden" } },
}

-- True once Questie.API reported ready and every field checked out; every launcher waits for it.
local questieReady = false

-- First Questie field or API the running Questie lacks; once set, the window stays closed for the session.
local missingQuestieField

-- Questie.db is a placeholder until Questie's init, so the character namespace resolves at check time.
local function getFieldOwner(moduleName)
    if moduleName == "Questie" then
        return Questie
    end
    if moduleName == "Questie.db.char" then
        return Questie.db and Questie.db.char
    end
    return QuestieLoader:ImportModule(moduleName)
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
    if missingQuestieField then
        return "This Questie version has no " .. missingQuestieField .. ", which the quest list needs. Update Questie and QuestieDB."
    end
    return "Questie has not finished loading yet. Try again in a moment; if this stays, check Questie for errors."
end

-- Questie's own completed-quest set, the one its IsDoable and prerequisite checks read. Questie replaces the table on a quest log reset, so it's read fresh every call.
local function isQuestCompleted(questId)
    return Questie.db.char.complete[questId] and true or false
end

-- Repeatable lives in the specialFlags bit rather than the quest tag, so it needs its own lookup next to getQuestTagLabel.
local function isQuestRepeatable(questId)
    return QuestieDB.IsRepeatable(questId) and true or false
end

local function getQuestTagLabel(questId)
    local tagId = QuestieDB.GetQuestTagInfo(questId)
    return tagId and QUEST_TAG_LABELS[tagId]
end

local function formatTag(label)
    return QUEST_TAG_COLORS[label]:WrapTextInColorCode("[" .. label .. "]")
end

-- Questie's XP estimate after its level and buff adjustments; pcall keeps one failing estimate from breaking the whole scan.
local function getQuestXp(questId)
    local ok, xp = pcall(QuestXP.GetQuestLogRewardXP, QuestXP, questId, true)
    return (ok and type(xp) == "number") and xp or 0
end

-- The catch-all bucket for quests whose zoneOrSort is a sort category rather than a real area id. Pinned to the bottom of the list by sortZones because it's mostly noise (class quests, faction quests, profession quests, ...).
local OTHER_ZONE_NAME = "Other"

-- zoneOrSort > 0 is a Blizzard area ID; <= 0 is a sort category we collapse into "Other". Names are static client data, and the scan plus the chain projection resolve them for thousands of quests per rescan, so results cache for the session.
local zoneNameCache = {}

-- Resolves names the way Questie's tracker does: the client area table first, then Questie's dungeon list.
local function getZoneName(zoneOrSort)
    if not zoneOrSort or zoneOrSort <= 0 then
        return OTHER_ZONE_NAME
    end
    local cached = zoneNameCache[zoneOrSort]
    if cached then
        return cached
    end
    local name = C_Map.GetAreaInfo(zoneOrSort) or ZoneDB:GetLocalizedDungeonName(zoneOrSort) or ("Zone " .. zoneOrSort)
    zoneNameCache[zoneOrSort] = name
    return name
end

-- Mirrors the hidden-quest exclusions IsDoable applies before its prereq logic: Questie's curated blacklist, quests the player hid manually, and IsDoable's own autoBlacklist verdicts. Needed wherever quests are classified after IsDoable already said no (missing-prereq rows, chain projection), because those paths never receive IsDoable's verdict on hidden state and would otherwise resurrect blacklisted or inactive-event quests.
local function isQuestHidden(questId)
    if QuestieCorrections.hiddenQuests[questId] or QuestieDB.autoBlacklist[questId] then
        return true
    end
    return Questie.db.char.hidden[questId] and true or false
end

-- Questie's effective levels, which resolve scaling quests (questLevel -1) to the player's level; a quest without its own level falls back to its required level.
local function getEffectiveLevel(questId, playerLevel)
    local level, requiredLevel, requiredMaxLevel = QuestieLib.GetEffectiveQuestLevel(questId, playerLevel)
    requiredLevel = requiredLevel or 0
    if level and level > 0 then
        return level, requiredLevel, requiredMaxLevel or 0
    end
    return requiredLevel, requiredLevel, requiredMaxLevel or 0
end

-- Questie's database can carry quests above the level cap; they can never be picked up.
local function passesLevelCap(level, requiredLevel)
    local maxLevel = GetMaxPlayerLevel()
    return level <= maxLevel and requiredLevel <= maxLevel
end

local function getQuestName(questId)
    return QuestieDB.QueryQuestSingle(questId, "name") or ("Quest " .. questId)
end

-- Session caches over static Questie data, keyed by quest id; onCorrectionApplied drops them when Questie rewrites its rows.
local sessionCache = { startInfo = {}, finishInfo = {}, reachable = {}, followers = nil, itemQuests = nil }

-- Giver and turn-in lookups. Lua 5.1 allows 200 locals per chunk, so single-use helpers live in do blocks and only the names declared above each block leave it.
local getQuestStartInfo, resolveStartInfo, getQuestFinishInfo
do
    -- Questie stores a spawn without a map position (dungeon interiors) as {-1, -1}; such a spawn still names its zone but must not show coordinates or set a waypoint.
    local function getSpawnCoords(spawn)
        local x, y = type(spawn) == "table" and spawn[1], type(spawn) == "table" and spawn[2]
        if type(x) == "number" and type(y) == "number" and x >= 0 and y >= 0 and (x > 0 or y > 0) then
            return spawn
        end
        return nil
    end

    -- Picks a spawn from Questie's per-zone spawn table: prefer the quest's own zone (zoneOrSort) so the labeled location matches the bucket; fall back to the smallest area id when no spawn lives there (deterministic, but arbitrary). Zone and spawn always come from the same entry.
    local function pickPreferredSpawn(spawns, preferZoneId)
        local preferredZoneId, preferredSpawn
        local fallbackZoneId, fallbackSpawn
        for zoneId, list in pairs(spawns) do
            if type(list) == "table" and list[1] then
                if preferZoneId and zoneId == preferZoneId then
                    preferredZoneId = zoneId
                    preferredSpawn = list[1]
                elseif not fallbackZoneId or zoneId < fallbackZoneId then
                    fallbackZoneId = zoneId
                    fallbackSpawn = list[1]
                end
            end
        end
        if preferredZoneId then
            return preferredZoneId, getSpawnCoords(preferredSpawn)
        end
        return fallbackZoneId, getSpawnCoords(fallbackSpawn)
    end

    local function getPreferredZoneId(questId)
        local questZone = QuestieDB.QueryQuestSingle(questId, "zoneOrSort")
        return (questZone and questZone > 0) and questZone or nil
    end

    -- Name, zone name, spawn and area id of an NPC, located in the quest's own zone when it spawns there.
    local function describeNpcForQuest(npcId, questId)
        local npc = QuestieDB:GetNPC(npcId)
        if not npc then
            return nil
        end
        if type(npc.spawns) ~= "table" then
            return npc.name, nil, nil, nil
        end
        local bestZoneId, bestSpawn = pickPreferredSpawn(npc.spawns, getPreferredZoneId(questId))
        if not bestZoneId then
            return npc.name, nil, nil, nil
        end
        return npc.name, getZoneName(bestZoneId), bestSpawn, bestZoneId
    end

    -- Returns name, zoneName, {x, y}, areaId for the quest's start source. Questie's `startedBy` is a 3-tuple: [1] NPC ids, [2] object ids, [3] item ids. Object/item start (no NPC giver): use the quest's own zone as a best-effort location and "Quest Item" as the generic giver name.
    local function computeQuestStartInfo(questId)
        local startedBy = QuestieDB.QueryQuestSingle(questId, "startedBy")
        if type(startedBy) ~= "table" then
            return nil, nil, nil, nil
        end

        local npcIds = startedBy[1]
        if type(npcIds) == "table" and npcIds[1] then
            local npcName, zoneName, spawn, areaId = describeNpcForQuest(npcIds[1], questId)
            if npcName then
                return npcName, zoneName, spawn, areaId
            end
        end

        local hasObjectStart = type(startedBy[2]) == "table" and startedBy[2][1] ~= nil
        local hasItemStart = type(startedBy[3]) == "table" and startedBy[3][1] ~= nil
        if hasObjectStart or hasItemStart then
            local questZone = getPreferredZoneId(questId)
            if questZone then
                return "Quest Item", getZoneName(questZone), nil, questZone
            end
            return "Quest Item", nil, nil, nil
        end

        return nil, nil, nil, nil
    end

    -- Start info is static DB data, but the scan resolves it for every doable quest on every rescan (accept, turn-in, level-up) and quest row tables are rebuilt each scan, so a per-row cache would not survive. Cache per questId for the session instead.
    function getQuestStartInfo(questId)
        local cached = sessionCache.startInfo[questId]
        if cached then
            return cached.npcName, cached.zoneName, cached.spawn, cached.areaId
        end
        local npcName, zoneName, spawn, areaId = computeQuestStartInfo(questId)
        sessionCache.startInfo[questId] = { npcName = npcName, zoneName = zoneName, spawn = spawn, areaId = areaId }
        return npcName, zoneName, spawn, areaId
    end

    -- Row and tooltip callers keep the table shape they already use; it fronts the session cache.
    function resolveStartInfo(quest)
        if quest.startInfo then
            return quest.startInfo
        end
        local npcName, zoneName, spawn, areaId = getQuestStartInfo(quest.id)
        quest.startInfo = {
            npcName = npcName,
            zoneName = zoneName,
            spawn = spawn,
            areaId = areaId,
        }
        return quest.startInfo
    end

    -- Returns name, zoneName, {x, y}, areaId for the quest's turn-in target. Questie's `finishedBy` is a 2-tuple: [1] NPC ids, [2] object ids. The turn-in location only exists in Questie's data.
    local function computeQuestFinishInfo(questId)
        local finishedBy = QuestieDB.QueryQuestSingle(questId, "finishedBy")
        if type(finishedBy) ~= "table" then
            return nil, nil, nil, nil
        end

        local npcIds = finishedBy[1]
        if type(npcIds) == "table" and npcIds[1] then
            local npcName, zoneName, spawn, areaId = describeNpcForQuest(npcIds[1], questId)
            if npcName then
                return npcName, zoneName, spawn, areaId
            end
        end

        local objectIds = finishedBy[2]
        if type(objectIds) == "table" and objectIds[1] then
            local name = QuestieDB.QueryObjectSingle(objectIds[1], "name")
            local spawns = QuestieDB.QueryObjectSingle(objectIds[1], "spawns")
            if type(spawns) == "table" then
                local bestZoneId, bestSpawn = pickPreferredSpawn(spawns, getPreferredZoneId(questId))
                if bestZoneId then
                    return name, getZoneName(bestZoneId), bestSpawn, bestZoneId
                end
            end
            return name, nil, nil, nil
        end

        return nil, nil, nil, nil
    end

    -- Turn-in targets are static DB data like start info; cached per questId for the session.
    function getQuestFinishInfo(questId)
        local cached = sessionCache.finishInfo[questId]
        if cached then
            return cached.npcName, cached.zoneName, cached.spawn, cached.areaId
        end
        local npcName, zoneName, spawn, areaId = computeQuestFinishInfo(questId)
        sessionCache.finishInfo[questId] = { npcName = npcName, zoneName = zoneName, spawn = spawn, areaId = areaId }
        return npcName, zoneName, spawn, areaId
    end
end

-- Map jump with waypoint and Questie pin pulse; only openMapForQuest leaves the block.
local openMapForQuest
do
    local PULSE = { SCALE = 1.25, DIM = 0.55, HALF_DURATION = 0.45, LOOPS = 3 }

    -- One half of the pulse: a scale and an alpha animation that run in parallel under the same order, so the pin grows as it dims.
    local function addPulseStep(group, order, scaleFrom, scaleTo, alphaFrom, alphaTo)
        local scale = group:CreateAnimation("Scale")
        scale:SetOrder(order)
        scale:SetDuration(PULSE.HALF_DURATION)
        scale:SetSmoothing("IN_OUT")
        scale:SetScaleFrom(scaleFrom, scaleFrom)
        scale:SetScaleTo(scaleTo, scaleTo)
        local fade = group:CreateAnimation("Alpha")
        fade:SetOrder(order)
        fade:SetDuration(PULSE.HALF_DURATION)
        fade:SetSmoothing("IN_OUT")
        fade:SetFromAlpha(alphaFrom)
        fade:SetToAlpha(alphaTo)
    end

    -- Breathing pulse on one Questie map icon, stopped after PULSE.LOOPS loops. REPEAT looping lets the client reset the frame between cycles, which avoids the jumps a single scale animation showed.
    local function createIconPulse(icon)
        local pulse = icon:CreateAnimationGroup()
        pulse:SetLooping("REPEAT")
        addPulseStep(pulse, 1, 1, PULSE.SCALE, 1, PULSE.DIM)
        addPulseStep(pulse, 2, PULSE.SCALE, 1, PULSE.DIM, 1)
        pulse:SetScript("OnLoop", function(self)
            self.qgLoops = self.qgLoops + 1
            if self.qgLoops >= PULSE.LOOPS then
                self:Stop()
            end
        end)
        return pulse
    end

    -- Pulses every Questie icon (world map and minimap) drawn for the quest. The pulse lives on Questie's pooled icon frames, so its fields carry a qg prefix.
    local function highlightQuestOnMap(questId)
        for _, icon in pairs(QuestieMap:GetFramesForQuest(questId)) do
            icon.qgPulse = icon.qgPulse or createIconPulse(icon)
            icon.qgPulse:Stop()
            icon.qgPulse.qgLoops = 0
            icon.qgPulse:Play()
        end
    end

    -- Dungeon interior maps can have no art layers for the world map to draw, so walk up to the first ancestor that has art.
    local function resolveRenderableMapId(uiMapId)
        local current = uiMapId
        for _ = 1, 5 do
            local layers = C_Map.GetMapArtLayers(current)
            if layers and #layers > 0 then
                return current
            end
            local mapInfo = C_Map.GetMapInfo(current)
            if not mapInfo or not mapInfo.parentMapID or mapInfo.parentMapID == 0 or mapInfo.parentMapID == current then
                return nil
            end
            current = mapInfo.parentMapID
        end
        return nil
    end

    -- The native user waypoint plus its in-world beacon. It replaces any waypoint the player set.
    local function setNativeWaypoint(uiMapId, x, y)
        if not C_Map.CanSetUserWaypointOnMap(uiMapId) then
            return
        end
        C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(uiMapId, x, y))
        C_SuperTrack.SetSuperTrackedUserWaypoint(true)
    end

    -- OpenWorldMap honours the WorldMapDisabled game rule; without a renderable map it only opens the map.
    function openMapForQuest(quest)
        local startInfo = resolveStartInfo(quest)
        local uiMapId = startInfo.areaId and ZoneDB:GetUiMapIdByAreaId(startInfo.areaId)
        local renderMapId = uiMapId and resolveRenderableMapId(uiMapId)
        OpenWorldMap(renderMapId)
        if not renderMapId then
            return
        end

        -- Spawn coords belong to uiMapId's coordinate space, so a waypoint is only set when that map is the one shown. TomTom wins when installed; otherwise the native waypoint and beacon are used.
        if renderMapId == uiMapId and startInfo.spawn then
            local x, y = startInfo.spawn[1] / 100, startInfo.spawn[2] / 100
            if type(TomTom) == "table" and TomTom.AddWaypoint then
                pcall(function()
                    TomTom:AddWaypoint(uiMapId, x, y, {
                        title = quest.name or getQuestName(quest.id),
                        persistent = false,
                        minimap = true,
                        world = true,
                    })
                end)
            else
                setNativeWaypoint(uiMapId, x, y)
            end
        end

        -- Questie draws icons asynchronously after the map changes, so wait a tick before pulsing.
        C_Timer.After(0.2, function()
            highlightQuestOnMap(quest.id)
        end)
    end
end

local function clampRange(value)
    if type(value) ~= "number" then
        return nil
    end
    value = math.floor(value + 0.5)
    if value < LEVEL_RANGE.MIN then return LEVEL_RANGE.MIN end
    if value > LEVEL_RANGE.MAX then return LEVEL_RANGE.MAX end
    return value
end

-- Saved band sizes; loadSavedVariables and every writer keep them clamped.
local function getLevelRange()
    return QuestieGuideDB.levelBelow, QuestieGuideDB.levelAbove
end

-- True when Questie colours the quest grey for the player. Used to exclude outgrown quests from the discovery sections.
local function isQuestTrivialForPlayer(questLevel)
    if not questLevel or questLevel <= 0 then
        return false
    end
    return QuestieDB.IsTrivial(questLevel)
end

-- Level band checks; only passesPlayerBand leaves the block.
local passesPlayerBand
do
    -- Quest passes when its effective level sits in [player - below, player + above].
    local function isLevelInBand(questLevel, playerLevel, below, above)
        if not questLevel or questLevel <= 0 then
            return true
        end
        if (playerLevel - questLevel) > below then
            return false
        end
        if (questLevel - playerLevel) > above then
            return false
        end
        return true
    end

    -- True when the quest would render red on the player (5+ levels above, QuestieLib's red tier). Red quests never count toward the XP figures, even when the slider band reaches them.
    local function isQuestRedForPlayer(questLevel, playerLevel)
        if not questLevel or questLevel <= 0 then
            return false
        end
        return (questLevel - playerLevel) >= 5
    end

    -- True when Questie colours the quest yellow or green: not grey by its trivial check, and below orange, which QuestieLib starts 3 levels above the player.
    local function isQuestYellowOrGreen(questLevel, playerLevel)
        if not questLevel or questLevel <= 0 then
            return true
        end
        return not QuestieDB.IsTrivial(questLevel) and (questLevel - playerLevel) < 3
    end

    -- Single authority for the player's level band, shared by display, XP and routing: the explicit ± slider band minus red quests, or Questie's yellow/green tier when the bypass checkbox is on.
    function passesPlayerBand(level, playerLevel)
        if QuestieGuideDB.useQuestieLevelRange then
            return isQuestYellowOrGreen(level, playerLevel)
        end
        local below, above = getLevelRange()
        return isLevelInBand(level, playerLevel, below, above)
            and not isQuestRedForPlayer(level, playerLevel)
    end
end

-- QuestieDB.IsDoable does not enforce requiredLevel, so we gate it explicitly.
local function meetsRequiredLevel(requiredLevel, playerLevel)
    if not requiredLevel or requiredLevel <= 0 then
        return true
    end
    return requiredLevel <= playerLevel
end

-- Mirrors AvailableQuests.IsLevelRequirementsFulfilled: a quest carrying a requiredMaxLevel is permanently unobtainable once the player outlevels it. IsDoable does not check this either.
local function exceedsRequiredMaxLevel(requiredMaxLevel, playerLevel)
    if not requiredMaxLevel or requiredMaxLevel == 0 then
        return false
    end
    return playerLevel > requiredMaxLevel
end

-- Mirrors _AddStarter in Questie's AvailableQuests module: a quest only gets a map icon when at least one approachable starter exists. NPC givers hostile to the player's faction are unreachable, and NPC or object givers need at least one spawn or waypoint in the world. Item-started quests count as reachable because Questie draws them at their drop sources. Anything failing this can never be picked up, so it must not be listed or counted. Reachability is static per character (DB plus faction), so results cache for the session.
local hasReachableStarter
do
    -- The faction test reads the player's own faction, as _AddStarter does.
    local function isNpcStarterReachable(npcId, playerFaction)
        local friendlyToFaction = QuestieDB.QueryNPCSingle(npcId, "friendlyToFaction")
        local hostile = (playerFaction == "Alliance" and friendlyToFaction == "H")
            or (playerFaction == "Horde" and friendlyToFaction == "A")
        if hostile then
            return false
        end
        local spawns = QuestieDB.QueryNPCSingle(npcId, "spawns")
        if type(spawns) == "table" and next(spawns) then
            return true
        end
        local waypoints = QuestieDB.QueryNPCSingle(npcId, "waypoints")
        return type(waypoints) == "table" and next(waypoints) ~= nil
    end

    local function computeReachableStarter(questId)
        local startedBy = QuestieDB.QueryQuestSingle(questId, "startedBy")
        if type(startedBy) ~= "table" then
            return false
        end
        local playerFaction = UnitFactionGroup("player")
        for _, npcId in ipairs(type(startedBy[1]) == "table" and startedBy[1] or {}) do
            if isNpcStarterReachable(npcId, playerFaction) then
                return true
            end
        end
        for _, objectId in ipairs(type(startedBy[2]) == "table" and startedBy[2] or {}) do
            local spawns = QuestieDB.QueryObjectSingle(objectId, "spawns")
            if type(spawns) == "table" and next(spawns) then
                return true
            end
        end
        return type(startedBy[3]) == "table" and startedBy[3][1] ~= nil
    end

    function hasReachableStarter(questId)
        local cached = sessionCache.reachable[questId]
        if cached == nil then
            cached = computeReachableStarter(questId)
            sessionCache.reachable[questId] = cached
        end
        return cached
    end
end

-- True when the quest is not gated by the player's race or class.
local function matchesPlayerFaction(questId)
    local requiredRaces = QuestieDB.QueryQuestSingle(questId, "requiredRaces")
    if requiredRaces and not QuestiePlayer.HasRequiredRace(requiredRaces) then
        return false
    end
    local requiredClasses = QuestieDB.QueryQuestSingle(questId, "requiredClasses")
    if requiredClasses and not QuestiePlayer.HasRequiredClass(requiredClasses) then
        return false
    end
    return true
end

-- Returns the active prereq table for a quest along with which type it is. preQuestSingle (OR) takes precedence over preQuestGroup (AND); Questie treats them as exclusive.
local function getQuestPrereqs(questId)
    local preIds = QuestieDB.QueryQuestSingle(questId, "preQuestSingle")
    if type(preIds) == "table" and preIds[1] then
        return preIds, "single"
    end
    preIds = QuestieDB.QueryQuestSingle(questId, "preQuestGroup")
    if type(preIds) == "table" and preIds[1] then
        return preIds, "group"
    end
    return nil, nil
end

-- True when the quest has prereqs and Questie reports them as not yet satisfied.
local function isBlockedByPrereqs(questId)
    local preIds, kind = getQuestPrereqs(questId)
    if not preIds then
        return false
    end
    if kind == "single" then
        return not QuestieDB:IsPreQuestSingleFulfilled(preIds)
    end
    return not QuestieDB:IsPreQuestGroupFulfilled(preIds)
end

-- Returns a list of chains [initial, ..., target] of incomplete prereqs. preQuestSingle (OR) takes the first incomplete alternative; preQuestGroup (AND) branches into one chain per incomplete prereq so the player sees every initial they have to pick up, not just one arbitrary path.
local function findMissingChains(targetId)
    local results = {}

    local function walk(questId, chain, depth, visited)
        if depth > MAX_CHAIN_DEPTH then
            results[#results + 1] = chain
            return
        end
        if not isBlockedByPrereqs(questId) then
            results[#results + 1] = chain
            return
        end
        local preIds, kind = getQuestPrereqs(questId)
        if not preIds then
            results[#results + 1] = chain
            return
        end
        local pending = {}
        for _, preId in ipairs(preIds) do
            if not visited[preId] and not isQuestCompleted(preId) then
                pending[#pending + 1] = preId
            end
        end
        if #pending == 0 then
            results[#results + 1] = chain
            return
        end

        -- OR: any one prereq satisfies the gate, so the first incomplete option is enough. AND: every prereq must be done, so each becomes its own chain.
        if kind == "single" then
            pending = { pending[1] }
        end
        for _, preId in ipairs(pending) do
            local subChain = { preId }
            for _, c in ipairs(chain) do subChain[#subChain + 1] = c end

            -- Clone visited per branch so AND siblings don't shadow each other's nodes.
            local nextVisited = {}
            for k in pairs(visited) do nextVisited[k] = true end
            nextVisited[preId] = true
            walk(preId, subChain, depth + 1, nextVisited)
        end
    end

    walk(targetId, { targetId }, 0, { [targetId] = true })

    local valid = {}
    for _, p in ipairs(results) do
        if #p > 1 then valid[#valid + 1] = p end
    end
    return valid
end

-- Follow-up projection; only collectZoneFollowups leaves the block.
local collectZoneFollowups
do
    -- Reverse prereq index: preQuestId -> { followerQuestId, ... }. Built once per session because the quest DB is static; only completion state changes at runtime. Negative preQuestGroup ids are indexed by absolute value so those followers stay discoverable through that edge.
    local function ensureFollowerIndex()
        if sessionCache.followers then
            return sessionCache.followers
        end
        local followerIndex = {}
        sessionCache.followers = followerIndex
        local function addEdge(preId, questId)
            if type(preId) == "number" and preId ~= 0 then
                if preId < 0 then preId = -preId end
                local list = followerIndex[preId]
                if not list then
                    list = {}
                    followerIndex[preId] = list
                end
                list[#list + 1] = questId
            end
        end
        for questId in pairs(QuestieDB.QuestPointers) do
            local preIds = QuestieDB.QueryQuestSingle(questId, "preQuestSingle")
            if type(preIds) == "table" then
                for _, preId in ipairs(preIds) do addEdge(preId, questId) end
            end
            preIds = QuestieDB.QueryQuestSingle(questId, "preQuestGroup")
            if type(preIds) == "table" then
                for _, preId in ipairs(preIds) do addEdge(preId, questId) end
            end
            local parentId = QuestieDB.QueryQuestSingle(questId, "parentQuest")
            if parentId and parentId ~= 0 then
                addEdge(parentId, questId)
            end
        end
        return followerIndex
    end

    -- A prereq is settled for the follow-up projection when it is already completed or part of the counted set (a quest the player can pick up now or unlocks along the way).
    local function isPreSettled(preId, counted)
        return counted[preId] == true or isQuestCompleted(preId)
    end

    -- Mirrors QuestieDB:IsPreQuestSingleFulfilled / IsPreQuestGroupFulfilled with counted treated as "will be completed". Single: any one entry settled. Group: every entry settled, where negative ids must be settled directly and positive ids may substitute via a settled exclusiveTo alternative. parentQuest children need the parent active, so the parent must be in the counted set rather than merely completed.
    local function prereqsSettled(questId, counted)
        local single = QuestieDB.QueryQuestSingle(questId, "preQuestSingle")
        if type(single) == "table" and single[1] then
            local anySettled = false
            for _, preId in ipairs(single) do
                if isPreSettled(preId, counted) then
                    anySettled = true
                    break
                end
            end
            if not anySettled then
                return false
            end
        end
        local group = QuestieDB.QueryQuestSingle(questId, "preQuestGroup")
        if type(group) == "table" and group[1] then
            for _, preId in ipairs(group) do
                if preId < 0 then
                    if not isPreSettled(-preId, counted) then
                        return false
                    end
                elseif not isPreSettled(preId, counted) then
                    local substitutes = QuestieDB.QueryQuestSingle(preId, "exclusiveTo")
                    local anySubstitute = false
                    if type(substitutes) == "table" then
                        for _, exId in ipairs(substitutes) do
                            if isPreSettled(exId, counted) then
                                anySubstitute = true
                                break
                            end
                        end
                    end
                    if not anySubstitute then
                        return false
                    end
                end
            end
        end
        local parentId = QuestieDB.QueryQuestSingle(questId, "parentQuest")
        if parentId and parentId ~= 0 and not counted[parentId] then
            return false
        end
        return true
    end

    -- Mirrors IsDoable's permanent-exclusion tail for followers the projection wants to count. exclusiveTo: mutually exclusive alternatives contribute XP once — when the lockout partner is completed, in the log or already counted, this follower is gone (between two exclusive followers the first one found is kept, an acceptable approximation of "count one branch"). nextQuestInChain and breadcrumb targets follow IsDoable exactly: done or in the log means the quest can never be accepted again. Profession, reputation and spell gates are deliberately not mirrored — rare on leveling chains and mostly caught by the level gates.
    local function isLockedForProjection(questId, counted, currentLog)
        local exclusiveTo = QuestieDB.QueryQuestSingle(questId, "exclusiveTo")
        if type(exclusiveTo) == "table" then
            for _, exId in ipairs(exclusiveTo) do
                if counted[exId] or currentLog[exId] or isQuestCompleted(exId) then
                    return true
                end
            end
        end
        local nextInChain = QuestieDB.QueryQuestSingle(questId, "nextQuestInChain")
        if nextInChain and nextInChain ~= 0 and (currentLog[nextInChain] or isQuestCompleted(nextInChain)) then
            return true
        end
        local breadcrumbFor = QuestieDB.QueryQuestSingle(questId, "breadcrumbForQuestId")
        if breadcrumbFor and breadcrumbFor ~= 0 and (currentLog[breadcrumbFor] or isQuestCompleted(breadcrumbFor)) then
            return true
        end
        return false
    end

    -- Projects which not-yet-doable quests unlock inside the zone once its seed quests are done, without leaving the zone. BFS over the reverse prereq index: a follower joins when it is set in the zone or starts at a giver in the zone, passes the same level and faction gates as the discovery scan, and every prereq is completed or already part of the projection. Accepted followers re-enter the frontier so deep chains resolve, and an AND-gated follower is re-examined via the edge from whichever prereq settles last. requiredLevel is deliberately not gated: the player levels up while clearing the zone, and the level band already bounds how far ahead the projection reaches. Repeatables are skipped, they are turn-in loops rather than one-trip chain XP.
    function collectZoneFollowups(zoneName, seeds, currentLog, playerLevel, passesLevelGate)
        local index = ensureFollowerIndex()
        local counted = {}
        local frontier = {}
        for _, questId in ipairs(seeds) do
            counted[questId] = true
            frontier[#frontier + 1] = questId
        end
        local ids = {}
        local xpTotal, count = 0, 0
        for _ = 1, MAX_CHAIN_DEPTH do
            local nextFrontier = {}
            for _, questId in ipairs(frontier) do
                for _, followerId in ipairs(index[questId] or {}) do
                    if not counted[followerId]
                        and not currentLog[followerId]
                        and not isQuestCompleted(followerId) then
                        -- Zone membership: set in the zone (zoneOrSort) or picked up in the zone (giver). The cheap zoneOrSort check runs first; the giver lookup is session-cached per quest.
                        local zoneOrSort = QuestieDB.QueryQuestSingle(followerId, "zoneOrSort")
                        local inZone = zoneOrSort and getZoneName(zoneOrSort) == zoneName
                        if not inZone then
                            local _, giverZoneName = getQuestStartInfo(followerId)
                            inZone = giverZoneName == zoneName
                        end
                        if inZone then
                            local level, requiredLevel, requiredMaxLevel = getEffectiveLevel(followerId, playerLevel)
                            if passesLevelCap(level, requiredLevel)
                                and not exceedsRequiredMaxLevel(requiredMaxLevel, playerLevel)
                                and passesLevelGate(level)
                                and not isQuestTrivialForPlayer(level)
                                and not isQuestHidden(followerId)
                                and hasReachableStarter(followerId)
                                and matchesPlayerFaction(followerId)
                                and not isQuestRepeatable(followerId)
                                and not isLockedForProjection(followerId, counted, currentLog)
                                and prereqsSettled(followerId, counted) then
                                counted[followerId] = true
                                nextFrontier[#nextFrontier + 1] = followerId
                                ids[followerId] = true
                                xpTotal = xpTotal + getQuestXp(followerId)
                                count = count + 1
                            end
                        end
                    end
                end
            end
            if #nextFrontier == 0 then
                break
            end
            frontier = nextFrontier
        end
        return { xp = xpTotal, count = count, ids = ids }
    end
end

-- Zone name the player is standing in, per Questie's area mapping; nil when unresolved.
-- ZoneDB:GetAreaIdByUiMapId raises on a map it has no area for, so an unmapped zone must not break every render.
local function getCurrentZoneName()
    local ok, areaId = pcall(QuestiePlayer.GetCurrentZoneId, QuestiePlayer)
    if not ok or not areaId or areaId <= 0 then
        return nil
    end
    return getZoneName(areaId)
end

-- Buckets every quest into its zone. Expensive; caller should cache the result.
local function scanQuestsByZone()
    local playerLevel = UnitLevel("player")
    local currentLog = QuestiePlayer.currentQuestlog

    -- Gate failures render only under an active search downstream and contribute no XP; see passesPlayerBand for the band semantics.
    local function passesLevelGate(level)
        return passesPlayerBand(level, playerLevel)
    end

    local byZone = {}

    local function ensureZone(zoneName)
        local entry = byZone[zoneName]
        if not entry then
            entry = {
                available = {},
                pickedUpElsewhere = {},
            }
            byZone[zoneName] = entry
        end
        return entry
    end

    -- Quests already in the player's log obey the level band like everything else: out-of-band log quests hide from the list, XP and routing, surfacing only under an active search. They render inside the pickup buckets with an [In Questlog] label, split by giver zone like every other quest.
    for questId in pairs(currentLog) do
        local zoneOrSort = QuestieDB.QueryQuestSingle(questId, "zoneOrSort")
        local level, requiredLevel = getEffectiveLevel(questId, playerLevel)
        if zoneOrSort and passesLevelCap(level, requiredLevel) then
            local questZoneName = getZoneName(zoneOrSort)
            local _, giverZoneName = getQuestStartInfo(questId)
            local quest = {
                id = questId,
                level = level,
                name = getQuestName(questId),

                -- Questie's QuestXP already applies the level reduction, so grey log quests contribute their real reduced XP.
                xp = getQuestXp(questId),
                tag = getQuestTagLabel(questId),
                repeatable = isQuestRepeatable(questId),
                inLog = true,
                outOfRange = not passesLevelGate(level),
            }
            local entry = ensureZone(questZoneName)
            local giverElsewhere = giverZoneName and giverZoneName ~= questZoneName
            local bucket = giverElsewhere and entry.pickedUpElsewhere or entry.available
            bucket[#bucket + 1] = quest
            if giverElsewhere then
                local giverEntry = ensureZone(giverZoneName)
                giverEntry.available[#giverEntry.available + 1] = quest
            end
        end
    end

    for questId in pairs(QuestieDB.QuestPointers) do
        if not currentLog[questId] and not isQuestCompleted(questId) then
            local level, requiredLevel, requiredMaxLevel = getEffectiveLevel(questId, playerLevel)

            -- Out-of-range quests stay in the list, tagged so renderList can hide or fade their rows; only the level cap, the required-level gates, grey (trivial) quests, and quests without a reachable starter exclude quests entirely from the discovery sections.
            if passesLevelCap(level, requiredLevel)
                and meetsRequiredLevel(requiredLevel, playerLevel)
                and not exceedsRequiredMaxLevel(requiredMaxLevel, playerLevel)
                and not isQuestTrivialForPlayer(level)
                and hasReachableStarter(questId) then
                local outOfRange = not passesLevelGate(level)
                if QuestieDB.IsDoable(questId) then
                    local zoneOrSort = QuestieDB.QueryQuestSingle(questId, "zoneOrSort")
                    if zoneOrSort then
                        local questZoneName = getZoneName(zoneOrSort)
                        local _, giverZoneName = getQuestStartInfo(questId)
                        local entry = ensureZone(questZoneName)
                        local quest = {
                            id = questId,
                            level = level,
                            name = getQuestName(questId),
                            xp = getQuestXp(questId),
                            tag = getQuestTagLabel(questId),
                            repeatable = isQuestRepeatable(questId),
                            outOfRange = outOfRange,
                        }

                        -- Non-log quests where the giver NPC lives in another zone go to "Picked Up Elsewhere" as a navigation hint: the quest is set here but you'd need to go somewhere else to start it. Quests with a giver in this zone (or with no resolvable giver location) stay under "Available".
                        local bucket = (giverZoneName and giverZoneName ~= questZoneName)
                            and entry.pickedUpElsewhere
                            or entry.available
                        bucket[#bucket + 1] = quest

                        -- A quest picked up in this zone but set elsewhere also counts for the giver zone: it lists under "Available" there and joins that zone's XP totals and follow-up seeds. The quest table is shared; its fields are zone-independent.
                        if giverZoneName and giverZoneName ~= questZoneName then
                            local giverEntry = ensureZone(giverZoneName)
                            giverEntry.available[#giverEntry.available + 1] = quest
                        end
                    end
                elseif not isQuestHidden(questId) and isBlockedByPrereqs(questId) and matchesPlayerFaction(questId) then
                    local zoneOrSort = QuestieDB.QueryQuestSingle(questId, "zoneOrSort")
                    if zoneOrSort then
                        -- Pick the shortest prereq chain. We don't require the chain initial to be doable; if it is, its tooltip badge shows `[Available]`, otherwise the chain is informational. Each blocked quest contributes ONE row keyed by its own questId — quests in `available` never reappear here.
                        local bestChain
                        for _, chain in ipairs(findMissingChains(questId)) do
                            if not bestChain or #chain < #bestChain then
                                bestChain = chain
                            end
                        end
                        if bestChain then
                            -- Blocked quests land greyed in the same pickup buckets as doable ones. Each zone gets its own row table because unlocksHere is marked per zone by the follow-up projection.
                            local function addBlockedRow(zoneName, bucketKey)
                                local entry = ensureZone(zoneName)
                                local bucket = entry[bucketKey]
                                bucket[#bucket + 1] = {
                                    id = questId,
                                    level = level,
                                    name = getQuestName(questId),
                                    xp = getQuestXp(questId),
                                    tag = getQuestTagLabel(questId),
                                    repeatable = isQuestRepeatable(questId),
                                    chain = bestChain,
                                    blocked = true,
                                    outOfRange = outOfRange,
                                }
                            end
                            local questZoneName = getZoneName(zoneOrSort)
                            local _, giverZoneName = getQuestStartInfo(questId)
                            local giverElsewhere = giverZoneName and giverZoneName ~= questZoneName
                            addBlockedRow(questZoneName, giverElsewhere and "pickedUpElsewhere" or "available")

                            -- A blocked quest starting at a giver in another zone also lists there, mirroring the doable path above.
                            if giverElsewhere then
                                addBlockedRow(giverZoneName, "available")
                            end
                        end
                    end
                end
            end
        end
    end

    -- Actionable rows stay at the top of each bucket: in-range doable first, then in-range blocked (greyed), then out-of-range, level/name ordered within each tier.
    local function sortQuests(list)
        local function tier(q)
            return (q.outOfRange and 2 or 0) + (q.blocked and 1 or 0)
        end
        table.sort(list, function(a, b)
            local ta, tb = tier(a), tier(b)
            if ta ~= tb then
                return ta < tb
            end
            if a.level == b.level then
                return a.name < b.name
            end
            return a.level < b.level
        end)
    end

    local zoneOrder = {}
    for zoneName, entry in pairs(byZone) do
        zoneOrder[#zoneOrder + 1] = zoneName
        sortQuests(entry.available)
        sortQuests(entry.pickedUpElsewhere)

        -- Stats power both the zone header summary and the zone sort. Count only in-range quests so the figures match what a player would consider when choosing where to level; in-log rows obey the band like everything else. The pickable rows double as seeds for the follow-up projection below; blocked rows are tallied after the projection settles which of them unlock in-zone.
        local countInRange = 0
        local xpNow = 0
        local seeds = {}
        local function tallyDoable(list)
            for _, q in ipairs(list) do
                if not q.blocked and not q.outOfRange then
                    countInRange = countInRange + 1
                    xpNow = xpNow + (q.xp or 0)
                    seeds[#seeds + 1] = q.id
                end
            end
        end
        tallyDoable(entry.available)
        tallyDoable(entry.pickedUpElsewhere)

        -- Follow-up projection: chains that keep unlocking in this zone (set here or starting here) once the seeds are done. Blocked quests whose chain runs through another zone stay out of the XP total and are reported separately, so a zone is never credited XP that requires traveling elsewhere to unlock.
        entry.followups = collectZoneFollowups(zoneName, seeds, currentLog, playerLevel, passesLevelGate)
        local travelXp, travelCount = 0, 0
        local function tallyBlocked(list)
            for _, q in ipairs(list) do
                if q.blocked then
                    q.unlocksHere = entry.followups.ids[q.id] == true
                    if not q.outOfRange then
                        countInRange = countInRange + 1
                        if not q.unlocksHere then
                            travelXp = travelXp + (q.xp or 0)
                            travelCount = travelCount + 1
                        end
                    end
                end
            end
        end
        tallyBlocked(entry.available)
        tallyBlocked(entry.pickedUpElsewhere)

        local levelSum, levelCount = 0, 0
        for _, q in ipairs(entry.available) do
            if not q.blocked and not q.inLog and not q.outOfRange and q.level and q.level > 0 then
                levelSum = levelSum + q.level
                levelCount = levelCount + 1
            end
        end

        -- xp is the one-trip value: everything grabbable now plus everything that unlocks in-zone along the way. It drives the XP sort and the best-zone marker.
        entry.stats = {
            count = countInRange,
            xp = xpNow + entry.followups.xp,
            xpFollowup = entry.followups.xp,
            followupCount = entry.followups.count,
            travelXp = travelXp,
            travelCount = travelCount,
            avgLevel = levelCount > 0 and (levelSum / levelCount) or nil,
        }
    end

    table.sort(zoneOrder)
    return byZone, zoneOrder
end

-- Apply the user's sort mode + direction in place. Cheap; safe to call every render. Zones without a value for the chosen metric sort to the END regardless of direction (so the player sees only zones with available quests at the top).
local function sortZones(zoneOrder, byZone)
    local mode = QuestieGuideDB.sortMode
    local desc = QuestieGuideDB.sortDir == "desc"

    local function compareNumeric(getValue)
        local missing = desc and -math.huge or math.huge
        return function(a, b)
            local va = getValue(a) or missing
            local vb = getValue(b) or missing
            if va == vb then return a < b end
            if desc then return va > vb end
            return va < vb
        end
    end

    if mode == "count" then
        table.sort(zoneOrder, compareNumeric(function(z) return byZone[z].stats.count end))
    elseif mode == "xp" then
        table.sort(zoneOrder, compareNumeric(function(z) return byZone[z].stats.xp end))
    elseif mode == "avgLevel" then
        table.sort(zoneOrder, compareNumeric(function(z) return byZone[z].stats.avgLevel end))
    else
        if desc then
            table.sort(zoneOrder, function(a, b) return a > b end)
        else
            table.sort(zoneOrder)
        end
    end

    -- "Other" holds the sort-category catch-all (class/faction/profession quests with no real zoneOrSort). Pin it to the bottom regardless of the selected mode or direction since it's almost always noise compared to the real zones above it.
    for i, name in ipairs(zoneOrder) do
        if name == OTHER_ZONE_NAME then
            table.remove(zoneOrder, i)
            zoneOrder[#zoneOrder + 1] = name
            break
        end
    end
end

local scanCache = { valid = false, byZone = nil, zoneOrder = nil }

local function invalidateScan()
    scanCache.valid = false
end

local function ensureScan()
    if not scanCache.valid then
        scanCache.byZone, scanCache.zoneOrder = scanQuestsByZone()
        scanCache.valid = true
    end
    return scanCache.byZone, scanCache.zoneOrder
end

local function formatLocation(zoneName, spawn)
    if not zoneName then
        return nil
    end
    if spawn then
        return string.format("%s  %.1f, %.1f", zoneName, spawn[1], spawn[2])
    end
    return zoneName
end

-- One label/value tooltip row in Blizzard's own pairing: gold label, white value.
local function addTooltipField(label, value)
    if value == nil or value == "" then
        return
    end
    GameTooltip_AddColoredDoubleLine(GameTooltip, label, tostring(value), NORMAL_FONT_COLOR, HIGHLIGHT_FONT_COLOR)
end

-- Questie's difficulty-coloured quest title, the same one Questie's own tooltips show.
local function getColoredQuestName(questId, showLevel)
    return QuestieLib:GetColoredQuestName(questId, showLevel, false)
end

-- Questie's difficulty colour (red/orange/yellow/green/grey) for the quest level, so the level brackets and name share Questie's hue.
local function getDifficultyColor(level)
    return CreateColor(QuestieLib:GetDifficultyColorPercent(level))
end

local function showQuestTooltip(anchor, questId)
    local quest = QuestieDB.GetQuest(questId)
    if not quest then
        return
    end

    GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
    GameTooltip_SetTitle(GameTooltip, getColoredQuestName(questId, true))
    GameTooltip_AddBlankLineToTooltip(GameTooltip)

    if quest.requiredLevel and quest.requiredLevel > 0 then
        addTooltipField("Required level", quest.requiredLevel)
    end

    if isQuestRepeatable(questId) then
        GameTooltip_AddColoredLine(GameTooltip, "Repeatable", COLOR.REPEATABLE)
    end
    local tagLabel = getQuestTagLabel(questId)
    if tagLabel then
        GameTooltip_AddColoredLine(GameTooltip, tagLabel, QUEST_TAG_COLORS[tagLabel])
    end

    local npcName, npcZone, npcSpawn = getQuestStartInfo(questId)
    addTooltipField("NPC", npcName)
    addTooltipField("Location", formatLocation(npcZone, npcSpawn))

    local xp = getQuestXp(questId)
    if xp > 0 then
        addTooltipField("XP", BreakUpLargeNumbers(xp))
    end

    if type(quest.objectivesText) == "table" and #quest.objectivesText > 0 then
        GameTooltip_AddBlankLineToTooltip(GameTooltip)
        GameTooltip_AddNormalLine(GameTooltip, "Objectives")
        for _, line in ipairs(quest.objectivesText) do
            GameTooltip_AddHighlightLine(GameTooltip, line)
        end
    end

    GameTooltip:Show()
end

-- Giver text under a row, "zone, NPC", or nil when neither is known.
local function formatGiverLine(startInfo)
    if not (startInfo and (startInfo.zoneName or startInfo.npcName)) then
        return nil
    end
    local parts = {}
    if startInfo.zoneName then parts[#parts + 1] = startInfo.zoneName end
    if startInfo.npcName then parts[#parts + 1] = startInfo.npcName end
    return table.concat(parts, ", ")
end

-- Two-line row presentation: [LVL] [TYPE] QUEST_NAME [badge?] over QUEST_GIVER_LOCATION, QUEST_GIVER_NAME. Level and quest name share Questie's difficulty colour; the type tag keeps its own colour. The whole giver line is muted grey so it reads as one subtitle. `badge` is appended after the quest name on line 1 when provided (used by the chain tooltip).
local function formatRowLines(level, name, quest, badge)
    local diff = getDifficultyColor(level)
    local line1 = diff:WrapTextInColorCode("[" .. tostring(level or 0) .. "]")
    if quest and quest.tag then
        line1 = line1 .. " " .. formatTag(quest.tag)
    end
    line1 = line1 .. " " .. diff:WrapTextInColorCode(name or "")
    if badge then
        line1 = line1 .. " " .. badge
    end

    local giverLine = quest and formatGiverLine(resolveStartInfo(quest))
    return line1, giverLine and COLOR.MUTED:WrapTextInColorCode(giverLine)
end

-- Missing-prerequisite chain tooltip; only showChainTooltip leaves the block.
local showChainTooltip
do
    -- Status badge for prior quests in the chain tooltip. `[In Questlog]` if the player has the quest in their log, `[Available]` if it can be picked up right now, otherwise no badge. Completed quests don't appear in the chain at all (findMissingChains skips them).
    local function getStatusBadge(questId)
        if QuestiePlayer.currentQuestlog[questId] then
            return COLOR.IN_LOG:WrapTextInColorCode("[In Questlog]")
        end
        if QuestieDB.IsDoable(questId) then
            return COLOR.READY:WrapTextInColorCode("[Available]")
        end
        return nil
    end

    -- Lightweight quest spec for formatRowLines callers that don't already have a list-row table on hand (i.e. the chain tooltip).
    local function buildQuestSpec(questId)
        local level = getEffectiveLevel(questId, UnitLevel("player"))
        return {
            id = questId,
            level = level,
            name = getQuestName(questId),
            tag = getQuestTagLabel(questId),
        }
    end

    function showChainTooltip(anchor, mpe)
        local chain = mpe.chain
        if type(chain) ~= "table" or #chain < 2 then
            return
        end

        GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")

        -- Title: the hovered (blocked) quest, in the tooltip's larger title font so it stands out above the prior-quests list.
        local title = getDifficultyColor(mpe.level):WrapTextInColorCode(string.format("[%d] %s", mpe.level or 0, mpe.name or ""))
        if mpe.tag then
            title = title .. " " .. formatTag(mpe.tag)
        end
        GameTooltip_SetTitle(GameTooltip, title)

        local giverLine = formatGiverLine(resolveStartInfo(mpe))
        if giverLine then
            GameTooltip_AddDisabledLine(GameTooltip, giverLine)
        end

        GameTooltip_AddBlankLineToTooltip(GameTooltip)

        -- Prior quests that must be completed before the hovered quest unlocks. The hovered quest itself is the chain tail (chain[#chain]); skip it.
        local priorCount = #chain - 1
        for i = 1, priorCount do
            local qid = chain[i]
            local spec = buildQuestSpec(qid)
            local line1, line2 = formatRowLines(spec.level, spec.name, spec, getStatusBadge(qid))
            GameTooltip_AddHighlightLine(GameTooltip, string.format("%d. %s", i, line1))
            if line2 then
                GameTooltip_AddHighlightLine(GameTooltip, line2)
            end
            if i ~= priorCount then
                GameTooltip_AddBlankLineToTooltip(GameTooltip)
            end
        end

        GameTooltip:Show()
    end
end

local function acquireRow(index)
    local row = rowPool[index]
    if row then
        row:Show()

        -- Pool rows persist across renders; reset alpha so a row that was previously used for an out-of-range quest doesn't carry the dimmed look forward when it's reused for a header or in-range quest. renderQuestRow overrides this for actual fading rows.
        row:SetAlpha(1)
        row.highlight:Hide()
        row.selection:Hide()

        -- Reset the header dressing so a row reused for a quest or message doesn't keep the toggle, text inset, or grey header color.
        row.toggle:Hide()
        row.toggleHighlight:SetTexture("")
        row.text:SetPoint("TOPLEFT", row, "TOPLEFT", LIST.TEXT_PAD, -LIST.ROW_PAD)
        row.text:SetTextColor(HIGHLIGHT_FONT_COLOR:GetRGB())
        return row
    end
    row = CreateFrame("Button", nil, scrollChild)
    row:SetHeight(LIST.ROW_HEIGHT)
    row:SetPoint("LEFT", scrollChild, "LEFT", 0, 0)
    row:SetPoint("RIGHT", scrollChild, "RIGHT", 0, 0)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    -- Hover: UI-QuestTitleHighlight in ADD blend, the title highlight Forever's gossip and quest greeting rows use. It sits on BACKGROUND so the row text stays on top, and renderQuestRow drives it so headers stay flat.
    row.highlight = row:CreateTexture(nil, "BACKGROUND")
    row.highlight:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    row.highlight:SetBlendMode("ADD")
    row.highlight:SetAllPoints(true)
    row.highlight:Hide()

    -- Selection: the questlog-quest-glow-yellow atlas Forever's quest log keeps on its called-out quest.
    row.selection = row:CreateTexture(nil, "BACKGROUND", nil, -1)
    row.selection:SetAtlas("questlog-quest-glow-yellow")
    row.selection:SetAllPoints(true)
    row.selection:Hide()
    row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")

    -- Anchor text from the top so wrapped lines grow downward; row height is sized to fit the measured text + LIST.ROW_PAD padding (see renderList).
    row.text:SetPoint("TOPLEFT", row, "TOPLEFT", LIST.TEXT_PAD, -LIST.ROW_PAD)
    row.text:SetPoint("TOPRIGHT", row, "TOPRIGHT", -LIST.TEXT_PAD, -LIST.ROW_PAD)
    row.text:SetJustifyH("LEFT")
    row.text:SetJustifyV("TOP")
    row.text:SetWordWrap(true)
    row.text:SetSpacing(LIST.LINE_GAP)
    row.text:SetTextColor(HIGHLIGHT_FONT_COLOR:GetRGB())

    -- Expand/collapse toggle for header rows. The hilight sits on the HIGHLIGHT layer so the button shows it automatically on mouse-over; quest rows keep its texture empty so nothing renders there.
    row.toggle = row:CreateTexture(nil, "ARTWORK")
    row.toggle:SetSize(LIST.TOGGLE_SIZE, LIST.TOGGLE_SIZE)
    row.toggle:SetPoint("TOPLEFT", row, "TOPLEFT", LIST.TOGGLE_INSET, 0)
    row.toggle:Hide()
    row.toggleHighlight = row:CreateTexture(nil, "HIGHLIGHT")
    row.toggleHighlight:SetBlendMode("ADD")
    row.toggleHighlight:SetAllPoints(row.toggle)
    rowPool[index] = row
    return row
end

-- Dresses a pooled row as a quest log header: plus/minus toggle, indented text, and header grey that whitens while hovered.
local function styleHeaderRow(row, collapsed)
    row.toggle:SetTexture(collapsed and TOGGLE_ART.PLUS or TOGGLE_ART.MINUS)
    row.toggle:Show()
    row.toggleHighlight:SetTexture(TOGGLE_ART.HILIGHT)
    row.text:SetPoint("TOPLEFT", row, "TOPLEFT", LIST.TEXT_INSET, -LIST.ROW_PAD)
    row.text:SetTextColor(HEADER_COLOR.r, HEADER_COLOR.g, HEADER_COLOR.b)
    row:SetScript("OnEnter", function(self)
        self.text:SetTextColor(HIGHLIGHT_FONT_COLOR:GetRGB())
    end)
    row:SetScript("OnLeave", function(self)
        self.text:SetTextColor(HEADER_COLOR.r, HEADER_COLOR.g, HEADER_COLOR.b)
    end)
end

local function hideUnusedRows(fromIndex)
    for i = fromIndex, #rowPool do
        rowPool[i]:Hide()
        rowPool[i]:SetScript("OnClick", nil)
        rowPool[i]:SetScript("OnEnter", nil)
        rowPool[i]:SetScript("OnLeave", nil)
    end
end

local function searchMatches(text)
    if searchText == "" then
        return true
    end
    if not text then
        return false
    end
    return string.find(string.lower(text), searchText, 1, true) ~= nil
end

-- Questie's plain-text share format: receivers running Questie turn "[[level] Name (id)]" into a rich questie hyperlink through its chat filter, everyone else still reads a plain string.
local function buildQuestLink(quest)
    local lvl = quest.level or 0
    local name = quest.name or ("Quest " .. quest.id)
    return string.format("[[%d] %s (%d)]", lvl, name, quest.id)
end

-- Puts the link into the open chat box, or opens chat with it.
local function linkQuestInChat(quest)
    local link = buildQuestLink(quest)
    local editBox = ChatFrameUtil.GetActiveWindow()
    if editBox and editBox:IsVisible() then
        ChatFrameUtil.InsertLink(link)
    else
        ChatFrameUtil.OpenChat(link)
    end
end

-- Context menus use MenuUtil, which shares no UIDropDownMenu globals with Blizzard's secure dropdowns and so can't taint them.
local function showQuestContextMenu(anchor, quest)
    MenuUtil.CreateContextMenu(anchor, function(_, rootDescription)
        rootDescription:CreateTitle(quest.name)
        rootDescription:CreateButton("Show on map", function() openMapForQuest(quest) end)
        rootDescription:CreateButton("Link in chat", function() linkQuestInChat(quest) end)
    end)
end

-- "Show on map" jumps to the next actionable step (the chain's initial), since the blocked quest itself isn't pickup-able yet. "Link in chat" links the blocked quest (the row the player is hovering).
local function showChainContextMenu(anchor, mpe)
    local initial = { id = mpe.chain and mpe.chain[1] }
    MenuUtil.CreateContextMenu(anchor, function(_, rootDescription)
        rootDescription:CreateTitle(mpe.name)
        rootDescription:CreateButton("Show next step on map", function() openMapForQuest(initial) end)
        rootDescription:CreateButton("Link in chat", function() linkQuestInChat(mpe) end)
    end)
end

-- Share of the current level an XP amount covers; nil at the level cap, where there is no next level.
local function getLevelShare(xp)
    local xpMax = UnitXPMax("player")
    if xp <= 0 or xpMax <= 0 or UnitLevel("player") >= GetMaxPlayerLevel() then
        return nil
    end
    return math.floor(xp / xpMax * 100 + 0.5)
end

-- Zone header hover: the breakdown behind the one-trip total. Uses scan-level stats driven by the level filter, which can differ from the rows on screen while a search or bucket filter narrows them.
local function showZoneTooltip(anchor, zoneName, stats, isBest, focusHint)
    if not stats then
        return
    end
    GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
    GameTooltip_SetTitle(GameTooltip, zoneName)
    if isBest then
        GameTooltip_AddNormalLine(GameTooltip, "Best zone for your next trip")
    end
    GameTooltip_AddBlankLineToTooltip(GameTooltip)
    local total = stats.xp or 0
    local share = getLevelShare(total)
    if share then
        addTooltipField("Total XP",
            string.format("%s XP, covers %d%% of level %d", BreakUpLargeNumbers(total), share, UnitLevel("player")))
    else
        addTooltipField("Total XP", BreakUpLargeNumbers(total) .. " XP")
    end
    if (stats.followupCount or 0) > 0 then
        addTooltipField("Includes follow-ups",
            string.format("%s XP (%d quests)", BreakUpLargeNumbers(stats.xpFollowup or 0), stats.followupCount))
    end
    if (stats.travelCount or 0) > 0 then
        addTooltipField("Gated outside this zone",
            string.format("%s XP (%d quests, not counted)", BreakUpLargeNumbers(stats.travelXp or 0), stats.travelCount))
    end
    if focusHint then
        GameTooltip_AddBlankLineToTooltip(GameTooltip)
        GameTooltip_AddInstructionLine(GameTooltip, "Right-click to focus this zone")
    end
    GameTooltip:Show()
end

-- Opens the quest map log at the quest, which selects and scrolls on its own. The details view needs a quest that is in the log, so Questie's quest log gates the call.
local function openQuestInLog(questId)
    if QuestiePlayer.currentQuestlog[questId] then
        QuestMapFrame_OpenToQuestDetails(questId)
    end
end

-- Blink the row's hover highlight a few times so the eye lands on the jump target. Ends hidden; a hover in between re-drives it through OnEnter/OnLeave anyway.
local function flashRow(row)
    local step = 0
    local function blink()
        step = step + 1
        if step % 2 == 1 then
            row.highlight:Show()
        else
            row.highlight:Hide()
        end
        if step < 6 then
            C_Timer.After(0.25, blink)
        end
    end
    blink()
end

-- First zone/bucket in display order holding a pickable or in-log row for the quest, honoring the active filters so the jump only targets a row that actually renders.
local function findListedQuest(questId)
    local byZone = ensureScan()
    local filters = QuestieGuideDB.filters
    for _, zoneName in ipairs(lastZoneOrder) do
        local entry = byZone[zoneName]
        if entry then
            for _, subKey in ipairs(SUBCAT_ORDER) do
                if filters[subKey] then
                    for _, q in ipairs(entry[subKey] or {}) do
                        if q.id == questId and not q.blocked and (not q.inLog or filters.inLog) then
                            return zoneName, subKey
                        end
                    end
                end
            end
        end
    end
end

-- Scrolls the quest list so offset (pixels below the list top) sits at the top of the view. UpdateScrollChildRect refreshes the range right after a re-render resized the list, and SetVerticalScroll moves ScrollFrameTemplate's own scroll bar through its OnVerticalScroll handler.
local function scrollListTo(offset)
    local scroll = mainFrame and mainFrame.scroll
    if not scroll then
        return false
    end
    scroll:UpdateScrollChildRect()
    local range = scroll:GetVerticalScrollRange()
    scroll:SetVerticalScroll(math.min(math.max(offset, 0), range))
    return true
end

-- Expand the target's zone and bucket, re-render, scroll the list to the row and blink it.
local function jumpToQuestInList(questId)
    local zoneName, subKey = findListedQuest(questId)
    if not zoneName then
        return false
    end

    -- The jump target becomes the selected row so the eye keeps it after the blink fades.
    selectedQuestId = questId
    QuestieGuideDB.zoneCollapsed[zoneName] = false
    QuestieGuideDB.groupCollapsed[zoneName .. "||" .. subKey] = false
    renderList()
    local target = rowTargets[questId]
    if not target or not mainFrame or not mainFrame.scroll then
        return false
    end

    -- A third down the viewport keeps some context visible above the target row.
    scrollListTo(target.top - mainFrame.scroll:GetHeight() / 3)
    flashRow(target.row)
    return true
end

-- Tooltip for a ready-to-turn-in quest: Questie-colored name plus the turn-in target, mirroring showQuestTooltip's field styling. The quest's startInfo carries the finisher (see collectCompletedByZone).
local function showTurnInTooltip(anchor, quest)
    GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
    GameTooltip_SetTitle(GameTooltip, getColoredQuestName(quest.id, true))
    GameTooltip_AddColoredLine(GameTooltip, "Completed", GREEN_FONT_COLOR)
    GameTooltip_AddBlankLineToTooltip(GameTooltip)
    local info = quest.startInfo
    addTooltipField("Turn in to", info and info.npcName)
    addTooltipField("Location", info and formatLocation(info.zoneName, info.spawn))
    if quest.xp and quest.xp > 0 then
        addTooltipField("XP", BreakUpLargeNumbers(quest.xp))
    end
    GameTooltip:Show()
end

-- Quests in the log that are ready to turn in, bucketed by the turn-in target's zone. Detection uses QuestieDB.IsComplete, which also settles no-objective auto-complete quests; the zone grouping needs Questie's finishedBy data either way. Cheap (the log holds few quests), so it runs fresh every render instead of joining the scan cache.
local function collectCompletedByZone()
    local playerLevel = UnitLevel("player")
    local byZone = {}
    local zoneOrder = {}
    for questId in pairs(QuestiePlayer.currentQuestlog) do
        if QuestieDB.IsComplete(questId) == 1 then
            local npcName, zoneName, spawn, areaId = getQuestFinishInfo(questId)
            local bucketName = zoneName or OTHER_ZONE_NAME
            local quest = {
                id = questId,
                level = getEffectiveLevel(questId, playerLevel),
                name = getQuestName(questId),
                xp = getQuestXp(questId),
                tag = getQuestTagLabel(questId),
                completed = true,

                -- Finisher stands in for startInfo so row line 2, map clicks, and the waypoint all point at the turn-in target instead of the giver.
                startInfo = { npcName = npcName, zoneName = zoneName, spawn = spawn, areaId = areaId },
            }
            local bucket = byZone[bucketName]
            if not bucket then
                bucket = {}
                byZone[bucketName] = bucket
                zoneOrder[#zoneOrder + 1] = bucketName
            end
            bucket[#bucket + 1] = quest
        end
    end
    for _, list in pairs(byZone) do
        table.sort(list, function(a, b)
            if a.level == b.level then
                return a.name < b.name
            end
            return a.level < b.level
        end)
    end

    -- Zones with the most turn-ins first so the best trip reads at a glance; ties alphabetical, "Other" pinned last like the main list.
    table.sort(zoneOrder, function(a, b)
        if a == OTHER_ZONE_NAME then return false end
        if b == OTHER_ZONE_NAME then return true end
        local countA, countB = #byZone[a], #byZone[b]
        if countA ~= countB then
            return countA > countB
        end
        return a < b
    end)
    return byZone, zoneOrder
end

-- Left-click on a blocked row lands on the chain step the player can act on now. The chain runs [initial, ..., blocked target]; the earliest step with a pickable or in-log row is the actionable one. Falls back to the map at the chain start when no step is listed.
local function jumpToUnlockingQuest(mpe)
    local chain = mpe.chain
    if type(chain) == "table" then
        for i = 1, #chain - 1 do
            if jumpToQuestInList(chain[i]) then
                return
            end
        end
    end
    openMapForQuest({ id = type(chain) == "table" and chain[1] or mpe.id })
end

-- Single action button under the empty-state message; created on demand, hidden by every normal render.
local emptyActionButton

local function getEmptyActionButton()
    if not emptyActionButton then
        emptyActionButton = CreateFrame("Button", nil, scrollChild, "UIPanelButtonTemplate")
        emptyActionButton:SetHeight(LAYOUT.BUTTON_H)
    end
    return emptyActionButton
end

function renderList()
    if not scrollChild then
        return
    end
    if emptyActionButton then
        emptyActionButton:Hide()
    end
    local byZone, zoneOrder = ensureScan()
    sortZones(zoneOrder, byZone)
    lastZoneOrder = zoneOrder
    rowTargets = {}
    zoneHeaderTops = {}

    -- The zone with the highest one-trip value (XP available now plus follow-ups unlocking in-zone) is called out in its header tooltip: the answer to "where should I go questing next", independent of the active sort. "Other" is a sort catch-all rather than a destination, so it never wins.
    local bestZoneName
    if searchText == "" then
        local bestXp = 0
        for _, candidate in ipairs(zoneOrder) do
            if candidate ~= OTHER_ZONE_NAME then
                local stats = byZone[candidate] and byZone[candidate].stats
                if stats and (stats.xp or 0) > bestXp then
                    bestXp = stats.xp
                    bestZoneName = candidate
                end
            end
        end
    end
    local filters = QuestieGuideDB.filters
    local currentZoneName = getCurrentZoneName()
    local index = 1
    local y = 0
    local renderedZones = 0

    -- Two-anchor (TOPLEFT + TOPRIGHT) placement: x-range comes from the horizontal span, top y from the shared y offset, height from sizeRow. Using three anchors (LEFT/RIGHT/TOP) over-constrains the vertical center and resolves inconsistently between the first paint and subsequent layout passes, which is what produced the post-reload offset.
    local function placeRow(row, indent)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", indent, -y)
        row:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", 0, -y)
    end

    -- Sizes the row to fit its wrapped text; minHeight keeps short rows on the grid. The text fontstring already has LEFT/RIGHT anchors inside the row, so wrap width is bounded and GetStringHeight reflects the wrapped result.
    local function sizeRow(row, minHeight)
        local textHeight = math.ceil(row.text:GetStringHeight())
        local h = textHeight + LIST.ROW_PAD * 2
        if h < minHeight then h = minHeight end
        row:SetHeight(h)
        return h
    end

    local function renderQuestRow(label, onEnter, onLeftClick, onRightClick, onShiftClick, alpha, quest)
        y = y + LIST.ROW_GAP
        local rowTop = y
        local row = acquireRow(index)
        placeRow(row, LIST.INDENT_STEP * 2)

        -- Rows are pooled and reused across renders, so always reset alpha explicitly. Out-of-range quests pass 0.5 to dim the row.
        row:SetAlpha(alpha or 1)
        row.text:SetText(label)

        -- The selected row keeps the selection glow until another row is selected. Blocked rows never carry it because their click jumps elsewhere.
        if quest and quest.id == selectedQuestId and not quest.blocked then
            row.selection:Show()
        end
        row:SetScript("OnEnter", function(self)
            row.highlight:Show()
            if onEnter then onEnter(self) end
        end)
        row:SetScript("OnLeave", function()
            row.highlight:Hide()
            GameTooltip:Hide()
        end)
        if onLeftClick or onRightClick or onShiftClick then
            row:SetScript("OnClick", function(self, btn)
                if btn == "LeftButton" and IsModifiedClick("CHATLINK") then
                    if onShiftClick then onShiftClick(self) end
                elseif btn == "RightButton" then
                    if onRightClick then onRightClick(self) end
                else
                    -- Plain left click selects the row like the native quest log before running its action; the re-render moves the selection texture.
                    if quest and not quest.blocked and quest.id ~= selectedQuestId then
                        selectedQuestId = quest.id
                        renderList()
                    end
                    if onLeftClick then onLeftClick(self) end
                end
            end)
        else
            row:SetScript("OnClick", nil)
        end
        y = y + sizeRow(row, LIST.ROW_HEIGHT)
        index = index + 1
        return row, rowTop
    end

    local zoneCollapsedDB = QuestieGuideDB.zoneCollapsed
    local groupCollapsedDB = QuestieGuideDB.groupCollapsed

    local function passesTagFilter(quest)
        -- Repeatable is tested before the tag switch because it rides a specialFlags bit, orthogonal to the tag: a repeatable quest can still carry Dungeon or Group.
        if quest.repeatable and not filters.repeatable then
            return false
        end
        local tag = quest.tag
        if tag == "Dungeon" then
            return filters.dungeons
        end
        if tag == "Group" or tag == "Raid" then
            return filters.eliteGroup
        end
        return true
    end

    local function passesQuest(quest, zoneMatch)
        if not passesTagFilter(quest) then
            return false
        end

        -- Out-of-range rows never render, EXCEPT quests already in the log: accepted quests always list here regardless of the bracket, while XP figures keep respecting it. Dimming is reserved for in-range quests that cannot be accepted yet.
        if quest.outOfRange and not quest.inLog then
            return false
        end
        if zoneMatch then
            return true
        end
        if searchMatches(quest.name) then
            return true
        end
        local startInfo = resolveStartInfo(quest)
        if startInfo and searchMatches(startInfo.npcName) then
            return true
        end
        return false
    end

    local function passesChain(mpe, zoneMatch)
        if zoneMatch then
            return true
        end
        if searchMatches(mpe.name) then
            return true
        end

        -- Match any step in the chain so typing the name of a prereq surfaces the quest that unlocks behind it.
        if type(mpe.chain) == "table" then
            for _, qid in ipairs(mpe.chain) do
                if searchMatches(getQuestName(qid)) then
                    return true
                end
            end
        end
        return false
    end

    -- Completed Quests section at the top of the list: turn-in zones sorted by count, quests styled like the zone buckets below. Returns true when it drew anything so the zone loop and empty-state message can account for it.
    local function renderCompletedSection()
        if not QuestieGuideDB.showCompleted then
            lastCompletedZones = {}
            return false
        end
        local completedByZone, completedZoneOrder = collectCompletedByZone()
        lastCompletedZones = completedZoneOrder

        local visibleByZone = {}
        local total = 0
        for _, zoneName in ipairs(completedZoneOrder) do
            local zoneMatch = searchMatches(zoneName)
            local list = {}
            for _, q in ipairs(completedByZone[zoneName]) do
                if zoneMatch or searchMatches(q.name) or (q.startInfo and searchMatches(q.startInfo.npcName)) then
                    list[#list + 1] = q
                end
            end
            if #list > 0 then
                visibleByZone[zoneName] = list
                total = total + #list
            end
        end
        if total == 0 then
            return false
        end

        local collapsed = zoneCollapsedDB[COMPLETED_KEY] == true
        local header = acquireRow(index)
        placeRow(header, 0)
        styleHeaderRow(header, collapsed)
        header.text:SetText(COMPLETED_LABEL .. " (" .. total .. ")")

        -- Section toggle only flips the section itself; turn-in zone state is independent, matching the zone headers.
        header:SetScript("OnClick", function()
            zoneCollapsedDB[COMPLETED_KEY] = not collapsed
            renderList()
        end)
        y = y + sizeRow(header, LIST.HEADER_HEIGHT)
        index = index + 1

        if not collapsed then
            local subIndex = 0
            for _, zoneName in ipairs(completedZoneOrder) do
                local list = visibleByZone[zoneName]
                if list then
                    subIndex = subIndex + 1
                    local groupKey = COMPLETED_KEY .. "||" .. zoneName
                    local groupHidden = groupCollapsedDB[groupKey] == true

                    y = y + (subIndex == 1 and LIST.ROW_GAP or LIST.GROUP_GAP)

                    local sub = acquireRow(index)
                    placeRow(sub, LIST.INDENT_STEP)
                    styleHeaderRow(sub, groupHidden)
                    sub.text:SetText(string.format("%s (%d)", zoneName, #list))
                    sub:SetScript("OnClick", function()
                        groupCollapsedDB[groupKey] = not groupHidden
                        renderList()
                    end)
                    y = y + sizeRow(sub, LIST.SUBHEADER_HEIGHT)
                    index = index + 1

                    if not groupHidden then
                        for _, quest in ipairs(list) do
                            -- Left-click opens the quest in the native log, matching every other in-log row; the turn-in map view stays reachable through the right-click menu.
                            local badge = COLOR.READY:WrapTextInColorCode("[Completed]")
                            local line1, line2 = formatRowLines(quest.level, quest.name, quest, badge)
                            local label = line2 and (line1 .. "\n" .. line2) or line1
                            renderQuestRow(label,
                                function(self) showTurnInTooltip(self, quest) end,
                                function() openQuestInLog(quest.id) end,
                                function(self) showQuestContextMenu(self, quest) end,
                                function() linkQuestInChat(quest) end,
                                nil, quest)
                        end
                    end
                end
            end
        end
        return true
    end

    -- Next-best-action banner: one line answering "where should I go now" without scanning headers. Click expands the zone and scrolls its header into view; hover shows the zone breakdown. Hidden while searching because bestZoneName is only computed on the unfiltered view.
    local bannerStats = bestZoneName and byZone[bestZoneName] and byZone[bestZoneName].stats
    if bestZoneName and bannerStats and (bannerStats.xp or 0) > 0 then
        local bannerZone = bestZoneName
        local row = acquireRow(index)
        placeRow(row, 0)
        local detail = BreakUpLargeNumbers(bannerStats.xp) .. " XP in one trip"
        local share = getLevelShare(bannerStats.xp)
        if share then
            detail = string.format("%s, covers %d%% of level %d", detail, share, UnitLevel("player"))
        end
        row.text:SetText(COLOR.ACCENT:WrapTextInColorCode("Next: " .. bannerZone) .. "  " .. COLOR.MUTED:WrapTextInColorCode(detail))
        row:SetScript("OnEnter", function(self)
            self.highlight:Show()
            showZoneTooltip(self, bannerZone, bannerStats, true)
        end)
        row:SetScript("OnLeave", function(self)
            self.highlight:Hide()
            GameTooltip:Hide()
        end)
        row:SetScript("OnClick", function()
            expandAndScrollToZone(bannerZone)
        end)
        y = y + sizeRow(row, LIST.HEADER_HEIGHT) + LIST.GROUP_GAP
        index = index + 1
    end

    local completedShown = renderCompletedSection()

    for _, zoneName in ipairs(zoneOrder) do
        local entry = byZone[zoneName]
        if entry then
            local collapsed = zoneCollapsedDB[zoneName] == true
            local zoneMatch = searchMatches(zoneName)

            -- Initialise one empty list per declared subcategory so iterating SUBCAT_ORDER below never lands on a nil bucket if a future key is added.
            local visible = {}
            for _, subKey in ipairs(SUBCAT_ORDER) do
                visible[subKey] = {}
            end

            -- In-log and blocked rows ride inside the pickup buckets, toggled by their filters. Blocked rows match the search through any step of their chain and respect the tag filters like every other row.
            local function passesRow(quest)
                if quest.blocked then
                    return filters.missingPre and passesTagFilter(quest) and passesChain(quest, zoneMatch)
                end
                if quest.inLog and not filters.inLog then
                    return false
                end
                return passesQuest(quest, zoneMatch)
            end
            for _, subKey in ipairs(SUBCAT_ORDER) do
                if filters[subKey] then
                    for _, q in ipairs(entry[subKey] or {}) do
                        if passesRow(q) then
                            visible[subKey][#visible[subKey] + 1] = q
                        end
                    end
                end
            end

            -- visibleTotal gates whether the zone renders at all (so a search match against an out-of-range quest still surfaces its zone), while inRangeTotal / inRangeXp / subInRangeCount drive the count and XP shown in the zone and subcategory headers. Out-of-range quests still render below as dimmed rows.
            local visibleTotal = 0
            local inRangeTotal = 0
            local inRangeXp = 0
            local subInRangeCount = {}
            for _, subKey in ipairs(SUBCAT_ORDER) do
                local subRangeN = 0
                for _, q in ipairs(visible[subKey]) do
                    visibleTotal = visibleTotal + 1

                    -- Log quests count as listed even outside the bracket; their XP only counts in range.
                    if not q.outOfRange or q.inLog then
                        subRangeN = subRangeN + 1
                        inRangeTotal = inRangeTotal + 1

                        -- Blocked-quest XP is carried by the zone-level follow-up figure (only chains that unlock in-zone count), never by row summation.
                        if not q.blocked and not q.outOfRange then
                            inRangeXp = inRangeXp + (q.xp or 0)
                        end
                    end
                end
                subInRangeCount[subKey] = subRangeN
            end

            -- Zones render only when they hold at least one in-range row; out-of-range rows never reach the visible lists.
            if visibleTotal > 0 then
                if renderedZones > 0 or completedShown then
                    y = y + LIST.ZONE_GAP
                end
                renderedZones = renderedZones + 1
                zoneHeaderTops[zoneName] = y

                local header = acquireRow(index)
                placeRow(header, 0)
                styleHeaderRow(header, collapsed)
                local summary = " (" .. inRangeTotal .. ")"

                -- Search narrows the rows on screen, so the zone-level follow-up projection would no longer match them; the projection only shows on the unfiltered view.
                local followupXp = (searchText == "" and entry.followups and entry.followups.xp) or 0

                -- Single total XP figure: rows in range plus follow-ups unlocking in-zone. Percent-of-level detail lives in the header tooltip.
                local totalXp = inRangeXp + followupXp
                if totalXp > 0 then
                    summary = summary .. " " .. COLOR.MUTED:WrapTextInColorCode(BreakUpLargeNumbers(totalXp) .. " XP")
                end
                local isBestZone = (zoneName == bestZoneName)

                -- Current-zone marker: gold tag on the header of the zone the player is standing in.
                local headerText = zoneName .. summary
                if zoneName == currentZoneName then
                    headerText = headerText .. " " .. COLOR.ACCENT:WrapTextInColorCode("(You are here)")
                end
                header.text:SetText(headerText)
                local zoneStats = entry.stats
                header:SetScript("OnEnter", function(self)
                    self.text:SetTextColor(HIGHLIGHT_FONT_COLOR:GetRGB())
                    showZoneTooltip(self, zoneName, zoneStats, isBestZone, true)
                end)
                header:SetScript("OnLeave", function(self)
                    self.text:SetTextColor(HEADER_COLOR.r, HEADER_COLOR.g, HEADER_COLOR.b)
                    GameTooltip:Hide()
                end)

                -- Zone toggle only flips the zone itself; subcategory state is independent and survives so Collapse All's collapsed subs stay collapsed. Right-click focuses the zone: everything else collapses, this zone expands.
                header:SetScript("OnClick", function(_, btn)
                    if btn == "RightButton" then
                        for _, other in ipairs(lastZoneOrder) do
                            zoneCollapsedDB[other] = other ~= zoneName
                        end
                        zoneCollapsedDB[COMPLETED_KEY] = true
                    else
                        zoneCollapsedDB[zoneName] = not collapsed
                    end
                    renderList()
                end)
                y = y + sizeRow(header, LIST.HEADER_HEIGHT)
                index = index + 1

                if not collapsed then
                    local subIndex = 0
                    for _, subKey in ipairs(SUBCAT_ORDER) do
                        local list = visible[subKey]
                        if filters[subKey] and #list > 0 then
                            subIndex = subIndex + 1
                            local groupKey = zoneName .. "||" .. subKey
                            local groupHidden = groupCollapsedDB[groupKey] == true

                            y = y + (subIndex == 1 and LIST.ROW_GAP or LIST.GROUP_GAP)

                            local sub = acquireRow(index)
                            placeRow(sub, LIST.INDENT_STEP)
                            styleHeaderRow(sub, groupHidden)
                            sub.text:SetText(string.format("%s (%d)",
                                SUBCAT_LABEL[subKey], subInRangeCount[subKey] or 0))
                            sub:SetScript("OnClick", function()
                                groupCollapsedDB[groupKey] = not groupHidden
                                renderList()
                            end)
                            y = y + sizeRow(sub, LIST.SUBHEADER_HEIGHT)
                            index = index + 1

                            if not groupHidden then
                                for _, quest in ipairs(list) do
                                    if quest.blocked then
                                        -- Row is the blocked quest itself, greyed until its chain is cleared. Left-click jumps the list to the chain step the player can pick up now; chat link points at the blocked quest (the row being hovered).
                                        local badge = COLOR.BLOCKED:WrapTextInColorCode("[Missing Pre-Quest]")
                                        local line1, line2 = formatRowLines(quest.level, quest.name, quest, badge)
                                        local label = line2 and (line1 .. "\n" .. line2) or line1
                                        renderQuestRow(label,
                                            function(self) showChainTooltip(self, quest) end,
                                            function() jumpToUnlockingQuest(quest) end,
                                            function(self) showChainContextMenu(self, quest) end,
                                            function() linkQuestInChat(quest) end,
                                            0.5, quest)
                                    else
                                        -- In-log rows open the native quest log; pickable rows open the map at their giver. Both register as jump targets for blocked rows' chains.
                                        local badge = quest.inLog
                                            and COLOR.IN_LOG:WrapTextInColorCode("[In Questlog]")
                                            or COLOR.READY:WrapTextInColorCode("[Available]")
                                        local line1, line2 = formatRowLines(quest.level, quest.name, quest, badge)
                                        local label = line2 and (line1 .. "\n" .. line2) or line1
                                        local onLeftClick = quest.inLog
                                            and function() openQuestInLog(quest.id) end
                                            or function() openMapForQuest(quest) end
                                        local row, rowTop = renderQuestRow(label,
                                            function(self) showQuestTooltip(self, quest.id) end,
                                            onLeftClick,
                                            function(self) showQuestContextMenu(self, quest) end,
                                            function() linkQuestInChat(quest) end,
                                            1, quest)
                                        if not rowTargets[quest.id] then
                                            rowTargets[quest.id] = { row = row, top = rowTop }
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if renderedZones == 0 and not completedShown then
        local anyBucket = filters.available or filters.pickedUpElsewhere
        local msg
        if not anyBucket then
            msg = "All quest filters are off. Enable Picked Up in Zone or Picked Up Outside of Zone to see quests."
        elseif searchText ~= "" then
            msg = string.format("No quests match \"%s\". Clear the search or change filters.", searchText)
        else
            msg = "No non-trivial quests available right now. Level up or move to a different area to unlock more."
        end
        local row = acquireRow(index)
        placeRow(row, 0)
        row.text:SetText(COLOR.MUTED:WrapTextInColorCode(msg))
        row:SetScript("OnEnter", nil)
        row:SetScript("OnLeave", nil)
        row:SetScript("OnClick", nil)
        y = y + sizeRow(row, LIST.ROW_HEIGHT * 2)
        index = index + 1

        -- One-click fix for the likely cause, mirroring the message above. No button when Questie's ranges govern or the sliders are maxed; the message's advice (level up, move on) has no shortcut.
        local below, above = getLevelRange()
        local actionText, action
        if not anyBucket then
            actionText = "Enable Quest Filters"
            action = function()
                filters.available = true
                filters.pickedUpElsewhere = true
                invalidateScan()
                renderList()
            end
        elseif searchText ~= "" then
            actionText = "Clear Search"
            action = function()
                mainFrame.searchBox:SetText("")
            end
        elseif not QuestieGuideDB.useQuestieLevelRange
            and (below < LEVEL_RANGE.MAX or above < LEVEL_RANGE.MAX) then
            actionText = "Widen Level Range"
            action = function()
                QuestieGuideDB.levelBelow = clampRange(below + 2)
                QuestieGuideDB.levelAbove = clampRange(above + 2)
                mainFrame.refreshRangeSliders()
                invalidateScan()
                renderList()
            end
        end
        if actionText then
            local button = getEmptyActionButton()
            button:SetText(actionText)
            button:SetWidth(math.max(LAYOUT.BUTTON_W, button:GetFontString():GetStringWidth() + 32))
            button:ClearAllPoints()
            button:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -(y + LIST.GROUP_GAP))
            button:SetScript("OnClick", action)
            button:Show()
            y = y + LIST.GROUP_GAP + LAYOUT.BUTTON_H
        end
    end

    scrollChild:SetHeight(math.max(y, 1))
    hideUnusedRows(index)

    if mainFrame and mainFrame.toggleAllButton then
        local allCollapsed = #zoneOrder > 0 or completedShown
        for _, zoneName in ipairs(zoneOrder) do
            if not zoneCollapsedDB[zoneName] then
                allCollapsed = false
                break
            end
        end
        if completedShown and not zoneCollapsedDB[COMPLETED_KEY] then
            allCollapsed = false
        end
        mainFrame.toggleAllButton:SetText(allCollapsed and "Expand All" or "Collapse All")
    end
end

-- Expands the zone and scrolls its header into view; shared by the banner, the Current Zone button, and level-up toast links. Returns false when the zone has no header on screen.
function expandAndScrollToZone(zoneName)
    QuestieGuideDB.zoneCollapsed[zoneName] = false
    renderList()
    local top = zoneHeaderTops[zoneName]
    if not top then
        return false
    end
    return scrollListTo(top)
end

-- Window builders; only buildMainFrame leaves the block.
local buildMainFrame
do
    -- A settings block: gold GameFontNormal heading over a body frame. Blocks chain below the previous one, so resizing one (the level range hides its sliders) moves every block below it.
    local function createGroup(parent, previous, labelText)
        local group = CreateFrame("Frame", nil, parent)
        if previous then
            group:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -LAYOUT.GROUP_GAP)
        else
            group:SetPoint("TOPLEFT", parent, "TOPLEFT", LAYOUT.PANE_PAD, -LAYOUT.PANE_PAD)
        end
        group:SetPoint("RIGHT", parent, "RIGHT", -LAYOUT.PANE_PAD, 0)
        local label = group:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        label:SetPoint("TOPLEFT", group, "TOPLEFT", 0, 0)
        label:SetText(labelText)
        local body = CreateFrame("Frame", nil, group)
        body:SetPoint("TOPLEFT", group, "TOPLEFT", 0, -LAYOUT.HEADING_H)
        body:SetPoint("BOTTOMRIGHT", group, "BOTTOMRIGHT", 0, 0)
        group.body = body
        return group
    end

    -- Explicit heights let the chained blocks below find their place.
    local function sizeGroup(group, bodyHeight)
        group:SetHeight(LAYOUT.HEADING_H + bodyHeight)
    end

    -- UICheckButtonTemplate keeps its own label anchor; only the font changes to white GameFontHighlight, the color Blizzard's option labels use.
    local function buildCheckbox(parent, name, labelText, onClick)
        local box = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
        box:SetSize(LAYOUT.CHECK_SIZE, LAYOUT.CHECK_SIZE)
        box.Text:SetFontObject("GameFontHighlight")
        box.Text:SetText(labelText)
        box:SetScript("OnClick", onClick)
        return box
    end

    -- MinimalSliderWithSteppersTemplate is the slider Blizzard's Settings panel uses: a Slider with - / + steppers and top, min and max labels, its width taken from the caller's anchors.
    local function buildRangeSlider(parent, name, labelPrefix, dbKey)
        local slider = CreateFrame("Frame", name, parent, "MinimalSliderWithSteppersTemplate")
        local steps = LEVEL_RANGE.MAX - LEVEL_RANGE.MIN
        local Label = MinimalSliderWithSteppersMixin.Label
        local formatters = {
            [Label.Top] = function(v) return labelPrefix .. v end,
            [Label.Min] = function() return tostring(LEVEL_RANGE.MIN) end,
            [Label.Max] = function() return tostring(LEVEL_RANGE.MAX) end,
        }
        slider:Init(QuestieGuideDB[dbKey], LEVEL_RANGE.MIN, LEVEL_RANGE.MAX, steps, formatters)
        slider:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(_, value)
            local v = clampRange(value)
            if not v or QuestieGuideDB[dbKey] == v then
                return
            end
            QuestieGuideDB[dbKey] = v
            invalidateScan()
            renderList()
        end, slider)
        return slider
    end

    -- Quest Level Range block: "Use Questie Level Ranges" above the below / above sliders. Ticking it hides the sliders, and the scan switches from the band to Questie's yellow/green tiers (see passesPlayerBand).
    local function buildRangeGroup(frame, parent)
        local expandedHeight = LAYOUT.CHECK_SIZE + (LAYOUT.CONTROL_GAP + LAYOUT.SLIDER_H) * 2
        local group = createGroup(parent, nil, "Quest Level Range")
        local body = group.body

        local useQuestieCheckbox = buildCheckbox(body, "QuestieGuideUseQuestieLevelRange", "Use Questie Level Ranges")
        useQuestieCheckbox:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)

        local belowTop = LAYOUT.CHECK_SIZE + LAYOUT.CONTROL_GAP
        local belowSlider = buildRangeSlider(body, "QuestieGuideRangeSlider1", "Quest Level Below: -", "levelBelow")
        belowSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -belowTop)
        belowSlider:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -belowTop)

        local aboveTop = belowTop + LAYOUT.SLIDER_H + LAYOUT.CONTROL_GAP
        local aboveSlider = buildRangeSlider(body, "QuestieGuideRangeSlider2", "Quest Level Above: +", "levelAbove")
        aboveSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -aboveTop)
        aboveSlider:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -aboveTop)

        local function applySliderLock(locked)
            belowSlider:SetShown(not locked)
            aboveSlider:SetShown(not locked)
            if not locked then
                belowSlider:SetEnabled(true)
                aboveSlider:SetEnabled(true)
            end
            sizeGroup(group, locked and LAYOUT.CHECK_SIZE or expandedHeight)
        end

        useQuestieCheckbox:SetChecked(QuestieGuideDB.useQuestieLevelRange)
        applySliderLock(QuestieGuideDB.useQuestieLevelRange)
        useQuestieCheckbox:SetScript("OnClick", function(self)
            local checked = self:GetChecked() and true or false
            QuestieGuideDB.useQuestieLevelRange = checked
            applySliderLock(checked)
            invalidateScan()
            renderList()
        end)

        frame.refreshRangeSliders = function()
            useQuestieCheckbox:SetChecked(QuestieGuideDB.useQuestieLevelRange)
            applySliderLock(QuestieGuideDB.useQuestieLevelRange)
            local below, above = getLevelRange()
            belowSlider:SetValue(below)
            aboveSlider:SetValue(above)
        end
        return group
    end

    -- Filter families, one multi-select dropdown each; the keys live under QuestieGuideDB.filters.
    local FILTER_FAMILIES = {
        {
            title = "Availability",
            specs = {
                { key = "inLog",             label = "In Questlog" },
                { key = "available",         label = "Picked Up in Zone" },
                { key = "pickedUpElsewhere", label = "Picked Up Outside of Zone" },
                { key = "missingPre",        label = "Missing Pre-Quest" },
            },
        },
        {
            title = "Quest Types",
            specs = {
                { key = "dungeons",   label = "Dungeons" },
                { key = "eliteGroup", label = "Elite (Group)" },
                { key = "repeatable", label = "Repeatable" },
            },
        },
    }

    -- Filters block: one full-width WowStyle1 dropdown per family. The button text stays on the family title because a multi-select would otherwise list every enabled option (OverrideText sets disableSelectionText), and the menu rereads its checked state from the saved variables on every open, so nothing needs refreshing.
    local function buildFilterGroup(parent, previous)
        local filters = QuestieGuideDB.filters
        local group = createGroup(parent, previous, "Filters")
        sizeGroup(group, LAYOUT.DROPDOWN_H * #FILTER_FAMILIES + LAYOUT.CONTROL_GAP * (#FILTER_FAMILIES - 1))
        for i, family in ipairs(FILTER_FAMILIES) do
            local dd = CreateFrame("DropdownButton", "QuestieGuideFilterDropdown" .. i, group.body, "WowStyle1DropdownTemplate")
            dd:OverrideText(family.title)
            dd:SetupMenu(function(_, rootDescription)
                for _, spec in ipairs(family.specs) do
                    rootDescription:CreateCheckbox(
                        spec.label,
                        function() return filters[spec.key] end,
                        function()
                            filters[spec.key] = not filters[spec.key]
                            invalidateScan()
                            renderList()
                        end)
                end
            end)
            local top = (i - 1) * (LAYOUT.DROPDOWN_H + LAYOUT.CONTROL_GAP)
            dd:SetPoint("TOPLEFT", group.body, "TOPLEFT", LAYOUT.DROPDOWN_INDENT, -top)
            dd:SetPoint("RIGHT", group.body, "RIGHT", -LAYOUT.DROPDOWN_INDENT, 0)
        end
        return group
    end

    -- Single-select dropdown bound to one saved key; the button text follows the selected radio through DropdownSelectionTextMixin, with defaultLabel shown when nothing matches.
    local function buildSortDropdown(parent, name, dbKey, options, defaultLabel)
        local dd = CreateFrame("DropdownButton", name, parent, "WowStyle1DropdownTemplate")
        dd:SetDefaultText(defaultLabel)
        dd:SetupMenu(function(_, rootDescription)
            for _, opt in ipairs(options) do
                rootDescription:CreateRadio(
                    opt.label,
                    function()
                        return QuestieGuideDB[dbKey] == opt.value
                    end,
                    function()
                        QuestieGuideDB[dbKey] = opt.value
                        renderList()
                    end)
            end
        end)
        return dd
    end

    -- Sorting block: sort key above direction, each full width like the filter dropdowns.
    local function buildSortGroup(frame, parent, previous)
        local group = createGroup(parent, previous, "Sorting")
        sizeGroup(group, LAYOUT.DROPDOWN_H * 2 + LAYOUT.CONTROL_GAP)
        local body = group.body

        local sortByDropdown = buildSortDropdown(body, "QuestieGuideSortByDropdown", "sortMode", SORT_BY_OPTIONS, "Sort By")
        sortByDropdown:SetPoint("TOPLEFT", body, "TOPLEFT", LAYOUT.DROPDOWN_INDENT, 0)
        sortByDropdown:SetPoint("RIGHT", body, "RIGHT", -LAYOUT.DROPDOWN_INDENT, 0)

        local sortDirDropdown = buildSortDropdown(body, "QuestieGuideSortDirDropdown", "sortDir", SORT_DIR_OPTIONS, "Direction")
        sortDirDropdown:SetPoint("TOPLEFT", body, "TOPLEFT", LAYOUT.DROPDOWN_INDENT, -(LAYOUT.DROPDOWN_H + LAYOUT.CONTROL_GAP))
        sortDirDropdown:SetPoint("RIGHT", body, "RIGHT", -LAYOUT.DROPDOWN_INDENT, 0)

        -- Regenerating the menus re-evaluates the radios, which refreshes the button text after the saved sort changed elsewhere.
        frame.refreshSortDropdown = function()
            sortByDropdown:GenerateMenu()
            sortDirDropdown:GenerateMenu()
        end
        return group
    end

    -- Visibility block: toggles that add whole sections to the list. The completed section reads the live quest log each render, so no rescan is needed.
    local function buildVisibilityGroup(frame, parent, previous)
        local group = createGroup(parent, previous, "Visibility Filters")
        sizeGroup(group, LAYOUT.CHECK_SIZE)
        local showCompletedCheckbox = buildCheckbox(group.body, "QuestieGuideShowCompleted", "Show Completed Quests", function(self)
            QuestieGuideDB.showCompleted = self:GetChecked() and true or false
            renderList()
        end)
        showCompletedCheckbox:SetPoint("TOPLEFT", group.body, "TOPLEFT", 0, 0)
        frame.refreshShowCompleted = function()
            showCompletedCheckbox:SetChecked(QuestieGuideDB.showCompleted)
        end
        return group
    end

    -- Left column: every option in its own InsetFrameTemplate, the way ChannelFrame splits its ButtonFrameTemplate window into a LeftInset and a RightInset.
    local function buildSettingsColumn(frame)
        local inset = CreateFrame("Frame", nil, frame, "InsetFrameTemplate")
        inset:SetPoint("TOPLEFT", frame, "TOPLEFT", PANEL_INSET_LEFT_OFFSET, PANEL_INSET_ATTIC_OFFSET)
        inset:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PANEL_INSET_LEFT_OFFSET, PANEL_INSET_BOTTOM_BUTTON_OFFSET)
        inset:SetWidth(LAYOUT.PANE_W)
        local rangeGroup = buildRangeGroup(frame, inset)
        local filterGroup = buildFilterGroup(inset, rangeGroup)
        local sortGroup = buildSortGroup(frame, inset, filterGroup)
        buildVisibilityGroup(frame, inset, sortGroup)
        return inset
    end

    -- Right column: the quest list in the template's own Inset, moved beside the settings column. ScrollFrameTemplate is what Forever's quest log (QuestScrollFrame) uses; it creates MinimalScrollBar and wires wheel, range and thumb itself.
    local function buildQuestList(frame, settingsInset)
        local inset = frame.Inset
        inset:ClearAllPoints()
        inset:SetPoint("TOPLEFT", settingsInset, "TOPRIGHT", LAYOUT.COLUMN_GAP, 0)
        inset:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", PANEL_INSET_RIGHT_OFFSET, PANEL_INSET_BOTTOM_BUTTON_OFFSET)

        local scroll = CreateFrame("ScrollFrame", nil, inset, "ScrollFrameTemplate")
        scroll.ScrollBar:SetHideIfUnscrollable(true)

        -- The bar hangs off the scroll frame's right edge and above its top by ScrollDefine's offsets, so the frame leaves exactly that room inside the inset.
        local barRight = scroll.ScrollBar:GetWidth() + SCROLL_FRAME_SCROLL_BAR_OFFSET_LEFT
        local barTop = SCROLL_FRAME_SCROLL_BAR_OFFSET_TOP
        scroll:SetPoint("TOPLEFT", inset, "TOPLEFT", LAYOUT.LIST_PAD, -(LAYOUT.LIST_PAD + barTop))
        scroll:SetPoint("BOTTOMRIGHT", inset, "BOTTOMRIGHT", -(LAYOUT.LIST_PAD + barRight), LAYOUT.LIST_PAD)

        -- The scroll child has no anchors so SetScrollChild can position it; its width follows the viewport so rows wrap inside it.
        local child = CreateFrame("Frame", nil, scroll)
        child:SetSize(math.max(1, scroll:GetWidth()), 1)
        scroll:SetScrollChild(child)
        scroll:HookScript("OnSizeChanged", function(self)
            child:SetWidth(math.max(1, self:GetWidth()))
            renderList()
        end)
        scrollChild = child
        frame.scroll = scroll
    end

    -- Attic search box, sized and placed like AddonList's; SearchBoxTemplate brings the magnifier, clear button and placeholder.
    local function buildSearchBox(frame)
        local searchBox = CreateFrame("EditBox", "QuestieGuideSearchBox", frame, "SearchBoxTemplate")
        searchBox:SetSize(LAYOUT.SEARCH_W, LAYOUT.SEARCH_H)
        searchBox:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -LAYOUT.SEARCH_RIGHT, -LAYOUT.SEARCH_TOP)
        searchBox.Instructions:SetText("Quest, zone or NPC name")
        searchBox:HookScript("OnTextChanged", function(self)
            local newText = string.lower(self:GetText() or "")
            if newText == searchText then return end
            searchText = newText
            renderList()
        end)
        frame.searchBox = searchBox
    end

    -- Collapses everything when anything is expanded, otherwise expands everything. Bucket state follows the zones, so the button acts as one "show me everything / nothing" control.
    local function toggleAllZones()
        local zc = QuestieGuideDB.zoneCollapsed
        local gc = QuestieGuideDB.groupCollapsed
        local completedActive = QuestieGuideDB.showCompleted and #lastCompletedZones > 0
        local anyExpanded = false
        for _, zoneName in ipairs(lastZoneOrder) do
            if not zc[zoneName] then anyExpanded = true; break end
        end
        if completedActive and not zc[COMPLETED_KEY] then
            anyExpanded = true
        end
        for _, zoneName in ipairs(lastZoneOrder) do
            zc[zoneName] = anyExpanded
            for _, subKey in ipairs(SUBCAT_ORDER) do
                gc[zoneName .. "||" .. subKey] = anyExpanded
            end
        end
        if completedActive then
            zc[COMPLETED_KEY] = anyExpanded
            for _, zoneName in ipairs(lastCompletedZones) do
                gc[COMPLETED_KEY .. "||" .. zoneName] = anyExpanded
            end
        end
        renderList()
    end

    -- Expands and scrolls to the zone the player is standing in.
    local function jumpToCurrentZone()
        local zoneName = getCurrentZoneName()
        if not zoneName then
            return
        end
        if not expandAndScrollToZone(zoneName) then
            print(INTRO_PREFIX .. "No quests listed for " .. zoneName .. ".")
        end
    end

    -- One MagicButtonTemplate bar button. MagicButton_OnLoad runs after the zero-offset anchor so it can apply Blizzard's corner and neighbour offsets.
    local function createBarButton(frame, text, onClick, point, relativeTo, relativePoint)
        local button = CreateFrame("Button", nil, frame, "MagicButtonTemplate")
        button:SetWidth(LAYOUT.BUTTON_W)
        button:SetPoint(point, relativeTo, relativePoint)
        MagicButton_OnLoad(button)
        button:SetText(text)
        button:SetScript("OnClick", onClick)
        return button
    end

    -- Button bar chained from the bottom-left corner, because the resize grip owns the bottom-right corner (PanelResizeButtonTemplate always sizes from BOTTOMRIGHT).
    local function buildButtonBar(frame)
        local toggleAllButton = createBarButton(frame, "Collapse All", toggleAllZones, "BOTTOMLEFT", frame, "BOTTOMLEFT")
        createBarButton(frame, "Current Zone", jumpToCurrentZone, "LEFT", toggleAllButton, "RIGHT")
        frame.toggleAllButton = toggleAllButton
    end

    -- The window: Blizzard's ButtonFrameTemplate with its portrait, title bar, close button, attic and button bar. Movable, clamped, resizable and closed by Escape; UIPanelWindows is avoided because of taint.
    local function createWindow()
        local frame = CreateFrame("Frame", "QuestieGuideFrame", UIParent, "ButtonFrameTemplate")

        -- Clamp the saved size to this layout's bounds.
        local savedSize = QuestieGuideDB.frameSize
        local width = math.min(math.max(savedSize.w, LAYOUT.MIN_W), LAYOUT.MAX_W)
        local height = math.min(math.max(savedSize.h, LAYOUT.MIN_H), LAYOUT.MAX_H)
        frame:SetSize(width, height)
        frame:SetTitle("Questie Guide")
        frame:SetPortraitToAsset(ADDON_ICON)
        frame:SetFrameStrata("HIGH")
        frame:SetToplevel(true)
        frame:SetClampedToScreen(true)
        frame:SetMovable(true)
        frame:SetResizable(true)
        frame:SetResizeBounds(LAYOUT.MIN_W, LAYOUT.MIN_H, LAYOUT.MAX_W, LAYOUT.MAX_H)
        frame:EnableMouse(true)
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", frame.StartMoving)
        frame:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
            local point, _, relPoint, x, y = self:GetPoint(1)
            QuestieGuideDB.framePos = { point = point, relPoint = relPoint, x = x, y = y }
        end)

        local savedPos = QuestieGuideDB.framePos
        if type(savedPos) == "table" and savedPos.point then
            frame:ClearAllPoints()
            frame:SetPoint(savedPos.point, UIParent, savedPos.relPoint or savedPos.point, savedPos.x or 0, savedPos.y or 0)
        else
            frame:SetPoint("CENTER")
        end
        frame:Hide()

        -- PanelResizeButtonTemplate is the corner grip of Blizzard's resizable EventTrace. Its Init replaces the frame's OnSizeChanged script with a wrapper, so the size-saving hook goes on afterwards.
        local resizeButton = CreateFrame("Button", nil, frame, "PanelResizeButtonTemplate")
        resizeButton:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -LAYOUT.GRIP_PAD, LAYOUT.GRIP_PAD)
        resizeButton:Init(frame, LAYOUT.MIN_W, LAYOUT.MIN_H, LAYOUT.MAX_W, LAYOUT.MAX_H)
        frame:HookScript("OnSizeChanged", function(self)
            QuestieGuideDB.frameSize = { w = math.floor(self:GetWidth()), h = math.floor(self:GetHeight()) }
        end)

        tinsert(UISpecialFrames, "QuestieGuideFrame")
        return frame
    end

    -- Builds the window on first open and returns it afterwards.
    function buildMainFrame()
        if mainFrame then
            return mainFrame
        end
        local frame = createWindow()
        local settingsInset = buildSettingsColumn(frame)
        buildQuestList(frame, settingsInset)
        buildSearchBox(frame)
        buildButtonBar(frame)
        mainFrame = frame
        return frame
    end
end

local function renderLoadingPlaceholder()
    if emptyActionButton then
        emptyActionButton:Hide()
    end
    hideUnusedRows(1)
    local row = acquireRow(1)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -LIST.ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", 0, -LIST.ROW_HEIGHT)
    row:SetHeight(LIST.ROW_HEIGHT)
    row.text:SetText(COLOR.MUTED:WrapTextInColorCode("Scanning quest database\226\128\166"))
    scrollChild:SetHeight(LIST.ROW_HEIGHT * 3)
end

local function showFrame()
    local frame = buildMainFrame()
    frame.refreshSortDropdown()
    frame.refreshRangeSliders()
    frame.refreshShowCompleted()
    frame:Show()
    renderLoadingPlaceholder()

    -- Defer the first real layout pass to the next tick: row wrapping needs the scroll child's width, which the scroll frame only resolves after its first layout.
    C_Timer.After(0, function()
        if not frame:IsShown() then return end
        renderList()
    end)
end

local function toggleFrame()
    local frame = buildMainFrame()
    if frame:IsShown() then
        frame:Hide()
    else
        showFrame()
    end
end

-- Click-through from Questie's map icons; only installMapIconHooks leaves the block.
local installMapIconHooks
do
    -- Opens the guide with the quest row expanded, scrolled to, and selected; used by Questie map icon clicks for quests not yet in the log.
    local function openGuideAtQuest(questId)
        showFrame()

        -- showFrame defers its first layout pass one tick, so the jump waits one tick too.
        C_Timer.After(0.1, function()
            if not jumpToQuestInList(questId) then
                print(INTRO_PREFIX .. getQuestName(questId) .. " is not listed with the current filters.")
            end
        end)
    end

    -- Runs after Questie's own pin OnClick. Plain left click on a quest icon opens the quest: in-log quests jump to the native quest log, everything else opens the guide at the quest row. Modified clicks (Shift hide, Ctrl TomTom) and chat-link insertion stay Questie's; a world-map click that changed the shown map was a zoom-to-zone click, detected against the map id captured on mouse-down.
    local function onMapIconClick(pin, button)
        if button ~= "LeftButton" or IsModifierKeyDown() then
            return
        end
        if ChatFrameUtil.GetActiveWindow() then
            return
        end
        local data = pin.data
        local questId = data and data.Id
        if type(questId) ~= "number" or data.Type == "manual" then
            return
        end
        if not pin.miniMapIcon and WorldMapFrame:IsShown()
            and pin.qgPreClickMapId and pin.UiMapID and pin.UiMapID ~= pin.qgPreClickMapId then
            return
        end
        if QuestiePlayer.currentQuestlog[questId] then
            openQuestInLog(questId)
        else
            openGuideAtQuest(questId)
        end
    end

    local hookedPins = {}

    local function hookMapIcon(pin)
        if not pin or hookedPins[pin] then
            return
        end
        hookedPins[pin] = true

        -- OnMouseDown fires before Questie's OnClick can switch maps, capturing which map the player actually clicked on.
        pin:HookScript("OnMouseDown", function(self)
            self.qgPreClickMapId = WorldMapFrame:GetMapID()
        end)
        pin:HookScript("OnClick", onMapIconClick)
    end

    -- Questie pins are pooled named globals (QuestieFrame1..N) created only by QuestieFrame.CreateIconFrame, which QuestieFramePool resolves per call, so a module-table hook catches every future pin; the sweep covers pins that already exist.
    function installMapIconHooks()
        hooksecurefunc(QuestieFrame, "CreateIconFrame", function(frameId)
            hookMapIcon(_G["QuestieFrame" .. frameId])
        end)
        local i = 1
        while _G["QuestieFrame" .. i] do
            hookMapIcon(_G["QuestieFrame" .. i])
            i = i + 1
        end
    end
end

-- Every launcher's click: toggles the window once Questie is ready, otherwise says why it can't open.
local function toggleIfReady()
    if not questieReady then
        print(INTRO_PREFIX .. describeQuestieState())
        return
    end
    toggleFrame()
end

-- Hover text shared by the minimap button and the addon compartment. The zone count reads the warm scan cache only; a hover must never start the expensive database walk.
local function fillLauncherTooltip(tooltip)
    GameTooltip_SetTitle(tooltip, "Questie Guide")
    local zoneName = scanCache.valid and getCurrentZoneName()
    if zoneName then
        local entry = scanCache.byZone[zoneName]
        local count = (entry and entry.stats and entry.stats.count) or 0
        GameTooltip_AddHighlightLine(tooltip, string.format("%d quest%s available in %s.", count, count == 1 and "" or "s", zoneName))
    end
    GameTooltip_AddInstructionLine(tooltip, "Left-click to open the quest panel.")
end

-- /qg toggles the window even when the minimap button is hidden; /qg reset rescues a window dragged off-screen.
SLASH_QUESTIEGUIDE1 = "/questieguide"
SLASH_QUESTIEGUIDE2 = "/qg"
SlashCmdList["QUESTIEGUIDE"] = function(msg)
    local command = strtrim(string.lower(msg or ""))
    if command == "reset" then
        QuestieGuideDB.framePos = nil
        QuestieGuideDB.frameSize = CopyTable(DEFAULTS.frameSize)
        if mainFrame then
            mainFrame:SetSize(DEFAULTS.frameSize.w, DEFAULTS.frameSize.h)
            mainFrame:ClearAllPoints()
            mainFrame:SetPoint("CENTER")
        end
        print(INTRO_PREFIX .. "Window position and size reset.")
        return
    end
    toggleIfReady()
end

-- Key binding entry point; Bindings.xml can only call named globals. The name global labels the entry under Key Bindings, mirroring how Questie registers its Journey toggle.
BINDING_NAME_QUESTIEGUIDE_TOGGLE = "Toggle Quest Panel"

function QuestieGuide_Toggle()
    toggleIfReady()
end

-- The addon compartment calls these through the toc's AddonCompartmentFunc fields, with (addonName, mouseButton) and (addonName, menuButton).
function QuestieGuide_CompartmentClick()
    toggleIfReady()
end

function QuestieGuide_CompartmentEnter(_, menuButton)
    GameTooltip:SetOwner(menuButton, "ANCHOR_LEFT")
    fillLauncherTooltip(GameTooltip)
    GameTooltip:Show()
end

function QuestieGuide_CompartmentLeave()
    GameTooltip:Hide()
end

do
    -- Clicking a level-up toast link opens the window at the named zone. hooksecurefunc on SetItemRef is the same interception Questie's debug-offer links use. Chat history survives a reload, so an old link can be clicked before Questie is ready.
    local ZONE_LINK_PREFIX = "addon:questieguide:zone:"
    hooksecurefunc("SetItemRef", function(link)
        if type(link) ~= "string" or link:sub(1, #ZONE_LINK_PREFIX) ~= ZONE_LINK_PREFIX then
            return
        end
        local areaId = tonumber(link:sub(#ZONE_LINK_PREFIX + 1))
        if not areaId or not questieReady then
            return
        end
        local zoneName = getZoneName(areaId)
        showFrame()

        -- showFrame defers its first layout pass one tick, so the jump waits one tick too.
        C_Timer.After(0.1, function()
            expandAndScrollToZone(zoneName)
        end)
    end)
end

-- Registers the launcher with LibDBIcon so any addon-manager UI (Titan Panel, ChocolateBar, edge-snap bars) can manage it consistently.
local function setupMinimapButton()
    local dataObject = LibStub("LibDataBroker-1.1"):NewDataObject("Questie Guide", {
        type = "launcher",
        text = "Questie Guide",
        icon = ADDON_ICON,
        OnClick = function(_, button)
            if button == "LeftButton" then
                toggleIfReady()
            end
        end,
        OnTooltipShow = fillLauncherTooltip,
    })
    LibStub("LibDBIcon-1.0"):Register("Questie Guide", dataObject, QuestieGuideDB.minimap)
end

local refreshTimer
local function scheduleRefresh()
    if not mainFrame or not mainFrame:IsShown() then
        return
    end
    if refreshTimer then
        refreshTimer:Cancel()
    end
    refreshTimer = C_Timer.NewTimer(0.5, function()
        refreshTimer = nil
        renderList()
    end)
end

-- Item tooltip quest lines; only the hook installer and the index scheduler leave the block.
local installItemTooltipHooks, scheduleItemQuestIndexBuild
do
    -- List every quest the item belongs to that is NOT in the quest log, styled like Questie's active-quest titles (difficulty-colored name via GetColoredQuestName plus a Questie:Colorize'd "(Status)" suffix, the same pattern as its "(Complete)"), so they read as part of Questie's block. Active quests stay Questie's job; adding them here would duplicate its title and objective lines.
    local INDEX_BUILD_DELAY = 5
    local indexBuildScheduled = false

    local ITEM_QUEST_KEYS = { "objectives", "sourceItemId", "requiredSourceItems" }

    -- sessionCache.itemQuests: itemId -> quest ids referencing the item (objectives, quest-provided, required source), built from Questie's compiled quest DB.
    local function buildItemQuestIndex()
        indexBuildScheduled = false
        local index = {}
        local function add(itemId, questId)
            if type(itemId) ~= "number" or itemId <= 0 then
                return
            end
            local list = index[itemId]
            if not list then
                list = {}
                index[itemId] = list
            end

            -- Each quest is processed in one go, so a repeat of the previous entry is the same quest referencing the item in a second role.
            if list[#list] ~= questId then
                list[#list + 1] = questId
            end
        end
        for questId in pairs(QuestieDB.QuestPointers) do
            local fields = QuestieDB.QueryQuest(questId, ITEM_QUEST_KEYS)
            if fields then
                local objectives = fields[1]
                if type(objectives) == "table" then
                    if type(objectives[3]) == "table" then
                        for _, objective in ipairs(objectives[3]) do
                            add((type(objective) == "table" and objective[1]) or objective, questId)
                        end
                    end
                    if type(objectives[6]) == "table" then
                        for _, objective in ipairs(objectives[6]) do
                            if type(objective) == "table" then
                                add(objective[3], questId)
                            end
                        end
                    end
                end
                add(fields[2], questId)
                if type(fields[3]) == "table" then
                    for _, itemId in ipairs(fields[3]) do
                        add(itemId, questId)
                    end
                end
            end
        end
        sessionCache.itemQuests = index
    end

    -- A few seconds after Questie reports ready, so the walk doesn't share a frame with Questie's own available-quest draw at the end of its init.
    function scheduleItemQuestIndexBuild()
        if indexBuildScheduled then
            return
        end
        indexBuildScheduled = true
        C_Timer.After(INDEX_BUILD_DELAY, buildItemQuestIndex)
    end

    -- Classifies a non-log quest for the item tooltip; nil skips the line. Skipped entirely: active quests (Questie renders them), hidden or race/class-gated quests, and permanently unobtainable ones. "Upcoming" covers both level-gated and prereq-blocked quests: not grabbable now, unlocks later.
    local function getItemQuestStatus(questId, playerLevel, currentLog)
        if currentLog[questId] then
            return nil
        end
        if isQuestCompleted(questId) then
            return "Completed Before", "gray"
        end
        if isQuestHidden(questId) or not matchesPlayerFaction(questId) then
            return nil
        end
        local level, requiredLevel, requiredMaxLevel = getEffectiveLevel(questId, playerLevel)
        if not passesLevelCap(level, requiredLevel) or exceedsRequiredMaxLevel(requiredMaxLevel, playerLevel) then
            return nil
        end
        if not meetsRequiredLevel(requiredLevel, playerLevel) then
            return "Upcoming", "yellow"
        end
        if QuestieDB.IsDoable(questId) then
            return "Available", "green"
        end
        if isBlockedByPrereqs(questId) then
            return "Upcoming", "yellow"
        end
        return nil
    end

    -- True when Questie already names this quest on the item tooltip via its start-item line, registered by its own item handler on the same hover before ours runs.
    local function questieShowsStartLine(itemId, questId, profile)
        if not profile.showQuestsInNpcTooltip then
            return false
        end
        local entries = QuestieTooltips.lookupByKey["i_" .. itemId]
        if not entries then
            return false
        end
        for _, entry in pairs(entries) do
            if entry.questId == questId and entry.name then
                return true
            end
        end
        return false
    end

    -- Per-frame dedup mirroring Questie's item handler: the post-call can fire repeatedly for one hover, so re-add only when the tooltip shows a different item or was rebuilt (fewer lines than when we last added).
    local lastTooltipItem = {}

    local function addQuestLinesToItemTooltip(tooltip, itemId)
        local itemQuests = sessionCache.itemQuests
        if tooltip:IsForbidden() or not itemId or not itemQuests then
            return
        end
        local profile = Questie.db.profile
        if not profile.enableTooltips then
            return
        end
        local last = lastTooltipItem[tooltip]
        if last and last.itemId == itemId and tooltip:NumLines() >= last.count then
            return
        end
        local currentLog = QuestiePlayer.currentQuestlog
        local playerLevel = UnitLevel("player")
        local questIds = {}
        local seen = {}
        for _, questId in ipairs(itemQuests[itemId] or {}) do
            seen[questId] = true
            questIds[#questIds + 1] = questId
        end
        local startQuestId = QuestieDB.QueryItemSingle(itemId, "startQuest")
        if startQuestId and startQuestId > 0 and not seen[startQuestId] then
            questIds[#questIds + 1] = startQuestId
        end
        for _, questId in ipairs(questIds) do
            local label, color = getItemQuestStatus(questId, playerLevel, currentLog)

            -- Drop the Available label when it would only repeat Questie's own start-item line; other statuses add information that line lacks.
            if label == "Available" and questId == startQuestId and questieShowsStartLine(itemId, questId, profile) then
                label = nil
            end
            if label then
                local status = Questie:Colorize("(" .. label .. ")", color)
                tooltip:AddLine(getColoredQuestName(questId, profile.enableTooltipsQuestLevel) .. " " .. status)
            end
        end
        lastTooltipItem[tooltip] = { itemId = itemId, count = tooltip:NumLines() }
    end

    -- Hooks the same two tooltips Questie's item handler hooks. Installed from the ready callback, after Questie's Stage 3 registered its own post-call, and post-calls run in registration order, so these lines land under Questie's.
    function installItemTooltipHooks()
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
            if tooltip == GameTooltip or tooltip == ItemRefTooltip then
                addQuestLinesToItemTooltip(tooltip, data and data.id)
            end
        end)
        for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
            tooltip:HookScript("OnHide", function(self)
                lastTooltipItem[self] = nil
            end)
        end
    end
end

-- Level-up toast: quests whose level requirement is exactly the new level, so each quest announces once. Gates mirror the discovery scan (doable, reachable starter, real zone) so the toast only names quests the window would list.
local function announceNewQuests(newLevel)
    if not questieReady then
        return
    end
    local currentLog = QuestiePlayer.currentQuestlog
    local counts, zones, zoneAreaIds = {}, {}, {}
    local total = 0
    for questId in pairs(QuestieDB.QuestPointers) do
        if QuestieDB.QueryQuestSingle(questId, "requiredLevel") == newLevel
            and not currentLog[questId]
            and not isQuestCompleted(questId)
            and hasReachableStarter(questId)
            and QuestieDB.IsDoable(questId) then
            local zoneOrSort = QuestieDB.QueryQuestSingle(questId, "zoneOrSort")
            local level, requiredLevel = getEffectiveLevel(questId, newLevel)
            if zoneOrSort and passesLevelCap(level, requiredLevel) then
                local zoneName = getZoneName(zoneOrSort)
                if not counts[zoneName] then
                    counts[zoneName] = 0
                    zones[#zones + 1] = zoneName
                    zoneAreaIds[zoneName] = zoneOrSort
                end
                counts[zoneName] = counts[zoneName] + 1
                total = total + 1
            end
        end
    end
    if total == 0 then
        return
    end
    table.sort(zones, function(a, b)
        if counts[a] ~= counts[b] then
            return counts[a] > counts[b]
        end
        return a < b
    end)
    local topCount = counts[zones[1]]
    local toast = string.format("%d new quest%s available in %s", topCount, topCount == 1 and "" or "s", zones[1])
    UIErrorsFrame:AddMessage(toast, NORMAL_FONT_COLOR:GetRGB())

    -- Zone names print as clickable addon links that open the window at that zone. Same |Haddon:...|h pattern and link colour Questie uses for its debug offers; a sort-category bucket ("Other") carries no real area id, so it prints plain.
    local parts = {}
    for i = 1, math.min(#zones, 3) do
        local zoneName = zones[i]
        local areaId = zoneAreaIds[zoneName]
        local label = zoneName
        if areaId and areaId > 0 then
            label = COLOR.LINK:WrapTextInColorCode("|Haddon:questieguide:zone:" .. areaId .. "|h[" .. zoneName .. "]|h")
        end
        parts[i] = string.format("%d in %s", counts[zoneName], label)
    end
    local more = #zones > 3 and string.format(" and %d more zones", #zones - 3) or ""
    print(INTRO_PREFIX .. "New quests at level " .. newLevel .. ": " .. table.concat(parts, ", ") .. more .. ".")
end

-- Questie readiness, saved variables and events; nothing leaves this block.
do
    -- Questie calls this after its own state changed. Objective progress only re-renders (the completed section reads live completeness); accept, turn-in and abandon change the zone buckets, so they rescan. The debounce also covers the accept path, where Questie adds the quest to its log right after the callback.
    local function onQuestUpdate(_, _, triggerReason)
        if triggerReason ~= Questie.API.Enums.QuestUpdateTriggerReason.QUEST_UPDATED then
            invalidateScan()
        end
        scheduleRefresh()
    end

    -- Questie rewrites composed rows when a Policy Correction lands after login (its Darkmoon Faire NPC slot waits for the calendar). Item repairs only fix names, which nothing here caches; NPC, object and quest writes can move givers, turn-ins and chains.
    local function onCorrectionApplied(datatype)
        if datatype == "Item" then
            return
        end
        wipe(sessionCache.startInfo)
        wipe(sessionCache.finishInfo)
        wipe(sessionCache.reachable)
        if datatype == "Quest" then
            sessionCache.followers = nil
            sessionCache.itemQuests = nil
            scheduleItemQuestIndexBuild()
        end
        invalidateScan()
        scheduleRefresh()
    end

    -- Runs once Questie.API reports ready: after Questie's Stage 3 installed its tooltip post-calls and filled its quest log and completed set.
    local function onQuestieReady()
        missingQuestieField = findMissingField()
        if missingQuestieField then
            print(INTRO_PREFIX .. describeQuestieState())
            return
        end
        questieReady = true
        installItemTooltipHooks()
        installMapIconHooks()
        hooksecurefunc(QuestieDB, "RefreshAfterCorrectionApply", onCorrectionApplied)
        Questie.API.RegisterForQuestUpdates(onQuestUpdate)
        scheduleItemQuestIndexBuild()
    end

    -- Questie.API is the stable part of Questie; without it the guide stays closed.
    local function registerWithQuestie()
        local api = Questie.API
        if not (api and api.RegisterOnReady and api.RegisterForQuestUpdates and api.Enums and api.Enums.QuestUpdateTriggerReason) then
            missingQuestieField = "Questie.API"
            return
        end
        api.RegisterOnReady(onQuestieReady)
    end

    -- Fills every missing or mistyped saved key from the defaults, nested tables included, so a new filter key arrives in old saved variables too.
    local function applyDefaults(db, defaults)
        for key, default in pairs(defaults) do
            if type(db[key]) ~= type(default) then
                db[key] = type(default) == "table" and CopyTable(default) or default
            elseif type(default) == "table" then
                applyDefaults(db[key], default)
            end
        end
    end

    local function isKnownOption(options, value)
        for _, opt in ipairs(options) do
            if opt.value == value then
                return true
            end
        end
        return false
    end

    local function loadSavedVariables()
        if type(QuestieGuideDB) ~= "table" then
            QuestieGuideDB = {}
        end
        applyDefaults(QuestieGuideDB, DEFAULTS)
        QuestieGuideDB.levelBelow = clampRange(QuestieGuideDB.levelBelow)
        QuestieGuideDB.levelAbove = clampRange(QuestieGuideDB.levelAbove)
        if not isKnownOption(SORT_BY_OPTIONS, QuestieGuideDB.sortMode) then
            QuestieGuideDB.sortMode = DEFAULTS.sortMode
        end
        if not isKnownOption(SORT_DIR_OPTIONS, QuestieGuideDB.sortDir) then
            QuestieGuideDB.sortDir = DEFAULTS.sortDir
        end
    end

    local function printIntroOnce()
        if QuestieGuideDB.introSeen then
            return
        end
        QuestieGuideDB.introSeen = true
        print(INTRO_PREFIX .. "Finds every quest you can pick up and rates the best zones for your level.")
        print(INTRO_PREFIX .. "Left-click the minimap button to open the quest panel, or type /qg.")
    end

    -- Quest events come from Questie (onQuestUpdate); only the player's own level and location are native events.
    local events = CreateFrame("Frame")
    events:RegisterEvent("ADDON_LOADED")
    events:RegisterEvent("PLAYER_LOGIN")
    events:RegisterEvent("PLAYER_LEVEL_UP")
    events:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    events:SetScript("OnEvent", function(_, event, arg)
        if event == "PLAYER_LEVEL_UP" then
            invalidateScan()
            scheduleRefresh()
            local newLevel = tonumber(arg) or UnitLevel("player")

            -- Waits out the level-up celebration frame spike before walking the quest DB.
            C_Timer.After(1, function()
                announceNewQuests(newLevel)
            end)
        elseif event == "ZONE_CHANGED_NEW_AREA" then
            -- Zone changes only move the current-zone header marker, which reads location at render, so the scan cache survives.
            scheduleRefresh()
        elseif event == "ADDON_LOADED" and arg == ADDON_NAME then
            loadSavedVariables()
            registerWithQuestie()
        elseif event == "PLAYER_LOGIN" then
            setupMinimapButton()
            printIntroOnce()
        end
    end)
end
