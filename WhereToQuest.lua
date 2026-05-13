-- WhereToQuest: zone-bucketed quest browser sourced from Questie.

local ADDON_NAME = ...

local DEFAULTS = {
    minBelow = 5,
    maxAbove = 3,
    sortMode = "name",
    filters = { inLog = true, available = true, missingPre = true },
}

local INTRO_PREFIX = "|cffffff00[WhereToQuest]:|r "

local SORT_OPTIONS = {
    { value = "name",     label = "Alphabetical" },
    { value = "count",    label = "Number of quests" },
    { value = "levelDiff", label = "Level discrepancy" },
}

local SUBCAT_ORDER = { "inLog", "available", "missingPre" }
local SUBCAT_LABEL = {
    inLog = "In Quest Log",
    available = "Available",
    missingPre = "Missing Pre Quest",
}

-- List spacing on an 8px grid.
local ROW_HEIGHT = 16
local SUBHEADER_HEIGHT = 18
local HEADER_HEIGHT = 20
local ROW_GAP = 4
local GROUP_GAP = 8
local ZONE_GAP = 12
local INDENT_STEP = 16

local FRAME_WIDTH = 360
local FRAME_HEIGHT = 560

local PAD_X = 14
local PAD_TOP = 30
local PAD_BOTTOM = 12
local SECTION_GAP = 14
local ELEMENT_GAP = 6
local INPUT_ROW_HEIGHT = 22

local MAX_CHAIN_DEPTH = 12

-- Classic Era (1.15.x) caps at 60; reject post-vanilla quests Questie may ship.
local CLASSIC_MAX_LEVEL = 60

-- Questie modules; resolved lazily because Questie loads after us.
local QuestieDB
local QuestieLib
local ZoneDB
local QuestiePlayer
local QuestXP

local mainFrame
local scrollChild
local rowPool = {}
local zoneCollapsed = {}
local groupCollapsed = {}
local lastZoneOrder = {}
local renderList

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

-- zoneOrSort > 0 is a Blizzard area ID; <= 0 is a sort category we collapse into "Other".
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

-- Returns name, zoneName, {x, y} for the quest's lowest-id starting NPC spawn.
local function getQuestStartInfo(questId)
    if not QuestieDB or not QuestieDB.GetNPC then
        return nil, nil, nil
    end
    local startedBy = QuestieDB.QueryQuestSingle(questId, "startedBy")
    local npcIds = startedBy and startedBy[1]
    if type(npcIds) ~= "table" or not npcIds[1] then
        return nil, nil, nil
    end
    local npc = QuestieDB:GetNPC(npcIds[1])
    if not npc then
        return nil, nil, nil
    end
    if type(npc.spawns) ~= "table" then
        return npc.name, nil, nil
    end
    local bestZoneId, bestSpawn
    for zoneId, spawns in pairs(npc.spawns) do
        if type(spawns) == "table" and spawns[1] and not (bestZoneId and zoneId >= bestZoneId) then
            bestZoneId = zoneId
            bestSpawn = spawns[1]
        end
    end
    if not bestZoneId then
        return npc.name, nil, nil
    end
    return npc.name, getZoneName(bestZoneId), bestSpawn
end

local function isQuestCompleted(questId)
    if IsQuestFlaggedCompleted then
        return IsQuestFlaggedCompleted(questId) == true
    end
    return false
end

-- preQuestSingle (OR) takes precedence over preQuestGroup (AND); Questie treats them as exclusive.
local function getQuestPrereqs(questId)
    local preIds = QuestieDB.QueryQuestSingle(questId, "preQuestSingle")
    if type(preIds) == "table" and preIds[1] then
        return preIds
    end
    preIds = QuestieDB.QueryQuestSingle(questId, "preQuestGroup")
    if type(preIds) == "table" and preIds[1] then
        return preIds
    end
    return nil
end

-- Returns the chain [initial, ..., target] of incomplete prereqs, or nil if all are complete.
local function findMissingChain(targetId)
    local chain = { targetId }
    local visited = { [targetId] = true }
    local cursor = targetId
    for _ = 1, MAX_CHAIN_DEPTH do
        local preIds = getQuestPrereqs(cursor)
        if not preIds then
            break
        end
        local nextPre
        for _, preId in ipairs(preIds) do
            if not visited[preId] and not isQuestCompleted(preId) then
                nextPre = preId
                break
            end
        end
        if not nextPre then
            break
        end
        visited[nextPre] = true
        table.insert(chain, 1, nextPre)
        cursor = nextPre
    end
    if #chain <= 1 then
        return nil
    end
    return chain
end

-- Buckets every quest into its zone. Expensive; caller should cache the result.
local function scanQuestsByZone()
    if not loadQuestie() then
        return {}, {}
    end
    local playerLevel = UnitLevel("player")
    local cfg = WhereToQuestDB or DEFAULTS
    local minLevel = playerLevel - (cfg.minBelow or DEFAULTS.minBelow)
    local maxLevel = playerLevel + (cfg.maxAbove or DEFAULTS.maxAbove)
    local currentLog = (QuestiePlayer and QuestiePlayer.currentQuestlog) or {}

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

    for questId in pairs(currentLog) do
        local zoneOrSort = QuestieDB.QueryQuestSingle(questId, "zoneOrSort")
        local level, requiredLevel = getEffectiveLevel(questId, playerLevel)
        if zoneOrSort and level <= CLASSIC_MAX_LEVEL and (requiredLevel or 0) <= CLASSIC_MAX_LEVEL then
            local entry = ensureZone(getZoneName(zoneOrSort))
            entry.inLog[#entry.inLog + 1] = { id = questId, level = level, name = getQuestName(questId) }
            entry.count = entry.count + 1
        end
    end

    local rangeCap = math.min(maxLevel, CLASSIC_MAX_LEVEL)

    for questId in pairs(QuestieDB.QuestPointers) do
        if not currentLog[questId] then
            local level, requiredLevel = getEffectiveLevel(questId, playerLevel)
            if level >= minLevel and level <= rangeCap and (requiredLevel or 0) <= CLASSIC_MAX_LEVEL then
                if QuestieDB.IsDoable(questId) then
                    local zoneOrSort = QuestieDB.QueryQuestSingle(questId, "zoneOrSort")
                    if zoneOrSort then
                        local entry = ensureZone(getZoneName(zoneOrSort))
                        entry.available[#entry.available + 1] = { id = questId, level = level, name = getQuestName(questId) }
                        entry.count = entry.count + 1
                    end
                elseif getQuestPrereqs(questId) then
                    -- Skip quests blocked by class/faction/race (no prereqs to surface).
                    local chain = findMissingChain(questId)
                    if chain then
                        local zoneOrSort = QuestieDB.QueryQuestSingle(questId, "zoneOrSort")
                        if zoneOrSort then
                            local entry = ensureZone(getZoneName(zoneOrSort))
                            local initialId = chain[1]
                            local mpe = entry.missingPre.entries[initialId]
                            if not mpe then
                                mpe = {
                                    initialId = initialId,
                                    initialName = getQuestName(initialId),
                                    initialLevel = getEffectiveLevel(initialId, playerLevel),
                                    targets = {},
                                }
                                entry.missingPre.entries[initialId] = mpe
                                entry.missingPre.order[#entry.missingPre.order + 1] = initialId
                            end
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

        local sum, total = 0, 0
        for _, q in ipairs(entry.inLog) do sum = sum + q.level; total = total + 1 end
        for _, q in ipairs(entry.available) do sum = sum + q.level; total = total + 1 end
        local avg = total > 0 and (sum / total) or 0
        entry.stats = {
            count = entry.count,
            avgLevel = avg,
            levelDiff = math.abs(avg - playerLevel),
        }
    end

    table.sort(zoneOrder)
    return byZone, zoneOrder
end

-- Apply the user's sort mode in place. Cheap; safe to call every render.
local function sortZones(zoneOrder, byZone)
    local mode = (WhereToQuestDB and WhereToQuestDB.sortMode) or DEFAULTS.sortMode
    if mode == "count" then
        table.sort(zoneOrder, function(a, b)
            local ca, cb = byZone[a].stats.count, byZone[b].stats.count
            if ca == cb then
                return a < b
            end
            return ca > cb
        end)
    elseif mode == "levelDiff" then
        table.sort(zoneOrder, function(a, b)
            local da, db = byZone[a].stats.levelDiff, byZone[b].stats.levelDiff
            if da == db then
                return a < b
            end
            return da < db
        end)
    else
        table.sort(zoneOrder)
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
    if #entry.targets == 1 then
        addTooltipField("Chain leads to", primary.name)
    else
        addTooltipField("Chain unlocks", string.format("%d quests in this zone", #entry.targets))
    end
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

local function colorQuestName(level, name)
    local r, g, b = 1, 1, 1
    if QuestieLib and QuestieLib.GetDifficultyColorPercent then
        r, g, b = QuestieLib:GetDifficultyColorPercent(level)
    end
    return string.format("|cff%02x%02x%02x%s|r",
        math.floor(r * 255), math.floor(g * 255), math.floor(b * 255), name)
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

    local function placeRow(row, height, indent)
        row:SetHeight(height)
        row:ClearAllPoints()
        row:SetPoint("LEFT", scrollChild, "LEFT", indent, 0)
        row:SetPoint("RIGHT", scrollChild, "RIGHT", 0, 0)
        row:SetPoint("TOP", scrollChild, "TOP", 0, -y)
    end

    local function hideGameTooltip()
        GameTooltip:Hide()
    end

    local function renderQuestRow(level, name, onEnter)
        y = y + ROW_GAP
        local row = acquireRow(index)
        placeRow(row, ROW_HEIGHT, INDENT_STEP * 2)
        row.text:SetText(colorQuestName(level, name))
        row:SetScript("OnEnter", onEnter)
        row:SetScript("OnLeave", hideGameTooltip)
        row:SetScript("OnClick", nil)
        y = y + ROW_HEIGHT
        index = index + 1
    end

    for _, zoneName in ipairs(zoneOrder) do
        local entry = byZone[zoneName]
        local collapsed = zoneCollapsed[zoneName] == true

        local visibleCounts = {
            inLog = filters.inLog and #entry.inLog or 0,
            available = filters.available and #entry.available or 0,
            missingPre = filters.missingPre and #entry.missingPre.order or 0,
        }

        if visibleCounts.inLog + visibleCounts.available + visibleCounts.missingPre > 0 then
            if renderedZones > 0 then
                y = y + ZONE_GAP
            end
            renderedZones = renderedZones + 1

            local header = acquireRow(index)
            placeRow(header, HEADER_HEIGHT, 0)
            local arrow = collapsed and "|cffffd200[+]|r " or "|cffffd200[-]|r "
            header.text:SetText(arrow .. zoneName .. " (" .. entry.count .. ")")
            header:SetScript("OnClick", function()
                zoneCollapsed[zoneName] = not collapsed
                renderList()
            end)
            header:SetScript("OnEnter", nil)
            header:SetScript("OnLeave", nil)
            y = y + HEADER_HEIGHT
            index = index + 1

            if not collapsed then
                local subIndex = 0
                for _, subKey in ipairs(SUBCAT_ORDER) do
                    local count = filters[subKey] and visibleCounts[subKey] or 0
                    if count > 0 then
                        subIndex = subIndex + 1
                        local groupKey = zoneName .. "||" .. subKey
                        local groupHidden = groupCollapsed[groupKey] == true

                        y = y + (subIndex == 1 and ROW_GAP or GROUP_GAP)

                        local sub = acquireRow(index)
                        placeRow(sub, SUBHEADER_HEIGHT, INDENT_STEP)
                        local subArrow = groupHidden and "[+]" or "[-]"
                        sub.text:SetText(string.format("|cff9d9d9d%s %s (%d)|r",
                            subArrow, SUBCAT_LABEL[subKey], count))
                        sub:SetScript("OnClick", function()
                            groupCollapsed[groupKey] = not groupHidden
                            renderList()
                        end)
                        sub:SetScript("OnEnter", nil)
                        sub:SetScript("OnLeave", nil)
                        y = y + SUBHEADER_HEIGHT
                        index = index + 1

                        if not groupHidden then
                            if subKey == "missingPre" then
                                for _, initialId in ipairs(entry.missingPre.order) do
                                    local mpe = entry.missingPre.entries[initialId]
                                    renderQuestRow(mpe.initialLevel, mpe.initialName, function(self)
                                        showChainTooltip(self, mpe)
                                    end)
                                end
                            else
                                for _, quest in ipairs(entry[subKey]) do
                                    local questId = quest.id
                                    renderQuestRow(quest.level, quest.name, function(self)
                                        showQuestTooltip(self, questId)
                                    end)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if renderedZones == 0 then
        local row = acquireRow(index)
        placeRow(row, ROW_HEIGHT, 0)
        row.text:SetText("|cffaaaaaaNo quests match the current filters.|r")
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

    -- Level Range section

    local levelRangeTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    levelRangeTitle:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD_X, -PAD_TOP)
    levelRangeTitle:SetText("Level Range")

    local levelRangeHelp = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    levelRangeHelp:SetPoint("TOPLEFT", levelRangeTitle, "BOTTOMLEFT", 0, -ELEMENT_GAP)
    levelRangeHelp:SetPoint("RIGHT", frame, "RIGHT", -PAD_X, 0)
    levelRangeHelp:SetJustifyH("LEFT")
    levelRangeHelp:SetWordWrap(true)
    levelRangeHelp:SetText("Quests within this many levels below and above your current level.")

    local rangeRow = CreateFrame("Frame", nil, frame)
    rangeRow:SetPoint("TOPLEFT", levelRangeHelp, "BOTTOMLEFT", 0, -ELEMENT_GAP)
    rangeRow:SetPoint("RIGHT", frame, "RIGHT", -PAD_X, 0)
    rangeRow:SetHeight(INPUT_ROW_HEIGHT)

    local belowLabel = rangeRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    belowLabel:SetPoint("LEFT", rangeRow, "LEFT", 0, 0)
    belowLabel:SetText("Levels below")

    local belowBox = CreateFrame("EditBox", nil, rangeRow, "InputBoxTemplate")
    belowBox:SetSize(36, 20)
    belowBox:SetPoint("LEFT", belowLabel, "RIGHT", 10, 0)
    belowBox:SetAutoFocus(false)
    belowBox:SetNumeric(true)
    belowBox:SetMaxLetters(2)
    frame.belowBox = belowBox

    local aboveLabel = rangeRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    aboveLabel:SetPoint("LEFT", belowBox, "RIGHT", 16, 0)
    aboveLabel:SetText("Levels above")

    local aboveBox = CreateFrame("EditBox", nil, rangeRow, "InputBoxTemplate")
    aboveBox:SetSize(36, 20)
    aboveBox:SetPoint("LEFT", aboveLabel, "RIGHT", 10, 0)
    aboveBox:SetAutoFocus(false)
    aboveBox:SetNumeric(true)
    aboveBox:SetMaxLetters(2)
    frame.aboveBox = aboveBox

    -- Returns true when the edit box value differs from saved state.
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
            invalidateScan()
            renderList()
        end
    end

    -- Debounce keystrokes so the list rebuilds once per pause.
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

    -- Filters section

    local filtersTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    filtersTitle:SetPoint("TOPLEFT", rangeRow, "BOTTOMLEFT", 0, -SECTION_GAP)
    filtersTitle:SetText("Filters")

    local filterRow = CreateFrame("Frame", nil, frame)
    filterRow:SetPoint("TOPLEFT", filtersTitle, "BOTTOMLEFT", 0, -ELEMENT_GAP)
    filterRow:SetPoint("RIGHT", frame, "RIGHT", -PAD_X, 0)
    filterRow:SetHeight(24)

    local FILTER_LAYOUT = {
        { key = "inLog",      label = "In Log",     x = 0   },
        { key = "available",  label = "Available",  x = 90  },
        { key = "missingPre", label = "Missing Pre", x = 190 },
    }

    frame.filterCheckboxes = {}
    for i, spec in ipairs(FILTER_LAYOUT) do
        local cb = CreateFrame("CheckButton", "WhereToQuestFilter" .. i, filterRow, "UICheckButtonTemplate")
        cb:SetSize(22, 22)
        cb:SetPoint("LEFT", filterRow, "LEFT", spec.x, 0)
        local cbText = _G[cb:GetName() .. "Text"]
        if cbText then
            cbText:SetText(spec.label)
            cbText:SetFontObject("GameFontNormalSmall")
        end
        cb:SetScript("OnClick", function(self)
            WhereToQuestDB.filters = WhereToQuestDB.filters or {}
            WhereToQuestDB.filters[spec.key] = self:GetChecked() and true or false
            renderList()
        end)
        cb.filterKey = spec.key
        frame.filterCheckboxes[#frame.filterCheckboxes + 1] = cb
    end

    frame.refreshFilters = function()
        local fs = (WhereToQuestDB and WhereToQuestDB.filters) or DEFAULTS.filters
        for _, cb in ipairs(frame.filterCheckboxes) do
            cb:SetChecked(fs[cb.filterKey] and true or false)
        end
    end

    -- Sorting section

    local sortingTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sortingTitle:SetPoint("TOPLEFT", filterRow, "BOTTOMLEFT", 0, -SECTION_GAP)
    sortingTitle:SetText("Sorting")

    -- UIDropDownMenuTemplate has ~16px invisible padding; offset to align edges.
    local sortDropdown = CreateFrame("Frame", "WhereToQuestSortDropdown", frame, "UIDropDownMenuTemplate")
    sortDropdown:SetPoint("TOPLEFT", sortingTitle, "BOTTOMLEFT", -16, 0)
    UIDropDownMenu_SetWidth(sortDropdown, 160)

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

    -- Match +16 inset to undo dropdown internal padding.
    local toggleAllButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    toggleAllButton:SetSize(110, 22)
    toggleAllButton:SetPoint("TOPLEFT", sortDropdown, "BOTTOMLEFT", 16, -ELEMENT_GAP)
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

    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", toggleAllButton, "BOTTOMLEFT", 0, -SECTION_GAP)
    scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -(PAD_X + 18), PAD_BOTTOM)

    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(FRAME_WIDTH - (PAD_X * 2) - 18, 1)
    scroll:SetScrollChild(child)
    scrollChild = child
    frame.scroll = scroll

    mainFrame = frame
    return frame
end

local function showFrame()
    local frame = buildMainFrame()
    invalidateScan()
    frame.belowBox:SetText(tostring(WhereToQuestDB.minBelow))
    frame.aboveBox:SetText(tostring(WhereToQuestDB.maxAbove))
    if frame.refreshSortDropdown then
        frame.refreshSortDropdown()
    end
    if frame.refreshFilters then
        frame.refreshFilters()
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
SLASH_WHERETOQUEST2 = "/wheretoquest"
SlashCmdList["WHERETOQUEST"] = function()
    if not loadQuestie() then
        print(INTRO_PREFIX .. "Questie is not loaded. Enable Questie to use this addon.")
        return
    end
    toggleFrame()
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
        if type(WhereToQuestDB.filters) ~= "table" then
            WhereToQuestDB.filters = {}
        end
        for key, defaultOn in pairs(DEFAULTS.filters) do
            if type(WhereToQuestDB.filters[key]) ~= "boolean" then
                WhereToQuestDB.filters[key] = defaultOn
            end
        end
    elseif event == "PLAYER_LOGIN" then
        print(INTRO_PREFIX .. "loaded. Type /wtq to open.")
    end
end)
