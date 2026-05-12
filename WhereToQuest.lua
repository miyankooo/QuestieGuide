-- WhereToQuest: lists Questie-known quests within a level range around the player.

local ADDON_NAME = ...

local DEFAULTS = { minBelow = 5, maxAbove = 3, sortMode = "name" }

local SORT_OPTIONS = {
    { value = "name",     label = "Alphabetical" },
    { value = "count",    label = "Number of quests" },
    { value = "levelDiff", label = "Level discrepancy" },
}

local ROW_HEIGHT = 16
local HEADER_HEIGHT = 18
local FRAME_WIDTH = 360
local FRAME_HEIGHT = 460

-- Questie module handles, resolved lazily because Questie loads after us.
local QuestieDB
local QuestieLib
local ZoneDB
local QuestiePlayer
local QuestXP

local mainFrame
local scrollChild
local rowPool = {}
local zoneCollapsed = {}
local lastZoneOrder = {}
local renderList

-- Resolve Questie modules. Returns true once Questie is loaded enough to query.
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
    return QuestieDB ~= nil and QuestieDB.QuestPointers ~= nil
end

-- Map a Questie zoneOrSort value to a human-readable zone name.
-- Positive values are Blizzard area IDs; negative values are quest sort categories.
local function getZoneName(zoneOrSort)
    if not zoneOrSort or zoneOrSort <= 0 then
        return "Other"
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

-- Pick the "effective" level to compare against the player's range.
local function getEffectiveLevel(questId, playerLevel)
    local level, requiredLevel = QuestieLib.GetTbcLevel(questId, playerLevel)
    if level and level > 0 then
        return level, requiredLevel or 0
    end
    return requiredLevel or 0, requiredLevel or 0
end

-- Gather quests that pass IsDoable and fall inside the configured level range.
-- Returns { [zoneName] = { { id, level, name }, ... }, ... } and a sorted zone list.
local function collectAvailableQuests()
    if not loadQuestie() then
        return {}, {}
    end
    local playerLevel = UnitLevel("player")
    local cfg = WhereToQuestDB or DEFAULTS
    local minLevel = playerLevel - (cfg.minBelow or DEFAULTS.minBelow)
    local maxLevel = playerLevel + (cfg.maxAbove or DEFAULTS.maxAbove)
    local currentLog = (QuestiePlayer and QuestiePlayer.currentQuestlog) or {}

    local byZone = {}
    for questId in pairs(QuestieDB.QuestPointers) do
        if not currentLog[questId] and QuestieDB.IsDoable(questId) then
            local level = getEffectiveLevel(questId, playerLevel)
            if level >= minLevel and level <= maxLevel then
                local zoneOrSort = QuestieDB.QueryQuestSingle(questId, "zoneOrSort")
                local zoneName = getZoneName(zoneOrSort)
                local list = byZone[zoneName]
                if not list then
                    list = {}
                    byZone[zoneName] = list
                end
                local name = QuestieDB.QueryQuestSingle(questId, "name") or ("Quest " .. questId)
                list[#list + 1] = { id = questId, level = level, name = name }
            end
        end
    end

    local zoneOrder = {}
    local zoneStats = {}
    for zoneName, list in pairs(byZone) do
        zoneOrder[#zoneOrder + 1] = zoneName
        table.sort(list, function(a, b)
            if a.level == b.level then
                return a.name < b.name
            end
            return a.level < b.level
        end)
        local sum = 0
        for _, q in ipairs(list) do
            sum = sum + q.level
        end
        local avg = #list > 0 and (sum / #list) or 0
        zoneStats[zoneName] = {
            count = #list,
            avgLevel = avg,
            levelDiff = math.abs(avg - playerLevel),
        }
    end

    local mode = (WhereToQuestDB and WhereToQuestDB.sortMode) or DEFAULTS.sortMode
    if mode == "count" then
        table.sort(zoneOrder, function(a, b)
            local ca, cb = zoneStats[a].count, zoneStats[b].count
            if ca == cb then
                return a < b
            end
            return ca > cb
        end)
    elseif mode == "levelDiff" then
        table.sort(zoneOrder, function(a, b)
            local da, db = zoneStats[a].levelDiff, zoneStats[b].levelDiff
            if da == db then
                return a < b
            end
            return da < db
        end)
    else
        table.sort(zoneOrder)
    end
    return byZone, zoneOrder, zoneStats
end

-- Build a Questie-style tooltip for a single quest.
local function showQuestTooltip(anchor, questId)
    if not loadQuestie() then
        return
    end
    local quest = QuestieDB.GetQuest(questId)
    if not quest then
        return
    end

    GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")

    local title = QuestieLib:GetColoredQuestName(questId, true, false)
    GameTooltip:AddLine(title)

    if quest.requiredLevel and quest.requiredLevel > 0 then
        GameTooltip:AddLine("Required level: " .. quest.requiredLevel, 0.8, 0.8, 0.8)
    end

    if quest.objectivesText and #quest.objectivesText > 0 then
        GameTooltip:AddLine(" ")
        for _, line in ipairs(quest.objectivesText) do
            GameTooltip:AddLine(line, 1, 1, 1, true)
        end
    end

    -- XP reward via Questie's QuestXP module. Assumption: this Questie API is stable.
    if QuestXP and QuestXP.GetQuestLogRewardXP then
        local ok, xp = pcall(QuestXP.GetQuestLogRewardXP, QuestXP, questId, true)
        if ok and xp and xp > 0 then
            GameTooltip:AddLine("XP reward: " .. xp, 1, 0.82, 0)
        end
    end

    local preSingle = quest.preQuestSingle
    if preSingle and #preSingle > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Requires one of:", 0.8, 0.8, 0.8)
        for _, pid in ipairs(preSingle) do
            local pname = QuestieDB.QueryQuestSingle(pid, "name") or ("Quest " .. pid)
            GameTooltip:AddLine("  " .. pname, 0.7, 0.7, 0.7)
        end
    end

    local preGroup = quest.preQuestGroup
    if preGroup and #preGroup > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Requires all of:", 0.8, 0.8, 0.8)
        for _, pid in ipairs(preGroup) do
            local pname = QuestieDB.QueryQuestSingle(pid, "name") or ("Quest " .. pid)
            GameTooltip:AddLine("  " .. pname, 0.7, 0.7, 0.7)
        end
    end

    local nextId = quest.nextQuestInChain
    if nextId and nextId > 0 then
        local nname = QuestieDB.QueryQuestSingle(nextId, "name") or ("Quest " .. nextId)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Follow-up: " .. nname, 0.6, 0.85, 1)
    end

    GameTooltip:Show()
end

-- Acquire or recycle a row button used for both zone headers and quest entries.
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
    row.text = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.text:SetJustifyH("LEFT")
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

function renderList()
    if not scrollChild then
        return
    end
    local byZone, zoneOrder = collectAvailableQuests()
    lastZoneOrder = zoneOrder
    local index = 1
    local y = 0

    for _, zoneName in ipairs(zoneOrder) do
        local list = byZone[zoneName]
        local collapsed = zoneCollapsed[zoneName] == true

        local header = acquireRow(index)
        header:SetHeight(HEADER_HEIGHT)
        header:ClearAllPoints()
        header:SetPoint("LEFT", scrollChild, "LEFT", 0, 0)
        header:SetPoint("RIGHT", scrollChild, "RIGHT", 0, 0)
        header:SetPoint("TOP", scrollChild, "TOP", 0, -y)
        local arrow = collapsed and "|cffffd200[+]|r " or "|cffffd200[-]|r "
        header.text:SetText(arrow .. zoneName .. " (" .. #list .. ")")
        header:SetScript("OnClick", function()
            zoneCollapsed[zoneName] = not collapsed
            renderList()
        end)
        header:SetScript("OnEnter", nil)
        header:SetScript("OnLeave", nil)
        y = y + HEADER_HEIGHT
        index = index + 1

        if not collapsed then
            for _, quest in ipairs(list) do
                local row = acquireRow(index)
                row:SetHeight(ROW_HEIGHT)
                row:ClearAllPoints()
                row:SetPoint("LEFT", scrollChild, "LEFT", 14, 0)
                row:SetPoint("RIGHT", scrollChild, "RIGHT", 0, 0)
                row:SetPoint("TOP", scrollChild, "TOP", 0, -y)
                local r, g, b = 1, 1, 1
                if QuestieLib and QuestieLib.GetDifficultyColorPercent then
                    r, g, b = QuestieLib:GetDifficultyColorPercent(quest.level)
                end
                row.text:SetText(string.format("|cff%02x%02x%02x[%d] %s|r",
                    math.floor(r * 255), math.floor(g * 255), math.floor(b * 255),
                    quest.level, quest.name))
                local questId = quest.id
                row:SetScript("OnEnter", function(self)
                    showQuestTooltip(self, questId)
                end)
                row:SetScript("OnLeave", function()
                    GameTooltip:Hide()
                end)
                row:SetScript("OnClick", nil)
                y = y + ROW_HEIGHT
                index = index + 1
            end
        end
    end

    if index == 1 then
        local row = acquireRow(index)
        row:SetHeight(ROW_HEIGHT)
        row:ClearAllPoints()
        row:SetPoint("LEFT", scrollChild, "LEFT", 0, 0)
        row:SetPoint("RIGHT", scrollChild, "RIGHT", 0, 0)
        row:SetPoint("TOP", scrollChild, "TOP", 0, -y)
        row.text:SetText("|cffaaaaaaNo available quests in range.|r")
        row:SetScript("OnEnter", nil)
        row:SetScript("OnLeave", nil)
        row:SetScript("OnClick", nil)
        y = y + ROW_HEIGHT
        index = index + 1
    end

    scrollChild:SetHeight(math.max(y, 1))
    hideUnusedRows(index)

    if mainFrame and mainFrame.toggleAllButton then
        local allCollapsed = #zoneOrder > 0
        for _, zoneName in ipairs(zoneOrder) do
            if not zoneCollapsed[zoneName] then
                allCollapsed = false
                break
            end
        end
        mainFrame.toggleAllButton:SetText(allCollapsed and "Expand all" or "Collapse all")
    end
end

local function buildMainFrame()
    if mainFrame then
        return mainFrame
    end

    local frame = CreateFrame("Frame", "WhereToQuestFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.title:SetPoint("TOP", frame.TitleBg, "TOP", 0, -3)
    frame.title:SetText("WhereToQuest")

    local belowLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    belowLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -42)
    belowLabel:SetText("Levels below")

    local belowBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    belowBox:SetSize(36, 20)
    belowBox:SetPoint("LEFT", belowLabel, "RIGHT", 10, 0)
    belowBox:SetAutoFocus(false)
    belowBox:SetNumeric(true)
    belowBox:SetMaxLetters(2)
    frame.belowBox = belowBox

    local aboveLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    aboveLabel:SetPoint("LEFT", belowBox, "RIGHT", 16, 0)
    aboveLabel:SetText("Levels above")

    local aboveBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    aboveBox:SetSize(36, 20)
    aboveBox:SetPoint("LEFT", aboveLabel, "RIGHT", 10, 0)
    aboveBox:SetAutoFocus(false)
    aboveBox:SetNumeric(true)
    aboveBox:SetMaxLetters(2)
    frame.aboveBox = aboveBox

    -- Write one input back to WhereToQuestDB. Returns true if the stored value changed.
    local function applyInput(editBox, key)
        local n = tonumber(editBox:GetText() or "")
        if not n or n < 0 then
            return false
        end
        n = math.floor(n)
        if WhereToQuestDB[key] == n then
            return false
        end
        WhereToQuestDB[key] = n
        return true
    end

    local function applyAndRefresh()
        local changed = applyInput(belowBox, "minBelow")
        if applyInput(aboveBox, "maxAbove") then
            changed = true
        end
        if changed then
            renderList()
        end
    end

    -- Debounce typing so the list doesn't rebuild on every keystroke.
    local pendingTimer
    local function cancelPending()
        if pendingTimer then
            pendingTimer:Cancel()
            pendingTimer = nil
        end
    end
    local function scheduleApply()
        cancelPending()
        pendingTimer = C_Timer.NewTimer(0.25, function()
            pendingTimer = nil
            applyAndRefresh()
        end)
    end
    local function flushApply(self)
        cancelPending()
        applyAndRefresh()
        if self and self.ClearFocus then
            self:ClearFocus()
        end
    end

    for _, box in ipairs({ belowBox, aboveBox }) do
        box:SetScript("OnTextChanged", scheduleApply)
        box:SetScript("OnEnterPressed", flushApply)
        box:SetScript("OnEditFocusLost", flushApply)
        box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    end

    local toggleAllButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    toggleAllButton:SetSize(96, 22)
    toggleAllButton:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -72)
    toggleAllButton:SetText("Collapse all")
    toggleAllButton:SetScript("OnClick", function()
        local anyExpanded = false
        for _, zoneName in ipairs(lastZoneOrder) do
            if not zoneCollapsed[zoneName] then
                anyExpanded = true
                break
            end
        end
        for _, zoneName in ipairs(lastZoneOrder) do
            zoneCollapsed[zoneName] = anyExpanded
        end
        renderList()
    end)
    frame.toggleAllButton = toggleAllButton

    local sortLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sortLabel:SetPoint("LEFT", toggleAllButton, "RIGHT", 18, 0)
    sortLabel:SetText("Sort zones by")

    local sortDropdown = CreateFrame("Frame", "WhereToQuestSortDropdown", frame, "UIDropDownMenuTemplate")
    sortDropdown:SetPoint("LEFT", sortLabel, "RIGHT", -4, -2)
    UIDropDownMenu_SetWidth(sortDropdown, 130)

    local function getSortLabel(value)
        for _, opt in ipairs(SORT_OPTIONS) do
            if opt.value == value then
                return opt.label
            end
        end
        return SORT_OPTIONS[1].label
    end

    local function initSortDropdown(self, level)
        local current = (WhereToQuestDB and WhereToQuestDB.sortMode) or DEFAULTS.sortMode
        for _, opt in ipairs(SORT_OPTIONS) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = opt.label
            info.value = opt.value
            info.checked = current == opt.value
            info.func = function(btn)
                WhereToQuestDB.sortMode = btn.value
                UIDropDownMenu_SetText(sortDropdown, getSortLabel(btn.value))
                renderList()
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end
    UIDropDownMenu_Initialize(sortDropdown, initSortDropdown)
    frame.sortDropdown = sortDropdown
    frame.refreshSortDropdown = function()
        UIDropDownMenu_SetText(sortDropdown, getSortLabel((WhereToQuestDB and WhereToQuestDB.sortMode) or DEFAULTS.sortMode))
    end

    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -102)
    scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -32, 12)

    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(FRAME_WIDTH - 60, 1)
    scroll:SetScrollChild(child)
    scrollChild = child
    frame.scroll = scroll

    mainFrame = frame
    return frame
end

local function showFrame()
    local frame = buildMainFrame()
    frame.belowBox:SetText(tostring(WhereToQuestDB.minBelow))
    frame.aboveBox:SetText(tostring(WhereToQuestDB.maxAbove))
    if frame.refreshSortDropdown then
        frame.refreshSortDropdown()
    end
    frame:Show()
    renderList()
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
SlashCmdList["WHERETOQUEST"] = function()
    toggleFrame()
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self, event, name)
    if event == "ADDON_LOADED" and name == ADDON_NAME then
        if type(WhereToQuestDB) ~= "table" then
            WhereToQuestDB = {}
        end
        if type(WhereToQuestDB.minBelow) ~= "number" then
            WhereToQuestDB.minBelow = DEFAULTS.minBelow
        end
        if type(WhereToQuestDB.maxAbove) ~= "number" then
            WhereToQuestDB.maxAbove = DEFAULTS.maxAbove
        end
        local validSort = false
        for _, opt in ipairs(SORT_OPTIONS) do
            if WhereToQuestDB.sortMode == opt.value then
                validSort = true
                break
            end
        end
        if not validSort then
            WhereToQuestDB.sortMode = DEFAULTS.sortMode
        end
    end
end)
