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
    },
    framePos = nil,
    frameSize = { w = 680, h = 620 },
    zoneCollapsed = {},
    groupCollapsed = {},
    minimap = { hide = false, minimapPos = 215 },
    useQuestieLevelRange = false,
    levelBelow = 5,
    levelAbove = 5,
    showCompleted = true,
    routeSort = true,
}

local LEVEL_RANGE_MIN = 0
local LEVEL_RANGE_MAX = 10

local INTRO_PREFIX = "|cffffff00[Questie Guide]:|r "

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

-- Layout grid: 8px outer chrome, 4px sub-grid for compact list rows.
local SPACING = {
    XS = 4,
    SM = 8,
    MD = 16,
    LG = 24,
}

local FRAME_WIDTH = 680
local FRAME_HEIGHT = 620

-- Split view: fixed-width options pane left, quest list fills the right pane. The dialog border art consumes the outer ~8px of PAD_X, so an 8px gutter renders the same visible spacing as the 16px border padding.
local OPTIONS_PANE_WIDTH = 260
local PANE_GAP = SPACING.SM
local FRAME_MIN_WIDTH = 640

-- Outer frame padding and section rhythm. Panel border to content is PAD_X on the sides and PAD_BOTTOM below; the pane gutter (PANE_GAP) matches the padding that stays visible beside the border art. Section boxes are separated by 24 (16 + 8) so each floating label clears the box above it.
local PAD_X = SPACING.MD
local PAD_TOP = 48               -- clears the dialog-box-header banner above the first section.
local PAD_BOTTOM = SPACING.MD
local SECTION_GAP = SPACING.LG   -- between section boxes; clears the floating label.
local ELEMENT_GAP = SPACING.SM
local SCROLLBAR_RESERVE = SPACING.LG
local SECTION_INNER_PAD = SPACING.SM + SPACING.XS  -- 12: inset between section border and body; clears the border art.
local SECTION_LABEL_LIFT = SPACING.SM              -- floating label bottom above the box top edge.

-- Options rows: sliders and dropdowns fill the pane width and stack vertically.
local ROW_EDGE_PAD = 0
local DROPDOWN_ROW_H = 28                  -- vertical room a dropdown row occupies.

-- List rhythm (rows use the 4px sub-grid for density), one table because renderList sits at Lua 5.1's 60-upvalue closure cap and each grouped constant frees a slot. Gap tiers: each tier visibly looser than the one nested below it, 4px between quest rows inside a subcategory, 8px between subcategory headers within a zone, 16px between zones.
local LIST = {
    ROW_HEIGHT = SPACING.MD,
    SUBHEADER_HEIGHT = SPACING.MD,
    HEADER_HEIGHT = SPACING.LG,
    ROW_GAP = SPACING.XS,
    GROUP_GAP = SPACING.SM,
    ZONE_GAP = SPACING.MD,
    INDENT_STEP = SPACING.MD,
}

-- Native quest log header treatment, mirroring Classic Era's QuestLogFrame (Blizzard_UIPanels_Game/Vanilla/QuestLogFrame.xml + .lua): a 16x16 red plus/minus toggle at x=3 with the additive hilight on hover, text 20px in from the row's left edge, header grey text that whitens on mouse-over (QuestDifficultyColors / QuestDifficultyHighlightColors "header").
local HEADER_TEXT_INSET = 20
local HEADER_TOGGLE_INSET = 3
local HEADER_R, HEADER_G, HEADER_B = 0.7, 0.7, 0.7
local TOGGLE_PLUS = "Interface\\Buttons\\UI-PlusButton-Up"
local TOGGLE_MINUS = "Interface\\Buttons\\UI-MinusButton-Up"
local TOGGLE_HILIGHT = "Interface\\Buttons\\UI-PlusButton-Hilight"

-- Wrapping: row height grows with wrapped text; LINE_SPACING tunes legibility.
local ROW_PAD_V = 2
local LINE_SPACING = 3

local MAX_CHAIN_DEPTH = 12

-- Classic Era (1.15.x) caps at 60; reject post-vanilla quests Questie may ship.
local CLASSIC_MAX_LEVEL = 60

local function passesClassicCaps(level, requiredLevel)
    return level <= CLASSIC_MAX_LEVEL and (requiredLevel or 0) <= CLASSIC_MAX_LEVEL
end

-- Questie modules; resolved lazily because Questie loads after us.
local QuestieDB
local QuestieLib
local ZoneDB
local QuestiePlayer
local QuestXP
local QuestieMap
local QuestieLink
local QuestieCorrections
local QuestieTooltips

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
-- Quest carrying the native-quest-log selection look; moved by row left-clicks, list jumps, and Questie map icon clicks.
local selectedQuestId
local getQuestTagLabel
local getQuestXp
local formatNumber

local QUEST_TAG_LABELS = {
    [1] = "Elite",
    [41] = "PvP",
    [62] = "Raid",
    [81] = "Dungeon",
}

local QUEST_TAG_COLORS = {
    Elite = "ff8000",
    Dungeon = "a335ee",
    Raid = "ff4040",
    PvP = "ffd200",
}

-- Native game color hex codes. RGB values mirror Classic Era's QuestDifficultyColors (Blizzard_FrameXMLBase/Classic/Constants.lua) and C_UIColor.GetColors() font color globals (HIGHLIGHT/GRAY/YELLOW/GREEN).
local COLOR = {
    WHITE  = "|cffffffff",
    GREY   = "|cff7f7f7f",
    YELLOW = "|cffffff00",
    GREEN  = "|cff00ff00",
    GOLD   = "|cffffd200",
    ORANGE = "|cffff7f00",
    RED    = "|cffff1a1a",
    BLUE   = "|cffaaaaff",
}

local function getZoneCollapsed()
    return (QuestieGuideDB and QuestieGuideDB.zoneCollapsed) or {}
end

local function getGroupCollapsed()
    return (QuestieGuideDB and QuestieGuideDB.groupCollapsed) or {}
end

local function loadQuestie()
    if QuestieDB and QuestieDB.QuestPointers then
        return true
    end
    local loader = _G.QuestieLoader
    if not loader then
        return false
    end
    QuestieDB = loader:ImportModule("QuestieDB")
    QuestieLib = loader:ImportModule("QuestieLib")
    ZoneDB = loader:ImportModule("ZoneDB")
    QuestiePlayer = loader:ImportModule("QuestiePlayer")
    QuestXP = loader:ImportModule("QuestXP")
    QuestieMap = loader:ImportModule("QuestieMap")
    QuestieLink = loader:ImportModule("QuestieLink")
    QuestieCorrections = loader:ImportModule("QuestieCorrections")
    QuestieTooltips = loader:ImportModule("QuestieTooltips")
    return QuestieDB ~= nil and QuestieDB.QuestPointers ~= nil
end

-- The catch-all bucket for quests whose zoneOrSort is a sort category rather than a real area id. Pinned to the bottom of the list by sortZones because it's mostly noise (class quests, faction quests, profession quests, ...).
local OTHER_ZONE_NAME = "Other"

-- zoneOrSort > 0 is a Blizzard area ID; <= 0 is a sort category we collapse into "Other". Names are static client data, and the scan plus the chain projection resolve them for thousands of quests per rescan, so results cache for the session.
local zoneNameCache = {}

local function getZoneName(zoneOrSort)
    if not zoneOrSort or zoneOrSort <= 0 then
        return OTHER_ZONE_NAME
    end
    local cached = zoneNameCache[zoneOrSort]
    if cached then
        return cached
    end
    local name
    if C_Map and C_Map.GetAreaInfo then
        name = C_Map.GetAreaInfo(zoneOrSort)
    end
    if not name and ZoneDB then
        name = ZoneDB:GetLocalizedDungeonName(zoneOrSort)
    end
    name = name or ("Zone " .. zoneOrSort)
    zoneNameCache[zoneOrSort] = name
    return name
end

-- Mirrors the hidden-quest exclusions IsDoable applies before its prereq logic: Questie's curated blacklist, quests the player hid manually, and IsDoable's own autoBlacklist verdicts. Needed wherever quests are classified after IsDoable already said no (missing-prereq rows, chain projection), because those paths never receive IsDoable's verdict on hidden state and would otherwise resurrect blacklisted or inactive-event quests.
local function isQuestHidden(questId)
    if QuestieCorrections and QuestieCorrections.hiddenQuests and QuestieCorrections.hiddenQuests[questId] then
        return true
    end
    if QuestieDB.autoBlacklist and QuestieDB.autoBlacklist[questId] then
        return true
    end
    local char = _G.Questie and _G.Questie.db and _G.Questie.db.char
    return (char and char.hidden and char.hidden[questId]) and true or false
end

-- Resolve level lookup by name because Questie renamed GetTbcLevel to GetEffectiveQuestLevel in Aug 2026; fall back to raw DB fields so a future rename degrades instead of erroring.
local function queryQuestLevels(questId, playerLevel)
    local lookup = QuestieLib.GetEffectiveQuestLevel or QuestieLib.GetTbcLevel
    if lookup then
        return lookup(questId, playerLevel)
    end
    local level = QuestieDB.QueryQuestSingle(questId, "questLevel")
    local requiredLevel = QuestieDB.QueryQuestSingle(questId, "requiredLevel") or 0

    -- Mirror Questie rule that questLevel -1 means the quest scales to player level.
    if level == -1 then
        local currentLevel = playerLevel or UnitLevel("player")
        if requiredLevel > currentLevel then
            level = requiredLevel
        else
            level = currentLevel
            requiredLevel = currentLevel
        end
    end
    return level, requiredLevel, QuestieDB.QueryQuestSingle(questId, "requiredMaxLevel")
end

local function getEffectiveLevel(questId, playerLevel)
    local level, requiredLevel, requiredMaxLevel = queryQuestLevels(questId, playerLevel)
    requiredMaxLevel = requiredMaxLevel or 0
    if level and level > 0 then
        return level, requiredLevel or 0, requiredMaxLevel
    end
    return requiredLevel or 0, requiredLevel or 0, requiredMaxLevel
end

local function getQuestName(questId)
    return QuestieDB.QueryQuestSingle(questId, "name") or ("Quest " .. questId)
end

-- Picks a spawn from Questie's per-zone spawn table: prefer the quest's own zone (zoneOrSort) so the labeled location matches the bucket; fall back to the smallest area id when no spawn lives there (deterministic, but arbitrary).
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
    return preferredZoneId or fallbackZoneId, preferredSpawn or fallbackSpawn
end

local function getPreferredZoneId(questId)
    local questZone = QuestieDB.QueryQuestSingle(questId, "zoneOrSort")
    return (questZone and questZone > 0) and questZone or nil
end

-- Returns name, zoneName, {x, y}, areaId for the quest's start source. Questie's `startedBy` is a 3-tuple: [1] NPC ids, [2] object ids, [3] item ids. Object/item start (no NPC giver): use the quest's own zone as a best-effort location and "Quest Item" as the generic giver name.
local function computeQuestStartInfo(questId)
    if not QuestieDB then
        return nil, nil, nil, nil
    end
    local startedBy = QuestieDB.QueryQuestSingle(questId, "startedBy")
    if type(startedBy) ~= "table" then
        return nil, nil, nil, nil
    end

    local npcIds = startedBy[1]
    if type(npcIds) == "table" and npcIds[1] and QuestieDB.GetNPC then
        local npc = QuestieDB:GetNPC(npcIds[1])
        if npc then
            if type(npc.spawns) ~= "table" then
                return npc.name, nil, nil, nil
            end
            local bestZoneId, bestSpawn = pickPreferredSpawn(npc.spawns, getPreferredZoneId(questId))
            if not bestZoneId then
                return npc.name, nil, nil, nil
            end
            return npc.name, getZoneName(bestZoneId), bestSpawn, bestZoneId
        end
    end

    local hasObjectStart = type(startedBy[2]) == "table" and startedBy[2][1] ~= nil
    local hasItemStart = type(startedBy[3]) == "table" and startedBy[3][1] ~= nil
    if hasObjectStart or hasItemStart then
        local questZone = QuestieDB.QueryQuestSingle(questId, "zoneOrSort")
        if questZone and questZone > 0 then
            return "Quest Item", getZoneName(questZone), nil, questZone
        end
        return "Quest Item", nil, nil, nil
    end

    return nil, nil, nil, nil
end

-- Start info is static DB data, but the scan resolves it for every doable quest on every rescan (accept, turn-in, level-up) and quest row tables are rebuilt each scan, so a per-row cache would not survive. Cache per questId for the session instead; only compute when QuestieDB is actually loaded so a nil result is never frozen in.
local startInfoCache = {}

local function getQuestStartInfo(questId)
    local cached = startInfoCache[questId]
    if cached then
        return cached.npcName, cached.zoneName, cached.spawn, cached.areaId
    end
    local npcName, zoneName, spawn, areaId = computeQuestStartInfo(questId)
    if QuestieDB then
        startInfoCache[questId] = { npcName = npcName, zoneName = zoneName, spawn = spawn, areaId = areaId }
    end
    return npcName, zoneName, spawn, areaId
end

-- Row and tooltip callers keep the table shape they already use; it now just fronts the session cache.
local function resolveStartInfo(quest)
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

-- Returns name, zoneName, {x, y}, areaId for the quest's turn-in target. Questie's `finishedBy` is a 2-tuple: [1] NPC ids, [2] object ids. The turn-in location only exists in Questie's data; no native API exposes it.
local function computeQuestFinishInfo(questId)
    if not QuestieDB then
        return nil, nil, nil, nil
    end
    local finishedBy = QuestieDB.QueryQuestSingle(questId, "finishedBy")
    if type(finishedBy) ~= "table" then
        return nil, nil, nil, nil
    end

    local npcIds = finishedBy[1]
    if type(npcIds) == "table" and npcIds[1] and QuestieDB.GetNPC then
        local npc = QuestieDB:GetNPC(npcIds[1])
        if npc then
            if type(npc.spawns) ~= "table" then
                return npc.name, nil, nil, nil
            end
            local bestZoneId, bestSpawn = pickPreferredSpawn(npc.spawns, getPreferredZoneId(questId))
            if not bestZoneId then
                return npc.name, nil, nil, nil
            end
            return npc.name, getZoneName(bestZoneId), bestSpawn, bestZoneId
        end
    end

    local objectIds = finishedBy[2]
    if type(objectIds) == "table" and objectIds[1] and QuestieDB.QueryObjectSingle then
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

-- Turn-in targets are static DB data like start info; cache per questId for the session and only freeze results once QuestieDB is loaded.
local finishInfoCache = {}

local function getQuestFinishInfo(questId)
    local cached = finishInfoCache[questId]
    if cached then
        return cached.npcName, cached.zoneName, cached.spawn, cached.areaId
    end
    local npcName, zoneName, spawn, areaId = computeQuestFinishInfo(questId)
    if QuestieDB then
        finishInfoCache[questId] = { npcName = npcName, zoneName = zoneName, spawn = spawn, areaId = areaId }
    end
    return npcName, zoneName, spawn, areaId
end

local HIGHLIGHT_PULSE_SCALE = 1.25
local HIGHLIGHT_PULSE_DIM = 0.55
local HIGHLIGHT_HALF_DURATION = 0.45
local HIGHLIGHT_PULSE_COUNT = 3

-- Combined scale + alpha "breathing" pulse on every Questie icon for the quest. Scale and alpha run in parallel so the pin grows brighter at the peak; using SetLooping("REPEAT") lets WoW reset the frame state between cycles cleanly, which avoids the velocity discontinuities pure scale animation suffered from.
local function highlightQuestOnMap(questId)
    if not QuestieMap or not QuestieMap.GetFramesForQuest then
        return
    end
    local frames = QuestieMap:GetFramesForQuest(questId)
    if not frames then
        return
    end
    for _, frame in pairs(frames) do
        if frame and frame.CreateAnimationGroup and frame:IsObjectType("Frame") then
            local pulse = frame.wtqPulse
            if not pulse then
                pulse = frame:CreateAnimationGroup()
                pulse:SetLooping("REPEAT")

                local scaleUp = pulse:CreateAnimation("Scale")
                scaleUp:SetOrder(1)
                scaleUp:SetDuration(HIGHLIGHT_HALF_DURATION)
                scaleUp:SetSmoothing("IN_OUT")
                if scaleUp.SetScale then scaleUp:SetScale(HIGHLIGHT_PULSE_SCALE, HIGHLIGHT_PULSE_SCALE) end
                if scaleUp.SetScaleFrom then scaleUp:SetScaleFrom(1, 1) end
                if scaleUp.SetScaleTo then scaleUp:SetScaleTo(HIGHLIGHT_PULSE_SCALE, HIGHLIGHT_PULSE_SCALE) end

                local fadeDown = pulse:CreateAnimation("Alpha")
                fadeDown:SetOrder(1)
                fadeDown:SetDuration(HIGHLIGHT_HALF_DURATION)
                fadeDown:SetSmoothing("IN_OUT")
                if fadeDown.SetChange then fadeDown:SetChange(HIGHLIGHT_PULSE_DIM - 1) end
                if fadeDown.SetFromAlpha then fadeDown:SetFromAlpha(1) end
                if fadeDown.SetToAlpha then fadeDown:SetToAlpha(HIGHLIGHT_PULSE_DIM) end

                local scaleDown = pulse:CreateAnimation("Scale")
                scaleDown:SetOrder(2)
                scaleDown:SetDuration(HIGHLIGHT_HALF_DURATION)
                scaleDown:SetSmoothing("IN_OUT")
                if scaleDown.SetScale then scaleDown:SetScale(1 / HIGHLIGHT_PULSE_SCALE, 1 / HIGHLIGHT_PULSE_SCALE) end
                if scaleDown.SetScaleFrom then scaleDown:SetScaleFrom(HIGHLIGHT_PULSE_SCALE, HIGHLIGHT_PULSE_SCALE) end
                if scaleDown.SetScaleTo then scaleDown:SetScaleTo(1, 1) end

                local fadeUp = pulse:CreateAnimation("Alpha")
                fadeUp:SetOrder(2)
                fadeUp:SetDuration(HIGHLIGHT_HALF_DURATION)
                fadeUp:SetSmoothing("IN_OUT")
                if fadeUp.SetChange then fadeUp:SetChange(1 - HIGHLIGHT_PULSE_DIM) end
                if fadeUp.SetFromAlpha then fadeUp:SetFromAlpha(HIGHLIGHT_PULSE_DIM) end
                if fadeUp.SetToAlpha then fadeUp:SetToAlpha(1) end

                pulse:SetScript("OnLoop", function(self)
                    self._wtqCount = (self._wtqCount or 0) + 1
                    if self._wtqCount >= HIGHLIGHT_PULSE_COUNT then
                        self:Stop()
                        self._wtqCount = 0
                    end
                end)

                frame.wtqPulse = pulse
            end
            pulse:Stop()
            pulse._wtqCount = 0
            pulse:Play()
        end
    end
end

-- Some Classic Era UI maps (notably dungeon interiors) have no art layers and crash Blizzard_MapCanvas when passed to SetMapID. Walk up to the first ancestor that actually has art so we open something instead of erroring.
local function resolveRenderableMapId(uiMapId)
    if not uiMapId or not C_Map or not C_Map.GetMapArtLayers then
        return nil
    end
    local current = uiMapId
    for _ = 1, 5 do
        local layers = C_Map.GetMapArtLayers(current)
        if layers and #layers > 0 then
            return current
        end
        local mapInfo = C_Map.GetMapInfo and C_Map.GetMapInfo(current)
        if not mapInfo or not mapInfo.parentMapID or mapInfo.parentMapID == 0 or mapInfo.parentMapID == current then
            return nil
        end
        current = mapInfo.parentMapID
    end
    return nil
end

local function openMapForQuest(quest)
    if not loadQuestie() then
        return
    end
    local startInfo = resolveStartInfo(quest)
    if not startInfo.areaId or not ZoneDB or not ZoneDB.GetUiMapIdByAreaId then
        if WorldMapFrame and not WorldMapFrame:IsShown() then
            ShowUIPanel(WorldMapFrame)
        end
        return
    end
    local uiMapId = ZoneDB:GetUiMapIdByAreaId(startInfo.areaId)
    if not uiMapId then
        return
    end
    local renderMapId = resolveRenderableMapId(uiMapId)
    if not renderMapId then
        if WorldMapFrame and not WorldMapFrame:IsShown() then
            ShowUIPanel(WorldMapFrame)
        end
        return
    end
    if not WorldMapFrame:IsShown() then
        ShowUIPanel(WorldMapFrame)
    end
    if WorldMapFrame.SetMapID then
        WorldMapFrame:SetMapID(renderMapId)
    end
    -- Classic Era 1.15 has no native user waypoints: C_Map.SetUserWaypoint, UiMapPoint, and C_SuperTrack are retail-only per the classic_era API docs, so the Questie icon pulse below is the native "here it is" cue. TomTom fills the gap when installed; spawn coords belong to uiMapId's coordinate space, so only when we're actually showing that map.
    if renderMapId == uiMapId and startInfo.spawn and type(TomTom) == "table" and TomTom.AddWaypoint then
        pcall(function()
            TomTom:AddWaypoint(uiMapId, startInfo.spawn[1] / 100, startInfo.spawn[2] / 100, {
                title = quest.name or getQuestName(quest.id),
                persistent = false,
                minimap = true,
                world = true,
            })
        end)
    end
    -- Questie draws icons asynchronously after SetMapID, so wait a tick before pulsing.
    C_Timer.After(0.2, function()
        highlightQuestOnMap(quest.id)
    end)
end

local function isQuestCompleted(questId)
    if IsQuestFlaggedCompleted then
        return IsQuestFlaggedCompleted(questId) == true
    end
    return false
end

local function clampRange(value)
    if type(value) ~= "number" then
        return nil
    end
    value = math.floor(value + 0.5)
    if value < LEVEL_RANGE_MIN then return LEVEL_RANGE_MIN end
    if value > LEVEL_RANGE_MAX then return LEVEL_RANGE_MAX end
    return value
end

local function getLevelRange()
    local db = QuestieGuideDB or {}
    local below = clampRange(db.levelBelow) or DEFAULTS.levelBelow
    local above = clampRange(db.levelAbove) or DEFAULTS.levelAbove
    return below, above
end

-- Quest passes when its effective level sits in [player - below, player + above].
local function isLevelInBand(questLevel, playerLevel, below, above)
    if not playerLevel then
        return true
    end
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

-- True when the quest would render grey on the player (below Blizzard's difficulty floor — quest level is more than greenRange below the player). Used to exclude outgrown quests from the discovery sections.
local function isQuestTrivialForPlayer(questLevel, playerLevel)
    if not playerLevel or not questLevel or questLevel <= 0 then
        return false
    end
    local greenRange = (GetQuestGreenRange and GetQuestGreenRange("player")) or 5
    return (playerLevel - questLevel) > greenRange
end

-- True when the quest would render red on the player (levelDiff >= 5, the "impossible" tier in GetRelativeDifficultyColor, Classic Era's Vanilla/UIParent.lua). Red quests never count toward the XP figures, even when the slider band reaches them.
local function isQuestRedForPlayer(questLevel, playerLevel)
    if not playerLevel or not questLevel or questLevel <= 0 then
        return false
    end
    return (questLevel - playerLevel) >= 5
end

-- True when the quest's difficulty color for the player is yellow or green. Mirrors GetRelativeDifficultyColor in Classic Era's Vanilla/UIParent.lua: yellow covers levelDiff -2..+2, green covers -greenRange..-3. Orange/red (levelDiff >= 3) and grey (below -greenRange) are excluded.
local function isQuestYellowOrGreen(questLevel, playerLevel)
    if not playerLevel then
        return true
    end
    if not questLevel or questLevel <= 0 then
        return true
    end
    local greenRange = (GetQuestGreenRange and GetQuestGreenRange("player")) or 5
    if (playerLevel - questLevel) > greenRange then
        return false
    end
    if (questLevel - playerLevel) >= 3 then
        return false
    end
    return true
end

-- QuestieDB.IsDoable does not enforce requiredLevel, so we gate it explicitly.
local function meetsRequiredLevel(requiredLevel, playerLevel)
    if not playerLevel then
        return true
    end
    if not requiredLevel or requiredLevel <= 0 then
        return true
    end
    return requiredLevel <= playerLevel
end

-- Mirrors AvailableQuests.IsLevelRequirementsFulfilled: a quest carrying a requiredMaxLevel is permanently unobtainable once the player outlevels it. IsDoable does not check this either.
local function exceedsRequiredMaxLevel(requiredMaxLevel, playerLevel)
    if not playerLevel or not requiredMaxLevel or requiredMaxLevel == 0 then
        return false
    end
    return playerLevel > requiredMaxLevel
end

-- Mirrors _AddStarter in Questie's AvailableQuests module: a quest only gets a map icon when at least one approachable starter exists. NPC givers hostile to the player's faction are unreachable, and NPC or object givers need at least one spawn or waypoint in the world. Item-started quests count as reachable because Questie draws them at their drop sources. Anything failing this can never be picked up, so it must not be listed or counted. Reachability is static per character (DB plus faction), so results cache for the session.
local reachableStarterCache = {}

local function hasReachableStarter(questId)
    local cached = reachableStarterCache[questId]
    if cached ~= nil then
        return cached
    end
    -- Older Questie builds without the single-field queries get the permissive answer instead of an empty panel.
    if not QuestieDB.QueryNPCSingle or not QuestieDB.QueryObjectSingle then
        return true
    end
    local reachable = false
    local startedBy = QuestieDB.QueryQuestSingle(questId, "startedBy")
    if type(startedBy) == "table" then
        local playerFaction = UnitFactionGroup("player")
        local npcIds = startedBy[1]
        if type(npcIds) == "table" then
            for _, npcId in ipairs(npcIds) do
                local friendlyToFaction = QuestieDB.QueryNPCSingle(npcId, "friendlyToFaction")
                local hostile = (playerFaction == "Alliance" and friendlyToFaction == "H")
                    or (playerFaction == "Horde" and friendlyToFaction == "A")
                if not hostile then
                    local spawns = QuestieDB.QueryNPCSingle(npcId, "spawns")
                    if type(spawns) == "table" and next(spawns) then
                        reachable = true
                        break
                    end
                    local waypoints = QuestieDB.QueryNPCSingle(npcId, "waypoints")
                    if type(waypoints) == "table" and next(waypoints) then
                        reachable = true
                        break
                    end
                end
            end
        end
        if not reachable and type(startedBy[2]) == "table" then
            for _, objectId in ipairs(startedBy[2]) do
                local spawns = QuestieDB.QueryObjectSingle(objectId, "spawns")
                if type(spawns) == "table" and next(spawns) then
                    reachable = true
                    break
                end
            end
        end
        if not reachable and type(startedBy[3]) == "table" and startedBy[3][1] then
            reachable = true
        end
    end
    reachableStarterCache[questId] = reachable
    return reachable
end

-- True when the quest is not gated by the player's race or class.
local function matchesPlayerFaction(questId)
    if not QuestiePlayer then
        return true
    end
    local requiredRaces = QuestieDB.QueryQuestSingle(questId, "requiredRaces")
    if requiredRaces and QuestiePlayer.HasRequiredRace and not QuestiePlayer.HasRequiredRace(requiredRaces) then
        return false
    end
    local requiredClasses = QuestieDB.QueryQuestSingle(questId, "requiredClasses")
    if requiredClasses and QuestiePlayer.HasRequiredClass and not QuestiePlayer.HasRequiredClass(requiredClasses) then
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

-- Reverse prereq index: preQuestId -> { followerQuestId, ... }. Built once per session because the quest DB is static; only completion state changes at runtime. Negative preQuestGroup ids are indexed by absolute value so those followers stay discoverable through that edge.
local followerIndex

local function ensureFollowerIndex()
    if followerIndex then
        return followerIndex
    end
    followerIndex = {}
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
local function collectZoneFollowups(zoneName, seeds, currentLog, playerLevel, passesLevelGate)
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
                        if passesClassicCaps(level, requiredLevel)
                            and not exceedsRequiredMaxLevel(requiredMaxLevel, playerLevel)
                            and passesLevelGate(level)
                            and not isQuestTrivialForPlayer(level, playerLevel)
                            and not isQuestHidden(followerId)
                            and hasReachableStarter(followerId)
                            and matchesPlayerFaction(followerId)
                            and not (QuestieDB.IsRepeatable and QuestieDB.IsRepeatable(followerId))
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

-- Zone name the player is standing in, per Questie's area mapping; nil when unresolved.
local function getCurrentZoneName()
    if not QuestiePlayer or not QuestiePlayer.GetCurrentZoneId then
        return nil
    end
    local areaId = QuestiePlayer:GetCurrentZoneId()
    if not areaId or areaId <= 0 then
        return nil
    end
    return getZoneName(areaId)
end

-- Player position in Questie's 0-100 zone coordinate space, only while the player is actually in the zone; the route seed falls back to the lowest-level quest otherwise.
local function getPlayerRouteStart(zoneName)
    if getCurrentZoneName() ~= zoneName then
        return nil
    end
    local mapId = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local pos = mapId and C_Map.GetPlayerMapPosition(mapId, "player")
    if not pos then
        return nil
    end
    return pos.x * 100, pos.y * 100
end

-- Greedy nearest-neighbor pickup route over the actionable rows whose giver has coordinates in this zone, so the bucket reads top-to-bottom as a travel path. In-log, blocked, out-of-range and coordinate-less rows keep their level order behind the routed block; spawn coordinates only compare within one zone's map space, hence the giver-zone check.
local function applyRouteOrder(list, zoneName)
    local routable, rest = {}, {}
    for _, q in ipairs(list) do
        local info = resolveStartInfo(q)
        if not q.blocked and not q.outOfRange and not q.inLog and info.spawn and info.zoneName == zoneName then
            routable[#routable + 1] = q
        else
            rest[#rest + 1] = q
        end
    end
    if #routable >= 2 then
        local ordered = {}
        local x, y = getPlayerRouteStart(zoneName)
        if not x then
            ordered[1] = table.remove(routable, 1)
            x, y = ordered[1].startInfo.spawn[1], ordered[1].startInfo.spawn[2]
        end
        while #routable > 0 do
            local bestIndex, bestDist
            for i, q in ipairs(routable) do
                local dx = q.startInfo.spawn[1] - x
                local dy = q.startInfo.spawn[2] - y
                local dist = dx * dx + dy * dy
                if not bestDist or dist < bestDist then
                    bestDist = dist
                    bestIndex = i
                end
            end
            local nextQuest = table.remove(routable, bestIndex)
            ordered[#ordered + 1] = nextQuest
            x, y = nextQuest.startInfo.spawn[1], nextQuest.startInfo.spawn[2]
        end
        -- Number the stops so rows can render "1. 2. 3."; routeZone scopes the number to the zone whose route it belongs to, because quest tables are shared across zone buckets.
        for i, q in ipairs(ordered) do
            q.routeIndex = i
            q.routeZone = zoneName
        end
        routable = ordered
    end
    for i, q in ipairs(routable) do
        list[i] = q
    end
    for i, q in ipairs(rest) do
        list[#routable + i] = q
    end
end

-- Buckets every quest into its zone. Expensive; caller should cache the result.
local function scanQuestsByZone()
    if not loadQuestie() then
        return {}, {}
    end
    local playerLevel = UnitLevel("player")
    local currentLog = (QuestiePlayer and QuestiePlayer.currentQuestlog) or {}
    local useQuestieLevelRange = QuestieGuideDB and QuestieGuideDB.useQuestieLevelRange and true or false
    local below, above = getLevelRange()
    local routeSort = not QuestieGuideDB or QuestieGuideDB.routeSort ~= false

    -- Slider on: explicit ± band centered on player level, minus red quests — an "above" of 5 would otherwise pull in +5 reds. Slider bypassed (useQuestieLevelRange): consider only quests Blizzard would color yellow or green for the player — the "worth doing now" tier. Gate failures render dimmed downstream and contribute no XP.
    local function passesLevelGate(level)
        if useQuestieLevelRange then
            return isQuestYellowOrGreen(level, playerLevel)
        end
        return isLevelInBand(level, playerLevel, below, above)
            and not isQuestRedForPlayer(level, playerLevel)
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

    -- Quests already in the player's log bypass the level band (if they accepted it, they want to see it regardless of how far it has drifted from their current level). They render inside the pickup buckets with an [In Questlog] label, split by giver zone like every other quest.
    for questId in pairs(currentLog) do
        local zoneOrSort = QuestieDB.QueryQuestSingle(questId, "zoneOrSort")
        local level, requiredLevel = getEffectiveLevel(questId, playerLevel)
        if zoneOrSort and passesClassicCaps(level, requiredLevel) then
            local questZoneName = getZoneName(zoneOrSort)
            local _, giverZoneName = getQuestStartInfo(questId)
            local quest = {
                id = questId,
                level = level,
                name = getQuestName(questId),
                -- Questie's QuestXP already applies the vanilla level reduction, so grey log quests contribute their real reduced XP.
                xp = getQuestXp(questId),
                tag = getQuestTagLabel(questId),
                inLog = true,
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
            -- The user's level slider (passesLevelGate) used to hard-filter here. We now keep out-of-range quests in the list and tag them so renderList can fade their rows; only the hard caps, the required-level gates, grey (trivial) quests, and quests without a reachable starter still exclude quests entirely from the discovery sections.
            if passesClassicCaps(level, requiredLevel)
                and meetsRequiredLevel(requiredLevel, playerLevel)
                and not exceedsRequiredMaxLevel(requiredMaxLevel, playerLevel)
                and not isQuestTrivialForPlayer(level, playerLevel)
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
        -- pickedUpElsewhere never routes: its givers live in other zones by definition, so their coordinates don't compare in this zone's map space.
        if routeSort then
            applyRouteOrder(entry.available, zoneName)
        end

        -- Stats power both the zone header summary and the zone sort. Count only in-range quests so the figures match what a player would consider when choosing where to level. In-log rows bypass the level band entirely and are always counted. The pickable rows double as seeds for the follow-up projection below; blocked rows are tallied after the projection settles which of them unlock in-zone.
        local countInRange = 0
        local xpNow = 0
        local seeds = {}
        local function tallyDoable(list)
            for _, q in ipairs(list) do
                if not q.blocked and (q.inLog or not q.outOfRange) then
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
    local mode = (QuestieGuideDB and QuestieGuideDB.sortMode) or DEFAULTS.sortMode
    local dir = (QuestieGuideDB and QuestieGuideDB.sortDir) or DEFAULTS.sortDir
    local desc = (dir == "desc")

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

-- Renders a muted-label / bright-value row inside GameTooltip.
local function addTooltipField(label, value)
    if value == nil or value == "" then
        return
    end
    GameTooltip:AddDoubleLine(label, tostring(value), 0.65, 0.65, 0.65, 1, 1, 1)
end

local function showQuestTooltip(anchor, questId)
    if not loadQuestie() then
        return
    end
    local quest = QuestieDB.GetQuest(questId)
    if not quest then
        return
    end

    GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
    GameTooltip:AddLine(QuestieLib:GetColoredQuestName(questId, true, false))
    GameTooltip:AddLine(" ")

    if quest.requiredLevel and quest.requiredLevel > 0 then
        addTooltipField("Required level", quest.requiredLevel)
    end

    if QuestieDB.IsRepeatable and QuestieDB.IsRepeatable(questId) then
        GameTooltip:AddLine("|cffff80ffRepeatable|r")
    end
    local tagLabel = getQuestTagLabel(questId)
    if tagLabel then
        local color = QUEST_TAG_COLORS[tagLabel] or "ff8000"
        GameTooltip:AddLine("|cff" .. color .. tagLabel .. "|r")
    end

    local npcName, npcZone, npcSpawn = getQuestStartInfo(questId)
    addTooltipField("NPC", npcName)
    addTooltipField("Location", formatLocation(npcZone, npcSpawn))

    if QuestXP and QuestXP.GetQuestLogRewardXP then
        local ok, xp = pcall(function() return QuestXP:GetQuestLogRewardXP(questId, true) end)
        if ok and xp and xp > 0 then
            addTooltipField("XP", xp)
        end
    end

    if type(quest.objectivesText) == "table" and #quest.objectivesText > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(COLOR.GOLD .. "Objectives|r")
        for _, line in ipairs(quest.objectivesText) do
            GameTooltip:AddLine(line, 1, 1, 1, true)
        end
    end

    GameTooltip:Show()
end

-- Questie's difficulty color (red/orange/yellow/green/grey) for the quest level. Matches the color the name receives so the level brackets and name share a hue.
local function getDifficultyRGB(level)
    if QuestieLib and QuestieLib.GetDifficultyColorPercent then
        return QuestieLib:GetDifficultyColorPercent(level)
    end
    return 1, 1, 1
end

local function getDifficultyColorCode(level)
    local r, g, b = getDifficultyRGB(level)
    return string.format("|cff%02x%02x%02x",
        math.floor(r * 255), math.floor(g * 255), math.floor(b * 255))
end

-- Two-line row presentation: [LVL] [TYPE] QUEST_NAME [badge?] QUEST_GIVER_LOCATION, QUEST_GIVER_NAME Level and quest name share Questie's difficulty color; the type tag keeps its native quality color (orange for Elite, purple for Dungeon). The whole giver line is grey (location, comma, and NPC name together) so it sits as a single subtle subtitle under the title. `badge` is appended after the quest name on line 1 when provided (used by the chain tooltip).
local function formatRowLines(level, name, quest, badge)
    local diff = getDifficultyColorCode(level)
    local line1 = diff .. "[" .. tostring(level or 0) .. "]|r"
    if quest and quest.tag then
        local color = QUEST_TAG_COLORS[quest.tag] or "ff8000"
        line1 = line1 .. " |cff" .. color .. "[" .. quest.tag .. "]|r"
    end
    line1 = line1 .. " " .. diff .. (name or "") .. "|r"
    if badge then
        line1 = line1 .. " " .. badge
    end

    local line2
    if quest then
        local startInfo = resolveStartInfo(quest)
        if startInfo and (startInfo.zoneName or startInfo.npcName) then
            local parts = {}
            if startInfo.zoneName then parts[#parts + 1] = startInfo.zoneName end
            if startInfo.npcName then parts[#parts + 1] = startInfo.npcName end
            line2 = COLOR.GREY .. table.concat(parts, ", ") .. "|r"
        end
    end
    return line1, line2
end

-- Status badge for prior quests in the chain tooltip. `[In Questlog]` (blue) if the player has the quest in their log, `[Available]` (green) if it can be picked up right now, otherwise no badge. Completed quests don't appear in the chain at all (findMissingChains skips them).
local function getStatusBadge(questId)
    local currentLog = (QuestiePlayer and QuestiePlayer.currentQuestlog) or {}
    if currentLog[questId] then
        return COLOR.BLUE .. "[In Questlog]|r"
    end
    if QuestieDB and QuestieDB.IsDoable and QuestieDB.IsDoable(questId) then
        return COLOR.GREEN .. "[Available]|r"
    end
    return nil
end

-- Lightweight quest spec for formatRowLines callers that don't already have a list-row table on hand (i.e. the chain tooltip).
local function buildQuestSpec(questId)
    local playerLevel = UnitLevel("player")
    local level = getEffectiveLevel(questId, playerLevel)
    return {
        id = questId,
        level = level,
        name = getQuestName(questId),
        tag = getQuestTagLabel(questId),
    }
end

local function showChainTooltip(anchor, mpe)
    if not loadQuestie() then
        return
    end
    local chain = mpe.chain
    if type(chain) ~= "table" or #chain < 2 then
        return
    end

    GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")

    -- Title: the hovered (blocked) quest. The tooltip's first AddLine uses the larger title font, so the hovered quest naturally stands out above the prior-quests list.
    local diff = getDifficultyColorCode(mpe.level)
    local title = string.format("%s[%d] %s|r", diff, mpe.level or 0, mpe.name or "")
    if mpe.tag then
        local tagColor = QUEST_TAG_COLORS[mpe.tag] or "ff8000"
        title = title .. " |cff" .. tagColor .. "[" .. mpe.tag .. "]|r"
    end
    GameTooltip:AddLine(title)

    local startInfo = resolveStartInfo(mpe)
    if startInfo and (startInfo.zoneName or startInfo.npcName) then
        local parts = {}
        if startInfo.zoneName then parts[#parts + 1] = startInfo.zoneName end
        if startInfo.npcName then parts[#parts + 1] = startInfo.npcName end
        GameTooltip:AddLine(COLOR.GREY .. table.concat(parts, ", ") .. "|r", 1, 1, 1, true)
    end

    GameTooltip:AddLine(" ")

    -- Prior quests that must be completed before the hovered quest unlocks. The hovered quest itself is the chain tail (chain[#chain]); skip it.
    local priorCount = #chain - 1
    for i = 1, priorCount do
        local qid = chain[i]
        local spec = buildQuestSpec(qid)
        local badge = getStatusBadge(qid)
        local line1, line2 = formatRowLines(spec.level, spec.name, spec, badge)
        GameTooltip:AddLine(string.format("%d. %s", i, line1), 1, 1, 1, true)
        if line2 then
            GameTooltip:AddLine(line2, 1, 1, 1, true)
        end
        if i ~= priorCount then
            GameTooltip:AddLine(" ")
        end
    end

    GameTooltip:Show()
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
        row.text:SetPoint("TOPLEFT", row, "TOPLEFT", SPACING.XS, -ROW_PAD_V)
        row.text:SetTextColor(1, 1, 1)
        return row
    end
    row = CreateFrame("Button", nil, scrollChild)
    row:SetHeight(LIST.ROW_HEIGHT)
    row:SetPoint("LEFT", scrollChild, "LEFT", 0, 0)
    row:SetPoint("RIGHT", scrollChild, "RIGHT", 0, 0)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    -- Native quest-list hover: UI-QuestTitleHighlight in ADD blend mode, sat on BACKGROUND so the row text (ARTWORK) stays on top. Same combo Blizzard uses for the quest log, friends list, addon list, and gossip rows. Driven manually in renderQuestRow so headers/subheaders (nil OnEnter) stay flat.
    row.highlight = row:CreateTexture(nil, "BACKGROUND")
    row.highlight:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    row.highlight:SetBlendMode("ADD")
    row.highlight:SetAllPoints(true)
    row.highlight:Hide()
    -- Native quest log selection look: the same UI-QuestLogTitleHighlight in ADD blend that QuestLogSkillHighlight uses (Classic Era Vanilla/QuestLogFrame.xml), vertex-colored per quest difficulty in renderQuestRow like QuestLog_Update does.
    row.selection = row:CreateTexture(nil, "BACKGROUND")
    row.selection:SetTexture("Interface\\QuestFrame\\UI-QuestLogTitleHighlight")
    row.selection:SetBlendMode("ADD")
    row.selection:SetAllPoints(true)
    row.selection:Hide()
    row.text = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    -- Anchor text from the top so wrapped lines grow downward; row height is sized to fit the measured text + ROW_PAD_V padding (see renderList).
    row.text:SetPoint("TOPLEFT", row, "TOPLEFT", SPACING.XS, -ROW_PAD_V)
    row.text:SetPoint("TOPRIGHT", row, "TOPRIGHT", -SPACING.XS, -ROW_PAD_V)
    row.text:SetJustifyH("LEFT")
    row.text:SetJustifyV("TOP")
    row.text:SetWordWrap(true)
    row.text:SetSpacing(LINE_SPACING)
    row.text:SetTextColor(1, 1, 1)
    -- Native expand/collapse toggle for header rows. The hilight sits on the HIGHLIGHT layer so the button shows it automatically on mouse-over; quest rows keep its texture empty so nothing renders there.
    row.toggle = row:CreateTexture(nil, "ARTWORK")
    row.toggle:SetSize(16, 16)
    row.toggle:SetPoint("TOPLEFT", row, "TOPLEFT", HEADER_TOGGLE_INSET, 0)
    row.toggle:Hide()
    row.toggleHighlight = row:CreateTexture(nil, "HIGHLIGHT")
    row.toggleHighlight:SetBlendMode("ADD")
    row.toggleHighlight:SetAllPoints(row.toggle)
    rowPool[index] = row
    return row
end

-- Dresses a pooled row as a native quest log header: plus/minus toggle, indented text, and header grey that whitens while hovered (the same swap Blizzard gets from NormalFont/HighlightFont on QuestLogTitleButton).
local function styleHeaderRow(row, collapsed)
    row.toggle:SetTexture(collapsed and TOGGLE_PLUS or TOGGLE_MINUS)
    row.toggle:Show()
    row.toggleHighlight:SetTexture(TOGGLE_HILIGHT)
    row.text:SetPoint("TOPLEFT", row, "TOPLEFT", HEADER_TEXT_INSET, -ROW_PAD_V)
    row.text:SetTextColor(HEADER_R, HEADER_G, HEADER_B)
    row:SetScript("OnEnter", function(self)
        self.text:SetTextColor(1, 1, 1)
    end)
    row:SetScript("OnLeave", function(self)
        self.text:SetTextColor(HEADER_R, HEADER_G, HEADER_B)
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

-- Forward declarations resolved later.
local showQuestContextMenu
local showChainContextMenu

-- Questie's plain-text share format: receivers running Questie convert the pattern into a rich |Hquestie:id:guid|h hyperlink via its chat filter, while non-Questie users still see a readable "[[level] Name (id)]" string.
local function buildQuestLink(quest)
    local lvl = quest.level or 0
    local name = quest.name or ("Quest " .. quest.id)
    if QuestieLink and QuestieLink.GetQuestLinkString then
        return QuestieLink:GetQuestLinkString(lvl, name, quest.id)
    end
    return string.format("[[%d] %s (%d)]", lvl, name, quest.id)
end

local function linkQuestInChat(quest)
    local link = buildQuestLink(quest)
    local edit = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
    if edit and edit:IsVisible() and ChatEdit_InsertLink then
        ChatEdit_InsertLink(link)
    elseif ChatFrame_OpenChat then
        ChatFrame_OpenChat(link)
    else
        print(INTRO_PREFIX .. link)
    end
end

-- Context menus use the modern Menu API (MenuUtil.CreateContextMenu). The legacy UIDropDownMenu/EasyMenu path was replaced because it shared globals (UIDROPDOWNMENU_INIT_MENU, UIDROPDOWNMENU_OPEN_MENU, DropDownList1/2) with Blizzard's secure dropdowns; opening one from our insecure code tainted Blizzard_GroupFinder_VanillaStyle's category dropdown init in LFGBrowseMixin:SearchActiveEntry, blocking the subsequent C_LFGList.Search.
function showQuestContextMenu(anchor, quest)
    MenuUtil.CreateContextMenu(anchor, function(_, rootDescription)
        rootDescription:CreateTitle(quest.name)
        rootDescription:CreateButton("Show on map", function() openMapForQuest(quest) end)
        rootDescription:CreateButton("Link in chat", function() linkQuestInChat(quest) end)
    end)
end

function showChainContextMenu(anchor, mpe)
    -- "Show on map" jumps to the next actionable step (the chain's initial), since the blocked quest itself isn't pickup-able yet. "Link in chat" links the blocked quest (the row the player is hovering).
    local initial = { id = mpe.chain and mpe.chain[1] }
    MenuUtil.CreateContextMenu(anchor, function(_, rootDescription)
        rootDescription:CreateTitle(mpe.name)
        rootDescription:CreateButton("Show next step on map", function() openMapForQuest(initial) end)
        rootDescription:CreateButton("Link in chat", function() linkQuestInChat(mpe) end)
    end)
end

function getQuestTagLabel(questId)
    if not QuestieDB or not QuestieDB.GetQuestTagInfo then
        return nil
    end
    local tagId = QuestieDB.GetQuestTagInfo(questId)
    return tagId and QUEST_TAG_LABELS[tagId] or nil
end

function getQuestXp(questId)
    if not QuestXP or not QuestXP.GetQuestLogRewardXP then
        return 0
    end
    local ok, xp = pcall(function() return QuestXP:GetQuestLogRewardXP(questId, true) end)
    if not ok or type(xp) ~= "number" then
        return 0
    end
    return xp
end

function formatNumber(n)
    n = math.floor(n + 0.5)
    if n < 1000 then return tostring(n) end
    local s = tostring(n)
    local out = s:sub(-3)
    s = s:sub(1, -4)
    while #s > 0 do
        out = s:sub(-3) .. "," .. out
        s = s:sub(1, -4)
    end
    return out
end

-- Zone header hover: the breakdown behind the one-trip total. Uses scan-level stats driven by the level filter, which can differ from the rows on screen while a search or bucket filter narrows them.
local function showZoneTooltip(anchor, zoneName, stats, isBest, focusHint)
    if not stats then
        return
    end
    GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
    GameTooltip:AddLine(zoneName)
    if isBest then
        GameTooltip:AddLine(COLOR.GOLD .. "Best zone for your next trip|r")
    end
    GameTooltip:AddLine(" ")
    local total = stats.xp or 0
    local xpMax = (UnitXPMax and UnitXPMax("player")) or 0
    if total > 0 and xpMax > 0 and UnitLevel("player") < CLASSIC_MAX_LEVEL then
        addTooltipField("Total XP",
            string.format("%s XP, covers %d%% of level %d", formatNumber(total), math.floor(total / xpMax * 100 + 0.5), UnitLevel("player")))
    else
        addTooltipField("Total XP", formatNumber(total) .. " XP")
    end
    if (stats.followupCount or 0) > 0 then
        addTooltipField("Includes follow-ups",
            string.format("%s XP (%d quests)", formatNumber(stats.xpFollowup or 0), stats.followupCount))
    end
    if (stats.travelCount or 0) > 0 then
        addTooltipField("Gated outside this zone",
            string.format("%s XP (%d quests, not counted)", formatNumber(stats.travelXp or 0), stats.travelCount))
    end
    if focusHint then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(COLOR.GREY .. "Right-Click: focus this zone|r")
    end
    GameTooltip:Show()
end

-- Opens the native quest log to the quest. Headers expand first because a quest under a collapsed header has no reachable log index, and the faux scroll list is nudged so the selection is on screen (QuestLog_SetSelection highlights but never scrolls).
local function openQuestInLog(questId)
    if not GetQuestLogIndexByID or not QuestLogFrame then
        return
    end
    if ExpandQuestHeader then
        ExpandQuestHeader(0)
    end
    local logIndex = GetQuestLogIndexByID(questId)
    if not logIndex or logIndex == 0 then
        return
    end
    if not QuestLogFrame:IsShown() then
        ShowUIPanel(QuestLogFrame)
    end
    if QuestLogListScrollFrame and FauxScrollFrame_SetOffset and QuestLogListScrollFrameScrollBar then
        local offset = math.max(0, logIndex - 3)
        FauxScrollFrame_SetOffset(QuestLogListScrollFrame, offset)
        QuestLogListScrollFrameScrollBar:SetValue(offset * (QUESTLOG_QUEST_HEIGHT or 16))
    end
    QuestLog_SetSelection(logIndex)
    QuestLog_Update()
end

-- Blink the row's native hover highlight a few times so the eye lands on the jump target. Ends hidden; a hover in between re-drives it through OnEnter/OnLeave anyway.
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
    local filters = (QuestieGuideDB and QuestieGuideDB.filters) or DEFAULTS.filters
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

-- Expand the target's zone and bucket, re-render, scroll the list to the row and blink it. Scrolling goes through the scrollbar so its thumb stays in sync.
local function jumpToQuestInList(questId)
    local zoneName, subKey = findListedQuest(questId)
    if not zoneName then
        return false
    end
    -- The jump target becomes the selected row so the eye keeps it after the blink fades.
    selectedQuestId = questId
    getZoneCollapsed()[zoneName] = false
    getGroupCollapsed()[zoneName .. "||" .. subKey] = false
    renderList()
    local target = rowTargets[questId]
    if not target or not mainFrame or not mainFrame.scroll then
        return false
    end
    local scroll, scrollBar = mainFrame.scroll, mainFrame.scrollBar
    local range = math.max(0, scrollChild:GetHeight() - scroll:GetHeight())
    if range > 0 then
        -- A third down the viewport keeps some context visible above the target row.
        local goal = math.min(math.max(target.top - scroll:GetHeight() / 3, 0), range)
        scrollBar:SetScrollPercentage(goal / range)
    end
    flashRow(target.row)
    return true
end

-- Tooltip for a ready-to-turn-in quest: Questie-colored name plus the turn-in target, mirroring showQuestTooltip's field styling. The quest's startInfo carries the finisher (see collectCompletedByZone).
local function showTurnInTooltip(anchor, quest)
    if not loadQuestie() then
        return
    end
    GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
    GameTooltip:AddLine(QuestieLib:GetColoredQuestName(quest.id, true, false))
    GameTooltip:AddLine(COLOR.GREEN .. "Completed|r")
    GameTooltip:AddLine(" ")
    local info = quest.startInfo
    addTooltipField("Turn in to", info and info.npcName)
    addTooltipField("Location", info and formatLocation(info.zoneName, info.spawn))
    if quest.xp and quest.xp > 0 then
        addTooltipField("XP", formatNumber(quest.xp))
    end
    GameTooltip:Show()
end

-- Quests in the log that are ready to turn in, bucketed by the turn-in target's zone. Detection uses QuestieDB.IsComplete, which reads the native quest log's isComplete flag and also settles no-objective auto-complete quests; the zone grouping needs Questie's finishedBy data either way. Cheap (log holds at most 20 quests), so it runs fresh every render instead of joining the scan cache.
local function collectCompletedByZone()
    if not loadQuestie() or not QuestieDB.IsComplete then
        return {}, {}
    end
    local playerLevel = UnitLevel("player")
    local currentLog = (QuestiePlayer and QuestiePlayer.currentQuestlog) or {}
    local byZone = {}
    local zoneOrder = {}
    for questId in pairs(currentLog) do
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
        emptyActionButton:SetHeight(SPACING.LG)
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
    local filters = (QuestieGuideDB and QuestieGuideDB.filters) or DEFAULTS.filters
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
        local h = textHeight + ROW_PAD_V * 2
        if h < minHeight then h = minHeight end
        row:SetHeight(h)
        return h
    end

    local function hideGameTooltip()
        GameTooltip:Hide()
    end

    local function renderQuestRow(label, onEnter, onLeftClick, onRightClick, onShiftClick, alpha, quest)
        y = y + LIST.ROW_GAP
        local rowTop = y
        local row = acquireRow(index)
        placeRow(row, LIST.INDENT_STEP * 2)
        -- Rows are pooled and reused across renders, so always reset alpha explicitly. Out-of-range quests pass 0.5 to dim the row.
        row:SetAlpha(alpha or 1)
        row.text:SetText(label)
        -- Selection mirrors the native quest log: the selected row keeps a difficulty-colored UI-QuestLogTitleHighlight until another row is selected. Blocked rows never carry it because their click jumps elsewhere.
        if quest and quest.id == selectedQuestId and not quest.blocked then
            row.selection:SetVertexColor(getDifficultyRGB(quest.level))
            row.selection:Show()
        end
        row:SetScript("OnEnter", function(self)
            row.highlight:Show()
            if onEnter then onEnter(self) end
        end)
        row:SetScript("OnLeave", function()
            row.highlight:Hide()
            hideGameTooltip()
        end)
        if onLeftClick or onRightClick or onShiftClick then
            row:SetScript("OnClick", function(self, btn)
                if btn == "LeftButton" and IsModifiedClick and IsModifiedClick("CHATLINK") then
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

    local zoneCollapsedDB = getZoneCollapsed()
    local groupCollapsedDB = getGroupCollapsed()
    local showDungeons = filters.dungeons ~= false
    local showEliteGroup = filters.eliteGroup ~= false

    local function passesTagFilter(quest)
        local tag = quest.tag
        if not tag then
            return true
        end
        if tag == "Dungeon" then
            return showDungeons
        end
        if tag == "Elite" or tag == "Raid" then
            return showEliteGroup
        end
        return true
    end

    local function passesQuest(quest, zoneMatch)
        if not passesTagFilter(quest) then
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
        if not (QuestieGuideDB and QuestieGuideDB.showCompleted) then
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
                            -- Left-click opens the map at the turn-in target and pulses the quest's Questie icons (quest.startInfo carries the finisher, so openMapForQuest lands there).
                            local badge = COLOR.GREEN .. "[Completed]|r"
                            local line1, line2 = formatRowLines(quest.level, quest.name, quest, badge)
                            local label = line2 and (line1 .. "\n" .. line2) or line1
                            renderQuestRow(label,
                                function(self) showTurnInTooltip(self, quest) end,
                                function() openMapForQuest(quest) end,
                                function(self) if showQuestContextMenu then showQuestContextMenu(self, quest) end end,
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
        local detail = formatNumber(bannerStats.xp) .. " XP in one trip"
        local xpMax = (UnitXPMax and UnitXPMax("player")) or 0
        local playerLevel = UnitLevel("player")
        if xpMax > 0 and playerLevel < CLASSIC_MAX_LEVEL then
            detail = string.format("%s, covers %d%% of level %d", detail, math.floor(bannerStats.xp / xpMax * 100 + 0.5), playerLevel)
        end
        row.text:SetText(COLOR.GOLD .. "Next: " .. bannerZone .. "|r  " .. COLOR.GREY .. detail .. "|r")
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
            if filters.available then
                for _, q in ipairs(entry.available or {}) do
                    if passesRow(q) then
                        visible.available[#visible.available + 1] = q
                    end
                end
            end
            if filters.pickedUpElsewhere then
                for _, q in ipairs(entry.pickedUpElsewhere or {}) do
                    if passesRow(q) then
                        visible.pickedUpElsewhere[#visible.pickedUpElsewhere + 1] = q
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
                    if not q.outOfRange then
                        subRangeN = subRangeN + 1
                        inRangeTotal = inRangeTotal + 1
                        -- Blocked-quest XP is carried by the zone-level follow-up figure (only chains that unlock in-zone count), never by row summation.
                        if not q.blocked then
                            inRangeXp = inRangeXp + (q.xp or 0)
                        end
                    end
                end
                subInRangeCount[subKey] = subRangeN
            end
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
                    summary = summary .. " " .. COLOR.GREY .. formatNumber(totalXp) .. " XP|r"
                end
                local isBestZone = (zoneName == bestZoneName)
                -- Current-zone marker: gold tag on the header of the zone the player is standing in.
                local headerText = zoneName .. summary
                if zoneName == currentZoneName then
                    headerText = headerText .. " " .. COLOR.GOLD .. "(You are here)|r"
                end
                header.text:SetText(headerText)
                local zoneStats = entry.stats
                header:SetScript("OnEnter", function(self)
                    self.text:SetTextColor(1, 1, 1)
                    showZoneTooltip(self, zoneName, zoneStats, isBestZone, true)
                end)
                header:SetScript("OnLeave", function(self)
                    self.text:SetTextColor(HEADER_R, HEADER_G, HEADER_B)
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
                        local list = visible[subKey] or {}
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
                                        local badge = COLOR.ORANGE .. "[Missing Pre-Quest]|r"
                                        local line1, line2 = formatRowLines(quest.level, quest.name, quest, badge)
                                        local label = line2 and (line1 .. "\n" .. line2) or line1
                                        renderQuestRow(label,
                                            function(self) showChainTooltip(self, quest) end,
                                            function() jumpToUnlockingQuest(quest) end,
                                            function(self) if showChainContextMenu then showChainContextMenu(self, quest) end end,
                                            function() linkQuestInChat(quest) end,
                                            0.5, quest)
                                    else
                                        -- In-log rows open the native quest log; pickable rows open the map at their giver. Both register as jump targets for blocked rows' chains.
                                        local badge = quest.inLog
                                            and (COLOR.BLUE .. "[In Questlog]|r")
                                            or (COLOR.GREEN .. "[Available]|r")
                                        local line1, line2 = formatRowLines(quest.level, quest.name, quest, badge)
                                        -- Route number prefix: the row's stop on this zone's pickup route. Gaps mean filtered-out stops.
                                        if quest.routeIndex and quest.routeZone == zoneName then
                                            line1 = COLOR.GREY .. quest.routeIndex .. ".|r " .. line1
                                        end
                                        local label = line2 and (line1 .. "\n" .. line2) or line1
                                        local onLeftClick = quest.inLog
                                            and function() openQuestInLog(quest.id) end
                                            or function() openMapForQuest(quest) end
                                        local row, rowTop = renderQuestRow(label,
                                            function(self) showQuestTooltip(self, quest.id) end,
                                            onLeftClick,
                                            function(self) if showQuestContextMenu then showQuestContextMenu(self, quest) end end,
                                            function() linkQuestInChat(quest) end,
                                            quest.outOfRange and 0.5 or 1, quest)
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
        row.text:SetText("|cffaaaaaa" .. msg .. "|r")
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
                QuestieGuideDB.filters.available = true
                QuestieGuideDB.filters.pickedUpElsewhere = true
                invalidateScan()
                renderList()
            end
        elseif searchText ~= "" then
            actionText = "Clear Search"
            action = function()
                if mainFrame and mainFrame.searchBox then
                    mainFrame.searchBox:SetText("")
                else
                    searchText = ""
                    renderList()
                end
            end
        elseif not (QuestieGuideDB and QuestieGuideDB.useQuestieLevelRange)
            and (below < LEVEL_RANGE_MAX or above < LEVEL_RANGE_MAX) then
            actionText = "Widen Level Range"
            action = function()
                QuestieGuideDB.levelBelow = clampRange(below + 2)
                QuestieGuideDB.levelAbove = clampRange(above + 2)
                if mainFrame and mainFrame.refreshRangeSliders then
                    mainFrame.refreshRangeSliders()
                end
                invalidateScan()
                renderList()
            end
        end
        if actionText then
            local button = getEmptyActionButton()
            button:SetText(actionText)
            local textWidth = button:GetFontString() and button:GetFontString():GetStringWidth() or 0
            button:SetWidth(math.max(140, textWidth + 32))
            button:ClearAllPoints()
            button:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -(y + SPACING.SM))
            button:SetScript("OnClick", action)
            button:Show()
            y = y + SPACING.LG + SPACING.SM
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
    getZoneCollapsed()[zoneName] = false
    renderList()
    local top = zoneHeaderTops[zoneName]
    local scroll = mainFrame and mainFrame.scroll
    local scrollBar = mainFrame and mainFrame.scrollBar
    if not top or not scroll or not scrollBar then
        return false
    end
    local range = math.max(0, scrollChild:GetHeight() - scroll:GetHeight())
    if range > 0 then
        scrollBar:SetScrollPercentage(math.min(math.max(top / range, 0), 1))
    end
    return true
end

-- Native Blizzard dialog-frame backdrop (matches AceGUI Frame, which is what Questie's options panel uses). DialogBox-Border has the metallic look with decorative corners; DialogBox-Background is the standard tan parchment.
local function applyPanelBackdrop(frame)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
end

-- Native Blizzard dialog-box header banner (Interface\DialogFrame\UI-DialogBox-Header) composed as three texture pieces (left cap, repeating middle, right cap), centered at the parent's top edge and overlapping into the frame interior. Same texture coords AceGUI uses for its Frame title.
local function buildTitleHeader(parent, text)
    local HEADER_TEXTURE = "Interface\\DialogFrame\\UI-DialogBox-Header"

    local mid = parent:CreateTexture(nil, "OVERLAY")
    mid:SetTexture(HEADER_TEXTURE)
    mid:SetTexCoord(0.31, 0.67, 0, 0.63)
    mid:SetPoint("TOP", parent, "TOP", 0, 12)
    mid:SetHeight(40)

    local left = parent:CreateTexture(nil, "OVERLAY")
    left:SetTexture(HEADER_TEXTURE)
    left:SetTexCoord(0.21, 0.31, 0, 0.63)
    left:SetPoint("RIGHT", mid, "LEFT")
    left:SetWidth(30)
    left:SetHeight(40)

    local right = parent:CreateTexture(nil, "OVERLAY")
    right:SetTexture(HEADER_TEXTURE)
    right:SetTexCoord(0.67, 0.77, 0, 0.63)
    right:SetPoint("LEFT", mid, "RIGHT")
    right:SetWidth(30)
    right:SetHeight(40)

    local title = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", mid, "TOP", 0, -14)
    title:SetText(text)

    mid:SetWidth((title:GetStringWidth() or 0) + 10)

    return mid
end

-- Boxed subcontainer (AceGUI InlineGroup look, shared with ChatScan and GatherMate2NodeAlert): dark bg + tooltip border with a floating yellow label above the box and an inner body frame. Section height = SECTION_INNER_PAD * 2 + content height.
local function buildSection(parent, labelText)
    local section = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    section:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 3, right = 3, top = 5, bottom = 3 },
    })
    section:SetBackdropColor(0.1, 0.1, 0.1, 0.5)
    section:SetBackdropBorderColor(0.4, 0.4, 0.4)

    local label = section:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("BOTTOMLEFT", section, "TOPLEFT", SECTION_INNER_PAD, SECTION_LABEL_LIFT)
    label:SetText(labelText)
    section.label = label

    local body = CreateFrame("Frame", nil, section)
    body:SetPoint("TOPLEFT", section, "TOPLEFT", SECTION_INNER_PAD, -SECTION_INNER_PAD)
    body:SetPoint("BOTTOMRIGHT", section, "BOTTOMRIGHT", -SECTION_INNER_PAD, SECTION_INNER_PAD)
    section.body = body

    return section
end

-- Layout model The frame contains exactly one `content` container, inset from the frame by PAD_X on the sides, PAD_TOP at the top (clears the title banner), PAD_BOTTOM at the bottom. Content splits into two panes: `optionsPane`, a fixed-width column on the left, and `listPane` filling the rest, separated by the PANE_GAP gutter sized to match the visible border padding. Every option section is a `buildSection` box (a bordered child with a floating label and an inner `body` frame) stacked inside `optionsPane` via `stack(element, gap)`, which pins TOPLEFT to the previous element's BOTTOMLEFT and RIGHT to the pane's RIGHT. Each section determines its own height; vertical position follows.
-- The quest list lives in `questsSection`, which fills `listPane` for the frame's full content height regardless of frame size.
local function buildMainFrame()
    if mainFrame then
        return mainFrame
    end

    local frame = CreateFrame("Frame", "QuestieGuideFrame", UIParent, "BackdropTemplate")
    local savedSize = (QuestieGuideDB and QuestieGuideDB.frameSize) or DEFAULTS.frameSize

    -- Sizes saved by the old single-column layout are too narrow for two panes.
    local savedWidth = math.max(savedSize.w or FRAME_WIDTH, FRAME_MIN_WIDTH)
    frame:SetSize(savedWidth, savedSize.h or FRAME_HEIGHT)
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:SetResizable(true)
    if frame.SetResizeBounds then
        frame:SetResizeBounds(FRAME_MIN_WIDTH, 420, 1200, 960)
    elseif frame.SetMinResize then
        frame:SetMinResize(FRAME_MIN_WIDTH, 420)
        frame:SetMaxResize(1200, 960)
    end
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint(1)
        QuestieGuideDB.framePos = { point = point, relPoint = relPoint, x = x, y = y }
    end)
    applyPanelBackdrop(frame)

    local savedPos = QuestieGuideDB and QuestieGuideDB.framePos
    if type(savedPos) == "table" and savedPos.point then
        frame:ClearAllPoints()
        frame:SetPoint(savedPos.point, UIParent, savedPos.relPoint or savedPos.point, savedPos.x or 0, savedPos.y or 0)
    else
        frame:SetPoint("CENTER")
    end
    frame:Hide()

    buildTitleHeader(frame, "Questie Guide")

    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)

    -- The single content container. Every section anchors inside this; nothing outside this is sized by the section chain.
    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD_X, -PAD_TOP)
    content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD_X, PAD_BOTTOM)

    -- Fixed-width options column on the left.
    local optionsPane = CreateFrame("Frame", nil, content)
    optionsPane:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    optionsPane:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 0)
    optionsPane:SetWidth(OPTIONS_PANE_WIDTH)

    -- Quest list column fills the remaining width.
    local listPane = CreateFrame("Frame", nil, content)
    listPane:SetPoint("TOPLEFT", optionsPane, "TOPRIGHT", PANE_GAP, 0)
    listPane:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)

    -- Stacks the element below the previous one with a chosen gap. The first element (prev == nil) docks to the options pane's top-left.
    local lastInStack
    local function stack(element, gap)
        element:ClearAllPoints()
        if lastInStack then
            element:SetPoint("TOPLEFT", lastInStack, "BOTTOMLEFT", 0, -(gap or SECTION_GAP))
        else
            element:SetPoint("TOPLEFT", optionsPane, "TOPLEFT", 0, 0)
        end
        element:SetPoint("RIGHT", optionsPane, "RIGHT", 0, 0)
        lastInStack = element
    end

    -- Creates a nested section box, stacks it inside `optionsPane`, and returns the section frame so callers can parent widgets to `section.body` and set the section's height once its content is sized. Nil gap falls back to `stack`'s SECTION_GAP default; the first section ignores the gap because there is no previous element to anchor below.
    local function makeSection(text, gap)
        local section = buildSection(optionsPane, text)
        stack(section, gap)
        return section
    end

    -- 1) Quest Level Range section: a "Use Questie Level Ranges" checkbox sits above the slider pair. When the checkbox is ticked, the sliders disable and the scan bypasses the band filter (see passesLevelGate).
    local rangeSection = makeSection("Quest Level Range")
    local RANGE_CHECKBOX_HEIGHT = 22
    local RANGE_CHECKBOX_GAP = SPACING.SM
    -- MinimalSliderWithSteppersTemplate is a Frame at 40px tall (top label, track + steppers, min/max labels). The sliders stack vertically because the options pane is too narrow for a side-by-side pair.
    local RANGE_SLIDER_FRAME_H = 40
    local RANGE_SLIDER_GAP = SPACING.SM
    local RANGE_SLIDER_TOP_OFFSET = RANGE_CHECKBOX_HEIGHT + RANGE_CHECKBOX_GAP
    local RANGE_HEIGHT_EXPANDED = SECTION_INNER_PAD * 2 + RANGE_CHECKBOX_HEIGHT + RANGE_CHECKBOX_GAP + RANGE_SLIDER_FRAME_H * 2 + RANGE_SLIDER_GAP
    local RANGE_HEIGHT_COLLAPSED = SECTION_INNER_PAD * 2 + RANGE_CHECKBOX_HEIGHT
    rangeSection:SetHeight(RANGE_HEIGHT_EXPANDED)
    local rangeRow = rangeSection.body

    local useQuestieCheckbox = CreateFrame("CheckButton", "QuestieGuideUseQuestieLevelRange", rangeRow, "UICheckButtonTemplate")
    useQuestieCheckbox:SetSize(RANGE_CHECKBOX_HEIGHT, RANGE_CHECKBOX_HEIGHT)
    useQuestieCheckbox:SetPoint("TOPLEFT", rangeRow, "TOPLEFT", ROW_EDGE_PAD, 0)
    local useQuestieLabel = _G[useQuestieCheckbox:GetName() .. "Text"]
    if useQuestieLabel then
        useQuestieLabel:SetFontObject("GameFontNormal")
        useQuestieLabel:SetText("Use Questie Level Ranges")
        -- Native template anchors LEFT→RIGHT x=-2 calibrated for the 32px default size, where the texture's built-in whitespace yields the standard gap. We're at 22px, so re-anchor with the explicit 4px offset to keep the same visual rhythm.
        useQuestieLabel:ClearAllPoints()
        useQuestieLabel:SetPoint("LEFT", useQuestieCheckbox, "RIGHT", 4, 0)
    end

    local sliderCounter = 0
    local function buildRangeSlider(parent, labelPrefix, dbKey)
        sliderCounter = sliderCounter + 1
        local name = "QuestieGuideRangeSlider" .. sliderCounter
        -- MinimalSliderWithSteppersTemplate is a Frame wrapping a Slider with - / + stepper buttons, a top label, and min/max labels — the same widget Blizzard's Settings panel uses. Width flows from the caller's TOPLEFT/TOPRIGHT anchors; the template anchors its slider track 19px in from each side, leaving room for the steppers.
        local slider = CreateFrame("Frame", name, parent, "MinimalSliderWithSteppersTemplate")
        slider._dbKey = dbKey
        local initial = clampRange(QuestieGuideDB and QuestieGuideDB[dbKey]) or DEFAULTS[dbKey]
        local steps = LEVEL_RANGE_MAX - LEVEL_RANGE_MIN
        local Label = MinimalSliderWithSteppersMixin.Label
        local formatters = {
            [Label.Top] = function(v) return labelPrefix .. v end,
            [Label.Min] = function() return tostring(LEVEL_RANGE_MIN) end,
            [Label.Max] = function() return tostring(LEVEL_RANGE_MAX) end,
        }
        slider:Init(initial, LEVEL_RANGE_MIN, LEVEL_RANGE_MAX, steps, formatters)
        slider:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(_, value)
            local v = clampRange(value)
            if not v then return end
            local cur = QuestieGuideDB and QuestieGuideDB[dbKey]
            if cur == v then return end
            QuestieGuideDB[dbKey] = v
            invalidateScan()
            renderList()
        end, slider)
        return slider
    end

    local belowSlider = buildRangeSlider(rangeRow, "Quest Level Below: -", "levelBelow")
    belowSlider:SetPoint("TOPLEFT", rangeRow, "TOPLEFT", ROW_EDGE_PAD, -RANGE_SLIDER_TOP_OFFSET)
    belowSlider:SetPoint("TOPRIGHT", rangeRow, "TOPRIGHT", -ROW_EDGE_PAD, -RANGE_SLIDER_TOP_OFFSET)

    local aboveSliderOffset = RANGE_SLIDER_TOP_OFFSET + RANGE_SLIDER_FRAME_H + RANGE_SLIDER_GAP
    local aboveSlider = buildRangeSlider(rangeRow, "Quest Level Above: +", "levelAbove")
    aboveSlider:SetPoint("TOPLEFT", rangeRow, "TOPLEFT", ROW_EDGE_PAD, -aboveSliderOffset)
    aboveSlider:SetPoint("TOPRIGHT", rangeRow, "TOPRIGHT", -ROW_EDGE_PAD, -aboveSliderOffset)

    frame.belowSlider = belowSlider
    frame.aboveSlider = aboveSlider

    -- Sliders disappear (and the section shrinks) when Questie's range governs, freeing vertical room for the quest list below.
    local function applySliderLock(locked)
        if locked then
            belowSlider:Hide()
            aboveSlider:Hide()
            rangeSection:SetHeight(RANGE_HEIGHT_COLLAPSED)
        else
            belowSlider:Show()
            aboveSlider:Show()
            belowSlider:SetEnabled(true)
            aboveSlider:SetEnabled(true)
            rangeSection:SetHeight(RANGE_HEIGHT_EXPANDED)
        end
    end

    useQuestieCheckbox:SetChecked(QuestieGuideDB and QuestieGuideDB.useQuestieLevelRange and true or false)
    applySliderLock(useQuestieCheckbox:GetChecked())
    useQuestieCheckbox:SetScript("OnClick", function(self)
        local checked = self:GetChecked() and true or false
        QuestieGuideDB.useQuestieLevelRange = checked
        applySliderLock(checked)
        invalidateScan()
        renderList()
    end)
    frame.useQuestieCheckbox = useQuestieCheckbox

    frame.refreshRangeSliders = function()
        local useQuestie = QuestieGuideDB and QuestieGuideDB.useQuestieLevelRange and true or false
        useQuestieCheckbox:SetChecked(useQuestie)
        applySliderLock(useQuestie)
        local below, above = getLevelRange()
        belowSlider:SetValue(below)
        aboveSlider:SetValue(above)
    end

    -- 2) Filters section: three native multi-select dropdowns stacked one per row so each stays full width inside the narrow options pane. Opening a dropdown lists its toggles as checkboxes. Quest-tag filters live under `QuestieGuideDB.filters`; display toggles live as top-level keys, so each group declares its own get/set.
    local filtersSection = makeSection("Filters")
    local filtersBody = filtersSection.body

    local function getFilterValue(key)
        local f = QuestieGuideDB and QuestieGuideDB.filters
        if f and f[key] ~= nil then return f[key] and true or false end
        return DEFAULTS.filters[key] and true or false
    end
    local function setFilterValue(key, value)
        QuestieGuideDB.filters = QuestieGuideDB.filters or {}
        QuestieGuideDB.filters[key] = value and true or false
    end

    local FILTER_GROUPS = {
        {
            title = "Availability",
            get = getFilterValue,
            set = setFilterValue,
            specs = {
                { key = "inLog",             label = "In Questlog" },
                { key = "available",         label = "Picked Up in Zone" },
                { key = "pickedUpElsewhere", label = "Picked Up Outside of Zone" },
                { key = "missingPre",        label = "Missing Pre-Quest" },
            },
        },
        {
            title = "Quest Types",
            get = getFilterValue,
            set = setFilterValue,
            specs = {
                { key = "dungeons",   label = "Dungeons" },
                { key = "eliteGroup", label = "Elite (Group)" },
            },
        },
    }

    local FILTER_ROW_GAP = SPACING.SM

    local filterDropdowns = {}
    local function buildFilterDropdown(parent, i, group)
        local dd = CreateFrame("DropdownButton", "QuestieGuideFilterDropdown" .. i, parent, "WowStyle2DropdownTemplate")
        -- Keep the button text fixed at the group title; the multi-select nature of these dropdowns means we'd otherwise show a long comma-separated list of every enabled subfilter, which doesn't fit the narrow column. OverrideText sets disableSelectionText, so the DropdownSelectionTextMixin won't replace it as checkboxes toggle.
        dd:OverrideText(group.title)
        dd:SetupMenu(function(_, rootDescription)
            for _, spec in ipairs(group.specs) do
                rootDescription:CreateCheckbox(
                    spec.label,
                    function() return group.get(spec.key) end,
                    function()
                        group.set(spec.key, not group.get(spec.key))
                        invalidateScan()
                        renderList()
                    end)
            end
        end)
        return dd
    end

    -- One full-width dropdown per row; anchors size the frames, no width math.
    for i, group in ipairs(FILTER_GROUPS) do
        local dd = buildFilterDropdown(filtersBody, i, group)
        local yOffset = (i - 1) * (DROPDOWN_ROW_H + FILTER_ROW_GAP)
        dd:SetPoint("TOPLEFT", filtersBody, "TOPLEFT", 0, -yOffset)
        dd:SetPoint("RIGHT", filtersBody, "RIGHT", 0, 0)
        filterDropdowns[i] = dd
    end
    frame.filterDropdowns = filterDropdowns

    filtersSection:SetHeight(SECTION_INNER_PAD * 2 + DROPDOWN_ROW_H * #FILTER_GROUPS + FILTER_ROW_GAP * (#FILTER_GROUPS - 1))

    -- The dropdowns reread their `checked` state from the DB each time the menu opens (init runs per-open), so no per-checkbox refresh is needed. These hooks are no-ops kept to preserve the public refresh contract.
    frame.refreshFilters = function() end
    frame.refreshToggles = function() end

    -- 3) Sorting section: sort-by dropdown above direction dropdown, each full width, matching the filters' stacked layout.
    local SORT_ROW_GAP = SPACING.SM
    local SORT_CHECKBOX_HEIGHT = 22
    local sortingSection = makeSection("Sorting")
    sortingSection:SetHeight(SECTION_INNER_PAD * 2 + DROPDOWN_ROW_H * 2 + SORT_ROW_GAP * 2 + SORT_CHECKBOX_HEIGHT)
    local sortRow = sortingSection.body

    -- Builds a single-select dropdown that reads/writes one DB key. The button text reflects the currently selected option via the DropdownSelectionTextMixin (defaultText shows when nothing matches).
    local function buildSortDropdown(parent, name, dbKey, options, defaultLabel)
        local dd = CreateFrame("DropdownButton", name, parent, "WowStyle2DropdownTemplate")
        dd:SetDefaultText(defaultLabel)
        dd:SetupMenu(function(_, rootDescription)
            for _, opt in ipairs(options) do
                rootDescription:CreateRadio(
                    opt.label,
                    function()
                        return ((QuestieGuideDB and QuestieGuideDB[dbKey]) or DEFAULTS[dbKey]) == opt.value
                    end,
                    function()
                        QuestieGuideDB[dbKey] = opt.value
                        renderList()
                    end)
            end
        end)
        return dd
    end

    local sortByDropdown = buildSortDropdown(sortRow, "QuestieGuideSortByDropdown", "sortMode", SORT_BY_OPTIONS, "Sort By")
    sortByDropdown:SetPoint("TOPLEFT", sortRow, "TOPLEFT", 0, 0)
    sortByDropdown:SetPoint("RIGHT", sortRow, "RIGHT", 0, 0)

    local sortDirDropdown = buildSortDropdown(sortRow, "QuestieGuideSortDirDropdown", "sortDir", SORT_DIR_OPTIONS, "Direction")
    sortDirDropdown:SetPoint("TOPLEFT", sortRow, "TOPLEFT", 0, -(DROPDOWN_ROW_H + SORT_ROW_GAP))
    sortDirDropdown:SetPoint("RIGHT", sortRow, "RIGHT", 0, 0)

    -- Route Order re-sorts each zone's pickable rows into a giver-proximity pickup route (see applyRouteOrder); off restores plain level order.
    local routeSortCheckbox = CreateFrame("CheckButton", "QuestieGuideRouteSort", sortRow, "UICheckButtonTemplate")
    routeSortCheckbox:SetSize(SORT_CHECKBOX_HEIGHT, SORT_CHECKBOX_HEIGHT)
    routeSortCheckbox:SetPoint("TOPLEFT", sortRow, "TOPLEFT", ROW_EDGE_PAD, -(DROPDOWN_ROW_H * 2 + SORT_ROW_GAP * 2))
    local routeSortLabel = _G[routeSortCheckbox:GetName() .. "Text"]
    if routeSortLabel then
        routeSortLabel:SetFontObject("GameFontNormal")
        routeSortLabel:SetText("Route Order Within Zones")
        -- Same re-anchor as the range checkbox: the template's gap is calibrated for the 32px default size.
        routeSortLabel:ClearAllPoints()
        routeSortLabel:SetPoint("LEFT", routeSortCheckbox, "RIGHT", 4, 0)
    end
    routeSortCheckbox:SetChecked(not QuestieGuideDB or QuestieGuideDB.routeSort ~= false)
    routeSortCheckbox:SetScript("OnClick", function(self)
        QuestieGuideDB.routeSort = self:GetChecked() and true or false
        -- Route order is applied at scan time, so the cache must rebuild.
        invalidateScan()
        renderList()
    end)
    frame.routeSortCheckbox = routeSortCheckbox

    frame.sortByDropdown = sortByDropdown
    frame.sortDirDropdown = sortDirDropdown
    -- The button text is driven by DropdownSelectionTextMixin via the per-option `isSelected` callbacks, so no manual refresh is required.
    frame.refreshSortDropdown = function()
        sortByDropdown:GenerateMenu()
        sortDirDropdown:GenerateMenu()
        routeSortCheckbox:SetChecked(not QuestieGuideDB or QuestieGuideDB.routeSort ~= false)
    end

    -- 4) Visibility Filters section: display toggles that add whole sections to the quest list, stored as top-level DB keys like the other display toggles.
    local visibilitySection = makeSection("Visibility Filters")
    local VIS_CHECKBOX_HEIGHT = 22
    visibilitySection:SetHeight(SECTION_INNER_PAD * 2 + VIS_CHECKBOX_HEIGHT)

    local showCompletedCheckbox = CreateFrame("CheckButton", "QuestieGuideShowCompleted", visibilitySection.body, "UICheckButtonTemplate")
    showCompletedCheckbox:SetSize(VIS_CHECKBOX_HEIGHT, VIS_CHECKBOX_HEIGHT)
    showCompletedCheckbox:SetPoint("TOPLEFT", visibilitySection.body, "TOPLEFT", ROW_EDGE_PAD, 0)
    local showCompletedLabel = _G[showCompletedCheckbox:GetName() .. "Text"]
    if showCompletedLabel then
        showCompletedLabel:SetFontObject("GameFontNormal")
        showCompletedLabel:SetText("Show Completed Quests")
        -- Same re-anchor as the range checkbox: the template's gap is calibrated for the 32px default size.
        showCompletedLabel:ClearAllPoints()
        showCompletedLabel:SetPoint("LEFT", showCompletedCheckbox, "RIGHT", 4, 0)
    end
    showCompletedCheckbox:SetScript("OnClick", function(self)
        QuestieGuideDB.showCompleted = self:GetChecked() and true or false
        -- Completed data reads the live quest log per render, so no scan invalidation is needed.
        renderList()
    end)
    frame.showCompletedCheckbox = showCompletedCheckbox

    frame.refreshShowCompleted = function()
        showCompletedCheckbox:SetChecked(QuestieGuideDB and QuestieGuideDB.showCompleted and true or false)
    end

    -- 5) Quests section: search row (label + helper + edit box) at the top, then the Collapse All button and scroll list. Fills the entire right pane.
    local questsSection = buildSection(listPane, "Quests")
    questsSection:SetPoint("TOPLEFT", listPane, "TOPLEFT", 0, 0)
    questsSection:SetPoint("BOTTOMRIGHT", listPane, "BOTTOMRIGHT", 0, 0)

    local searchLabel = questsSection.body:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    searchLabel:SetPoint("TOPLEFT", questsSection.body, "TOPLEFT", 0, 0)
    searchLabel:SetText("Search")

    local searchHelp = questsSection.body:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    searchHelp:SetPoint("TOPLEFT", searchLabel, "BOTTOMLEFT", 0, -SPACING.XS)
    searchHelp:SetPoint("RIGHT", questsSection.body, "RIGHT", 0, 0)
    searchHelp:SetJustifyH("LEFT")
    searchHelp:SetWordWrap(true)
    searchHelp:SetSpacing(LINE_SPACING)
    searchHelp:SetText("Filter by quest name, zone name, or NPC name.")

    local searchBox = CreateFrame("EditBox", "QuestieGuideSearchBox", questsSection.body, "SearchBoxTemplate")
    searchBox:SetHeight(20)
    -- InputBoxVisualTemplate (inherited via SearchBoxTemplate) anchors its Left border texture at x=-5 from the frame's LEFT, so the visible box extends 5px beyond the frame on the left while staying flush on the right. Shift the frame's left anchor by +5 so the visible texture lines up with the section body's left edge, matching the right.
    searchBox:SetPoint("TOPLEFT", searchHelp, "BOTTOMLEFT", 5, -ELEMENT_GAP)
    searchBox:SetPoint("RIGHT", questsSection.body, "RIGHT", 0, 0)
    searchBox:SetAutoFocus(false)
    searchBox:HookScript("OnTextChanged", function(self)
        local newText = string.lower(self:GetText() or "")
        if newText == searchText then return end
        searchText = newText
        renderList()
    end)
    frame.searchBox = searchBox

    -- Collapse All sits directly under the search box. The search box frame is inset +5 from the body's left to line its texture up with the body edge, so pull the button back -5 to align its left with the visible search bar.
    local toggleAllButton = CreateFrame("Button", nil, questsSection.body, "UIPanelButtonTemplate")
    toggleAllButton:SetSize(SPACING.LG * 5, SPACING.LG)
    toggleAllButton:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", -5, -ELEMENT_GAP)
    toggleAllButton:SetText("Collapse All")
    toggleAllButton:SetScript("OnClick", function()
        local zc = getZoneCollapsed()
        local gc = getGroupCollapsed()
        local completedActive = QuestieGuideDB.showCompleted and #lastCompletedZones > 0
        local anyExpanded = false
        for _, zoneName in ipairs(lastZoneOrder) do
            if not zc[zoneName] then anyExpanded = true; break end
        end
        if completedActive and not zc[COMPLETED_KEY] then
            anyExpanded = true
        end
        -- anyExpanded -> collapse everything; otherwise expand everything. Subcategory state mirrors the zone toggle so the button acts as a single "show me everything / nothing" control.
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
    end)
    frame.toggleAllButton = toggleAllButton

    -- Jumps to the zone the player is standing in, expanding and scrolling to its header.
    local currentZoneButton = CreateFrame("Button", nil, questsSection.body, "UIPanelButtonTemplate")
    currentZoneButton:SetSize(SPACING.LG * 5, SPACING.LG)
    currentZoneButton:SetPoint("LEFT", toggleAllButton, "RIGHT", SPACING.SM, 0)
    currentZoneButton:SetText("Current Zone")
    currentZoneButton:SetScript("OnClick", function()
        local zoneName = getCurrentZoneName()
        if not zoneName then
            return
        end
        if not expandAndScrollToZone(zoneName) then
            print(INTRO_PREFIX .. "No quests listed for " .. zoneName .. ".")
        end
    end)
    frame.currentZoneButton = currentZoneButton

    local scroll = CreateFrame("ScrollFrame", nil, questsSection.body)
    scroll:SetPoint("TOPLEFT", toggleAllButton, "BOTTOMLEFT", 5, -ELEMENT_GAP)
    scroll:SetPoint("BOTTOMRIGHT", questsSection.body, "BOTTOMRIGHT", -SCROLLBAR_RESERVE, 0)

    -- Scroll child: explicit width via SetSize, kept in sync with the scroll viewport in scroll's own OnSizeChanged. No anchors so SetScrollChild's internal positioning runs normally (which is what makes the list scroll vertically when content overflows).
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(math.max(1, scroll:GetWidth()), 1)
    scroll:SetScrollChild(child)
    scrollChild = child
    frame.scroll = scroll

    -- Native minimal scrollbar from the in-game Options panel (MinimalScrollBar).
    local scrollBar = CreateFrame("EventFrame", nil, questsSection.body, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 4, -4)
    scrollBar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 4, 8)
    scrollBar:SetHideIfUnscrollable(true)
    scrollBar:Init(1, 0.25)
    frame.scrollBar = scrollBar

    local function refreshScrollBar()
        local viewport = scroll:GetHeight()
        local content = math.max(child:GetHeight(), 1)
        local visiblePct = math.min(1, viewport / content)
        scrollBar:SetVisibleExtentPercentage(visiblePct)
        local range = math.max(0, content - viewport)
        scroll:SetVerticalScroll(range * scrollBar:GetScrollPercentage())
    end

    scrollBar:RegisterCallback("OnScroll", function(_, scrollPercentage)
        local range = math.max(0, child:GetHeight() - scroll:GetHeight())
        scroll:SetVerticalScroll(range * scrollPercentage)
    end, scroll)

    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(_, delta)
        if not scrollBar:HasScrollableExtent() then return end
        local pct = scrollBar:GetScrollPercentage() - delta * 0.1
        scrollBar:SetScrollPercentage(math.max(0, math.min(1, pct)))
    end)

    scroll:HookScript("OnSizeChanged", function(self)
        child:SetWidth(math.max(1, self:GetWidth()))
        renderList()
        refreshScrollBar()
    end)

    child:HookScript("OnSizeChanged", refreshScrollBar)

    frame:HookScript("OnSizeChanged", function(self)
        QuestieGuideDB.frameSize = { w = math.floor(self:GetWidth()), h = math.floor(self:GetHeight()) }
    end)

    local resizeGrip = CreateFrame("Button", nil, frame)
    resizeGrip:SetSize(16, 16)
    resizeGrip:SetPoint("BOTTOMRIGHT", -4, 4)
    resizeGrip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizeGrip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resizeGrip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    resizeGrip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    resizeGrip:SetScript("OnMouseUp", function() frame:StopMovingOrSizing() end)

    -- Lets ESC close the window like a Blizzard panel.
    tinsert(UISpecialFrames, "QuestieGuideFrame")

    mainFrame = frame
    return frame
end

local function renderLoadingPlaceholder()
    if not scrollChild then
        return
    end
    if emptyActionButton then
        emptyActionButton:Hide()
    end
    for _, row in ipairs(rowPool) do
        row:Hide()
        row:SetScript("OnClick", nil)
        row:SetScript("OnEnter", nil)
        row:SetScript("OnLeave", nil)
    end
    local row = acquireRow(1)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -LIST.ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", 0, -LIST.ROW_HEIGHT)
    row:SetHeight(LIST.ROW_HEIGHT)
    row.text:SetText("|cff7f7f7fScanning quest database\226\128\166|r")
    scrollChild:SetHeight(LIST.ROW_HEIGHT * 3)
end

local function showFrame()
    local frame = buildMainFrame()
    if frame.refreshSortDropdown then
        frame.refreshSortDropdown()
    end
    if frame.refreshFilters then
        frame.refreshFilters()
    end
    if frame.refreshToggles then
        frame.refreshToggles()
    end
    if frame.refreshRangeSliders then
        frame.refreshRangeSliders()
    end
    if frame.refreshShowCompleted then
        frame.refreshShowCompleted()
    end
    frame:Show()
    renderLoadingPlaceholder()
    -- Defer the first real layout pass to the next tick. Dropdown rows get their final width from the section body's OnSizeChanged hook, but that hook may not have fired yet on the first paint; renderList itself also relies on the scroll child's resolved width.
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
    if ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow() then
        return
    end
    local data = pin.data
    local questId = data and data.Id
    if type(questId) ~= "number" or data.Type == "manual" then
        return
    end
    if not pin.miniMapIcon and WorldMapFrame and WorldMapFrame:IsShown()
        and pin.qgPreClickMapId and pin.UiMapID and pin.UiMapID ~= pin.qgPreClickMapId then
        return
    end
    if not loadQuestie() then
        return
    end
    local currentLog = (QuestiePlayer and QuestiePlayer.currentQuestlog) or {}
    if currentLog[questId] then
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
        self.qgPreClickMapId = WorldMapFrame and WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
    end)
    pin:HookScript("OnClick", onMapIconClick)
end

-- Questie pins are pooled named globals (QuestieFrame1..N) created only by QuestieFrame.CreateIconFrame, which QuestieFramePool resolves per call, so a module-table hook catches every future pin; the sweep covers pins that already exist.
local mapIconHooksInstalled = false

local function installMapIconHooks()
    if mapIconHooksInstalled then
        return
    end
    local questieLoader = _G.QuestieLoader
    local frameModule = questieLoader and questieLoader:ImportModule("QuestieFrame")
    if not frameModule or not frameModule.CreateIconFrame then
        return
    end
    mapIconHooksInstalled = true
    hooksecurefunc(frameModule, "CreateIconFrame", function(frameId)
        hookMapIcon(_G["QuestieFrame" .. frameId])
    end)
    local i = 1
    while _G["QuestieFrame" .. i] do
        hookMapIcon(_G["QuestieFrame" .. i])
        i = i + 1
    end
end

-- /qg toggles the panel even when the minimap button is hidden; /qg reset rescues a window dragged off-screen.
SLASH_QUESTIEGUIDE1 = "/questieguide"
SLASH_QUESTIEGUIDE2 = "/qg"
SlashCmdList["QUESTIEGUIDE"] = function(msg)
    local command = strtrim(string.lower(msg or ""))
    if command == "reset" then
        QuestieGuideDB.framePos = nil
        QuestieGuideDB.frameSize = { w = DEFAULTS.frameSize.w, h = DEFAULTS.frameSize.h }
        if mainFrame then
            mainFrame:SetSize(DEFAULTS.frameSize.w, DEFAULTS.frameSize.h)
            mainFrame:ClearAllPoints()
            mainFrame:SetPoint("CENTER")
        end
        print(INTRO_PREFIX .. "Window position and size reset.")
        return
    end
    if not loadQuestie() then
        print(INTRO_PREFIX .. "Questie has not finished loading yet. Try again in a moment.")
        return
    end
    toggleFrame()
end

-- Key binding entry point; Bindings.xml can only call named globals. The name global labels the entry under Key Bindings, mirroring how Questie registers its Journey toggle.
BINDING_NAME_QUESTIEGUIDE_TOGGLE = "Toggle Quest Panel"

function QuestieGuide_Toggle()
    if not loadQuestie() then
        print(INTRO_PREFIX .. "Questie has not finished loading yet. Try again in a moment.")
        return
    end
    toggleFrame()
end

-- Clicking a level-up toast link opens the panel at the named zone. hooksecurefunc on SetItemRef is the same interception Questie's debug-offer links use on this client.
local ZONE_LINK_PREFIX = "addon:questieguide:zone:"
hooksecurefunc("SetItemRef", function(link)
    if type(link) ~= "string" or link:sub(1, #ZONE_LINK_PREFIX) ~= ZONE_LINK_PREFIX then
        return
    end
    local areaId = tonumber(link:sub(#ZONE_LINK_PREFIX + 1))
    if not areaId or not loadQuestie() then
        return
    end
    local zoneName = getZoneName(areaId)
    showFrame()
    -- showFrame defers its first layout pass one tick, so the jump waits one tick too.
    C_Timer.After(0.1, function()
        expandAndScrollToZone(zoneName)
    end)
end)

-- Registers the launcher with LibDBIcon so any addon-manager UI (CleanUI's edge-snap refresh, Titan Panel, ChocolateBar, etc.) can manage it consistently.
local function setupMinimapButton()
    local LDB = LibStub("LibDataBroker-1.1")
    local LDBIcon = LibStub("LibDBIcon-1.0")
    if LDBIcon:IsRegistered("Questie Guide") then
        return
    end

    local dataObject = LDB:NewDataObject("Questie Guide", {
        type = "launcher",
        text = "Questie Guide",
        icon = "Interface\\Icons\\INV_Misc_Map02",
        OnClick = function(_, button)
            if button == "LeftButton" then
                if not loadQuestie() then
                    return
                end
                toggleFrame()
            end
        end,
        OnTooltipShow = function(tt)
            tt:AddLine("Questie Guide")
            -- Current-zone count reads the warm scan cache only; a minimap hover must never trigger the expensive DB walk itself.
            local zoneName = getCurrentZoneName()
            if zoneName and scanCache.valid and scanCache.byZone then
                local entry = scanCache.byZone[zoneName]
                local count = (entry and entry.stats and entry.stats.count) or 0
                tt:AddLine(string.format("%d quest%s available in %s.", count, count == 1 and "" or "s", zoneName), 1, 1, 1)
            end
            tt:AddLine("|cffffd200Left-click|r to open the quest panel.", 1, 1, 1)
        end,
    })

    -- Migrate legacy angle field to LibDBIcon's minimapPos.
    if QuestieGuideDB.minimap.angle and not QuestieGuideDB.minimap.minimapPos then
        QuestieGuideDB.minimap.minimapPos = QuestieGuideDB.minimap.angle
    end
    QuestieGuideDB.minimap.angle = nil

    LDBIcon:Register("Questie Guide", dataObject, QuestieGuideDB.minimap)
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

-- Item tooltip quest lines: list every quest the item belongs to that is NOT in the quest log, styled exactly like Questie's active-quest titles (difficulty-colored name via GetColoredQuestName plus a Colorize'd "(Status)" suffix, the same pattern as its "(Complete)"). Active quests stay Questie's job; adding them here would duplicate its title and objective lines.
local INDEX_BUILD_DELAY = 5

-- itemId -> array of quest ids referencing the item (objectives, quest-provided, required source). Built once per session from Questie's compiled quest DB; the DB is static, so no invalidation.
local itemQuestIndex
local indexBuildScheduled = false

local ITEM_QUEST_KEYS = { "objectives", "sourceItemId", "requiredSourceItems" }

local function buildItemQuestIndex()
    if itemQuestIndex then
        return
    end
    if not loadQuestie() then
        -- Questie hasn't compiled its DB yet; retry until it has so the tooltip lines eventually light up.
        C_Timer.After(INDEX_BUILD_DELAY, buildItemQuestIndex)
        return
    end
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
    itemQuestIndex = index
end

local function scheduleItemQuestIndexBuild()
    if indexBuildScheduled or itemQuestIndex then
        return
    end
    indexBuildScheduled = true
    -- A few seconds after login so Questie has finished compiling its DB and the player isn't sharing a frame with the quest-DB walk.
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
    if not passesClassicCaps(level, requiredLevel) or exceedsRequiredMaxLevel(requiredMaxLevel, playerLevel) then
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
    local entries = QuestieTooltips and QuestieTooltips.lookupByKey and QuestieTooltips.lookupByKey["i_" .. itemId]
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

-- Per-frame dedup mirroring Questie's item handler: OnTooltipSetItem can fire repeatedly for one hover, so re-add only when the tooltip shows a different item or was rebuilt (fewer lines than when we last added).
local lastTooltipItem = {}

local function addQuestLinesToItemTooltip(tooltip)
    if tooltip.IsForbidden and tooltip:IsForbidden() then
        return
    end
    if not itemQuestIndex or not loadQuestie() then
        return
    end
    local profile = _G.Questie and _G.Questie.db and _G.Questie.db.profile
    if not profile or not profile.enableTooltips then
        return
    end
    local _, link = tooltip:GetItem()
    local itemId = link and tonumber(string.match(link, "item:(%d+)"))
    if not itemId then
        return
    end
    local last = lastTooltipItem[tooltip]
    if last and last.itemId == itemId and tooltip:NumLines() >= last.count then
        return
    end
    local currentLog = (QuestiePlayer and QuestiePlayer.currentQuestlog) or {}
    local playerLevel = UnitLevel("player")
    local questIds = {}
    local seen = {}
    for _, questId in ipairs(itemQuestIndex[itemId] or {}) do
        seen[questId] = true
        questIds[#questIds + 1] = questId
    end
    local startQuestId = QuestieDB.QueryItemSingle and QuestieDB.QueryItemSingle(itemId, "startQuest")
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
            tooltip:AddLine(QuestieLib:GetColoredQuestName(questId, profile.enableTooltipsQuestLevel, false)
                .. " " .. _G.Questie:Colorize("(" .. label .. ")", color))
        end
    end
    lastTooltipItem[tooltip] = { itemId = itemId, count = tooltip:NumLines() }
end

-- Hook the same two tooltips Questie's item handler hooks; ours registers later so its lines land under Questie's.
local tooltipHooksInstalled = false
local function installItemTooltipHooks()
    if tooltipHooksInstalled then
        return
    end
    tooltipHooksInstalled = true
    for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
        tooltip:HookScript("OnTooltipSetItem", addQuestLinesToItemTooltip)
        tooltip:HookScript("OnHide", function(self)
            lastTooltipItem[self] = nil
        end)
    end
end

-- Level-up toast: quests whose level requirement is exactly the new level, so each quest announces once. Gates mirror the discovery scan (doable, reachable starter, real zone) so the toast only names quests the panel would list.
local function announceNewQuests(newLevel)
    if not loadQuestie() then
        return
    end
    local currentLog = (QuestiePlayer and QuestiePlayer.currentQuestlog) or {}
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
            if zoneOrSort and passesClassicCaps(level, requiredLevel) then
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
    if UIErrorsFrame then
        UIErrorsFrame:AddMessage(toast, 1, 0.82, 0)
    end
    -- Zone names print as clickable addon links that open the panel at that zone. Same |Haddon:...|h pattern and link blue Questie uses for its debug offers; a sort-category bucket ("Other") carries no real area id, so it prints plain.
    local parts = {}
    for i = 1, math.min(#zones, 3) do
        local zoneName = zones[i]
        local areaId = zoneAreaIds[zoneName]
        local label = zoneName
        if areaId and areaId > 0 then
            label = "|cff71d5ff|Haddon:questieguide:zone:" .. areaId .. "|h[" .. zoneName .. "]|h|r"
        end
        parts[i] = string.format("%d in %s", counts[zoneName], label)
    end
    local more = #zones > 3 and string.format(" and %d more zones", #zones - 3) or ""
    print(INTRO_PREFIX .. "New quests at level " .. newLevel .. ": " .. table.concat(parts, ", ") .. more .. ".")
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:RegisterEvent("PLAYER_LEVEL_UP")
loader:RegisterEvent("QUEST_ACCEPTED")
loader:RegisterEvent("QUEST_REMOVED")
loader:RegisterEvent("QUEST_TURNED_IN")
loader:RegisterEvent("UNIT_QUEST_LOG_CHANGED")
loader:RegisterEvent("ZONE_CHANGED_NEW_AREA")
loader:SetScript("OnEvent", function(self, event, name)
    -- QUEST_LOG_UPDATE is deliberately absent: it fires on every objective tick and each fire costs a full DB rescan, while accept/remove/turn-in/level-up already cover everything that changes zone bucketing. Zone changes rescan too: the route seed is scan-time player position, and the current-zone header marker plus the Current Zone button read location at render.
    if event == "QUEST_ACCEPTED" or event == "QUEST_REMOVED" or event == "QUEST_TURNED_IN"
        or event == "PLAYER_LEVEL_UP" or event == "ZONE_CHANGED_NEW_AREA" then
        invalidateScan()
        scheduleRefresh()
        if event == "PLAYER_LEVEL_UP" then
            local newLevel = tonumber(name) or UnitLevel("player")
            -- Waits out the level-up celebration frame spike before walking the quest DB.
            C_Timer.After(1, function()
                announceNewQuests(newLevel)
            end)
        end
        return
    end
    -- Objective progress can flip a log quest to complete. Re-render only (the scan cache stays valid); the completed section reads live completeness each render.
    if event == "UNIT_QUEST_LOG_CHANGED" then
        if name == "player" then
            scheduleRefresh()
        end
        return
    end
    if event == "ADDON_LOADED" and name == ADDON_NAME then
        if type(QuestieGuideDB) ~= "table" then
            QuestieGuideDB = {}
        end
        QuestieGuideDB.minBelow = nil
        QuestieGuideDB.maxAbove = nil
        QuestieGuideDB.levelBelow = clampRange(QuestieGuideDB.levelBelow) or DEFAULTS.levelBelow
        QuestieGuideDB.levelAbove = clampRange(QuestieGuideDB.levelAbove) or DEFAULTS.levelAbove
        if type(QuestieGuideDB.useQuestieLevelRange) ~= "boolean" then
            QuestieGuideDB.useQuestieLevelRange = DEFAULTS.useQuestieLevelRange
        end
        if type(QuestieGuideDB.showCompleted) ~= "boolean" then
            QuestieGuideDB.showCompleted = DEFAULTS.showCompleted
        end
        if type(QuestieGuideDB.routeSort) ~= "boolean" then
            QuestieGuideDB.routeSort = DEFAULTS.routeSort
        end
        local validSort = false
        for _, opt in ipairs(SORT_BY_OPTIONS) do
            if QuestieGuideDB.sortMode == opt.value then
                validSort = true
                break
            end
        end
        if not validSort then
            QuestieGuideDB.sortMode = DEFAULTS.sortMode
        end
        local validDir = false
        for _, opt in ipairs(SORT_DIR_OPTIONS) do
            if QuestieGuideDB.sortDir == opt.value then
                validDir = true
                break
            end
        end
        if not validDir then
            QuestieGuideDB.sortDir = DEFAULTS.sortDir
        end
        -- One-time switch to the one-trip XP sort the zone recommendation is built around; the flag keeps any later manual sort choice untouched.
        if not QuestieGuideDB.oneTripSortApplied then
            QuestieGuideDB.oneTripSortApplied = true
            QuestieGuideDB.sortMode = "xp"
            QuestieGuideDB.sortDir = "desc"
        end
        if type(QuestieGuideDB.filters) ~= "table" then
            QuestieGuideDB.filters = {}
        end
        for key, defaultOn in pairs(DEFAULTS.filters) do
            if type(QuestieGuideDB.filters[key]) ~= "boolean" then
                QuestieGuideDB.filters[key] = defaultOn
            end
        end
        QuestieGuideDB.showNpcName = nil
        QuestieGuideDB.showCoords = nil
        -- Zone pinning was removed; the sort setting now governs every zone.
        QuestieGuideDB.pinCurrentZone = nil
        if type(QuestieGuideDB.frameSize) ~= "table" then
            QuestieGuideDB.frameSize = { w = DEFAULTS.frameSize.w, h = DEFAULTS.frameSize.h }
        end
        if type(QuestieGuideDB.zoneCollapsed) ~= "table" then
            QuestieGuideDB.zoneCollapsed = {}
        end
        if type(QuestieGuideDB.groupCollapsed) ~= "table" then
            QuestieGuideDB.groupCollapsed = {}
        end
        if type(QuestieGuideDB.minimap) ~= "table" then
            QuestieGuideDB.minimap = { hide = false, minimapPos = 215 }
        end
        QuestieGuideDB.showHidden = nil
        QuestieGuideDB.hiddenQuests = nil
    elseif event == "PLAYER_LOGIN" then
        setupMinimapButton()
        installItemTooltipHooks()
        installMapIconHooks()
        scheduleItemQuestIndexBuild()
    end
end)
