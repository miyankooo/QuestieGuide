-- The quest list: its scroll frame and search box, pooled rows, the render pass, and the jumps, links and menus on its rows.
local _, ns = ...

local UI = LibStub("LibNativeUI-1.0")

local COLOR = ns.COLOR
local RANGE_LIMIT = ns.RANGE_LIMIT
local SUBCAT_ORDER = ns.SUBCAT_ORDER
local SUBCAT_LABEL = ns.SUBCAT_LABEL
local LAYOUT = ns.LAYOUT
local clampRange = ns.clampRange
local getQuestTag = ns.getQuestTag
local getQuestName = ns.getQuestName
local resolveStartInfo = ns.resolveStartInfo
local getCurrentZoneName = ns.getCurrentZoneName
local invalidateScan = ns.invalidateScan
local ensureScan = ns.ensureScan
local sortZones = ns.sortZones
local collectCompletedByZone = ns.collectCompletedByZone
local findBestZone = ns.findBestZone
local formatLevelLock = ns.formatLevelLock
local formatRowLines = ns.formatRowLines
local showQuestTooltip = ns.showQuestTooltip
local showChainTooltip = ns.showChainTooltip
local getLevelShare = ns.getLevelShare
local showZoneTooltip = ns.showZoneTooltip
local showTurnInTooltip = ns.showTurnInTooltip
local openMapForQuest = ns.openMapForQuest
local openQuestInLog = ns.openQuestInLog

local QuestiePlayer = QuestieLoader:ImportModule("QuestiePlayer")

-- Blizzard's quest log header grey; headers whiten to the body colour while hovered.
local HEADER_COLOR = QuestDifficultyColors.header

-- Completed-quests section: sentinel collapse key that can't collide with a real zone name ("||" never appears in area names).
local COMPLETED_KEY = "||completed"
local COMPLETED_LABEL = "Completed Quests"

-- Quest list metrics on the 4px grid. Rows snap their centred text to the grid, one 16px line at least; quest rows add 8px of air around their text. The +/- toggle sits flush left with header text right after it, and gaps grow per tier (none between quests, one gap before a bucket, two before a zone) so quests, buckets and zones read apart.
local LIST = {
    ROW_HEIGHT = 16,
    ROW_PADDING = 8,
    GROUP_GAP = UI.Space.gap,
    ZONE_GAP = 16,
    INDENT_STEP = 16,
    TEXT_INSET = UI.Size.icon,
    TOGGLE_SIZE = UI.Size.icon,
}

-- Header expand/collapse art, the same textures Forever's Group Finder listing headers use.
local TOGGLE_ART = {
    PLUS = "Interface\\Buttons\\UI-PlusButton-Up",
    MINUS = "Interface\\Buttons\\UI-MinusButton-Up",
    HILIGHT = "Interface\\Buttons\\UI-PlusButton-Hilight",
}

-- The Quest Types filter that covers each tag id; PvP has none. The elite flag also falls under the Elite filter.
local TAG_FILTERS = {
    [Constants.QuestConsts.QUEST_INFO_ELITE_ID] = "elite",
    [Constants.QuestConsts.QUEST_INFO_DUNGEON_ID] = "dungeons",
    [Constants.QuestConsts.QUEST_INFO_RAID_ID] = "elite",
}

local scrollChild
local rowPool = {}
local lastZoneOrder = {}

-- Turn-in zones rendered by the completed section on the last pass; drives Collapse All parity.
local lastCompletedZones = {}

-- questId -> { row, top } for pickable and in-log rows, rebuilt every render; powers the jump-to-prerequisite scroll.
local rowTargets = {}

-- zoneName -> header top offset, rebuilt every render; powers the banner's jump-to-zone scroll.
local zoneHeaderTops = {}
local renderList
local expandAndScrollToZone
local searchText = ""

-- Quest carrying the selection glow; moved by row left-clicks, list jumps, and Questie map icon clicks.
local selectedQuestId

local function acquireRow(index)
    local row = rowPool[index]
    if row then
        row:Show()

        -- Pool rows persist across renders; reset alpha so a row that was previously used for an out-of-range quest doesn't carry the dimmed look forward when it's reused for a header or in-range quest. renderQuestRow overrides this for actual fading rows.
        row:SetAlpha(1)
        row.highlight:Hide()
        row.selection:Hide()

        -- Reset the header dressing so a row reused for a quest or message doesn't keep the toggle, text inset, or grey header color.
        row.toggle:Hide()
        row.toggleHighlight:SetTexture("")
        row.text:SetPoint("LEFT", row, "LEFT", 0, 0)
        row.text:SetTextColor(UI.Color.body:GetRGB())
        return row
    end
    row = CreateFrame("Button", nil, scrollChild)
    row:SetHeight(LIST.ROW_HEIGHT)
    row:SetPoint("LEFT", scrollChild, "LEFT", 0, 0)
    row:SetPoint("RIGHT", scrollChild, "RIGHT", 0, 0)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    -- Hover: UI-QuestTitleHighlight in ADD blend, the title highlight Forever's gossip and quest greeting rows use. It sits on BACKGROUND so the row text stays on top, and renderQuestRow drives it so headers stay flat.
    row.highlight = row:CreateTexture(nil, "BACKGROUND")
    row.highlight:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    row.highlight:SetBlendMode("ADD")
    row.highlight:SetAllPoints(true)
    row.highlight:Hide()

    -- Selection: the questlog-quest-glow-yellow atlas Forever's quest log keeps on its called-out quest.
    row.selection = row:CreateTexture(nil, "BACKGROUND", nil, -1)
    row.selection:SetAtlas("questlog-quest-glow-yellow")
    row.selection:SetAllPoints(true)
    row.selection:Hide()

    -- Anchored only across the row, so the text is centred vertically and its height follows the wrapped lines; renderList sizes the row from that height (see sizeRow).
    row.text = UI.CreateText(row, "body")
    row.text:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.text:SetWordWrap(true)

    -- Expand/collapse toggle for header rows. The hilight sits on the HIGHLIGHT layer so the button shows it automatically on mouse-over; quest rows keep its texture empty so nothing renders there.
    row.toggle = row:CreateTexture(nil, "ARTWORK")
    row.toggle:SetSize(LIST.TOGGLE_SIZE, LIST.TOGGLE_SIZE)
    row.toggle:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.toggle:Hide()
    row.toggleHighlight = row:CreateTexture(nil, "HIGHLIGHT")
    row.toggleHighlight:SetBlendMode("ADD")
    row.toggleHighlight:SetAllPoints(row.toggle)
    rowPool[index] = row
    return row
end

-- Dresses a pooled row as a quest log header: plus/minus toggle, indented text, and header grey that whitens while hovered.
local function styleHeaderRow(row, collapsed)
    row.toggle:SetTexture(collapsed and TOGGLE_ART.PLUS or TOGGLE_ART.MINUS)
    row.toggle:Show()
    row.toggleHighlight:SetTexture(TOGGLE_ART.HILIGHT)
    row.text:SetPoint("LEFT", row, "LEFT", LIST.TEXT_INSET, 0)
    row.text:SetTextColor(HEADER_COLOR.r, HEADER_COLOR.g, HEADER_COLOR.b)
    row:SetScript("OnEnter", function(self)
        self.text:SetTextColor(UI.Color.body:GetRGB())
    end)
    row:SetScript("OnLeave", function(self)
        self.text:SetTextColor(HEADER_COLOR.r, HEADER_COLOR.g, HEADER_COLOR.b)
    end)
end

local function hideUnusedRows(fromIndex)
    for i = fromIndex, #rowPool do
        rowPool[i]:Hide()
        rowPool[i]:SetScript("OnClick", nil)
        rowPool[i]:SetScript("OnEnter", nil)
        rowPool[i]:SetScript("OnLeave", nil)
    end
end

local function searchMatches(text)
    if searchText == "" then
        return true
    end
    if not text then
        return false
    end
    return string.find(string.lower(text), searchText, 1, true) ~= nil
end

-- Questie's plain-text share format: receivers running Questie turn "[[level] Name (id)]" into a rich questie hyperlink through its chat filter, everyone else still reads a plain string.
local function buildQuestLink(quest)
    local lvl = quest.level or 0
    local name = quest.name or ("Quest " .. quest.id)
    return string.format("[[%d] %s (%d)]", lvl, name, quest.id)
end

-- Puts the link into the open chat box, or opens chat with it. A quest in the log gets the native link every reader can click, as Questie itself prefers.
local function linkQuestInChat(quest)
    local link = QuestiePlayer.currentQuestlog[quest.id] and GetQuestLink(quest.id) or buildQuestLink(quest)
    local editBox = ChatFrameUtil.GetActiveWindow()
    if editBox and editBox:IsVisible() then
        ChatFrameUtil.InsertLink(link)
    else
        ChatFrameUtil.OpenChat(link)
    end
end

-- Context menus use MenuUtil, which shares no UIDropDownMenu globals with Blizzard's secure dropdowns and so can't taint them.
local function showQuestContextMenu(anchor, quest)
    MenuUtil.CreateContextMenu(anchor, function(_, rootDescription)
        rootDescription:CreateTitle(quest.name)
        rootDescription:CreateButton("Show on Map", function() openMapForQuest(quest) end)
        rootDescription:CreateButton("Link in Chat", function() linkQuestInChat(quest) end)
    end)
end

-- "Show Next Step on Map" jumps to the next actionable step (the chain's initial), since the blocked quest itself isn't pickup-able yet. "Link in Chat" links the blocked quest (the row the player is hovering).
local function showChainContextMenu(anchor, mpe)
    local initial = { id = mpe.chain and mpe.chain[1] }
    MenuUtil.CreateContextMenu(anchor, function(_, rootDescription)
        rootDescription:CreateTitle(mpe.name)
        rootDescription:CreateButton("Show Next Step on Map", function() openMapForQuest(initial) end)
        rootDescription:CreateButton("Link in Chat", function() linkQuestInChat(mpe) end)
    end)
end

-- Blink the row's hover highlight a few times so the eye lands on the jump target. Ends hidden; a hover in between re-drives it through OnEnter/OnLeave anyway.
local function flashRow(row)
    local step = 0
    local function blink()
        step = step + 1
        if step % 2 == 1 then
            row.highlight:Show()
        else
            row.highlight:Hide()
        end
        if step < 6 then
            C_Timer.After(0.25, blink)
        end
    end
    blink()
end

-- First zone/bucket in display order holding a pickable or in-log row for the quest, honoring the active filters so the jump only targets a row that actually renders.
local function findListedQuest(questId)
    local byZone = ensureScan()
    local filters = QuestieGuideDB.filters
    for _, zoneName in ipairs(lastZoneOrder) do
        local entry = byZone[zoneName]
        if entry then
            for _, subKey in ipairs(SUBCAT_ORDER) do
                if filters[subKey] then
                    for _, q in ipairs(entry[subKey] or {}) do
                        if q.id == questId and not q.blocked and (not q.inLog or filters.inLog) then
                            return zoneName, subKey
                        end
                    end
                end
            end
        end
    end
end

-- Scrolls the quest list so offset (pixels below the list top) sits at the top of the view. UpdateScrollChildRect refreshes the range right after a re-render resized the list, and SetVerticalScroll moves ScrollFrameTemplate's own scroll bar through its OnVerticalScroll handler.
local function scrollListTo(offset)
    local scroll = ns.mainFrame and ns.mainFrame.scroll
    if not scroll then
        return false
    end
    scroll:UpdateScrollChildRect()
    local range = scroll:GetVerticalScrollRange()
    scroll:SetVerticalScroll(math.min(math.max(offset, 0), range))
    return true
end

-- Expand the target's zone and bucket, re-render, scroll the list to the row and blink it.
local function jumpToQuestInList(questId)
    local zoneName, subKey = findListedQuest(questId)
    if not zoneName then
        return false
    end

    -- The jump target becomes the selected row so the eye keeps it after the blink fades.
    selectedQuestId = questId
    QuestieGuideDB.zoneCollapsed[zoneName] = false
    QuestieGuideDB.groupCollapsed[zoneName .. "||" .. subKey] = false
    renderList()
    local target = rowTargets[questId]
    if not target or not ns.mainFrame or not ns.mainFrame.scroll then
        return false
    end

    -- A third down the viewport keeps some context visible above the target row.
    scrollListTo(target.top - ns.mainFrame.scroll:GetHeight() / 3)
    flashRow(target.row)
    return true
end

-- Left-click on a blocked row lands on the chain step the player can act on now. The chain runs [initial, ..., blocked target]; the earliest step with a pickable or in-log row is the actionable one. Falls back to the map at the chain start when no step is listed.
local function jumpToUnlockingQuest(mpe)
    local chain = mpe.chain
    if type(chain) == "table" then
        for i = 1, #chain - 1 do
            if jumpToQuestInList(chain[i]) then
                return
            end
        end
    end
    openMapForQuest({ id = type(chain) == "table" and chain[1] or mpe.id })
end

-- Action buttons under the empty-state message, one per label because a button fits its label once, when it is created. Every render hides them.
local emptyButtons = {}

local function getEmptyButton(label)
    emptyButtons[label] = emptyButtons[label] or UI.CreateButton(scrollChild, label)
    return emptyButtons[label]
end

local function hideEmptyButtons()
    for _, button in pairs(emptyButtons) do
        button:Hide()
    end
end

-- True after a render that left any zone or the completed section expanded; drives the Collapse All / Expand All button.
local anyZoneExpanded = false

function renderList()
    if not scrollChild then
        return
    end
    hideEmptyButtons()
    local byZone, zoneOrder = ensureScan()
    sortZones(zoneOrder, byZone)
    lastZoneOrder = zoneOrder
    rowTargets = {}
    zoneHeaderTops = {}
    local bestZoneName = findBestZone(byZone, zoneOrder)
    local filters = QuestieGuideDB.filters
    local currentZoneName = getCurrentZoneName()
    local index = 1
    local y = 0
    local renderedZones = 0

    -- Two-anchor (TOPLEFT + TOPRIGHT) placement: x-range comes from the horizontal span, top y from the shared y offset, height from sizeRow. Using three anchors (LEFT/RIGHT/TOP) over-constrains the vertical center and resolves inconsistently between the first paint and subsequent layout passes, which is what produced the post-reload offset.
    local function placeRow(row, indent)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", indent, -y)
        row:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", 0, -y)
    end

    -- Sizes the row to its wrapped text plus padding, snapped to the grid; minHeight keeps short rows one line tall. The text already spans the row's width, so GetStringHeight reflects the wrapped result, rounded first so a fractional pixel can't add a grid step.
    local function sizeRow(row, minHeight, padding)
        local textHeight = math.floor(row.text:GetStringHeight() + 0.5)
        local h = UI.Snap(textHeight + (padding or 0))
        if h < minHeight then h = minHeight end
        row:SetHeight(h)
        return h
    end

    local function renderQuestRow(label, onEnter, onLeftClick, onRightClick, onShiftClick, alpha, quest)
        local rowTop = y
        local row = acquireRow(index)
        placeRow(row, LIST.INDENT_STEP * 2)

        -- Rows are pooled and reused across renders, so always reset alpha explicitly. Out-of-range quests pass 0.5 to dim the row.
        row:SetAlpha(alpha or 1)
        row.text:SetText(label)

        -- The selected row keeps the selection glow until another row is selected. Blocked rows never carry it because their click jumps elsewhere.
        if quest and quest.id == selectedQuestId and not quest.blocked then
            row.selection:Show()
        end
        row:SetScript("OnEnter", function(self)
            row.highlight:Show()
            if onEnter then onEnter(self) end
        end)
        row:SetScript("OnLeave", function()
            row.highlight:Hide()
            GameTooltip_Hide()
        end)
        if onLeftClick or onRightClick or onShiftClick then
            row:SetScript("OnClick", function(self, btn)
                if btn == "LeftButton" and IsModifiedClick("CHATLINK") then
                    if onShiftClick then onShiftClick(self) end
                elseif btn == "RightButton" then
                    if onRightClick then onRightClick(self) end
                else
                    -- Plain left click selects the row like the native quest log before running its action; the re-render moves the selection texture.
                    if quest and not quest.blocked and quest.id ~= selectedQuestId then
                        selectedQuestId = quest.id
                        renderList()
                    end
                    if onLeftClick then onLeftClick(self) end
                end
            end)
        else
            row:SetScript("OnClick", nil)
        end
        y = y + sizeRow(row, LIST.ROW_HEIGHT, LIST.ROW_PADDING)
        index = index + 1
        return row, rowTop
    end

    local zoneCollapsedDB = QuestieGuideDB.zoneCollapsed
    local groupCollapsedDB = QuestieGuideDB.groupCollapsed

    -- A zone the player never toggled starts collapsed, except the current zone and the Next zone, so a first open leads with the answer instead of every row. A search shows its matches expanded.
    local function isZoneCollapsed(zoneName)
        local stored = zoneCollapsedDB[zoneName]
        if stored ~= nil then
            return stored
        end
        return searchText == "" and zoneName ~= currentZoneName and zoneName ~= bestZoneName
    end

    -- A row passes only when every filter covering it is on: repeatable rides a specialFlags bit orthogonal to the tag, and the elite flag sits beside the tag, so an elite dungeon quest needs both Dungeons and Elite.
    local function passesTagFilter(quest)
        if quest.repeatable and not filters.repeatable then
            return false
        end
        local tagId, isElite = getQuestTag(quest.id)
        if isElite and not filters.elite then
            return false
        end
        local filterKey = TAG_FILTERS[tagId]
        return not filterKey or filters[filterKey]
    end

    local function passesQuest(quest, zoneMatch)
        if not passesTagFilter(quest) then
            return false
        end

        -- Out-of-range rows never render, EXCEPT quests already in the log: accepted quests always list here regardless of the bracket, while XP figures keep respecting it. Dimming is reserved for in-range quests that cannot be accepted yet.
        if quest.outOfRange and not quest.inLog then
            return false
        end
        if zoneMatch then
            return true
        end
        if searchMatches(quest.name) then
            return true
        end
        local startInfo = resolveStartInfo(quest)
        if startInfo and searchMatches(startInfo.npcName) then
            return true
        end
        return false
    end

    local function passesChain(mpe, zoneMatch)
        if zoneMatch then
            return true
        end
        if searchMatches(mpe.name) then
            return true
        end

        -- Match any step in the chain so typing the name of a prereq surfaces the quest that unlocks behind it.
        if type(mpe.chain) == "table" then
            for _, qid in ipairs(mpe.chain) do
                if searchMatches(getQuestName(qid)) then
                    return true
                end
            end
        end
        return false
    end

    -- Completed Quests section at the top of the list: turn-in zones sorted by count, quests styled like the zone buckets below. Returns true when it drew anything so the zone loop and empty-state message can account for it.
    local function renderCompletedSection()
        if not QuestieGuideDB.showCompleted then
            lastCompletedZones = {}
            return false
        end
        local completedByZone, completedZoneOrder = collectCompletedByZone()
        lastCompletedZones = completedZoneOrder

        local visibleByZone = {}
        local total = 0
        for _, zoneName in ipairs(completedZoneOrder) do
            local zoneMatch = searchMatches(zoneName)
            local list = {}
            for _, q in ipairs(completedByZone[zoneName]) do
                if zoneMatch or searchMatches(q.name) or (q.startInfo and searchMatches(q.startInfo.npcName)) then
                    list[#list + 1] = q
                end
            end
            if #list > 0 then
                visibleByZone[zoneName] = list
                total = total + #list
            end
        end
        if total == 0 then
            return false
        end

        local collapsed = zoneCollapsedDB[COMPLETED_KEY] == true
        local header = acquireRow(index)
        placeRow(header, 0)
        styleHeaderRow(header, collapsed)
        header.text:SetText(COMPLETED_LABEL .. " (" .. total .. ")")

        -- Section toggle only flips the section itself; turn-in zone state is independent, matching the zone headers.
        header:SetScript("OnClick", function()
            zoneCollapsedDB[COMPLETED_KEY] = not collapsed
            renderList()
        end)
        y = y + sizeRow(header, LIST.ROW_HEIGHT)
        index = index + 1

        if not collapsed then
            for _, zoneName in ipairs(completedZoneOrder) do
                local list = visibleByZone[zoneName]
                if list then
                    local groupKey = COMPLETED_KEY .. "||" .. zoneName
                    local groupHidden = groupCollapsedDB[groupKey] == true

                    y = y + LIST.GROUP_GAP

                    local sub = acquireRow(index)
                    placeRow(sub, LIST.INDENT_STEP)
                    styleHeaderRow(sub, groupHidden)
                    sub.text:SetText(string.format("%s (%d)", zoneName, #list))
                    sub:SetScript("OnClick", function()
                        groupCollapsedDB[groupKey] = not groupHidden
                        renderList()
                    end)
                    y = y + sizeRow(sub, LIST.ROW_HEIGHT)
                    index = index + 1

                    if not groupHidden then
                        for _, quest in ipairs(list) do
                            -- Left-click opens the quest in the native log, matching every other in-log row; the turn-in map view stays reachable through the right-click menu. The section header already says these are completed, so the rows carry no badge.
                            local line1, line2 = formatRowLines(quest)
                            local label = line2 and (line1 .. "\n" .. line2) or line1
                            renderQuestRow(label,
                                function(self) showTurnInTooltip(self, quest) end,
                                function() openQuestInLog(quest.id) end,
                                function(self) showQuestContextMenu(self, quest) end,
                                function() linkQuestInChat(quest) end,
                                nil, quest)
                        end
                    end
                end
            end
        end
        return true
    end

    -- Next-best-action banner: one line answering "where should I go now" without scanning headers. Click expands the zone and scrolls its header into view; hover shows the zone breakdown. Hidden while searching, which narrows the rows the banner would point at.
    local bannerStats = searchText == "" and bestZoneName and byZone[bestZoneName].stats
    if bannerStats then
        local bannerZone = bestZoneName
        local row = acquireRow(index)
        placeRow(row, 0)
        local detail = BreakUpLargeNumbers(bannerStats.xp) .. " XP in one trip"
        local share = getLevelShare(bannerStats.xp)
        if share then
            detail = string.format("%s, covers %d%% of level %d", detail, share, UnitLevel("player"))
        end
        row.text:SetText(COLOR.ACCENT:WrapTextInColorCode("Next: " .. bannerZone) .. "  " .. COLOR.MUTED:WrapTextInColorCode(detail))
        row:SetScript("OnEnter", function(self)
            self.highlight:Show()
            showZoneTooltip(self, bannerZone, bannerStats, true)
        end)
        row:SetScript("OnLeave", function(self)
            self.highlight:Hide()
            GameTooltip_Hide()
        end)
        row:SetScript("OnClick", function()
            expandAndScrollToZone(bannerZone)
        end)

        -- The banner highlights on hover like a quest row, so it gets the same air around its text.
        y = y + sizeRow(row, LIST.ROW_HEIGHT, LIST.ROW_PADDING) + LIST.GROUP_GAP
        index = index + 1
    end

    local completedShown = renderCompletedSection()

    for _, zoneName in ipairs(zoneOrder) do
        local entry = byZone[zoneName]
        if entry then
            local collapsed = isZoneCollapsed(zoneName)
            local zoneMatch = searchMatches(zoneName)

            -- Initialise one empty list per declared subcategory so iterating SUBCAT_ORDER below never lands on a nil bucket if a future key is added.
            local visible = {}
            for _, subKey in ipairs(SUBCAT_ORDER) do
                visible[subKey] = {}
            end

            -- In-log and blocked rows ride inside the pickup buckets, toggled by their filters. Blocked rows match the search through any step of their chain and respect the tag filters like every other row.
            local function passesRow(quest)
                if quest.blocked then
                    return filters.missingPre and passesTagFilter(quest) and passesChain(quest, zoneMatch)
                end
                if quest.inLog and not filters.inLog then
                    return false
                end
                return passesQuest(quest, zoneMatch)
            end
            for _, subKey in ipairs(SUBCAT_ORDER) do
                if filters[subKey] then
                    for _, q in ipairs(entry[subKey] or {}) do
                        if passesRow(q) then
                            visible[subKey][#visible[subKey] + 1] = q
                        end
                    end
                end
            end

            -- visibleTotal gates whether the zone renders at all (so a search match against an out-of-range quest still surfaces its zone), while inRangeTotal / inRangeXp / subInRangeCount drive the count and XP shown in the zone and subcategory headers. Out-of-range quests still render below as dimmed rows.
            local visibleTotal = 0
            local inRangeTotal = 0
            local inRangeXp = 0
            local subInRangeCount = {}
            for _, subKey in ipairs(SUBCAT_ORDER) do
                local subRangeN = 0
                for _, q in ipairs(visible[subKey]) do
                    visibleTotal = visibleTotal + 1

                    -- Log quests count as listed even outside the bracket; their XP only counts in range.
                    if not q.outOfRange or q.inLog then
                        subRangeN = subRangeN + 1
                        inRangeTotal = inRangeTotal + 1

                        -- Blocked-quest XP is carried by the zone-level follow-up figure (only chains that unlock in-zone count), never by row summation.
                        if not q.blocked and not q.outOfRange and q.countsXp then
                            inRangeXp = inRangeXp + (q.xp or 0)
                        end
                    end
                end
                subInRangeCount[subKey] = subRangeN
            end

            -- Zones render only when they hold at least one in-range row; out-of-range rows never reach the visible lists.
            if visibleTotal > 0 then
                if renderedZones > 0 or completedShown then
                    y = y + LIST.ZONE_GAP
                end
                renderedZones = renderedZones + 1
                zoneHeaderTops[zoneName] = y

                local header = acquireRow(index)
                placeRow(header, 0)
                styleHeaderRow(header, collapsed)
                local summary = " (" .. inRangeTotal .. ")"

                -- Search narrows the rows on screen, so the zone-level follow-up projection would no longer match them; the projection only shows on the unfiltered view.
                local followupXp = (searchText == "" and entry.followups and entry.followups.xp) or 0

                -- Single total XP figure: rows in range plus follow-ups unlocking in-zone. Percent-of-level detail lives in the header tooltip.
                local totalXp = inRangeXp + followupXp
                if totalXp > 0 then
                    summary = summary .. " " .. COLOR.MUTED:WrapTextInColorCode(BreakUpLargeNumbers(totalXp) .. " XP")
                end
                local isBestZone = (zoneName == bestZoneName)

                -- Current-zone marker: gold tag on the header of the zone the player is standing in.
                local headerText = zoneName .. summary
                if zoneName == currentZoneName then
                    headerText = headerText .. " " .. COLOR.ACCENT:WrapTextInColorCode("(You are here)")
                end
                header.text:SetText(headerText)
                local zoneStats = entry.stats
                header:SetScript("OnEnter", function(self)
                    self.text:SetTextColor(UI.Color.body:GetRGB())
                    showZoneTooltip(self, zoneName, zoneStats, isBestZone, true)
                end)
                header:SetScript("OnLeave", function(self)
                    self.text:SetTextColor(HEADER_COLOR.r, HEADER_COLOR.g, HEADER_COLOR.b)
                    GameTooltip_Hide()
                end)

                -- Zone toggle only flips the zone itself; subcategory state is independent and survives so Collapse All's collapsed subs stay collapsed. Right-click focuses the zone: everything else collapses, this zone expands.
                header:SetScript("OnClick", function(_, btn)
                    if btn == "RightButton" then
                        for _, other in ipairs(lastZoneOrder) do
                            zoneCollapsedDB[other] = other ~= zoneName
                        end
                        zoneCollapsedDB[COMPLETED_KEY] = true
                    else
                        zoneCollapsedDB[zoneName] = not collapsed
                    end
                    renderList()
                end)
                y = y + sizeRow(header, LIST.ROW_HEIGHT)
                index = index + 1

                if not collapsed then
                    for _, subKey in ipairs(SUBCAT_ORDER) do
                        local list = visible[subKey]
                        if filters[subKey] and #list > 0 then
                            local groupKey = zoneName .. "||" .. subKey
                            local groupHidden = groupCollapsedDB[groupKey] == true

                            y = y + LIST.GROUP_GAP

                            local sub = acquireRow(index)
                            placeRow(sub, LIST.INDENT_STEP)
                            styleHeaderRow(sub, groupHidden)
                            sub.text:SetText(string.format("%s (%d)",
                                SUBCAT_LABEL[subKey], subInRangeCount[subKey] or 0))
                            sub:SetScript("OnClick", function()
                                groupCollapsedDB[groupKey] = not groupHidden
                                renderList()
                            end)
                            y = y + sizeRow(sub, LIST.ROW_HEIGHT)
                            index = index + 1

                            if not groupHidden then
                                for _, quest in ipairs(list) do
                                    if quest.blocked then
                                        -- Row is the blocked quest itself, greyed until its chain is cleared. Left-click jumps the list to the chain step the player can pick up now; chat link points at the blocked quest (the row being hovered).
                                        local badge = COLOR.BLOCKED:WrapTextInColorCode("[Missing Pre-Quest]")
                                        local line1, line2 = formatRowLines(quest, badge)
                                        local label = line2 and (line1 .. "\n" .. line2) or line1
                                        renderQuestRow(label,
                                            function(self) showChainTooltip(self, quest) end,
                                            function() jumpToUnlockingQuest(quest) end,
                                            function(self) showChainContextMenu(self, quest) end,
                                            function() linkQuestInChat(quest) end,
                                            0.5, quest)
                                    else
                                        -- In-log rows open the native quest log; pickable and level-locked rows open the map at their giver, and level-locked rows dim like blocked ones because they can't be accepted yet. All register as jump targets for blocked rows' chains. Pickable is the default state, so it carries no badge.
                                        local badge
                                        if quest.inLog then
                                            badge = COLOR.IN_LOG:WrapTextInColorCode("[In Questlog]")
                                        elseif quest.lockedLevel then
                                            badge = formatLevelLock(quest.lockedLevel)
                                        end
                                        local line1, line2 = formatRowLines(quest, badge)
                                        local label = line2 and (line1 .. "\n" .. line2) or line1
                                        local onLeftClick = quest.inLog
                                            and function() openQuestInLog(quest.id) end
                                            or function() openMapForQuest(quest) end
                                        local row, rowTop = renderQuestRow(label,
                                            function(self) showQuestTooltip(self, quest.id) end,
                                            onLeftClick,
                                            function(self) showQuestContextMenu(self, quest) end,
                                            function() linkQuestInChat(quest) end,
                                            quest.lockedLevel and 0.5 or 1, quest)
                                        if not rowTargets[quest.id] then
                                            rowTargets[quest.id] = { row = row, top = rowTop }
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if renderedZones == 0 and not completedShown then
        local anyBucket = filters.available or filters.pickedUpElsewhere
        local msg
        if not anyBucket then
            msg = "Starts Here and Starts Elsewhere are both off. Turn one on in the Filter menu."
        elseif searchText ~= "" then
            msg = string.format("No quests match \"%s\". Clear the search or change filters.", searchText)
        else
            msg = "No quests in your level range. Level up or widen the range."
        end
        local row = acquireRow(index)
        placeRow(row, 0)
        row.text:SetText(COLOR.MUTED:WrapTextInColorCode(msg))
        row:SetScript("OnEnter", nil)
        row:SetScript("OnLeave", nil)
        row:SetScript("OnClick", nil)
        y = y + sizeRow(row, LIST.ROW_HEIGHT * 2)
        index = index + 1

        -- One-click fix for the likely cause, mirroring the message above. No button when Questie's ranges govern or the band is maxed; the message's advice (level up) has no shortcut. Changes made here bypass the Filter menu, so its reset button is rechecked.
        local below, above = QuestieGuideDB.levelBelow, QuestieGuideDB.levelAbove
        local actionText, action
        if not anyBucket then
            actionText = "Show Both"
            action = function()
                filters.available = true
                filters.pickedUpElsewhere = true
                ns.mainFrame.filterDropdown:ValidateResetState()
                renderList()
            end
        elseif searchText ~= "" then
            actionText = "Clear Search"
            action = function()
                ns.mainFrame.searchBox:SetText("")
            end
        elseif not QuestieGuideDB.useQuestieLevelRange
            and (below < RANGE_LIMIT.MAX or above < RANGE_LIMIT.MAX) then
            actionText = "Widen Level Range"
            action = function()
                QuestieGuideDB.levelBelow = clampRange(below + 2)
                QuestieGuideDB.levelAbove = clampRange(above + 2)
                ns.mainFrame.filterDropdown:ValidateResetState()
                invalidateScan()
                renderList()
            end
        end
        if actionText then
            local button = getEmptyButton(actionText)
            button:ClearAllPoints()
            button:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -(y + LIST.GROUP_GAP))
            button:SetScript("OnClick", action)
            button:Show()
            y = y + LIST.GROUP_GAP + UI.Size.row
        end
    end

    scrollChild:SetHeight(math.max(y, 1))
    hideUnusedRows(index)

    local anyExpanded = completedShown and not zoneCollapsedDB[COMPLETED_KEY]
    for _, zoneName in ipairs(zoneOrder) do
        anyExpanded = anyExpanded or not isZoneCollapsed(zoneName)
    end
    anyZoneExpanded = anyExpanded
    if ns.mainFrame and ns.mainFrame.toggleAllButton then
        ns.mainFrame.toggleAllButton:SetText(anyExpanded and "Collapse All" or "Expand All")
    end
end

-- Expands the zone and scrolls its header into view; shared by the banner, the Current Zone button, and the chat zone links. Returns false when the zone has no header on screen.
function expandAndScrollToZone(zoneName)
    QuestieGuideDB.zoneCollapsed[zoneName] = false
    renderList()
    local top = zoneHeaderTops[zoneName]
    if not top then
        return false
    end
    return scrollListTo(top)
end

-- One muted line while the first render waits a tick, so an open never shows the last session's rows.
local function renderLoadingPlaceholder()
    hideEmptyButtons()
    hideUnusedRows(1)
    local row = acquireRow(1)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -LIST.ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", 0, -LIST.ROW_HEIGHT)
    row:SetHeight(LIST.ROW_HEIGHT)
    row.text:SetText(COLOR.MUTED:WrapTextInColorCode("Scanning quest database\226\128\166"))
    scrollChild:SetHeight(LIST.ROW_HEIGHT * 3)
end

-- The quest list fills the template's own Inset. ScrollFrameTemplate is what Forever's quest log (QuestScrollFrame) uses; it creates MinimalScrollBar and wires wheel, range and thumb itself.
local function buildQuestList(frame)
    -- The list sits one padding inside the inset, leaving the gutter the bar hangs into on the right.
    local scroll = UI.CreateScroll(frame.Inset)
    scroll.ScrollBar:SetHideIfUnscrollable(true)
    scroll:SetPoint("TOPLEFT", frame.Inset, "TOPLEFT", UI.Space.padding, -UI.Space.padding)
    scroll:SetPoint("BOTTOMRIGHT", frame.Inset, "BOTTOMRIGHT", -UI.ScrollGutter(), UI.Space.padding)

    -- The scroll child's width follows the viewport so rows wrap inside it. The first render waits for onWindowShow's tick, so the loading line paints before the scan.
    local child = scroll.content
    child:SetWidth(math.max(1, scroll:GetWidth()))
    scroll:HookScript("OnSizeChanged", function(self)
        child:SetWidth(math.max(1, self:GetWidth()))
    end)
    scrollChild = child
    frame.scroll = scroll
end

-- Attic search box on AddonList's right edge, centred between the title bar and the inset; SearchBoxTemplate brings the magnifier, clear button and placeholder.
local function buildSearchBox(frame)
    local searchBox = UI.CreateSearchBox(frame, LAYOUT.SEARCH_W, "QuestieGuideSearchBox")
    searchBox:SetPoint("RIGHT", frame, "TOPRIGHT", -LAYOUT.SEARCH_RIGHT, (PANEL_INSET_TOP_OFFSET + PANEL_INSET_ATTIC_OFFSET) / 2)
    searchBox.Instructions:SetText("Quest, zone or NPC name")
    searchBox:HookScript("OnTextChanged", function(self)
        local newText = string.lower(self:GetText() or "")
        if newText == searchText then return end
        searchText = newText
        renderList()
    end)
    frame.searchBox = searchBox
end

-- Collapses everything when anything is expanded, otherwise expands everything. Bucket state follows the zones, so the button acts as one "show me everything / nothing" control.
local function toggleAllZones()
    local zc = QuestieGuideDB.zoneCollapsed
    local gc = QuestieGuideDB.groupCollapsed
    local collapse = anyZoneExpanded
    for _, zoneName in ipairs(lastZoneOrder) do
        zc[zoneName] = collapse
        for _, subKey in ipairs(SUBCAT_ORDER) do
            gc[zoneName .. "||" .. subKey] = collapse
        end
    end
    if QuestieGuideDB.showCompleted and #lastCompletedZones > 0 then
        zc[COMPLETED_KEY] = collapse
        for _, zoneName in ipairs(lastCompletedZones) do
            gc[COMPLETED_KEY .. "||" .. zoneName] = collapse
        end
    end
    renderList()
end

ns.renderList = renderList
ns.expandAndScrollToZone = expandAndScrollToZone
ns.jumpToQuestInList = jumpToQuestInList
ns.renderLoadingPlaceholder = renderLoadingPlaceholder
ns.buildQuestList = buildQuestList
ns.buildSearchBox = buildSearchBox
ns.toggleAllZones = toggleAllZones
