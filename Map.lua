-- The world map and quest log jumps, and click-through from Questie's map pins into the guide.
local _, ns = ...

local UI = LibStub("LibNativeUI-1.0")

local ADDON_TITLE = ns.ADDON_TITLE
local getQuestName = ns.getQuestName
local resolveStartInfo = ns.resolveStartInfo

local ZoneDB = QuestieLoader:ImportModule("ZoneDB")
local QuestiePlayer = QuestieLoader:ImportModule("QuestiePlayer")
local QuestieMap = QuestieLoader:ImportModule("QuestieMap")
local QuestieFrame = QuestieLoader:ImportModule("QuestieFrame")

-- Blizzard's map and quest log open through ShowUIPanel, which refuses addon callers in combat, so a click then says why nothing opened.
local function isBlockedInCombat()
    if not InCombatLockdown() then
        return false
    end
    UI.Print(ADDON_TITLE, "The map and quest log can't open in combat. Click the quest again after combat.")
    return true
end

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

-- OpenWorldMap honours the WorldMapDisabled game rule; without a renderable map it only opens the map. In combat only the waypoint lands.
local function openMapForQuest(quest)
    local startInfo = resolveStartInfo(quest)
    local uiMapId = startInfo.areaId and ZoneDB:GetUiMapIdByAreaId(startInfo.areaId)
    local renderMapId = uiMapId and resolveRenderableMapId(uiMapId)

    -- Spawn coords belong to uiMapId's coordinate space, so a waypoint is only set when that map is the one shown.
    if renderMapId and renderMapId == uiMapId and startInfo.spawn then
        setNativeWaypoint(uiMapId, startInfo.spawn[1] / 100, startInfo.spawn[2] / 100)
    end
    if isBlockedInCombat() then
        return
    end
    OpenWorldMap(renderMapId)
    if not renderMapId then
        return
    end

    -- Questie draws icons asynchronously after the map changes, so wait a tick before pulsing.
    C_Timer.After(0.2, function()
        highlightQuestOnMap(quest.id)
    end)
end

-- Opens the quest map log at the quest, which selects and scrolls on its own. The details view needs a quest that is in the log, so Questie's quest log gates the call.
local function openQuestInLog(questId)
    if QuestiePlayer.currentQuestlog[questId] and not isBlockedInCombat() then
        QuestMapFrame_OpenToQuestDetails(questId)
    end
end

-- Opens the guide with the quest row expanded, scrolled to, and selected. The guide is the addon's own frame, so this works in combat too.
local function openGuideAtQuest(questId)
    ns.buildMainFrame():Show()

    -- The window's first layout pass waits a tick after it shows, so the jump waits too.
    C_Timer.After(0.1, function()
        if not ns.jumpToQuestInList(questId) then
            UI.Print(ADDON_TITLE, getQuestName(questId) .. " is not listed with the current filters. Change the filters to show it.")
        end
    end)
end

-- Runs after Questie's own pin OnClick. A plain left click on an available-quest "!" opens the guide at that quest; objective, turn-in and manual pins stay Questie's, whose own plain click does nothing there. Modified clicks (Questie's Shift hide and Ctrl waypoint) and chat-link insertion stay Questie's; a world-map click that changed the shown map was a zoom-to-zone click, detected against the map id captured on mouse-down.
local function onMapIconClick(pin, button)
    if button ~= "LeftButton" or IsModifierKeyDown() then
        return
    end
    if ChatFrameUtil.GetActiveWindow() then
        return
    end
    local data = pin.data
    local questId = data and data.Id
    if type(questId) ~= "number" or data.Type ~= "available" then
        return
    end
    if not pin.miniMapIcon and WorldMapFrame:IsShown()
        and pin.qgPreClickMapId and pin.UiMapID and pin.UiMapID ~= pin.qgPreClickMapId then
        return
    end
    openGuideAtQuest(questId)
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
local function installMapIconHooks()
    hooksecurefunc(QuestieFrame, "CreateIconFrame", function(frameId)
        hookMapIcon(_G["QuestieFrame" .. frameId])
    end)
    local i = 1
    while _G["QuestieFrame" .. i] do
        hookMapIcon(_G["QuestieFrame" .. i])
        i = i + 1
    end
end

ns.openMapForQuest = openMapForQuest
ns.openQuestInLog = openQuestInLog
ns.installMapIconHooks = installMapIconHooks
