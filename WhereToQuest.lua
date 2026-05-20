-- WhereToQuest: zone-bucketed quest browser sourced from Questie.

local ADDON_NAME = ...

local DEFAULTS = {
    sortMode = "count",
    sortDir = "desc",
    filters = {
        inLog = true,
        available = true,
        missingPre = true,
        dungeons = true,
        eliteGroup = true,
    },
    showNpcName = false,
    showCoords = false,
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
local LEVEL_RANGE_MAX = 5

local INTRO_PREFIX = "|cffffff00[WhereToQuest]:|r "

local SORT_BY_OPTIONS = {
    { value = "count",    label = "Quest Count" },
    { value = "xp",       label = "Total XP" },
    { value = "avgLevel", label = "Average Quest Level" },
    { value = "name",     label = "Alphabetical" },
}
local SORT_DIR_OPTIONS = {
    { value = "asc",  label = "Ascending" },
    { value = "desc", label = "Descending" },
}

local SUBCAT_ORDER = { "inLog", "available", "missingPre" }
local SUBCAT_LABEL = {
    inLog = "In Quest Log",
    available = "Available",
    missingPre = "Chain Prerequisites",
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
-- rows. UIDropDownMenu sizing constant from the template
-- (UIDROPDOWNMENU_DEFAULT_WIDTH_PADDING * 2 == 50): UIDropDownMenu_SetWidth(d, W)
-- sets the Middle texture to W and frame width to W + 50 (left cap 25 + right
-- cap 25 are added on top of the requested width).
local ROW_EDGE_PAD = 4
local SLIDER_CENTER_HALF_GAP = 8           -- each slider sits this far from the row's centerline.
local DROPDOWN_CAP_TOTAL = 50              -- frame width = middle width + 50; matches Blizzard's UIDROPDOWNMENU_DEFAULT_WIDTH_PADDING * 2.
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

-- Returns name, zoneName, {x, y}, areaId for the quest's first start NPC.
-- Prefers a spawn in the quest's own zone (zoneOrSort) so the labeled location
-- matches the zone the quest is bucketed under; falls back to the smallest
-- area id if no spawn lives in the quest zone (deterministic, but arbitrary).
local function getQuestStartInfo(questId)
    if not QuestieDB or not QuestieDB.GetNPC then
        return nil, nil, nil, nil
    end
    local startedBy = QuestieDB.QueryQuestSingle(questId, "startedBy")
    local npcIds = startedBy and startedBy[1]
    if type(npcIds) ~= "table" or not npcIds[1] then
        return nil, nil, nil, nil
    end
    local npc = QuestieDB:GetNPC(npcIds[1])
    if not npc then
        return nil, nil, nil, nil
    end
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

    -- Quests already in the player's log bypass the level band: if the player
    -- accepted it, they want to see it regardless of how far it has drifted
    -- from their current level.
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
            if passesClassicCaps(level, requiredLevel)
                and passesLevelGate(level)
                and meetsRequiredLevel(requiredLevel, playerLevel) then
                if QuestieDB.IsDoable(questId) then
                    local zoneOrSort = QuestieDB.QueryQuestSingle(questId, "zoneOrSort")
                    if zoneOrSort then
                        local entry = ensureZone(getZoneName(zoneOrSort))
                        entry.available[#entry.available + 1] = {
                            id = questId,
                            level = level,
                            name = getQuestName(questId),
                            xp = getQuestXp(questId),
                            tag = getQuestTagLabel(questId),
                        }
                        entry.count = entry.count + 1
                    end
                elseif isBlockedByPrereqs(questId) and matchesPlayerFaction(questId) then
                    local zoneOrSort = QuestieDB.QueryQuestSingle(questId, "zoneOrSort")
                    if zoneOrSort then
                        local chains = findMissingChains(questId)
                        for _, chain in ipairs(chains) do
                            local initialId = chain[1]
                            -- Only surface chains the player can actually start now:
                            -- the initial step must itself pass Questie's full doability check
                            -- (handles race/class/faction/reputation/exclusiveTo/breadcrumb).
                            if QuestieDB.IsDoable(initialId) then
                                local initialZoneOrSort = QuestieDB.QueryQuestSingle(initialId, "zoneOrSort")
                                local entry = ensureZone(getZoneName(zoneOrSort))
                                local mpe = entry.missingPre.entries[initialId]
                                if not mpe then
                                    mpe = {
                                        initialId = initialId,
                                        initialName = getQuestName(initialId),
                                        initialLevel = getEffectiveLevel(initialId, playerLevel),
                                        initialZone = initialZoneOrSort and getZoneName(initialZoneOrSort) or nil,
                                        targets = {},
                                        -- Dedupe per (initial, target) so AND paths that converge
                                        -- on the same initial don't list the same target twice.
                                        targetIds = {},
                                    }
                                    entry.missingPre.entries[initialId] = mpe
                                    entry.missingPre.order[#entry.missingPre.order + 1] = initialId
                                end
                                if not mpe.targetIds[questId] then
                                    mpe.targetIds[questId] = true
                                    mpe.targets[#mpe.targets + 1] = {
                                        id = questId,
                                        name = getQuestName(questId),
                                        chain = chain,
                                    }
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    local function sortQuests(list)
        table.sort(list, function(a, b)
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
        table.sort(entry.missingPre.order, function(a, b)
            local ea, eb = entry.missingPre.entries[a], entry.missingPre.entries[b]
            if ea.initialLevel == eb.initialLevel then
                return ea.initialName < eb.initialName
            end
            return ea.initialLevel < eb.initialLevel
        end)

        local xpTotal = 0
        for _, q in ipairs(entry.inLog) do xpTotal = xpTotal + (q.xp or 0) end
        for _, q in ipairs(entry.available) do xpTotal = xpTotal + (q.xp or 0) end
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
        GameTooltip:AddLine("|cffffd200Objectives|r")
        for _, line in ipairs(quest.objectivesText) do
            GameTooltip:AddLine("  " .. line, 1, 1, 1, true)
        end
    end

    GameTooltip:Show()
end

local function showChainTooltip(anchor, entry)
    if not loadQuestie() then
        return
    end
    local primary = entry.targets[1]
    if not primary then
        return
    end
    local chain = primary.chain

    GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
    GameTooltip:AddLine(entry.initialName)
    addTooltipField("Pick up in", entry.initialZone)
    if #entry.targets == 1 then
        addTooltipField("Chain leads to", primary.name)
    else
        addTooltipField("Chain unlocks", string.format("%d quests in this zone", #entry.targets))
    end
    addTooltipField("Steps to target", #chain)
    GameTooltip:AddLine(" ")

    for i, qid in ipairs(chain) do
        local isTarget = (i == #chain)
        local heading
        if isTarget then
            heading = string.format("|cffffaa00%d. %s  (target)|r", i, getQuestName(qid))
        else
            heading = string.format("|cffffd200%d.|r %s", i, getQuestName(qid))
        end
        GameTooltip:AddLine(heading, 1, 1, 1, true)

        local npcName, npcZone, npcSpawn = getQuestStartInfo(qid)
        GameTooltip:AddDoubleLine("   |cff9d9d9dNPC|r", npcName or "unknown", 1, 1, 1, 1, 1, 1)
        local locText = formatLocation(npcZone, npcSpawn)
        if locText then
            GameTooltip:AddDoubleLine("   |cff9d9d9dLocation|r", locText, 1, 1, 1, 1, 1, 1)
        end

        if not isTarget then
            GameTooltip:AddLine(" ")
        end
    end

    GameTooltip:Show()
end

local function acquireRow(index)
    local row = rowPool[index]
    if row then
        row:Show()
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

local function colorQuestName(level, name)
    local r, g, b = 1, 1, 1
    if QuestieLib and QuestieLib.GetDifficultyColorPercent then
        r, g, b = QuestieLib:GetDifficultyColorPercent(level)
    end
    return string.format("|cff%02x%02x%02x%s|r",
        math.floor(r * 255), math.floor(g * 255), math.floor(b * 255), name)
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

local function formatRowLabel(level, name, quest)
    local label = colorQuestName(level, name)
    if quest and quest.tag then
        local color = QUEST_TAG_COLORS[quest.tag] or "ff8000"
        label = label .. " |cff" .. color .. "[" .. quest.tag .. "]|r"
    end
    if not quest then
        return label
    end
    local wantName = WhereToQuestDB and WhereToQuestDB.showNpcName
    local wantCoords = WhereToQuestDB and WhereToQuestDB.showCoords
    if not wantName and not wantCoords then
        return label
    end
    local info = resolveStartInfo(quest)
    if not info then
        return label
    end
    local parts = {}
    if wantName and info.npcName then
        if info.zoneName then
            parts[#parts + 1] = info.npcName .. ", " .. info.zoneName
        else
            parts[#parts + 1] = info.npcName
        end
    end
    if wantCoords and info.spawn then
        parts[#parts + 1] = string.format("%.1f, %.1f", info.spawn[1], info.spawn[2])
    end
    if #parts == 0 then
        return label
    end
    return label .. "  |cff7f7f7f" .. table.concat(parts, " \194\183 ") .. "|r"
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

local contextMenuFrame

local function ensureContextMenuFrame()
    if not contextMenuFrame then
        contextMenuFrame = CreateFrame("Frame", "WhereToQuestContextMenu", UIParent, "UIDropDownMenuTemplate")
    end
    return contextMenuFrame
end

function showQuestContextMenu(anchor, quest)
    local items = {
        { text = quest.name, isTitle = true, notCheckable = true },
        { text = "Show on map", notCheckable = true, func = function() openMapForQuest(quest) end },
        { text = "Link in chat", notCheckable = true, func = function() linkQuestInChat(quest) end },
        { text = "Close", notCheckable = true, func = function() end },
    }
    EasyMenu(items, ensureContextMenuFrame(), "cursor", 0, 0, "MENU")
end

function showChainContextMenu(anchor, mpe)
    local quest = mpe._pseudo or { id = mpe.initialId, level = mpe.initialLevel, name = mpe.initialName }
    local items = {
        { text = mpe.initialName, isTitle = true, notCheckable = true },
        { text = "Show on map", notCheckable = true, func = function() openMapForQuest(quest) end },
        { text = "Link in chat", notCheckable = true, func = function() linkQuestInChat(quest) end },
        { text = "Close", notCheckable = true, func = function() end },
    }
    EasyMenu(items, ensureContextMenuFrame(), "cursor", 0, 0, "MENU")
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

    local function renderQuestRow(label, onEnter, onLeftClick, onRightClick, onShiftClick)
        y = y + ROW_GAP
        local row = acquireRow(index)
        placeRow(row, INDENT_STEP * 2)
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
        if WhereToQuestDB and (WhereToQuestDB.showNpcName or WhereToQuestDB.showCoords) then
            local info = resolveStartInfo(quest)
            if info and searchMatches(info.npcName) then
                return true
            end
        end
        return false
    end

    local function passesChain(mpe, zoneMatch)
        if zoneMatch then
            return true
        end
        if searchMatches(mpe.initialName) then
            return true
        end
        for _, target in ipairs(mpe.targets) do
            if searchMatches(target.name) then
                return true
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

            local visible = { inLog = {}, available = {}, missingPre = {} }
            if filters.inLog then
                for _, q in ipairs(entry.inLog) do
                    if passesQuest(q, zoneMatch) then
                        visible.inLog[#visible.inLog + 1] = q
                    end
                end
            end
            if filters.available then
                for _, q in ipairs(entry.available) do
                    if passesQuest(q, zoneMatch) then
                        visible.available[#visible.available + 1] = q
                    end
                end
            end
            if filters.missingPre then
                for _, initialId in ipairs(entry.missingPre.order) do
                    local mpe = entry.missingPre.entries[initialId]
                    if passesChain(mpe, zoneMatch) then
                        visible.missingPre[#visible.missingPre + 1] = mpe
                    end
                end
            end

            local visibleTotal = #visible.inLog + #visible.available + #visible.missingPre
            if visibleTotal > 0 then
                if renderedZones > 0 then
                    y = y + ZONE_GAP
                end
                renderedZones = renderedZones + 1

                local visibleXp = 0
                for _, q in ipairs(visible.available) do visibleXp = visibleXp + (q.xp or 0) end
                for _, q in ipairs(visible.inLog) do visibleXp = visibleXp + (q.xp or 0) end

                local header = acquireRow(index)
                placeRow(header, 0)
                local arrow = collapsed and "|cffffd200[+]|r " or "|cffffd200[-]|r "
                local summary = " (" .. visibleTotal .. ")"
                if visibleXp > 0 then
                    local xpMax = (UnitXPMax and UnitXPMax("player")) or 0
                    if xpMax > 0 then
                        local pct = math.floor(visibleXp / xpMax * 100 + 0.5)
                        summary = summary .. string.format(" |cff7f7f7f\194\183 %s XP (%d%% lvl)|r", formatNumber(visibleXp), pct)
                    else
                        summary = summary .. string.format(" |cff7f7f7f\194\183 %s XP|r", formatNumber(visibleXp))
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
                        local list = visible[subKey]
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
                                        local pseudo = mpe._pseudo
                                        if not pseudo then
                                            pseudo = { id = mpe.initialId, level = mpe.initialLevel, name = mpe.initialName }
                                            mpe._pseudo = pseudo
                                        end
                                        local label = formatRowLabel(mpe.initialLevel, mpe.initialName, pseudo)
                                        -- Only call out the pickup zone when it differs from the row's
                                        -- own zone; otherwise the hint just repeats the zone header.
                                        if mpe.initialZone and mpe.initialZone ~= zoneName then
                                            label = label .. " |cff7f7f7f(pick up in " .. mpe.initialZone .. ")|r"
                                        end
                                        renderQuestRow(label,
                                            function(self) showChainTooltip(self, mpe) end,
                                            function() openMapForQuest(pseudo) end,
                                            function(self) if showChainContextMenu then showChainContextMenu(self, mpe) end end,
                                            function() linkQuestInChat(pseudo) end)
                                    end
                                else
                                    for _, quest in ipairs(list) do
                                        local label = formatRowLabel(quest.level, quest.name, quest)
                                        renderQuestRow(label,
                                            function(self) showQuestTooltip(self, quest.id) end,
                                            function() openMapForQuest(quest) end,
                                            function(self) if showQuestContextMenu then showQuestContextMenu(self, quest) end end,
                                            function() linkQuestInChat(quest) end)
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
        local anyBucket = filters.inLog or filters.available or filters.missingPre
        local msg
        if not anyBucket then
            msg = "All quest filters are off. Enable In Quest Log, Available, or Show Chain Prerequisites to see quests."
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

-- Lays out N native UIDropDownMenuTemplate dropdowns side by side inside `row`,
-- with ROW_EDGE_PAD on each end and DROPDOWN_VISIBLE_GAP between adjacent
-- dropdowns. Every dropdown frame fits entirely inside the row, so nothing
-- spills past the subcontainer's right edge regardless of how narrow the row
-- gets. Call from row:HookScript("OnSizeChanged", ...) so the row stays
-- responsive to frame resizes.
local function layoutDropdownRow(dropdowns, row)
    local n = #dropdowns
    if n == 0 then return end
    local w = row:GetWidth()
    if w <= 1 then return end

    local contentW = w - 2 * ROW_EDGE_PAD
    local frameW = math.max(80, (contentW - (n - 1) * DROPDOWN_VISIBLE_GAP) / n)
    -- UIDropDownMenu_SetWidth(d, middleW) yields a frame of (middleW + DROPDOWN_CAP_TOTAL).
    local middleW = math.max(30, frameW - DROPDOWN_CAP_TOTAL)

    local x = ROW_EDGE_PAD
    for _, d in ipairs(dropdowns) do
        UIDropDownMenu_SetWidth(d, middleW)
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
    rangeSection:SetHeight(SPACING.LG * 2 + SECTION_INNER_PAD * 2 + RANGE_CHECKBOX_HEIGHT + RANGE_CHECKBOX_GAP)
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

    -- Sliders are visually locked (greyed out) when Questie's range governs.
    local function applySliderLock(locked)
        if locked then
            belowSlider:Disable()
            aboveSlider:Disable()
        else
            belowSlider:Enable()
            aboveSlider:Enable()
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
                { key = "inLog",      label = "In Quest Log" },
                { key = "available",  label = "Available" },
                { key = "missingPre", label = "Show Chain Prerequisites" },
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
            title = "Zone & NPCs",
            get = getToggleValue,
            set = setToggleValue,
            specs = {
                { key = "showNpcName",    label = "Show NPC Name and Location" },
                { key = "showCoords",     label = "Show NPC Coordinates" },
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
        local dd = CreateFrame("Frame", "WhereToQuestFilterDropdown" .. i, parent, "UIDropDownMenuTemplate")
        UIDropDownMenu_Initialize(dd, function(self, level)
            for _, spec in ipairs(group.specs) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = spec.label
                info.isNotRadio = true
                info.keepShownOnClick = true
                info.checked = group.get(spec.key)
                info.func = function(btn)
                    group.set(spec.key, btn.checked and true or false)
                    invalidateScan()
                    renderList()
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end)
        UIDropDownMenu_SetText(dd, group.title)
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

    local function getSortByLabel(value)
        for _, opt in ipairs(SORT_BY_OPTIONS) do
            if opt.value == value then return opt.label end
        end
        return SORT_BY_OPTIONS[1].label
    end
    local function getSortDirLabel(value)
        for _, opt in ipairs(SORT_DIR_OPTIONS) do
            if opt.value == value then return opt.label end
        end
        return SORT_DIR_OPTIONS[2].label
    end

    local sortByDropdown = CreateFrame("Frame", "WhereToQuestSortByDropdown", sortRow, "UIDropDownMenuTemplate")
    UIDropDownMenu_Initialize(sortByDropdown, function(self, level)
        local current = (WhereToQuestDB and WhereToQuestDB.sortMode) or DEFAULTS.sortMode
        for _, opt in ipairs(SORT_BY_OPTIONS) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = opt.label
            info.value = opt.value
            info.checked = current == opt.value
            info.func = function(btn)
                WhereToQuestDB.sortMode = btn.value
                UIDropDownMenu_SetText(sortByDropdown, getSortByLabel(btn.value))
                renderList()
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    local sortDirDropdown = CreateFrame("Frame", "WhereToQuestSortDirDropdown", sortRow, "UIDropDownMenuTemplate")
    UIDropDownMenu_Initialize(sortDirDropdown, function(self, level)
        local current = (WhereToQuestDB and WhereToQuestDB.sortDir) or DEFAULTS.sortDir
        for _, opt in ipairs(SORT_DIR_OPTIONS) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = opt.label
            info.value = opt.value
            info.checked = current == opt.value
            info.func = function(btn)
                WhereToQuestDB.sortDir = btn.value
                UIDropDownMenu_SetText(sortDirDropdown, getSortDirLabel(btn.value))
                renderList()
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    local function layoutSortRow() layoutDropdownRow({ sortByDropdown, sortDirDropdown }, sortRow) end
    sortRow:HookScript("OnSizeChanged", layoutSortRow)

    frame.sortByDropdown = sortByDropdown
    frame.sortDirDropdown = sortDirDropdown
    frame.refreshSortDropdown = function()
        UIDropDownMenu_SetText(sortByDropdown, getSortByLabel((WhereToQuestDB and WhereToQuestDB.sortMode) or DEFAULTS.sortMode))
        UIDropDownMenu_SetText(sortDirDropdown, getSortDirLabel((WhereToQuestDB and WhereToQuestDB.sortDir) or DEFAULTS.sortDir))
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
    searchHelp:SetText("Filter by quest name, zone name, or NPC name (when NPC display is on).")

    local searchBox = CreateFrame("EditBox", "WhereToQuestSearchBox", questsSection.body, "SearchBoxTemplate")
    searchBox:SetHeight(20)
    searchBox:SetPoint("TOPLEFT", searchHelp, "BOTTOMLEFT", SPACING.SM, -ELEMENT_GAP)
    searchBox:SetPoint("RIGHT", questsSection.body, "RIGHT", -SPACING.SM, 0)
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

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:RegisterEvent("QUEST_LOG_UPDATE")
loader:RegisterEvent("PLAYER_LEVEL_UP")
loader:SetScript("OnEvent", function(self, event, name)
    if event == "QUEST_LOG_UPDATE" or event == "PLAYER_LEVEL_UP" then
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
        if type(WhereToQuestDB.showNpcName) ~= "boolean" then
            WhereToQuestDB.showNpcName = DEFAULTS.showNpcName
        end
        if type(WhereToQuestDB.showCoords) ~= "boolean" then
            WhereToQuestDB.showCoords = DEFAULTS.showCoords
        end
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
        print(INTRO_PREFIX .. "Loaded. Type /wtq for available commands.")
    end
end)
