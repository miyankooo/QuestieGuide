-- Row text in Forever's quest log format, the quest, chain, zone and turn-in tooltips, and the quest lines on item tooltips.
local _, ns = ...

local COLOR = ns.COLOR
local sessionCache = ns.sessionCache
local isQuestCompleted = ns.isQuestCompleted
local getQuestTag = ns.getQuestTag
local getQuestXp = ns.getQuestXp
local isQuestHidden = ns.isQuestHidden
local getEffectiveLevel = ns.getEffectiveLevel
local passesLevelCap = ns.passesLevelCap
local getQuestName = ns.getQuestName
local getQuestStartInfo = ns.getQuestStartInfo
local resolveStartInfo = ns.resolveStartInfo
local meetsRequiredLevel = ns.meetsRequiredLevel
local exceedsRequiredMaxLevel = ns.exceedsRequiredMaxLevel
local matchesPlayerFaction = ns.matchesPlayerFaction
local isBlockedByPrereqs = ns.isBlockedByPrereqs
local getQuestLog = ns.getQuestLog
local questField = ns.questField
local itemField = ns.itemField
local getAllQuestIds = ns.getAllQuestIds
local isRepeatable = ns.isRepeatable
local isDoable = ns.isDoable
local getLevelDifficulty = ns.getLevelDifficulty

-- The tag text Forever's quest log prints after a quest name, per tag id (Camelot QuestUtilsOverrides.GetQuestTagText).
local QUEST_TAG_TEXT = {
    [Constants.QuestConsts.QUEST_INFO_ELITE_ID] = ELITE,
    [Constants.QuestConsts.QUEST_INFO_DUNGEON_ID] = CALENDAR_TYPE_DUNGEON,
    [Constants.QuestConsts.QUEST_INFO_PVP_ID] = CALENDAR_TYPE_PVP,
    [Constants.QuestConsts.QUEST_INFO_RAID_ID] = RAID,
}

-- Status label for a quest the player can't accept yet, in Blizzard's own "Requires Level %d" wording (ITEM_MIN_LEVEL).
local function formatLevelLock(requiredLevel)
    return COLOR.LOCKED:WrapTextInColorCode("[" .. ITEM_MIN_LEVEL:format(requiredLevel) .. "]")
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

-- One label/value tooltip row in Blizzard's own pairing: gold label, white value.
local function addTooltipField(tooltip, label, value)
    if value == nil or value == "" then
        return
    end
    GameTooltip_AddColoredDoubleLine(tooltip, label, tostring(value), NORMAL_FONT_COLOR, HIGHLIGHT_FONT_COLOR)
end

-- Every row tooltip: a GameTooltip owned by the hovered row, filled with Blizzard's GameTooltip_* line helpers. Rows set their own OnEnter for the hover highlight, so they call this from it.
local function showTooltip(anchor, fill)
    GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
    fill(GameTooltip)
    GameTooltip:Show()
end

-- The colour Forever's quest log gives a title (Camelot QuestUtilsOverrides.GetQuestTitleDifficultyColor): the game's difficulty for a quest the client has loaded, else the level gap, since the game rates a quest it hasn't loaded yellow.
local function getDifficultyColor(level, questId)
    local difficulty
    if HaveQuestData(questId) then
        difficulty = C_PlayerInfo.GetContentDifficultyQuestForPlayer(questId)
    elseif level and level > 0 then
        difficulty = getLevelDifficulty(level, UnitLevel("player"))
    end
    local color = GetDifficultyColor(difficulty)
    return CreateColor(color.r, color.g, color.b)
end

-- "[12+] Quest name" in the quest's difficulty colour, the title Forever's quest log shows (Camelot QuestUtilsOverrides.GetQuestTitlePrefix).
local function formatQuestTitle(questId, level, name)
    local _, isElite = getQuestTag(questId)
    local title = string.format("[%d%s] %s", level or 0, isElite and "+" or "", name or getQuestName(questId))
    return getDifficultyColor(level, questId):WrapTextInColorCode(title)
end

local function showQuestTooltip(anchor, questId)
    showTooltip(anchor, function(tooltip)
        GameTooltip_SetTitle(tooltip, formatQuestTitle(questId, (getEffectiveLevel(questId, UnitLevel("player")))))
        GameTooltip_AddBlankLineToTooltip(tooltip)

        local requiredLevel = questField(questId, "requiredLevel")
        if requiredLevel and requiredLevel > 0 then
            GameTooltip_AddHighlightLine(tooltip, ITEM_MIN_LEVEL:format(requiredLevel))
        end

        if isRepeatable(questId) then
            GameTooltip_AddColoredLine(tooltip, QUEST_CLASSIFICATION_RECURRING, COLOR.REPEATABLE)
        end
        local tagText = QUEST_TAG_TEXT[getQuestTag(questId)]
        if tagText then
            GameTooltip_AddColoredLine(tooltip, tagText, COLOR.MUTED)
        end

        local npcName, npcZone, npcSpawn = getQuestStartInfo(questId)
        addTooltipField(tooltip, "NPC", npcName)
        addTooltipField(tooltip, "Location", formatLocation(npcZone, npcSpawn))

        local xp = getQuestXp(questId)
        if xp > 0 then
            addTooltipField(tooltip, "XP", BreakUpLargeNumbers(xp))
        end

        local objectivesText = questField(questId, "objectivesText")
        if type(objectivesText) == "table" and #objectivesText > 0 then
            GameTooltip_AddBlankLineToTooltip(tooltip)
            GameTooltip_AddNormalLine(tooltip, "Objectives")
            for _, line in ipairs(objectivesText) do
                GameTooltip_AddHighlightLine(tooltip, line)
            end
        end
    end)
end

-- Giver text under a row, "zone, NPC", or nil when neither is known.
local function formatGiverLine(startInfo)
    if not (startInfo and (startInfo.zoneName or startInfo.npcName)) then
        return nil
    end
    local parts = {}
    if startInfo.zoneName then parts[#parts + 1] = startInfo.zoneName end
    if startInfo.npcName then parts[#parts + 1] = startInfo.npcName end
    return table.concat(parts, ", ")
end

-- Two-line row presentation in Forever's quest log format, "[12+] Quest name (Dungeon) [badge?]", over the giver's zone and name. Level and quest name share the difficulty colour; the tag and the whole giver line are muted grey so they read as secondary. `badge` is appended to line 1 when provided.
local function formatRowLines(quest, badge)
    local tagId = getQuestTag(quest.id)
    local line1 = formatQuestTitle(quest.id, quest.level, quest.name or "")
    if QUEST_TAG_TEXT[tagId] then
        line1 = line1 .. " " .. COLOR.MUTED:WrapTextInColorCode(PARENS_TEMPLATE:format(QUEST_TAG_TEXT[tagId]))
    end
    if badge then
        line1 = line1 .. " " .. badge
    end

    local giverLine = formatGiverLine(resolveStartInfo(quest))
    return line1, giverLine and COLOR.MUTED:WrapTextInColorCode(giverLine)
end

-- Status badge for prior quests in the chain tooltip. `[In Questlog]` if the player has the quest in their log, `[Available]` if it can be picked up right now, `[Requires Level N]` if only its level requirement stands in the way (isDoable ignores it), otherwise no badge. Completed quests don't appear in the chain at all (findMissingChains skips them).
local function getStatusBadge(questId)
    if getQuestLog()[questId] then
        return COLOR.IN_LOG:WrapTextInColorCode("[In Questlog]")
    end
    if isDoable(questId) then
        local playerLevel = UnitLevel("player")
        local _, requiredLevel = getEffectiveLevel(questId, playerLevel)
        if not meetsRequiredLevel(requiredLevel, playerLevel) then
            return formatLevelLock(requiredLevel)
        end
        return COLOR.READY:WrapTextInColorCode("[Available]")
    end
    return nil
end

-- Lightweight quest spec for formatRowLines callers that don't already have a list-row table on hand (i.e. the chain tooltip).
local function buildQuestSpec(questId)
    local level = getEffectiveLevel(questId, UnitLevel("player"))
    return {
        id = questId,
        level = level,
        name = getQuestName(questId),
    }
end

-- The chain tooltip's lines: the blocked quest as the title, then every prior step with its status badge.
local function fillChainTooltip(tooltip, mpe)
    local chain = mpe.chain

    -- Title: the hovered (blocked) quest, in the tooltip's larger title font so it stands out above the prior-quests list.
    GameTooltip_SetTitle(tooltip, (formatRowLines(mpe)))

    local giverLine = formatGiverLine(resolveStartInfo(mpe))
    if giverLine then
        GameTooltip_AddDisabledLine(tooltip, giverLine)
    end

    GameTooltip_AddBlankLineToTooltip(tooltip)

    -- Prior quests that must be completed before the hovered quest unlocks. The hovered quest itself is the chain tail (chain[#chain]); skip it.
    local priorCount = #chain - 1
    for i = 1, priorCount do
        local qid = chain[i]
        local spec = buildQuestSpec(qid)
        local line1, line2 = formatRowLines(spec, getStatusBadge(qid))
        GameTooltip_AddHighlightLine(tooltip, string.format("%d. %s", i, line1))
        if line2 then
            GameTooltip_AddHighlightLine(tooltip, line2)
        end
        if i ~= priorCount then
            GameTooltip_AddBlankLineToTooltip(tooltip)
        end
    end
end

-- Missing-prerequisite chain tooltip on a blocked row.
local function showChainTooltip(anchor, mpe)
    if type(mpe.chain) ~= "table" or #mpe.chain < 2 then
        return
    end
    showTooltip(anchor, function(tooltip)
        fillChainTooltip(tooltip, mpe)
    end)
end

-- Share of the current level an XP amount covers; nil at the level cap, where there is no next level.
local function getLevelShare(xp)
    local xpMax = UnitXPMax("player")
    if xp <= 0 or xpMax <= 0 or UnitLevel("player") >= GetMaxPlayerLevel() then
        return nil
    end
    return math.floor(xp / xpMax * 100 + 0.5)
end

-- Zone header hover: the breakdown behind the one-trip total. Uses scan-level stats driven by the level filter, which can differ from the rows on screen while a search or bucket filter narrows them.
local function showZoneTooltip(anchor, zoneName, stats, isBest, focusHint)
    if not stats then
        return
    end
    showTooltip(anchor, function(tooltip)
        GameTooltip_SetTitle(tooltip, zoneName)
        if isBest then
            GameTooltip_AddNormalLine(tooltip, "Best zone for your next trip.")
        end
        GameTooltip_AddBlankLineToTooltip(tooltip)
        local total = stats.xp or 0
        local share = getLevelShare(total)
        if share then
            addTooltipField(tooltip, "Total XP",
                string.format("%s XP, covers %d%% of level %d", BreakUpLargeNumbers(total), share, UnitLevel("player")))
        else
            addTooltipField(tooltip, "Total XP", BreakUpLargeNumbers(total) .. " XP")
        end
        if (stats.followupCount or 0) > 0 then
            addTooltipField(tooltip, "Includes follow-ups",
                string.format("%s XP (%d quests)", BreakUpLargeNumbers(stats.xpFollowup or 0), stats.followupCount))
        end
        if (stats.travelCount or 0) > 0 then
            addTooltipField(tooltip, "Unlocks elsewhere",
                string.format("%s XP (%d quests, not counted)", BreakUpLargeNumbers(stats.travelXp or 0), stats.travelCount))
        end
        if focusHint then
            GameTooltip_AddBlankLineToTooltip(tooltip)
            GameTooltip_AddInstructionLine(tooltip, "Right-click to focus this zone.")
        end
    end)
end

-- Tooltip for a ready-to-turn-in quest: the coloured title plus the turn-in target, mirroring showQuestTooltip's field styling. The quest's startInfo carries the finisher (see collectCompletedByZone).
local function showTurnInTooltip(anchor, quest)
    showTooltip(anchor, function(tooltip)
        GameTooltip_SetTitle(tooltip, formatQuestTitle(quest.id, quest.level, quest.name))
        GameTooltip_AddColoredLine(tooltip, "Completed", COLOR.READY)
        GameTooltip_AddBlankLineToTooltip(tooltip)
        local info = quest.startInfo
        addTooltipField(tooltip, "Turn in to", info and info.npcName)
        addTooltipField(tooltip, "Location", info and formatLocation(info.zoneName, info.spawn))
        if quest.xp and quest.xp > 0 then
            addTooltipField(tooltip, "XP", BreakUpLargeNumbers(quest.xp))
        end
    end)
end

-- Item tooltips list every quest the item belongs to that is NOT in the quest log, as the coloured quest title plus a "(Status)" suffix. Quests in the log are left out; the quest log already tracks them.
local INDEX_BUILD_DELAY = 5
local indexBuildScheduled = false

-- sessionCache.itemQuests: itemId -> quest ids referencing the item (objectives, quest-provided, required source), built from QuestieDB.
local function buildItemQuestIndex()
    indexBuildScheduled = false
    local index = {}
    local function add(itemId, questId)
        if type(itemId) ~= "number" or itemId <= 0 then
            return
        end
        local list = index[itemId]
        if not list then
            list = {}
            index[itemId] = list
        end

        -- Each quest is processed in one go, so a repeat of the previous entry is the same quest referencing the item in a second role.
        if list[#list] ~= questId then
            list[#list + 1] = questId
        end
    end
    for _, questId in ipairs(getAllQuestIds()) do
        -- Item objectives, then spell objectives, whose third field is the item the spell is cast with.
        local objectives = questField(questId, "objectives")
        if type(objectives) == "table" then
            if type(objectives[3]) == "table" then
                for _, objective in ipairs(objectives[3]) do
                    add((type(objective) == "table" and objective[1]) or objective, questId)
                end
            end
            if type(objectives[6]) == "table" then
                for _, objective in ipairs(objectives[6]) do
                    if type(objective) == "table" then
                        add(objective[3], questId)
                    end
                end
            end
        end
        add(questField(questId, "sourceItemId"), questId)
        local sourceItems = questField(questId, "requiredSourceItems")
        if type(sourceItems) == "table" then
            for _, itemId in ipairs(sourceItems) do
                add(itemId, questId)
            end
        end
    end
    sessionCache.itemQuests = index
end

-- A few seconds after login, so the walk over every quest doesn't share a frame with the login's own work.
local function scheduleItemQuestIndexBuild()
    if indexBuildScheduled then
        return
    end
    indexBuildScheduled = true
    C_Timer.After(INDEX_BUILD_DELAY, buildItemQuestIndex)
end

-- Classifies a non-log quest for the item tooltip as a label and its colour; nil skips the line. Skipped entirely: active quests, hidden or race/class-gated quests, and permanently unobtainable ones. A quest the player is too low for reads "Requires Level N", the chain tooltip's own wording (ITEM_MIN_LEVEL), in grey; "Upcoming" is left for prereq-blocked quests.
local function getItemQuestStatus(questId, playerLevel, currentLog)
    if currentLog[questId] then
        return nil
    end
    if isQuestCompleted(questId) then
        return "Completed Before", GRAY_FONT_COLOR
    end
    if isQuestHidden(questId) or not matchesPlayerFaction(questId) then
        return nil
    end
    local level, requiredLevel, requiredMaxLevel = getEffectiveLevel(questId, playerLevel)
    if not passesLevelCap(level, requiredLevel) or exceedsRequiredMaxLevel(requiredMaxLevel, playerLevel) then
        return nil
    end
    if not meetsRequiredLevel(requiredLevel, playerLevel) then
        return ITEM_MIN_LEVEL:format(requiredLevel), GRAY_FONT_COLOR
    end
    if isDoable(questId) then
        return "Available", GREEN_FONT_COLOR
    end
    if isBlockedByPrereqs(questId) then
        return "Upcoming", YELLOW_FONT_COLOR
    end
    return nil
end

-- Per-frame dedup: the post-call can fire repeatedly for one hover, so re-add only when the tooltip shows a different item or was rebuilt (fewer lines than when we last added).
local lastTooltipItem = {}

local function addQuestLinesToItemTooltip(tooltip, itemId)
    local itemQuests = sessionCache.itemQuests
    if tooltip:IsForbidden() or not itemId or not itemQuests then
        return
    end
    local last = lastTooltipItem[tooltip]
    if last and last.itemId == itemId and tooltip:NumLines() >= last.count then
        return
    end
    local currentLog = getQuestLog()
    local playerLevel = UnitLevel("player")
    local questIds = {}
    local seen = {}
    for _, questId in ipairs(itemQuests[itemId] or {}) do
        seen[questId] = true
        questIds[#questIds + 1] = questId
    end
    local startQuestId = itemField(itemId, "startQuest")
    if startQuestId and startQuestId > 0 and not seen[startQuestId] then
        questIds[#questIds + 1] = startQuestId
    end
    for _, questId in ipairs(questIds) do
        local label, color = getItemQuestStatus(questId, playerLevel, currentLog)
        if label then
            local level = getEffectiveLevel(questId, playerLevel)
            tooltip:AddLine(formatQuestTitle(questId, level) .. " " .. color:WrapTextInColorCode("(" .. label .. ")"))
        end
    end
    lastTooltipItem[tooltip] = { itemId = itemId, count = tooltip:NumLines() }
end

-- Forever hides tooltip data as secret values inside instances and in some combat cases; a secret can't be read or used as a key. Both predicates are declared SecretArguments = "AllowedWhenUntainted", so callers pcall this and count a raise as secret.
local function readableItemId(data)
    if type(data) ~= "table" or issecrettable(data) then
        return nil
    end
    local itemId = data.id
    if issecretvalue(itemId) or type(itemId) ~= "number" then
        return nil
    end
    return itemId
end

-- The item tooltip and the chat link tooltip; other tooltips, such as the comparison ones, stay as they are.
local function installItemTooltipHooks()
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
        if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then
            return
        end

        local ok, itemId = pcall(readableItemId, data)
        if ok and itemId then
            addQuestLinesToItemTooltip(tooltip, itemId)
        end
    end)
    for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
        tooltip:HookScript("OnHide", function(self)
            lastTooltipItem[self] = nil
        end)
    end
end

ns.formatRowLines = formatRowLines
ns.showQuestTooltip = showQuestTooltip
ns.showChainTooltip = showChainTooltip
ns.getLevelShare = getLevelShare
ns.showZoneTooltip = showZoneTooltip
ns.showTurnInTooltip = showTurnInTooltip
ns.installItemTooltipHooks = installItemTooltipHooks
ns.scheduleItemQuestIndexBuild = scheduleItemQuestIndexBuild
