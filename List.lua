-- The quest list: its scroll frame and search box, pooled rows, the render pass, and the jumps, links and menus on its rows.
local _, ns = ...

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
local formatRowLines = ns.formatRowLines
local showQuestTooltip = ns.showQuestTooltip
local showChainTooltip = ns.showChainTooltip
local getLevelShare = ns.getLevelShare
local showZoneTooltip = ns.showZoneTooltip
local showTurnInTooltip = ns.showTurnInTooltip
local setMapPin = ns.setMapPin
local openMapForQuest = ns.openMapForQuest
local focusQuest = ns.focusQuest
local Snap = ns.Snap
local HookTooltip = ns.HookTooltip
local getQuestLog = ns.getQuestLog

-- Ready for Turn-In section: sentinel collapse key that can't collide with a real zone name ("||" never appears in area names).
local COMPLETED_KEY = "||completed"
local COMPLETED_LABEL = "Ready for Turn-In"

-- What a plain click on each kind of row does, as the instruction line under its tooltip.
local CLICK_HINT = {
    pickup = "Click to set a map pin at the giver. Right-click for more.",
    inLog = "Click to focus this quest. Right-click for more.",
    turnIn = "Click to focus this quest, so the arrow leads to its turn-in. Right-click for more.",
    blocked = "Click to jump to the step you can do now. Right-click for more.",
}
local SET_MAP_PIN = "Set Map Pin"

-- Quest rows on the 4px grid: their centred text snapped to it, one 16px line at least, with 8px of air around it. The banner keeps one gap under it.
local LIST = {
    ROW_HEIGHT = 16,
    ROW_PADDING = 8,
    GROUP_GAP = 8,
}

-- The tree around the quests, laid out like the character window's Statistics list (Blizzard_Statistics/Camelot): a
-- zone heads on StatisticsHeaderTemplate's 26 px collapse bar and a category inside it on StatisticsSubHeaderTemplate's
-- 22 px line, each header GAP under the line before and a category's quests ending GAP above the next line, as its
-- view spaces them, and each level stands NEST further in, its tree view's indent (StatisticsFrame.lua). The
-- Statistics list's own metrics, so they are kept off the grid.
local TREE = { HEADER = 26, SUB_HEADER = 22, GAP = 3, NEST = 20 }

-- The list sits one padding inside the inset and leaves the scroll gutter free on its right: SCROLL_FRAME_SCROLL_BAR_OFFSET_LEFT 6, the 8 px MinimalScrollBar and a gap, rounded up to the grid.
local PADDING = 16
local SCROLL_GUTTER = 24

-- What each bucket header holds, for its tooltip.
local SUBCAT_HELP = {
    available = "Quests whose giver stands in this zone.",
    pickedUpElsewhere = "Quests set in this zone whose giver stands in another zone.",
}

-- Text in a font role: GameFontNormal (heading, gold), GameFontHighlight (body, white), GameFontDisable (muted,
-- grey), GameFontNormalLarge (title, 16 px, a dialog's subject line only).
local function CreateText(parent, fontObject, layer)
    local text = parent:CreateFontString(nil, layer or "ARTWORK")
    text:SetFontObject(fontObject or GameFontHighlight)
    text:SetJustifyH("LEFT")
    return text
end

-- A content button one row (24) tall. Without a width it fits its label the way UIPanelButtonTemplate's FitToText
-- does (text plus 40, SecureUIPanelTemplates.xml:42), at least 64, rounded up to 8 so neighbours share widths.
local function CreateButton(parent, label, width)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetText(label)
    width = width or math.max(64, math.ceil((button:GetTextWidth() + 40) / 8) * 8)
    button:SetSize(width, 24)
    return button
end

-- SearchBoxTemplate types and hints in 10 px fonts; both move to the 12 px roles, the hint keeping its grey.
local function CreateSearchBox(parent, width, name)
    local box = CreateFrame("EditBox", name, parent, "SearchBoxTemplate")
    box:SetSize(width or 160, 20)
    box:SetAutoFocus(false)
    box:SetFontObject(GameFontHighlight)
    local r, g, b = box.Instructions:GetTextColor()
    box.Instructions:SetFontObject(GameFontDisable)
    box.Instructions:SetTextColor(r, g, b)
    return box
end

-- A ScrollFrameTemplate with its scroll child. Leave the 24 px gutter free on its right for the bar.
local function CreateScroll(parent, name)
    local scroll = CreateFrame("ScrollFrame", name, parent, "ScrollFrameTemplate")
    scroll.content = CreateFrame("Frame", nil, scroll)
    scroll.content:SetSize(1, 1)
    scroll:SetScrollChild(scroll.content)
    return scroll
end

-- A quest row, from the quest log: the title highlight Forever's gossip and quest greeting rows use (ADD blend) on
-- hover and the quest log's yellow glow on the selected row.
local function CreateQuestRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row.highlight = row:CreateTexture(nil, "BACKGROUND")
    row.highlight:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    row.highlight:SetBlendMode("ADD")
    row.highlight:SetAllPoints()
    row.highlight:Hide()
    row.selection = row:CreateTexture(nil, "BACKGROUND", nil, -1)
    row.selection:SetAtlas("questlog-quest-glow-yellow")
    row.selection:SetAllPoints()
    row.selection:Hide()
    row.text = CreateText(row, GameFontHighlight)
    return row
end

-- A zone's header, StatisticsHeaderTemplate's: the dark collapse bar (common-button-list-collapseExpand) across the
-- row, the same art in ADD blend at 0.3 on hover, the plus or minus (common-button-list-plus, -minus) at its own size
-- 8 in from the right and 1 down, the name in gold 10 in from the left and a muted count before the plus.
-- SetCollapsed sets the plus or minus. Built from the atlases, since the template's mixin collapses the player's
-- statistics.
local function CreateGroupHeader(parent)
    local header = CreateFrame("Button", nil, parent)
    header:SetHeight(TREE.HEADER)
    local bar = header:CreateTexture(nil, "BACKGROUND")
    bar:SetAtlas("common-button-list-collapseExpand")
    bar:SetAllPoints()
    local glow = header:CreateTexture(nil, "HIGHLIGHT")
    glow:SetAtlas("common-button-list-collapseExpand")
    glow:SetBlendMode("ADD")
    glow:SetAlpha(0.3)
    glow:SetAllPoints()
    header.state = header:CreateTexture(nil, "BORDER")
    header.state:SetPoint("RIGHT", -8, -1)
    header.count = CreateText(header, GameFontDisable, "OVERLAY")
    header.count:SetPoint("RIGHT", header.state, "LEFT", -8, 1)
    header.name = CreateText(header, GameFontNormal, "OVERLAY")
    header.name:SetPoint("LEFT", 10, 0)
    header.name:SetPoint("RIGHT", header.count, "LEFT", -4, 0)
    header.name:SetWordWrap(false)
    function header:SetCollapsed(collapsed)
        self.state:SetAtlas(collapsed and "common-button-list-plus" or "common-button-list-minus", true)
    end
    return header
end

-- A category inside a zone, StatisticsSubHeaderTemplate's: 22 tall, the closed or open campaign icon
-- (campaign_headericon_closed, -open) at its own size in the template's 20 px toggle 2 in from the left, lit by the
-- plus button's hilight on hover, the name in body 4 after the toggle and 24 short of the right edge, and the entry's
-- rounded line from character creation's dropdowns (charactercreate-customize-dropdown-linemouseover) behind it, white
-- at 0.10 alpha on hover (StatisticsEntryMixin:RefreshBackgroundHighlightOpacity). A click anywhere on it toggles, as
-- the template's own click does. SetCollapsed sets the icon, SetHovered the line.
local function CreateSubHeader(parent)
    local header = CreateFrame("Button", nil, parent)
    header:SetHeight(TREE.SUB_HEADER)
    local left = header:CreateTexture(nil, "BACKGROUND")
    left:SetAtlas("charactercreate-customize-dropdown-linemouseover-side")
    left:SetWidth(6)
    left:SetPoint("TOPLEFT")
    left:SetPoint("BOTTOMLEFT")
    local right = header:CreateTexture(nil, "BACKGROUND")
    right:SetAtlas("charactercreate-customize-dropdown-linemouseover-side")
    right:SetTexCoord(1, 0, 0, 1)
    right:SetWidth(6)
    right:SetPoint("TOPRIGHT")
    right:SetPoint("BOTTOMRIGHT")
    local middle = header:CreateTexture(nil, "BACKGROUND")
    middle:SetAtlas("charactercreate-customize-dropdown-linemouseover-middle")
    middle:SetPoint("TOPLEFT", left, "TOPRIGHT")
    middle:SetPoint("BOTTOMRIGHT", right, "BOTTOMLEFT")
    local line = { left, right, middle }
    header.state = header:CreateTexture(nil, "ARTWORK")
    header.state:SetPoint("CENTER", header, "LEFT", 12, 0)
    local hilight = header:CreateTexture(nil, "HIGHLIGHT")
    hilight:SetTexture("Interface\\Buttons\\UI-PlusButton-Hilight")
    hilight:SetBlendMode("ADD")
    hilight:SetSize(20, 20)
    hilight:SetPoint("LEFT", 2, 0)
    header.name = CreateText(header, GameFontHighlight, "OVERLAY")
    header.name:SetPoint("LEFT", 26, 0)
    header.name:SetPoint("RIGHT", -24, 0)
    header.name:SetWordWrap(false)
    function header:SetCollapsed(collapsed)
        self.state:SetAtlas(collapsed and "campaign_headericon_closed" or "campaign_headericon_open", true)
    end
    function header:SetHovered(hovered)
        for _, part in ipairs(line) do part:SetAlpha(hovered and 0.10 or 0) end
    end
    header:SetHovered(false)
    return header
end

-- An empty list says what fills it and how, in one muted line centred in the list.
local function CreateEmptyState(parent, text)
    local empty = CreateText(parent, GameFontDisable)
    empty:SetPoint("LEFT", 16, 0)
    empty:SetPoint("RIGHT", -16, 0)
    empty:SetJustifyH("CENTER")
    empty:SetText(text)
    return empty
end

-- The Quest Types filter that covers each tag id; PvP has none. The elite flag also falls under the Elite filter.
local TAG_FILTERS = {
    [Constants.QuestConsts.QUEST_INFO_ELITE_ID] = "elite",
    [Constants.QuestConsts.QUEST_INFO_DUNGEON_ID] = "dungeons",
    [Constants.QuestConsts.QUEST_INFO_RAID_ID] = "elite",
}

local scrollChild
local emptyState
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

-- Quest carrying the selection glow; moved by row left-clicks and list jumps.
local selectedQuestId

local function acquireRow(index)
    local row = rowPool[index]
    if row then
        row:Show()

        -- Pool rows persist across renders; reset alpha so a row that was previously used for an out-of-range quest doesn't carry the dimmed look forward when it's reused for the banner or an in-range quest. renderQuestRow overrides this for actual fading rows.
        row:SetAlpha(1)
        row.highlight:Hide()
        row.selection:Hide()
        return row
    end

    -- The quest log row. Its hover highlight sits on BACKGROUND so the text stays on top, and renderQuestRow and the banner drive it. placeRow anchors every row before it shows.
    row = CreateQuestRow(scrollChild)
    row:SetHeight(LIST.ROW_HEIGHT)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    -- Anchored only across the row, so the text is centred vertically and its height follows the wrapped lines; renderList sizes the row from that height (see sizeRow).
    row.text:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.text:SetWordWrap(true)
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

-- Like Blizzard's own Shift-click, a link goes into the chat box the player has open. Opening chat from addon code
-- (ChatFrameUtil.OpenChat) writes the chat box's own fields and taints Blizzard's chat, so with no box open the
-- click says to open one. A quest in the log gets the native link every reader can click, as Questie itself prefers.
local LINK_NEEDS_CHAT = "Open the chat box first to link a quest."

local function linkQuestInChat(quest)
    local link = getQuestLog()[quest.id] and GetQuestLink(quest.id) or buildQuestLink(quest)
    if not ChatFrameUtil.InsertLink(link) then
        UIErrorsFrame:AddExternalErrorMessage(LINK_NEEDS_CHAT)
    end
end

-- Link in Chat for a row's menu, greyed with the reason while no chat box is open, as the dungeon finder greys a
-- choice (LFDFrame.lua).
local function addLinkButton(rootDescription, quest)
    local button = rootDescription:CreateButton("Link in Chat", function() linkQuestInChat(quest) end)
    if not ChatFrameUtil.GetActiveWindow() then
        button:SetEnabled(false)
        button:SetTooltip(function(tooltip)
            GameTooltip_SetTitle(tooltip, "Link in Chat")
            GameTooltip_AddErrorLine(tooltip, LINK_NEEDS_CHAT)
        end)
    end
end

-- Context menus use MenuUtil, which shares no UIDropDownMenu globals with Blizzard's secure dropdowns and so can't taint them.
-- A quest in the log leads with the objective tracker's own Focus (SUPER_TRACK_QUEST). Set Map Pin pins the giver, or the turn-in target of a quest ready to turn in, so a quest still in progress has none.
local function showQuestContextMenu(anchor, quest)
    MenuUtil.CreateContextMenu(anchor, function(_, rootDescription)
        rootDescription:CreateTitle(quest.name)
        if getQuestLog()[quest.id] then
            rootDescription:CreateButton(SUPER_TRACK_QUEST, function() focusQuest(quest.id) end)
        end
        if not quest.inLog then
            rootDescription:CreateButton(SET_MAP_PIN, function() setMapPin(quest) end)
        end
        rootDescription:CreateButton("Show on Map", function() openMapForQuest(quest) end)
        addLinkButton(rootDescription, quest)
    end)
end

-- The chain's first step, the quest to pick up first, as the map actions take it.
local function chainStart(mpe)
    local questId = type(mpe.chain) == "table" and mpe.chain[1] or mpe.id
    return { id = questId, name = getQuestName(questId) }
end

-- The map actions point at the chain's first step, since the blocked quest itself can't be picked up yet. "Link in Chat" links the blocked quest (the row the player is hovering).
local function showChainContextMenu(anchor, mpe)
    local initial = chainStart(mpe)
    MenuUtil.CreateContextMenu(anchor, function(_, rootDescription)
        rootDescription:CreateTitle(mpe.name)
        rootDescription:CreateButton("Set Map Pin at Next Step", function() setMapPin(initial) end)
        rootDescription:CreateButton("Show Next Step on Map", function() openMapForQuest(initial) end)
        addLinkButton(rootDescription, mpe)
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

-- Left-click on a blocked row lands on the chain step the player can act on now. The chain runs [initial, ..., blocked target]; the earliest step with a pickable or in-log row is the actionable one. Falls back to a map pin at the chain start when no step is listed.
local function jumpToUnlockingQuest(mpe)
    local chain = mpe.chain
    if type(chain) == "table" then
        for i = 1, #chain - 1 do
            if jumpToQuestInList(chain[i]) then
                return
            end
        end
    end
    setMapPin(chainStart(mpe))
end

-- Action buttons under the empty-state line, one per label because a button fits its label once, when it is created. Every render hides them with the line.
local emptyButtons = {}

local function getEmptyButton(label, help)
    local button = emptyButtons[label]
    if not button then
        button = CreateButton(emptyState:GetParent(), label)
        HookTooltip(button, function(tooltip)
            GameTooltip_SetTitle(tooltip, label)
            GameTooltip_AddNormalLine(tooltip, help)
        end)
        emptyButtons[label] = button
    end
    return button
end

local function hideEmptyState()
    emptyState:Hide()
    for _, button in pairs(emptyButtons) do
        button:Hide()
    end
end

-- True after a render that left any zone or the completed section expanded; drives the Collapse All / Expand All button.
local anyZoneExpanded = false

-- The render pass's cursor: the next row's pool index and top offset below the list top. renderList resets both, and the row builders below advance them. They live at file level so the builders sit outside renderList, which keeps it under Lua 5.1's 60 upvalues.
local index, y = 1, 0

-- Two-anchor (TOPLEFT + TOPRIGHT) placement: x-range comes from the horizontal span, top y from the shared y offset, height from sizeRow. Using three anchors (LEFT/RIGHT/TOP) over-constrains the vertical center and resolves inconsistently between the first paint and subsequent layout passes, which is what produced the post-reload offset.
local function placeRow(row, indent)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", indent, -y)
    row:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", 0, -y)
end

-- Sizes the row to its wrapped text plus padding, snapped to the grid; minHeight keeps short rows one line tall. The text already spans the row's width, so GetStringHeight reflects the wrapped result, rounded first so a fractional pixel can't add a grid step.
local function sizeRow(row, minHeight, padding)
    local textHeight = math.floor(row.text:GetStringHeight() + 0.5)
    local h = Snap(textHeight + (padding or 0))
    if h < minHeight then h = minHeight end
    row:SetHeight(h)
    return h
end

-- Zone and category headers, pooled apart from the quest rows; each render numbers them from one again.
local headerPool, subHeaderPool = {}, {}
local headerCount, subHeaderCount = 0, 0

local function hideUnusedHeaders(pool, fromIndex)
    for i = fromIndex, #pool do
        pool[i]:Hide()
    end
end

-- A header's tooltip: the zone breakdown on a zone, otherwise its title and what it holds.
local function onHeaderEnter(self)
    if self.stats then
        showZoneTooltip(self, self.key, self.stats, self.isBest, true)
        return
    end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip_SetTitle(GameTooltip, self.title)
    GameTooltip_AddNormalLine(GameTooltip, self.help)
    GameTooltip:Show()
end

-- A click flips the header's own saved state, a category's independent of its zone's, so Collapse All's collapsed categories stay collapsed. A right-click on a zone focuses it: every other zone and the completed section collapse, this one expands.
local function onHeaderClick(self, button)
    if button == "RightButton" and self.stats then
        local zoneCollapsedDB = QuestieGuideDB.zoneCollapsed
        for _, other in ipairs(lastZoneOrder) do
            zoneCollapsedDB[other] = other ~= self.key
        end
        zoneCollapsedDB[COMPLETED_KEY] = true
    else
        self.store[self.key] = not self.collapsed
    end
    renderList()
end

local function onSubHeaderEnter(self)
    self:SetHovered(true)
    onHeaderEnter(self)
end

local function onSubHeaderLeave(self)
    self:SetHovered(false)
    GameTooltip_Hide()
end

-- A header's muted count: its quests, and their XP when they give any.
local function formatHeaderCount(count, xp)
    local text = string.format("%d |4quest:quests;", count)
    if xp and xp > 0 then
        text = text .. ", " .. BreakUpLargeNumbers(xp) .. " XP"
    end
    return text
end

-- Places a header across the list, indent in from the left, GAP above the next line.
local function placeHeader(header, height, indent)
    header:ClearAllPoints()
    header:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", indent, -y)
    header:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", 0, -y)
    header:Show()
    y = y + height + TREE.GAP
end

-- A header on the collapse bar, saved under store[key]: a zone, whose caller adds stats and isBest for its tooltip and right-click, or the completed section, whose caller adds a title and a help line.
local function renderHeader(key, store, collapsed, name, count)
    headerCount = headerCount + 1
    local header = headerPool[headerCount]
    if not header then
        header = CreateGroupHeader(scrollChild)
        header:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        header:SetScript("OnEnter", onHeaderEnter)
        header:SetScript("OnLeave", GameTooltip_Hide)
        header:SetScript("OnClick", onHeaderClick)
        headerPool[headerCount] = header
    end
    header.key, header.store, header.collapsed = key, store, collapsed
    header.stats, header.isBest, header.title, header.help = nil, nil, nil, nil
    header.name:SetText(name)
    header.count:SetText(count)
    header:SetCollapsed(collapsed)
    placeHeader(header, TREE.HEADER, 0)
    return header
end

-- A category's header inside a zone or the completed section, saved under store[key], its count muted after the name.
local function renderSubHeader(key, store, collapsed, label, count, help)
    subHeaderCount = subHeaderCount + 1
    local header = subHeaderPool[subHeaderCount]
    if not header then
        header = CreateSubHeader(scrollChild)
        header:SetScript("OnEnter", onSubHeaderEnter)
        header:SetScript("OnLeave", onSubHeaderLeave)
        header:SetScript("OnClick", onHeaderClick)
        subHeaderPool[subHeaderCount] = header
    end
    header.key, header.store, header.collapsed = key, store, collapsed
    header.title, header.help = label, help
    header.name:SetText(label .. " " .. COLOR.MUTED:WrapTextInColorCode("(" .. count .. ")"))
    header:SetCollapsed(collapsed)
    header:SetHovered(header:IsMouseOver())
    placeHeader(header, TREE.SUB_HEADER, TREE.NEST)
end

local function renderQuestRow(label, onEnter, onLeftClick, onRightClick, onShiftClick, alpha, quest)
    local rowTop = y
    local row = acquireRow(index)
    placeRow(row, TREE.NEST * 2)

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

-- One row in a zone bucket. A blocked row is the blocked quest itself, greyed until its chain is cleared: left-click jumps the list to the chain step the player can pick up now, and the chat link points at the blocked quest. In-log rows focus the quest, as the tracker's Focus Quest does, so the in-world arrow leads to it. Pickable and level-locked rows set Blizzard's map pin at their giver, and level-locked rows dim like blocked ones because they can't be accepted yet. Pickable is the default state, so it carries no badge. Every row but a blocked one registers as a jump target for blocked rows' chains.
local function renderBucketRow(quest)
    if quest.blocked then
        local badge = COLOR.BLOCKED:WrapTextInColorCode("[Missing Pre-Quest]")
        local line1, line2 = formatRowLines(quest, badge)
        local label = line2 and (line1 .. "\n" .. line2) or line1
        renderQuestRow(label,
            function(self) showChainTooltip(self, quest, CLICK_HINT.blocked) end,
            function() jumpToUnlockingQuest(quest) end,
            function(self) showChainContextMenu(self, quest) end,
            function() linkQuestInChat(quest) end,
            0.5, quest)
        return
    end
    local badge = quest.inLog and COLOR.IN_LOG:WrapTextInColorCode("[In Questlog]") or nil
    local line1, line2 = formatRowLines(quest, badge)
    local label = line2 and (line1 .. "\n" .. line2) or line1
    local onLeftClick = quest.inLog
        and function() focusQuest(quest.id) end
        or function() setMapPin(quest) end
    local row, rowTop = renderQuestRow(label,
        function(self) showQuestTooltip(self, quest.id, quest.inLog and CLICK_HINT.inLog or CLICK_HINT.pickup) end,
        onLeftClick,
        function(self) showQuestContextMenu(self, quest) end,
        function() linkQuestInChat(quest) end,
        1, quest)
    if not rowTargets[quest.id] then
        rowTargets[quest.id] = { row = row, top = rowTop }
    end
end

-- A row passes only when every filter covering it is on: repeatable rides a specialFlags bit orthogonal to the tag, and the elite flag sits beside the tag, so an elite dungeon quest needs both Dungeons and Elite.
local function passesTagFilter(quest, filters)
    if quest.repeatable and not filters.repeatable then
        return false
    end

    -- With Elite and Dungeons both on no tag can hide the row, so the default view skips a tag lookup per quest in every zone, collapsed ones included.
    if filters.elite and filters.dungeons then
        return true
    end
    local tagId, isElite = getQuestTag(quest.id)
    if isElite and not filters.elite then
        return false
    end
    local filterKey = TAG_FILTERS[tagId]
    return not filterKey or filters[filterKey]
end

-- In-log and blocked rows ride inside the pickup buckets, toggled by their filters. Every row respects the tag filters. Out-of-range rows never render, EXCEPT quests already in the log: accepted quests always list here regardless of the bracket, while XP figures keep respecting it. A search matches the zone, the quest name or its giver, and a blocked row also matches through any step of its chain, so typing the name of a prereq surfaces the quest that unlocks behind it.
local function passesRow(quest, filters, zoneMatch)
    if not passesTagFilter(quest, filters) then
        return false
    end
    if quest.blocked then
        if not filters.missingPre then
            return false
        end
        if zoneMatch or searchMatches(quest.name) then
            return true
        end
        for _, qid in ipairs(quest.chain) do
            if searchMatches(getQuestName(qid)) then
                return true
            end
        end
        return false
    end
    if (quest.inLog and not filters.inLog) or (quest.outOfRange and not quest.inLog) then
        return false
    end
    if zoneMatch or searchMatches(quest.name) then
        return true
    end
    local startInfo = resolveStartInfo(quest)
    return startInfo ~= nil and searchMatches(startInfo.npcName)
end

-- Next-best-action banner: one line answering "where should I go now" without scanning headers. Click expands the zone and scrolls its header into view; hover shows the zone breakdown. Hidden while searching, which narrows the rows the banner would point at.
local function renderBanner(byZone, bestZoneName)
    local bannerStats = searchText == "" and bestZoneName and byZone[bestZoneName].stats
    if not bannerStats then
        return
    end
    local row = acquireRow(index)
    placeRow(row, 0)
    local detail = BreakUpLargeNumbers(bannerStats.xp) .. " XP in one trip"
    local share = getLevelShare(bannerStats.xp)
    if share then
        detail = string.format("%s, covers %d%% of level %d", detail, share, UnitLevel("player"))
    end
    row.text:SetText(COLOR.ACCENT:WrapTextInColorCode("Next: " .. bestZoneName) .. "  " .. COLOR.MUTED:WrapTextInColorCode(detail))
    row:SetScript("OnEnter", function(self)
        self.highlight:Show()
        showZoneTooltip(self, bestZoneName, bannerStats, true)
    end)
    row:SetScript("OnLeave", function(self)
        self.highlight:Hide()
        GameTooltip_Hide()
    end)
    row:SetScript("OnClick", function()
        expandAndScrollToZone(bestZoneName)
    end)

    -- The banner highlights on hover like a quest row, so it gets the same air around its text.
    y = y + sizeRow(row, LIST.ROW_HEIGHT, LIST.ROW_PADDING) + LIST.GROUP_GAP
    index = index + 1
end

-- Ready for Turn-In section at the top of the list: turn-in zones sorted by count, quests styled like the zone buckets below. Returns true when it drew anything so the zone loop and empty-state message can account for it.
local function renderCompletedSection()
    if not QuestieGuideDB.showCompleted then
        lastCompletedZones = {}
        return false
    end
    local zoneCollapsedDB = QuestieGuideDB.zoneCollapsed
    local groupCollapsedDB = QuestieGuideDB.groupCollapsed
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

    -- The section heads on the collapse bar like a zone, its turn-in zones as its categories; each keeps its own state.
    local collapsed = zoneCollapsedDB[COMPLETED_KEY] == true
    local header = renderHeader(COMPLETED_KEY, zoneCollapsedDB, collapsed, COMPLETED_LABEL, formatHeaderCount(total))
    header.title, header.help = COMPLETED_LABEL, "Quests ready to turn in, grouped by the zone of their turn-in NPC."

    if not collapsed then
        for _, zoneName in ipairs(completedZoneOrder) do
            local list = visibleByZone[zoneName]
            if list then
                local groupKey = COMPLETED_KEY .. "||" .. zoneName
                local groupHidden = groupCollapsedDB[groupKey] == true
                renderSubHeader(groupKey, groupCollapsedDB, groupHidden, zoneName, #list, "Quests to turn in here.")

                if not groupHidden then
                    for _, quest in ipairs(list) do
                        -- Left-click focuses the quest, so the in-world arrow leads to its turn-in, matching every other in-log row; the turn-in map view stays reachable through the right-click menu. The section header already says these are completed, so the rows carry no badge.
                        local line1, line2 = formatRowLines(quest)
                        local label = line2 and (line1 .. "\n" .. line2) or line1
                        renderQuestRow(label,
                            function(self) showTurnInTooltip(self, quest, CLICK_HINT.turnIn) end,
                            function() focusQuest(quest.id) end,
                            function(self) showQuestContextMenu(self, quest) end,
                            function() linkQuestInChat(quest) end,
                            nil, quest)
                    end
                    y = y + TREE.GAP
                end
            end
        end
    end
    return true
end

-- The empty state when nothing renders: one muted line centred in the list that says what fills it, with a one-click fix for the likely cause under it. No button when the band is maxed; the line's advice (level up) has no shortcut. Changes made here bypass the Filter menu, so its reset button is rechecked.
local function renderEmptyState(filters)
    local anyBucket = filters.available or filters.pickedUpElsewhere
    local msg
    if not anyBucket then
        msg = "Starts Here and Starts Elsewhere are both off. Turn one on in the Filter menu."
    elseif searchText ~= "" then
        msg = string.format("No quests match \"%s\". Clear the search or change filters.", searchText)
    else
        msg = "No quests in your level range. Level up or widen the range."
    end
    emptyState:SetText(msg)
    emptyState:Show()

    local below, above = QuestieGuideDB.levelBelow, QuestieGuideDB.levelAbove
    local actionText, help, action
    if not anyBucket then
        actionText = "Show Both"
        help = "Turns Starts Here and Starts Elsewhere back on."
        action = function()
            filters.available = true
            filters.pickedUpElsewhere = true
            ns.mainFrame.filterDropdown:ValidateResetState()
            renderList()
        end
    elseif searchText ~= "" then
        actionText = "Clear Search"
        help = "Empties the search box, so every quest lists again."
        action = function()
            ns.mainFrame.searchBox:SetText("")
        end
    elseif below < RANGE_LIMIT.BELOW or above < RANGE_LIMIT.ABOVE then
        actionText = "Widen Level Range"
        help = "Adds up to two levels below and two above your level to the range."
        action = function()
            QuestieGuideDB.levelBelow = clampRange(below + 2, RANGE_LIMIT.BELOW)
            QuestieGuideDB.levelAbove = clampRange(above + 2, RANGE_LIMIT.ABOVE)
            ns.mainFrame.filterDropdown:ValidateResetState()
            invalidateScan()
            renderList()
        end
    end
    if actionText then
        local button = getEmptyButton(actionText, help)
        button:ClearAllPoints()
        button:SetPoint("TOP", emptyState, "BOTTOM", 0, -LIST.GROUP_GAP)
        button:SetScript("OnClick", action)
        button:Show()
    end
end

function renderList()
    if not scrollChild then
        return
    end
    hideEmptyState()
    local byZone, zoneOrder = ensureScan()
    local currentZoneName = getCurrentZoneName()
    sortZones(zoneOrder, byZone, currentZoneName)
    lastZoneOrder = zoneOrder
    rowTargets = {}
    zoneHeaderTops = {}
    local bestZoneName = findBestZone(byZone, zoneOrder)
    local filters = QuestieGuideDB.filters
    index, y = 1, 0
    headerCount, subHeaderCount = 0, 0
    local renderedZones = 0

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

    renderBanner(byZone, bestZoneName)
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
            for _, subKey in ipairs(SUBCAT_ORDER) do
                if filters[subKey] then
                    for _, q in ipairs(entry[subKey] or {}) do
                        if passesRow(q, filters, zoneMatch) then
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
                renderedZones = renderedZones + 1
                zoneHeaderTops[zoneName] = y

                -- One XP figure: rows in range plus the follow-ups unlocking in the zone. Search narrows the rows on screen, so the zone-level follow-up projection would no longer match them; it only counts on the unfiltered view. The percent of the level lives in the tooltip.
                local followupXp = (searchText == "" and entry.followups and entry.followups.xp) or 0
                local name = zoneName
                if zoneName == currentZoneName then
                    name = name .. " " .. HIGHLIGHT_FONT_COLOR:WrapTextInColorCode("(You are here)")
                end
                local header = renderHeader(zoneName, zoneCollapsedDB, collapsed, name, formatHeaderCount(inRangeTotal, inRangeXp + followupXp))
                header.stats, header.isBest = entry.stats, zoneName == bestZoneName

                if not collapsed then
                    for _, subKey in ipairs(SUBCAT_ORDER) do
                        local list = visible[subKey]
                        if filters[subKey] and #list > 0 then
                            local groupKey = zoneName .. "||" .. subKey
                            local groupHidden = groupCollapsedDB[groupKey] == true
                            renderSubHeader(groupKey, groupCollapsedDB, groupHidden, SUBCAT_LABEL[subKey], subInRangeCount[subKey] or 0, SUBCAT_HELP[subKey])
                            if not groupHidden then
                                for _, quest in ipairs(list) do
                                    renderBucketRow(quest)
                                end
                                y = y + TREE.GAP
                            end
                        end
                    end
                end
            end
        end
    end

    if renderedZones == 0 and not completedShown then
        renderEmptyState(filters)
    end

    scrollChild:SetHeight(math.max(y, 1))
    hideUnusedRows(index)
    hideUnusedHeaders(headerPool, headerCount + 1)
    hideUnusedHeaders(subHeaderPool, subHeaderCount + 1)

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

-- The empty state's line while the first render waits a tick, so an open never shows the last session's rows.
local function renderLoadingPlaceholder()
    hideEmptyState()
    hideUnusedRows(1)
    hideUnusedHeaders(headerPool, 1)
    hideUnusedHeaders(subHeaderPool, 1)
    emptyState:SetText("Scanning quest database\226\128\166")
    emptyState:Show()
    scrollChild:SetHeight(1)
end

-- The quest list fills the template's own Inset. ScrollFrameTemplate is what Forever's quest log (QuestScrollFrame) uses; it creates MinimalScrollBar and wires wheel, range and thumb itself.
local function buildQuestList(frame)
    -- The list sits one padding inside the inset, leaving the gutter the bar hangs into on the right.
    local scroll = CreateScroll(frame.Inset)
    scroll.ScrollBar:SetHideIfUnscrollable(true)
    scroll:SetPoint("TOPLEFT", frame.Inset, "TOPLEFT", PADDING, -PADDING)
    scroll:SetPoint("BOTTOMRIGHT", frame.Inset, "BOTTOMRIGHT", -SCROLL_GUTTER, PADDING)

    -- The empty state centres in the list's visible area. The scroll frame sits a level above the brown panel, which shares the Inset's level.
    emptyState = CreateEmptyState(scroll, "")
    emptyState:Hide()
    frame.emptyState = emptyState

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
    local searchBox = CreateSearchBox(frame, LAYOUT.SEARCH_W, "QuestieGuideSearchBox")
    searchBox:SetPoint("RIGHT", frame, "TOPRIGHT", -LAYOUT.SEARCH_RIGHT, (PANEL_INSET_TOP_OFFSET + PANEL_INSET_ATTIC_OFFSET) / 2)
    searchBox.Instructions:SetText("Quest, zone or NPC name")
    HookTooltip(searchBox, function(tooltip)
        GameTooltip_SetTitle(tooltip, SEARCH)
        GameTooltip_AddNormalLine(tooltip, "Lists only the quests whose name, zone or giver matches, with their zones expanded.")
    end)
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
ns.renderLoadingPlaceholder = renderLoadingPlaceholder
ns.buildQuestList = buildQuestList
ns.buildSearchBox = buildSearchBox
ns.toggleAllZones = toggleAllZones
