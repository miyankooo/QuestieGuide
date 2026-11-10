-- The world map and quest log jumps.
local _, ns = ...

local resolveStartInfo = ns.resolveStartInfo
local getQuestLog = ns.getQuestLog
local getUiMapId = ns.getUiMapId

-- Blizzard's map and quest log open through ShowUIPanel, which refuses addon callers in combat, so a click then shows Blizzard's own red combat error instead of a chat line.
local function isBlockedInCombat()
    if not InCombatLockdown() then
        return false
    end
    UIErrorsFrame:AddExternalErrorMessage(ERR_NOT_IN_COMBAT)
    return true
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

-- OpenWorldMap honours the WorldMapDisabled game rule; without a renderable map it only opens the map. In combat only the waypoint lands.
local function openMapForQuest(quest)
    local startInfo = resolveStartInfo(quest)
    local uiMapId = startInfo.areaId and getUiMapId(startInfo.areaId)
    local renderMapId = uiMapId and resolveRenderableMapId(uiMapId)

    -- Spawn coords belong to uiMapId's coordinate space, so a waypoint is only set when that map is the one shown.
    if renderMapId and renderMapId == uiMapId and startInfo.spawn then
        setNativeWaypoint(uiMapId, startInfo.spawn[1] / 100, startInfo.spawn[2] / 100)
    end
    if isBlockedInCombat() then
        return
    end
    OpenWorldMap(renderMapId)
end

-- Opens the quest map log at the quest, which selects and scrolls on its own. The details view needs a quest that is in the log, so the log gates the call.
local function openQuestInLog(questId)
    if getQuestLog()[questId] and not isBlockedInCombat() then
        QuestMapFrame_OpenToQuestDetails(questId)
    end
end

ns.openMapForQuest = openMapForQuest
ns.openQuestInLog = openQuestInLog
