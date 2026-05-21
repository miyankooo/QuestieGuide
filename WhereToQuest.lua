-- WhereToQuest: zone-bucketed quest browser sourced from Questie.

local ADDON_NAME = ...

local DEFAULTS = {
    sortMode = "count",
    sortDir = "desc",
    filters = {
        inLog = true,
        available = true,
        pickedUpElsewhere = true,
        missingPre = true,
        dungeons = true,
        eliteGroup = true,
    },
    pinCurrentZone = true,
    framePos = nil,
    frameSize = { w = 360, h = 620 },
    zoneCollapsed = {},
    groupCollapsed = {},
    minimap = { hide = false, minimapPos = 215 },
    useQuestieLevelRange = false,
    levelBelow = 5,
    levelAbove = 5,
}

local LEVEL_RANGE_MIN = 0
local LEVEL_RANGE_MAX = 10

local INTRO_PREFIX = "|cffffff00[WhereToQuest]:|r "

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

local SUBCAT_ORDER = { "inLog", "available", "pickedUpElsewhere", "missingPre" }
local SUBCAT_LABEL = {
    inLog = "In Quest Log",
    available = "Available in Zone",
    pickedUpElsewhere = "Available Elsewhere",
    missingPre = "Missing Pre-Quest",
}

-- Layout grid: 8px outer chrome, 4px sub-grid for compact list rows.
local SPACING = {
    XS = 4,
    SM = 8,
    MD = 16,
    LG = 24,
}

local FRAME_WIDTH = 360
local FRAME_HEIGHT = 620

-- Outer frame padding and section rhythm.
local PAD_X = SPACING.MD
local PAD_TOP = 52               -- clears the dialog-box-header banner above the first section.
local PAD_BOTTOM = SPACING.LG
local SECTION_GAP = 22           -- clears the floating section label above the next box.
local ELEMENT_GAP = SPACING.SM
local SCROLLBAR_RESERVE = SPACING.LG
local SECTION_INNER_PAD = 12     -- inner padding for nested section boxes.
local SECTION_LABEL_LIFT = 7     -- lift of section label above its box's top edge.

-- Slider / dropdown alignment within a row. The "edge" margin and "center gap"
-- mirror the existing slider layout so dropdown rows visually match slider
-- rows. The new Menu API dropdowns are sized directly via SetWidth, so the
-- old UIDROPDOWNMENU_DEFAULT_WIDTH_PADDING math is no longer needed.
local ROW_EDGE_PAD = 0
local SLIDER_CENTER_HALF_GAP = 8           -- each slider sits this far from the row's centerline.
local DROPDOWN_VISIBLE_GAP = SLIDER_CENTER_HALF_GAP * 2  -- visible gap between adjacent dropdown frames (16, matching the sliders' total center gap).
local DROPDOWN_ROW_H = 28                  -- vertical room a dropdown row occupies.

-- List rhythm (rows use the 4px sub-grid for density).
local ROW_HEIGHT = SPACING.MD
local SUBHEADER_HEIGHT = SPACING.MD
local HEADER_HEIGHT = SPACING.LG
local ROW_GAP = SPACING.XS
local GROUP_GAP = SPACING.SM
local ZONE_GAP = SPACING.MD
local INDENT_STEP = SPACING.MD

-- Wrapping: row height grows with wrapped text; LINE_SPACING tunes legibility.
local ROW_PAD_V = 2
local LINE_SPACING = 3

local MAX_CHAIN_DEPTH = 12

-- Classic Era (1.15.x) caps at 60; reject post-vanilla quests Questie may ship.
local CLASSIC_MAX_LEVEL = 60

-- Questie modules; resolved lazily because Questie loads after us.
local QuestieDB
local QuestieLib
local ZoneDB
local QuestiePlayer
local QuestXP
local QuestieMap
local QuestieLink

local mainFrame
local scrollChild
local rowPool = {}
local lastZoneOrder = {}
local renderList
local searchText = ""
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

-- Native game color hex codes. RGB values mirror Classic Era's
-- QuestDifficultyColors (Blizzard_FrameXMLBase/Classic/Constants.lua) and
-- C_UIColor.GetColors() font color globals (HIGHLIGHT/GRAY/YELLOW/GREEN).
local COLOR = {
    WHITE  = "|cffffffff",
    GREY   = "|cff7f7f7f",
    YELLOW = "|cffffff00",
    GREEN  = "|cff00ff00",
    GOLD   = "|cffffd200",
    ORANGE = "|cffff8000",
}

local function getZoneCollapsed()
    return (WhereToQuestDB and WhereToQuestDB.zoneCollapsed) or {}
end

local function getGroupCollapsed()
    return (WhereToQuestDB and WhereToQuestDB.groupCollapsed) or {}
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
    return QuestieDB ~= nil and QuestieDB.QuestPointers ~= nil
end

-- The catch-all bucket for quests whose zoneOrSort is a sort category rather
-- than a real area id. Pinned to the bottom of the list by sortZones because
-- it's mostly noise (class quests, faction quests, profession quests, ...).
local OTHER_ZONE_NAME = "Other"

-- zoneOrSort > 0 is a Blizzard area ID; <= 0 is a sort category we collapse into "Other".
local function getZoneName(zoneOrSort)
    if not zoneOrSort or zoneOrSort <= 0 then
        return OTHER_ZONE_NAME
    end
    if C_Map and C_Map.GetAreaInfo then
        local name = C_Map.GetAreaInfo(zoneOrSort)
        if name then
            return name
        end
    end
    if ZoneDB then
        local dn = ZoneDB:GetLocalizedDungeonName(zoneOrSort)
        if dn then
            return dn
        end
    end
    return "Zone " .. zoneOrSort
end

local function getEffectiveLevel(questId, playerLevel)
    local level, requiredLevel = QuestieLib.GetTbcLevel(questId, playerLevel)
    if level and level > 0 then
        return level, requiredLevel or 0
    end
    return requiredLevel or 0, requiredLevel or 0
end

local function getQuestName(questId)
    return QuestieDB.QueryQuestSingle(questId, "name") or ("Quest " .. questId)
end

-- Returns name, zoneName, {x, y}, areaId for the quest's start source.
-- Questie's `startedBy` is a 3-tuple: [1] NPC ids, [2] object ids, [3] item ids.
-- Real NPC start: prefer a spawn in the quest's own zone (zoneOrSort) so the
-- labeled location matches the bucket; fall back to the smallest area id when
-- no spawn lives in the quest zone (deterministic, but arbitrary).
-- Object/item start (no NPC giver): use the quest's own zone as a best-effort
-- location and "Quest Item" as the generic giver name.
local function getQuestStartInfo(questId)
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
            local questZone = QuestieDB.QueryQuestSingle(questId, "zoneOrSort")
            local preferZoneId = (questZone and questZone > 0) and questZone or nil
            local preferredZoneId, preferredSpawn
            local fallbackZoneId, fallbackSpawn
            for zoneId, spawns in pairs(npc.spawns) do
                if type(spawns) == "table" and spawns[1] then
                    if preferZoneId and zoneId == preferZoneId then
                        preferredZoneId = zoneId
                        preferredSpawn = spawns[1]
                    elseif not fallbackZoneId or zoneId < fallbackZoneId then
                        fallbackZoneId = zoneId
                        fallbackSpawn = spawns[1]
                    end
                end
            end
            local bestZoneId = preferredZoneId or fallbackZoneId
            local bestSpawn = preferredSpawn or fallbackSpawn
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

-- Caches start info on the quest table so repeated row renders / clicks are cheap.
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

local HIGHLIGHT_PULSE_SCALE = 1.25
local HIGHLIGHT_PULSE_DIM = 0.55
local HIGHLIGHT_HALF_DURATION = 0.45
local HIGHLIGHT_PULSE_COUNT = 3

-- Combined scale + alpha "breathing" pulse on every Questie icon for the quest.
-- Scale and alpha run in parallel so the pin grows brighter at the peak; using
-- SetLooping("REPEAT") lets WoW reset the frame state between cycles cleanly,
-- which avoids the velocity discontinuities pure scale animation suffered from.
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

-- Some Classic Era UI maps (notably dungeon interiors) have no art layers and
-- crash Blizzard_MapCanvas when passed to SetMapID. Walk up to the first
-- ancestor that actually has art so we open something instead of erroring.
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
        local info = C_Map.GetMapInfo and C_Map.GetMapInfo(current)
        if not info or not info.parentMapID or info.parentMapID == 0 or info.parentMapID == current then
            return nil
        end
        current = info.parentMapID
    end
    return nil
end

local function openMapForQuest(quest)
    if not loadQuestie() then
        return
    end
    local info = resolveStartInfo(quest)
    if not info.areaId or not ZoneDB or not ZoneDB.GetUiMapIdByAreaId then
        if WorldMapFrame and not WorldMapFrame:IsShown() then
            ShowUIPanel(WorldMapFrame)
        end
        return
    end
    local uiMapId = ZoneDB:GetUiMapIdByAreaId(info.areaId)
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
    -- Spawn coords belong to the original uiMapId's coordinate space; only
    -- drop a waypoint when we're actually showing that map.
    if renderMapId == uiMapId and info.spawn and C_Map and C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates then
        pcall(function()
            C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(uiMapId, info.spawn[1] / 100, info.spawn[2] / 100))
            if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
                C_SuperTrack.SetSuperTrackedUserWaypoint(true)
            end
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
    local db = WhereToQuestDB or {}
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

-- True when the quest would render grey on the player (below Blizzard's
-- difficulty floor). Used when the slider band is bypassed so the list still
-- spans green to red instead of including every trivial quest in the DB.
local function isQuestTrivialForPlayer(questLevel, playerLevel)
    if not playerLevel or not questLevel or questLevel <= 0 then
        return false
    end
    local greenRange = (GetQuestGreenRange and GetQuestGreenRange("player")) or 5
    return (playerLevel - questLevel) > greenRange
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

-- Returns the active prereq table for a quest along with which type it is.
-- preQuestSingle (OR) takes precedence over preQuestGroup (AND); Questie treats them as exclusive.
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

-- Returns a list of chains [initial, ..., target] of incomplete prereqs.
-- preQuestSingle (OR) takes the first incomplete alternative; preQuestGroup
-- (AND) branches into one chain per incomplete prereq so the player sees
-- every initial they have to pick up, not just one arbitrary path.
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
        -- OR: any one prereq satisfies the gate, so the first incomplete option
        -- is enough. AND: every prereq must be done, so each becomes its own chain.
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

-- Buckets every quest into its zone. Expensive; caller should cache the result.
local function scanQuestsByZone()
    if not loadQuestie() then
        return {}, {}
    end
    local playerLevel = UnitLevel("player")
    local currentLog = (QuestiePlayer and QuestiePlayer.currentQuestlog) or {}
    local useQuestieLevelRange = WhereToQuestDB and WhereToQuestDB.useQuestieLevelRange and true or false
    local below, above = getLevelRange()

    -- Slider on: explicit band. Slider bypassed: defer to Questie's green-to-red
    -- range by only excluding trivial (grey) quests; everything green and above
    -- passes through to the doability checks below.
    local function passesLevelGate(level)
        if useQuestieLevelRange then
            return not isQuestTrivialForPlayer(level, playerLevel)
        end
        return isLevelInBand(level, playerLevel, below, above)
    end

    local byZone = {}

    local function ensureZone(zoneName)
        local entry = byZone[zoneName]
        if not entry then
            entry = {
                inLog = {},
                available = {},
                pickedUpElsewhere = {},
                missingPre = { order = {}, entries = {} },
                count = 0,
            }
            byZone[zoneName] = entry
        end
        return entry
    end

    local function passesClassicCaps(level, requiredLevel)
        return level <= CLASSIC_MAX_LEVEL and (requiredLevel or 0) <= CLASSIC_MAX_LEVEL
    end

    -- Quests already in the player's log bypass the level band (if they
    -- accepted it, they want to see it regardless of how far it has drifted
    -- from their current level) and ALWAYS go into "In Quest Log" for their
    -- zone. We deliberately do NOT split log quests by giver zone any more
    -- -- if it's in the log, it's in the log, period. "Picked Up Elsewhere"
    -- below is for the inverse case: quests not in the log whose giver sits
    -- outside the quest's own zone.
    for questId in pairs(currentLog) do
        local zoneOrSort = QuestieDB.QueryQuestSingle(questId, "zoneOrSort")
        local level, requiredLevel = getEffectiveLevel(questId, playerLevel)
        if zoneOrSort and passesClassicCaps(level, requiredLevel) then
            local entry = ensureZone(getZoneName(zoneOrSort))
            entry.inLog[#entry.inLog + 1] = {
                id = questId,
                level = level,
                name = getQuestName(questId),
                xp = getQuestXp(questId),
                tag = getQuestTagLabel(questId),
            }
            entry.count = entry.count + 1
        end
    end

    for questId in pairs(QuestieDB.QuestPointers) do
        if not currentLog[questId] and not isQuestCompleted(questId) then
            local level, requiredLevel = getEffectiveLevel(questId, playerLevel)
            -- The user's level slider (passesLevelGate) used to hard-filter
            -- here. We now keep out-of-range quests in the list and tag them
            -- so renderList can fade their rows; only the hard caps and the
            -- required-level gate still exclude quests entirely.
            if passesClassicCaps(level, requiredLevel)
                and meetsRequiredLevel(requiredLevel, playerLevel) then
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
                        -- Non-log quests where the giver NPC lives in another
                        -- zone go to "Picked Up Elsewhere" as a navigation
                        -- hint: the quest is set here but you'd need to go
                        -- somewhere else to start it. Quests with a giver in
                        -- this zone (or with no resolvable giver location)
                        -- stay under "Available".
                        local bucket = (giverZoneName and giverZoneName ~= questZoneName)
                            and entry.pickedUpElsewhere
                            or entry.available
                        bucket[#bucket + 1] = quest
                        entry.count = entry.count + 1
                    end
                elseif isBlockedByPrereqs(questId) and matchesPlayerFaction(questId) then
                    local zoneOrSort = QuestieDB.QueryQuestSingle(questId, "zoneOrSort")
                    if zoneOrSort then
                        -- Pick the shortest prereq chain. We don't require the
                        -- chain initial to be doable; if it is, its tooltip badge
                        -- shows `[Available]`, otherwise the chain is informational.
                        -- Each blocked quest contributes ONE row keyed by its own
                        -- questId — quests in `available` never reappear here.
                        local bestChain
                        for _, chain in ipairs(findMissingChains(questId)) do
                            if not bestChain or #chain < #bestChain then
                                bestChain = chain
                            end
                        end
                        if bestChain then
                            local entry = ensureZone(getZoneName(zoneOrSort))
                            entry.missingPre.entries[questId] = {
                                id = questId,
                                level = level,
                                name = getQuestName(questId),
                                tag = getQuestTagLabel(questId),
                                chain = bestChain,
                                outOfRange = outOfRange,
                            }
                            entry.missingPre.order[#entry.missingPre.order + 1] = questId
                            entry.count = entry.count + 1
                        end
                    end
                end
            end
        end
    end

    -- In-range quests sort above out-of-range so the actionable rows stay
    -- at the top of each bucket; faded rows sink below within the same
    -- level/name ordering.
    local function sortQuests(list)
        table.sort(list, function(a, b)
            if (a.outOfRange and true or false) ~= (b.outOfRange and true or false) then
                return not a.outOfRange
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
        sortQuests(entry.inLog)
        sortQuests(entry.available)
        sortQuests(entry.pickedUpElsewhere)
        table.sort(entry.missingPre.order, function(a, b)
            local ea, eb = entry.missingPre.entries[a], entry.missingPre.entries[b]
            if (ea.outOfRange and true or false) ~= (eb.outOfRange and true or false) then
                return not ea.outOfRange
            end
            if ea.level ~= eb.level then return ea.level < eb.level end
            return ea.name < eb.name
        end)

        local xpTotal = 0
        for _, q in ipairs(entry.inLog) do xpTotal = xpTotal + (q.xp or 0) end
        for _, q in ipairs(entry.available) do xpTotal = xpTotal + (q.xp or 0) end
        for _, q in ipairs(entry.pickedUpElsewhere) do xpTotal = xpTotal + (q.xp or 0) end
        local levelSum, levelCount = 0, 0
        for _, q in ipairs(entry.available) do
            if q.level and q.level > 0 then
                levelSum = levelSum + q.level
                levelCount = levelCount + 1
            end
        end
        entry.stats = {
            count = entry.count,
            xp = xpTotal,
            avgLevel = levelCount > 0 and (levelSum / levelCount) or nil,
        }
    end

    table.sort(zoneOrder)
    return byZone, zoneOrder
end

-- Apply the user's sort mode + direction in place. Cheap; safe to call every render.
-- Zones without a value for the chosen metric sort to the END regardless of
-- direction (so the player sees only zones with available quests at the top).
local function sortZones(zoneOrder, byZone)
    local mode = (WhereToQuestDB and WhereToQuestDB.sortMode) or DEFAULTS.sortMode
    local dir = (WhereToQuestDB and WhereToQuestDB.sortDir) or DEFAULTS.sortDir
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

    -- "Other" holds the sort-category catch-all (class/faction/profession
    -- quests with no real zoneOrSort). Pin it to the bottom regardless of the
    -- selected mode or direction since it's almost always noise compared to
    -- the real zones above it.
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

-- Questie's difficulty color (red/orange/yellow/green/grey) for the quest level.
-- Matches the color the name receives so the level brackets and name share a hue.
local function getDifficultyColorCode(level)
    local r, g, b = 1, 1, 1
    if QuestieLib and QuestieLib.GetDifficultyColorPercent then
        r, g, b = QuestieLib:GetDifficultyColorPercent(level)
    end
    return string.format("|cff%02x%02x%02x",
        math.floor(r * 255), math.floor(g * 255), math.floor(b * 255))
end

-- Two-line row presentation:
--   [LVL] [TYPE] QUEST_NAME [badge?]
--   QUEST_GIVER_LOCATION, QUEST_GIVER_NAME
-- Level and quest name share Questie's difficulty color; the type tag keeps
-- its native quality color (orange for Elite, purple for Dungeon). The whole
-- giver line is grey (location, comma, and NPC name together) so it sits as
-- a single subtle subtitle under the title. `badge` is appended after the
-- quest name on line 1 when provided (used by the chain tooltip).
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
        local info = resolveStartInfo(quest)
        if info and (info.zoneName or info.npcName) then
            local parts = {}
            if info.zoneName then parts[#parts + 1] = info.zoneName end
            if info.npcName then parts[#parts + 1] = info.npcName end
            line2 = COLOR.GREY .. table.concat(parts, ", ") .. "|r"
        end
    end
    return line1, line2
end

local function formatRowLabel(level, name, quest)
    local line1, line2 = formatRowLines(level, name, quest, nil)
    if line2 then
        return line1 .. "\n" .. line2
    end
    return line1
end

-- Status badge for prior quests in the chain tooltip. `[In Progress]` (yellow)
-- if the player has the quest in their log, `[Available]` (green) if it can be
-- picked up right now, otherwise no badge. Completed quests don't appear in
-- the chain at all (findMissingChains skips them).
local function getStatusBadge(questId)
    local currentLog = (QuestiePlayer and QuestiePlayer.currentQuestlog) or {}
    if currentLog[questId] then
        return COLOR.YELLOW .. "[In Progress]|r"
    end
    if QuestieDB and QuestieDB.IsDoable and QuestieDB.IsDoable(questId) then
        return COLOR.GREEN .. "[Available]|r"
    end
    return nil
end

-- Lightweight quest spec for formatRowLines callers that don't already have
-- a list-row table on hand (i.e. the chain tooltip).
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

    -- Title: the hovered (blocked) quest. The tooltip's first AddLine uses the
    -- larger title font, so the hovered quest naturally stands out above the
    -- prior-quests list.
    local diff = getDifficultyColorCode(mpe.level)
    local title = string.format("%s[%d] %s|r", diff, mpe.level or 0, mpe.name or "")
    if mpe.tag then
        local tagColor = QUEST_TAG_COLORS[mpe.tag] or "ff8000"
        title = title .. " |cff" .. tagColor .. "[" .. mpe.tag .. "]|r"
    end
    GameTooltip:AddLine(title)

    local info = resolveStartInfo(mpe)
    if info and (info.zoneName or info.npcName) then
        local parts = {}
        if info.zoneName then parts[#parts + 1] = info.zoneName end
        if info.npcName then parts[#parts + 1] = info.npcName end
        GameTooltip:AddLine(COLOR.GREY .. table.concat(parts, ", ") .. "|r", 1, 1, 1, true)
    end

    GameTooltip:AddLine(" ")

    -- Prior quests that must be completed before the hovered quest unlocks.
    -- The hovered quest itself is the chain tail (chain[#chain]); skip it.
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
        -- Pool rows persist across renders; reset alpha so a row that was
        -- previously used for an out-of-range quest doesn't carry the
        -- dimmed look forward when it's reused for a header or in-range
        -- quest. renderQuestRow overrides this for actual fading rows.
        row:SetAlpha(1)
        return row
    end
    row = CreateFrame("Button", nil, scrollChild)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("LEFT", scrollChild, "LEFT", 0, 0)
    row:SetPoint("RIGHT", scrollChild, "RIGHT", 0, 0)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row.text = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    -- Anchor text from the top so wrapped lines grow downward; row height is
    -- sized to fit the measured text + ROW_PAD_V padding (see renderList).
    row.text:SetPoint("TOPLEFT", row, "TOPLEFT", SPACING.XS, -ROW_PAD_V)
    row.text:SetPoint("TOPRIGHT", row, "TOPRIGHT", -SPACING.XS, -ROW_PAD_V)
    row.text:SetJustifyH("LEFT")
    row.text:SetJustifyV("TOP")
    row.text:SetWordWrap(true)
    row.text:SetSpacing(LINE_SPACING)
    row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
    row.highlight:SetAllPoints(true)
    row.highlight:SetColorTexture(1, 1, 1, 0.08)
    rowPool[index] = row
    return row
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

local function getPlayerZoneName()
    if not C_Map or not C_Map.GetBestMapForUnit then
        return nil
    end
    local uiMapId = C_Map.GetBestMapForUnit("player")
    if not uiMapId or not C_Map.GetMapInfo then
        return nil
    end
    local info = C_Map.GetMapInfo(uiMapId)
    return info and info.name or nil
end

-- Forward declarations resolved later.
local showQuestContextMenu
local showChainContextMenu

-- Questie's plain-text share format: receivers running Questie convert the
-- pattern into a rich |Hquestie:id:guid|h hyperlink via its chat filter, while
-- non-Questie users still see a readable "[[level] Name (id)]" string.
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

-- Context menus use the modern Menu API (MenuUtil.CreateContextMenu). The
-- legacy UIDropDownMenu/EasyMenu path was replaced because it shared globals
-- (UIDROPDOWNMENU_INIT_MENU, UIDROPDOWNMENU_OPEN_MENU, DropDownList1/2) with
-- Blizzard's secure dropdowns; opening one from our insecure code tainted
-- Blizzard_GroupFinder_VanillaStyle's category dropdown init in
-- LFGBrowseMixin:SearchActiveEntry, blocking the subsequent C_LFGList.Search.
function showQuestContextMenu(anchor, quest)
    MenuUtil.CreateContextMenu(anchor, function(_, rootDescription)
        rootDescription:CreateTitle(quest.name)
        rootDescription:CreateButton("Show on map", function() openMapForQuest(quest) end)
        rootDescription:CreateButton("Link in chat", function() linkQuestInChat(quest) end)
    end)
end

function showChainContextMenu(anchor, mpe)
    -- "Show on map" jumps to the next actionable step (the chain's initial),
    -- since the blocked quest itself isn't pickup-able yet. "Link in chat"
    -- links the blocked quest (the row the player is hovering).
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

function renderList()
    if not scrollChild then
        return
    end
    local byZone, zoneOrder = ensureScan()
    sortZones(zoneOrder, byZone)
    lastZoneOrder = zoneOrder
    local filters = (WhereToQuestDB and WhereToQuestDB.filters) or DEFAULTS.filters
    local index = 1
    local y = 0
    local renderedZones = 0

    -- Two-anchor (TOPLEFT + TOPRIGHT) placement: x-range comes from the
    -- horizontal span, top y from the shared y offset, height from sizeRow.
    -- Using three anchors (LEFT/RIGHT/TOP) over-constrains the vertical center
    -- and resolves inconsistently between the first paint and subsequent
    -- layout passes, which is what produced the post-reload offset.
    local function placeRow(row, indent)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", indent, -y)
        row:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", 0, -y)
    end

    -- Sizes the row to fit its wrapped text; minHeight keeps short rows on the grid.
    -- The text fontstring already has LEFT/RIGHT anchors inside the row, so wrap
    -- width is bounded and GetStringHeight reflects the wrapped result.
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

    local function renderQuestRow(label, onEnter, onLeftClick, onRightClick, onShiftClick, alpha)
        y = y + ROW_GAP
        local row = acquireRow(index)
        placeRow(row, INDENT_STEP * 2)
        -- Rows are pooled and reused across renders, so always reset alpha
        -- explicitly. Out-of-range quests pass 0.5 to dim the row.
        row:SetAlpha(alpha or 1)
        row.text:SetText(label)
        row:SetScript("OnEnter", onEnter)
        row:SetScript("OnLeave", hideGameTooltip)
        if onLeftClick or onRightClick or onShiftClick then
            row:SetScript("OnClick", function(self, btn)
                if btn == "LeftButton" and IsModifiedClick and IsModifiedClick("CHATLINK") then
                    if onShiftClick then onShiftClick(self) end
                elseif btn == "RightButton" then
                    if onRightClick then onRightClick(self) end
                else
                    if onLeftClick then onLeftClick(self) end
                end
            end)
        else
            row:SetScript("OnClick", nil)
        end
        y = y + sizeRow(row, ROW_HEIGHT)
        index = index + 1
    end

    local zoneCollapsedDB = getZoneCollapsed()
    local groupCollapsedDB = getGroupCollapsed()
    local pinCurrentZone = WhereToQuestDB and WhereToQuestDB.pinCurrentZone
    local playerZone = pinCurrentZone and getPlayerZoneName() or nil
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
        local info = resolveStartInfo(quest)
        if info and searchMatches(info.npcName) then
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
        -- Match any step in the chain so typing the name of a prereq surfaces
        -- the quest that unlocks behind it.
        if type(mpe.chain) == "table" then
            for _, qid in ipairs(mpe.chain) do
                if searchMatches(getQuestName(qid)) then
                    return true
                end
            end
        end
        return false
    end

    -- Reorder so the player's current zone floats to the top when pinning is on.
    if playerZone then
        local reordered = { playerZone }
        for _, name in ipairs(zoneOrder) do
            if name ~= playerZone then
                reordered[#reordered + 1] = name
            end
        end
        if byZone[playerZone] then
            zoneOrder = reordered
        end
    end

    for _, zoneName in ipairs(zoneOrder) do
        local entry = byZone[zoneName]
        if entry then
            local collapsed = zoneCollapsedDB[zoneName] == true
            local zoneMatch = searchMatches(zoneName)

            -- Initialise one empty list per declared subcategory so iterating
            -- SUBCAT_ORDER below never lands on a nil bucket if a future key is
            -- added.
            local visible = {}
            for _, subKey in ipairs(SUBCAT_ORDER) do
                visible[subKey] = {}
            end
            if filters.inLog then
                for _, q in ipairs(entry.inLog or {}) do
                    if passesQuest(q, zoneMatch) then
                        visible.inLog[#visible.inLog + 1] = q
                    end
                end
            end
            if filters.available then
                for _, q in ipairs(entry.available or {}) do
                    if passesQuest(q, zoneMatch) then
                        visible.available[#visible.available + 1] = q
                    end
                end
            end
            if filters.pickedUpElsewhere then
                for _, q in ipairs(entry.pickedUpElsewhere or {}) do
                    if passesQuest(q, zoneMatch) then
                        visible.pickedUpElsewhere[#visible.pickedUpElsewhere + 1] = q
                    end
                end
            end
            if filters.missingPre and entry.missingPre and entry.missingPre.order then
                for _, blockedId in ipairs(entry.missingPre.order) do
                    local mpe = entry.missingPre.entries[blockedId]
                    if mpe and passesChain(mpe, zoneMatch) then
                        visible.missingPre[#visible.missingPre + 1] = mpe
                    end
                end
            end

            local visibleTotal = 0
            for _, subKey in ipairs(SUBCAT_ORDER) do
                visibleTotal = visibleTotal + #visible[subKey]
            end
            if visibleTotal > 0 then
                if renderedZones > 0 then
                    y = y + ZONE_GAP
                end
                renderedZones = renderedZones + 1

                local visibleXp = 0
                for _, q in ipairs(visible.available) do visibleXp = visibleXp + (q.xp or 0) end
                for _, q in ipairs(visible.inLog) do visibleXp = visibleXp + (q.xp or 0) end
                for _, q in ipairs(visible.pickedUpElsewhere) do visibleXp = visibleXp + (q.xp or 0) end

                local header = acquireRow(index)
                placeRow(header, 0)
                local arrow = collapsed and "|cffffd200[+]|r " or "|cffffd200[-]|r "
                local summary = " (" .. visibleTotal .. ")"
                if visibleXp > 0 then
                    local xpMax = (UnitXPMax and UnitXPMax("player")) or 0
                    if xpMax > 0 then
                        local pct = math.floor(visibleXp / xpMax * 100 + 0.5)
                        summary = summary .. string.format(" %s%s total XP (%d%% of current level)|r",
                            COLOR.GREY, formatNumber(visibleXp), pct)
                    else
                        summary = summary .. string.format(" %s%s total XP|r",
                            COLOR.GREY, formatNumber(visibleXp))
                    end
                end
                header.text:SetText(arrow .. zoneName .. summary)
                header:SetScript("OnClick", function()
                    zoneCollapsedDB[zoneName] = not collapsed
                    renderList()
                end)
                header:SetScript("OnEnter", nil)
                header:SetScript("OnLeave", nil)
                y = y + sizeRow(header, HEADER_HEIGHT)
                index = index + 1

                if not collapsed then
                    local subIndex = 0
                    for _, subKey in ipairs(SUBCAT_ORDER) do
                        local list = visible[subKey] or {}
                        if filters[subKey] and #list > 0 then
                            subIndex = subIndex + 1
                            local groupKey = zoneName .. "||" .. subKey
                            local groupHidden = groupCollapsedDB[groupKey] == true

                            y = y + (subIndex == 1 and ROW_GAP or GROUP_GAP)

                            local sub = acquireRow(index)
                            placeRow(sub, INDENT_STEP)
                            local subArrow = groupHidden and "[+]" or "[-]"
                            sub.text:SetText(string.format("|cff9d9d9d%s %s (%d)|r",
                                subArrow, SUBCAT_LABEL[subKey], #list))
                            sub:SetScript("OnClick", function()
                                groupCollapsedDB[groupKey] = not groupHidden
                                renderList()
                            end)
                            sub:SetScript("OnEnter", nil)
                            sub:SetScript("OnLeave", nil)
                            y = y + sizeRow(sub, SUBHEADER_HEIGHT)
                            index = index + 1

                            if not groupHidden then
                                if subKey == "missingPre" then
                                    for _, mpe in ipairs(list) do
                                        -- Row is the blocked quest itself. Map jumps to the
                                        -- next actionable step (chain[1]); chat link points
                                        -- at the blocked quest (the row being hovered).
                                        local initial = mpe._initial
                                        if not initial then
                                            initial = { id = mpe.chain and mpe.chain[1] }
                                            mpe._initial = initial
                                        end
                                        local label = formatRowLabel(mpe.level, mpe.name, mpe)
                                        renderQuestRow(label,
                                            function(self) showChainTooltip(self, mpe) end,
                                            function() openMapForQuest(initial) end,
                                            function(self) if showChainContextMenu then showChainContextMenu(self, mpe) end end,
                                            function() linkQuestInChat(mpe) end,
                                            mpe.outOfRange and 0.5 or 1)
                                    end
                                else
                                    for _, quest in ipairs(list) do
                                        local label = formatRowLabel(quest.level, quest.name, quest)
                                        renderQuestRow(label,
                                            function(self) showQuestTooltip(self, quest.id) end,
                                            function() openMapForQuest(quest) end,
                                            function(self) if showQuestContextMenu then showQuestContextMenu(self, quest) end end,
                                            function() linkQuestInChat(quest) end,
                                            quest.outOfRange and 0.5 or 1)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if renderedZones == 0 then
        local anyBucket = filters.inLog or filters.available or filters.pickedUpElsewhere or filters.missingPre
        local msg
        if not anyBucket then
            msg = "All quest filters are off. Enable In Quest Log, Available, Picked Up Elsewhere, or Missing Prerequisite to see quests."
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
        y = y + sizeRow(row, ROW_HEIGHT * 2)
        index = index + 1
    end

    scrollChild:SetHeight(math.max(y, 1))
    hideUnusedRows(index)

    if mainFrame and mainFrame.toggleAllButton then
        local allCollapsed = #zoneOrder > 0
        for _, zoneName in ipairs(zoneOrder) do
            if not zoneCollapsedDB[zoneName] then
                allCollapsed = false
                break
            end
        end
        mainFrame.toggleAllButton:SetText(allCollapsed and "Expand" or "Collapse")
    end
end

-- Native Blizzard dialog-frame backdrop (matches AceGUI Frame, which is what
-- Questie's options panel uses). DialogBox-Border has the metallic look with
-- decorative corners; DialogBox-Background is the standard tan parchment.
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

-- Native Blizzard dialog-box header banner (Interface\DialogFrame\UI-DialogBox-Header)
-- composed as three texture pieces (left cap, repeating middle, right cap),
-- centered at the parent's top edge and overlapping into the frame interior.
-- Same texture coords AceGUI uses for its Frame title.
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

-- Lays out N WowStyle2DropdownTemplate dropdowns side by side inside `row`,
-- flush with the row edges, with DROPDOWN_VISIBLE_GAP between adjacent
-- dropdowns. The section body already provides symmetric padding around the
-- row, so no extra edge inset is added here. Call from row:HookScript(
-- "OnSizeChanged", ...) so the row stays responsive to frame resizes.
local function layoutDropdownRow(dropdowns, row)
    local n = #dropdowns
    if n == 0 then return end
    local w = row:GetWidth()
    if w <= 1 then return end

    local frameW = math.max(80, (w - (n - 1) * DROPDOWN_VISIBLE_GAP) / n)

    local x = 0
    for _, d in ipairs(dropdowns) do
        d:SetWidth(frameW)
        d:ClearAllPoints()
        d:SetPoint("TOPLEFT", row, "TOPLEFT", x, 0)
        x = x + frameW + DROPDOWN_VISIBLE_GAP
    end
end

-- Nested section box (matches AceGUI InlineGroup): flat dark bg + tooltip border.
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
    label:SetPoint("BOTTOMLEFT", section, "TOPLEFT", 12, SECTION_LABEL_LIFT)
    label:SetText(labelText)
    section.label = label

    local body = CreateFrame("Frame", nil, section)
    body:SetPoint("TOPLEFT", section, "TOPLEFT", SECTION_INNER_PAD, -SECTION_INNER_PAD)
    body:SetPoint("BOTTOMRIGHT", section, "BOTTOMRIGHT", -SECTION_INNER_PAD, SECTION_INNER_PAD)
    section.body = body

    return section
end

-- Layout model
-- ------------
-- The frame contains exactly one `content` container, inset from the frame by
-- PAD_X on the sides, PAD_TOP at the top (clears the title banner), PAD_BOTTOM
-- at the bottom. Every section is a `buildSection` box (a bordered child with
-- a floating label and an inner `body` frame) and is anchored via a single
-- helper, `stack(element, gap)`, which pins TOPLEFT to the previous element's
-- BOTTOMLEFT and RIGHT to `content`'s RIGHT. Each section determines its own
-- height; vertical position follows automatically.
--
-- The quest list lives in the final section (`questsSection`), which is
-- anchored both TOP (below the previous section) and BOTTOM (to content), so
-- it fills the remaining vertical space regardless of frame size.

local function buildMainFrame()
    if mainFrame then
        return mainFrame
    end

    local frame = CreateFrame("Frame", "WhereToQuestFrame", UIParent, "BackdropTemplate")
    local savedSize = (WhereToQuestDB and WhereToQuestDB.frameSize) or DEFAULTS.frameSize
    frame:SetSize(savedSize.w or FRAME_WIDTH, savedSize.h or FRAME_HEIGHT)
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:SetResizable(true)
    if frame.SetResizeBounds then
        frame:SetResizeBounds(320, 380, 720, 960)
    elseif frame.SetMinResize then
        frame:SetMinResize(320, 380)
        frame:SetMaxResize(720, 960)
    end
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint(1)
        WhereToQuestDB.framePos = { point = point, relPoint = relPoint, x = x, y = y }
    end)
    applyPanelBackdrop(frame)

    local savedPos = WhereToQuestDB and WhereToQuestDB.framePos
    if type(savedPos) == "table" and savedPos.point then
        frame:ClearAllPoints()
        frame:SetPoint(savedPos.point, UIParent, savedPos.relPoint or savedPos.point, savedPos.x or 0, savedPos.y or 0)
    else
        frame:SetPoint("CENTER")
    end
    frame:Hide()

    buildTitleHeader(frame, "WhereToQuest")

    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)

    -- The single content container. Every section anchors inside this; nothing
    -- outside this is sized by the section chain.
    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD_X, -PAD_TOP)
    content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD_X, PAD_BOTTOM)

    -- Stacks the element below the previous one with a chosen gap. The first
    -- element (prev == nil) docks to content's top-left.
    local lastInStack
    local function stack(element, gap)
        element:ClearAllPoints()
        if lastInStack then
            element:SetPoint("TOPLEFT", lastInStack, "BOTTOMLEFT", 0, -(gap or SECTION_GAP))
        else
            element:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
        end
        element:SetPoint("RIGHT", content, "RIGHT", 0, 0)
        lastInStack = element
    end

    -- Creates a nested section box, stacks it inside `content`, and returns
    -- the section frame so callers can parent widgets to `section.body` and
    -- set the section's height once its content is sized. Nil gap falls back
    -- to `stack`'s SECTION_GAP default; the first section ignores the gap
    -- because there is no previous element to anchor below.
    local function makeSection(text, gap)
        local section = buildSection(content, text)
        stack(section, gap)
        return section
    end

    -- 1) Quest Level Range section: a "Use Questie Level Ranges" checkbox sits
    -- above the slider pair. When the checkbox is ticked, the sliders disable
    -- and the scan bypasses the band filter (see passesLevelGate).
    local rangeSection = makeSection("Quest Level Range")
    local RANGE_CHECKBOX_HEIGHT = 22
    local RANGE_CHECKBOX_GAP = 6
    local RANGE_SLIDER_LABEL_PAD = 4
    -- Original slider top offset (14) plus space cleared by the checkbox row above it.
    local RANGE_SLIDER_TOP_OFFSET = RANGE_CHECKBOX_HEIGHT + RANGE_CHECKBOX_GAP + 14
    local RANGE_HEIGHT_EXPANDED = SPACING.LG * 2 + SECTION_INNER_PAD * 2 + RANGE_CHECKBOX_HEIGHT + RANGE_CHECKBOX_GAP
    local RANGE_HEIGHT_COLLAPSED = SECTION_INNER_PAD * 2 + RANGE_CHECKBOX_HEIGHT
    rangeSection:SetHeight(RANGE_HEIGHT_EXPANDED)
    local rangeRow = rangeSection.body

    local useQuestieCheckbox = CreateFrame("CheckButton", "WhereToQuestUseQuestieLevelRange", rangeRow, "UICheckButtonTemplate")
    useQuestieCheckbox:SetSize(RANGE_CHECKBOX_HEIGHT, RANGE_CHECKBOX_HEIGHT)
    useQuestieCheckbox:SetPoint("TOPLEFT", rangeRow, "TOPLEFT", ROW_EDGE_PAD, 0)
    local useQuestieLabel = _G[useQuestieCheckbox:GetName() .. "Text"]
    if useQuestieLabel then
        useQuestieLabel:SetFontObject("GameFontNormal")
        useQuestieLabel:SetText("Use Questie Level Ranges")
    end

    local sliderCounter = 0
    local function buildRangeSlider(parent, labelPrefix, dbKey)
        sliderCounter = sliderCounter + 1
        local name = "WhereToQuestRangeSlider" .. sliderCounter
        local slider = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
        -- Width is determined by the caller's TOPLEFT/TOPRIGHT anchors so the
        -- two sliders fill the row.
        slider:SetHeight(18)
        slider:SetMinMaxValues(LEVEL_RANGE_MIN, LEVEL_RANGE_MAX)
        slider:SetValueStep(1)
        slider:SetObeyStepOnDrag(true)
        local low = _G[name .. "Low"]
        local high = _G[name .. "High"]
        local text = _G[name .. "Text"]
        if low then low:SetText(tostring(LEVEL_RANGE_MIN)) end
        if high then high:SetText(tostring(LEVEL_RANGE_MAX)) end
        if text then
            text:ClearAllPoints()
            text:SetPoint("BOTTOM", slider, "TOP", 0, RANGE_SLIDER_LABEL_PAD)
        end
        slider._labelPrefix = labelPrefix
        slider._dbKey = dbKey
        slider._text = text
        local initial = clampRange(WhereToQuestDB and WhereToQuestDB[dbKey]) or DEFAULTS[dbKey]
        slider:SetValue(initial)
        if text then text:SetText(labelPrefix .. initial) end
        slider:SetScript("OnValueChanged", function(self, value)
            local v = clampRange(value)
            if not v then return end
            if self._text then
                self._text:SetText(self._labelPrefix .. v)
            end
            local cur = WhereToQuestDB and WhereToQuestDB[self._dbKey]
            if cur == v then return end
            WhereToQuestDB[self._dbKey] = v
            invalidateScan()
            renderList()
        end)
        return slider
    end

    local belowSlider = buildRangeSlider(rangeRow, "Quest Level Below: -", "levelBelow")
    belowSlider:SetPoint("TOPLEFT", rangeRow, "TOPLEFT", ROW_EDGE_PAD, -RANGE_SLIDER_TOP_OFFSET)
    belowSlider:SetPoint("TOPRIGHT", rangeRow, "TOP", -SLIDER_CENTER_HALF_GAP, -RANGE_SLIDER_TOP_OFFSET)

    local aboveSlider = buildRangeSlider(rangeRow, "Quest Level Above: +", "levelAbove")
    aboveSlider:SetPoint("TOPLEFT", rangeRow, "TOP", SLIDER_CENTER_HALF_GAP, -RANGE_SLIDER_TOP_OFFSET)
    aboveSlider:SetPoint("TOPRIGHT", rangeRow, "TOPRIGHT", -ROW_EDGE_PAD, -RANGE_SLIDER_TOP_OFFSET)

    frame.belowSlider = belowSlider
    frame.aboveSlider = aboveSlider

    -- Sliders disappear (and the section shrinks) when Questie's range governs,
    -- freeing vertical room for the quest list below.
    local function applySliderLock(locked)
        if locked then
            belowSlider:Hide()
            aboveSlider:Hide()
            rangeSection:SetHeight(RANGE_HEIGHT_COLLAPSED)
        else
            belowSlider:Show()
            aboveSlider:Show()
            belowSlider:Enable()
            aboveSlider:Enable()
            rangeSection:SetHeight(RANGE_HEIGHT_EXPANDED)
        end
    end

    useQuestieCheckbox:SetChecked(WhereToQuestDB and WhereToQuestDB.useQuestieLevelRange and true or false)
    applySliderLock(useQuestieCheckbox:GetChecked())
    useQuestieCheckbox:SetScript("OnClick", function(self)
        local checked = self:GetChecked() and true or false
        WhereToQuestDB.useQuestieLevelRange = checked
        applySliderLock(checked)
        invalidateScan()
        renderList()
    end)
    frame.useQuestieCheckbox = useQuestieCheckbox

    frame.refreshRangeSliders = function()
        local useQuestie = WhereToQuestDB and WhereToQuestDB.useQuestieLevelRange and true or false
        useQuestieCheckbox:SetChecked(useQuestie)
        applySliderLock(useQuestie)
        local below, above = getLevelRange()
        belowSlider:SetValue(below)
        if belowSlider._text then belowSlider._text:SetText(belowSlider._labelPrefix .. below) end
        aboveSlider:SetValue(above)
        if aboveSlider._text then aboveSlider._text:SetText(aboveSlider._labelPrefix .. above) end
    end

    -- 2) Filters section: three native multi-select dropdowns laid out in a
    -- 2+1 grid (Availability + Quest Types on the top row, Zone & NPCs full
    -- width on the bottom row) so each dropdown stays wide enough to be
    -- readable inside the default panel width. Opening a dropdown lists its
    -- toggles as checkboxes (`info.isNotRadio` + `info.keepShownOnClick`).
    -- Quest-tag filters live under `WhereToQuestDB.filters`; display toggles
    -- live as top-level keys, so each group declares its own get/set.
    local filtersSection = makeSection("Filters")
    local filtersBody = filtersSection.body

    local function getFilterValue(key)
        local f = WhereToQuestDB and WhereToQuestDB.filters
        if f and f[key] ~= nil then return f[key] and true or false end
        return DEFAULTS.filters[key] and true or false
    end
    local function setFilterValue(key, value)
        WhereToQuestDB.filters = WhereToQuestDB.filters or {}
        WhereToQuestDB.filters[key] = value and true or false
    end

    local function getToggleValue(key)
        local v = WhereToQuestDB and WhereToQuestDB[key]
        if v == nil then v = DEFAULTS[key] end
        return v and true or false
    end
    local function setToggleValue(key, value)
        WhereToQuestDB[key] = value and true or false
    end

    local FILTER_GROUPS = {
        {
            title = "Availability",
            get = getFilterValue,
            set = setFilterValue,
            specs = {
                { key = "inLog",             label = "In Quest Log" },
                { key = "available",         label = "Available in Zone" },
                { key = "pickedUpElsewhere", label = "Available Elsewhere" },
                { key = "missingPre",        label = "Missing Pre-Quest" },
            },
        },
        {
            title = "Quest Types",
            get = getFilterValue,
            set = setFilterValue,
            specs = {
                { key = "dungeons",   label = "Dungeons" },
                { key = "eliteGroup", label = "Elite/Group Quests" },
            },
        },
        {
            title = "Zones",
            get = getToggleValue,
            set = setToggleValue,
            specs = {
                { key = "pinCurrentZone", label = "Pin Current Zone" },
            },
        },
    }

    -- Two row frames inside the section body so the dropdowns can flow as 2+1.
    local FILTER_ROW_GAP = SPACING.SM
    local filtersTopRow = CreateFrame("Frame", nil, filtersBody)
    filtersTopRow:SetHeight(DROPDOWN_ROW_H)
    filtersTopRow:SetPoint("TOPLEFT", filtersBody, "TOPLEFT", 0, 0)
    filtersTopRow:SetPoint("RIGHT", filtersBody, "RIGHT", 0, 0)

    local filtersBottomRow = CreateFrame("Frame", nil, filtersBody)
    filtersBottomRow:SetHeight(DROPDOWN_ROW_H)
    filtersBottomRow:SetPoint("TOPLEFT", filtersTopRow, "BOTTOMLEFT", 0, -FILTER_ROW_GAP)
    filtersBottomRow:SetPoint("RIGHT", filtersBody, "RIGHT", 0, 0)

    local filterDropdowns = {}
    local function buildFilterDropdown(parent, i, group)
        local dd = CreateFrame("DropdownButton", "WhereToQuestFilterDropdown" .. i, parent, "WowStyle2DropdownTemplate")
        -- Keep the button text fixed at the group title; the multi-select
        -- nature of these dropdowns means we'd otherwise show a long
        -- comma-separated list of every enabled subfilter, which doesn't fit
        -- the narrow column. OverrideText sets disableSelectionText, so the
        -- DropdownSelectionTextMixin won't replace it as checkboxes toggle.
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

    filterDropdowns[1] = buildFilterDropdown(filtersTopRow, 1, FILTER_GROUPS[1])
    filterDropdowns[2] = buildFilterDropdown(filtersTopRow, 2, FILTER_GROUPS[2])
    filterDropdowns[3] = buildFilterDropdown(filtersBottomRow, 3, FILTER_GROUPS[3])
    frame.filterDropdowns = filterDropdowns

    local function layoutFilterRows()
        layoutDropdownRow({ filterDropdowns[1], filterDropdowns[2] }, filtersTopRow)
        layoutDropdownRow({ filterDropdowns[3] }, filtersBottomRow)
    end
    filtersTopRow:HookScript("OnSizeChanged", layoutFilterRows)

    filtersSection:SetHeight(DROPDOWN_ROW_H * 2 + FILTER_ROW_GAP + SECTION_INNER_PAD * 2)

    -- The dropdowns reread their `checked` state from the DB each time the
    -- menu opens (init runs per-open), so no per-checkbox refresh is needed.
    -- These hooks are no-ops kept to preserve the public refresh contract.
    frame.refreshFilters = function() end
    frame.refreshToggles = function() end

    -- 3) Sorting section: sort-by dropdown + direction dropdown, side by side
    -- filling the row, matching the Quest Level Range sliders' layout.
    local sortingSection = makeSection("Sorting")
    sortingSection:SetHeight(DROPDOWN_ROW_H + SECTION_INNER_PAD * 2)
    local sortRow = sortingSection.body

    -- Builds a single-select dropdown that reads/writes one DB key. The
    -- button text reflects the currently selected option via the
    -- DropdownSelectionTextMixin (defaultText shows when nothing matches).
    local function buildSortDropdown(parent, name, dbKey, options, defaultLabel)
        local dd = CreateFrame("DropdownButton", name, parent, "WowStyle2DropdownTemplate")
        dd:SetDefaultText(defaultLabel)
        dd:SetupMenu(function(_, rootDescription)
            for _, opt in ipairs(options) do
                rootDescription:CreateRadio(
                    opt.label,
                    function()
                        return ((WhereToQuestDB and WhereToQuestDB[dbKey]) or DEFAULTS[dbKey]) == opt.value
                    end,
                    function()
                        WhereToQuestDB[dbKey] = opt.value
                        renderList()
                    end)
            end
        end)
        return dd
    end

    local sortByDropdown = buildSortDropdown(sortRow, "WhereToQuestSortByDropdown", "sortMode", SORT_BY_OPTIONS, "Sort By")
    local sortDirDropdown = buildSortDropdown(sortRow, "WhereToQuestSortDirDropdown", "sortDir", SORT_DIR_OPTIONS, "Direction")

    local function layoutSortRow() layoutDropdownRow({ sortByDropdown, sortDirDropdown }, sortRow) end
    sortRow:HookScript("OnSizeChanged", layoutSortRow)

    frame.sortByDropdown = sortByDropdown
    frame.sortDirDropdown = sortDirDropdown
    -- The button text is driven by DropdownSelectionTextMixin via the
    -- per-option `isSelected` callbacks, so no manual refresh is required.
    frame.refreshSortDropdown = function()
        sortByDropdown:GenerateMenu()
        sortDirDropdown:GenerateMenu()
    end

    -- 4) Quests section: search row (label + helper + edit box) at the top,
    -- then toolbar and scroll list. Anchored top (below previous section) AND
    -- bottom (to content's bottom) so it fills the remainder.
    local questsSection = buildSection(content, "Quests")
    questsSection:ClearAllPoints()
    questsSection:SetPoint("TOPLEFT", lastInStack, "BOTTOMLEFT", 0, -SECTION_GAP)
    questsSection:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
    lastInStack = questsSection

    local searchLabel = questsSection.body:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    searchLabel:SetPoint("TOPLEFT", questsSection.body, "TOPLEFT", 0, 0)
    searchLabel:SetText("Search")

    local searchHelp = questsSection.body:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    searchHelp:SetPoint("TOPLEFT", searchLabel, "BOTTOMLEFT", 0, -2)
    searchHelp:SetPoint("RIGHT", questsSection.body, "RIGHT", 0, 0)
    searchHelp:SetJustifyH("LEFT")
    searchHelp:SetWordWrap(true)
    searchHelp:SetSpacing(LINE_SPACING)
    searchHelp:SetText("Filter by quest name, zone name, or NPC name.")

    local searchBox = CreateFrame("EditBox", "WhereToQuestSearchBox", questsSection.body, "SearchBoxTemplate")
    searchBox:SetHeight(20)
    searchBox:SetPoint("TOPLEFT", searchHelp, "BOTTOMLEFT", 0, -ELEMENT_GAP)
    searchBox:SetPoint("RIGHT", questsSection.body, "RIGHT", 0, 0)
    searchBox:SetAutoFocus(false)
    searchBox:HookScript("OnTextChanged", function(self)
        local newText = string.lower(self:GetText() or "")
        if newText == searchText then return end
        searchText = newText
        renderList()
    end)
    frame.searchBox = searchBox

    local toolbar = CreateFrame("Frame", nil, questsSection.body)
    toolbar:SetHeight(SPACING.LG)
    toolbar:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", 0, -ELEMENT_GAP)
    toolbar:SetPoint("RIGHT", questsSection.body, "RIGHT", 0, 0)

    local refreshButton = CreateFrame("Button", nil, toolbar, "UIPanelButtonTemplate")
    refreshButton:SetSize(SPACING.LG * 3 + SPACING.SM, SPACING.LG)
    refreshButton:SetPoint("RIGHT", toolbar, "RIGHT", 0, 0)
    refreshButton:SetText("Refresh")
    refreshButton:SetScript("OnClick", function()
        invalidateScan()
        renderList()
    end)
    frame.refreshButton = refreshButton

    local toggleAllButton = CreateFrame("Button", nil, toolbar, "UIPanelButtonTemplate")
    toggleAllButton:SetSize(SPACING.LG * 4, SPACING.LG)
    toggleAllButton:SetPoint("RIGHT", refreshButton, "LEFT", -ELEMENT_GAP, 0)
    toggleAllButton:SetText("Collapse")
    toggleAllButton:SetScript("OnClick", function()
        local zc = getZoneCollapsed()
        local anyExpanded = false
        for _, zoneName in ipairs(lastZoneOrder) do
            if not zc[zoneName] then anyExpanded = true; break end
        end
        for _, zoneName in ipairs(lastZoneOrder) do
            zc[zoneName] = anyExpanded
        end
        renderList()
    end)
    frame.toggleAllButton = toggleAllButton

    local scroll = CreateFrame("ScrollFrame", nil, questsSection.body, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -ELEMENT_GAP)
    scroll:SetPoint("BOTTOMRIGHT", questsSection.body, "BOTTOMRIGHT", -SCROLLBAR_RESERVE, 0)

    -- Scroll child: explicit width via SetSize, kept in sync with the scroll
    -- viewport in scroll's own OnSizeChanged. No anchors so SetScrollChild's
    -- internal positioning runs normally (which is what makes the list scroll
    -- vertically when content overflows).
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(math.max(1, scroll:GetWidth()), 1)
    scroll:SetScrollChild(child)
    scrollChild = child
    frame.scroll = scroll

    scroll:HookScript("OnSizeChanged", function(self)
        child:SetWidth(math.max(1, self:GetWidth()))
        renderList()
    end)

    frame:HookScript("OnSizeChanged", function(self)
        WhereToQuestDB.frameSize = { w = math.floor(self:GetWidth()), h = math.floor(self:GetHeight()) }
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
    tinsert(UISpecialFrames, "WhereToQuestFrame")

    mainFrame = frame
    return frame
end

local function renderLoadingPlaceholder()
    if not scrollChild then
        return
    end
    for _, row in ipairs(rowPool) do
        row:Hide()
        row:SetScript("OnClick", nil)
        row:SetScript("OnEnter", nil)
        row:SetScript("OnLeave", nil)
    end
    local row = acquireRow(1)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", 0, -ROW_HEIGHT)
    row:SetHeight(ROW_HEIGHT)
    row.text:SetText("|cff7f7f7fScanning quest database\226\128\166|r")
    scrollChild:SetHeight(ROW_HEIGHT * 3)
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
    frame:Show()
    renderLoadingPlaceholder()
    -- Defer the first real layout pass to the next tick. Dropdown rows get
    -- their final width from the section body's OnSizeChanged hook, but that
    -- hook may not have fired yet on the first paint; renderList itself also
    -- relies on the scroll child's resolved width.
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

SLASH_WHERETOQUEST1 = "/wtq"
SLASH_WHERETOQUEST2 = "/wheretoquest"
SlashCmdList["WHERETOQUEST"] = function()
    if not loadQuestie() then
        print(INTRO_PREFIX .. "Questie is not loaded. Enable Questie to use this addon.")
        return
    end
    toggleFrame()
end

-- Registers the launcher with LibDBIcon so any addon-manager UI (CleanUI's
-- edge-snap refresh, Titan Panel, ChocolateBar, etc.) can manage it consistently.
local function setupMinimapButton()
    local LDB = LibStub("LibDataBroker-1.1")
    local LDBIcon = LibStub("LibDBIcon-1.0")
    if LDBIcon:IsRegistered("WhereToQuest") then
        return
    end

    local dataObject = LDB:NewDataObject("WhereToQuest", {
        type = "launcher",
        text = "WhereToQuest",
        icon = "Interface\\Icons\\INV_Misc_Map02",
        OnClick = function(_, button)
            if button == "LeftButton" then
                SlashCmdList["WHERETOQUEST"]()
            end
        end,
        OnTooltipShow = function(tt)
            tt:AddLine("WhereToQuest")
            tt:AddLine("|cffffffffClick|r to toggle.", 1, 1, 1)
        end,
    })

    -- Migrate legacy angle field to LibDBIcon's minimapPos.
    if WhereToQuestDB.minimap.angle and not WhereToQuestDB.minimap.minimapPos then
        WhereToQuestDB.minimap.minimapPos = WhereToQuestDB.minimap.angle
    end
    WhereToQuestDB.minimap.angle = nil

    LDBIcon:Register("WhereToQuest", dataObject, WhereToQuestDB.minimap)
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

-- Item tooltip enrichment shared state.
local questStatusCache = {}
local activeQuestIdSet

local function invalidateActiveQuestCaches()
    wipe(questStatusCache)
    activeQuestIdSet = nil
end

-- Set of quest IDs currently in the player's quest log. C_QuestLog is the
-- canonical API in Classic Era 1.15; we fall back to the legacy
-- GetQuestLogTitle if Blizzard ever drops it.
local function getActiveQuestIdSet()
    if activeQuestIdSet then
        return activeQuestIdSet
    end
    local set = {}
    if C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo then
        for i = 1, C_QuestLog.GetNumQuestLogEntries() do
            local info = C_QuestLog.GetInfo(i)
            if info and not info.isHeader and info.questID and info.questID > 0 then
                set[info.questID] = true
            end
        end
    elseif GetNumQuestLogEntries and GetQuestLogTitle then
        for i = 1, GetNumQuestLogEntries() do
            local _, _, _, isHeader, _, _, _, qid = GetQuestLogTitle(i)
            if not isHeader and qid and qid > 0 then
                set[qid] = true
            end
        end
    end
    activeQuestIdSet = set
    return set
end

-- Tooltip: extend Questie's item tooltip with quest-relevance lines for the
-- cases Questie does not already cover.
--
-- Questie shows objective progress + "(Complete)" only for quests currently
-- in the player's log. We add lines for every OTHER quest that references
-- this item -- past, future, available, locked -- so the player can decide
-- whether to keep, trade, or discard the item. Applies to any item type:
-- quest items, trade goods, reagents, anything Questie has linkage data on.
--
-- Lines mirror Questie's format: the colored "[level] Quest Name" title from
-- QuestieLib:GetColoredQuestName, followed by an explicit status badge.
-- Status badges use Questie's own color values (red/yellow/green) so the
-- lines blend with Questie's existing tooltip block.

-- Status priority drives sort order. Colors match Questie's palette in
-- Questie.lua so the lines visually match Questie's quest-name rendering.
--
--   Available           -- doable right now (includes repeatable redo)
--   Upcoming            -- player can't do it yet (level/prereqs); future
--   Previously Completed-- already turned in; past relevance
--   Past                -- quest level is grey for this player; outgrown
local STATUS_AVAILABLE  = { label = "(Available)",            color = "|cFFffff00", order = 1 }
local STATUS_UPCOMING   = { label = "(Upcoming)",             color = "|cFFff6f22", order = 2 }
local STATUS_COMPLETED  = { label = "(Previously Completed)", color = "|cFF00ff00", order = 3 }
local STATUS_PAST       = { label = "(Past)",                 color = "|cFFa6a6a6", order = 4 }

local TOOLTIP_LINE_CAP = 10
local INDEX_BUILD_DELAY = 5

-- Per-tooltip guards keyed by tooltip frame so GameTooltip and ItemRefTooltip
-- track their state independently. Weak keys so tooltips can still be GC'd.
local tooltipLastItem = setmetatable({}, { __mode = "k" })
-- NumLines() snapshot taken right AFTER we appended our lines. On the next
-- OnTooltipSetItem fire, if NumLines is now smaller, the tooltip was rebuilt
-- under us (e.g. by an async GET_ITEM_INFO_RECEIVED refresh) and our lines
-- need to be re-added — this is the fix for the ~200ms flicker users saw.
local tooltipLastLineCount = setmetatable({}, { __mode = "k" })

-- Global objective index: itemId -> array of every quest id where this item
-- appears in the quest's item-objective list (questKeys.objectives[3]).
-- Built once per session from Questie's compiled quest DB.
--
-- Scope is intentionally narrow: only true objectives count. Quest starters,
-- source items (sourceItemId), required-but-not-objective items
-- (requiredSourceItems), rewards, and triggers are excluded. If an item
-- isn't something the quest text says "Bring N to ..." for, we don't show
-- it as quest-related. This matches the user's intent: tooltip lines should
-- only point at quests where the item is an actual goal.
local globalItemObjectiveIndex
local indexBuildScheduled = false

local function buildGlobalItemObjectiveIndex()
    if globalItemObjectiveIndex then
        return
    end
    if not loadQuestie() or not QuestieDB.QuestPointers then
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
        list[#list + 1] = questId
    end
    for questId in pairs(QuestieDB.QuestPointers) do
        local objectives = QuestieDB.QueryQuestSingle(questId, "objectives")
        if type(objectives) == "table" and type(objectives[3]) == "table" then
            for _, obj in ipairs(objectives[3]) do
                local iid = (type(obj) == "table" and obj[1]) or (type(obj) == "number" and obj) or nil
                add(iid, questId)
            end
        end
    end
    globalItemObjectiveIndex = index
end

local function scheduleGlobalIndexBuild()
    if indexBuildScheduled or globalItemObjectiveIndex then
        return
    end
    indexBuildScheduled = true
    -- A few seconds after login so Questie has finished compiling its DB
    -- and the player isn't sharing a frame with our quest-DB walk.
    C_Timer.After(INDEX_BUILD_DELAY, buildGlobalItemObjectiveIndex)
end

-- Returns the list of quest ids that have this item as an objective, or nil
-- if the global index hasn't been built yet. There is intentionally no
-- relatedQuests fallback: relatedQuests mixes objectives with rewards /
-- starters / required-source items, and the user wants objectives only.
local function getObjectiveQuestsForItem(itemId)
    if globalItemObjectiveIndex then
        return globalItemObjectiveIndex[itemId]
    end
    scheduleGlobalIndexBuild()
    return nil
end

-- Questie-styled colored quest title with level prefix. Falls back to a
-- difficulty-tinted "[level] Name" if Questie's helper isn't accessible.
local function styledQuestName(qid)
    if QuestieLib and QuestieLib.GetColoredQuestName then
        local ok, str = pcall(QuestieLib.GetColoredQuestName, QuestieLib, qid, true, false)
        if ok and str and str ~= "" then
            return str
        end
    end
    local name = (QuestieDB and QuestieDB.QueryQuestSingle and QuestieDB.QueryQuestSingle(qid, "name")) or ("Quest " .. qid)
    local level = QuestieDB and QuestieDB.QueryQuestSingle and QuestieDB.QueryQuestSingle(qid, "questLevel")
    if type(level) == "number" and level > 0 then
        return getDifficultyColorCode(level) .. "[" .. level .. "] " .. name .. "|r"
    end
    return name
end

-- Returns a STATUS_* table for the quest, or nil when the line should be
-- suppressed: the quest is in the active log (Questie handles those with
-- live progress) or it's race/class-locked so the player can never do it.
--
-- Priority order matters:
--   1. Previously Completed wins over "doable / outgrown" only when the quest
--      is one-time done (NOT doable any more). Repeatable quests already
--      turned in once are still IsDoable, so they fall through to Available.
--   2. Past beats Available for trivial-level quests: the player has
--      outgrown the quest, so flagging it as Available misleadingly suggests
--      they should bother picking it up.
--   3. Available next (covers repeatables and never-done-but-doable).
--   4. Upcoming catches everything else (too high level, prereqs missing).
local function getQuestTooltipStatus(qid)
    local cached = questStatusCache[qid]
    if cached ~= nil then
        if cached == false then return nil end
        return cached
    end

    -- Active log: Questie shows it with live objective progress, skip.
    if getActiveQuestIdSet()[qid] then
        questStatusCache[qid] = false
        return nil
    end

    -- Race/class lock: the player can NEVER do this quest, so the item is
    -- not relevant to them. Hide rather than label as Upcoming.
    if not matchesPlayerFaction(qid) then
        questStatusCache[qid] = false
        return nil
    end

    local doable = QuestieDB.IsDoable and QuestieDB.IsDoable(qid)
    local completed = isQuestCompleted(qid)
    local status
    if completed and not doable then
        status = STATUS_COMPLETED
    else
        local playerLevel = UnitLevel("player")
        local level = QuestieLib and getEffectiveLevel(qid, playerLevel) or 0
        if isQuestTrivialForPlayer(level, playerLevel) then
            status = STATUS_PAST
        elseif doable then
            status = STATUS_AVAILABLE
        else
            status = STATUS_UPCOMING
        end
    end
    questStatusCache[qid] = status
    return status
end

-- Gathers every quest where this item is an actual objective. Quest
-- starters, source items, required-source items, rewards and triggers are
-- deliberately excluded -- the tooltip should only call out quests where
-- collecting this item is the goal. Active-log quests are filtered out by
-- getQuestTooltipStatus so Questie's own progress lines stay authoritative.
--
-- Quests that share a name across factions/cities (e.g. "A Donation of
-- Silk" exists once per capital) collapse into a single line. The kept
-- entry is the one with the most actionable status (lowest order value), so
-- if any version of the quest is still Available the player sees that
-- rather than a misleading "Previously Completed" from another version.
local function collectItemQuestEntries(itemId)
    local related = getObjectiveQuestsForItem(itemId)
    if type(related) ~= "table" then
        return {}
    end

    local seenQids = {}
    local byName = {}
    for _, qid in ipairs(related) do
        if type(qid) == "number" and qid > 0 and not seenQids[qid] then
            seenQids[qid] = true
            local status = getQuestTooltipStatus(qid)
            if status then
                local name = QuestieDB.QueryQuestSingle(qid, "name") or ("Quest " .. qid)
                local level = QuestieDB.QueryQuestSingle(qid, "questLevel")
                local entry = {
                    qid = qid,
                    level = (type(level) == "number" and level) or 0,
                    status = status,
                }
                local existing = byName[name]
                if not existing or status.order < existing.status.order then
                    byName[name] = entry
                end
            end
        end
    end

    local entries = {}
    for _, e in pairs(byName) do
        entries[#entries + 1] = e
    end

    table.sort(entries, function(a, b)
        if a.status.order ~= b.status.order then
            return a.status.order < b.status.order
        end
        if a.level ~= b.level then
            return a.level < b.level
        end
        return a.qid < b.qid
    end)

    return entries
end

-- Returns true when at least one line was appended so the caller can size the
-- tooltip. Lines are inserted directly under whatever Questie already wrote;
-- a single blank separator goes above ours so it visually groups together.
local function appendQuestItemTooltipLines(tooltip, itemId)
    if not loadQuestie() then
        return false
    end
    local entries = collectItemQuestEntries(itemId)
    if #entries == 0 then
        return false
    end

    tooltip:AddLine(" ")

    local shown = 0
    for _, entry in ipairs(entries) do
        if shown >= TOOLTIP_LINE_CAP then break end
        local line = styledQuestName(entry.qid) .. " " .. entry.status.color .. entry.status.label .. "|r"
        tooltip:AddLine(line, 1, 1, 1, true)
        shown = shown + 1
    end
    local remaining = #entries - shown
    if remaining > 0 then
        tooltip:AddLine(string.format("|cff7f7f7f... and %d more|r", remaining), 1, 1, 1, true)
    end

    return true
end

local function extractItemIdFromTooltip(tooltip)
    if not tooltip.GetItem then
        return nil
    end
    local _, link = tooltip:GetItem()
    if not link then
        return nil
    end
    return tonumber(link:match("item:(%d+)"))
end

-- OnTooltipSetItem can fire multiple times for the same tooltip display:
-- Blizzard refires it when async data lands (GET_ITEM_INFO_RECEIVED) and on
-- some setter paths the tooltip is internally cleared and rebuilt. Both
-- modes used to wipe our appended lines while the cache still claimed
-- "already added", which produced the ~200ms flicker. We now also compare
-- the tooltip's current NumLines against the count we recorded right after
-- our last append: any drop means the tooltip was rebuilt and we re-add.
local function onItemTooltipShow(self)
    if self.IsForbidden and self:IsForbidden() then
        return
    end
    if not self.NumLines then
        return
    end
    local itemId = extractItemIdFromTooltip(self)
    if not itemId then
        return
    end

    local sameItem = tooltipLastItem[self] == itemId
    local lastCount = tooltipLastLineCount[self]
    if sameItem and lastCount and self:NumLines() >= lastCount then
        -- Our lines are still in place, nothing to do.
        return
    end

    tooltipLastItem[self] = itemId
    local added = appendQuestItemTooltipLines(self, itemId)
    tooltipLastLineCount[self] = self:NumLines()
    if added then
        self:Show()
    end
end

local function onItemTooltipCleared(self)
    tooltipLastItem[self] = nil
    tooltipLastLineCount[self] = nil
end

local tooltipHooksInstalled = false
local function installTooltipHooks()
    if tooltipHooksInstalled then
        return
    end
    if GameTooltip then
        GameTooltip:HookScript("OnTooltipSetItem", onItemTooltipShow)
        GameTooltip:HookScript("OnHide", onItemTooltipCleared)
    end
    if ItemRefTooltip then
        ItemRefTooltip:HookScript("OnTooltipSetItem", onItemTooltipShow)
        ItemRefTooltip:HookScript("OnHide", onItemTooltipCleared)
    end
    tooltipHooksInstalled = true
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:RegisterEvent("QUEST_LOG_UPDATE")
loader:RegisterEvent("PLAYER_LEVEL_UP")
loader:RegisterEvent("QUEST_ACCEPTED")
loader:RegisterEvent("QUEST_REMOVED")
loader:RegisterEvent("QUEST_TURNED_IN")
loader:SetScript("OnEvent", function(self, event, name)
    if event == "QUEST_ACCEPTED" or event == "QUEST_REMOVED" or event == "QUEST_TURNED_IN" then
        invalidateActiveQuestCaches()
        invalidateScan()
        scheduleRefresh()
        return
    end
    if event == "QUEST_LOG_UPDATE" or event == "PLAYER_LEVEL_UP" then
        invalidateActiveQuestCaches()
        invalidateScan()
        scheduleRefresh()
        return
    end
    if event == "ADDON_LOADED" and name == ADDON_NAME then
        if type(WhereToQuestDB) ~= "table" then
            WhereToQuestDB = {}
        end
        WhereToQuestDB.minBelow = nil
        WhereToQuestDB.maxAbove = nil
        WhereToQuestDB.levelBelow = clampRange(WhereToQuestDB.levelBelow) or DEFAULTS.levelBelow
        WhereToQuestDB.levelAbove = clampRange(WhereToQuestDB.levelAbove) or DEFAULTS.levelAbove
        if type(WhereToQuestDB.useQuestieLevelRange) ~= "boolean" then
            WhereToQuestDB.useQuestieLevelRange = DEFAULTS.useQuestieLevelRange
        end
        local validSort = false
        for _, opt in ipairs(SORT_BY_OPTIONS) do
            if WhereToQuestDB.sortMode == opt.value then
                validSort = true
                break
            end
        end
        if not validSort then
            WhereToQuestDB.sortMode = DEFAULTS.sortMode
        end
        local validDir = false
        for _, opt in ipairs(SORT_DIR_OPTIONS) do
            if WhereToQuestDB.sortDir == opt.value then
                validDir = true
                break
            end
        end
        if not validDir then
            WhereToQuestDB.sortDir = DEFAULTS.sortDir
        end
        if type(WhereToQuestDB.filters) ~= "table" then
            WhereToQuestDB.filters = {}
        end
        for key, defaultOn in pairs(DEFAULTS.filters) do
            if type(WhereToQuestDB.filters[key]) ~= "boolean" then
                WhereToQuestDB.filters[key] = defaultOn
            end
        end
        WhereToQuestDB.showNpcName = nil
        WhereToQuestDB.showCoords = nil
        if type(WhereToQuestDB.pinCurrentZone) ~= "boolean" then
            WhereToQuestDB.pinCurrentZone = DEFAULTS.pinCurrentZone
        end
        if type(WhereToQuestDB.frameSize) ~= "table" then
            WhereToQuestDB.frameSize = { w = DEFAULTS.frameSize.w, h = DEFAULTS.frameSize.h }
        end
        if type(WhereToQuestDB.zoneCollapsed) ~= "table" then
            WhereToQuestDB.zoneCollapsed = {}
        end
        if type(WhereToQuestDB.groupCollapsed) ~= "table" then
            WhereToQuestDB.groupCollapsed = {}
        end
        if type(WhereToQuestDB.minimap) ~= "table" then
            WhereToQuestDB.minimap = { hide = false, minimapPos = 215 }
        end
        WhereToQuestDB.showHidden = nil
        WhereToQuestDB.hiddenQuests = nil
    elseif event == "PLAYER_LOGIN" then
        setupMinimapButton()
        installTooltipHooks()
        print(INTRO_PREFIX .. "Loaded. Type /wtq for available commands.")
    end
end)
