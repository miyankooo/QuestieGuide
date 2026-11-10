-- Every way to open the window: minimap button, addon menu, slash command, key binding, the welcome line and the zone links in chat.
local addonName, ns = ...

local ADDON_ICON = ns.ADDON_ICON
local COLOR = ns.COLOR
local getZoneName = ns.getZoneName
local getCurrentZoneName = ns.getCurrentZoneName
local scanCache = ns.scanCache
local findBestZone = ns.findBestZone
local countPickable = ns.countPickable
local expandAndScrollToZone = ns.expandAndScrollToZone
local buildMainFrame = ns.buildMainFrame
local toggleWindow = ns.toggleWindow

-- Every launcher's click: toggles the window when QuestieDB passed its check, otherwise says why it can't open.
local function toggleIfReady()
    if not ns.questDB then
        ns.Print(ns.questDBProblem)
        return
    end
    toggleWindow()
end

-- The quests to pick up where the player stands and the Next zone with its trip XP, as the launcher tooltip's state rows. It reads the last scan, even a stale one; a hover must never start the expensive database walk.
local function addLauncherStatus(tooltip)
    if not scanCache.byZone then
        return
    end
    local zoneName = getCurrentZoneName()
    if zoneName then
        local entry = scanCache.byZone[zoneName]
        local count = entry and countPickable(entry) or 0
        GameTooltip_AddColoredDoubleLine(tooltip, zoneName, string.format("%d |4quest:quests; to pick up", count),
            HIGHLIGHT_FONT_COLOR, HIGHLIGHT_FONT_COLOR)
    end
    local nextZone = findBestZone(scanCache.byZone, scanCache.zoneOrder)
    if nextZone then
        GameTooltip_AddColoredDoubleLine(tooltip, "Next: " .. nextZone, BreakUpLargeNumbers(scanCache.byZone[nextZone].stats.xp) .. " XP",
            HIGHLIGHT_FONT_COLOR, HIGHLIGHT_FONT_COLOR)
    end
end

-- Lines under the title the launcher adds, shared by the minimap button and the addon menu.
local function fillLauncherTooltip(tooltip)
    addLauncherStatus(tooltip)
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

-- Blizzard reserves the addon link type for addons and hands every click on one to all of them through one EventRegistry event (ItemRefHandlersShared.lua:279-282), so no Blizzard function is hooked. The welcome line links the window; chat zone links add the zone's area id.
local LINK = LinkTypes.AddOn .. ":" .. addonName
local ZONE_LINK_PREFIX = LINK .. ":zone:"

-- A link in the gold of Blizzard's own chat links.
local function formatLink(label, ...)
    return COLOR.LINK:WrapTextInColorCode(LinkUtil.FormatLink(LinkTypes.AddOn, "[" .. label .. "]", addonName, ...))
end

-- A zone name as a clickable chat link that opens the window at that zone.
local function formatZoneLink(zoneName, areaId)
    return formatLink(zoneName, "zone", areaId)
end

-- The first load on an account says what the guide does and links the window.
local function printWelcome()
    ns.Print("Lists the quests you can pick up now, grouped by zone and rated by XP. Open the " .. formatLink(ns.title)
        .. " window or type /qg to see the best zone for your next trip.")
end

-- /qg intro: the welcome line now, and the help tip again, at once while the window is open, else when it next opens.
local function replayIntro()
    QuestieGuideDB.tipSeen = nil
    printWelcome()
    local frame = ns.mainFrame
    if frame and frame.filterDropdown:IsVisible() then frame.showTip() end
end

EventUtil.ContinueOnPlayerLogin(function()
    if ns.firstRun then printWelcome() end
end)

-- Opens the window from a link, and at a zone for a zone link. Another addon's link may come from a line kept from restricted content, so it is checked before any comparison.
EventRegistry:RegisterCallback("SetItemRef", function(_, link)
    if not ns.CanAccess(link) or type(link) ~= "string" then
        return
    end
    local areaId
    if link ~= LINK then
        if link:sub(1, #ZONE_LINK_PREFIX) ~= ZONE_LINK_PREFIX then
            return
        end
        areaId = tonumber(link:sub(#ZONE_LINK_PREFIX + 1))
        if not areaId then
            return
        end
    end
    if not ns.questDB then
        ns.Print(ns.questDBProblem)
        return
    end
    buildMainFrame():Show()
    if not areaId then
        return
    end

    -- The window's first layout pass waits a tick after it shows, so the jump waits too.
    local zoneName = getZoneName(areaId)
    C_Timer.After(0.1, function()
        expandAndScrollToZone(zoneName)
    end)
end, ns)

-- Key binding entry point; Bindings.xml can only call named globals. The name global labels the entry under Key Bindings, mirroring how Questie registers its Journey toggle.
BINDING_NAME_QUESTIEGUIDE_TOGGLE = "Toggle Window"

function QuestieGuide_Toggle()
    toggleIfReady()
end

-- One long command and one short alias. The bare command opens the window even when the minimap button is hidden; help, intro and minimap are the shared words, reset rescues a window dragged off-screen, and any other word prints the hint. The window holds QuestieGuideDB.position itself, so reset empties it in place.
SLASH_QUESTIEGUIDE1, SLASH_QUESTIEGUIDE2 = "/questieguide", "/qg"
SlashCmdList.QUESTIEGUIDE = function(message)
    local command = strtrim(message or ""):lower()
    if command == "" then
        toggleIfReady()
    elseif command == "help" or command == "?" then
        ns.Print("Type /qg to open the window, /qg intro to see the welcome line and the tip again, "
            .. "/qg minimap to show or hide the minimap button, /qg reset to move the window back to the center, or /qg help for this list.")
    elseif command == "intro" then
        replayIntro()
    elseif command == "minimap" then
        local show = QuestieGuideDB.minimap.hide
        setMinimapShown(show)
        if not show then ns.Print("Minimap button hidden. Type /qg minimap to show it again.") end
    elseif command == "reset" then
        wipe(QuestieGuideDB.position)
        if ns.mainFrame then
            ns.mainFrame:ClearAllPoints()
            ns.mainFrame:SetPoint("CENTER")
        end
        ns.Print("Window position reset.")
    else
        ns.Print("Unknown command. Type /qg help for the list.")
    end
end

ns.formatZoneLink = formatZoneLink
ns.setupLauncher = setupLauncher
