-- Blizzard's map pin at a quest's giver, the world map jump and the quest focus.
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

-- Why a pin can't land: an item drops somewhere, and some givers stand where QuestieDB has no position, such as inside a dungeon.
local NO_POSITION = {
    item = "This quest starts from an item, so it has no map pin.",
    other = "This quest's giver has no map position.",
}

-- Blizzard's map pin (MAP_PIN) at the quest's giver, or at its turn-in target for a quest ready to turn in, focused so
-- the in-world arrow leads there, with the sound the map plays for it. It replaces any pin the player set, as the
-- map's own pin does, and needs no window, so it lands in combat too. Returns the place it pinned, or nil after
-- saying why in Blizzard's red error text.
local function placeMapPin(quest)
    local startInfo = resolveStartInfo(quest)
    local uiMapId = startInfo.areaId and getUiMapId(startInfo.areaId)
    local spawn = startInfo.spawn
    if not (uiMapId and spawn) then
        UIErrorsFrame:AddExternalErrorMessage(NO_POSITION[startInfo.kind] or NO_POSITION.other)
        return nil
    end
    if not (C_Map.CanSetUserWaypointOnMap(uiMapId)
        and C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(uiMapId, spawn[1] / 100, spawn[2] / 100))) then
        UIErrorsFrame:AddExternalErrorMessage(MAP_PIN_INVALID_MAP)
        return nil
    end
    C_SuperTrack.SetSuperTrackedUserWaypoint(true)
    PlaySound(SOUNDKIT.UI_MAP_WAYPOINT_SUPER_TRACK_ON)
    return startInfo
end

-- Set Map Pin: the pin, and one chat line with Blizzard's own Map Pin Location link (C_Map.GetUserWaypointHyperlink),
-- coloured as Blizzard colours it in chat (GetFixedLink). A click on the link is Blizzard's: it sets the pin again and
-- opens the map at it (ItemRefHandlers.lua, LinkTypes.WorldMapWaypoint).
local function setMapPin(quest)
    local place = placeMapPin(quest)
    if not place then
        return
    end
    local link = C_Map.GetUserWaypointHyperlink()
    ns.Print(string.format("Map pin set at %s in %s for %s%s.", place.npcName, place.zoneName, quest.name,
        link and (": " .. GetFixedLink(link)) or ""))
end

-- Show on Map: the pin where there is a position, then the map. OpenWorldMap honours the WorldMapDisabled game rule;
-- without a renderable map it only opens the map. In combat only the pin lands.
-- A map change made by addon code refreshes the quest log in that code's taint, and the refresh shows again the quest
-- the player has open in its details, writing QuestMapFrame.DetailsFrame.questID (QuestLogMixin:Refresh,
-- QuestMapFrame_UpdateAll). The objective tracker reads that field on every update (QuestMapFrame_GetFocusedQuestID,
-- QuestObjectiveTracker.lua:296), so its next update would run tainted and be blocked in combat. While a quest's
-- details are open, the map therefore opens where it is; ShowUIPanel itself runs through Blizzard's forbidden delegate.
local function openMapForQuest(quest)
    local startInfo = resolveStartInfo(quest)
    local uiMapId = startInfo.areaId and getUiMapId(startInfo.areaId)
    if startInfo.spawn then
        placeMapPin(quest)
    end
    if isBlockedInCombat() then
        return
    end
    OpenWorldMap(not QuestMapFrame_GetFocusedQuestID() and uiMapId and resolveRenderableMapId(uiMapId) or nil)
end

-- A quest in the log gets the objective tracker's own Focus Quest (SUPER_TRACK_QUEST): the tracker marks it and the
-- in-world arrow leads to its objectives or its turn-in, in combat too. Never QuestMapFrame_OpenToQuestDetails, which
-- would write the details frame's quest from addon code and taint the tracker as above.
local function focusQuest(questId)
    if getQuestLog()[questId] then
        C_SuperTrack.SetSuperTrackedQuestID(questId)
    end
end

ns.setMapPin = setMapPin
ns.openMapForQuest = openMapForQuest
ns.focusQuest = focusQuest
