-- Every way to open the window: minimap button, addon menu, slash command, key binding and the zone links in chat.
local _, ns = ...

local UI = LibStub("LibNativeUI-1.0")

local ADDON_TITLE = ns.ADDON_TITLE
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
        UI.Print(ADDON_TITLE, describeQuestieState())
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

-- The minimap button and addon menu entry, set up at login; its setShown backs /qg minimap.
local launcher

-- /qg toggles the window even when the minimap button is hidden; /qg minimap shows or hides that button; /qg reset rescues a window dragged off-screen. The window holds QuestieGuideDB.position itself, so reset empties it in place.
UI.RegisterSlash("QUESTIEGUIDE", { "/questieguide", "/qg" }, function(msg)
    local command = strtrim(string.lower(msg or ""))
    if command == "minimap" then
        launcher.setShown(QuestieGuideDB.minimap.hide)
        UI.Print(ADDON_TITLE, QuestieGuideDB.minimap.hide and "Minimap button hidden. Type /qg minimap to show it again." or "Minimap button shown.")
        return
    end
    if command == "reset" then
        wipe(QuestieGuideDB.position)
        if ns.mainFrame then
            ns.mainFrame:ClearAllPoints()
            ns.mainFrame:SetPoint("CENTER")
        end
        UI.Print(ADDON_TITLE, "Window position reset.")
        return
    end
    toggleIfReady()
end)

-- Key binding entry point; Bindings.xml can only call named globals. The name global labels the entry under Key Bindings, mirroring how Questie registers its Journey toggle.
BINDING_NAME_QUESTIEGUIDE_TOGGLE = "Toggle Window"

function QuestieGuide_Toggle()
    toggleIfReady()
end

-- A zone name as a clickable chat link that opens the window at that zone, in the same |Haddon:...|h pattern and link colour Questie uses for its debug offers.
local function formatZoneLink(zoneName, areaId)
    return COLOR.LINK:WrapTextInColorCode("|Haddon:questieguide:zone:" .. areaId .. "|h[" .. zoneName .. "]|h")
end

-- Clicking a zone link in the guide's chat lines opens the window at that zone. hooksecurefunc on SetItemRef is the same interception Questie's debug-offer links use. Chat history survives a reload, so an old link can be clicked before Questie is ready.
local ZONE_LINK_PREFIX = "addon:questieguide:zone:"
hooksecurefunc("SetItemRef", function(link)
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

-- One launcher for the minimap button and the addon menu: LibDBIcon draws the button, keeps its position in QuestieGuideDB.minimap and adds the addon menu entry through Blizzard's AddonCompartmentFrame. Addon-manager bars (Titan Panel, ChocolateBar) pick up the same LDB launcher.
local function setupLauncher()
    launcher = UI.CreateLauncher({
        title = ADDON_TITLE,
        icon = ADDON_ICON,
        db = QuestieGuideDB.minimap,
        onClick = function(button)
            if button == "LeftButton" then
                toggleIfReady()
            end
        end,
        tooltip = fillLauncherTooltip,
    })
end

ns.formatZoneLink = formatZoneLink
ns.setupLauncher = setupLauncher
