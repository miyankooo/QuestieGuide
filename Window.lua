-- The tool window: the Filter menu in the attic, the bar buttons and the show handler.
local _, ns = ...

local UI = LibStub("LibNativeUI-1.0")

local ADDON_TITLE = ns.ADDON_TITLE
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

-- Blizzard's Filter button left of the search box, one gap between their art. Its reset button appears whenever the filters differ from the defaults.
local function buildFilterDropdown(frame)
    local filter = UI.CreateFilterDropdown(frame)
    filter:SetPoint("RIGHT", frame.searchBox, "LEFT", -(UI.Space.gap + UI.Native.inputArt + LAYOUT.FILTER_ART), 0)
    filter:SetDefaultCallback(resetFilters)
    filter:SetIsDefaultCallback(filtersAreDefault)
    filter:SetupMenu(setupFilterMenu)
    frame.filterDropdown = filter
end

-- Expands and scrolls to the zone the player is standing in.
local function jumpToCurrentZone()
    local zoneName = getCurrentZoneName()
    if not zoneName then
        UI.Print(ADDON_TITLE, "Your current zone has no Questie data.")
        return
    end
    if not expandAndScrollToZone(zoneName) then
        UI.Print(ADDON_TITLE, "No quests listed for " .. zoneName .. ". Widen the level range or change the filters.")
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
    local frame = UI.CreateWindow({
        name = "QuestieGuideFrame",
        title = ADDON_TITLE,
        icon = ADDON_ICON,
        width = LAYOUT.FRAME_W,
        height = LAYOUT.FRAME_H,
        position = QuestieGuideDB.position,
    })
    buildQuestList(frame)
    buildSearchBox(frame)
    buildFilterDropdown(frame)
    UI.AddBarButton(frame, "Current Zone", jumpToCurrentZone)
    frame.toggleAllButton = UI.AddBarButton(frame, "Collapse All", toggleAllZones)
    frame:HookScript("OnShow", onWindowShow)
    ns.mainFrame = frame
    return frame
end

-- One toggle for every launcher; the window is built on first use.
local toggleWindow = UI.CreateToggle(buildMainFrame)

ns.buildMainFrame = buildMainFrame
ns.toggleWindow = toggleWindow
