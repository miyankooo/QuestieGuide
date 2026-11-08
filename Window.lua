-- The tool window: the Filter menu in the attic, the bar buttons, the help tip and the show handler.
local _, ns = ...

local ADDON_ICON = ns.ADDON_ICON
local DEFAULTS = ns.DEFAULTS
local RANGE_LIMIT = ns.RANGE_LIMIT
local SORT_BY_OPTIONS = ns.SORT_BY_OPTIONS
local SORT_DIR_OPTIONS = ns.SORT_DIR_OPTIONS
local SUBCAT_LABEL = ns.SUBCAT_LABEL
local LAYOUT = ns.LAYOUT
local getCurrentZoneName = ns.getCurrentZoneName
local invalidateScan = ns.invalidateScan
local renderList = ns.renderList
local expandAndScrollToZone = ns.expandAndScrollToZone
local renderLoadingPlaceholder = ns.renderLoadingPlaceholder
local buildQuestList = ns.buildQuestList
local buildSearchBox = ns.buildSearchBox
local toggleAllZones = ns.toggleAllZones
local Snap = ns.Snap

-- The spacing role between related controls, and InputBoxTemplate's left cap, drawn 5 px outside the box (InputBoxTemplates.xml:49).
local GAP = 8
local INPUT_ART = 5

-- The collections panel's ornaments, which a tool window leaves out.
local BACKGROUND_CORNERS = { "BGCornerTopLeft", "BGCornerTopRight", "BGCornerBottomLeft", "BGCornerBottomRight" }

-- Restores a saved position, or centres the frame.
local function RestorePosition(frame, position)
    frame:ClearAllPoints()
    if position and position.point then
        frame:SetPoint(position.point, UIParent, position.relPoint or position.point, position.x or 0, position.y or 0)
    else
        frame:SetPoint("CENTER")
    end
end

-- Windows and dialogs: toplevel, clamped, dragged with the left button, closed by Escape through UISpecialFrames,
-- never UIPanelWindows, so they never drive Blizzard's panel layout.
local function MakeMovable(frame, name, strata, position)
    frame:SetFrameStrata(strata)
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if position then
            local point, _, relPoint, x, y = self:GetPoint(1)
            position.point, position.relPoint, position.x, position.y = point, relPoint, x, y
        end
    end)
    RestorePosition(frame, position)
    frame:Hide()
    tinsert(UISpecialFrames, name)
end

-- A tool window on ButtonFrameTemplate: portrait, title, close button, inset, attic and button bar come from the
-- template. The wardrobe's brown panel (CollectionsBackgroundTemplate, Mainline/SharedCollectionTemplates.xml) takes
-- the inset's place without its corner ornaments; Inset stays the content parent and draws nothing.
local function CreateWindow(name, title, icon, width, height, position)
    local frame = CreateFrame("Frame", name, UIParent, "ButtonFrameTemplate")
    frame:SetSize(width, height)
    frame.Inset.Bg:Hide()
    frame.Inset.NineSlice:Hide()
    local background = CreateFrame("Frame", nil, frame, "CollectionsBackgroundTemplate")
    background:ClearAllPoints()
    background:SetAllPoints(frame.Inset)
    for _, corner in ipairs(BACKGROUND_CORNERS) do background[corner]:Hide() end
    frame.Background = background
    frame:SetTitle(title)
    frame:SetPortraitToAsset(icon)

    -- The close button goes through HideUIPanel, which refuses insecure callers in combat. UIPanelCloseButton_OnClick
    -- asks onCloseCallback first, so the window hides itself instead.
    frame.onCloseCallback = function()
        frame:Hide()
        return false
    end

    MakeMovable(frame, name, "HIGH", position)
    return frame
end

-- A MagicButtonTemplate bar button, 128 wide: the first takes the bottom-right corner, later ones chain leftwards.
-- MagicButton_OnLoad runs after the anchor so Blizzard applies its corner and neighbour spacing.
local function AddBarButton(window, label, onClick, width)
    local button = CreateFrame("Button", nil, window, "MagicButtonTemplate")
    button:SetWidth(width or 128)
    window.barButtons = window.barButtons or {}
    local previous = window.barButtons[#window.barButtons]
    if previous then
        button:SetPoint("RIGHT", previous, "LEFT")
    else
        button:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT")
    end
    MagicButton_OnLoad(button)
    button:SetText(label)
    button:SetScript("OnClick", onClick)
    window.barButtons[#window.barButtons + 1] = button
    return button
end

-- Builds the window on first use and flips it after that, so no frame exists until the player asks.
local function CreateToggle(build)
    local window
    return function()
        window = window or build()
        window:SetShown(not window:IsShown())
    end
end

-- Blizzard's Filter button (Blizzard_Menu/Mainline/MenuTemplates.xml:66), as on the Who list. The template sizes
-- itself to its text; the width is fixed on the grid so later text never moves it. Set SetDefaultCallback and
-- SetIsDefaultCallback before SetupMenu; the template then shows its own reset button.
local function CreateFilterDropdown(parent, width)
    local dropdown = CreateFrame("DropdownButton", nil, parent, "WowStyle1FilterDropdownTemplate")
    dropdown.resizeToText = false
    dropdown:SetWidth(width or Snap(dropdown:GetWidth()))
    return dropdown
end

-- Blizzard's yellow help tip as an own HelpTipTemplate frame on the target, never HelpTip:Show, which takes a frame from Blizzard's shared pool and taints the help tips Blizzard shows later. It shows each time its target shows until the player closes it or uses the feature, then never again on the account; it hides with its target without being marked, and /qg intro clears the flag. Init leaves acknowledged set from an earlier close (HelpTip.lua:419-431, 495, 687), so Reset runs before every Init.
local function AttachTip(target, text, targetPoint, relativeRegion)
    local tip
    local info = {
        text = text,
        buttonStyle = HelpTip.ButtonStyle.Close,
        targetPoint = targetPoint,
        onAcknowledgeCallback = function() QuestieGuideDB.tipSeen = true end,
    }
    local function ShowTip()
        if QuestieGuideDB.tipSeen or (tip and tip:IsShown()) then return end
        if not tip then
            tip = CreateFrame("Frame", nil, target, "HelpTipTemplate")
            tip.width = HelpTip.width
            tip:SetWidth(tip.width)
        end
        tip:Reset()
        tip:Init(target, info, relativeRegion or target)
        tip:Show()
    end
    target:HookScript("OnShow", ShowTip)
    if target:IsVisible() then ShowTip() end

    -- The player used the feature: the tip goes for good, shown or not.
    local function Retire()
        if tip and tip.info then tip:Acknowledge() else QuestieGuideDB.tipSeen = true end
    end
    return ShowTip, Retire
end

local TIP_TEXT = "Open Filter to choose quest types, the level range and the sort order."

-- Level Range radios: Questie's own Quest Level Options, or the guide's band of levels below and above the player.
local RANGE_SOURCE_OPTIONS = {
    { value = true,  label = "Questie Level Ranges" },
    { value = false, label = "Custom Range" },
}

-- Radio entries for one side of the custom band, 0 to 10 levels.
local BAND_OPTIONS = {}
for levels = RANGE_LIMIT.MIN, RANGE_LIMIT.MAX do
    BAND_OPTIONS[#BAND_OPTIONS + 1] = { value = levels, label = tostring(levels) }
end

-- Filter menu families, a title and its checkboxes each; the keys live under QuestieGuideDB.filters.
local FILTER_FAMILIES = {
    {
        title = "Availability",
        specs = {
            { key = "inLog",             label = "In Questlog" },
            { key = "available",         label = SUBCAT_LABEL.available },
            { key = "pickedUpElsewhere", label = SUBCAT_LABEL.pickedUpElsewhere },
            { key = "missingPre",        label = "Missing Pre-Quest" },
        },
    },
    {
        title = "Quest Types",
        specs = {
            { key = "dungeons",   label = DUNGEONS },
            { key = "elite", label = ELITE },
            { key = "repeatable", label = QUEST_CLASSIFICATION_RECURRING },
        },
    },
}

-- Everything the menu holds except the sort order, which is not a filter; the native reset button shows while any of it differs from DEFAULTS.
local RANGE_KEYS = { "showCompleted", "useQuestieLevelRange", "levelBelow", "levelAbove" }

local function filtersAreDefault()
    for key, default in pairs(DEFAULTS.filters) do
        if QuestieGuideDB.filters[key] ~= default then
            return false
        end
    end
    for _, key in ipairs(RANGE_KEYS) do
        if QuestieGuideDB[key] ~= DEFAULTS[key] then
            return false
        end
    end
    return true
end

local function resetFilters()
    for key, default in pairs(DEFAULTS.filters) do
        QuestieGuideDB.filters[key] = default
    end
    for _, key in ipairs(RANGE_KEYS) do
        QuestieGuideDB[key] = DEFAULTS[key]
    end
    invalidateScan()
    renderList()
end

-- The level range decides which quests the scan lists, so every change rescans. Picking a band size switches to the custom range it belongs to.
local function setRangeSetting(dbKey, value)
    QuestieGuideDB[dbKey] = value
    if dbKey ~= "useQuestieLevelRange" then
        QuestieGuideDB.useQuestieLevelRange = false
    end
    invalidateScan()
    renderList()
end

-- Sorting only reorders the cached scan.
local function setSortSetting(dbKey, value)
    QuestieGuideDB[dbKey] = value
    renderList()
end

-- One radio per option, bound to one saved key. A radio closes the whole menu unless its callback returns a response (Menu.lua, MenuManagerMixin:AttributeRespond), so range radios pass MenuResponse.Refresh to stay open and redraw their marks.
local function addRadios(description, dbKey, options, onSelect, response)
    for _, option in ipairs(options) do
        description:CreateRadio(option.label,
            function() return QuestieGuideDB[dbKey] == option.value end,
            function()
                onSelect(dbKey, option.value)
                return response
            end)
    end
end

-- Filters only narrow the rows on screen, so a toggle re-renders without a rescan. The menu rereads every state on open, and the template rechecks its reset button after each click.
local function setupFilterMenu(_, rootDescription)
    local filters = QuestieGuideDB.filters
    for _, family in ipairs(FILTER_FAMILIES) do
        rootDescription:CreateTitle(family.title)
        for _, spec in ipairs(family.specs) do
            rootDescription:CreateCheckbox(spec.label,
                function() return filters[spec.key] end,
                function()
                    filters[spec.key] = not filters[spec.key]
                    renderList()
                end)
        end
    end
    rootDescription:CreateDivider()
    rootDescription:CreateCheckbox("Show Completed",
        function() return QuestieGuideDB.showCompleted end,
        function()
            QuestieGuideDB.showCompleted = not QuestieGuideDB.showCompleted
            renderList()
        end)

    local rangeMenu = rootDescription:CreateButton(LEVEL_RANGE)
    addRadios(rangeMenu, "useQuestieLevelRange", RANGE_SOURCE_OPTIONS, setRangeSetting, MenuResponse.Refresh)
    addRadios(rangeMenu:CreateButton("Levels Below"), "levelBelow", BAND_OPTIONS, setRangeSetting, MenuResponse.Refresh)
    addRadios(rangeMenu:CreateButton("Levels Above"), "levelAbove", BAND_OPTIONS, setRangeSetting, MenuResponse.Refresh)

    local sortMenu = rootDescription:CreateButton(WHO_SORT_LABEL)
    addRadios(sortMenu, "sortMode", SORT_BY_OPTIONS, setSortSetting)
    sortMenu:CreateDivider()
    addRadios(sortMenu, "sortDir", SORT_DIR_OPTIONS, setSortSetting)
end

-- Blizzard's Filter button left of the search box, one gap between their art. Its reset button appears whenever the filters differ from the defaults. It holds every option, so the help tip points here, below the button where the list has room, and opening the menu counts as using it.
local function buildFilterDropdown(frame)
    local filter = CreateFilterDropdown(frame)
    filter:SetPoint("RIGHT", frame.searchBox, "LEFT", -(GAP + INPUT_ART + LAYOUT.FILTER_ART), 0)
    filter:SetDefaultCallback(resetFilters)
    filter:SetIsDefaultCallback(filtersAreDefault)
    filter:SetupMenu(setupFilterMenu)
    local _, retireTip = AttachTip(filter, TIP_TEXT, HelpTip.Point.BottomEdgeCenter)
    filter:RegisterCallback(DropdownButtonMixin.Event.OnMenuOpen, retireTip)
    frame.filterDropdown = filter
end

-- Expands and scrolls to the zone the player is standing in.
local function jumpToCurrentZone()
    local zoneName = getCurrentZoneName()
    if not zoneName then
        ns.Print("Your current zone has no Questie data.")
        return
    end
    if not expandAndScrollToZone(zoneName) then
        ns.Print("No quests listed for " .. zoneName .. ". Widen the level range or change the filters.")
    end
end

-- Questie fills its tag cache a second after a first lookup misses, so the session's first list renders once more when the tags have arrived.
local TAG_RETRY_DELAY = 1.5
local tagRetryDone = false

-- Every open lays the list out on the next tick: row wrapping needs the scroll child's width, which the scroll frame only resolves after its first layout.
local function onWindowShow(frame)
    renderLoadingPlaceholder()
    C_Timer.After(0, function()
        if not frame:IsShown() then
            return
        end
        renderList()
        if not tagRetryDone then
            tagRetryDone = true
            C_Timer.After(TAG_RETRY_DELAY, function()
                if frame:IsShown() then
                    renderList()
                end
            end)
        end
    end)
end

-- Builds the window on first open and returns it afterwards. The shared tool window keeps its place in QuestieGuideDB.position; the primary action, Current Zone, takes the bar's bottom-right corner with Collapse All beside it.
local function buildMainFrame()
    if ns.mainFrame then
        return ns.mainFrame
    end
    local frame = CreateWindow("QuestieGuideFrame", ns.title, ADDON_ICON, LAYOUT.FRAME_W, LAYOUT.FRAME_H, QuestieGuideDB.position)
    buildQuestList(frame)
    buildSearchBox(frame)
    buildFilterDropdown(frame)
    AddBarButton(frame, "Current Zone", jumpToCurrentZone)
    frame.toggleAllButton = AddBarButton(frame, "Collapse All", toggleAllZones)
    frame:HookScript("OnShow", onWindowShow)
    ns.mainFrame = frame
    return frame
end

-- One toggle for every launcher; the window is built on first use.
local toggleWindow = CreateToggle(buildMainFrame)

ns.buildMainFrame = buildMainFrame
ns.toggleWindow = toggleWindow
