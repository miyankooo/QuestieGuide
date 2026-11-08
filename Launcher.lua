-- Every way to open the window: minimap button, addon menu, slash command, key binding and the zone links in chat.
local _, ns = ...

local ADDON_ICON = ns.ADDON_ICON
local COLOR = ns.COLOR
local describeQuestieState = ns.describeQuestieState
local getZoneName = ns.getZoneName
local getCurrentZoneName = ns.getCurrentZoneName
local scanCache = ns.scanCache
local findBestZone = ns.findBestZone
local countPickable = ns.countPickable
local expandAndScrollToZone = ns.expandAndScrollToZone
local buildMainFrame = ns.buildMainFrame
local toggleWindow = ns.toggleWindow

-- Every launcher's click: toggles the window once Questie is ready, otherwise says why it can't open.
local function toggleIfReady()
    if not ns.questieReady then
        ns.Print(describeQuestieState())
        return
    end
    toggleWindow()
end

-- One status line under the launcher title: the quests to pick up where the player stands and the Next zone with its trip XP. It reads the last scan, even a stale one; a hover must never start the expensive database walk.
local function getLauncherStatus()
    if not scanCache.byZone then
        return nil
    end
    local parts = {}
    local zoneName = getCurrentZoneName()
    if zoneName then
        local entry = scanCache.byZone[zoneName]
        local count = entry and countPickable(entry) or 0
        parts[#parts + 1] = string.format("%d quest%s to pick up in %s.", count, count == 1 and "" or "s", zoneName)
    end
    local nextZone = findBestZone(scanCache.byZone, scanCache.zoneOrder)
    if nextZone then
        parts[#parts + 1] = string.format("Next: %s, %s XP.", nextZone, BreakUpLargeNumbers(scanCache.byZone[nextZone].stats.xp))
    end
    return #parts > 0 and table.concat(parts, " ") or nil
end

-- Lines under the title the launcher adds, shared by the minimap button and the addon menu.
local function fillLauncherTooltip(tooltip)
    local status = getLauncherStatus()
    if status then
        GameTooltip_AddHighlightLine(tooltip, status)
    end
    GameTooltip_AddInstructionLine(tooltip, "Left-click to toggle the window.")
end

-- One launcher for the minimap button and the Addon Compartment: LibDBIcon draws the button and adds the
-- compartment entry through AddonCompartmentFrame, so both share the click and the tooltip. Such an addon has no
-- AddonCompartmentFunc toc keys. LibStub, CallbackHandler-1.0, LibDataBroker-1.1 and LibDBIcon-1.0 load first.
local function CreateLauncher(icon, db, onClick, fillTooltip)
    local LDBIcon = LibStub("LibDBIcon-1.0")
    if not LDBIcon:IsRegistered(ns.title) then
        local object = LibStub("LibDataBroker-1.1"):NewDataObject(ns.title, {
            type = "launcher",
            text = ns.title,
            icon = icon,
            OnClick = function(_, button) onClick(button) end,
            OnTooltipShow = function(tooltip)
                GameTooltip_SetTitle(tooltip, ns.title)
                fillTooltip(tooltip)
            end,
        })
        LDBIcon:Register(ns.title, object, db)
        LDBIcon:AddButtonToCompartment(ns.title)
    end
    -- Shows or hides only the minimap button and remembers it in db.hide; the addon menu entry stays.
    return function(shown)
        db.hide = not shown
        if shown then LDBIcon:Show(ns.title) else LDBIcon:Hide(ns.title) end
    end
end

-- Shows or hides the minimap button, set up at login; LibDBIcon keeps its position in QuestieGuideDB.minimap. Addon-manager bars (Titan Panel, ChocolateBar) pick up the same LDB launcher.
local setMinimapShown

local function setupLauncher()
    setMinimapShown = CreateLauncher(ADDON_ICON, QuestieGuideDB.minimap, function(button)
        if button == "LeftButton" then
            toggleIfReady()
        end
    end, fillLauncherTooltip)
end

-- Only the minimap button hides; the addon menu entry stays as the way back.
local function toggleMinimapButton()
    local show = QuestieGuideDB.minimap.hide == true
    setMinimapShown(show)
    ns.Print(show and "Minimap button shown." or "Minimap button hidden. Type /qg minimap to show it again.")
end

-- /qg toggles the window even when the minimap button is hidden; /qg minimap shows or hides that button; /qg reset rescues a window dragged off-screen. The window holds QuestieGuideDB.position itself, so reset empties it in place.
SLASH_QUESTIEGUIDE1, SLASH_QUESTIEGUIDE2 = "/questieguide", "/qg"
SlashCmdList.QUESTIEGUIDE = function(message)
    local command = strtrim(message or ""):lower()
    if command == "minimap" then
        toggleMinimapButton()
    elseif command == "reset" then
        wipe(QuestieGuideDB.position)
        if ns.mainFrame then
            ns.mainFrame:ClearAllPoints()
            ns.mainFrame:SetPoint("CENTER")
        end
        ns.Print("Window position reset.")
    else
        toggleIfReady()
    end
end

-- Key binding entry point; Bindings.xml can only call named globals. The name global labels the entry under Key Bindings, mirroring how Questie registers its Journey toggle.
BINDING_NAME_QUESTIEGUIDE_TOGGLE = "Toggle Window"

function QuestieGuide_Toggle()
    toggleIfReady()
end

-- A zone name as a clickable chat link that opens the window at that zone, in the same |Haddon:...|h pattern and link colour Questie uses for its debug offers.
local function formatZoneLink(zoneName, areaId)
    return COLOR.LINK:WrapTextInColorCode("|Haddon:questieguide:zone:" .. areaId .. "|h[" .. zoneName .. "]|h")
end

-- Clicking a zone link in the guide's chat lines opens the window at that zone. Blizzard's addon link handler passes every addon link to the SetItemRef callback (ItemRefHandlersShared.lua), so no Blizzard function is hooked. Chat history survives a reload, so an old link can be clicked before Questie is ready.
local ZONE_LINK_PREFIX = "addon:questieguide:zone:"
EventRegistry:RegisterCallback("SetItemRef", function(_, link)
    if type(link) ~= "string" or link:sub(1, #ZONE_LINK_PREFIX) ~= ZONE_LINK_PREFIX then
        return
    end
    local areaId = tonumber(link:sub(#ZONE_LINK_PREFIX + 1))
    if not areaId or not ns.questieReady then
        return
    end
    local zoneName = getZoneName(areaId)
    buildMainFrame():Show()

    -- The window's first layout pass waits a tick after it shows, so the jump waits too.
    C_Timer.After(0.1, function()
        expandAndScrollToZone(zoneName)
    end)
end)

ns.formatZoneLink = formatZoneLink
ns.setupLauncher = setupLauncher
